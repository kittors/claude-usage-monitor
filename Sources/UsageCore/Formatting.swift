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

    /// 倒计时：`2 小时 32 分`、`18 分 05 秒`、`3 天 4 小时`
    public static func countdown(_ interval: TimeInterval, showSeconds: Bool = true) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let days = total / 86_400, hours = (total % 86_400) / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if showSeconds { return String(format: "%d 分 %02d 秒", minutes, seconds) }
        return "\(max(1, minutes)) 分钟"
    }

    /// 相对时间：`刚刚`、`3 分钟前`、`2 小时前`
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
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

/// 货币展示（美元 / 按汇率折算人民币）。
public struct MoneyFormat: Sendable, Equatable {
    public enum Unit: String, Sendable, CaseIterable, Codable {
        case usd, cny
        public var symbol: String { self == .usd ? "$" : "¥" }
        public var code: String { self == .usd ? "USD" : "CNY" }
    }

    public var unit: Unit
    /// 1 美元兑人民币
    public var rate: Double

    public init(unit: Unit = .usd, rate: Double = 7.1) {
        self.unit = unit
        self.rate = rate
    }

    public var symbol: String { unit.symbol }

    public func convert(_ usd: Double) -> Double { unit == .usd ? usd : usd * rate }

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
        let digits = abs(value) >= 10_000 ? 0 : 2
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
        guard abs(v) >= 100 else { return symbol + String(format: "%.2f", v) }
        return symbol + Fmt.grouped(Int64(v.rounded()))
    }
}
