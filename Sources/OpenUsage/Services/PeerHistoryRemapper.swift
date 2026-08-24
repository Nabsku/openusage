import Foundation

/// Account histories merge only when both Macs prove the same provider-family/account identity.
enum PeerHistoryRemapper {
    struct Remapped {
        var histories: [(cardID: String, history: ProviderUsageHistory)] = []
        var remoteOnly: [RemoteOnlyHistory] = []
        var quarantined: [QuarantinedHistory] = []
    }

    struct QuarantinedHistory {
        enum Reason: Equatable {
            case missingPeerIdentity
            case ambiguousPeerIdentity
            case unresolvedLocalIdentity
            case ambiguousLocalIdentity
        }

        var cardID: String
        var family: String
        var reason: Reason
    }

    struct RemoteOnlyHistory {
        var identityKey: String
        var family: String
        var cardID: String
        var deviceNamesByID: [String: String]
        var histories: [ProviderUsageHistory]

        var displayName: String {
            let deviceLabel = deviceNamesByID.count == 1
                ? deviceNamesByID.values.first ?? "Another Mac"
                : "\(deviceNamesByID.count) Macs"
            return "\(family.capitalized) · \(deviceLabel)"
        }
    }

    static func remap(
        documents: [UsageHistoryDocument],
        localIdentityByCardID: [String: String],
        localAccountCardIDs: Set<String>,
        knownAccountIdentitiesByFamily: [String: Set<String>] = [:]
    ) -> Remapped {
        struct AccountKey: Hashable {
            let family: String
            let identity: String

            init(family: String, identity: String) {
                self.family = family
                self.identity = identity.lowercased()
            }
        }

        var knownIdentities = knownAccountIdentitiesByFamily
        for (cardID, identity) in localIdentityByCardID {
            knownIdentities[ProviderAccountID.family(of: cardID), default: []].insert(identity)
        }
        for document in documents {
            for (cardID, identity) in document.identities ?? [:] {
                knownIdentities[ProviderAccountID.family(of: cardID), default: []].insert(identity)
            }
        }
        func accountKey(family: String, identity: String) -> AccountKey? {
            guard family == "claude", let parsed = ClaudeIdentity(identity) else {
                return AccountKey(family: family, identity: identity)
            }
            let organizations = Set((knownIdentities[family] ?? []).compactMap(ClaudeIdentity.init).compactMap {
                $0.user == parsed.user ? $0.organization : nil
            })
            if parsed.organization == nil, organizations.count > 1 { return nil }
            let canonical = parsed.organization.map { "\(parsed.user)|\($0)" }
                ?? organizations.first.map { "\(parsed.user)|\($0)" }
                ?? parsed.user
            return AccountKey(family: family, identity: canonical)
        }

        var localCards: [AccountKey: [String]] = [:]
        var ambiguousLocalUsers: Set<String> = []
        for (cardID, identity) in localIdentityByCardID where !identity.isEmpty {
            let family = ProviderAccountID.family(of: cardID)
            guard ProviderAccountID.families.contains(family) else { continue }
            guard let key = accountKey(family: family, identity: identity) else {
                if let parsed = ClaudeIdentity(identity) { ambiguousLocalUsers.insert(parsed.user) }
                continue
            }
            localCards[key, default: []].append(cardID)
        }
        var result = Remapped()
        var remoteAccounts: [AccountKey: RemoteOnlyHistory] = [:]

        for document in UsageHistoryDocument.newestByDevice(documents) {
            let peerIdentityCounts = Dictionary(
                (document.identities ?? [:]).compactMap { cardID, identity in
                    accountKey(family: ProviderAccountID.family(of: cardID), identity: identity)
                        .map { ($0, 1) }
                },
                uniquingKeysWith: +
            )
            for (peerCardID, history) in document.providers.sorted(by: { $0.key < $1.key }) {
                let family = ProviderAccountID.family(of: peerCardID)

                guard ProviderAccountID.families.contains(family) else {
                    result.histories.append((peerCardID, history))
                    continue
                }

                guard let identity = document.identities?[peerCardID], !identity.isEmpty else {
                    result.quarantined.append(.init(cardID: peerCardID, family: family, reason: .missingPeerIdentity))
                    continue
                }
                guard let key = accountKey(family: family, identity: identity) else {
                    result.quarantined.append(.init(cardID: peerCardID, family: family, reason: .ambiguousPeerIdentity))
                    continue
                }
                guard peerIdentityCounts[key] == 1 else {
                    result.quarantined.append(.init(cardID: peerCardID, family: family, reason: .ambiguousPeerIdentity))
                    continue
                }

                let matches = localCards[key] ?? []
                if matches.count == 1 {
                    result.histories.append((matches[0], history))
                    continue
                }
                if matches.count > 1 {
                    result.quarantined.append(.init(cardID: peerCardID, family: family, reason: .ambiguousLocalIdentity))
                    continue
                }
                if family == "claude", let parsed = ClaudeIdentity(identity),
                   ambiguousLocalUsers.contains(parsed.user)
                {
                    result.quarantined.append(.init(cardID: peerCardID, family: family, reason: .ambiguousLocalIdentity))
                    continue
                }

                let familyCards = localAccountCardIDs.filter { ProviderAccountID.family(of: $0) == family }
                if familyCards.contains(where: { localIdentityByCardID[$0] == nil }) {
                    result.quarantined.append(.init(cardID: peerCardID, family: family, reason: .unresolvedLocalIdentity))
                    continue
                }

                var entry = remoteAccounts[key] ?? RemoteOnlyHistory(
                    identityKey: key.identity,
                    family: family,
                    cardID: ProviderAccountID.make(family: family, identityKey: key.identity),
                    deviceNamesByID: [:],
                    histories: []
                )
                entry.deviceNamesByID[document.deviceID] = document.deviceName
                entry.histories.append(history)
                remoteAccounts[key] = entry
            }
        }

        result.remoteOnly = remoteAccounts.values.sorted {
            ($0.family, $0.identityKey) < ($1.family, $1.identityKey)
        }
        return result
    }
}
