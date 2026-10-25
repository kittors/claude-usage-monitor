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
    /// 简洁：指针停在折线上离现在多少秒。存距离而不是时刻：折线每秒左移，指针不动时，指着的是它下面现在那个点
    @State private var hoveredAge: Double?
    /// 详细：指针停在哪一次回复上
    @State private var hoveredReply: UInt64?

    var body: some View {
        let detailed = prefs.speedDisplay == .detailed
        // 每秒走一格：生成中的秒数、时间轴左移、滑出近 5 分钟的回复。面板收起时停下
        TimelineView(.animation(minimumInterval: 1, paused: !visible)) { context in
            SpeedContent(
                store: store, prefs: prefs, now: context.date.timeIntervalSince1970, detailed: detailed,
                hoveredAge: $hoveredAge, hoveredReply: $hoveredReply
            )
        }
        // 面板收起时指针离开的事件不会来：下次打开不能还停在上次指着的那一点
        .onChange(of: visible) { _, visible in
            guard !visible else { return }
            hoveredAge = nil
            hoveredReply = nil
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

    /// 一段时间里的回复：几次、输出多少、生成用了多久。耗时精确到 0.1 秒，拿显示出来的数心算也对得上
    static func breakdown(_ rate: OutputSpeed.Rate) -> [Tip.Row] {
        let seconds = String(format: "%.1f", rate.duration)
        return [
            .init(L10n.t("回复", "Replies"), L10n.t("\(Fmt.grouped(rate.count)) 次", Fmt.grouped(rate.count))),
            .init(L10n.t("输出", "Output"), "\(Fmt.grouped(rate.output)) tokens"),
            .init(L10n.t("生成耗时", "Time"), L10n.t("\(seconds) 秒", "\(seconds)s")),
        ]
    }

    /// 速度是怎么算的
    static var basis: String {
        L10n.t(
            "速度 = 输出 ÷ 生成耗时，按 token 加权。耗时从请求发出算到回复写完，包含排队和等第一个字，所以短回复显得慢。思考的 token 也算输出。",
            "Speed = output ÷ time, weighted by tokens. Time runs from sending the request to the end of the reply, including the queue and the wait for the first token, so short replies look slow. Thinking counts as output."
        )
    }

    /// 近 5 分钟的说明。简洁时右边没有最近 1 小时的统计，传进来一起写上；
    /// 收起后的摘要只看个大概，不带算法说明，面板很矮时也放得下
    static func recentTip(_ recent: OutputSpeed.Rate?, hour: OutputSpeed.Rate?, model: ModelSpeed?, explains: Bool = true) -> Tip {
        var rows = recent.map(breakdown) ?? []
        if let hour {
            rows.append(.init(
                L10n.t("最近 1 小时", "Last hour"),
                L10n.t("\(whole(hour.tokensPerSecond)) tok/s · \(Fmt.grouped(hour.count)) 次", "\(whole(hour.tokensPerSecond)) tok/s · \(Fmt.grouped(hour.count)) replies"),
                separated: true
            ))
        }
        let name = model.map { " · \($0.title)" } ?? ""
        var notes: [String] = []
        if recent == nil { notes.append(L10n.t("这 5 分钟里没有写完的回复。", "No reply finished in these 5 minutes.")) }
        if explains { notes.append(basis) }
        return Tip(title: L10n.t("近 5 分钟\(name)", "Last 5 min\(name)"), rows: rows, note: notes.isEmpty ? nil : notes.joined(separator: L10n.t("", " ")))
    }

    /// 详细时右边那两行：最近 1 小时是怎么算出来的
    static func hourTip(_ hour: OutputSpeed.Rate?, model: ModelSpeed?) -> Tip? {
        guard let hour else { return nil }
        let name = model.map { " · \($0.title)" } ?? ""
        return Tip(title: L10n.t("最近 1 小时\(name)", "Last hour\(name)"), rows: breakdown(hour), note: basis)
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
    @Binding var hoveredAge: Double?
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
                .contentShape(Rectangle())
                .tip("speed.summary") { summaryTip(recent, requests: requests, model: model, replied: replied, untimed: untimed) }
        } content: {
            if replied {
                SpeedFigures(
                    store: store, models: models, model: model, now: now, detailed: detailed,
                    hoveredAge: $hoveredAge, hoveredReply: $hoveredReply
                )
            } else {
                SpeedEmpty(untimed: untimed, generating: !pending.isEmpty)
            }
        }
    }
}

extension SpeedContent {
    /// 收起后的摘要：近 5 分钟和最近 1 小时的数字，不带算法说明；没有回复时不浮起，Claude Code 太旧时说明怎么办
    private func summaryTip(_ recent: OutputSpeed.Rate?, requests: [TimedRequest], model: ModelSpeed?, replied: Bool, untimed: Bool) -> Tip? {
        if untimed {
            return Tip(L10n.t("2.1.304 起的 Claude Code 会记下每个请求发出的时刻，更新后就能计时", "Claude Code 2.1.304 and later record when each request is sent. Update to time replies."))
        }
        guard replied else { return nil }
        let hour = OutputSpeed.rate(requests, from: now - OutputSpeed.span, to: now)
        return SpeedSection.recentTip(recent, hour: hour, model: model, explains: false)
    }
}

/// 最近 1 小时有回复时：左边大数字和模型，右边折线（详细时是统计），详细时下面再画每一次回复
private struct SpeedFigures: View {
    let store: UsageStore
    let models: [ModelSpeed]
    let model: ModelSpeed?
    let now: Double
    let detailed: Bool
    @Binding var hoveredAge: Double?
    @Binding var hoveredReply: UInt64?

    var body: some View {
        let requests = model?.requests ?? []
        let recent = OutputSpeed.rate(requests, from: now - OutputSpeed.recent, to: now)
        let hour = OutputSpeed.rate(requests, from: now - OutputSpeed.span, to: now)
        // 简洁时右边的折线和指着它时左下那一行用同一组点
        let trend = detailed ? [] : OutputSpeed.trend(requests, from: now - OutputSpeed.span, to: now)
        let pointed = hoveredAge.flatMap { SpeedLine.nearest(trend, to: now - $0) }.map { trend[$0] }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    SpeedHeadline(rate: recent)
                        .tip("speed.recent") { SpeedSection.recentTip(recent, hour: detailed ? nil : hour, model: model) }
                    ZStack(alignment: .leading) {
                        ModelSwitch(store: store, models: models, current: model, now: now)
                            .opacity(pointed == nil ? 1 : 0)
                        if let pointed {
                            Text(SpeedSection.moment(pointed.t, requests: requests))
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
                        .tip("speed.hour") { SpeedSection.hourTip(hour, model: model) }
                } else {
                    // 指着折线时左下那一行换成那一刻的速度，不另外浮起说明，免得挡住折线
                    SpeedSparkline(trend: trend, now: now, hoveredAge: $hoveredAge)
                        .frame(width: 104, height: 30)
                        .padding(.bottom, 3)
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
            hoveredAge = nil
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
                .tip("speed.pending") { Tip(L10n.t("请求已经发出，回复写完后数字会更新", "The request is out. The number updates when the reply is written.")) }
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
    }
}

/// 「近 5 分钟 · Opus 5.5」。最近 1 小时用了几个模型时，点一下换下一个
private struct ModelSwitch: View {
    let store: UsageStore
    let models: [ModelSpeed]
    let current: ModelSpeed?
    let now: Double

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
        .tip("speed.models") { switchable ? modelsTip : nil }
    }

    /// 几个模型各自最近 1 小时的速度，圆点标出现在显示的那个
    private var modelsTip: Tip {
        let rows = models.map { m in
            let value = OutputSpeed.rate(m.requests, from: now - OutputSpeed.span, to: now).map {
                L10n.t("\(SpeedSection.whole($0.tokensPerSecond)) tok/s · \(Fmt.grouped($0.count)) 次", "\(SpeedSection.whole($0.tokensPerSecond)) tok/s · \(Fmt.grouped($0.count)) replies")
            } ?? (m.pending.isEmpty ? "–" : L10n.t("生成中", "Generating"))
            return Tip.Row(m.title, value, dot: m.id == current?.id ? Palette.accent : Palette.quaternary)
        }
        return Tip(title: L10n.t("最近 1 小时用了 \(models.count) 个模型", "\(models.count) models in the last hour"), rows: rows, note: L10n.t("点击换下一个", "Click to show the next one."))
    }
}

// MARK: - 简洁

/// 最近 1 小时里近 5 分钟均速的变化，右端是现在、也就是左边的大数字。和本期消耗的柱状图一样大，没有坐标轴。
/// 纵轴按这一小时的高低缩放，只看变化；范围至少是最高值的三成，几 tok/s 的抖动不会被放大成大起伏
private struct SpeedSparkline: View {
    let trend: [OutputSpeed.TrendPoint]
    let now: Double
    @Binding var hoveredAge: Double?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let scale = Scale(size: size, now: now, values: trend.map(\.rate))
            let points = trend.map(scale.point)
            let pointed = hoveredAge.flatMap { SpeedLine.nearest(trend, to: now - $0) }

            Canvas { context, _ in
                guard !points.isEmpty else {
                    // 最近 1 小时没有回复：只留一条淡淡的底线
                    context.fill(Path(CGRect(x: 0, y: size.height - 1.5, width: size.width, height: 1.5)), with: .color(Color.white.opacity(0.12)))
                    return
                }
                context.stroke(SpeedLine.path(points), with: .color(Color.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .overlay(alignment: .topLeading) {
                // 现在：和柱状图里的今天一样用强调色，新回复写进来时滑到新的高度。近 5 分钟没有回复时线停在最后一次回复，不画这个点
                if let last = trend.last, last.t == now, let point = points.last {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 5, height: 5)
                        .position(point)
                        .animation(.smooth(duration: 0.5), value: last.rate)
                }
                if let i = pointed {
                    Circle()
                        .fill(Palette.text)
                        .frame(width: 4, height: 4)
                        .position(points[i])
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    // 吸附到最近的那次回复，记下它离现在多久；换到另一个点时才更新
                    let t = now - OutputSpeed.span * Double(1 - min(max(p.x / max(size.width, 1), 0), 1))
                    let age = SpeedLine.nearest(trend, to: t).map { now - trend[$0].t }
                    if hoveredAge != age { hoveredAge = age }
                case .ended:
                    hoveredAge = nil
                }
            }
            .accessibilityElement()
            .accessibilityLabel(L10n.t("最近 1 小时的输出速度变化", "Output speed over the last hour"))
        }
    }

    /// 每个点画在哪：横向按时间，最右边是现在
    private struct Scale {
        let size: CGSize
        let now: Double
        let bottom: Double
        let range: Double

        init(size: CGSize, now: Double, values: [Double]) {
            self.size = size
            self.now = now
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            let span = max(high - low, high * 0.3, 1)
            // 上下各留一成
            bottom = max(0, (low + high) / 2 - span * 0.6)
            range = span * 1.2
        }

        func point(_ p: OutputSpeed.TrendPoint) -> CGPoint {
            let x = size.width * CGFloat(1 - (now - p.t) / OutputSpeed.span)
            let rise = (size.height - 2) * CGFloat(min(max((p.rate - bottom) / range, 0), 1))
            return CGPoint(x: x, y: size.height - 1 - rise)
        }
    }
}

/// 均速线的画法和取点，详细的图和简洁的折线共用
private enum SpeedLine {
    /// 横向挨得比这个近的点只留后一个：一小时几百次回复时，线不会在一个像素里来回折
    private static let minimumGap: CGFloat = 1.5

    /// 经过每个点的平滑曲线。两点之间用单调三次曲线（Steffen 方法，和 d3 的 monotoneX 一样），
    /// 只会在这两个点的高低之间，不会冲出去画出比实际更高或更低的弯
    static func path(_ points: [CGPoint]) -> Path {
        let p = thinned(points)
        var path = Path()
        guard let first = p.first else { return path }
        path.move(to: first)
        guard p.count > 2 else {
            // 只有一个点时画成一个圆点（圆头的零长度线段）
            path.addLine(to: p.count == 2 ? p[1] : first)
            return path
        }
        let n = p.count
        var h = [CGFloat](repeating: 0, count: n - 1)
        var slope = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            h[i] = p[i + 1].x - p[i].x
            slope[i] = h[i] > 0 ? (p[i + 1].y - p[i].y) / h[i] : 0
        }
        var tangent = [CGFloat](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            let s0 = slope[i - 1], s1 = slope[i]
            let mean = (s0 * h[i] + s1 * h[i - 1]) / (h[i - 1] + h[i])
            let limit = min(abs(s0), abs(s1), abs(mean) / 2)
            tangent[i] = (sign(s0) + sign(s1)) * limit
        }
        tangent[0] = endTangent(slope[0], neighbor: tangent[1])
        tangent[n - 1] = endTangent(slope[n - 2], neighbor: tangent[n - 2])
        for i in 0..<(n - 1) {
            let dx = h[i] / 3
            path.addCurve(
                to: p[i + 1],
                control1: CGPoint(x: p[i].x + dx, y: p[i].y + dx * tangent[i]),
                control2: CGPoint(x: p[i + 1].x - dx, y: p[i + 1].y - dx * tangent[i + 1])
            )
        }
        return path
    }

    /// 离 t 最近的点（点按时间排好）
    static func nearest(_ trend: [OutputSpeed.TrendPoint], to t: Double) -> Int? {
        guard !trend.isEmpty else { return nil }
        var lo = 0, hi = trend.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if trend[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return 0 }
        if lo == trend.count { return trend.count - 1 }
        return t - trend[lo - 1].t <= trend[lo].t - t ? lo - 1 : lo
    }

    private static func thinned(_ points: [CGPoint]) -> [CGPoint] {
        var kept: [CGPoint] = []
        kept.reserveCapacity(points.count)
        for point in points {
            if kept.count > 1, let last = kept.last, point.x - last.x < minimumGap {
                kept[kept.count - 1] = point
            } else {
                kept.append(point)
            }
        }
        return kept
    }

    private static func sign(_ v: CGFloat) -> CGFloat {
        v > 0 ? 1 : (v < 0 ? -1 : 0)
    }

    /// 两端的切线：照着旁边那段推，再限住大小、方向和那一段一致，第一段和最后一段也不会冲出去
    private static func endTangent(_ slope: CGFloat, neighbor: CGFloat) -> CGFloat {
        let t = (3 * slope - neighbor) / 2
        if sign(t) != sign(slope) { return 0 }
        return abs(t) > 3 * abs(slope) ? 3 * slope : t
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

        // 近 5 分钟均速：每次回复写完时取一个点，连成一条平滑的线，没有回复的时段直接连过去。最右端就是上面的大数字
        let trend = OutputSpeed.trend(requests, from: now - OutputSpeed.span, to: now)
        let line = SpeedLine.path(trend.map { CGPoint(x: layout.x($0.t), y: layout.y($0.rate)) })
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
