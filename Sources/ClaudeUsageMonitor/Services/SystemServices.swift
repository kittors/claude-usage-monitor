import Foundation
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
