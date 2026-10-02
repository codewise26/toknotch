import Foundation

/// Token usage read from Claude Desktop cowork / local-agent JSONL on disk.
struct ClaudeDesktopSupplement: Equatable {
    let contributions: [GraphReport.Day]
    let lifetimeEntries: [UsageReport.Entry]
    let filesScanned: Int
    let messagesParsed: Int

    var hasUsage: Bool { messagesParsed > 0 }

    static let empty = ClaudeDesktopSupplement(
        contributions: [], lifetimeEntries: [], filesScanned: 0, messagesParsed: 0
    )
}

/// Scans `~/Library/Application Support/Claude` for agent audit and session logs.
///
/// Main-window Desktop chat is not written here; only cowork / embedded Code paths.
enum ClaudeDesktopScanner {
    static let clientID = UsageApp.claudeDesktop.id

    static func isInstalled(fileManager: FileManager = .default) -> Bool {
        let config = supportRoot(fileManager: fileManager).appendingPathComponent("config.json")
        return fileManager.isReadableFile(atPath: config.path)
    }

    static func scan(supportRoot overrideRoot: URL? = nil,
                     fileManager: FileManager = .default,
                     calendar: Calendar = .current) -> ClaudeDesktopSupplement {
        let root = overrideRoot ?? supportRoot(fileManager: fileManager)
        guard fileManager.fileExists(atPath: root.path) else { return .empty }

        let key = DayKey(calendar: calendar)
        var events: [ParsedEvent] = []
        var filesScanned = 0

        enumerateJSONL(under: root, fileManager: fileManager) { url in
            guard shouldScan(url) else { return }
            filesScanned += 1
            guard let data = fileManager.contents(atPath: url.path) else { return }
            parseFile(data, sourceURL: url, key: key, into: &events)
        }

        guard !events.isEmpty else {
            return ClaudeDesktopSupplement(
                contributions: [], lifetimeEntries: [], filesScanned: filesScanned,
                messagesParsed: 0
            )
        }

        let contributions = buildDays(from: events)
        let lifetimeEntries = buildLifetime(from: events)
        return ClaudeDesktopSupplement(
            contributions: contributions,
            lifetimeEntries: lifetimeEntries,
            filesScanned: filesScanned,
            messagesParsed: events.count
        )
    }

    // MARK: - Paths

    private static func supportRoot(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    private static func shouldScan(_ url: URL) -> Bool {
        let path = url.path
        if url.lastPathComponent == "audit.jsonl" { return true }
        if path.contains("/.claude/projects/session/"), url.pathExtension == "jsonl" { return true }
        if path.contains("claude-code-sessions"), url.pathExtension == "jsonl" { return true }
        return false
    }

    private static func enumerateJSONL(under root: URL,
                                       fileManager: FileManager,
                                       body: (URL) -> Void) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            body(url)
        }
    }

    // MARK: - Parse

    private struct ParsedEvent: Equatable {
        let day: String
        let model: String
        let tokens: TokenCounts
        let cost: Double
    }

    private static func parseFile(_ data: Data, sourceURL: URL, key: DayKey,
                                  into events: inout [ParsedEvent]) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            guard !line.isEmpty, let event = parseLine(String(line), key: key) else { continue }
            events.append(event)
        }
    }

    private static func parseLine(_ line: String, key: DayKey) -> ParsedEvent? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let type = root["type"] as? String
        guard type == "assistant" else { return nil }

        let message = (root["message"] as? [String: Any]) ?? root
        guard let usage = message["usage"] as? [String: Any] else { return nil }

        let model = (message["model"] as? String) ?? "unknown"
        let tokens = tokenCounts(from: usage)
        guard tokens.total > 0 else { return nil }

        let day = dayKey(from: root, key: key)
        let cost = ModelCostEstimator.cost(model: model, tokens: tokens)
        return ParsedEvent(day: day, model: model, tokens: tokens, cost: cost)
    }

    private static func tokenCounts(from usage: [String: Any]) -> TokenCounts {
        func int64(_ key: String) -> Int64 {
            (usage[key] as? NSNumber)?.int64Value ?? Int64(usage[key] as? Int ?? 0)
        }
        let cacheCreate = usage["cache_creation"] as? [String: Any]
        let ephemeral5 = (cacheCreate?["ephemeral_5m_input_tokens"] as? NSNumber)?.int64Value ?? 0
        let ephemeral1h = (cacheCreate?["ephemeral_1h_input_tokens"] as? NSNumber)?.int64Value ?? 0
        let cacheWrite = int64("cache_creation_input_tokens")
            + ephemeral5 + ephemeral1h

        return TokenCounts(
            input: int64("input_tokens"),
            output: int64("output_tokens"),
            cacheRead: int64("cache_read_input_tokens"),
            cacheWrite: cacheWrite,
            reasoning: 0
        )
    }

    private static func dayKey(from root: [String: Any], key: DayKey) -> String {
        if let ms = root["_audit_timestamp"] as? NSNumber {
            return key.day(Date(timeIntervalSince1970: ms.doubleValue / 1000))
        }
        if let iso = root["timestamp"] as? String, let date = parseISO(iso) {
            return key.day(date)
        }
        return key.day(Date())
    }

    private static func parseISO(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    // MARK: - Aggregate

    private static func buildDays(from events: [ParsedEvent]) -> [GraphReport.Day] {
        var byDate: [String: [ParsedEvent]] = [:]
        for event in events {
            byDate[event.day, default: []].append(event)
        }

        return byDate.keys.sorted().map { date in
            let dayEvents = byDate[date] ?? []
            var byModel: [String: (tokens: TokenCounts, cost: Double, messages: Int)] = [:]
            for event in dayEvents {
                var entry = byModel[event.model] ?? (TokenCounts(), 0, 0)
                entry.tokens = entry.tokens + event.tokens
                entry.cost += event.cost
                entry.messages += 1
                byModel[event.model] = entry
            }

            let clients = byModel.map { model, totals in
                GraphReport.Day.Line(
                    client: clientID,
                    modelId: model,
                    tokens: totals.tokens,
                    cost: totals.cost,
                    messages: totals.messages
                )
            }
            let breakdown = clients.reduce(TokenCounts()) { $0 + $1.tokens }
            let cost = clients.reduce(0) { $0 + $1.cost }
            let messages = clients.reduce(0) { $0 + $1.messages }
            return GraphReport.Day(
                date: date,
                tokenBreakdown: breakdown,
                clients: clients,
                cost: cost,
                messages: messages
            )
        }
    }

    private static func buildLifetime(from events: [ParsedEvent]) -> [UsageReport.Entry] {
        var byModel: [String: (tokens: TokenCounts, cost: Double, messages: Int)] = [:]
        for event in events {
            var entry = byModel[event.model] ?? (TokenCounts(), 0, 0)
            entry.tokens = entry.tokens + event.tokens
            entry.cost += event.cost
            entry.messages += 1
            byModel[event.model] = entry
        }
        return byModel.map { model, totals in
            UsageReport.Entry(
                client: clientID,
                model: model,
                tokens: totals.tokens,
                cost: totals.cost,
                messages: totals.messages
            )
        }
    }
}
