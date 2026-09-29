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

    /// 菜单栏上某一项的当前数值；还没有数据时为 nil
    func menuBarValue(_ item: MenuBarItem, money: MoneyFormat) -> StatusIconRenderer.Value? {
        let rows = limitRows
        func limit(_ row: LimitRow?) -> StatusIconRenderer.Value? {
            row.map { .init(label: item.shortLabel, text: "\($0.percent)%", fraction: $0.fraction) }
        }
        func cost(_ amount: Double?) -> StatusIconRenderer.Value? {
            amount.map { .init(label: item.shortLabel, text: money.compact($0), fraction: nil) }
        }
        switch item {
        case .fiveHour: return limit(rows.first { $0.id == "five" })
        case .weekly: return limit(rows.first { $0.id == "week" })
        case .model(let name): return limit(rows.first { $0.id == "scoped-\(name)" || $0.id == "family-\(name)" })
        case .todayCost: return cost(snapshot?.day.cost)
        case .weekCost: return cost(snapshot?.week?.cost)
        case .monthCost: return cost(snapshot?.billing.cost)
        }
    }

    /// 有单独周额度的模型（例如 Fable），可以放到菜单栏上
    var limitModels: [String] {
        limitRows.compactMap { row in
            for prefix in ["scoped-", "family-"] where row.id.hasPrefix(prefix) { return String(row.id.dropFirst(prefix.count)) }
            return nil
        }
    }

    static func rows(from usage: OfficialUsage, now: Date) -> [LimitRow] {
        var rows: [LimitRow] = []

        // 5 小时：没有进行中的窗口时官方返回 0% 且没有重置时间
        let five = usage.fiveHour ?? OfficialLimit(utilization: 0, resetsAt: nil)
        if let reset = five.resetsAt {
            rows.append(reset > now
                ? LimitRow(id: "five", title: L10n.tNow("5 小时", "5-hour"), percent: five.percent, reset: .countdown(reset), resetsAt: reset)
                : LimitRow(id: "five", title: L10n.tNow("5 小时", "5-hour"), percent: 0, reset: .elapsed, resetsAt: reset))
        } else {
            rows.append(LimitRow(id: "five", title: L10n.tNow("5 小时", "5-hour"), percent: five.percent, reset: .idle))
        }

        if let week = usage.sevenDay {
            rows.append(weekly(id: "week", title: L10n.tNow("本周 · 全部模型", "Week · all models"), week, now: now))
        }
        for scoped in usage.scoped {
            rows.append(weekly(id: "scoped-\(scoped.modelName)", title: L10n.tNow("本周 · \(scoped.modelName)", "Week · \(scoped.modelName)"), scoped.limit, now: now))
        }
        for (name, limit) in [("Sonnet", usage.sevenDaySonnet), ("Opus", usage.sevenDayOpus)] {
            guard let limit, limit.percent > 0, !usage.scoped.contains(where: { $0.modelName.hasPrefix(name) }) else { continue }
            rows.append(weekly(id: "family-\(name)", title: L10n.tNow("本周 · \(name)", "Week · \(name)"), limit, now: now))
        }
        return rows
    }

    private static func weekly(id: String, title: String, _ limit: OfficialLimit, now: Date) -> LimitRow {
        guard let reset = limit.resetsAt else { return LimitRow(id: id, title: title, percent: limit.percent, reset: .none) }
        if reset <= now { return LimitRow(id: id, title: title, percent: 0, reset: .elapsed, resetsAt: reset) }
        return LimitRow(id: id, title: title, percent: limit.percent, reset: .weekday(reset), resetsAt: reset)
    }
}
