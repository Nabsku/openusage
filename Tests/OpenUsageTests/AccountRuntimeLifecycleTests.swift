import KeyboardShortcuts
import Network
import XCTest
@testable import OpenUsage

@MainActor
final class LocalUsageServerTests: XCTestCase {
    func testReplacementWaitsForOldListenerCancellationBeforeStarting() async throws {
        let first = FakeLocalUsageListener()
        first.automaticallyFinishesCancellation = false
        let replacement = FakeLocalUsageListener()
        let retired = LocalUsageServer(state: Self.emptyState, makeListener: { _ in first })
        let successor = LocalUsageServer(state: Self.emptyState, makeListener: { _ in replacement })
        retired.start()
        XCTAssertEqual(first.startCount, 1)

        let handoff = Task { @MainActor in
            await retired.stop()
            successor.start()
        }
        try await waitUntil { first.cancelCount == 1 }
        XCTAssertEqual(replacement.startCount, 0, "the old socket must be released before rebinding")

        first.send(.cancelled)
        await handoff.value

        XCTAssertEqual(replacement.startCount, 1)
        XCTAssertEqual(replacement.cancelCount, 0)
        await successor.stop()
        XCTAssertEqual(replacement.cancelCount, 1)
    }

    func testOccupiedPortDisablesListenerWithoutRetrying() async throws {
        let listener = FakeLocalUsageListener()
        var attempts = 0
        let server = LocalUsageServer(state: Self.emptyState, makeListener: { _ in
            attempts += 1
            return listener
        })
        server.start()
        listener.send(.failed(.posix(.EADDRINUSE)))
        try await waitUntil { listener.cancelCount == 1 }

        XCTAssertEqual(attempts, 1, "an externally occupied port disables the optional API")
        await server.stop()
    }

    func testAcceptedConnectionCannotServeAfterStopOrListenerReplacement() {
        let originalGeneration = UUID()
        let replacementGeneration = UUID()
        let cases: [(Bool, UUID?, Bool)] = [
            (true, originalGeneration, true), (false, originalGeneration, false),
            (true, nil, false), (true, replacementGeneration, false),
        ]
        for (running, listenerGeneration, expected) in cases {
            XCTAssertEqual(LocalUsageServer.canServeConnection(
                isRunning: running, listenerGeneration: listenerGeneration,
                connectionGeneration: originalGeneration
            ), expected)
        }
    }

    private nonisolated static func emptyState() -> LocalUsageAPI.State {
        LocalUsageAPI.State(enabledOrderedIDs: [], knownIDs: [], snapshots: [:])
    }

    private func waitUntil(timeout: Duration = .seconds(2), condition: @escaping @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition was not met before timeout")
    }
}

@MainActor
private final class FakeLocalUsageListener: LocalUsageListening {
    private var stateHandler: (@Sendable (NWListener.State) -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    var automaticallyFinishesCancellation = true

    func setStateHandler(_ handler: (@Sendable (NWListener.State) -> Void)?) { stateHandler = handler }
    func setConnectionHandler(_ handler: (@Sendable (NWConnection) -> Void)?) {}
    func start(queue: DispatchQueue) { startCount += 1 }

    func cancel() {
        cancelCount += 1
        if automaticallyFinishesCancellation { send(.cancelled) }
    }

    func send(_ state: NWListener.State) { stateHandler?(state) }
}

@MainActor
final class AccountDiscoveryThreadingTests: XCTestCase {
    func testAccountFilesystemScansRunOffTheMainThread() async {
        let prepared = await AppContainer.prepareAccountDiscovery(
            configScan: { ClaudeConfigDirDiscovery.Result(notes: [Thread.isMainThread ? "main" : "background"]) },
            coworkScan: { ClaudeCoworkDiscovery.Result(notes: [Thread.isMainThread ? "main" : "background"]) }
        )

        XCTAssertEqual(prepared.config.notes, ["background"])
        XCTAssertEqual(prepared.cowork.notes, ["background"])
    }

    func testCancelledCoworkScanQuarantinesItsPartialResult() async {
        let sandbox = URL(fileURLWithPath: "/Users/dev/cowork/.claude")
        let result = await Task.detached {
            ClaudeCoworkDiscovery(
                files: FakeFiles([:]),
                homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
                listSandboxes: { _ in
                    withUnsafeCurrentTask { task in task?.cancel() }
                    return [sandbox]
                }
            ).run()
        }.value

        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.sandboxes.isEmpty)
    }

    func testCancellationAfterConfigScanSkipsCoworkDiscovery() async {
        let prepared = await AppContainer.prepareAccountDiscovery(
            configScan: {
                withUnsafeCurrentTask { task in task?.cancel() }
                return ClaudeConfigDirDiscovery.Result(notes: ["config scanned"])
            },
            coworkScan: { ClaudeCoworkDiscovery.Result(notes: ["cowork should not run"]) }
        )

        XCTAssertEqual(prepared.config.notes, ["config scanned"])
        XCTAssertTrue(prepared.cowork.truncated)
    }
}

@MainActor
final class StatusItemShortcutLifecycleTests: XCTestCase {
    func testRemovingControllerHandlerPreservesShortcutAndAllowsReplacement() {
        let name = KeyboardShortcuts.Name("OpenUsageTests.StatusItemShortcut.\(UUID().uuidString)")
        let shortcut = KeyboardShortcuts.Shortcut(.f19, modifiers: [.command, .control, .option, .shift])
        defer {
            KeyboardShortcuts.removeHandler(for: name)
            KeyboardShortcuts.reset(name)
        }

        KeyboardShortcuts.setShortcut(shortcut, for: name)
        KeyboardShortcuts.onKeyUp(for: name) {}

        KeyboardShortcuts.removeHandler(for: name)
        XCTAssertFalse(KeyboardShortcuts.isEnabled(for: name))
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: name), shortcut)

        KeyboardShortcuts.onKeyUp(for: name) {}
        XCTAssertTrue(KeyboardShortcuts.isEnabled(for: name))
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: name), shortcut)
    }
}
