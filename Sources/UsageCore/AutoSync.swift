import Foundation

/// 自动查询官方用量的频率
public enum AutoSyncMode: String, CaseIterable, Sendable {
    /// 按本机的 Token 消耗决定（默认）
    case consumption
    case every10Seconds
    case every30Seconds
    case everyMinute
    case every2Minutes
    case every5Minutes

    /// 固定间隔；按消耗查询时为 nil
    public var interval: TimeInterval? {
        switch self {
        case .consumption: nil
        case .every10Seconds: 10
        case .every30Seconds: 30
        case .everyMinute: 60
        case .every2Minutes: 120
        case .every5Minutes: 300
        }
    }
}

/// 自动查询的时机。只决定什么时候向官方查询，显示的数值仍然只来自官方接口。
///
/// 自动查询要同时满足：Claude Code 正在使用（会话在运行，且最近有新的 Token 消耗）、
/// 距上一次请求不少于 10 秒，再按所选频率判断。出口是否可用由调用方在发请求前确认。
public enum AutoSyncPolicy {
    /// 任意两次官方请求的最短间隔（自动与手动都遵守）
    public static let minimumSpacing: TimeInterval = 10
    /// 「正在使用」：最近这么久内有新的 Token 消耗
    public static let activeWindow: TimeInterval = 5 * 60
    /// 按消耗查询：上次查询之后新增的消耗（按 API 价格折算，美元）达到这个数就查
    public static let costThreshold: Double = 0.5
    /// 按消耗查询：一直有新消耗时，最长这么久也查一次
    public static let longestWait: TimeInterval = 2 * 60
    /// 按消耗查询：消耗停下这么久后补查一次，拿到这一轮结束时的数字
    public static let settleDelay: TimeInterval = 15

    public struct Activity: Sendable, Equatable {
        /// 有 Claude Code 会话在运行（终端里的命令行，或桌面版里的 Claude Code）
        public var claudeCodeRunning: Bool
        /// 最近一次新增 Token 消耗的时间
        public var lastConsumption: Date?
        /// 上次成功查询之后新增的消耗（美元，按 API 价格折算）
        public var unsyncedCost: Double

        public init(claudeCodeRunning: Bool, lastConsumption: Date?, unsyncedCost: Double) {
            self.claudeCodeRunning = claudeCodeRunning
            self.lastConsumption = lastConsumption
            self.unsyncedCost = unsyncedCost
        }
    }

    public enum Occasion: Sendable, Equatable {
        /// 定时检查
        case tick
        /// 启动、从睡眠唤醒、出口恢复可用：正在使用就查一次
        case resume
    }

    /// 最近有新的 Token 消耗
    public static func hasRecentConsumption(_ activity: Activity, now: Date) -> Bool {
        guard let last = activity.lastConsumption else { return false }
        return now.timeIntervalSince(last) < activeWindow
    }

    /// Claude Code 正在使用：会话在运行，并且最近有新的消耗
    public static func isInUse(_ activity: Activity, now: Date) -> Bool {
        activity.claudeCodeRunning && hasRecentConsumption(activity, now: now)
    }

    /// - Parameters:
    ///   - lastRequest: 上一次向官方发出请求的时间（自动或手动）
    ///   - windowReset: 上次同步之后，5 小时或每周窗口已经到了重置时间
    public static func shouldSync(
        mode: AutoSyncMode, occasion: Occasion, activity: Activity,
        lastRequest: Date?, windowReset: Bool, now: Date
    ) -> Bool {
        guard isInUse(activity, now: now) else { return false }
        let sinceRequest = lastRequest.map { now.timeIntervalSince($0) } ?? .infinity
        guard sinceRequest >= minimumSpacing else { return false }
        switch occasion {
        case .resume:
            return true
        case .tick:
            if windowReset { return true }
            if let interval = mode.interval { return sinceRequest >= interval }
            guard activity.unsyncedCost > 0 else { return false }
            if activity.unsyncedCost >= costThreshold || sinceRequest >= longestWait { return true }
            // 消耗停下来了：补查一次
            guard let last = activity.lastConsumption else { return false }
            return now.timeIntervalSince(last) >= settleDelay
        }
    }
}
