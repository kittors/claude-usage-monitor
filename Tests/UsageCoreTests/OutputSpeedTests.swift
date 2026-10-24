import Foundation
import Testing
@testable import UsageCore

// MARK: - 会话记录里的行

private func request(_ id: String, at time: String, model: String = "claude-opus-5-5") -> String {
    #"{"type":"api-request","sessionId":"s1","id":"\#(id)","timestamp":"\#(time)","version":"2.1.308","querySource":"sdk","params":{"model":"\#(model)","max_tokens":128000}}"#
}

/// 回复的一块。同一次回复的每一块各写一行，usage 都是最终值
private func block(_ msg: String, ref: String?, at time: String, output: Int, model: String = "claude-opus-5-5",
                   kind: String = "thinking", sidechain: Bool = false) -> String {
    let refField = ref.map { #""requestRef":"\#($0)","# } ?? ""
    return #"{"parentUuid":"p","isSidechain":\#(sidechain),"message":{"model":"\#(model)","id":"\#(msg)","type":"message","role":"assistant","content":[{"type":"\#(kind)"}],"stop_reason":"tool_use","usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000,"output_tokens":\#(output),"speed":"standard"}},"requestId":"req_\#(msg)",\#(refField)"type":"assistant","uuid":"u","timestamp":"\#(time)","sessionId":"s1"}"#
}

private let interrupted = #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"u2","timestamp":"2026-10-24T15:00:30.000Z","sessionId":"s1"}"#

private let synthetic = #"{"parentUuid":"p","isSidechain":false,"type":"assistant","uuid":"u3","timestamp":"2026-10-24T15:00:30.000Z","message":{"id":"x","model":"<synthetic>","role":"assistant","type":"message","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"API Error"}]},"isApiErrorMessage":true,"sessionId":"s1"}"#

private let t0 = TokenParser.parseTimestamp("2026-10-24T15:00:00.000Z")!

// MARK: - 解析

@Test func parsesRequestStartsAndEnds() throws {
    let blob = #"{"type":"api-request-blob","hash":"h","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"sessionId":"s1"}"#
    let body = [
        request("r1", at: "2026-10-24T15:00:00.000Z"),
        blob,
        block("m1", ref: "r1", at: "2026-10-24T15:00:12.500Z", output: 900),
        interrupted,
        synthetic,
    ].joined(separator: "\n") + "\n"

    let events = TokenParser.parse(data: Data(body.utf8), from: 0).events
    #expect(events.count == 4)
    guard case .requestStarted(let start) = events[0] else { Issue.record("expected request"); return }
    #expect(start == RequestStart(id: "r1", time: t0, model: "claude-opus-5-5"))
    guard case .usage(let usage) = events[1] else { Issue.record("expected usage"); return }
    #expect(usage.requestRef == "r1")
    #expect(usage.tokens.output == 900)
    guard case .requestEnded = events[2], case .requestEnded = events[3] else { Issue.record("expected ends"); return }
}

@Test func quotedInterruptionInsideToolOutputIsNotAnEnd() {
    // 工具结果里引用到这句话时在字符串里，引号是转义过的
    let quoted = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"{\"text\":\"[Request interrupted by user]\"}"}]},"sessionId":"s1"}"#
    #expect(TokenParser.parse(data: Data((quoted + "\n").utf8), from: 0).events.isEmpty)
}

// MARK: - 索引

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cum-speed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func append(_ lines: [String], to url: URL) throws {
    let text = lines.joined(separator: "\n") + "\n"
    if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    } else {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

@Test func timesEachRequestFromSendToLastBlock() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("s1.jsonl")
    let index = UsageIndex(sourceSignature: "test")

    // 请求发出，回复还没写进来：算作生成中
    try append([request("r1", at: "2026-10-24T15:00:00.000Z")], to: file)
    var stats = index.scan(roots: [dir])
    #expect(stats.timingsChanged)
    #expect(index.pending.values.map(\.id) == ["r1"])
    #expect(index.timings.isEmpty)

    // 整条回复一起写进来：思考、两次工具调用各一行
    try append([
        block("m1", ref: "r1", at: "2026-10-24T15:00:08.000Z", output: 1200),
        block("m1", ref: "r1", at: "2026-10-24T15:00:09.000Z", output: 1200, kind: "tool_use"),
        block("m1", ref: "r1", at: "2026-10-24T15:00:10.000Z", output: 1200, kind: "tool_use"),
    ], to: file)
    stats = index.scan(roots: [dir])
    #expect(stats.timingsChanged)
    #expect(index.pending.isEmpty)
    let timing = try #require(index.timings.values.first)
    #expect(index.timings.count == 1)
    #expect(timing.start == t0)
    #expect(timing.end == t0 + 10)
    #expect(timing.output == 1200)

    let log = index.speedLog()
    #expect(log.requests.count == 1)
    #expect(log.requests[0].model == "Opus 5.5")
    #expect(log.requests[0].rate == 120)
}

@Test func interruptedOrFailedRequestsStopGenerating() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("s1.jsonl")
    let index = UsageIndex(sourceSignature: "test")

    try append([request("r1", at: "2026-10-24T15:00:00.000Z"), interrupted], to: file)
    index.scan(roots: [dir])
    #expect(index.pending.isEmpty)

    try append([request("r2", at: "2026-10-24T15:01:00.000Z"), synthetic], to: file)
    index.scan(roots: [dir])
    #expect(index.pending.isEmpty)

    // 出错重试：同一个文件里新发的请求替换掉旧的
    try append([request("r3", at: "2026-10-24T15:02:00.000Z"), request("r4", at: "2026-10-24T15:02:05.000Z")], to: file)
    index.scan(roots: [dir])
    #expect(index.pending.values.map(\.id) == ["r4"])
    #expect(index.timings.isEmpty)
}

@Test func repliesWithoutRequestLinesAreUntimed() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try append([block("m1", ref: nil, at: "2026-10-24T15:00:08.000Z", output: 500)], to: dir.appendingPathComponent("s1.jsonl"))
    let index = UsageIndex(sourceSignature: "test")
    index.scan(roots: [dir])
    #expect(index.records.count == 1)
    #expect(index.timings.isEmpty)
    #expect(index.lastUntimed == t0 + 8)
}

@Test func timingsComeBackAfterLoadingTheCache() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // 计时只留最近两小时：用现在的时间写记录
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let now = Date()
    try append([
        request("r1", at: f.string(from: now.addingTimeInterval(-60))),
        block("m1", ref: "r1", at: f.string(from: now.addingTimeInterval(-50)), output: 800),
        request("r2", at: f.string(from: now.addingTimeInterval(-5))),
    ], to: dir.appendingPathComponent("s1.jsonl"))

    let first = UsageIndex(sourceSignature: "test")
    first.scan(roots: [dir])
    #expect(first.timings.count == 1)
    let cache = dir.appendingPathComponent("index.bin")
    try first.write(to: cache)

    // 磁盘缓存里没有计时；游标已经在文件末尾，第一次扫描仍要从头读一遍补上
    let loaded = try UsageIndex.read(from: cache)
    #expect(loaded.timings.isEmpty)
    let stats = loaded.scan(roots: [dir])
    #expect(stats.timingsChanged)
    #expect(loaded.timings.count == 1)
    #expect(loaded.pending.values.map(\.id) == ["r2"])
    #expect(loaded.records.count == 1)
}

// MARK: - 计算

private func sample(_ id: UInt64, end: Double, duration: Double, output: Int, model: String = "Opus 5.5") -> TimedRequest {
    TimedRequest(id: id, model: model, start: end - duration, end: end, output: output)
}

@Test func rateWeighsByTokens() throws {
    // 一次长回复 2000 tokens / 20 秒，一次短回复 100 tokens / 10 秒（大部分时间在等第一个字）
    let requests = [sample(1, end: 100, duration: 20, output: 2000), sample(2, end: 200, duration: 10, output: 100)]
    let rate = try #require(OutputSpeed.rate(requests, from: 0, to: 200))
    #expect(rate.count == 2)
    #expect(rate.output == 2100)
    #expect(rate.duration == 30)
    #expect(rate.tokensPerSecond == 70)
    // 窗口是左开右闭
    #expect(OutputSpeed.rate(requests, from: 100, to: 200)?.count == 1)
    #expect(OutputSpeed.rate(requests, from: 200, to: 300) == nil)
}

@Test func curveEndsAtTheHeadlineNumber() throws {
    let requests = (0..<40).map { i in sample(UInt64(i), end: Double(i) * 45, duration: 10 + Double(i % 7), output: 300 + i * 37) }
    let now = 40.0 * 45
    let curve = OutputSpeed.curve(requests, from: now - OutputSpeed.span, to: now, count: 161)
    #expect(curve.count == 161)
    let headline = try #require(OutputSpeed.rate(requests, from: now - OutputSpeed.recent, to: now))
    #expect(curve.last == headline.tokensPerSecond)
    // 一开始没有请求
    #expect(curve.first == .some(nil))
}

@Test func ceilingKeepsMostPointsInside() {
    #expect(OutputSpeed.ceiling([]) == 150)
    let opus = (0..<20).map { sample(UInt64($0), end: Double($0), duration: 10, output: 600 + $0 * 20) }
    #expect(OutputSpeed.ceiling(opus) == 150)
    let haiku = (0..<20).map { sample(UInt64($0), end: Double($0), duration: 10, output: 2000 + $0 * 30) }
    #expect(OutputSpeed.ceiling(haiku) == 300)
    #expect(OutputSpeed.gridline(below: 150) == 100)
    #expect(OutputSpeed.gridline(below: 300) == 200)
}

@Test func modelsAreSeparatedAndStalePendingDropped() {
    let now = 10_000.0
    let log = SpeedLog(
        requests: [
            sample(1, end: now - 4000, duration: 10, output: 9000),
            sample(2, end: now - 100, duration: 10, output: 500, model: "Haiku 5.5"),
            sample(3, end: now - 50, duration: 10, output: 800),
            sample(4, end: now - 20, duration: 10, output: 900, model: "Haiku 5.5"),
        ],
        pending: [
            PendingRequest(id: "old", model: "Opus 5.5", start: now - OutputSpeed.pendingLimit - 1),
            PendingRequest(id: "live", model: "Opus 5.5", start: now - 3),
        ]
    )
    let models = log.models(now: now)
    // 一个多小时以前的那次不算：Haiku 输出更多，排在前面
    #expect(models.map(\.model) == ["Haiku 5.5", "Opus 5.5"])
    #expect(models[1].requests.map(\.id) == [3])
    #expect(models[1].pending.map(\.id) == ["live"])
}
