import CoreGraphics
import SwiftUI

/// A coding tool tokscale reports usage under — the `client` field, not the model maker.
struct UsageApp: Hashable, Codable, Identifiable, Equatable {
    /// Tokscale client id (`cursor`, `codex`, …) or a synthetic id for tools with no ledger yet.
    let id: String

    /// Claude Desktop is detected locally but may not appear in tokscale scans.
    static let claudeDesktop = UsageApp(id: "claude-desktop")

    func title(_ language: AppLanguage) -> String {
        switch id {
        case "cursor":          return language.t("app.name.cursor")
        case "codex":           return language.t("app.name.codex")
        case "claude", "claude-code": return language.t("app.name.claudeCode")
        case "claude-desktop":  return language.t("app.name.claudeDesktop")
        default:
            return id.split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    var tint: Color {
        switch id {
        case "cursor":          return Color(hex: 0x6B6B6B)
        case "codex":           return Color(hex: 0x10A37F)
        case "claude", "claude-code", "claude-desktop": return Color(hex: 0xD97757)
        default:                return Palette.textSecondary
        }
    }

    var ringTint: Color { tint }

    var initials: String {
        switch id {
        case "cursor":          return "Cu"
        case "codex":           return "Cx"
        case "claude", "claude-code", "claude-desktop": return "Cl"
        default:
            let parts = id.prefix(2).uppercased()
            return parts.isEmpty ? "?" : String(parts)
        }
    }

    /// Traced logo for ring marks, same contract as `Vendor.outline`.
    var outline: [[CGPoint]]? {
        switch id {
        case "cursor": return GlyphOutline.cursor
        case "codex": return GlyphOutline.openai
        case "claude", "claude-code", "claude-desktop": return GlyphOutline.claude
        default: return nil
        }
    }

    /// Whether this app has subscription plans in the menu (vs pay-as-you-go only).
    var supportsSubscriptionPlans: Bool {
        switch id {
        case "cursor": return true
        case "codex": return true
        case "claude", "claude-code", "claude-desktop": return true
        default: return false
        }
    }
}

/// Which catalogue backs an app's plan menu.
enum UsageAppPlanKind {
    case openAI
    case anthropic
    case cursorEnterprise
    case usageBilled

    static func kind(for app: UsageApp) -> UsageAppPlanKind {
        switch app.id {
        case "codex": return .openAI
        case "cursor": return .cursorEnterprise
        case "claude", "claude-code", "claude-desktop": return .anthropic
        default: return .usageBilled
        }
    }
}

/// Resolves which menu item is selected for a stored subscription.
enum PlanMenuSelection {
    static func selected(plan: Subscription?,
                         catalog: (String) -> PlanCatalog.Plan?) -> PlanCatalog.Plan {
        guard let plan else { return .none }
        if plan.planID == nil { return .custom }
        if let id = plan.planID, let known = catalog(id) { return known }
        return plan.isActive ? .custom : .none
    }
}
