import Foundation

/// 一组按计费类别拆分的 token 计数。
public struct TokenCounts: Hashable, Sendable, Codable {
    /// 新增（未命中缓存）输入
    public var input: Int64
    /// 输出（含 thinking）
    public var output: Int64
    /// 缓存写入 · 5 分钟 TTL（1.25× 输入价）
    public var cacheWrite5m: Int64
    /// 缓存写入 · 1 小时 TTL（2× 输入价）
    public var cacheWrite1h: Int64
    /// 缓存读取 / 命中
    public var cacheRead: Int64

    public init(input: Int64 = 0, output: Int64 = 0, cacheWrite5m: Int64 = 0, cacheWrite1h: Int64 = 0, cacheRead: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    public static let zero = TokenCounts()

    /// 缓存写入合计
    public var cacheWrite: Int64 { cacheWrite5m + cacheWrite1h }
    /// 输入侧总量（新增输入 + 缓存写入 + 缓存读取），也就是单次请求的上下文长度
    public var prompt: Int64 { input + cacheWrite + cacheRead }
    /// 全部 token
    public var total: Int64 { prompt + output }
    /// 缓存命中率 = 缓存读取 / 输入侧总量
    public var cacheHitRate: Double { prompt > 0 ? Double(cacheRead) / Double(prompt) : 0 }
    public var isEmpty: Bool { total == 0 }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }
}
