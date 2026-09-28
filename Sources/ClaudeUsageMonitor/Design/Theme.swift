import SwiftUI
import UsageCore

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// 极简配色：灰阶建立层级，唯一的强调色（Claude 陶土橙）只用于进度填充。
enum Palette {
    static let accent = Color(hex: 0xD97757)

    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.38)
    static let quaternary = Color.white.opacity(0.2)

    static let track = Color.white.opacity(0.09)
    static let divider = Color.white.opacity(0.08)
    static let hover = Color.white.opacity(0.055)

    static let warning = Color(hex: 0xE3A24B)
    static let critical = Color(hex: 0xE5584F)
    static let live = Color(hex: 0x6CC08B)

    // Token 类别：一个色相 + 中性灰，低饱和
    static let cacheRead = accent
    static let cacheWrite = accent.opacity(0.5)
    static let input = Color.white.opacity(0.62)
    static let output = Color.white.opacity(0.32)

    /// 进度填充色：正常用强调色，超过预警阈值变琥珀，接近上限变红
    static func level(_ fraction: Double, warning threshold: Double = 0.8) -> Color {
        if fraction >= 0.95 { return critical }
        if fraction >= threshold { return warning }
        return accent
    }
}

enum Metrics {
    static let popoverWidth: CGFloat = 356
    static let popoverCorner: CGFloat = 14
    static let shadowInset: CGFloat = 20
    static let padding: CGFloat = 16
}

extension Font {
    /// 区块标题
    static let sectionTitle = Font.system(size: 11.5, weight: .medium)
    /// 行标签
    static let rowLabel = Font.system(size: 12.5, weight: .regular)
    /// 行数值
    static let rowValue = Font.system(size: 12.5, weight: .medium)
    /// 说明文字
    static let caption = Font.system(size: 10.5, weight: .regular)
}

extension Animation {
    static let quiet = Animation.easeOut(duration: 0.18)
    static let settle = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.7)
}
