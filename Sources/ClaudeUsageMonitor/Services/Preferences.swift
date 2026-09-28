import Foundation
import Observation
import UsageCore

/// 订阅计划。预算是「API 等价美元」的经验估算，可在设置中一键校准。
enum Plan: String, CaseIterable, Identifiable, Codable {
    case pro, team, max5x, max20x, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pro: "Pro"
        case .team: "Team"
        case .max5x: "Max 5×"
        case .max20x: "Max 20×"
        case .custom: "自定义"
        }
    }



    var tagline: String {
        switch self {
        case .pro: "个人入门"
        case .team: "团队标准席位"
        case .max5x: "5 倍 Pro 用量"
        case .max20x: "20 倍 Pro 用量"
        case .custom: "自定义速率上限"
        }
    }

    /// 5 小时窗口预算（API 等价美元）。Max 20× 的数值来自与官方 `/usage` 百分比的对照反推，
    /// 其余计划按官方倍数关系折算。
    var fiveHourBudget: Double {
        switch self {
        case .pro: 38
        case .team: 48
        case .max5x: 190
        case .max20x: 750
        case .custom: 300
        }
    }

    /// 每周预算（API 等价美元）
    var weeklyBudget: Double {
        switch self {
        case .pro: 265
        case .team: 330
        case .max5x: 1320
        case .max20x: 5300
        case .custom: 2500
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
    case fiveHour, weekly, today, cycle
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHour: "5 小时"
        case .weekly: "本周"
        case .today: "今日费用"
        case .cycle: "本期费用"
        }
    }
}

/// 偏好设置（`UserDefaults` 持久化）。
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var plan: Plan { didSet { save(plan.rawValue, "plan") } }
    var billingAnchorDay: Int { didSet { save(billingAnchorDay, "billingAnchorDay") } }
    var weeklyResetWeekday: Int { didSet { save(weeklyResetWeekday, "weeklyResetWeekday") } }
    var weeklyResetHour: Int { didSet { save(weeklyResetHour, "weeklyResetHour") } }
    var weeklyResetMinute: Int { didSet { save(weeklyResetMinute, "weeklyResetMinute") } }
    var fiveHourBudget: Double { didSet { save(fiveHourBudget, "fiveHourBudget") } }
    var weeklyBudget: Double { didSet { save(weeklyBudget, "weeklyBudget") } }
    var budgetsCalibrated: Bool { didSet { save(budgetsCalibrated, "budgetsCalibrated") } }
    var dataDirectory: String? { didSet { save(dataDirectory, "dataDirectory") } }
    var currency: MoneyFormat.Unit { didSet { save(currency.rawValue, "currency") } }
    var exchangeRate: Double { didSet { save(exchangeRate, "exchangeRate") } }
    var menuBarIcon: MenuBarIcon { didSet { save(menuBarIcon.rawValue, "menuBarIcon") } }
    var menuBarStyle: MenuBarStyle { didSet { save(menuBarStyle.rawValue, "menuBarStyle") } }
    var menuBarMetric: MenuBarMetric { didSet { save(menuBarMetric.rawValue, "menuBarMetric") } }
    var warningThreshold: Double { didSet { save(warningThreshold, "warningThreshold") } }
    var notificationsEnabled: Bool { didSet { save(notificationsEnabled, "notificationsEnabled") } }
    /// 使用 Claude 官方用量接口（读取 Claude Code 的登录凭据）
    var officialUsageEnabled: Bool { didSet { save(officialUsageEnabled, "officialUsageEnabled") } }
    /// 手动指定的本周起算时间（周额度被中途重置时使用，进入下一个周期后不再生效）
    var weeklyStartOverride: Date? { didSet { save(weeklyStartOverride?.timeIntervalSince1970, "weeklyStartOverride") } }

    private init() {
        let d = UserDefaults.standard
        plan = Plan(rawValue: d.string(forKey: "plan") ?? "") ?? .max20x
        billingAnchorDay = d.object(forKey: "billingAnchorDay") as? Int ?? 1
        weeklyResetWeekday = d.object(forKey: "weeklyResetWeekday") as? Int ?? 7
        weeklyResetHour = d.object(forKey: "weeklyResetHour") as? Int ?? 22
        weeklyResetMinute = d.object(forKey: "weeklyResetMinute") as? Int ?? 0
        let p = Plan(rawValue: d.string(forKey: "plan") ?? "") ?? .max20x
        fiveHourBudget = d.object(forKey: "fiveHourBudget") as? Double ?? p.fiveHourBudget
        weeklyBudget = d.object(forKey: "weeklyBudget") as? Double ?? p.weeklyBudget
        budgetsCalibrated = d.bool(forKey: "budgetsCalibrated")
        dataDirectory = d.string(forKey: "dataDirectory")
        currency = MoneyFormat.Unit(rawValue: d.string(forKey: "currency") ?? "") ?? .usd
        exchangeRate = d.object(forKey: "exchangeRate") as? Double ?? 7.1
        menuBarIcon = MenuBarIcon(rawValue: d.string(forKey: "menuBarIcon") ?? "") ?? .mascot
        menuBarStyle = MenuBarStyle(rawValue: d.string(forKey: "menuBarStyle") ?? "") ?? .iconPercent
        menuBarMetric = MenuBarMetric(rawValue: d.string(forKey: "menuBarMetric") ?? "") ?? .fiveHour
        warningThreshold = d.object(forKey: "warningThreshold") as? Double ?? 0.8
        notificationsEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? true
        officialUsageEnabled = d.object(forKey: "officialUsageEnabled") as? Bool ?? true
        weeklyStartOverride = (d.object(forKey: "weeklyStartOverride") as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    // MARK: 派生值

    /// 切换计划时同步重置预算
    func apply(plan newPlan: Plan) {
        plan = newPlan
        if newPlan != .custom {
            fiveHourBudget = newPlan.fiveHourBudget
            weeklyBudget = newPlan.weeklyBudget
        }
        budgetsCalibrated = false
    }

    var usageSettings: UsageSettings {
        UsageSettings(
            billingAnchorDay: billingAnchorDay,
            weeklyResetWeekday: weeklyResetWeekday,
            weeklyResetHour: weeklyResetHour,
            weeklyResetMinute: weeklyResetMinute,
            fiveHourBudget: max(1, fiveHourBudget),
            weeklyBudget: max(1, weeklyBudget),
            calendar: .current,
            weeklyStartOverride: weeklyStartOverride
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
