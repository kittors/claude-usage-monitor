import Foundation

/// 计算所需的用户配置。
public struct UsageSettings: Sendable, Equatable {
    /// 每月扣费日（1～31，超过当月天数时取当月最后一天）
    public var billingAnchorDay: Int
    /// 扣费日当天的重置时刻（本地时区）。这一刻之前的用量仍属于上一月。
    public var billingAnchorHour: Int
    public var billingAnchorMinute: Int
    public var billingAnchorSecond: Int
    /// 每周限额的某次重置时间。本周窗口按它每 7 天对齐；还没同步过时为 nil。
    public var weeklyReset: Date?
    public var calendar: Calendar

    public init(billingAnchorDay: Int = 1, billingAnchorHour: Int = 0, billingAnchorMinute: Int = 0,
                billingAnchorSecond: Int = 0, weeklyReset: Date? = nil, calendar: Calendar = .current) {
        self.billingAnchorDay = billingAnchorDay
        self.billingAnchorHour = billingAnchorHour
        self.billingAnchorMinute = billingAnchorMinute
        self.billingAnchorSecond = billingAnchorSecond
        self.weeklyReset = weeklyReset
        self.calendar = calendar
    }
}

/// 索引的只读快照（记录已按时间排序）。
public struct IndexSnapshot: Sendable {
    public var records: [UsageRecord]
    public var models: [String]

    public init(records: [UsageRecord], models: [String]) {
        self.records = records
        self.models = models
    }
}

public extension UsageIndex {
    func makeSnapshot() -> IndexSnapshot {
        IndexSnapshot(records: records.sorted { $0.time < $1.time }, models: models)
    }
}

// MARK: - 结果模型

public struct ModelUsage: Sendable, Equatable, Identifiable {
    public var modelID: String
    public var displayName: String
    public var family: ModelFamily
    public var cost: Double
    public var tokens: TokenCounts
    public var requests: Int
    public var isEstimated: Bool
    public var id: String { modelID }
}

public struct DayUsage: Sendable, Equatable, Identifiable {
    public var date: Date
    public var cost: Double
    public var tokens: TokenCounts
    public var requests: Int
    public var id: Date { date }
}

/// 一段时间（今天、本周或本月）里的统计。
public struct PeriodUsage: Sendable, Equatable {
    public var start: Date
    /// 下一周期开始（不含）
    public var end: Date
    /// 周期内第几天（从 1 开始）
    public var dayIndex: Int
    public var dayCount: Int
    public var cost: Double
    public var tokens: TokenCounts
    public var requests: Int
    public var models: [ModelUsage]

    /// 周期最后一天（含）
    public var lastDay: Date { end.addingTimeInterval(-1) }
    /// 到今天为止的日均费用
    public var dailyAverage: Double { cost / Double(max(1, dayIndex)) }
}

/// 本机用量（Claude Code 会话日志按 API 价格折算）。限额百分比只来自官方接口，不在这里推算。
public struct UsageSnapshot: Sendable, Equatable {
    public var generatedAt: Date
    /// 本月（扣费日 + 每周限额的重置时刻）
    public var billing: PeriodUsage
    /// 今天（当地自然日）
    public var day: PeriodUsage
    /// 本周。还没有每周限额的重置时间时为 nil，不用自然周代替。
    public var week: PeriodUsage?
    /// 最近 30 天（含今天），按日期升序
    public var daily: [DayUsage]
    public var totalRecords: Int
    public var lifetimeCost: Double
    public var firstRecord: Date?
    /// 最近一条记录的时间（用来判断 Claude Code 最近有没有消耗）
    public var lastRecord: Date?

    public var today: DayUsage? { daily.last }
    public var hasData: Bool { totalRecords > 0 }
}

// MARK: - 计算

public enum UsageCalculator {
    public static func snapshot(of index: IndexSnapshot, settings: UsageSettings, now: Date = Date()) -> UsageSnapshot {
        let records = index.records
        let infos = index.models.map { PricingCatalog.info(for: $0) }
        let costs: [Double] = records.map { r in
            guard let price = infos[Int(r.model)].price else { return 0 }
            return price.cost(r.tokens, fast: r.isFast) + Double(r.webSearches) * PricingCatalog.webSearchCost
        }
        let cal = settings.calendar
        let month = billingInterval(
            now: now, anchorDay: settings.billingAnchorDay,
            hour: settings.billingAnchorHour, minute: settings.billingAnchorMinute,
            second: settings.billingAnchorSecond, calendar: cal
        )
        let today = dayInterval(now: now, calendar: cal)
        return UsageSnapshot(
            generatedAt: now,
            billing: summarize(records: records, costs: costs, infos: infos, interval: month, calendar: cal, now: now),
            day: summarize(records: records, costs: costs, infos: infos, interval: today, calendar: cal, now: now),
            week: settings.weeklyReset.map { reset in
                summarize(
                    records: records, costs: costs, infos: infos,
                    interval: weeklyInterval(now: now, reset: reset), calendar: cal, now: now
                )
            },
            daily: dailyUsage(records: records, costs: costs, calendar: cal, now: now, days: 30),
            totalRecords: records.count,
            lifetimeCost: costs.reduce(0, +),
            firstRecord: records.first.map { Date(timeIntervalSince1970: $0.time) },
            lastRecord: records.last.map { Date(timeIntervalSince1970: $0.time) }
        )
    }

    // MARK: 计费周期

    /// 周期从扣费日的重置时刻开始，到下一次重置时刻为止（不含）。
    /// 只传日期时按当地 0:00 切分。
    public static func billingInterval(
        now: Date, anchorDay: Int, hour: Int = 0, minute: Int = 0, second: Int = 0, calendar cal: Calendar
    ) -> DateInterval {
        let hour = min(max(0, hour), 23)
        let minute = min(max(0, minute), 59)
        let second = min(max(0, second), 59)
        func anchor(year: Int, month: Int) -> Date {
            let first = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
            let days = cal.range(of: .day, in: .month, for: first)?.count ?? 28
            let day = min(max(1, anchorDay), days)
            let atReset = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
            return cal.date(from: atReset)
                ?? cal.date(from: DateComponents(year: year, month: month, day: day))
                ?? first
        }
        func shift(_ year: Int, _ month: Int, by delta: Int) -> (Int, Int) {
            let m0 = year * 12 + (month - 1) + delta
            return (m0 / 12, m0 % 12 + 1)
        }
        let c = cal.dateComponents([.year, .month], from: now)
        let (y, m) = (c.year ?? 2026, c.month ?? 1)
        let thisAnchor = anchor(year: y, month: m)
        let (sy, sm) = now >= thisAnchor ? (y, m) : shift(y, m, by: -1)
        let (ey, em) = shift(sy, sm, by: 1)
        return DateInterval(start: anchor(year: sy, month: sm), end: anchor(year: ey, month: em))
    }

    /// 当地今天 0:00 到明天 0:00。
    public static func dayInterval(now: Date, calendar cal: Calendar) -> DateInterval {
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    /// 包含 `now` 的那一周。`reset` 是每周限额的某次重置（面板上的「周六 22:00」），窗口按它每 7 天重复。
    public static func weeklyInterval(now: Date, reset: Date) -> DateInterval {
        let week: TimeInterval = 7 * 86_400
        let steps = floor(now.timeIntervalSince(reset) / week)
        let start = reset.addingTimeInterval(steps * week)
        return DateInterval(start: start, end: start.addingTimeInterval(week))
    }

    static func summarize(
        records: [UsageRecord], costs: [Double], infos: [ModelInfo],
        interval: DateInterval, calendar cal: Calendar, now: Date
    ) -> PeriodUsage {
        let from = lowerBound(records, interval.start.timeIntervalSince1970)
        let to = lowerBound(records, interval.end.timeIntervalSince1970)
        var cost = 0.0
        var tokens = TokenCounts.zero
        var byModel: [UInt16: ModelUsage] = [:]
        for i in from..<to {
            let r = records[i]
            cost += costs[i]
            tokens += r.tokens
            if byModel[r.model] == nil {
                let info = infos[Int(r.model)]
                byModel[r.model] = ModelUsage(
                    modelID: info.id, displayName: info.displayName, family: info.family,
                    cost: 0, tokens: .zero, requests: 0, isEstimated: info.isEstimated || info.price == nil
                )
            }
            byModel[r.model]!.cost += costs[i]
            byModel[r.model]!.tokens += r.tokens
            byModel[r.model]!.requests += 1
        }
        // 同一显示名（如带日期后缀的 Haiku）合并
        var merged: [String: ModelUsage] = [:]
        for m in byModel.values {
            if var existing = merged[m.displayName] {
                existing.cost += m.cost
                existing.tokens += m.tokens
                existing.requests += m.requests
                merged[m.displayName] = existing
            } else {
                merged[m.displayName] = m
            }
        }
        // 按重置时刻起算的整天，而不是自然日零点：28 日 22:00 重置时，次日 21:00 仍是周期第一天
        let dayCount = max(1, cal.dateComponents([.day], from: interval.start, to: interval.end).day ?? 30)
        let dayIndex = min(dayCount, (cal.dateComponents([.day], from: interval.start, to: now).day ?? 0) + 1)
        return PeriodUsage(
            start: interval.start, end: interval.end, dayIndex: dayIndex, dayCount: max(1, dayCount),
            cost: cost, tokens: tokens, requests: to - from,
            models: merged.values.sorted { $0.cost > $1.cost }
        )
    }

    // MARK: 每日趋势

    static func dailyUsage(records: [UsageRecord], costs: [Double], calendar cal: Calendar, now: Date, days: Int) -> [DayUsage] {
        let today = cal.startOfDay(for: now)
        var bounds: [Date] = (0...days).compactMap { k in cal.date(byAdding: .day, value: k - days + 1, to: today) }
        if bounds.count != days + 1 {
            bounds = (0...days).map { today.addingTimeInterval(Double($0 - days + 1) * 86_400) }
        }
        var result = (0..<days).map { DayUsage(date: bounds[$0], cost: 0, tokens: .zero, requests: 0) }
        var day = 0
        let endT = bounds[days].timeIntervalSince1970
        for i in lowerBound(records, bounds[0].timeIntervalSince1970)..<records.count {
            let t = records[i].time
            if t >= endT { break }
            while day < days - 1, t >= bounds[day + 1].timeIntervalSince1970 { day += 1 }
            result[day].cost += costs[i]
            result[day].tokens += records[i].tokens
            result[day].requests += 1
        }
        return result
    }

    // MARK: 工具

    /// 第一个 `time >= t` 的下标
    static func lowerBound(_ records: [UsageRecord], _ t: Double) -> Int {
        var lo = 0, hi = records.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if records[mid].time < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// 周期范围。午夜切分时只写日期；有具体时刻时写到分钟，结束为下一次重置的前一分钟。
    public static func periodTitle(start: Date, end: Date, calendar cal: Calendar) -> String {
        let parts = cal.dateComponents([.hour, .minute, .second], from: start)
        let midnight = (parts.hour ?? 0) == 0 && (parts.minute ?? 0) == 0 && (parts.second ?? 0) == 0
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = midnight ? "M月d日" : "M月d日 HH:mm"
        return "\(f.string(from: start)) – \(f.string(from: end.addingTimeInterval(-1)))"
    }

    /// 闭区间，精确到秒：开始时刻，以及下一周期开始前的最后一秒。
    public static func periodRange(start: Date, end: Date, calendar cal: Calendar, locale: Locale = Locale(identifier: "zh_CN")) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = locale
        let chinese = locale.language.languageCode?.identifier == "zh"
        f.dateFormat = chinese ? "M月d日 HH:mm:ss" : "MMM d, HH:mm:ss"
        return "\(f.string(from: start)) – \(f.string(from: end.addingTimeInterval(-1)))"
    }
}
