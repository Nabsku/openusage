import Foundation

/// Reads token accounting from Antigravity's local conversation databases, discovered by FelixIsaac
/// in openusage#1058/#1120. Transcript JSONL files contain no usable generation token counts.
///
/// SQLite batches are bounded, and oversized protobufs are skipped before `hex(data)` runs: real
/// Antigravity sessions can contain generation blobs hundreds of megabytes in size.
actor AntigravityDbUsageScanner {
    static let maximumBlobBytes = 1_048_576
    static let batchSize = 8

    private let sqlite: SQLiteAccessing
    private let conversationsDirectories: @Sendable () -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter
    private let oversizedBlobReporter: UsageLogReadFailureReporter
    private var scanCache: [String: CachedDatabase] = [:]

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        conversationsDirectories: @escaping @Sendable () -> [String] = AntigravityDbUsageScanner.defaultConversationsDirectories,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil,
        oversizedBlobWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.conversationsDirectories = conversationsDirectories
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("antigravity"),
            warning: readFailureWarning
        )
        self.oversizedBlobReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("antigravity"),
            warning: oversizedBlobWarning ?? { count in
                let noun = count == 1 ? "database" : "databases"
                AppLog.warn(LogTag.plugin("antigravity"), "Skipped oversized generation records in \(count) Antigravity \(noun)")
            }
        )
    }

    /// Each Antigravity surface keeps its own conversation store under `~/.gemini`: the `agy` CLI,
    /// the Antigravity IDE, the Antigravity 2.0 app, and ACP-hosted sessions.
    static let defaultConversationsDirectories: @Sendable () -> [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["antigravity-cli", "antigravity", "antigravity-ide", "antigravity-acp"].map {
            home.appendingPathComponent(".gemini/\($0)/conversations").path
        }
    }

    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let directories = conversationsDirectories().map(expandHome)
        var paths: [String] = []
        var failingPaths: [String: String] = [:]
        for directory in directories {
            do {
                paths += try Self.databaseFiles(in: directory)
            } catch {
                failingPaths[directory] = error.localizedDescription
            }
        }

        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let checkedPaths = Set(paths).union(directories)
        scanCache = scanCache.filter {
            checkedPaths.contains($0.key) && $0.value.fingerprint.latestModification >= since
        }

        var accumulator = DailyUsageAccumulator()
        var oversizedPaths: Set<String> = []

        for path in paths {
            guard !Task.isCancelled else { return nil }
            do {
                let cached = try cachedDatabase(path: path, since: since)
                guard !Task.isCancelled else { return nil }
                guard let cached else { continue }
                for event in cached.events {
                    Self.accumulate(event, since: since, pricing: pricing, into: &accumulator)
                }
                if cached.sawOversizedBlob {
                    oversizedPaths.insert(path)
                }
            } catch {
                failingPaths[path] = error.localizedDescription
            }
        }

        let newlyFailing = await readFailureReporter.update(
            checkedPaths: checkedPaths,
            failingPaths: Set(failingPaths.keys)
        )
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("antigravity"), "usage query failed for \(path): \(failingPaths[path] ?? "unknown error")")
        }

        let newlyOversized = await oversizedBlobReporter.update(
            checkedPaths: checkedPaths,
            failingPaths: oversizedPaths
        )
        for path in newlyOversized.sorted() {
            AppLog.warn(LogTag.plugin("antigravity"), "generation records larger than \(Self.maximumBlobBytes) bytes skipped in \(path)")
        }

        let result = accumulator.build()
        return result.series.daily.isEmpty && result.unknownModelsByDay.isEmpty ? nil : result
    }

    /// `CASE` prevents SQLite from expanding oversized blobs, while the inner `LIMIT` bounds the
    /// maximum hex payload returned by any subprocess to roughly `batchSize * maximumBlobBytes * 2`.
    /// Modern Antigravity conversation DBs omit timestamps from `gen_metadata.data` and record them
    /// in `steps.metadata`, correlated by `idx`; `includeSteps: false` serves databases without that table.
    static func dataSQL(after index: Int, includeSteps: Bool = true) -> String {
        let stepColumn = includeSteps
            ? ",\n    'step_hex', (SELECT CASE WHEN length(metadata) <= \(maximumBlobBytes) THEN hex(metadata) ELSE NULL END FROM steps WHERE idx = g.idx)"
            : ""
        return """
        SELECT json_group_array(json_object('index', g.idx, 'hex',
            CASE WHEN length(g.data) <= \(maximumBlobBytes) THEN hex(g.data) ELSE NULL END\(stepColumn)))
        FROM (
            SELECT idx, data FROM gen_metadata
            WHERE idx > \(index) AND data IS NOT NULL
            ORDER BY idx
            LIMIT \(batchSize)
        ) g
        """
    }

    static let stepsTableProbeSQL = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'steps'"

    private func cachedDatabase(path: String, since: Date) throws -> CachedDatabase? {
        let fingerprint = try DatabaseFingerprint(path: path)
        guard fingerprint.latestModification >= since else { return nil }

        if let cached = scanCache[path], cached.fingerprint == fingerprint, cached.windowStart <= since {
            return cached
        }

        var cached = scanCache[path]
        if cached?.fingerprint.databaseIdentifier != fingerprint.databaseIdentifier
            || (cached?.fingerprint.databaseSize ?? 0) > fingerprint.databaseSize
            || (cached?.windowStart ?? since) > since
        {
            cached = nil
        }

        var refreshed = cached ?? CachedDatabase(fingerprint: fingerprint, windowStart: since)
        refreshed.fingerprint = fingerprint
        refreshed.windowStart = since
        refreshed.events.removeAll {
            Date(timeIntervalSince1970: TimeInterval($0.timestampSeconds)) < since
        }
        try readDatabase(path: path, since: since, into: &refreshed)
        guard !Task.isCancelled else { return nil }
        scanCache[path] = refreshed
        return refreshed
    }

    private func readDatabase(path: String, since: Date, into cached: inout CachedDatabase) throws {
        if cached.hasStepsTable == nil {
            cached.hasStepsTable = try sqlite.queryValue(path: path, sql: Self.stepsTableProbeSQL) != nil
        }
        let includeSteps = cached.hasStepsTable ?? false

        while !Task.isCancelled {
            let sql = Self.dataSQL(after: cached.lastIndex, includeSteps: includeSteps)
            guard let payload = try sqlite.queryValue(path: path, sql: sql) else { break }
            let rows = try JSONDecoder().decode([Row].self, from: Data(payload.utf8))
            guard !rows.isEmpty else { break }

            for row in rows {
                guard row.index > cached.lastIndex else {
                    throw SQLiteError.queryFailed("Antigravity generation indices are not strictly increasing")
                }
                cached.lastIndex = row.index

                guard let hex = row.hex else {
                    cached.sawOversizedBlob = true
                    continue
                }

                guard let blob = Self.bytes(fromHex: hex),
                      let event = AntigravityProtoDecoder.generationEvent(
                          from: blob, stepMetadata: row.stepHex.flatMap(Self.bytes(fromHex:))
                      ),
                      Date(timeIntervalSince1970: TimeInterval(event.timestampSeconds)) >= since
                else { continue }
                cached.events.append(event)
            }

            if rows.count < Self.batchSize { break }
        }
    }

    private struct Row: Decodable {
        let index: Int
        let hex: String?
        let stepHex: String?

        enum CodingKeys: String, CodingKey {
            case index
            case hex
            case stepHex = "step_hex"
        }
    }

    private static func accumulate(
        _ event: AntigravityProtoDecoder.GenerationEvent,
        since: Date,
        pricing: ModelPricing,
        into accumulator: inout DailyUsageAccumulator
    ) {
        let date = Date(timeIntervalSince1970: TimeInterval(event.timestampSeconds))
        guard date >= since else { return }

        let inputAndCached = event.inputTokens.addingReportingOverflow(event.cacheReadTokens)
        let total = inputAndCached.partialValue.addingReportingOverflow(event.outputTokens)
        guard !inputAndCached.overflow, !total.overflow, total.partialValue > 0 else { return }

        let day = DailyUsageAccumulator.dayKey(from: date)
        let tokens = TokenBreakdown(
            input: event.inputTokens,
            cacheRead: event.cacheReadTokens,
            output: event.outputTokens
        )

        let model = Self.breakdownModel(event.model)
        guard let cost = pricing.estimatedCostDollars(model: model, tokens: tokens) else {
            accumulator.addUnknownModel(day: day, model: model)
            return
        }
        accumulator.add(day: day, tokens: total.partialValue, cost: cost, model: model)
    }

    /// Antigravity resolves subagent tiers (`flash_lite`, `flash`, `pro`) through a server-sent
    /// `TieredModelConfig`, and logs the resolved ID with a `-tiered` suffix
    /// (`gemini-3.7-flash-tiered`). It is the same model at the same price, so the breakdown
    /// shows it under the base name.
    static func breakdownModel(_ model: String) -> String {
        model.hasSuffix("-tiered") ? String(model.dropLast("-tiered".count)) : model
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.utf8.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.utf8.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func databaseFiles(in directory: String) throws -> [String] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }

        return names
            .filter { $0.hasSuffix(".db") }
            .sorted()
            .map { directory.trimmingTrailingSlashes + "/" + $0 }
    }

    private struct DatabaseFingerprint: Equatable {
        let databaseIdentifier: UInt64
        let databaseSize: Int64
        let databaseModification: Date
        let walSize: Int64?
        let walModification: Date?

        init(path: String) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            databaseIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            databaseSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            databaseModification = attributes[.modificationDate] as? Date ?? .distantPast

            do {
                let walAttributes = try FileManager.default.attributesOfItem(atPath: path + "-wal")
                walSize = (walAttributes[.size] as? NSNumber)?.int64Value ?? 0
                walModification = walAttributes[.modificationDate] as? Date ?? .distantPast
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                walSize = nil
                walModification = nil
            }
        }

        var latestModification: Date {
            max(databaseModification, walModification ?? .distantPast)
        }
    }

    private struct CachedDatabase {
        var fingerprint: DatabaseFingerprint
        var windowStart: Date
        var lastIndex = -1
        var events: [AntigravityProtoDecoder.GenerationEvent] = []
        var sawOversizedBlob = false
        /// Probed once per database; nil until the first read.
        var hasStepsTable: Bool?
    }
}
