import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    static func make(
        defaults: UserDefaults = .standard,
        claude: ClaudeRuntimePlan = ClaudeRuntimePlan()
    ) -> [ProviderRuntime] {
        var runtimes: [ProviderRuntime] = []

        if claude.cards.isEmpty, claude.allowsUnboundFallback {
            // Preserve the existing spend-only / unresolved-identity behavior when discovery
            // cannot prove any Claude account. Once an account is verified, every Claude runtime
            // comes from its record instead; there is never a second hardcoded default card.
            runtimes.append(ClaudeProvider(
                authStore: ClaudeAuthStore(
                    allowsUnpinnedStandardDesktopFallback: claude.defaultCoworkRoots == nil
                ),
                logUsageScanner: ClaudeLogUsageScanner(
                    coworkRootsOverride: claude.defaultCoworkRoots
                )
            ))
        } else {
            runtimes += claude.cards.map(claudeAccountRuntime)
        }

        // The three established families remain first, followed by the alphabetical provider tail.
        // Account instances sit together before Codex regardless of which one holds the default.
        runtimes += [
            CodexProvider(),
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

    private static func claudeAccountRuntime(_ card: ClaudeAccountCard) -> ClaudeProvider {
        let authStore: ClaudeAuthStore
        let scanner: ClaudeLogUsageScanner

        switch card.credential {
        case .defaultHome:
            authStore = ClaudeAuthStore(
                scope: .standard,
                desktopAccessPolicy: card.desktopAccess,
                allowsUnscopedStandardKeychainFallback: card.allowsUnscopedKeychainFallback
            )
            scanner = ClaudeLogUsageScanner(
                cacheIdentityOverride: card.id == "claude" ? nil : "claude-account:\(card.id)",
                additionalRoots: card.additionalLogRoots,
                coworkRootsOverride: card.coworkRootsOverride
            )
        case .configDir(let path, let keychainLiteral):
            authStore = ClaudeAuthStore(
                scope: .configDir(path: path, keychainLiteral: keychainLiteral)
            )
            scanner = ClaudeLogUsageScanner(
                cacheIdentityOverride: "claude-account:\(card.id)",
                rootsOverride: card.logRoots
            )
        case .desktop(let organization):
            authStore = ClaudeAuthStore(scope: .desktopOnly(organization: organization))
            scanner = ClaudeLogUsageScanner(
                cacheIdentityOverride: "claude-account:\(card.id)",
                rootsOverride: card.logRoots
            )
        }

        return ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: card.id, displayName: card.displayName),
            authStore: authStore,
            logUsageScanner: scanner,
            expectedIdentityKey: card.identityKey
        )
    }
}
