import AppKit
import SwiftUI

/// The settings window, reached from the orb below the notch or the menu bar.
///
/// Two pages, because there are two questions. Payback is the reason the app
/// exists — what each plan costs and what it has returned — and it is where
/// the window opens. Everything else is how the notch looks and behaves, and it
/// is short enough to sit on one page.
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var store: UsageStore
    @ObservedObject var updater: Updater

    @State private var page: Page = .payback
    /// Which page to open on. Only set by the render tests, which have to be
    /// able to photograph each one.
    var startingPage: Page? = nil
    /// Opens the About window, from the version line at the foot of Settings.
    var onAbout: () -> Void = {}

    enum Page: String, CaseIterable, Identifiable {
        case payback, settings
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .payback:  return "creditcard.fill"
            case .settings: return "gearshape.fill"
            }
        }

        var tint: Color {
            switch self {
            case .payback:  return .green
            case .settings: return .gray
            }
        }

        func title(_ language: AppLanguage) -> String {
            language.t("settings.page." + rawValue)
        }
    }

    private var language: AppLanguage { preferences.appLanguage }

    var body: some View {
        // A plain split rather than `NavigationSplitView`. That view insists on
        // putting a sidebar-collapse button into the window's toolbar, and it
        // cannot be removed — which means a title bar has to exist to hold it,
        // and a button whose only offer is to hide the one control that makes
        // this window navigable. Two columns side by side owe nobody a toolbar.
        HStack(spacing: 0) {
            sidebar
                .frame(width: SettingsView.sidebarWidth)
                .background(SidebarMaterial())
            Divider()
            detail
        }
        // Fills whatever the window gives it rather than claiming a fixed
        // size. With `fullSizeContentView` the window's content area includes
        // the title bar's height, so a hard-coded height leaves a band of bare
        // window showing along the bottom edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear {
            // Anything stored by the four-page window, or nothing at all,
            // opens on Payback.
            page = startingPage
                ?? Page(rawValue: preferences.lastSettingsPage)
                ?? .payback
        }
        .onChange(of: page) { _, new in preferences.lastSettingsPage = new.rawValue }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Clear of the window controls, which sit over the sidebar now that
            // there is no title bar for them to live in.
            Color.clear.frame(height: 42)

            ForEach(Page.allCases) { item in
                Button {
                    page = item
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        SettingsIcon(symbol: item.symbol, tint: item.tint)
                        Text(item.title(language))
                            .font(.system(size: 13))
                            .foregroundStyle(page == item ? Color.white : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(page == item ? Color.accentColor : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .payback:  PaybackPage(preferences: preferences, store: store)
        case .settings: PreferencesPage(preferences: preferences, updater: updater, onAbout: onAbout)
        }
    }

    // Two short page names need far less than the four did; the room goes to
    // the vendor rows, which carry a plan menu, a renewal day, a multiple and
    // a switch on one line.
    static let sidebarWidth: CGFloat = 180
    static let width: CGFloat = 800
    static let height: CGFloat = 620
}

// MARK: - Payback

struct PaybackPage: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var store: UsageStore

    private var language: AppLanguage { preferences.appLanguage }

    /// Apps with a plan first, then everything else busiest first.
    ///
    /// One list rather than a page of ring switches beside a page of plans:
    /// both were lists of the same tools, and whether an app gets a ring
    /// is a question asked about exactly the thing whose plan is on that row.
    private var apps: [UsageApp] {
        let all = store.availableApps
        let hasPlan = { app in
            guard let plan = store.plan(for: app) else { return false }
            return plan.isActive || plan.planID == nil
        }
        return all.filter(hasPlan) + all.filter { !hasPlan($0) }
    }

    var body: some View {
        SettingsPage {

            SettingsGroup(title: language.t("settings.thisPeriod")) {
                if let total = store.periodPayback() {
                    PaybackSummary(paid: total.paid, earned: total.earned, language: language)
                } else {
                    // Not a zero: nothing has been paid for yet, so there is
                    // nothing to have paid back.
                    SettingsRow("creditcard", tint: .green,
                                title: language.t("settings.pickAPlanToSeePayback")) { EmptyView() }
                }
            }

            SettingsGroup(title: language.t("settings.apps"),
                          footnote: language.t("settings.privacy")) {
                // Only when something is wrong. A source that works has nothing
                // to say for itself.
                if let problem = store.problem {
                    SettingsRow("exclamationmark.triangle.fill", tint: .orange, title: problem) {
                        Button(language.t("settings.refresh")) { store.refreshNow(byHand: true) }
                            .controlSize(.small)
                            .disabled(store.isRefreshing)
                    }
                    if !apps.isEmpty { SettingsDivider(inset: 0) }
                }
                if apps.isEmpty {
                    if store.problem == nil {
                        SettingsRow("hourglass", tint: .gray,
                                    title: language.t("settings.scanningThisMacSUsage")) { EmptyView() }
                    }
                } else {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { SettingsDivider(inset: 0) }
                        AppRow(app: app, preferences: preferences,
                               store: store, language: language)
                    }
                }
            }
            .animation(.snappy, value: apps.map(\.id))

            if store.cursorNeedsLogin {
                SettingsGroup(title: language.t("settings.integrations")) {
                    SettingsRow("cursorarrow.triangle.2.circlepath", tint: .blue,
                                title: language.t("settings.cursorLoginTitle"),
                                subtitle: language.t("settings.cursorLoginSubtitle")) {
                        Button(language.t("settings.copyCursorLogin")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                "\"\(TokscaleCLI.bundledExecutable ?? TokscaleCLI.executable)\" cursor login",
                                forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            }

            if let desktop = store.detectedPlans[UsageApp.claudeDesktop],
               desktop.source == "Claude.app" {
                SettingsGroup(title: language.t("settings.integrations")) {
                    SettingsRow("info.circle.fill", tint: .orange,
                                title: language.t("settings.claudeDesktopTitle"),
                                subtitle: language.t("settings.claudeDesktopSubtitle")) { EmptyView() }
                }
            }

            SettingsGroup(title: language.t("settings.dataSources"),
                          footnote: language.t("settings.dataSourcesFootnote")) {
                SettingsRow("doc.text.magnifyingglass", tint: .gray,
                            title: language.t("settings.scanDataSources")) {
                    Button(language.t("settings.refresh")) { store.refreshNow(byHand: true) }
                        .controlSize(.small)
                        .disabled(store.isRefreshing)
                }
                if let report = store.clientScanReport {
                    SettingsDivider(inset: 0)
                    ScrollView {
                        Text(report)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                    .padding(.horizontal, SettingsMetrics.rowPaddingH)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

/// The one line the payback page exists to produce.
private struct PaybackSummary: View {
    let paid: Double
    let earned: Double
    let language: AppLanguage

    private var multiple: Double { paid > 0 ? earned / paid : 0 }
    private var paidBack: Bool { multiple >= 1 }
    private var scale: PaybackScale { .around(multiple) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(language.t("settings.earned"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(UsageFormat.money(earned, language))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Text(String(format: "%.1f×", multiple))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(paidBack ? Color.green : Color.orange)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill((paidBack ? Color.green : Color.orange).gradient)
                        .frame(width: max(4, proxy.size.width * scale.fill(multiple)))
                    if let breakEven = scale.breakEven {
                        // Break-even, cut into the bar in the card's own colour.
                        // Once a plan is well past paying for itself the fill
                        // alone says nothing; where this tick sits is the whole
                        // reading.
                        Capsule()
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .frame(width: 2)
                            .offset(x: proxy.size.width * breakEven - 1)
                    }
                }
            }
            .frame(height: 6)

            Text(language.t(paidBack ? "settings.plansTotalOver" : "settings.plansTotalToGo",
                            UsageFormat.money(paid, language),
                            UsageFormat.money(abs(earned - paid), language)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, SettingsMetrics.rowPaddingH)
        .padding(.vertical, 11)
    }
}

/// One app: its plan, when that renews, what it has returned, and whether
/// the notch gives it a ring.
private struct AppRow: View {
    let app: UsageApp
    @ObservedObject var preferences: Preferences
    @ObservedObject var store: UsageStore
    let language: AppLanguage

    @State private var draft: String = ""
    @FocusState private var editing: Bool

    private var detected: DetectedPlan? { store.detectedPlans[app] }
    private var plan: Subscription? { store.plan(for: app) }
    private var isCustom: Bool { plan != nil && plan?.planID == nil }

    private var isUsageBilled: Bool { PlanCatalog.menu(for: app).isEmpty }

    private var selected: PlanCatalog.Plan {
        PlanMenuSelection.selected(plan: plan) { PlanCatalog.plan(id: $0, for: app) }
    }

    private var renewalDay: Binding<Int> {
        Binding(
            get: { plan?.renewalDay ?? detected?.renewalDay ?? 1 },
            set: { day in
                guard let current = plan, current.renewalDay != day else { return }
                preferences.subscriptions[app.id] =
                    Subscription(monthlyUSD: current.monthlyUSD, renewalDay: day,
                                 planID: current.planID)
            }
        )
    }

    private var payback: Payback? {
        plan.flatMap { store.payback(for: app, plan: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                RingGlyphView(glyph: .app(app), size: 17)
                    .foregroundStyle(app.ringTint)
                    .frame(width: SettingsMetrics.iconSize)

                Text(app.title(language))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(width: Self.nameWidth, alignment: .leading)

                if isUsageBilled {
                    Text(usageLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                    Spacer(minLength: 6)
                } else {
                    if let periodText = periodUsageLine {
                        Text(periodText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .monospacedDigit()
                            .frame(maxWidth: Self.periodWidth, alignment: .leading)
                    }

                    planMenu

                    Group {
                        if plan != nil {
                            Picker("", selection: renewalDay) {
                                ForEach(1...31, id: \.self) { day in
                                    Text(UsageFormat.dayOfMonth(day, language)).tag(day)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .frame(width: Self.dayWidth)

                    verdict.frame(width: Self.verdictWidth, alignment: .trailing)
                    Spacer(minLength: 6)
                }

                Toggle("", isOn: Binding(
                    get: { preferences.showsRing(for: app) },
                    set: { preferences.setRing($0, for: app) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(language.t("settings.showRing"))
            }

            if isCustom || store.isDetected(app)
                || (detected?.needsManualMonthlyPrice == true && plan == nil) {
                HStack(spacing: 6) {
                    if isCustom {
                        Text("$").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("0", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 62)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .focused($editing)
                            .onSubmit(commit)
                            .onChange(of: editing) { _, focused in if !focused { commit() } }
                        Text(language.t("settings.perMonth"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if let detected, detected.needsManualMonthlyPrice {
                        Text(language.t("settings.enterSeatCost"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .help(language.t("settings.detected", detected.name, detected.source))
                    } else if let detected {
                        Text(language.t("settings.autoDetected"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                            .help(language.t("settings.detected", detected.name, detected.source))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, SettingsMetrics.iconSize + 9 + Self.nameWidth + 9)
            }
        }
        .padding(.horizontal, SettingsMetrics.rowPaddingH)
        .padding(.vertical, 8)
        .onAppear { draft = plan.map { trimmed($0.monthlyUSD) } ?? "" }
    }

    private static let nameWidth: CGFloat = 104
    private static let periodWidth: CGFloat = 148
    private static let menuWidth: CGFloat = 196
    private static let dayWidth: CGFloat = 68
    private static let verdictWidth: CGFloat = 44

    private var planMenu: some View {
        Menu {
            ForEach(PlanCatalog.menu(for: app)) { option in
                Button { selectPlan(option) } label: {
                    Text(caption(for: option))
                }
            }
            if periodMenuCaption != nil || allTimeMenuCaption != nil {
                Divider()
                if let period = periodMenuCaption {
                    Button {} label: { Text(period) }
                        .disabled(true)
                }
                if let allTime = allTimeMenuCaption {
                    Button {} label: { Text(allTime) }
                        .disabled(true)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(caption(for: selected))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.menuWidth, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var usageLine: String {
        var parts = [language.t("settings.payAsYouGo")]
        if let totals = store.lifetime(for: app) {
            parts.append(UsageFormat.tokens(totals.tokens, language))
            parts.append(UsageFormat.money(totals.cost, language))
        }
        return parts.joined(separator: " · ")
    }

    private var periodUsageLine: String? { periodMenuCaption }

    private var periodMenuCaption: String? {
        guard plan != nil else { return nil }
        let day = renewalDay.wrappedValue
        guard let period = store.periodTotals(for: app, renewalDay: day) else { return nil }
        return language.t("settings.periodUsage",
                          UsageFormat.tokens(period.tokens, language),
                          UsageFormat.money(period.cost, language))
    }

    private var allTimeMenuCaption: String? {
        guard let lifetime = store.lifetime(for: app) else { return nil }
        return language.t("settings.allTimeUsage",
                          UsageFormat.tokens(lifetime.tokens, language),
                          UsageFormat.money(lifetime.cost, language))
    }

    private func selectPlan(_ choice: PlanCatalog.Plan) {
        guard choice != selected else { return }
        let day = plan?.renewalDay ?? detected?.renewalDay ?? 1
        switch choice.id {
        case "none":
            preferences.subscriptions[app.id] = Subscription(monthlyUSD: 0, renewalDay: day)
        case "custom":
            preferences.subscriptions[app.id] =
                Subscription(monthlyUSD: plan?.monthlyUSD ?? 0, renewalDay: day)
            draft = plan.map { trimmed($0.monthlyUSD) } ?? ""
            editing = true
        default:
            preferences.subscriptions[app.id] =
                Subscription(monthlyUSD: choice.monthlyUSD, renewalDay: day, planID: choice.id)
        }
    }

    private func caption(for option: PlanCatalog.Plan) -> String {
        switch option.id {
        case "none":   return language.t("settings.noPlan")
        case "custom": return language.t("settings.custom")
        default:
            return option.monthlyUSD > 0
                ? "\(option.name) · \(UsageFormat.moneyShort(option.monthlyUSD, language))"
                : option.name
        }
    }

    private func commit() {
        guard isCustom else { return }
        let cleaned = draft.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        let value = Double(cleaned) ?? 0
        preferences.subscriptions[app.id] =
            Subscription(monthlyUSD: value, renewalDay: renewalDay.wrappedValue)
        draft = value > 0 ? trimmed(value) : ""
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    @ViewBuilder
    private var verdict: some View {
        if let payback {
            Text(String(format: "%.1f×", payback.multiple))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(app.tint)
                .help(language.t(payback.hasPaidBack ? "settings.paidBack" : "settings.onTheWay"))
        }
    }
}

// MARK: - Settings

struct PreferencesPage: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var updater: Updater
    var onAbout: () -> Void = {}

    private var language: AppLanguage { preferences.appLanguage }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPage {

                SettingsGroup(title: language.t("settings.theNotch")) {
                    SettingsPictureRow(
                        title: language.t("settings.show"),
                        subtitle: preferences.notchVisibility.explanation(language),
                        selection: $preferences.notchVisibility,
                        options: NotchVisibility.allCases,
                        caption: { $0.title(language) },
                        preview: { NotchVisibilityPreview(visibility: $0, edge: preferences.notchEdge) }
                    )
                    SettingsDivider(inset: 0)
                    SettingsPictureRow(
                        title: language.t("settings.edge"),
                        subtitle: preferences.notchEdge.explanation(language),
                        selection: $preferences.notchEdge,
                        options: NotchEdge.allCases,
                        caption: { $0.title(language) },
                        preview: { NotchEdgePreview(edge: $0) }
                    )
                }

                SettingsGroup(title: language.t("settings.theAppItself")) {
                    SettingsMenuRow(
                        title: language.t("settings.language"),
                        selection: $preferences.appLanguage,
                        options: AppLanguage.available,
                        // Each language named in itself; only "system" is
                        // written in whatever the reader is currently using.
                        label: { $0 == .system ? language.t("settings.systemLanguage") : $0.endonym },
                        symbol: "globe", tint: .teal
                    )
                    SettingsDivider()
                    SettingsRow("menubar.rectangle", tint: .gray,
                                title: language.t("settings.showInMenuBar"),
                                subtitle: preferences.showsMenuBarIcon
                                    ? nil : language.t("settings.showInMenuBar.off")) {
                        Toggle("", isOn: $preferences.showsMenuBarIcon)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow("dock.rectangle", tint: .gray, title: language.t("settings.showInDock")) {
                        Toggle("", isOn: $preferences.showsInDock)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    if Updater.isConfigured {
                        SettingsDivider()
                        SettingsRow("arrow.triangle.2.circlepath", tint: .green,
                                    title: language.t("settings.autoUpdate")) {
                            Toggle("", isOn: $updater.installsAutomatically)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                    }
                    SettingsDivider()
                    SettingsRow("chart.bar.fill", tint: .blue,
                                title: language.t("settings.shareUsageStatistics"),
                                subtitle: language.t("settings.shareUsageStatisticsSubtitle")) {
                        Toggle("", isOn: $preferences.sharesUsageStatistics)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }

            }

            footer
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
    }

    /// Version, updates and source in one quiet line: none of it is a setting,
    /// and all of it is occasionally wanted.
    private var footer: some View {
        HStack(spacing: 6) {
            // The version is the way into About, as it is in most Mac apps.
            Button { onAbout() } label: {
                Text(verbatim: "TokNotch \(updater.currentVersion)")
            }
            .buttonStyle(.plain)
            .help(language.t("menu.about"))
            if Updater.isConfigured {
                Text(verbatim: "·")
                Button(updater.outcome.label(language)) { updater.checkForUpdates() }
                    .buttonStyle(.link)
                    .disabled(updater.outcome == .checking)
            }
            Text(verbatim: "·")
            Link(destination: ForkMetadata.repositoryURL) {
                HStack(spacing: 3) {
                    Image(systemName: "star")
                    Text(language.t("settings.starOnGitHub"))
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
}
