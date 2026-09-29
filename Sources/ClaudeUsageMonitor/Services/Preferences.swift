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
        case .mascot: L10n.tNow("Clawd 吉祥物", "Clawd")
        case .logo: L10n.tNow("Claude 标志", "Claude logo")
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable, Codable {
    case icon, iconPercent, ringPercent, dualBars
    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: L10n.tNow("仅图标", "Icon")
        case .iconPercent: L10n.tNow("图标 + 百分比", "Icon + percent")
        case .ringPercent: L10n.tNow("圆环 + 百分比", "Ring + percent")
        case .dualBars: L10n.tNow("图标 + 双条", "Icon + bars")
        }
    }
}

enum MenuBarMetric: String, CaseIterable, Identifiable, Codable {
    case fiveHour, weekly, today, week, cycle
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHour: L10n.tNow("5 小时", "5-hour")
        case .weekly: L10n.tNow("本周百分比", "Weekly percent")
        case .today: L10n.tNow("每日费用", "Today")
        case .week: L10n.tNow("每周费用", "This week")
        case .cycle: L10n.tNow("每月费用", "This month")
        }
    }
}

/// 本期消耗的统计范围。Claude 的额度按周重置，默认是本周。
enum CostSpan: String, CaseIterable, Identifiable, Codable {
    case month, week, day
    var id: String { rawValue }

    var title: String {
        switch self {
        case .month: L10n.tNow("本月周期", "This month")
        case .week: L10n.tNow("本周期", "This week")
        case .day: L10n.tNow("每日", "Today")
        }
    }
}

extension AutoSyncMode: Identifiable {
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .consumption: L10n.tNow("按 Token 消耗", "By token use")
        case .every10Seconds: L10n.tNow("每 10 秒", "Every 10 seconds")
        case .every30Seconds: L10n.tNow("每 30 秒", "Every 30 seconds")
        case .everyMinute: L10n.tNow("每 1 分钟", "Every minute")
        case .every2Minutes: L10n.tNow("每 2 分钟", "Every 2 minutes")
        case .every5Minutes: L10n.tNow("每 5 分钟", "Every 5 minutes")
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
    /// 界面语言。默认跟随系统。
    var appLanguage: AppLanguage {
        didSet {
            save(appLanguage.rawValue, "appLanguage")
            Localization.shared.apply(appLanguage)
        }
    }
    var menuBarIcon: MenuBarIcon { didSet { save(menuBarIcon.rawValue, "menuBarIcon") } }
    var menuBarStyle: MenuBarStyle { didSet { save(menuBarStyle.rawValue, "menuBarStyle") } }
    var menuBarMetric: MenuBarMetric { didSet { save(menuBarMetric.rawValue, "menuBarMetric") } }
    /// 菜单栏数值右侧显示出口安不安全。
    var showExitSafety: Bool { didSet { save(showExitSafety, "showExitSafety") } }
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
    /// 官方用量和续期的出口。空字符串表示系统代理。
    var officialProxy: String { didSet { save(officialProxy, "officialProxy") } }
    /// Claude Code 的登录快过期时自动续期。默认开启。
    var autoRenewLogin: Bool { didSet { save(autoRenewLogin, "autoRenewLogin") } }
    /// 自动查询官方用量的频率。默认按 Token 消耗。
    var autoSyncMode: AutoSyncMode { didSet { save(autoSyncMode.rawValue, "autoSyncMode") } }

    private init() {
        let d = UserDefaults.standard
        // 1.0 用于本地估算的设置已经不再需要
        for key in ["fiveHourBudget", "weeklyBudget", "budgetsCalibrated", "weeklyResetWeekday", "weeklyResetHour",
                    "weeklyResetMinute", "weeklyStartOverride", "weeklyResetTracker", "exchangeRate"] {
            d.removeObject(forKey: key)
        }
        plan = Plan(rawValue: d.string(forKey: "plan") ?? "")
        billingAnchorDay = d.object(forKey: "billingAnchorDay") as? Int ?? 1
        billingAnchorHour = d.object(forKey: "billingAnchorHour") as? Int
        billingAnchorMinute = d.object(forKey: "billingAnchorMinute") as? Int
        billingAnchorSecond = d.object(forKey: "billingAnchorSecond") as? Int
        dataDirectory = d.string(forKey: "dataDirectory")
        currency = MoneyFormat.Unit(rawValue: d.string(forKey: "currency") ?? "") ?? .usd
        appLanguage = AppLanguage(rawValue: d.string(forKey: "appLanguage") ?? "") ?? .system
        menuBarIcon = MenuBarIcon(rawValue: d.string(forKey: "menuBarIcon") ?? "") ?? .mascot
        menuBarStyle = MenuBarStyle(rawValue: d.string(forKey: "menuBarStyle") ?? "") ?? .iconPercent
        menuBarMetric = MenuBarMetric(rawValue: d.string(forKey: "menuBarMetric") ?? "") ?? .fiveHour
        showExitSafety = d.object(forKey: "showExitSafety") as? Bool ?? true
        costSpan = CostSpan(rawValue: d.string(forKey: "costSpan") ?? "") ?? .week
        weeklyResetAt = (d.object(forKey: "weeklyResetAt") as? Double).map { Date(timeIntervalSince1970: $0) }
        warningThreshold = d.object(forKey: "warningThreshold") as? Double ?? 0.8
        notificationsEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? true
        officialUsageEnabled = d.object(forKey: "officialUsageEnabled") as? Bool ?? true
        officialProxy = d.string(forKey: "officialProxy") ?? ""
        // 自动续期默认开启。1.1 之后有一版出于安全考虑统一关掉过一次，这里恢复一次，之后尊重用户自己的选择。
        if d.object(forKey: "didEnableAutoRenewByDefault") == nil {
            d.set(true, forKey: "didEnableAutoRenewByDefault")
            d.set(true, forKey: "autoRenewLogin")
            d.removeObject(forKey: "didDisableAutoRenewForSafety")
            autoRenewLogin = true
        } else {
            autoRenewLogin = d.object(forKey: "autoRenewLogin") as? Bool ?? true
        }
        autoSyncMode = AutoSyncMode(rawValue: d.string(forKey: "autoSyncMode") ?? "") ?? .consumption
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

    var money: MoneyFormat {
        _ = ExchangeRates.shared.fetchedAt
        return MoneyFormat(unit: currency, rate: ExchangeRates.shared.rate(for: currency))
    }

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
