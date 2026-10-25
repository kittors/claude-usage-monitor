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
        CollapsibleSection(.limits, title: L10n.t("用量限额", "Limits"), prefs: prefs, spacing: 13) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let status = statusText(official, now: context.date)
                Text(status)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.25), value: status)
            }
            .tip("limits.status") { statusTip(official) }
        } summary: {
            LimitsSummary(rows: rows, fallback: statusText(official, now: Date()), stale: Self.staleReason(official.state), official: official)
        } content: {
            LimitsContent(store: store, prefs: prefs, rows: rows)
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

    /// 标题右侧的说明：数字从哪来、上次什么时候同步；现在取不到新数字时先写原因
    private func statusTip(_ official: OfficialUsageService) -> Tip {
        var notes = [L10n.t(
            // 「/」后面加不换行的连接符，「/usage」不会断在两行
            "来自 Claude 官方用量接口，和 Claude Code 的 /\u{2060}usage 相同。Claude Code 正在使用时，消耗够让数字变化就同步；随时可以点「立即刷新」",
            "From the same endpoint as Claude Code /\u{2060}usage. While Claude Code is in use, it syncs once usage is enough to change the numbers. Refresh works any time."
        )]
        if official.usage != nil, Self.staleReason(official.state) != nil {
            notes.insert(Self.unavailableReason(official.state, fetching: official.isFetching), at: 0)
        }
        let rows = official.usage.map { [Tip.Row(L10n.t("上次同步", "Last sync"), Self.moment($0.fetchedAt))] } ?? []
        return Tip(title: L10n.t("官方用量", "Official usage"), rows: rows, note: notes.joined(separator: "\n"))
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

    /// 显示的是上次同步的数字、现在取不到新的：登录失效、没有授权或请求失败。正在连接不算
    static func staleReason(_ state: OfficialUsageService.State) -> String? {
        switch state {
        case .connected, .connecting, .disabled: nil
        default: shortReason(state)
        }
    }

    /// 面板里的说明：一个图标、一句话和一行补充
    static func note(_ state: OfficialUsageService.State, fetching: Bool) -> (icon: Icon, title: String, detail: String?) {
        switch state {
        case .connected, .connecting:
            if fetching { return (.gauge, L10n.t("正在获取官方用量…", "Fetching official usage…"), nil) }
            return (.gauge, L10n.t("还没有官方数据", "No official numbers yet"),
                    L10n.t("Claude Code 正在使用时会自动查询，也可以点「立即刷新」", "They are checked while Claude Code is in use, or tap Refresh."))
        case .disabled:
            return (.gauge, L10n.t("官方用量已关闭", "Official usage is off"),
                    L10n.t("可以在「设置 › 用量」中开启", "Turn it on in Settings > Usage."))
        case .noCredentials:
            return (.terminal, L10n.t("没有找到 Claude Code 的登录", "No Claude Code login found"),
                    L10n.t("登录后即可显示官方用量", "Sign in to show official usage."))
        case .denied:
            return (.warning, L10n.t("没有获得钥匙串授权", "Keychain access was denied"),
                    L10n.t("在「设置 › 用量」中重新连接，并在系统弹窗中选择「始终允许」", "Reconnect in Settings > Usage and choose Always Allow."))
        case .expired:
            return (.clock, L10n.t("Claude Code 的登录已过期", "The Claude Code login has expired"),
                    L10n.t("开启「设置 › 用量 › 自动续期登录」，或重新登录", "Turn on automatic renewal in Settings > Usage, or sign in again."))
        case .signedOut:
            return (.terminal, L10n.t("Claude Code 的登录已失效", "The Claude Code login is no longer valid"),
                    L10n.t("登录到期或已退出，重新登录后自动恢复", "It expired or was signed out. Sign in again and this app recovers."))
        case .failed(let message):
            return (.warning, L10n.t("暂时无法获取官方用量", "Official usage is unavailable"),
                    L10n.t("\(message)，稍后自动重试", "\(message). Retrying shortly."))
        }
    }
}

/// 展开时的内容。详细：每项三行，名字和百分比、进度条、重置时间；简洁：每项一行。没有官方数据时说明原因
private struct LimitsContent: View {
    let store: UsageStore
    let prefs: Preferences
    let rows: [LimitRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if rows.isEmpty {
                LimitsUnavailable(store: store)
            } else {
                if prefs.limitsDisplay == .compact {
                    CompactLimits(rows: rows)
                } else {
                    ForEach(rows) { row in
                        LimitRowView(row: row, style: prefs.resetTimeStyle, countdown: prefs.showsResetCountdown)
                    }
                }
                // 登录失效时，上面是上次同步的数字
                if store.official.state.awaitingLogin {
                    LimitsUnavailable(store: store)
                }
            }
        }
    }
}

/// 没有官方数据或登录失效：说明原因，需要登录时带上在终端登录的按钮
private struct LimitsUnavailable: View {
    let store: UsageStore

    var body: some View {
        let official = store.official
        let note = LimitsSection.note(official.state, fetching: official.isFetching)
        EmptyNote(icon: note.icon, title: note.title, detail: note.detail) {
            if official.state.awaitingLogin {
                FooterButton(icon: .terminal, title: L10n.t("在终端中登录 Claude Code", "Sign in with Claude Code in Terminal")) { store.signInToClaudeCode() }
                    .padding(.leading, -8)
                    .padding(.top, 3)
            }
        }
    }
}

/// 收起后标题右侧：每项的短名字和百分比，百分比和进度条同色。没有数据时写原因。
/// 现在取不到新数字时（登录失效、请求失败），百分比不上色，后面写上原因，免得把上次的数字当成现在的。
/// 悬停时列出每项的全名和什么时候重置，不用展开也能看到
private struct LimitsSummary: View {
    let rows: [LimitRow]
    let fallback: String
    let stale: String?
    let official: OfficialUsageService

    var body: some View {
        line
            .contentShape(Rectangle())
            .tip("limits.summary") { tip }
    }

    @ViewBuilder
    private var line: some View {
        if rows.isEmpty {
            Text(fallback)
        } else {
            HStack(spacing: 10) {
                ForEach(rows) { row in
                    HStack(spacing: 4) {
                        Text(row.shortTitle)
                        Text("\(row.percent)%")
                            .fontWeight(.medium)
                            .foregroundStyle(stale == nil ? Palette.level(row.fraction) : Palette.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: row.fraction))
                    }
                }
                if let stale {
                    Text(stale)
                        .foregroundStyle(Palette.warning)
                }
            }
        }
    }

    private var tip: Tip {
        // 没有数字时标题右侧只有一句短原因，说明里写全
        guard !rows.isEmpty else { return Tip(LimitsSection.unavailableReason(official.state, fetching: official.isFetching)) }
        let now = Date()
        let items = rows.map { row in
            Tip.Row(row.title, ["\(row.percent)%", row.resetPhrase(now: now)].compactMap { $0 }.joined(separator: " · "))
        }
        var note: String?
        if let stale, let usage = official.usage {
            let moment = LimitsSection.moment(usage.fetchedAt)
            note = L10n.t("现在取不到新数字（\(stale)），显示的是\(moment) 同步的结果", "No fresh numbers right now (\(stale)). Last sync: \(moment).")
        }
        return Tip(rows: items, note: note)
    }
}

/// 简洁：每项一行，名字、进度条、百分比排成三列，进度条从同一处开始、到同一处结束。
/// 全名、重置时间、还剩多久和安全线写在悬停说明里，整行都可以悬停
private struct CompactLimits: View {
    let rows: [LimitRow]

    /// 行距的一半。每行上下各补这么多当作悬停区域：相邻两行连在一起，从一行移到下一行时说明直接换过去
    private static let halfGap: CGFloat = 5.5

    var body: some View {
        // 安全线随时间前进：5 小时窗口里 1% 是 3 分钟，10 秒走一次就够
        TimelineView(.periodic(from: .now, by: 10)) { context in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    let line = row.paceLine(now: context.date)
                    let color = Palette.level(row.fraction)
                    let tip = row.tip(line, now: context.date, detailed: false)
                    HStack(spacing: 12) {
                        // 名字和百分比都按这一列里最宽的那个占位
                        ZStack(alignment: .leading) {
                            ForEach(rows) { Text($0.shortTitle).hidden() }
                            Text(row.shortTitle)
                                .foregroundStyle(Palette.text)
                        }
                        .font(.rowLabel)
                        .lineLimit(1)
                        // 指着进度条时也提亮安全区；安全线是多少写在下面浮起的说明里
                        ThinBar(
                            fraction: row.fraction, color: color,
                            mark: line?.fraction, exceeded: line?.isExceeded(by: row.fraction) ?? false,
                            onPoint: { _ in }
                        )
                        ZStack(alignment: .trailing) {
                            ForEach(rows) { Text("\($0.percent)%").hidden() }
                            Text("\(row.percent)%")
                                .foregroundStyle(color)
                                .contentTransition(.numericText(value: row.fraction))
                        }
                        .font(.rowValue)
                        .monospacedDigit()
                    }
                    .padding(.vertical, Self.halfGap)
                    .contentShape(Rectangle())
                    .tip("limit.\(row.id)") { tip }
                    // 读屏不会悬停：一行读成一句，说明里的内容当作提示读出来
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(tip?.plainText ?? "")
                }
            }
            .padding(.vertical, -Self.halfGap)
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
    /// 指针停在进度条上：下面那一行换成安全线是多少、还能用多少
    @State private var pointing = false

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
                ThinBar(
                    fraction: row.fraction, color: color,
                    mark: line?.fraction, exceeded: line?.isExceeded(by: row.fraction) ?? false,
                    onPoint: { inside in withAnimation(.quiet) { pointing = inside } }
                )
                if row.reset != .none {
                    caption(now: context.date, line: line)
                }
            }
            .contentShape(Rectangle())
            .tip("limit.\(row.id)") { row.tip(line, now: context.date, detailed: true, style: style, countdown: countdown) }
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

    /// 进度条下面一行：左边什么时候重置，右边（打开倒计时时）还剩多久。
    /// 指针停在进度条上时，左边换成安全线的说明，写在这一行里而不是浮在进度条上方，不会盖住上一行的标题
    private func caption(now: Date, line: LimitPace.Line?) -> some View {
        let caption = resetCaption(now: now)
        let note = pointing ? row.safeLineNote(line) : nil
        return HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Text(caption.text)
                    .opacity(note == nil ? 1 : 0)
                if let note {
                    HStack(spacing: 5) {
                        Text(note.value)
                        Text("·")
                        Text(note.detail)
                            .foregroundStyle(note.alert ? Palette.critical : Palette.secondary)
                    }
                    .foregroundStyle(Palette.secondary)
                    .transition(.opacity)
                }
            }
            Spacer(minLength: 8)
            if let remaining = caption.remaining {
                Text(remaining)
                    .foregroundStyle(Palette.secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(Palette.tertiary)
        .monospacedDigit()
        .lineLimit(1)
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

extension LimitRow {
    /// 安全线在哪，还能用多少或超了多少：「28.6%」「还可用 2.6%」
    @MainActor
    func safeLine(_ line: LimitPace.Line) -> (mark: String, detail: String, alert: Bool) {
        let mark = Self.percent(line.fraction)
        if line.isExceeded(by: fraction) {
            let over = Self.percent(fraction - line.fraction)
            return (mark, L10n.t("超出 \(over)", "\(over) over"), true)
        }
        if fraction > line.fraction {
            return (mark, L10n.t("窗口刚开始", "Just started"), false)
        }
        let left = Self.percent(line.fraction - fraction)
        return (mark, L10n.t("还可用 \(left)", "\(left) left"), false)
    }

    /// 安全线是多少，还能用多少或超了多少：「安全线 28.6%」「还可用 2.6%」
    @MainActor
    func safeLineNote(_ line: LimitPace.Line?) -> (value: String, detail: String, alert: Bool)? {
        guard let line else { return nil }
        let s = safeLine(line)
        return (L10n.t("安全线 \(s.mark)", "Safe line \(s.mark)"), s.detail, s.alert)
    }

    /// 保留一位小数，正好是整数时不带：28.6%、50%
    static func percent(_ fraction: Double) -> String {
        let tenths = (fraction * 1000).rounded()
        return tenths.truncatingRemainder(dividingBy: 10) == 0 ? "\(Int(tenths / 10))%" : String(format: "%.1f%%", tenths / 10)
    }

    /// 悬停说明。简洁时一行里只有短名字和百分比：写上全名、重置时刻、还剩多久和安全线。
    /// 详细时下面那一行写了重置时间（指着进度条时换成安全线），只补那一行没写的，再说明安全线是怎么来的：
    /// 5 小时用默认写法又没开倒计时，那一行是「2 小时 30 分后重置」，补上具体时刻；每周用默认写法时只写了星期，补上日期；
    /// 没开倒计时就补上还剩多久
    @MainActor
    func tip(_ line: LimitPace.Line?, now: Date, detailed: Bool, style: ResetTimeStyle = .fullDate, countdown: Bool = true) -> Tip? {
        var rows: [Tip.Row] = []
        var notes: [String] = []
        switch reset {
        case .countdown(let date), .weekday(let date):
            guard date > now else { break }
            var fiveHour = false
            if case .countdown = reset { fiveHour = true }
            let showsMoment = !detailed || (style == .weekday && !(fiveHour && countdown))
            let showsLeft = !detailed || (!countdown && !(fiveHour && style == .weekday))
            if showsMoment {
                rows.append(.init(L10n.t("重置", "Resets"), LimitsSection.longMoment(date)))
            }
            if showsLeft {
                rows.append(.init(L10n.t("还剩", "Time left"), Fmt.countdown(date.timeIntervalSince(now), showSeconds: false)))
            }
        case .elapsed:
            let at = resetsAt.map { L10n.t("（\(LimitsSection.longMoment($0))）", " (\(LimitsSection.longMoment($0)))") } ?? ""
            notes.append(L10n.t("已到重置时间\(at)，正在等待同步新窗口的数据", "The reset time\(at) has passed. Waiting for the new window to sync."))
        case .idle:
            notes.append(L10n.t("现在没有进行中的 5 小时窗口，下一次请求时开始计时", "No 5-hour window is running. The next request starts one."))
        case .none:
            break
        }
        if let line {
            if !detailed {
                let s = safeLine(line)
                rows.append(.init(L10n.t("安全线", "Safe line"), "\(s.mark) · \(s.detail)", color: s.alert ? Palette.critical : nil))
            }
            notes.append(lineExplanation(line))
        }
        let tip = Tip(title: detailed ? nil : title, rows: rows, note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
        return tip.isEmpty ? nil : tip
    }

    /// 进度条上那根白线是怎么来的，超了会怎样
    @MainActor
    private func lineExplanation(_ line: LimitPace.Line) -> String {
        var text: String
        if let day = line.day {
            text = L10n.t(
                "进度条上的白线是安全线：今天是这一周的第 \(day) 天，今天结束前用到 \(day)/7 都不会提前用完。",
                "The white line is the safe line: day \(day) of 7, so staying under \(day)/7 by the end of today lasts the week."
            )
        } else {
            let elapsed = Fmt.countdown(line.elapsed, showSeconds: false)
            text = L10n.t(
                "进度条上的白线是安全线：5 小时已过 \(elapsed)，用量不超过它就能撑到重置。",
                "The white line is the safe line: \(elapsed) of the 5 hours have passed, so staying under it lasts until the reset."
            )
        }
        if line.isExceeded(by: fraction) {
            text += L10n.t("照这个速度会在重置前用完。", " At this pace the limit runs out before the reset.")
        } else if line.settling, fraction > line.fraction {
            text += L10n.t("窗口刚开始，先不提示超线。", " The window just started, so going over is not flagged yet.")
        }
        return text
    }

    /// 收起后的说明里每项一句：今天 22:00 重置、空闲中、已重置
    @MainActor
    func resetPhrase(now: Date) -> String? {
        switch reset {
        case .countdown(let date), .weekday(let date):
            date > now ? L10n.t("\(LimitsSection.dayTime(date)) 重置", "resets \(LimitsSection.dayTime(date))") : L10n.t("已重置", "reset")
        case .elapsed: L10n.t("已重置", "reset")
        case .idle: L10n.t("空闲中", "idle")
        case .none: nil
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

    /// 悬停说明里的重置时刻：今天 22:00、明天 22:00、10月31日 周五 22:00
    static func longMoment(_ date: Date) -> String {
        let rounded = roundedToMinute(date)
        let cal = Calendar.autoupdatingCurrent
        let time = formatter("HH:mm").string(from: rounded)
        if cal.isDateInToday(rounded) { return L10n.t("今天 \(time)", "Today \(time)") }
        if cal.isDateInTomorrow(rounded) { return L10n.t("明天 \(time)", "Tomorrow \(time)") }
        return formatter(Localization.shared.isChinese ? "M月d日 EEE HH:mm" : "EEE, MMM d, HH:mm").string(from: rounded)
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

        CollapsibleSection(.spend, title: L10n.t("本期消耗", "Spend"), prefs: prefs, spacing: 10) {
            // 日期区间写在标题右侧。还没同步每周限额时本周没有区间，下面会说明
            SpanLayers(prefs: prefs, alignment: .trailing) { s in
                Text(figures[s]?.range ?? "")
            }
            .monospacedDigit()
        } summary: {
            SpendSummary(prefs: prefs, snapshot: snapshot, money: money)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                SpanTabs(prefs: prefs)
                SpanAvailable(prefs: prefs, snapshot: snapshot) {
                    if prefs.spendDisplay == .compact {
                        // 简洁：只留金额、预计和最近 14 天
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            CycleHeader(snapshot: snapshot, prefs: prefs, now: context.date)
                        }
                    } else {
                        details(figures, money: money)
                    }
                }
            }
        }
    }

    /// 详细：金额下面再列 Token 构成、缓存命中率和各模型的花费
    private func details(_ figures: [CostSpan: SpanFigures], money: MoneyFormat) -> some View {
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
                    TokenColumn(prefs: prefs, label: L10n.t("新增输入", "Input"), color: Palette.input, figures: figures.mapValues(\.input),
                                note: L10n.t("没有命中缓存的新输入，按原价计费", "New input not served from the cache, billed at the full price"))
                    TokenColumn(prefs: prefs, label: L10n.t("输出", "Output"), color: Palette.output, figures: figures.mapValues(\.output),
                                note: L10n.t("回复的内容，思考的 token 也算在里面", "The replies, thinking included"))
                    TokenColumn(prefs: prefs, label: L10n.t("缓存创建", "Cache write"), color: Palette.cacheWrite, figures: figures.mapValues(\.cacheWrite),
                                note: L10n.t("写进缓存的输入，按输入价的 1.25 倍（5 分钟）或 2 倍（1 小时）计费", "Input written to the cache, billed at 1.25× (5 minutes) or 2× (1 hour) the input price"))
                    TokenColumn(prefs: prefs, label: L10n.t("缓存命中", "Cache read"), color: Palette.cacheRead, figures: figures.mapValues(\.cacheRead),
                                note: L10n.t("从缓存读出的输入，单价远低于原价输入", "Input read from the cache, billed far below the full input price"))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.t("缓存命中率", "Cache hit rate"))
                            .font(.rowLabel)
                            .foregroundStyle(Palette.text)
                        Spacer()
                        SpanLayers(prefs: prefs, alignment: .trailing) { s in
                            if let f = figures[s] {
                                Text(f.saved)
                                    .tip("spend.saved.\(s.rawValue)") { Tip(L10n.t("如果没有 Prompt Caching，这些命中缓存的 token 需要按原价计费", "Without prompt caching, these tokens would be billed at the full input price.")) }
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(Palette.tertiary)
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
            let costs = p.categories
            func column(_ tokens: Int64, _ cost: Double) -> TokenColumn.Figure {
                TokenColumn.Figure(tokens: tokens, cost: cost, amount: Fmt.magnitude(tokens), money: money.whole(cost))
            }
            result[span] = SpanFigures(
                range: UsageCalculator.periodRange(start: p.start, end: p.end, calendar: .current, locale: Localization.shared.locale),
                tokens: Fmt.magnitude(p.tokens.total),
                tokensHelp: L10n.t("共 \(Fmt.grouped(p.tokens.total)) tokens", "\(Fmt.grouped(p.tokens.total)) tokens in total"),
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

/// 选中的周期还没有数据时（本周要等每周限额同步），下面的数字换成一句说明
private struct SpanAvailable<Content: View>: View {
    let prefs: Preferences
    let snapshot: UsageSnapshot
    @ViewBuilder let content: Content

    var body: some View {
        if snapshot.period(prefs.costSpan) != nil {
            content
        } else {
            EmptyNote(
                icon: .calendar,
                title: L10n.t("本周要等每周限额同步", "This week waits for the weekly limit"),
                detail: L10n.t("本周按官方每周额度的重置时间统计，同步一次后显示", "It follows the official weekly reset and appears after one sync.")
            )
            .padding(.top, 2)
        }
    }
}

/// 收起后标题右侧：选中的周期花了多少。悬停时写上周期、第几天、预计、还剩和今天
private struct SpendSummary: View {
    let prefs: Preferences
    let snapshot: UsageSnapshot
    let money: MoneyFormat

    var body: some View {
        let span = prefs.costSpan
        line(span)
            .contentShape(Rectangle())
            .tip("spend.summary") { tip(span) }
    }

    private func line(_ span: CostSpan) -> some View {
        HStack(spacing: 4) {
            Text(span.shortTitle)
            if let p = snapshot.period(span) {
                Text(money.string(p.cost))
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: money.convert(p.cost)))
            } else {
                Text(L10n.t("等待同步", "waiting for sync"))
            }
        }
    }

    private func tip(_ span: CostSpan) -> Tip {
        guard let p = snapshot.period(span) else {
            return Tip(L10n.t("本周按官方每周额度的重置时间统计，同步一次后显示", "It follows the official weekly reset and appears after one sync."))
        }
        let math = SpendMath(snapshot: snapshot, money: money, now: Date())
        var rows: [Tip.Row] = []
        if span != .day {
            rows.append(.init(L10n.t("进度", "Progress"), L10n.t("第 \(p.dayIndex) / \(p.dayCount) 天", "Day \(p.dayIndex) of \(p.dayCount)")))
        }
        if let projected = math.projectedText(p) {
            rows.append(.init(L10n.t("预计", "Estimate"), projected))
        }
        if span == .day {
            if let runsOut = math.projection(p)?.runsOut {
                rows.append(.init(L10n.t("每周额度", "Weekly limit"), SpendMath.runsOutNote(runsOut, now: math.now)))
            }
        } else {
            rows.append(math.remainingRow(p))
            rows.append(.init(L10n.t("今日", "Today"), money.whole(snapshot.today?.cost ?? 0)))
        }
        let range = UsageCalculator.periodRange(start: p.start, end: p.end, calendar: .current, locale: Localization.shared.locale)
        return Tip(title: span.title, rows: rows, note: range)
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
        .contentShape(Rectangle())
        .tip("spend.stat.\(label)") { help[prefs.costSpan].map { Tip($0) } }
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
                        ModelList(span: span, models: p.models, total: p.cost, money: money)
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
        let math = SpendMath(snapshot: snapshot, money: money, now: now)
        let recent = Array(snapshot.daily.suffix(14))
        // 柱状图里属于这个周期的天：和周期有交集的那几根
        let periodStart = snapshot.period(span).flatMap { p in recent.firstIndex { $0.date.addingTimeInterval(86_400) > p.start } }

        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // 按基线对齐：某个周期的金额缩小了，也和其它周期站在同一条基线上，下面的日均行不跟着动
                // 说明挂在每个周期自己那一层上：指着的就是看得见的那串字，隐藏的几层不接收悬停
                SpanLayers(prefs: prefs, alignment: .leadingFirstTextBaseline) { s in
                    if let p = snapshot.period(s) {
                        total(p, math: math)
                            .tip("spend.total.\(s.rawValue)") { totalTip(p, span: s, math: math) }
                    }
                }
                ZStack(alignment: .leading) {
                    SpanLayers(prefs: prefs) { s in
                        if let p = snapshot.period(s) {
                            summary(p, span: s, math: math)
                                .tip("spend.pace.\(s.rawValue)") { paceTip(p, span: s, math: math) }
                        }
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
            // 指着柱子时左边第二行换成那一天的花费，不另外浮起说明
            MiniBars(values: recent.map(\.cost), highlightIndex: recent.count - 1, periodStart: periodStart, hovered: $hoveredDay)
                .frame(width: 104, height: 30)
                .padding(.bottom, 3)
        }
    }

    /// 总额和预计排成一行文字：放不下时两者一起等比缩小，不会把整块内容撑宽
    private func total(_ p: PeriodUsage, math: SpendMath) -> some View {
        let money = math.money
        let amount = Text(money.string(p.cost))
            .font(.system(size: 26, weight: .semibold))
            .tracking(-0.4)
            .foregroundStyle(Palette.text)
        var line = amount
        if let projected = math.projectedText(p) {
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

    /// 多天的周期：第几天，和额度用满还剩多少（预计 − 已花，两个数对得上）；没有额度读数时写日均。
    /// 今天：照今天的速度每周额度会用完时，写上什么时候用完
    @ViewBuilder
    private func summary(_ p: PeriodUsage, span: CostSpan, math: SpendMath) -> some View {
        if span == .day {
            let today = L10n.t("当天", "Today")
            if let runsOut = math.projection(p)?.runsOut {
                Text([today, SpendMath.runsOutNote(runsOut, now: now)].joined(separator: " · "))
            } else {
                Text(today)
            }
        } else {
            let day = L10n.t("第 \(p.dayIndex) / \(p.dayCount) 天", "Day \(p.dayIndex) of \(p.dayCount)")
            Text([day, math.remainingNote(p)].joined(separator: " · "))
        }
    }

    /// 金额的说明。简洁时下面没有 Token 构成、缓存和各模型，一起写在这里；最后是预计的意思
    private func totalTip(_ p: PeriodUsage, span: CostSpan, math: SpendMath) -> Tip {
        let money = math.money
        var rows: [Tip.Row] = []
        if prefs.spendDisplay == .compact {
            rows.append(.init(L10n.t("总 Tokens", "Tokens"), Fmt.magnitude(p.tokens.total)))
            rows.append(.init(L10n.t("请求", "Requests"), L10n.t("\(Fmt.grouped(p.requests)) 次", Fmt.grouped(p.requests))))
            // 今天的金额就是上面的大数字
            if span != .day {
                rows.append(.init(L10n.t("今日", "Today"), money.whole(snapshot.today?.cost ?? 0)))
            }
            let saved = L10n.t("省 \(money.compact(p.categories.savings))", "saved \(money.compact(p.categories.savings))")
            rows.append(.init(L10n.t("缓存命中率", "Cache hit rate"), "\(Fmt.percent(p.tokens.cacheHitRate, digits: 1)) · \(saved)"))
            for (i, line) in ModelList.lines(p.models, total: p.cost, money: money).enumerated() {
                rows.append(.init(line.name, "\(line.share) · \(line.amount)", separated: i == 0))
            }
        }
        let currency = L10n.t("点击金额切换货币", "Click the amount to change currency")
        return Tip(rows: rows, note: [math.meaning(p, span: span), currency].compactMap { $0 }.joined(separator: "\n"))
    }

    /// 第二行的说明：还剩多少就是预计减去已花，额度用满的金额是怎么折算出来的
    private func paceTip(_ p: PeriodUsage, span: CostSpan, math: SpendMath) -> Tip? {
        if span == .day {
            // 今天这一行只在额度会用完时多写一句
            guard math.projection(p)?.runsOut != nil else { return nil }
            return math.dayHelp(p).map { Tip($0) }
        }
        guard let projected = math.projectedText(p), let a = snapshot.weeklyAllowance else {
            return Tip(L10n.t("日均按实际过去的时间算，不足一天按一天算。同步每周限额后这里换成还剩多少", "The daily average uses the time actually passed, at least one day. Once the weekly limit syncs, this shows what is left."))
        }
        let rows: [Tip.Row] = [
            .init(L10n.t("预计", "Estimate"), projected),
            .init(L10n.t("已花", "Spent"), math.money.string(p.cost)),
            .init(L10n.t("还剩", "Left"), math.exactRemaining(p) ?? L10n.t("额度已用满", "Limit used up")),
        ]
        return Tip(rows: rows, note: math.allowanceBasis(a))
    }
}

/// 本期消耗里由金额推出来的几样：预计、还剩、预计的意思和额度的折算。头部、收起后的摘要和它们的说明共用
private struct SpendMath {
    let snapshot: UsageSnapshot
    let money: MoneyFormat
    let now: Date

    /// 本周、本月：每周额度用满时一共多少；今天：照今天的速度到今天结束，每周额度用完就停到下次重置
    func projection(_ p: PeriodUsage) -> Projection? {
        p.projection(now: now, allowance: snapshot.weeklyAllowance)
    }

    /// 预计的金额。今天还没花钱时不外推
    func projectedText(_ p: PeriodUsage) -> String? {
        guard let projection = projection(p), p.dayCount > 1 || p.cost > 0 else { return nil }
        return money.whole(projection.cost)
    }

    /// 额度用满还剩多少（美元）：显示出来的预计减去已花，拿面板上的两个数心算对得上。没有额度读数时为 nil
    func remaining(_ p: PeriodUsage) -> Double? {
        guard let projection = projection(p) else { return nil }
        // 已经花到预计（额度用满）时就是 0，不受取整影响
        guard projection.cost - p.cost >= 0.005 else { return 0 }
        let shown = money.convert(projection.cost)
        let rounded = money.unit.fractionDigits == 0 || abs(shown) >= 100 ? shown.rounded() : (shown * 100).rounded() / 100
        return max(0, rounded / money.rate - p.cost)
    }

    /// 说明里「预计 − 已花 = 还剩」那一行：两个数都按显示出来的位数取整再相减，按其中更细的位数写，
    /// 三个数拿来做减法正好对上（第二行只写整数，是它四舍五入的结果）。没有额度读数或已经用满时为 nil
    @MainActor
    func exactRemaining(_ p: PeriodUsage) -> String? {
        guard let projection = projection(p), projection.cost - p.cost >= 0.005 else { return nil }
        let estimateDigits = money.unit.fractionDigits == 0 || abs(money.convert(projection.cost)) >= 100 ? 0 : 2
        let spentDigits = money.fractionDigits(for: p.cost)
        func shown(_ usd: Double, _ digits: Int) -> Double {
            let scale = pow(10, Double(digits))
            return (money.convert(usd) * scale).rounded() / scale
        }
        let left = max(0, shown(projection.cost, estimateDigits) - shown(p.cost, spentDigits))
        return money.string(left / money.rate, digits: max(estimateDigits, spentDigits))
    }

    /// 第二行右半：额度用满还剩多少；没有额度读数时写日均
    @MainActor
    func remainingNote(_ p: PeriodUsage) -> String {
        guard let left = remaining(p) else {
            let daily = money.whole(p.dailyAverage(now: now))
            return L10n.t("日均 \(daily)", "\(daily)/day")
        }
        guard left >= 0.005 else { return L10n.t("额度已用满", "limit used up") }
        let amount = money.whole(left)
        return L10n.t("还剩 \(amount)", "\(amount) left")
    }

    /// 说明里的同一项，拆成名称和数值
    @MainActor
    func remainingRow(_ p: PeriodUsage) -> Tip.Row {
        guard let left = remaining(p) else { return .init(L10n.t("日均", "Per day"), money.whole(p.dailyAverage(now: now))) }
        guard left >= 0.005 else { return .init(L10n.t("还剩", "Left"), L10n.t("额度已用满", "Limit used up")) }
        return .init(L10n.t("还剩", "Left"), money.whole(left))
    }

    /// 预计是什么意思。今天：照今天的速度一共多少，额度会用完时写明什么时候
    @MainActor
    func meaning(_ p: PeriodUsage, span: CostSpan) -> String? {
        if span == .day { return dayHelp(p) }
        guard let projection = projection(p), let a = snapshot.weeklyAllowance else {
            return L10n.t("同步每周限额后显示预计：每周额度用满时本机一共花多少", "The estimate appears once the weekly limit syncs: what this Mac spends with the weekly limit fully used")
        }
        let projected = money.whole(projection.cost)
        let full = money.whole(a.full)
        return span == .week
            ? L10n.t("预计 \(projected)：本周额度用满（100%）时本机一共花多少，不管用得快慢", "\(projected) is what this Mac spends with this week's limit fully used, however fast you go")
            : L10n.t("预计 \(projected)：已经花的 \(money.string(p.cost))，加上之后每周都用满（每周约 \(full)，跨出这个周期的那一周按时间折算）", "\(projected): \(money.string(p.cost)) spent, plus every week after this used in full (about \(full) a week, prorated where a week runs past the period)")
    }

    /// 额度用满的金额是怎么折算出来的
    @MainActor
    func allowanceBasis(_ a: WeeklyAllowance) -> String {
        let percent = Int(a.utilization.rounded(.down))
        let full = money.whole(a.full)
        let spent = money.string(a.syncedCost)
        if a.borrowed {
            let at = a.syncedAt.map { CycleSection.day($0) } ?? ""
            return L10n.t(
                "本周的百分比还不到 10%，误差太大，先用 \(at) 同步时的比例：那一周已用 \(percent)%，本机花了 \(spent)，额度用满约 \(full)",
                "This week is still under 10%, too coarse to use, so it borrows the sync on \(at): that week was at \(percent)% with \(spent) spent here, so a full week is about \(full)"
            )
        }
        let basis = L10n.t(
            "上次同步时本周已用 \(percent)%，本机花了 \(spent)，照这个比例本机花到约 \(full) 时额度用满",
            "At the last sync this week was at \(percent)% with \(spent) spent here, so the limit is full at about \(full)"
        )
        guard a.utilization < WeeklyAllowance.minimumUtilization else { return basis }
        return basis + L10n.t("。官方百分比只有整数，现在还小，误差较大，用得越多越准", ". The official percentage is a whole number, so this is rough while it is small and sharpens as you use more")
    }

    /// 今天：照今天到现在的速度今天一共多少；每周额度会在今天用完时写明什么时候
    @MainActor
    func dayHelp(_ p: PeriodUsage) -> String? {
        guard p.cost > 0, let projection = projection(p) else { return nil }
        let projected = money.whole(projection.cost)
        guard let runsOut = projection.runsOut else {
            return L10n.t("照今天到现在的速度，今天预计一共 \(projected)", "At today's pace so far, about \(projected) today")
        }
        let stop = L10n.t("额度用完就停到下次重置", "spending stops until the next reset")
        guard runsOut > now else {
            return L10n.t("每周额度已经用完；\(stop)，今天预计一共 \(projected)", "The weekly limit is used up and \(stop): about \(projected) today")
        }
        let moment = LimitsSection.formatter(Localization.shared.isChinese ? "M月d日 HH:mm" : "MMM d, HH:mm").string(from: runsOut)
        return L10n.t("照今天到现在的速度，每周额度会在 \(moment) 前后用完；\(stop)，今天预计一共 \(projected)", "At today's pace so far, the weekly limit runs out around \(moment) and \(stop): about \(projected) today")
    }

    /// 额度用完的时刻：今天写到分钟，明天写「明天」，一周之内写星期几，再远写日期
    @MainActor
    static func runsOutNote(_ date: Date, now: Date) -> String {
        guard date > now else { return L10n.t("额度已用完", "limit reached") }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        if cal.isDate(date, inSameDayAs: now) {
            let time = LimitsSection.formatter("HH:mm").string(from: date)
            return L10n.t("\(time) 用完", "runs out \(time)")
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: today), cal.isDate(date, inSameDayAs: tomorrow) {
            return L10n.t("明天用完", "runs out tomorrow")
        }
        if let week = cal.date(byAdding: .day, value: 7, to: today), date < week {
            let weekday = LimitsSection.formatter("EEE").string(from: date)
            return L10n.t("\(weekday)用完", "runs out \(weekday)")
        }
        let day = CycleSection.day(date)
        return L10n.t("\(day)用完", "runs out \(day)")
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
    /// 这一类是什么、怎么计费
    let note: String

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
        // 指着时这一列已经换成折算的金额，说明里只写准确的 token 数和怎么计费
        .tip("spend.token.\(label)") {
            figures[prefs.costSpan].map { Tip(title: label, rows: [.init("Tokens", Fmt.grouped($0.tokens))], note: note) }
        }
    }
}

/// 本期按模型的费用（最多 3 行，其余合并）。占比加起来正好 100%，金额加起来正好是上面的总额。
/// 指着一行时写上请求次数和 tokens；「其他」列出合并了哪几个模型
private struct ModelList: View {
    let span: CostSpan
    let models: [ModelUsage]
    let total: Double
    let money: MoneyFormat

    struct Line {
        let name: String
        let share: String
        let amount: String
        let estimated: Bool
        /// 这一行算进去的模型，「其他」是合并起来的几个
        let models: [ModelUsage]
    }

    /// 最多 3 行：超过 3 个模型时展示前 2 个 + 其他
    @MainActor
    static func lines(_ models: [ModelUsage], total: Double, money: MoneyFormat) -> [Line] {
        let keep = models.count > 3 ? 2 : models.count
        var groups = models.prefix(keep).map { (name: $0.displayName, models: [$0], estimated: $0.isEstimated) }
        let merged = Array(models.dropFirst(keep))
        if merged.reduce(0, { $0 + $1.cost }) > 0.005 { groups.append((L10n.t("其他", "Other"), merged, false)) }
        let costs = groups.map { $0.models.reduce(0) { $0 + $1.cost } }
        let shares = Fmt.shares(costs)
        let amounts = money.split(total, into: costs)
        return groups.indices.map { i in
            Line(name: groups[i].name, share: shares[i], amount: amounts[i], estimated: groups[i].estimated, models: groups[i].models)
        }
    }

    var body: some View {
        let lines = Self.lines(models, total: total, money: money)
        return VStack(spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.element.name) { i, line in
                row(line)
                    .contentShape(Rectangle())
                    // 按位置编号：两个模型显示名相同时也不会认错是哪一行
                    .tip("model.\(span.rawValue).\(i)") { tip(line) }
            }
        }
    }

    private func row(_ line: Line) -> some View {
        HStack(spacing: 8) {
            Text(line.name)
                .foregroundStyle(Palette.secondary)
            if line.estimated {
                Text(L10n.t("估价", "est.")).foregroundStyle(Palette.quaternary)
            }
            Spacer()
            Text(line.share)
                .foregroundStyle(Palette.tertiary)
                .frame(width: 44, alignment: .trailing)
            Text(line.amount)
                .foregroundStyle(Palette.text)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .font(.system(size: 11.5))
        .monospacedDigit()
    }

    private func tip(_ line: Line) -> Tip {
        func usage(_ m: ModelUsage) -> String {
            L10n.t("\(Fmt.grouped(m.requests)) 次 · \(Fmt.magnitude(m.tokens.total)) tokens", "\(Fmt.grouped(m.requests)) requests · \(Fmt.magnitude(m.tokens.total)) tokens")
        }
        if line.models.count == 1, let m = line.models.first {
            let note = m.isEstimated ? L10n.t("价目表里还没有这个模型的官方价格，金额是估算的", "There is no official price for this model yet, so the amount is an estimate.") : nil
            return Tip(title: line.name, rows: [
                .init(L10n.t("请求", "Requests"), L10n.t("\(Fmt.grouped(m.requests)) 次", Fmt.grouped(m.requests))),
                .init("Tokens", Fmt.magnitude(m.tokens.total)),
            ], note: note)
        }
        return Tip(
            title: L10n.t("其他 \(line.models.count) 个模型", "\(line.models.count) other models"),
            rows: line.models.map { Tip.Row($0.displayName, usage($0)) }
        )
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
