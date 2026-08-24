import Foundation

/// Account-routing inputs cross the assembly/runtime boundary together.
struct ClaudeRuntimePlan: Sendable {
    let cards: [ClaudeAccountCard]
    let allowsUnboundFallback: Bool
    let defaultCoworkRoots: [URL]?

    init(
        cards: [ClaudeAccountCard] = [],
        allowsUnboundFallback: Bool = true,
        defaultCoworkRoots: [URL]? = nil
    ) {
        self.cards = cards
        self.allowsUnboundFallback = allowsUnboundFallback
        self.defaultCoworkRoots = defaultCoworkRoots
    }
}

/// One verified account-to-runtime binding. The credential source belongs to its permanent account
/// record, so the original bare card can move while another account takes over the default home.
struct ClaudeAccountCard: Equatable, Sendable {
    enum Credential: Equatable, Sendable {
        case defaultHome
        case configDir(path: String, keychainLiteral: String)
        case desktop(organization: String)
    }

    var id: String
    var displayName: String
    var identityKey: String
    var credential: Credential
    var logRoots: [URL]
    var additionalLogRoots: [URL] = []
    var coworkRootsOverride: [URL]?
    /// Credential ownership is decided once by assembly, never reconstructed from spend roots.
    var desktopAccess: ClaudeDesktopAccessPolicy = .denied
    /// The bare CLI keychain item is safe only when one verified account owns the default home.
    var allowsUnscopedKeychainFallback = false
}

/// Filesystem discovery happens off the main actor; account reconciliation remains main-actor-owned.
struct PreparedProviderAccountDiscovery: Sendable {
    var config: ClaudeConfigDirDiscovery.Result
    var cowork: ClaudeCoworkDiscovery.Result
}

/// Account assembly has five explicit phases: observe identity sources, plan verified accounts,
/// partition Cowork sessions, reconcile stable records, and bind one runtime per observed account.
@MainActor
struct ProviderAccountAssembly {
    let identityKeysByCard: [String: String]
    var claudeCards: [ClaudeAccountCard] = []
    var allowsUnboundClaudeFallback = true

    var claudeRuntimePlan: ClaudeRuntimePlan {
        ClaudeRuntimePlan(
            cards: claudeCards,
            allowsUnboundFallback: allowsUnboundClaudeFallback
        )
    }

    static func make(
        defaults: UserDefaults = .standard,
        accountsStore: ProviderAccountsStore? = nil,
        waitsForLoginShell: Bool,
        preparedDiscovery: PreparedProviderAccountDiscovery? = nil
    ) -> Self {
        let store = accountsStore ?? ProviderAccountsStore(defaults: defaults)
        let shellFactsReadable = !waitsForLoginShell
            || LoginShellEnvironment.shared.capturedSuccessfully
            || ShellEnvironmentSnapshotStore.launchSnapshot != nil
        let families = shellFactsReadable
            ? ProviderAccountID.families
            : ProviderAccountID.families.filter { family in
                guard let key = homeOverrideKeys[family] else { return false }
                return ProcessInfo.processInfo.environment[key]?.nilIfEmpty != nil
            }
        if families.count < ProviderAccountID.families.count {
            AppLog.info(.config, "account identity read skipped for \(ProviderAccountID.families.subtracting(families).sorted().joined(separator: ", ")): login shell cold and no shell-environment snapshot exists yet")
        }
        guard !families.isEmpty else {
            return Self(
                identityKeysByCard: [:],
                allowsUnboundClaudeFallback: !store.records.contains { $0.family == "claude" }
            )
        }
        return make(
            observer: DefaultAccountObserver(),
            accountsStore: store,
            families: families,
            claudeDiscovery: ClaudeConfigDirDiscovery(),
            coworkDiscovery: ClaudeCoworkDiscovery(),
            preparedDiscovery: preparedDiscovery
        )
    }

    static func make(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        families: Set<String> = ProviderAccountID.families,
        claudeDiscovery: ClaudeConfigDirDiscovery? = nil,
        coworkDiscovery: ClaudeCoworkDiscovery? = nil,
        preparedDiscovery: PreparedProviderAccountDiscovery? = nil,
        hasDesktopCredentialMaterial: @Sendable () -> Bool = {
            ClaudeDesktopAuthStore().hasCredentialMaterial()
        }
    ) -> Self {
        let observed = ClaudeSourceObservations.observe(
            observer: observer,
            accountsStore: accountsStore,
            families: families,
            claudeDiscovery: claudeDiscovery,
            coworkDiscovery: coworkDiscovery,
            preparedDiscovery: preparedDiscovery
        )
        var plan = ClaudeAccountPlan.make(from: observed)
        let partition = ClaudeCoworkPartition.make(
            from: observed,
            plan: &plan,
            hasDesktopCredentialMaterial: hasDesktopCredentialMaterial
        )
        let records = reconcile(plan, observed: observed, accountsStore: accountsStore)
        return bind(
            plan: plan,
            observed: observed,
            partition: partition,
            records: records,
            accountsStore: accountsStore
        )
    }

    private static let homeOverrideKeys: [String: String] = [
        "claude": "CLAUDE_CONFIG_DIR",
        "codex": "CODEX_HOME",
    ]

    private static func reconcile(
        _ plan: ClaudeAccountPlan,
        observed: ClaudeSourceObservations,
        accountsStore: ProviderAccountsStore
    ) -> [ProviderAccountRecord] {
        if observed.defaultOutcome != nil, plan.defaultIdentity == nil {
            accountsStore.clearDefaultSource(family: "claude")
        }
        let claudeObservations: [ProviderAccountsStore.AccountObservation] = plan.orderedIdentities.compactMap { identity in
            guard let account = plan.accounts[identity] else { return nil }
            return ProviderAccountsStore.AccountObservation(
                family: "claude",
                identityKey: account.identityKey,
                label: account.label,
                sources: account.sources
            )
        }
        return accountsStore.reconcile(with: claudeObservations + plan.otherObservations)
    }

    private static func bind(
        plan: ClaudeAccountPlan,
        observed: ClaudeSourceObservations,
        partition: ClaudeCoworkPartition,
        records: [ProviderAccountRecord],
        accountsStore: ProviderAccountsStore
    ) -> Self {
        let hasExactlyOneDefaultAccount = plan.accounts.count == 1
            && plan.defaultIdentity.flatMap { plan.accounts[$0]?.credential } == .defaultHome
        let permitsUnscopedFallback = observed.desktopPolicy.allowsUnpinnedFallback(
            defaultIdentity: plan.defaultIdentity,
            hasExactlyOneDefaultAccount: hasExactlyOneDefaultAccount,
            coworkScan: observed.cowork
        )

        var identityKeys = plan.identityKeysByCard
        var cards: [ClaudeAccountCard] = []
        for identity in plan.orderedIdentities {
            guard let planned = plan.accounts[identity],
                  let record = records.first(where: {
                      $0.family == "claude"
                          && $0.identityKey == identity
                          && !$0.removedTombstone
                  })
            else { continue }
            let isDefaultHome = planned.credential == .defaultHome
            let desktopAccess: ClaudeDesktopAccessPolicy = isDefaultHome
                ? observed.desktopPolicy.access(
                    for: record.identityKey,
                    allowsActiveOrganization: permitsUnscopedFallback
                )
                : .denied
            cards.append(ClaudeAccountCard(
                id: record.id,
                displayName: accountsStore.derivedDisplayName(cardID: record.id)
                    ?? record.derivedDisplayName,
                identityKey: record.identityKey,
                credential: planned.credential,
                logRoots: planned.logRoots,
                additionalLogRoots: planned.additionalLogRoots,
                coworkRootsOverride: isDefaultHome && partition.requiresPartition
                    ? partition.defaultRoots
                    : nil,
                desktopAccess: desktopAccess,
                allowsUnscopedKeychainFallback: isDefaultHome && permitsUnscopedFallback
            ))
            identityKeys[record.id] = record.identityKey
            AppLog.info(.config, "accounts: claude card \(record.id) bound to \(sourceDescription(planned.credential)); \(planned.logRoots.count) verified log root(s)")
        }
        cards.sort {
            if $0.id == "claude" { return true }
            if $1.id == "claude" { return false }
            return $0.id < $1.id
        }

        return Self(
            identityKeysByCard: identityKeys,
            claudeCards: cards,
            allowsUnboundClaudeFallback: !records.contains { $0.family == "claude" }
        )
    }

    private static func sourceDescription(_ credential: ClaudeAccountCard.Credential) -> String {
        switch credential {
        case .defaultHome: "default home"
        case .configDir: "config dir"
        case .desktop: "desktop"
        }
    }
}
