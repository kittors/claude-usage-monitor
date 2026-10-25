import SwiftUI
import UsageCore

// MARK: - 输出速度

/// 输出速度。简洁时和本期消耗的头部同一个格局：左边是近 5 分钟的加权均速，右边是最近 1 小时里它的变化；
/// 详细时右边换成最近 1 小时的统计，下面画出每一次回复。最近 1 小时没有回复时只写一句说明，不画空图。
/// 会话记录要等整条回复结束才写，所以每次回复结束数字才变；生成中只知道发出了多久
struct SpeedSection: View {
    let store: UsageStore
    let prefs: Preferences

    @Environment(\.panelVisible) private var visible
    /// 简洁：指针停在折线的哪个时刻
    @State private var hoveredMoment: Double?
    /// 详细：指针停在哪一次回复上
    @State private var hoveredReply: UInt64?

    var body: some View {
        let detailed = prefs.speedDisplay == .detailed
        // 每秒走一格：生成中的秒数、时间轴左移、滑出近 5 分钟的回复。面板收起时停下
        TimelineView(.animation(minimumInterval: 1, paused: !visible)) { context in
            SpeedContent(
                store: store, prefs: prefs, now: context.date.timeIntervalSince1970, detailed: detailed,
                hoveredMoment: $hoveredMoment, hoveredReply: $hoveredReply
            )
        }
    }

    static func whole(_ rate: Double) -> String { String(Int(rate.rounded())) }

    /// 指针所在的时刻：「23:42 前 5 分钟 · 96 tok/s」
    static func moment(_ t: Double, requests: [TimedRequest]) -> String {
        let time = LimitsSection.formatter("HH:mm").string(from: Date(timeIntervalSince1970: t))
        guard let rate = OutputSpeed.rate(requests, from: t - OutputSpeed.recent, to: t) else {
            return L10n.t("\(time) 前 5 分钟没有回复", "No replies in the 5 min to \(time)")
        }
        return L10n.t("\(time) 前 5 分钟 · \(whole(rate.tokensPerSecond)) tok/s", "5 min to \(time) · \(whole(rate.tokensPerSecond)) tok/s")
    }

    /// 悬停说明：这个数是怎么算出来的。耗时精确到 0.1 秒，拿显示出来的数心算也对得上
    static func help(_ rate: OutputSpeed.Rate?, period: String, note: String? = nil) -> String {
        let basis = L10n.t(
            "生成耗时从请求发出算到回复写完，包含排队和等第一个字的时间，所以短回复会显得慢。按 token 加权，短回复对均速的影响小。思考的 token 也算输出。",
            "Time runs from sending the request to the end of the reply, including the queue and the wait for the first token, so short replies look slow. Weighted by tokens, so short replies barely move the average. Thinking counts as output."
        )
        var lines: [String] = []
        if let rate {
            let seconds = String(format: "%.1f", rate.duration)
            lines.append(L10n.t(
                "\(period) \(Fmt.grouped(rate.count)) 次回复：\(Fmt.grouped(rate.output)) tokens ÷ 生成耗时 \(seconds) 秒 = \(whole(rate.tokensPerSecond)) tok/s",
                "\(period), \(Fmt.grouped(rate.count)) replies: \(Fmt.grouped(rate.output)) tokens ÷ \(seconds)s = \(whole(rate.tokensPerSecond)) tok/s"
            ))
        }
        if let note { lines.append(note) }
        lines.append(basis)
        return lines.joined(separator: "\n")
    }
}

extension ModelSpeed {
    /// 面板上的名字，快速模式单独一组
    @MainActor var title: String { isFast ? L10n.t("\(model) 快速", "\(model) Fast") : model }
}

/// 这一秒要画的内容
private struct SpeedContent: View {
    let store: UsageStore
    let prefs: Preferences
    let now: Double
    let detailed: Bool
    @Binding var hoveredMoment: Double?
    @Binding var hoveredReply: UInt64?

    var body: some View {
        let log = store.speedLog
        let models = log.models(now: now)
        let model = store.speedModel(in: models)
        let requests = model?.requests ?? []
        let pending = model?.pending ?? []
        let recent = OutputSpeed.rate(requests, from: now - OutputSpeed.recent, to: now)
        // 最近 1 小时哪个模型都没有写完的回复：不画空图表，只说明一句
        let replied = models.contains { ($0.requests.last?.end ?? 0) > now - OutputSpeed.span }
        // Claude Code 太旧，回复里没有请求发出的时刻
        let untimed = !replied && (log.lastUntimed ?? 0) > now - OutputSpeed.span

        CollapsibleSection(.speed, title: L10n.t("输出速度", "Output speed"), prefs: prefs, spacing: 10) {
            SpeedStatus(pending: pending, now: now)
        } summary: {
            SpeedSummary(rate: recent, generating: !pending.isEmpty, replied: replied, untimed: untimed)
        } content: {
            if replied {
                SpeedFigures(
                    store: store, models: models, model: model, now: now, detailed: detailed,
                    hoveredMoment: $hoveredMoment, hoveredReply: $hoveredReply
                )
            } else {
                SpeedEmpty(untimed: untimed, generating: !pending.isEmpty)
            }
        }
    }
}

/// 最近 1 小时有回复时：左边大数字和模型，右边折线（详细时是统计），详细时下面再画每一次回复
private struct SpeedFigures: View {
    let store: UsageStore
    let models: [ModelSpeed]
    let model: ModelSpeed?
    let now: Double
    let detailed: Bool
    @Binding var hoveredMoment: Double?
    @Binding var hoveredReply: UInt64?

    var body: some View {
        let requests = model?.requests ?? []
        let recent = OutputSpeed.rate(requests, from: now - OutputSpeed.recent, to: now)
        let hour = OutputSpeed.rate(requests, from: now - OutputSpeed.span, to: now)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    SpeedHeadline(rate: recent)
                    ZStack(alignment: .leading) {
                        ModelSwitch(store: store, models: models, current: model)
                            .opacity(hoveredMoment == nil ? 1 : 0)
                        if let t = hoveredMoment, !detailed {
                            Text(SpeedSection.moment(t, requests: requests))
                                .font(.caption)
                                .foregroundStyle(Palette.tertiary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                if detailed {
                    HourFigures(rate: hour)
                } else {
                    SpeedSparkline(requests: requests, now: now, hovered: $hoveredMoment)
                        .frame(width: 104, height: 30)
                        .padding(.bottom, 3)
                        .help(SpeedSection.help(
                            hour, period: L10n.t("最近 1 小时", "In the last hour"),
                            note: L10n.t("折线上每一点是那一刻往前 5 分钟的均速，右端就是左边的数字。", "Each point is the 5-minute average up to that moment; the right end is the number on the left.")
                        ))
                }
            }
            if detailed {
                VStack(alignment: .leading, spacing: 6) {
                    SpeedChart(requests: requests, pending: model?.pending ?? [], now: now, hovered: $hoveredReply)
                        .frame(height: 64)
                    SpeedAxis(hovered: requests.first { $0.id == hoveredReply })
                }
            }
        }
        // 换成说明或收起时，指针离开的事件不会再来，悬停留下的时刻要清掉
        .onDisappear {
            hoveredMoment = nil
            hoveredReply = nil
        }
    }
}

/// 最近 1 小时没有回复时的说明
private struct SpeedEmpty: View {
    let untimed: Bool
    let generating: Bool

    var body: some View {
        if untimed {
            EmptyNote(
                icon: .clock,
                title: L10n.t("更新 Claude Code 后才能计时", "Update Claude Code to time replies"),
                detail: L10n.t("2.1.304 起会记下每个请求发出的时刻", "Version 2.1.304 and later record when each request is sent.")
            )
        } else if generating {
            EmptyNote(icon: .pulse, title: L10n.t("回复写完后显示速度", "The speed appears once the reply is written"))
        } else {
            EmptyNote(
                icon: .pulse,
                title: L10n.t("最近 1 小时没有回复", "No replies in the last hour"),
                detail: L10n.t("Claude Code 写完回复后，这里显示每秒输出多少 token", "Once Claude Code writes a reply, its tokens per second show here.")
            )
        }
    }
}

/// 收起后标题右侧：近 5 分钟的速度；正在生成时前面亮一个绿点
private struct SpeedSummary: View {
    let rate: OutputSpeed.Rate?
    let generating: Bool
    let replied: Bool
    let untimed: Bool

    var body: some View {
        HStack(spacing: 5) {
            if generating {
                Circle()
                    .fill(Palette.live)
                    .frame(width: 5, height: 5)
            }
            if let rate {
                let number = Text(SpeedSection.whole(rate.tokensPerSecond))
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.secondary)
                Text("\(number) tok/s")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: rate.tokensPerSecond.rounded()))
            } else if generating {
                Text(L10n.t("生成中", "Generating"))
            } else if untimed {
                Text(L10n.t("更新 Claude Code 后才能计时", "Update Claude Code to time replies"))
            } else {
                Text(replied ? L10n.t("近 5 分钟没有回复", "No replies in 5 min") : L10n.t("最近 1 小时没有回复", "No replies in the last hour"))
            }
        }
    }
}

/// 标题右侧：正在生成时，绿点加已经等了多久。没在生成时什么也不显示
private struct SpeedStatus: View {
    let pending: [PendingRequest]
    let now: Double

    var body: some View {
        ZStack(alignment: .trailing) {
            if let first = pending.first {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Palette.live)
                        .frame(width: 5, height: 5)
                    Text(generating(first, count: pending.count))
                        .foregroundStyle(Palette.secondary)
                        .monospacedDigit()
                }
                .transition(.opacity)
                .help(L10n.t("请求已经发出，回复写完后数字会更新", "The request is out. The number updates when the reply is written."))
            }
        }
        .animation(.quiet, value: pending.isEmpty)
    }

    private func generating(_ first: PendingRequest, count: Int) -> String {
        let elapsed = max(0, Int(now - first.start))
        let time = elapsed < 60
            ? L10n.t("\(elapsed) 秒", "\(elapsed)s")
            : L10n.t("\(elapsed / 60) 分 \(String(format: "%02d", elapsed % 60)) 秒", "\(elapsed / 60)m \(String(format: "%02d", elapsed % 60))s")
        return count > 1
            ? L10n.t("\(count) 个生成中 · \(time)", "\(count) generating · \(time)")
            : L10n.t("生成中 · \(time)", "Generating · \(time)")
    }
}

/// 近 5 分钟的加权均速：和本期消耗的金额同一种字号
private struct SpeedHeadline: View {
    let rate: OutputSpeed.Rate?

    var body: some View {
        let value = rate.map { Int($0.tokensPerSecond.rounded()) }
        let number = Text(value.map(String.init) ?? "–")
            .font(.system(size: 26, weight: .semibold))
            .tracking(-0.4)
            .foregroundStyle(value == nil ? Palette.tertiary : Palette.text)
        let unit = Text(" tok/s")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.tertiary)
        Text("\(number)\(unit)")
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(.numericText(value: Double(value ?? 0)))
            .animation(.smooth(duration: 0.5), value: value)
            .help(SpeedSection.help(rate, period: L10n.t("近 5 分钟", "In the last 5 minutes")))
    }
}

/// 「近 5 分钟 · Opus 5.5」。最近 1 小时用了几个模型时，点一下换下一个
private struct ModelSwitch: View {
    let store: UsageStore
    let models: [ModelSpeed]
    let current: ModelSpeed?

    @State private var hovering = false

    var body: some View {
        let switchable = models.count > 1
        HStack(spacing: 4) {
            Text(current.map { L10n.t("近 5 分钟 · \($0.title)", "Last 5 min · \($0.title)") } ?? L10n.t("近 5 分钟", "Last 5 min"))
            if switchable {
                SVGIcon(.chevronDown, size: 8, lineWidth: 2.4)
            }
        }
        .font(.caption)
        .foregroundStyle(switchable && hovering ? Palette.secondary : Palette.tertiary)
        .lineLimit(1)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.quiet) { hovering = inside } }
        .onTapGesture {
            guard switchable, let current, let index = models.firstIndex(where: { $0.id == current.id }) else { return }
            withAnimation(.smooth(duration: 0.4)) { store.speedChoice = models[(index + 1) % models.count].id }
        }
        .help(switchable ? L10n.t("最近 1 小时用了 \(models.count) 个模型，点击切换", "\(models.count) models in the last hour. Click to switch.") : "")
    }
}

// MARK: - 简洁

/// 最近 1 小时里近 5 分钟均速的变化，右端是现在、也就是左边的大数字。和本期消耗的柱状图一样大，没有坐标轴。
/// 纵轴按这一小时的高低缩放，只看变化；范围至少是最高值的三成，几 tok/s 的抖动不会被放大成大起伏
private struct SpeedSparkline: View {
    let requests: [TimedRequest]
    let now: Double
    @Binding var hovered: Double?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let count = max(2, Int(size.width / 2) + 1)
            let from = now - OutputSpeed.span
            let values = OutputSpeed.curve(requests, from: from, to: now, count: count)
            let scale = Scale(size: size, count: count, values: values.compactMap { $0 })
            let point = scale.point
            let hoveredIndex = hovered.map { scale.index(($0 - from) / OutputSpeed.span) }

            Canvas { context, _ in
                guard values.contains(where: { $0 != nil }) else {
                    // 最近 1 小时没有回复：只留一条淡淡的底线
                    context.fill(Path(CGRect(x: 0, y: size.height - 1.5, width: size.width, height: 1.5)), with: .color(Color.white.opacity(0.12)))
                    return
                }
                // 窗口里没有回复的地方断开
                var line = Path()
                var drawing = false
                for (i, value) in values.enumerated() {
                    guard let value else {
                        drawing = false
                        continue
                    }
                    if drawing { line.addLine(to: point(i, value)) } else { line.move(to: point(i, value)) }
                    drawing = true
                }
                context.stroke(line, with: .color(Color.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .overlay(alignment: .topLeading) {
                // 现在：和柱状图里的今天一样用强调色，新回复写进来时滑到新的高度
                if let last = values.last ?? nil {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 5, height: 5)
                        .position(point(count - 1, last))
                        .animation(.smooth(duration: 0.5), value: last)
                }
                if let i = hoveredIndex, let value = values[i] {
                    Circle()
                        .fill(Palette.text)
                        .frame(width: 4, height: 4)
                        .position(point(i, value))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let i = scale.index(Double(p.x / size.width))
                    let t = from + OutputSpeed.span * Double(i) / Double(count - 1)
                    if hovered != t { hovered = t }
                case .ended:
                    hovered = nil
                }
            }
            .accessibilityElement()
            .accessibilityLabel(L10n.t("最近 1 小时的输出速度变化", "Output speed over the last hour"))
        }
    }

    /// 第 i 个时刻的值画在哪
    private struct Scale {
        let size: CGSize
        let count: Int
        let bottom: Double
        let range: Double

        init(size: CGSize, count: Int, values: [Double]) {
            self.size = size
            self.count = count
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            let span = max(high - low, high * 0.3, 1)
            // 上下各留一成
            bottom = max(0, (low + high) / 2 - span * 0.6)
            range = span * 1.2
        }

        func point(_ i: Int, _ value: Double) -> CGPoint {
            let x = size.width * CGFloat(i) / CGFloat(count - 1)
            let rise = (size.height - 2) * CGFloat(min(max((value - bottom) / range, 0), 1))
            return CGPoint(x: x, y: size.height - 1 - rise)
        }

        /// 横向位置（0…1）最近的那个时刻
        func index(_ fraction: Double) -> Int {
            let raw = Int((fraction * Double(count - 1)).rounded())
            return min(max(raw, 0), count - 1)
        }
    }
}

// MARK: - 每次回复

/// 右侧：最近 1 小时的均速和回复次数
private struct HourFigures: View {
    let rate: OutputSpeed.Rate?

    var body: some View {
        if let rate {
            VStack(alignment: .trailing, spacing: 3) {
                Text(L10n.t("1 小时 \(SpeedSection.whole(rate.tokensPerSecond)) tok/s", "1 hr \(SpeedSection.whole(rate.tokensPerSecond)) tok/s"))
                    .foregroundStyle(Palette.secondary)
                Text(L10n.t("\(Fmt.grouped(rate.count)) 次 · \(Fmt.magnitude(Int64(rate.output))) tokens", "\(Fmt.grouped(rate.count)) replies · \(Fmt.magnitude(Int64(rate.output))) tokens"))
                    .foregroundStyle(Palette.tertiary)
            }
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(.numericText())
            .animation(.smooth(duration: 0.5), value: rate)
            .help(SpeedSection.help(rate, period: L10n.t("最近 1 小时", "In the last hour")))
        }
    }
}

/// 图下方的时间刻度；指针停在某个点上时换成那次回复的算式
private struct SpeedAxis: View {
    let hovered: TimedRequest?

    var body: some View {
        ZStack {
            Text(L10n.t("60 分钟前", "60 min ago")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.t("30 分钟前", "30 min ago"))
            Text(L10n.t("现在", "Now")).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(Palette.tertiary)
        .opacity(hovered == nil ? 1 : 0)
        .overlay(alignment: .leading) {
            if let hovered {
                Text(Self.detail(hovered))
                    .foregroundStyle(Palette.secondary)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
    }

    /// 23:31:05 · 2,821 tokens ÷ 31.1 秒 = 91 tok/s。速度用显示出来的秒数算，心算对得上
    static func detail(_ r: TimedRequest) -> String {
        let time = LimitsSection.formatter("HH:mm:ss").string(from: Date(timeIntervalSince1970: r.end))
        let seconds = String(format: "%.1f", r.duration)
        let shown = Double(seconds) ?? r.duration
        let rate = shown > 0 ? SpeedSection.whole(Double(r.output) / shown) : "–"
        return L10n.t(
            "\(time) · \(Fmt.grouped(r.output)) tokens ÷ \(seconds) 秒 = \(rate) tok/s",
            "\(time) · \(Fmt.grouped(r.output)) tokens ÷ \(seconds)s = \(rate) tok/s"
        )
    }
}

/// 最近 1 小时，右边是现在。每个点是一次回复，纵轴是这一次的速度；白线是近 5 分钟均速，底部的绿线是正在生成的请求
private struct SpeedChart: View {
    let requests: [TimedRequest]
    let pending: [PendingRequest]
    let now: Double
    @Binding var hovered: UInt64?

    var body: some View {
        GeometryReader { geo in
            let shown = requests.filter { $0.end > now - OutputSpeed.span }
            let layout = Layout(size: geo.size, now: now, ceiling: OutputSpeed.ceiling(shown))
            Canvas { context, size in
                draw(in: &context, size: size, layout: layout, shown: shown)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    // 12pt 以内最近的点
                    var best: UInt64?
                    var distance: CGFloat = 144
                    for r in shown {
                        let q = layout.point(r)
                        let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
                        if d < distance { distance = d; best = r.id }
                    }
                    if hovered != best { hovered = best }
                case .ended:
                    hovered = nil
                }
            }
            .accessibilityElement()
            .accessibilityLabel(L10n.t("最近 1 小时每次回复的输出速度", "Output speed of each reply in the last hour"))
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, layout: Layout, shown: [TimedRequest]) {
        // 唯一一条参考线，数字标在左端
        let grid = OutputSpeed.gridline(below: layout.ceiling)
        let gy = layout.y(grid)
        context.fill(Path(CGRect(x: 0, y: gy - 0.25, width: size.width, height: 0.5)), with: .color(Palette.divider))
        context.draw(
            Text(String(Int(grid))).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.28)),
            at: CGPoint(x: 0, y: gy - 2), anchor: .bottomLeading
        )

        for r in shown {
            let p = layout.point(r)
            let radius = Self.radius(r)
            let dot = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            // 很淡：几个会话同时在跑时一小时有几百个点，叠在一起的地方自然亮一些
            context.fill(dot, with: .color(r.id == hovered ? Palette.accent : Color.white.opacity(0.22)))
        }

        // 近 5 分钟均速：每 2pt 取一个时刻，窗口里没有回复的地方断开。最右端就是上面的大数字
        let count = max(2, Int(layout.plotWidth / 2))
        let values = OutputSpeed.curve(requests, from: now - OutputSpeed.span, to: now, count: count)
        var line = Path()
        var drawing = false
        for (i, value) in values.enumerated() {
            guard let value else {
                drawing = false
                continue
            }
            let t = now - OutputSpeed.span + OutputSpeed.span * Double(i) / Double(count - 1)
            let p = CGPoint(x: layout.x(t), y: layout.y(value))
            if drawing { line.addLine(to: p) } else { line.move(to: p) }
            drawing = true
        }
        context.stroke(line, with: .color(Color.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

        // 正在生成：从发出那一刻画到现在，几个同时在跑时往上错开
        for (i, p) in pending.enumerated() {
            let x0 = max(0, layout.x(p.start))
            let x1 = layout.x(now)
            let bar = CGRect(x: min(x0, x1 - 2), y: size.height - 1.5 - CGFloat(i) * 3, width: max(2, x1 - x0), height: 1.5)
            context.fill(Path(roundedRect: bar, cornerRadius: 0.75), with: .color(Palette.live))
        }
    }

    /// 输出 100 tokens 约 1.3pt，1000 约 1.8pt，最大 3pt：大小只是个提示，不让长回复变成一个个泡泡
    static func radius(_ r: TimedRequest) -> CGFloat {
        min(3, 1.1 + CGFloat(Double(r.output).squareRoot()) / 45)
    }

    struct Layout {
        let size: CGSize
        let now: Double
        let ceiling: Double
        /// 左右各留一点，贴边的点不会被裁掉一半
        static let inset: CGFloat = 4

        var plotWidth: CGFloat { max(1, size.width - Self.inset * 2) }

        func x(_ t: Double) -> CGFloat {
            Self.inset + plotWidth * CGFloat(1 - (now - t) / OutputSpeed.span)
        }

        /// 顶上留给最大的点，底下留给生成中的绿线
        func y(_ rate: Double) -> CGFloat {
            let top: CGFloat = 5
            let bottom = size.height - 5
            return bottom - (bottom - top) * CGFloat(min(rate, ceiling) / ceiling)
        }

        func point(_ r: TimedRequest) -> CGPoint { CGPoint(x: x(r.end), y: y(r.rate)) }
    }
}
