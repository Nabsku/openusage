import CryptoKit
import Foundation
import Observation

/// Card-id helpers for the account-first model. The account occupying a family's default home when
/// first observed keeps the bare family id (`claude`, `codex`) as its permanent record id — that is
/// what makes existing installs migrate by doing nothing. Any later account of the same family mints
/// `family@<hash8>` from its identity key.
enum ProviderAccountID {
    enum BareRuntimeResolution: Sendable {
        case permanentRecord
        case currentDefaultSource
    }

    struct FamilyMetadata: Sendable {
        var bareRuntimeResolution: BareRuntimeResolution
    }

    /// Runtime aliases belong to family metadata: multi-card families keep their permanent bare
    /// record, while a single-runtime family follows whichever account currently owns its source.
    static let metadataByFamily: [String: FamilyMetadata] = [
        "claude": FamilyMetadata(bareRuntimeResolution: .permanentRecord),
        "codex": FamilyMetadata(bareRuntimeResolution: .currentDefaultSource),
    ]
    /// The family ids that participate in the account-first model.
    static let families = Set(metadataByFamily.keys)

    /// `claude@ab12cd34` — a stable, non-reversible id derived from the account's identity key.
    static func make(family: String, identityKey: String) -> String {
        "\(family)@\(hash8(identityKey))"
    }

    /// The digest also identifies remote-only account histories without exposing account details.
    static func hash8(_ identityKey: String) -> String {
        let digest = SHA256.hash(data: Data(identityKey.lowercased().utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The family a card id belongs to: `claude@ab12cd34` → `claude`, bare ids map to themselves.
    static func family(of cardID: String) -> String {
        cardID.firstIndex(of: "@").map { String(cardID[..<$0]) } ?? cardID
    }

    static func isAccountCard(_ cardID: String) -> Bool {
        cardID.contains("@")
    }
}

/// One place an account is signed in. "Default" is a badge on a source (`holdsDefaultSource`), never
/// a key: it marks who currently occupies the default home, and it never drives ids or sort order —
/// a swap re-points source edges, cards don't move. Phase 1 only observes the default home; later
/// phases add config dirs, cswap vault slots, Codex homes, and Desktop logins as more kinds.
struct ProviderAccountSource: Codable, Equatable, Sendable {
    /// A string-backed value, rather than an exhaustive enum, keeps account records readable when
    /// a newer development build introduces another source kind. Unknown sources stay persisted;
    /// this build simply cannot bind a runtime to one until it learns how to verify that source.
    struct Kind: RawRepresentable, Codable, Equatable, Hashable, Sendable {
        static let defaultHome = Self(rawValue: "defaultHome")
        static let configDir = Self(rawValue: "configDir")
        static let desktop = Self(rawValue: "desktop")

        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        var isKnown: Bool {
            self == .defaultHome || self == .configDir || self == .desktop
        }
    }

    var kind: Kind
    /// Canonical home path the source was observed at.
    var anchor: String?
    var holdsDefaultSource: Bool
    /// Claude Code hashes the literal config-dir spelling to derive its keychain service.
    var keychainLiteral: String?

    init(kind: Kind, anchor: String?, holdsDefaultSource: Bool, keychainLiteral: String? = nil) {
        self.kind = kind
        self.anchor = anchor
        self.holdsDefaultSource = holdsDefaultSource
        self.keychainLiteral = keychainLiteral
    }
}

/// An account as the account-first model sees it: opaque identity key, stable record id minted at
/// creation, and the sources currently attaching to it.
struct ProviderAccountRecord: Codable, Equatable, Sendable {
    /// Stable id minted when the account is first seen; never re-derived. The first account observed
    /// at a family's default home gets the bare family id.
    var id: String
    var family: String
    var identityKey: String
    /// Older Claude state sometimes omits the organization. Keep its previous spelling when that
    /// changes so a later second organization cannot silently inherit the same account card.
    var identityAliases: [String]? = nil
    var label: String?
    /// User-entered names belong to the account and survive source changes and rescans.
    var customLabel: String?
    var sources: [ProviderAccountSource]
    /// Historical tombstones remain honored, but unavailable accounts are hidden instead of removed.
    var removedTombstone: Bool = false

    var derivedDisplayName: String {
        derivedDisplayName(identifyingBareAccount: false)
    }

    /// The bare card keeps its original title while it is alone, but gains the same organization
    /// label as its siblings when multiple accounts need to be distinguished.
    func derivedDisplayName(identifyingBareAccount: Bool) -> String {
        guard ProviderAccountID.isAccountCard(id) || identifyingBareAccount else {
            return family.capitalized
        }
        guard let label = label?.nilIfEmpty else {
            if ProviderAccountID.isAccountCard(id) { return id }
            return "\(family.capitalized) — \(ProviderAccountID.hash8(identityKey).prefix(4))"
        }
        if label.hasSuffix(")"), let openingParenthesis = label.lastIndex(of: "(") {
            let organization = label[
                label.index(after: openingParenthesis)..<label.index(before: label.endIndex)
            ].trimmingCharacters(in: .whitespaces)
            if !organization.isEmpty {
                let email = label[..<openingParenthesis].trimmingCharacters(in: .whitespaces)
                let personalNames = ["\(email)'s Organization", "\(email)’s Organization"]
                let name = personalNames.contains {
                    $0.caseInsensitiveCompare(organization) == .orderedSame
                } ? "Personal" : organization
                return "\(family.capitalized) — \(name)"
            }
        }
        return "\(family.capitalized) — \(label)"
    }

}

/// The account-first registry (`openusage.providerAccounts.v2`). Reconciled at every launch from the
/// verified source observations. Every account-aware runtime is constructed from one of these records,
/// so its card, credentials, history, and persisted layout all share the same permanent account id.
@MainActor
@Observable
final class ProviderAccountsStore {
    static let storageKey = "openusage.providerAccounts.v2"
    static let legacyStorageKey = "openusage.providerAccounts.v1"

    private let defaults: UserDefaults
    private(set) var records: [ProviderAccountRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let currentData = defaults.data(forKey: Self.storageKey)
        let legacyData = defaults.data(forKey: Self.legacyStorageKey)
        if let data = currentData ?? legacyData {
            do {
                self.records = try JSONDecoder().decode([ProviderAccountRecord].self, from: data)
            } catch {
                AppLog.error(.config, "provider-account records were undecodable; starting a fresh registry: \(error.localizedDescription)")
                self.records = []
            }
        } else {
            self.records = []
        }

        if currentData == nil, legacyData != nil, !records.isEmpty {
            persist()
            AppLog.info(.config, "migrated \(records.count) provider account(s) into the downgrade-safe v2 registry")
        }
        if let legacyData {
            repairLegacyMirrorIfNeeded(legacyData)
        }
    }

    /// One account observed this launch, before reconciliation assigns (or re-finds) its record id.
    struct AccountObservation {
        var family: String
        var identityKey: String
        var label: String?
        var sources: [ProviderAccountSource]
    }

    /// Merges this launch's observations into the persisted set. Phase 1 semantics: an observation
    /// updates its account's label and sources, or creates the record; the first account of a family
    /// gets the bare family id, a later one mints `family@<hash8>`. Records never move or vanish here
    /// — an account that went unobserved (logged out, unreadable identity) is simply left as it was,
    /// except that a newly observed default-home holder takes the default badge off every sibling.
    @discardableResult
    func reconcile(with observations: [AccountObservation]) -> [ProviderAccountRecord] {
        var updated = records
        var changed = false

        for observation in observations {
            let match = Self.matchingRecord(
                for: observation,
                in: updated,
                observations: observations
            )
            if case .ambiguous = match {
                AppLog.warn(.config, "accounts: claude identity omitted its organization while multiple organizations share the login; observation quarantined")
                continue
            }
            if case .existing(let index) = match {
                guard !updated[index].removedTombstone else { continue }
                var record = updated[index]
                if record.identityKey != observation.identityKey {
                    var aliases = record.identityAliases ?? []
                    if !aliases.contains(record.identityKey) {
                        aliases.append(record.identityKey)
                    }
                    aliases.removeAll { $0 == observation.identityKey }
                    record.identityAliases = aliases.isEmpty ? nil : aliases
                    record.identityKey = observation.identityKey
                }
                record.label = observation.label ?? record.label
                // A source added by a newer app must survive this build's narrower discovery pass.
                // Known sources, by contrast, are authoritative for the current launch: keeping a
                // stale default-home edge would let a moved account borrow another login.
                let forwardCompatibleSources = record.sources.filter { !$0.kind.isKnown }
                record.sources = observation.sources + forwardCompatibleSources
                if record != updated[index] {
                    updated[index] = record
                    changed = true
                }
            } else {
                updated.append(ProviderAccountRecord(
                    id: Self.availableID(for: observation, in: updated),
                    family: observation.family,
                    identityKey: observation.identityKey,
                    label: observation.label,
                    sources: observation.sources
                ))
                changed = true
            }

            // The default badge is exclusive per family: when this observation holds it, strip it
            // from every sibling record (the account that swapped out no longer answers the bare id).
            if observation.sources.contains(where: \.holdsDefaultSource) {
                for index in updated.indices
                where updated[index].family == observation.family
                    && updated[index].identityKey != observation.identityKey
                    && updated[index].sources.contains(where: \.holdsDefaultSource)
                {
                    updated[index].sources = updated[index].sources.map { source in
                        var source = source
                        source.holdsDefaultSource = false
                        return source
                    }
                    changed = true
                }
            }
        }

        if changed {
            records = updated
            persist()
        }
        return records
    }

    private enum RecordMatch {
        case existing(Int)
        case newRecord
        case ambiguous
    }

    /// Claude's account UUID can appear either alone or with its organization UUID. Treat those as
    /// one account only when the user's complete persisted and incoming history proves exactly one
    /// possible organization; two different explicit organizations are always separate accounts.
    private static func matchingRecord(
        for observation: AccountObservation,
        in records: [ProviderAccountRecord],
        observations: [AccountObservation]
    ) -> RecordMatch {
        guard observation.family == "claude" else {
            if let index = records.firstIndex(where: {
                $0.family == observation.family && $0.identityKey == observation.identityKey
            }) {
                return .existing(index)
            }
            return .newRecord
        }

        guard let observed = ClaudeIdentity(observation.identityKey) else { return .ambiguous }
        let familyRecords = records.enumerated().filter { _, record in
            record.family == observation.family
                && ClaudeIdentity(record.identityKey)?.user == observed.user
        }
        let known = familyRecords.flatMap { _, record in
            ([record.identityKey] + (record.identityAliases ?? [])).compactMap(ClaudeIdentity.init)
        } + observations.compactMap { candidate -> ClaudeIdentity? in
            guard candidate.family == observation.family,
                  let identity = ClaudeIdentity(candidate.identityKey),
                  identity.user == observed.user
            else { return nil }
            return identity
        }
        guard let resolved = ClaudeIdentity.canonical(observed, among: known) else { return .ambiguous }
        if let exact = familyRecords.first(where: { _, record in
            ClaudeIdentity(record.identityKey)?.matchesExactly(observed) == true
        }) {
            return .existing(exact.offset)
        }

        let compatible = familyRecords.filter { _, record in
            guard let existing = ClaudeIdentity(record.identityKey),
                  let canonical = ClaudeIdentity.canonical(existing, among: known)
            else { return false }
            return canonical == resolved
        }
        guard compatible.count == 1 else {
            return compatible.isEmpty ? .newRecord : .ambiguous
        }
        return .existing(compatible[0].offset)
    }

    func record(for cardID: String) -> ProviderAccountRecord? {
        records.first { $0.id == cardID }
    }

    /// Claude runtimes follow their permanent account-card ids, while the single Codex runtime
    /// still keeps its historical bare id when another recorded account takes the default home.
    /// Resolve that one presentation alias to its current verified owner, never to the old record.
    func runtimeRecord(for cardID: String) -> ProviderAccountRecord? {
        let family = ProviderAccountID.family(of: cardID)
        if !ProviderAccountID.isAccountCard(cardID),
           ProviderAccountID.metadataByFamily[family]?.bareRuntimeResolution == .currentDefaultSource
        {
            return defaultBadgeHolder(family: family)
        }
        return record(for: cardID)
    }

    /// The contextual default title, shared by baked providers, visible cards, API output, and the
    /// Customize name placeholder. Stable identity suffixes distinguish duplicate organization names.
    func derivedDisplayName(cardID: String) -> String? {
        guard let record = runtimeRecord(for: cardID) else { return nil }
        let familyRecords = records.filter {
            $0.family == record.family && !$0.removedTombstone
        }
        let identifiesBareAccount = familyRecords.count > 1
        let proposed = record.derivedDisplayName(
            identifyingBareAccount: identifiesBareAccount
        )
        let collides = familyRecords.contains { sibling in
            guard sibling.id != record.id else { return false }
            let siblingName = sibling.customLabel?.nilIfEmpty
                ?? sibling.derivedDisplayName(identifyingBareAccount: identifiesBareAccount)
            return siblingName == proposed
        }
        guard collides else { return proposed }
        return "\(proposed) · \(ProviderAccountID.hash8(record.identityKey).prefix(4))"
    }

    func resolvedDisplayName(cardID: String) -> String? {
        guard let record = runtimeRecord(for: cardID) else { return nil }
        return record.customLabel?.nilIfEmpty ?? derivedDisplayName(cardID: cardID)
    }

    var resolvedDisplayNamesByCardID: [String: String] {
        Dictionary(uniqueKeysWithValues: records.compactMap { record in
            resolvedDisplayName(cardID: record.id).map { (record.id, $0) }
        })
    }

    func rename(cardID: String, to name: String?) {
        guard let record = runtimeRecord(for: cardID),
              let index = records.firstIndex(where: { $0.id == record.id })
        else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard records[index].customLabel != trimmed else { return }
        records[index].customLabel = trimmed
        persist()
    }

    /// The record currently holding a family's default badge, if any.
    func defaultBadgeHolder(family: String) -> ProviderAccountRecord? {
        records.first { record in
            record.family == family
                && !record.removedTombstone
                && record.sources.contains(where: \.holdsDefaultSource)
        }
    }

    /// A logged-out or unreadable default home no longer belongs to its previous account. Retain
    /// the account and every other source, but remove its stale home edge and default badge so a
    /// future source cannot inherit ownership from an old observation.
    func clearDefaultSource(family: String) {
        var changed = false
        for index in records.indices where records[index].family == family {
            let existing = records[index].sources
            let remaining = existing
                .filter { $0.kind != .defaultHome }
                .map { source in
                    var source = source
                    source.holdsDefaultSource = false
                    return source
                }
            guard remaining != existing else { continue }
            records[index].sources = remaining
            changed = true
        }
        if changed { persist() }
    }

    /// The bare family id when free (the migration-killing rule: the first account observed at the
    /// default home IS the existing card), else an identity-derived `family@<hash8>` id.
    private static func availableID(for observation: AccountObservation, in records: [ProviderAccountRecord]) -> String {
        let observedAtDefaultHome = observation.sources.contains { $0.kind == .defaultHome }
        if observedAtDefaultHome, !records.contains(where: { $0.id == observation.family }) {
            return observation.family
        }
        let derived = ProviderAccountID.make(family: observation.family, identityKey: observation.identityKey)
        guard records.contains(where: { $0.id == derived }) else { return derived }
        // A hash-prefix collision between two distinct identities of one family; salt until free.
        var attempt = 0
        while true {
            let salted = ProviderAccountID.make(
                family: observation.family,
                identityKey: "\(observation.identityKey)|\(attempt)"
            )
            if !records.contains(where: { $0.id == salted }) { return salted }
            attempt += 1
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else {
            AppLog.error(.config, "failed to encode provider-account records; keeping previous persisted state")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Development builds before the registry split may already have written Desktop/config-dir
    /// sources into v1, which older releases decode as an exhaustive default-home-only enum. Keep
    /// v2 authoritative, but repair that legacy mirror once so downgrading cannot wipe its records.
    private func repairLegacyMirrorIfNeeded(_ data: Data) {
        if (try? JSONDecoder().decode([LegacyAccountRecord].self, from: data)) != nil {
            return
        }
        guard !records.isEmpty else { return }
        let projected = records.map { record in
            LegacyAccountRecord(
                id: record.id,
                family: record.family,
                identityKey: record.identityKey,
                label: record.label,
                sources: record.sources.compactMap { source in
                    guard source.kind == .defaultHome else { return nil }
                    return LegacyAccountSource(
                        kind: .defaultHome,
                        anchor: source.anchor,
                        holdsDefaultSource: source.holdsDefaultSource
                    )
                },
                removedTombstone: record.removedTombstone
            )
        }
        do {
            defaults.set(try JSONEncoder().encode(projected), forKey: Self.legacyStorageKey)
            AppLog.info(.config, "repaired the legacy provider-account mirror for downgrade compatibility")
        } catch {
            AppLog.error(.config, "failed to repair the legacy provider-account mirror: \(error.localizedDescription)")
        }
    }

    private struct LegacyAccountRecord: Codable {
        var id: String
        var family: String
        var identityKey: String
        var label: String?
        var sources: [LegacyAccountSource]
        var removedTombstone: Bool
    }

    private struct LegacyAccountSource: Codable {
        enum Kind: String, Codable { case defaultHome }

        var kind: Kind
        var anchor: String?
        var holdsDefaultSource: Bool
    }
}
