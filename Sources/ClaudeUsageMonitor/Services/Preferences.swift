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
        case .iconPercent: L10n.tNow("图标 + 数值", "Icon + values")
        case .ringPercent: L10n.tNow("圆环 + 数值", "Ring + values")
        case .dualBars: L10n.tNow("图标 + 双条", "Icon + bars")
        }
    }
}

/// 菜单栏上可以显示的数值，可以多选。按模型的周额度（例如 Fable）用模型名区分。
enum MenuBarItem: Hashable, Identifiable {
    case fiveHour
    case weekly
    case model(String)
    case todayCost
    case weekCost
    case monthCost

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .fiveHour: "fiveHour"
        case .weekly: "weekly"
        case .model(let name): "model:\(name)"
        case .todayCost: "today"
        case .weekCost: "week"
        case .monthCost: "cycle"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "fiveHour": self = .fiveHour
        case "weekly": self = .weekly
        case "today": self = .todayCost
        case "week": self = .weekCost
        case "cycle": self = .monthCost
        default:
            guard rawValue.hasPrefix("model:"), rawValue.count > 6 else { return nil }
            self = .model(String(rawValue.dropFirst(6)))
        }
    }

    /// 设置里的完整名字，也用于菜单栏的悬停说明
    var title: String {
        switch self {
        case .fiveHour: L10n.tNow("5 小时", "5-hour")
        case .weekly: L10n.tNow("本周 · 全部模型", "Week · all models")
        case .model(let name): L10n.tNow("本周 · \(name)", "Week · \(name)")
        case .todayCost: L10n.tNow("今日费用", "Today's cost")
        case .weekCost: L10n.tNow("本周费用", "This week's cost")
        case .monthCost: L10n.tNow("本月费用", "This month's cost")
        }
    }

    /// 菜单栏上数值上方的小标签，尽量短
    var shortLabel: String {
        switch self {
        case .fiveHour: L10n.tNow("5小时", "5H")
        case .weekly: L10n.tNow("本周", "WEEK")
        case .model(let name): L10n.tNow(name, name.uppercased())
        case .todayCost: L10n.tNow("今日", "TODAY")
        case .weekCost: L10n.tNow("本周", "WEEK")
        case .monthCost: L10n.tNow("本月", "MONTH")
        }
    }

    var isCost: Bool {
        switch self {
        case .todayCost, .weekCost, .monthCost: true
        default: false
        }
    }

    /// 按菜单栏上的顺序排列：限额在前、费用在后；同类之间保持原来的先后
    static func ordered(_ items: [MenuBarItem]) -> [MenuBarItem] {
        items.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
    }

    /// 菜单栏上的排列顺序：限额在前（5 小时、本周、各模型），费用在后
    var order: Int {
        switch self {
        case .fiveHour: 0
        case .weekly: 1
        case .model: 2
        case .todayCost: 3
        case .weekCost: 4
        case .monthCost: 5
        }
    }
}

/// 面板里重置时间的写法（按系统当前时区）
enum ResetTimeStyle: String, CaseIterable, Identifiable, Codable {
    /// 周六 22:00；今天、明天写作「今天」「明天」
    case weekday
    /// 2026年10月3日 22:00
    case fullDate
    var id: String { rawValue }
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
    /// 菜单栏里的 Clawd 不停地活动（动作取自 Claude Code）。默认开启。
    var menuBarAnimation: Bool { didSet { save(menuBarAnimation, "menuBarAnimation") } }
    /// 菜单栏显示哪些数值（可以多选）。默认只显示 5 小时。
    var menuBarItems: [MenuBarItem] { didSet { save(menuBarItems.map(\.rawValue), "menuBarItems") } }

    /// 菜单栏上的实际顺序：限额在前、费用在后；同类之间保持选择的先后
    var orderedMenuBarItems: [MenuBarItem] { MenuBarItem.ordered(menuBarItems) }
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
    /// 自动查询的最短间隔（秒）：两次自动查询至少隔这么久。默认 30 秒，可以在 10 秒到 1 小时之间自定义。
    /// 什么时候查由 Token 消耗决定（见 `AutoSyncPolicy`），这里只限制最快的频率。
    var autoSyncInterval: TimeInterval {
        didSet {
            let clamped = AutoSyncPolicy.clampedInterval(autoSyncInterval)
            if autoSyncInterval != clamped { autoSyncInterval = clamped }
            save(clamped, "autoSyncInterval")
        }
    }
    /// 点开菜单栏图标时刷新一次。默认开启。
    var refreshOnOpen: Bool { didSet { save(refreshOnOpen, "refreshOnOpen") } }
    /// 面板里重置时间的写法。默认「周六 22:00」。
    var resetTimeStyle: ResetTimeStyle { didSet { save(resetTimeStyle.rawValue, "resetTimeStyle") } }
    /// 重置时间旁显示倒计时，精确到秒、每秒刷新。默认关闭。
    var showsResetCountdown: Bool { didSet { save(showsResetCountdown, "showsResetCountdown") } }

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
        let language = AppLanguage(rawValue: d.string(forKey: "appLanguage") ?? "") ?? .system
        appLanguage = language
        // 初始化时不会触发 didSet：启动时要自己套用保存的语言，否则重启后又回到系统语言
        Localization.shared.apply(language)
        menuBarIcon = MenuBarIcon(rawValue: d.string(forKey: "menuBarIcon") ?? "") ?? .mascot
        menuBarStyle = MenuBarStyle(rawValue: d.string(forKey: "menuBarStyle") ?? "") ?? .iconPercent
        menuBarAnimation = d.object(forKey: "menuBarAnimation") as? Bool ?? true
        // 以前只能选一个数值：沿用那一个
        let savedItems = (d.stringArray(forKey: "menuBarItems") ?? d.string(forKey: "menuBarMetric").map { [$0] } ?? [])
            .compactMap(MenuBarItem.init(rawValue:))
        menuBarItems = savedItems.isEmpty ? [.fiveHour] : savedItems
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
        // 1.2.5 及以前「自动查询」选的是几档固定频率：换成同样秒数的最短间隔，之后不再需要这一项
        if let legacy = d.string(forKey: "autoSyncMode").flatMap(AutoSyncPolicy.legacyInterval), d.object(forKey: "autoSyncInterval") == nil {
            d.set(legacy, forKey: "autoSyncInterval")
        }
        d.removeObject(forKey: "autoSyncMode")
        autoSyncInterval = AutoSyncPolicy.clampedInterval(d.object(forKey: "autoSyncInterval") as? Double ?? AutoSyncPolicy.defaultInterval)
        refreshOnOpen = d.object(forKey: "refreshOnOpen") as? Bool ?? true
        resetTimeStyle = ResetTimeStyle(rawValue: d.string(forKey: "resetTimeStyle") ?? "") ?? .weekday
        showsResetCountdown = d.object(forKey: "showsResetCountdown") as? Bool ?? false
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
