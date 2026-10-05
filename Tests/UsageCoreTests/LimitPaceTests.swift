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
