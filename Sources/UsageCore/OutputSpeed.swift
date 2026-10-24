import Foundation

/// 一次请求从发出到回复写完。索引里按 key 去重保存，用来算输出速度
public struct RequestTiming: Sendable, Equatable {
    public var key: UInt64
    /// 请求发出（`api-request` 行的时间）
    public var start: Double
    /// 回复最后一块写完
    public var end: Double
    /// 输出 tokens，含思考
    public var output: Int64
    /// 模型表下标
    public var model: UInt16
    public var isFast: Bool
    public var isSidechain: Bool
}

/// 一次完成的请求
public struct TimedRequest: Sendable, Equatable, Identifiable {
    public var id: UInt64
    /// 模型的显示名，例如「Opus 5.5」
    public var model: String
    public var isFast: Bool
    public var start: Double
    public var end: Double
    public var output: Int
    public var isSidechain: Bool

    public init(id: UInt64, model: String, isFast: Bool = false, start: Double, end: Double, output: Int, isSidechain: Bool = false) {
        self.id = id
        self.model = model
        self.isFast = isFast
        self.start = start
        self.end = end
        self.output = output
        self.isSidechain = isSidechain
    }

    /// 生成耗时：从请求发出到回复最后一块写完，包含排队和等第一个字的时间
    public var duration: Double { end - start }
    public var rate: Double { duration > 0 ? Double(output) / duration : 0 }
}

/// 发出了、还没有回复的请求
public struct PendingRequest: Sendable, Equatable, Identifiable {
    public var id: String
    /// 模型的显示名；请求行里没写模型时为 nil
    public var model: String?
    public var start: Double

    public init(id: String, model: String?, start: Double) {
        self.id = id
        self.model = model
        self.start = start
    }
}

/// 一个模型最近 1 小时的请求。速度只在同一个模型里比较：Haiku 大约是 Opus 的两三倍，混在一起平均没有意义
public struct ModelSpeed: Sendable, Equatable, Identifiable {
    public var model: String
    public var isFast: Bool
    /// 最近 1 小时零 5 分钟完成的请求，按完成时刻排序
    public var requests: [TimedRequest]
    /// 正在等回复的请求，按发出时刻排序
    public var pending: [PendingRequest]

    public var id: String { Self.id(model, fast: isFast) }

    static func id(_ model: String, fast: Bool) -> String { fast ? model + "|fast" : model }
}

/// 输出速度的原始数据：最近完成的请求（按完成时刻排序）和正在等回复的请求
public struct SpeedLog: Sendable, Equatable {
    public var requests: [TimedRequest]
    public var pending: [PendingRequest]
    /// 最近一条没有发出时刻的回复：Claude Code 版本太旧，算不出速度
    public var lastUntimed: Double?

    public init(requests: [TimedRequest], pending: [PendingRequest], lastUntimed: Double? = nil) {
        self.requests = requests
        self.pending = pending
        self.lastUntimed = lastUntimed
    }

    public static let empty = SpeedLog(requests: [], pending: [])

    /// 按模型分开，最近 1 小时输出多的在前。超时还没回复的请求不再算作生成中。
    /// 多带上 1 小时之前的 5 分钟：图表最左边那一刻的近 5 分钟均速要用到
    public func models(now: Double) -> [ModelSpeed] {
        var groups: [String: ModelSpeed] = [:]
        let from = now - OutputSpeed.span - OutputSpeed.recent
        for r in requests[OutputSpeed.firstIndex(requests, endingAfter: from)...] where r.end <= now {
            groups[ModelSpeed.id(r.model, fast: r.isFast), default: ModelSpeed(model: r.model, isFast: r.isFast, requests: [], pending: [])]
                .requests.append(r)
        }
        // 请求行里看不出是不是快速模式，算在标准模式下
        for p in pending where p.start <= now && now - p.start < OutputSpeed.pendingLimit {
            guard let model = p.model else { continue }
            groups[ModelSpeed.id(model, fast: false), default: ModelSpeed(model: model, isFast: false, requests: [], pending: [])]
                .pending.append(p)
        }
        var ranked: [(model: ModelSpeed, output: Int)] = []
        for group in groups.values {
            var output = 0
            for r in group.requests { output += r.output }
            ranked.append((group, output))
        }
        ranked.sort { a, b in a.output != b.output ? a.output > b.output : a.model.id < b.model.id }
        return ranked.map(\.model)
    }
}

/// 输出速度 = 输出 tokens ÷ 生成耗时。生成耗时从请求发出算到回复最后一块写完，所以包含排队和等第一个字的时间。
/// 会话记录要等整条回复结束才写，拿不到生成过程中的瞬时速度
public enum OutputSpeed {
    /// 主数字看近 5 分钟
    public static let recent: TimeInterval = 300
    /// 图表和均速看最近 1 小时
    public static let span: TimeInterval = 3600
    /// 发出这么久还没有回复，不再算作生成中。一周里最慢的一次回复不到 6 分钟
    public static let pendingLimit: TimeInterval = 600

    public struct Rate: Sendable, Equatable {
        public var output: Int
        /// 各次生成耗时之和。几个会话同时在跑时会比时间段本身长
        public var duration: Double
        public var count: Int

        /// Σ 输出 ÷ Σ 耗时：按 token 加权，几十个 token 的短回复（大部分时间在等第一个字）拉低得少
        public var tokensPerSecond: Double { duration > 0 ? Double(output) / duration : 0 }
    }

    /// 完成时刻落在 (from, to] 的请求加起来的速度。requests 按完成时刻排序
    public static func rate(_ requests: [TimedRequest], from: Double, to: Double) -> Rate? {
        var output = 0, duration = 0.0, count = 0
        var i = firstIndex(requests, endingAfter: from)
        while i < requests.count, requests[i].end <= to {
            output += requests[i].output
            duration += requests[i].duration
            count += 1
            i += 1
        }
        guard count > 0, duration > 0 else { return nil }
        return Rate(output: output, duration: duration, count: count)
    }

    /// 近 5 分钟均速随时间的变化：从 from 到 to 等距取 count 个时刻，每个时刻往前看 5 分钟。窗口里没有请求时为 nil。
    /// 最后一个值就是 `to` 时刻的近 5 分钟均速，和主数字是同一个数
    public static func curve(_ requests: [TimedRequest], from: Double, to: Double, count: Int) -> [Double?] {
        guard count > 1, to > from else { return [] }
        let step = (to - from) / Double(count - 1)
        return (0..<count).map { i in
            let t = i == count - 1 ? to : from + Double(i) * step
            return rate(requests, from: t - recent, to: t)?.tokensPerSecond
        }
    }

    /// 纵轴上限：大多数点都放得下，偶尔一次特别快的贴在顶上，不把其他点压扁。取 50 的整数倍，至少 150
    public static func ceiling(_ requests: [TimedRequest]) -> Double {
        let rates = requests.map(\.rate).sorted()
        guard !rates.isEmpty else { return 150 }
        let high = rates[Int(Double(rates.count - 1) * 0.95)]
        return max(150, (high * 1.15 / 50).rounded(.up) * 50)
    }

    /// 图上唯一一条参考线：不超过上限四分之三的整数
    public static func gridline(below ceiling: Double) -> Double {
        [50.0, 100, 200, 300, 500, 1000, 2000].last { $0 <= ceiling * 0.75 } ?? 50
    }

    /// 第一个完成时刻晚于 t 的下标
    static func firstIndex(_ requests: [TimedRequest], endingAfter t: Double) -> Int {
        var lo = 0, hi = requests.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if requests[mid].end <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

public extension UsageIndex {
    /// 交给界面画输出速度：最近完成的请求和正在等回复的请求
    func speedLog() -> SpeedLog {
        var requests: [TimedRequest] = []
        requests.reserveCapacity(timings.count)
        for t in timings.values {
            let name = PricingCatalog.info(for: models[Int(t.model)]).displayName
            requests.append(TimedRequest(
                id: t.key, model: name, isFast: t.isFast,
                start: t.start, end: t.end, output: Int(t.output), isSidechain: t.isSidechain
            ))
        }
        // 顺序固定下来：内容没变时两次结果相等，界面不用重画
        requests.sort { a, b in a.end != b.end ? a.end < b.end : a.id < b.id }
        var waiting: [PendingRequest] = []
        for s in pending.values {
            waiting.append(PendingRequest(id: s.id, model: s.model.map { PricingCatalog.info(for: $0).displayName }, start: s.time))
        }
        waiting.sort { a, b in a.start != b.start ? a.start < b.start : a.id < b.id }
        return SpeedLog(requests: requests, pending: waiting, lastUntimed: lastUntimed)
    }
}
