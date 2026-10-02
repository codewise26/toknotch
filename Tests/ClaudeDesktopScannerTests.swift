import XCTest
@testable import TokNotch

final class ClaudeDesktopScannerTests: XCTestCase {
    private static let auditFixture = """
    {"type":"assistant","timestamp":"2026-09-05T10:00:00.000Z","sessionId":"s1","message":{"model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}
    {"type":"user","timestamp":"2026-09-05T10:01:00.000Z","message":{"role":"user","content":"hi"}}
    {"type":"assistant","timestamp":"2026-09-05T10:05:00.000Z","sessionId":"s1","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0}}}

    """

    private var root: URL!
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeDesktop-\(UUID().uuidString)")
        let auditDir = root
            .appendingPathComponent("local-agent-mode-sessions/session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
        try Self.auditFixture.write(to: auditDir.appendingPathComponent("audit.jsonl"),
                                    atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testParsesAuditJSONLIntoSupplement() {
        let supplement = ClaudeDesktopScanner.scan(supportRoot: root, calendar: calendar)
        XCTAssertEqual(supplement.messagesParsed, 2)
        XCTAssertEqual(supplement.lifetimeEntries.count, 1)
        XCTAssertEqual(supplement.lifetimeEntries.first?.client, "claude-desktop")
        let tokens = supplement.lifetimeEntries.first?.tokens
        XCTAssertEqual(tokens, TokenCounts(input: 110, output: 55, cacheRead: 3000, cacheWrite: 200))
        XCTAssertGreaterThan(supplement.lifetimeEntries.first?.cost ?? 0, 0)
    }

    func testDigestMergeKeepsDesktopSeparateFromClaudeCode() {
        let day = "2026-09-05"
        let counts = TokenCounts(input: 110, output: 55, cacheRead: 3000, cacheWrite: 200)
        let desktop = ClaudeDesktopSupplement(
            contributions: [
                GraphReport.Day(
                    date: day,
                    tokenBreakdown: counts,
                    clients: [.init(client: "claude-desktop", modelId: "claude-sonnet-5",
                                    tokens: counts, cost: 1, messages: 2)],
                    cost: 1, messages: 2
                )
            ],
            lifetimeEntries: [
                .init(client: "claude-desktop", model: "claude-sonnet-5",
                      tokens: counts, cost: 1, messages: 2)
            ],
            filesScanned: 1,
            messagesParsed: 2
        )
        let graph = GraphReport(contributions: [
            GraphReport.Day(date: day, tokenBreakdown: TokenCounts(output: 10),
                            clients: [.init(client: "claude", modelId: "claude-opus-5",
                                            tokens: TokenCounts(output: 10), cost: 0, messages: 1)],
                            cost: 0, messages: 1)
        ])
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5))!
        let digest = UsageDigest.build(graph: graph, lifetime: UsageReport(entries: [], messages: 0),
                                       desktop: desktop, now: now, calendar: calendar)
        XCTAssertEqual(Set(digest.today.apps.map(\.app.id)), ["claude", "claude-desktop"])
        XCTAssertEqual(digest.lifetime.totals.tokens, counts.total)
        XCTAssertEqual(digest.today.totals.tokens, counts.total + 10)
    }
}

final class ModelCostEstimatorTests: XCTestCase {
    func testFallbackRatesProduceNonZeroCost() {
        ModelCostEstimator.resetCacheForTesting()
        let cost = ModelCostEstimator.cost(
            model: "claude-sonnet-5-unknown-suffix",
            tokens: TokenCounts(input: 1000, output: 1000)
        )
        XCTAssertGreaterThan(cost, 0)
    }
}

final class UsageAppOutlineTests: XCTestCase {
    func testTrackedAppsExposeNonEmptyOutlines() {
        for id in ["cursor", "codex", "claude", "claude-desktop"] {
            let outline = UsageApp(id: id).outline
            XCTAssertNotNil(outline, id)
            XCTAssertFalse(outline?.isEmpty ?? true, id)
        }
    }
}
