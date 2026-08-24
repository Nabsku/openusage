import Foundation

/// A complete identity universe is assembled before any source is folded or accepted. Partial
/// Cowork identities still inform Desktop safety, but cannot create cards or route spend logs.
@MainActor
struct ClaudeSourceObservations {
    struct FamilyOutcome {
        let family: String
        let outcome: DefaultAccountObserver.Outcome
    }

    let outcomes: [FamilyOutcome]
    let defaultOutcome: DefaultAccountObserver.Outcome?
    let config: ClaudeConfigDirDiscovery.Result?
    let cowork: ClaudeCoworkDiscovery.Result?
    let knownIdentities: Set<String>
    let preferredIdentities: [String: String]
    let desktopPolicy: ClaudeDesktopAccountPolicy

    static func observe(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        families: Set<String>,
        claudeDiscovery: ClaudeConfigDirDiscovery?,
        coworkDiscovery: ClaudeCoworkDiscovery?,
        preparedDiscovery: PreparedProviderAccountDiscovery?
    ) -> Self {
        let outcomes: [FamilyOutcome] = [
            ("claude", { observer.observeClaude() }),
            ("codex", { observer.observeCodex() }),
        ].compactMap { family, observe in
            families.contains(family) ? FamilyOutcome(family: family, outcome: observe()) : nil
        }
        let defaultOutcome = outcomes.first { $0.family == "claude" }?.outcome
        if case .unresolved? = defaultOutcome {
            AppLog.info(.config, "discovery: claude default identity is unreadable; checking independently verified config-dir and Desktop accounts")
        }

        let config = defaultOutcome != nil
            ? preparedDiscovery?.config ?? claudeDiscovery?.run()
            : nil
        let cowork = defaultOutcome != nil
            ? preparedDiscovery?.cowork ?? coworkDiscovery?.run()
            : nil
        for note in (config?.notes ?? []) + (cowork?.notes ?? []) {
            AppLog.info(.config, "discovery: \(note)")
        }

        var knownIdentities = Set(
            accountsStore.records
                .filter { $0.family == "claude" }
                .flatMap { [$0.identityKey] + ($0.identityAliases ?? []) }
        )
        if case .resolved(let identity, _, _)? = defaultOutcome {
            knownIdentities.insert(identity)
        }
        for finding in config?.findings ?? [] {
            knownIdentities.insert(finding.identityKey)
        }
        if cowork?.truncated != true {
            for sandbox in cowork?.sandboxes ?? [] {
                if let identity = sandbox.identityKey { knownIdentities.insert(identity) }
            }
        }

        var preferredIdentities: [String: String] = [:]
        if case .resolved(let raw, _, _)? = defaultOutcome,
           let identity = ClaudeIdentity(raw)
        {
            preferredIdentities[identity.user] = identity.key
        }
        for finding in config?.findings ?? [] {
            guard let identity = ClaudeIdentity(finding.identityKey),
                  preferredIdentities[identity.user] == nil
            else { continue }
            preferredIdentities[identity.user] = identity.key
        }

        return Self(
            outcomes: outcomes,
            defaultOutcome: defaultOutcome,
            config: config,
            cowork: cowork,
            knownIdentities: knownIdentities,
            preferredIdentities: preferredIdentities,
            desktopPolicy: ClaudeDesktopAccountPolicy(
                records: accountsStore.records,
                defaultOutcome: defaultOutcome,
                configFindings: config?.findings ?? [],
                coworkScan: cowork
            )
        )
    }

    func canonicalIdentity(_ raw: String) -> String? {
        ClaudeIdentity.canonical(raw, among: knownIdentities, preferred: preferredIdentities)
    }
}

/// Credential-bearing default/config sources choose the identity spelling a bound runtime can
/// verify; Cowork partitions may attach roots later, but never change that source ownership.
@MainActor
struct ClaudeAccountPlan {
    struct Account {
        var identityKey: String
        var label: String?
        var sources: [ProviderAccountSource]
        var credential: ClaudeAccountCard.Credential
        var logRoots: [URL]
        var additionalLogRoots: [URL] = []
    }

    var identityKeysByCard: [String: String] = [:]
    var otherObservations: [ProviderAccountsStore.AccountObservation] = []
    var accounts: [String: Account] = [:]
    var orderedIdentities: [String] = []
    var defaultIdentity: String?

    static func make(from observed: ClaudeSourceObservations) -> Self {
        var plan = Self()
        plan.observeDefaults(observed)
        plan.attachConfigDirectories(observed)
        return plan
    }

    private mutating func observeDefaults(_ observed: ClaudeSourceObservations) {
        for familyOutcome in observed.outcomes {
            let family = familyOutcome.family
            switch familyOutcome.outcome {
            case .resolved(let rawIdentity, let label, let anchor):
                let identity: String
                if family == "claude" {
                    guard let canonical = observed.canonicalIdentity(rawIdentity) else {
                        AppLog.warn(.config, "accounts: claude default identity omits its organization while multiple organizations share that login; source quarantined")
                        continue
                    }
                    identity = canonical
                    defaultIdentity = canonical
                    orderedIdentities.append(canonical)
                    accounts[canonical] = Account(
                        identityKey: canonical,
                        label: label,
                        sources: [ProviderAccountSource(
                            kind: .defaultHome, anchor: anchor, holdsDefaultSource: true
                        )],
                        credential: .defaultHome,
                        logRoots: [URL(fileURLWithPath: anchor)]
                    )
                } else {
                    identity = rawIdentity
                    otherObservations.append(ProviderAccountsStore.AccountObservation(
                        family: family,
                        identityKey: identity,
                        label: label,
                        sources: [ProviderAccountSource(
                            kind: .defaultHome, anchor: anchor, holdsDefaultSource: true
                        )]
                    ))
                    identityKeysByCard[family] = identity
                }
                AppLog.info(.config, "accounts: \(family) default identity resolved (\(ProviderAccountID.make(family: family, identityKey: identity)))")
            case .unresolved(let reason):
                AppLog.info(.config, "accounts: \(family) default identity unresolved — \(reason)")
            case .absent:
                AppLog.debug(.config, "accounts: \(family) has no default login")
            }
        }
    }

    private mutating func attachConfigDirectories(_ observed: ClaudeSourceObservations) {
        for finding in observed.config?.findings ?? [] {
            guard let identity = observed.canonicalIdentity(finding.identityKey) else {
                AppLog.warn(.config, "discovery: claude config-dir identity omits its organization while multiple organizations share that login; source quarantined")
                continue
            }
            let source = ProviderAccountSource(
                kind: .configDir,
                anchor: finding.anchorPath,
                holdsDefaultSource: false,
                keychainLiteral: finding.keychainLiteral
            )
            let root = URL(fileURLWithPath: finding.anchorPath)
            if var account = accounts[identity] {
                appendUnique(source, to: &account.sources)
                appendUnique(root, to: &account.logRoots)
                if account.credential == .defaultHome {
                    appendUnique(root, to: &account.additionalLogRoots)
                }
                if account.label == nil { account.label = finding.label }
                accounts[identity] = account
            } else {
                orderedIdentities.append(identity)
                accounts[identity] = Account(
                    identityKey: identity,
                    label: finding.label,
                    sources: [source],
                    credential: .configDir(
                        path: finding.anchorPath,
                        keychainLiteral: finding.keychainLiteral
                    ),
                    logRoots: [root]
                )
            }
        }
    }
}

/// Cowork discovery changes spend routing and Desktop candidates only after their ownership has
/// been proven. A partial scan remains account-safety evidence but contributes no spend roots.
@MainActor
struct ClaudeCoworkPartition {
    var defaultRoots: [URL] = []
    var requiresPartition = false

    static func make(
        from observed: ClaudeSourceObservations,
        plan: inout ClaudeAccountPlan,
        hasDesktopCredentialMaterial: @Sendable () -> Bool
    ) -> Self {
        var partition = Self()
        var unidentifiedRoots: [URL] = []
        var desktopCredentialMaterial: Bool?

        if let scan = observed.cowork, !scan.truncated {
            for sandbox in scan.sandboxes {
                guard let rawIdentity = sandbox.identityKey else {
                    unidentifiedRoots.append(sandbox.root)
                    continue
                }
                guard let identity = observed.canonicalIdentity(rawIdentity) else {
                    partition.requiresPartition = true
                    AppLog.warn(.config, "discovery: cowork sandbox identity omits its organization while multiple organizations share that login; sandbox quarantined")
                    continue
                }
                if identity == plan.defaultIdentity {
                    appendUnique(sandbox.root, to: &partition.defaultRoots)
                    continue
                }

                partition.requiresPartition = true
                let hasAmbiguousOwner = observed.desktopPolicy.hasAmbiguousOrganization(
                    sandbox.organization
                )
                let desktopSource = ProviderAccountSource(
                    kind: .desktop, anchor: nil, holdsDefaultSource: false
                )
                if var account = plan.accounts[identity] {
                    appendUnique(sandbox.root, to: &account.logRoots)
                    if sandbox.organization != nil && !hasAmbiguousOwner {
                        appendUnique(desktopSource, to: &account.sources)
                    } else if hasAmbiguousOwner {
                        AppLog.warn(.config, "discovery: cowork organization names multiple account owners; Desktop credential source quarantined")
                    }
                    if account.label == nil { account.label = sandbox.label }
                    plan.accounts[identity] = account
                    continue
                }

                guard let organization = sandbox.organization?.nilIfEmpty else {
                    AppLog.warn(.config, "discovery: cowork account \(ProviderAccountID.make(family: "claude", identityKey: identity)) has no organization pin; sandbox quarantined")
                    continue
                }
                guard !hasAmbiguousOwner else {
                    AppLog.warn(.config, "discovery: cowork organization names multiple account owners; Desktop-only account quarantined")
                    continue
                }
                if desktopCredentialMaterial == nil {
                    desktopCredentialMaterial = hasDesktopCredentialMaterial()
                }
                guard desktopCredentialMaterial == true else {
                    AppLog.info(.config, "discovery: cowork account \(ProviderAccountID.make(family: "claude", identityKey: identity)) has no current Desktop credential material; historical sandbox skipped")
                    continue
                }
                plan.orderedIdentities.append(identity)
                plan.accounts[identity] = ClaudeAccountPlan.Account(
                    identityKey: identity,
                    label: sandbox.label,
                    sources: [desktopSource],
                    credential: .desktop(organization: organization),
                    logRoots: [sandbox.root]
                )
            }
        }

        if plan.accounts.count > 1 { partition.requiresPartition = true }
        if !unidentifiedRoots.isEmpty, partition.requiresPartition {
            AppLog.warn(.config, "discovery: \(unidentifiedRoots.count) unidentified cowork sandbox(es) quarantined because account ownership cannot be proven")
        }
        if observed.cowork?.truncated == true {
            partition.requiresPartition = true
            partition.defaultRoots = []
            AppLog.warn(.config, "discovery: cowork scan truncated; cowork spend withheld until a complete scan proves account ownership")
        }
        return partition
    }
}

private func appendUnique<Value: Equatable>(_ value: Value, to values: inout [Value]) {
    if !values.contains(value) { values.append(value) }
}
