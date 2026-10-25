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
    /// 打开「设置 › 通用 › 软件更新」
    var openUpdate: () -> Void
    var quit: () -> Void
    var chooseDataDirectory: () -> Void
}

struct PopoverView: View {
    let store: UsageStore
    let prefs: Preferences
    let presentation: PanelPresentation
    let actions: PopoverActions
    var onSizeChange: (CGSize) -> Void = { _ in }

    /// 悬停说明：同一时刻只浮起一条，画在面板最上层
    @State private var tips = TipCenter()

    var body: some View {
        let visible = presentation.isVisible
        let processes = prefs.showsProcesses
        VStack(alignment: .leading, spacing: 0) {
            Header(store: store, prefs: prefs)
                .padding(.bottom, 10)
            NetworkPlaceRow(display: prefs.exitDisplay)
            if processes {
                ClaudeProcessSection()
            }
            // 进程列表展开、收起时，下面这整块作为一个整体移动。不分组的话，位移会下推到每个叶子视图各自做动画，
            // 正在滚动的数字按自己那份动画走，和周围的内容错开，看起来就是跳动。
            VStack(alignment: .leading, spacing: 0) {
                Hairline()
                content
                Hairline()
                Footer(store: store, actions: actions)
                    .padding(.top, 7)
            }
            .geometryGroup()
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.top, 13)
        .padding(.bottom, 7)
        // 万一某一行比面板宽，也只是往右溢出，不会把整块内容往左挤
        .frame(width: Metrics.popoverWidth, alignment: .leading)
        .background(PanelBackground())
        // 说明只在面板范围里摆放，不会伸到阴影边距外被窗口裁掉
        .overlayPreferenceValue(TipKey.self) { item in
            TipLayer(item: item)
        }
        // 进程出现、退出，出口出了问题，IPv6 警告、更新提示出现时，面板高度随内容一起过渡
        .animation(.disclosure, value: ClaudeProcesses.shared.tasks.map(\.pid))
        .animation(.disclosure, value: NetworkPlace.shared.ipv6IsDirect)
        .animation(.disclosure, value: NetworkPlaceRow.hasIssue(NetworkPlace.shared))
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: visible)
        .padding(Metrics.shadowInset)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.panelVisible, visible)
        .environment(\.colorScheme, .dark)
        .environment(tips)
        .onChange(of: visible, initial: true) { _, visible in
            tips.setActive(visible)
        }
        .task(id: visible && processes) {
            guard visible, processes else { return }
            while !Task.isCancelled {
                ClaudeProcesses.shared.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// 面板中间的几块，按设置里的选择排列，相邻两块之间一条发丝线
    private enum Block: Hashable {
        case limits, speed, spend
        /// 第一次建立本地索引：速度和花费要等它
        case indexing
        /// 没有找到会话记录
        case noSessions
        /// 设置里把三块都关掉了
        case allHidden
    }

    /// 限额只来自官方接口，不用等本地索引；速度和花费来自本地索引
    private var blocks: [Block] {
        let limits = prefs.limitsDisplay != .hidden
        let speed = prefs.speedDisplay != .hidden
        let spend = prefs.spendDisplay != .hidden
        guard limits || speed || spend else { return [.allHidden] }
        var blocks: [Block] = limits ? [.limits] : []
        switch store.phase {
        case .ready:
            if store.snapshot != nil {
                if speed { blocks.append(.speed) }
                if spend { blocks.append(.spend) }
            }
        case .launching, .indexing:
            if speed || spend { blocks.append(.indexing) }
        case .empty:
            if speed || spend { blocks.append(.noSessions) }
        }
        return blocks
    }

    private var content: some View {
        let blocks = blocks
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element) { index, block in
                if index > 0 { Hairline() }
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .limits:
            LimitsSection(store: store, prefs: prefs)
                .padding(.vertical, 14)
        case .speed:
            SpeedSection(store: store, prefs: prefs)
                .padding(.vertical, 14)
        case .spend:
            if let snapshot = store.snapshot {
                CycleSection(snapshot: snapshot, prefs: prefs)
                    .padding(.vertical, 14)
            }
        case .indexing:
            LoadingSection(phase: store.phase)
                .padding(.vertical, 28)
        case .noSessions:
            EmptySection(prefs: prefs, choose: actions.chooseDataDirectory)
                .padding(.vertical, 28)
        case .allHidden:
            EmptyNote(
                icon: .sliders,
                title: L10n.t("面板里的内容都已隐藏", "Everything in the panel is hidden"),
                detail: L10n.t("可以在「设置 › 面板」中选择要显示的内容", "Choose what to show in Settings > Panel.")
            )
            .padding(.vertical, 16)
        }
    }
}

// MARK: - 网络位置

private struct NetworkPlaceRow: View {
    /// 设置里选「异常时」时，平时不显示这一行
    let display: ExitDisplay
    @State private var hoveringIP = false

    var body: some View {
        let network = NetworkPlace.shared
        if display == .always || Self.hasIssue(network) {
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
            .padding(.bottom, 8)
            .transition(.opacity)
        }
    }

    /// 官方请求暂停（出口在中国大陆、香港、澳门，或无法确认），或者 IPv6 直连。选了「异常时」也要显示。
    /// 跟着菜单栏盾牌判断：风险出口重新确认时地址会先清掉，盾牌保持警示，这一行也不能闪没
    static func hasIssue(_ network: NetworkPlace) -> Bool {
        switch network.menuShield {
        case .risk, .severe: true
        case .none, .safe, .loading: false
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
                    .tip("exit.paused") { Tip(L10n.t("出口在中国大陆、香港或澳门，暂停向官方查询用量", "The exit is in mainland China, Hong Kong, or Macau, so official usage checks are paused.")) }
            } else if network.place?.isUnitedStates == true {
                chip(L10n.t("美区", "US"), color: Palette.accent)
            } else if network.failed {
                chip(L10n.t("已暂停", "Paused"), color: Palette.critical)
                    .tip("exit.paused") { Tip(L10n.t("确认不了出口在哪，先暂停向官方查询用量", "The exit cannot be confirmed, so official usage checks are paused.")) }
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
                // 和下面几块的标题同一个样子
                SectionHeader(title: L10n.t("进程", "Processes"), collapsed: !expanded, toggle: toggle) {
                    Text(L10n.t("\(list.tasks.count) 个", "\(list.tasks.count)"))
                        .monospacedDigit()
                        .contentTransition(.identity)
                        .tip("processes.summary") { expanded ? nil : Self.tip(list.tasks) }
                }

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

    /// 收起时的说明：有哪些进程、各占多少内存
    private static func tip(_ tasks: [ClaudeTask]) -> Tip {
        let rows = tasks.map { task in
            let memory = ByteCountFormatter.string(fromByteCount: task.bytes, countStyle: .memory)
            return Tip.Row(task.name, task.detail.map { "\($0) · \(memory)" } ?? memory)
        }
        return Tip(rows: rows, note: L10n.t("点击展开，可以强制退出", "Click to expand and force quit"))
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
    }
}

// MARK: - 更新

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
    @State private var spinning = false

    var body: some View {
        HStack(spacing: 0) {
            // 有新版本时「设置…」带一个小圆点，点开直接到「通用 › 软件更新」
            let update = AppUpdate.shared
            FooterButton(icon: .sliders, title: L10n.t("设置…", "Settings…"), badge: update.showsBadge,
                         action: update.showsBadge ? actions.openUpdate : actions.openSettings)
                .tip("footer.settings") { settingsTip(update) }
            Spacer()
            FooterButton(icon: .refresh, title: L10n.t("立即刷新", "Refresh"), rotation: spin) {
                store.refreshNow()
                startSpinning()
            }
            .tip("footer.refresh") { refreshTip }
            Spacer()
            FooterButton(icon: .power, title: L10n.t("退出", "Quit"), action: actions.quit)
                .tip("footer.quit") { Tip(rows: [Self.shortcut("⌘Q")]) }
        }
        .padding(.horizontal, -8)
        .onChange(of: store.isRefreshing) { _, refreshing in
            if refreshing { startSpinning() }
        }
        .onAppear {
            if store.isRefreshing { startSpinning() }
        }
    }

    private static func shortcut(_ keys: String) -> Tip.Row {
        Tip.Row(L10n.t("快捷键", "Shortcut"), keys)
    }

    private func settingsTip(_ update: AppUpdate) -> Tip {
        Tip(rows: [Self.shortcut("⌘,")], note: update.availableVersion.map { L10n.t("新版本 \($0) 可以更新", "Version \($0) is available") })
    }

    private var refreshTip: Tip {
        var rows = [Self.shortcut("⌘R")]
        if let last = store.lastUpdated {
            rows.insert(Tip.Row(L10n.t("上次同步", "Last sync"), Fmt.relative(last)), at: 0)
        }
        return Tip(rows: rows)
    }

    /// 至少转一圈；刷新还没完成就接着转，新结果出来后停在整圈处
    private func startSpinning() {
        guard !spinning else { return }
        spinning = true
        turn()
    }

    private func turn() {
        withAnimation(.linear(duration: 0.75)) {
            spin += 360
        } completion: {
            if store.isRefreshing { turn() } else { spinning = false }
        }
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
