import Foundation

/// 自动查询的时机。只决定什么时候向官方查询，显示的数值仍然只来自官方接口。
///
/// 官方用量接口限额很紧，同一账号下的客户端共用同一份，所以只在数字可能变化时才问：
/// 官方百分比是整数，本机消耗攒够让它涨一格（1 个百分点）才值得查一次。一格要多少消耗，
/// 由当前窗口自己的数据推算（窗口里的本机消耗 ÷ 官方百分比），只用来安排查询时机，不用来显示。
/// 另外还要满足：Claude Code 正在使用（会话在运行，且最近有新的 Token 消耗）、上次同步之后 Token 有变化、
/// 距上一次请求不少于所选间隔。请求预算（`RequestBudget`）与出口是否可用由调用方在发请求前确认。
public enum AutoSyncPolicy {
    /// 任意两次官方请求的最短间隔（自动与手动都遵守）
    public static let minimumSpacing: TimeInterval = 10
    /// 自动查询的最短间隔：默认 30 秒，可以在 10 秒到 1 小时之间自定义
    public static let defaultInterval: TimeInterval = 30
    public static let intervalRange: ClosedRange<TimeInterval> = minimumSpacing...3600
    /// 「正在使用」：最近这么久内有新的 Token 消耗
    public static let activeWindow: TimeInterval = 5 * 60
    /// 一格至少按这么多本机消耗（美元，按 API 价格折算）算：窗口刚开始、还推算不出来时用它
    public static let minimumStep: Double = 0.5
    /// 一直有新消耗时，最长这么久也查一次：其他设备上的用量、推算的偏差都靠它校正
    public static let longestWait: TimeInterval = 15 * 60
    /// 消耗停下这么久后（Claude Code 两轮之间的停顿），攒下的消耗够三成格就补查一次
    public static let settleDelay: TimeInterval = 15
    /// 停下补查、展开面板时，攒到这么多格就值得问一次
    public static let partialStep: Double = 0.3

    public struct Activity: Sendable, Equatable {
        /// 有 Claude Code 会话在运行（终端里的命令行，或桌面版里的 Claude Code）
        public var claudeCodeRunning: Bool
        /// 最近一次新增 Token 消耗的时间
        public var lastConsumption: Date?
        /// 上次成功查询之后新增的消耗（美元，按 API 价格折算）
        public var unsyncedCost: Double
        /// 上次成功查询之后有没有新的 Token 消耗（包括应用启动之前发生的）
        public var hasNewUsage: Bool
        /// 官方百分比涨一格大约需要的本机消耗（美元），见 `step(_:)`
        public var step: Double

        public init(claudeCodeRunning: Bool, lastConsumption: Date?, unsyncedCost: Double,
                    hasNewUsage: Bool? = nil, step: Double = AutoSyncPolicy.minimumStep) {
            self.claudeCodeRunning = claudeCodeRunning
            self.lastConsumption = lastConsumption
            self.unsyncedCost = unsyncedCost
            self.hasNewUsage = hasNewUsage ?? (unsyncedCost > 0)
            self.step = step
        }

        /// 上次同步之后攒下了几格
        public var progress: Double { unsyncedCost / max(step, AutoSyncPolicy.minimumStep) }
    }

    /// 一个限额窗口在上次同步时的样子：窗口里（重置前 5 小时或 7 天以来）的本机消耗，和官方给的整数百分比
    public struct Window: Sendable, Equatable {
        public var cost: Double
        public var percent: Int

        public init(cost: Double, percent: Int) {
            self.cost = cost
            self.percent = percent
        }
    }

    public enum Occasion: Sendable, Equatable {
        /// 定时检查
        case tick
        /// 启动、从睡眠唤醒、出口恢复可用：正在使用就查一次
        case resume
    }

    /// 官方百分比涨一格大约需要的本机消耗。上次同步时百分比取整后是 p，实际在 p 到 p+1 之间，按 p+1 算，宁可早一点查；
    /// 取各窗口里最小的一格。还是 0% 时一格就是窗口里已有的消耗（消耗翻一倍再问），太小时按 `minimumStep`。
    public static func step(_ windows: [Window]) -> Double {
        let steps = windows.map { $0.cost / Double(max(0, $0.percent) + 1) }
        return max(minimumStep, steps.min() ?? minimumStep)
    }

    /// 自定义的间隔取整到秒，并限制在允许的范围内
    public static func clampedInterval(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return defaultInterval }
        return min(max(seconds.rounded(), intervalRange.lowerBound), intervalRange.upperBound)
    }

    /// 1.2.5 及以前「自动查询」的几档固定频率：升级后换成同样秒数的最短间隔
    public static func legacyInterval(_ rawValue: String) -> TimeInterval? {
        switch rawValue {
        case "every10Seconds": 10
        case "every30Seconds": 30
        case "everyMinute": 60
        case "every2Minutes": 120
        case "every5Minutes": 300
        default: nil
        }
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
    ///   - interval: 所选间隔（秒），自动查询不会比它更频繁
    ///   - lastRequest: 上一次向官方发出请求的时间（自动或手动）
    public static func shouldSync(
        interval: TimeInterval, occasion: Occasion, activity: Activity, lastRequest: Date?, now: Date
    ) -> Bool {
        // Token 没有变化，官方数字就不会变：不查询
        guard isInUse(activity, now: now), activity.hasNewUsage else { return false }
        let sinceRequest = lastRequest.map { now.timeIntervalSince($0) } ?? .infinity
        // 所选间隔是最快的频率：启动、唤醒也不会更频繁
        guard sinceRequest >= clampedInterval(interval) else { return false }
        switch occasion {
        case .resume:
            return true
        case .tick:
            // 攒够一格，数字很可能已经变了；一直在消耗时也不会太久不查
            if activity.progress >= 1 || sinceRequest >= longestWait { return true }
            // 消耗停下来了：攒下的够三成格就补查一次
            guard let last = activity.lastConsumption, now.timeIntervalSince(last) >= settleDelay else { return false }
            return activity.progress >= partialStep
        }
    }

    /// 展开面板时要不要查：上次同步后攒下的消耗够三成格（数字可能已经变了），或者有新消耗、但很久没查过了
    public static func shouldCheckOnOpen(activity: Activity, lastRequest: Date?, now: Date) -> Bool {
        guard activity.hasNewUsage else { return false }
        let sinceRequest = lastRequest.map { now.timeIntervalSince($0) } ?? .infinity
        return activity.progress >= partialStep || sinceRequest >= longestWait
    }
}
