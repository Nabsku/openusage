import CryptoKit
import Foundation

struct ClaudeAuthStore: Sendable {
    private static let defaultClaudeHome = "~/.claude"
    private static let credentialFileName = ".credentials.json"
    private static let keychainServicePrefix = "Claude Code"
    private static let prodBaseAPIURL = "https://api.anthropic.com"
    private static let prodRefreshURL = "https://platform.claude.com/v1/oauth/token"
    private static let prodClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let nonProdClientID = "22422756-60c9-4084-8eb7-27705fd5cf9a"

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var desktop: ClaudeDesktopAuthStore
    var homeDirectory: @Sendable () -> URL
    var now: @Sendable () -> Date
    let scope: ClaudeCredentialScope
    let expectedIdentityKey: String?
    /// Aliases explicitly verified against this card's selected credential source at launch.
    let verifiedIdentityAliases: Set<ClaudeIdentity>
    let desktopAccessPolicy: ClaudeDesktopAccessPolicy
    let allowsUnscopedStandardKeychainFallback: Bool

    var standardDesktopOrganization: String? { desktopAccessPolicy.organization }
    var allowsUnpinnedStandardDesktopFallback: Bool { desktopAccessPolicy == .activeOrganization }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        desktop: ClaudeDesktopAuthStore? = nil,
        scope: ClaudeCredentialScope = .standard,
        expectedIdentityKey: String? = nil,
        verifiedIdentityAliases: Set<ClaudeIdentity> = [],
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        desktopAccessPolicy: ClaudeDesktopAccessPolicy? = nil,
        allowsUnscopedStandardKeychainFallback: Bool = true,
        standardDesktopOrganization: String? = nil,
        allowsUnpinnedStandardDesktopFallback: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.desktop = desktop ?? ClaudeDesktopAuthStore(files: files, now: now)
        self.homeDirectory = homeDirectory
        self.scope = scope
        self.expectedIdentityKey = expectedIdentityKey
        self.verifiedIdentityAliases = verifiedIdentityAliases
        self.allowsUnscopedStandardKeychainFallback = allowsUnscopedStandardKeychainFallback
        if let desktopAccessPolicy {
            self.desktopAccessPolicy = desktopAccessPolicy
        } else if let organization = standardDesktopOrganization?.nilIfEmpty?.lowercased() {
            self.desktopAccessPolicy = .pinned(organization)
        } else {
            self.desktopAccessPolicy = allowsUnpinnedStandardDesktopFallback ? .activeOrganization : .denied
        }
        self.now = now
    }

    /// All credential sources currently on disk/keychain, in fixed keychain-before-file order, for the
    /// refresh loop to try in order. The provider probes each and — on an auth-expiry error
    /// (`ClaudeAuthError.allowsAuthFallback`) — falls through to the next, so an external `claude`
    /// re-login is picked up no matter which source it lands in, even when a stale/locked-out token still
    /// sits in another. Re-read on every refresh; nothing is cached in memory.
    func loadCredentialSet(
        allowDesktopInteraction: Bool = false,
        forceDesktopFallback: Bool = false
    ) -> ClaudeCredentialLoad {
        var stored = orderedStoredCandidates()
        var desktopStatus: ClaudeDesktopCredentialStatus = .notChecked
        // A working CLI login remains the source of truth and avoids a second Keychain prompt. Desktop
        // is a fallback for people who only use the native app (or whose stored CLI login lacks profile
        // scope), never a competing account source. Scoped cards are stricter: a `.configDir` card
        // never consults Desktop at all (that login belongs to another card), and a `.desktopOnly`
        // card consults nothing else — always pinned to its own org.
        let access: ClaudeDesktopAccessPolicy
        switch scope {
        case .standard:
            access = desktopAccessPolicy
        case .desktopOnly(let organization):
            access = .pinned(organization)
        case .configDir:
            access = .denied
        }
        let desktopAllowed = access != .denied
        if forceDesktopFallback, !desktopAllowed {
            // Tell the provider there is no safe Desktop candidate so it preserves the original CLI
            // auth error instead of converting it to a generic "not logged in" result.
            desktopStatus = .notFound
        }
        let hasUsableCLILogin = stored.contains {
            $0.hasUsableAccessToken && liveUsageAvailability($0) == .available
        }
        if desktopAllowed, forceDesktopFallback || !hasUsableCLILogin {
            let result = desktop.load(allowInteraction: allowDesktopInteraction, organization: access.organization)
            desktopStatus = result.status
            if let oauth = result.oauth {
                stored.insert(ClaudeCredentialState(
                    oauth: oauth,
                    source: .desktop,
                    fullData: nil,
                    inferenceOnly: false
                ), at: 0)
            }
        }

        let candidates = applyingEnvironmentToken(to: stored)
        return ClaudeCredentialLoad(candidates: candidates, desktopStatus: desktopStatus)
    }

    func loadCredentialCandidates() -> [ClaudeCredentialState] {
        loadCredentialSet().candidates
    }

    /// Whether this scoped card's login leaves any local footprint, checked without ever reading a
    /// keychain secret — safe for the every-launch seeding probe (`NewProviderSeeder`), which must
    /// never raise a permission dialog. The `.standard` card keeps its richer
    /// `loadCredentialSet`-based probe in `ClaudeProvider.hasLocalCredentials`.
    func hasCredentialFootprint() -> Bool {
        switch scope {
        case .standard:
            return !loadCredentialSet().candidates.isEmpty
        case .configDir:
            if files.exists(credentialsPath()) { return true }
            return keychainServiceCandidates().contains {
                keychain.genericPasswordExists(service: $0) == true
            }
        case .desktopOnly:
            return desktop.hasCredentialMaterial()
        }
    }

    func belongsToExpectedAccount() -> Bool {
        guard let expectedIdentityKey else { return true }
        let identityPath: String
        switch scope {
        case .configDir(let path, _):
            identityPath = "\(path)/.claude.json"
        case .desktopOnly(let organization):
            guard let separator = expectedIdentityKey.firstIndex(of: "|") else { return false }
            return expectedIdentityKey[expectedIdentityKey.index(after: separator)...]
                .caseInsensitiveCompare(organization) == .orderedSame
        case .standard:
            let home = claudeHomeOverride() ?? Self.defaultClaudeHome
            guard !home.contains(",") else { return false }
            identityPath = DefaultAccountObserver.claudeLocation(
                configDir: home, homeDirectory: homeDirectory()
            ).identityPath
        }
        guard let text = try? files.readTextIfPresent(identityPath),
              let state = try? JSONDecoder().decode(
                DefaultAccountObserver.ClaudeStateFile.self, from: Data(text.utf8)
              ),
              let account = state.oauthAccount,
              let observed = DefaultAccountObserver.claudeIdentityKey(account)
        else { return false }
        guard let observedIdentity = ClaudeIdentity(observed),
              let expectedIdentity = ClaudeIdentity(expectedIdentityKey)
        else { return false }
        if observedIdentity == expectedIdentity { return true }
        return observedIdentity.user == expectedIdentity.user
            && observedIdentity.organization == nil
            && expectedIdentity.organization != nil
            && verifiedIdentityAliases.contains(observedIdentity)
    }

    private func applyingEnvironmentToken(to stored: [ClaudeCredentialState]) -> [ClaudeCredentialState] {
        // An ambient env token describes the DEFAULT login's environment; a scoped card must never
        // inherit it (that would leak one account's token into another account's card).
        guard case .standard = scope else { return stored }
        guard let envAccessToken = envText("CLAUDE_CODE_OAUTH_TOKEN") else {
            return stored
        }
        // An explicit `CLAUDE_CODE_OAUTH_TOKEN` is inference-only (typically a `claude setup-token`
        // token): it can run the model but 403s on the usage endpoint. It also reaches us when the user
        // only *ambiently* has it exported — OpenUsage captures the login-shell environment — so it must
        // not shadow a real interactive login that CAN read usage. Prefer any stored login able to fetch
        // live usage (keychain-first, then file) for the usage call, with the env token kept as a
        // trailing inference-only fallback for the refresh loop. With no live-capable stored login (a
        // genuinely headless setup) the env token is the only candidate — unchanged: spend tiles still
        // load. Nothing is silenced; only the credential SELECTED for the usage fetch changes.
        let liveCapable = stored.filter { liveUsageAvailability($0) == .available }
        // Borrow plan metadata (subscription type / scopes) for display from the credential actually
        // preferred — the live-capable login when there is one, else the first stored login — so the
        // fallback doesn't inherit metadata from a login we decided not to use. Source it honestly as
        // `.environment`: the token came from the env, so the refresh-start diagnostics name the real
        // source when the loop falls back to it, and `save()` correctly no-ops instead of writing an env
        // token back into the keychain under a borrowed source.
        let base = liveCapable.first ?? stored.first
        var oauth = base?.oauth ?? ClaudeOAuth()
        oauth.accessToken = envAccessToken
        let envCandidate = ClaudeCredentialState(
            oauth: oauth,
            source: .environment,
            fullData: base?.fullData,
            inferenceOnly: true
        )
        return liveCapable.isEmpty ? [envCandidate] : liveCapable + [envCandidate]
    }

    func needsRefresh(_ oauth: ClaudeOAuth) -> Bool {
        guard let expiresAt = oauth.expiresAt else { return false }
        return expiresAt - now().timeIntervalSince1970 * 1000 <= 5 * 60 * 1000
    }

    func credentialGeneration(forceDesktopFallback: Bool = false) -> ClaudeCredentialGeneration {
        ClaudeCredentialGeneration(loadCredentialSet(forceDesktopFallback: forceDesktopFallback).candidates)
    }

    /// Save an OAuth rotation only if the ordered effective candidate set is unchanged. Checking the
    /// whole generation catches a newly added higher-priority source as well as replacement in place.
    /// The underlying stores provide no atomic compare-and-swap, so this remains best-effort.
    func save(_ state: ClaudeCredentialState, ifUnchanged expected: ClaudeCredentialGeneration) throws -> Bool {
        guard belongsToExpectedAccount(), credentialGeneration() == expected else { return false }
        var fullData = state.fullData ?? ClaudeCredentialsFile()
        fullData.claudeAiOauth = state.oauth
        let data = try JSONEncoder().encode(fullData)
        guard let text = String(data: data, encoding: .utf8) else { return false }

        switch state.source {
        case .file:
            try files.writeText(credentialsPath(), text)
        case .keychainCurrentUser(let service):
            try keychain.writeGenericPasswordForCurrentUser(service: service, value: text)
        case .keychainLegacy(let service):
            try keychain.writeGenericPassword(service: service, value: text)
        case .desktop:
            return false
        case .environment:
            return false
        }
        // NEVER log the credential blob/tokens — only that a rotation was persisted, and to where.
        AppLog.debug(LogTag.auth("claude"), "persisted rotated credentials (source=\(state.source.label))")
        return true
    }

    /// Why the live-usage endpoint (`/api/oauth/usage`, which backs Session / Weekly / Sonnet / Extra
    /// Usage) can or can't be called for a credential. Reading usage requires the `user:profile` scope,
    /// so a token that only carries `user:inference` (e.g. one minted by `claude setup-token`) can't —
    /// and the provider surfaces that as a friendly "re-login" notice instead of silently blank bars.
    enum LiveUsageAvailability: Equatable, Sendable {
        case available
        /// An explicit `CLAUDE_CODE_OAUTH_TOKEN`: inference-only by design, so there's nothing to fetch
        /// and nothing to nag about — the spend tiles still load from local logs.
        case inferenceOnlyToken
        /// A stored login whose granted scopes lack `user:profile`. The usage endpoint would reject it,
        /// so the session/weekly bars can't load until the user signs in again with `claude`.
        case missingProfileScope
    }

    /// The required scope for the usage endpoint. A credential missing it can authenticate for inference
    /// but can't read subscription usage windows.
    static let usageScope = "user:profile"

    func liveUsageAvailability(_ state: ClaudeCredentialState) -> LiveUsageAvailability {
        if state.inferenceOnly { return .inferenceOnlyToken }
        // Older credentials predate the scopes field; treat an absent/empty list as "unknown, allow" so
        // we don't suppress usage for tokens that actually carry the access (and would 403 loudly if not).
        guard let scopes = state.oauth.scopes, !scopes.isEmpty else { return .available }
        return scopes.contains(Self.usageScope) ? .available : .missingProfileScope
    }

    func claudeHomeOverride() -> String? {
        envText("CLAUDE_CONFIG_DIR")
    }

    // Resolved OAuth endpoint strings before URL validation. The suffix is derived from the same
    // env-var branching as the URLs but never depends on URL validity, so the (non-throwing) keychain
    // candidate path can read it without risking a throw.
    private struct ResolvedOAuthEndpoints {
        var baseAPI: String
        var refreshURL: String
        var clientID: String
        var suffix: String
    }

    private func resolveOAuthEndpoints() -> ResolvedOAuthEndpoints {
        Self.resolveOAuthEndpoints(environment: environment)
    }

    private static func resolveOAuthEndpoints(environment: EnvironmentReading) -> ResolvedOAuthEndpoints {
        var baseAPI = Self.prodBaseAPIURL
        var refreshURL = Self.prodRefreshURL
        var clientID = Self.prodClientID
        var suffix = ""

        let isAntUser = envText(environment, "USER_TYPE") == "ant"
        if isAntUser, envFlag(environment, "USE_LOCAL_OAUTH") {
            let base = (envText(environment, "CLAUDE_LOCAL_OAUTH_API_BASE") ?? "http://localhost:8000").trimmingTrailingSlashes
            baseAPI = base
            refreshURL = "\(base)/v1/oauth/token"
            clientID = Self.nonProdClientID
            suffix = "-local-oauth"
        } else if isAntUser, envFlag(environment, "USE_STAGING_OAUTH") {
            baseAPI = "https://api-staging.anthropic.com"
            refreshURL = "https://platform.staging.ant.dev/v1/oauth/token"
            clientID = Self.nonProdClientID
            suffix = "-staging-oauth"
        }

        if let custom = envText(environment, "CLAUDE_CODE_CUSTOM_OAUTH_URL") {
            let base = custom.trimmingTrailingSlashes
            baseAPI = base
            refreshURL = "\(base)/v1/oauth/token"
            suffix = "-custom-oauth"
        }
        if let override = envText(environment, "CLAUDE_CODE_OAUTH_CLIENT_ID") {
            clientID = override
        }

        return ResolvedOAuthEndpoints(baseAPI: baseAPI, refreshURL: refreshURL, clientID: clientID, suffix: suffix)
    }

    /// The keychain service names as this environment's Claude Code writes them — the single source
    /// both the scoped store and config-dir DISCOVERY build from, so a non-prod OAuth setup (local/
    /// staging/custom, which suffixes the service) can never make discovery probe one name while
    /// refresh reads another.
    static func baseKeychainServiceName(environment: EnvironmentReading) -> String {
        "\(keychainServicePrefix)\(resolveOAuthEndpoints(environment: environment).suffix)-credentials"
    }

    static func scopedKeychainServiceName(forConfigDirLiteral literal: String, environment: EnvironmentReading) -> String {
        "\(baseKeychainServiceName(environment: environment))-\(hashSuffix(literal))"
    }

    // baseAPI/refreshURL can derive from user-set env vars (CLAUDE_CODE_CUSTOM_OAUTH_URL,
    // CLAUDE_LOCAL_OAUTH_API_BASE). A malformed value is a system-boundary input that must fail
    // loudly — never force-unwrap (crashes the app) and never silently fall back to prod (that hides
    // the misconfiguration and would send the user's token to production).
    func oauthConfig() throws -> ClaudeOAuthConfig {
        let endpoints = resolveOAuthEndpoints()
        let usageURLString = "\(endpoints.baseAPI)/api/oauth/usage"
        guard let usageURL = URL(string: usageURLString) else {
            throw ClaudeAuthError.invalidOAuthURL(usageURLString)
        }
        guard let refreshURL = URL(string: endpoints.refreshURL) else {
            throw ClaudeAuthError.invalidOAuthURL(endpoints.refreshURL)
        }
        return ClaudeOAuthConfig(
            usageURL: usageURL,
            refreshURL: refreshURL,
            clientID: endpoints.clientID
        )
    }

    func keychainServiceCandidates() -> [String] {
        // Only needs the file suffix, which never fails — keep this off the throwing URL path so
        // credential loading stays forgiving even when a custom OAuth URL is malformed.
        let base = "\(Self.keychainServicePrefix)\(resolveOAuthEndpoints().suffix)-credentials"
        switch scope {
        case .configDir(_, let keychainLiteral):
            // Exactly this card's item — never the bare default service, which is another account's
            // login.
            return ["\(base)-\(hashSuffix(keychainLiteral))"]
        case .desktopOnly:
            return []
        case .standard:
            if let configDir = claudeHomeOverride() {
                return ["\(base)-\(hashSuffix(configDir))"]
            }
            return [base]
        }
    }

    static func parseCredentials(_ text: String) -> ClaudeCredentialsFile? {
        ProviderParse.decodeJSONWithHexFallback(text, as: ClaudeCredentialsFile.self)
    }

    /// Keychain and file credentials in fixed keychain-before-file order. The keychain is Claude Code's
    /// source of truth on macOS — recent versions keep the current session there and can leave a stale
    /// `~/.claude/.credentials.json` behind — so it must win when valid; the file is only a fallback
    /// (older installs / Linux-style layouts). The refresh loop still falls through to the file on an
    /// auth-expiry error, so a fresh external `claude` re-login that landed in the other source is picked
    /// up (#687) WITHOUT letting a stale file outrank the live keychain just because its token carries a
    /// later expiry (the #738 regression from ranking purely by expiry). The source kind (never the
    /// token) is logged so a "locked out" report can be diagnosed from which source was chosen.
    private func orderedStoredCandidates() -> [ClaudeCredentialState] {
        // A desktop-only card has no CLI sources at all.
        if case .desktopOnly = scope { return [] }
        if case .standard = scope, expectedIdentityKey == nil,
           desktopAccessPolicy == .denied, !allowsUnscopedStandardKeychainFallback
        {
            return []
        }
        var candidates: [ClaudeCredentialState] = []
        if let keychain = loadKeychainCredentials() { candidates.append(keychain) }
        if let file = loadFileCredentials() { candidates.append(file) }

        if candidates.count > 1 {
            let labels = candidates.map(\.source.label).joined(separator: ", ")
            AppLog.debug(LogTag.auth("claude"), "credential candidates (keychain first): \(labels)")
        } else if let only = candidates.first {
            AppLog.debug(LogTag.auth("claude"), "credential source: \(only.source.label)")
        }
        return candidates
    }

    private func loadFileCredentials() -> ClaudeCredentialState? {
        let path = credentialsPath()
        guard files.exists(path),
              let text = try? files.readText(path),
              let parsed = Self.parseCredentials(text),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.isEmpty == false
        else {
            return nil
        }
        return ClaudeCredentialState(oauth: oauth, source: .file, fullData: parsed, inferenceOnly: false)
    }

    private func loadKeychainCredentials() -> ClaudeCredentialState? {
        // The service name is safe to log; NEVER log the returned credential blob / OAuth tokens.
        for service in keychainServiceCandidates() {
            if let state = credentialState(
                from: try? keychain.readGenericPasswordForCurrentUser(service: service),
                service: service, source: .keychainCurrentUser(service: service)
            ) {
                return state
            }
            if let state = credentialState(
                from: try? keychain.readGenericPassword(service: service),
                service: service, source: .keychainLegacy(service: service)
            ) {
                return state
            }
            AppLog.debug(.keychain, "read miss service=\(service)")
        }
        return nil
    }

    /// Parse one keychain hit into a credential state, or `nil` if it's absent / malformed / tokenless.
    /// Shared by the current-user and legacy reads so they don't repeat the parse-guard-log-build block;
    /// the keychain read itself stays at the call site to preserve the read order and error-swallowing.
    private func credentialState(
        from value: String?,
        service: String,
        source: ClaudeCredentialState.Source
    ) -> ClaudeCredentialState? {
        guard let value,
              let parsed = Self.parseCredentials(value),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.isEmpty == false
        else {
            return nil
        }
        AppLog.debug(.keychain, "read hit service=\(service)")
        return ClaudeCredentialState(oauth: oauth, source: source, fullData: parsed, inferenceOnly: false)
    }

    private func credentialsPath() -> String {
        if case .configDir(let path, _) = scope {
            return "\(path)/\(Self.credentialFileName)"
        }
        return "\(envText("CLAUDE_CONFIG_DIR") ?? Self.defaultClaudeHome)/\(Self.credentialFileName)"
    }

    private func envText(_ name: String) -> String? {
        Self.envText(environment, name)
    }

    private static func envText(_ environment: EnvironmentReading, _ name: String) -> String? {
        guard let value = environment.value(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func envFlag(_ name: String) -> Bool {
        Self.envFlag(environment, name)
    }

    private static func envFlag(_ environment: EnvironmentReading, _ name: String) -> Bool {
        guard let value = envText(environment, name)?.lowercased() else { return false }
        return !["0", "false", "no", "off"].contains(value)
    }

    private func hashSuffix(_ value: String) -> String {
        Self.hashSuffix(value)
    }

    private static func hashSuffix(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}
