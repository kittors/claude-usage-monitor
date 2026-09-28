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
}

@Test func weeklyIntervalFindsLastReset() {
    let settings = UsageSettings(weeklyResetWeekday: 7, weeklyResetHour: 22, calendar: shanghai)
    // 2026-09-28 是周一
    var i = UsageCalculator.weeklyInterval(now: date("2026-09-28 22:45"), settings: settings)
    #expect(i.start == date("2026-09-26 22:00") && i.end == date("2026-10-03 22:00"))
    // 恰好在重置时刻
    i = UsageCalculator.weeklyInterval(now: date("2026-10-03 22:00"), settings: settings)
    #expect(i.start == date("2026-10-03 22:00"))
}

private func record(_ t: Double, output: UInt32 = 1_000_000) -> UsageRecord {
    UsageRecord(key: UInt64(t), time: t, input: 0, output: output, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0,
                session: 0, model: 0, webSearches: 0, flags: 0)
}

@Test func fiveHourBlocksFollowSessionRules() {
    let h = 3600.0
    let base = 1_790_000_000.0 - 1_790_000_000.0.truncatingRemainder(dividingBy: h)  // 整点
    let records = [record(base + 0.5 * h), record(base + 2 * h), record(base + 5.2 * h), record(base + 6 * h)]
    // 第一个窗口 [0.5h, 5.5h)，5.2h 仍在其中；6h 开启第二个窗口（精确时刻，不取整）
    let block = UsageCalculator.activeBlock(records: records, now: base + 6.5 * h)
    #expect(block?.start == base + 6 * h)
    #expect(block?.firstIndex == 3)
    // 第二个窗口结束后没有新请求：无活动窗口
    #expect(UsageCalculator.activeBlock(records: records, now: base + 11.1 * h) == nil)

    let snapshot = IndexSnapshot(records: records, models: ["claude-opus-5-5"])
    let settings = UsageSettings(fiveHourBudget: 100, weeklyBudget: 1000, calendar: shanghai)
    let snap = UsageCalculator.snapshot(of: snapshot, settings: settings, now: Date(timeIntervalSince1970: base + 6.5 * h))
    // 每条记录 = 1M output × $20，当前窗口只有 6h 那一条
    #expect(abs(snap.fiveHour.cost - 20) < 1e-9)
    #expect(abs(snap.fiveHour.fraction - 0.2) < 1e-9)
    #expect(snap.fiveHour.end == Date(timeIntervalSince1970: base + 11 * h))
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
}

@Test func officialWindowsOverrideLocalWindows() {
    let h = 3600.0
    let base = 1_790_000_000.0
    let records = [record(base), record(base + 2 * h), record(base + 3 * h)]
    let snapshot = IndexSnapshot(records: records, models: ["claude-opus-5-5"])
    // 官方窗口在 base+1.5h 开始（例如这段时间里还有其他设备的用量），应只统计之后的两条
    let official = DateInterval(start: Date(timeIntervalSince1970: base + 1.5 * h), end: Date(timeIntervalSince1970: base + 6.5 * h))
    let settings = UsageSettings(fiveHourBudget: 100, weeklyBudget: 1000, calendar: shanghai, fiveHourWindow: official)
    let snap = UsageCalculator.snapshot(of: snapshot, settings: settings, now: Date(timeIntervalSince1970: base + 3.5 * h))
    #expect(abs(snap.fiveHour.cost - 40) < 1e-9)
    #expect(snap.fiveHour.requests == 2)
    #expect(snap.fiveHour.end == official.end)
    #expect(snap.fiveHour.isActive)

    // 最近一次官方同步之后的本机费用（按记录时间统计，用于两次同步之间的推算）
    var synced = settings
    synced.officialSyncedAt = Date(timeIntervalSince1970: base + 2.5 * h)
    let later = UsageCalculator.snapshot(of: snapshot, settings: synced, now: Date(timeIntervalSince1970: base + 3.5 * h))
    #expect(abs(later.costSinceSync - 20) < 1e-9)
    #expect(snap.costSinceSync == 0)
}

// MARK: - 周额度中途重置

/// 每 6 分钟一条、每条 $5（1M output 单价 $20 × 0.25M），即每小时 $50
private func steadyRecords(from start: Double, hours: Double) -> [UsageRecord] {
    stride(from: start + 360, to: start + hours * 3600, by: 360).map { record($0, output: 250_000) }
}

/// 按官方口径生成观测：只统计 `countFrom` 之后的用量，百分比取整，只在变化时记录
private func officialObservations(records: [UsageRecord], countFrom: Double, budget: Double, after: Double) -> [WindowObservation] {
    var result: [WindowObservation] = []
    var acc = 0.0
    for r in records {
        if r.time >= countFrom { acc += 5 }
        guard r.time > after else { continue }
        let u = (100 * acc / budget).rounded(.down)
        if result.last?.utilization != u { result.append(WindowObservation(time: r.time + 30, utilization: u)) }
    }
    return result
}

private let cycleStart = 1_790_000_000.0

@Test func infersMidWeekResetFromOfficialPercentages() throws {
    let h = 3600.0
    let records = steadyRecords(from: cycleStart, hours: 48)
    let costs = Array(repeating: 5.0, count: records.count)
    let reset = cycleStart + 30 * h
    // 重置之后才开始观测（App 当时没在运行），官方只统计重置之后的用量
    let obs = officialObservations(records: records, countFrom: reset, budget: 1000, after: reset + 2 * h)
    #expect(obs.count >= 50)
    let result = try #require(UsageCalculator.inferResetStart(records: records, costs: costs, windowStart: cycleStart, observations: obs))
    #expect(abs(result.start - reset) < 0.3 * h)
    #expect(abs(result.budget - 1000) < 30)
}

@Test func withoutResetTheCycleStartIsKept() throws {
    let h = 3600.0
    let records = steadyRecords(from: cycleStart, hours: 40)
    let costs = Array(repeating: 5.0, count: records.count)
    let obs = officialObservations(records: records, countFrom: cycleStart, budget: 1000, after: cycleStart + 2 * h)
    let result = try #require(UsageCalculator.inferResetStart(records: records, costs: costs, windowStart: cycleStart, observations: obs))
    #expect(result.start == cycleStart)
    #expect(abs(result.budget - 1000) < 30)
}

@Test func inconsistentObservationsAreIgnored() {
    let h = 3600.0
    let records = steadyRecords(from: cycleStart, hours: 40)
    let costs = Array(repeating: 5.0, count: records.count)
    var obs = officialObservations(records: records, countFrom: cycleStart, budget: 1000, after: cycleStart + 2 * h)
    // 观测期间其他设备用掉了 10%：本机费用解释不了这部分变化，不下结论
    for i in (obs.count / 2)..<obs.count { obs[i].utilization += 10 }
    #expect(UsageCalculator.inferResetStart(records: records, costs: costs, windowStart: cycleStart, observations: obs) == nil)
    // 观测太少也不下结论
    #expect(UsageCalculator.inferResetStart(records: records, costs: costs, windowStart: cycleStart, observations: Array(obs.prefix(2))) == nil)
}

@Test func weeklyStartPrefersLatestKnownReset() {
    let h = 3600.0
    let records = steadyRecords(from: cycleStart, hours: 48)
    let reset = cycleStart + 30 * h
    let obs = officialObservations(records: records, countFrom: reset, budget: 1000, after: reset + 2 * h)
    let index = IndexSnapshot(records: records, models: ["claude-opus-5-5"])
    let now = Date(timeIntervalSince1970: cycleStart + 48 * h)
    var settings = UsageSettings(
        fiveHourBudget: 100, weeklyBudget: 5000, calendar: shanghai,
        weeklyWindow: DateInterval(start: Date(timeIntervalSince1970: cycleStart), duration: 7 * 86_400),
        weeklyObservations: obs
    )

    // 自动推算：本机费用从重置时起算，预算不受重置前用量的污染
    var snap = UsageCalculator.snapshot(of: index, settings: settings, now: now)
    #expect(snap.weeklyCycleStart == Date(timeIntervalSince1970: cycleStart))
    #expect(snap.weeklyStartSource == .inferred)
    #expect(abs(snap.weeklyStart.timeIntervalSince1970 - reset) < 0.3 * h)
    #expect(abs(snap.weekly.cost - 900) < 20)
    #expect(abs((snap.weeklyInferredBudget ?? 0) - 1000) < 30)

    // 手动指定优先于推算
    let manual = Date(timeIntervalSince1970: reset - 2 * h)
    settings.weeklyStartOverride = manual
    snap = UsageCalculator.snapshot(of: index, settings: settings, now: now)
    #expect(snap.weeklyStartSource == .manual)
    #expect(snap.weeklyStart == manual)
    #expect(abs((snap.weeklyInferredBudget ?? 0) - 1000) < 30)

    // 之后又检测到一次更晚的重置：以检测结果为准
    let floor = Date(timeIntervalSince1970: reset + h)
    settings.weeklyResetFloor = floor
    snap = UsageCalculator.snapshot(of: index, settings: settings, now: now)
    #expect(snap.weeklyStartSource == .detected)
    #expect(snap.weeklyStart == floor)

    // 上一个周期留下的手动时间不再生效
    settings.weeklyResetFloor = nil
    settings.weeklyStartOverride = Date(timeIntervalSince1970: cycleStart - h)
    snap = UsageCalculator.snapshot(of: index, settings: settings, now: now)
    #expect(snap.weeklyStartSource == .inferred)
}

@Test func observationLogConfirmsDropsBeforeTreatingThemAsResets() {
    var log = WeeklyObservationLog()
    let end = Date(timeIntervalSince1970: 2_000_000)
    func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 + minutes * 60) }

    let accepted = log.record(utilization: 10, resetsAt: end, at: at(0))
    #expect(accepted)
    log.record(utilization: 10, resetsAt: end, at: at(1))
    log.record(utilization: 11, resetsAt: end, at: at(2))
    #expect(log.observations.map(\.utilization) == [10, 11])
    #expect(log.observations.last?.time == at(2).timeIntervalSince1970)
    // 同一次请求重复传入
    let duplicate = log.record(utilization: 12, resetsAt: end, at: at(2))
    #expect(!duplicate)

    // 只出现一次的异常值不算重置
    log.record(utilization: 0, resetsAt: end, at: at(3))
    log.record(utilization: 11, resetsAt: end, at: at(4))
    #expect(log.resetFloor == nil)
    #expect(log.observations.map(\.utilization) == [10, 11])

    // 连续两次明显下降：确认中途重置，下界是最后一次看到原有水平的时间
    log.record(utilization: 11, resetsAt: end, at: at(30))
    log.record(utilization: 1, resetsAt: end, at: at(31))
    log.record(utilization: 2, resetsAt: end, at: at(32))
    #expect(log.resetFloor == at(30).timeIntervalSince1970)
    #expect(log.observations.map(\.utilization) == [1, 2])

    // 例行重置进入新周期：重新开始
    log.record(utilization: 0, resetsAt: end.addingTimeInterval(7 * 86_400), at: at(40))
    #expect(log.resetFloor == nil)
    #expect(log.observations.map(\.utilization) == [0])

    // 持久化往返
    let data = try! JSONEncoder().encode(log)
    #expect(try! JSONDecoder().decode(WeeklyObservationLog.self, from: data) == log)
}
