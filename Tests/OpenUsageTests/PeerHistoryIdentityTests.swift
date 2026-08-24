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

        let remapped = PeerHistoryRemapper.remap(
            documents: [miniDoc], localIdentityByCardID: localMap, localAccountCardIDs: Set(localMap.keys)
        )

        XCTAssertTrue(remapped.remoteOnly.isEmpty)
        let byCard = Dictionary(grouping: remapped.histories, by: { $0.cardID })
        XCTAssertEqual(byCard["claude"]?.first?.history.series.daily.first?.costUSD, 494.27, "mini's Max spend belongs to this Mac's default (Max) card")
        XCTAssertEqual(byCard["claude@f15456b0"]?.first?.history.series.daily.first?.costUSD, 502.34, "mini's Team spend belongs to this Mac's Team card")
    }

    func testRemapCollectsRemoteOnlyAccounts() {
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude@ab12cd34": history(day: "2026-07-16", tokens: 50, cost: 42)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )
        let remapped = PeerHistoryRemapper.remap(
            documents: [doc],
            localIdentityByCardID: ["claude": maxKey], localAccountCardIDs: ["claude"]
        )
        XCTAssertTrue(remapped.histories.isEmpty)
        XCTAssertEqual(remapped.remoteOnly.count, 1)
        XCTAssertEqual(remapped.remoteOnly.first?.family, "claude")
        XCTAssertEqual(remapped.remoteOnly.first?.deviceNamesByID.values.first, "Mac mini")
        XCTAssertEqual(remapped.remoteOnly.first?.cardID,
                       ProviderAccountID.make(family: "claude", identityKey: "uuid-other|org-x"))
    }

    func testRemapKeepsOnlyTheNewestVerifiedHistoryFromEachDevice() {
        let previous = makeDocument(
            deviceID: "same-mac", updatedAt: Date(timeIntervalSince1970: 100),
            providers: ["claude": history(day: "2026-07-16", tokens: 900, cost: 90)],
            identities: ["claude": maxKey]
        )
        let current = makeDocument(
            deviceID: "same-mac", updatedAt: Date(timeIntervalSince1970: 200),
            providers: ["claude": history(day: "2026-07-16", tokens: 20, cost: 2)],
            identities: ["claude": maxKey]
        )

        let remapped = PeerHistoryRemapper.remap(
            documents: [previous, current], localIdentityByCardID: ["claude": maxKey],
            localAccountCardIDs: ["claude"]
        )

        XCTAssertEqual(remapped.histories.count, 1)
        XCTAssertEqual(remapped.histories.first?.history.series.daily.first?.totalTokens, 20)
    }

    func testRemapLegacyAccountHistoryWithoutIdentityIsQuarantined() {
        let v1 = UsageHistoryDocument(
            schema: UsageHistoryDocument.legacySchemaV1,
            deviceID: "d", deviceName: "old Mac", updatedAt: Date(),
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: nil
        )
        let remapped = PeerHistoryRemapper.remap(
            documents: [v1],
            localIdentityByCardID: ["claude": maxKey], localAccountCardIDs: ["claude"]
        )
        XCTAssertTrue(remapped.histories.isEmpty)
        XCTAssertEqual(remapped.quarantined.first?.reason, .missingPeerIdentity)
        XCTAssertTrue(remapped.remoteOnly.isEmpty)
    }

    func testDifferentProviderFamiliesCannotShareAnIdentity() {
        let document = makeDocument(
            providers: ["codex": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: ["codex": maxKey]
        )
        let result = PeerHistoryRemapper.remap(
            documents: [document],
            localIdentityByCardID: ["claude": maxKey],
            localAccountCardIDs: ["claude", "codex"]
        )
        XCTAssertTrue(result.histories.isEmpty)
        XCTAssertEqual(result.quarantined.first?.reason, .unresolvedLocalIdentity)
    }

    func testAmbiguousLocalAndPeerOwnershipAreQuarantined() {
        let document = makeDocument(
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: ["claude": maxKey]
        )
        let local = PeerHistoryRemapper.remap(
            documents: [document],
            localIdentityByCardID: ["claude": maxKey, "claude@12345678": maxKey],
            localAccountCardIDs: ["claude", "claude@12345678"]
        )
        XCTAssertEqual(local.quarantined.first?.reason, .ambiguousLocalIdentity)

        let duplicate = makeDocument(
            providers: [
                "claude": history(day: "2026-07-16", tokens: 10, cost: 1),
                "claude@12345678": history(day: "2026-07-16", tokens: 20, cost: 2),
            ],
            identities: ["claude": maxKey, "claude@12345678": maxKey]
        )
        let peer = PeerHistoryRemapper.remap(
            documents: [duplicate], localIdentityByCardID: ["claude": maxKey],
            localAccountCardIDs: ["claude"]
        )
        XCTAssertEqual(peer.quarantined.map(\.reason), [.ambiguousPeerIdentity, .ambiguousPeerIdentity])
    }

    func testMixedCaseIdentitiesResolveToTheSameAccountAcrossMacs() {
        let document = makeDocument(
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: ["claude": maxKey.uppercased()]
        )

        let remapped = PeerHistoryRemapper.remap(
            documents: [document], localIdentityByCardID: ["claude": maxKey],
            localAccountCardIDs: ["claude"]
        )

        XCTAssertEqual(remapped.histories.map(\.cardID), ["claude"])
        XCTAssertTrue(remapped.remoteOnly.isEmpty)
    }

    func testOrganizationlessIdentityFollowsItsOnlyVerifiedOrganization() {
        let document = makeDocument(
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: ["claude": "uuid-me"]
        )
        let remapped = PeerHistoryRemapper.remap(
            documents: [document], localIdentityByCardID: ["claude": teamKey],
            localAccountCardIDs: ["claude"],
            knownAccountIdentitiesByFamily: ["claude": ["uuid-me", teamKey]]
        )

        XCTAssertEqual(remapped.histories.map(\.cardID), ["claude"])
        XCTAssertTrue(remapped.remoteOnly.isEmpty)
    }

    func testOrganizationlessIdentityIsQuarantinedWhenMultipleOrganizationsExist() {
        let document = makeDocument(
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: ["claude": "uuid-me"]
        )
        let remapped = PeerHistoryRemapper.remap(
            documents: [document], localIdentityByCardID: ["claude": teamKey],
            localAccountCardIDs: ["claude"],
            knownAccountIdentitiesByFamily: ["claude": [teamKey, maxKey]]
        )

        XCTAssertEqual(remapped.quarantined.map(\.reason), [.ambiguousPeerIdentity])
        XCTAssertTrue(remapped.histories.isEmpty)
    }

    func testCodexExportsOnlyVerifiedHistoryWithoutCrossAccountCarryForward() async {
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.usageTrend(provider: codex)
            .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test")
        let knownHistory = history(day: "2026-07-16", tokens: 10, cost: 1)
        let cases: [(previous: String?, current: String?, fresh: Bool, exports: Bool)] = [
            (nil, "account-b", true, true),
            ("account-a", "account-b", false, false),
            ("account-a", nil, false, false),
            ("account-a", "account-b", true, false),
        ]
        for scenario in cases {
            let cache = scratchCache()
            if let previous = scenario.previous {
                cache.store(snapshot(providerID: "codex", history: knownHistory), producedByIdentityKey: previous)
            }
            let next = scenario.fresh
                ? snapshot(providerID: "codex", history: knownHistory)
                : ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: [])
            let runtime = AccountReportingRuntime(provider: codex, snapshot: next, identity: scenario.current)
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [codex], descriptors: [descriptor]),
                providers: [runtime], cache: cache, defaults: makeScratchDefaults("CodexOwnership"),
                providerIdentityKeys: scenario.previous.map { ["codex": $0] } ?? [:],
                knownAccountIdentitiesByFamily: scenario.previous.map { ["codex": Set([$0])] } ?? [:]
            )
            _ = await store.refresh(providerID: "codex", force: true)
            let document = store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
            XCTAssertEqual(document.providers["codex"] != nil, scenario.exports)
            XCTAssertEqual(document.identities?["codex"], scenario.exports ? scenario.current : nil)
            if !scenario.fresh { XCTAssertNil(store.snapshots["codex"]?.usageHistory) }
        }
    }

    func testKeychainCodexAccountSwitchStaysQuarantinedAcrossColdRelaunches() async {
        let defaults = makeScratchDefaults("CodexColdAccountSwitch")
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.usageTrend(provider: codex)
            .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test")
        let rollout = history(day: "2026-07-16", tokens: 10, cost: 1)

        for (identity, shouldExport) in [("account-a", true), ("account-b", false), ("account-b", false)] {
            let runtime = AccountReportingRuntime(
                provider: codex, snapshot: snapshot(providerID: "codex", history: rollout), identity: identity
            )
            let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "cold-codex", ttl: 600)
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [codex], descriptors: [descriptor]),
                providers: [runtime], cache: cache, defaults: defaults
            )

            _ = await store.refresh(providerID: "codex", force: true)
            let document = store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
            XCTAssertEqual(document.providers["codex"] != nil, shouldExport)
        }
    }

    func testVerifiedCodexCacheSurvivesInitialCloudWriteBeforeRefresh() {
        let defaults = makeScratchDefaults("CodexColdCloudWrite")
        let provider = CodexProvider(expectedIdentityKey: "account-a")
        let descriptor = WidgetDescriptor.usageTrend(provider: provider.provider)
            .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "cold-codex", ttl: 600)
        cache.store(
            snapshot(providerID: "codex", history: history(day: "2026-07-16", tokens: 10, cost: 1)),
            producedByIdentityKey: "account-a"
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider.provider], descriptors: [descriptor]),
            providers: [provider], cache: cache, defaults: defaults,
            providerIdentityKeys: ["codex": "account-a"]
        )

        let document = store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")

        XCTAssertNotNil(document.providers["codex"])
        XCTAssertEqual(document.identities?["codex"], "account-a")
    }

    func testUnsafeCodexRefreshKeepsLocalHistoryButNeverReplacesTheVerifiedCache() async {
        let defaults = makeScratchDefaults("CodexUnsafeLocalHistory")
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.usageTrend(provider: codex)
            .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test")
        let verifiedHistory = history(day: "2026-07-16", tokens: 10, cost: 1)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "codex-unsafe", ttl: 600)
        cache.store(snapshot(providerID: "codex", history: verifiedHistory), producedByIdentityKey: "account-a")

        let unsafe = AccountReportingRuntime(
            provider: codex,
            snapshot: ProviderSnapshot(providerID: "codex", displayName: "Updated Codex", lines: []),
            identity: "account-a",
            historySafeToExport: false
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [codex], descriptors: [descriptor]),
            providers: [unsafe], cache: cache, defaults: defaults,
            providerIdentityKeys: ["codex": "account-a"]
        )

        _ = await store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(store.snapshots["codex"]?.usageHistory, verifiedHistory)
        XCTAssertNil(store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac").providers["codex"])

        let coldCache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "codex-unsafe", ttl: 600)
        XCTAssertEqual(coldCache.loadSnapshots(providerIDs: ["codex"])["codex"]?.displayName, "codex")
        let coldProvider = CodexProvider(expectedIdentityKey: "account-a")
        let coldStore = WidgetDataStore(
            registry: WidgetRegistry(providers: [coldProvider.provider], descriptors: [descriptor]),
            providers: [coldProvider], cache: coldCache, defaults: defaults,
            providerIdentityKeys: ["codex": "account-a"]
        )

        XCTAssertEqual(coldStore.snapshots["codex"]?.usageHistory, verifiedHistory)
        XCTAssertEqual(
            coldStore.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac").providers["codex"],
            verifiedHistory
        )
    }

    func testLocalDocumentPublishesAccountCardsWithIdentities() {
        let registry = makeRegistry()
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
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: cache,
            defaults: makeScratchDefaults("PublishDoc"),
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )

        let document = dataStore.localHistoryDocument(deviceID: "dev", deviceName: "This Mac")
        XCTAssertEqual(document.schema, UsageHistoryDocument.currentSchema)
        XCTAssertNotNil(document.providers["claude@f15456b0"], "account cards sync now")
        XCTAssertEqual(document.identities?["claude"], maxKey)
        XCTAssertEqual(document.identities?["claude@f15456b0"], teamKey)
        XCTAssertNoThrow(try document.validate())
    }

    func testCodexAndClaudeHistoriesSyncForTheirVerifiedAccounts() throws {
        let existing = makeRegistry()
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let codexDescriptor = WidgetDescriptor.usageTrend(provider: codex)
            .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test")
        let registry = WidgetRegistry(
            providers: existing.providers + [codex],
            descriptors: existing.descriptors + [codexDescriptor]
        )
        let cache = scratchCache()
        let today = dayKey(Date())
        let localCodex = history(day: today, tokens: 20, cost: 2)
        let codexSnapshot = UsageHistorySnapshotRenderer.render(
            local: snapshot(providerID: "codex", history: localCodex),
            history: localCodex,
            descriptor: try XCTUnwrap(registry.historyDescriptorsByProvider["codex"]),
            combined: false
        )
        cache.store(
            snapshot(providerID: "claude", history: history(day: today, tokens: 10, cost: 1)),
            producedByIdentityKey: maxKey
        )
        cache.store(codexSnapshot, producedByIdentityKey: "codex-local")
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: cache,
            defaults: makeScratchDefaults("CodexDeviceLocal"),
            providerIdentityKeys: ["claude": maxKey, "codex": "codex-local"]
        )

        let outgoing = dataStore.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
        XCTAssertEqual(Set(outgoing.providers.keys), ["claude", "codex"])
        XCTAssertEqual(outgoing.identities, ["claude": maxKey, "codex": "codex-local"])
        XCTAssertNoThrow(try outgoing.validate())

        let incoming = makeDocument(
            providers: [
                "claude": history(day: today, tokens: 100, cost: 10),
                "codex": history(day: today, tokens: 900, cost: 90),
            ],
            identities: ["claude": maxKey, "codex": "codex-local"]
        )
        dataStore.setPeerHistoryDocuments([incoming], ownDeviceID: "this-mac")

        XCTAssertNotEqual(dataStore.snapshots["codex"], codexSnapshot)
        XCTAssertNotNil(dataStore.snapshots["codex"]?.line(label: "Today"))
        XCTAssertNotNil(dataStore.snapshots["claude"]?.line(label: "Today"))
        XCTAssertTrue(dataStore.remoteOnlySpend.isEmpty)
    }

    func testRemoteOnlyAccountFeedsTotalSpend() {
        let registry = makeRegistry()
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("RemoteTotal"),
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )
        let today = dayKey(Date())
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude@ab12cd34": history(day: today, tokens: 1_000_000, cost: 42)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )
        dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")

        XCTAssertEqual(dataStore.remoteOnlySpend.count, 1)
        let entry = dataStore.remoteOnlySpend[0]
        XCTAssertEqual(entry.provider.displayName, "Claude · Mac mini")

        let total = TotalSpendAggregator.total(
            for: .today,
            providers: [entry.provider],
            snapshots: [entry.provider.id: entry.snapshot]
        )
        XCTAssertEqual(total.slices.count, 1)
        XCTAssertEqual(total.slices[0].amountUSD, 42, accuracy: 0.001)
    }

    func testRemoteOnlyAccountAppearsWhenThisMacHasNoLocalLogin() {
        let provider = ClaudeProvider.makeProvider()
        let descriptor = WidgetDescriptor.usageTrend(provider: provider)
            .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test")
        let dataStore = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [], cache: scratchCache(), defaults: makeScratchDefaults("NoLocalAccount"),
            providerIdentityKeys: [:]
        )
        let document = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude": history(day: dayKey(Date()), tokens: 100, cost: 4)],
            identities: ["claude": "remote-account"]
        )

        dataStore.setPeerHistoryDocuments([document], ownDeviceID: "this-mac")

        XCTAssertEqual(dataStore.remoteOnlySpend.count, 1)
        XCTAssertEqual(dataStore.remoteOnlySpend.first?.provider.displayName, "Claude · Mac mini")
    }

    func testClearingPeersDropsRemoteOnlyEntries() {
        let dataStore = WidgetDataStore(
            registry: makeRegistry(),
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("ClearPeers"),
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude@ab12cd34": history(day: dayKey(Date()), tokens: 10, cost: 1)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )
        dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")
        XCTAssertEqual(dataStore.remoteOnlySpend.count, 1)

        dataStore.clearPeerHistoryDocuments()
        XCTAssertTrue(dataStore.remoteOnlySpend.isEmpty, "sync off returns Total Spend to local-only")
    }

    func testOneRemoteAccountAcrossMultipleMacsHasOneStableLabel() {
        let dataStore = WidgetDataStore(
            registry: makeRegistry(), providers: [], cache: scratchCache(),
            defaults: makeScratchDefaults("MultipleMacs"),
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )
        let today = dayKey(Date())
        let mini = makeDocument(
            deviceName: "Mac mini", providers: ["claude": history(day: today, tokens: 10, cost: 1)],
            identities: ["claude": "remote-account"]
        )
        let laptop = makeDocument(
            deviceName: "Mac mini", providers: ["claude": history(day: today, tokens: 20, cost: 2)],
            identities: ["claude": "remote-account"]
        )

        dataStore.setPeerHistoryDocuments([mini, laptop], ownDeviceID: "this-mac")
        XCTAssertEqual(dataStore.remoteOnlySpend.map(\.provider.displayName), ["Claude · 2 Macs"])

        dataStore.setPeerHistoryDocuments([laptop, mini], ownDeviceID: "this-mac")
        XCTAssertEqual(dataStore.remoteOnlySpend.map(\.provider.displayName), ["Claude · 2 Macs"])
    }

    func testMultipleRemoteAccountsOnTheSameMacHaveDistinctLabels() {
        let dataStore = WidgetDataStore(
            registry: makeRegistry(), providers: [], cache: scratchCache(),
            defaults: makeScratchDefaults("SameMac"),
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )
        let today = dayKey(Date())
        let document = makeDocument(
            deviceName: "Mac mini", providers: [
                "claude": history(day: today, tokens: 10, cost: 1),
                "claude@12345678": history(day: today, tokens: 20, cost: 2),
            ],
            identities: ["claude": "remote-a", "claude@12345678": "remote-b"]
        )

        dataStore.setPeerHistoryDocuments([document], ownDeviceID: "this-mac")

        XCTAssertEqual(
            Set(dataStore.remoteOnlySpend.map(\.provider.displayName)),
            [
                "Claude · Mac mini · \(ProviderAccountID.hash8("remote-a").prefix(4))",
                "Claude · Mac mini · \(ProviderAccountID.hash8("remote-b").prefix(4))",
            ]
        )
    }

    // MARK: - Fixtures

    private final class AccountReportingRuntime: ProviderRuntime, AccountIdentityReporting {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor] = []
        let snapshot: ProviderSnapshot
        let identity: String?
        let isAccountHistorySafeToExport: Bool
        private(set) var verifiedAccountIdentityKey: String?

        init(provider: Provider, snapshot: ProviderSnapshot, identity: String?, historySafeToExport: Bool = true) {
            self.provider = provider
            self.snapshot = snapshot
            self.identity = identity
            self.isAccountHistorySafeToExport = historySafeToExport
        }

        func refresh() async -> ProviderSnapshot {
            verifiedAccountIdentityKey = identity
            return snapshot
        }
    }

    private func makeRegistry() -> WidgetRegistry {
        let claude = ClaudeProvider.makeProvider()
        let extraCard = ClaudeProvider.makeProvider(id: "claude@f15456b0", displayName: "Claude — Team")
        let descriptors = [
            WidgetDescriptor.usageTrend(provider: claude)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test"),
            WidgetDescriptor.usageTrend(provider: extraCard)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test"),
        ]
        return WidgetRegistry(providers: [claude, extraCard], descriptors: descriptors)
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
        deviceID: String = UUID().uuidString,
        deviceName: String = "Peer",
        updatedAt: Date = Date(),
        providers: [String: ProviderUsageHistory],
        identities: [String: String]?
    ) -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: deviceID,
            deviceName: deviceName,
            updatedAt: updatedAt,
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
