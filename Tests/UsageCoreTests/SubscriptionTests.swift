import Foundation
import Testing
@testable import UsageCore

private let shanghai: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return cal
}()

private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    shanghai.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

/// 每月 28 日、22:00 换期（和每周重置同一个时刻）
private func term(_ now: Date, day: Int = 28, hour: Int = 22) -> SubscriptionTerm {
    SubscriptionTerm(now: now, anchorDay: day, hour: hour, minute: 0, second: 0, calendar: shanghai)
}

/// CI 上的 Swift 6.1 推断 `#expect` 里的可选值和隐式成员很慢：先算出来，再和写明类型的值比较
private func health(_ status: String?, action: Bool = false, plan: Bool = true) -> SubscriptionHealth? {
    SubscriptionHealth(status: status, paymentActionRequired: action, hasPaidPlan: plan)
}

private let active = SubscriptionHealth.active
private let paymentFailed = SubscriptionHealth.paymentFailed
private let actionRequired = SubscriptionHealth.actionRequired
private let inactive = SubscriptionHealth.inactive
private let unknown: SubscriptionHealth? = nil
private let noReminder: Int? = nil

// MARK: - 官方订阅状态

@Test func subscriptionStatusFollowsStripeNames() {
    #expect(health("active") == active)
    #expect(health("trialing") == active)
    #expect(health("past_due") == paymentFailed)
    #expect(health("PAST_DUE") == paymentFailed)
    for ended in ["canceled", "cancelled", "unpaid", "incomplete", "incomplete_expired", "paused"] {
        let result = health(ended)
        #expect(result == inactive, "\(ended)")
    }
}

@Test func paymentNeedingConfirmationOutranksPastDue() {
    #expect(health("past_due", action: true) == actionRequired)
    #expect(health("active", action: true) == actionRequired)
    // 已经结束的订阅不再要求付款
    #expect(health("canceled", action: true) == inactive)
}

@Test func missingStatusOnlyMeansEndedWithoutAPlan() {
    // 组织付费的套餐（Team、Enterprise）可能没有订阅状态：不下结论
    #expect(health(nil) == unknown)
    #expect(health(nil, plan: false) == inactive)
    #expect(health("", plan: false) == inactive)
    // 认不出的新状态不报警
    #expect(health("some_new_state") == unknown)
}

// MARK: - 本期还剩几天

@Test func termEndsOnTheBillingDayAtTheResetClock() {
    let now = at(2026, 11, 4, 23, 0)
    let t = term(now)
    let start = at(2026, 10, 28, 22)
    let end = at(2026, 11, 28, 22)
    #expect(t.start == start)
    #expect(t.end == end)
    // 11 月 28 日 − 11 月 4 日 = 24 天
    #expect(t.daysLeft == 24)
    #expect(t.isEnding == false)
    #expect(t.justStarted(at: now) == false)
}

@Test func lastDaysCountByTheCalendar() {
    let fourDays = term(at(2026, 11, 24, 23, 59))
    #expect(fourDays.daysLeft == 4)
    #expect(fourDays.isEnding == false)
    let threeDays = term(at(2026, 11, 25, 0, 0))
    #expect(threeDays.daysLeft == 3)
    #expect(threeDays.isEnding == true)
    let tomorrow = term(at(2026, 11, 27, 10))
    #expect(tomorrow.daysLeft == 1)
    // 扣费日当天、换期之前
    let lastDay = term(at(2026, 11, 28, 21, 59, 59))
    let end = at(2026, 11, 28, 22)
    #expect(lastDay.daysLeft == 0)
    #expect(lastDay.end == end)
}

@Test func termRollsOverAtTheResetClock() {
    let rollover = at(2026, 11, 28, 22)
    let next = term(rollover)
    let end = at(2026, 12, 28, 22)
    #expect(next.start == rollover)
    #expect(next.end == end)
    #expect(next.daysLeft == 30)
    #expect(next.justStarted(at: rollover) == true)
    #expect(next.justStarted(at: at(2026, 11, 29, 21, 59)) == true)
    #expect(next.justStarted(at: at(2026, 11, 29, 22)) == false)
}

@Test func lateBillingDaysUseTheMonthsLastDay() {
    // 每月 31 日：二月按 28 日
    let feb = SubscriptionTerm(now: at(2027, 2, 10), anchorDay: 31, calendar: shanghai)
    let start = at(2027, 1, 31)
    let end = at(2027, 2, 28)
    #expect(feb.start == start)
    #expect(feb.end == end)
    #expect(feb.daysLeft == 18)
}

// MARK: - 到期提醒

@Test func remindersFireThreeDaysAndOneDayBefore() {
    let none = Set<Int>()
    let afterThree: Set<Int> = [3]
    let afterBoth: Set<Int> = [3, 1]
    #expect(term(at(2026, 11, 24, 12)).dueReminder(sent: none) == noReminder)
    #expect(term(at(2026, 11, 25, 12)).dueReminder(sent: none) == 3)
    #expect(term(at(2026, 11, 25, 12)).dueReminder(sent: afterThree) == noReminder)
    #expect(term(at(2026, 11, 26, 12)).dueReminder(sent: afterThree) == noReminder)
    #expect(term(at(2026, 11, 27, 12)).dueReminder(sent: afterThree) == 1)
    #expect(term(at(2026, 11, 28, 12)).dueReminder(sent: afterBoth) == noReminder)
}

@Test func missedRemindersCollapseIntoOne() {
    // 前几天没开机：只补最近的那一次，不会接连弹两条
    let none = Set<Int>()
    let afterOne: Set<Int> = [1]
    #expect(term(at(2026, 11, 26, 12)).dueReminder(sent: none) == 3)
    #expect(term(at(2026, 11, 28, 12)).dueReminder(sent: none) == 1)
    #expect(term(at(2026, 11, 28, 12)).dueReminder(sent: afterOne) == noReminder)
}
