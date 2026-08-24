import XCTest
@testable import OpenUsage

/// Desktop tokens name an organization, so every historical user and source still constrains auth.
@MainActor
final class ClaudeDesktopAccountIsolationTests: ClaudeAssemblyTestCase {
    private func makeCoworkDiscovery(_ files: [String: String]) -> ClaudeCoworkDiscovery {
        makeCoworkDiscovery(
            files: files,
            sandboxes: files.keys.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        )
    }

    func testCompleteDiscoveryRequiresPinnedOwnershipAroundHistoricalAccounts() throws {
        let scenarios: [(organization: String?, expected: ClaudeDesktopAccessPolicy)] = [
            (nil, .denied),
            ("org-a", .pinned("org-a")),
        ]
        for scenario in scenarios {
            let identity = scenario.organization.map { "account-a|\($0)" } ?? "account-a"
            let store = try makeClaudeStore(identity: identity, otherIdentity: "account-b|org-b")
            let assembly = ProviderAccountAssembly.make(
                observer: makeClaudeObserver(
                    claudeState("account-a", organization: scenario.organization)
                ),
                accountsStore: store,
                coworkDiscovery: makeCoworkDiscovery([:])
            )

            XCTAssertEqual(assembly.claudeCards.map(\.identityKey), [identity])
            let runtime = try claudeRuntime(for: assembly)
            XCTAssertEqual(runtime.authStore.desktopAccessPolicy, scenario.expected)
            XCTAssertFalse(runtime.authStore.allowsUnpinnedStandardDesktopFallback)
        }
    }

    func testOrglessDefaultKeepsItsVerifiedDesktopPinWhenAnotherAccountExists() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let config = "/Users/dev/.claude-work"
        let ownSandbox = "/Users/dev/cowork/personal/.claude"
        let assembly = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(claudeState("account-a")),
            accountsStore: store,
            claudeDiscovery: makeDiscovery(
                files: [
                    config + "/.claude.json": claudeState("account-b", organization: "org-b"),
                    config + "/.credentials.json":
                        #"{"claudeAiOauth":{"accessToken":"work-token"}}"#,
                ],
                subdirectories: [config]
            ),
            coworkDiscovery: makeCoworkDiscovery([
                ownSandbox + "/.claude.json": claudeState("account-a", organization: "org-a"),
            ])
        )

        XCTAssertEqual(assembly.claudeCards.count, 2)
        let card = try XCTUnwrap(assembly.claudeCards.first { $0.credential == .defaultHome })
        XCTAssertEqual(card.identityKey, "account-a")
        XCTAssertEqual(card.desktopAccess, .pinned("org-a"))
        XCTAssertFalse(card.allowsUnscopedKeychainFallback)
        let runtime = try claudeRuntime(for: assembly)
        XCTAssertEqual(runtime.authStore.desktopAccessPolicy, .pinned("org-a"))
        XCTAssertEqual(runtime.authStore.standardDesktopOrganization, "org-a")
    }

    func testDifferentOrglessConfigUserDisablesOrganizationPinnedDesktopAuth() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let config = "/Users/dev/.claude-work"
        let assembly = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(claudeState("account-a", organization: "org-a")),
            accountsStore: store,
            claudeDiscovery: makeDiscovery(
                files: [
                    config + "/.claude.json": claudeState("account-b"),
                    config + "/.credentials.json":
                        #"{"claudeAiOauth":{"accessToken":"work-token"}}"#,
                ],
                subdirectories: [config]
            ),
            coworkDiscovery: makeCoworkDiscovery([:])
        )

        XCTAssertEqual(Set(assembly.claudeCards.map(\.identityKey)), ["account-a|org-a", "account-b"])
        let card = try XCTUnwrap(assembly.claudeCards.first { $0.credential == .defaultHome })
        XCTAssertEqual(card.desktopAccess, .denied)
        XCTAssertEqual(try claudeRuntime(for: assembly).authStore.desktopAccessPolicy, .denied)
    }

    func testOrganizationlessUsersOnEitherSideQuarantineDesktopOwnershipAndSpend() throws {
        for (defaultIdentity, coworkIdentity) in [
            ("account-b", "account-a|org-a"), ("account-a|org-a", "account-b"),
        ] {
            let store = ProviderAccountsStore(defaults: makeScratchDefaults())
            let root = "/Users/dev/cowork/other/.claude"
            let defaultParts = defaultIdentity.split(separator: "|").map(String.init)
            let coworkParts = coworkIdentity.split(separator: "|").map(String.init)
            let assembly = ProviderAccountAssembly.make(
                observer: makeClaudeObserver(claudeState(
                    defaultParts[0], organization: defaultParts.count > 1 ? defaultParts[1] : nil
                )),
                accountsStore: store,
                coworkDiscovery: makeCoworkDiscovery([
                    root + "/.claude.json": claudeState(
                        coworkParts[0], organization: coworkParts.count > 1 ? coworkParts[1] : nil
                    ),
                ]),
                hasDesktopCredentialMaterial: { true }
            )

            let card = try XCTUnwrap(assembly.claudeCards.first)
            XCTAssertEqual(assembly.claudeCards.map(\.identityKey), [defaultIdentity])
            XCTAssertEqual(store.records.map(\.identityKey), [defaultIdentity])
            XCTAssertEqual(card.coworkRootsOverride, [])
            XCTAssertEqual(card.desktopAccess, .denied)
            XCTAssertEqual(try claudeRuntime(for: assembly).authStore.desktopAccessPolicy, .denied)
        }
    }

    func testTombstonedUserSharingOrganizationDisablesPinnedDesktopAuth() throws {
        let store = try makeClaudeStore(
            identity: "account-a|org-shared",
            otherIdentity: "account-b|org-shared",
            removed: true
        )
        let assembly = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(claudeState("account-a", organization: "org-shared")),
            accountsStore: store,
            coworkDiscovery: makeCoworkDiscovery([:])
        )

        XCTAssertEqual(try XCTUnwrap(assembly.claudeCards.first).desktopAccess, .denied)
        let runtime = try claudeRuntime(for: assembly)
        XCTAssertNil(runtime.authStore.standardDesktopOrganization)
        XCTAssertFalse(runtime.authStore.allowsUnpinnedStandardDesktopFallback)
    }

    func testSingleAccountsUniqueOrganizationAliasDoesNotBlockDesktopFallback() throws {
        let store = try makeClaudeStore(identity: "account-a", aliases: ["account-a|org-a"])
        let assembly = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(claudeState("account-a")),
            accountsStore: store,
            coworkDiscovery: makeCoworkDiscovery([:])
        )

        XCTAssertEqual(assembly.claudeCards.map(\.identityKey), ["account-a"])
        let runtime = try claudeRuntime(for: assembly)
        XCTAssertEqual(runtime.authStore.standardDesktopOrganization, "org-a")
        XCTAssertTrue(runtime.authStore.allowsUnpinnedStandardDesktopFallback)
    }

    func testDifferentDesktopUsersSharingAnOrganizationCannotBorrowTokensOrLogs() throws {
        for includesVerifiedRoot in [false, true] {
            let store = ProviderAccountsStore(defaults: makeScratchDefaults())
            let ownRoot = "/Users/dev/cowork/current/.claude"
            let otherRoot = "/Users/dev/cowork/other/.claude"
            var files = [
                otherRoot + "/.claude.json": claudeState("account-b", organization: "org-shared"),
            ]
            if includesVerifiedRoot {
                files[ownRoot + "/.claude.json"] = claudeState(
                    "account-a", organization: "org-shared"
                )
            }
            let assembly = ProviderAccountAssembly.make(
                observer: makeClaudeObserver(
                    claudeState("account-a", organization: "org-shared")
                ),
                accountsStore: store,
                coworkDiscovery: makeCoworkDiscovery(files),
                hasDesktopCredentialMaterial: { true }
            )

            let card = try XCTUnwrap(assembly.claudeCards.first)
            XCTAssertEqual(assembly.claudeCards.count, 1)
            XCTAssertEqual(card.identityKey, "account-a|org-shared")
            XCTAssertEqual(card.coworkRootsOverride?.map(\.path), includesVerifiedRoot ? [ownRoot] : [])
            XCTAssertEqual(card.desktopAccess, .denied)
            XCTAssertFalse(store.records.contains { $0.identityKey == "account-b|org-shared" })
            XCTAssertEqual(try claudeRuntime(for: assembly).authStore.desktopAccessPolicy, .denied)
        }
    }

    func testPersistedUserSharingCoworkOrganizationQuarantinesDesktopOnlyCard() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        _ = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(claudeState("account-a", organization: "org-shared")),
            accountsStore: store
        )
        let root = "/Users/dev/cowork/other/.claude"
        let assembly = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(claudeState("account-c", organization: "org-other")),
            accountsStore: store,
            coworkDiscovery: makeCoworkDiscovery([
                root + "/.claude.json": claudeState("account-b", organization: "org-shared"),
            ]),
            hasDesktopCredentialMaterial: { true }
        )

        XCTAssertEqual(assembly.claudeCards.map(\.identityKey), ["account-c|org-other"])
        XCTAssertFalse(store.records.contains { $0.identityKey == "account-b|org-shared" })
    }

}

/// Login changes hide unavailable cards while retaining account identities, names, and ownership.
@MainActor
final class ClaudeAccountLifecycleTests: ClaudeAssemblyTestCase {
    func testUnresolvedDefaultLogoutKeepsVerifiedDesktopAndConfigAccounts() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        _ = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(claudeState("account-a", organization: "org-a")),
            accountsStore: store
        )
        let config = "/Users/dev/.claude-work"
        let sandbox = "/Users/dev/cowork/personal/.claude"
        let assembly = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(#"{"oauthAccount":null}"#),
            accountsStore: store,
            claudeDiscovery: makeDiscovery(
                files: [
                    config + "/.claude.json": claudeState("account-b", organization: "org-b"),
                    config + "/.credentials.json": #"{"claudeAiOauth":{"accessToken":"work"}}"#,
                ],
                subdirectories: [config]
            ),
            coworkDiscovery: makeCoworkDiscovery(
                files: [sandbox + "/.claude.json": claudeState("account-a", organization: "org-a")],
                sandboxes: [sandbox]
            ),
            hasDesktopCredentialMaterial: { true }
        )

        XCTAssertEqual(assembly.claudeCards.count, 2)
        XCTAssertEqual(
            assembly.claudeCards.first { $0.id == "claude" }?.credential,
            .desktop(organization: "org-a")
        )
        XCTAssertEqual(
            assembly.claudeCards.first { $0.identityKey == "account-b|org-b" }?.credential,
            .configDir(path: config, keychainLiteral: config)
        )
        XCTAssertFalse(assembly.allowsUnboundClaudeFallback)
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"))
    }

    func testUnresolvedDefaultNeverResurrectsKnownAccountsAndPreservesNames() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        _ = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(claudeState("account-a", organization: "org-a")),
            accountsStore: store
        )
        store.rename(cardID: "claude", to: "Personal")
        let loggedOut = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(#"{"oauthAccount":null}"#),
            accountsStore: store
        )

        XCTAssertTrue(loggedOut.claudeCards.isEmpty)
        XCTAssertFalse(loggedOut.allowsUnboundClaudeFallback)
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(store.record(for: "claude")?.sources, [])
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Personal")
        XCTAssertFalse(ProviderCatalog.make(claude: loggedOut.claudeRuntimePlan).contains {
            $0 is ClaudeProvider
        })
        XCTAssertEqual(
            ProviderAccountsStore(defaults: defaults).record(for: "claude")?.identityKey,
            "account-a|org-a"
        )
    }

    func testNeverIdentifiedClaudeAccountKeepsLegacySpendOnlyFallback() throws {
        let assembly = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(#"{"oauthAccount":null}"#),
            accountsStore: ProviderAccountsStore(defaults: makeScratchDefaults())
        )

        XCTAssertTrue(assembly.allowsUnboundClaudeFallback)
        let runtime = try XCTUnwrap(
            ProviderCatalog.make(claude: assembly.claudeRuntimePlan)
                .compactMap { $0 as? ClaudeProvider }.first
        )
        XCTAssertEqual(runtime.provider.id, "claude")
        XCTAssertNil(runtime.expectedIdentityKey)
    }

    func testDesktopLogoutHidesHistoricalAccountsUntilCredentialsReturn() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = makeClaudeObserver(claudeState("account-a", organization: "org-a"))
        let root = "/Users/dev/cowork/work/.claude"
        let cowork = makeCoworkDiscovery(
            files: [root + "/.claude.json": claudeState("account-b", organization: "org-b")],
            sandboxes: [root]
        )
        let signedIn = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )
        let desktopID = try XCTUnwrap(signedIn.claudeCards.first { $0.id != "claude" }?.id)
        let signedOut = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { false }
        )

        XCTAssertEqual(signedOut.claudeCards.map(\.id), ["claude"])
        XCTAssertNotNil(store.record(for: desktopID))
        let restored = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )
        XCTAssertEqual(restored.claudeCards.first { $0.id != "claude" }?.id, desktopID)
    }

    func testOneDefaultAndThreeDesktopOrganizationsBecomeFourIndependentCards() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let identities = [
            ("shared-user", "org-work"),
            ("shared-user", "org-client"),
            ("other-user", "org-other"),
        ]
        let roots = identities.indices.map { "/Users/dev/cowork/\($0)/.claude" }
        let files = Dictionary(uniqueKeysWithValues: zip(roots, identities).map { root, identity in
            (root + "/.claude.json", claudeState(identity.0, organization: identity.1))
        })
        let assembly = ProviderAccountAssembly.make(
            observer: makeClaudeObserver(
                claudeState("shared-user", organization: "org-personal")
            ),
            accountsStore: store,
            coworkDiscovery: makeCoworkDiscovery(files: files, sandboxes: roots),
            hasDesktopCredentialMaterial: { true }
        )

        let expected = Set(["shared-user|org-personal"] + identities.map { "\($0.0)|\($0.1)" })
        XCTAssertEqual(assembly.claudeCards.count, 4)
        XCTAssertEqual(Set(assembly.claudeCards.map(\.identityKey)), expected)
        XCTAssertEqual(Set(assembly.claudeCards.map(\.id)).count, 4)
        XCTAssertEqual(Set(
            ProviderCatalog.make(claude: assembly.claudeRuntimePlan)
                .compactMap { ($0 as? ClaudeProvider)?.expectedIdentityKey }
        ), expected)
    }
}
