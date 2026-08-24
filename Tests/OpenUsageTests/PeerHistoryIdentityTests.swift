import XCTest
@testable import OpenUsage

/// Identity-keyed iCloud matching: the same account merges into the same card across Macs regardless
/// of which machine calls it the default and which shows it as an extra account card, and accounts
/// with no local card surface as remote-only Total Spend entries.
@MainActor
final class PeerHistoryIdentityTests: XCTestCase {
    private let teamKey = "uuid-me|org-team"
    private let maxKey = "uuid-me|org-max"

    func testDocumentV2AllowsAccountCardsAndV1StaysStrict() throws {
        var v2 = makeDocument(providers: [
            "claude": history(day: "2026-07-16", tokens: 10, cost: 1),
            "claude@ab12cd34": history(day: "2026-07-16", tokens: 20, cost: 2),
        ], identities: ["claude": maxKey, "claude@ab12cd34": teamKey])
        XCTAssertNoThrow(try v2.validate())

        v2.schema = UsageHistoryDocument.legacySchemaV1
        XCTAssertThrowsError(try v2.validate()) // account-card ids are a v2 concept

        let v1 = UsageHistoryDocument(
            schema: UsageHistoryDocument.legacySchemaV1,
            deviceID: "d", deviceName: "n", updatedAt: Date(),
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: nil
        )
        XCTAssertNoThrow(try v1.validate())
    }

    func testRemapMatchesAccountsAcrossDefaultAndExtraCardRoles() {
        // The mini↔MacBook case: mini's DEFAULT card is the Team account (claude), its extra card is
        // Max. This Mac is the mirror image (default = Max, extra = Team). Every peer history must
        // land on the LOCAL card with the same account.
        let miniDoc = makeDocument(
            deviceName: "Mac mini",
            providers: [
                "claude": history(day: "2026-07-16", tokens: 100, cost: 502.34),
                "claude@b2d3867d": history(day: "2026-07-16", tokens: 90, cost: 494.27),
            ],
            identities: ["claude": teamKey, "claude@b2d3867d": maxKey]
        )
        let localMap = ["claude": maxKey, "claude@f15456b0": teamKey]

        let remapped = PeerHistoryRemapper.remap(documents: [miniDoc], localIdentityByCardID: localMap)

        XCTAssertTrue(remapped.remoteOnly.isEmpty)
        let byCard = Dictionary(grouping: remapped.histories, by: { $0.cardID })
        XCTAssertEqual(byCard["claude"]?.first?.history.series.daily.first?.costUSD, 494.27, "mini's Max spend belongs to this Mac's default (Max) card")
        XCTAssertEqual(byCard["claude@f15456b0"]?.first?.history.series.daily.first?.costUSD, 502.34, "mini's Team spend belongs to this Mac's Team card")
    }

    func testUnsafeIdentityStatesNeverMergeOrCreateRemoteOnlySpend() {
        let usage = history(day: "2026-07-16", tokens: 10, cost: 1)
        let claude = makeDocument(providers: ["claude": usage], identities: ["claude": teamKey])
        let duplicate = makeDocument(
            providers: ["claude": usage, "claude@extra": usage],
            identities: ["claude": teamKey, "claude@extra": teamKey]
        )
        let codex = makeDocument(providers: ["codex": usage], identities: ["codex": "shared"])
        let cases: [(name: String, document: UsageHistoryDocument, local: [String: String], cards: Set<String>?,
                     reasons: [PeerHistoryRemapper.QuarantinedHistory.Reason])] = [
            ("unresolved local account", claude, [:], nil, [.unresolvedLocalIdentity]),
            ("duplicate local account", claude, ["claude": teamKey, "claude@extra": teamKey], nil,
             [.ambiguousLocalIdentity]),
            ("duplicate peer account", duplicate, ["claude": teamKey], nil,
             [.ambiguousPeerIdentity, .ambiguousPeerIdentity]),
            ("cross-provider identity", codex, ["claude": "shared"], nil, [.unresolvedLocalIdentity]),
            ("unresolved sibling", claude, ["claude": maxKey], ["claude", "claude@extra"],
             [.unresolvedLocalIdentity])
        ]
        for entry in cases {
            let remapped = PeerHistoryRemapper.remap(
                documents: [entry.document], localIdentityByCardID: entry.local, localAccountCardIDs: entry.cards
            )
            XCTAssertTrue(remapped.histories.isEmpty, entry.name)
            XCTAssertTrue(remapped.remoteOnly.isEmpty, entry.name)
            XCTAssertEqual(remapped.quarantined.map(\.reason), entry.reasons, entry.name)
        }
    }

    func testLegacyHistoryQuarantinesAccountFamiliesButMergesOtherProviders() {
        for cardID in ["claude", "grok"] {
            let document = UsageHistoryDocument(
                schema: UsageHistoryDocument.legacySchemaV1,
                deviceID: "d", deviceName: "old Mac", updatedAt: Date(),
                providers: [cardID: history(day: "2026-07-16", tokens: 10, cost: 1)], identities: nil
            )
            let remapped = PeerHistoryRemapper.remap(
                documents: [document], localIdentityByCardID: ["claude": maxKey]
            )
            XCTAssertEqual(remapped.histories.map(\.cardID), cardID == "grok" ? [cardID] : [], cardID)
            XCTAssertEqual(remapped.quarantined.map(\.reason),
                           cardID == "claude" ? [.missingPeerIdentity] : [], cardID)
            XCTAssertTrue(remapped.remoteOnly.isEmpty, cardID)
        }
    }

    func testOrganizationAliasesMergeOnlyWhenTheirCompleteIdentityUniverseIsUnambiguous() {
        func document(_ identities: [String: String]) -> UsageHistoryDocument {
            makeDocument(
                providers: Dictionary(uniqueKeysWithValues: identities.keys.map {
                    ($0, history(day: "2026-07-16", tokens: 10, cost: 1))
                }), identities: identities
            )
        }
        typealias Reason = PeerHistoryRemapper.QuarantinedHistory.Reason
        let cases: [(name: String, documents: [UsageHistoryDocument], local: [String: String],
                     merged: [String], remote: [String], reasons: [Reason])] = [
            ("orgless peer", [document(["claude": "uuid-me"])], ["claude@extra": teamKey],
             ["claude@extra"], [], []),
            ("orgless local account", [document(["claude@extra": teamKey])], ["claude": "uuid-me"],
             ["claude"], [], []),
            ("orgless peer with multiple organizations", [document(["claude": "uuid-me"])],
             ["claude": maxKey, "claude@extra": teamKey], [], [], [.ambiguousPeerIdentity]),
            ("orgless local account with multiple peer organizations",
             [document(["claude": teamKey]), document(["claude": maxKey])], ["claude": "uuid-me"],
             [], [], [.ambiguousLocalIdentity, .ambiguousLocalIdentity]),
            ("duplicate peer aliases", [document(["claude": "uuid-me", "claude@extra": teamKey])],
             ["claude": teamKey], [], [], [.ambiguousPeerIdentity, .ambiguousPeerIdentity]),
            ("remote-only aliases across devices",
             [document(["claude": "uuid-other"]), document(["claude": "uuid-other|org-work"])],
             ["claude": maxKey], [], ["uuid-other|org-work"], [])
        ]
        for entry in cases {
            let remapped = PeerHistoryRemapper.remap(documents: entry.documents, localIdentityByCardID: entry.local)
            XCTAssertEqual(remapped.histories.map(\.cardID), entry.merged, entry.name)
            XCTAssertEqual(remapped.remoteOnly.map(\.identityKey), entry.remote, entry.name)
            XCTAssertEqual(remapped.quarantined.map(\.reason), entry.reasons, entry.name)
            if !entry.remote.isEmpty {
                XCTAssertEqual(remapped.remoteOnly.first?.histories.count, 2, entry.name)
            }
        }
    }

    func testLocalDocumentPublishesAccountCardsWithIdentities() {
        // Preload the cache; the store's init adopts cached snapshots as its local set. The entries
        // carry the same account stamp the store is launched with, or the swap guard discards them.
        let cache = scratchCache()
        cache.store(
            snapshot(providerID: "claude", history: history(day: "2026-07-16", tokens: 10, cost: 1)),
            producedByIdentityKey: maxKey
        )
        cache.store(
            snapshot(providerID: "claude@f15456b0", history: history(day: "2026-07-16", tokens: 20, cost: 2)),
            producedByIdentityKey: teamKey
        )
        let dataStore = makeDataStore("PublishDoc", cache: cache)

        let document = dataStore.localHistoryDocument(deviceID: "dev", deviceName: "This Mac")
        XCTAssertEqual(document.schema, UsageHistoryDocument.currentSchema)
        XCTAssertNotNil(document.providers["claude@f15456b0"], "account cards sync now")
        XCTAssertEqual(document.identities?["claude"], maxKey)
        XCTAssertEqual(document.identities?["claude@f15456b0"], teamKey)
        XCTAssertNoThrow(try document.validate())
    }

    func testRemoteOnlyAccountFeedsTotalSpend() {
        let dataStore = makeDataStore("RemoteTotal")
        let today = dayKey(Date())
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: [
                "claude@ab12cd34": history(day: today, tokens: 1_000_000, cost: 42),
                "claude@22222222": history(day: today, tokens: 20, cost: 2)
            ],
            identities: ["claude@ab12cd34": "uuid-other|org-x", "claude@22222222": "uuid-second|org-y"]
        )
        dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")

        XCTAssertEqual(dataStore.remoteOnlySpend.count, 2)
        let names = Set(dataStore.remoteOnlySpend.map(\.provider.displayName))
        XCTAssertEqual(names.count, 2, "each remote account retains its own identity-derived name")
        let expectedCardID = ProviderAccountID.make(family: "claude", identityKey: "uuid-other|org-x")
        XCTAssertTrue(names.contains(expectedCardID))

        let total = TotalSpendAggregator.total(
            for: .today,
            providers: dataStore.remoteOnlySpend.map(\.provider),
            snapshots: Dictionary(uniqueKeysWithValues: dataStore.remoteOnlySpend.map {
                ($0.provider.id, $0.snapshot)
            })
        )
        XCTAssertEqual(total.slices.count, 2)
        XCTAssertEqual(total.slices.map(\.amountUSD).sorted(), [2, 42])

        dataStore.clearPeerHistoryDocuments()
        XCTAssertTrue(dataStore.remoteOnlySpend.isEmpty, "sync off returns Total Spend to local-only")
    }

    func testRemoteOnlySpendFollowsAnyEnabledFamilyCard() {
        let doc = makeDocument(
            providers: ["claude@ab12cd34": history(day: dayKey(Date()), tokens: 10, cost: 1)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )
        let cases: [(name: String, includeDefault: Bool, identities: [String: String]?,
                     enabled: @MainActor (String) -> Bool, expected: Int)] = [
            ("entire family disabled", true, nil, { _ in false }, 0),
            ("missing bare card", false, ["claude@f15456b0": teamKey], { _ in true }, 1),
            ("bare card disabled but sibling enabled", true, nil, { $0 != "claude" }, 1)
        ]
        for entry in cases {
            let dataStore = makeDataStore(
                entry.name, includeDefault: entry.includeDefault, identities: entry.identities,
                isEnabled: entry.enabled
            )
            dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")
            XCTAssertEqual(dataStore.remoteOnlySpend.count, entry.expected, entry.name)
            if entry.expected > 0 {
                XCTAssertEqual(dataStore.remoteOnlySpend.first?.provider.icon, .providerMark("claude"), entry.name)
            }
        }
    }

    func testUnresolvedLocalAccountHistoryIsNotPublished() {
        let cache = scratchCache()
        cache.store(snapshot(
            providerID: "claude",
            history: history(day: "2026-07-16", tokens: 10, cost: 1)
        ))
        let dataStore = makeDataStore("UnresolvedPublish", cache: cache, identities: [:])

        let document = dataStore.localHistoryDocument(deviceID: "dev", deviceName: "This Mac")

        XCTAssertNil(document.providers["claude"])
        XCTAssertNil(document.identities)
    }

    // MARK: - Fixtures

    private func makeDataStore(
        _ name: String,
        cache: ProviderSnapshotCache? = nil,
        includeDefault: Bool = true,
        identities: [String: String]? = nil,
        isEnabled: @escaping @MainActor (String) -> Bool = { _ in true }
    ) -> WidgetDataStore {
        WidgetDataStore(
            registry: makeRegistry(includeDefault: includeDefault),
            providers: [],
            cache: cache ?? scratchCache(),
            defaults: makeScratchDefaults(name),
            isProviderEnabled: isEnabled,
            providerIdentityKeys: identities ?? ["claude": maxKey, "claude@f15456b0": teamKey]
        )
    }

    private func makeRegistry(includeDefault: Bool = true) -> WidgetRegistry {
        let claude = ClaudeProvider.makeProvider()
        let extraCard = ClaudeProvider.makeProvider(id: "claude@f15456b0", displayName: "Claude — Team")
        let providers = includeDefault ? [claude, extraCard] : [extraCard]
        let descriptors = providers.map {
            WidgetDescriptor.usageTrend(provider: $0)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test")
        }
        return WidgetRegistry(providers: providers, descriptors: descriptors)
    }

    private func scratchCache() -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: makeScratchDefaults("Cache"), storageKey: "snapshots", ttl: 600)
    }

    private func makeScratchDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.PeerIdentity.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeDocument(
        deviceName: String = "Peer",
        providers: [String: ProviderUsageHistory],
        identities: [String: String]?
    ) -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: UUID().uuidString,
            deviceName: deviceName,
            updatedAt: Date(),
            providers: providers,
            identities: identities
        )
    }

    private func history(day: String, tokens: Int, cost: Double) -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: [DailyUsageEntry(date: day, totalTokens: tokens, costUSD: cost)]),
            modelUsage: nil,
            unknownModelsByDay: [:]
        )
    }

    private func snapshot(providerID: String, history: ProviderUsageHistory) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(
            providerID: providerID,
            displayName: providerID,
            lines: [],
            refreshedAt: Date()
        )
        snapshot.usageHistory = history
        return snapshot
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
