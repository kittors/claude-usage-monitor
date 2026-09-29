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
                .padding(.bottom, 10)
            NetworkPlaceRow()
                .padding(.bottom, 8)
            ClaudeProcessSection()
            if AppUpdate.shared.showsNotice {
                UpdateBanner()
                    .padding(.bottom, 10)
            }
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
        // 进程出现、退出，IPv6 警告、更新提示出现时，面板高度随内容一起过渡
        .animation(.disclosure, value: ClaudeProcesses.shared.tasks.map(\.pid))
        .animation(.disclosure, value: NetworkPlace.shared.ipv6IsDirect)
        .animation(.disclosure, value: AppUpdate.shared.showsNotice)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: visible)
        .padding(Metrics.shadowInset)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.panelVisible, visible)
        .environment(\.colorScheme, .dark)
        .task(id: visible) {
            guard visible else { return }
            while !Task.isCancelled {
                ClaudeProcesses.shared.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
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

// MARK: - 网络位置

private struct NetworkPlaceRow: View {
    @State private var hoveringIP = false

    var body: some View {
        let network = NetworkPlace.shared
        VStack(alignment: .leading, spacing: 2) {
            exitLine(network)
            if network.ipv6IsDirect {
                Text(L10n.t("严重警告：IPv6 直连中国大陆、香港或澳门", "Severe warning: IPv6 connects directly from mainland China, Hong Kong, or Macau"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.critical)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }
        }
    }

    /// 确认中显示骨架，结果出来后在原地淡入。两者行高、各元素的位置都相同，切换时这一行不会跳动。
    private func exitLine(_ network: NetworkPlace) -> some View {
        let checking = network.place == nil && !network.failed
        return ZStack {
            if checking {
                ExitSkeleton()
                    .transition(.opacity)
            } else {
                resolvedLine(network)
                    .transition(.opacity)
            }
        }
        .frame(height: 26)
        .animation(.easeOut(duration: 0.25), value: checking)
    }

    private func resolvedLine(_ network: NetworkPlace) -> some View {
        HStack(spacing: 8) {
            Text(network.place?.flag ?? "🌐")
                .font(.system(size: 15))
                .frame(width: 20, alignment: .center)
            Text(title(network))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            if let place = network.place, place.restrictsUsage {
                chip(L10n.t("已暂停", "Paused"), color: Palette.critical)
            } else if network.place?.isUnitedStates == true {
                chip(L10n.t("美区", "US"), color: Palette.accent)
            } else if network.failed {
                chip(L10n.t("已暂停", "Paused"), color: Palette.critical)
            }
            Spacer(minLength: 8)
            if let place = network.place {
                // 遮住的数字换成等宽的「•」，和完整地址一样长：显示、隐藏时只是字符原地交替，宽高都不变
                Text(hoveringIP ? place.ip : Self.masked(place.ip))
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(ipColor(place))
                    .contentTransition(.opacity)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.16)) { hoveringIP = hovering }
                    }
            }
        }
    }
}

/// 出口确认中的骨架：国旗、地区名、IP 各一块占位，位置和大小与确认后的一行一致，轻轻呼吸表示正在加载
private struct ExitSkeleton: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = 0.5 + 0.5 * cos(t * .pi * 2 / 1.6)
            HStack(spacing: 8) {
                bar(width: 18, height: 13)
                    .frame(width: 20)
                bar(width: 40, height: 10)
                Spacer(minLength: 8)
                // 与遮住后的 IP 同样的字体和长度，占位条的宽度就是真实地址的宽度
                Text(verbatim: "000.000.•••.••")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .hidden()
                    .overlay { bar(width: nil, height: 10) }
                    .padding(.horizontal, 4)
            }
            .opacity(0.55 + 0.45 * breath)
        }
    }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.white.opacity(0.1))
            .frame(width: width, height: height)
    }
}

private extension NetworkPlaceRow {
    private func chip(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private func ipColor(_ place: PublicNetwork) -> Color {
        if place.restrictsUsage { return Palette.critical }
        return hoveringIP ? Palette.secondary : Palette.tertiary
    }

    /// 平时只露出前两段（IPv6 为第一段），其余每个数字换成一个「•」，长度与完整地址相同；鼠标停在上面时再显示完整地址。
    static func masked(_ ip: String) -> String {
        let separator: Character = ip.contains(":") ? ":" : "."
        let keep = separator == "." ? 2 : 1
        var groups = 0
        return String(ip.map { character in
            if character == separator {
                groups += 1
                return character
            }
            return groups < keep ? character : "•"
        })
    }

    private func title(_ network: NetworkPlace) -> String {
        guard let place = network.place else {
            return network.failed
                ? L10n.t("无法确认出口", "Exit unknown")
                : L10n.t("正在确认出口", "Checking exit")
        }
        return countryName(place.countryCode)
    }

    private func countryName(_ code: String) -> String {
        switch code {
        case "CN": L10n.t("中国大陆", "Mainland China")
        case "HK": L10n.t("中国香港", "Hong Kong")
        case "MO": L10n.t("中国澳门", "Macau")
        case "US": L10n.t("美国", "United States")
        default:
            Locale(identifier: Localization.shared.isChinese ? "zh_CN" : "en_US").localizedString(forRegionCode: code) ?? code
        }
    }
}

// MARK: - 进程

private struct ClaudeProcessSection: View {
    @State private var expanded = false

    var body: some View {
        let list = ClaudeProcesses.shared
        if !list.tasks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        SVGIcon(.chevronDown, size: 9, lineWidth: 2.2)
                            .foregroundStyle(Palette.tertiary)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                        Text(L10n.t("进程", "Processes"))
                            .font(.sectionTitle)
                            .foregroundStyle(Palette.secondary)
                        Spacer(minLength: 8)
                        Text(L10n.t("\(list.tasks.count) 个", "\(list.tasks.count)"))
                            .font(.caption)
                            .foregroundStyle(Palette.tertiary)
                            .monospacedDigit()
                            .contentTransition(.identity)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(StillButtonStyle())

                // 高度从 0 到全部行：行随高度逐渐露出，下方内容与面板背景在同一个动画里移动
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(list.tasks) { task in
                        ClaudeProcessRow(task: task)
                    }
                }
                .padding(.top, 4)
                .frame(height: expanded ? nil : 0, alignment: .top)
                .clipped()
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
            }
            .padding(.bottom, 8)
        }
    }

    /// 展开状态必须在动画事务里切换：只给列表加 `.animation` 的话，下方内容会直接跳到终点，
    /// 列表却还在原地淡出，两者叠在一起就是拖影
    private func toggle() {
        withAnimation(.disclosure) { expanded.toggle() }
    }
}

private struct ClaudeProcessRow: View {
    let task: ClaudeTask
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(task.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = task.detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                Text(ByteCountFormatter.string(fromByteCount: task.bytes, countStyle: .memory))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
                    .monospacedDigit()
                    .opacity(hovering ? 0 : 1)
                Button {
                    ClaudeProcesses.shared.forceQuit(task.pid)
                } label: {
                    Text(L10n.t("强制退出", "Force quit"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.critical)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(Capsule().fill(Palette.critical.opacity(0.16)))
                }
                .buttonStyle(PressableStyle(scale: 0.96))
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(height: 26)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Palette.hover : .clear)
        )
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hovering = h } }
        .help(L10n.t("强制停止这个进程", "Force quit this process"))
    }
}

// MARK: - 更新

private struct UpdateBanner: View {
    var body: some View {
        let update = AppUpdate.shared
        Button {
            if update.canInstall { update.install() }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(update.statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    if update.canInstall {
                        Text(L10n.t("更新", "Update"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background(Capsule().fill(Palette.accent))
                    }
                }
                if case .downloading = update.phase {
                    DownloadProgress(fraction: update.downloadFraction)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(PressableStyle())
        .disabled(!update.canInstall)
    }
}

// MARK: - 顶栏 / 底栏

private struct Header: View {
    let store: UsageStore
    let prefs: Preferences

    var body: some View {
        HStack(spacing: 8) {
            ClaudeLogo(size: 15)
            Text(L10n.t("Claude 用量", "Claude usage"))
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
            FooterButton(icon: .sliders, title: L10n.t("设置…", "Settings…"), action: actions.openSettings)
            Spacer()
            FooterButton(icon: .refresh, title: L10n.t("立即刷新", "Refresh"), rotation: spin) {
                withAnimation(.settle) { spin += 360 }
                store.refreshNow()
            }
            .help(store.lastUpdated.map { L10n.t("上次同步：\(Fmt.relative($0))", "Last sync: \(Fmt.relative($0))") } ?? "")
            Spacer()
            FooterButton(icon: .power, title: L10n.t("退出", "Quit"), action: actions.quit)
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
            Text(L10n.t("正在建立本地索引", "Building the local index"))
                .font(.rowValue)
                .foregroundStyle(Palette.text)
            Text(L10n.t("首次需要扫描全部会话日志，之后只做增量更新", "The first scan reads every session log. Later scans only read what was added."))
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
            Text(L10n.t("没有找到 Claude Code 会话记录", "No Claude Code sessions found"))
                .font(.rowValue)
                .foregroundStyle(Palette.text)
            Text(prefs.dataRootsDisplay.isEmpty ? L10n.t("~/.claude/projects 不存在", "~/.claude/projects does not exist") : prefs.dataRootsDisplay)
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
                .multilineTextAlignment(.center)
            FooterButton(icon: .folder, title: L10n.t("选择数据目录…", "Choose data folder…"), action: choose)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }
}
