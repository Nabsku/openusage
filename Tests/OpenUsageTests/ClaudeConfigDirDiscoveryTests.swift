import XCTest
@testable import OpenUsage

/// A discovered account needs both a verified identity and its own file or scoped keychain login.
final class ClaudeConfigDirDiscoveryTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/dev")

    private func discover(
        _ files: [String: String], paths: [String],
        environment: [String: String] = [:], services: [String: String] = [:]
    ) -> ClaudeConfigDirDiscovery.Result {
        ClaudeConfigDirDiscovery(
            environment: FakeEnvironment(environment), files: FakeFiles(files),
            keychain: ServiceKeychain(values: services), homeDirectory: { [home] in home },
            listSubdirectories: { url in
                paths.map(URL.init(fileURLWithPath:)).filter {
                    $0.deletingLastPathComponent().path == url.path
                }
            }
        ).run()
    }

    func testFileAndScopedKeychainCredentialsRequireTheirOwnIdentity() throws {
        let filePath = "/Users/dev/.claude-work"
        let keyedPath = "/Users/dev/.claude-alt"
        let literal = "~/.claude-alt"
        let service = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: literal, environment: FakeEnvironment()
        )
        let result = discover([
            filePath + "/.claude.json":
                #"{"oauthAccount":{"accountUuid":"WORK","emailAddress":"work@example.com","organizationName":"Sunstory"}}"#,
            filePath + "/.credentials.json": #"{"claudeAiOauth":{"accessToken":"work"}}"#,
            keyedPath + "/.claude.json": #"{"oauthAccount":{"accountUuid":"KEYED"}}"#,
        ], paths: [filePath, keyedPath], services: [service: "present"])

        let work = try XCTUnwrap(result.findings.first { $0.identityKey == "work" })
        XCTAssertEqual(work.label, "work@example.com (Sunstory)")
        XCTAssertEqual(work.anchorPath, filePath)
        XCTAssertEqual(result.findings.first { $0.identityKey == "keyed" }?.keychainLiteral, literal)
    }

    func testIdentityAndCredentialCannotBeBorrowedFromDifferentDirectories() {
        let identityOnly = "/Users/dev/.claude-identity"
        let credentialOnly = "/Users/dev/.claude-anon"
        let result = discover([
            identityOnly + "/.claude.json": #"{"oauthAccount":{"accountUuid":"ACCOUNT"}}"#,
            credentialOnly + "/.credentials.json": #"{"claudeAiOauth":{"accessToken":"other"}}"#,
        ], paths: [identityOnly, credentialOnly])

        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.notes.count, 1)
    }

    func testDefaultHomesRespectConfiguredOverrideAndNeverProduceDuplicateCards() {
        let configured = "/Users/dev/.claude-main"
        let xdg = "/Users/dev/.config/claude"
        let files = [
            configured + "/.claude.json": #"{"oauthAccount":{"accountUuid":"MAIN"}}"#,
            configured + "/.credentials.json": #"{"claudeAiOauth":{"accessToken":"main"}}"#,
            xdg + "/.claude.json": #"{"oauthAccount":{"accountUuid":"XDG"}}"#,
            xdg + "/.credentials.json": #"{"claudeAiOauth":{"accessToken":"xdg"}}"#,
        ]
        XCTAssertEqual(
            discover(
                files, paths: [configured, xdg],
                environment: ["CLAUDE_CONFIG_DIR": "~/.claude-main"]
            ).findings.map(\.identityKey),
            ["xdg"]
        )
        XCTAssertEqual(discover(files, paths: [configured, xdg]).findings.map(\.identityKey), ["main"])
    }
}

/// Every sandbox contributes its exact account identity, or remains explicitly unassigned.
final class ClaudeCoworkDiscoveryTests: XCTestCase {
    private let sandboxA = URL(fileURLWithPath: "/Users/dev/cowork/a/.claude")
    private let sandboxB = URL(fileURLWithPath: "/Users/dev/cowork/b/.claude")

    private func discover(
        files: [String: String], roots: [URL], timeBudget: TimeInterval = 3
    ) -> ClaudeCoworkDiscovery.Result {
        ClaudeCoworkDiscovery(
            files: FakeFiles(files), homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSandboxes: { _ in roots }, timeBudget: timeBudget
        ).run()
    }

    func testEverySandboxPreservesItsIdentityOrExplicitlyRemainsUnassigned() throws {
        let missing = URL(fileURLWithPath: "/Users/dev/cowork/missing/.claude")
        let result = discover(files: [
            sandboxA.path + "/.claude.json":
                #"{"oauthAccount":{"accountUuid":"WORK","emailAddress":"work@example.com","organizationUuid":"ORG","organizationName":"Sunstory"}}"#,
            sandboxB.path + "/.claude.json": #"{"oauthAccount":{}}"#,
        ], roots: [sandboxA, sandboxB, missing])

        let verified = try XCTUnwrap(result.sandboxes.first)
        XCTAssertEqual(verified.root, sandboxA)
        XCTAssertEqual(verified.identityKey, "work|org")
        XCTAssertEqual(verified.organization, "org")
        XCTAssertEqual(verified.label, "work@example.com (Sunstory)")
        XCTAssertEqual(result.sandboxes.map(\.root), [sandboxA, sandboxB, missing])
        XCTAssertNil(result.sandboxes[1].identityKey)
        XCTAssertNil(result.sandboxes[2].identityKey)
    }

    func testTruncatedWalkIsExplicitAndNormalBudgetHandlesHundredsOfSandboxes() {
        let truncated = discover(files: [:], roots: [sandboxA, sandboxB], timeBudget: -1)
        XCTAssertTrue(truncated.truncated)
        XCTAssertTrue(truncated.sandboxes.isEmpty)
        XCTAssertEqual(truncated.notes.count, 1)

        let roots = (0..<250).map { URL(fileURLWithPath: "/Users/dev/cowork/\($0)/.claude") }
        let files = Dictionary(uniqueKeysWithValues: roots.enumerated().map { index, root in
            (
                root.path + "/.claude.json",
                #"{"oauthAccount":{"accountUuid":"ACCOUNT-\#(index % 3)","organizationUuid":"ORG-\#(index % 3)"}}"#
            )
        })
        let complete = discover(files: files, roots: roots)
        XCTAssertFalse(complete.truncated)
        XCTAssertEqual(complete.sandboxes.count, roots.count)
        XCTAssertEqual(Set(complete.sandboxes.compactMap(\.identityKey)), [
            "account-0|org-0", "account-1|org-1", "account-2|org-2",
        ])
    }

    func testCoworkRootsOverrideExcludesAnotherAccountsUsageFromTheScanner() async throws {
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        let home = try ClaudeLogFixture.makeUserHome(
            claudeFiles: [
                "project/terminal.jsonl": ClaudeLogFixture.usageLine(
                    timestamp: timestamp, input: 100, output: 50, costUSD: 0.25,
                    messageID: "terminal", requestID: "terminal"
                ),
            ],
            coworkSessions: [
                "group/sub/local_mine": ["workspace/session.jsonl": ClaudeLogFixture.usageLine(
                    timestamp: timestamp, input: 10, output: 5, costUSD: 0.05,
                    messageID: "mine", requestID: "mine"
                )],
                "group/sub/local_theirs": ["workspace/session.jsonl": ClaudeLogFixture.usageLine(
                    timestamp: timestamp, input: 90_000, output: 10, costUSD: 9.99,
                    messageID: "theirs", requestID: "theirs"
                )],
            ]
        )
        let root = home.appendingPathComponent(
            "Library/Application Support/Claude/local-agent-mode-sessions/group/sub/local_mine/.claude"
        )
        let scanner = ClaudeLogUsageScanner(
            environment: FakeEnvironment(), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
            coworkRootsOverride: [root]
        )
        let scanned = await scanner.scan(now: now, pricing: TestPricing.bundled)
        let result = try XCTUnwrap(scanned)
        XCTAssertEqual(result.series.daily.count, 1)
        XCTAssertEqual(result.series.daily[0].totalTokens, 165)
        XCTAssertEqual(result.series.daily[0].costUSD ?? 0, 0.30, accuracy: 1e-9)
    }
}

/// Incomplete walks never own logs, and every known or observed account still constrains auth.
@MainActor
final class ClaudeCoworkPartitionTests: ClaudeAssemblyTestCase {
    func testTruncatedCoworkWalkSeparatesDesktopAuthFromUnverifiedLogs() throws {
        let scenarios: [(organization: String?, otherAccount: Bool, policy: ClaudeDesktopAccessPolicy)] = [
            ("org-a", true, .pinned("org-a")),
            ("org-a", false, .pinned("org-a")),
            (nil, false, .activeOrganization),
        ]

        for scenario in scenarios {
            let store = ProviderAccountsStore(defaults: makeScratchDefaults())
            let configPath = "/Users/dev/.claude-work"
            let findings: [ClaudeConfigDirDiscovery.Finding] = scenario.otherAccount ? [
                .init(
                    identityKey: "account-b|org-b", label: nil,
                    anchorPath: configPath, keychainLiteral: configPath
                ),
            ] : []
            let assembly = ProviderAccountAssembly.make(
                observer: makeClaudeObserver(
                    claudeState("account-a", organization: scenario.organization)
                ),
                accountsStore: store,
                preparedDiscovery: PreparedProviderAccountDiscovery(
                    config: .init(findings: findings),
                    cowork: .init(sandboxes: [], truncated: true)
                )
            )

            let card = try XCTUnwrap(assembly.claudeCards.first { $0.credential == .defaultHome })
            XCTAssertEqual(assembly.claudeCards.count, scenario.otherAccount ? 2 : 1)
            XCTAssertEqual(card.coworkRootsOverride, [])
            XCTAssertEqual(card.desktopAccess, scenario.policy)
            let runtime = try claudeRuntime(for: assembly)
            XCTAssertEqual(runtime.authStore.desktopAccessPolicy, scenario.policy)
            XCTAssertEqual(
                runtime.authStore.allowsUnpinnedStandardDesktopFallback,
                scenario.policy == .activeOrganization
            )
        }
    }

    func testTruncatedCoworkWalkCountsHistoricalAndRemovedAccountOwnership() throws {
        for removed in [false, true] {
            let store = try makeClaudeStore(
                identity: "account-a", otherIdentity: "account-b|org-b", removed: removed
            )
            let assembly = ProviderAccountAssembly.make(
                observer: makeClaudeObserver(claudeState("account-a")),
                accountsStore: store,
                preparedDiscovery: PreparedProviderAccountDiscovery(
                    config: .init(), cowork: .init(sandboxes: [], truncated: true)
                )
            )

            let card = try XCTUnwrap(assembly.claudeCards.first)
            XCTAssertEqual(assembly.claudeCards.count, 1)
            XCTAssertEqual(card.desktopAccess, .denied)
            XCTAssertEqual(card.coworkRootsOverride, [])
            XCTAssertFalse(try claudeRuntime(for: assembly).authStore.allowsUnpinnedStandardDesktopFallback)
        }
    }

    func testTruncatedCoworkObservationsQuarantineOtherUsersAndAmbiguousOrganizations() throws {
        let scenarios: [(identity: String, observed: [String])] = [
            ("account-a", ["account-b|org-b"]),
            ("account-a", ["account-a|org-personal", "account-a|org-work"]),
            ("account-a|org-shared", ["account-b|org-shared"]),
        ]

        for scenario in scenarios {
            let store = ProviderAccountsStore(defaults: makeScratchDefaults())
            let parts = scenario.identity.split(separator: "|").map(String.init)
            let sandboxes = scenario.observed.enumerated().map { index, identity in
                ClaudeCoworkDiscovery.Sandbox(
                    root: URL(fileURLWithPath: "/Users/dev/cowork/\(index)/.claude"),
                    identityKey: identity,
                    organization: ClaudeIdentity(identity)?.organization
                )
            }
            let assembly = ProviderAccountAssembly.make(
                observer: makeClaudeObserver(
                    claudeState(parts[0], organization: parts.count == 2 ? parts[1] : nil)
                ),
                accountsStore: store,
                preparedDiscovery: PreparedProviderAccountDiscovery(
                    config: .init(), cowork: .init(sandboxes: sandboxes, truncated: true)
                )
            )

            let card = try XCTUnwrap(assembly.claudeCards.first)
            XCTAssertEqual(assembly.claudeCards.count, 1)
            XCTAssertEqual(card.coworkRootsOverride, [])
            XCTAssertEqual(card.desktopAccess, .denied)
            XCTAssertEqual(store.records.count, 1, "partial discoveries cannot create cards")
            let runtime = try claudeRuntime(for: assembly)
            XCTAssertNil(runtime.authStore.standardDesktopOrganization)
            XCTAssertFalse(runtime.authStore.allowsUnpinnedStandardDesktopFallback)
        }
    }
}
