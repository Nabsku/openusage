import XCTest
import os
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
        desktopUser: String? = nil,
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
            coworkDiscovery: discovery, hasDesktopCredentialMaterial: { expectedUser in
                hasDesktopMaterial && (desktopUser.map {
                    $0.caseInsensitiveCompare(expectedUser) == .orderedSame
                } ?? true)
            }
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

        let switched = makeAssembly(
            defaultAccount: Account(user: "primary", organization: "personal"),
            desktopAccounts: [
                Account(user: "former", organization: "old-team"),
                Account(user: "current", organization: "current-team"),
                Account(user: "current", organization: "current-personal"),
            ],
            desktopUser: "current"
        )
        XCTAssertEqual(Set(switched.claudeCards.map(\.identityKey)), [
            "current|current-team", "current|current-personal",
        ])
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

    func testPartialDesktopEvidenceNeverChangesTheVerifiedDefaultIdentity() {
        for persistedOrganization in [String?.none, "trusted"] {
            let suiteName = "OpenUsageTests.PartialDesktopOwnership.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = ProviderAccountsStore(defaults: defaults)
            if let persistedOrganization {
                store.reconcile(with: [.init(
                    family: "claude", identityKey: "primary|\(persistedOrganization)", label: nil,
                    sources: [.init(kind: .defaultHome, anchor: "/Users/dev/.claude", holdsDefaultSource: true)]
                )])
            }
            let observer = DefaultAccountObserver(
                environment: FakeEnvironment(),
                files: FakeFiles(["/Users/dev/.claude.json": Account(user: "primary", organization: nil).state]),
                keychain: FakeKeychain(), homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
            )
            let first = URL(fileURLWithPath: "/Users/dev/cowork/first/.claude")
            let second = URL(fileURLWithPath: "/Users/dev/cowork/second/.claude")
            let clock = OSAllocatedUnfairLock(initialState: 0)
            let cowork = ClaudeCoworkDiscovery(
                files: FakeFiles([
                    first.path + "/.claude.json": Account(user: "primary", organization: "partial").state,
                    second.path + "/.claude.json": Account(user: "primary", organization: "unseen").state,
                ]),
                homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
                listSandboxes: { _ in [first, second] }, timeBudget: 1,
                now: {
                    let call = clock.withLock { count in
                        defer { count += 1 }
                        return count
                    }
                    return Date(timeIntervalSince1970: call < 2 ? 0 : 2)
                }
            )

            let assembly = ProviderAccountAssembly.make(
                observer: observer, accountsStore: store, coworkDiscovery: cowork
            )
            let expected = persistedOrganization.map { "primary|\($0)" } ?? "primary"

            XCTAssertEqual(assembly.identityKeysByCard["claude"], expected)
            XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.identityKey, expected)
            XCTAssertEqual(assembly.defaultClaudeDesktopAccess, .denied)
            XCTAssertEqual(assembly.defaultClaudeCoworkRoots, [])
        }
    }

    func testDesktopFootprintDetectionNeverReadsTheSafeStorageKey() {
        let root = "/Users/dev/Library/Application Support/Claude"
        let files = FakeFiles([
            root + "/config.json": #"{"oauth:tokenCacheV2":"encrypted"}"#,
            root + "/Cookies": "present",
        ])
        let desktop = ClaudeDesktopAuthStore(
            files: files, sqlite: FakeClaudeDesktopSQLite(value: "1"),
            keyReader: UnexpectedSafeStorageReader(),
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
