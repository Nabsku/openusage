import Foundation
import KeyboardShortcuts
import Observation

/// Composition root: owns the (constant) registry and the (mutable) stores, injected
/// into the SwiftUI environment.
@MainActor
@Observable
final class AppContainer {
    private let accountGraph: AccountRuntimeGraph
    var registry: WidgetRegistry { accountGraph.state.registry }
    var layout: LayoutStore { accountGraph.state.layout }
    var dataStore: WidgetDataStore { accountGraph.state.dataStore }
    /// Opt-in private iCloud document sync for additive machine-local daily history.
    var iCloudSync: ICloudUsageSyncStore { accountGraph.state.iCloudSync }
    /// Single source of truth for which providers the user has turned off. Both stores consult it (via
    /// injected closures) and the Customize provider list drives it.
    let enablement: ProviderEnablementStore
    /// Providers that need a user-supplied API key (currently OpenRouter and Z.ai), conforming to
    /// `APIKeyManaging`. Each matching Customize provider detail shows an API Key section and writes
    /// changes through the capability. Empty when no installed provider needs a user key.
    var apiKeyProviders: [any APIKeyManaging] { accountGraph.state.apiKeyProviders }
    /// Quota pace notification preferences (three independent triggers). Drives the Settings section
    /// and is read by `WidgetDataStore.evaluateNotifications`.
    let notificationSettings: NotificationSettingsStore
    /// Anonymous usage telemetry (mandatory daily activity and crashes, optional provider rollups).
    /// Exposed so Settings can toggle extra analytics and termination can flush queued events.
    let telemetry: TelemetryRecorder
    /// Source of truth for the popover's transparency: the persisted Increase Transparency toggle, the
    /// ephemeral secret-code easter-egg state, and the system accessibility flags it yields to. Read by both
    /// the SwiftUI surface and the AppKit panel (`StatusItemController`).
    let transparency: PopoverTransparencyStore
    /// The menu bar's screen-share privacy mode: the persisted Hide From Screen Share toggle
    /// plus the live capture signal. Read by `StatusItemImageUpdater` to swap the strip for the
    /// wordmark while the screen is shared or recorded.
    let privacy: MenuBarPrivacyStore
    /// One-time onboarding state (the first-run Customize hint card). Only ever marked pending by
    /// `FirstRunSeeder` on a fresh install, so existing installs never see the card.
    let onboarding: OnboardingStore
    /// Claims Codex rate-limit reset credits from the resets popover (the app's only provider-API
    /// write). Shares the Codex provider's auth store and usage client; `nil` only if the Codex
    /// provider were ever removed from the registry. Injected into the view tree via
    /// `\.codexResetClaim`.
    var codexResetClaim: CodexResetClaimService? { accountGraph.state.codexResetClaim }
    /// The account registry the launch pass reconciled. The UI observes it live: a rename
    /// (`customLabel`) re-titles the card everywhere without a relaunch.
    let accounts: ProviderAccountsStore
    /// The provider runtimes, kept so on-demand credential detection (the Customize "Reset All" reseed)
    /// can re-probe `hasLocalCredentials()` the same way first-run seeding does.
    private var providers: [ProviderRuntime] { accountGraph.state.providers }
    /// Read-only usage API on 127.0.0.1:6736 for other local apps (silently off when the port is taken).
    private let localAPI: LocalUsageServer
    /// Persists a fresh `ShellEnvironmentSnapshot` once the login-shell capture completes, so the next
    /// launch can read shell-exported facts (provider home overrides) even when its own capture is slow.
    private let shellEnvironmentSnapshotTask: Task<Void, Never>

    /// `isFreshInstall` must be captured by the caller BEFORE `SettingsMigrator.migrate()` runs (the
    /// migrator's schema stamp makes the defaults domain non-empty). See `AppDelegate`.
    init(isFreshInstall: Bool = false) {
        // Capture the user's login-shell environment off-main so provider keys exported in a shell
        // profile (e.g. OPENROUTER_API_KEY) resolve in a Finder/Dock-launched build, not only when
        // run from a terminal. Warmed here so the first refresh finds the cache ready.
        LoginShellEnvironment.shared.prewarm()
        // Once the capture lands, persist its identity-relevant facts so the NEXT launch has them
        // even if that launch's own capture is slow (see `ShellEnvironmentSnapshot`).
        self.shellEnvironmentSnapshotTask = ShellEnvironmentSnapshotStore(defaults: .standard).startRefreshTask()
        // The status item appears from a quarantined local-only graph immediately; the expensive
        // filesystem walks and first credential detection wait for the verified background bootstrap.
        let accounts = ProviderAccountsStore()
        let accountAssembly = ProviderAccountAssembly(
            identityKeysByCard: [:],
            allowsUnboundClaudeFallback: !accounts.records.contains { $0.family == "claude" },
            isClaudeDiscoveryComplete: false,
            defaultClaudeDesktopAccess: .denied
        )
        self.accounts = accounts

        let enablement = ProviderEnablementStore()
        let notificationSettings = NotificationSettingsStore()
        let runtime = Self.makeAccountRuntime(
            assembly: accountAssembly, accounts: accounts,
            enablement: enablement, notificationSettings: notificationSettings,
            quarantinesUnverifiedAccountData: true
        )
        runtime.iCloudSync.shutdownForAccountGraphReload()
        let providers = runtime.providers
        let dataStore = runtime.dataStore
        let accountGraph = AccountRuntimeGraph(state: runtime)
        self.accountGraph = accountGraph
        // Fresh installs start minimal: seed the enabled-provider list (Claude/Codex/Cursor right away,
        // then the detected set once the local credential probe finishes). No-op on every later launch.
        let onboarding = OnboardingStore()
        FirstRunSeeder.seedIfNeeded(
            isFreshInstall: isFreshInstall,
            providers: providers,
            enablement: enablement,
            onboarding: onboarding,
            deferDetectionUntilDiscovery: true
        )
        self.onboarding = onboarding
        self.enablement = enablement
        self.notificationSettings = notificationSettings

        // Anonymous usage telemetry (mandatory daily activity and crashes, optional provider rollups).
        // Its state lives in a dedicated UserDefaults suite, kept separate from app settings so the user's
        // optional-analytics choice and the install id stay independent of any settings change. The
        // snapshot closure reads the live layout/enablement so `app_daily_active` always reflects
        // the current configuration.
        let telemetryStore = TelemetryStore()
        let telemetry = TelemetryRecorder(
            sink: PostHogTelemetrySink(enabled: telemetryStore.enabled),
            store: telemetryStore,
            snapshot: { [accountGraph, enablement] in
                let registry = accountGraph.state.registry
                let layout = accountGraph.state.layout
                // Report the *active* configuration: a metric whose provider is turned off is hidden
                // from the dashboard and menu bar, so exclude it here too — keeping the metric arrays
                // consistent with `enabledProviders` (which is also enablement-filtered).
                let providerOn: (String) -> Bool = { metricID in
                    guard let providerID = registry.descriptor(id: metricID)?.providerID else { return false }
                    return enablement.isEnabled(providerID)
                }
                return TelemetryConfigSnapshot(
                    enabledProviders: registry.providers.map(\.id).filter { enablement.isEnabled($0) },
                    enabledMetricIDs: layout.placed.map(\.descriptorID).filter(providerOn),
                    pinnedMetricIDs: layout.pinnedMetricIDs.filter(providerOn),
                    expandedMetricIDs: layout.expandedMetricIDs.filter(providerOn),
                    menuBarStyle: layout.menuBarStyle.rawValue
                )
            }
        )
        dataStore.onRefreshOutcome = { [weak telemetry] providerID, outcome, category, manual in
            telemetry?.record(providerID: providerID, outcome: outcome, category: category, manual: manual)
        }
        self.telemetry = telemetry
        self.transparency = PopoverTransparencyStore()
        self.privacy = MenuBarPrivacyStore()
        self.localAPI = LocalUsageServer(state: { [accountGraph, enablement, accounts] in
            let current = accountGraph.state
            return LocalUsageAPI.State(
                enabledOrderedIDs: current.layout.orderedProviderIDs().filter { enablement.isEnabled($0) },
                knownIDs: Set(current.registry.providers.map(\.id)),
                snapshots: current.dataStore.snapshots,
                limitDescriptors: current.registry.limitDescriptorsByProvider,
                errors: current.dataStore.providerErrors
            )
            // API output is human-read too: resolve card titles at respond time so renames show,
            // exactly like every UI surface.
            .resolvingDisplayNames(accounts.resolvedDisplayNamesByCardID)
        })
        accountGraph.runtimeTasks = AccountRuntimeTaskLifetime([
            Self.startPeriodicRefresh(dataStore: dataStore, telemetry: telemetry)
        ])
        localAPI.start()
        accountGraph.accountWatcher = AccountRuntimeTaskLifetime([
            Self.startAccountGraphWatch(accounts: accounts, initialAssembly: accountAssembly) { [weak self] assembly in
                self?.replaceAccountRuntime(with: assembly)
            } onOwnershipUnverified: { [weak self] in
                guard let self else { return }
                let quarantined = ProviderAccountAssembly(
                    identityKeysByCard: [:],
                    allowsUnboundClaudeFallback: !self.accounts.records.contains { $0.family == "claude" },
                    isClaudeDiscoveryComplete: false,
                    defaultClaudeDesktopAccess: .denied
                )
                self.replaceAccountRuntime(with: quarantined, quarantinesUnverifiedAccountData: true)
            } onLogRootsChanged: { [weak self] assembly in
                await self?.updateAccountLogRouting(with: assembly)
            },
        ])
        // Become the notification-center delegate so banners show while frontmost — a menu-bar accessory
        // effectively always is. Notification authorization is requested the first time a trigger is
        // turned on in Settings, not at launch — triggers default off. No-op under tests.
        AppNotifications.shared.registerAsDelegate()
    }

    deinit {
        shellEnvironmentSnapshotTask.cancel()
    }

    private static func makeAccountRuntime(
        assembly: ProviderAccountAssembly,
        accounts: ProviderAccountsStore,
        enablement: ProviderEnablementStore,
        notificationSettings: NotificationSettingsStore,
        snapshotCache: ProviderSnapshotCache = ProviderSnapshotCache(),
        quarantinesUnverifiedAccountData: Bool = false
    ) -> AccountRuntimeGraph.State {
        let providers = ProviderCatalog.make(accountAssembly: assembly)
        let registry = WidgetRegistry.from(providers)
        let layout = LayoutStore(
            registry: registry,
            persistInitialState: !quarantinesUnverifiedAccountData,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) }
        )
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: providers,
            cache: snapshotCache,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) },
            orderedDescriptors: { [layout] in layout.visiblePlaced.compactMap { layout.descriptor(for: $0) } },
            notificationSettings: { notificationSettings },
            providerIdentityKeys: assembly.identityKeysByCard,
            knownAccountIdentitiesByFamily: accounts.records.reduce(into: [:]) { identities, record in
                identities[record.family, default: []].formUnion(
                    [record.identityKey] + (record.identityAliases ?? [])
                )
            },
            quarantinesUnverifiedAccountData: quarantinesUnverifiedAccountData,
            resolveDisplayName: { [accounts] in accounts.resolvedDisplayName(cardID: $0) }
        )
        let iCloudSync = ICloudUsageSyncStore(dataStore: dataStore)
        enablement.onProviderEnabled = { [weak dataStore] id in dataStore?.clearFailureBackoff(for: id) }
        enablement.onChange = { [weak dataStore, weak iCloudSync] in
            dataStore?.providerEnablementDidChange()
            iCloudSync?.scheduleWrite()
        }
        let codexResetClaim = providers.compactMap { $0 as? CodexProvider }.first.map { codex in
            CodexResetClaimService(
                authStore: codex.authStore,
                usageClient: codex.usageClient,
                expectedIdentityKey: codex.expectedIdentityKey,
                verifiedIdentityKey: { [weak codex] in codex?.verifiedAccountIdentityKey },
                refreshAfterClaim: { [weak dataStore] in
                    var failures = 0
                    for attempt in 0..<45 {
                        guard let dataStore else { return }
                        switch await dataStore.refresh(providerID: codex.provider.id, force: true) {
                        case .refreshed, .cacheHit, .backedOff:
                            return
                        case .failed:
                            failures += 1
                            guard failures < 3 else {
                                AppLog.error(LogTag.plugin("codex"), "post-claim refresh failed \(failures) times; meters may lag until the next cycle")
                                return
                            }
                            try? await Task.sleep(for: .seconds(2))
                        case .skipped:
                            AppLog.info(LogTag.plugin("codex"), "post-claim refresh waiting out an in-flight refresh (attempt \(attempt + 1))")
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                    AppLog.error(LogTag.plugin("codex"), "post-claim refresh kept being skipped; meters may lag until the next cycle")
                }
            )
        }
        return .init(
            registry: registry,
            layout: layout,
            dataStore: dataStore,
            snapshotCache: snapshotCache,
            iCloudSync: iCloudSync,
            providers: providers,
            apiKeyProviders: providers.compactMap { $0 as? any APIKeyManaging },
            codexResetClaim: codexResetClaim
        )
    }

    /// The name a card renders under right now — the app-side face of the one resolver
    /// (`ProviderAccountRecord.resolvedDisplayName`). Live: a rename in the account registry
    /// re-titles the card everywhere without a relaunch. Non-account providers (no record) keep
    /// their static display name; `Provider.displayName` itself only ever carries the derived
    /// default, so the fallback can never be a stale rename.
    func displayName(for provider: Provider) -> String {
        accounts.resolvedDisplayName(cardID: provider.id) ?? provider.displayName
    }

    /// Whether the card has an account record a rename can attach to (accounts-model families only,
    /// and only once the account's identity has been observed at least once).
    func canRename(_ providerID: String) -> Bool {
        accounts.runtimeRecord(for: providerID) != nil
    }

    /// Re-runs first-launch credential detection on demand — the enablement half of the Customize
    /// "Reset All" action (`LayoutStore.resetToDefault` handles metrics, order, pins, and expansion).
    /// Delegates to `FirstRunSeeder.reseed`; returns its detection task so callers can await it.
    @discardableResult
    func reseedEnabledProviders() -> Task<Void, Never> {
        let task = FirstRunSeeder.reseed(providers: providers, enablement: enablement)
        accountGraph.resetDetection = AccountRuntimeTaskLifetime([task])
        return task
    }

    private func replaceAccountRuntime(
        with assembly: ProviderAccountAssembly, quarantinesUnverifiedAccountData: Bool = false
    ) {
        let previousScreen = layout.screen
        let snapshotCache = accountGraph.state.snapshotCache
        accountGraph.retireCurrentState()
        let replacement = Self.makeAccountRuntime(
            assembly: assembly, accounts: accounts,
            enablement: enablement, notificationSettings: notificationSettings,
            snapshotCache: snapshotCache,
            quarantinesUnverifiedAccountData: quarantinesUnverifiedAccountData
        )
        if quarantinesUnverifiedAccountData {
            replacement.iCloudSync.shutdownForAccountGraphReload()
        }
        replacement.layout.screen = previousScreen
        replacement.dataStore.onRefreshOutcome = { [weak telemetry] providerID, outcome, category, manual in
            telemetry?.record(providerID: providerID, outcome: outcome, category: category, manual: manual)
        }
        accountGraph.state = replacement
        accountGraph.runtimeTasks = AccountRuntimeTaskLifetime([
            Self.startPeriodicRefresh(dataStore: replacement.dataStore, telemetry: telemetry),
            quarantinesUnverifiedAccountData ? nil
                : NewProviderSeeder.reconcileIfNeeded(providers: replacement.providers, enablement: enablement),
        ])
        AppLog.info(.config, "accounts: account runtimes updated without replacing app services")
    }

    private func updateAccountLogRouting(with assembly: ProviderAccountAssembly) async {
        var updatedProviderIDs: [String] = []
        for provider in providers.compactMap({ $0 as? ClaudeProvider }) {
            guard !Task.isCancelled else { return }
            let updated: Bool
            if let card = assembly.claudeCards.first(where: { $0.id == provider.provider.id }) {
                updated = await provider.logUsageScanner.updateLogRoots(
                    rootsOverride: card.logRoots, additionalRoots: [], coworkRootsOverride: nil
                )
            } else if provider.provider.id == assembly.defaultClaudeCardID {
                updated = await provider.logUsageScanner.updateLogRoots(
                    rootsOverride: nil,
                    additionalRoots: assembly.defaultClaudeExtraLogRoots,
                    coworkRootsOverride: assembly.defaultClaudeCoworkRoots
                )
            } else {
                continue
            }
            if updated { updatedProviderIDs.append(provider.provider.id) }
        }
        for providerID in updatedProviderIDs {
            guard !Task.isCancelled else { return }
            await dataStore.refresh(providerID: providerID, force: true)
        }
        if !updatedProviderIDs.isEmpty {
            AppLog.info(.config, "accounts: refreshed log routes for \(updatedProviderIDs.count) existing account(s)")
        }
    }

    struct AccountOwnershipFingerprint: Equatable {
        struct Card: Equatable {
            var id: String
            var identityKey: String
            var verifiedIdentityAliases: Set<ClaudeIdentity>
            var credential: ClaudeAccountCard.Credential
        }

        var identities: [String: String]
        var cards: [Card]
        var defaultClaudeCardID: String
        var allowsUnboundClaudeFallback: Bool
        var isClaudeDiscoveryComplete: Bool
        var defaultClaudeVerifiedIdentityAliases: Set<ClaudeIdentity>
        var desktopAccess: ClaudeDesktopAccessPolicy

        init(_ assembly: ProviderAccountAssembly) {
            identities = assembly.identityKeysByCard
            cards = assembly.claudeCards.map {
                Card(
                    id: $0.id, identityKey: $0.identityKey,
                    verifiedIdentityAliases: $0.verifiedIdentityAliases, credential: $0.credential
                )
            }
            defaultClaudeCardID = assembly.defaultClaudeCardID
            allowsUnboundClaudeFallback = assembly.allowsUnboundClaudeFallback
            isClaudeDiscoveryComplete = assembly.isClaudeDiscoveryComplete
            defaultClaudeVerifiedIdentityAliases = assembly.defaultClaudeVerifiedIdentityAliases
            desktopAccess = assembly.defaultClaudeDesktopAccess
        }
    }

    struct AccountLogRoutingFingerprint: Equatable {
        var rootsByCard: [String: Set<URL>]
        var defaultCardID: String
        var defaultExtraRoots: Set<URL>
        var defaultCoworkRoots: Set<URL>?

        init(_ assembly: ProviderAccountAssembly) {
            rootsByCard = Dictionary(uniqueKeysWithValues: assembly.claudeCards.map {
                ($0.id, Set($0.logRoots))
            })
            defaultCardID = assembly.defaultClaudeCardID
            defaultExtraRoots = Set(assembly.defaultClaudeExtraLogRoots)
            defaultCoworkRoots = assembly.defaultClaudeCoworkRoots.map { Set($0) }
        }

        func reassignsExistingRoots(from previous: Self) -> Bool {
            var ownersByRoot: [URL: String] = [:]
            for (cardID, roots) in rootsByCard {
                for root in roots { ownersByRoot[root] = cardID }
            }
            for root in defaultExtraRoots.union(defaultCoworkRoots ?? []) {
                ownersByRoot[root] = defaultCardID
            }
            for (cardID, roots) in previous.rootsByCard {
                if roots.contains(where: { ownersByRoot[$0].map { $0 != cardID } ?? false }) {
                    return true
                }
            }
            return previous.defaultExtraRoots.union(previous.defaultCoworkRoots ?? []).contains {
                ownersByRoot[$0].map { $0 != previous.defaultCardID } ?? false
            }
        }
    }

    private static func startAccountGraphWatch(
        accounts: ProviderAccountsStore,
        initialAssembly: ProviderAccountAssembly,
        onChange: @escaping @MainActor (ProviderAccountAssembly) -> Void,
        onOwnershipUnverified: @escaping @MainActor () -> Void,
        onLogRootsChanged: @escaping @MainActor (ProviderAccountAssembly) async -> Void
    ) -> Task<Void, Never> {
        func observeDefaults() async -> [String: DefaultAccountObserver.Outcome] {
            await loadOffMainActor {
                let observer = DefaultAccountObserver()
                let desktop = ClaudeDesktopAuthStore().lastKnownAccountUUID().map {
                    DefaultAccountObserver.Outcome.resolved(identityKey: $0, label: nil, anchor: "desktop")
                } ?? .absent
                return ["claude": observer.observeClaude(), "codex": observer.observeCodex(), "claude-desktop": desktop]
            }
        }

        return Task { @MainActor in
            while !Task.isCancelled {
                let shellReady = await loadOffMainActor { LoginShellEnvironment.shared.ensureCaptured() }
                guard !Task.isCancelled else { return }
                if shellReady || ShellEnvironmentSnapshotStore.launchSnapshot != nil { break }
                AppLog.error(.config, "accounts: login shell unavailable; retrying quarantined account discovery")
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
            var previousDefaults: [String: DefaultAccountObserver.Outcome] = [:]
            var previousOwnership = AccountOwnershipFingerprint(initialAssembly)
            var previousRouting = AccountLogRoutingFingerprint(initialAssembly)
            var checksSinceFullDiscovery = 0
            var bootstrapped = false
            var ownershipIsQuarantined = false
            while !Task.isCancelled {
                if bootstrapped {
                    do {
                        try await Task.sleep(for: .seconds(5))
                    } catch {
                        return
                    }
                }
                let observedDefaults = await observeDefaults()
                guard !Task.isCancelled else { return }
                checksSinceFullDiscovery += 1
                guard !bootstrapped || ownershipIsQuarantined
                    || observedDefaults != previousDefaults || checksSinceFullDiscovery >= 12
                else {
                    continue
                }
                if bootstrapped && observedDefaults != previousDefaults && !ownershipIsQuarantined {
                    onOwnershipUnverified()
                    ownershipIsQuarantined = true
                }
                checksSinceFullDiscovery = 0
                let preferredAnchors = Set(accounts.records.flatMap { record in
                    record.sources.filter { $0.kind == .configDir }.compactMap(\.anchor)
                })
                let prepared = await prepareAccountDiscovery(configScan: {
                    ClaudeConfigDirDiscovery().run(prioritizing: preferredAnchors)
                })
                guard !Task.isCancelled else { return }
                guard prepared.isComplete else {
                    if bootstrapped && !ownershipIsQuarantined {
                        onOwnershipUnverified()
                        ownershipIsQuarantined = true
                    }
                    AppLog.warn(.config, "accounts: incomplete background discovery quarantined before reconciliation")
                    if !bootstrapped {
                        try? await Task.sleep(for: .seconds(5))
                    }
                    continue
                }
                guard await observeDefaults() == observedDefaults else {
                    AppLog.info(.config, "accounts: default login changed during discovery; retrying")
                    continue
                }
                previousDefaults = observedDefaults
                let assembly = ProviderAccountAssembly.make(
                    accountsStore: accounts, waitsForLoginShell: true, preparedDiscovery: prepared
                )
                guard !Task.isCancelled else { return }
                let ownership = AccountOwnershipFingerprint(assembly)
                let routing = AccountLogRoutingFingerprint(assembly)
                let replacesGraph = !bootstrapped
                    || ownershipIsQuarantined
                    || ownership != previousOwnership
                    || routing.reassignsExistingRoots(from: previousRouting)
                guard replacesGraph || routing != previousRouting else { continue }
                bootstrapped = true
                ownershipIsQuarantined = false
                previousOwnership = ownership
                previousRouting = routing
                if replacesGraph {
                    onChange(assembly)
                } else {
                    await onLogRootsChanged(assembly)
                }
            }
        }
    }

    static func prepareAccountDiscovery(
        configScan: @escaping @Sendable () -> ClaudeConfigDirDiscovery.Result = {
            ClaudeConfigDirDiscovery().run()
        },
        coworkScan: @escaping @Sendable () -> ClaudeCoworkDiscovery.Result = {
            ClaudeCoworkDiscovery().run()
        },
        desktopAccount: @escaping @Sendable () -> String? = {
            let desktop = ClaudeDesktopAuthStore()
            return desktop.hasCredentialMaterial() ? desktop.lastKnownAccountUUID() : nil
        }
    ) async -> PreparedProviderAccountDiscovery {
        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled else {
                return PreparedProviderAccountDiscovery(
                    config: .init(truncated: true), cowork: .init(truncated: true)
                )
            }
            let config = configScan()
            guard !Task.isCancelled, !config.truncated else {
                return PreparedProviderAccountDiscovery(config: config, cowork: .init(truncated: true))
            }
            let cowork = coworkScan()
            guard !Task.isCancelled, !cowork.truncated else {
                return PreparedProviderAccountDiscovery(config: config, cowork: cowork)
            }
            return PreparedProviderAccountDiscovery(
                config: config, cowork: cowork, desktopAccountUUID: desktopAccount()
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The Settings "Reset All Settings" action: restores every user preference the container owns to
    /// its default (see `docs/settings.md` § Reset). Composes the Customize reset (`resetToDefault` +
    /// provider reseed) with the Settings-only preferences. Deliberately untouched: telemetry (the
    /// optional-analytics choice and install id stay independent of settings changes — see the
    /// `TelemetryStore` note above), the iCloud sync device identity, provider credentials, and
    /// cached usage snapshots.
    /// Launch at Login and the Sparkle update preferences live outside the container; the Settings
    /// screen resets those alongside this call.
    func resetAllSettings() {
        layout.resetToDefault()
        // The menu-bar Icon Style is a Settings preference, not part of the Customize layout reset.
        layout.menuBarStyle = .text
        reseedEnabledProviders()
        dataStore.resetDisplaySettings()
        notificationSettings.resetToDefaults()
        transparency.resetToDefaults()
        privacy.hideUsageWhileScreenSharing = false
        // Same as flipping the Settings toggle off: stops syncing and removes this Mac's document
        // from the shared iCloud container (peers keep their own history).
        iCloudSync.enabled = false
        // Removing an `@AppStorage` key restores its declared default; the Settings screen's
        // `@AppStorage` properties observe the change. New settings must be added here.
        for key in [
            AppearanceSetting.key, TimeFormatSetting.key, DensitySetting.key,
            ReduceAnimationsSetting.key, LogLevelSetting.key, TotalSpendSetting.key,
            TotalSpendSetting.periodKey, TotalSpendSetting.metricKey,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        KeyboardShortcuts.reset(.togglePopover)
        AppearanceSetting.applyCurrent()
        AppLog.reloadLevel()
        AppLog.info(.config, "All settings reset to defaults")
    }

    /// Drives live updates: refresh on launch, then again every refresh interval. Each pass honors the
    /// cache, so it only hits the network once a snapshot has actually expired. `@Observable` propagates
    /// the resulting snapshot changes to the menu-bar label and any open widgets, so the UI refreshes on
    /// its own instead of only when the popover opens.
    ///
    /// Between passes the loop sleeps via `RefreshWakeSignal`, which wakes it early when the user
    /// enables/disables a provider so a newly-enabled provider is fetched promptly instead of waiting out
    /// the full interval. The signal subscribes BEFORE the first pass and buffers, so an enablement change
    /// landing while a pass is still running (first-run credential detection, `NewProviderSeeder`, the
    /// Customize "Reset All" reseed — all of which typically finish faster than the network fetches) is
    /// never lost. Each pass still honors the cache (and the per-provider failure backoff), so an early
    /// wake only hits the network for a provider whose snapshot has actually expired.
    ///
    /// The wake is deliberately scoped to `ProviderEnablementStore.didChangeNotification` — NOT the
    /// firehose `UserDefaults.didChangeNotification`, which fires for the app's own snapshot-cache writes,
    /// Sparkle's update bookkeeping, and unrelated global-domain changes from other processes. Waking on
    /// that, with no minimum interval before re-refreshing, collapsed the fixed 5-minute cadence into a
    /// refresh storm.
    private static func startPeriodicRefresh(dataStore: WidgetDataStore, telemetry: TelemetryRecorder) -> Task<Void, Never> {
        Task {
            let wakeSignal = RefreshWakeSignal()
            while !Task.isCancelled {
                await dataStore.refreshAll()
                // Re-evaluate quota pace milestones every tick — after the refresh so it sees fresh data,
                // and on every loop (not just on a fetch) so pace worsening from elapsed time alone still
                // alerts even with the popover closed.
                await dataStore.evaluateNotifications()
                // Day-rollover beat: always emits `app_daily_active` once per local day; flushes
                // prior-day provider rollups only while optional analytics are on. Runs on launch
                // and every interval, so always-running instances still produce a daily-active signal.
                telemetry.tick()
                await wakeSignal.waitForWake(timeout: RefreshSetting.interval)
            }
        }
    }
}
