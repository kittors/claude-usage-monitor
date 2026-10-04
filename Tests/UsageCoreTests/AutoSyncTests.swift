import Foundation
import Testing
@testable import UsageCore

// MARK: - 自动查询的时机

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// 默认一格 $5：攒下的消耗按格数算
private func activity(running: Bool = true, consumedAgo: TimeInterval? = 3, unsynced: Double = 0.1,
                      newUsage: Bool = true, step: Double = 5) -> AutoSyncPolicy.Activity {
    AutoSyncPolicy.Activity(
        claudeCodeRunning: running,
        lastConsumption: consumedAgo.map { now.addingTimeInterval(-$0) },
        unsyncedCost: unsynced,
        hasNewUsage: newUsage,
        step: step
    )
}

private func sync(
    _ occasion: AutoSyncPolicy.Occasion = .tick, _ activity: AutoSyncPolicy.Activity,
    every interval: TimeInterval = AutoSyncPolicy.defaultInterval, requestedAgo: TimeInterval? = 60
) -> Bool {
    AutoSyncPolicy.shouldSync(
        interval: interval, occasion: occasion, activity: activity,
        lastRequest: requestedAgo.map { now.addingTimeInterval(-$0) }, now: now
    )
}

@Test func autoSyncOnlyWhileClaudeCodeIsInUse() {
    // 会话在运行、最近有消耗才算正在使用
    #expect(AutoSyncPolicy.isInUse(activity(), now: now))
    #expect(!AutoSyncPolicy.isInUse(activity(running: false), now: now))
    #expect(!AutoSyncPolicy.isInUse(activity(consumedAgo: nil), now: now))
    #expect(!AutoSyncPolicy.isInUse(activity(consumedAgo: 5 * 60 + 1), now: now))
    #expect(AutoSyncPolicy.isInUse(activity(consumedAgo: 5 * 60 - 1), now: now))

    // 不在使用：攒得再多、多久没查都不自动查询
    let idle = activity(running: false, unsynced: 100)
    #expect(!sync(.tick, idle, requestedAgo: nil))
    #expect(!sync(.resume, idle, requestedAgo: nil))
}

@Test func checksWhenUsageCanMoveThePercentage() {
    // 一格 $5：攒够一格才查，数字很可能已经变了
    #expect(!sync(.tick, activity(consumedAgo: 1, unsynced: 4.9)))
    #expect(sync(.tick, activity(consumedAgo: 1, unsynced: 5)))
    // 以前攒满 $0.5 就查：现在一格之内都不查，省下的就是被限流的那些请求
    #expect(!sync(.tick, activity(consumedAgo: 1, unsynced: 0.5), requestedAgo: 600))
    // 一直在消耗但攒不够一格：最长 15 分钟也查一次，校正其他设备的用量和推算偏差
    #expect(!sync(.tick, activity(consumedAgo: 1, unsynced: 0.5), requestedAgo: AutoSyncPolicy.longestWait - 1))
    #expect(sync(.tick, activity(consumedAgo: 1, unsynced: 0.5), requestedAgo: AutoSyncPolicy.longestWait))
}

@Test func settlesOnceUsageStops() {
    // 消耗停下 15 秒（Claude Code 两轮之间）：攒下的够三成格就补查一次
    #expect(!sync(.tick, activity(consumedAgo: 14, unsynced: 1.5)))
    #expect(sync(.tick, activity(consumedAgo: 15, unsynced: 1.5)))
    // 不到三成格，数字多半没变：不查
    #expect(!sync(.tick, activity(consumedAgo: 60, unsynced: 1.4)))
}

@Test func neverFasterThanTheInterval() {
    let heavy = activity(consumedAgo: 1, unsynced: 50)
    #expect(AutoSyncPolicy.defaultInterval == 30)
    #expect(!sync(.tick, heavy, requestedAgo: 29.9))
    #expect(sync(.tick, heavy, requestedAgo: 30))
    #expect(!sync(.resume, heavy, requestedAgo: 20))
    #expect(sync(.resume, heavy, requestedAgo: nil))
    // 自定义：最短 10 秒，再短也按 10 秒
    #expect(sync(.tick, heavy, every: 10, requestedAgo: 10))
    #expect(!sync(.tick, heavy, every: 3, requestedAgo: 9.9))
    #expect(!sync(.tick, heavy, every: 300, requestedAgo: 299))
}

@Test func noNewTokensMeansNoCheck() {
    // 上次同步之后 Token 没有变化：官方数字不会变，任何时机都不查
    let unchanged = activity(unsynced: 0, newUsage: false)
    #expect(!sync(.tick, unchanged, requestedAgo: 3600))
    #expect(!sync(.resume, unchanged, requestedAgo: nil))
    #expect(!AutoSyncPolicy.shouldCheckOnOpen(activity: unchanged, lastRequest: nil, now: now))
    // 应用启动前就有的新消耗（这次运行里还没算进累计）也算有变化
    #expect(sync(.resume, activity(unsynced: 0, newUsage: true), requestedAgo: nil))
}

@Test func openingThePanelChecksWhenTheNumberMayHaveMoved() {
    func open(_ a: AutoSyncPolicy.Activity, requestedAgo: TimeInterval? = 60) -> Bool {
        AutoSyncPolicy.shouldCheckOnOpen(activity: a, lastRequest: requestedAgo.map { now.addingTimeInterval(-$0) }, now: now)
    }
    // 三成格以上：数字可能已经变了
    #expect(open(activity(unsynced: 1.5)))
    #expect(!open(activity(unsynced: 1.4)))
    // 有新消耗但很久没查过（包括启动后第一次）：查
    #expect(open(activity(unsynced: 0.1), requestedAgo: AutoSyncPolicy.longestWait))
    #expect(open(activity(unsynced: 0, newUsage: true), requestedAgo: nil))
}

@Test func stepComesFromTheWindowItself() {
    typealias W = AutoSyncPolicy.Window
    // 上次同步时 5 小时窗口里本机花了 $33，官方 5%：实际在 5% 到 6% 之间，按 6% 算一格 $5.5（宁早勿晚）
    #expect(abs(AutoSyncPolicy.step([W(cost: 33, percent: 5)]) - 5.5) < 1e-9)
    // 取各窗口里小的一格：本周 $35、2% 一格约 $11.7，5 小时那格更小
    #expect(abs(AutoSyncPolicy.step([W(cost: 33, percent: 5), W(cost: 35, percent: 2)]) - 5.5) < 1e-9)
    // 窗口刚开始还是 0%：一格至少是窗口里已有的消耗，随消耗翻倍放宽
    #expect(AutoSyncPolicy.step([W(cost: 2, percent: 0)]) == 2)
    // 太小或推算不出来时按最小一格
    #expect(AutoSyncPolicy.step([W(cost: 0.1, percent: 0)]) == AutoSyncPolicy.minimumStep)
    #expect(AutoSyncPolicy.step([]) == AutoSyncPolicy.minimumStep)
    #expect(AutoSyncPolicy.step([W(cost: 0, percent: 7)]) == AutoSyncPolicy.minimumStep)
    // 格数按最小一格兜底，不会除以 0
    #expect(activity(unsynced: 1, step: 0).progress == 2)
}

@Test func intervalIsClampedToWholeSeconds() {
    #expect(AutoSyncPolicy.intervalRange.contains(AutoSyncPolicy.defaultInterval))
    #expect(AutoSyncPolicy.intervalRange.lowerBound == AutoSyncPolicy.minimumSpacing)
    #expect(AutoSyncPolicy.clampedInterval(30) == 30)
    #expect(AutoSyncPolicy.clampedInterval(29.6) == 30)
    #expect(AutoSyncPolicy.clampedInterval(5) == 10)
    #expect(AutoSyncPolicy.clampedInterval(-1) == 10)
    #expect(AutoSyncPolicy.clampedInterval(7200) == 3600)
    #expect(AutoSyncPolicy.clampedInterval(.nan) == 30)
    #expect(AutoSyncPolicy.clampedInterval(.infinity) == 30)
}

@Test func legacyFixedFrequenciesBecomeIntervals() {
    // 1.2.5 及以前的几档固定频率，升级后换成同样秒数的最短间隔
    #expect(AutoSyncPolicy.legacyInterval("every10Seconds") == 10)
    #expect(AutoSyncPolicy.legacyInterval("every30Seconds") == 30)
    #expect(AutoSyncPolicy.legacyInterval("everyMinute") == 60)
    #expect(AutoSyncPolicy.legacyInterval("every2Minutes") == 120)
    #expect(AutoSyncPolicy.legacyInterval("every5Minutes") == 300)
    #expect(AutoSyncPolicy.legacyInterval("consumption") == nil)
    #expect(AutoSyncPolicy.legacyInterval("") == nil)
}

// MARK: - 请求预算

@Test func budgetKeepsRequestsUnderTheServerLimit() {
    var budget = RequestBudget()
    // 闲置之后可以连着用几次：自动查询用到只剩一次为止，那一次留给手动刷新
    for i in 0..<4 {
        #expect(budget.allows(manual: false, at: now), "第 \(i + 1) 次")
        budget.spend(at: now)
    }
    #expect(!budget.allows(manual: false, at: now))
    #expect(budget.allows(manual: true, at: now))
    budget.spend(at: now)
    #expect(!budget.allows(manual: true, at: now))

    // 每 5 分钟攒回一次；自动查询要攒到两次（花一次、留一次）
    #expect(budget.wait(manual: true, at: now) == RequestBudget.refillInterval)
    #expect(budget.wait(manual: false, at: now) == 2 * RequestBudget.refillInterval)
    let later = now.addingTimeInterval(2 * RequestBudget.refillInterval)
    #expect(budget.allows(manual: false, at: later))

    // 一小时内自动查询最多：先用掉攒下的 4 次，之后每 5 分钟 1 次
    var hour = RequestBudget()
    var sent = 0
    for second in stride(from: 0.0, to: 3600, by: 2) {
        let t = now.addingTimeInterval(second)
        if hour.allows(manual: false, at: t) { hour.spend(at: t); sent += 1 }
    }
    #expect(sent <= 4 + 12)
}

@Test func budgetRefillsUpToCapacityAndDrainsOnRateLimit() {
    var budget = RequestBudget(tokens: 0, updatedAt: now)
    #expect(budget.available(at: now.addingTimeInterval(3600)) == RequestBudget.capacity)
    // 系统时间往回调：不倒扣，也不凭空多出来
    #expect(budget.available(at: now.addingTimeInterval(-3600)) == 0)
    // 服务器已经限流：清零重新攒
    budget = RequestBudget()
    budget.drain(at: now)
    #expect(budget.available(at: now) == 0)
    #expect(!budget.allows(manual: true, at: now))
    // 跨重启保留
    let data = try? JSONEncoder().encode(budget)
    #expect(data.flatMap { try? JSONDecoder().decode(RequestBudget.self, from: $0) } == budget)
}
