import Foundation

/// 官方在一周中途重置了每周限额：重置时间没变，百分比却比这一周之前的读数低了一截
/// （2026-11-11 那次是 95% 之后直接回到 1%）。
///
/// 重置之后官方百分比从 0 重新算，本机这一周的消耗却一直在累加。折算额度时只能拿重置之后的消耗去对应官方百分比，
/// 之前花的不再占用额度。官方不说什么时候重置的，只知道在前后两次读数之间，具体时刻由 `UsageCalculator` 估计。
public struct MidweekReset: Sendable, Equatable, Codable {
    /// 重置前最后一次读数
    public var before: WeeklyReading
    /// 重置后第一次读数
    public var after: WeeklyReading
    /// 这一周的结束（每周限额的重置时间）
    public var weekEnd: Date

    /// 比同一周之前的读数至少低这么多（百分点）才算重置：官方百分比只有整数，偶尔小幅修正不算
    public static let minimumDrop = 5.0

    public init(before: WeeklyReading, after: WeeklyReading, weekEnd: Date) {
        self.before = before
        self.after = after
        self.weekEnd = weekEnd
    }

    /// 两次读数之间有没有重置：同一周（每周重置时间相差不到一分钟）、时间先后对，而且百分比明显变低
    public static func between(_ before: WeeklyReading, weekEnd beforeEnd: Date,
                               and after: WeeklyReading, weekEnd afterEnd: Date) -> MidweekReset? {
        guard abs(beforeEnd.timeIntervalSince(afterEnd)) < 60, after.at > before.at,
              before.utilization - after.utilization >= minimumDrop else { return nil }
        return MidweekReset(before: before, after: after, weekEnd: afterEnd)
    }

    /// 是不是这一周的
    public func belongs(toWeekEnding end: Date) -> Bool {
        abs(weekEnd.timeIntervalSince(end)) < 60
    }
}
