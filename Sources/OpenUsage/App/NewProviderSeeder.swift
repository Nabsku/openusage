import Foundation

/// Turns on providers that arrived with an update — but only the ones the user actually has.
///
/// `FirstRunSeeder` handles the very first launch; this is its every-later-launch sibling. It diffs the
/// registry against the store's known-provider set: anything never seen before gets the same local-only
/// `hasLocalCredentials()` probe as first-run detection, and is enabled on a hit. Providers the install
/// has already seen are never touched, so a user's choice to keep one off is never overridden.
///
/// One-shot semantics: new IDs are marked known synchronously, before the probe. A new provider without
/// credentials stays off and is never probed again — enabling it later is the user's call.
@MainActor
enum NewProviderSeeder {
    /// Returns the detection task (for tests to await), or `nil` when there is nothing to do — the
    /// common case: no new providers, or a store still in legacy disabled-list mode (where new providers
    /// default to on already, so there is nothing to detect).
    @discardableResult
    static func reconcileIfNeeded(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore
    ) -> Task<Void, Never>? {
        guard enablement.enabledIDs != nil else { return nil }

        let currentIDs = Set(providers.map(\.provider.id))
        // An enabled-list store with no known set predates the tracking (an unbundled `swift run`
        // seeded before this shipped — bundled installs get it from the v2 settings migration or
        // `FirstRunSeeder`). Baseline it to the current registry without probing: we can't tell "new"
        // from "user turned it off", so auto-enabling anything here could override a real choice.
        guard !enablement.knownIDs.isEmpty || enablement.detectionJob != nil else {
            enablement.registerKnownProviders(currentIDs)
            return nil
        }

        let newIDs = currentIDs.subtracting(enablement.knownIDs)
        let pendingIDs = enablement.pendingDetectionIDs.intersection(currentIDs)
        let detectionIDs = newIDs.union(pendingIDs)
        guard !detectionIDs.isEmpty else {
            if enablement.detectionJob?.mode == .replacement {
                enablement.finishProviderDetection(enablement.pendingDetectionIDs.subtracting(currentIDs))
            }
            return nil
        }
        if let job = enablement.detectionJob,
           job.mode == .replacement,
           enablement.enabledIDs == job.baseline
        {
            enablement.beginProviderDetection(detectionIDs, mode: .replacement, baseline: job.baseline)
        } else {
            enablement.beginProviderDetection(
                detectionIDs,
                mode: .additive,
                baseline: enablement.enabledIDs ?? []
            )
        }
        enablement.registerKnownProviders(currentIDs)
        AppLog.info(
            .config,
            "new or interrupted provider checks: \(detectionIDs.sorted()); probing local credentials"
        )
        return FirstRunSeeder.resumeDetection(
            providers: providers,
            enablement: enablement,
            logPrefix: "new or interrupted provider checks"
        )
    }
}
