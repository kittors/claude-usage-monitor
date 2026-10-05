import SwiftUI

/// 悬停在进度条上时，安全线上方的小标签
struct BarMarkLabel: Equatable {
    /// 主文字，例如「安全线 28.6%」
    var value: String
    /// 补充，例如「还可用 2.6%」「超出 11%」
    var detail: String?
    /// 补充用警示色
    var alert = false
}

/// 细进度条（单色填充）。可以带一条安全线：用量超过它时，线右边那一段换成警示色；
/// 指针停在进度条上时，提亮安全区，并在安全线上方显示它是多少。
struct ThinBar: View {
    var fraction: Double
    var color: Color = Palette.accent
    var height: CGFloat = 4
    var delay: Double = 0.08
    /// 安全线的位置（0…1），nil 时不画
    var mark: Double?
    /// 用量超过了安全线
    var exceeded = false
    /// 悬停时在安全线上方显示的标签
    var markLabel: BarMarkLabel?

    @State private var shown: Double = 0
    @State private var shownMark: Double = 0
    @State private var hovering = false
    @State private var labelSize = CGSize.zero

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fillWidth = max(height, width * min(1, max(0, shown)))
            let markX = width * min(1, max(0, shownMark))
            let pointed = hovering && mark != nil && markLabel != nil
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                // 安全区：从 0 到安全线，悬停时提亮
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: max(height, markX))
                    .opacity(pointed ? 1 : 0)
                if fraction > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: fillWidth)
                    // 超线的那一段：同一个胶囊，只露出安全线右边
                    Capsule()
                        .fill(Palette.critical)
                        .frame(width: fillWidth)
                        .mask(alignment: .leading) {
                            HStack(spacing: 0) {
                                Color.clear.frame(width: min(markX, fillWidth))
                                Color.black
                            }
                        }
                        .opacity(exceeded ? 1 : 0)
                }
            }
            .frame(width: width, height: height)
            // 安全线比进度条上下各长一点，画在浮层里，不影响布局
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Palette.text)
                    .frame(width: 1.5, height: height + (pointed ? 8 : 4))
                    .offset(x: markX - 0.75)
                    .opacity(mark == nil ? 0 : 1)
            }
            // 标签在安全线正上方；靠近两端时往里收，不出进度条的范围
            .overlay(alignment: .topLeading) {
                if let markLabel, mark != nil {
                    label(markLabel)
                        .background {
                            GeometryReader { Color.clear.preference(key: BarLabelSize.self, value: $0.size) }
                        }
                        .offset(
                            x: min(max(markX - labelSize.width / 2, 0), max(0, width - labelSize.width)),
                            y: -labelSize.height - (pointed ? 7 : 4)
                        )
                        .opacity(pointed ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: height)
        .onPreferenceChange(BarLabelSize.self) { labelSize = $0 }
        // 悬停区域比进度条高一些，不用对准那根细线
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.quiet) { hovering = inside }
        }
        .padding(.vertical, -6)
        .modifier(GrowingValue(target: fraction, delay: delay, shown: $shown))
        // 安全线随时间一点点前进时直接跟上；跳一格（例如每周进入新的一天）才做动画
        .modifier(GrowingValue(target: mark ?? 0, animatesAbove: 0.002, shown: $shownMark))
        .animation(.quiet, value: exceeded)
        .animation(.quiet, value: mark == nil)
    }

    private func label(_ label: BarMarkLabel) -> some View {
        HStack(spacing: 5) {
            Text(label.value)
                .foregroundStyle(Palette.text)
            if let detail = label.detail {
                Text(detail)
                    .foregroundStyle(label.alert ? Palette.critical : Palette.secondary)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .monospacedDigit()
        .contentTransition(.numericText())
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(white: 0.16).opacity(0.96))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
        }
    }
}

/// 安全线标签量出来的尺寸。没有标签的部分传上来的是默认的零，不能把量到的值盖掉。
private struct BarLabelSize: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 极简柱状图：无坐标轴，悬停回传下标
struct MiniBars: View {
    var values: [Double]
    var highlightIndex: Int?
    /// 从这一根起属于当前选中的周期，比周期外的亮一些
    var periodStart: Int?
    @Binding var hovered: Int?

    @State private var shown: Double = 0

    var body: some View {
        GeometryReader { geo in
            let n = max(1, values.count)
            let spacing: CGFloat = 2
            let width = max(1, (geo.size.width - spacing * CGFloat(n - 1)) / CGFloat(n))
            let maxValue = max(values.max() ?? 0, 0.0001)
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(values.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: min(1.5, width / 2), style: .continuous)
                        .fill(barColor(i))
                        .frame(width: width, height: max(1.5, geo.size.height * values[i] / maxValue * shown))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let i = min(n - 1, max(0, Int(p.x / (width + spacing))))
                    if hovered != i { hovered = i }
                case .ended:
                    hovered = nil
                }
            }
        }
        .modifier(GrowingValue(target: 1, delay: 0.12, shown: $shown))
    }

    /// 指针所在（没有时是今天）用强调色；当前周期里的天比周期外的亮一些
    private func barColor(_ i: Int) -> Color {
        if hovered == i || (hovered == nil && i == highlightIndex) { return Palette.accent }
        let inPeriod = periodStart.map { i >= $0 } ?? true
        return Color.white.opacity(inPeriod ? 0.34 : 0.14)
    }
}
