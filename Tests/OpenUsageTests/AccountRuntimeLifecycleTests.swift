import XCTest
@testable import OpenUsage

@MainActor
final class AccountRuntimeLifecycleTests: XCTestCase {
    func testAccountFilesystemScansRunOffTheMainThread() async {
        let prepared = await AppContainer.prepareAccountDiscovery(
            configScan: { .init(notes: [Thread.isMainThread ? "main" : "background"]) },
            coworkScan: { .init(notes: [Thread.isMainThread ? "main" : "background"]) }
        )

        XCTAssertEqual(prepared.config.notes, ["background"])
        XCTAssertEqual(prepared.cowork.notes, ["background"])
        XCTAssertTrue(prepared.isComplete)
    }

    func testIncompletePreparedDiscoveryNeverMutatesPersistedAccountOwnership() {
        let suiteName = "OpenUsageTests.IncompleteAccountGraph.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accounts = ProviderAccountsStore(defaults: defaults)
        accounts.reconcile(with: [.init(
            family: "claude", identityKey: "original", label: "Original",
            sources: [.init(kind: .defaultHome, anchor: "/Users/dev/.claude", holdsDefaultSource: true)]
        )])
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(), files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount":{"accountUuid":"replacement"}}"#,
            ]), keychain: FakeKeychain(), homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: accounts,
            preparedDiscovery: .init(config: .init(truncated: true), cowork: .init())
        )

        XCTAssertEqual(accounts.defaultBadgeHolder(family: "claude")?.identityKey, "original")
        XCTAssertFalse(assembly.isClaudeDiscoveryComplete)
        XCTAssertEqual(assembly.defaultClaudeDesktopAccess, .denied)
    }

    func testSessionRootChangesUpdateRoutingWithoutReplacingAccountOwnership() {
        let account = ClaudeAccountCard(
            id: "claude@team", displayName: "Team", identityKey: "person|team",
            credential: .desktop(organization: "team"),
            logRoots: [URL(fileURLWithPath: "/tmp/session-one")]
        )
        let first = ProviderAccountAssembly(
            identityKeysByCard: [account.id: account.identityKey], claudeCards: [account],
            defaultClaudeExtraLogRoots: [URL(fileURLWithPath: "/tmp/default-config")],
            defaultClaudeCoworkRoots: [URL(fileURLWithPath: "/tmp/default-cowork")]
        )
        var updatedCard = first
        updatedCard.claudeCards[0].logRoots.append(URL(fileURLWithPath: "/tmp/session-two"))
        var updatedConfig = first
        updatedConfig.defaultClaudeExtraLogRoots.append(URL(fileURLWithPath: "/tmp/another-config"))
        var updatedCowork = first
        updatedCowork.defaultClaudeCoworkRoots?.append(URL(fileURLWithPath: "/tmp/another-cowork"))
        let ownership = AppContainer.AccountOwnershipFingerprint(first)
        let routing = AppContainer.AccountLogRoutingFingerprint(first)

        for update in [updatedCard, updatedConfig, updatedCowork] {
            XCTAssertEqual(ownership, .init(update))
            XCTAssertNotEqual(routing, .init(update))
            XCTAssertFalse(AppContainer.AccountLogRoutingFingerprint(update).reassignsExistingRoots(from: routing))
        }

        var changedOwner = first
        changedOwner.claudeCards[0].logRoots.append(URL(fileURLWithPath: "/tmp/default-cowork"))
        changedOwner.defaultClaudeCoworkRoots = []
        XCTAssertTrue(AppContainer.AccountLogRoutingFingerprint(changedOwner).reassignsExistingRoots(from: routing))
    }

    func testCancellationAfterConfigScanNeverRunsCoworkDiscovery() async {
        let prepared = await AppContainer.prepareAccountDiscovery(
            configScan: {
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(notes: ["config scanned"])
            },
            coworkScan: { .init(notes: ["must not run"]) }
        )

        XCTAssertEqual(prepared.config.notes, ["config scanned"])
        XCTAssertTrue(prepared.cowork.truncated)
    }

    func testRetiredRefreshNeverOverwritesReplacementSnapshot() async {
        let suiteName = "OpenUsageTests.RetiredAccountRuntime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let oldSnapshot = ProviderSnapshot(providerID: provider.id, displayName: "Old Account", lines: [])
        let newSnapshot = ProviderSnapshot(providerID: provider.id, displayName: "New Account", lines: [])
        let oldRuntime = DeferredSnapshotRuntime(provider: provider, snapshot: oldSnapshot)
        let registry = WidgetRegistry(providers: [provider], descriptors: [])
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "handoff")
        let oldStore = WidgetDataStore(registry: registry, providers: [oldRuntime], cache: cache, defaults: defaults)
        let oldRefresh = Task { await oldStore.refresh(providerID: provider.id, force: true) }
        while !oldRuntime.isWaiting { await Task.yield() }

        oldStore.retireForAccountGraphReload()
        let replacementRuntime = TestProviderRuntime(provider: provider, descriptors: [], snapshot: newSnapshot)
        let replacementStore = WidgetDataStore(
            registry: registry, providers: [replacementRuntime], cache: cache, defaults: defaults
        )
        let replacementOutcome = await replacementStore.refresh(providerID: provider.id, force: true)
        oldRuntime.complete()
        let retiredOutcome = await oldRefresh.value

        XCTAssertEqual(replacementOutcome, .refreshed)
        XCTAssertEqual(retiredOutcome, .skipped)
        let persisted = ProviderSnapshotCache(userDefaults: defaults, storageKey: "handoff")
        XCTAssertEqual(persisted.loadSnapshots(providerIDs: [provider.id])[provider.id]?.displayName, "New Account")
    }

    func testCancellingRefreshBatchCancelsOutstandingProviderWork() async {
        let suiteName = "OpenUsageTests.CancelledAccountRuntime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let runtime = HangingProviderRuntime(provider: provider, descriptors: [])
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: []),
            providers: [runtime], cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults
        )
        let refresh = Task { await store.refreshAll(force: true) }
        while store.refreshingProviderIDs.isEmpty { await Task.yield() }

        store.retireForAccountGraphReload()
        refresh.cancel()
        await refresh.value

        XCTAssertTrue(runtime.wasCancelled)
        XCTAssertNil(store.lastRefreshAt)
        let retiredOutcome = await store.refresh(providerID: provider.id, force: true)
        XCTAssertEqual(retiredOutcome, .skipped)
    }
}

@MainActor
private final class DeferredSnapshotRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let snapshot: ProviderSnapshot
    private var continuation: CheckedContinuation<ProviderSnapshot, Never>?

    var isWaiting: Bool { continuation != nil }

    init(provider: Provider, snapshot: ProviderSnapshot) {
        self.provider = provider
        self.snapshot = snapshot
    }

    func refresh() async -> ProviderSnapshot {
        await withCheckedContinuation { continuation = $0 }
    }

    func complete() {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}
