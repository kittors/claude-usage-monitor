import SwiftUI
import UsageCore

// MARK: - 用量限额

struct LimitsSection: View {
    let store: UsageStore
    let prefs: Preferences

    var body: some View {
        let money = prefs.money
        let rows = store.limitRows
        VStack(alignment: .leading, spacing: 13) {
            SectionTitle(title: "用量限额") {
                sourceLabel
            }
            ForEach(rows) { row in
                LimitRowView(row: row, threshold: prefs.warningThreshold, money: money)
            }
        }
    }

    @ViewBuilder
    private var sourceLabel: some View {
        if store.isUsingOfficialLimits {
            Text("官方数据")
                .help("与 Claude Code /usage 相同的官方接口，每分钟同步一次")
        } else {
            Text(fallbackReason)
                .help("官方数据暂不可用，当前按本机 Claude Code 日志的 API 等价费用 ÷ 预算估算。可在设置中查看连接状态。")
        }
    }

    private var fallbackReason: String {
        switch store.official.state {
        case .disabled: "估算值"
        case .connecting: "正在连接官方…"
        case .denied: "估算值 · 未授权"
        case .noCredentials: "估算值 · 未登录"
        case .expired: "估算值 · 凭据过期"
        case .failed, .connected: "估算值"
        }
    }
}

private struct LimitRowView: View {
    let row: LimitRow
    let threshold: Double
    let money: MoneyFormat

    var body: some View {
        let color = Palette.level(row.fraction, warning: threshold)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.rowLabel)
                    .foregroundStyle(Palette.text)
                Spacer()
                Text(Fmt.percent(row.fraction))
                    .font(.rowValue)
                    .foregroundStyle(row.fraction >= threshold ? color : Palette.text)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: row.fraction))
            }
            ThinBar(fraction: row.fraction, color: color)
            if hasCaption {
                HStack(spacing: 8) {
                    Text(detailText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(resetText(now: context.date))
                    }
                }
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
                .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .help(helpText)
    }

    private var hasCaption: Bool {
        row.localCost != nil || row.reset != .none
    }

    private var detailText: String {
        guard let cost = row.localCost else { return "" }
        var text = row.budget.map { "\(money.whole(cost)) / \(money.whole($0))" } ?? "本机 \(money.whole(cost))"
        if let since = row.since {
            text += " · \(since.source == .inferred ? "约" : "")\(LimitsSection.moment(since.date)) 起"
        }
        return text
    }

    /// 速率、预测与起算说明放在悬停提示里，行内文字保持不变
    private var helpText: String {
        var lines: [String] = []
        if let syncedAt = row.syncedAt {
            lines.append("官方数据 \(LimitsSection.moment(syncedAt)) 同步，之后按本机新增用量推算，每 5 分钟校正一次")
        }
        if let rate = row.burnRate, rate > 0 {
            var line = "近 1 小时 \(money.whole(rate))/时"
            if let p = row.projected {
                line += p > 1 ? "，按此速率会在重置前用完" : "，重置前预计 \(Fmt.percent(p))"
            }
            lines.append(line)
        }
        if let since = row.since {
            let when = LimitsSection.moment(since.date)
            switch since.source {
            case .detected: lines.append("本周额度在 \(when) 之后被中途重置过（官方百分比出现下降），本机费用从这之后算起")
            case .inferred: lines.append("根据本机费用与官方百分比的变化推算，本周额度约在 \(when) 被中途重置过，本机费用从这时算起。可在设置中手动指定")
            case .manual: lines.append("本机费用从设置中指定的 \(when) 算起")
            case .scheduled: break
            }
        }
        return lines.joined(separator: "\n")
    }

    private func resetText(now: Date) -> String {
        switch row.reset {
        case .countdown(let date): "\(Fmt.countdown(date.timeIntervalSince(now)))后重置"
        case .weekday(let date): "\(LimitsSection.weekday(date)) 重置"
        case .idle: "空闲中"
        case .none: ""
        }
    }
}

extension LimitsSection {
    /// 官方的重置时间常带有亚秒误差（例如 13:59:59.9），就近取整到分钟再显示
    static func weekday(_ date: Date) -> String {
        let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE HH:mm"
        return f.string(from: rounded)
    }

    /// 今天 05:32 / 昨天 05:32 / 周一 05:32
    static func moment(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        if cal.isDateInToday(date) { return "今天 \(f.string(from: date))" }
        if cal.isDateInYesterday(date) { return "昨天 \(f.string(from: date))" }
        f.dateFormat = "EEE HH:mm"
        return f.string(from: date)
    }
}

// MARK: - 本期消耗

struct CycleSection: View {
    let snapshot: UsageSnapshot
    let prefs: Preferences

    @State private var hoveredDay: Int?
    @State private var hoveredToken: String?

    var body: some View {
        let money = prefs.money
        let billing = snapshot.billing
        let tokens = billing.tokens
        let recent = Array(snapshot.daily.suffix(14))
        let costs = CategoryCosts(models: billing.models)

        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "本期消耗") {
                Text("\(Self.day(billing.start)) – \(Self.day(billing.lastDay))")
            }

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
                            withAnimation(.quiet) { prefs.currency = prefs.currency == .usd ? .cny : .usd }
                        }
                        .help("点击切换 $ / ¥")
                    Group {
                        if let i = hoveredDay, let day = recent[safe: i] {
                            Text("\(Self.dayWithWeekday(day.date)) · \(money.string(day.cost)) · \(Fmt.grouped(day.requests)) 次")
                        } else {
                            Text("第 \(billing.dayIndex) / \(billing.dayCount) 天 · 预计整期 \(money.whole(billing.projectedCost(now: Date())))")
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
                    .help("最近 14 天")
            }

            HStack(spacing: 0) {
                stat("总 Tokens", Fmt.chinese(tokens.total), help: "≈ \(Fmt.grouped(tokens.total)) tokens")
                Spacer()
                stat("请求", "\(Fmt.grouped(billing.requests)) 次", help: nil)
                Spacer()
                stat("今日", money.whole(snapshot.today?.cost ?? 0), help: nil)
            }

            HStack(alignment: .top, spacing: 0) {
                tokenColumn("input", "新增输入", tokens.input, cost: costs.input, color: Palette.input, money: money)
                tokenColumn("output", "输出", tokens.output, cost: costs.output, color: Palette.output, money: money)
                tokenColumn("write", "缓存创建", tokens.cacheWrite, cost: costs.cacheWrite, color: Palette.cacheWrite, money: money)
                tokenColumn("read", "缓存命中", tokens.cacheRead, cost: costs.cacheRead, color: Palette.cacheRead, money: money)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("缓存命中率")
                        .font(.rowLabel)
                        .foregroundStyle(Palette.text)
                    Spacer()
                    Text("省 \(money.compact(costs.savings))")
                        .font(.caption)
                        .foregroundStyle(Palette.tertiary)
                        .help("如果没有 Prompt Caching，这些命中缓存的 token 需要按原价计费")
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
            Text(hovering ? money.whole(cost) : Fmt.chinese(value))
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
        .help("\(label)：\(Fmt.grouped(value)) tokens · 约 \(money.string(cost))")
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }

    static func dayWithWeekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
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
                row("其他", rest, estimated: false)
            }
        }
    }

    private func row(_ name: String, _ cost: Double, estimated: Bool) -> some View {
        let share = total > 0 ? cost / total : 0
        return HStack(spacing: 8) {
            Text(name)
                .foregroundStyle(Palette.secondary)
            if estimated {
                Text("估价").foregroundStyle(Palette.quaternary)
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
