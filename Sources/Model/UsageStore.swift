import AppKit
import Combine
import os

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var rings: [RingSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var availableApps: [UsageApp] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var problem: String?
    @Published private(set) var detectedPlans: [UsageApp: DetectedPlan] = [:]
    @Published private(set) var cursorNeedsLogin = false
    @Published private(set) var clientScanReport: String?

    var language: AppLanguage = .system { didSet { guard language != oldValue else { return }; render() } }
    var enabledApps: Set<String> = [] { didSet { guard enabledApps != oldValue else { return }; render() } }
    var subscriptions: [String: Subscription] = [:] { didSet { guard subscriptions != oldValue else { return }; render() } }

    var effectivePlans: [String: Subscription] {
        var merged = Dictionary(uniqueKeysWithValues:
            detectedPlans.compactMap { app, plan in
                plan.subscription.map { (app.id, $0) }
            })
        merged.merge(subscriptions) { _, override in override }
        return merged.filter { $0.value.isActive }
    }

    func isDetected(_ app: UsageApp) -> Bool {
        subscriptions[app.id] == nil && detectedPlans[app]?.subscription != nil
    }

    private var digest: UsageDigest?
    private var failure: String?
    private let interval: TimeInterval
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var lastAntigravitySync: Date?
    private var lastCursorSync: Date?
    private var lastDesktopScan: Date?
    private var desktopSupplement: ClaudeDesktopSupplement = .empty
    private static let antigravitySyncInterval: TimeInterval = 5 * 60
    private static let cursorSyncInterval: TimeInterval = 5 * 60
    private static let desktopScanInterval: TimeInterval = 5 * 60
    private static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    init(interval: TimeInterval = 60) {
        self.interval = interval
        detectedPlans = PlanDetector.detect()
        render()
    }

    func start() {
        refreshNow()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    func loadForTesting(_ digest: UsageDigest) {
        self.digest = digest
        self.availableApps = digest.apps.map(\.app)
        self.lastUpdated = digest.generatedAt
        render()
    }

    func refreshNow(byHand: Bool = false) {
        guard task == nil else { return }
        isRefreshing = true
        task = Task { [weak self] in
            await self?.syncAntigravityIfDue(force: byHand)
            await self?.syncCursorIfDue(force: byHand)
            self?.scanDesktopIfDue(force: byHand)
            if byHand { await self?.loadClientScan() }
            await self?.refresh()
            self?.task = nil
            self?.isRefreshing = false
        }
    }

    private func syncAntigravityIfDue(force: Bool) async {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity") != nil
        else { return }
        if !force, let last = lastAntigravitySync,
           Date().timeIntervalSince(last) < Self.antigravitySyncInterval { return }
        lastAntigravitySync = Date()
        do {
            try await TokscaleCLI.syncAntigravity()
        } catch {
            Log.usage.error("antigravity sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func syncCursorIfDue(force: Bool) async {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.cursorBundleID) != nil
        else {
            cursorNeedsLogin = false
            return
        }
        let linked = await TokscaleCLI.cursorIsLinked()
        cursorNeedsLogin = !linked
        guard linked else { return }
        if !force, let last = lastCursorSync,
           Date().timeIntervalSince(last) < Self.cursorSyncInterval { return }
        lastCursorSync = Date()
        do {
            try await TokscaleCLI.syncCursor()
        } catch {
            Log.usage.error("cursor sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadClientScan() async {
        do {
            var report = try await TokscaleCLI.clientsReport()
            if desktopSupplement.filesScanned > 0 || desktopSupplement.messagesParsed > 0 {
                report += """

                Claude Desktop JSONL: \(desktopSupplement.filesScanned) file(s), \
                \(desktopSupplement.messagesParsed) assistant message(s).
                """
            }
            clientScanReport = report
        } catch {
            Log.usage.error("clients scan failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func scanDesktopIfDue(force: Bool) {
        guard ClaudeDesktopScanner.isInstalled() else {
            desktopSupplement = .empty
            return
        }
        if !force, let last = lastDesktopScan,
           Date().timeIntervalSince(last) < Self.desktopScanInterval { return }
        lastDesktopScan = Date()
        desktopSupplement = ClaudeDesktopScanner.scan()
    }

    private func refresh() async {
        do {
            async let graph = TokscaleCLI.graph()
            async let lifetime = TokscaleCLI.lifetime()
            let digest = UsageDigest.build(
                graph: try await graph,
                lifetime: try await lifetime,
                desktop: desktopSupplement.hasUsage ? desktopSupplement : nil
            )

            self.digest = digest
            self.failure = nil
            self.problem = nil
            self.lastUpdated = digest.generatedAt
            self.detectedPlans = PlanDetector.detect()
            self.availableApps = mergedApps(from: digest)
            Log.usage.notice("""
                read ok — lifetime \(digest.lifetime.totals.tokens, privacy: .public),                 today \(digest.today.totals.tokens, privacy: .public),                 \(digest.apps.count, privacy: .public) app(s)
                """)
        } catch {
            self.failure = Self.explain(error, language: language)
            self.problem = self.failure
            Log.usage.error("tokscale read failed: \(String(describing: error), privacy: .public)")
        }
        render()
    }

    private func mergedApps(from digest: UsageDigest) -> [UsageApp] {
        let usageOrder = digest.apps.map(\.app)
        var extras = detectedPlans.keys.filter { app in !usageOrder.contains(app) }
        let desktop = UsageApp.claudeDesktop
        if (ClaudeDesktopScanner.isInstalled() || desktopSupplement.hasUsage),
           !usageOrder.contains(desktop), !extras.contains(desktop) {
            extras.append(desktop)
        }
        return usageOrder + extras
    }

    func plan(for app: UsageApp) -> Subscription? {
        if let stored = subscriptions[app.id] { return stored }
        return detectedPlans[app]?.subscription
    }

    func payback(for app: UsageApp, plan: Subscription,
                 now: Date = Date(), calendar: Calendar = .current) -> Payback? {
        guard let digest, plan.isActive else { return nil }
        let period = BillingPeriod.current(renewalDay: plan.renewalDay,
                                           now: now, calendar: calendar)
        return Payback(subscription: plan, period: period,
                       earned: digest.totals(for: app, in: period, calendar: calendar).cost)
    }

    func periodPayback() -> (paid: Double, earned: Double)? {
        let plans = effectivePlans
        guard !plans.isEmpty else { return nil }
        return plans.reduce((paid: 0, earned: 0)) { sum, entry in
            let app = UsageApp(id: entry.key)
            return (sum.paid + entry.value.monthlyUSD,
                    sum.earned + (payback(for: app, plan: entry.value)?.earned ?? 0))
        }
    }

    func lifetime(for app: UsageApp) -> UsageDigest.Totals? {
        digest?.apps.first { $0.app == app }?.totals
    }

    func periodTotals(for app: UsageApp, plan: Subscription,
                      now: Date = Date(), calendar: Calendar = .current) -> UsageDigest.Totals? {
        guard let digest else { return nil }
        let period = BillingPeriod.current(renewalDay: plan.renewalDay, now: now, calendar: calendar)
        return digest.totals(for: app, in: period, calendar: calendar)
    }

    func periodTotals(for app: UsageApp, renewalDay: Int,
                      now: Date = Date(), calendar: Calendar = .current) -> UsageDigest.Totals? {
        guard let digest else { return nil }
        let period = BillingPeriod.current(renewalDay: renewalDay, now: now, calendar: calendar)
        return digest.totals(for: app, in: period, calendar: calendar)
    }

    /// Plans that define a billing period for an app ring — same gate as Settings
    /// (`plan != nil`), including custom $0, not only paid `effectivePlans`.
    private var subscriptionsForRings: [String: Subscription] {
        guard let digest else { return [:] }
        var result: [String: Subscription] = [:]
        for usage in digest.apps {
            guard let plan = plan(for: usage.app) else { continue }
            if plan.isActive || plan.planID == nil {
                result[usage.app.id] = plan
            }
        }
        return result
    }

    private func render() {
        guard let digest else {
            let note = failure
            rings = RingKind.primaries.map {
                RingBuilder.placeholder($0, language: language, note: note)
            }
            return
        }
        rings = RingBuilder.rings(from: digest, apps: enabledApps,
                                  subscriptions: subscriptionsForRings, language: language)
    }

    private static func explain(_ error: Error, language: AppLanguage) -> String {
        guard let failure = error as? TokscaleCLI.Failure else {
            return language.t("status.readFailed", (error as NSError).localizedDescription)
        }
        switch failure {
        case .notInstalled:      return language.t("status.notInstalled")
        case .exited(127):       return language.t("status.noNode")
        case .exited(let code):  return language.t("status.exited", code)
        case .undecodable:       return language.t("status.undecodable")
        case .timedOut:          return language.t("status.timedOut")
        }
    }
}

