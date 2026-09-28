import Foundation

/// 计算所需的用户配置。
public struct UsageSettings: Sendable, Equatable {
    /// 每月扣费日（1～31，超过当月天数时取当月最后一天）
    public var billingAnchorDay: Int
    /// 每周限额重置：星期（`Calendar` 约定，1 = 周日 … 7 = 周六）
    public var weeklyResetWeekday: Int
    public var weeklyResetHour: Int
    public var weeklyResetMinute: Int
    /// 5 小时窗口的预算（API 等价美元）
    public var fiveHourBudget: Double
    /// 每周预算（API 等价美元）
    public var weeklyBudget: Double
    public var calendar: Calendar
    /// 官方给出的 5 小时窗口（有官方数据时覆盖本地推算的窗口）
    public var fiveHourWindow: DateInterval?
    /// 官方给出的每周窗口（固定周期）
    public var weeklyWindow: DateInterval?
    /// 本周期内官方每周百分比的观测记录（用于推算中途重置）
    public var weeklyObservations: [WindowObservation]
    /// 已检测到的中途重置时刻（观测到百分比下降）
    public var weeklyResetFloor: Date?
    /// 手动指定的本周起算时间（优先级最高）
    public var weeklyStartOverride: Date?
    /// 最近一次成功获取官方用量的时间：之后的本机用量用于推算两次同步之间的变化
    public var officialSyncedAt: Date?

    public init(
        billingAnchorDay: Int = 1,
        weeklyResetWeekday: Int = 7,
        weeklyResetHour: Int = 22,
        weeklyResetMinute: Int = 0,
        fiveHourBudget: Double = 400,
        weeklyBudget: Double = 4000,
        calendar: Calendar = .current,
        fiveHourWindow: DateInterval? = nil,
        weeklyWindow: DateInterval? = nil,
        weeklyObservations: [WindowObservation] = [],
        weeklyResetFloor: Date? = nil,
        weeklyStartOverride: Date? = nil,
        officialSyncedAt: Date? = nil
    ) {
        self.billingAnchorDay = billingAnchorDay
        self.weeklyResetWeekday = weeklyResetWeekday
        self.weeklyResetHour = weeklyResetHour
        self.weeklyResetMinute = weeklyResetMinute
        self.fiveHourBudget = fiveHourBudget
        self.weeklyBudget = weeklyBudget
        self.calendar = calendar
        self.fiveHourWindow = fiveHourWindow
        self.weeklyWindow = weeklyWindow
        self.weeklyObservations = weeklyObservations
        self.weeklyResetFloor = weeklyResetFloor
        self.weeklyStartOverride = weeklyStartOverride
        self.officialSyncedAt = officialSyncedAt
    }
}

/// 一次官方用量观测
public struct WindowObservation: Codable, Sendable, Equatable {
    public var time: Double
    /// 百分比（0～100）
    public var utilization: Double

    public init(time: Double, utilization: Double) {
        self.time = time
        self.utilization = utilization
    }
}

/// 本周用量从何时起算
public enum WeeklyStartSource: Sendable, Equatable {
    /// 固定周期（上次例行重置）
    case scheduled
    /// 观测到百分比下降，检测到中途重置
    case detected
    /// 根据本机费用与官方百分比的变化推算出中途重置
    case inferred
    /// 用户手动指定
    case manual
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

/// 一个限额窗口（5 小时 / 每周）的用量。
public struct WindowUsage: Sendable, Equatable {
    public var start: Date
    /// 重置时间
    public var end: Date
    public var cost: Double
    public var tokens: TokenCounts
    public var requests: Int
    public var budget: Double
    /// 5 小时窗口：当前是否处于活动的会话块中
    public var isActive: Bool
    /// 最近 60 分钟的消耗速率（美元 / 小时）
    public var burnRatePerHour: Double
    /// 窗口内的消耗分布（用于迷你柱状图）
    public var bins: [Double]

    public var fraction: Double { budget > 0 ? cost / budget : 0 }
    /// 以当前速率持续到重置时的预计占比
    public func projectedFraction(now: Date) -> Double {
        guard budget > 0, isActive else { return fraction }
        let remaining = max(0, end.timeIntervalSince(now)) / 3600
        return (cost + burnRatePerHour * remaining) / budget
    }
}

public struct FamilyUsage: Sendable, Equatable, Identifiable {
    public var family: ModelFamily
    public var cost: Double
    public var tokens: TokenCounts
    public var requests: Int
    public var id: ModelFamily { family }
}

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

/// 订阅计费周期（月度）的统计。
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
    /// 时间进度 0～1
    public func elapsedFraction(now: Date) -> Double {
        let total = end.timeIntervalSince(start)
        return total > 0 ? min(1, max(0, now.timeIntervalSince(start) / total)) : 0
    }
    /// 按当前节奏推算的整期费用
    public func projectedCost(now: Date) -> Double {
        let f = elapsedFraction(now: now)
        return f > 0.02 ? cost / f : cost
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public var generatedAt: Date
    public var fiveHour: WindowUsage
    public var weekly: WindowUsage
    public var weeklyFamilies: [FamilyUsage]
    public var billing: PeriodUsage
    /// 最近 30 天（含今天），按日期升序
    public var daily: [DayUsage]
    /// 历史 5 小时块费用的分位数（用于校准建议）
    public var blockP90: Double
    public var blockMax: Double
    public var totalRecords: Int
    public var lifetimeCost: Double
    public var firstRecord: Date?
    /// 本周期的起点（上次例行重置）
    public var weeklyCycleStart: Date
    /// 本周用量的实际起算时间与来源（可能因中途重置晚于固定周期起点）
    public var weeklyStart: Date
    public var weeklyStartSource: WeeklyStartSource
    /// 由观测差分推算出的真实周预算（API 等价美元）
    public var weeklyInferredBudget: Double?
    /// 最近一次官方同步之后的本机费用（按记录时间统计）
    public var costSinceSync: Double

    public var today: DayUsage? { daily.last }
    public var hasData: Bool { totalRecords > 0 }
}

// MARK: - 计算

public enum UsageCalculator {
    public static let fiveHours: TimeInterval = 5 * 3600

    public static func snapshot(of index: IndexSnapshot, settings: UsageSettings, now: Date = Date()) -> UsageSnapshot {
        let records = index.records
        let infos = index.models.map { PricingCatalog.info(for: $0) }
        let costs: [Double] = records.map { r in
            guard let price = infos[Int(r.model)].price else { return 0 }
            return price.cost(r.tokens, fast: r.isFast) + Double(r.webSearches) * PricingCatalog.webSearchCost
        }
        let nowT = now.timeIntervalSince1970

        let fiveHour = fiveHourWindow(records: records, costs: costs, budget: settings.fiveHourBudget, now: nowT, official: settings.fiveHourWindow)
        let weekStart = weeklyStart(records: records, costs: costs, settings: settings, now: now)
        let (weekly, families) = weeklyWindow(records: records, costs: costs, infos: infos, settings: settings, now: now, start: weekStart.start)
        let billing = billingPeriod(records: records, costs: costs, infos: infos, settings: settings, now: now)
        let daily = dailyUsage(records: records, costs: costs, calendar: settings.calendar, now: now, days: 30)
        let blocks = blockCosts(records: records, costs: costs)

        return UsageSnapshot(
            generatedAt: now,
            fiveHour: fiveHour,
            weekly: weekly,
            weeklyFamilies: families,
            billing: billing,
            daily: daily,
            blockP90: percentile(blocks, 0.9),
            blockMax: blocks.max() ?? 0,
            totalRecords: records.count,
            lifetimeCost: costs.reduce(0, +),
            firstRecord: records.first.map { Date(timeIntervalSince1970: $0.time) },
            weeklyCycleStart: (settings.weeklyWindow ?? weeklyInterval(now: now, settings: settings)).start,
            weeklyStart: weekStart.start,
            weeklyStartSource: weekStart.source,
            weeklyInferredBudget: weekStart.budget,
            costSinceSync: settings.officialSyncedAt.map { t in
                costs[lowerBound(records, t.timeIntervalSince1970)...].reduce(0, +)
            } ?? 0
        )
    }

    // MARK: 5 小时窗口

    /// 与 Claude 的限额窗口规则一致：窗口从首条消息的时刻开始，持续 5 小时；
    /// 窗口结束后的下一条消息开启新窗口。（已用官方 `/usage` 的重置时间验证，
    /// 窗口起点是精确时刻而不是向下取整的整点。）
    static func fiveHourWindow(records: [UsageRecord], costs: [Double], budget: Double, now: Double, official: DateInterval? = nil) -> WindowUsage {
        let binCount = 20
        let start: Double, firstIndex: Int, active: Bool
        if let official {
            // 官方窗口：直接按官方的起止时间统计本机用量
            start = official.end.timeIntervalSince1970 - fiveHours
            firstIndex = lowerBound(records, start)
            active = now < official.end.timeIntervalSince1970
        } else if let block = activeBlock(records: records, now: now) {
            start = block.start
            firstIndex = block.firstIndex
            active = true
        } else {
            return WindowUsage(
                start: Date(timeIntervalSince1970: now), end: Date(timeIntervalSince1970: now + fiveHours),
                cost: 0, tokens: .zero, requests: 0, budget: budget, isActive: false, burnRatePerHour: 0,
                bins: Array(repeating: 0, count: binCount)
            )
        }
        var cost = 0.0
        var tokens = TokenCounts.zero
        var recent = 0.0
        var requests = 0
        var bins = Array(repeating: 0.0, count: binCount)
        let binWidth = fiveHours / Double(binCount)
        for i in firstIndex..<records.count where records[i].time <= now + 60 {
            let r = records[i]
            cost += costs[i]
            tokens += r.tokens
            requests += 1
            if r.time >= now - 3600 { recent += costs[i] }
            let b = Int((r.time - start) / binWidth)
            bins[min(binCount - 1, max(0, b))] += costs[i]
        }
        return WindowUsage(
            start: Date(timeIntervalSince1970: start),
            end: Date(timeIntervalSince1970: start + fiveHours),
            cost: cost, tokens: tokens, requests: requests, budget: budget,
            isActive: active, burnRatePerHour: recent, bins: bins
        )
    }

    static func activeBlock(records: [UsageRecord], now: Double) -> (start: Double, firstIndex: Int)? {
        guard let last = records.last, now - last.time < fiveHours, now >= records[0].time else { return nil }
        // 回溯到最近一次 ≥ 5 小时的空闲间隔，之后的活动才可能属于当前块
        var i = records.count - 1
        while i > 0, records[i].time - records[i - 1].time < fiveHours { i -= 1 }
        var start = records[i].time
        var first = i
        for j in i..<records.count where records[j].time >= start + fiveHours {
            start = records[j].time
            first = j
        }
        guard now < start + fiveHours else { return nil }
        return (start, first)
    }

    /// 历史上每个 5 小时块的费用
    static func blockCosts(records: [UsageRecord], costs: [Double]) -> [Double] {
        var result: [Double] = []
        var start = -Double.infinity
        var acc = 0.0
        for (i, r) in records.enumerated() {
            if r.time >= start + fiveHours {
                if start.isFinite { result.append(acc) }
                start = r.time
                acc = 0
            }
            acc += costs[i]
        }
        if start.isFinite { result.append(acc) }
        return result
    }

    // MARK: 每周窗口

    public static func weeklyInterval(now: Date, settings: UsageSettings) -> DateInterval {
        let cal = settings.calendar
        var comps = DateComponents()
        comps.weekday = settings.weeklyResetWeekday
        comps.hour = settings.weeklyResetHour
        comps.minute = settings.weeklyResetMinute
        comps.second = 0
        let next = cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            ?? now.addingTimeInterval(7 * 86_400)
        let start = cal.date(byAdding: .day, value: -7, to: next) ?? next.addingTimeInterval(-7 * 86_400)
        return DateInterval(start: start, end: next)
    }

    static func weeklyWindow(
        records: [UsageRecord], costs: [Double], infos: [ModelInfo], settings: UsageSettings, now: Date, start: Date? = nil
    ) -> (WindowUsage, [FamilyUsage]) {
        let scheduled = settings.weeklyWindow ?? weeklyInterval(now: now, settings: settings)
        let interval = DateInterval(start: min(max(start ?? scheduled.start, scheduled.start), now), end: scheduled.end)
        let from = lowerBound(records, interval.start.timeIntervalSince1970)
        var cost = 0.0, recent = 0.0
        var tokens = TokenCounts.zero
        var bins = Array(repeating: 0.0, count: 7)
        var families: [ModelFamily: FamilyUsage] = [:]
        let nowT = now.timeIntervalSince1970
        let startT = interval.start.timeIntervalSince1970
        for i in from..<records.count {
            let r = records[i]
            cost += costs[i]
            tokens += r.tokens
            if r.time >= nowT - 3600 { recent += costs[i] }
            bins[min(6, max(0, Int((r.time - startT) / 86_400)))] += costs[i]
            let family = infos[Int(r.model)].family
            families[family, default: FamilyUsage(family: family, cost: 0, tokens: .zero, requests: 0)].cost += costs[i]
            families[family]!.tokens += r.tokens
            families[family]!.requests += 1
        }
        let window = WindowUsage(
            start: interval.start, end: interval.end, cost: cost, tokens: tokens, requests: records.count - from,
            budget: settings.weeklyBudget, isActive: cost > 0, burnRatePerHour: recent, bins: bins
        )
        return (window, families.values.sorted { $0.cost > $1.cost })
    }

    // MARK: 中途重置

    /// 本周用量的实际起算时间：取固定周期起点、检测到的中途重置、手动指定三者中最晚的一个；
    /// 如果本机费用与官方百分比的变化表明之后还有一次没被检测到的重置，改用推算结果（手动指定时不覆盖）。
    static func weeklyStart(
        records: [UsageRecord], costs: [Double], settings: UsageSettings, now: Date
    ) -> (start: Date, source: WeeklyStartSource, budget: Double?) {
        let scheduled = (settings.weeklyWindow ?? weeklyInterval(now: now, settings: settings)).start
        func valid(_ date: Date?) -> Date? { date.flatMap { $0 > scheduled && $0 < now ? $0 : nil } }
        var start = scheduled
        var source = WeeklyStartSource.scheduled
        if let floor = valid(settings.weeklyResetFloor) {
            start = floor
            source = .detected
        }
        if let manual = valid(settings.weeklyStartOverride), manual >= start {
            start = manual
            source = .manual
        }
        let inference = inferResetStart(
            records: records, costs: costs, windowStart: start.timeIntervalSince1970, observations: settings.weeklyObservations
        )
        if source != .manual, let inference, inference.start > start.timeIntervalSince1970 + 60 {
            return (Date(timeIntervalSince1970: inference.start), .inferred, inference.budget)
        }
        return (start, source, inference?.budget)
    }

    /// 差分推算：在同一周期内，官方百分比 u 与本机累计费用 C 近似满足 u = (C − C₀) / B。
    /// 对多次观测做最小二乘，得到真实预算 B，以及未被计入（中途重置之前）的费用 C₀；
    /// 再在时间轴上找到累计费用达到 C₀ 的时刻，即为重置发生的时间。
    /// 只依赖增量，因此不受中途重置影响。
    public static func inferResetStart(
        records: [UsageRecord], costs: [Double], windowStart: Double, observations: [WindowObservation]
    ) -> (start: Double, budget: Double)? {
        let obs = observations.filter { $0.time > windowStart }.sorted { $0.time < $1.time }
        guard obs.count >= 3,
              let uMin = obs.map(\.utilization).min(), let uMax = obs.map(\.utilization).max(),
              uMax - uMin >= 5
        else { return nil }

        // 自 windowStart 起的累计费用（记录已按时间排序）
        let from = lowerBound(records, windowStart)
        var times: [Double] = []
        var prefix: [Double] = []
        var acc = 0.0
        times.reserveCapacity(records.count - from)
        prefix.reserveCapacity(records.count - from)
        for i in from..<records.count {
            acc += costs[i]
            times.append(records[i].time)
            prefix.append(acc)
        }
        func cumulative(at t: Double) -> Double {
            var lo = 0, hi = times.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if times[mid] <= t { lo = mid + 1 } else { hi = mid }
            }
            return lo == 0 ? 0 : prefix[lo - 1]
        }

        let xs = obs.map { cumulative(at: $0.time) }
        let ys = obs.map { $0.utilization / 100 }
        let n = Double(xs.count)
        let sx = xs.reduce(0, +), sy = ys.reduce(0, +)
        let sxx = xs.reduce(0) { $0 + $1 * $1 }
        let sxy = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let denominator = n * sxx - sx * sx
        guard denominator > 0 else { return nil }
        let slope = (n * sxy - sx * sy) / denominator
        let intercept = (sy - slope * sx) / n
        guard slope > 0 else { return nil }
        let budget = 1 / slope
        let uncounted = -intercept / slope

        // 官方百分比是整数，正常情况下每个点离拟合直线不超过 1～2 个百分点；
        // 偏差更大说明数据混入了其他来源（例如其他设备的用量、未识别的重置），不下结论
        let residuals = zip(xs, ys).map { $0.1 - (slope * $0.0 + intercept) }
        let mean = sy / n
        let total = ys.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let residual = residuals.reduce(0) { $0 + $1 * $1 }
        guard residuals.allSatisfy({ abs($0) <= 0.025 }), total > 0, 1 - residual / total >= 0.9 else { return nil }
        // 未计入的费用很少：视为没有中途重置
        guard uncounted > 0.03 * budget else { return (windowStart, budget) }
        // 重置必须发生在第一次观测之前
        guard uncounted < xs[0], let index = prefix.firstIndex(where: { $0 >= uncounted }) else { return nil }
        return (times[index], budget)
    }

    // MARK: 计费周期

    public static func billingInterval(now: Date, anchorDay: Int, calendar cal: Calendar) -> DateInterval {
        func anchor(year: Int, month: Int) -> Date {
            let first = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
            let days = cal.range(of: .day, in: .month, for: first)?.count ?? 28
            return cal.date(from: DateComponents(year: year, month: month, day: min(max(1, anchorDay), days))) ?? first
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

    static func billingPeriod(
        records: [UsageRecord], costs: [Double], infos: [ModelInfo], settings: UsageSettings, now: Date
    ) -> PeriodUsage {
        let cal = settings.calendar
        let interval = billingInterval(now: now, anchorDay: settings.billingAnchorDay, calendar: cal)
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
        let startDay = cal.startOfDay(for: interval.start)
        let dayIndex = (cal.dateComponents([.day], from: startDay, to: cal.startOfDay(for: now)).day ?? 0) + 1
        let dayCount = cal.dateComponents([.day], from: startDay, to: cal.startOfDay(for: interval.end)).day ?? 30
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

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
}
