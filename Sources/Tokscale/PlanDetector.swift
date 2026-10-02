import Foundation

/// A plan read from a tool's own configuration rather than typed in.
struct DetectedPlan: Equatable {
    let planID: String
    /// What the vendor calls it, when we recognise the id.
    let name: String
    /// List price for that plan, or nil when the id is one we do not know.
    let monthlyUSD: Double?
    /// The day of the month the subscription renews on, taken from when it
    /// started — Stripe bills on the anniversary of the first payment.
    let renewalDay: Int?
    /// Shown in settings, so it is never a mystery where a number came from.
    let source: String

    var subscription: Subscription? {
        guard let monthlyUSD, monthlyUSD > 0 else { return nil }
        return Subscription(monthlyUSD: monthlyUSD, renewalDay: renewalDay ?? 1,
                            planID: planID)
    }

    /// Detected identity without a list price — typical for enterprise seats.
    var needsManualMonthlyPrice: Bool {
        monthlyUSD == nil || monthlyUSD == 0
    }
}

/// Finds the plans a Mac is already signed in to.
///
/// Two kinds of source, and the difference matters:
///
/// * Claude Code keeps the account's plan in `~/.claude.json`, an ordinary
///   configuration file with no token in it.
/// * Codex keeps it inside the identity token in `~/.codex/auth.json`, which
///   *is* the credential store.
///
/// Neither goes near the keychain, so no password prompt can appear either way.
/// From the second, only the three plan claims are ever read — the plan type
/// and the dates around it. The access token, the refresh token and the API key
/// that sit beside them in the same file are never read, never copied and never
/// logged, and nothing from any of this leaves the machine.
enum PlanDetector {
    static func detect(fileManager: FileManager = .default) -> [UsageApp: DetectedPlan] {
        var found: [UsageApp: DetectedPlan] = [:]
        if let claude = detectClaude(fileManager: fileManager) {
            found[UsageApp(id: "claude")] = claude
        } else if let desktop = detectClaudeDesktop(fileManager: fileManager) {
            found[UsageApp.claudeDesktop] = desktop
        }
        if let codex = detectCodex(fileManager: fileManager) {
            found[UsageApp(id: "codex")] = codex
        }
        return found
    }

    // MARK: - Anthropic

    /// `~/.claude.json` → `oauthAccount.organizationType`, plus the date the
    /// subscription started.
    static func detectClaude(fileManager: FileManager = .default,
                             path: String? = nil) -> DetectedPlan? {
        let file = path ?? NSString(string: "~/.claude.json").expandingTildeInPath
        guard fileManager.isReadableFile(atPath: file),
              let data = fileManager.contents(atPath: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }

        let billing = account["billingType"] as? String
        let type = account["organizationType"] as? String
        let known = type.flatMap { PlanCatalog.plan(id: $0, for: .anthropic) }

        // Stripe subscriptions carry a list price; enterprise and API-billed
        // accounts still name themselves so payback can use a custom seat cost.
        if billing != nil && billing != "stripe_subscription" {
            let id = type ?? "claude_enterprise"
            return DetectedPlan(
                planID: id,
                name: known?.name ?? readable(id),
                monthlyUSD: nil,
                renewalDay: (account["subscriptionCreatedAt"] as? String).flatMap { Self.day(ofISO: $0) },
                source: "~/.claude.json"
            )
        }

        guard let type else { return nil }

        return DetectedPlan(
            planID: type,
            name: known?.name ?? readable(type),
            monthlyUSD: known?.monthlyUSD,
            renewalDay: (account["subscriptionCreatedAt"] as? String).flatMap { Self.day(ofISO: $0) },
            source: "~/.claude.json"
        )
    }

    /// Claude Desktop keeps no JSONL ledger tokscale can scan. We still surface
    /// that the app is present so Settings can explain the gap.
    static func detectClaudeDesktop(fileManager: FileManager = .default,
                                    configPath: String? = nil) -> DetectedPlan? {
        let config = configPath ?? NSString(string: "~/Library/Application Support/Claude/config.json")
            .expandingTildeInPath
        guard fileManager.isReadableFile(atPath: config) else { return nil }
        return DetectedPlan(
            planID: "claude_enterprise",
            name: "Claude Desktop",
            monthlyUSD: nil,
            renewalDay: nil,
            source: "Claude.app"
        )
    }

    // MARK: - OpenAI

    /// `~/.codex/auth.json` → the ChatGPT plan carried in the identity token.
    ///
    /// The plan is not in any of Codex's configuration files — its global state
    /// carries no plan, subscription or billing field at all — so the identity
    /// token is the only place on the machine that knows. Its payload is a
    /// plain base64url JSON claim set; it is decoded here, never verified and
    /// never sent anywhere, because the only thing being asked of it is a
    /// string the user already knows about themselves.
    static func detectCodex(fileManager: FileManager = .default,
                            path: String? = nil) -> DetectedPlan? {
        let file = path ?? NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard fileManager.isReadableFile(atPath: file),
              let data = fileManager.contents(atPath: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let identity = tokens["id_token"] as? String,
              let claims = self.claims(ofJWT: identity),
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let type = auth["chatgpt_plan_type"] as? String
        else { return nil }

        // A free account has nothing to weigh usage against.
        guard type.lowercased() != "free" else { return nil }

        let id = "chatgpt_\(type.lowercased())"
        let known = PlanCatalog.plan(id: id, for: .openai)
        return DetectedPlan(
            planID: id,
            name: known?.name ?? "ChatGPT \(type.capitalized)",
            monthlyUSD: known?.monthlyUSD,
            renewalDay: (auth["chatgpt_subscription_active_start"] as? String)
                .flatMap { Self.day(ofISO: $0) },
            source: "~/.codex/auth.json"
        )
    }

    /// A JWT's claim set, decoded but deliberately not verified.
    ///
    /// Verification would need OpenAI's signing keys and a network round trip,
    /// and would prove something nobody is asking about: this is not an
    /// authentication decision, it is reading a plan name the account holder
    /// already knows.
    static func claims(ofJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Shared

    /// The day of the month out of an ISO 8601 timestamp.
    static func day(ofISO string: String, calendar: Calendar = .current) -> Int? {
        // Both shapes occur: Claude writes fractional seconds, OpenAI does not.
        // Vendors record these in UTC; the renewal *day* is the UTC calendar day.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let date = withFraction.date(from: string) ?? plain.date(from: string)
        guard let date else { return nil }
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return utc.component(.day, from: date)
    }

    /// `claude_max_20x` → `Claude Max 20x`, for a plan id we do not have a
    /// price for. Better than showing the raw identifier.
    private static func readable(_ id: String) -> String {
        id.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
