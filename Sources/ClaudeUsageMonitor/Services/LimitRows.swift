import Foundation
import UsageCore

/// 一行限额（弹窗、菜单栏与通知共用），数值全部来自官方接口。
struct LimitRow: Identifiable, Equatable {
    enum Reset: Equatable {
        /// 5 小时：倒计时
        case countdown(Date)
        /// 每周：星期与时刻
        case weekday(Date)
        /// 已到重置时间，正在等待同步新窗口的数据
        case elapsed
        /// 当前没有进行中的 5 小时窗口
        case idle
        case none
    }

    let id: String
    let title: String
    /// 与官方显示一致的整数百分比
    let percent: Int
    let reset: Reset
    /// 精确的重置时间（悬停提示用）
    var resetsAt: Date?

    var fraction: Double { Double(percent) / 100 }
}

extension UsageStore {
    /// 当前应展示的限额行：第一行为 5 小时，第二行为本周全部模型，之后是按模型划分的周额度
    var limitRows: [LimitRow] {
        official.usage.map { Self.rows(from: $0, now: Date()) } ?? []
    }

    static func rows(from usage: OfficialUsage, now: Date) -> [LimitRow] {
        var rows: [LimitRow] = []

        // 5 小时：没有进行中的窗口时官方返回 0% 且没有重置时间
        let five = usage.fiveHour ?? OfficialLimit(utilization: 0, resetsAt: nil)
        if let reset = five.resetsAt {
            rows.append(reset > now
                ? LimitRow(id: "five", title: "5 小时", percent: five.percent, reset: .countdown(reset), resetsAt: reset)
                : LimitRow(id: "five", title: "5 小时", percent: 0, reset: .elapsed, resetsAt: reset))
        } else {
            rows.append(LimitRow(id: "five", title: "5 小时", percent: five.percent, reset: .idle))
        }

        if let week = usage.sevenDay {
            rows.append(weekly(id: "week", title: "本周 · 全部模型", week, now: now))
        }
        for scoped in usage.scoped {
            rows.append(weekly(id: "scoped-\(scoped.modelName)", title: "本周 · \(scoped.modelName)", scoped.limit, now: now))
        }
        for (name, limit) in [("Sonnet", usage.sevenDaySonnet), ("Opus", usage.sevenDayOpus)] {
            guard let limit, limit.percent > 0, !usage.scoped.contains(where: { $0.modelName.hasPrefix(name) }) else { continue }
            rows.append(weekly(id: "family-\(name)", title: "本周 · \(name)", limit, now: now))
        }
        return rows
    }

    private static func weekly(id: String, title: String, _ limit: OfficialLimit, now: Date) -> LimitRow {
        guard let reset = limit.resetsAt else { return LimitRow(id: id, title: title, percent: limit.percent, reset: .none) }
        if reset <= now { return LimitRow(id: id, title: title, percent: 0, reset: .elapsed, resetsAt: reset) }
        return LimitRow(id: id, title: title, percent: limit.percent, reset: .weekday(reset), resetsAt: reset)
    }
}
