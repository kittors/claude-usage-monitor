import Foundation

/// 模型族。每周限额的「专用模型」分项按族统计。
public enum ModelFamily: String, CaseIterable, Sendable, Codable, Comparable {
    case fable, mythos, opus, sonnet, haiku, other

    public var displayName: String {
        switch self {
        case .fable: "Fable"
        case .mythos: "Mythos"
        case .opus: "Opus"
        case .sonnet: "Sonnet"
        case .haiku: "Haiku"
        case .other: "Other"
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 99 }
    public static func < (lhs: ModelFamily, rhs: ModelFamily) -> Bool { lhs.order < rhs.order }
}

/// 每百万 token 的美元单价。
public struct ModelPrice: Hashable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double
    /// `usage.speed == "fast"` 时的整体价格倍数
    public var fastMultiplier: Double

    /// 缓存写入按官方倍率推导：5 分钟 TTL = 1.25×，1 小时 TTL = 2×；
    /// 缓存读取默认 0.1×，个别模型（Fable 5.1、Opus 5.5）有单独定价。
    public init(input: Double, output: Double, cacheRead: Double? = nil, fastMultiplier: Double = 2) {
        self.input = input
        self.output = output
        self.cacheWrite5m = input * 1.25
        self.cacheWrite1h = input * 2
        self.cacheRead = cacheRead ?? input * 0.1
        self.fastMultiplier = fastMultiplier
    }

    public func cost(_ t: TokenCounts, fast: Bool = false) -> Double {
        let micro = Double(t.input) * input
            + Double(t.output) * output
            + Double(t.cacheWrite5m) * cacheWrite5m
            + Double(t.cacheWrite1h) * cacheWrite1h
            + Double(t.cacheRead) * cacheRead
        return micro / 1_000_000 * (fast ? fastMultiplier : 1)
    }
}

/// 解析后的模型信息。
public struct ModelInfo: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let family: ModelFamily
    /// nil 表示未知模型（不计费）
    public let price: ModelPrice?
    /// 定价是否按族回退估算（精确型号不在价目表中）
    public let isEstimated: Bool
    public let contextWindow: Int
}

/// 官方 API 价目表（USD / 百万 token，数据截至 2026-06）。
public enum PricingCatalog {
    /// 每次 Web Search 服务端工具调用的费用（$10 / 1000 次）
    public static let webSearchCost = 0.01

    private struct Entry {
        let prefix: String
        let price: ModelPrice
        let context: Int
    }

    private static let entries: [Entry] = [
        Entry(prefix: "claude-fable-5-1", price: ModelPrice(input: 10, output: 50, cacheRead: 0.25), context: 1_000_000),
        Entry(prefix: "claude-mythos-5-1", price: ModelPrice(input: 10, output: 50, cacheRead: 0.25), context: 1_000_000),
        Entry(prefix: "claude-fable-5", price: ModelPrice(input: 10, output: 50), context: 1_000_000),
        Entry(prefix: "claude-mythos-5", price: ModelPrice(input: 10, output: 50), context: 1_000_000),
        Entry(prefix: "claude-opus-5-5", price: ModelPrice(input: 4, output: 20, cacheRead: 0.20), context: 1_000_000),
        Entry(prefix: "claude-opus-5", price: ModelPrice(input: 5, output: 25), context: 1_000_000),
        Entry(prefix: "claude-opus-4-8", price: ModelPrice(input: 5, output: 25), context: 1_000_000),
        Entry(prefix: "claude-opus-4-7", price: ModelPrice(input: 5, output: 25), context: 1_000_000),
        Entry(prefix: "claude-opus-4-6", price: ModelPrice(input: 5, output: 25, fastMultiplier: 6), context: 1_000_000),
        Entry(prefix: "claude-opus-4-5", price: ModelPrice(input: 5, output: 25), context: 200_000),
        Entry(prefix: "claude-opus-4-1", price: ModelPrice(input: 15, output: 75), context: 200_000),
        Entry(prefix: "claude-opus-4", price: ModelPrice(input: 15, output: 75), context: 200_000),
        Entry(prefix: "claude-sonnet-5", price: ModelPrice(input: 2, output: 10), context: 1_000_000),
        Entry(prefix: "claude-sonnet-4-6", price: ModelPrice(input: 3, output: 15), context: 1_000_000),
        Entry(prefix: "claude-sonnet-4-5", price: ModelPrice(input: 3, output: 15), context: 200_000),
        Entry(prefix: "claude-sonnet-4", price: ModelPrice(input: 3, output: 15), context: 200_000),
        Entry(prefix: "claude-3-7-sonnet", price: ModelPrice(input: 3, output: 15), context: 200_000),
        Entry(prefix: "claude-3-5-sonnet", price: ModelPrice(input: 3, output: 15), context: 200_000),
        Entry(prefix: "claude-haiku-4-5", price: ModelPrice(input: 1, output: 5), context: 200_000),
        Entry(prefix: "claude-3-5-haiku", price: ModelPrice(input: 0.8, output: 4), context: 200_000),
        Entry(prefix: "claude-3-haiku", price: ModelPrice(input: 0.25, output: 1.25), context: 200_000),
        Entry(prefix: "claude-3-opus", price: ModelPrice(input: 15, output: 75), context: 200_000),
    ].sorted { $0.prefix.count > $1.prefix.count }

    /// 找不到精确型号时，按族回退到当前代的价格。
    private static let familyFallback: [ModelFamily: Entry] = [
        .fable: entries.first { $0.prefix == "claude-fable-5-1" }!,
        .mythos: entries.first { $0.prefix == "claude-mythos-5-1" }!,
        .opus: entries.first { $0.prefix == "claude-opus-5" }!,
        .sonnet: entries.first { $0.prefix == "claude-sonnet-5" }!,
        .haiku: entries.first { $0.prefix == "claude-haiku-4-5" }!,
    ]

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: ModelInfo] = [:]

    public static func info(for rawID: String) -> ModelInfo {
        cacheLock.lock()
        if let hit = cache[rawID] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let info = resolve(rawID)
        cacheLock.lock()
        cache[rawID] = info
        cacheLock.unlock()
        return info
    }

    private static func resolve(_ rawID: String) -> ModelInfo {
        let id = normalize(rawID)
        let wantsLongContext = rawID.lowercased().contains("[1m]")
        let family = family(of: id)
        let name = displayName(for: id, family: family)

        if let entry = entries.first(where: { matches(id, prefix: $0.prefix) }) {
            return ModelInfo(
                id: rawID, displayName: name, family: family, price: entry.price, isEstimated: false,
                contextWindow: wantsLongContext ? max(entry.context, 1_000_000) : entry.context
            )
        }
        if let entry = familyFallback[family] {
            return ModelInfo(
                id: rawID, displayName: name, family: family, price: entry.price, isEstimated: true,
                contextWindow: wantsLongContext ? 1_000_000 : entry.context
            )
        }
        return ModelInfo(id: rawID, displayName: name, family: .other, price: nil, isEstimated: true, contextWindow: 200_000)
    }

    /// 去掉供应商前缀（`us.anthropic.`）、`[1m]` 与 `@日期` 后缀，统一小写。
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()
        if let r = s.range(of: "claude-") { s = String(s[r.lowerBound...]) }
        if let r = s.firstIndex(where: { $0 == "[" || $0 == "@" || $0 == ":" }) { s = String(s[..<r]) }
        return s
    }

    private static func matches(_ id: String, prefix: String) -> Bool {
        guard id.hasPrefix(prefix) else { return false }
        let rest = id.dropFirst(prefix.count)
        return rest.isEmpty || rest.hasPrefix("-")
    }

    static func family(of id: String) -> ModelFamily {
        for family in [ModelFamily.fable, .mythos, .opus, .sonnet, .haiku] where id.contains(family.rawValue) {
            return family
        }
        return .other
    }

    /// `claude-opus-5-5` → `Opus 5.5`，`claude-3-5-sonnet-20241022` → `Sonnet 3.5`
    static func displayName(for id: String, family: ModelFamily) -> String {
        guard id.hasPrefix("claude-") else { return id }
        let parts = id.dropFirst("claude-".count).split(separator: "-")
        var version: [Substring] = []
        var name: Substring?
        for part in parts {
            if part.allSatisfy(\.isNumber) {
                if part.count <= 2 { version.append(part) }  // 8 位的日期后缀直接丢弃
            } else if name == nil {
                name = part
            }
        }
        let title = name.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? family.displayName
        return version.isEmpty ? title : "\(title) \(version.joined(separator: "."))"
    }
}
