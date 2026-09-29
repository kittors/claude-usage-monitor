import SwiftUI
import UsageCore

/// 弹窗的显示状态（由 `MenuBarController` 驱动）
@MainActor
@Observable
final class PanelPresentation {
    var isVisible = false
}

struct PopoverActions {
    var openSettings: () -> Void
    var quit: () -> Void
    var chooseDataDirectory: () -> Void
}

struct PopoverView: View {
    let store: UsageStore
    let prefs: Preferences
    let presentation: PanelPresentation
    let actions: PopoverActions
    var onSizeChange: (CGSize) -> Void = { _ in }

    var body: some View {
        let visible = presentation.isVisible
        VStack(alignment: .leading, spacing: 0) {
            Header(store: store, prefs: prefs)
                .padding(.bottom, 12)
            Hairline()
            content
            Hairline()
            Footer(store: store, actions: actions)
                .padding(.top, 7)
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.top, 13)
        .padding(.bottom, 7)
        .frame(width: Metrics.popoverWidth)
        .background(PanelBackground())
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: visible)
        .padding(Metrics.shadowInset)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.panelVisible, visible)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .ready:
            if let snapshot = store.snapshot {
                LimitsSection(store: store, prefs: prefs)
                    .padding(.vertical, 14)
                Hairline()
                CycleSection(snapshot: snapshot, prefs: prefs)
                    .padding(.vertical, 14)
            }
        case .launching, .indexing:
            LoadingSection(phase: store.phase)
                .padding(.vertical, 28)
        case .empty:
            EmptySection(prefs: prefs, choose: actions.chooseDataDirectory)
                .padding(.vertical, 28)
        }
    }
}

// MARK: - 顶栏 / 底栏

private struct Header: View {
    let store: UsageStore
    let prefs: Preferences

    var body: some View {
        HStack(spacing: 8) {
            ClaudeLogo(size: 15)
            Text("Claude 用量")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
            Spacer()
            // 套餐来自服务端账号资料（凭据里的档位是登录时的快照，升级后不会更新）
            if let plan = store.official.detectedPlan ?? prefs.plan {
                Text(plan.title)
                    .font(.caption)
                    .foregroundStyle(Palette.tertiary)
            }
        }
        .frame(height: 22)
    }
}

private struct Footer: View {
    let store: UsageStore
    let actions: PopoverActions
    @State private var spin = 0.0

    var body: some View {
        HStack(spacing: 0) {
            FooterButton(icon: .sliders, title: "设置…", action: actions.openSettings)
            Spacer()
            FooterButton(icon: .refresh, title: "立即刷新", rotation: spin) {
                withAnimation(.settle) { spin += 360 }
                store.refreshNow()
            }
            .help(store.lastUpdated.map { "上次同步：\(Fmt.relative($0))" } ?? "")
            Spacer()
            FooterButton(icon: .power, title: "退出", action: actions.quit)
        }
        .padding(.horizontal, -8)
    }
}

// MARK: - 加载 / 空状态

private struct LoadingSection: View {
    let phase: UsageStore.Phase

    private var progress: Double {
        if case .indexing(let p) = phase { return p }
        return 0
    }

    var body: some View {
        VStack(spacing: 10) {
            LookingAroundMascot(width: 44)
                .padding(.bottom, 4)
            Text("正在建立本地索引")
                .font(.rowValue)
                .foregroundStyle(Palette.text)
            Text("首次需要扫描全部会话日志，之后只做增量更新")
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
            ThinBar(fraction: max(0.01, progress), delay: 0)
                .frame(width: 180)
                .padding(.top, 6)
            Text(Fmt.percent(progress))
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
                .monospacedDigit()
                .contentTransition(.numericText(value: progress))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct EmptySection: View {
    let prefs: Preferences
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            MascotView(width: 44, color: Palette.quaternary)
                .padding(.bottom, 4)
            Text("没有找到 Claude Code 会话记录")
                .font(.rowValue)
                .foregroundStyle(Palette.text)
            Text(prefs.dataRootsDisplay.isEmpty ? "~/.claude/projects 不存在" : prefs.dataRootsDisplay)
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
                .multilineTextAlignment(.center)
            FooterButton(icon: .folder, title: "选择数据目录…", action: choose)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }
}
