import AppKit
import SwiftUI

// MARK: - 毛玻璃

/// 系统毛玻璃（窗口背后模糊），用与 SwiftUI 相同的连续圆角路径做遮罩。
struct GlassEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> MaskedEffectView {
        let view = MaskedEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: MaskedEffectView, context: Context) {
        view.material = material
        view.cornerRadius = cornerRadius
    }
}

final class MaskedEffectView: NSVisualEffectView {
    var cornerRadius: CGFloat = 0 {
        didSet { if oldValue != cornerRadius { updateMask() } }
    }

    /// 九宫格遮罩：只画四个角，中间拉伸。面板高度在动画里逐帧变化时不用每帧重画一张整面板大小的遮罩。
    private func updateMask() {
        guard cornerRadius > 0 else {
            maskImage = nil
            return
        }
        // 连续圆角的弧线从边上约 1.53 倍半径处开始，角上留足这么多
        let inset = ceil(cornerRadius * 1.6)
        let rect = CGRect(x: 0, y: 0, width: inset * 2 + 1, height: inset * 2 + 1)
        let path = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect).cgPath
        let image = NSImage(size: rect.size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        image.resizingMode = .stretch
        maskImage = image
    }
}

/// 弹窗背景：原生毛玻璃 + 轻微压暗 + 0.5pt 描边。
struct PanelBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.popoverCorner, style: .continuous)
        ZStack {
            shape.fill(Color.black.opacity(0.35))
                .shadow(color: .black.opacity(0.3), radius: 14, x: 0, y: 8)
            GlassEffect(material: .popover, cornerRadius: Metrics.popoverCorner)
            shape.fill(Color.black.opacity(0.22))
            shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        }
    }
}

// MARK: - 排版元素

struct SectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.sectionTitle)
                .foregroundStyle(Palette.secondary)
            Spacer(minLength: 8)
            trailing
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
        }
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: 0.5)
    }
}

// MARK: - 动画

private struct PanelVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 弹窗当前是否可见
    var panelVisible: Bool {
        get { self[PanelVisibleKey.self] }
        set { self[PanelVisibleKey.self] = newValue }
    }
}

/// 进度类组件的显示值：出现时直接落在当前值，只有数据真正变化时才平滑过渡。
struct GrowingValue: ViewModifier {
    let target: Double
    var delay: Double = 0
    /// 变化不超过它时直接跟上、不做动画（例如随时间一点点前进的安全线）
    var animatesAbove: Double = 0
    @Binding var shown: Double

    func body(content: Content) -> some View {
        content
            .onAppear { shown = target }
            .onChange(of: target) { old, new in
                if abs(new - old) <= animatesAbove {
                    shown = new
                } else {
                    withAnimation(.settle) { shown = new }
                }
            }
    }
}
