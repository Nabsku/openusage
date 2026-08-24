import XCTest
@testable import OpenUsage

/// Account-bound credential scopes never inherit another login, organization, or ambient token.
final class ClaudeScopedAuthStoreTests: XCTestCase {
    private let scope = ClaudeCredentialScope.configDir(
        path: "/Users/dev/.claude-work", keychainLiteral: "~/.claude-work"
    )

    func testScopedAndDesktopAccountsRejectUnrelatedCredentialsAndEnvironmentTokens() {
        let environment = FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "ambient-token"])
        let files = FakeFiles([
            "~/.claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"default-at"}}"#,
            "/Users/dev/.claude-work/.credentials.json":
                #"{"claudeAiOauth":{"accessToken":"work-at"}}"#,
        ])
        let scoped = ClaudeAuthStore(
            environment: environment, files: files, keychain: ServiceKeychain(), scope: scope
        )
        let expectedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: "~/.claude-work", environment: environment
        )
        let own = scoped.loadCredentialSet()
        XCTAssertEqual(scoped.keychainServiceCandidates(), [expectedService])
        XCTAssertEqual(own.candidates.map(\.oauth.accessToken), ["work-at"])
        XCTAssertEqual(own.desktopStatus, .notChecked)

        let desktop = ClaudeAuthStore(
            environment: environment, files: files, keychain: ServiceKeychain(),
            scope: .desktopOnly(organization: "org-a")
        )
        XCTAssertTrue(desktop.keychainServiceCandidates().isEmpty)
        let isolated = desktop.loadCredentialSet()
        XCTAssertTrue(isolated.candidates.isEmpty)
        XCTAssertEqual(isolated.desktopStatus, .notFound)
    }

    @MainActor
    func testCoworkPartitionDisablesOnlyUnpinnedFallback() throws {
        let partitioned = ProviderCatalog.make(claude: ClaudeRuntimePlan(defaultCoworkRoots: []))
        let scoped = try XCTUnwrap(partitioned.compactMap { $0 as? ClaudeProvider }.first)
        let unpartitioned = try XCTUnwrap(
            ProviderCatalog.make().compactMap { $0 as? ClaudeProvider }.first
        )
        XCTAssertFalse(scoped.authStore.allowsUnpinnedStandardDesktopFallback)
        XCTAssertTrue(unpartitioned.authStore.allowsUnpinnedStandardDesktopFallback)
    }

    func testEveryCredentialScopeRequiresItsExactSourceAndOrganization() {
        let state = #"{"oauthAccount":{"accountUuid":"ACCOUNT-A","organizationUuid":"ORG-A"}}"#
        let cases: [(ClaudeCredentialScope, [String: String], [String: String])] = [
            (
                scope, [:],
                ["/Users/dev/.claude-work/.claude.json": state, "~/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCOUNT-B","organizationUuid":"ORG-B"}}"#]
            ),
            (.standard, ["CLAUDE_CONFIG_DIR": "/tmp/claude"], ["/tmp/claude/.claude.json": state]),
            (.standard, [:], ["~/.claude.json": state]),
            (.desktopOnly(organization: "ORG-A"), [:], [:]),
        ]
        for (scope, environment, states) in cases {
            let store = ClaudeAuthStore(
                environment: FakeEnvironment(environment), files: FakeFiles(states),
                keychain: ServiceKeychain(), scope: scope
            )
            XCTAssertTrue(store.matchesIdentity("account-a|org-a"))
            XCTAssertFalse(store.matchesIdentity("account-a|org-b"))
            XCTAssertFalse(store.matchesIdentity("account-a"))
        }
    }

    func testDefaultIdentityNeverGuessesMissingOrganizationOrMissingState() {
        let path = "/tmp/claude/.claude.json"
        let files = FakeFiles([path: #"{"oauthAccount":{"accountUuid":"ACCOUNT-A"}}"#])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files, keychain: ServiceKeychain()
        )
        XCTAssertTrue(store.matchesIdentity("account-a"))
        XCTAssertFalse(store.matchesIdentity("account-a|org-a"))
        files.files.removeValue(forKey: path)
        XCTAssertFalse(store.matchesIdentity("account-a"))
    }

    func testConfiguredAccountCannotFallBackToAnotherAccountsBareKeychainItem() {
        let environment = FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude-work"])
        let store = ClaudeAuthStore(
            environment: environment, files: FakeFiles(),
            keychain: ServiceKeychain(values: [
                "Claude Code-credentials": #"{"claudeAiOauth":{"accessToken":"other"}}"#,
            ]),
            allowsUnpinnedStandardDesktopFallback: false
        )
        XCTAssertEqual(store.keychainServiceCandidates(), [
            ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: "/tmp/claude-work", environment: environment
            ),
        ])
        XCTAssertTrue(store.loadCredentialSet().candidates.isEmpty)
    }

    @MainActor
    func testAccountRuntimeScopesEveryWidgetToItsStableCardIdentifier() {
        let provider = ClaudeProvider(provider: ClaudeProvider.makeProvider(
            id: "claude@deadbeef", displayName: "Claude — Work"
        ))
        XCTAssertEqual(provider.provider.id, "claude@deadbeef")
        XCTAssertEqual(provider.provider.displayName, "Claude — Work")
        XCTAssertTrue(provider.widgetDescriptors.allSatisfy {
            $0.id.hasPrefix("claude@deadbeef.")
        })
    }
}
