import AppKit
import ServiceManagement
import UserNotifications
import UsageCore

/// 用量预警：跨过阈值时通过通知中心提醒，每个窗口每个阈值只提醒一次。
@MainActor
final class Notifier {
    private let defaults = UserDefaults.standard
    private var notified: [String]
    private var requested = false

    /// 只有打包成 .app 运行时才能使用通知中心（`swift run` 直接运行会崩溃）
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    init() {
        notified = UserDefaults.standard.stringArray(forKey: "notifiedWindows") ?? []
    }

    func evaluate(_ rows: [LimitRow], prefs: Preferences) {
        guard prefs.notificationsEnabled, center != nil else { return }
        let thresholds = Array(Set([prefs.warningThreshold, 0.95])).sorted(by: >)
        for row in rows where row.id == "five" || row.id == "week" {
            check(row, thresholds: thresholds)
        }
    }

    private func check(_ row: LimitRow, thresholds: [Double]) {
        let resetDate: Date
        switch row.reset {
        case .countdown(let d), .weekday(let d): resetDate = d
        case .elapsed, .idle, .none: return
        }
        let name = row.id == "five" ? L10n.t("5 小时限额", "5-hour limit") : L10n.t("本周限额", "Weekly limit")
        for t in thresholds where row.fraction >= t {
            // 以重置时间标识窗口，每个窗口每个阈值只提醒一次
            let key = "\(row.id)-\(Int(resetDate.timeIntervalSince1970 / 60))-\(Int(t * 100))"
            guard !notified.contains(key) else { return }
            notified.append(key)
            if notified.count > 60 { notified.removeFirst(notified.count - 60) }
            defaults.set(notified, forKey: "notifiedWindows")

            let reset = Fmt.countdown(resetDate.timeIntervalSinceNow, showSeconds: false)
            post(
                title: L10n.t("\(name)已使用 \(row.percent)%", "\(name) at \(row.percent)%"),
                body: t >= 0.95
                    ? L10n.t("即将触达上限，\(reset)后重置。", "Near the cap. Resets in \(reset).")
                    : L10n.t("当前消耗偏快，\(reset)后重置。", "Usage is running ahead. Resets in \(reset).")
            )
            return
        }
    }

    // MARK: 到期提醒

    /// 已经发过的到期提醒，和用量预警分开记：用量预警记得很快，混在一起会把这里挤掉、同一件事又提醒一遍
    private var expiryNotified = UserDefaults.standard.stringArray(forKey: "notifiedExpiry") ?? []

    /// 订阅到期前 3 天、1 天各提醒一次；官方显示扣款失败、付款要验证、订阅结束时提醒一次（恢复正常后再出问题会再提醒）；
    /// Claude Code 登录到期前 1 天提醒一次
    func evaluateExpiry(store: UsageStore, prefs: Preferences, now: Date = Date()) {
        guard prefs.expiryReminders, center != nil else { return }
        let official = store.official
        // 没有付费套餐（从来没订阅过）时，不谈订阅到期
        if let plan = official.detectedPlan ?? prefs.plan {
            switch official.subscriptionHealth {
            case .some(let health) where health != .active:
                remindOnce("status-\(health)") { subscriptionAlert(health, plan: plan) }
            case .some:
                forget { $0.hasPrefix("status-") }
                remindTerm(store.subscriptionTerm, plan: plan, prefs: prefs)
            case .none:
                remindTerm(store.subscriptionTerm, plan: plan, prefs: prefs)
            }
        }
        if let expires = official.loginExpiresAt {
            let left = expires.timeIntervalSince(now)
            if left > 0, left <= 86_400 {
                remindOnce("login-\(Int(expires.timeIntervalSince1970 / 60))") {
                    (L10n.t("Claude Code 登录\(LimitsSection.dayTime(expires)) 到期", "Claude Code login expires \(LimitsSection.dayTime(expires))"),
                     L10n.t("到期后要重新登录（claude auth login），官方用量才能继续同步。", "Sign in again after that (claude auth login) so official usage keeps syncing."))
                }
            }
        }
    }

    private func remindTerm(_ term: SubscriptionTerm?, plan: Plan, prefs: Preferences) {
        guard let term else { return }
        let prefix = "term-\(Int(term.end.timeIntervalSince1970 / 60))-"
        let sent = Set(expiryNotified.compactMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil })
        guard let point = term.dueReminder(sent: sent) else { return }
        remindOnce(prefix + "\(point)") {
            let title = switch term.daysLeft {
            case 0: L10n.t("\(plan.title) 订阅今天到期", "\(plan.title) subscription ends today")
            case 1: L10n.t("\(plan.title) 订阅明天到期", "\(plan.title) subscription ends tomorrow")
            default: L10n.t("\(plan.title) 订阅还剩 \(term.daysLeft) 天", "\(plan.title) subscription: \(term.daysLeft) days left")
            }
            let date = CycleSection.dayWithWeekday(term.end)
            return (title, L10n.t(
                "按每月扣费日（\(prefs.billingAnchorDay) 日），本期到 \(date)。准确日期以 claude.ai 的账单页为准。",
                "By your billing day (day \(prefs.billingAnchorDay)), this period ends \(date). The claude.ai billing page has the exact date."
            ))
        }
    }

    private func subscriptionAlert(_ health: SubscriptionHealth, plan: Plan) -> (String, String) {
        switch health {
        case .paymentFailed:
            (L10n.t("\(plan.title) 订阅续费扣款失败", "\(plan.title) renewal payment failed"),
             L10n.t("Anthropic 会再试几次。请到 claude.ai 的「设置 › 账单」更新付款方式。", "Anthropic will retry. Update the payment method in Settings > Billing on claude.ai."))
        case .actionRequired:
            (L10n.t("\(plan.title) 订阅付款需要验证", "\(plan.title) payment needs confirming"),
             L10n.t("续费付款需要验证，请到 claude.ai 的「设置 › 账单」完成付款。", "The renewal payment needs confirming. Finish it in Settings > Billing on claude.ai."))
        case .inactive, .active:
            (L10n.t("\(plan.title) 订阅已结束", "\(plan.title) subscription has ended"),
             L10n.t("官方账号资料显示订阅已经结束，可以在 claude.ai 重新订阅。", "Your official account profile shows the subscription has ended. You can subscribe again on claude.ai."))
        }
    }

    /// 同一件事只提醒一次
    private func remindOnce(_ key: String, _ make: () -> (String, String)) {
        guard !expiryNotified.contains(key) else { return }
        expiryNotified.append(key)
        if expiryNotified.count > 20 { expiryNotified.removeFirst(expiryNotified.count - 20) }
        defaults.set(expiryNotified, forKey: "notifiedExpiry")
        let (title, body) = make()
        post(title: title, body: body)
    }

    private func forget(_ matches: (String) -> Bool) {
        guard expiryNotified.contains(where: matches) else { return }
        expiryNotified.removeAll(where: matches)
        defaults.set(expiryNotified, forKey: "notifiedExpiry")
    }

    private func post(title: String, body: String) {
        guard let center else { return }
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if requested {
            send()
        } else {
            requested = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { send() }
            }
        }
    }
}

/// 系统通知权限。在「系统设置 › 通知」里关掉了这个 App，预警和到期提醒都不会弹出，系统只是默默收下
enum NotificationPermission {
    static func isDenied() async -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// 打开「系统设置 › 通知」里这个 App 的那一页
    static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 开机自启动（SMAppService）
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
