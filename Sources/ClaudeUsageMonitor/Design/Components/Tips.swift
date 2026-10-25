import SwiftUI

// MARK: - 悬停说明

/// 指针停在面板里某一处时浮起的说明：一个标题、几行「名称 数值」和一段补充，三样都可以没有。
/// 面板是不抢焦点的浮层，App 不在前台时系统的 `.help` 不弹，弹出来也要等一两秒，所以面板里的说明都用这个
struct Tip: Equatable {
    var title: String?
    var rows: [Row] = []
    var note: String?

    struct Row: Equatable {
        var label: String
        var value: String
        /// 数值的颜色，默认是正文色
        var color: Color?
        /// 名称前面的小圆点，例如 token 类别的颜色
        var dot: Color?
        /// 和上一行之间多空一点，分成两组
        var separated = false

        init(_ label: String, _ value: String, color: Color? = nil, dot: Color? = nil, separated: Bool = false) {
            self.label = label
            self.value = value
            self.color = color
            self.dot = dot
            self.separated = separated
        }
    }

    init(title: String? = nil, rows: [Row] = [], note: String? = nil) {
        self.title = title
        self.rows = rows
        self.note = note
    }

    /// 只有一句话
    init(_ note: String) {
        self.note = note
    }

    var isEmpty: Bool { title == nil && rows.isEmpty && note?.isEmpty != false }

    /// 读屏用：标题、每行「名称 数值」和补充连成一段
    var plainText: String {
        var parts: [String] = []
        if let title { parts.append(title) }
        for row in rows { parts.append("\(row.label) \(row.value)") }
        if let note { parts.append(note) }
        return parts.joined(separator: "\n")
    }
}

extension View {
    /// 指针停在这里时浮起说明。`id` 在面板里不能重复；内容只在说明显示时才计算，跟着数据实时更新
    func tip(_ id: String, _ make: @escaping () -> Tip?) -> some View {
        modifier(TipTarget(id: id, make: make))
    }
}

/// 面板里同一时刻只浮起一条说明。指针停 0.2 秒才出来，划过时不会一路闪；
/// 已经有说明（或刚收起）时移到另一处，直接换过去，不用再等
@MainActor
@Observable
final class TipCenter {
    /// 正在显示的那一处
    private(set) var shown: String?
    @ObservationIgnored private var hovered: String?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var hiddenAt = Date.distantPast
    /// 面板在屏幕上。收起后还要淡出一会儿才真正拿走，这段时间里指针划过也不理会
    @ObservationIgnored private var active = false

    private static let delay = Duration.milliseconds(200)
    /// 说明收起后这么久之内，移到另一处直接显示
    private static let warm: TimeInterval = 0.6

    /// 面板显示、收起时调用。两次都清掉状态：收起后指针离开的事件不会再来，下次打开不能还留着上次的说明
    func setActive(_ active: Bool) {
        self.active = active
        reset()
    }

    func enter(_ id: String) {
        guard active else { return }
        hovered = id
        pending?.cancel()
        pending = nil
        guard shown != id else { return }
        if shown != nil || Date().timeIntervalSince(hiddenAt) < Self.warm {
            show(id)
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            self?.show(id)
        }
    }

    /// 指针离开。先进了另一处、后收到这一处的离开时，不能把新的说明收掉
    func exit(_ id: String) {
        guard hovered == id else { return }
        hovered = nil
        pending?.cancel()
        pending = nil
        if shown == id { hide() }
    }

    private func reset() {
        hovered = nil
        pending?.cancel()
        pending = nil
        // 已经没有说明时不再写一次：每写一次，面板里每一处的说明都要重新看一遍
        if shown != nil { shown = nil }
        hiddenAt = .distantPast
    }

    private func show(_ id: String) {
        guard active, hovered == id else { return }
        withAnimation(.easeOut(duration: 0.12)) { shown = id }
    }

    private func hide() {
        withAnimation(.easeOut(duration: 0.1)) { shown = nil }
        hiddenAt = Date()
    }
}

private struct TipTarget: ViewModifier {
    let id: String
    let make: () -> Tip?
    /// 设置窗口等没有说明层的地方为 nil，什么也不做
    @Environment(TipCenter.self) private var center: TipCenter?

    func body(content: Content) -> some View {
        // 只有正在显示的那一处才去算内容
        let tip = center?.shown == id ? make() : nil
        content
            .onHover { inside in
                guard let center else { return }
                if inside {
                    // 这一处暂时没有可说的就不占用，否则移到旁边时会被当成已经有说明浮着，直接弹出来
                    guard let tip = make(), !tip.isEmpty else { return }
                    center.enter(id)
                } else {
                    center.exit(id)
                }
            }
            // 收起、换成说明、数据变了不再显示时，指针离开的事件不会来
            .onDisappear { center?.exit(id) }
            .anchorPreference(key: TipKey.self, value: .bounds) { anchor in
                guard let tip, !tip.isEmpty else { return nil }
                return TipItem(id: id, anchor: anchor, tip: tip)
            }
    }
}

struct TipItem: Equatable {
    let id: String
    let anchor: Anchor<CGRect>
    let tip: Tip
}

struct TipKey: PreferenceKey {
    static var defaultValue: TipItem? { nil }

    static func reduce(value: inout TipItem?, nextValue: () -> TipItem?) {
        if let next = nextValue() { value = next }
    }
}

/// 浮在面板最上层的说明。不接收指针，指针可以穿过它移到下面的内容上
struct TipLayer: View {
    let item: TipItem?

    var body: some View {
        GeometryReader { proxy in
            if let item {
                TipPlacement(target: proxy[item.anchor]) {
                    TipBubble(tip: item.tip)
                }
                // 换到另一处时是新的一块：旧的原地淡出，新的在新位置淡入，不会从一处滑到另一处
                .id(item.id)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 说明放在目标下方、水平居中，下方放不下就放上方，左右不超出面板。
/// 面板很矮、上下都放不下时，先加宽让它矮一些，再放在空的多的一边
private struct TipPlacement: Layout {
    let target: CGRect

    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 8
    private static let maxWidth: CGFloat = 252

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let target = target.offsetBy(dx: bounds.minX, dy: bounds.minY)
        let widest = (bounds.width - Self.margin * 2).rounded(.down)
        // 短的说明按内容收窄，长的到最大宽度后换行
        var width = min(Self.maxWidth, widest, bubble.sizeThatFits(.unspecified).width.rounded(.up))
        var height = bubble.sizeThatFits(ProposedViewSize(width: width, height: nil)).height.rounded(.up)
        let roomBelow = bounds.maxY - Self.margin - (target.maxY + Self.gap)
        let roomAbove = target.minY - Self.gap - (bounds.minY + Self.margin)
        // 上下都放不下（面板很矮）：先用满面板的宽度，让它矮一些
        if height > max(roomBelow, roomAbove), width < widest {
            width = widest
            height = bubble.sizeThatFits(ProposedViewSize(width: width, height: nil)).height.rounded(.up)
        }
        let y: CGFloat
        if height <= roomBelow {
            y = target.maxY + Self.gap
        } else if height <= roomAbove {
            y = target.minY - Self.gap - height
        } else if roomBelow >= roomAbove {
            // 还是放不下：放在空的多的一边，尽量不超出面板
            y = max(bounds.minY + Self.margin, bounds.maxY - Self.margin - height)
        } else {
            y = bounds.minY + Self.margin
        }
        let x = min(max(target.midX - width / 2, bounds.minX + Self.margin), bounds.maxX - Self.margin - width)
        bubble.place(at: CGPoint(x: x.rounded(), y: y.rounded()), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: height))
    }
}

private struct TipBubble: View {
    let tip: Tip

    var body: some View {
        // 只有一句话时，这句话就是正文
        let lone = tip.title == nil && tip.rows.isEmpty
        VStack(alignment: .leading, spacing: 6) {
            if let title = tip.title {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !tip.rows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(tip.rows.indices, id: \.self) { i in
                        row(tip.rows[i])
                            .padding(.top, i > 0 && tip.rows[i].separated ? 5 : 0)
                    }
                }
            }
            if let note = tip.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: lone ? 11 : 10.5))
                    .foregroundStyle(lone ? Palette.text : Palette.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            shape
                .fill(Color(white: 0.11).opacity(0.97))
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 3)
            shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        }
    }

    private func row(_ row: Tip.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(spacing: 5) {
                if let dot = row.dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 5, height: 5)
                }
                Text(row.label)
            }
            .foregroundStyle(Palette.secondary)
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 16)
            Text(row.value)
                .foregroundStyle(row.color ?? Palette.text)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }
}
