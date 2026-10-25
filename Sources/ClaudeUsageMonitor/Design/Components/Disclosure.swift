import SwiftUI

// MARK: - 可以收起的区块

/// 面板里的一个区块：点标题收起、展开，收起后标题右侧换成一句摘要。
/// 收起时内容的高度收到 0、超出的部分裁掉，下面的内容和面板背景在同一个动画里上移；
/// 收完才把内容拿掉，里面每秒刷新的时间线也跟着停下。展开时在同一个动画里放回来
struct CollapsibleSection<Status: View, Summary: View, Content: View>: View {
    let section: PanelSection
    let title: String
    let prefs: Preferences
    /// 标题和内容之间的距离
    let spacing: CGFloat
    let status: Status
    let summary: Summary
    let content: Content

    /// 内容在不在视图里：收起的动画播完才变成 false
    @State private var mounted: Bool
    /// 每点一次加一。收起动画播完时还是同一次，才把内容拿掉：连点「收起、展开、收起」时，
    /// 第一次的回调会落在第二次收起的中途
    @State private var toggles = 0
    /// 裁剪框比内容左右各宽出这么多（面板的左右边距），贴边画的圆点、按钮的悬停底色不会被切掉
    private static var slack: CGFloat { Metrics.padding }

    init(
        _ section: PanelSection, title: String, prefs: Preferences, spacing: CGFloat = 12,
        @ViewBuilder status: () -> Status,
        @ViewBuilder summary: () -> Summary,
        @ViewBuilder content: () -> Content
    ) {
        self.section = section
        self.title = title
        self.prefs = prefs
        self.spacing = spacing
        self.status = status()
        self.summary = summary()
        self.content = content()
        _mounted = State(initialValue: !prefs.isCollapsed(section))
    }

    var body: some View {
        let collapsed = prefs.isCollapsed(section)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title, collapsed: collapsed, toggle: toggle) {
                ZStack(alignment: .trailing) {
                    if collapsed {
                        summary.transition(.opacity)
                    } else {
                        status.transition(.opacity)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if mounted {
                    // 内容总按自己的高度排：高度 0 会一路传给里面，能缩放的金额会跟着缩小、下面的内容跟着跳
                    content
                        .padding(.top, spacing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Self.slack)
            .frame(height: collapsed ? 0 : nil, alignment: .top)
            .clipped()
            .padding(.horizontal, -Self.slack)
            .opacity(collapsed ? 0 : 1)
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
        }
    }

    /// 和进程列表一样，状态必须在动画事务里切换，下方内容才会和这一块一起移动
    private func toggle() {
        toggles += 1
        if prefs.isCollapsed(section) {
            withAnimation(.disclosure) {
                mounted = true
                prefs.setCollapsed(section, false)
            }
        } else {
            let current = toggles
            withAnimation(.disclosure) {
                prefs.setCollapsed(section, true)
            } completion: {
                if toggles == current { mounted = false }
            }
        }
    }
}

/// 区块标题，整行都可以点。指针停在上面时标题提亮、旁边露出箭头；收起后箭头一直在，指向右边
struct SectionHeader<Trailing: View>: View {
    let title: String
    let collapsed: Bool
    let toggle: () -> Void
    @ViewBuilder var trailing: Trailing

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // 箭头画在浮层里：不参与基线对齐，也不随显示、隐藏改变标题的宽度
                Text(title)
                    .font(.sectionTitle)
                    .foregroundStyle(hovering ? Palette.text : Palette.secondary)
                    .padding(.trailing, 14)
                    .overlay(alignment: .trailing) {
                        SVGIcon(.chevronDown, size: 9, lineWidth: 2.2)
                            .foregroundStyle(Palette.tertiary)
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                            .opacity(collapsed || hovering ? 1 : 0)
                    }
                Spacer(minLength: 0)
                trailing
                    .font(.caption)
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(StillButtonStyle())
        .onHover { inside in withAnimation(.quiet) { hovering = inside } }
        .accessibilityValue(collapsed ? L10n.t("已收起", "Collapsed") : L10n.t("已展开", "Expanded"))
    }
}

// MARK: - 空状态

/// 区块里暂时没有内容时的说明：左边一个淡淡的小图标，右边一句话，需要时再补一行说明或一个按钮
struct EmptyNote<Action: View>: View {
    let icon: Icon
    let title: String
    var detail: String?
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SVGIcon(icon, size: 14)
                .foregroundStyle(Palette.tertiary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.055)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                action
            }
            // 只有一行字时和图标居中对齐，多行时从顶上排
            .frame(minHeight: 28, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EmptyNote where Action == EmptyView {
    init(icon: Icon, title: String, detail: String? = nil) {
        self.init(icon: icon, title: title, detail: detail) { EmptyView() }
    }
}
