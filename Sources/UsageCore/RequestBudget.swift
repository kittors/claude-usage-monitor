import Foundation

/// 官方用量接口的请求预算（令牌桶），跨重启保留。
///
/// 这个接口限额很紧，同一账号下的 Claude Code 等客户端共用同一份：服务器连续放行二三十次后就开始返回 429，
/// 也不说要等多久。这里把本 App 压在平均每 5 分钟 1 次以内（可以连着用几次），给其他客户端留足余量。
/// 自动查询和展开面板用完之后至少还要剩下一次，留给手动刷新。
public struct RequestBudget: Codable, Equatable, Sendable {
    public static let capacity: Double = 5
    /// 每过这么久攒回一次
    public static let refillInterval: TimeInterval = 5 * 60
    /// 自动查询、展开面板至少给手动刷新留下这么多
    public static let manualReserve: Double = 1

    public private(set) var tokens: Double
    public private(set) var updatedAt: Date

    public init(tokens: Double = RequestBudget.capacity, updatedAt: Date = .distantPast) {
        self.tokens = tokens
        self.updatedAt = updatedAt
    }

    /// 现在能用几次（含零头）
    public func available(at now: Date) -> Double {
        // 系统时间往回调时不倒扣
        let elapsed = max(0, now.timeIntervalSince(updatedAt))
        return min(Self.capacity, tokens + elapsed / Self.refillInterval)
    }

    /// 还要等多久才够发一次。自动查询、展开面板花掉一次之后，还要给手动刷新留一次。
    public func wait(manual: Bool, at now: Date) -> TimeInterval {
        let missing = (manual ? 1 : 1 + Self.manualReserve) - available(at: now)
        return missing > 1e-9 ? missing * Self.refillInterval : 0
    }

    public func allows(manual: Bool, at now: Date) -> Bool { wait(manual: manual, at: now) == 0 }

    /// 发出了一次用量请求
    public mutating func spend(at now: Date) {
        tokens = max(0, available(at: now) - 1)
        updatedAt = now
    }

    /// 服务器已经限流：这份额度眼下用完了，从零开始攒
    public mutating func drain(at now: Date) {
        tokens = 0
        updatedAt = now
    }
}
