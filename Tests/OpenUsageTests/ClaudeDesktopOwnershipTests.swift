import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeDesktopOwnershipTests: XCTestCase {
    private struct Account {
        let user: String
        let organization: String?

        var state: String {
            let organization = organization.map { ",\"organizationUuid\":\"\($0)\"" } ?? ""
            return "{\"oauthAccount\":{\"accountUuid\":\"\(user)\"\(organization)}}"
        }
    }

    private func makeAssembly(
        defaultAccount: Account?,
        desktopAccounts: [Account],
        hasDesktopMaterial: Bool = true,
        timeBudget: TimeInterval = 3
    ) -> ProviderAccountAssembly {
        let suiteName = "OpenUsageTests.DesktopOwnership.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let defaultFiles = defaultAccount.map { ["/Users/dev/.claude.json": $0.state] } ?? [:]
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(), files: FakeFiles(defaultFiles), keychain: FakeKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        var sandboxFiles: [String: String] = [:]
        let roots = desktopAccounts.enumerated().map { index, account in
            let root = URL(fileURLWithPath: "/Users/dev/cowork/\(index)/.claude")
            sandboxFiles[root.path + "/.claude.json"] = account.state
            return root
        }
        let discovery = ClaudeCoworkDiscovery(
            files: FakeFiles(sandboxFiles), homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSandboxes: { _ in roots }, timeBudget: timeBudget
        )
        return ProviderAccountAssembly.make(
            observer: observer, accountsStore: ProviderAccountsStore(defaults: defaults),
            coworkDiscovery: discovery, hasDesktopCredentialMaterial: { hasDesktopMaterial }
        )
    }

    func testHistoricalDesktopSandboxesNeverCreateCardsWithoutCredentialMaterial() {
        let assembly = makeAssembly(
            defaultAccount: Account(user: "primary", organization: "personal"),
            desktopAccounts: [Account(user: "former", organization: "team")],
            hasDesktopMaterial: false
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertEqual(assembly.defaultClaudeCoworkRoots, [])
    }

    func testUsersSharingAnOrganizationCannotBorrowEachOthersDesktopToken() {
        let assembly = makeAssembly(
            defaultAccount: Account(user: "primary", organization: "shared"),
            desktopAccounts: [Account(user: "coworker", organization: "shared")]
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertEqual(assembly.defaultClaudeCoworkRoots, [])
        XCTAssertEqual(assembly.defaultClaudeDesktopAccess, .denied)
    }

    func testOrganizationlessDefaultFoldsOntoItsSingleVerifiedDesktopOrganization() {
        let assembly = makeAssembly(
            defaultAccount: Account(user: "primary", organization: nil),
            desktopAccounts: [Account(user: "primary", organization: "team")]
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertEqual(assembly.identityKeysByCard["claude"], "primary|team")
        XCTAssertEqual(assembly.defaultClaudeVerifiedIdentityAliases, [ClaudeIdentity("primary")!])
        XCTAssertEqual(assembly.defaultClaudeDesktopAccess, .pinned("team"))
    }

    func testDesktopOnlyAccountDoesNotCreateAnAdditionalEmptyClaudeCard() {
        let assembly = makeAssembly(
            defaultAccount: nil, desktopAccounts: [Account(user: "desktop", organization: "team")]
        )
        let providers = ProviderCatalog.make(
            claudeCards: assembly.claudeCards, defaultClaudeCardID: assembly.defaultClaudeCardID,
            claudeIdentityKeys: assembly.identityKeysByCard,
            defaultClaudeDesktopAccess: assembly.defaultClaudeDesktopAccess
        ).filter { ProviderAccountID.family(of: $0.provider.id) == "claude" }

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers.first?.provider.id, assembly.claudeCards.first?.id)
    }

    func testIncompleteDiscoveryNeverEnablesUnverifiedActiveOrganizationFallback() {
        let assembly = makeAssembly(
            defaultAccount: Account(user: "primary", organization: nil),
            desktopAccounts: [Account(user: "other", organization: "team")], timeBudget: -1
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertEqual(assembly.defaultClaudeCoworkRoots, [])
        XCTAssertEqual(assembly.defaultClaudeDesktopAccess, .denied)
    }

    func testDesktopFootprintDetectionNeverReadsTheSafeStorageKey() {
        let root = "/Users/dev/Library/Application Support/Claude"
        let files = FakeFiles([
            root + "/config.json": #"{"oauth:tokenCacheV2":"encrypted"}"#,
            root + "/Cookies": "present",
        ])
        let desktop = ClaudeDesktopAuthStore(
            files: files, keyReader: UnexpectedSafeStorageReader(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let auth = ClaudeAuthStore(
            files: files, desktop: desktop, scope: .desktopOnly(organization: "team")
        )

        XCTAssertTrue(auth.hasCredentialFootprint())
    }
}

private struct UnexpectedSafeStorageReader: ClaudeDesktopSafeStorageKeyReading {
    func readPassword(allowInteraction: Bool) throws -> String? {
        XCTFail("Credential detection must not read Claude Desktop Safe Storage")
        return nil
    }
}
