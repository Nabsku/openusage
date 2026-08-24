import XCTest
@testable import OpenUsage

/// The launch account pass end to end: observer outcomes → account registry records → the per-card
/// identity map consumed by the snapshot cache stamp and the bare-id resolver.
@MainActor
final class ProviderAccountAssemblyTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderAccountAssembly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testResolvedFamiliesFeedIdentityKeysAndTheRegistry() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Claude resolved at the default home; Codex has credentials that name no account.
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.identityKeysByCard, ["claude": "acct-1"])
        // The registry recorded the resolved account under the bare id, holding the default badge.
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(record.label, "dev@example.com")
        XCTAssertEqual(record.sources.map(\.kind), [.defaultHome])
        // An unresolved family claims no account: no record, no identity key.
        XCTAssertNil(store.defaultBadgeHolder(family: "codex"))

        let unreadable = DefaultAccountObserver(
            environment: FakeEnvironment(),
            files: FakeFiles([
                "/Users/dev/.claude/.credentials.json":
                    #"{"claudeAiOauth":{"accessToken":"still-signed-in"}}"#,
            ]),
            keychain: FakeKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let retained = ProviderAccountAssembly.make(observer: unreadable, accountsStore: store)
        let runtime = try XCTUnwrap(ProviderCatalog.make(
            defaultClaudeCardID: retained.defaultClaudeCardID,
            claudeIdentityKeys: retained.identityKeysByCard
        ).first as? ClaudeProvider)

        XCTAssertEqual(retained.identityKeysByCard["claude"], "acct-1")
        XCTAssertEqual(runtime.authStore.expectedIdentityKey, "acct-1")
    }

    /// A family whose home facts aren't readable this launch (first Finder/Dock launch racing a
    /// slow shell) is left out of the pass entirely: not observed, not reconciled — while a family
    /// whose home override is already in the process environment still resolves.
    func testFamiliesOutsideThePassAreNeitherObservedNorReconciled() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1", "account_id": "CODEX-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store, families: ["codex"])

        XCTAssertEqual(assembly.identityKeysByCard, ["codex": "codex-1"])
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"), "an out-of-pass family must not be reconciled")
    }

    private func makeDiscovery(
        files: [String: String],
        subdirectories: [String]
    ) -> ClaudeConfigDirDiscovery {
        ClaudeConfigDirDiscovery(
            environment: FakeEnvironment([:]),
            files: FakeFiles(files),
            keychain: ServiceKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSubdirectories: { url in
                subdirectories
                    .map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().path == url.path }
            }
        )
    }

    func testADistinctConfigDirAccountMintsAHashedRecordAndAnExtraCard() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "emailAddress": "work@example.com", "organizationName": "Sunstory"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertEqual(assembly.claudeCards.count, 1)
        XCTAssertTrue(card.id.hasPrefix("claude@"), "a config-dir account never claims the bare id")
        XCTAssertEqual(card.displayName, "Claude — Sunstory")
        XCTAssertEqual(card.configDirPath, "/Users/dev/.claude-work")
        XCTAssertEqual(assembly.identityKeysByCard["claude"], "acct-1")
        XCTAssertEqual(assembly.identityKeysByCard[card.id], "acct-2")
        // The registry recorded both: the default holder under the bare id, the extra account with
        // its config-dir source.
        let record = try XCTUnwrap(store.records.first { $0.id == card.id })
        XCTAssertEqual(record.sources.map(\.kind), [.configDir])
        XCTAssertEqual(record.label, "work@example.com (Sunstory)")
        XCTAssertTrue(assembly.defaultClaudeExtraLogRoots.isEmpty)
    }

    func testASameAccountConfigDirFoldsOntoTheDefaultCardAsALogRoot() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-side/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.claude-side/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-1"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-side"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty, "one account never renders as two cards")
        XCTAssertEqual(assembly.defaultClaudeExtraLogRoots.map(\.path), ["/Users/dev/.claude-side"])
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(Set(record.sources.map(\.kind)), [.defaultHome, .configDir])
    }

    func testAnUnresolvedDefaultLoginSkipsCandidatesThisLaunch() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Credentials exist but the state file names no account → unresolved, footprint present.
                "/Users/dev/.claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        XCTAssertTrue(
            assembly.claudeCards.isEmpty,
            "with a nameless default login, an accepted candidate could be that very account — skip"
        )
        XCTAssertTrue(store.records.isEmpty)
    }

    func testNoDefaultLoginStillAcceptsAConfigDirOnlyAccount() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertTrue(
            card.id.hasPrefix("claude@"),
            "the bare id stays reserved for a future default-home login even when it is free"
        )
    }

    func testARenameNeverBakesIntoTheCardOnlyTheResolverCarriesIt() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        // First pass creates the record; the user then renames it.
        let first = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )
        let cardID = try XCTUnwrap(first.claudeCards.first?.id)
        XCTAssertEqual(first.claudeCards.first?.displayName, cardID, "no label → the short-hash id fallback")
        store.rename(cardID: cardID, to: "Work Max")

        let reloadedStore = ProviderAccountsStore(defaults: defaults)
        let second = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: reloadedStore,
            claudeDiscovery: discovery
        )
        // The baked card name stays the DERIVED default — a rename lives only in the registry and
        // is resolved at render time, so a baked name can never be a stale copy of it.
        XCTAssertEqual(second.claudeCards.first?.displayName, cardID)
        XCTAssertEqual(reloadedStore.resolvedDisplayName(cardID: cardID), "Work Max")
    }

    func testPreviouslyVerifiedConfigDirectoryRemainsTheCredentialPrimary() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: FakeKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let previous = "/Users/dev/.claude-z-work"
        let earlier = "/Users/dev/.claude-a-work"
        let files = [
            previous + "/.claude.json": #"{"oauthAccount":{"accountUuid":"work"}}"#,
            previous + "/.credentials.json": #"{"claudeAiOauth":{"accessToken":"current"}}"#,
            earlier + "/.claude.json": #"{"oauthAccount":{"accountUuid":"work"}}"#,
            earlier + "/.credentials.json": #"{"claudeAiOauth":{"accessToken":"older"}}"#,
        ]
        _ = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store,
            claudeDiscovery: makeDiscovery(files: files, subdirectories: [previous])
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store,
            claudeDiscovery: makeDiscovery(files: files, subdirectories: [earlier, previous])
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertEqual(card.configDirPath, previous)
        XCTAssertEqual(card.extraLogRoots.map(\.path), [earlier])
        XCTAssertEqual(store.record(for: card.id)?.sources.first?.anchor, previous)
    }

    func testIncompleteDiscoveryDisablesUnverifiedDesktopFallback() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(),
            files: FakeFiles(["/Users/dev/.claude.json": #"{"oauthAccount":{"accountUuid":"main"}}"#]),
            keychain: FakeKeychain(), homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = ClaudeConfigDirDiscovery(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: ServiceKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSubdirectories: { _ in [URL(fileURLWithPath: "/Users/dev/.claude-work")] },
            timeBudget: -1
        )
        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )
        let provider = try XCTUnwrap(ProviderCatalog.make(
            claudeCards: assembly.claudeCards, claudeIdentityKeys: assembly.identityKeysByCard,
            isClaudeDiscoveryComplete: assembly.isClaudeDiscoveryComplete
        ).first as? ClaudeProvider)

        XCTAssertFalse(assembly.isClaudeDiscoveryComplete)
        XCTAssertFalse(provider.authStore.allowsDesktopFallback)
    }

    func testAccountSwapKeepsTheOriginalCardBoundToItsOwnConfigDirectory() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let original = DefaultAccountObserver(
            environment: FakeEnvironment(),
            files: FakeFiles(["/Users/dev/.claude.json":
                #"{"oauthAccount":{"accountUuid":"ACCOUNT-A"}}"#]),
            keychain: FakeKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        _ = ProviderAccountAssembly.make(observer: original, accountsStore: store)
        store.rename(cardID: "claude", to: "Personal")

        let replacement = DefaultAccountObserver(
            environment: FakeEnvironment(),
            files: FakeFiles(["/Users/dev/.claude.json":
                #"{"oauthAccount":{"accountUuid":"ACCOUNT-B"}}"#]),
            keychain: FakeKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let path = "/Users/dev/.claude-personal"
        let discovery = makeDiscovery(
            files: [
                path + "/.claude.json": #"{"oauthAccount":{"accountUuid":"ACCOUNT-A"}}"#,
                path + "/.credentials.json": #"{"claudeAiOauth":{"accessToken":"personal"}}"#,
            ],
            subdirectories: [path]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: replacement, accountsStore: store, claudeDiscovery: discovery
        )
        let originalCard = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertEqual(originalCard.id, "claude")
        XCTAssertEqual(originalCard.configDirPath, path)
        XCTAssertEqual(originalCard.displayName, "Claude")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Personal")
        XCTAssertNotEqual(assembly.defaultClaudeCardID, "claude")
        XCTAssertEqual(assembly.identityKeysByCard["claude"], "account-a")
        XCTAssertEqual(assembly.identityKeysByCard[assembly.defaultClaudeCardID], "account-b")

        let runtimes = ProviderCatalog.make(
            claudeCards: assembly.claudeCards,
            defaultClaudeExtraLogRoots: assembly.defaultClaudeExtraLogRoots,
            defaultClaudeDisplayName: assembly.defaultClaudeDisplayName,
            defaultClaudeCardID: assembly.defaultClaudeCardID
        ).compactMap { $0 as? ClaudeProvider }
        XCTAssertEqual(runtimes.first?.provider.id, "claude")
        XCTAssertEqual(runtimes.first?.authStore.scope,
                       .configDir(path: path, keychainLiteral: path))
        XCTAssertEqual(runtimes.last?.provider.id, assembly.defaultClaudeCardID)
        XCTAssertEqual(runtimes.last?.authStore.scope, .standard)

        let temporarilyUnreadable = DefaultAccountObserver(
            environment: FakeEnvironment(),
            files: FakeFiles([
                "/Users/dev/.claude/.credentials.json":
                    #"{"claudeAiOauth":{"accessToken":"account-b"}}"#,
            ]),
            keychain: FakeKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let unresolved = ProviderAccountAssembly.make(
            observer: temporarilyUnreadable, accountsStore: store
        )
        let retained = ProviderCatalog.make(
            defaultClaudeCardID: unresolved.defaultClaudeCardID,
            claudeIdentityKeys: unresolved.identityKeysByCard
        ).compactMap { $0 as? ClaudeProvider }

        XCTAssertEqual(unresolved.defaultClaudeCardID, assembly.defaultClaudeCardID)
        XCTAssertEqual(retained.map { $0.provider.id }, [assembly.defaultClaudeCardID])
        XCTAssertEqual(retained.first?.authStore.expectedIdentityKey, "account-b")

        let signedOut = DefaultAccountObserver(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: FakeKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let afterLogout = ProviderAccountAssembly.make(
            observer: signedOut, accountsStore: store, claudeDiscovery: discovery
        )
        let remaining = ProviderCatalog.make(
            claudeCards: afterLogout.claudeCards,
            defaultClaudeCardID: afterLogout.defaultClaudeCardID,
            claudeIdentityKeys: afterLogout.identityKeysByCard
        ).compactMap { $0 as? ClaudeProvider }

        XCTAssertEqual(remaining.map { $0.provider.id }, ["claude"])
        XCTAssertEqual(remaining.first?.authStore.scope, .configDir(path: path, keychainLiteral: path))
        XCTAssertNil(afterLogout.identityKeysByCard[assembly.defaultClaudeCardID])
    }

    func testNothingObservedLeavesRegistryAndKeysEmpty() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertTrue(assembly.identityKeysByCard.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(defaults.data(forKey: ProviderAccountsStore.storageKey), "no observations, no write")
    }
}
