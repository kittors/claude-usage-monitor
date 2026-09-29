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
            NetworkPlaceRow(prefs: prefs)
                .padding(.bottom, 8)
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

// MARK: - 网络位置

private struct NetworkPlaceRow: View {
    let prefs: Preferences
    @State private var hoveringIP = false

    var body: some View {
        let network = NetworkPlace.shared
        VStack(alignment: .leading, spacing: 1) {
            exitLine(network)
            if network.place != nil || network.failed {
                HStack(spacing: 8) {
                    Text(ipv6Line(network))
                        .font(.system(size: network.ipv6IsDirect && !prefs.blockIPv6 ? 11 : 10.5, weight: network.ipv6IsDirect && !prefs.blockIPv6 ? .semibold : .medium))
                        .foregroundStyle(ipv6Color(network))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 6)
                    Button {
                        prefs.blockIPv6.toggle()
                    } label: {
                        Text(prefs.blockIPv6 ? L10n.t("取消", "Undo") : L10n.t("屏蔽", "Block"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(prefs.blockIPv6 ? Palette.secondary : Palette.text)
                            .padding(.horizontal, 8)
                            .frame(height: 18)
                            .background(Capsule().fill(Color.white.opacity(prefs.blockIPv6 ? 0.08 : 0.14)))
                    }
                    .buttonStyle(PressableStyle(scale: 0.96))
                    .help(prefs.blockIPv6
                        ? L10n.t("官方用量恢复可用 IPv6", "Official usage may use IPv6 again")
                        : L10n.t("官方用量和出口检查只走 IPv4", "Official usage and the exit check use IPv4 only"))
                }
                .padding(.leading, 28)
            }
        }
    }

    private func exitLine(_ network: NetworkPlace) -> some View {
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
                Text(hoveringIP ? place.ip : Self.abbreviated(place.ip))
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(ipColor(place))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onHover { hoveringIP = $0 }
                    .animation(.quiet, value: hoveringIP)
            }
        }
        .frame(height: 26)
    }

    private func ipv6Line(_ network: NetworkPlace) -> String {
        if prefs.blockIPv6 {
            return network.ipv6IsDirect
                ? L10n.t("已屏蔽 IPv6，系统仍是直连", "IPv6 blocked here. The system path is still direct")
                : L10n.t("已屏蔽 IPv6", "IPv6 blocked")
        }
        if network.ipv6IsDirect {
            return L10n.t("严重警告：IPv6 正在直连", "Severe warning: IPv6 is connecting directly")
        }
        return L10n.t("未屏蔽 IPv6，仍是风险点", "IPv6 is not blocked and is still a risk")
    }

    private func ipv6Color(_ network: NetworkPlace) -> Color {
        if prefs.blockIPv6 { return network.ipv6IsDirect ? Palette.warning : Palette.secondary }
        return network.ipv6IsDirect ? Palette.critical : Palette.warning
    }

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

    /// 平时只露出前两段，鼠标停在上面时再换成完整地址。
    private static func abbreviated(_ ip: String) -> String {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 {
            return "\(parts[0]).\(parts[1]).***.***"
        }
        let groups = ip.split(separator: ":", omittingEmptySubsequences: false)
        if groups.count > 2, let head = groups.first {
            return "\(head):****:****"
        }
        return "***"
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

// MARK: - 更新

private struct UpdateBanner: View {
    var body: some View {
        let update = AppUpdate.shared
        Button {
            if update.canInstall { update.install() }
        } label: {
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
