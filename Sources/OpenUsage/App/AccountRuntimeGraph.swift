import Foundation
import Observation

/// Account-bound services can change without replacing the status item, HTTP listener, or telemetry.
@MainActor
@Observable
final class AccountRuntimeGraph {
    struct State {
        let registry: WidgetRegistry
        let layout: LayoutStore
        let dataStore: WidgetDataStore
        let snapshotCache: ProviderSnapshotCache
        let iCloudSync: ICloudUsageSyncStore
        let providers: [ProviderRuntime]
        let apiKeyProviders: [any APIKeyManaging]
        let codexResetClaim: CodexResetClaimService?
    }

    var state: State
    @ObservationIgnored var runtimeTasks: AccountRuntimeTaskLifetime?
    @ObservationIgnored var accountWatcher: AccountRuntimeTaskLifetime?
    @ObservationIgnored var resetDetection: AccountRuntimeTaskLifetime?

    init(state: State) {
        self.state = state
    }

    func retireCurrentState() {
        state.codexResetClaim?.retireForAccountGraphReload()
        state.dataStore.retireForAccountGraphReload()
        runtimeTasks = nil
        resetDetection = nil
        state.iCloudSync.shutdownForAccountGraphReload()
    }
}

/// Task handles are Sendable, so destruction cancels them safely even outside the main actor.
final class AccountRuntimeTaskLifetime: Sendable {
    private let tasks: [Task<Void, Never>]

    init(_ tasks: [Task<Void, Never>?]) {
        self.tasks = tasks.compactMap { $0 }
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }
}
