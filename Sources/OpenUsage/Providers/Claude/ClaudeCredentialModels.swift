import Foundation

struct ClaudeOAuth: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Double?
    var subscriptionType: String?
    var rateLimitTier: String?
    var scopes: [String]?
}

struct ClaudeCredentialsFile: Codable, Hashable, Sendable {
    var claudeAiOauth: ClaudeOAuth?
}

struct ClaudeCredentialState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case file
        case keychainCurrentUser(service: String)
        case keychainLegacy(service: String)
        case desktop
        case environment

        /// Log-safe source kind — NEVER the keychain service name or any token.
        var label: String {
            switch self {
            case .file: "file"
            case .keychainCurrentUser: "keychainCurrentUser"
            case .keychainLegacy: "keychainLegacy"
            case .desktop: "desktop"
            case .environment: "environment"
            }
        }
    }

    var oauth: ClaudeOAuth
    var source: Source
    var fullData: ClaudeCredentialsFile?
    var inferenceOnly: Bool

    /// Whether this candidate carries a non-blank access token — the single definition of "usable"
    /// shared by `refresh()`'s candidate filter and `hasLocalCredentials()`'s first-run detection, so
    /// the two can never drift.
    var hasUsableAccessToken: Bool {
        oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// A token-free, log-safe one-line descriptor for diagnosing auth failures from a default-level
    /// (info) log: the source kind plus booleans for whether this candidate carries a refresh token and
    /// whether its access token is already expired (`expiresAt`, epoch ms, vs `now`). NEVER includes any
    /// token value or the credential blob — only the source kind and the two booleans. Why these two
    /// booleans: a candidate with `refresh=no` can never self-heal an expiry (the #738 root cause), and
    /// `expired=yes` explains why a refresh was needed at all.
    func diagnosticsLabel(now: Date) -> String {
        let refresh = (oauth.refreshToken?.isEmpty == false) ? "yes" : "no"
        let expired: String
        if let expiresAt = oauth.expiresAt {
            expired = expiresAt <= now.timeIntervalSince1970 * 1000 ? "yes" : "no"
        } else {
            expired = "unknown"
        }
        return "\(source.label) refresh=\(refresh) expired=\(expired)"
    }
}

/// Token-bearing credential candidates in their effective probe order. Environment-only inference
/// tokens are excluded because they never fetch live usage; every stored candidate that can affect
/// selection remains, including an earlier source that the current refresh already tried and rejected.
struct ClaudeCredentialGeneration: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        let oauth: ClaudeOAuth
        let source: ClaudeCredentialState.Source

        init(_ state: ClaudeCredentialState) {
            oauth = state.oauth
            source = state.source
        }
    }

    var candidates: [Candidate]

    init(_ states: [ClaudeCredentialState]) {
        candidates = states
            .filter { $0.hasUsableAccessToken && !$0.inferenceOnly }
            .map(Candidate.init)
    }

    func replacing(_ state: ClaudeCredentialState) -> Self {
        var updated = self
        guard let index = updated.candidates.firstIndex(where: { $0.source == state.source }) else {
            fatalError("live usage source missing from Claude credential generation")
        }
        updated.candidates[index] = Candidate(state)
        return updated
    }
}

struct ClaudeCredentialLoad: Sendable {
    var candidates: [ClaudeCredentialState]
    var desktopStatus: ClaudeDesktopCredentialStatus
}

enum ClaudeAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case desktopPermissionRequired
    case desktopTokenExpired
    case desktopCredentialsUnavailable
    case sessionExpired
    case tokenExpired
    case credentialsChanged
    case invalidOAuthURL(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `claude` to authenticate."
        case .desktopPermissionRequired:
            return "Claude Desktop login found. Refresh once and choose Always Allow to connect it."
        case .desktopTokenExpired:
            return "Claude Desktop login is stale. Open Claude Desktop, then refresh OpenUsage."
        case .desktopCredentialsUnavailable:
            return "Claude Desktop login couldn't be read. Open Claude Desktop, then try again."
        case .sessionExpired:
            return "Session expired. Run `claude` to log in again."
        case .tokenExpired:
            return "Token expired. Run `claude` to log in again."
        case .credentialsChanged:
            return "Claude login changed during refresh. Refresh again."
        case .invalidOAuthURL(let value):
            return "Invalid Claude OAuth URL: \(value). Check CLAUDE_CODE_CUSTOM_OAUTH_URL / CLAUDE_LOCAL_OAUTH_API_BASE."
        }
    }

    /// Whether a failure on one credential source should fall through to the next one rather than
    /// failing the whole refresh. An expired/revoked token in the preferred source (a stale keychain
    /// entry from a prior login that later "locked out") must not shadow a fresh token an external
    /// `claude` re-login wrote to a different source — so the token-is-bad cases allow a fallback,
    /// while "no credentials at all" does not (there is nothing better to try). Mirrors
    /// `CodexAuthError.allowsAuthFallback`.
    var allowsAuthFallback: Bool {
        switch self {
        case .sessionExpired, .tokenExpired, .desktopTokenExpired:
            return true
        case .notLoggedIn, .desktopPermissionRequired, .desktopCredentialsUnavailable,
             .credentialsChanged, .invalidOAuthURL:
            return false
        }
    }
}

struct ClaudeOAuthConfig: Hashable, Sendable {
    var usageURL: URL
    var refreshURL: URL
    var clientID: String
}

/// Which login a `ClaudeAuthStore` is allowed to see. `.standard` is the default card —
/// byte-identical to the store's historical behavior. `.configDir` backs an extra account card and
/// deliberately has no cross-account, environment-token, or Desktop fallback: the card can only ever
/// read the one login it was created for.
enum ClaudeCredentialScope: Hashable, Sendable {
    case standard
    /// One extra `CLAUDE_CONFIG_DIR` home. `keychainLiteral` is the literal string whose hash names
    /// the keychain item (Claude Code hashes the env value as typed — `~/…` vs absolute differ).
    case configDir(path: String, keychainLiteral: String)
}
