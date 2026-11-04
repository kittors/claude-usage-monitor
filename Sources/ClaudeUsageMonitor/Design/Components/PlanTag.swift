import SwiftUI

/// 套餐徽章：套餐名大写、加字距，放进小胶囊。只用 Claude 陶土色，档位越高越实：
/// Pro 细描边，Max 浅陶土底，Ultra 实心陶土底配深色字。Team、Enterprise 由组织付费，用中性的灰色胶囊。
struct PlanTag: View {
    let plan: Plan

    private static let tracking: CGFloat = 0.9

    var body: some View {
        let style = Self.style(plan)
        Text(plan.title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(Self.tracking)
            .foregroundStyle(style.text)
            // 字距也加在最后一个字母后面：右边少留这么多，字才居中
            .padding(.leading, 6)
            .padding(.trailing, 6 - Self.tracking)
            .frame(height: 16)
            .background(Capsule().fill(style.fill))
            .overlay(Capsule().strokeBorder(style.stroke, lineWidth: 1))
            .fixedSize()
    }

    struct Style {
        var fill: Color
        var stroke: Color = .clear
        var text: Color
    }

    static func style(_ plan: Plan) -> Style {
        let clay = ClaudeBrand.orange
        switch plan {
        case .pro: return Style(fill: .clear, stroke: clay.opacity(0.6), text: Color(hex: 0xE0896C))
        case .max: return Style(fill: clay.opacity(0.2), text: Color(hex: 0xE8977C))
        case .ultra: return Style(fill: clay, text: Color(hex: 0x3A1A0E))
        case .team, .enterprise: return Style(fill: Color.white.opacity(0.08), text: Palette.secondary)
        }
    }
}
