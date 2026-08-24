import Foundation

/// Account aliases combine only when their complete identity universe proves one organization.
struct ClaudeIdentity: Hashable, Sendable {
    let user: String
    let organization: String?

    init?(_ raw: String) {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let components = normalized.split(separator: "|", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count),
              !components[0].isEmpty,
              components.count == 1 || !components[1].isEmpty,
              normalized.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { return nil }
        user = String(components[0])
        organization = components.count == 2 ? String(components[1]) : nil
    }

    var key: String { organization.map { "\(user)|\($0)" } ?? user }
    func matchesExactly(_ other: ClaudeIdentity) -> Bool { self == other }

    static func canonical(
        _ identity: ClaudeIdentity,
        among known: some Sequence<ClaudeIdentity>,
        preferred: [String: ClaudeIdentity] = [:]
    ) -> ClaudeIdentity? {
        let organizations = Set(known.compactMap { candidate in
            candidate.user == identity.user ? candidate.organization : nil
        })
        if identity.organization != nil {
            if organizations.count == 1,
               let preferred = preferred[identity.user],
               preferred.organization == nil
            {
                return preferred
            }
            return identity
        }
        guard organizations.count <= 1 else { return nil }
        if let preferred = preferred[identity.user], preferred.organization == nil { return preferred }
        guard let organization = organizations.first else { return identity }
        return ClaudeIdentity("\(identity.user)|\(organization)")
    }

    static func canonical(
        _ raw: String,
        among known: some Sequence<String>,
        preferred: [String: String] = [:]
    ) -> String? {
        guard let identity = ClaudeIdentity(raw) else { return nil }
        let identities = known.compactMap(ClaudeIdentity.init)
        let preferences = preferred.reduce(into: [String: ClaudeIdentity]()) { result, entry in
            if let identity = ClaudeIdentity(entry.value) { result[entry.key.lowercased()] = identity }
        }
        return canonical(identity, among: identities, preferred: preferences)?.key
    }
}

/// A Desktop token is either forbidden, limited to one verified organization, or allowed to follow
/// the active organization only when the complete account evidence proves one possible owner.
enum ClaudeDesktopAccessPolicy: Equatable, Sendable {
    case denied
    case activeOrganization
    case pinned(String)

    var organization: String? {
        guard case .pinned(let organization) = self else { return nil }
        return organization
    }
}

/// Keeps Desktop credential ownership independent from Cowork spend-log routing. Desktop tokens
/// identify an organization but not a user, so hidden accounts still contribute ownership evidence.
struct ClaudeDesktopAccountPolicy {
    private let knownIdentities: Set<ClaudeIdentity>
    private let usersByOrganization: [String: Set<String>]
    private let organizationsByUser: [String: Set<String>]
    private let usersWithoutKnownOrganization: Set<String>

    init(
        records: [ProviderAccountRecord],
        defaultOutcome: DefaultAccountObserver.Outcome?,
        configFindings: [ClaudeConfigDirDiscovery.Finding],
        coworkScan: ClaudeCoworkDiscovery.Result?
    ) {
        var identities = Set(
            records
                .filter { $0.family == "claude" }
                .flatMap { [$0.identityKey] + ($0.identityAliases ?? []) }
                .compactMap(ClaudeIdentity.init)
        )
        if case .resolved(let raw, _, _)? = defaultOutcome,
           let identity = ClaudeIdentity(raw)
        {
            identities.insert(identity)
        }
        for finding in configFindings {
            if let identity = ClaudeIdentity(finding.identityKey) {
                identities.insert(identity)
            }
        }
        // A partial walk cannot assign logs or create cards, but identities it positively observed
        // still disprove exclusive Desktop ownership and must remain usable as safety evidence.
        for sandbox in coworkScan?.sandboxes ?? [] {
            if let raw = sandbox.identityKey, let identity = ClaudeIdentity(raw) {
                identities.insert(identity)
            }
        }
        knownIdentities = identities

        var usersByOrganization: [String: Set<String>] = [:]
        var organizationsByUser: [String: Set<String>] = [:]
        var organizationlessUsers = Set<String>()
        for identity in identities {
            guard let organization = identity.organization else {
                organizationlessUsers.insert(identity.user)
                continue
            }
            usersByOrganization[organization, default: []].insert(identity.user)
            organizationsByUser[identity.user, default: []].insert(organization)
        }
        self.usersByOrganization = usersByOrganization
        self.organizationsByUser = organizationsByUser
        // An org-less alias of a user with one known org is not a second unknown account; an
        // entirely org-less different user, by contrast, could own any Desktop organization.
        usersWithoutKnownOrganization = organizationlessUsers.subtracting(organizationsByUser.keys)
    }

    func hasAmbiguousOrganization(_ organization: String?) -> Bool {
        guard let organization = organization?.nilIfEmpty?.lowercased() else { return false }
        let identifiedUsers = usersByOrganization[organization] ?? []
        return identifiedUsers.count > 1
            || usersWithoutKnownOrganization.contains { !identifiedUsers.contains($0) }
    }

    /// Prefer a known org even when Claude Code's current state temporarily omits it. The pin is
    /// valid only when aliases, persisted records, and scanned sources name exactly one possibility.
    func organization(for identityKey: String?) -> String? {
        guard let identityKey, let identity = ClaudeIdentity(identityKey) else { return nil }
        if let organization = identity.organization { return organization }
        guard let organizations = organizationsByUser[identity.user], organizations.count == 1 else {
            return nil
        }
        return organizations.first
    }

    /// One closed decision travels unchanged from source assembly into the auth store; no runtime
    /// reconstructs credential safety from account count, log partitions, or unrelated booleans.
    func access(
        for identityKey: String,
        allowsActiveOrganization: Bool
    ) -> ClaudeDesktopAccessPolicy {
        if let organization = organization(for: identityKey) {
            return hasAmbiguousOrganization(organization) ? .denied : .pinned(organization)
        }
        return allowsActiveOrganization ? .activeOrganization : .denied
    }

    func allowsUnpinnedFallback(
        defaultIdentity: String?,
        hasExactlyOneDefaultAccount: Bool,
        coworkScan: ClaudeCoworkDiscovery.Result?
    ) -> Bool {
        guard hasExactlyOneDefaultAccount,
              let defaultIdentity,
              let account = ClaudeIdentity(defaultIdentity)
        else { return false }
        // An explicit org still gets its pinned fallback during an incomplete walk; preserve the
        // stricter scoped-keychain behavior rather than unnecessarily re-enabling the bare item.
        if coworkScan?.truncated == true, account.organization != nil { return false }

        var organizations: Set<String> = []
        for identity in knownIdentities {
            guard identity.user == account.user else { return false }
            if let organization = identity.organization {
                organizations.insert(organization)
                if organizations.count > 1 { return false }
            }
        }
        return true
    }
}
