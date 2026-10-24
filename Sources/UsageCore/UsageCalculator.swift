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
    /// 进行中的 5 小时窗口的重置时间，窗口是它之前的 5 小时。没有进行中的窗口时为 nil。
    public var fiveHourReset: Date?
    /// 上次同步时官方的每周限额（全部模型），用来折算额度用满时的金额。没有官方数据时为 nil。
    public var weeklyReading: WeeklyReading?
    /// 之前某一周算准的比例。本周的百分比还太小时借用它
    public var earlierAllowance: AllowanceBasis?
    public var calendar: Calendar

    public init(billingAnchorDay: Int = 1, billingAnchorHour: Int = 0, billingAnchorMinute: Int = 0,
                billingAnchorSecond: Int = 0, weeklyReset: Date? = nil, fiveHourReset: Date? = nil,
                weeklyReading: WeeklyReading? = nil, earlierAllowance: AllowanceBasis? = nil, calendar: Calendar = .current) {
        self.billingAnchorDay = billingAnchorDay
        self.billingAnchorHour = billingAnchorHour
        self.billingAnchorMinute = billingAnchorMinute
        self.billingAnchorSecond = billingAnchorSecond
        self.weeklyReset = weeklyReset
        self.fiveHourReset = fiveHourReset
        self.weeklyReading = weeklyReading
        self.earlierAllowance = earlierAllowance
        self.calendar = calendar
    }
}

/// 官方每周限额某次同步的读数
public struct WeeklyReading: Sendable, Equatable {
    /// 已用百分比（0～100，可能超过 100）
    public var utilization: Double
    /// 取到这个百分比的时间
    public var at: Date

    public init(utilization: Double, at: Date) {
        self.utilization = utilization
        self.at = at
    }
}

/// 折算额度用的一次同步：那一刻那一周的本机消耗对应官方的百分比
public struct AllowanceBasis: Sendable, Equatable, Codable {
    /// 官方百分比（0～100）
    public var utilization: Double
    /// 同步那一刻，那一周的本机消耗
    public var syncedCost: Double
    public var at: Date

    public init(utilization: Double, syncedCost: Double, at: Date) {
        self.utilization = utilization
        self.syncedCost = syncedCost
        self.at = at
    }

    /// 额度用满时那一周的本机消耗
    public var full: Double { syncedCost * 100 / utilization }
}

/// 每周限额折算成本机消耗：同步那一刻，本周的本机消耗对应官方的百分比，照这个比例，本机花到多少时额度用满。
/// 官方百分比里还有其他设备和网页上的用量，按同样的比例继续，算出来的就是本机能花到哪里。
/// 只用来算预计，限额区显示的百分比仍然只来自官方。
public struct WeeklyAllowance: Sendable, Equatable {
    /// 官方百分比只有整数，太小时一个百分点的误差就很大：低于它时先借用之前算准的比例
    public static let minimumUtilization = 10.0

    /// 本周窗口
    public var start: Date
    public var end: Date
    /// 同步时官方的百分比（0～100），和那一刻本周的本机消耗
    public var utilization: Double
    public var syncedCost: Double
    /// 本周到现在的本机消耗
    public var spent: Double
    /// 折算用的那次同步
    public var syncedAt: Date?
    /// 本周的百分比还太小，借用的是之前一周的比例
    public var borrowed = false

    /// 额度用满时本周的本机消耗
    public var full: Double { syncedCost * 100 / utilization }
    /// 本周还能花多少
    public var remaining: Double { max(0, full - spent) }

    /// 从 t 到 end 每周都用满还能花多少：本周还剩的额度按落在这一段里的时间折算，之后每周一整份，最后不满一周的按时间折算
    func ahead(from t: Date, to end: Date) -> Double {
        var segment = max(t, start)
        var weekEnd = self.end
        var left = remaining
        while weekEnd <= segment {
            weekEnd = weekEnd.addingTimeInterval(LimitPace.weekWindow)
            left = full
        }
        var total = 0.0
        while segment < end {
            let span = weekEnd.timeIntervalSince(segment)
            total += left * min(weekEnd, end).timeIntervalSince(segment) / span
            segment = weekEnd
            weekEnd = weekEnd.addingTimeInterval(LimitPace.weekWindow)
            left = full
        }
        return total
    }
}

/// 预计：本周、本月是额度用满时一共多少；今天是照今天的速度到今天结束一共多少
public struct Projection: Sendable, Equatable {
    public var cost: Double
    /// 只有今天会有：照今天的速度，本周额度在今天用完的时刻。用完之后到下次重置不再增加；额度够用时为 nil。
    public var runsOut: Date?

    public init(cost: Double, runsOut: Date? = nil) {
        self.cost = cost
        self.runsOut = runsOut
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

/// 按计费类别拆开的费用（美元）。逐次请求用它自己的单价累加，和总额用的是同一套价格；
/// 各项相加等于总额，但不含快速模式倍率和联网搜索费。
public struct CategoryCosts: Sendable, Equatable {
    public var input = 0.0
    public var output = 0.0
    public var cacheWrite = 0.0
    public var cacheRead = 0.0
    /// 缓存读取省下的钱：按原价输入计算，比缓存读取价多出来的部分
    public var savings = 0.0

    mutating func add(_ t: TokenCounts, price: ModelPrice) {
        let p = price.tier(for: t)
        input += Double(t.input) * p.input / 1e6
        output += Double(t.output) * p.output / 1e6
        cacheWrite += (Double(t.cacheWrite5m) * p.cacheWrite5m + Double(t.cacheWrite1h) * p.cacheWrite1h) / 1e6
        cacheRead += Double(t.cacheRead) * p.cacheRead / 1e6
        savings += Double(t.cacheRead) * (p.input - p.cacheRead) / 1e6
    }
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
    /// 按计费类别拆开的费用，和 `cost` 用同一套单价
    public var categories = CategoryCosts()

    /// 周期最后一天（含）
    public var lastDay: Date { end.addingTimeInterval(-1) }

    /// 到现在为止的日均费用：按实际过去的时间算，不足一天按一天算（刚开始时几分钟的消耗不会被放大）
    public func dailyAverage(now: Date) -> Double {
        cost / (elapsed(now: now, atLeast: 86_400) / 86_400)
    }

    /// 照现在的速度，整个周期一共会用多少。多天的周期就是日均 × 天数，和面板上的日均对得上；
    /// 只有一天时按小时外推，开头不足 6 小时按 6 小时算。
    public func projectedCost(now: Date) -> Double {
        guard dayCount == 1 else { return dailyAverage(now: now) * Double(dayCount) }
        let length = end.timeIntervalSince(start)
        return cost * length / elapsed(now: now, atLeast: Self.shortestDay)
    }

    /// 预计。本周是额度用满（100%）时一共多少，不管用得快慢，已经花得更多时就是实际花的；
    /// 本月是已经花的，加上之后每周都用满。没有额度读数时这两个都没有预计。
    /// 今天没有单独的额度：照今天的速度按小时外推，本周额度用完就停到下次重置。
    public func projection(now: Date, allowance: WeeklyAllowance?) -> Projection? {
        if dayCount == 1 { return paced(now: now, allowance: allowance) }
        guard let a = allowance else { return nil }
        if start == a.start, end == a.end { return Projection(cost: max(cost, a.full)) }
        return Projection(cost: cost + a.ahead(from: now, to: end))
    }

    /// 照现在的速度到周期结束，并且每周额度用完就停到下次重置。
    /// 从现在起按周切开：本周最多再花掉还剩的额度，之后每一周最多一整份。额度够用时就是 `projectedCost(now:)`。
    func paced(now: Date, allowance: WeeklyAllowance?) -> Projection {
        let linear = projectedCost(now: now)
        let elapsed = elapsed(now: now, atLeast: dayCount == 1 ? Self.shortestDay : 86_400)
        guard let a = allowance, cost > 0, elapsed < end.timeIntervalSince(start) else { return Projection(cost: linear) }
        // 和日均、按小时外推用同一个速度：开头不足一天（或 6 小时）时也按那么久算
        let rate = cost / elapsed
        var t = start.addingTimeInterval(elapsed)
        var weekEnd = a.end
        var left = a.remaining
        while weekEnd <= t {
            weekEnd = weekEnd.addingTimeInterval(LimitPace.weekWindow)
            left = a.full
        }
        var total = cost
        var runsOut: Date?
        while t < end {
            let segmentEnd = min(weekEnd, end)
            let wanted = rate * segmentEnd.timeIntervalSince(t)
            if wanted > left {
                if runsOut == nil { runsOut = t.addingTimeInterval(left / rate) }
                total += left
            } else {
                total += wanted
            }
            t = segmentEnd
            weekEnd = weekEnd.addingTimeInterval(LimitPace.weekWindow)
            left = a.full
        }
        guard let runsOut, total < linear else { return Projection(cost: linear) }
        return Projection(cost: total, runsOut: runsOut)
    }

    /// 只有一天的周期，开头不足 6 小时按 6 小时算
    private static let shortestDay: TimeInterval = 6 * 3600

    /// 周期已经过去的时间，至少按 `minimum` 算，最多到周期结束
    private func elapsed(now: Date, atLeast minimum: TimeInterval) -> TimeInterval {
        let length = max(1, end.timeIntervalSince(start))
        return min(length, max(min(minimum, length), now.timeIntervalSince(start)))
    }
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
    /// 每周限额折算成本机消耗：本周、本月的预计按额度用满算。没有官方读数、也没有之前算准的比例时为 nil。
    public var weeklyAllowance: WeeklyAllowance?
    /// 进行中的 5 小时窗口里的本机消耗。没有进行中的窗口时为 nil。
    public var fiveHourCost: Double?
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
    /// 5 小时限额窗口的长度
    public static let fiveHourWindow: TimeInterval = 5 * 3600

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
        let week = settings.weeklyReset.map { reset in
            summarize(
                records: records, costs: costs, infos: infos,
                interval: weeklyInterval(now: now, reset: reset), calendar: cal, now: now
            )
        }
        return UsageSnapshot(
            generatedAt: now,
            billing: summarize(records: records, costs: costs, infos: infos, interval: month, calendar: cal, now: now),
            day: summarize(records: records, costs: costs, infos: infos, interval: today, calendar: cal, now: now),
            week: week,
            weeklyAllowance: week.flatMap { allowance(records: records, costs: costs, week: $0, reading: settings.weeklyReading, earlier: settings.earlierAllowance) },
            fiveHourCost: settings.fiveHourReset.map { reset in
                let from = lowerBound(records, reset.timeIntervalSince1970 - fiveHourWindow)
                let to = lowerBound(records, reset.timeIntervalSince1970)
                return costs[from..<max(from, to)].reduce(0, +)
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

    /// 本周的官方读数折算成本机消耗。读数必须是这一周里取到的：重置之后、还没同步时，上一周的百分比不算。
    /// 本机消耗按读数那一刻之前的记录算，和百分比是同一时刻，之后新增的消耗不会让额度看起来变大。
    /// 本周的百分比还不到 10%（或还没同步过）时，借用之前算准的比例；没有的话先用本周的，用得越多越准
    static func allowance(records: [UsageRecord], costs: [Double], week: PeriodUsage, reading: WeeklyReading?, earlier: AllowanceBasis?) -> WeeklyAllowance? {
        var current: WeeklyAllowance?
        if let r = reading, r.utilization.isFinite, r.utilization > 0, r.at >= week.start, r.at < week.end {
            let from = lowerBound(records, week.start.timeIntervalSince1970)
            let to = lowerBound(records, r.at.timeIntervalSince1970)
            let synced = costs[from..<max(from, to)].reduce(0, +)
            if synced > 0 {
                current = WeeklyAllowance(start: week.start, end: week.end, utilization: r.utilization, syncedCost: synced, spent: week.cost, syncedAt: r.at)
            }
        }
        if let current, current.utilization >= WeeklyAllowance.minimumUtilization { return current }
        if let e = earlier, e.utilization >= WeeklyAllowance.minimumUtilization, e.utilization.isFinite, e.syncedCost > 0 {
            return WeeklyAllowance(
                start: week.start, end: week.end, utilization: e.utilization, syncedCost: e.syncedCost, spent: week.cost,
                syncedAt: e.at, borrowed: true
            )
        }
        return current
    }

    static func summarize(
        records: [UsageRecord], costs: [Double], infos: [ModelInfo],
        interval: DateInterval, calendar cal: Calendar, now: Date
    ) -> PeriodUsage {
        let from = lowerBound(records, interval.start.timeIntervalSince1970)
        let to = lowerBound(records, interval.end.timeIntervalSince1970)
        var cost = 0.0
        var tokens = TokenCounts.zero
        var categories = CategoryCosts()
        var byModel: [UInt16: ModelUsage] = [:]
        for i in from..<to {
            let r = records[i]
            cost += costs[i]
            tokens += r.tokens
            if let price = infos[Int(r.model)].price { categories.add(r.tokens, price: price) }
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
            models: merged.values.sorted { $0.cost > $1.cost }, categories: categories
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
        let f = DateFormats.formatter(midnight ? "M月d日" : "M月d日 HH:mm", locale: Locale(identifier: "zh_CN"), timeZone: cal.timeZone, calendar: cal)
        return "\(f.string(from: start)) – \(f.string(from: end.addingTimeInterval(-1)))"
    }

    /// 闭区间，精确到秒：开始时刻，以及下一周期开始前的最后一秒。
    public static func periodRange(start: Date, end: Date, calendar cal: Calendar, locale: Locale = Locale(identifier: "zh_CN")) -> String {
        let chinese = locale.language.languageCode?.identifier == "zh"
        let f = DateFormats.formatter(chinese ? "M月d日 HH:mm:ss" : "MMM d, HH:mm:ss", locale: locale, timeZone: cal.timeZone, calendar: cal)
        return "\(f.string(from: start)) – \(f.string(from: end.addingTimeInterval(-1)))"
    }
}
