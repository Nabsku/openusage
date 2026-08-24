import XCTest
@testable import OpenUsage

@MainActor
final class ProviderAccountsStoreTests: XCTestCase {
    private struct LegacyMirrorRecord: Codable {
        struct Source: Codable {
            enum Kind: String, Codable { case defaultHome }

            var kind: Kind
            var anchor: String?
            var holdsDefaultSource: Bool
        }

        var id: String
        var family: String
        var identityKey: String
        var label: String?
        var sources: [Source]
        var removedTombstone: Bool
    }

    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderAccounts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func defaultHomeObservation(
        family: String,
        identityKey: String,
        label: String? = nil,
        anchor: String = "/Users/dev/.claude"
    ) -> ProviderAccountsStore.AccountObservation {
        ProviderAccountsStore.AccountObservation(
            family: family,
            identityKey: identityKey,
            label: label,
            sources: [ProviderAccountSource(kind: .defaultHome, anchor: anchor, holdsDefaultSource: true)]
        )
    }

    private func sideObservation(
        _ identityKey: String,
        label: String? = nil,
        kind: ProviderAccountSource.Kind = .desktop,
        anchor: String? = nil,
        keychainLiteral: String? = nil
    ) -> ProviderAccountsStore.AccountObservation {
        ProviderAccountsStore.AccountObservation(
            family: "claude", identityKey: identityKey, label: label,
            sources: [ProviderAccountSource(
                kind: kind, anchor: anchor, holdsDefaultSource: false, keychainLiteral: keychainLiteral
            )]
        )
    }

    func testFirstAccountOfAFamilyGetsTheBareID() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())

        let records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com"),
        ])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "claude", "the migration-killing rule: the first account IS the existing card")
        XCTAssertEqual(records[0].identityKey, "acct-a")
        XCTAssertEqual(records[0].label, "a@example.com")
        XCTAssertTrue(records[0].sources.contains(where: \.holdsDefaultSource))
    }

    func testSwappedDefaultMintsAHashIDAndTakesTheBadge() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a")])

        let records = store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-b")])

        XCTAssertEqual(records.count, 2, "the swapped-out account's record survives")
        let old = records.first { $0.identityKey == "acct-a" }
        let new = records.first { $0.identityKey == "acct-b" }
        XCTAssertEqual(old?.id, "claude", "the original keeps its minted id")
        XCTAssertEqual(new?.id, ProviderAccountID.make(family: "claude", identityKey: "acct-b"))
        XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.identityKey, "acct-b")
        XCTAssertEqual(old?.sources.contains(where: \.holdsDefaultSource), false, "the badge is exclusive per family")
    }

    func testRenamingCodexRuntimeUpdatesOnlyItsCurrentAccountAndSurvivesSwitchBack() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [defaultHomeObservation(family: "codex", identityKey: "account-a", label: "alice@example.com")])
        store.rename(cardID: "codex", to: "Alice")
        store.reconcile(with: [defaultHomeObservation(family: "codex", identityKey: "account-b", label: "bob@example.com")])

        let active = try XCTUnwrap(store.runtimeRecord(for: "codex"))
        XCTAssertEqual(active.identityKey, "account-b")
        XCTAssertNotEqual(active.id, "codex", "the runtime alias keeps permanent account ids")
        XCTAssertEqual(store.derivedDisplayName(cardID: "codex"), "Codex — bob@example.com")
        store.rename(cardID: "codex", to: "Bob")

        let accountBID = try XCTUnwrap(store.runtimeRecord(for: "codex")?.id)
        XCTAssertEqual(store.record(for: "codex")?.customLabel, "Alice")
        XCTAssertEqual(store.record(for: accountBID)?.customLabel, "Bob")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "codex"), "Bob")
        XCTAssertEqual(store.resolvedDisplayNamesByCardID["codex"], "Bob")
        XCTAssertEqual(ProviderAccountsStore(defaults: defaults).record(for: accountBID)?.customLabel, "Bob")

        store.reconcile(with: [defaultHomeObservation(family: "codex", identityKey: "account-a", label: "alice@example.com")])

        XCTAssertEqual(store.runtimeRecord(for: "codex")?.identityKey, "account-a")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "codex"), "Alice")
        XCTAssertEqual(store.record(for: accountBID)?.customLabel, "Bob")
    }

    func testUnverifiedCodexRuntimeCannotBorrowAPreviousAccountsName() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [defaultHomeObservation(family: "codex", identityKey: "account-a", label: "alice@example.com")])
        store.rename(cardID: "codex", to: "Alice")
        store.clearDefaultSource(family: "codex")

        XCTAssertNil(store.runtimeRecord(for: "codex"))
        XCTAssertNil(store.resolvedDisplayName(cardID: "codex"))
        XCTAssertNil(store.resolvedDisplayNamesByCardID["codex"])

        store.rename(cardID: "codex", to: "Another Account")
        XCTAssertEqual(store.record(for: "codex")?.customLabel, "Alice")
    }

    func testOrganizationAppearingOrDisappearingPreservesTheCardAliasesAndCustomName() {
        for (previous, current) in [("acct-a", "acct-a|org-work"), ("acct-a|org-work", "acct-a")] {
            let defaults = makeScratchDefaults()
            let store = ProviderAccountsStore(defaults: defaults)
            store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: previous)])
            store.rename(cardID: "claude", to: "My Claude")

            let records = store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: current)])

            XCTAssertEqual(records.count, 1, "\(previous) → \(current)")
            XCTAssertEqual(records.first?.id, "claude")
            XCTAssertEqual(records.first?.identityKey, current)
            XCTAssertEqual(records.first?.identityAliases, [previous])
            XCTAssertEqual(records.first?.customLabel, "My Claude")
            XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.id, "claude")
            let reloaded = ProviderAccountsStore(defaults: defaults)
            XCTAssertEqual(reloaded.record(for: "claude")?.identityKey, current)
            XCTAssertEqual(reloaded.record(for: "claude")?.identityAliases, [previous])
            XCTAssertEqual(reloaded.resolvedDisplayName(cardID: "claude"), "My Claude")
        }
    }

    func testExplicitOrRememberedOrganizationsNeverShareAnAccountCard() {
        for droppedOrganization in [false, true] {
            let store = ProviderAccountsStore(defaults: makeScratchDefaults())
            store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a|org-work")])
            store.rename(cardID: "claude", to: "Work")
            if droppedOrganization {
                store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a")])
            }

            let records = store.reconcile(with: [
                defaultHomeObservation(family: "claude", identityKey: "acct-a|org-personal")
            ])

            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(store.record(for: "claude")?.identityKey,
                           droppedOrganization ? "acct-a" : "acct-a|org-work")
            XCTAssertEqual(store.record(for: "claude")?.customLabel, "Work")
            XCTAssertEqual(records.first { $0.identityKey == "acct-a|org-personal" }?.id,
                           ProviderAccountID.make(family: "claude", identityKey: "acct-a|org-personal"))
            if droppedOrganization {
                XCTAssertEqual(store.record(for: "claude")?.identityAliases, ["acct-a|org-work"])
            }
        }
    }

    func testOrganizationLessObservationIsQuarantinedWhenMultipleOrganizationsExist() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a|org-work"),
            sideObservation("acct-a|org-personal"),
        ])
        let original = store.records

        let records = store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a")])

        XCTAssertEqual(records, original, "an unidentified organization must not claim either account")
        XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.identityKey, "acct-a|org-work")
    }

    func testMultipleIncomingOrganizationsCannotClaimAnExistingOrganizationLessAccount() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a")])

        let records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a|org-work"),
            sideObservation("acct-a|org-personal"),
        ])

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(store.record(for: "claude")?.identityKey, "acct-a")
        XCTAssertNotNil(records.first { $0.identityKey == "acct-a|org-work" })
        XCTAssertNotNil(records.first { $0.identityKey == "acct-a|org-personal" })
    }

    func testUnobservedFamilyIsLeftUntouched() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [defaultHomeObservation(family: "codex", identityKey: "acct-c")])

        // A launch that could not observe codex (logged out, unreadable identity) reports nothing.
        let records = store.reconcile(with: [])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(store.defaultBadgeHolder(family: "codex")?.identityKey, "acct-c")
    }

    func testReconcileUpdatesLabelButKeepsItWhenObservationHasNone() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com")])

        var records = store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a")])
        XCTAssertEqual(records[0].label, "a@example.com", "a label-less observation must not erase the known label")

        records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@new.example.com"),
        ])
        XCTAssertEqual(records[0].label, "a@new.example.com")
    }

    func testTombstonedRecordIsNeverResurrected() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "old")])
        // Simulate a future "Remove Account…" by tombstoning the persisted record directly.
        var records = store.records
        records[0].removedTombstone = true
        defaults.set(try! JSONEncoder().encode(records), forKey: ProviderAccountsStore.storageKey)

        let reloaded = ProviderAccountsStore(defaults: defaults)
        let after = reloaded.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "new"),
        ])

        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].label, "old", "a tombstoned account ignores rescan observations")
        XCTAssertNil(reloaded.defaultBadgeHolder(family: "claude"), "a tombstoned record never answers the badge")
    }

    func testRecordsPersistAcrossInstances() {
        let defaults = makeScratchDefaults()
        ProviderAccountsStore(defaults: defaults).reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com"),
            defaultHomeObservation(family: "codex", identityKey: "acct-c", anchor: "/Users/dev/.codex"),
        ])

        let reloaded = ProviderAccountsStore(defaults: defaults)

        XCTAssertEqual(reloaded.records.count, 2)
        XCTAssertEqual(reloaded.defaultBadgeHolder(family: "claude")?.label, "a@example.com")
        XCTAssertEqual(reloaded.defaultBadgeHolder(family: "codex")?.sources.first?.anchor, "/Users/dev/.codex")
    }

    func testUndecodableRegistryStartsFresh() {
        let defaults = makeScratchDefaults()
        defaults.set(Data("not json".utf8), forKey: ProviderAccountsStore.storageKey)

        XCTAssertTrue(ProviderAccountsStore(defaults: defaults).records.isEmpty)
    }

    func testRenamePersistsAndFollowsTheAccountAcrossSourceChanges() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "old@example.com")])
        store.rename(cardID: "claude", to: "  Personal  ")

        let records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-b"),
            sideObservation(
                "acct-a", label: "new@example.com", kind: .configDir,
                anchor: "/Users/dev/.claude-personal", keychainLiteral: "~/.claude-personal"
            ),
        ])

        let original = records.first { $0.id == "claude" }
        XCTAssertEqual(original?.identityKey, "acct-a")
        XCTAssertEqual(original?.sources.map(\.kind), [.configDir])
        XCTAssertEqual(original?.sources.first?.keychainLiteral, "~/.claude-personal")
        XCTAssertEqual(original?.customLabel, "Personal")
        XCTAssertEqual(store.runtimeRecord(for: "claude")?.identityKey, "acct-a")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Personal")
        XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.identityKey, "acct-b")
        XCTAssertEqual(
            ProviderAccountsStore(defaults: defaults).record(for: "claude")?.customLabel,
            "Personal"
        )
        store.rename(cardID: "claude", to: "   ")
        XCTAssertNil(store.record(for: "claude")?.customLabel)
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Claude — new@example.com")
    }

    func testAccountNamesKeepTheBareTitleUntilAnotherOrganizationAppears() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            defaultHomeObservation(
                family: "claude",
                identityKey: "acct-work|org-work",
                label: "rob@example.com (SUNSTORY)"
            ),
        ])

        XCTAssertEqual(store.derivedDisplayName(cardID: "claude"), "Claude")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Claude")
        store.reconcile(with: [
            defaultHomeObservation(
                family: "claude",
                identityKey: "acct-work|org-work",
                label: "rob@example.com (SUNSTORY)"
            ),
            sideObservation("acct-personal|org-personal", label: "rob@example.com (rob@example.com's Organization)"),
        ])

        let personal = try XCTUnwrap(store.records.first { $0.id != "claude" })
        XCTAssertEqual(store.derivedDisplayName(cardID: "claude"), "Claude — SUNSTORY")
        XCTAssertEqual(store.derivedDisplayName(cardID: personal.id), "Claude — Personal")
        XCTAssertEqual(store.resolvedDisplayNamesByCardID[personal.id], "Claude — Personal")
        store.reconcile(with: [
            sideObservation("acct-other|org-other", label: "other@example.com (SUNSTORY)"),
        ])

        let duplicate = try XCTUnwrap(store.records.first { $0.identityKey == "acct-other|org-other" })
        XCTAssertNotEqual(store.derivedDisplayName(cardID: "claude"), store.derivedDisplayName(cardID: duplicate.id))
        store.rename(cardID: "claude", to: "My Custom Name")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "My Custom Name")
        XCTAssertEqual(store.resolvedDisplayName(cardID: duplicate.id), "Claude — SUNSTORY")
    }

    func testUnknownSourceKindsSurviveDecodeAndReconciliation() throws {
        let defaults = makeScratchDefaults()
        let persisted = #"[{"id":"claude","family":"claude","identityKey":"acct-a","label":"Personal","sources":[{"kind":"futureVault","anchor":"vault-a","holdsDefaultSource":false}],"removedTombstone":false}]"#
        defaults.set(Data(persisted.utf8), forKey: ProviderAccountsStore.storageKey)
        let store = ProviderAccountsStore(defaults: defaults)

        XCTAssertEqual(store.records.count, 1, "a forward source must not wipe the entire registry")
        XCTAssertEqual(store.records[0].sources.first?.kind.rawValue, "futureVault")

        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a")])

        let reloaded = ProviderAccountsStore(defaults: defaults)
        XCTAssertEqual(
            Set(reloaded.records[0].sources.map(\.kind.rawValue)),
            ["defaultHome", "futureVault"]
        )
        XCTAssertEqual(reloaded.records[0].sources.last?.anchor, "vault-a")
    }

    func testConfigDirectoryOnlyAccountDoesNotClaimReservedBareID() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let records = store.reconcile(with: [
            sideObservation("acct-side", kind: .configDir, anchor: "/Users/dev/.claude-side")
        ])

        XCTAssertEqual(records.first?.id, ProviderAccountID.make(family: "claude", identityKey: "acct-side"))
    }

    func testLegacyRegistryMigratesToV2AndRepairsDowngradeMirrorWithoutLosingNames() throws {
        let defaults = makeScratchDefaults()
        let unsafeLegacy = #"[{"id":"claude","family":"claude","identityKey":"acct-a|org-a","label":"a@example.com","customLabel":"Personal","sources":[{"kind":"defaultHome","anchor":"/Users/dev/.claude","holdsDefaultSource":true},{"kind":"configDir","anchor":"/Users/dev/.claude-side","holdsDefaultSource":false,"keychainLiteral":"~/.claude-side"}],"removedTombstone":false},{"id":"claude@12345678","family":"claude","identityKey":"acct-b|org-b","label":"b@example.com","customLabel":"Work","sources":[{"kind":"desktop","anchor":null,"holdsDefaultSource":false}],"removedTombstone":false}]"#
        defaults.set(Data(unsafeLegacy.utf8), forKey: ProviderAccountsStore.legacyStorageKey)

        let migrated = ProviderAccountsStore(defaults: defaults)

        XCTAssertEqual(migrated.records.count, 2)
        XCTAssertEqual(migrated.record(for: "claude")?.customLabel, "Personal")
        XCTAssertEqual(migrated.record(for: "claude@12345678")?.customLabel, "Work")
        XCTAssertNotNil(defaults.data(forKey: ProviderAccountsStore.storageKey))

        let mirrorData = try XCTUnwrap(defaults.data(forKey: ProviderAccountsStore.legacyStorageKey))
        let downgradeRecords = try JSONDecoder().decode([LegacyMirrorRecord].self, from: mirrorData)
        XCTAssertEqual(downgradeRecords.count, 2)
        XCTAssertEqual(downgradeRecords[0].sources.map(\.kind), [.defaultHome])
        XCTAssertTrue(downgradeRecords[1].sources.isEmpty)

        // An old release may rewrite its own mirror; v2 remains authoritative on re-upgrade.
        defaults.set(try JSONEncoder().encode([downgradeRecords[0]]), forKey: ProviderAccountsStore.legacyStorageKey)
        let upgradedAgain = ProviderAccountsStore(defaults: defaults)
        XCTAssertEqual(upgradedAgain.records.count, 2)
        XCTAssertEqual(upgradedAgain.record(for: "claude@12345678")?.customLabel, "Work")
        XCTAssertEqual(upgradedAgain.record(for: "claude@12345678")?.sources.map(\.kind), [.desktop])
    }

    func testClearingDefaultSourcePreservesAccountAndOtherSources() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [
            ProviderAccountsStore.AccountObservation(
                family: "claude",
                identityKey: "acct-a",
                label: "Personal",
                sources: [
                    ProviderAccountSource(kind: .defaultHome, anchor: "/Users/dev/.claude", holdsDefaultSource: true),
                    ProviderAccountSource(kind: .desktop, anchor: nil, holdsDefaultSource: false),
                ]
            ),
        ])
        store.rename(cardID: "claude", to: "Saved Name")

        store.clearDefaultSource(family: "claude")

        XCTAssertNil(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(store.record(for: "claude")?.sources.map(\.kind), [.desktop])
        XCTAssertEqual(store.record(for: "claude")?.customLabel, "Saved Name")
    }

    func testClaudeIdentityNormalizesAndQuarantinesAmbiguousOrganizations() {
        XCTAssertEqual(ClaudeIdentity("  USER|ORG  ")?.key, "user|org")
        for malformed in ["", "|org", "user|", "user|org|another", "user name"] {
            XCTAssertNil(ClaudeIdentity(malformed), malformed)
        }
        let orgless = ClaudeIdentity("user")!
        let scoped = ClaudeIdentity("user|org")!
        XCTAssertEqual(ClaudeIdentity.canonical(orgless, among: [orgless, scoped]), scoped)
        XCTAssertNil(ClaudeIdentity.canonical(orgless, among: [scoped, ClaudeIdentity("user|other")!]))
    }

    func testFamilyHelperSplitsCardIDs() {
        XCTAssertEqual(ProviderAccountID.family(of: "claude"), "claude")
        XCTAssertEqual(ProviderAccountID.family(of: "claude@ab12cd34"), "claude")
        XCTAssertEqual(ProviderAccountID.family(of: "cursor"), "cursor")
    }
}
