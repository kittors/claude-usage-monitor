import Foundation

/// 官方用量接口的请求预算（令牌桶），跨重启保留。
///
/// 这个接口的额度是整个账号共用的：Claude Code 的 `/usage`、桌面版里的 Claude Code 都算在里面。
/// 服务器能连着放行十几次，之后回补得很慢：1.7.1 平均约 11 分钟查一次（最密时 7 分钟一次），5.7 小时后被限流，
/// 之后 40 分钟里的重试全部被拒，而且不说要等多久（`Retry-After: 0`）。按那天的记录推算，每小时只回补 3 次左右。所以：
/// - 平时把本 App 压在平均每 20 分钟 1 次以内（每小时 3 次；闲置之后可以连着用几次），给其他客户端留足余量；
/// - 被限流后先停一段时间（15 分钟起，冷却期间又被拒就翻倍，最长 1 小时），之后攒得更慢：每次限流放慢一倍，
///   最多 4 倍；没有再被限流时，放慢的部分每 6 小时恢复一半；
/// - 自动查询和展开面板用完之后至少还要剩下一次，留给手动刷新。
public struct RequestBudget: Equatable, Sendable {
    public static let capacity: Double = 5
    /// 平时每过这么久攒回一次
    public static let refillInterval: TimeInterval = 20 * 60
    /// 自动查询、展开面板至少给手动刷新留下这么多
    public static let manualReserve: Double = 1
    /// 被限流后先停这么久；冷却期间又被拒就翻倍，最长 `longestCooldown`
    public static let firstCooldown: TimeInterval = 15 * 60
    public static let longestCooldown: TimeInterval = 60 * 60
    /// 每次限流，攒回一次的间隔放慢一倍，最多慢到这么多倍
    public static let maximumSlowdown: Double = 4
    /// 没有再被限流时，放慢的部分每过这么久恢复一半
    public static let recoveryHalfLife: TimeInterval = 6 * 3600

    public private(set) var tokens: Double
    public private(set) var updatedAt: Date
    /// 被限流后，直到这个时间都不再请求
    public private(set) var blockedUntil: Date
    /// 连着被限流的次数，成功一次就清零
    public private(set) var streak: Int
    /// 最近一次被限流时，攒回一次的间隔放慢到了几倍，以及那一刻
    private var slowdown: Double
    private var slowedAt: Date

    public init(tokens: Double = RequestBudget.capacity, updatedAt: Date = .distantPast) {
        self.tokens = tokens
        self.updatedAt = updatedAt
        blockedUntil = .distantPast
        streak = 0
        slowdown = 1
        slowedAt = .distantPast
    }

    /// 现在放慢到几倍：放慢的部分按半衰期慢慢恢复
    public func slowdown(at now: Date) -> Double {
        guard slowdown > 1 else { return 1 }
        // 系统时间往回调时不算恢复
        let elapsed = max(0, now.timeIntervalSince(slowedAt))
        return 1 + (slowdown - 1) * pow(0.5, elapsed / Self.recoveryHalfLife)
    }

    /// 现在每过多久攒回一次
    public func interval(at now: Date) -> TimeInterval { Self.refillInterval * slowdown(at: now) }

    /// 现在能用几次（含零头）。上次用掉之后，按那时的速度攒
    public func available(at now: Date) -> Double {
        // 系统时间往回调时不倒扣
        let elapsed = max(0, now.timeIntervalSince(updatedAt))
        return min(Self.capacity, tokens + elapsed / interval(at: updatedAt))
    }

    /// 被限流之后还要停多久（系统时间往回调时也不会停得比最长冷却更久）
    public func cooldown(at now: Date) -> TimeInterval {
        min(Self.longestCooldown, max(0, blockedUntil.timeIntervalSince(now)))
    }

    /// 还要等多久才能发一次：被限流后的冷却，以及攒够次数。自动查询、展开面板花掉一次之后，还要给手动刷新留一次。
    public func wait(manual: Bool, at now: Date) -> TimeInterval {
        let missing = (manual ? 1 : 1 + Self.manualReserve) - available(at: now)
        let refill = missing > 1e-9 ? missing * interval(at: updatedAt) : 0
        return max(cooldown(at: now), refill)
    }

    public func allows(manual: Bool, at now: Date) -> Bool { wait(manual: manual, at: now) == 0 }

    /// 发出了一次用量请求
    public mutating func spend(at now: Date) {
        tokens = max(0, available(at: now) - 1)
        updatedAt = now
    }

    /// 请求成功了：不再算作连着被限流
    public mutating func succeeded() {
        streak = 0
    }

    /// 服务器限流了：这份额度眼下用完了。先停一段时间，之后更慢地攒。
    /// 剩下的次数最多留一次：冷却一过就能手动再试，自动查询要等攒回一次。
    /// - Parameter retryAfter: 服务器要求等的秒数。没给或为 0 时按冷却时间算，最多也只等最长冷却
    public mutating func rateLimited(retryAfter: TimeInterval?, at now: Date) {
        let left = min(available(at: now), Self.manualReserve)
        streak += 1
        let cooldown = min(Self.longestCooldown, Self.firstCooldown * pow(2, Double(streak - 1)))
        let asked = min(Self.longestCooldown, max(0, retryAfter ?? 0))
        blockedUntil = now.addingTimeInterval(max(cooldown, asked))
        // 一次限流只放慢一次：冷却期间又被拒，说明额度还没恢复，不说明平时查得太勤
        if streak == 1 {
            slowdown = min(Self.maximumSlowdown, slowdown(at: now) * 2)
            slowedAt = now
        }
        tokens = left
        updatedAt = now
    }
}

// 1.7.1 及以前只存了 tokens 和 updatedAt，其余各项读不到时按没有被限流过算
extension RequestBudget: Codable {
    private enum CodingKeys: String, CodingKey {
        case tokens, updatedAt, blockedUntil, streak, slowdown, slowedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tokens: try c.decode(Double.self, forKey: .tokens), updatedAt: try c.decode(Date.self, forKey: .updatedAt))
        blockedUntil = try c.decodeIfPresent(Date.self, forKey: .blockedUntil) ?? .distantPast
        streak = max(0, try c.decodeIfPresent(Int.self, forKey: .streak) ?? 0)
        let factor = try c.decodeIfPresent(Double.self, forKey: .slowdown) ?? 1
        slowdown = factor.isFinite ? min(Self.maximumSlowdown, max(1, factor)) : 1
        slowedAt = try c.decodeIfPresent(Date.self, forKey: .slowedAt) ?? .distantPast
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tokens, forKey: .tokens)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(blockedUntil, forKey: .blockedUntil)
        try c.encode(streak, forKey: .streak)
        try c.encode(slowdown, forKey: .slowdown)
        try c.encode(slowedAt, forKey: .slowedAt)
    }
}
