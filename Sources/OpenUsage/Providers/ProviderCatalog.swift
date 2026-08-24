import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    /// `claudeCards` carries the extra Claude account cards found by the launch account pass
    /// (`ProviderAccountAssembly`). Each becomes an ordinary runtime inserted right after the default
    /// Claude card, with credentials and usage logs pinned to exactly its own config dir. The empty
    /// default keeps the historical single-card set for focused tests and callers that intentionally
    /// skip the account pass.
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        defaultClaudeExtraLogRoots: [URL] = [],
        defaultClaudeDisplayName: String? = nil,
        defaultClaudeCardID: String = "claude",
        defaultClaudeVerifiedIdentityAliases: Set<ClaudeIdentity> = [],
        claudeIdentityKeys: [String: String] = [:],
        allowsUnboundClaudeFallback: Bool = true,
        isClaudeDiscoveryComplete: Bool = true,
        allowsUnownedClaudeDesktopFallback: Bool = false,
        defaultClaudeCoworkRoots: [URL]? = nil,
        defaultClaudeDesktopAccess: ClaudeDesktopAccessPolicy? = nil
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name. Account cards slot in right after
        // their family's default card.
        //
        // Every baked `Provider.displayName` here is the DERIVED default — renames live only in the
        // account registry and are resolved at render time (`ProviderAccountRecord.resolvedDisplayName`),
        // so a baked name can never be a stale copy of one.
        var runtimes: [ProviderRuntime] = []
        if (claudeIdentityKeys[defaultClaudeCardID] != nil
            || (claudeCards.isEmpty && allowsUnboundClaudeFallback))
            && !claudeCards.contains(where: { $0.id == defaultClaudeCardID })
        {
            runtimes.append(ClaudeProvider(
                provider: ClaudeProvider.makeProvider(
                    id: defaultClaudeCardID,
                    displayName: defaultClaudeDisplayName ?? "Claude"
                ),
                authStore: ClaudeAuthStore(
                    expectedIdentityKey: claudeIdentityKeys[defaultClaudeCardID],
                    verifiedIdentityAliases: defaultClaudeVerifiedIdentityAliases,
                    desktopAccessPolicy: defaultClaudeDesktopAccess
                        ?? (claudeCards.isEmpty
                            && (isClaudeDiscoveryComplete || allowsUnownedClaudeDesktopFallback)
                            ? .activeOrganization : .denied),
                    allowsUnscopedStandardKeychainFallback: claudeCards.isEmpty
                        && isClaudeDiscoveryComplete
                        && defaultClaudeDesktopAccess != .denied
                ),
                logUsageScanner: ClaudeLogUsageScanner(
                    additionalRoots: defaultClaudeExtraLogRoots,
                    coworkRootsOverride: defaultClaudeCoworkRoots
                ),
                allowsUnattributedPiUsage: claudeCards.isEmpty && isClaudeDiscoveryComplete
            ))
        }
        for card in claudeCards {
            runtimes.append(claudeAccountRuntime(card: card))
        }
        runtimes.sort { $0.provider.id == "claude" && $1.provider.id != "claude" }
        runtimes += [
            CodexProvider(expectedIdentityKey: claudeIdentityKeys["codex"]),
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(defaults: defaults),
            DevinProvider(),
            GrokProvider(),
            OpenCodeProvider(),
            OpenRouterProvider(),
            ZAIProvider()
        ]
        return runtimes
    }

    /// An extra Claude account card: same provider machinery, credentials and logs pinned to one
    /// login (a config-dir home, or Claude Desktop's org-pinned cache for a Cowork account). The
    /// scanner's parse cache is partitioned per card so distinct homes never share records.
    private static func claudeAccountRuntime(card: ClaudeAccountCard) -> ClaudeProvider {
        let scope: ClaudeCredentialScope = switch card.credential {
        case .configDir(let path, let keychainLiteral):
            .configDir(path: path, keychainLiteral: keychainLiteral)
        case .desktop(let organization):
            .desktopOnly(organization: organization)
        }
        return ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: card.id, displayName: card.displayName),
            authStore: ClaudeAuthStore(
                scope: scope,
                expectedIdentityKey: card.identityKey,
                verifiedIdentityAliases: card.verifiedIdentityAliases
            ),
            logUsageScanner: ClaudeLogUsageScanner(
                cacheIdentityOverride: "claude-account:\(card.id)",
                rootsOverride: card.logRoots
            )
        )
    }
}
