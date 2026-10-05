import Foundation

/// 限额的安全线：按时间进度，此刻用到这里为止，照这个速度到重置都不会用完。
/// 窗口只由官方的重置时间推出来（重置前 5 小时、重置前 7 天），不涉及任何用量估算。
public enum LimitPace {
    public static let fiveHourWindow: TimeInterval = 5 * 3600
    public static let weekWindow: TimeInterval = 7 * 86_400
    /// 5 小时窗口开头这一段先不提示超线：一两条带大段上下文的消息就会冲过还很低的安全线
    public static let settlingShare = 0.1

    public struct Line: Sendable, Equatable {
        /// 安全线的位置（0…1）
        public var fraction: Double
        /// 窗口已经过去的时间
        public var elapsed: TimeInterval
        /// 每周按天算时，今天是窗口里的第几天（1…7）；5 小时为 nil
        public var day: Int?
        /// 5 小时窗口刚开始，先不提示超线
        public var settling: Bool

        /// 用量超过了安全线（窗口刚开始时不算）
        public func isExceeded(by usage: Double) -> Bool {
            !settling && usage > fraction + 1e-9
        }
    }

    /// 5 小时：安全线随时间连续推进，等于窗口已经过去的比例
    public static func fiveHour(resetsAt: Date?, now: Date) -> Line? {
        guard let elapsed = elapsed(resetsAt: resetsAt, window: fiveHourWindow, now: now) else { return nil }
        return Line(fraction: elapsed / fiveHourWindow, elapsed: elapsed, day: nil, settling: elapsed < fiveHourWindow * settlingShare)
    }

    /// 每周：从窗口开始（重置前 7 天）起每 24 小时算一天。今天是第 k 天，安全线就是 k/7，今天结束前用到这里都不会提前用完。
    public static func weekly(resetsAt: Date?, now: Date) -> Line? {
        guard let elapsed = elapsed(resetsAt: resetsAt, window: weekWindow, now: now) else { return nil }
        let day = min(7, Int(elapsed / 86_400) + 1)
        return Line(fraction: Double(day) / 7, elapsed: elapsed, day: day, settling: false)
    }

    /// 窗口已经过去多久。已经重置、或者窗口还没开始时为 nil。
    private static func elapsed(resetsAt: Date?, window: TimeInterval, now: Date) -> TimeInterval? {
        guard let resetsAt, resetsAt > now else { return nil }
        let elapsed = window - resetsAt.timeIntervalSince(now)
        return elapsed >= 0 ? elapsed : nil
    }
}

/// 按比例把一个整数总数分给各部分（最大余数法）：各部分加起来正好等于总数。
/// 用来显示占比和分项金额，避免出现「100% + 0.2%」「$762 + $1.55 ≠ $763.17」这种看起来对不上的情况。
public enum Apportion {
    /// 按权重的比例分成整数，加起来正好是 `total`
    public static func largestRemainder(_ weights: [Double], total: Int) -> [Int] {
        let clean = weights.map { $0.isFinite ? max(0, $0) : 0 }
        let sum = clean.reduce(0, +)
        guard total > 0, sum > 0 else { return clean.map { _ in 0 } }
        return rounded(clean.map { $0 / sum * Double(total) }, total: total)
    }

    /// 已经换算成目标单位的数（例如以分计的金额）取整，加起来正好是 `total`：各自向下取整，差的几份给小数部分最大的，
    /// 这样每一项都尽量贴近自己的值。和 `total` 差得比取整误差还多时，先按比例缩放。
    public static func rounded(_ quotas: [Double], total: Int) -> [Int] {
        let clean = quotas.map { $0.isFinite ? max(0, $0) : 0 }
        guard total > 0 else { return clean.map { _ in 0 } }
        var parts = clean.map { Int($0.rounded(.down)) }
        var left = total - parts.reduce(0, +)
        guard (0...clean.count).contains(left) else { return largestRemainder(clean, total: total) }
        let remainders = clean.indices.map { clean[$0] - Double(parts[$0]) }
        // 余数大的先多分一份；余数一样时按原来的顺序
        let order = clean.indices.sorted { a, b in
            remainders[a] != remainders[b] ? remainders[a] > remainders[b] : a < b
        }
        for i in order where left > 0 {
            parts[i] += 1
            left -= 1
        }
        return parts
    }
}
