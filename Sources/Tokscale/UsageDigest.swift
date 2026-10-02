import Foundation

/// Everything the rings show, worked out once from the two reports.
struct UsageDigest: Equatable {
    let today: Period
    let month: Period
    let lifetime: Period
    /// Apps this machine has actually used, busiest first.
    let apps: [AppUsage]
    let days: [DayUsage]
    let generatedAt: Date

    struct DayUsage: Equatable {
        let date: String
        let totals: Totals
        let models: [ModelUsage]
    }

    func totals(for app: UsageApp, in period: BillingPeriod,
                calendar: Calendar = .current) -> Totals {
        models(for: app, in: period, calendar: calendar)
            .reduce(Totals()) { $0 + $1.totals }
    }

    /// Per-model usage for one app inside a billing window, busiest first.
    func models(for app: UsageApp, in period: BillingPeriod,
                calendar: Calendar = .current) -> [ModelUsage] {
        let key = DayKey(calendar: calendar)
        let from = key.day(period.start)
        let until = key.day(period.end)
        let slice = days
            .filter { $0.date >= from && $0.date < until }
            .flatMap(\.models)
            .filter { $0.app == app }
        return Self.merge(slice)
    }

    struct Totals: Equatable {
        var counts = TokenCounts()
        var cost: Double = 0
        var messages: Int = 0

        var tokens: Int64 { counts.total }

        static func + (a: Totals, b: Totals) -> Totals {
            Totals(counts: a.counts + b.counts, cost: a.cost + b.cost,
                   messages: a.messages + b.messages)
        }
    }

    struct ModelUsage: Equatable, Identifiable {
        let model: String
        let app: UsageApp
        let totals: Totals
        var id: String { "\(app.id)|\(model)" }
    }

    struct AppUsage: Equatable, Identifiable {
        let app: UsageApp
        let totals: Totals
        let models: [ModelUsage]
        var id: String { app.id }
    }

    struct Baseline: Equatable {
        let value: Double
        let captionKey: String
    }

    struct Period: Equatable {
        let totals: Totals
        let models: [ModelUsage]
        let apps: [AppUsage]
        let baseline: Baseline?

        var fraction: Double? {
            guard let baseline, baseline.value > 0 else { return nil }
            return Double(totals.tokens) / baseline.value
        }
    }

    static func build(graph: GraphReport, lifetime report: UsageReport,
                      desktop: ClaudeDesktopSupplement? = nil,
                      now: Date = Date(), calendar: Calendar = .current) -> UsageDigest {
        let graph = mergedGraph(graph, desktop: desktop)
        let report = mergedLifetime(report, desktop: desktop)
        let days = graph.contributions
        let key = DayKey(calendar: calendar)

        let todayKey = key.day(now)
        let todayDays = days.filter { $0.date == todayKey }
        let todayTotals = totals(ofDays: todayDays)

        let windowStart = key.day(calendar.date(byAdding: .day, value: -30, to: now) ?? now)
        let recentPeak = days
            .filter { $0.date >= windowStart && $0.date < todayKey }
            .map { $0.tokenBreakdown.total }
            .max() ?? 0
        let todayBaseline = recentPeak > 0
            ? Baseline(value: Double(recentPeak), captionKey: "baseline.recentPeak")
            : nil

        let monthPrefix = key.month(now)
        let monthDays = days.filter { $0.date.hasPrefix(monthPrefix) }
        let monthTotals = totals(ofDays: monthDays)

        let dayOfMonth = calendar.component(.day, from: now)
        let lastMonthPrefix = calendar.date(byAdding: .month, value: -1, to: now).map(key.month)
        let lastMonthToDate = lastMonthPrefix.map { prefix in
            days.filter { $0.date.hasPrefix(prefix) && key.dayNumber($0.date) <= dayOfMonth }
        } ?? []
        let lastMonthTokens = totals(ofDays: lastMonthToDate).tokens
        let monthBaseline = lastMonthTokens > 0
            ? Baseline(value: Double(lastMonthTokens), captionKey: "baseline.lastMonth")
            : nil

        let lifetimeModels = merge(report.entries.map {
            ModelUsage(model: $0.model,
                       app: UsageApp(id: $0.client),
                       totals: Totals(counts: $0.tokens, cost: $0.cost, messages: $0.messages))
        })
        let lifetimeTotals = Totals(
            counts: lifetimeModels.reduce(TokenCounts()) { $0 + $1.totals.counts },
            cost: lifetimeModels.reduce(0) { $0 + $1.totals.cost },
            messages: report.messages
        )
        let milestone = nextMilestone(above: lifetimeTotals.tokens)
        let lifetimeBaseline = Baseline(value: Double(milestone),
                                        captionKey: "baseline.milestone")

        let lifetimeApps = group(lifetimeModels)

        let history = days.map { day in
            DayUsage(date: day.date,
                     totals: Totals(counts: day.tokenBreakdown, cost: day.cost,
                                    messages: day.messages),
                     models: modelsOf(days: [day]))
        }

        return UsageDigest(
            today: Period(totals: todayTotals,
                          models: modelsOf(days: todayDays),
                          apps: group(modelsOf(days: todayDays)),
                          baseline: todayBaseline),
            month: Period(totals: monthTotals,
                          models: modelsOf(days: monthDays),
                          apps: group(modelsOf(days: monthDays)),
                          baseline: monthBaseline),
            lifetime: Period(totals: lifetimeTotals,
                             models: lifetimeModels,
                             apps: lifetimeApps,
                             baseline: lifetimeBaseline),
            apps: lifetimeApps,
            days: history,
            generatedAt: now
        )
    }

    static func nextMilestone(above value: Int64) -> Int64 {
        guard value > 0 else { return 1_000_000 }
        var magnitude: Int64 = 1_000_000
        while magnitude <= Int64.max / 10 {
            for rung in [Int64(1), 2, 5] where magnitude * rung > value {
                return magnitude * rung
            }
            magnitude *= 10
        }
        return value
    }

    private static func totals(ofDays days: [GraphReport.Day]) -> Totals {
        Totals(counts: days.reduce(TokenCounts()) { $0 + $1.tokenBreakdown },
               cost: days.reduce(0) { $0 + $1.cost },
               messages: days.reduce(0) { $0 + $1.messages })
    }

    private static func modelsOf(days: [GraphReport.Day]) -> [ModelUsage] {
        merge(days.flatMap(\.clients).map {
            ModelUsage(model: $0.modelId,
                       app: UsageApp(id: $0.client),
                       totals: Totals(counts: $0.tokens, cost: $0.cost, messages: $0.messages))
        })
    }

    private static func merge(_ models: [ModelUsage]) -> [ModelUsage] {
        var byKey: [String: ModelUsage] = [:]
        for model in models {
            if let existing = byKey[model.id] {
                byKey[model.id] = ModelUsage(model: existing.model, app: existing.app,
                                             totals: existing.totals + model.totals)
            } else {
                byKey[model.id] = model
            }
        }
        return byKey.values.sorted { $0.totals.tokens > $1.totals.tokens }
    }

    private static func group(_ models: [ModelUsage]) -> [AppUsage] {
        Dictionary(grouping: models, by: \.app)
            .map { app, models in
                AppUsage(app: app,
                         totals: models.reduce(Totals()) { $0 + $1.totals },
                         models: models.sorted { $0.totals.tokens > $1.totals.tokens })
            }
            .sorted { $0.totals.tokens > $1.totals.tokens }
    }

    // MARK: - Claude Desktop supplement

    private static func mergedGraph(_ graph: GraphReport,
                                    desktop: ClaudeDesktopSupplement?) -> GraphReport {
        guard let desktop, !desktop.contributions.isEmpty else { return graph }
        var byDate = Dictionary(uniqueKeysWithValues: graph.contributions.map { ($0.date, $0) })
        for day in desktop.contributions {
            if let existing = byDate[day.date] {
                byDate[day.date] = mergeDays(existing, day)
            } else {
                byDate[day.date] = day
            }
        }
        let contributions = byDate.values.sorted { $0.date < $1.date }
        return GraphReport(contributions: contributions)
    }

    private static func mergeDays(_ a: GraphReport.Day, _ b: GraphReport.Day) -> GraphReport.Day {
        let clients = mergeClientLines(a.clients + b.clients)
        return GraphReport.Day(
            date: a.date,
            tokenBreakdown: a.tokenBreakdown + b.tokenBreakdown,
            clients: clients,
            cost: a.cost + b.cost,
            messages: a.messages + b.messages
        )
    }

    private static func mergeClientLines(_ lines: [GraphReport.Day.Line]) -> [GraphReport.Day.Line] {
        var byKey: [String: GraphReport.Day.Line] = [:]
        for line in lines {
            let key = "\(line.client)|\(line.modelId)"
            if let existing = byKey[key] {
                byKey[key] = GraphReport.Day.Line(
                    client: line.client,
                    modelId: line.modelId,
                    tokens: existing.tokens + line.tokens,
                    cost: existing.cost + line.cost,
                    messages: existing.messages + line.messages
                )
            } else {
                byKey[key] = line
            }
        }
        return Array(byKey.values)
    }

    private static func mergedLifetime(_ report: UsageReport,
                                        desktop: ClaudeDesktopSupplement?) -> UsageReport {
        guard let desktop, !desktop.lifetimeEntries.isEmpty else { return report }
        let entries = mergeLifetimeEntries(report.entries + desktop.lifetimeEntries)
        return UsageReport(entries: entries,
                           messages: report.messages + desktop.messagesParsed)
    }

    private static func mergeLifetimeEntries(_ entries: [UsageReport.Entry]) -> [UsageReport.Entry] {
        var byKey: [String: UsageReport.Entry] = [:]
        for entry in entries {
            let key = "\(entry.client)|\(entry.model)"
            if let existing = byKey[key] {
                byKey[key] = UsageReport.Entry(
                    client: entry.client,
                    model: entry.model,
                    tokens: existing.tokens + entry.tokens,
                    cost: existing.cost + entry.cost,
                    messages: existing.messages + entry.messages
                )
            } else {
                byKey[key] = entry
            }
        }
        return Array(byKey.values)
    }
}

struct DayKey {
    private let dayFormatter: DateFormatter
    private let monthFormatter: DateFormatter

    init(calendar: Calendar = .current) {
        dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.timeZone = calendar.timeZone
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.dateFormat = "yyyy-MM"
    }

    func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    func month(_ date: Date) -> String { monthFormatter.string(from: date) }

    func dayNumber(_ key: String) -> Int {
        Int(key.suffix(2)) ?? 0
    }
}
