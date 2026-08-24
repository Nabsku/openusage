import Foundation

/// Launch-time identity walk over Cowork's session sandboxes (the `.claude` dirs the Claude desktop
/// app creates per session, see `ClaudeLogUsageScanner.coworkClaudeDirs`).
///
/// Each sandbox carries its own `.claude.json`, which names the account that ran the session. The
/// walk only reads those identity files — no keychain, no credential files — so it can never raise
/// a permission dialog or block launch. Routing is the assembly's job: sandboxes naming the default
/// account stay on the default card, sandboxes naming a known config-dir account attach as its log
/// roots, and a distinct account becomes one Desktop-backed card.
struct ClaudeCoworkDiscovery {
    /// One Cowork session sandbox and the account it names, when it names one.
    struct Sandbox: Equatable, Sendable {
        /// The session's `.claude` dir (a spend-log root: it holds `projects/**/*.jsonl`).
        var root: URL
        /// `nil` when the sandbox's identity file is missing or names no account — such a sandbox
        /// stays on the default card, exactly where the built-in walk has always put it.
        var identityKey: String?
        var label: String?
        /// The account's org UUID (lowercased) — the pin a Desktop-backed card reads credentials
        /// under. Claude Desktop caches tokens per org, so an account without one can't get a card.
        var organization: String?
    }

    struct Result: Sendable {
        var sandboxes: [Sandbox] = []
        /// The support trail (token-free and email-free): identity hashes and paths only.
        var notes: [String] = []
        /// True when the walk hit its time budget before visiting every sandbox. A partial list
        /// must not drive routing — a missed non-default sandbox would silently bleed into the
        /// default card, and a partial partition would drop default spend — so the assembly skips
        /// the whole cowork pass this launch and retries next launch.
        var truncated = false
    }

    var files: TextFileAccessing
    var homeDirectory: @Sendable () -> URL
    /// Ownership discovery must distinguish an empty directory from an unreadable directory.
    var listSandboxes: @Sendable (URL) throws -> [URL]
    /// Wall-clock budget; on overrun the scan returns what it has, flagged `truncated` so the
    /// assembly knows the list is not the whole truth (and retries next launch).
    var timeBudget: TimeInterval
    var now: @Sendable () -> Date

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        listSandboxes: @escaping @Sendable (URL) throws -> [URL] = Self.ownershipSandboxes,
        // Heavy Desktop users commonly accumulate hundreds of sandbox identities. A subsecond
        // launch budget silently discarded the entire account partition on those real machines.
        timeBudget: TimeInterval = 3,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.files = files
        self.homeDirectory = homeDirectory
        self.listSandboxes = listSandboxes
        self.timeBudget = timeBudget
        self.now = now
    }

    func run() -> Result {
        let started = now()
        var result = Result()
        let roots: [URL]
        do {
            roots = try listSandboxes(homeDirectory())
        } catch {
            result.notes.append("cowork sandbox enumeration failed → account routing quarantined")
            result.truncated = true
            AppLog.error(.config, "cowork sandbox enumeration failed; account routing quarantined")
            return result
        }
        for root in roots {
            if Task.isCancelled {
                result.notes.append("cowork sandbox scan cancelled → skipping incomplete cowork routing")
                result.truncated = true
                break
            }
            if now().timeIntervalSince(started) > timeBudget {
                result.notes.append("cowork sandbox scan hit its \(Int(timeBudget * 1000))ms budget → skipping cowork routing this launch")
                result.truncated = true
                break
            }
            var unreadable = false
            let sandbox = sandbox(at: root, notes: &result.notes, unreadable: &unreadable)
            result.sandboxes.append(sandbox)
            if unreadable {
                result.truncated = true
                break
            }
        }
        return result
    }

    private static func ownershipSandboxes(_ home: URL) throws -> [URL] {
        let base = home.appendingPathComponent(
            "Library/Application Support/Claude/local-agent-mode-sessions"
        )
        func subdirectories(of directory: URL) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true
            }
        }
        let groups: [URL]
        do {
            groups = try subdirectories(of: base)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        var roots: [URL] = []
        for group in groups {
            for subdirectory in try subdirectories(of: group) {
                var sessions = try subdirectories(of: subdirectory)
                for holder in sessions where holder.lastPathComponent == "agent" {
                    sessions.append(contentsOf: try subdirectories(of: holder))
                }
                roots.append(contentsOf: sessions.map { $0.appendingPathComponent(".claude") })
            }
        }
        return roots.sorted { $0.path < $1.path }
    }

    private func sandbox(at root: URL, notes: inout [String], unreadable: inout Bool) -> Sandbox {
        let identityText: String?
        do {
            identityText = try files.readTextIfPresent(root.path + "/.claude.json")
        } catch {
            notes.append("cowork sandbox \(logPath(root.path)): identity file unreadable → account routing quarantined")
            AppLog.error(.config, "cowork sandbox identity unreadable; account routing quarantined")
            unreadable = true
            return Sandbox(root: root)
        }
        guard let identityText else { return Sandbox(root: root) }
        guard let parsed = try? JSONDecoder().decode(
                  DefaultAccountObserver.ClaudeStateFile.self, from: Data(identityText.utf8)
              )
        else {
            notes.append("cowork sandbox \(logPath(root.path)): identity file invalid → account routing quarantined")
            unreadable = true
            return Sandbox(root: root)
        }
        guard let account = parsed.oauthAccount,
              let key = DefaultAccountObserver.claudeIdentityKey(account)
        else {
            notes.append("cowork sandbox \(logPath(root.path)): account identity unavailable → account routing quarantined")
            unreadable = true
            return Sandbox(root: root)
        }
        return Sandbox(
            root: root,
            identityKey: key,
            label: DefaultAccountObserver.claudeIdentityLabel(account),
            organization: account.organizationUuid?.nilIfEmpty?.lowercased()
        )
    }

    /// Log-safe path: the home prefix is folded to `~` so support logs don't carry the username.
    private func logPath(_ path: String) -> String {
        let home = homeDirectory().path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
