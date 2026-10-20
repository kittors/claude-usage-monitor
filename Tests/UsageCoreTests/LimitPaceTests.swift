import Foundation
import Testing
@testable import UsageCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func after(_ hours: Double, _ minutes: Double = 0, _ seconds: Double = 0) -> Date {
    now.addingTimeInterval(hours * 3600 + minutes * 60 + seconds)
}

// MARK: - 安全线

@Test func fiveHourLineFollowsElapsedTime() {
    // 还剩 2:47:00 重置：已经过去 2 小时 13 分
    let line = LimitPace.fiveHour(resetsAt: after(2, 47), now: now)
    #expect(line != nil)
    #expect(abs((line?.fraction ?? 0) - 133.0 / 300) < 1e-9)
    #expect(line?.day == nil)
    #expect(line?.settling == false)
    #expect(line?.isExceeded(by: 0.12) == false)
    #expect(line?.isExceeded(by: 0.45) == true)

    // 窗口开头 30 分钟先不提示超线
    let early = LimitPace.fiveHour(resetsAt: after(4, 50), now: now)
    #expect(early?.settling == true)
    #expect(early?.isExceeded(by: 0.5) == false)
    #expect(LimitPace.fiveHour(resetsAt: after(4, 30), now: now)?.settling == false)
}

@Test func fiveHourLineNeedsAnActiveWindow() {
    #expect(LimitPace.fiveHour(resetsAt: nil, now: now) == nil)
    // 已经到了重置时间
    #expect(LimitPace.fiveHour(resetsAt: now, now: now) == nil)
    #expect(LimitPace.fiveHour(resetsAt: after(-1), now: now) == nil)
    // 重置时间比窗口还远：窗口还没开始
    #expect(LimitPace.fiveHour(resetsAt: after(5, 0, 1), now: now) == nil)
    // 刚开始
    #expect(LimitPace.fiveHour(resetsAt: after(5), now: now)?.fraction == 0)
}

@Test func weeklyLineStepsByDay() {
    // 还剩 5 天 05:56:59：已经过去 1 天 18 小时多，是第 2 天，安全线 2/7
    let line = LimitPace.weekly(resetsAt: after(5 * 24 + 5, 56, 59), now: now)
    #expect(line?.day == 2)
    #expect(abs((line?.fraction ?? 0) - 2.0 / 7) < 1e-9)
    #expect(line?.settling == false)
    #expect(line?.isExceeded(by: 0.24) == false)
    #expect(line?.isExceeded(by: 0.30) == true)

    // 第一天就有 1/7；整 48 小时进入第 3 天；最后一刻仍是第 7 天
    #expect(LimitPace.weekly(resetsAt: after(7 * 24), now: now)?.day == 1)
    #expect(LimitPace.weekly(resetsAt: after(7 * 24), now: now)?.fraction == 1.0 / 7)
    #expect(LimitPace.weekly(resetsAt: after(5 * 24), now: now)?.day == 3)
    #expect(LimitPace.weekly(resetsAt: after(5 * 24, 0, 1), now: now)?.day == 2)
    #expect(LimitPace.weekly(resetsAt: after(0, 0, 1), now: now)?.day == 7)
    #expect(LimitPace.weekly(resetsAt: after(0, 0, 1), now: now)?.fraction == 1)

    #expect(LimitPace.weekly(resetsAt: nil, now: now) == nil)
    #expect(LimitPace.weekly(resetsAt: now, now: now) == nil)
    #expect(LimitPace.weekly(resetsAt: after(7 * 24, 0, 1), now: now) == nil)
}

// MARK: - 按比例分配

@Test func apportionAddsUpExactly() {
    // 截图里的 Opus 与 Haiku：四舍五入成 100% 和 0.2% 会多出 0.2%
    #expect(Apportion.largestRemainder([761.62, 1.55], total: 1000) == [998, 2])
    #expect(Apportion.largestRemainder([1, 1, 1], total: 100) == [34, 33, 33])
    #expect(Apportion.largestRemainder([2, 1], total: 3) == [2, 1])
    #expect(Apportion.largestRemainder([0, 5], total: 10) == [0, 10])
    #expect(Apportion.largestRemainder([0, 0], total: 10) == [0, 0])
    #expect(Apportion.largestRemainder([], total: 10) == [])
    #expect(Apportion.largestRemainder([3, -1, .nan], total: 10) == [10, 0, 0])
    for weights in [[0.3, 0.3, 0.4], [9.99, 0.004, 0.006], [1e6, 1, 1, 1]] {
        #expect(Apportion.largestRemainder(weights, total: 1000).reduce(0, +) == 1000)
    }
}

@Test func sharesUseOnePrecision() {
    #expect(Fmt.shares([761.62, 1.55]) == ["99.8%", "0.2%"])
    #expect(Fmt.shares([60, 40]) == ["60%", "40%"])
    #expect(Fmt.shares([5]) == ["100%"])
    #expect(Fmt.shares([2, 1]) == ["66.7%", "33.3%"])
    #expect(Fmt.shares([0, 0]) == ["0%", "0%"])
}

@Test func splitAmountsMatchTheShownTotal() {
    let usd = MoneyFormat()
    #expect(usd.string(763.17) == "$763.17")
    #expect(usd.split(763.17, into: [761.62, 1.55]) == ["$761.62", "$1.55"])
    // 各自四舍五入会变成 $0.01 + $0.01 ≠ $0.01
    #expect(usd.split(0.01, into: [0.005, 0.005]) == ["$0.01", "$0.00"])
    // 总额 ≥ 10000 时不带小数，分项也不带
    #expect(usd.string(12_345.6) == "$12,346")
    #expect(usd.split(12_345.6, into: [12_000.2, 345.4]) == ["$12,000", "$346"])
    // 日元没有小数，先折算再拆分
    let yen = MoneyFormat(unit: .jpy, rate: 150)
    #expect(yen.split(10, into: [7.5, 2.5]) == ["JP¥1,125", "JP¥375"])
}

// MARK: - 本期预计

private func period(days: Int, cost: Double) -> PeriodUsage {
    PeriodUsage(start: now, end: now.addingTimeInterval(Double(days) * 86_400), dayIndex: 1, dayCount: days,
                cost: cost, tokens: .zero, requests: 0, models: [])
}

@Test func projectionFollowsTheDailyAverage() {
    let week = period(days: 7, cost: 700)
    // 过去 1.75 天：日均 400，预计 400 × 7
    #expect(abs(week.dailyAverage(now: after(42)) - 400) < 1e-9)
    #expect(abs(week.projectedCost(now: after(42)) - 2800) < 1e-9)
    // 刚开始 2 小时：按一天算，不把两小时的消耗放大成一周
    #expect(abs(week.dailyAverage(now: after(2)) - 700) < 1e-9)
    #expect(abs(week.projectedCost(now: after(2)) - 4900) < 1e-9)
    // 周期结束之后就是实际总额
    #expect(abs(week.projectedCost(now: after(8 * 24)) - 700) < 1e-9)
}

@Test func projectionForASingleDayUsesHours() {
    let day = period(days: 1, cost: 60)
    #expect(abs(day.projectedCost(now: after(12)) - 120) < 1e-9)
    // 开头不足 6 小时按 6 小时算
    #expect(abs(day.projectedCost(now: after(2)) - 240) < 1e-9)
    #expect(abs(day.projectedCost(now: after(30)) - 60) < 1e-9)
}

// MARK: - 预计按每周额度封顶

private func allowance(start: Date = now, utilization: Double, synced: Double, spent: Double) -> WeeklyAllowance {
    WeeklyAllowance(start: start, end: start.addingTimeInterval(7 * 86_400), utilization: utilization, syncedCost: synced, spent: spent)
}

@Test func weekProjectionStopsWhereTheLimitRunsOut() throws {
    // 过去 2 天花了 2000，照日均 1000 一周是 7000；同步时 2000 对应 62.5%，额度用完时是 3200
    let week = period(days: 7, cost: 2000)
    let a = allowance(utilization: 62.5, synced: 2000, spent: 2000)
    #expect(abs(a.full - 3200) < 1e-9)
    #expect(abs(a.remaining - 1200) < 1e-9)
    let p = week.projection(now: after(48), allowance: a)
    #expect(abs(p.cost - 3200) < 1e-9)
    let runsOut = try #require(p.runsOut)
    // 还能花 1200，照日均 1000 再过 1.2 天；和只看官方百分比一样：2 天用了 62.5%，第 3.2 天用完
    #expect(abs(runsOut.timeIntervalSince(after(48)) - 1.2 * 86_400) < 1e-6)
    #expect(abs(runsOut.timeIntervalSince(now) - 2 / 0.625 * 86_400) < 1e-6)
}

@Test func projectionWithinTheLimitIsTheDailyAverage() {
    // 2 天花了 600，照日均 300 一周 2100，额度 3200 够用
    let week = period(days: 7, cost: 600)
    let p = week.projection(now: after(48), allowance: allowance(utilization: 18.75, synced: 600, spent: 600))
    #expect(p.runsOut == nil)
    #expect(abs(p.cost - week.projectedCost(now: after(48))) < 1e-9)
    #expect(week.projection(now: after(48), allowance: nil) == Projection(cost: 2100))
}

@Test func earlyProjectionCountsAWholeDayLikeTheAverage() throws {
    // 开头 2 小时花了 700：和日均一样按一天算，额度 2800，第 4 天用完
    let week = period(days: 7, cost: 700)
    let p = week.projection(now: after(2), allowance: allowance(utilization: 25, synced: 700, spent: 700))
    #expect(abs(p.cost - 2800) < 1e-9)
    #expect(abs(try #require(p.runsOut).timeIntervalSince(now) - 4 * 86_400) < 1e-6)
}

@Test func monthProjectionStopsEachWeekAtItsLimit() throws {
    // 30 天过去 10 天，花了 4000（日均 400）。本周从第 7 天开始，同步时花了 1500、对应 50%：每周额度 3000
    let month = period(days: 30, cost: 4000)
    let a = allowance(start: after(7 * 24), utilization: 50, synced: 1500, spent: 1500)
    let p = month.projection(now: after(10 * 24), allowance: a)
    // 本周还有 4 天想花 1600，只剩 1500；之后两整周各 2800，不到 3000；最后 2 天 800
    #expect(abs(p.cost - (4000 + 1500 + 2800 + 2800 + 800)) < 1e-9)
    #expect(abs(try #require(p.runsOut).timeIntervalSince(after(10 * 24)) - 3.75 * 86_400) < 1e-6)

    // 日均 600 时之后的整周也到顶
    let busy = period(days: 30, cost: 6000)
    let q = busy.projection(now: after(10 * 24), allowance: a)
    #expect(abs(q.cost - (6000 + 1500 + 3000 + 3000 + 1200)) < 1e-9)
    #expect(abs(try #require(q.runsOut).timeIntervalSince(after(10 * 24)) - 2.5 * 86_400) < 1e-6)
}

@Test func dayProjectionResumesAfterTheWeeklyReset() throws {
    // 过去 12 小时花了 600（每小时 50）。每周额度第 20 小时重置，本周只剩 200
    let day = period(days: 1, cost: 600)
    let a = allowance(start: after(20 - 7 * 24), utilization: 95, synced: 3800, spent: 3800)
    let p = day.projection(now: after(12), allowance: a)
    // 重置前 8 小时想花 400，只剩 200，第 16 小时用完；重置后 4 小时是新的一周，200
    #expect(abs(p.cost - (600 + 200 + 200)) < 1e-9)
    #expect(try #require(p.runsOut) == after(16))
}

@Test func projectionHoldsOnceTheLimitIsUsedUp() {
    // 官方已经 100%：本周到重置前不再增加
    let week = period(days: 7, cost: 3000)
    let p = week.projection(now: after(96), allowance: allowance(utilization: 100, synced: 3000, spent: 3000))
    #expect(abs(p.cost - 3000) < 1e-9)
    #expect(p.runsOut == after(96))
    // 周期已经结束：就是实际总额
    #expect(week.projection(now: after(8 * 24), allowance: allowance(utilization: 100, synced: 3000, spent: 3000)) == Projection(cost: 3000))
}

@Test func roundingKeepsEachPartClose() {
    // 已经是目标单位：各自取整，差的那一份给小数最大的
    #expect(Apportion.rounded([12_000.2, 345.4], total: 12_346) == [12_000, 346])
    #expect(Apportion.rounded([0.5, 0.5], total: 1) == [1, 0])
    #expect(Apportion.rounded([1.2, 2.3], total: 4) == [1, 3])
    // 和总数差得太多：按比例缩放
    #expect(Apportion.rounded([1, 1], total: 10) == [5, 5])
    #expect(Apportion.rounded([5, 5], total: 0) == [0, 0])
}

@Test func projectionMatchesTheShownDailyAverage() {
    let usd = MoneyFormat()
    // 日均显示 $462（实际 $461.57），乘出来是 $3,234，而不是 461.57 × 7 = $3,231
    #expect(usd.whole(461.57) == "$462")
    #expect(usd.whole(461.57, times: 7) == "$3,234")
    // 不足 100 时日均保留两位小数
    #expect(usd.whole(12.345, times: 7) == "$86.45")
    #expect(usd.whole(20.004, times: 7) == "$140")
    let yen = MoneyFormat(unit: .jpy, rate: 150)
    #expect(yen.whole(3.333, times: 30) == "JP¥15,000")
}
