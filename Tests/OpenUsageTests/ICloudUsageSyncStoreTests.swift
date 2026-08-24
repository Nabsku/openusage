import XCTest
@testable import OpenUsage

@MainActor
final class ICloudUsageSyncStoreTests: XCTestCase {
    func testEnableWritesLoadsAndDisableDeletesThisMac() async throws {
        let defaults = makeDefaults("enable-disable")
        let fileStore = RecordingHistoryFileStore()
        let sync = makeSync(defaults, fileStore: fileStore, writeDebounce: .milliseconds(10))

        sync.enabled = true
        try await waitUntil { await fileStore.writeCount == 1 && sync.displayedDocuments.count == 1 }

        XCTAssertEqual(sync.displayedDocuments.first?.deviceID, sync.deviceID)
        XCTAssertNil(sync.serviceError)

        sync.enabled = false
        try await waitUntil { await fileStore.deletedDeviceIDs.contains(sync.deviceID) }
        XCTAssertTrue(sync.documents.isEmpty)
    }

    func testAdjacentHistoryChangesDebounceToOneWrite() async throws {
        let defaults = makeDefaults("debounce")
        let fileStore = RecordingHistoryFileStore()
        let sync = makeSync(defaults, fileStore: fileStore, writeDebounce: .milliseconds(20))
        sync.enabled = true
        try await waitUntil { await fileStore.writeCount == 1 }

        sync.scheduleWrite()
        sync.scheduleWrite()
        sync.scheduleWrite()
        try await waitUntil { await fileStore.writeCount == 2 }
        try await Task.sleep(for: .milliseconds(40))

        let writeCount = await fileStore.writeCount
        XCTAssertEqual(writeCount, 2)
    }

    func testAccountGraphShutdownCancelsDebouncedWriteWithoutDisablingOrDeleting() async throws {
        let defaults = makeDefaults("account-graph-shutdown-debounce")
        let fileStore = RecordingHistoryFileStore()
        let sync = makeSync(defaults, fileStore: fileStore, writeDebounce: .milliseconds(30))
        sync.enabled = true
        try await waitUntil { await fileStore.writeCount == 1 && !sync.isSyncing }

        sync.scheduleWrite()
        sync.shutdownForAccountGraphReload()
        sync.scheduleWrite()
        try await Task.sleep(for: .milliseconds(80))

        let writeCount = await fileStore.writeCount
        let documents = await fileStore.documents
        let deletedDeviceIDs = await fileStore.deletedDeviceIDs
        XCTAssertEqual(writeCount, 1, "the retired graph cannot publish a queued or newly scheduled write")
        XCTAssertEqual(documents.map(\.deviceID), [sync.deviceID], "graph reload keeps this Mac's existing file")
        XCTAssertTrue(deletedDeviceIDs.isEmpty, "graph reload is not the same as opting out of iCloud")
        XCTAssertTrue(sync.enabled)
        XCTAssertTrue(defaults.bool(forKey: "openusage.icloudSync.enabled.v1"))
    }

    func testAccountGraphShutdownCancelsInFlightWriteWithoutReplacingExistingFile() async throws {
        let defaults = makeDefaults("account-graph-shutdown-in-flight")
        let deviceIDStore = MemoryDeviceIDStore()
        let expectedDeviceID = UUID().uuidString.lowercased()
        try deviceIDStore.writeDeviceID(expectedDeviceID)
        let existingDocument = UsageHistoryDocument(
            deviceID: expectedDeviceID,
            deviceName: "Previous Account Graph",
            updatedAt: Date(timeIntervalSince1970: 123),
            providers: [:]
        )
        let fileStore = RecordingHistoryFileStore(seedDocuments: [existingDocument])
        let sync = makeSync(defaults, fileStore: fileStore, deviceIDStore: deviceIDStore)

        await fileStore.holdNextWrite()
        sync.enabled = true
        try await waitUntil { await fileStore.writeInFlight }

        sync.shutdownForAccountGraphReload()
        await fileStore.releaseWrite()
        try await waitUntil { !(await fileStore.writeInFlight) && !sync.isSyncing }

        let documents = await fileStore.documents
        let deletedDeviceIDs = await fileStore.deletedDeviceIDs
        XCTAssertEqual(documents, [existingDocument], "a canceled stale graph must not replace the current device file")
        XCTAssertTrue(deletedDeviceIDs.isEmpty, "only the replacement graph owns subsequent writes")
        XCTAssertTrue(sync.enabled)
        XCTAssertNil(sync.serviceError, "cancellation is an intentional shutdown, not an iCloud failure")
    }

    func testRapidEnableChangesCannotLeaveAnOrphanedWriterAfterShutdown() async throws {
        let defaults = makeDefaults("orphaned-activation")
        let deviceIDStore = MemoryDeviceIDStore()
        let deviceID = UUID().uuidString.lowercased()
        try deviceIDStore.writeDeviceID(deviceID)
        let currentDocument = UsageHistoryDocument(
            deviceID: deviceID, deviceName: "Current Account", updatedAt: Date(), providers: [:]
        )
        let fileStore = RecordingHistoryFileStore(seedDocuments: [currentDocument])
        let sync = makeSync(defaults, fileStore: fileStore, deviceIDStore: deviceIDStore)

        await fileStore.holdNextWrite()
        sync.enabled = true
        try await waitUntil { await fileStore.writeInFlight }
        sync.enabled = false
        sync.enabled = true
        sync.shutdownForAccountGraphReload()
        await fileStore.releaseWrite()
        try await waitUntil { !(await fileStore.writeInFlight) && !sync.isSyncing }

        let documents = await fileStore.documents
        let deletedDeviceIDs = await fileStore.deletedDeviceIDs
        XCTAssertEqual(documents, [currentDocument])
        XCTAssertTrue(deletedDeviceIDs.isEmpty)
    }

    func testCanceledCoordinatedAccessorCannotOverwriteReplacementAccountDocument() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-sync-coordination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("device.json")
        let currentAccount = Data("replacement-account".utf8)
        try currentAccount.write(to: documentURL)

        let fileStore = ICloudUsageHistoryFileStore()
        let retiredWriter = Task.detached {
            try await fileStore.coordinatedWrite(
                Data("retired-account".utf8),
                to: documentURL,
                beforeWriting: {
                    withUnsafeCurrentTask { task in task?.cancel() }
                }
            )
        }

        do {
            try await retiredWriter.value
            XCTFail("a graph retired while waiting for file coordination must not commit")
        } catch is CancellationError {
            // Expected: cancellation is checked after the coordinated accessor begins.
        }
        XCTAssertEqual(try Data(contentsOf: documentURL), currentAccount)
    }

    func testDisableImmediatelyBeforeGraphReloadStillDeletesThisMac() async throws {
        let defaults = makeDefaults("disable-immediate-account-graph-reload")
        let fileStore = RecordingHistoryFileStore()
        let deviceIDStore = MemoryDeviceIDStore()
        let retired = makeSync(defaults, fileStore: fileStore, deviceIDStore: deviceIDStore)
        retired.enabled = true
        try await waitUntil { await fileStore.writeCount == 1 && !retired.isSyncing }

        retired.enabled = false
        retired.shutdownForAccountGraphReload()
        let replacement = makeSync(defaults, fileStore: fileStore, deviceIDStore: deviceIDStore)

        XCTAssertFalse(replacement.enabled)
        try await waitUntil { await fileStore.deletedDeviceIDs.contains(retired.deviceID) }
        let documents = await fileStore.documents
        XCTAssertFalse(documents.contains { $0.deviceID == retired.deviceID })
    }

    func testReenabledReplacementKeepsThisMacAfterInterruptedDisable() async throws {
        let defaults = makeDefaults("disable-reload-reenable")
        let fileStore = RecordingHistoryFileStore()
        let deviceIDStore = MemoryDeviceIDStore()
        let retired = makeSync(defaults, fileStore: fileStore, deviceIDStore: deviceIDStore)
        retired.enabled = true
        try await waitUntil { await fileStore.writeCount == 1 && !retired.isSyncing }

        await fileStore.holdNextDelete()
        retired.enabled = false
        retired.shutdownForAccountGraphReload()
        try await waitUntil { await fileStore.deleteIsHeld }
        let replacement = makeSync(defaults, fileStore: fileStore, deviceIDStore: deviceIDStore)
        replacement.enabled = true

        for _ in 0..<10 { await Task.yield() }
        let writesBeforeDeleteCompletes = await fileStore.writeCount
        XCTAssertEqual(writesBeforeDeleteCompletes, 1, "replacement waits for the retired graph's deletion")
        await fileStore.releaseDelete()
        try await waitUntil { await fileStore.writeCount == 2 && !replacement.isSyncing }
        let documents = await fileStore.documents
        XCTAssertEqual(documents.map(\.deviceID), [replacement.deviceID])
        XCTAssertTrue(replacement.enabled)
    }

    func testDisableDeletesWriteThatWasAlreadyInFlight() async throws {
        let defaults = makeDefaults("disable-in-flight-write")
        let fileStore = RecordingHistoryFileStore()
        let sync = makeSync(defaults, fileStore: fileStore)

        // Hold the enable write open so disable can race it deliberately, instead of hoping an
        // 80ms sleep is still in flight when the test flips the toggle on a loaded CI runner.
        await fileStore.holdNextWrite()
        sync.enabled = true
        try await waitUntil { await fileStore.writeInFlight }

        sync.enabled = false
        try await waitUntil {
            await fileStore.deletedDeviceIDs.contains(sync.deviceID)
        }

        await fileStore.releaseWrite()
        try await waitUntil {
            let writeInFlight = await fileStore.writeInFlight
            return !writeInFlight && !sync.isSyncing
        }

        let documents = await fileStore.documents
        XCTAssertFalse(documents.contains { $0.deviceID == sync.deviceID })
    }

    func testUnavailableStoreSurfacesFriendlyError() async throws {
        let defaults = makeDefaults("unavailable")
        let fileStore = RecordingHistoryFileStore(unavailable: true)
        let sync = makeSync(defaults, fileStore: fileStore)

        sync.enabled = true
        try await waitUntil { sync.serviceError != nil && !sync.isSyncing }

        XCTAssertEqual(sync.serviceError, ICloudUsageSyncError.unavailable.localizedDescription)
        XCTAssertFalse(sync.isSyncing)
    }

    func testMalformedPeerMessageIsVisibleAndValidDocumentsStillLoad() async throws {
        let defaults = makeDefaults("malformed")
        let peer = UsageHistoryDocument(
            deviceID: "peer",
            deviceName: "Peer Mac",
            updatedAt: .now,
            providers: [:]
        )
        let fileStore = RecordingHistoryFileStore(
            seedDocuments: [peer],
            invalidFileMessages: ["broken.json: invalid value"]
        )
        let sync = makeSync(defaults, fileStore: fileStore)

        sync.enabled = true
        try await waitUntil { sync.invalidFileMessages.count == 1 }

        XCTAssertTrue(sync.displayedDocuments.contains { $0.deviceID == "peer" })
        XCTAssertNotNil(sync.serviceError)
    }

    func testBackgroundReloadShowsSyncActivity() async throws {
        let defaults = makeDefaults("background-sync-activity")
        let fileStore = RecordingHistoryFileStore()
        let sync = makeSync(defaults, fileStore: fileStore, writeDebounce: .milliseconds(10))

        sync.enabled = true
        try await waitUntil {
            await fileStore.writeCount == 1 && !sync.isSyncing
        }

        // Gate only the post-write reload so isSyncing stays true long enough to observe.
        await fileStore.holdNextLoad()
        sync.scheduleWrite()
        try await waitUntil {
            let writeCount = await fileStore.writeCount
            let loadInFlight = await fileStore.loadInFlight
            return writeCount == 2 && loadInFlight && sync.isSyncing
        }

        await fileStore.releaseLoad()
        try await waitUntil { !sync.isSyncing }
    }

    func testDeviceIdentitySurvivesPreferencesResetThroughKeychainStore() {
        let expectedID = UUID().uuidString.lowercased()
        let firstDefaults = makeDefaults("identity-first")
        firstDefaults.set(expectedID, forKey: "openusage.icloudSync.deviceID.v1")
        let deviceIDStore = MemoryDeviceIDStore()

        let first = makeSync(firstDefaults, deviceIDStore: deviceIDStore)
        let resetDefaults = makeDefaults("identity-after-reset")
        let afterReset = makeSync(resetDefaults, deviceIDStore: deviceIDStore)

        XCTAssertEqual(first.deviceID, expectedID)
        XCTAssertEqual(afterReset.deviceID, expectedID)
        XCTAssertEqual(resetDefaults.string(forKey: "openusage.icloudSync.deviceID.v1"), expectedID)
    }

    func testKeychainIdentityIsScopedToDevelopmentAndProductionBundles() throws {
        let keychain = ServiceKeychain()
        let development = KeychainICloudDeviceIDStore(
            keychain: keychain,
            bundleIdentifier: "com.robinebers.openusage.dev"
        )
        let production = KeychainICloudDeviceIDStore(
            keychain: keychain,
            bundleIdentifier: "com.robinebers.openusage"
        )

        try development.writeDeviceID("development-id")
        try production.writeDeviceID("production-id")

        XCTAssertEqual(try development.readDeviceID(), "development-id")
        XCTAssertEqual(try production.readDeviceID(), "production-id")
    }

    private func makeSync(
        _ defaults: UserDefaults,
        fileStore: RecordingHistoryFileStore = RecordingHistoryFileStore(),
        deviceIDStore: MemoryDeviceIDStore = MemoryDeviceIDStore(),
        writeDebounce: Duration = .seconds(3)
    ) -> ICloudUsageSyncStore {
        ICloudUsageSyncStore(
            dataStore: WidgetDataStore(
                registry: WidgetRegistry(providers: [], descriptors: []),
                providers: [],
                cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
                defaults: defaults
            ),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: deviceIDStore,
            writeDebounce: writeDebounce,
            observesMetadataChanges: false
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "OpenUsageTests.ICloudSync.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }
}

private final class MemoryDeviceIDStore: ICloudDeviceIDStoring, @unchecked Sendable {
    private var deviceID: String?

    func readDeviceID() throws -> String? {
        deviceID
    }

    func writeDeviceID(_ deviceID: String) throws {
        self.deviceID = deviceID
    }
}

private actor RecordingHistoryFileStore: UsageHistoryFileStoring {
    private(set) var documents: [UsageHistoryDocument]
    private(set) var invalidFileMessages: [String]
    private(set) var writeCount = 0
    private(set) var deletedDeviceIDs: [String] = []
    private let unavailable: Bool
    private(set) var loadInFlight = false
    private(set) var writeInFlight = false
    private var shouldHoldNextLoad = false
    private var shouldHoldNextWrite = false
    private var shouldHoldNextDelete = false
    private var loadGate: CheckedContinuation<Void, Never>?
    private var writeGate: CheckedContinuation<Void, Never>?
    private var deleteGate: CheckedContinuation<Void, Never>?
    var deleteIsHeld: Bool { deleteGate != nil }

    init(
        unavailable: Bool = false,
        seedDocuments: [UsageHistoryDocument] = [],
        invalidFileMessages: [String] = []
    ) {
        self.unavailable = unavailable
        self.documents = seedDocuments
        self.invalidFileMessages = invalidFileMessages
    }

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        if unavailable { throw ICloudUsageSyncError.unavailable }
        loadInFlight = true
        defer { loadInFlight = false }
        if shouldHoldNextLoad {
            shouldHoldNextLoad = false
            await withCheckedContinuation { continuation in
                loadGate = continuation
            }
        }
        return UsageHistoryLoadResult(documents: documents, invalidFileMessages: invalidFileMessages)
    }

    func write(_ document: UsageHistoryDocument) async throws {
        if unavailable { throw ICloudUsageSyncError.unavailable }
        try Task.checkCancellation()
        writeCount += 1
        writeInFlight = true
        defer { writeInFlight = false }
        if shouldHoldNextWrite {
            shouldHoldNextWrite = false
            await withCheckedContinuation { continuation in
                writeGate = continuation
            }
        }
        try Task.checkCancellation()
        documents.removeAll { $0.deviceID == document.deviceID }
        documents.append(document)
    }

    func delete(deviceID: String) async throws {
        if unavailable { throw ICloudUsageSyncError.unavailable }
        if shouldHoldNextDelete {
            shouldHoldNextDelete = false
            await withCheckedContinuation { deleteGate = $0 }
        }
        deletedDeviceIDs.append(deviceID)
        documents.removeAll { $0.deviceID == deviceID }
    }

    func holdNextLoad() {
        shouldHoldNextLoad = true
    }

    func holdNextWrite() {
        shouldHoldNextWrite = true
    }

    func holdNextDelete() { shouldHoldNextDelete = true }
    func releaseDelete() { deleteGate?.resume(); deleteGate = nil }

    func releaseLoad() {
        loadGate?.resume()
        loadGate = nil
    }

    func releaseWrite() {
        writeGate?.resume()
        writeGate = nil
    }
}
