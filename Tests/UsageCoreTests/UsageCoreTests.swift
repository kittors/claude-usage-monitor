import Foundation
import Testing
@testable import UsageCore

// MARK: - 解析

@Test func timestampParsingMatchesFoundation() throws {
    let samples = [
        "2026-09-28T14:40:53.806Z",
        "2026-02-28T23:59:59Z",
        "2024-02-29T00:00:00.5Z",
        "2026-09-28T22:40:53.806+08:00",
        "1999-12-31T23:59:59.999-05:30",
    ]
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let g = ISO8601DateFormatter()
    for s in samples {
        let expected = (f.date(from: s) ?? g.date(from: s))!.timeIntervalSince1970
        let actual = try #require(TokenParser.parseTimestamp(s))
        #expect(abs(actual - expected) < 0.001, "\(s)")
    }
    #expect(TokenParser.parseTimestamp("not a date") == nil)
}

private func line(id: String, req: String, output: Int, time: String = "2026-09-28T14:40:53.806Z",
                  model: String = "claude-opus-5-5", session: String = "s1", sidechain: Bool = false) -> String {
    """
    {"parentUuid":"p","isSidechain":\(sidechain),"message":{"model":"\(model)","id":"\(id)","type":"message","role":"assistant","content":[{"type":"text","text":"hi \\"usage\\" {}"}],"stop_reason":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":300,"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200},"output_tokens":\(output),"service_tier":"standard","iterations":[{"input_tokens":2,"output_tokens":\(output),"type":"message","model":null}],"speed":"standard"}},"requestId":"\(req)","type":"assistant","uuid":"u","timestamp":"\(time)","cwd":"/Users/me/Dev/Lyra","sessionId":"\(session)","gitBranch":"main"}
    """
}

@Test func parsesAssistantUsageAndTitles() {
    let body = [
        line(id: "msg_1", req: "req_1", output: 9),
        #"{"type":"user","message":{"role":"user","content":"hello"},"sessionId":"s1"}"#,
        #"{"type":"custom-title","customTitle":"重构计费模块","sessionId":"s1"}"#,
        line(id: "msg_1", req: "req_1", output: 766),
    ].joined(separator: "\n") + "\n" + #"{"type":"assistant","partial"#  // 未写完的最后一行

    let result = TokenParser.parse(data: Data(body.utf8), from: 0)
    #expect(result.events.count == 3)
    #expect(result.endOffset == Int64(body.utf8.count - #"{"type":"assistant","partial"#.utf8.count))

    guard case .usage(let first) = result.events[0] else { Issue.record("expected usage"); return }
    #expect(first.model == "claude-opus-5-5")
    #expect(first.tokens.input == 2)
    #expect(first.tokens.cacheWrite5m == 100)
    #expect(first.tokens.cacheWrite1h == 200)
    #expect(first.tokens.cacheRead == 1000)
    #expect(first.cwd == "/Users/me/Dev/Lyra")

    guard case .title(let sid, let title) = result.events[1] else { Issue.record("expected title"); return }
    #expect(sid == "s1" && title == "重构计费模块")
}

@Test func deduplicatesStreamingLinesKeepingFinalOutput() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cum-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let main = dir.appendingPathComponent("s1.jsonl")
    let sub = dir.appendingPathComponent("s1/subagents/agent-a.jsonl")
    try FileManager.default.createDirectory(at: sub.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (line(id: "m1", req: "r1", output: 9) + "\n" + line(id: "m1", req: "r1", output: 766) + "\n")
        .write(to: main, atomically: true, encoding: .utf8)
    // 同一条消息出现在另一个文件里（例如 resume 复制的历史），不应重复计数
    try (line(id: "m1", req: "r1", output: 766) + "\n" + line(id: "m2", req: "r2", output: 50, sidechain: true) + "\n")
        .write(to: sub, atomically: true, encoding: .utf8)

    let index = UsageIndex(sourceSignature: "test")
    let stats = index.scan(roots: [dir])
    #expect(stats.filesParsed == 2)
    #expect(index.records.count == 2)
    let m1 = try #require(index.records.first { $0.output == 766 })
    #expect(m1.cacheRead == 1000)

    // 增量追加
    let handle = try FileHandle(forWritingTo: main)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line(id: "m3", req: "r3", output: 5, time: "2026-09-28T15:00:00Z") + "\n").utf8))
    try handle.close()
    let again = index.scan(roots: [dir])
    #expect(again.filesParsed == 1)
    #expect(again.recordsAdded == 1)
    #expect(index.records.count == 3)

    // 会话上下文取主链最后一条
    let meta = try #require(index.sessions.first { $0.id == "s1" })
    #expect(meta.context.output == 5)

    // 持久化往返
    let cache = dir.appendingPathComponent("index.bin")
    try index.write(to: cache)
    let loaded = try UsageIndex.read(from: cache)
    #expect(loaded.records == index.records)
    #expect(loaded.sessions == index.sessions)
    // 加载后第一次扫描：最近改过的文件从头再读一遍补上请求的计时，记录去重后不变；之后不再读没变的文件
    let primed = loaded.scan(roots: [dir])
    #expect(primed.recordsAdded == 0)
    #expect(primed.recordsUpdated == 0)
    #expect(loaded.records == index.records)
    #expect(loaded.scan(roots: [dir]).filesParsed == 0)
}

// MARK: - 定价

@Test func pricingMatchesClaudeCodeCostState() {
    // 与 Claude Code cost-state 中 claude-opus-5-5 的 totalCostUSD 核对过的公式
    let info = PricingCatalog.info(for: "claude-opus-5-5")
    let price = try! #require(info.price)
    let t = TokenCounts(input: 1_000_000, output: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
    #expect(abs(price.cost(t) - (4 + 20 + 5 + 8 + 0.2)) < 1e-9)
    #expect(abs(price.cost(t, fast: true) - 2 * (4 + 20 + 5 + 8 + 0.2)) < 1e-9)

    #expect(PricingCatalog.info(for: "claude-fable-5-1").price?.cacheRead == 0.25)
    #expect(PricingCatalog.info(for: "claude-fable-5").price?.cacheRead == 1.0)
    #expect(PricingCatalog.info(for: "claude-opus-5").price?.input == 5)
    #expect(PricingCatalog.info(for: "claude-haiku-4-5-20251001").price?.input == 1)
    #expect(PricingCatalog.info(for: "us.anthropic.claude-sonnet-5").price?.input == 2)
    #expect(PricingCatalog.info(for: "claude-haiku-4-5-20251001").contextWindow == 200_000)
    #expect(PricingCatalog.info(for: "claude-opus-4-6[1m]").contextWindow == 1_000_000)
    #expect(PricingCatalog.info(for: "gpt-5").price == nil)
}

@Test func modelDisplayNames() {
    #expect(PricingCatalog.info(for: "claude-opus-5-5").displayName == "Opus 5.5")
    #expect(PricingCatalog.info(for: "claude-fable-5-1").displayName == "Fable 5.1")
    #expect(PricingCatalog.info(for: "claude-haiku-4-5-20251001").displayName == "Haiku 4.5")
    #expect(PricingCatalog.info(for: "claude-3-5-sonnet-20241022").displayName == "Sonnet 3.5")
    #expect(PricingCatalog.info(for: "claude-opus-5").family == .opus)
}

@Test func haikuFiveFiveTiersByPromptLength() throws {
    let info = PricingCatalog.info(for: "claude-haiku-5-5")
    let price = try #require(info.price)
    #expect(info.displayName == "Haiku 5.5")
    #expect(info.contextWindow == 1_000_000)
    #expect(!info.isEstimated)
    #expect(price.input == 0.10 && price.output == 0.50)
    #expect(abs(price.cacheRead - 0.01) < 1e-12)

    // 提示词（新增输入 + 缓存写入 + 缓存读取）正好 10 万：第一档
    let short = TokenCounts(input: 1, output: 1_000_000, cacheWrite5m: 50_000, cacheRead: 49_999)
    #expect(abs(price.cost(short) - (0.0000001 + 0.00625 + 0.00049999 + 0.5)) < 1e-9)
    // 超过 10 万：整次请求的每个 token 都按第二档
    let long = TokenCounts(input: 1, output: 1_000_000, cacheWrite5m: 50_000, cacheRead: 50_000)
    #expect(abs(price.cost(long) - (0.0000005 + 0.03125 + 0.0025 + 2.5)) < 1e-9)

    var split = CategoryCosts()
    split.add(long, price: price)
    #expect(abs(split.input + split.output + split.cacheWrite + split.cacheRead - price.cost(long)) < 1e-9)

    // 没有列出的 Haiku 型号按当前代（5.5）估价
    #expect(PricingCatalog.info(for: "claude-haiku-6").price?.input == 0.10)
    #expect(PricingCatalog.info(for: "claude-haiku-6").isEstimated)
}

@Test func sonnetFiveFiveHasItsOwnCacheReadPrice() {
    let info = PricingCatalog.info(for: "us.anthropic.claude-sonnet-5-5")
    #expect(info.displayName == "Sonnet 5.5")
    #expect(info.price?.input == 2)
    #expect(info.price?.output == 10)
    #expect(info.price?.cacheRead == 0.10)
    #expect(!info.isEstimated)
}

// MARK: - 时间窗口

private var shanghai: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return c
}

private func date(_ s: String, _ cal: Calendar = shanghai) -> Date {
    let f = DateFormatter()
    f.calendar = cal
    f.timeZone = cal.timeZone
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}

@Test func billingIntervalHandlesAnchorDays() {
    let cal = shanghai
    var i = UsageCalculator.billingInterval(now: date("2026-09-28 12:00"), anchorDay: 15, calendar: cal)
    #expect(i.start == date("2026-09-15 00:00") && i.end == date("2026-10-15 00:00"))

    i = UsageCalculator.billingInterval(now: date("2026-09-10 12:00"), anchorDay: 15, calendar: cal)
    #expect(i.start == date("2026-08-15 00:00") && i.end == date("2026-09-15 00:00"))

    // 31 号扣费：2 月取最后一天
    i = UsageCalculator.billingInterval(now: date("2026-03-05 12:00"), anchorDay: 31, calendar: cal)
    #expect(i.start == date("2026-02-28 00:00") && i.end == date("2026-03-31 00:00"))

    i = UsageCalculator.billingInterval(now: date("2026-01-01 00:00"), anchorDay: 1, calendar: cal)
    #expect(i.start == date("2026-01-01 00:00") && i.end == date("2026-02-01 00:00"))
    #expect(UsageCalculator.periodTitle(start: i.start, end: i.end, calendar: cal) == "1月1日 – 1月31日")
}

@Test func billingIntervalStartsAtResetTime() {
    let cal = shanghai
    // 28 日 22:00 才换周期：当天 21:00 仍是上一周期
    var i = UsageCalculator.billingInterval(now: date("2026-09-28 21:00"), anchorDay: 28, hour: 22, calendar: cal)
    #expect(i.start == date("2026-08-28 22:00") && i.end == date("2026-09-28 22:00"))
    #expect(UsageCalculator.periodTitle(start: i.start, end: i.end, calendar: cal) == "8月28日 22:00 – 9月28日 21:59")

    i = UsageCalculator.billingInterval(now: date("2026-09-28 22:00"), anchorDay: 28, hour: 22, calendar: cal)
    #expect(i.start == date("2026-09-28 22:00") && i.end == date("2026-10-28 22:00"))

    // 2 月没有 31 日，时刻仍保留
    i = UsageCalculator.billingInterval(now: date("2026-03-05 12:00"), anchorDay: 31, hour: 22, minute: 30, calendar: cal)
    #expect(i.start == date("2026-02-28 22:30") && i.end == date("2026-03-31 22:30"))
}

@Test func weeklyIntervalFollowsTheOfficialReset() throws {
    let cal = shanghai
    // 面板上的「周六 22:00」：下一次重置是 10 月 3 日。9 月 29 日仍属于从 9 月 26 日 22:00 开始的这一周。
    let reset = date("2026-10-03 22:00")
    var i = UsageCalculator.weeklyInterval(now: date("2026-09-29 10:37"), reset: reset)
    #expect(i.start == date("2026-09-26 22:00") && i.end == reset)

    // 重置那一刻起算新的一周
    i = UsageCalculator.weeklyInterval(now: reset, reset: reset)
    #expect(i.start == reset && i.end == date("2026-10-10 22:00"))

    i = UsageCalculator.weeklyInterval(now: date("2026-10-03 21:59"), reset: reset)
    #expect(i.start == date("2026-09-26 22:00") && i.end == reset)

    let now = date("2026-09-29 10:37")
    let boundary = date("2026-09-26 22:00").timeIntervalSince1970
    let records = [record(boundary - 3600), record(boundary + 60), record(now.timeIntervalSince1970 - 60)]
    let snap = UsageCalculator.snapshot(
        of: IndexSnapshot(records: records, models: ["claude-opus-5-5"]),
        settings: UsageSettings(billingAnchorDay: 28, billingAnchorHour: 22, weeklyReset: reset, calendar: cal),
        now: now
    )
    let week = try #require(snap.week)
    // 重置前一小时不算本周；当天的自然日只含现在这条
    #expect(week.requests == 2)
    #expect(abs(week.cost - 40) < 1e-9)
    #expect(week.start == date("2026-09-26 22:00"))
    #expect(UsageCalculator.periodRange(start: week.start, end: week.end, calendar: cal) == "9月26日 22:00:00 – 10月3日 21:59:59")
    let today = snap.day
    #expect(UsageCalculator.periodRange(start: today.start, end: today.end, calendar: cal) == "9月29日 00:00:00 – 9月29日 23:59:59")
    #expect(UsageCalculator.periodRange(start: snap.billing.start, end: snap.billing.end, calendar: cal) == "9月28日 22:00:00 – 10月28日 21:59:59")
    #expect(snap.day.requests == 1)
    #expect(snap.day.start == date("2026-09-29 00:00"))
}

@Test func usageBeforeResetIsNotCountedInNewPeriod() {
    let cal = shanghai
    let now = date("2026-09-29 10:37")
    let reset = date("2026-09-28 22:00").timeIntervalSince1970
    // 重置前一小时属于上一周期；按零点切分会把它算进本期，额度偏多
    let records = [record(reset - 3600), record(reset + 60)]
    let snap = UsageCalculator.snapshot(
        of: IndexSnapshot(records: records, models: ["claude-opus-5-5"]),
        settings: UsageSettings(billingAnchorDay: 28, billingAnchorHour: 22, calendar: cal), now: now
    )
    #expect(snap.billing.requests == 1)
    #expect(abs(snap.billing.cost - 20) < 1e-9)
    #expect(snap.billing.start == date("2026-09-28 22:00"))
    #expect(snap.billing.end == date("2026-10-28 22:00"))
    #expect(snap.billing.dayIndex == 1)
}

private func record(_ t: Double, output: UInt32 = 1_000_000) -> UsageRecord {
    UsageRecord(key: UInt64(t), time: t, input: 0, output: output, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0,
                session: 0, model: 0, webSearches: 0, flags: 0)
}

@Test func fiveHourCostCoversTheOfficialWindowOnly() {
    let now = date("2026-10-04 10:00")
    let reset = date("2026-10-04 13:20")
    let t = now.timeIntervalSince1970
    // 窗口是重置前的 5 小时（08:20 起）：08:10 那条属于上一个窗口
    let records = [record(date("2026-10-04 08:10").timeIntervalSince1970), record(date("2026-10-04 08:20").timeIntervalSince1970), record(t - 60)]
    let index = IndexSnapshot(records: records, models: ["claude-opus-5-5"])
    let snap = UsageCalculator.snapshot(of: index, settings: UsageSettings(fiveHourReset: reset, calendar: shanghai), now: now)
    #expect(abs((snap.fiveHourCost ?? 0) - 40) < 1e-9)
    // 没有进行中的 5 小时窗口
    #expect(UsageCalculator.snapshot(of: index, settings: UsageSettings(calendar: shanghai), now: now).fiveHourCost == nil)
}

@Test func weeklyAllowanceUsesTheCostAtTheSync() throws {
    let now = date("2026-10-20 17:31")
    let sync = date("2026-10-20 17:00")
    // 每条 $20：上一周 1 条，本周同步之前 3 条，同步之后 1 条
    let times = ["2026-10-17 21:00", "2026-10-18 10:00", "2026-10-19 10:00", "2026-10-20 16:00"].map { date($0).timeIntervalSince1970 }
    let index = IndexSnapshot(records: (times + [now.timeIntervalSince1970 - 60]).map { record($0) }, models: ["claude-opus-5-5"])
    func allowance(_ reading: WeeklyReading?, earlier: AllowanceBasis? = nil) -> WeeklyAllowance? {
        let settings = UsageSettings(weeklyReset: date("2026-10-24 22:00"), weeklyReading: reading, earlierAllowance: earlier, calendar: shanghai)
        return UsageCalculator.snapshot(of: index, settings: settings, now: now).weeklyAllowance
    }
    let a = try #require(allowance(WeeklyReading(utilization: 40, at: sync)))
    #expect(a.start == date("2026-10-17 22:00"))
    #expect(abs(a.syncedCost - 60) < 1e-9)
    #expect(abs(a.spent - 80) < 1e-9)
    #expect(a.syncedAt == sync)
    #expect(!a.borrowed)
    // 60 对应 40%：花到 150 用满，还能花 70
    #expect(abs(a.full - 150) < 1e-9)
    #expect(abs(a.remaining - 70) < 1e-9)

    // 百分比太小：先用本周的；有之前算准的比例时借用它
    let small = try #require(allowance(WeeklyReading(utilization: 9, at: sync)))
    #expect(!small.borrowed)
    #expect(small.utilization == 9)
    // 之前那周一整份约 $651，和本周 9%（$600～$667）对得上
    let earlier = AllowanceBasis(utilization: 63, syncedCost: 410, at: date("2026-10-15 12:00"))
    let borrowed = try #require(allowance(WeeklyReading(utilization: 9, at: sync), earlier: earlier))
    #expect(borrowed.borrowed)
    #expect(borrowed.syncedAt == earlier.at)
    #expect(abs(borrowed.full - earlier.full) < 1e-9)
    #expect(abs(borrowed.spent - 80) < 1e-9)
    // 本周的百分比够大时不借用
    #expect(allowance(WeeklyReading(utilization: 40, at: sync), earlier: earlier)?.borrowed == false)
    // 上一周的读数、没有读数：只能借用
    #expect(allowance(WeeklyReading(utilization: 90, at: date("2026-10-17 21:30"))) == nil)
    #expect(allowance(nil) == nil)
    #expect(allowance(nil, earlier: earlier)?.borrowed == true)
}

// MARK: - 官方中途重置每周限额

/// 每条 $20。本周（10-17 22:00 起）重置前 4 条，12:00 时官方 80%（一整份额度 = $100）；
/// 13:00 前后官方重置，之后 13:30、14:00 各一条，14:30 时官方 40%；第二天 10:00、16:00 各一条
private let resetWeekEnd = date("2026-10-24 22:00")
private let highReading = WeeklyReading(utilization: 80, at: date("2026-10-20 12:00"))
private let lowReading = WeeklyReading(utilization: 40, at: date("2026-10-20 14:30"))
private let resetIndex = IndexSnapshot(
    records: ["2026-10-18 10:00", "2026-10-19 10:00", "2026-10-20 10:00", "2026-10-20 11:00",
              "2026-10-20 13:30", "2026-10-20 14:00", "2026-10-21 10:00", "2026-10-21 16:00"]
        .map { record(date($0).timeIntervalSince1970) },
    models: ["claude-opus-5-5"]
)

private func resetSnapshot(_ reading: WeeklyReading?, earlier: AllowanceBasis? = nil, reset: MidweekReset? = nil,
                           now: Date = date("2026-10-21 17:00")) -> UsageSnapshot {
    let settings = UsageSettings(weeklyReset: resetWeekEnd, weeklyReading: reading, earlierAllowance: earlier,
                                 midweekReset: reset, calendar: shanghai)
    return UsageCalculator.snapshot(of: resetIndex, settings: settings, now: now)
}

@Test func midweekResetIsADropWithinTheSameWeek() throws {
    let reset = try #require(MidweekReset.between(highReading, weekEnd: resetWeekEnd, and: lowReading, weekEnd: resetWeekEnd))
    #expect(reset.before == highReading)
    #expect(reset.after == lowReading)
    // 每周重置时间只差零点几秒（官方返回的时间带小数）也是同一周
    let jittered = resetWeekEnd.addingTimeInterval(0.7)
    #expect(MidweekReset.between(highReading, weekEnd: resetWeekEnd, and: lowReading, weekEnd: jittered) != nil)
    // 新的一周从 0% 开始，不算中途重置
    let nextWeek = resetWeekEnd.addingTimeInterval(7 * 86_400)
    #expect(MidweekReset.between(highReading, weekEnd: resetWeekEnd, and: lowReading, weekEnd: nextWeek) == nil)
    // 只低了几个百分点（官方修正、取整）不算；先后颠倒也不算
    let slightly = WeeklyReading(utilization: 76, at: lowReading.at)
    #expect(MidweekReset.between(highReading, weekEnd: resetWeekEnd, and: slightly, weekEnd: resetWeekEnd) == nil)
    #expect(MidweekReset.between(lowReading, weekEnd: resetWeekEnd, and: highReading, weekEnd: resetWeekEnd) == nil)
    // 存进偏好再读回来
    let data = try JSONEncoder().encode(reset)
    #expect(try JSONDecoder().decode(MidweekReset.self, from: data) == reset)
}

@Test func midweekResetCountsOnlyTheCostAfterIt() throws {
    let reset = MidweekReset(before: highReading, after: lowReading, weekEnd: resetWeekEnd)
    let snap = resetSnapshot(WeeklyReading(utilization: 60, at: date("2026-10-21 12:00")), reset: reset)
    let a = try #require(snap.weeklyAllowance)
    // 重置后 40% 按重置前的比例是 $40：从 14:30 往前数够 $40 的是 13:30 那条
    #expect(a.restartedAt == date("2026-10-20 13:30"))
    #expect(a.reset == reset)
    #expect(abs(a.forgiven - 80) < 1e-9)
    // 重置后到第二天 12:00 花了 $60，对应 60%：一整份还是 $100
    #expect(abs(a.syncedCost - 60) < 1e-9)
    #expect(abs(a.full - 100) < 1e-9)
    // 重置后一共花了 $80，还剩 $20；本周用满时一共 $80 + $100
    #expect(abs(a.spent - 80) < 1e-9)
    #expect(abs(a.remaining - 20) < 1e-9)
    #expect(abs(a.fullWeek - 180) < 1e-9)
    let week = try #require(snap.week)
    #expect(abs(week.cost - 160) < 1e-9)
    #expect(week.projection(now: date("2026-10-21 17:00"), allowance: a) == Projection(cost: 180))

    // 不知道重置过时，整周的 $140 对应 60%，一整份被算成 $233
    let naive = try #require(resetSnapshot(WeeklyReading(utilization: 60, at: date("2026-10-21 12:00"))).weeklyAllowance)
    #expect(naive.full > 230)
}

@Test func midweekResetFromTheBorrowedBasisOfTheSameWeek() throws {
    // 升级前就重置了：没记下重置，但借用的比例是本周 12:00 的 80%，比现在的 40% 高出一截
    let earlier = AllowanceBasis(utilization: 80, syncedCost: 80, at: highReading.at)
    let snap = resetSnapshot(lowReading, earlier: earlier)
    let a = try #require(snap.weeklyAllowance)
    #expect(a.reset == MidweekReset(before: highReading, after: lowReading, weekEnd: resetWeekEnd))
    #expect(a.restartedAt == date("2026-10-20 13:30"))
    #expect(!a.borrowed)
    #expect(abs(a.full - 100) < 1e-9)
    // 本周一共 $160，重置前的 $80 不算
    #expect(abs(a.spent - 80) < 1e-9)

    // 借用的比例来自上一周：不是中途重置
    let small = WeeklyReading(utilization: 5, at: lowReading.at)
    let lastWeek = AllowanceBasis(utilization: 80, syncedCost: 80, at: date("2026-10-16 12:00"))
    let plain = try #require(resetSnapshot(small, earlier: lastWeek).weeklyAllowance)
    #expect(plain.reset == nil)
    #expect(plain.forgiven == 0)
}

@Test func midweekResetWhileBorrowingKeepsOnlyTheLaterCost() throws {
    // 记下的重置：重置后 5%，按重置前的比例是 $5，往前数到 14:00 那条
    let reset = MidweekReset(before: highReading, after: WeeklyReading(utilization: 5, at: lowReading.at), weekEnd: resetWeekEnd)
    // 重置后百分比还小：借用之前那周对得上的比例（一整份 $360），只有重置后的消耗占额度
    let lastWeek = AllowanceBasis(utilization: 50, syncedCost: 180, at: date("2026-10-16 12:00"))
    let a = try #require(resetSnapshot(reset.after, earlier: lastWeek, reset: reset).weeklyAllowance)
    #expect(a.borrowed)
    #expect(a.restartedAt == date("2026-10-20 14:00"))
    #expect(abs(a.full - 360) < 1e-9)
    #expect(abs(a.forgiven - 100) < 1e-9)
    #expect(abs(a.spent - 60) < 1e-9)
    #expect(abs(a.fullWeek - 460) < 1e-9)
}

@Test func aBorrowedRatioThatContradictsThisWeekIsDropped() throws {
    // 本周 2%、花了 $40：一整份在 $1,333～$2,000 之间
    let index = IndexSnapshot(records: [record(date("2026-10-18 10:00").timeIntervalSince1970), record(date("2026-10-18 11:00").timeIntervalSince1970)],
                              models: ["claude-opus-5-5"])
    func allowance(earlier: AllowanceBasis) -> WeeklyAllowance? {
        let settings = UsageSettings(weeklyReset: resetWeekEnd, weeklyReading: WeeklyReading(utilization: 2, at: date("2026-10-18 12:00")),
                                     earlierAllowance: earlier, calendar: shanghai)
        return UsageCalculator.snapshot(of: index, settings: settings, now: date("2026-10-18 13:00")).weeklyAllowance
    }
    // 上周按没认出的中途重置、拿整周消耗算的比例：10% 对应 $3,500，一整份 $35,000，差了十几倍，不借用
    let inflated = try #require(allowance(earlier: AllowanceBasis(utilization: 10, syncedCost: 3500, at: date("2026-10-16 12:00"))))
    #expect(!inflated.borrowed)
    #expect(inflated.utilization == 2)
    #expect(abs(inflated.full - 2000) < 1e-9)
    // 对得上的照常借用：一整份 $1,800
    let fine = try #require(allowance(earlier: AllowanceBasis(utilization: 50, syncedCost: 900, at: date("2026-10-16 12:00"))))
    #expect(fine.borrowed)
    #expect(abs(fine.full - 1800) < 1e-9)
}

@Test func restartTimeStaysBetweenTheTwoReadings() throws {
    let week = try #require(resetSnapshot(nil).week)
    let records = resetIndex.records
    let costs = records.map { _ in 20.0 }
    func restart(after: WeeklyReading, before: WeeklyReading = highReading) -> Date {
        UsageCalculator.restartTime(MidweekReset(before: before, after: after, weekEnd: resetWeekEnd), records: records, costs: costs, week: week)
    }
    // 重置后还是 0%：取重置后那次读数
    #expect(restart(after: WeeklyReading(utilization: 0, at: lowReading.at)) == lowReading.at)
    // 重置后的百分比比两次读数之间的消耗还多：不早于重置前那次读数
    #expect(restart(after: WeeklyReading(utilization: 75, at: lowReading.at)) == highReading.at)
    // 重置前本周还没有消耗，比例算不出来
    let early = WeeklyReading(utilization: 80, at: date("2026-10-18 09:00"))
    #expect(restart(after: lowReading, before: early) == lowReading.at)
    // 不是这一周的重置不用
    let other = MidweekReset(before: highReading, after: lowReading, weekEnd: resetWeekEnd.addingTimeInterval(-7 * 86_400))
    let a = try #require(resetSnapshot(WeeklyReading(utilization: 60, at: date("2026-10-21 12:00")), reset: other).weeklyAllowance)
    #expect(a.reset == nil)
    #expect(a.restartedAt == nil)
}

// MARK: - 本机在一周中途换过账号

private let switchedAway = date("2026-10-20 13:00")
private let switchedBack = date("2026-10-21 12:00")

private func switchedSnapshot(_ reading: WeeklyReading?, away: [DateInterval], earlier: AllowanceBasis? = nil) -> UsageSnapshot {
    let settings = UsageSettings(weeklyReset: resetWeekEnd, weeklyReading: reading, earlierAllowance: earlier,
                                 otherAccounts: away, calendar: shanghai)
    return UsageCalculator.snapshot(of: resetIndex, settings: settings, now: date("2026-10-21 17:00"))
}

@Test func accountSpansFollowSwitchesBackAndForth() throws {
    let a = "00000000-0000-4000-8000-00000000000a"
    let b = "00000000-0000-4000-8000-00000000000b"
    // 第一次换：补上之前一直是 a
    var spans = AccountSpan.switching([], from: a, to: b, at: switchedAway)
    let first: [AccountSpan] = [AccountSpan(account: a, since: Date.distantPast), AccountSpan(account: b, since: switchedAway)]
    #expect(spans == first)
    let before: [DateInterval] = [DateInterval(start: Date.distantPast, end: switchedAway)]
    #expect(AccountSpan.away(from: b, in: spans) == before)
    // 换回来：a 只有中间那段不在
    spans = AccountSpan.switching(spans, from: b, to: a, at: switchedBack)
    let between: [DateInterval] = [DateInterval(start: switchedAway, end: switchedBack)]
    #expect(AccountSpan.away(from: a, in: spans) == between)
    let bAway: [DateInterval] = [before[0], DateInterval(start: switchedBack, end: Date.distantFuture)]
    #expect(AccountSpan.away(from: b, in: spans) == bAway)
    // 只留最近 8 天：更早的只留延续进来的那一段
    let later = switchedBack.addingTimeInterval(10 * 86_400)
    spans = AccountSpan.switching(spans, from: a, to: b, at: later)
    let trimmed: [AccountSpan] = [AccountSpan(account: a, since: switchedBack), AccountSpan(account: b, since: later)]
    #expect(spans == trimmed)
    // 从来没换过账号
    #expect(AccountSpan.away(from: a, in: []).isEmpty)
    // 存进偏好再读回来
    let data = try JSONEncoder().encode(spans)
    let decoded = try JSONDecoder().decode([AccountSpan].self, from: data)
    #expect(decoded == spans)
}

@Test func spendingOnAnotherAccountDoesNotCountTowardThisOne() throws {
    // 13:00 起换成了这个账号：本周之前的 4 条（$80）是上一个账号花的。换过来后 13:30、14:00 两条，14:30 时这个账号 40%
    let a = try #require(switchedSnapshot(lowReading, away: [DateInterval(start: .distantPast, end: switchedAway)]).weeklyAllowance)
    #expect(abs(a.elsewhere - 80) < 1e-9)
    #expect(a.forgiven == 0)
    // 换过来后到 14:30 花了 $40，对应 40%：一整份 $100
    #expect(abs(a.syncedCost - 40) < 1e-9)
    #expect(abs(a.full - 100) < 1e-9)
    // 这个账号一共花了 $80（含第二天两条），还剩 $20；本周用满时本机一共 $80 + $100
    #expect(abs(a.spent - 80) < 1e-9)
    #expect(abs(a.remaining - 20) < 1e-9)
    #expect(abs(a.fullWeek - 180) < 1e-9)
    #expect(abs(a.setAside - 80) < 1e-9)
    // 不知道换过账号时，上一个账号的 $80 也算进去：40% 对应 $120，一整份被算成 $300
    let naive = try #require(switchedSnapshot(lowReading, away: []).weeklyAllowance)
    #expect(abs(naive.full - 300) < 1e-9)
}

@Test func switchingBackKeepsTheAccountsOwnEarlierSpending() throws {
    // 本周先用这个账号花了 4 条（$80），13:00 换走、第二天 12:00 换回来：中间 3 条（$60）是别的账号的。
    // 换回来后 16:00 一条，16:30 时这个账号 50%：它自己花了 $100，一整份 $200
    let away = [DateInterval(start: switchedAway, end: switchedBack)]
    let reading = WeeklyReading(utilization: 50, at: date("2026-10-21 16:30"))
    let a = try #require(switchedSnapshot(reading, away: away).weeklyAllowance)
    #expect(abs(a.elsewhere - 60) < 1e-9)
    #expect(abs(a.syncedCost - 100) < 1e-9)
    #expect(abs(a.full - 200) < 1e-9)
    #expect(abs(a.spent - 100) < 1e-9)
    // 本周本机一共 $160：预计 $260 = 别的账号的 $60 + 这个账号用满的 $200，还剩 $100
    let week = try #require(switchedSnapshot(reading, away: away).week)
    #expect(abs(week.cost - 160) < 1e-9)
    #expect(week.projection(now: date("2026-10-21 17:00"), allowance: a) == Projection(cost: 260))
    #expect(abs(a.remaining - 100) < 1e-9)
}

@Test func snapshotCoversBillingPeriodAndDays() {
    let now = date("2026-09-28 12:00")
    let t = now.timeIntervalSince1970
    // 每条记录 = 1M output × $20
    let records = [record(t - 40 * 86_400), record(t - 2 * 86_400), record(t - 3600), record(t - 60)]
    let snap = UsageCalculator.snapshot(
        of: IndexSnapshot(records: records, models: ["claude-opus-5-5"]),
        settings: UsageSettings(billingAnchorDay: 1, calendar: shanghai), now: now
    )
    #expect(snap.totalRecords == 4)
    #expect(abs(snap.lifetimeCost - 80) < 1e-9)
    #expect(snap.billing.requests == 3)
    #expect(abs(snap.billing.cost - 60) < 1e-9)
    #expect(snap.billing.dayIndex == 28)
    // 9 月 1 日零点到 28 日中午过去 27.5 天
    #expect(abs(snap.billing.dailyAverage(now: now) - 60.0 / 27.5) < 1e-9)
    #expect(abs((snap.today?.cost ?? 0) - 40) < 1e-9)
    #expect(snap.daily.count == 30)
}

@Test func haikuCategoriesAddUpToTheTotalAcrossTiers() {
    let now = date("2026-10-08 12:00")
    let t = now.timeIntervalSince1970
    // 第一条提示词正好 10 万：第一档；第二条算上缓存读取是 100,001：整条按第二档
    let short = UsageRecord(key: 1, time: t - 120, input: 100_000, output: 1_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0,
                            session: 0, model: 0, webSearches: 0, flags: 0)
    let long = UsageRecord(key: 2, time: t - 60, input: 1, output: 1_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 100_000,
                           session: 0, model: 0, webSearches: 0, flags: 0)
    let snap = UsageCalculator.snapshot(
        of: IndexSnapshot(records: [short, long], models: ["claude-haiku-5-5"]),
        settings: UsageSettings(billingAnchorDay: 1, calendar: shanghai), now: now
    )
    // 0.0105 + (0.0000005 + 0.0025 + 0.005)
    #expect(abs(snap.billing.cost - 0.0180005) < 1e-12)
    let c = snap.billing.categories
    #expect(abs(c.input + c.output + c.cacheWrite + c.cacheRead - snap.billing.cost) < 1e-12)
    #expect(abs(c.input - 0.0100005) < 1e-12)
    #expect(abs(c.cacheRead - 0.005) < 1e-12)
    // 缓存读取省下的钱：100,000 × (0.5 - 0.05) / 1e6
    #expect(abs(c.savings - 0.045) < 1e-12)
}

// MARK: - 格式化

@Test func chineseNumberFormatting() {
    #expect(Fmt.chinese(26_000) == "2.6 万")
    #expect(Fmt.chinese(14_114_000) == "1411.4 万")
    #expect(Fmt.chinese(5_157_000_000) == "51.57 亿")
    #expect(Fmt.chinese(9_999) == "9,999")
    #expect(Fmt.compact(227_600) == "227.6k")
    #expect(Fmt.compact(1_000_000) == "1M")
    #expect(Fmt.grouped(5_245_583_915) == "5,245,583,915")
    #expect(MoneyFormat().string(1680.44) == "$1,680.44")
    #expect(MoneyFormat(unit: .cny, rate: 7).string(10) == "¥70.00")
    #expect(MoneyFormat(unit: .jpy, rate: 150).string(10) == "JP¥1,500")
    #expect(MoneyFormat(unit: .eur, rate: 0.9).string(10) == "€9.00")
}

// MARK: - 官方用量

@Test func decodesOfficialUsageResponse() throws {
    let json = """
    {"five_hour":{"utilization":71.0,"resets_at":"2026-09-28T17:00:00.482019+00:00"},
     "seven_day":{"utilization":65,"resets_at":"2026-10-03T14:00:00Z"},
     "seven_day_oauth_apps":null,"seven_day_opus":{"utilization":null,"resets_at":null},
     "seven_day_sonnet":{"utilization":2.0,"resets_at":"2026-10-03T14:00:00Z"},
     "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null},
     "limits":[{"kind":"weekly_scoped","group":"weekly","percent":0,"resets_at":1790949600,"scope":{"model":{"display_name":"Fable"}}},
               {"kind":"session","group":"session","percent":71,"resets_at":null,"scope":{}}],
     "unknown_future_field":{"x":1}}
    """
    let usage = try OfficialUsage.decode(Data(json.utf8))
    let five = try #require(usage.fiveHour)
    #expect(five.utilization == 71)
    #expect(abs(five.fraction - 0.71) < 1e-9)
    #expect(abs(five.resetsAt!.timeIntervalSince1970 - 1_790_614_800.482019) < 0.01)
    #expect(usage.sevenDay?.utilization == 65)
    #expect(usage.sevenDayOpus == nil)  // utilization 为 null 视为没有该项
    #expect(usage.sevenDaySonnet?.utilization == 2)
    #expect(usage.scoped.count == 1)
    #expect(usage.scoped.first?.modelName == "Fable")
    #expect(usage.scoped.first?.limit.resetsAt == Date(timeIntervalSince1970: 1_790_949_600))
    #expect(usage.extraUsageEnabled == false)
    // 14:00 UTC = 上海 22:00，与面板「周六 22:00」一致；不用 5 小时窗口的时刻
    let clock = try #require(usage.weeklyResetClock(calendar: shanghai))
    #expect(clock.hour == 22 && clock.minute == 0)
}

@Test func decodesWhetherExtraUsageCoversTheLimit() throws {
    let on = try OfficialUsage.decode(Data(#"{"seven_day":{"utilization":63},"extra_usage":{"is_enabled":true,"monthly_limit":5000}}"#.utf8))
    #expect(on.extraUsageEnabled == true)
    // 没有这一项、为 null、格式变了：都当作不知道，限额本身照常解析
    let bodies = [
        #"{"seven_day":{"utilization":63}}"#,
        #"{"seven_day":{"utilization":63},"extra_usage":null}"#,
        #"{"seven_day":{"utilization":63},"extra_usage":"on"}"#,
        #"{"seven_day":{"utilization":63},"extra_usage":{"is_enabled":"yes"}}"#,
    ]
    for body in bodies {
        let usage = try OfficialUsage.decode(Data(body.utf8))
        #expect(usage.extraUsageEnabled == nil)
        #expect(usage.sevenDay?.utilization == 63)
    }
}

@Test func weeklyResetClockIgnoresFiveHourAndRoundsSubseconds() throws {
    let fiveOnly = try OfficialUsage.decode(Data(#"{"five_hour":{"utilization":19,"resets_at":"2026-09-29T02:48:07Z"}}"#.utf8))
    #expect(fiveOnly.weeklyResetClock(calendar: shanghai) == nil)

    // 13:59:59.6Z 就近到 14:00Z，上海时间 22:00
    let almost = try OfficialUsage.decode(Data(#"{"seven_day":{"utilization":1,"resets_at":"2026-10-03T13:59:59.6Z"}}"#.utf8))
    let clock = try #require(almost.weeklyResetClock(calendar: shanghai))
    #expect(clock.hour == 22 && clock.minute == 0)

    let scoped = OfficialUsage(scoped: [ScopedLimit(modelName: "Fable", limit: OfficialLimit(utilization: 0, resetsAt: date("2026-10-03 22:15")))])
    let scopedClock = try #require(scoped.weeklyResetClock(calendar: shanghai))
    #expect(scopedClock.hour == 22 && scopedClock.minute == 15)
}

@Test func nextResetIsTheEarliestUpcomingWindow() throws {
    let now = date("2026-10-04 08:30")
    let usage = OfficialUsage(
        fiveHour: OfficialLimit(utilization: 12, resetsAt: date("2026-10-04 13:20").addingTimeInterval(-0.093)),
        sevenDay: OfficialLimit(utilization: 40, resetsAt: date("2026-10-10 22:00").addingTimeInterval(-0.092)),
        scoped: [ScopedLimit(modelName: "Fable", limit: OfficialLimit(utilization: 7, resetsAt: date("2026-10-10 22:00")))]
    )
    #expect(usage.nextReset(after: now) == date("2026-10-04 13:20").addingTimeInterval(-0.093))

    // 5 小时已经过了：下一个是每周。本周与 Fable 只差 0.092 秒，算同一时刻，取较晚的，到点时两项都已重置
    let weekly = try #require(usage.nextReset(after: date("2026-10-04 13:20")))
    #expect(weekly == date("2026-10-10 22:00"))
    #expect(usage.sevenDay!.resetsAt! < weekly && usage.scoped[0].limit.resetsAt! <= weekly)

    // 全都过了，或者没有重置时间（5 小时空闲时官方不给）：没有下一个
    #expect(usage.nextReset(after: date("2026-10-10 22:00")) == nil)
    #expect(OfficialUsage(fiveHour: OfficialLimit(utilization: 0, resetsAt: nil)).nextReset(after: now) == nil)
}

@Test func comparesVersionsAndReadsGitHubRelease() throws {
    let older = try #require(AppVersion("1.1.0"))
    let newer = try #require(AppVersion("v1.2.0"))
    #expect(older < newer)
    #expect(!(AppVersion("1.2")! < AppVersion("1.2.0")!))
    #expect(!(AppVersion("1.2.0")! < AppVersion("1.2")!))
    #expect(AppVersion("nope") == nil)

    let json = Data(#"""
    {"tag_name":"v1.2.0","assets":[
      {"name":"ClaudeUsageMonitor-1.2.0-macOS.zip","browser_download_url":"https://example.com/app.zip"},
      {"name":"ClaudeUsageMonitor-1.2.0-macOS.zip.sha256","browser_download_url":"https://example.com/app.zip.sha256"}
    ]}
    """#.utf8)
    let release = try AppRelease.decodeGitHub(json)
    #expect(release.version == newer)
    #expect(release.zipURL.absoluteString == "https://example.com/app.zip")
    #expect(release.checksumURL?.absoluteString == "https://example.com/app.zip.sha256")
}

@Test func pausesUsageInMainlandHongKongAndMacau() throws {
    for code in ["CN", "cn", "HK", "MO"] {
        #expect(PublicNetwork.restrictsUsage(countryCode: code))
    }
    #expect(!PublicNetwork.restrictsUsage(countryCode: "US"))
    #expect(!PublicNetwork.restrictsUsage(countryCode: "JP"))
    let united = try PublicNetwork.decode(Data(#"{"ip":"8.8.8.8","country_code":"US","region":"California","city":"Mountain View"}"#.utf8))
    #expect(united.isUnitedStates)
    #expect(!united.restrictsUsage)
    #expect(united.flag == "🇺🇸")
    let macau = try PublicNetwork.decode(Data(#"{"success":true,"ip":"1.2.3.4","country_code":"MO","region":"","city":"Macau"}"#.utf8))
    #expect(macau.restrictsUsage)
    #expect(macau.city == "Macau")
    #expect(macau.region == nil)
    let trace = PublicNetwork.decodeTrace("fl=1\nh=api.anthropic.com\nip=168.143.189.31\nloc=US\ncolo=LAX\n")
    #expect(trace?.ip == "168.143.189.31")
    #expect(trace?.countryCode == "US")
    #expect(trace?.region == "LAX")
    #expect(trace?.restrictsUsage == false)
    #expect(PublicNetwork.decodeTrace("ip=1.1.1.1\nloc=CN\n")?.restrictsUsage == true)
    let v6 = PublicNetwork.decodeTrace("ip=240e:1:1::1\nloc=HK\n")
    #expect(v6?.isIPv6 == true)
    #expect(v6?.restrictsUsage == true)
    let tun = "State:/Network/Interface/utun9/IPv4"
    #expect(ExitSignals.interfaceName(inDynamicStoreKey: tun) == "utun9")
    #expect(ExitSignals.interfaceName(inDynamicStoreKey: "State:/Network/Global/Proxies") == nil)
    let withTun = ExitSignals.interfaceNames(in: ["State:/Network/Interface/en0/IPv4", tun])
    #expect(!ExitSignals.interfacesChanged(from: nil, to: withTun))
    #expect(ExitSignals.interfacesChanged(from: Set(["en0"]), to: withTun))
    #expect(!ExitSignals.interfacesChanged(from: withTun, to: Set(["en0", "utun9"])))
    let unitedExit = ExitSignals.HeldExit(place: trace, failed: false)
    #expect(ExitSignals.apply(current: unitedExit, found: nil, replacing: false) == unitedExit)
    #expect(ExitSignals.apply(current: unitedExit, found: nil, replacing: true) == ExitSignals.HeldExit(place: nil, failed: true))
    #expect(ExitSignals.apply(current: unitedExit, found: v6, replacing: true).place == v6)
    #expect(UsageTone.tone(for: 0.1) == .calm)
    #expect(UsageTone.tone(for: 0.4) == .steady)
    #expect(UsageTone.tone(for: 0.6) == .warm)
    #expect(UsageTone.tone(for: 0.8) == .high)
    #expect(UsageTone.tone(for: 0.97) == .critical)
}

@Test func parsesOutboundProxy() {
    #expect(OutboundProxy.parse("  ") == nil)
    #expect(OutboundProxy.parse("127.0.0.1:7890") == OutboundProxy(host: "127.0.0.1", port: 7890, socks: false))
    #expect(OutboundProxy.parse("http://127.0.0.1:7890/path") == OutboundProxy(host: "127.0.0.1", port: 7890, socks: false))
    #expect(OutboundProxy.parse("socks5://127.0.0.1:7891") == OutboundProxy(host: "127.0.0.1", port: 7891, socks: true))
    #expect(OutboundProxy.parse("not a proxy") == nil)
    #expect(OutboundProxy.parse("127.0.0.1:99999") == nil)
}

@Test func decodesFrankfurterUSDRates() throws {
    let json = Data(#"{"amount":1.0,"base":"USD","date":"2026-09-26","rates":{"CNY":7.12,"EUR":0.92,"JPY":149.2,"GBP":0.78}}"#.utf8)
    let rates = try FXRates.perUSD(fromFrankfurter: json)
    #expect(rates["USD"] == 1)
    #expect(rates["CNY"] == 7.12)
    #expect(rates["JPY"] == 149.2)
    #expect(MoneyFormat(unit: .cny, rate: rates["CNY"]!).convert(2) == 14.24)
}

@Test func officialPercentRoundsDownLikeClaudeCode() {
    // Claude Code /usage 显示 Math.floor(utilization)
    #expect(OfficialLimit(utilization: 71.9, resetsAt: nil).percent == 71)
    #expect(OfficialLimit(utilization: 12, resetsAt: nil).percent == 12)
    #expect(OfficialLimit(utilization: 0.4, resetsAt: nil).percent == 0)
    #expect(OfficialLimit(utilization: 104.2, resetsAt: nil).percent == 104)
    #expect(OfficialLimit(utilization: .nan, resetsAt: nil).percent == 0)
    #expect(abs(OfficialLimit(utilization: 79.99, resetsAt: nil).fraction - 0.79) < 1e-9)
}
