import SwiftUI
import UsageCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case usage, display, data, general
    var id: String { rawValue }

    var title: String {
        switch self {
        case .usage: L10n.tNow("用量", "Usage")
        case .display: L10n.tNow("显示", "Display")
        case .data: L10n.tNow("数据", "Data")
        case .general: L10n.tNow("通用", "General")
        }
    }

    var icon: Icon {
        switch self {
        case .usage: .gauge
        case .display: .menuBar
        case .data: .database
        case .general: .sliders
        }
    }
}

/// 设置窗口当前的标签页。面板上的新版本提示会直接打开「通用」并高亮「软件更新」。
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()

    var tab: SettingsTab = .usage
    /// 每次从新版本提示进入都会变化，更新一栏据此高亮一下
    private(set) var updateHighlight = 0
    @ObservationIgnored var handledHighlight = 0

    func showUpdate() {
        tab = .general
        updateHighlight += 1
        AppUpdate.shared.showNotes()
    }
}

/// 设置窗口：与弹窗一致的暗色毛玻璃 + 顶部图标标签页。
struct SettingsView: View {
    @Bindable var prefs: Preferences
    let store: UsageStore

    @Bindable private var navigation = SettingsNavigation.shared

    var body: some View {
        let tab = navigation.tab
        VStack(spacing: 0) {
            TabBar(selection: $navigation.tab)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Hairline()
            ScrollView {
                Group {
                    switch tab {
                    case .usage: UsagePage(prefs: prefs, store: store)
                    case .display: DisplayPage(prefs: prefs, store: store)
                    case .data: DataPage(prefs: prefs, store: store)
                    case .general: GeneralPage(prefs: prefs, store: store)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 26)
                .transition(.opacity)
                .id(tab)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 540, height: 640)
        .background {
            ZStack {
                GlassEffect(material: .hudWindow)
                Color(hex: 0x1C1B1A).opacity(0.86)
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .animation(.quiet, value: tab)
    }
}

private struct TabBar: View {
    @Binding var selection: SettingsTab
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = tab == selection
                VStack(spacing: 4) {
                    SVGIcon(tab.icon, size: 17)
                    Text(tab.title).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(selected ? Palette.text : Palette.tertiary)
                .frame(width: 66, height: 48)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .matchedGeometryEffect(id: "tab", in: namespace)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.quiet) { selection = tab } }
            }
        }
    }
}

// MARK: - 用量

private struct UsagePage: View {
    @Bindable var prefs: Preferences
    let store: UsageStore

    var body: some View {
        let official = store.official
        let billing = store.billingSettings()
        let clock = store.learnedResetClock
        let interval = UsageCalculator.billingInterval(
            now: Date(), anchorDay: billing.billingAnchorDay,
            hour: billing.billingAnchorHour, minute: billing.billingAnchorMinute,
            second: billing.billingAnchorSecond, calendar: .current
        )
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: L10n.t("官方用量", "Official usage"))
            SettingsRow(title: L10n.t("Claude 官方用量", "Claude official usage"), detail: officialDetail(official)) {
                SwitchToggle(isOn: $prefs.officialUsageEnabled)
            }
            if prefs.officialUsageEnabled {
                Hairline()
                SettingsRow(
                    title: L10n.t("展开面板时立即查询", "Check when the panel opens"),
                    detail: prefs.refreshOnOpen
                        ? L10n.t("点开菜单栏图标时立即查询一次，只要求出口可用；10 秒内不重复查询。", "Checks right away when you open the menu bar panel. Only needs an allowed exit. Not repeated within 10 seconds.")
                        : L10n.t("已关闭：展开面板只显示上次的结果，按下方的自动查询频率更新，也可以点「立即刷新」。", "Off: opening the panel shows the last numbers. They update as set below, or with Refresh.")
                ) {
                    SwitchToggle(isOn: $prefs.refreshOnOpen)
                }
                Hairline()
                SettingsRow(title: L10n.t("自动查询", "Check automatically"), detail: autoSyncDetail) {
                    DropdownButton(options: AutoSyncMode.allCases.map { ($0, $0.title) }, selection: $prefs.autoSyncMode)
                }
                Hairline()
                SettingsRow(title: L10n.t("官方请求代理", "Official request proxy"), detail: proxyDetail) {
                    ProxyField(text: $prefs.officialProxy)
                }
                Hairline()
                SettingsRow(title: L10n.t("自动续期登录", "Renew login automatically"), detail: renewalDetail(official)) {
                    SwitchToggle(isOn: $prefs.autoRenewLogin)
                }
                if needsAttention(official.state) {
                    Hairline()
                    HStack {
                        Text(attentionHint(official.state))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        if official.state.awaitingLogin {
                            QuietButton(title: L10n.t("在终端中登录", "Sign in via Terminal"), prominent: true) { store.signInToClaudeCode() }
                        } else {
                            QuietButton(title: L10n.t("重新连接", "Reconnect"), prominent: true) { official.refresh(.manual) }
                        }
                    }
                    .padding(.vertical, 11)
                }
            }
            Text(L10n.t(
                "官方用量会用当前登录访问 Anthropic，需要和 Claude Code 走同一网络。自动查询只在出口可用、且 Claude Code（终端或桌面版）正在使用时进行；手动刷新只要求出口可用。任意两次查询至少间隔 10 秒。关闭后仍可看本机费用。",
                "Official usage sends your login to Anthropic and must use the same network as Claude Code. Automatic checks run only while the exit is allowed and Claude Code (Terminal or desktop) is in use. Refresh only needs an allowed exit. Checks are at least 10 seconds apart. Local cost stays available when this is off."
            ))
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            SettingsHeader(title: L10n.t("计费周期", "Billing period"))
            SettingsRow(title: L10n.t("每月扣费日", "Billing day"), detail: L10n.t("当前周期 ", "Current period ") + UsageCalculator.periodRange(start: interval.start, end: interval.end, calendar: .current, locale: Localization.shared.locale)) {
                DropdownButton(options: (1...31).map { ($0, L10n.t("每月 \($0) 日", "Day \($0)")) }, selection: $prefs.billingAnchorDay)
            }
            Hairline()
            SettingsRow(
                title: L10n.t("重置时刻", "Reset time"),
                detail: clock == nil
                    ? L10n.t("与每周限额相同，同步后自动对齐", "Same clock as the weekly limit, filled in after sync")
                    : L10n.t("与每周限额相同，这一刻之前的用量仍计入上一周期", "Same clock as the weekly limit. Usage before this instant stays in the previous period")
            ) {
                Text(clock.map { String(format: "%02d:%02d:%02d", $0.hour, $0.minute, billing.billingAnchorSecond) } ?? "—")
                    .font(.system(size: 12.5))
                    .foregroundStyle(clock == nil ? Palette.tertiary : Palette.text)
                    .monospacedDigit()
            }
        }
    }

    private func officialDetail(_ official: OfficialUsageService) -> String {
        let synced = official.usage.map { L10n.t("上次同步 \(Fmt.relative($0.fetchedAt))", "Synced \(Fmt.relative($0.fetchedAt))") }
        switch official.state {
        case .connected:
            let plan = (official.detectedPlan ?? prefs.plan).map { " · \($0.title)" } ?? ""
            return L10n.t("已连接\(plan) · \(synced ?? "刚刚同步")，与 Claude Code /usage 一致",
                          "Connected\(plan) · \(synced ?? "just now"), same as Claude Code /usage")
        case .connecting:
            return official.isFetching
                ? L10n.t("正在连接…", "Connecting…")
                : L10n.t("尚未查询：Claude Code 正在使用时自动查询", "Not checked yet. It checks while Claude Code is in use.")
        case .noCredentials: return L10n.t("未找到 Claude Code 的登录信息", "No Claude Code login found")
        case .denied: return L10n.t("未获得钥匙串授权", "Keychain access was denied")
        case .expired:
            return prefs.autoRenewLogin
                ? L10n.t("Claude Code 的登录已过期，且无法自动续期，需要重新登录", "The Claude Code login has expired and could not be renewed. Sign in again.")
                : L10n.t("Claude Code 的登录已过期，开启下方的自动续期即可恢复", "The Claude Code login has expired. Turn on automatic renewal below.")
        case .signedOut: return L10n.t("Claude Code 的登录已失效（登录到期或已退出），需要重新登录", "The Claude Code login is no longer valid. Sign in again.")
        case .failed(let message): return L10n.t("暂时无法获取（\(message)），稍后自动重试", "Unavailable (\(message)). Retrying shortly.") + (synced.map { " · \($0)" } ?? "")
        case .disabled: return L10n.t("已关闭，菜单栏与面板不显示 5 小时 / 每周用量", "Off. The menu bar and panel hide 5-hour and weekly usage.")
        }
    }

    private var autoSyncDetail: String {
        switch prefs.autoSyncMode {
        case .consumption:
            return L10n.t(
                "按本机的 Token 消耗决定：消耗越快查得越勤，最快 10 秒一次，持续消耗时最长 2 分钟一次；消耗停下后再补查一次。",
                "Follows local token use: the faster tokens go, the more often it checks, at most every 10 seconds and at least every 2 minutes while tokens are used. One more check after use stops."
            )
        case .every10Seconds:
            return L10n.t(
                "Claude Code 正在使用时每 10 秒查询一次。间隔这么短容易被接口限流，被限流后要等 5 到 30 分钟。",
                "Checks every 10 seconds while Claude Code is in use. This often hits the rate limit, and then checks pause for 5 to 30 minutes."
            )
        case let mode:
            let seconds = Int(mode.interval ?? 0)
            let zh = seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分钟"
            let en = seconds < 60 ? "\(seconds) seconds" : (seconds == 60 ? "minute" : "\(seconds / 60) minutes")
            return L10n.t("Claude Code 正在使用时每 \(zh)查询一次。", "Checks every \(en) while Claude Code is in use.")
        }
    }

    private var proxyDetail: String {
        let base = L10n.t(
            "留空使用系统代理。填写后用量和续期都从这里出去，例如 127.0.0.1:7890 或 socks5://127.0.0.1:7890",
            "Leave empty to use the system proxy. Usage and renewal then go out through this address, for example 127.0.0.1:7890 or socks5://127.0.0.1:7890"
        )
        if !prefs.officialProxy.trimmingCharacters(in: .whitespaces).isEmpty, OutboundProxy.parse(prefs.officialProxy) == nil {
            return base + "\n" + L10n.t("格式无法识别，目前仍走系统代理。", "That address was not recognized, so the system proxy is still used.")
        }
        return base
    }

    private func renewalDetail(_ official: OfficialUsageService) -> String {
        var status: [String] = []
        if let renewed = official.lastRenewal { status.append(L10n.t("上次续期 \(LimitsSection.moment(renewed))", "Renewed \(LimitsSection.moment(renewed))")) }
        if let until = official.loginExpiresAt { status.append(L10n.t("登录有效期至 \(Self.day(until))", "Login valid until \(Self.day(until))")) }
        let text = L10n.t(
            "默认开启。登录快过期时，按 Claude Code 相同的方式向 Anthropic 续期并写回钥匙串，走上面的同一条代理。关闭后，登录过期时只显示上次的官方数字。",
            "On by default. Before the login expires, it renews it with Anthropic the same way Claude Code does and writes it back, using the proxy above. When off, the last official numbers stay after expiry."
        )
        return status.isEmpty ? text : text + "\n" + status.joined(separator: " · ")
    }

    private func needsAttention(_ state: OfficialUsageService.State) -> Bool {
        switch state {
        case .connected, .connecting, .disabled: false
        default: true
        }
    }

    private func attentionHint(_ state: OfficialUsageService.State) -> String {
        switch state {
        case .denied: L10n.t("首次连接时，系统会询问是否允许读取「Claude Code-credentials」，请选择「始终允许」。", "On first connect, macOS asks to read Claude Code-credentials. Choose Always Allow.")
        case .noCredentials, .signedOut, .expired: L10n.t("将打开终端运行 claude auth login，在浏览器中完成授权后自动恢复。", "Terminal will run claude auth login. Finish in the browser and this app recovers.")
        default: L10n.t("问题解决后会自动恢复，也可以立即重试。", "It retries on its own. You can also try again now.")
        }
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Localization.shared.locale
        f.dateFormat = Localization.shared.isChinese ? "M月d日" : "MMM d"
        return f.string(from: date)
    }
}

// MARK: - 显示

private struct DisplayPage: View {
    @Bindable var prefs: Preferences
    let store: UsageStore
    /// 指针停在哪个数值方块上：上方的预览据此突出这一列，或预览加入它之后的样子
    @State private var hoveredItem: MenuBarItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: L10n.t("菜单栏", "Menu bar"))
            MenuBarPreview(prefs: prefs, store: store, hovered: hoveredItem)
                .padding(.vertical, 12)
            SettingsRow(title: L10n.t("图标", "Icon")) {
                PillSegmented(options: MenuBarIcon.allCases.map { ($0, $0 == .mascot ? "Clawd" : L10n.t("Claude 标志", "Claude logo")) }, selection: $prefs.menuBarIcon)
            }
            Hairline()
            SettingsRow(title: L10n.t("样式", "Style")) {
                DropdownButton(options: MenuBarStyle.allCases.map { ($0, $0.title) }, selection: $prefs.menuBarStyle)
            }
            if prefs.menuBarStyle == .iconPercent || prefs.menuBarStyle == .ringPercent {
                Hairline()
                MenuBarItemsRow(prefs: prefs, store: store, hovered: $hoveredItem)
            }
            Hairline()
            SettingsRow(title: L10n.t("出口安全", "Exit safety"), detail: L10n.t("在数值右侧显示盾牌。官方请求只走 IPv4。IPv6 直连中国大陆、香港或澳门时，菜单栏会警告。", "A shield beside the value. Official requests use IPv4 only. A direct IPv6 connection from mainland China, Hong Kong, or Macau warns in the menu bar.")) {
                SwitchToggle(isOn: $prefs.showExitSafety)
            }

            SettingsHeader(title: L10n.t("货币", "Currency"))
            SettingsRow(title: L10n.t("显示货币", "Display currency"), detail: L10n.t("按最新美元牌价自动折算，面板金额一起变", "Converted from USD at the latest rate. Panel amounts follow.")) {
                DropdownButton(
                    options: MoneyFormat.Unit.allCases.map { ($0, L10n.currency($0)) },
                    selection: $prefs.currency
                )
            }

            SettingsHeader(title: L10n.t("提醒", "Alerts"))
            SettingsRow(title: L10n.t("用量预警通知", "Usage alerts"), detail: L10n.t("超过预警线、以及达到 95% 时各提醒一次", "Once past your line, and again at 95%.")) {
                SwitchToggle(isOn: $prefs.notificationsEnabled)
            }
            Hairline()
            SettingsRow(title: L10n.t("预警线", "Warning line"), detail: L10n.t("到达这条线时提醒。进度条颜色随占用量变化。", "Notifies at this line. Bar color follows how full the limit is.")) {
                HStack(spacing: 10) {
                    ThinSlider(value: $prefs.warningThreshold, range: 0.5...0.95, step: 0.01)
                    Text(Fmt.percent(prefs.warningThreshold))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.secondary)
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
    }
}

/// 菜单栏显示哪些数值：一条和菜单栏一样的深色小条，每个数值一列（小标签 + 数值），亮起的就会显示在菜单栏上
private struct MenuBarItemsRow: View {
    @Bindable var prefs: Preferences
    let store: UsageStore
    @Binding var hovered: MenuBarItem?
    /// 想取消最后一项时轻轻晃一下
    @State private var refused: MenuBarItem?
    @State private var refusals = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("显示数值", "Menu bar values"))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.text)
                Text(L10n.t("亮起的会显示在菜单栏上，点一下切换，可以多选。", "Lit values appear in the menu bar. Click to toggle. Pick one or more."))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 2) {
                ForEach(limits) { column($0) }
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 5)
                ForEach([MenuBarItem.todayCost, .weekCost, .monthCost]) { column($0) }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        }
        .padding(.vertical, 11)
    }

    /// 5 小时、本周，以及账号里有单独周额度的模型；已选但暂时没有数据的模型也列出来，方便取消
    private var limits: [MenuBarItem] {
        var names = store.limitModels
        for case .model(let name) in prefs.menuBarItems where !names.contains(name) { names.append(name) }
        return [.fiveHour, .weekly] + names.map { .model($0) }
    }

    private func column(_ item: MenuBarItem) -> some View {
        ValueToggle(
            item: item,
            value: store.menuBarValue(item, money: prefs.money) ?? Self.sample(item, money: prefs.money),
            selected: prefs.menuBarItems.contains(item),
            refusals: refused == item ? refusals : 0,
            hovered: $hovered
        ) { toggle(item) }
    }

    private func toggle(_ item: MenuBarItem) {
        if let index = prefs.menuBarItems.firstIndex(of: item) {
            // 至少保留一个；只要图标可以把样式改成「仅图标」
            guard prefs.menuBarItems.count > 1 else {
                refused = item
                withAnimation(.linear(duration: 0.4)) { refusals += 1 }
                return
            }
            withAnimation(.snappy(duration: 0.22)) { _ = prefs.menuBarItems.remove(at: index) }
        } else {
            withAnimation(.snappy(duration: 0.22)) { prefs.menuBarItems.append(item) }
        }
    }

    /// 还没有数据时的示意数值
    static func sample(_ item: MenuBarItem, money: MoneyFormat) -> StatusIconRenderer.Value {
        switch item {
        case .fiveHour: .init(label: item.shortLabel, text: "42%", fraction: 0.42)
        case .weekly: .init(label: item.shortLabel, text: "68%", fraction: 0.68)
        case .model: .init(label: item.shortLabel, text: "12%", fraction: 0.12)
        case .todayCost: .init(label: item.shortLabel, text: money.compact(12), fraction: nil)
        case .weekCost: .init(label: item.shortLabel, text: money.compact(86), fraction: nil)
        case .monthCost: .init(label: item.shortLabel, text: money.compact(1234), fraction: nil)
        }
    }
}

/// 小条里的一列：和菜单栏上的样子一样。选中时亮起并上色，没选时变灰变暗，指针停上去半亮
private struct ValueToggle: View {
    let item: MenuBarItem
    let value: StatusIconRenderer.Value
    let selected: Bool
    let refusals: Int
    @Binding var hovered: MenuBarItem?
    let toggle: () -> Void

    var body: some View {
        let isHovered = hovered == item
        Button(action: toggle) {
            VStack(spacing: 0) {
                Text(value.label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.62))
                Text(value.text)
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tone)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(selected ? (isHovered ? 0.11 : 0.07) : (isHovered ? 0.05 : 0)))
            )
            .saturation(selected || isHovered ? 1 : 0)
            .opacity(selected ? 1 : (isHovered ? 0.7 : 0.3))
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
        .modifier(Shake(travel: CGFloat(refusals)))
        .onHover { inside in
            withAnimation(.quiet) {
                if inside { hovered = item } else if hovered == item { hovered = nil }
            }
        }
        .help(item.title)
    }

    private var tone: Color {
        guard let fraction = value.fraction else { return Palette.text }
        let rgb = UsageTone.tone(for: fraction).components
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// 按下时轻轻缩一下，不改变颜色
private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 左右晃动（travel 每加 1 晃一轮）
private struct Shake: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 4 * sin(travel * .pi * 6), y: 0))
    }
}

/// 菜单栏效果的实时预览：用当前的真实数值；指针停在数值方块上时，突出那一列，或先放进来看看效果
private struct MenuBarPreview: View {
    let prefs: Preferences
    let store: UsageStore
    var hovered: MenuBarItem?

    var body: some View {
        let network = NetworkPlace.shared
        let money = prefs.money
        let selected = prefs.menuBarItems
        let showsValues = prefs.menuBarStyle == .iconPercent || prefs.menuBarStyle == .ringPercent
        let candidate = showsValues ? hovered.flatMap { selected.contains($0) ? nil : $0 } : nil
        let items = MenuBarItem.ordered(selected + (candidate.map { [$0] } ?? []))
        let values: [StatusIconRenderer.Value] = items.map { item in
            var value = store.menuBarValue(item, money: money) ?? MenuBarItemsRow.sample(item, money: money)
            if item == candidate {
                value.emphasis = 0.4
            } else if let hovered, selected.contains(hovered), selected.count > 1, item != hovered {
                value.emphasis = 0.3
            }
            return value
        }
        let limits = values.compactMap(\.fraction)
        let input = StatusIconRenderer.Input(
            icon: prefs.menuBarIcon, style: prefs.menuBarStyle, values: values,
            primary: limits.first ?? 0.42, secondary: 0.65, fraction: limits.max() ?? 0.42,
            showsSafety: prefs.showExitSafety,
            exitSafe: network.exitIsSafe,
            ipv6Direct: network.ipv6IsDirect
        )
        HStack(spacing: 14) {
            Spacer()
            Capsule().fill(Color.white.opacity(0.18)).frame(width: 14, height: 4)
            Image(nsImage: StatusIconRenderer.image(input))
            Capsule().fill(Color.white.opacity(0.18)).frame(width: 22, height: 4)
            Text("9:41").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
        .animation(.quiet, value: input)
    }
}

// MARK: - 数据

private struct DataPage: View {
    @Bindable var prefs: Preferences
    let store: UsageStore
    @State private var confirmRebuild = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: L10n.t("会话目录", "Session folder"))
            SettingsRow(title: prefs.dataRootsDisplay.isEmpty ? L10n.t("未找到会话目录", "No session folder found") : prefs.dataRootsDisplay,
                        detail: prefs.dataDirectory == nil ? L10n.t("默认位置", "Default location") : L10n.t("自定义位置", "Custom location")) {
                HStack(spacing: 6) {
                    if prefs.dataDirectory != nil {
                        QuietButton(title: L10n.t("恢复默认", "Reset")) { prefs.dataDirectory = nil }
                    }
                    QuietButton(title: L10n.t("更改…", "Change…")) { DataDirectoryPicker.choose(prefs: prefs) }
                }
            }

            SettingsHeader(title: L10n.t("本地索引", "Local index"))
            SettingsRow(title: L10n.t("已索引", "Indexed"), detail: indexSummary) {
                QuietButton(title: confirmRebuild ? L10n.t("确认重建", "Confirm rebuild") : L10n.t("重建…", "Rebuild…"), destructive: confirmRebuild) {
                    if confirmRebuild {
                        store.rebuildIndex()
                        confirmRebuild = false
                    } else {
                        withAnimation(.quiet) { confirmRebuild = true }
                    }
                }
            }
            if confirmRebuild {
                Text(L10n.t(
                    "重建会重新扫描全部日志（通常几秒）。已被 Claude Code 清理的旧日志对应的历史用量将无法恢复。",
                    "Rebuild scans every log, usually a few seconds. Usage from logs Claude Code already deleted cannot be recovered."
                ))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            Hairline()
            SettingsRow(title: L10n.t("最近一次扫描", "Last scan"), detail: scanSummary) { EmptyView() }

            Text(L10n.t(
                "只读取本机 Claude Code 的会话日志，不会上传任何数据。索引会保留已被 Claude Code 自动清理的历史记录，因此统计可以覆盖更长的时间。",
                "Only this Mac's Claude Code session logs are read. Nothing is uploaded. The index keeps history after Claude Code deletes old logs."
            ))
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
        }
    }

    private var indexSummary: String {
        let records = Int64(store.snapshot?.totalRecords ?? 0)
        let size = ByteCountFormatter.string(fromByteCount: store.cacheSize, countStyle: .file)
        return L10n.t(
            "\(store.indexedFiles) 个日志文件 · \(Fmt.magnitude(records)) 条请求 · 索引 \(size)",
            "\(store.indexedFiles) log files · \(Fmt.magnitude(records)) requests · index \(size)"
        )
    }

    private var scanSummary: String {
        guard let scan = store.lastScan else { return L10n.t("尚未扫描", "Not scanned yet") }
        let ms = Int((scan.duration * 1000).rounded())
        let when = store.lastUpdated.map { Fmt.relative($0) } ?? ""
        return L10n.t("\(when) · 耗时 \(ms) ms · \(scan.filesParsed) 个文件有更新", "\(when) · \(ms) ms · \(scan.filesParsed) files changed")
    }
}

// MARK: - 通用

private struct GeneralPage: View {
    @Bindable var prefs: Preferences
    let store: UsageStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: L10n.t("语言", "Language"))
            SettingsRow(title: L10n.t("界面语言", "App language"), detail: L10n.t("默认跟随系统", "Defaults to the system language")) {
                DropdownButton(options: AppLanguage.allCases.map { ($0, $0.title) }, selection: $prefs.appLanguage)
            }

            SettingsHeader(title: L10n.t("更新", "Updates"))
            UpdateSettingsRow()

            SettingsHeader(title: L10n.t("启动", "Startup"))
            SettingsRow(title: L10n.t("登录时自动启动", "Launch at login"), detail: launchError ?? (LaunchAtLogin.needsApproval ? L10n.t("需要在「系统设置 › 通用 › 登录项」中允许", "Allow it in System Settings > General > Login Items") : nil)) {
                SwitchToggle(isOn: $launchAtLogin)
            }
            .onChange(of: launchAtLogin) { _, enabled in
                do {
                    try LaunchAtLogin.set(enabled)
                    launchError = nil
                } catch {
                    launchError = L10n.t("设置失败：\(error.localizedDescription)", "Could not update: \(error.localizedDescription)")
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            }

            VStack(spacing: 10) {
                MascotView(width: 52)
                    .padding(.bottom, 4)
                Text("Claude Usage Monitor")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(L10n.t("版本 \(Self.version)", "Version \(Self.version)"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.tertiary)
                if let snap = store.snapshot, let first = snap.firstRecord {
                    Text(L10n.t("自 \(Self.day(first)) 起，累计 \(prefs.money.whole(snap.lifetimeCost)) API 等价用量", "Since \(Self.day(first)), \(prefs.money.whole(snap.lifetimeCost)) API-equivalent usage"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondary)
                        .monospacedDigit()
                }
                Text(L10n.t("Claude 标志与 Clawd 吉祥物为 Anthropic 的商标，本项目与 Anthropic 无关。", "The Claude logo and Clawd are trademarks of Anthropic. This project is not affiliated with Anthropic."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.quaternary)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.t("开发版", "dev")
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Localization.shared.locale
        f.dateFormat = Localization.shared.isChinese ? "yyyy年M月d日" : "MMM d, yyyy"
        return f.string(from: date)
    }
}

private struct UpdateSettingsRow: View {
    @State private var hovering = false
    /// 从面板的新版本提示进入时轻轻高亮一下，告诉用户更新在这里
    @State private var highlighted = false

    var body: some View {
        let update = AppUpdate.shared
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("软件更新", "App update"))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.text)
                    Button {
                        update.toggleNotes()
                    } label: {
                        Text(update.statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(hovering || update.notesVisible ? Palette.text : Palette.tertiary)
                            .underline(hovering || update.notesVisible)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
                    .help(L10n.t("查看这个版本更新了什么", "See what changed in this version"))
                }
                Spacer(minLength: 12)
                if update.canInstall {
                    HStack(spacing: 8) {
                        if !update.isIgnored {
                            QuietButton(title: L10n.t("忽略", "Skip")) { withAnimation(.quiet) { update.ignoreAvailableVersion() } }
                                .help(L10n.t("只忽略这个版本，出了新的版本会再提醒", "Skips only this version. A newer one will be shown again."))
                        }
                        QuietButton(title: L10n.t("更新", "Update"), prominent: true) { update.install() }
                    }
                } else if case .downloading = update.phase {
                    EmptyView()
                } else {
                    QuietButton(title: L10n.t("检查", "Check")) { update.check() }
                }
            }
            if case .downloading = update.phase {
                DownloadProgress(fraction: update.downloadFraction)
            }
            if update.notesVisible {
                ReleaseNotes(update: update)
            }
        }
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.accent.opacity(highlighted ? 0.12 : 0))
                .padding(.horizontal, -12)
        )
        .task(id: SettingsNavigation.shared.updateHighlight) {
            let navigation = SettingsNavigation.shared
            guard navigation.updateHighlight != navigation.handledHighlight else { return }
            navigation.handledHighlight = navigation.updateHighlight
            withAnimation(.easeOut(duration: 0.3)) { highlighted = true }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.9)) { highlighted = false }
        }
    }
}

struct DownloadProgress: View {
    var fraction: Double

    var body: some View {
        HStack(spacing: 10) {
            ThinBar(fraction: fraction, color: Palette.accent, delay: 0)
            Text(Fmt.percent(fraction))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }
}

private struct ReleaseNotes: View {
    let update: AppUpdate
    @State private var hoveringLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(update.notesVersion.map { L10n.t("版本 \($0)", "Version \($0)") } ?? L10n.t("更新说明", "Release notes"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                if update.pageURL != nil {
                    Button {
                        update.openReleasePage()
                    } label: {
                        HStack(spacing: 4) {
                            Text(L10n.t("在浏览器中打开", "Open in browser"))
                            SVGIcon(.external, size: 11)
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(hoveringLink ? Palette.accent : Palette.tertiary)
                    }
                    .buttonStyle(StillButtonStyle())
                    .onHover { h in withAnimation(.quiet) { hoveringLink = h } }
                }
            }
            FadingScrollView(maxHeight: 260) {
                if update.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(L10n.t("这个版本没有附带说明。", "This version has no notes."))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)
                } else {
                    MarkdownNotes(markdown: update.notes)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
        )
    }
}
