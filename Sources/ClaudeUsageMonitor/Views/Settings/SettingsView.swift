import SwiftUI
import UsageCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case usage, display, data, general
    var id: String { rawValue }

    var title: String {
        switch self {
        case .usage: "用量"
        case .display: "显示"
        case .data: "数据"
        case .general: "通用"
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

/// 设置窗口：与弹窗一致的暗色毛玻璃 + 顶部图标标签页。
struct SettingsView: View {
    @Bindable var prefs: Preferences
    let store: UsageStore

    @State private var tab: SettingsTab = .usage

    var body: some View {
        VStack(spacing: 0) {
            TabBar(selection: $tab)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Hairline()
            ScrollView {
                Group {
                    switch tab {
                    case .usage: UsagePage(prefs: prefs, store: store)
                    case .display: DisplayPage(prefs: prefs)
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
            SettingsHeader(title: "官方用量")
            SettingsRow(title: "Claude 官方用量", detail: officialDetail(official)) {
                SwitchToggle(isOn: $prefs.officialUsageEnabled)
            }
            if prefs.officialUsageEnabled {
                Hairline()
                SettingsRow(title: "自动续期登录", detail: renewalDetail(official)) {
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
                            QuietButton(title: "在终端中登录", prominent: true) { store.signInToClaudeCode() }
                        } else {
                            QuietButton(title: "重新连接", prominent: true) { official.refresh(.manual) }
                        }
                    }
                    .padding(.vertical, 11)
                }
            }
            Text("5 小时与每周的百分比只来自官方接口，与 Claude Code /usage 完全一致；暂时取不到时显示上次同步的官方数值并注明时间，不做估算。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            SettingsHeader(title: "计费周期")
            SettingsRow(title: "每月扣费日", detail: "当前周期 \(UsageCalculator.periodRange(start: interval.start, end: interval.end, calendar: .current))") {
                DropdownButton(options: (1...31).map { ($0, "每月 \($0) 日") }, selection: $prefs.billingAnchorDay)
            }
            Hairline()
            SettingsRow(
                title: "重置时刻",
                detail: clock == nil ? "与每周限额相同，同步后自动对齐" : "与每周限额相同，这一刻之前的用量仍计入上一周期"
            ) {
                Text(clock.map { String(format: "%02d:%02d:%02d", $0.hour, $0.minute, billing.billingAnchorSecond) } ?? "—")
                    .font(.system(size: 12.5))
                    .foregroundStyle(clock == nil ? Palette.tertiary : Palette.text)
                    .monospacedDigit()
            }
        }
    }

    private func officialDetail(_ official: OfficialUsageService) -> String {
        let synced = official.usage.map { "上次同步 \(Fmt.relative($0.fetchedAt))" }
        switch official.state {
        case .connected:
            let plan = (official.detectedPlan ?? prefs.plan).map { " · \($0.title)" } ?? ""
            return "已连接\(plan) · \(synced ?? "刚刚同步")，与 Claude Code /usage 一致"
        case .connecting: return "正在连接…"
        case .noCredentials: return "未找到 Claude Code 的登录信息"
        case .denied: return "未获得钥匙串授权"
        case .expired:
            return prefs.autoRenewLogin ? "Claude Code 的登录已过期，且无法自动续期，需要重新登录" : "Claude Code 的登录已过期，开启下方的自动续期即可恢复"
        case .signedOut: return "Claude Code 的登录已失效（登录到期或已退出），需要重新登录"
        case .failed(let message): return "暂时无法获取（\(message)），稍后自动重试" + (synced.map { " · \($0)" } ?? "")
        case .disabled: return "已关闭，菜单栏与面板不显示 5 小时 / 每周用量"
        }
    }

    private func renewalDetail(_ official: OfficialUsageService) -> String {
        var status: [String] = []
        if let renewed = official.lastRenewal { status.append("上次续期 \(LimitsSection.moment(renewed))") }
        if let until = official.loginExpiresAt { status.append("登录有效期至 \(Self.day(until))") }
        let text = "Claude Code 的登录约 8 小时过期，到期前按 Claude Code 相同的方式续期，不影响 Claude Code 的使用"
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
        case .denied: "首次连接时，系统会询问是否允许读取「Claude Code-credentials」，请选择「始终允许」。"
        case .noCredentials, .signedOut, .expired: "将打开终端运行 claude auth login，在浏览器中完成授权后自动恢复。"
        default: "问题解决后会自动恢复，也可以立即重试。"
        }
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }
}

// MARK: - 显示

private struct DisplayPage: View {
    @Bindable var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "菜单栏")
            MenuBarPreview(prefs: prefs)
                .padding(.vertical, 12)
            SettingsRow(title: "图标") {
                PillSegmented(options: MenuBarIcon.allCases.map { ($0, $0 == .mascot ? "Clawd" : "Claude 标志") }, selection: $prefs.menuBarIcon)
            }
            Hairline()
            SettingsRow(title: "样式") {
                DropdownButton(options: MenuBarStyle.allCases.map { ($0, $0.title) }, selection: $prefs.menuBarStyle)
            }
            Hairline()
            SettingsRow(title: "显示数值") {
                DropdownButton(options: MenuBarMetric.allCases.map { ($0, $0.title) }, selection: $prefs.menuBarMetric)
            }

            SettingsHeader(title: "货币")
            SettingsRow(title: "显示货币") {
                PillSegmented(options: [(MoneyFormat.Unit.usd, "美元 $"), (.cny, "人民币 ¥")], selection: $prefs.currency)
            }
            if prefs.currency == .cny {
                Hairline()
                SettingsRow(title: "汇率") {
                    NumberField(value: $prefs.exchangeRate, prefix: "1 $ =", suffix: "¥", fractionDigits: 2, width: 44)
                }
            }

            SettingsHeader(title: "提醒")
            SettingsRow(title: "用量预警通知", detail: "超过预警线、以及达到 95% 时各提醒一次") {
                SwitchToggle(isOn: $prefs.notificationsEnabled)
            }
            Hairline()
            SettingsRow(title: "预警线", detail: "超过后进度条与菜单栏图标变为琥珀色") {
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

/// 菜单栏效果的实时预览
private struct MenuBarPreview: View {
    let prefs: Preferences

    var body: some View {
        let input = StatusIconRenderer.Input(
            icon: prefs.menuBarIcon, style: prefs.menuBarStyle,
            text: prefs.menuBarMetric == .today || prefs.menuBarMetric == .cycle ? prefs.money.compact(1234) : "42%",
            primary: 0.42, secondary: 0.65, level: .normal
        )
        HStack(spacing: 14) {
            Spacer()
            Capsule().fill(Color.white.opacity(0.18)).frame(width: 14, height: 4)
            Image(nsImage: StatusIconRenderer.image(input))
                .renderingMode(.template)
                .foregroundStyle(Palette.text)
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
            SettingsHeader(title: "会话目录")
            SettingsRow(title: prefs.dataRootsDisplay.isEmpty ? "未找到会话目录" : prefs.dataRootsDisplay,
                        detail: prefs.dataDirectory == nil ? "默认位置" : "自定义位置") {
                HStack(spacing: 6) {
                    if prefs.dataDirectory != nil {
                        QuietButton(title: "恢复默认") { prefs.dataDirectory = nil }
                    }
                    QuietButton(title: "更改…") { DataDirectoryPicker.choose(prefs: prefs) }
                }
            }

            SettingsHeader(title: "本地索引")
            SettingsRow(title: "已索引", detail: indexSummary) {
                QuietButton(title: confirmRebuild ? "确认重建" : "重建…", destructive: confirmRebuild) {
                    if confirmRebuild {
                        store.rebuildIndex()
                        confirmRebuild = false
                    } else {
                        withAnimation(.quiet) { confirmRebuild = true }
                    }
                }
            }
            if confirmRebuild {
                Text("重建会重新扫描全部日志（通常几秒）。已被 Claude Code 清理的旧日志对应的历史用量将无法恢复。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            Hairline()
            SettingsRow(title: "最近一次扫描", detail: scanSummary) { EmptyView() }

            Text("只读取本机 Claude Code 的会话日志，不会上传任何数据。索引会保留已被 Claude Code 自动清理的历史记录，因此统计可以覆盖更长的时间。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
        }
    }

    private var indexSummary: String {
        let records = Int64(store.snapshot?.totalRecords ?? 0)
        let size = ByteCountFormatter.string(fromByteCount: store.cacheSize, countStyle: .file)
        return "\(store.indexedFiles) 个日志文件 · \(Fmt.chinese(records)) 条请求 · 索引 \(size)"
    }

    private var scanSummary: String {
        guard let scan = store.lastScan else { return "尚未扫描" }
        let ms = Int((scan.duration * 1000).rounded())
        let when = store.lastUpdated.map { Fmt.relative($0) } ?? ""
        return "\(when) · 耗时 \(ms) ms · \(scan.filesParsed) 个文件有更新"
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
            SettingsHeader(title: "启动")
            SettingsRow(title: "登录时自动启动", detail: launchError ?? (LaunchAtLogin.needsApproval ? "需要在「系统设置 › 通用 › 登录项」中允许" : nil)) {
                SwitchToggle(isOn: $launchAtLogin)
            }
            .onChange(of: launchAtLogin) { _, enabled in
                do {
                    try LaunchAtLogin.set(enabled)
                    launchError = nil
                } catch {
                    launchError = "设置失败：\(error.localizedDescription)"
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            }

            VStack(spacing: 10) {
                MascotView(width: 52)
                    .padding(.bottom, 4)
                Text("Claude Usage Monitor")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text("版本 \(Self.version)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.tertiary)
                if let snap = store.snapshot, let first = snap.firstRecord {
                    Text("自 \(Self.day(first)) 起，累计 \(prefs.money.whole(snap.lifetimeCost)) API 等价用量")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondary)
                        .monospacedDigit()
                }
                Text("Claude 标志与 Clawd 吉祥物为 Anthropic 的商标，本项目与 Anthropic 无关。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.quaternary)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日"
        return f.string(from: date)
    }
}
