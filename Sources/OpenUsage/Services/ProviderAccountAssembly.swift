import Foundation

/// One extra Claude account card to build this launch: a login found on this computer whose account
/// is distinct from the default card's — a custom-config-dir login, or a Claude Desktop (Cowork)
/// login. Cards render only while their source is found (owner decision 4) — a record with no
/// finding this launch simply builds no card.
struct ClaudeAccountCard: Equatable, Sendable {
    /// Where the card's credentials come from (its spend logs are `logRoots`, kept separate —
    /// a Desktop-backed card's logs are Cowork sandboxes, not a credential home).
    enum Credential: Equatable, Sendable {
        /// One custom `CLAUDE_CONFIG_DIR` home; `keychainLiteral` names the dir's keychain item
        /// (see `ClaudeCredentialScope.configDir`).
        case configDir(path: String, keychainLiteral: String)
        /// Claude Desktop's Safe Storage cache, pinned to this org's token
        /// (see `ClaudeCredentialScope.desktopOnly`).
        case desktop(organization: String)
    }

    /// The account's stable record id (`claude@ab12cd34`) — the card id everywhere: layout, cache,
    /// CLI/API matching.
    var id: String
    /// The DERIVED card name (`ProviderAccountRecord.derivedDisplayName`) baked into the launch
    /// `Provider`. Never a rename: renames live only in the account registry and are resolved at
    /// render time, so a baked name can never be a stale copy of one.
    var displayName: String
    var identityKey: String
    var credential: Credential
    /// Every spend-log root the card scans: its config dir(s), plus any Cowork sandboxes this
    /// account produced.
    var logRoots: [URL]
    /// Only identities observed at this card's verified credential source may authorize aliases.
    var verifiedIdentityAliases: Set<String> = []
}

/// The launch-time account pass: read which account is signed in at each family's default home,
/// scan for extra Claude logins in custom config dirs, reconcile the account registry, and expose
/// what the rest of launch consumes — the per-card identity map (snapshot-cache account stamp) and
/// the extra-card build plan (`ProviderCatalog`). Runs once per launch (app) or per invocation
/// (one-shot CLI); a mid-run swap is caught on the next launch.
@MainActor
struct ProviderAccountAssembly {
    /// Card id → the account identity signed in there this launch. A card whose identity didn't
    /// resolve is absent.
    let identityKeysByCard: [String: String]
    /// Extra Claude account cards found on this computer this launch, in stable id order.
    var claudeCards: [ClaudeAccountCard] = []
    /// Same-account custom config dirs discovered for the DEFAULT card's login: extra spend-log
    /// roots for the default scanner, never extra credentials.
    var defaultClaudeExtraLogRoots: [URL] = []
    /// The default account's derived title; custom names are resolved at presentation boundaries.
    var defaultClaudeDisplayName: String?
    /// Identity observed at the verified default source, even when its record uses another alias.
    var defaultClaudeVerifiedIdentityAliases: Set<String> = []
    /// The default runtime follows its account record, even when another account keeps `claude`.
    var defaultClaudeCardID = "claude"
    /// A generic runtime is safe only before any Claude account has ever been identified.
    var allowsUnboundClaudeFallback = true
    /// An incomplete scan cannot prove that an unpinned Desktop login belongs to the default card.
    var isClaudeDiscoveryComplete = true
    /// A first-launch shell delay cannot hide another account when no Claude record exists yet.
    var allowsUnownedClaudeDesktopFallback = false
    /// Set only when another account's Cowork sandboxes exist: the default card's partition of the
    /// Cowork walk (that account's sessions must not bleed into the default card's spend). `nil`
    /// keeps the scanner's built-in walk byte-identical.
    var defaultClaudeCoworkRoots: [URL]?
    var defaultClaudeDesktopAccess: ClaudeDesktopAccessPolicy = .activeOrganization

    /// `waitsForLoginShell`: true for the menu-bar app (a Finder/Dock launch inherits no shell
    /// exports, so the pass leans on the login-shell layers), false for the one-shot CLI (a terminal
    /// launch's process environment already carries the user's exports). The app passes its own
    /// `accountsStore` so the registry the pass reconciles is the same instance the UI observes for
    /// renames; the CLI omits it and gets a throwaway.
    static func make(
        defaults: UserDefaults = .standard,
        accountsStore: ProviderAccountsStore? = nil,
        waitsForLoginShell: Bool
    ) -> ProviderAccountAssembly {
        // The identity read needs the login shell's exports (CLAUDE_CONFIG_DIR/CODEX_HOME name the
        // default homes), and it reads them through the very same reader the provider auth stores
        // use — `ProcessEnvironmentReader`, which pins identity-relevant keys to the persisted
        // shell-environment snapshot for the whole session, so identity and usage resolve the same
        // homes no matter when the async capture lands. The one unreadable state is a genuinely
        // FIRST Finder/Dock launch: capture still cold and no snapshot persisted yet — a
        // shell-exported home override would be invisible, so that family's read must be skipped
        // rather than misread as "no override". The skip is per family: a family whose home override
        // is already visible in the process environment (a terminal launch, `launchctl setenv`)
        // doesn't need the shell layers at all and still resolves.
        let shellFactsReadable = !waitsForLoginShell
            || LoginShellEnvironment.shared.capturedSuccessfully
            || ShellEnvironmentSnapshotStore.launchSnapshot != nil
        let families = shellFactsReadable
            ? ProviderAccountID.families
            : ProviderAccountID.families.filter { family in
                guard let key = Self.homeOverrideKeys[family] else { return false }
                return ProcessInfo.processInfo.environment[key]?.nilIfEmpty != nil
            }
        if families.count < ProviderAccountID.families.count {
            AppLog.info(.config, "account identity read skipped for \(ProviderAccountID.families.subtracting(families).sorted().joined(separator: ", ")): login shell cold and no shell-environment snapshot exists yet")
        }
        let resolvedAccountsStore = accountsStore ?? ProviderAccountsStore(defaults: defaults)
        guard !families.isEmpty else {
            return make(
                observer: DefaultAccountObserver(), accountsStore: resolvedAccountsStore, families: []
            )
        }
        return make(
            observer: DefaultAccountObserver(),
            accountsStore: resolvedAccountsStore,
            families: families,
            claudeDiscovery: ClaudeConfigDirDiscovery(),
            coworkDiscovery: ClaudeCoworkDiscovery()
        )
    }

    /// The environment variable that relocates each family's default home — the fact whose
    /// invisibility (shell layers unreadable AND not in the process environment) makes that family's
    /// identity read unsafe on a first launch.
    private static let homeOverrideKeys: [String: String] = [
        "claude": "CLAUDE_CONFIG_DIR",
        "codex": "CODEX_HOME",
    ]

    /// The environment-independent core, separated so tests inject a fixed observer, discovery, and
    /// scratch store. `families` limits the pass to the families whose home facts are readable this
    /// launch (see `make(defaults:waitsForLoginShell:)`); a family left out is simply not observed —
    /// no identity key, no reconciliation, exactly as if the pass never ran for it. `claudeDiscovery`
    /// is skipped alongside the claude family (its exclusion set needs the same home facts).
    static func make(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        families: Set<String> = ProviderAccountID.families,
        claudeDiscovery: ClaudeConfigDirDiscovery? = nil,
        coworkDiscovery: ClaudeCoworkDiscovery? = nil,
        hasDesktopCredentialMaterial: @Sendable () -> Bool = {
            ClaudeDesktopAuthStore().hasCredentialMaterial()
        }
    ) -> ProviderAccountAssembly {
        var identityKeys: [String: String] = [:]
        var observations: [ProviderAccountsStore.AccountObservation] = []

        let outcomes: [(family: String, outcome: DefaultAccountObserver.Outcome)] = [
            ("claude", { observer.observeClaude() }),
            ("codex", { observer.observeCodex() }),
        ].compactMap { family, observe in
            families.contains(family) ? (family, observe()) : nil
        }
        for (family, outcome) in outcomes {
            switch outcome {
            case .resolved(let identityKey, let label, let anchor):
                identityKeys[family] = identityKey
                observations.append(ProviderAccountsStore.AccountObservation(
                    family: family,
                    identityKey: identityKey,
                    label: label,
                    sources: [ProviderAccountSource(kind: .defaultHome, anchor: anchor, holdsDefaultSource: true)]
                ))
                AppLog.info(.config, "accounts: \(family) default identity resolved (\(ProviderAccountID.make(family: family, identityKey: identityKey)))")
            case .unresolved(let reason):
                // The soak signal for later phases: how often a real login can't name its account.
                AppLog.info(.config, "accounts: \(family) default identity unresolved — \(reason)")
            case .absent:
                AppLog.debug(.config, "accounts: \(family) has no default login")
            }
        }

        // Extra Claude logins in custom config dirs and Cowork sandboxes. Guarded on the default
        // read: when a default login clearly EXISTS but can't be named (`unresolved`), accepting
        // candidates could render the very account the default card shows as a second card — skip
        // them this launch instead. A machine with no default login at all keeps accepting: there
        // is nothing to duplicate, and a custom-dir-only login should still get its card.
        var plannedCards: [PlannedClaudeCard] = []
        var defaultClaudeExtraLogRoots: [URL] = []
        var isClaudeDiscoveryComplete = families.contains("claude")
        let preferredConfigAnchors = Dictionary(uniqueKeysWithValues: accountsStore.records.compactMap { record in
            record.sources.first { $0.kind == .configDir }?.anchor.map { (record.identityKey, $0) }
        })
        var defaultClaudeCoworkRoots: [URL]?
        let claudeOutcome = outcomes.first { $0.family == "claude" }?.outcome
        if case .unresolved = claudeOutcome {
            isClaudeDiscoveryComplete = false
        }
        let hasKnownClaudeAccount = accountsStore.records.contains { $0.family == "claude" }
        var claudeCandidatesAllowed = false
        if let claudeOutcome {
            if case .unresolved = claudeOutcome, !hasKnownClaudeAccount {
                AppLog.info(.config, "discovery: claude default login present but its identity is unreadable → skipping extra-account candidates this launch")
            } else {
                claudeCandidatesAllowed = true
            }
        }
        let configScan = claudeCandidatesAllowed
            ? claudeDiscovery?.run(prioritizing: Set(preferredConfigAnchors.values))
            : nil
        isClaudeDiscoveryComplete = configScan?.truncated != true
        let coworkScan = claudeCandidatesAllowed ? coworkDiscovery?.run() : nil
        let desktopPolicy = ClaudeDesktopAccountPolicy(
            records: accountsStore.records,
            defaultOutcome: claudeOutcome,
            configFindings: configScan?.findings ?? [],
            coworkScan: coworkScan
        )
        if let defaultIdentity = identityKeys["claude"] {
            if let canonical = desktopPolicy.canonical(defaultIdentity) {
                identityKeys["claude"] = canonical
                if let index = observations.firstIndex(where: { $0.family == "claude" }) {
                    observations[index].identityKey = canonical
                }
            } else {
                claudeCandidatesAllowed = false
                defaultClaudeCoworkRoots = []
                AppLog.warn(.config, "discovery: Claude's default account matches multiple organizations; account routing quarantined")
            }
        }
        if let scan = configScan, claudeCandidatesAllowed {
            let defaultKey = identityKeys["claude"]
            for note in scan.notes {
                AppLog.info(.config, "discovery: \(note)")
            }
            var order: [String] = []
            var grouped: [String: [ClaudeConfigDirDiscovery.Finding]] = [:]
            for finding in scan.findings where isClaudeDiscoveryComplete {
                guard let canonical = desktopPolicy.canonical(finding.identityKey) else { continue }
                let records = accountsStore.records.filter {
                    $0.family == "claude"
                        && ($0.matches(identityKey: finding.identityKey)
                            || $0.matches(identityKey: canonical))
                }
                guard records.count <= 1 else {
                    isClaudeDiscoveryComplete = false
                    order.removeAll()
                    grouped.removeAll()
                    break
                }
                let identityKey = records.first?.identityKey ?? canonical
                if grouped[identityKey] == nil { order.append(identityKey) }
                grouped[identityKey, default: []].append(finding)
            }
            for identityKey in order {
                var findings = grouped[identityKey] ?? []
                if let preferred = preferredConfigAnchors[identityKey],
                   let index = findings.firstIndex(where: { $0.anchorPath == preferred }), index != 0
                {
                    findings.insert(findings.remove(at: index), at: 0)
                }
                let sources = findings.map {
                    ProviderAccountSource(
                        kind: .configDir,
                        anchor: $0.anchorPath,
                        holdsDefaultSource: false,
                        keychainLiteral: $0.keychainLiteral
                    )
                }
                let matchesDefault = defaultKey.map { observedDefault in
                    identityKey.caseInsensitiveCompare(observedDefault) == .orderedSame
                        || accountsStore.records.contains {
                            $0.family == "claude"
                                && $0.matches(identityKey: observedDefault)
                                && $0.matches(identityKey: identityKey)
                        }
                } ?? false
                if matchesDefault {
                    // Same account as the default card: its dirs are extra spend-log roots on
                    // that card, never a second card — duplicate cards are structurally
                    // impossible because identity routes the source to the existing record.
                    defaultClaudeExtraLogRoots += findings.map { URL(fileURLWithPath: $0.anchorPath) }
                    if let index = observations.firstIndex(where: {
                        $0.family == "claude" && $0.identityKey == defaultKey
                    }) {
                        observations[index].sources += sources
                    }
                    AppLog.info(.config, "discovery: \(findings.count) config dir(s) fold onto the default claude card (same account)")
                } else {
                    guard let primary = findings.first else { continue }
                    observations.append(ProviderAccountsStore.AccountObservation(
                        family: "claude",
                        identityKey: identityKey,
                        label: primary.label,
                        sources: sources
                    ))
                    plannedCards.append(PlannedClaudeCard(
                        identityKey: identityKey,
                        credential: .configDir(path: primary.anchorPath, keychainLiteral: primary.keychainLiteral),
                        logRoots: findings.map { URL(fileURLWithPath: $0.anchorPath) },
                        verifiedIdentityAliases: [primary.identityKey]
                    ))
                }
            }
        }

        // Cowork sandboxes: identity comes from each session sandbox's own `.claude.json`.
        // Sandboxes naming the default login (the overwhelmingly common case) stay exactly where
        // they are today — on the default card. Sandboxes naming an account already found in a
        // config dir become that card's extra log roots. A distinct account becomes ONE
        // Desktop-backed card (org-pinned Safe Storage credentials) with its sandboxes as the
        // card's spend logs. The moment any non-default sandbox exists, the default card's walk is
        // partitioned so another account's sessions can't bleed into its spend.
        if let scan = coworkScan, claudeCandidatesAllowed {
            let defaultKey = identityKeys["claude"]
            for note in scan.notes {
                AppLog.info(.config, "discovery: \(note)")
            }
            if scan.truncated {
                defaultClaudeCoworkRoots = []
            }
            var defaultBucket: [URL] = []
            var order: [String] = []
            var grouped: [String: [ClaudeCoworkDiscovery.Sandbox]] = [:]
            var quarantinedUnidentifiedSandbox = false
            for sandbox in scan.truncated ? [] : scan.sandboxes {
                guard let rawIdentity = sandbox.identityKey else {
                    if desktopPolicy.hasMultipleAccounts {
                        quarantinedUnidentifiedSandbox = true
                    } else {
                        defaultBucket.append(sandbox.root)
                    }
                    continue
                }
                guard let key = desktopPolicy.canonical(rawIdentity) else {
                    quarantinedUnidentifiedSandbox = true
                    continue
                }
                guard key != defaultKey else {
                    defaultBucket.append(sandbox.root)
                    continue
                }
                if grouped[key] == nil { order.append(key) }
                grouped[key, default: []].append(sandbox)
            }
            for identityKey in order {
                let sandboxes = grouped[identityKey] ?? []
                let roots = sandboxes.map(\.root)
                if let index = plannedCards.firstIndex(where: { $0.identityKey == identityKey }) {
                    // The account already has a card from its config dir; its sandboxes are just
                    // more of its spend logs.
                    plannedCards[index].logRoots += roots
                    AppLog.info(.config, "discovery: \(roots.count) cowork sandbox(es) attach to an existing claude account card as log roots")
                    continue
                }
                guard let organization = sandboxes.compactMap(\.organization).first else {
                    // Desktop caches tokens per org; without the pin the card could only read
                    // Desktop's ACTIVE org, which may be a different account's usage pool.
                    AppLog.info(.config, "discovery: cowork account \(ProviderAccountID.make(family: "claude", identityKey: identityKey)) has no organization pin → skipped Desktop-backed card")
                    continue
                }
                guard hasDesktopCredentialMaterial(),
                      desktopPolicy.access(for: identityKey, allowsActiveOrganization: false)
                          == .pinned(organization)
                else {
                    AppLog.info(.config, "discovery: desktop credentials absent or their organization has ambiguous ownership → skipped Desktop-backed card")
                    continue
                }
                let label = sandboxes.compactMap(\.label).first
                observations.append(ProviderAccountsStore.AccountObservation(
                    family: "claude",
                    identityKey: identityKey,
                    label: label,
                    sources: [ProviderAccountSource(kind: .desktop, anchor: nil, holdsDefaultSource: false)]
                ))
                plannedCards.append(PlannedClaudeCard(
                    identityKey: identityKey,
                    credential: .desktop(organization: organization),
                    logRoots: roots,
                    verifiedIdentityAliases: [identityKey]
                ))
            }
            if !order.isEmpty || quarantinedUnidentifiedSandbox {
                defaultClaudeCoworkRoots = defaultBucket
                AppLog.info(.config, "discovery: cowork partition — default keeps \(defaultBucket.count) sandbox dir(s), \(order.count) other account(s) found")
            }
        }

        let observedDefaultIdentity = identityKeys["claude"]
        let familiesWithoutDefault = Set(outcomes.compactMap { entry -> String? in
            switch entry.outcome {
            case .absent:
                entry.family
            case .unresolved:
                entry.family == "claude" ? nil : entry.family
            case .resolved:
                nil
            }
        })
        let records = accountsStore.reconcile(
            with: observations, clearingDefaultSourcesFor: familiesWithoutDefault
        )
        for (family, observedIdentity) in Array(identityKeys) {
            if let record = records.first(where: {
                $0.family == family && $0.matches(identityKey: observedIdentity)
            }) {
                identityKeys[family] = record.identityKey
            }
        }
        let badgeHolder = accountsStore.defaultBadgeHolder(family: "claude")
        let defaultClaudeRecord: ProviderAccountRecord?
        switch claudeOutcome {
        case .resolved:
            defaultClaudeRecord = identityKeys["claude"].flatMap { observed in
                badgeHolder?.matches(identityKey: observed) == true ? badgeHolder : nil
            }
        case .unresolved, .none:
            defaultClaudeRecord = badgeHolder
        case .absent:
            defaultClaudeRecord = nil
        }
        if let defaultClaudeRecord {
            if defaultClaudeRecord.id != "claude" {
                identityKeys.removeValue(forKey: "claude")
            }
            identityKeys[defaultClaudeRecord.id] = defaultClaudeRecord.identityKey
        }

        // The extra-card build plan: one card per distinct account found this launch, under its
        // reconciled record id.
        var claudeCards: [ClaudeAccountCard] = []
        for planned in plannedCards {
            guard let record = records.first(where: {
                $0.family == "claude" && $0.matches(identityKey: planned.identityKey)
            }) else {
                continue
            }
            claudeCards.append(ClaudeAccountCard(
                id: record.id,
                displayName: record.derivedDisplayName,
                identityKey: record.identityKey,
                credential: planned.credential,
                logRoots: planned.logRoots,
                verifiedIdentityAliases: planned.verifiedIdentityAliases
            ))
            identityKeys[record.id] = record.identityKey
            let kind = if case .desktop = planned.credential { "desktop (cowork)" } else { "config dir" }
            AppLog.info(.config, "accounts: extra claude card \(record.id) — \(kind), \(planned.logRoots.count) log root(s)")
        }
        claudeCards.sort { $0.id < $1.id }

        let defaultClaudeName = defaultClaudeRecord.flatMap { record -> String? in
            guard record.id != "claude" else { return nil }
            return record.derivedDisplayName
        }
        let allowsUnownedDesktop = !families.contains("claude")
            && !records.contains { $0.family == "claude" }
        let allowsActiveOrganization = (isClaudeDiscoveryComplete || allowsUnownedDesktop)
            && coworkScan?.truncated != true
            && !desktopPolicy.hasMultipleAccounts
            && plannedCards.isEmpty
        let desktopAccess = if let defaultKey = identityKeys[defaultClaudeRecord?.id ?? "claude"] {
            desktopPolicy.access(for: defaultKey, allowsActiveOrganization: allowsActiveOrganization)
        } else {
            allowsActiveOrganization ? ClaudeDesktopAccessPolicy.activeOrganization : .denied
        }
        return ProviderAccountAssembly(
            identityKeysByCard: identityKeys,
            claudeCards: claudeCards,
            defaultClaudeExtraLogRoots: defaultClaudeExtraLogRoots,
            defaultClaudeDisplayName: defaultClaudeName,
            defaultClaudeVerifiedIdentityAliases: Set(observedDefaultIdentity.map { [$0] } ?? []),
            defaultClaudeCardID: defaultClaudeRecord?.id ?? "claude",
            allowsUnboundClaudeFallback: !records.contains { $0.family == "claude" },
            isClaudeDiscoveryComplete: isClaudeDiscoveryComplete,
            allowsUnownedClaudeDesktopFallback: allowsUnownedDesktop,
            defaultClaudeCoworkRoots: defaultClaudeCoworkRoots,
            defaultClaudeDesktopAccess: desktopAccess
        )
    }

    /// One distinct account's card plan before reconciliation assigns its record id.
    private struct PlannedClaudeCard {
        var identityKey: String
        var credential: ClaudeAccountCard.Credential
        var logRoots: [URL]
        var verifiedIdentityAliases: Set<String>
    }
}
