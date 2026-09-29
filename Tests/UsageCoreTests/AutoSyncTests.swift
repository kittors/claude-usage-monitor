import Foundation
import Testing
@testable import UsageCore

// MARK: - 自动查询的时机

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func activity(running: Bool = true, consumedAgo: TimeInterval? = 3, unsynced: Double = 0.1, newUsage: Bool = true) -> AutoSyncPolicy.Activity {
    AutoSyncPolicy.Activity(
        claudeCodeRunning: running,
        lastConsumption: consumedAgo.map { now.addingTimeInterval(-$0) },
        unsyncedCost: unsynced,
        hasNewUsage: newUsage
    )
}

private func sync(
    _ mode: AutoSyncMode = .consumption, _ occasion: AutoSyncPolicy.Occasion = .tick,
    _ activity: AutoSyncPolicy.Activity, requestedAgo: TimeInterval? = 60, windowReset: Bool = false
) -> Bool {
    AutoSyncPolicy.shouldSync(
        mode: mode, occasion: occasion, activity: activity,
        lastRequest: requestedAgo.map { now.addingTimeInterval(-$0) },
        windowReset: windowReset, now: now
    )
}

@Test func autoSyncOnlyWhileClaudeCodeIsInUse() {
    // 会话在运行、最近有消耗才算正在使用
    #expect(AutoSyncPolicy.isInUse(activity(), now: now))
    #expect(!AutoSyncPolicy.isInUse(activity(running: false), now: now))
    #expect(!AutoSyncPolicy.isInUse(activity(consumedAgo: nil), now: now))
    #expect(!AutoSyncPolicy.isInUse(activity(consumedAgo: 5 * 60 + 1), now: now))
    #expect(AutoSyncPolicy.isInUse(activity(consumedAgo: 5 * 60 - 1), now: now))

    // 不在使用：任何频率、任何时机都不自动查询
    let idle = activity(running: false, unsynced: 10)
    for mode in AutoSyncMode.allCases {
        #expect(!sync(mode, .tick, idle, requestedAgo: nil))
    }
    #expect(!sync(.consumption, .resume, idle))
    #expect(!sync(.consumption, .tick, idle, windowReset: true))
}

@Test func autoSyncNeverFasterThanTenSeconds() {
    let busy = activity(unsynced: 50)
    #expect(!sync(.every10Seconds, .tick, busy, requestedAgo: 9.9))
    #expect(sync(.every10Seconds, .tick, busy, requestedAgo: 10))
    #expect(!sync(.consumption, .tick, busy, requestedAgo: 9))
    #expect(!sync(.consumption, .resume, busy, requestedAgo: 5))
    #expect(!sync(.consumption, .tick, busy, requestedAgo: 3, windowReset: true))
    #expect(sync(.consumption, .tick, busy, requestedAgo: nil))
}

@Test func fixedIntervalsFollowTheChosenPeriod() {
    let using = activity(unsynced: 0)
    #expect(!sync(.every30Seconds, .tick, using, requestedAgo: 29))
    #expect(sync(.every30Seconds, .tick, using, requestedAgo: 30))
    #expect(!sync(.everyMinute, .tick, using, requestedAgo: 59))
    #expect(sync(.everyMinute, .tick, using, requestedAgo: 60))
    #expect(!sync(.every5Minutes, .tick, using, requestedAgo: 299))
    #expect(sync(.every5Minutes, .tick, using, requestedAgo: 300))
    // 窗口到了重置时间，不等下一个周期
    #expect(sync(.every5Minutes, .tick, using, requestedAgo: 20, windowReset: true))
}

@Test func noNewTokensMeansNoCheck() {
    // 上次同步之后 Token 没有变化：官方数字不会变，任何频率、任何时机都不查
    let unchanged = activity(unsynced: 0, newUsage: false)
    for mode in AutoSyncMode.allCases {
        #expect(!sync(mode, .tick, unchanged, requestedAgo: 3600))
        #expect(!sync(mode, .tick, unchanged, requestedAgo: 3600, windowReset: true))
        #expect(!sync(mode, .resume, unchanged, requestedAgo: nil))
    }
    // 应用启动前就有的新消耗（这次运行里还没算进累计）也算有变化
    #expect(sync(.consumption, .resume, activity(unsynced: 0, newUsage: true), requestedAgo: nil))
    #expect(sync(.everyMinute, .tick, activity(unsynced: 0, newUsage: true), requestedAgo: 60))
}

@Test func consumptionModeFollowsTokenUse() {
    // 没有新消耗就不查
    #expect(!sync(.consumption, .tick, activity(unsynced: 0, newUsage: false), requestedAgo: 3600))
    // 新消耗达到阈值：满 10 秒就查
    #expect(sync(.consumption, .tick, activity(consumedAgo: 1, unsynced: AutoSyncPolicy.costThreshold), requestedAgo: 12))
    // 消耗少、仍在继续：等到最长间隔
    #expect(!sync(.consumption, .tick, activity(consumedAgo: 1, unsynced: 0.05), requestedAgo: 60))
    #expect(sync(.consumption, .tick, activity(consumedAgo: 1, unsynced: 0.05), requestedAgo: AutoSyncPolicy.longestWait))
    // 消耗停下 15 秒：补查一次
    #expect(!sync(.consumption, .tick, activity(consumedAgo: 14, unsynced: 0.05), requestedAgo: 30))
    #expect(sync(.consumption, .tick, activity(consumedAgo: 15, unsynced: 0.05), requestedAgo: 30))
    // 闲了很久之后的第一笔消耗：立即查
    #expect(sync(.consumption, .tick, activity(consumedAgo: 1, unsynced: 0.01), requestedAgo: 3600))
}

@Test func resumeSyncsOnceWhileInUse() {
    let using = activity(unsynced: 0)
    #expect(sync(.every5Minutes, .resume, using, requestedAgo: 11))
    #expect(sync(.consumption, .resume, using, requestedAgo: nil))
    #expect(!sync(.consumption, .resume, activity(running: false), requestedAgo: nil))
}

@Test func modeIntervals() {
    #expect(AutoSyncMode.consumption.interval == nil)
    #expect(AutoSyncMode.allCases.compactMap(\.interval) == [10, 30, 60, 120, 300])
    #expect(AutoSyncMode.allCases.compactMap(\.interval).allSatisfy { $0 >= AutoSyncPolicy.minimumSpacing })
}
