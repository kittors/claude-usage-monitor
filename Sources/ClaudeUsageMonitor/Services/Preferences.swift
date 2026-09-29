import Foundation
import Observation
import UsageCore

/// 订阅套餐（由服务端账号资料识别，只用于展示）
enum Plan: String, CaseIterable, Identifiable, Codable {
    case pro, max5x, max20x, team, enterprise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pro: "Pro"
        case .max5x: "Max 5×"
        case .max20x: "Max 20×"
        case .team: "Team"
        case .enterprise: "Enterprise"
        }
    }
}

enum MenuBarIcon: String, CaseIterable, Identifiable, Codable {
    case mascot, logo
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mascot: "Clawd 吉祥物"
        case .logo: "Claude 标志"
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable, Codable {
    case icon, iconPercent, ringPercent, dualBars
    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: "仅图标"
        case .iconPercent: "图标 + 百分比"
        case .ringPercent: "圆环 + 百分比"
        case .dualBars: "图标 + 双条"
        }
    }
}

enum MenuBarMetric: String, CaseIterable, Identifiable, Codable {
    case fiveHour, weekly, today, week, cycle
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHour: "5 小时"
        case .weekly: "本周百分比"
        case .today: "每日费用"
        case .week: "每周费用"
        case .cycle: "每月费用"
        }
    }
}

/// 本期消耗的统计范围。Claude 的额度按周重置，默认是本周。
enum CostSpan: String, CaseIterable, Identifiable, Codable {
    case month, week, day
    var id: String { rawValue }

    var title: String {
        switch self {
        case .month: "本月周期"
        case .week: "本周期"
        case .day: "每日"
        }
    }
}

/// 偏好设置（`UserDefaults` 持久化）。
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// 最近一次从服务端识别到的套餐（启动后、首次同步前用于展示）
    var plan: Plan? { didSet { save(plan?.rawValue, "plan") } }
    var billingAnchorDay: Int { didSet { save(billingAnchorDay, "billingAnchorDay") } }
    /// 上次从每周限额记下的重置时刻。还没同步过时为 nil，周期暂时按 0:00。
    var billingAnchorHour: Int? {
        didSet {
            guard let hour = billingAnchorHour else { save(nil, "billingAnchorHour"); return }
            let clamped = min(max(0, hour), 23)
            if hour != clamped { billingAnchorHour = clamped; return }
            save(clamped, "billingAnchorHour")
        }
    }
    var billingAnchorMinute: Int? {
        didSet {
            guard let minute = billingAnchorMinute else { save(nil, "billingAnchorMinute"); return }
            let clamped = min(max(0, minute), 59)
            if minute != clamped { billingAnchorMinute = clamped; return }
            save(clamped, "billingAnchorMinute")
        }
    }
    var billingAnchorSecond: Int? {
        didSet {
            guard let second = billingAnchorSecond else { save(nil, "billingAnchorSecond"); return }
            let clamped = min(max(0, second), 59)
            if second != clamped { billingAnchorSecond = clamped; return }
            save(clamped, "billingAnchorSecond")
        }
    }
    var dataDirectory: String? { didSet { save(dataDirectory, "dataDirectory") } }
    var currency: MoneyFormat.Unit { didSet { save(currency.rawValue, "currency") } }
    var exchangeRate: Double { didSet { save(exchangeRate, "exchangeRate") } }
    var menuBarIcon: MenuBarIcon { didSet { save(menuBarIcon.rawValue, "menuBarIcon") } }
    var menuBarStyle: MenuBarStyle { didSet { save(menuBarStyle.rawValue, "menuBarStyle") } }
    var menuBarMetric: MenuBarMetric { didSet { save(menuBarMetric.rawValue, "menuBarMetric") } }
    /// 本期消耗看哪一段。默认本周，因为额度按周重置。
    var costSpan: CostSpan { didSet { save(costSpan.rawValue, "costSpan") } }
    /// 上次同步到的每周限额重置时间，用来在下次同步前继续对齐本周。
    var weeklyResetAt: Date? {
        didSet {
            if let weeklyResetAt { save(weeklyResetAt.timeIntervalSince1970, "weeklyResetAt") }
            else { save(nil, "weeklyResetAt") }
        }
    }
    var warningThreshold: Double { didSet { save(warningThreshold, "warningThreshold") } }
    var notificationsEnabled: Bool { didSet { save(notificationsEnabled, "notificationsEnabled") } }
    /// 使用 Claude 官方用量接口（读取 Claude Code 的登录凭据）
    var officialUsageEnabled: Bool { didSet { save(officialUsageEnabled, "officialUsageEnabled") } }
    /// Claude Code 的登录过期时自动续期（与 Claude Code 相同的流程）
    var autoRenewLogin: Bool { didSet { save(autoRenewLogin, "autoRenewLogin") } }

    private init() {
        let d = UserDefaults.standard
        // 1.0 用于本地估算的设置已经不再需要
        for key in ["fiveHourBudget", "weeklyBudget", "budgetsCalibrated", "weeklyResetWeekday", "weeklyResetHour",
                    "weeklyResetMinute", "weeklyStartOverride", "weeklyResetTracker"] {
            d.removeObject(forKey: key)
        }
        plan = Plan(rawValue: d.string(forKey: "plan") ?? "")
        billingAnchorDay = d.object(forKey: "billingAnchorDay") as? Int ?? 1
        billingAnchorHour = d.object(forKey: "billingAnchorHour") as? Int
        billingAnchorMinute = d.object(forKey: "billingAnchorMinute") as? Int
        billingAnchorSecond = d.object(forKey: "billingAnchorSecond") as? Int
        dataDirectory = d.string(forKey: "dataDirectory")
        currency = MoneyFormat.Unit(rawValue: d.string(forKey: "currency") ?? "") ?? .usd
        exchangeRate = d.object(forKey: "exchangeRate") as? Double ?? 7.1
        menuBarIcon = MenuBarIcon(rawValue: d.string(forKey: "menuBarIcon") ?? "") ?? .mascot
        menuBarStyle = MenuBarStyle(rawValue: d.string(forKey: "menuBarStyle") ?? "") ?? .iconPercent
        menuBarMetric = MenuBarMetric(rawValue: d.string(forKey: "menuBarMetric") ?? "") ?? .fiveHour
        costSpan = CostSpan(rawValue: d.string(forKey: "costSpan") ?? "") ?? .week
        weeklyResetAt = (d.object(forKey: "weeklyResetAt") as? Double).map { Date(timeIntervalSince1970: $0) }
        warningThreshold = d.object(forKey: "warningThreshold") as? Double ?? 0.8
        notificationsEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? true
        officialUsageEnabled = d.object(forKey: "officialUsageEnabled") as? Bool ?? true
        autoRenewLogin = d.object(forKey: "autoRenewLogin") as? Bool ?? true
    }

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    // MARK: 派生值

    var usageSettings: UsageSettings {
        UsageSettings(
            billingAnchorDay: billingAnchorDay,
            billingAnchorHour: billingAnchorHour ?? 0,
            billingAnchorMinute: billingAnchorMinute ?? 0,
            billingAnchorSecond: billingAnchorSecond ?? 0,
            weeklyReset: weeklyResetAt,
            calendar: .current
        )
    }

    var money: MoneyFormat { MoneyFormat(unit: currency, rate: exchangeRate) }

    static var defaultDataDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [home.appendingPathComponent(".claude/projects")]
        if let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            for part in config.split(separator: ",") {
                roots.insert(URL(fileURLWithPath: String(part)).appendingPathComponent("projects"), at: 0)
            }
        }
        roots.append(home.appendingPathComponent(".config/claude/projects"))
        return roots
    }

    var dataRoots: [URL] {
        if let dataDirectory, !dataDirectory.isEmpty { return [URL(fileURLWithPath: dataDirectory)] }
        return Self.defaultDataDirectories.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var dataRootsDisplay: String {
        dataRoots.map { $0.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
            .joined(separator: "\n")
    }

    var sourceSignature: String { dataRoots.map(\.path).sorted().joined(separator: "|") }
}
