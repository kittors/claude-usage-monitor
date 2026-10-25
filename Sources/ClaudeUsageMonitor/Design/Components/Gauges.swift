import SwiftUI

/// 细进度条（单色填充）。可以带一条安全线：用量超过它时，线右边那一段换成警示色；
/// 指针停在进度条上时提亮安全区，并告诉外面，由外面在下方那一行写出安全线是多少。
/// 说明不浮在进度条上方：那里是上一行的标题，浮层会盖住它。
struct ThinBar: View {
    var fraction: Double
    var color: Color = Palette.accent
    var height: CGFloat = 4
    var delay: Double = 0.08
    /// 安全线的位置（0…1），nil 时不画
    var mark: Double?
    /// 用量超过了安全线
    var exceeded = false
    /// 指针移进、移出进度条。设置了才在悬停时提亮安全区
    var onPoint: ((Bool) -> Void)?

    @State private var shown: Double = 0
    @State private var shownMark: Double = 0
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fillWidth = max(height, width * min(1, max(0, shown)))
            let markX = width * min(1, max(0, shownMark))
            let pointed = hovering && mark != nil && onPoint != nil
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
        }
        .frame(height: height)
        // 悬停区域比进度条高一些，不用对准那根细线
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.quiet) { hovering = inside }
            onPoint?(inside)
        }
        .padding(.vertical, -6)
        .modifier(GrowingValue(target: fraction, delay: delay, shown: $shown))
        // 安全线随时间一点点前进时直接跟上；跳一格（例如每周进入新的一天）才做动画
        .modifier(GrowingValue(target: mark ?? 0, animatesAbove: 0.002, shown: $shownMark))
        .animation(.quiet, value: exceeded)
        .animation(.quiet, value: mark == nil)
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
