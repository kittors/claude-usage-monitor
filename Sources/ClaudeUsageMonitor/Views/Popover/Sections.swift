import SwiftUI
import UsageCore

// MARK: - 用量限额

/// 官方限额：数值与 Claude Code `/usage` 完全一致，不做任何估算
struct LimitsSection: View {
    let store: UsageStore
    let prefs: Preferences

    var body: some View {
        let rows = store.limitRows
        let official = store.official
        VStack(alignment: .leading, spacing: 13) {
            SectionTitle(title: L10n.t("用量限额", "Limits")) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let status = statusText(official, now: context.date)
                    Text(status)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.25), value: status)
                }
                .help(statusHelp(official))
            }
            if rows.isEmpty {
                ForEach([L10n.t("5 小时", "5-hour"), L10n.t("本周 · 全部模型", "Week · all models")], id: \.self) { title in
                    PlaceholderRow(title: title)
                }
            } else {
                ForEach(rows) { row in
                    LimitRowView(row: row, style: prefs.resetTimeStyle, countdown: prefs.showsResetCountdown)
                }
            }
            if rows.isEmpty || official.state.awaitingLogin {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Self.unavailableReason(official.state, fetching: official.isFetching))
                        .font(.caption)
                        .foregroundStyle(Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if official.state.awaitingLogin {
                        FooterButton(icon: .terminal, title: L10n.t("在终端中登录 Claude Code", "Sign in with Claude Code in Terminal")) { store.signInToClaudeCode() }
                            .padding(.leading, -8)
                    }
                }
            }
        }
    }

    private func statusText(_ official: OfficialUsageService, now: Date) -> String {
        if let notice = official.notice { return notice }
        if official.isFetching { return L10n.t("正在同步…", "Syncing…") }
        guard let usage = official.usage else {
            if official.state == .connecting, !official.isFetching { return L10n.t("尚未查询", "Not checked yet") }
            return Self.shortReason(official.state)
        }
        let synced = L10n.t("\(Fmt.relative(usage.fetchedAt, now: now))同步", "Synced \(Fmt.relative(usage.fetchedAt, now: now))")
        if official.state == .connected { return synced }
        var reason = Self.shortReason(official.state)
        if official.rateLimitedUntil > now {
            let minutes = max(1, Int((official.rateLimitedUntil.timeIntervalSince(now) / 60).rounded(.up)))
            reason += L10n.t("，约 \(minutes) 分钟后重试", ", retry in about \(minutes) min")
        }
        return "\(synced) · \(reason)"
    }

    private func statusHelp(_ official: OfficialUsageService) -> String {
        var lines = [L10n.t(
            "来自 Claude 官方用量接口（与 Claude Code /usage 相同）。Claude Code 正在使用时，消耗够让数字变化就同步；随时可以点「立即刷新」",
            "From the same endpoint as Claude Code /usage. While Claude Code is in use, it syncs once usage is enough to change the numbers. Refresh works any time."
        )]
        if let usage = official.usage { lines.append(L10n.t("上次同步：\(Self.moment(usage.fetchedAt))", "Last sync: \(Self.moment(usage.fetchedAt))")) }
        if official.state != .connected, official.usage != nil { lines.append(Self.unavailableReason(official.state, fetching: official.isFetching)) }
        return lines.joined(separator: "\n")
    }

    static func shortReason(_ state: OfficialUsageService.State) -> String {
        switch state {
        case .connected: L10n.t("已连接", "Connected")
        case .connecting: L10n.t("正在连接…", "Connecting…")
        case .disabled: L10n.t("已关闭", "Off")
        case .noCredentials: L10n.t("未登录", "Not signed in")
        case .denied: L10n.t("未授权", "Not allowed")
        case .expired: L10n.t("登录已过期", "Login expired")
        case .signedOut: L10n.t("需要重新登录", "Sign in again")
        case .failed(let message): message
        }
    }

    /// 暂时没有官方数据时的说明
    static func unavailableReason(_ state: OfficialUsageService.State, fetching: Bool) -> String {
        switch state {
        case .connected, .connecting:
            fetching
                ? L10n.t("正在获取官方用量…", "Fetching official usage…")
                : L10n.t("还没有官方数据。Claude Code 正在使用时会自动查询，也可以点「立即刷新」。", "No official numbers yet. They are checked while Claude Code is in use, or tap Refresh.")
        case .disabled: L10n.t("官方用量已关闭，可在「设置 › 用量」中开启。", "Official usage is off. Turn it on in Settings > Usage.")
        case .noCredentials: L10n.t("没有找到 Claude Code 的登录信息，登录后即可显示官方用量。", "No Claude Code login found. Sign in to show official usage.")
        case .denied: L10n.t("没有获得钥匙串授权，请在「设置 › 用量」中重新连接，并在系统弹窗中选择「始终允许」。", "Keychain access was denied. Reconnect in Settings > Usage and choose Always Allow.")
        case .expired: L10n.t("Claude Code 的登录已过期。开启「设置 › 用量 › 自动续期登录」，或重新登录。", "The Claude Code login has expired. Turn on automatic renewal in Settings > Usage, or sign in again.")
        case .signedOut: L10n.t("Claude Code 的登录已失效（登录到期或已退出），重新登录后自动恢复。", "The Claude Code login is no longer valid. Sign in again and this app recovers.")
        case .failed(let message): L10n.t("暂时无法获取官方用量（\(message)），稍后自动重试。", "Official usage is unavailable (\(message)). Retrying shortly.")
        }
    }
}

private struct LimitRowView: View {
    let row: LimitRow
    /// 重置时间的写法，以及要不要在右侧显示精确到秒的倒计时
    let style: ResetTimeStyle
    let countdown: Bool
    /// 刚刚上涨了多少，几秒后淡出
    @State private var rise: Int?
    @State private var riseCount = 0

    var body: some View {
        let color = Palette.level(row.fraction)
        // 每秒刷新：倒计时、随时间前进的安全线和悬停说明用同一个时刻
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let line = row.paceLine(now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title)
                        .font(.rowLabel)
                        .foregroundStyle(Palette.text)
                    Spacer()
                    if let rise {
                        Text("+\(rise)%")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(color.opacity(0.8))
                            .monospacedDigit()
                            .transition(.opacity.combined(with: .offset(y: 4)))
                    }
                    Text("\(row.percent)%")
                        .font(.rowValue)
                        .foregroundStyle(color)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: row.fraction))
                }
                .contentShape(Rectangle())
                .help(help(line))
                ThinBar(
                    fraction: row.fraction, color: color,
                    mark: line?.fraction, exceeded: line?.isExceeded(by: row.fraction) ?? false, markLabel: markLabel(line)
                )
                if row.reset != .none {
                    let caption = resetCaption(now: context.date)
                    HStack(spacing: 8) {
                        Text(caption.text)
                        Spacer(minLength: 8)
                        if let remaining = caption.remaining {
                            Text(remaining)
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.tertiary)
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .help(help(line))
                }
            }
        }
        .onChange(of: row.percent) { old, new in
            guard new > old else { return }
            withAnimation(.easeOut(duration: 0.25)) { rise = new - old }
            riseCount += 1
        }
        .task(id: riseCount) {
            guard rise != nil else { return }
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { rise = nil }
        }
    }

    /// 指针停在进度条上时，安全线上方的标签：安全线是多少，还能用多少或超了多少
    private func markLabel(_ line: LimitPace.Line?) -> BarMarkLabel? {
        guard let line else { return nil }
        let value = L10n.t("安全线 \(Self.percent(line.fraction))", "Safe line \(Self.percent(line.fraction))")
        if line.isExceeded(by: row.fraction) {
            let over = Self.percent(row.fraction - line.fraction)
            return BarMarkLabel(value: value, detail: L10n.t("超出 \(over)", "\(over) over"), alert: true)
        }
        if row.fraction > line.fraction {
            return BarMarkLabel(value: value, detail: L10n.t("窗口刚开始", "Just started"))
        }
        let left = Self.percent(line.fraction - row.fraction)
        return BarMarkLabel(value: value, detail: L10n.t("还可用 \(left)", "\(left) left"))
    }

    /// 保留一位小数，正好是整数时不带：28.6%、50%
    private static func percent(_ fraction: Double) -> String {
        let tenths = (fraction * 1000).rounded()
        return tenths.truncatingRemainder(dividingBy: 10) == 0 ? "\(Int(tenths / 10))%" : String(format: "%.1f%%", tenths / 10)
    }

    /// 悬停说明：什么时候重置，安全线在哪、怎么来的，超了多少
    private func help(_ line: LimitPace.Line?) -> String {
        var parts: [String] = []
        if let reset = row.resetsAt {
            parts.append(L10n.t("重置时间：\(LimitsSection.fullDate(reset))（\(LimitsSection.zoneName)）", "Resets \(LimitsSection.fullDate(reset)) (\(LimitsSection.zoneName))"))
        }
        guard let line else { return parts.joined(separator: "\n") }
        let mark = Self.percent(line.fraction)
        if let day = line.day {
            parts.append(L10n.t(
                "安全线 \(mark)：今天是这一周的第 \(day) 天，今天结束前用到 \(day)/7 都不会提前用完",
                "Safe line \(mark): day \(day) of 7, so staying under \(day)/7 by the end of today lasts the week"
            ))
        } else {
            let elapsed = Fmt.countdown(line.elapsed, showSeconds: false)
            parts.append(L10n.t(
                "安全线 \(mark)：5 小时已过 \(elapsed)，用量不超过这个比例就能撑到重置",
                "Safe line \(mark): \(elapsed) of the 5 hours have passed, so staying under this share lasts until the reset"
            ))
        }
        if line.isExceeded(by: row.fraction) {
            let over = Self.percent(row.fraction - line.fraction)
            parts.append(L10n.t("已超出 \(over)，照这个速度会在重置前用完", "\(over) over the line. At this pace the limit runs out before the reset"))
        } else if line.settling, row.fraction > line.fraction {
            parts.append(L10n.t("窗口刚开始，先不提示超线", "The window just started, so going over is not flagged yet"))
        }
        return parts.joined(separator: "\n")
    }

    /// 左边是什么时候重置，右边（打开倒计时时）是还剩多久，精确到秒
    private func resetCaption(now: Date) -> (text: String, remaining: String?) {
        let date: Date
        switch row.reset {
        case .countdown(let reset):
            guard reset > now else { return (L10n.t("已重置", "Reset"), nil) }
            // 默认写法下，5 小时窗口本来就显示「还剩多久」
            if style == .weekday && !countdown {
                let left = Fmt.countdown(reset.timeIntervalSince(now))
                return (L10n.t("\(left)后重置", "Resets in \(left)"), nil)
            }
            date = reset
        case .weekday(let reset):
            guard reset > now else { return (L10n.t("已重置", "Reset"), nil) }
            date = reset
        case .elapsed: return (L10n.t("已重置", "Reset"), nil)
        case .idle: return (L10n.t("空闲中", "Idle"), nil)
        case .none: return ("", nil)
        }
        let moment = LimitsSection.resetMoment(date, style: style)
        return (L10n.t("\(moment) 重置", "Resets \(moment)"), countdown ? LimitsSection.clock(date.timeIntervalSince(now)) : nil)
    }
}

/// 还没有官方数据时的占位行
private struct PlaceholderRow: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.rowLabel)
                    .foregroundStyle(Palette.secondary)
                Spacer()
                Text("—")
                    .font(.rowValue)
                    .foregroundStyle(Palette.tertiary)
            }
            ThinBar(fraction: 0, color: Palette.tertiary)
        }
    }
}

extension LimitsSection {
    /// 官方的重置时间常带有亚秒误差（例如 13:59:59.9），就近取整到分钟再显示
    static func weekday(_ date: Date) -> String {
        formatter("EEE HH:mm").string(from: roundedToMinute(date))
    }

    /// 重置时刻，按系统当前时区。官方时间常带亚秒误差（例如 21:59:59.9），就近取整到分钟
    static func resetMoment(_ date: Date, style: ResetTimeStyle) -> String {
        switch style {
        case .weekday: dayTime(date)
        case .fullDate: fullDate(date)
        }
    }

    /// 今天 22:00 / 明天 22:00 / 周六 22:00
    static func dayTime(_ date: Date) -> String {
        let rounded = roundedToMinute(date)
        let cal = Calendar.autoupdatingCurrent
        let time = formatter("HH:mm").string(from: rounded)
        if cal.isDateInToday(rounded) { return L10n.t("今天 \(time)", "today \(time)") }
        if cal.isDateInTomorrow(rounded) { return L10n.t("明天 \(time)", "tomorrow \(time)") }
        return formatter("EEE HH:mm").string(from: rounded)
    }

    /// 2026年10月3日 22:00 / Oct 3, 2026 22:00
    static func fullDate(_ date: Date) -> String {
        formatter(Localization.shared.isChinese ? "yyyy年M月d日 HH:mm" : "MMM d, yyyy HH:mm").string(from: roundedToMinute(date))
    }

    /// 还剩多久，精确到秒：3 天 14:25:07 / 04:50:12
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let days = total / 86_400
        let hms = String(format: "%02d:%02d:%02d", total % 86_400 / 3600, total % 3600 / 60, total % 60)
        return days > 0 ? L10n.t("\(days) 天 \(hms)", "\(days)d \(hms)") : hms
    }

    /// 系统当前时区的简称，例如 GMT+8。查一次要读时区名称数据，面板每秒刷新时都要用，记下来。
    static var zoneName: String {
        let zone = TimeZone.autoupdatingCurrent
        let locale = Localization.shared.locale
        let key = "\(zone.identifier)|\(locale.identifier)"
        if let name = zoneNames[key] { return name }
        let name = zone.localizedName(for: .shortStandard, locale: locale) ?? zone.identifier
        zoneNames[key] = name
        return name
    }

    private static var zoneNames: [String: String] = [:]

    static func formatter(_ format: String) -> DateFormatter {
        DateFormats.formatter(format, locale: Localization.shared.locale)
    }

    private static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    /// 今天 05:32 / 昨天 05:32 / 周一 05:32
    static func moment(_ date: Date) -> String {
        let cal = Calendar.current
        let time = formatter("HH:mm").string(from: date)
        if cal.isDateInToday(date) { return L10n.t("今天 \(time)", "Today \(time)") }
        if cal.isDateInYesterday(date) { return L10n.t("昨天 \(time)", "Yesterday \(time)") }
        return formatter("EEE HH:mm").string(from: date)
    }
}

// MARK: - 本期消耗

/// 本月周期 / 本周期 / 每日。等宽标签，选中项用面板里已有的浅色块。
/// 选中块是同一块在下面平移；标签的两种样式叠在一起淡入淡出，过渡时不用逐帧重画文字。
private struct SpanTabs: View {
    /// 直接拿偏好而不是 Binding：在父视图里创建 Binding 会读一次当前值，切换时整个本期消耗区都要跟着重建
    let prefs: Preferences

    var body: some View {
        let selection = prefs.costSpan
        let spans = CostSpan.allCases
        let index = CGFloat(spans.firstIndex(of: selection) ?? 0)
        HStack(spacing: 2) {
            ForEach(spans) { span in
                let selected = span == selection
                ZStack {
                    label(span.title, weight: .regular, color: Palette.secondary)
                        .opacity(selected ? 0 : 1)
                    label(span.title, weight: .medium, color: Palette.text)
                        .opacity(selected ? 1 : 0)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard span != prefs.costSpan else { return }
                    // 选中块滑过去，下面的数字、柱状图、模型行一起过渡
                    withAnimation(.disclosure) { prefs.costSpan = span }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(span.title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .background(alignment: .leading) {
            GeometryReader { geo in
                let width = (geo.size.width - 2 * CGFloat(spans.count - 1)) / CGFloat(spans.count)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.13))
                    .frame(width: width, height: geo.size.height)
                    .offset(x: index * (width + 2))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private func label(_ title: String, weight: Font.Weight, color: Color) -> some View {
        Text(title)
            .font(.system(size: 12, weight: weight))
            .foregroundStyle(color)
            .lineLimit(1)
            .compositingGroup()
    }
}

/// 本期消耗。三个周期的数字都已排好叠在一起，切换周期时只是淡入淡出。
/// 这里的 body 不读当前选中的周期：切换时只有跟周期有关的几个小视图重新计算，整块内容不用重建。
struct CycleSection: View {
    let snapshot: UsageSnapshot
    @Bindable var prefs: Preferences

    var body: some View {
        let money = prefs.money
        let figures = SpanFigures.all(snapshot, money: money)

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("本期消耗", "Spend"))
                    .font(.sectionTitle)
                    .foregroundStyle(Palette.secondary)
                SpanLayers(prefs: prefs) { s in
                    Text(figures[s]?.range ?? L10n.t("同步每周限额后显示本周区间", "The weekly range appears after the weekly limit syncs"))
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SpanTabs(prefs: prefs)

            SpanAvailable(prefs: prefs, snapshot: snapshot) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        // 每分钟刷新：日均和预计随时间变化，没有新消耗时也不会停在旧值上
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            CycleHeader(snapshot: snapshot, prefs: prefs, now: context.date)
                        }

                        HStack(spacing: 0) {
                            SpanStat(prefs: prefs, label: L10n.t("总 Tokens", "Tokens"), values: figures.mapValues(\.tokens), help: figures.mapValues(\.tokensHelp))
                            Spacer()
                            SpanStat(prefs: prefs, label: L10n.t("请求", "Requests"), values: figures.mapValues(\.requests))
                            Spacer()
                            // 今天的花费不随周期变化
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(L10n.t("今日", "Today"))
                                    .font(.caption)
                                    .foregroundStyle(Palette.tertiary)
                                Text(money.whole(snapshot.today?.cost ?? 0))
                                    .font(.rowValue)
                                    .foregroundStyle(Palette.text)
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            }
                        }

                        HStack(alignment: .top, spacing: 0) {
                            TokenColumn(prefs: prefs, label: L10n.t("新增输入", "Input"), color: Palette.input, figures: figures.mapValues(\.input))
                            TokenColumn(prefs: prefs, label: L10n.t("输出", "Output"), color: Palette.output, figures: figures.mapValues(\.output))
                            TokenColumn(prefs: prefs, label: L10n.t("缓存创建", "Cache write"), color: Palette.cacheWrite, figures: figures.mapValues(\.cacheWrite))
                            TokenColumn(prefs: prefs, label: L10n.t("缓存命中", "Cache read"), color: Palette.cacheRead, figures: figures.mapValues(\.cacheRead))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(L10n.t("缓存命中率", "Cache hit rate"))
                                    .font(.rowLabel)
                                    .foregroundStyle(Palette.text)
                                Spacer()
                                SpanLayers(prefs: prefs, alignment: .trailing) { s in
                                    if let f = figures[s] { Text(f.saved) }
                                }
                                .font(.caption)
                                .foregroundStyle(Palette.tertiary)
                                .help(L10n.t("如果没有 Prompt Caching，这些命中缓存的 token 需要按原价计费", "Without prompt caching, these tokens would be billed at the full input price."))
                                SpanLayers(prefs: prefs, alignment: .trailing) { s in
                                    if let f = figures[s] {
                                        Text(f.hitRate).contentTransition(.numericText(value: f.hitRateValue))
                                    }
                                }
                                .font(.rowValue)
                                .foregroundStyle(Palette.text)
                                .monospacedDigit()
                            }
                            SpanBar(prefs: prefs, fractions: figures.mapValues(\.hitRateValue))
                        }
                    }
                    ModelLists(prefs: prefs, snapshot: snapshot, money: money)
                }
            }
        }
    }

    static func day(_ date: Date) -> String {
        LimitsSection.formatter(Localization.shared.isChinese ? "M月d日" : "MMM d").string(from: date)
    }

    static func dayWithWeekday(_ date: Date) -> String {
        LimitsSection.formatter(Localization.shared.isChinese ? "M月d日 EEE" : "EEE, MMM d").string(from: date)
    }
}

private extension UsageSnapshot {
    func period(_ span: CostSpan) -> PeriodUsage? {
        switch span {
        case .day: day
        case .week: week
        case .month: billing
        }
    }
}

/// 一个周期在本期消耗区要显示的文字。数据或货币变了才重新算，切换周期时直接取用。
private struct SpanFigures {
    var range: String
    var tokens: String
    var tokensHelp: String
    var requests: String
    var saved: String
    var hitRate: String
    var hitRateValue: Double
    var input: TokenColumn.Figure
    var output: TokenColumn.Figure
    var cacheWrite: TokenColumn.Figure
    var cacheRead: TokenColumn.Figure

    @MainActor
    static func all(_ snapshot: UsageSnapshot, money: MoneyFormat) -> [CostSpan: SpanFigures] {
        var result: [CostSpan: SpanFigures] = [:]
        for span in CostSpan.allCases {
            guard let p = snapshot.period(span) else { continue }
            let costs = CategoryCosts(models: p.models)
            func column(_ tokens: Int64, _ cost: Double) -> TokenColumn.Figure {
                TokenColumn.Figure(tokens: tokens, cost: cost, amount: Fmt.magnitude(tokens), money: money.whole(cost))
            }
            result[span] = SpanFigures(
                range: UsageCalculator.periodRange(start: p.start, end: p.end, calendar: .current, locale: Localization.shared.locale),
                tokens: Fmt.magnitude(p.tokens.total),
                tokensHelp: "≈ \(Fmt.grouped(p.tokens.total)) tokens",
                requests: L10n.t("\(Fmt.grouped(p.requests)) 次", Fmt.grouped(p.requests)),
                saved: L10n.t("省 \(money.compact(costs.savings))", "Saved \(money.compact(costs.savings))"),
                hitRate: Fmt.percent(p.tokens.cacheHitRate, digits: 1),
                hitRateValue: p.tokens.cacheHitRate,
                input: column(p.tokens.input, costs.input),
                output: column(p.tokens.output, costs.output),
                cacheWrite: column(p.tokens.cacheWrite, costs.cacheWrite),
                cacheRead: column(p.tokens.cacheRead, costs.cacheRead)
            )
        }
        return result
    }
}

/// 三个周期的同一项叠在同一个位置，只显示选中的那个。
/// 切换周期时只是淡入淡出：三份文字早已排好、画好，不用在切换那一帧重新测量，也不用逐帧重画；
/// 这一项的大小取三份中最大的，切换时旁边的内容不会挪动。
private struct SpanLayers<Content: View>: View {
    let prefs: Preferences
    var alignment: Alignment = .leading
    /// 数据更新时数字怎么过渡
    var transition: ContentTransition = .numericText()
    @ViewBuilder let content: (CostSpan) -> Content

    var body: some View {
        let selection = prefs.costSpan
        ZStack(alignment: alignment) {
            ForEach(CostSpan.allCases) { span in
                let shown = span == selection
                content(span)
                    .contentTransition(transition)
                    // 先合成为一组再改透明度：透明度落在图层上，过渡时不用逐帧重画文字
                    .compositingGroup()
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
        }
    }
}

/// 选中的周期还没有数据时（本周要等每周限额同步）下面的数字整块不显示
private struct SpanAvailable<Content: View>: View {
    let prefs: Preferences
    let snapshot: UsageSnapshot
    @ViewBuilder let content: Content

    var body: some View {
        if snapshot.period(prefs.costSpan) != nil {
            content
        }
    }
}

/// 一项统计：标签 + 三个周期叠在一起的数值
private struct SpanStat: View {
    let prefs: Preferences
    let label: String
    let values: [CostSpan: String]
    var help: [CostSpan: String] = [:]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
            SpanLayers(prefs: prefs) { s in
                if let value = values[s] { Text(value) }
            }
            .font(.rowValue)
            .foregroundStyle(Palette.text)
            .monospacedDigit()
        }
        .help(help[prefs.costSpan] ?? "")
    }
}

/// 缓存命中率的进度条，跟着选中的周期
private struct SpanBar: View {
    let prefs: Preferences
    let fractions: [CostSpan: Double]

    var body: some View {
        ThinBar(fraction: fractions[prefs.costSpan] ?? 0, color: Color.white.opacity(0.42), delay: 0.14)
    }
}

/// 各周期的模型列表叠在一起。行数各周期不同：每份量出自己的高度，这一块按选中的那份显示，
/// 多出来的行在过渡中淡出、收起
private struct ModelLists: View {
    let prefs: Preferences
    let snapshot: UsageSnapshot
    let money: MoneyFormat

    @State private var heights: [CostSpan: CGFloat] = [:]

    var body: some View {
        let selection = prefs.costSpan
        ZStack(alignment: .top) {
            ForEach(CostSpan.allCases) { span in
                let shown = span == selection
                Group {
                    if let p = snapshot.period(span), !p.models.isEmpty {
                        ModelList(models: p.models, total: p.cost, money: money)
                            .padding(.top, 12)
                    } else {
                        Color.clear.frame(height: 0)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[span] = $0 }
                .contentTransition(.numericText())
                .compositingGroup()
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
            }
        }
        .frame(height: heights[selection], alignment: .top)
        .clipped()
    }
}

/// 本期消耗的总额、预计与日均，右边是最近 14 天的柱状图
private struct CycleHeader: View {
    let snapshot: UsageSnapshot
    @Bindable var prefs: Preferences
    let now: Date

    @State private var hoveredDay: Int?

    var body: some View {
        let money = prefs.money
        let span = prefs.costSpan
        let recent = Array(snapshot.daily.suffix(14))
        // 柱状图里属于这个周期的天：和周期有交集的那几根
        let periodStart = snapshot.period(span).flatMap { p in recent.firstIndex { $0.date.addingTimeInterval(86_400) > p.start } }

        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // 按基线对齐：某个周期的金额缩小了，也和其它周期站在同一条基线上，下面的日均行不跟着动
                SpanLayers(prefs: prefs, alignment: .leadingFirstTextBaseline) { s in
                    if let p = snapshot.period(s) { total(p, span: s, money: money) }
                }
                .help(snapshot.period(span).map { help($0, span: span, money: money) } ?? "")
                ZStack(alignment: .leading) {
                    SpanLayers(prefs: prefs) { s in
                        if let p = snapshot.period(s) { Text(summary(p, span: s, money: money)) }
                    }
                    .opacity(hoveredDay == nil ? 1 : 0)
                    if let i = hoveredDay, let day = recent[safe: i] {
                        Text(L10n.t("\(CycleSection.dayWithWeekday(day.date)) · \(money.string(day.cost)) · \(Fmt.grouped(day.requests)) 次", "\(CycleSection.dayWithWeekday(day.date)) · \(money.string(day.cost)) · \(Fmt.grouped(day.requests))"))
                    }
                }
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
                .monospacedDigit()
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            MiniBars(values: recent.map(\.cost), highlightIndex: recent.count - 1, periodStart: periodStart, hovered: $hoveredDay)
                .frame(width: 104, height: 30)
                .padding(.bottom, 3)
                .help(L10n.t("最近 14 天", "Last 14 days"))
        }
    }

    /// 总额和预计排成一行文字：放不下时两者一起等比缩小，不会把整块内容撑宽
    private func total(_ p: PeriodUsage, span: CostSpan, money: MoneyFormat) -> some View {
        let amount = Text(money.string(p.cost))
            .font(.system(size: 26, weight: .semibold))
            .tracking(-0.4)
            .foregroundStyle(Palette.text)
        var line = amount
        if p.cost > 0 {
            let projected = projectedText(p, span: span, money: money)
            let suffix = Text("  " + L10n.t("预计 \(projected)", "→ \(projected)"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.tertiary)
            line = Text("\(amount)\(suffix)")
        }
        return line
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText(value: money.convert(p.cost)))
            .onTapGesture {
                let all = MoneyFormat.Unit.allCases
                let index = all.firstIndex(of: prefs.currency) ?? 0
                withAnimation(.quiet) { prefs.currency = all[(index + 1) % all.count] }
            }
    }

    /// 多天的周期：预计就是面板上显示的日均 × 天数，两个数对得上；只有一天时按小时外推
    private func projectedText(_ p: PeriodUsage, span: CostSpan, money: MoneyFormat) -> String {
        span == .day ? money.whole(p.projectedCost(now: now)) : money.whole(p.dailyAverage(now: now), times: p.dayCount)
    }

    private func summary(_ p: PeriodUsage, span: CostSpan, money: MoneyFormat) -> String {
        guard span != .day else { return L10n.t("当天", "Today") }
        let daily = money.whole(p.dailyAverage(now: now))
        return L10n.t("第 \(p.dayIndex) / \(p.dayCount) 天 · 日均 \(daily)", "Day \(p.dayIndex) of \(p.dayCount) · \(daily)/day")
    }

    private func help(_ p: PeriodUsage, span: CostSpan, money: MoneyFormat) -> String {
        let currency = L10n.t("点击金额切换货币", "Click the amount to change currency")
        guard p.cost > 0 else { return currency }
        let projected = projectedText(p, span: span, money: money)
        let daily = money.whole(p.dailyAverage(now: now))
        let pace = span == .day
            ? L10n.t("照今天到现在的速度，今天预计一共 \(projected)", "At today's pace so far, about \(projected) today")
            : L10n.t("照现在的速度，这个周期预计一共 \(projected)（日均 \(daily) × \(p.dayCount) 天）", "At this pace, about \(projected) for the period (\(daily)/day × \(p.dayCount) days)")
        return "\(pace)\n\(currency)"
    }
}

/// 一类 token：上面是类别，下面是数量；指针停在上面时换成折算的金额
private struct TokenColumn: View {
    struct Figure: Equatable {
        var tokens: Int64
        var cost: Double
        /// 数量，例如「2.6 万」「227.6k」
        var amount: String
        /// 折算的金额
        var money: String
    }

    let prefs: Preferences
    let label: String
    let color: Color
    let figures: [CostSpan: Figure]

    @State private var hovering = false

    var body: some View {
        let selection = prefs.costSpan
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(label)
            }
            .font(.caption)
            .foregroundStyle(Palette.tertiary)
            SpanLayers(prefs: prefs, transition: .opacity) { s in
                if let figure = figures[s] {
                    let money = hovering && s == selection
                    Text(money ? figure.money : figure.amount)
                        .lineLimit(1)
                        // 只有换成金额时才可能放不下；平时不缩放，省去按各种字号反复测量
                        .minimumScaleFactor(money ? 0.8 : 1)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.text)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.quiet) { hovering = h } }
        .help(figures[selection].map { L10n.t("\(label)：\(Fmt.grouped($0.tokens)) tokens · 约 \(prefs.money.string($0.cost))", "\(label): \(Fmt.grouped($0.tokens)) tokens · about \(prefs.money.string($0.cost))") } ?? "")
    }
}

/// 本期按模型的费用（最多 3 行，其余合并）。占比加起来正好 100%，金额加起来正好是上面的总额。
private struct ModelList: View {
    let models: [ModelUsage]
    let total: Double
    let money: MoneyFormat

    private struct Entry: Identifiable {
        let id: String
        let cost: Double
        let estimated: Bool
    }

    var body: some View {
        // 最多 3 行：超过 3 个模型时展示前 2 个 + 其他
        let keep = models.count > 3 ? 2 : models.count
        var entries = models.prefix(keep).map { Entry(id: $0.displayName, cost: $0.cost, estimated: $0.isEstimated) }
        let rest = models.dropFirst(keep).reduce(0) { $0 + $1.cost }
        if rest > 0.005 { entries.append(Entry(id: L10n.t("其他", "Other"), cost: rest, estimated: false)) }
        let shares = Fmt.shares(entries.map(\.cost))
        let amounts = money.split(total, into: entries.map(\.cost))
        return VStack(spacing: 5) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                row(entry, share: shares[i], amount: amounts[i])
            }
        }
    }

    private func row(_ entry: Entry, share: String, amount: String) -> some View {
        HStack(spacing: 8) {
            Text(entry.id)
                .foregroundStyle(Palette.secondary)
            if entry.estimated {
                Text(L10n.t("估价", "est.")).foregroundStyle(Palette.quaternary)
            }
            Spacer()
            Text(share)
                .foregroundStyle(Palette.tertiary)
                .frame(width: 44, alignment: .trailing)
            Text(amount)
                .foregroundStyle(Palette.text)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .font(.system(size: 11.5))
        .monospacedDigit()
    }
}

/// 按计费类别拆分的费用
struct CategoryCosts {
    var input = 0.0, output = 0.0, cacheWrite = 0.0, cacheRead = 0.0, savings = 0.0

    init(models: [ModelUsage]) {
        for m in models {
            guard let p = PricingCatalog.info(for: m.modelID).price else { continue }
            let t = m.tokens
            input += Double(t.input) * p.input / 1e6
            output += Double(t.output) * p.output / 1e6
            cacheWrite += (Double(t.cacheWrite5m) * p.cacheWrite5m + Double(t.cacheWrite1h) * p.cacheWrite1h) / 1e6
            cacheRead += Double(t.cacheRead) * p.cacheRead / 1e6
            savings += Double(t.cacheRead) * (p.input - p.cacheRead) / 1e6
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
