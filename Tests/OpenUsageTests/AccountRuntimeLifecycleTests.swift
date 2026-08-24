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

    func testSessionRootChangesNeverChangeAccountOwnershipFingerprint() {
        let account = ClaudeAccountCard(
            id: "claude@team", displayName: "Team", identityKey: "person|team",
            credential: .desktop(organization: "team"),
            logRoots: [URL(fileURLWithPath: "/tmp/session-one")]
        )
        var updated = account
        updated.logRoots.append(URL(fileURLWithPath: "/tmp/session-two"))
        let first = ProviderAccountAssembly(identityKeysByCard: [account.id: account.identityKey], claudeCards: [account])
        let second = ProviderAccountAssembly(identityKeysByCard: [updated.id: updated.identityKey], claudeCards: [updated])

        XCTAssertEqual(AppContainer.AccountOwnershipFingerprint(first), .init(second))
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
}
