import Foundation

/// Claude Desktop identifies cached tokens by organization, never by the individual user.
enum ClaudeDesktopAccessPolicy: Equatable, Sendable {
    case denied
    case activeOrganization
    case pinned(String)

    var organization: String? {
        guard case .pinned(let organization) = self else { return nil }
        return organization
    }
}

struct ClaudeIdentity: Hashable, Sendable {
    let user: String
    let organization: String?

    init?(_ value: String) {
        let parts = value.lowercased().split(separator: "|", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        user = String(parts[0])
        organization = parts.count == 2 ? String(parts[1]) : nil
    }

    var key: String { organization.map { "\(user)|\($0)" } ?? user }
}

/// Every observed and remembered identity contributes to one closed Desktop ownership decision.
struct ClaudeDesktopAccountPolicy {
    private let identities: Set<ClaudeIdentity>

    init(
        records: [ProviderAccountRecord],
        defaultOutcome: DefaultAccountObserver.Outcome?,
        configFindings: [ClaudeConfigDirDiscovery.Finding],
        coworkScan: ClaudeCoworkDiscovery.Result?
    ) {
        let persisted = records.filter { $0.family == "claude" }.flatMap { record in
            ([record.identityKey] + (record.identityAliases ?? [])).compactMap(ClaudeIdentity.init)
        }
        var collected = Set(persisted)
        if case .resolved(let value, _, _)? = defaultOutcome, let identity = ClaudeIdentity(value) {
            collected.insert(identity)
        }
        collected.formUnion(configFindings.compactMap { ClaudeIdentity($0.identityKey) })
        collected.formUnion((coworkScan?.sandboxes ?? []).compactMap { sandbox in
            sandbox.identityKey.flatMap(ClaudeIdentity.init)
        })
        identities = collected
    }

    func canonical(_ value: String) -> String? {
        guard let identity = ClaudeIdentity(value) else { return nil }
        let organizations = Set(identities.compactMap { $0.user == identity.user ? $0.organization : nil })
        if identity.organization == nil, organizations.count > 1 { return nil }
        if identity.organization == nil, let organization = organizations.first {
            return "\(identity.user)|\(organization)"
        }
        return identity.key
    }

    var hasMultipleAccounts: Bool {
        Set(identities.compactMap { canonical($0.key) }).count > 1
    }

    func organization(for value: String?) -> String? {
        guard let value, let identity = ClaudeIdentity(value) else { return nil }
        if let organization = identity.organization { return organization }
        let organizations = Set(identities.compactMap { $0.user == identity.user ? $0.organization : nil })
        return organizations.count == 1 ? organizations.first : nil
    }

    func access(for value: String?, allowsActiveOrganization: Bool) -> ClaudeDesktopAccessPolicy {
        guard let value, let identity = ClaudeIdentity(value) else { return .denied }
        guard let organization = organization(for: value) else {
            return allowsActiveOrganization && !hasMultipleAccounts ? .activeOrganization : .denied
        }
        let knownOwners = Set(identities.filter { $0.organization == organization }.map(\.user))
        let unidentifiedOwners = Set(identities.filter { candidate in
            candidate.organization == nil
                && !identities.contains { $0.user == candidate.user && $0.organization != nil }
        }.map(\.user))
        guard knownOwners.union(unidentifiedOwners).subtracting([identity.user]).isEmpty else {
            return .denied
        }
        return .pinned(organization)
    }
}
