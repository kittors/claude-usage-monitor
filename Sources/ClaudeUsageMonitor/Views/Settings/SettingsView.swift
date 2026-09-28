import SwiftUI
import UsageCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case plan, display, data, general
    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: "套餐"
        case .display: "显示"
        case .data: "数据"
        case .general: "通用"
        }
    }

    var icon: Icon {
        switch self {
        case .plan: .gauge
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

    @State private var tab: SettingsTab = .plan

    var body: some View {
        VStack(spacing: 0) {
            TabBar(selection: $tab)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Hairline()
            ScrollView {
                Group {
                    switch tab {
                    case .plan: PlanPage(prefs: prefs, store: store)
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

// MARK: - 套餐

private struct PlanPage: View {
    @Bindable var prefs: Preferences
    let store: UsageStore

    @State private var officialFive = ""
    @State private var officialWeek = ""
    @State private var calibratedAt: Date?

    var body: some View {
        let money = prefs.money
        let interval = UsageCalculator.billingInterval(now: Date(), anchorDay: prefs.billingAnchorDay, calendar: .current)
        let official = store.official
        let connected = official.state == .connected
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "用量数据")
            SettingsRow(title: "Claude 官方用量", detail: officialDetail(official)) {
                SwitchToggle(isOn: $prefs.officialUsageEnabled)
            }
            if prefs.officialUsageEnabled, !connected, official.state != .connecting {
                Hairline()
                HStack {
                    Text("首次连接时，系统会询问是否允许读取「Claude Code-credentials」，请选择「始终允许」。")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    QuietButton(title: "重新连接", prominent: true) { official.refresh(force: true) }
                }
                .padding(.vertical, 11)
            }

            SettingsHeader(title: "本周额度")
            WeeklyStartRows(prefs: prefs, store: store)

            SettingsHeader(title: "订阅计划")
            VStack(alignment: .leading, spacing: 8) {
                PillSegmented(
                    options: Plan.allCases.map { ($0, $0.title) },
                    selection: Binding(get: { prefs.plan }, set: { prefs.apply(plan: $0) })
                )
                Text(official.detectedPlan != nil
                     ? "已从 Claude 账号（服务端）识别为 \(official.detectedPlan!.title)"
                     : "\(prefs.plan.tagline) · 默认额度 5 小时 \(money.whole(prefs.plan.fiveHourBudget)) · 每周 \(money.whole(prefs.plan.weeklyBudget))")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(.vertical, 11)

            SettingsHeader(title: "计费周期")
            SettingsRow(title: "每月扣费日", detail: "当前周期 \(Self.day(interval.start)) – \(Self.day(interval.end.addingTimeInterval(-1)))") {
                DropdownButton(options: (1...31).map { ($0, "每月 \($0) 日") }, selection: $prefs.billingAnchorDay)
            }

            SettingsHeader(title: connected ? "额度预算（离线估算与速率预测）" : "额度预算")
            SettingsRow(title: "5 小时额度", detail: connected && prefs.budgetsCalibrated ? "已根据官方用量自动校准" : "以 API 等价费用衡量") {
                NumberField(value: $prefs.fiveHourBudget, prefix: "$")
            }
            Hairline()
            SettingsRow(title: "每周额度") {
                NumberField(value: $prefs.weeklyBudget, prefix: "$")
            }
            Hairline()
            SettingsRow(title: "每周重置时间") {
                HStack(spacing: 6) {
                    DropdownButton(options: (1...7).map { ($0, Self.weekdays[$0 - 1]) }, selection: $prefs.weeklyResetWeekday)
                    DropdownButton(options: (0..<48).map { ($0, String(format: "%02d:%02d", $0 / 2, ($0 % 2) * 30)) }, selection: resetSlot)
                }
            }

            if !connected {
            SettingsHeader(title: "对照官方用量校准")
            SettingsRow(title: "官方显示的用量", detail: "在 Claude 应用的用量面板或 /usage 中查看") {
                HStack(spacing: 8) {
                    Text("5 小时").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                    PercentField(text: $officialFive)
                    Text("本周").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary).padding(.leading, 4)
                    PercentField(text: $officialWeek)
                }
            }
            Hairline()
            HStack {
                Text(calibrationStatus(money: money))
                    .font(.system(size: 12))
                    .foregroundStyle(calibratedAt == nil ? Palette.tertiary : Palette.live)
                    .monospacedDigit()
                Spacer()
                QuietButton(title: "校准", prominent: Double(officialFive) != nil || Double(officialWeek) != nil, action: calibrate)
            }
            .padding(.vertical, 11)
            }
        }
    }

    private func officialDetail(_ official: OfficialUsageService) -> String {
        switch official.state {
        case .connected:
            let plan = " · \((official.detectedPlan ?? prefs.plan).title)"
            let when = official.usage.map { " · \(Fmt.relative($0.fetchedAt))同步" } ?? ""
            return "已连接\(plan)\(when)，与 Claude Code /usage 一致"
        case .connecting: return "正在连接…"
        case .noCredentials: return "未找到 Claude Code 登录信息，请先在终端运行 claude 并登录"
        case .denied: return "未获得钥匙串授权"
        case .expired: return "登录凭据已过期，运行一次 Claude Code 会自动刷新，随后这里自动恢复"
        case .failed(let message): return "暂时无法获取（\(message)），稍后自动重试"
        case .disabled: return "已关闭，5 小时与每周用量按本机日志估算"
        }
    }

    /// 以 30 分钟为粒度的重置时刻
    private var resetSlot: Binding<Int> {
        Binding(
            get: { prefs.weeklyResetHour * 2 + (prefs.weeklyResetMinute >= 30 ? 1 : 0) },
            set: { slot in
                prefs.weeklyResetHour = slot / 2
                prefs.weeklyResetMinute = (slot % 2) * 30
            }
        )
    }

    private func calibrationStatus(money: MoneyFormat) -> String {
        if let calibratedAt, Date().timeIntervalSince(calibratedAt) < 3 { return "已根据官方用量更新额度" }
        guard let snap = store.snapshot else { return "暂无本机数据" }
        return "本机当前：5 小时 \(money.whole(snap.fiveHour.cost)) · 本周 \(money.whole(snap.weekly.cost))"
    }

    private func calibrate() {
        guard let snap = store.snapshot else { return }
        if let p = Double(officialFive), p > 0, snap.fiveHour.cost > 0 {
            prefs.fiveHourBudget = (snap.fiveHour.cost / (p / 100)).rounded()
        }
        if let p = Double(officialWeek), p > 0, snap.weekly.cost > 0 {
            prefs.weeklyBudget = (snap.weekly.cost / (p / 100)).rounded()
        }
        prefs.budgetsCalibrated = true
        officialFive = ""
        officialWeek = ""
        withAnimation(.quiet) { calibratedAt = Date() }
    }

    static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }
}

/// 本周起算时间：默认自动（例行重置，或检测 / 推算到的中途重置），也可以手动指定
private struct WeeklyStartRows: View {
    @Bindable var prefs: Preferences
    let store: UsageStore

    private static let slotMinutes = 15

    var body: some View {
        let cycleStart = store.snapshot?.weeklyCycleStart
            ?? UsageCalculator.weeklyInterval(now: Date(), settings: prefs.usageSettings).start
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "起算时间", detail: detail(cycleStart: cycleStart)) {
                PillSegmented(
                    options: [(false, "自动"), (true, "手动")],
                    selection: Binding(
                        get: { prefs.weeklyStartOverride != nil },
                        set: { manual in
                            withAnimation(.quiet) {
                                prefs.weeklyStartOverride = manual ? defaultManualStart(cycleStart: cycleStart) : nil
                            }
                        }
                    )
                )
            }
            if let override = prefs.weeklyStartOverride {
                Hairline()
                SettingsRow(title: "中途重置发生在", detail: "只对本周期有效，下次例行重置后自动恢复为自动") {
                    HStack(spacing: 6) {
                        DropdownButton(options: dayOptions(cycleStart: cycleStart), selection: dayBinding(override, cycleStart: cycleStart))
                        DropdownButton(options: slotOptions(day: startOfDay(override), cycleStart: cycleStart),
                                       selection: slotBinding(override, cycleStart: cycleStart))
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private func detail(cycleStart: Date) -> String {
        let routine = "上次例行重置（\(LimitsSection.weekday(cycleStart))）"
        guard let snap = store.snapshot else { return "从\(routine)算起" }
        let when = LimitsSection.moment(snap.weeklyStart)
        switch snap.weeklyStartSource {
        case .scheduled:
            return store.isUsingOfficialLimits ? "从\(routine)算起，检测到中途重置会自动调整" : "从\(routine)算起"
        case .detected:
            let prefix = prefs.weeklyStartOverride != nil ? "之后又检测到一次中途重置" : "检测到中途重置"
            return "\(prefix)：官方百分比在 \(when) 之后出现下降，本机费用从这之后算起"
        case .inferred:
            return "推算本周额度约在 \(when) 被中途重置过（根据本机费用与官方百分比的变化），本机费用从这时算起"
        case .manual:
            return "本机费用从 \(when) 算起，用于本周用量与额度推算"
        }
    }

    // MARK: 手动指定

    private func startOfDay(_ date: Date) -> Date { Calendar.current.startOfDay(for: date) }

    /// 可选范围：本周期起点之后、现在之前
    private func clamp(_ date: Date, cycleStart: Date) -> Date {
        min(max(date, cycleStart.addingTimeInterval(60)), Date().addingTimeInterval(-60))
    }

    private func defaultManualStart(cycleStart: Date) -> Date {
        let current = store.snapshot?.weeklyStart ?? cycleStart
        let base = current > cycleStart ? current : max(startOfDay(Date()), cycleStart)
        let step = Double(Self.slotMinutes * 60)
        let rounded = Date(timeIntervalSince1970: (base.timeIntervalSince1970 / step).rounded(.down) * step)
        return clamp(rounded > cycleStart ? rounded : rounded.addingTimeInterval(step), cycleStart: cycleStart)
    }

    private func dayOptions(cycleStart: Date) -> [(value: Date, title: String)] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        var days: [(Date, String)] = []
        var day = startOfDay(cycleStart)
        while day <= Date() {
            days.append((day, cal.isDateInToday(day) ? "今天" : (cal.isDateInYesterday(day) ? "昨天" : f.string(from: day))))
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// 某一天里可选的时刻（以 15 分钟为粒度）
    private func validSlots(day: Date, cycleStart: Date) -> [Int] {
        let now = Date()
        return (0..<(24 * 60 / Self.slotMinutes)).filter { slot in
            let t = day.addingTimeInterval(Double(slot * Self.slotMinutes * 60))
            return t > cycleStart && t < now
        }
    }

    private func slotOptions(day: Date, cycleStart: Date) -> [(value: Int, title: String)] {
        validSlots(day: day, cycleStart: cycleStart).map { slot in
            let minutes = slot * Self.slotMinutes
            return (slot, String(format: "%02d:%02d", minutes / 60, minutes % 60))
        }
    }

    private func slot(of date: Date) -> Int {
        Int(date.timeIntervalSince(startOfDay(date)) / 60) / Self.slotMinutes
    }

    private func dayBinding(_ override: Date, cycleStart: Date) -> Binding<Date> {
        Binding(
            get: { startOfDay(override) },
            set: { day in
                // 换日期时尽量保留原来的时刻，超出范围就取最接近的可选时刻
                let valid = validSlots(day: day, cycleStart: cycleStart)
                let wanted = slot(of: override)
                guard let chosen = valid.min(by: { abs($0 - wanted) < abs($1 - wanted) }) else { return }
                prefs.weeklyStartOverride = clamp(day.addingTimeInterval(Double(chosen * Self.slotMinutes * 60)), cycleStart: cycleStart)
            }
        )
    }

    private func slotBinding(_ override: Date, cycleStart: Date) -> Binding<Int> {
        Binding(
            get: { slot(of: override) },
            set: { slot in
                let day = startOfDay(override)
                prefs.weeklyStartOverride = clamp(day.addingTimeInterval(Double(slot * Self.slotMinutes * 60)), cycleStart: cycleStart)
            }
        )
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
                    ThinSlider(value: $prefs.warningThreshold, range: 0.5...0.95, step: 0.05)
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
