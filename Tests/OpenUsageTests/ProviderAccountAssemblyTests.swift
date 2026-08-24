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
        XCTAssertFalse(assembly.isClaudeDiscoveryComplete)
        let unavailable = ProviderAccountAssembly.make(observer: observer, accountsStore: store, families: [])
        XCTAssertFalse(unavailable.isClaudeDiscoveryComplete)
        XCTAssertTrue(unavailable.allowsUnownedClaudeDesktopFallback)
        let runtime = ProviderCatalog.make(
            isClaudeDiscoveryComplete: unavailable.isClaudeDiscoveryComplete,
            allowsUnownedClaudeDesktopFallback: unavailable.allowsUnownedClaudeDesktopFallback
        ).first as? ClaudeProvider
        XCTAssertEqual(runtime?.authStore.allowsDesktopFallback, true)

        for account in ["original-account", "swapped-account"] {
            store.reconcile(with: [.init(
                family: "claude", identityKey: account, label: nil,
                sources: [.init(kind: .defaultHome, anchor: "/Users/dev/.claude", holdsDefaultSource: true)]
            )])
        }
        for families: Set<String> in [["codex"], []] {
            let skipped = ProviderAccountAssembly.make(
                observer: observer, accountsStore: store, families: families
            )
            XCTAssertNotEqual(skipped.defaultClaudeCardID, "claude")
            XCTAssertEqual(skipped.identityKeysByCard[skipped.defaultClaudeCardID], "swapped-account")
            XCTAssertFalse(skipped.allowsUnownedClaudeDesktopFallback)
            let bound = ProviderCatalog.make(
                defaultClaudeCardID: skipped.defaultClaudeCardID,
                claudeIdentityKeys: skipped.identityKeysByCard,
                isClaudeDiscoveryComplete: skipped.isClaudeDiscoveryComplete,
                allowsUnownedClaudeDesktopFallback: skipped.allowsUnownedClaudeDesktopFallback
            ).first as? ClaudeProvider
            XCTAssertEqual(bound?.authStore.expectedIdentityKey, "swapped-account")
            XCTAssertEqual(bound?.authStore.allowsDesktopFallback, false)
        }
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
        XCTAssertEqual(card.credential, .configDir(path: "/Users/dev/.claude-work", keychainLiteral: "/Users/dev/.claude-work"))
        XCTAssertEqual(card.logRoots.map(\.path), ["/Users/dev/.claude-work"])
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
        XCTAssertFalse(assembly.isClaudeDiscoveryComplete)
        let runtime = ProviderCatalog.make(
            isClaudeDiscoveryComplete: assembly.isClaudeDiscoveryComplete
        ).first as? ClaudeProvider
        XCTAssertEqual(runtime?.authStore.allowsDesktopFallback, false)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testCanonicalAccountAliasRetainsTheSameCardWithObservedCredentialOwnership() throws {
        let defaults = makeScratchDefaults()
        let existing = ProviderAccountRecord(
            id: "claude", family: "claude", identityKey: "acct-1|org-1",
            identityAliases: ["acct-1"], label: "Work", customLabel: "My Work Account",
            sources: [.init(kind: .defaultHome, anchor: "/Users/dev/.claude", holdsDefaultSource: true)]
        )
        defaults.set(try JSONEncoder().encode([existing]), forKey: ProviderAccountsStore.storageKey)
        let store = ProviderAccountsStore(defaults: defaults)
        let defaultFiles = FakeFiles(["/Users/dev/.claude.json":
            #"{"oauthAccount":{"accountUuid":"ACCT-1"}}"#])
        let observer = DefaultAccountObserver(
            files: defaultFiles,
            keychain: FakeKeychain(), homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCT-1","organizationUuid":"ORG-1"}}"#,
                "/Users/dev/.claude-work/.credentials.json":
                    #"{"claudeAiOauth":{"accessToken":"same-account"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )
        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        XCTAssertEqual(store.records.map(\.id), ["claude"])
        XCTAssertEqual(assembly.identityKeysByCard["claude"], "acct-1|org-1")
        XCTAssertEqual(assembly.defaultClaudeVerifiedIdentityAliases, [try XCTUnwrap(ClaudeIdentity("acct-1"))])
        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertEqual(assembly.defaultClaudeExtraLogRoots.map(\.path), ["/Users/dev/.claude-work"])
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "My Work Account")

        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "alias-cache")
        cache.store(ProviderSnapshot(providerID: "claude", displayName: "Claude", lines: []),
                    producedByIdentityKey: existing.identityKey)
        XCTAssertFalse(cache.hasStaleAccountStamp(
            providerID: "claude", currentIdentityKey: assembly.identityKeysByCard["claude"]
        ))

        let runtime = try XCTUnwrap(ProviderCatalog.make(
            defaultClaudeVerifiedIdentityAliases: assembly.defaultClaudeVerifiedIdentityAliases,
            claudeIdentityKeys: assembly.identityKeysByCard
        ).first as? ClaudeProvider)
        var auth = runtime.authStore
        auth.files = defaultFiles
        auth.homeDirectory = { URL(fileURLWithPath: "/Users/dev") }
        XCTAssertTrue(auth.belongsToExpectedAccount())
        defaultFiles.files["/Users/dev/.claude.json"] =
            #"{"oauthAccount":{"accountUuid":"ACCT-1","organizationUuid":"OTHER"}}"#
        XCTAssertFalse(auth.belongsToExpectedAccount(), "an unverified organization must stay isolated")
    }

    func testAliasedConfigDirectoriesProduceOneStableNonDefaultAccountCard() throws {
        let defaults = makeScratchDefaults()
        let records = [
            ProviderAccountRecord(
                id: "claude", family: "claude", identityKey: "default", label: nil,
                sources: [.init(kind: .defaultHome, anchor: "/Users/dev/.claude", holdsDefaultSource: true)]
            ),
            ProviderAccountRecord(
                id: "claude@work", family: "claude", identityKey: "work|org",
                identityAliases: ["work"], label: "Work", sources: []
            ),
        ]
        defaults.set(try JSONEncoder().encode(records), forKey: ProviderAccountsStore.storageKey)
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            files: FakeFiles(["/Users/dev/.claude.json":
                #"{"oauthAccount":{"accountUuid":"default"}}"#]),
            keychain: FakeKeychain(), homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let paths = ["/Users/dev/.claude-work-a", "/Users/dev/.claude-work-b"]
        let discovery = makeDiscovery(files: [
            paths[0] + "/.claude.json": #"{"oauthAccount":{"accountUuid":"work"}}"#,
            paths[1] + "/.claude.json": #"{"oauthAccount":{"accountUuid":"work","organizationUuid":"org"}}"#,
            paths[0] + "/.credentials.json": #"{"claudeAiOauth":{"accessToken":"a"}}"#,
            paths[1] + "/.credentials.json": #"{"claudeAiOauth":{"accessToken":"b"}}"#,
        ], subdirectories: paths)

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertEqual(assembly.claudeCards.map(\.id), ["claude@work"])
        XCTAssertEqual(card.identityKey, "work|org")
        XCTAssertEqual(assembly.identityKeysByCard[card.id], "work|org")
        XCTAssertEqual(card.verifiedIdentityAliases, [try XCTUnwrap(ClaudeIdentity("work"))])

        let runtime = try XCTUnwrap(ProviderCatalog.make(
            claudeCards: assembly.claudeCards,
            claudeIdentityKeys: assembly.identityKeysByCard
        ).first { $0.provider.id == card.id } as? ClaudeProvider)
        var auth = runtime.authStore
        auth.files = FakeFiles([paths[0] + "/.claude.json":
            #"{"oauthAccount":{"accountUuid":"work"}}"#])
        XCTAssertTrue(auth.belongsToExpectedAccount())
        auth.files = FakeFiles([paths[0] + "/.claude.json":
            #"{"oauthAccount":{"accountUuid":"work","organizationUuid":"other"}}"#])
        XCTAssertFalse(auth.belongsToExpectedAccount(), "aliases from other organizations are never authorized")
    }

    func testKnownDefaultLogoutKeepsVerifiedAccountsWithoutAnUnboundFallback() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [.init(
            family: "claude", identityKey: "previous", label: nil,
            sources: [.init(kind: .defaultHome, anchor: "/Users/dev/.claude", holdsDefaultSource: true)]
        )])
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(),
            files: FakeFiles([
                "/Users/dev/.claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"stale"}}"#,
            ]),
            keychain: FakeKeychain(), homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let work = "/Users/dev/.claude-work"
        let discovery = makeDiscovery(files: [
            work + "/.claude.json": #"{"oauthAccount":{"accountUuid":"work"}}"#,
            work + "/.credentials.json": #"{"claudeAiOauth":{"accessToken":"work-token"}}"#,
        ], subdirectories: [work])

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )
        let providers = ProviderCatalog.make(
            claudeCards: assembly.claudeCards, claudeIdentityKeys: assembly.identityKeysByCard,
            allowsUnboundClaudeFallback: assembly.allowsUnboundClaudeFallback,
            defaultClaudeDesktopAccess: assembly.defaultClaudeDesktopAccess
        ).filter { ProviderAccountID.family(of: $0.provider.id) == "claude" }

        XCTAssertNil(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(providers.map { $0.provider.id }, [try XCTUnwrap(assembly.claudeCards.first).id])
        XCTAssertFalse(assembly.allowsUnboundClaudeFallback)
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

    // MARK: - Cowork sandboxes

    private let coworkBase = "/Users/dev/Library/Application Support/Claude/local-agent-mode-sessions/g/s"

    private func makeCoworkDiscovery(
        files: [String: String],
        sandboxes: [String]
    ) -> ClaudeCoworkDiscovery {
        ClaudeCoworkDiscovery(
            files: FakeFiles(files),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSandboxes: { _ in sandboxes.map { URL(fileURLWithPath: $0) } }
        )
    }

    private func makeDefaultResolvedObserver() -> DefaultAccountObserver {
        DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCT-1","organizationUuid":"ORG-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
    }

    func testOrganizationlessConfigLoginCarriesOnlyItsVerifiedIdentityAlias() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let path = "/Users/dev/.claude-work"
        let sandbox = "\(coworkBase)/local_work/.claude"
        let config = makeDiscovery(files: [
            path + "/.claude.json": #"{"oauthAccount":{"accountUuid":"work-user"}}"#,
            path + "/.credentials.json": #"{"claudeAiOauth":{"accessToken":"work"}}"#,
        ], subdirectories: [path])
        let cowork = makeCoworkDiscovery(files: [
            sandbox + "/.claude.json":
                #"{"oauthAccount":{"accountUuid":"work-user","organizationUuid":"work-org"}}"#,
        ], sandboxes: [sandbox])

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(), accountsStore: store,
            claudeDiscovery: config, coworkDiscovery: cowork
        )
        let card = try XCTUnwrap(assembly.claudeCards.first)
        let provider = try XCTUnwrap(ProviderCatalog.make(
            claudeCards: assembly.claudeCards,
            claudeIdentityKeys: assembly.identityKeysByCard,
            defaultClaudeDesktopAccess: assembly.defaultClaudeDesktopAccess
        ).compactMap { $0 as? ClaudeProvider }.first { $0.provider.id == card.id })

        XCTAssertEqual(card.identityKey, "work-user|work-org")
        XCTAssertEqual(card.verifiedIdentityAliases, [try XCTUnwrap(ClaudeIdentity("work-user"))])
        XCTAssertEqual(provider.authStore.verifiedIdentityAliases, card.verifiedIdentityAliases)
    }

    func testDefaultAccountSandboxesLeaveTheBuiltInCoworkWalkUntouched() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let sandbox = "\(coworkBase)/local_1/.claude"
        let cowork = makeCoworkDiscovery(
            files: [sandbox + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#],
            sandboxes: [sandbox]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(), accountsStore: store, coworkDiscovery: cowork
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertNil(assembly.defaultClaudeCoworkRoots, "no partition — the scanner's built-in walk stays byte-identical")
    }

    func testIncompleteCoworkWalkCannotCreateCardsOrMisattributeSpend() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let sandbox = "\(coworkBase)/local_1/.claude"
        let cowork = ClaudeCoworkDiscovery(
            files: FakeFiles([
                sandbox + "/.claude.json":
                    #"{"oauthAccount":{"accountUuid":"ACCT-2","organizationUuid":"ORG-2"}}"#,
            ]),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSandboxes: { _ in [URL(fileURLWithPath: sandbox)] },
            timeBudget: -1
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(), accountsStore: store, coworkDiscovery: cowork
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertEqual(assembly.defaultClaudeCoworkRoots, [])
        XCTAssertEqual(assembly.defaultClaudeDesktopAccess, .pinned("org-1"))
        XCTAssertEqual(store.records.count, 1)
    }

    func testADistinctCoworkAccountBecomesOneDesktopBackedCardAndPartitionsTheWalk() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let mine = "\(coworkBase)/local_1/.claude"
        let theirsA = "\(coworkBase)/local_2/.claude"
        let theirsB = "\(coworkBase)/local_3/.claude"
        let identity = #"{"oauthAccount": {"accountUuid": "ACCT-2", "organizationUuid": "ORG-2", "organizationName": "Sunstory"}}"#
        let cowork = makeCoworkDiscovery(
            files: [
                mine + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                theirsA + "/.claude.json": identity,
                theirsB + "/.claude.json": identity,
            ],
            sandboxes: [mine, theirsA, theirsB]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(), accountsStore: store, coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertEqual(assembly.claudeCards.count, 1, "several sandboxes of one account are ONE card")
        XCTAssertEqual(card.credential, .desktop(organization: "org-2"))
        XCTAssertEqual(card.displayName, "Claude — Sunstory")
        XCTAssertEqual(card.logRoots.map(\.path), [theirsA, theirsB])
        XCTAssertEqual(assembly.identityKeysByCard[card.id], "acct-2|org-2")
        XCTAssertEqual(assembly.defaultClaudeCoworkRoots?.map(\.path), [mine], "the default card keeps exactly its own sandboxes")
        let record = try XCTUnwrap(store.records.first { $0.id == card.id })
        XCTAssertEqual(record.sources.map(\.kind), [.desktop])
    }

    func testCoworkSandboxesOfAConfigDirAccountAttachAsItsLogRoots() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let sandbox = "\(coworkBase)/local_1/.claude"
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "organizationUuid": "ORG-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )
        let cowork = makeCoworkDiscovery(
            files: [sandbox + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "organizationUuid": "ORG-2"}}"#],
            sandboxes: [sandbox]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(),
            accountsStore: store,
            claudeDiscovery: discovery,
            coworkDiscovery: cowork
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertEqual(assembly.claudeCards.count, 1, "the sandbox joins the config-dir card instead of minting a second one")
        XCTAssertEqual(card.credential, .configDir(path: "/Users/dev/.claude-work", keychainLiteral: "/Users/dev/.claude-work"))
        XCTAssertEqual(card.logRoots.map(\.path), ["/Users/dev/.claude-work", sandbox])
        XCTAssertEqual(assembly.defaultClaudeCoworkRoots?.map(\.path), [], "the other account's sandbox leaves the default walk")
    }

    func testADistinctCoworkAccountWithoutAnOrgPinGetsNoCardButStaysOutOfTheDefaultWalk() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let sandbox = "\(coworkBase)/local_1/.claude"
        let cowork = makeCoworkDiscovery(
            // An account UUID but no org: Desktop caches tokens per org, so there is no safe
            // credential pin for a card.
            files: [sandbox + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-3"}}"#],
            sandboxes: [sandbox]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(), accountsStore: store, coworkDiscovery: cowork
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertEqual(
            assembly.defaultClaudeCoworkRoots?.map(\.path), [],
            "another account's sessions must still not bleed into the default card's spend"
        )
        XCTAssertEqual(store.records.count, 1, "only the default account has a record")
    }

    func testAnUnidentifiedSandboxIsQuarantinedWhenMultipleAccountsExist() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let nameless = "\(coworkBase)/local_1/.claude"
        let theirs = "\(coworkBase)/local_2/.claude"
        let cowork = makeCoworkDiscovery(
            files: [theirs + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "organizationUuid": "ORG-2"}}"#],
            sandboxes: [nameless, theirs]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: makeDefaultResolvedObserver(), accountsStore: store, coworkDiscovery: cowork,
            hasDesktopCredentialMaterial: { true }
        )

        XCTAssertEqual(assembly.claudeCards.count, 1)
        XCTAssertEqual(
            assembly.defaultClaudeCoworkRoots?.map(\.path), [],
            "an unidentified sandbox cannot safely be attributed when multiple accounts exist"
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
        XCTAssertEqual(card.credential, .configDir(path: previous, keychainLiteral: previous))
        XCTAssertEqual(card.logRoots.map(\.path), [previous, earlier])
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
        XCTAssertEqual(provider.authStore.desktopAccessPolicy, .denied)
        XCTAssertFalse(provider.allowsUnattributedPiUsage)
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
        XCTAssertEqual(originalCard.credential, .configDir(path: path, keychainLiteral: path))
        XCTAssertEqual(originalCard.displayName, "Claude")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Personal")
        XCTAssertNotEqual(assembly.defaultClaudeCardID, "claude")
        XCTAssertEqual(assembly.identityKeysByCard["claude"], "account-a")
        XCTAssertEqual(assembly.identityKeysByCard[assembly.defaultClaudeCardID], "account-b")

        let runtimes = ProviderCatalog.make(
            claudeCards: assembly.claudeCards,
            defaultClaudeExtraLogRoots: assembly.defaultClaudeExtraLogRoots,
            defaultClaudeDisplayName: assembly.defaultClaudeDisplayName,
            defaultClaudeCardID: assembly.defaultClaudeCardID,
            claudeIdentityKeys: assembly.identityKeysByCard
        ).compactMap { $0 as? ClaudeProvider }
        XCTAssertEqual(runtimes.first?.provider.id, "claude")
        XCTAssertEqual(runtimes.first?.authStore.scope,
                       .configDir(path: path, keychainLiteral: path))
        XCTAssertEqual(runtimes.last?.provider.id, assembly.defaultClaudeCardID)
        XCTAssertEqual(runtimes.last?.authStore.scope, .standard)
        XCTAssertEqual(runtimes.last?.allowsUnattributedPiUsage, false)
        XCTAssertEqual((ProviderCatalog.make().first as? ClaudeProvider)?.allowsUnattributedPiUsage, true)

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
