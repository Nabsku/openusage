import Foundation
import KeyboardShortcuts
import Observation

/// Composition root: owns the (constant) registry and the (mutable) stores, injected
/// into the SwiftUI environment.
@MainActor
@Observable
final class AppContainer {
    /// The AppDelegate replaces its immutable registry, layout, runtime, and status-item graph when
    /// a login changes; posting only after a verified graph diff keeps account cards stable otherwise.
    static let accountGraphDidChangeNotification = Notification.Name(
        "OpenUsage.accountGraphDidChange"
    )

    let registry: WidgetRegistry
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    /// Opt-in private iCloud document sync for additive machine-local daily history.
    let iCloudSync: ICloudUsageSyncStore
    /// Single source of truth for which providers the user has turned off. Both stores consult it (via
    /// injected closures) and the Customize provider list drives it.
    let enablement: ProviderEnablementStore
    /// Providers that need a user-supplied API key (currently OpenRouter and Z.ai), conforming to
    /// `APIKeyManaging`. Each matching Customize provider detail shows an API Key section and writes
    /// changes through the capability. Empty when no installed provider needs a user key.
    let apiKeyProviders: [any APIKeyManaging]
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
    let codexResetClaim: CodexResetClaimService?
    /// The authoritative account registry shared by discovery, runtime assembly, and live renames.
    let accounts: ProviderAccountsStore

    /// The provider runtimes, kept so on-demand credential detection (the Customize "Reset All" reseed)
    /// can re-probe `hasLocalCredentials()` the same way first-run seeding does.
    private let providers: [ProviderRuntime]
    /// Read-only usage API on 127.0.0.1:6736 for other local apps (silently off when the port is taken).
    private let localAPI: LocalUsageServer
    // A `let` of a `Sendable` `Task` is implicitly nonisolated, so the nonisolated `deinit` can cancel it.
    private let refreshTask: Task<Void, Never>
    /// The fresh-install credential-detection pass (see `FirstRunSeeder`); `nil` on every later launch.
    private let seedTask: Task<Void, Never>?
    /// The new-provider credential-detection pass (see `NewProviderSeeder`); `nil` unless this launch is
    /// the first with a provider the install has never seen.
    private let newProviderTask: Task<Void, Never>?
    /// Persists a fresh `ShellEnvironmentSnapshot` once the login-shell capture completes, so the next
    /// launch can read shell-exported facts (provider home overrides) even when its own capture is slow.
    private let shellEnvironmentSnapshotTask: Task<Void, Never>
    /// Cheap default-home identity checks catch live swaps promptly; full discovery is throttled.
    private let accountGraphWatchTask: Task<Void, Never>

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
        // Reconcile one shared registry before constructing any account-aware runtime. Every Claude
        // runtime then follows its record's current verified source, regardless of its card id.
        let accounts = ProviderAccountsStore()
        let accountAssembly = ProviderAccountAssembly.make(
            accountsStore: accounts,
            waitsForLoginShell: true
        )
        self.accounts = accounts

        let providers = ProviderCatalog.make(
            claude: accountAssembly.claudeRuntimePlan
        )
        let registry = WidgetRegistry.from(providers)
        let apiKeyProviders = providers.compactMap { $0 as? any APIKeyManaging }
        let enablement = ProviderEnablementStore()
        let notificationSettings = NotificationSettingsStore()
        let layout = LayoutStore(
            registry: registry,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) }
        )
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: providers,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) },
            orderedDescriptors: { [layout] in layout.visiblePlaced.compactMap { layout.descriptor(for: $0) } },
            notificationSettings: { notificationSettings },
            providerIdentityKeys: accountAssembly.identityKeysByCard,
            resolveDisplayName: { [accounts] in accounts.resolvedDisplayName(cardID: $0) }
        )
        let iCloudSync = ICloudUsageSyncStore(dataStore: dataStore)
        // Re-enabling a provider should fetch it promptly, so clear any leftover failure backoff before
        // the enablement wake refreshes. `weak` breaks the cycle (dataStore already captures enablement).
        enablement.onProviderEnabled = { [weak dataStore] id in dataStore?.clearFailureBackoff(for: id) }
        enablement.onChange = { [weak dataStore, weak iCloudSync] in
            dataStore?.providerEnablementDidChange()
            iCloudSync?.scheduleWrite()
        }
        // Fresh installs start minimal: seed the enabled-provider list (Claude/Codex/Cursor right away,
        // then the detected set once the local credential probe finishes). No-op on every later launch.
        let onboarding = OnboardingStore()
        let firstRunSeedTask = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: isFreshInstall,
            providers: providers,
            enablement: enablement,
            onboarding: onboarding
        )
        self.seedTask = firstRunSeedTask
        // Providers added by an update get the same credential detection on their first launch — enabled
        // only when the user actually has the tool. Runs every launch; a no-op unless the registry has a
        // provider this install has never seen (fresh installs were just baselined by FirstRunSeeder).
        self.newProviderTask = firstRunSeedTask == nil
            ? NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: enablement)
            : nil
        self.providers = providers
        self.onboarding = onboarding
        self.registry = registry
        self.enablement = enablement
        self.apiKeyProviders = apiKeyProviders
        self.notificationSettings = notificationSettings
        self.layout = layout
        self.dataStore = dataStore
        self.iCloudSync = iCloudSync

        // The resets popover's claim service, sharing the Codex provider's credential loading and HTTP
        // client so the claim's auth can't drift from the provider's. A successful claim forces a Codex
        // refresh so the meters and credit count reconcile before the popover shows its result. The
        // forced refresh returns `.skipped` when another refresh already owns the provider — and that
        // in-flight probe may carry *pre-claim* usage — so retry until this refresh actually runs
        // (bounded; the racing probe finishes in seconds).
        self.codexResetClaim = providers.compactMap { $0 as? CodexProvider }.first.map { codex in
            CodexResetClaimService(
                authStore: codex.authStore,
                usageClient: codex.usageClient,
                refreshAfterClaim: { [weak dataStore] in
                    // The bound must outlast the provider's slowest refresh: usage fetch (10s timeout)
                    // + token refresh (15s) + usage retry (10s) + reset-credit fetch (10s) ≈ 45s. The
                    // common race (the periodic timer's probe) clears in a couple of seconds; the
                    // pathological one keeps the popover's honest "Resetting…" up rather than showing
                    // a success banner over pre-claim meters. A `.failed` probe is retried a few times
                    // too — a transient flake right after the claim must not strand pre-claim meters
                    // behind a success banner — before giving up loudly (the provider error already
                    // shows on the card, so the staleness isn't silent).
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

        // Anonymous usage telemetry (mandatory daily activity and crashes, optional provider rollups).
        // Its state lives in a dedicated UserDefaults suite, kept separate from app settings so the user's
        // optional-analytics choice and the install id stay independent of any settings change. The
        // snapshot closure reads the live layout/enablement so `app_daily_active` always reflects
        // the current configuration.
        let telemetryStore = TelemetryStore()
        let telemetry = TelemetryRecorder(
            sink: PostHogTelemetrySink(enabled: telemetryStore.enabled),
            store: telemetryStore,
            snapshot: { [registry, enablement, layout] in
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
        self.localAPI = LocalUsageServer(state: { [layout, enablement, dataStore, accounts] in
            LocalUsageAPI.State(
                enabledOrderedIDs: layout.orderedProviderIDs().filter { enablement.isEnabled($0) },
                knownIDs: Set(registry.providers.map(\.id)),
                snapshots: dataStore.snapshots,
                limitDescriptors: registry.limitDescriptorsByProvider,
                errors: dataStore.providerErrors
            )
            .resolvingDisplayNames(accounts.resolvedDisplayNamesByCardID)
        })
        self.refreshTask = Self.startPeriodicRefresh(dataStore: dataStore, telemetry: telemetry)
        self.accountGraphWatchTask = Self.startAccountGraphWatch(
            accounts: accounts,
            initialAssembly: accountAssembly
        )
        localAPI.start()
        // Become the notification-center delegate so banners show while frontmost — a menu-bar accessory
        // effectively always is. Notification authorization is requested the first time a trigger is
        // turned on in Settings, not at launch — triggers default off. No-op under tests.
        AppNotifications.shared.registerAsDelegate()
    }

    deinit {
        refreshTask.cancel()
        seedTask?.cancel()
        newProviderTask?.cancel()
        shellEnvironmentSnapshotTask.cancel()
        accountGraphWatchTask.cancel()
    }

    /// Stop every long-lived service before the AppDelegate installs the replacement graph.
    func shutdownForAccountGraphReload() async {
        accountGraphWatchTask.cancel()
        refreshTask.cancel()
        seedTask?.cancel()
        newProviderTask?.cancel()
        shellEnvironmentSnapshotTask.cancel()
        iCloudSync.shutdownForAccountGraphReload()
        await localAPI.stop()
    }

    func displayName(for provider: Provider) -> String {
        accounts.resolvedDisplayName(cardID: provider.id) ?? provider.displayName
    }

    func displayName(for providerID: String) -> String {
        accounts.resolvedDisplayName(cardID: providerID)
            ?? registry.provider(id: providerID)?.displayName
            ?? providerID
    }

    func canRename(_ providerID: String) -> Bool {
        accounts.runtimeRecord(for: providerID) != nil
    }

    /// Re-runs first-launch credential detection on demand — the enablement half of the Customize
    /// "Reset All" action (`LayoutStore.resetToDefault` handles metrics, order, pins, and expansion).
    /// Delegates to `FirstRunSeeder.reseed`; returns its detection task so callers can await it.
    @discardableResult
    func reseedEnabledProviders() -> Task<Void, Never> {
        FirstRunSeeder.reseed(providers: providers, enablement: enablement)
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

    /// Watch one tiny default-home identity file every five seconds, and only walk config dirs and
    /// Cowork sandboxes after a detected swap or once a minute. The potentially hundreds of identity
    /// files are collected off the main actor; account-store reconciliation alone returns to it.
    private static func startAccountGraphWatch(
        accounts: ProviderAccountsStore,
        initialAssembly: ProviderAccountAssembly
    ) -> Task<Void, Never> {
        let initialDefaultIdentity = DefaultAccountObserver().observeClaude()
        return Task { @MainActor in
            var previousDefaultIdentity = initialDefaultIdentity
            var checksSinceFullDiscovery = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let currentDefaultIdentity = DefaultAccountObserver().observeClaude()
                checksSinceFullDiscovery += 1
                let defaultChanged = currentDefaultIdentity != previousDefaultIdentity
                guard defaultChanged || checksSinceFullDiscovery >= 12 else { continue }

                previousDefaultIdentity = currentDefaultIdentity
                checksSinceFullDiscovery = 0
                let preparedDiscovery = await prepareAccountDiscovery()
                guard !Task.isCancelled else { return }
                guard DefaultAccountObserver().observeClaude() == currentDefaultIdentity else {
                    AppLog.info(.config, "accounts: default login changed during discovery; retrying with a fresh graph scan")
                    continue
                }
                let currentAssembly = ProviderAccountAssembly.make(
                    accountsStore: accounts,
                    waitsForLoginShell: true,
                    preparedDiscovery: preparedDiscovery
                )
                guard !Task.isCancelled else { return }
                guard currentAssembly.claudeCards != initialAssembly.claudeCards
                    || currentAssembly.identityKeysByCard != initialAssembly.identityKeysByCard
                    || currentAssembly.allowsUnboundClaudeFallback != initialAssembly.allowsUnboundClaudeFallback
                else { continue }

                AppLog.info(.config, "accounts: verified account sources changed; rebuilding the runtime graph")
                NotificationCenter.default.post(
                    name: Self.accountGraphDidChangeNotification,
                    object: nil
                )
                return
            }
        }
    }

    /// Collect blocking filesystem/keychain-attribute discovery on a detached utility executor.
    /// Cancelling the graph watcher also cancels its detached scan; no stale result may reconcile.
    static func prepareAccountDiscovery(
        configScan: @escaping @Sendable () -> ClaudeConfigDirDiscovery.Result = {
            ClaudeConfigDirDiscovery().run()
        },
        coworkScan: @escaping @Sendable () -> ClaudeCoworkDiscovery.Result = {
            ClaudeCoworkDiscovery().run()
        }
    ) async -> PreparedProviderAccountDiscovery {
        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled else {
                return PreparedProviderAccountDiscovery(
                    config: ClaudeConfigDirDiscovery.Result(),
                    cowork: ClaudeCoworkDiscovery.Result(truncated: true)
                )
            }
            let config = configScan()
            guard !Task.isCancelled else {
                return PreparedProviderAccountDiscovery(
                    config: config,
                    cowork: ClaudeCoworkDiscovery.Result(truncated: true)
                )
            }
            return PreparedProviderAccountDiscovery(config: config, cowork: coworkScan())
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
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
