import Foundation
import UsageCore

/// 一行限额（弹窗、菜单栏与通知共用）。官方数据可用时取官方值，否则为本地估算。
struct LimitRow: Identifiable, Equatable {
    enum Reset: Equatable {
        case countdown(Date)
        case weekday(Date)
        case idle
        case none
    }

    let id: String
    let title: String
    let fraction: Double
    let reset: Reset
    let isOfficial: Bool
    /// 本机在该窗口内的 API 等价费用
    var localCost: Double?
    /// 估算模式下的预算
    var budget: Double?
    /// 最近 60 分钟的消耗速率（美元 / 小时）
    var burnRate: Double?
    /// 按当前速率到重置时的预计占比
    var projected: Double?
    /// 本机费用的起算时间：仅在本周额度被中途重置过时才有
    var since: Since?
    /// 官方数据的同步时间（之后的变化由本机用量推算）
    var syncedAt: Date?

    struct Since: Equatable {
        let date: Date
        let source: WeeklyStartSource
    }
}

extension UsageStore {
    /// 当前应展示的限额行：第一行为 5 小时，第二行为本周全部模型
    var limitRows: [LimitRow] {
        guard let snap = snapshot else { return [] }
        if let usage = official.freshUsage {
            return officialRows(usage, snap)
        }
        return estimatedRows(snap)
    }

    var isUsingOfficialLimits: Bool { official.freshUsage != nil }

    private func officialRows(_ usage: OfficialUsage, _ snap: UsageSnapshot) -> [LimitRow] {
        let now = Date()
        // 两次同步之间：官方百分比 + 同步之后的本机新增费用 ÷ 预算，下次同步时再用官方值校正
        let sinceSync = snap.costSinceSync
        var rows: [LimitRow] = []

        if let five = usage.fiveHour, let reset = five.resetsAt, reset > now {
            let budget = max(1, prefs.fiveHourBudget)
            let fraction = five.fraction + sinceSync / budget
            var row = LimitRow(
                id: "five", title: "5 小时", fraction: fraction, reset: .countdown(reset), isOfficial: true,
                localCost: snap.fiveHour.cost, burnRate: snap.fiveHour.burnRatePerHour, syncedAt: usage.fetchedAt
            )
            if snap.fiveHour.burnRatePerHour > 0 {
                row.projected = fraction + snap.fiveHour.burnRatePerHour * reset.timeIntervalSince(now) / 3600 / budget
            }
            rows.append(row)
        } else {
            // 官方窗口已经结束、还没同步到新窗口：先按本机用量估算
            let five = snap.fiveHour
            rows.append(LimitRow(
                id: "five", title: "5 小时", fraction: five.isActive ? five.fraction : 0,
                reset: five.isActive ? .countdown(five.end) : .idle, isOfficial: false,
                localCost: five.isActive ? five.cost : nil, burnRate: five.burnRatePerHour
            ))
        }

        if let week = usage.sevenDay, let reset = week.resetsAt, reset > now {
            let budget = max(1, snap.weeklyInferredBudget ?? prefs.weeklyBudget)
            rows.append(LimitRow(
                id: "week", title: "本周 · 全部模型", fraction: week.fraction + sinceSync / budget,
                reset: .weekday(reset), isOfficial: true, localCost: snap.weekly.cost,
                since: Self.weeklySince(snap), syncedAt: usage.fetchedAt
            ))
        } else {
            let week = snap.weekly
            rows.append(LimitRow(
                id: "week", title: "本周 · 全部模型", fraction: week.fraction, reset: .weekday(week.end),
                isOfficial: false, localCost: week.cost, budget: week.budget, since: Self.weeklySince(snap)
            ))
        }

        for scoped in usage.scoped {
            rows.append(LimitRow(
                id: "scoped-\(scoped.modelName)", title: "本周 · \(scoped.modelName)",
                fraction: scoped.limit.fraction,
                reset: scoped.limit.resetsAt.map { .weekday($0) } ?? .none,
                isOfficial: true
            ))
        }
        for (name, limit) in [("Sonnet", usage.sevenDaySonnet), ("Opus", usage.sevenDayOpus)] {
            guard let limit, limit.utilization > 0, !usage.scoped.contains(where: { $0.modelName.hasPrefix(name) }) else { continue }
            rows.append(LimitRow(
                id: "family-\(name)", title: "本周 · \(name)",
                fraction: limit.fraction,
                reset: limit.resetsAt.map { .weekday($0) } ?? .none,
                isOfficial: true
            ))
        }
        return rows
    }

    private static func weeklySince(_ snap: UsageSnapshot) -> LimitRow.Since? {
        snap.weeklyStartSource == .scheduled ? nil : LimitRow.Since(date: snap.weeklyStart, source: snap.weeklyStartSource)
    }

    private func estimatedRows(_ snap: UsageSnapshot) -> [LimitRow] {
        let five = snap.fiveHour
        let week = snap.weekly
        let fable = snap.weeklyFamilies.first { $0.family == .fable }?.cost ?? 0
        return [
            LimitRow(
                id: "five", title: "5 小时", fraction: five.fraction,
                reset: five.isActive ? .countdown(five.end) : .idle,
                isOfficial: false, localCost: five.cost, budget: five.budget,
                burnRate: five.burnRatePerHour,
                projected: five.isActive ? five.projectedFraction(now: Date()) : nil
            ),
            LimitRow(
                id: "week", title: "本周 · 全部模型", fraction: week.fraction,
                reset: .weekday(week.end), isOfficial: false, localCost: week.cost, budget: week.budget,
                since: Self.weeklySince(snap)
            ),
            LimitRow(
                id: "fable", title: "本周 · Fable", fraction: fable / max(1, week.budget),
                reset: .none, isOfficial: false
            ),
        ]
    }
}
