import Foundation

/// Seeds a fresh install's enabled providers so the first launch shows only the tools the user
/// actually has, instead of every provider OpenUsage knows about.
///
/// Two steps, both on the first launch only (existing installs keep their all-on legacy default and
/// are never touched):
/// 1. **Synchronously** switch `ProviderEnablementStore` into enabled-list mode with the established
///    fallback set (Claude, Codex, Cursor), so the dashboard and menu bar never flash all providers.
/// 2. **Asynchronously** probe every provider's `hasLocalCredentials()` (local files/keychain only, no
///    network) and replace the fallback with exactly the detected set — unless nothing was detected
///    (keep the fallback) or the user already touched the toggles while the probe ran (their choice wins).
@MainActor
enum FirstRunSeeder {
    /// The established providers (see AGENTS.md "## Providers"), shown when detection finds nothing.
    static let fallbackProviderIDs: Set<String> = ["claude", "codex", "cursor"]

    /// Returns the detection task (for tests to await), or `nil` when no seeding happened. The
    /// `enabledIDs == nil` guard makes seeding idempotent: an already-seeded store (e.g. an unbundled
    /// `swift run`, which always reports fresh) is never overwritten.
    @discardableResult
    static func seedIfNeeded(
        isFreshInstall: Bool,
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore,
        onboarding: OnboardingStore,
        deferDetectionUntilDiscovery: Bool = false
    ) -> Task<Void, Never>? {
        guard isFreshInstall, enablement.enabledIDs == nil else { return nil }

        // Persist the unfinished job before marking providers known, so an interrupted launch can
        // still distinguish an outstanding first-run check from a completed one.
        let task: Task<Void, Never>?
        if deferDetectionUntilDiscovery {
            let providerIDs = Set(providers.map(\.provider.id))
            let fallback = fallbackProviderIDs.intersection(providerIDs)
            enablement.seedEnabledProviders(fallback)
            enablement.beginProviderDetection(providerIDs, mode: .replacement, baseline: fallback)
            AppLog.info(.config, "first run: seeded providers \(fallback.sorted()); awaiting verified account discovery")
            task = nil
        } else {
            task = seedFallbackThenDetect(providers: providers, enablement: enablement, logPrefix: "first run")
        }
        enablement.registerKnownProviders(Set(providers.map(\.provider.id)))
        onboarding.markCustomizeHintPending()
        return task
    }

    /// Re-runs first-launch detection on demand for the Customize "Reset All" action. Unlike first-run
    /// and update-time seeding, this is a deliberate user reset, so it *does* overwrite the current
    /// on/off choices: it snaps the enabled set to the Claude/Codex/Cursor fallback synchronously (so the
    /// dashboard reflects the reset without waiting on the probe), then replaces it with exactly the
    /// providers detected on this machine once the local credential probe finishes — keeping the fallback
    /// when nothing is detected. A toggle the user flips during the (brief, local-only) probe still wins.
    /// Returns the detection task so tests and callers can await it.
    @discardableResult
    static func reseed(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore
    ) -> Task<Void, Never> {
        seedFallbackThenDetect(providers: providers, enablement: enablement,
                               logPrefix: "reset all", probeVerb: "re-probing")
    }

    /// The shared seed→probe→replace sequence behind both first-run seeding and the "Reset All" reseed:
    /// synchronously snap the enabled set to the `fallbackProviderIDs` intersected with the known
    /// providers (so the UI never waits on the probe), then off the main actor detect installed tools and
    /// replace the fallback with exactly the detected set. The guard encodes two policies that must stay
    /// together: a toggle the user flipped during the (brief, local-only) probe wins over detection, and
    /// an empty detection keeps the fallback. Returns the detection task so callers/tests can await it.
    private static func seedFallbackThenDetect(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore,
        logPrefix: String,
        probeVerb: String = "probing"
    ) -> Task<Void, Never> {
        let providerIDs = Set(providers.map(\.provider.id))
        let fallback = fallbackProviderIDs.intersection(providerIDs)
        enablement.seedEnabledProviders(fallback)
        enablement.beginProviderDetection(providerIDs, mode: .replacement, baseline: fallback)
        AppLog.info(.config, "\(logPrefix): seeded providers \(fallback.sorted()); \(probeVerb) local credentials")
        return resumeDetection(providers: providers, enablement: enablement, logPrefix: logPrefix)
    }

    static func resumeDetection(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore,
        logPrefix: String
    ) -> Task<Void, Never> {
        let providerIDs = Set(providers.map(\.provider.id)).intersection(enablement.pendingDetectionIDs)
        let pendingProviders = providers.filter { providerIDs.contains($0.provider.id) }
        return Task {
            let detected = await detectLocalProviders(pendingProviders)
            guard !Task.isCancelled else { return }
            defer { enablement.finishProviderDetection(providerIDs) }
            AppLog.info(.config, "\(logPrefix): detected credentials for \(detected.sorted())")
            guard let job = enablement.detectionJob else { return }
            let pendingDetected = detected.intersection(job.ids)

            switch job.mode {
            case .replacement:
                guard enablement.enabledIDs == job.baseline, !pendingDetected.isEmpty else { return }
                let honoringUserChoices = pendingDetected.union(job.baseline.subtracting(job.ids))
                enablement.seedEnabledProviders(honoringUserChoices)
            case .additive:
                for id in pendingDetected.sorted() {
                    guard !Task.isCancelled else { return }
                    guard enablement.pendingDetectionIDs.contains(id), !enablement.isEnabled(id) else { continue }
                    AppLog.info(.config, "new provider \(id): credentials detected, enabling")
                    enablement.setEnabled(true, for: id)
                }
            }
        }
    }

    /// Local-only credential probe across every provider: the set whose `hasLocalCredentials()` (config
    /// files/keychain, never the network) reports a login on this machine. Shared by first-run seeding,
    /// `NewProviderSeeder`, and the Customize "Reset All" reseed so all detect installed tools the same way.
    ///
    /// Probes run concurrently — the same MainActor-safe fan-out as `WidgetDataStore.refreshAll` (one
    /// `Task {}` per provider; the overlap happens at the off-main-actor loads inside each probe). A
    /// single probe can shell out to `security`/`sqlite3` with waits of up to ~5s, so probing the whole
    /// registry sequentially made detection take the *sum* of those waits — long enough that detected
    /// providers visibly trickled in on first launch.
    static func detectLocalProviders(_ providers: [ProviderRuntime]) async -> Set<String> {
        let probes = providers.map { provider in
            (provider.provider.id, Task { await provider.hasLocalCredentials() })
        }
        return await withTaskCancellationHandler {
            var detected = Set<String>()
            for (id, probe) in probes {
                guard !Task.isCancelled else { return detected }
                if await probe.value { detected.insert(id) }
            }
            return detected
        } onCancel: {
            for (_, probe) in probes { probe.cancel() }
        }
    }
}
