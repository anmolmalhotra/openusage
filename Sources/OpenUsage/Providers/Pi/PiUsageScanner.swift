import Foundation

/// Builds a per-day token/cost series from pi's session logs for one OpenUsage card, so usage that
/// happened inside pi (e.g. a Claude sub driven through pi) folds into that card's Usage Trend and
/// spend tiles alongside its native source.
///
/// Pi records an authoritative per-message `usage.cost.total` (like OpenCode), so that carried cost is
/// used when present; when pi logs a `$0` cost (subscription usage it doesn't impute), the tokens are
/// priced through the shared engine instead — the same `carried cost, else price` rule the Claude and
/// Codex log scanners use. Pi's usage shape differs from Claude Code's (`usage.input`/`output`,
/// nested `usage.cost.total`), so it has its own parser rather than routing through those scanners.
///
/// Provider-owned scanner instances share a versioned incremental parse cache (keyed by path, size,
/// and mtime) in memory and Application Support, so refreshes and relaunches parse only changed files.
/// The shared cache serializes scans for the same sessions directory across provider instances.
actor PiUsageScanner {
    /// How a card prices a pi request that carries no cost of its own. Providers with their own
    /// request rules (Codex's long-context and priority tiers) supply their estimator; the rest use
    /// the shared pricing engine.
    typealias CostEstimator = @Sendable (String, TokenBreakdown) -> Double?

    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        logTag: LogTag.plugin("pi"),
        persistence: JSONLScanCachePersistence(namespace: "pi", schemaVersion: 4)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
    }

    /// One parsed model-attributed usage record. Raw timestamp is kept so a cached parse stays valid as
    /// the window slides; `cardID` is resolved at parse time so aggregation is a cheap filter.
    struct Entry: Codable, Sendable, Equatable {
        var id: String?
        var deduplicationKey: String? = nil
        var providerID: String? = nil
        var sourcePath: String? = nil
        var sessionID: String? = nil
        var parentPath: String? = nil
        var timestamp: Date
        var cardID: String
        var model: String
        /// pi's own `usage.cost.total`, used directly when > 0; nil/0 falls through to engine pricing.
        var carriedCost: Double?
        /// The token buckets, for pricing the fall-through case.
        var tokens: TokenBreakdown
        /// Pi's reported total, falling back to the sum of its token buckets when missing or zero.
        var reportedTotalTokens: Int
    }

    /// Scan the last `daysBack` days of pi logs for one card. Returns nil when pi's sessions directory
    /// has no log files at all, so a provider with no pi usage folds in nothing.
    func scan(
        cardID: String, daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing,
        estimateCost: CostEstimator? = nil
    ) async -> LogUsageScan? {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        guard let entries = await parsedEntries(since: since), !Task.isCancelled else { return nil }
        return Self.aggregate(
            entries: Self.dedup(entries), cardID: cardID, since: since, pricing: pricing,
            estimateCost: estimateCost, until: now
        )
    }
    
    /// The same local transcript parser powers detection and refresh; no credentials or network calls.
    func hasUsage(cardID: String, daysBack: Int = 30, now: Date = Date()) async -> Bool {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        guard let entries = await parsedEntries(since: since), !Task.isCancelled else { return false }
        return entries.contains { $0.cardID == cardID && $0.timestamp >= since && $0.timestamp <= now }
    }
    
    private func parsedEntries(since: Date) async -> [Entry]? {
        let directory = PiPaths.sessionsDirectory(environment: environment, homeDirectory: homeDirectory())
        let cacheIdentity = directory.resolvingSymlinksInPath().path
        let files = JSONLScanning.jsonlFiles(under: directory)
        let entries = await scanner.items(
            from: files,
            since: since,
            cacheIdentity: cacheIdentity,
            initialState: ParseState(),
            initialStateForFile: { ParseState(sourcePath: $0) },
            parse: Self.parseFile
        )
        return files.isEmpty ? nil : entries
    }

    // MARK: - Parsing

    /// Each file keeps its header identity across the streaming reader's bounded batches.
    struct ParseState: Sendable {
        var sourcePath: String?
        var sessionID: String?
        var parentPath: String?
        var warnedUnattributedSummary = false
        
        init(sourcePath: String? = nil) {
            self.sourcePath = sourcePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        }
    }
    
    static func parseFile(_ data: Data) -> [Entry] {
        var state = ParseState()
        return parseFile(data, state: &state)
    }
    
    static func parseFile(_ data: Data, state: inout ParseState) -> [Entry] {
        let usageMarker = Data(#""usage""#.utf8)
        let sessionMarker = Data(#""session""#.utf8)
        let summaryMarkers = [Data(#""compaction""#.utf8), Data(#""branch_summary""#.utf8)]
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if line.range(of: sessionMarker) != nil,
               let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               object["type"] as? String == "session" {
                state.sessionID = trimmedString(object["id"])
                state.parentPath = parentPath(from: object, sourcePath: state.sourcePath)
                continue
            }
            if line.range(of: usageMarker) != nil,
               summaryMarkers.contains(where: { line.range(of: $0) != nil }),
               let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               let type = object["type"] as? String, ["compaction", "branch_summary"].contains(type),
               object["usage"] is [String: Any] {
                if !state.warnedUnattributedSummary {
                    AppLog.warn(LogTag.plugin("pi"), "Skipped Pi summary usage without reliable provider attribution; local spend may be incomplete")
                    state.warnedUnattributedSummary = true
                }
                continue
            }
            guard line.range(of: usageMarker) != nil,
                  var entry = parseLine(Data(line), sessionID: state.sessionID)
            else { continue }
            entry.sourcePath = state.sourcePath
            entry.parentPath = state.parentPath
            entries.append(entry)
        }
        return entries
    }

    static func parseLine(_ data: Data, sessionID: String? = nil) -> Entry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw)
        else { return nil }
        let attribution: [String: Any]
        switch object["type"] as? String {
        case "message":
            guard let message = object["message"] as? [String: Any],
                  message["role"] as? String == "assistant"
            else { return nil }
            attribution = message
        case "usage":
            // Pi's kind identifies the operation, not the format. Future kinds carry ordinary usage.
            attribution = object
        default:
            return nil
        }
        guard let providerID = trimmedString(attribution["provider"]),
              let cardID = PiProviderMapping.cardID(forPiProvider: providerID),
              let usage = attribution["usage"] as? [String: Any]
        else { return nil }

        guard let input = tokenCount(usage["input"]),
              let output = tokenCount(usage["output"]),
              let cacheRead = tokenCount(usage["cacheRead"]),
              let cacheWrite = tokenCount(usage["cacheWrite"]),
              let rawCacheWrite1h = tokenCount(usage["cacheWrite1h"]),
              let reportedTotal = tokenCount(usage["totalTokens"])
        else {
            AppLog.warn(LogTag.plugin("pi"), "Skipped Pi usage with out-of-range token counts")
            return nil
        }
        let cacheWrite1h = min(rawCacheWrite1h, cacheWrite)
        let tokens = TokenBreakdown(
            input: input,
            cacheWrite5m: cacheWrite - cacheWrite1h,
            cacheWrite1h: cacheWrite1h,
            cacheRead: cacheRead,
            output: output
        )
        var total = 0
        for count in [input, cacheRead, cacheWrite, output] {
            let sum = total.addingReportingOverflow(count)
            guard !sum.overflow else {
                AppLog.warn(LogTag.plugin("pi"), "Skipped Pi usage whose token total exceeds the supported range")
                return nil
            }
            total = sum.partialValue
        }
        let carriedCost = (usage["cost"] as? [String: Any]).flatMap { ProviderParse.number($0["total"]) }
        guard total > 0 || reportedTotal > 0 || (carriedCost ?? 0) > 0 else { return nil }
        let id = trimmedString(object["id"])
        let session = trimmedString(object["sessionId"]) ?? trimmedString(object["session_id"]) ?? trimmedString(sessionID)
        let deduplicationKey = id.flatMap { id in
            session.map { "pi:\($0.utf8.count):\($0):\(id)" }
        }
        return Entry(
            id: id,
            deduplicationKey: deduplicationKey,
            providerID: providerID,
            sessionID: session,
            timestamp: timestamp,
            cardID: cardID,
            model: trimmedString(attribution["model"]) ?? trimmedString(attribution["responseModel"]) ?? "",
            carriedCost: carriedCost.flatMap { $0 > 0 ? $0 : nil },
            tokens: tokens,
            reportedTotalTokens: reportedTotal > 0 ? reportedTotal : total
        )
    }
    
    private static func parentPath(from header: [String: Any], sourcePath: String?) -> String? {
        guard let parent = trimmedString(header["parentSession"]) else { return nil }
        let base: URL?
        if let cwd = trimmedString(header["cwd"]), cwd.hasPrefix("/") {
            base = URL(fileURLWithPath: cwd, isDirectory: true)
        } else {
            base = sourcePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        }
        guard parent.hasPrefix("/") || base != nil else { return nil }
        return URL(fileURLWithPath: parent, relativeTo: base).resolvingSymlinksInPath().path
    }
    
    private static func trimmedString(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    
    /// Missing or invalid buckets contain no usable tokens. Never trap converting external numbers.
    private static func tokenCount(_ value: Any?) -> Int? {
        guard let number = ProviderParse.number(value), number > 0 else { return 0 }
        return Int(exactly: number.rounded(.towardZero))
    }

    // MARK: - Dedup and aggregation

    /// Session copies and lineage-linked forks may repeat the same completed request.
    static func dedup(_ entries: [Entry]) -> [Entry] {
        PiUsageDeduplication.deduplicate(entries)
    }

    /// Bucket the card's entries into local calendar days. Cost is pi's carried total when it recorded
    /// one, else the tokens priced through `pricing`; a model that can't be priced and carries no cost
    /// is excluded from the totals and surfaced as the tile's unknown-model warning, matching the log
    /// scanners.
    static func aggregate(
        entries: [Entry], cardID: String, since: Date, pricing: ModelPricing,
        estimateCost: CostEstimator? = nil, until: Date = .distantFuture
    ) -> LogUsageScan {
        let estimate = estimateCost ?? { pricing.estimatedCostDollars(model: $0, tokens: $1) }
        var accumulator = DailyUsageAccumulator()
        var totalTokens = 0
        var totalCost = 0.0
        for entry in entries where entry.cardID == cardID && entry.timestamp >= since && entry.timestamp <= until {
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            let trimmedModel = entry.model.nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName

            let cost: Double
            if let carried = entry.carriedCost, carried > 0 {
                cost = carried
            } else if let model = trimmedModel, let estimated = estimate(model, entry.tokens) {
                cost = estimated
            } else {
                if entry.reportedTotalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: modelName)
                }
                continue
            }
            let tokenSum = totalTokens.addingReportingOverflow(entry.reportedTotalTokens)
            let costSum = totalCost + cost
            guard !tokenSum.overflow, cost.isFinite, cost >= 0, costSum.isFinite else {
                AppLog.warn(LogTag.plugin("pi"), "Skipped Pi usage exceeding the supported total range")
                continue
            }
            totalTokens = tokenSum.partialValue
            totalCost = costSum
            accumulator.add(day: day, tokens: entry.reportedTotalTokens, cost: cost, model: modelName)
        }
        return accumulator.build()
    }
}
