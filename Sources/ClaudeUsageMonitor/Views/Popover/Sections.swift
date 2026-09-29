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
                    Text(statusText(official, now: context.date))
                }
                .help(statusHelp(official))
            }
            if rows.isEmpty {
                ForEach([L10n.t("5 小时", "5-hour"), L10n.t("本周 · 全部模型", "Week · all models")], id: \.self) { title in
                    PlaceholderRow(title: title)
                }
            } else {
                ForEach(rows) { row in
                    LimitRowView(row: row)
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
            "来自 Claude 官方用量接口（与 Claude Code /usage 相同）。Claude Code 正在使用时，按「设置 › 用量 › 自动查询」的频率同步；随时可以点「立即刷新」",
            "From the same endpoint as Claude Code /usage. While Claude Code is in use, it syncs as set in Settings > Usage > Check automatically. Refresh works any time."
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

    var body: some View {
        let color = Palette.level(row.fraction)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.rowLabel)
                    .foregroundStyle(Palette.text)
                Spacer()
                Text("\(row.percent)%")
                    .font(.rowValue)
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: row.fraction))
            }
            ThinBar(fraction: row.fraction, color: color)
            if row.reset != .none {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(resetText(now: context.date))
                }
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
                .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .help(row.resetsAt.map { L10n.t("重置时间：\(LimitsSection.moment($0))", "Resets \(LimitsSection.moment($0))") } ?? "")
    }

    private func resetText(now: Date) -> String {
        switch row.reset {
        case .countdown(let date): date > now ? L10n.t("\(Fmt.countdown(date.timeIntervalSince(now)))后重置", "Resets in \(Fmt.countdown(date.timeIntervalSince(now)))") : L10n.t("已重置", "Reset")
        case .weekday(let date): date > now ? L10n.t("\(LimitsSection.weekday(date)) 重置", "Resets \(LimitsSection.weekday(date))") : L10n.t("已重置", "Reset")
        case .elapsed: L10n.t("已重置", "Reset")
        case .idle: L10n.t("空闲中", "Idle")
        case .none: ""
        }
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
        let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
        let f = DateFormatter()
        f.locale = Localization.shared.locale
        f.dateFormat = "EEE HH:mm"
        return f.string(from: rounded)
    }

    /// 今天 05:32 / 昨天 05:32 / 周一 05:32
    static func moment(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Localization.shared.locale
        f.dateFormat = "HH:mm"
        if cal.isDateInToday(date) { return L10n.t("今天 \(f.string(from: date))", "Today \(f.string(from: date))") }
        if cal.isDateInYesterday(date) { return L10n.t("昨天 \(f.string(from: date))", "Yesterday \(f.string(from: date))") }
        f.dateFormat = "EEE HH:mm"
        return f.string(from: date)
    }
}

// MARK: - 本期消耗

/// 本月周期 / 本周期 / 每日。等宽标签，选中项用面板里已有的浅色块。
private struct SpanTabs: View {
    @Binding var selection: CostSpan
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CostSpan.allCases) { span in
                let selected = span == selection
                Text(span.title)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Palette.text : Palette.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.13))
                                .matchedGeometryEffect(id: "span", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.quiet) { selection = span } }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

struct CycleSection: View {
    let snapshot: UsageSnapshot
    @Bindable var prefs: Preferences

    @State private var hoveredDay: Int?
    @State private var hoveredToken: String?

    private var period: PeriodUsage? {
        switch prefs.costSpan {
        case .day: snapshot.day
        case .week: snapshot.week
        case .month: snapshot.billing
        }
    }

    var body: some View {
        let money = prefs.money
        let recent = Array(snapshot.daily.suffix(14))

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("本期消耗", "Spend"))
                    .font(.sectionTitle)
                    .foregroundStyle(Palette.secondary)
                Text(period.map { UsageCalculator.periodRange(start: $0.start, end: $0.end, calendar: .current, locale: Localization.shared.locale) }
                    ?? L10n.t("同步每周限额后显示本周区间", "The weekly range appears after the weekly limit syncs"))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SpanTabs(selection: $prefs.costSpan)
            if let billing = period {
                cycleBody(billing, money: money, recent: recent)
            }
        }
    }

    @ViewBuilder
    private func cycleBody(_ billing: PeriodUsage, money: MoneyFormat, recent: [DayUsage]) -> some View {
        let tokens = billing.tokens
        let costs = CategoryCosts(models: billing.models)
        let summary = prefs.costSpan == .day
            ? L10n.t("当天", "Today")
            : L10n.t("第 \(billing.dayIndex) / \(billing.dayCount) 天 · 日均 \(money.whole(billing.dailyAverage))", "Day \(billing.dayIndex) of \(billing.dayCount) · \(money.whole(billing.dailyAverage))/day")

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(money.string(billing.cost))
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(Palette.text)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: money.convert(billing.cost)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .onTapGesture {
                            let all = MoneyFormat.Unit.allCases
                            let index = all.firstIndex(of: prefs.currency) ?? 0
                            withAnimation(.quiet) { prefs.currency = all[(index + 1) % all.count] }
                        }
                        .help(L10n.t("点击切换货币", "Click to change currency"))
                    Group {
                        if let i = hoveredDay, let day = recent[safe: i] {
                            Text(L10n.t("\(Self.dayWithWeekday(day.date)) · \(money.string(day.cost)) · \(Fmt.grouped(day.requests)) 次", "\(Self.dayWithWeekday(day.date)) · \(money.string(day.cost)) · \(Fmt.grouped(day.requests))"))
                        } else {
                            Text(summary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                MiniBars(values: recent.map(\.cost), highlightIndex: recent.count - 1, hovered: $hoveredDay)
                    .frame(width: 104, height: 30)
                    .padding(.bottom, 3)
                    .help(L10n.t("最近 14 天", "Last 14 days"))
            }

            HStack(spacing: 0) {
                stat(L10n.t("总 Tokens", "Tokens"), Fmt.magnitude(tokens.total), help: "≈ \(Fmt.grouped(tokens.total)) tokens")
                Spacer()
                stat(L10n.t("请求", "Requests"), L10n.t("\(Fmt.grouped(billing.requests)) 次", Fmt.grouped(billing.requests)), help: nil)
                Spacer()
                stat(L10n.t("今日", "Today"), money.whole(snapshot.today?.cost ?? 0), help: nil)
            }

            HStack(alignment: .top, spacing: 0) {
                tokenColumn("input", L10n.t("新增输入", "Input"), tokens.input, cost: costs.input, color: Palette.input, money: money)
                tokenColumn("output", L10n.t("输出", "Output"), tokens.output, cost: costs.output, color: Palette.output, money: money)
                tokenColumn("write", L10n.t("缓存创建", "Cache write"), tokens.cacheWrite, cost: costs.cacheWrite, color: Palette.cacheWrite, money: money)
                tokenColumn("read", L10n.t("缓存命中", "Cache read"), tokens.cacheRead, cost: costs.cacheRead, color: Palette.cacheRead, money: money)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.t("缓存命中率", "Cache hit rate"))
                        .font(.rowLabel)
                        .foregroundStyle(Palette.text)
                    Spacer()
                    Text(L10n.t("省 \(money.compact(costs.savings))", "Saved \(money.compact(costs.savings))"))
                        .font(.caption)
                        .foregroundStyle(Palette.tertiary)
                        .help(L10n.t("如果没有 Prompt Caching，这些命中缓存的 token 需要按原价计费", "Without prompt caching, these tokens would be billed at the full input price."))
                    Text(Fmt.percent(tokens.cacheHitRate, digits: 1))
                        .font(.rowValue)
                        .foregroundStyle(Palette.text)
                        .monospacedDigit()
                }
                ThinBar(fraction: tokens.cacheHitRate, color: Color.white.opacity(0.42), delay: 0.14)
            }

            if !billing.models.isEmpty {
                ModelList(models: billing.models, total: billing.cost, money: money)
            }
        }
    }

    private func stat(_ label: String, _ value: String, help: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
            Text(value)
                .font(.rowValue)
                .foregroundStyle(Palette.text)
                .monospacedDigit()
        }
        .help(help ?? "")
    }

    private func tokenColumn(_ id: String, _ label: String, _ value: Int64, cost: Double, color: Color, money: MoneyFormat) -> some View {
        let hovering = hoveredToken == id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(label)
            }
            .font(.caption)
            .foregroundStyle(Palette.tertiary)
            Text(hovering ? money.whole(cost) : Fmt.magnitude(value))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.text)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.quiet) { hoveredToken = h ? id : nil } }
        .help(L10n.t("\(label)：\(Fmt.grouped(value)) tokens · 约 \(money.string(cost))", "\(label): \(Fmt.grouped(value)) tokens · about \(money.string(cost))"))
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Localization.shared.locale
        f.dateFormat = Localization.shared.isChinese ? "M月d日" : "MMM d"
        return f.string(from: date)
    }

    static func dayWithWeekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Localization.shared.locale
        f.dateFormat = Localization.shared.isChinese ? "M月d日 EEE" : "EEE, MMM d"
        return f.string(from: date)
    }
}

/// 本期按模型的费用（最多 3 行，其余合并）
private struct ModelList: View {
    let models: [ModelUsage]
    let total: Double
    let money: MoneyFormat

    var body: some View {
        // 最多 3 行：超过 3 个模型时展示前 2 个 + 其他
        let keep = models.count > 3 ? 2 : models.count
        let top = Array(models.prefix(keep))
        let rest = models.dropFirst(keep).reduce(0) { $0 + $1.cost }
        VStack(spacing: 5) {
            ForEach(top) { m in
                row(m.displayName, m.cost, estimated: m.isEstimated)
            }
            if rest > 0.005 {
                row(L10n.t("其他", "Other"), rest, estimated: false)
            }
        }
    }

    private func row(_ name: String, _ cost: Double, estimated: Bool) -> some View {
        let share = total > 0 ? cost / total : 0
        return HStack(spacing: 8) {
            Text(name)
                .foregroundStyle(Palette.secondary)
            if estimated {
                Text(L10n.t("估价", "est.")).foregroundStyle(Palette.quaternary)
            }
            Spacer()
            Text(Fmt.percent(share, digits: share > 0 && share < 0.01 ? 1 : 0))
                .foregroundStyle(Palette.tertiary)
                .frame(width: 40, alignment: .trailing)
            Text(money.whole(cost))
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
