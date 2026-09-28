import SwiftUI

/// 细进度条（单色填充）
struct ThinBar: View {
    var fraction: Double
    var color: Color = Palette.accent
    var height: CGFloat = 4
    var delay: Double = 0.08

    @State private var shown: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                if fraction > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: max(height, geo.size.width * min(1, max(0, shown))))
                }
            }
        }
        .frame(height: height)
        .modifier(GrowingValue(target: fraction, delay: delay, shown: $shown))
    }
}

/// 极简柱状图：无坐标轴，悬停回传下标
struct MiniBars: View {
    var values: [Double]
    var highlightIndex: Int?
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
                    let isFocus = hovered == i || (hovered == nil && i == highlightIndex)
                    RoundedRectangle(cornerRadius: min(1.5, width / 2), style: .continuous)
                        .fill(isFocus ? Palette.accent : Color.white.opacity(0.22))
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
}
