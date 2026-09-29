import Foundation

/// 数字 / 时间的展示格式。
public enum Fmt {
    /// 中文大数：`26_000` → `2.6 万`，`5_245_583_915` → `52.46 亿`
    public static func chinese(_ value: Int64) -> String {
        let d = Double(value)
        if abs(d) >= 1e8 { return String(format: "%.2f 亿", d / 1e8) }
        if abs(d) >= 1e4 { return String(format: "%.1f 万", d / 1e4) }
        return grouped(value)
    }

    /// 紧凑英文单位：`227_600` → `227.6k`，`1_000_000` → `1M`
    public static func compact(_ value: Int64) -> String {
        let d = Double(value)
        switch abs(d) {
        case 1e9...: return trimmed(d / 1e9, digits: 2) + "B"
        case 1e6...: return trimmed(d / 1e6, digits: d >= 1e8 ? 0 : 2) + "M"
        case 1e3...: return trimmed(d / 1e3, digits: d >= 1e5 ? 1 : 1) + "k"
        default: return String(value)
        }
    }

    /// 千分位：`5245583915` → `5,245,583,915`
    public static func grouped(_ value: Int64) -> String {
        groupedFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func grouped(_ value: Int) -> String { grouped(Int64(value)) }

    public static func percent(_ fraction: Double, digits: Int = 0) -> String {
        guard fraction.isFinite else { return "–" }
        return String(format: "%.\(digits)f%%", fraction * 100)
    }

    /// 界面语言。应用启动后按系统语言或用户选择改写；测试保持中文。
    public static var localizedChinese = true

    /// 中文用万/亿，英文用 k/M/B。
    public static func magnitude(_ value: Int64) -> String {
        localizedChinese ? chinese(value) : compact(value)
    }

    /// 倒计时：`2 小时 32 分`、`18 分 05 秒`、`3 天 4 小时`
    public static func countdown(_ interval: TimeInterval, showSeconds: Bool = true) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let days = total / 86_400, hours = (total % 86_400) / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if !localizedChinese {
            if days > 0 { return "\(days)d \(hours)h" }
            if hours > 0 { return "\(hours)h \(minutes)m" }
            if showSeconds { return String(format: "%dm %02ds", minutes, seconds) }
            return "\(max(1, minutes))m"
        }
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if showSeconds { return String(format: "%d 分 %02d 秒", minutes, seconds) }
        return "\(max(1, minutes)) 分钟"
    }

    /// 相对时间：`刚刚`、`3 分钟前`、`2 小时前`
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if !localizedChinese {
            if s < 45 { return "just now" }
            if s < 3600 { return "\(max(1, s / 60))m ago" }
            if s < 86_400 { return "\(s / 3600)h ago" }
            return "\(s / 86_400)d ago"
        }
        if s < 45 { return "刚刚" }
        if s < 3600 { return "\(max(1, s / 60)) 分钟前" }
        if s < 86_400 { return "\(s / 3600) 小时前" }
        return "\(s / 86_400) 天前"
    }

    static func trimmed(_ v: Double, digits: Int) -> String {
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.maximumFractionDigits = 0
        return f
    }()
}

/// 货币展示。金额在日志里按美元计价，其它货币用「1 美元兑多少」折算。
public struct MoneyFormat: Sendable, Equatable {
    public enum Unit: String, Sendable, CaseIterable, Codable {
        case usd, cny, jpy, gbp, eur, hkd, sgd, aud, cad, chf, krw

        public var code: String { rawValue.uppercased() }

        public var title: String {
            switch self {
            case .usd: "美元"
            case .cny: "人民币"
            case .jpy: "日元"
            case .gbp: "英镑"
            case .eur: "欧元"
            case .hkd: "港币"
            case .sgd: "新加坡元"
            case .aud: "澳元"
            case .cad: "加元"
            case .chf: "瑞士法郎"
            case .krw: "韩元"
            }
        }

        /// 面板上的符号。日元不用单独的「¥」，免得和人民币混在一起。
        public var symbol: String {
            switch self {
            case .usd: "$"
            case .cny: "¥"
            case .jpy: "JP¥"
            case .gbp: "£"
            case .eur: "€"
            case .hkd: "HK$"
            case .sgd: "S$"
            case .aud: "A$"
            case .cad: "C$"
            case .chf: "CHF "
            case .krw: "₩"
            }
        }

        /// 日元、韩元没有小数。
        public var fractionDigits: Int { self == .jpy || self == .krw ? 0 : 2 }

        /// 第一次拿到牌价之前的近似值。
        public var fallbackPerUSD: Double {
            switch self {
            case .usd: 1
            case .cny: 7.1
            case .jpy: 149
            case .gbp: 0.78
            case .eur: 0.92
            case .hkd: 7.8
            case .sgd: 1.33
            case .aud: 1.52
            case .cad: 1.38
            case .chf: 0.88
            case .krw: 1_380
            }
        }
    }

    public var unit: Unit
    /// 1 美元兑多少该货币
    public var rate: Double

    public init(unit: Unit = .usd, rate: Double = 1) {
        self.unit = unit
        self.rate = rate
    }

    public var symbol: String { unit.symbol }

    public func convert(_ usd: Double) -> Double { usd * rate }

    /// `$1,680.44`；金额 ≥ 10000 时省略小数
    public func string(_ usd: Double) -> String {
        let v = convert(usd)
        return symbol + number(v)
    }

    /// 仅数字部分
    public func number(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        let digits = unit.fractionDigits == 0 ? 0 : (abs(value) >= 10_000 ? 0 : 2)
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// 紧凑：`$1.7k`
    public func compact(_ usd: Double) -> String {
        let v = convert(usd)
        switch abs(v) {
        case 1e6...: return symbol + Fmt.trimmed(v / 1e6, digits: 2) + "M"
        case 1e4...: return symbol + Fmt.trimmed(v / 1e3, digits: 1) + "k"
        default: return whole(usd)
        }
    }

    /// 整数金额：`$5,300`；不足 100 时保留两位小数
    public func whole(_ usd: Double) -> String {
        let v = convert(usd)
        if unit.fractionDigits == 0 || abs(v) >= 100 { return symbol + Fmt.grouped(Int64(v.rounded())) }
        return symbol + String(format: "%.2f", v)
    }
}

/// 欧洲央行经 Frankfurter 公布的牌价：`GET https://api.frankfurter.app/latest?from=USD`
public enum FXRates {
    public static func perUSD(fromFrankfurter data: Data) throws -> [String: Double] {
        struct Raw: Decodable {
            let base: String
            let rates: [String: Double]
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard raw.base == "USD" else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "expected USD base"))
        }
        var rates = raw.rates
        rates["USD"] = 1
        return rates
    }
}
