import Foundation

/// 用量占用的颜色档。从低到高：绿、黄绿、琥珀、橙、红。
public enum UsageTone: Sendable, Equatable {
    case calm, steady, warm, high, critical

    public static func tone(for fraction: Double) -> UsageTone {
        switch min(1, max(0, fraction)) {
        case ..<0.25: .calm
        case ..<0.50: .steady
        case ..<0.75: .warm
        case ..<0.90: .high
        default: .critical
        }
    }

    /// sRGB，0xRRGGBB
    public var hex: UInt32 {
        switch self {
        case .calm: 0x6CC08B
        case .steady: 0xC5C56A
        case .warm: 0xE3A24B
        case .high: 0xE07A3C
        case .critical: 0xE5584F
        }
    }

    public var components: (red: Double, green: Double, blue: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}
