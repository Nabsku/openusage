import XCTest
@testable import OpenUsage

/// The `.configDir` credential scope: an extra account card may only ever see its own login —
/// its own credentials file and its own computed keychain item, with no Desktop, environment-token,
/// or default-service fallback.
final class ClaudeScopedAuthStoreTests: XCTestCase {
    private let scope = ClaudeCredentialScope.configDir(
        path: "/Users/dev/.claude-work",
        keychainLiteral: "~/.claude-work"
    )

    func testScopedStoreReadsOnlyItsOwnCredentialSources() throws {
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: "~/.claude-work", environment: FakeEnvironment([:])
        )
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Another account's default-home file must stay invisible to the scoped card.
                "~/.claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "default-at"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "work-at"}}"#,
            ]),
            keychain: ServiceKeychain(),
            scope: scope
        )

        XCTAssertEqual(store.keychainServiceCandidates(), [scopedService], "never the bare default service")
        let load = store.loadCredentialSet()
        XCTAssertEqual(load.candidates.map(\.oauth.accessToken), ["work-at"])
        XCTAssertEqual(load.desktopStatus, .notChecked, "a config-dir card never consults Desktop")
    }

    func testScopedStoreNeverInheritsTheAmbientEnvironmentToken() {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "ambient-token"]),
            files: FakeFiles([
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "work-at"}}"#,
            ]),
            keychain: ServiceKeychain(),
            scope: scope
        )

        let candidates = store.loadCredentialSet().candidates
        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["work-at"])
        XCTAssertFalse(candidates.contains { $0.source == .environment })
    }

    func testStandardCustomHomeNeverBorrowsAnotherAccountsBareKeychain() {
        let literal = "~/.claude-work"
        let environment = FakeEnvironment(["CLAUDE_CONFIG_DIR": literal])
        let scoped = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: literal, environment: environment
        )
        let bare = ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        for allowsFallback in [false, true] {
            let store = ClaudeAuthStore(
                environment: environment,
                files: FakeFiles([literal + "/.credentials.json":
                    #"{"claudeAiOauth":{"accessToken":"own-account"}}"#]),
                keychain: ServiceKeychain(currentUserValues: [bare:
                    #"{"claudeAiOauth":{"accessToken":"another-account"}}"#]),
                desktopAccessPolicy: .pinned("org-work"),
                allowsUnscopedStandardKeychainFallback: allowsFallback
            )

            XCTAssertEqual(store.keychainServiceCandidates(), [scoped])
            XCTAssertEqual(store.loadCredentialCandidates().map(\.oauth.accessToken), ["own-account"])
        }
    }

    func testCredentialRotationCannotOverwriteAnotherAccountAfterIdentityChanges() throws {
        let identityPath = "/Users/dev/.claude-work/.claude.json"
        let credentialPath = "/Users/dev/.claude-work/.credentials.json"
        let original = #"{"claudeAiOauth":{"accessToken":"account-a"}}"#
        let files = FakeFiles([
            identityPath: #"{"oauthAccount":{"accountUuid":"account-a"}}"#,
            credentialPath: original,
        ])
        let store = ClaudeAuthStore(
            files: files,
            keychain: ServiceKeychain(),
            scope: scope,
            expectedIdentityKey: "account-a"
        )
        var candidate = try XCTUnwrap(store.loadCredentialCandidates().first)
        let generation = ClaudeCredentialGeneration([candidate])
        candidate.oauth.accessToken = "rotated-account-a"
        files.files[identityPath] = #"{"oauthAccount":{"accountUuid":"account-b"}}"#

        XCTAssertFalse(try store.save(candidate, ifUnchanged: generation))
        XCTAssertEqual(files.files[credentialPath], original)
    }

    func testOrganizationlessIdentityMatchesOnlyVerifiedSourceEvidence() {
        let scenarios: [(organization: String?, policy: ClaudeDesktopAccessPolicy, verified: Bool, matches: Bool)] = [
            (nil, .denied, true, true),
            (nil, .activeOrganization, true, true),
            (nil, .pinned("org-work"), false, false),
            ("org-other", .pinned("org-work"), true, false),
        ]

        for scenario in scenarios {
            let identity = scenario.organization.map {
                #"{"oauthAccount":{"accountUuid":"account-a","organizationUuid":"\#($0)"}}"#
            } ?? #"{"oauthAccount":{"accountUuid":"account-a"}}"#
            let store = ClaudeAuthStore(
                files: FakeFiles(["/Users/dev/.claude-work/.claude.json": identity]),
                keychain: ServiceKeychain(),
                scope: scope,
                expectedIdentityKey: "account-a|org-work",
                verifiedIdentityAliases: scenario.verified ? [ClaudeIdentity("account-a")!] : [],
                desktopAccessPolicy: scenario.policy
            )

            XCTAssertEqual(store.belongsToExpectedAccount(), scenario.matches)
        }
    }

    func testFootprintProbeSeesFileAndKeychainShapesWithoutReadingSecrets() {
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: "~/.claude-work", environment: FakeEnvironment([:])
        )
        let fileBacked = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["/Users/dev/.claude-work/.credentials.json": "{}"]),
            keychain: ServiceKeychain(),
            scope: scope
        )
        XCTAssertTrue(fileBacked.hasCredentialFootprint())

        let keychainBacked = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: ServiceKeychain(values: [scopedService: "present"]),
            scope: scope
        )
        XCTAssertTrue(keychainBacked.hasCredentialFootprint())

        let bare = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: ServiceKeychain(),
            scope: scope
        )
        XCTAssertFalse(bare.hasCredentialFootprint())
    }

    func testStandardStoreDropsDesktopFallbackWhileExtraCardsExistAndNoOrgPinIsKnown() {
        // With no CLI login, no org pin, and the unpinned fallback disallowed (extra Claude cards
        // exist), the load reports `.notFound` instead of consulting Desktop — the caller keeps the
        // honest CLI error.
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: ServiceKeychain(),
            allowsUnpinnedStandardDesktopFallback: false
        )

        let load = store.loadCredentialSet(forceDesktopFallback: true)
        XCTAssertEqual(load.desktopStatus, .notFound)
        XCTAssertTrue(load.candidates.isEmpty)
    }

    func testDesktopOnlyStoreHasNoCLISourcesAndNeverInheritsTheEnvironmentToken() {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "ambient-token"]),
            files: FakeFiles([
                // Every CLI credential on the machine must stay invisible to a Desktop-backed card.
                "~/.claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "default-at"}}"#,
            ]),
            keychain: ServiceKeychain(),
            scope: .desktopOnly(organization: "11111111-2222-3333-4444-555555555555")
        )

        XCTAssertEqual(store.keychainServiceCandidates(), [])
        // No Desktop material in this fixture, so the load ends up empty — the point is that no CLI
        // or environment candidate leaked in, and Desktop WAS consulted (status is not .notChecked).
        let load = store.loadCredentialSet()
        XCTAssertTrue(load.candidates.isEmpty)
        XCTAssertEqual(load.desktopStatus, .notFound)
    }
}
