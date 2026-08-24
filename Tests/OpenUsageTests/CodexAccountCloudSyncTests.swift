import XCTest
@testable import OpenUsage

/// Keychain-mode Codex cannot expose an account during prompt-free launch discovery. Its first
/// successful refresh already owns the selected credential, so cloud history learns the verified
/// account without another keychain read or any cross-account history carry-forward.
@MainActor
final class CodexAccountCloudSyncTests: XCTestCase {
    let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testKeychainAccountsRequireVerifiedMetadataOrJWTClaimsWithoutExtraReads() async throws {
        let cases: [(name: String, credential: String, expected: String?)] = [
            ("explicit account metadata", try authJSON(accountID: "  KEYCHAIN-ACCOUNT  "), "keychain-account"),
            ("ID-token account claim", try authJSON(
                accountID: nil, idToken: makeIDToken(accountID: "JWT-ACCOUNT")
            ), "jwt-account"),
            ("access-token account claim", try authJSON(
                accessToken: makeIDToken(accountID: "ACCESS-TOKEN-ACCOUNT"), accountID: nil
            ), "access-token-account"),
            ("identityless credential is quarantined", try authJSON(accountID: nil), nil)
        ]
        for entry in cases {
            let fixture = try makeFixture(keychainAuth: entry.credential, includeHistory: true)
            XCTAssertEqual(fixture.keychain.readCount, 0, "\(entry.name): launch remains prompt-free")

            let outcome = await fixture.store.refresh(providerID: "codex", force: true)

            XCTAssertEqual(outcome, .refreshed, entry.name)
            XCTAssertEqual(fixture.keychain.readCount, 1, "\(entry.name): no extra keychain read")
            XCTAssertEqual(fixture.provider.lastSuccessfulIdentityKey, entry.expected, entry.name)
            XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), entry.expected, entry.name)
            let document = fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
            XCTAssertEqual(document.providers["codex"] != nil, entry.expected != nil, entry.name)
            XCTAssertEqual(document.identities?["codex"], entry.expected, entry.name)
        }
    }

    func testRejectedFileFallbackPublishesOnlyAnIndependentlyVerifiedKeychainOwner() async throws {
        for accountID in ["ACCOUNT-B", nil] as [String?] {
            let scenario = accountID == nil ? "identityless fallback is quarantined" : "verified keychain wins"
            let http = RoutingHTTPClient { request in
                if request.headers["Authorization"] == "Bearer rejected-file-token" {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            }
            let fixture = try makeFixture(
                keychainAuth: authJSON(accessToken: "winning-keychain-token", accountID: accountID),
                fileAuth: authJSON(accessToken: "rejected-file-token", accountID: "ACCOUNT-A"),
                includeHistory: true, initialIdentity: "account-a", cachedHistory: historicalUsage(), http: http
            )
            XCTAssertNotNil(fixture.provider.lastSuccessfulCredentialFingerprint, scenario)
            XCTAssertEqual(fixture.keychain.readCount, 0, scenario)

            let outcome = await fixture.store.refresh(providerID: "codex", force: true)

            let expected = accountID?.lowercased()
            XCTAssertEqual(outcome, .refreshed, scenario)
            XCTAssertEqual(fixture.provider.lastSuccessfulIdentityKey, expected, scenario)
            XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), expected, scenario)
            let document = fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
            XCTAssertEqual(document.identities?["codex"], expected, scenario)
            XCTAssertEqual(document.providers["codex"] != nil, expected != nil, scenario)
            XCTAssertEqual(fixture.keychain.readCount, 1, scenario)
        }
    }

    func testFirstRefreshPreservesLaunchOwnershipOnlyWhenFileCredentialLineageMatches() async throws {
        let history = historicalUsage()
        let cases: [(name: String, file: String?, files: [String: String]?, owner: String,
                     expected: String?, keychainReads: Int, mutateFile: Bool)] = [
            ("same identified file loses metadata", try authJSON(accessToken: "file-token", accountID: "ACCOUNT-A"),
             nil, "account-a", "account-a", 0, true),
            ("earlier identityless file cannot claim later identified account", nil, [
                "~/.config/codex/auth.json": try authJSON(accessToken: "identityless-first", accountID: nil),
                "~/.codex/auth.json": try authJSON(accessToken: "identified-second", accountID: "ACCOUNT-A")
            ], "account-a", nil, 0, false),
            ("launch-known account survives first keychain metadata miss", nil, nil,
             "launch-account", "launch-account", 1, false)
        ]
        for entry in cases {
            let fixture = try makeFixture(
                keychainAuth: authJSON(accountID: nil), fileAuth: entry.file, fileAuthCandidates: entry.files,
                includeHistory: false, initialIdentity: entry.owner, cachedHistory: history
            )
            let initialFingerprint = fixture.provider.lastSuccessfulCredentialFingerprint
            XCTAssertEqual(initialFingerprint != nil, entry.file != nil || entry.files != nil, entry.name)
            if entry.mutateFile {
                fixture.files.files["/fixture-codex/auth.json"] = try authJSON(accessToken: "file-token", accountID: nil)
            }

            let outcome = await fixture.store.refresh(providerID: "codex", force: true)

            XCTAssertEqual(outcome, .refreshed, entry.name)
            XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey, entry.name)
            XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), entry.expected, entry.name)
            XCTAssertEqual(fixture.store.localSnapshots["codex"]?.usageHistory,
                           entry.expected == nil ? nil : history, entry.name)
            XCTAssertEqual(fixture.keychain.readCount, entry.keychainReads, entry.name)
            XCTAssertNotNil(fixture.provider.lastSuccessfulCredentialFingerprint, entry.name)
        }
    }

    func testAccountSwitchByMetadataOrAccessTokenClaimNeverInheritsCachedHistory() async throws {
        let cases = [
            ("account metadata", try authJSON(accountID: "ACCOUNT-B")),
            ("access-token claim", try authJSON(accessToken: makeIDToken(accountID: "ACCOUNT-B"), accountID: nil))
        ]
        for (name, credential) in cases {
            let fixture = try makeFixture(
                keychainAuth: credential, includeHistory: false, initialIdentity: "account-a",
                cachedHistory: historicalUsage()
            )

            let outcome = await fixture.store.refresh(providerID: "codex", force: true)

            XCTAssertEqual(outcome, .refreshed, name)
            XCTAssertEqual(fixture.provider.lastSuccessfulIdentityKey, "account-b", name)
            XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "account-b", name)
            XCTAssertNil(fixture.store.localSnapshots["codex"]?.usageHistory, name)
        }
    }

    func testIdentitylessCredentialsPreserveHistoryOnlyWithVerifiedTokenLineage() async throws {
        let history = historicalUsage()
        let cases: [(name: String, initialAccess: String, initialRefresh: String?, nextAccess: String,
                     nextRefresh: String?, preserves: Bool)] = [
            ("same access token", "same-token", nil, "same-token", nil, true),
            ("rotated access with shared refresh token", "old-access", "stable-refresh", "new-access", "stable-refresh", true),
            ("unrelated access and refresh tokens", "account-a", "refresh-a", "account-b", "refresh-b", false)
        ]

        for entry in cases {
            let fixture = try makeFixture(
                keychainAuth: authJSON(
                    accessToken: entry.initialAccess, refreshToken: entry.initialRefresh, accountID: "ACCOUNT-A"
                ),
                includeHistory: false, initialIdentity: "account-a", cachedHistory: history
            )
            _ = await fixture.store.refresh(providerID: "codex", force: true)
            let initialFingerprint = fixture.provider.lastSuccessfulCredentialFingerprint
            fixture.keychain.value = try authJSON(
                accessToken: entry.nextAccess, refreshToken: entry.nextRefresh, accountID: nil
            )

            let outcome = await fixture.store.refresh(providerID: "codex", force: true)

            XCTAssertEqual(outcome, .refreshed, entry.name)
            XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey, entry.name)
            XCTAssertEqual(
                fixture.cache.producedByIdentityKey(providerID: "codex"),
                entry.preserves ? "account-a" : nil, entry.name
            )
            XCTAssertEqual(fixture.store.localSnapshots["codex"]?.usageHistory,
                           entry.preserves ? history : nil, entry.name)
            XCTAssertEqual(
                fixture.provider.lastSuccessfulCredentialFingerprint == initialFingerprint,
                entry.preserves, entry.name
            )
            let document = fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
            XCTAssertEqual(document.providers["codex"], entry.preserves ? history : nil, entry.name)
            XCTAssertEqual(document.identities?["codex"], entry.preserves ? "account-a" : nil, entry.name)
            XCTAssertEqual(fixture.keychain.readCount, 2, entry.name)
        }
    }

    func testOwnedOAuthRotationPreservesHistoryForProactiveAndUnauthorizedRefresh() async throws {
        let history = historicalUsage()
        for unauthorized in [false, true] {
            let scenario = unauthorized ? "401 retry" : "proactive stale-token refresh"
            let http = RoutingHTTPClient { request in
                if request.url == CodexUsageClient.refreshURL {
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                        #"{"access_token":"rotated-access","refresh_token":"rotated-refresh"}"#.utf8
                    ))
                }
                if unauthorized, request.headers["Authorization"] == "Bearer rejected-access" {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            }
            let fixture = try makeFixture(
                keychainAuth: authJSON(
                    accessToken: "original-access", refreshToken: "original-refresh", accountID: "ACCOUNT-A"
                ),
                includeHistory: false, initialIdentity: "account-a", cachedHistory: history, http: http
            )
            _ = await fixture.store.refresh(providerID: "codex", force: true)
            let initialFingerprint = fixture.provider.lastSuccessfulCredentialFingerprint
            fixture.keychain.value = try authJSON(
                accessToken: unauthorized ? "rejected-access" : "original-access",
                refreshToken: "original-refresh", accountID: nil,
                lastRefresh: unauthorized ? nil : OpenUsageISO8601.string(
                    from: instant.addingTimeInterval(-9 * 24 * 60 * 60)
                )
            )

            let outcome = await fixture.store.refresh(providerID: "codex", force: true)

            XCTAssertEqual(outcome, .refreshed, scenario)
            XCTAssertTrue(http.requests.contains { $0.url == CodexUsageClient.refreshURL }, scenario)
            XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey, scenario)
            XCTAssertEqual(fixture.provider.lastSuccessfulCredentialFingerprint, initialFingerprint, scenario)
            XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "account-a", scenario)
            XCTAssertEqual(fixture.store.localSnapshots["codex"]?.usageHistory, history, scenario)
        }
    }

    func testReloadedUnrelatedIdentitylessCredentialBreaksTrustedLineage() async throws {
        let history = historicalUsage()
        let fixture = try makeFixture(
            keychainAuth: authJSON(
                accessToken: "account-a-access",
                refreshToken: "account-a-refresh",
                accountID: "ACCOUNT-A"
            ),
            includeHistory: false,
            initialIdentity: "account-a",
            cachedHistory: history
        )
        _ = await fixture.store.refresh(providerID: "codex", force: true)

        let replacedCredential = try authJSON(
            accessToken: "different-account-access",
            refreshToken: "different-account-refresh",
            accountID: nil
        )
        fixture.keychain.value = replacedCredential
        fixture.keychain.queuedReadValues = [
            try authJSON(
                accessToken: "account-a-access",
                refreshToken: "account-a-refresh",
                accountID: nil,
                lastRefresh: OpenUsageISO8601.string(from: instant.addingTimeInterval(-9 * 24 * 60 * 60))
            ),
            replacedCredential
        ]

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNil(fixture.provider.lastSuccessfulIdentityKey)
        XCTAssertNil(fixture.cache.producedByIdentityKey(providerID: "codex"))
        XCTAssertNil(fixture.store.localSnapshots["codex"]?.usageHistory)
        XCTAssertNil(
            fixture.store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac")
                .providers["codex"]
        )
    }

}

extension CodexAccountCloudSyncTests {
    struct Fixture {
        var provider: CodexProvider
        var store: WidgetDataStore
        var cache: ProviderSnapshotCache
        var keychain: CountingCodexCloudKeychain
        var files: FakeFiles
    }

    func historicalUsage() -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2000-01-01", totalTokens: 987_654_321, costUSD: 1234)
            ]),
            modelUsage: nil,
            unknownModelsByDay: [:]
        )
    }

    func makeFixture(
        keychainAuth: String,
        fileAuth: String? = nil,
        fileAuthCandidates: [String: String]? = nil,
        includeHistory: Bool,
        initialIdentity: String? = nil,
        cachedHistory: ProviderUsageHistory? = nil,
        http: (any HTTPClient)? = nil
    ) throws -> Fixture {
        let now = instant
        let timestamp = OpenUsageISO8601.string(from: now)
        let home = includeHistory
            ? try CodexLogFixture.makeHome(files: [
                "sessions/rollout.jsonl": [
                    CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.2"),
                    CodexLogFixture.tokenCount(
                        timestamp: timestamp,
                        last: CodexLogFixture.usage(input: 100, output: 50)
                    )
                ].joined(separator: "\n")
            ])
            : nil
        if let home {
            addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        }
        let keychain = CountingCodexCloudKeychain(value: keychainAuth)
        let files = FakeFiles(fileAuthCandidates ?? fileAuth.map { ["/fixture-codex/auth.json": $0] } ?? [:])
        let client = http ?? FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("{}".utf8)
        ))
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(fileAuthCandidates == nil ? ["CODEX_HOME": "/fixture-codex"] : [:]),
                files: files,
                keychain: keychain,
                now: { now }
            ),
            usageClient: CodexUsageClient(http: client),
            logUsageScanner: CodexLogFixture.scanner(home: home),
            now: { now },
            pricing: { TestPricing.bundled }
        )
        let defaults = try makeDefaults()
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "codex-cloud-snapshots",
            ttl: 600,
            now: { now }
        )
        if let cachedHistory {
            cache.store(
                ProviderSnapshot(
                    providerID: "codex",
                    displayName: "Codex",
                    lines: [.progress(label: "Session", used: 10, limit: 100, format: .percent)],
                    refreshedAt: now,
                    usageHistory: cachedHistory
                ),
                producedByIdentityKey: initialIdentity
            )
        }
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([provider]),
            providers: [provider],
            cache: cache,
            defaults: defaults,
            providerIdentityKeys: initialIdentity.map { ["codex": $0] } ?? [:]
        )
        return Fixture(provider: provider, store: store, cache: cache, keychain: keychain, files: files)
    }

    func authJSON(
        accessToken: String = "keychain-token",
        refreshToken: String? = nil,
        accountID: String?,
        idToken: String? = nil,
        lastRefresh: String? = nil
    ) throws -> String {
        var tokens: [String: Any] = ["access_token": accessToken]
        if let refreshToken { tokens["refresh_token"] = refreshToken }
        if let accountID { tokens["account_id"] = accountID }
        if let idToken { tokens["id_token"] = idToken }
        var auth: [String: Any] = ["tokens": tokens]
        if let lastRefresh { auth["last_refresh"] = lastRefresh }
        let data = try JSONSerialization.data(withJSONObject: auth)
        return String(decoding: data, as: UTF8.self)
    }

    func makeIDToken(accountID: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID]
        ])
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "OpenUsageTests.CodexAccountCloudSync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

final class CountingCodexCloudKeychain: KeychainAccessing, @unchecked Sendable {
    var value: String?
    var queuedReadValues: [String] = []
    private(set) var readCount = 0

    init(value: String?) {
        self.value = value
    }

    func readGenericPassword(service: String) throws -> String? {
        readCount += 1
        if !queuedReadValues.isEmpty {
            return queuedReadValues.removeFirst()
        }
        return value
    }

    func writeGenericPassword(service: String, value: String) throws {
        self.value = value
    }
}
