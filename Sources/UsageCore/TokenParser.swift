import Foundation

/// 单条 assistant 消息的 usage 解析结果。
public struct ParsedUsage: Sendable {
    /// `message.id + requestId` 的 64 位哈希，用于全局去重
    public var key: UInt64
    /// Unix 时间戳（秒）
    public var time: Double
    public var model: String
    public var sessionId: String
    public var cwd: String?
    public var gitBranch: String?
    public var isSidechain: Bool
    public var tokens: TokenCounts
    public var webSearches: Int
    public var isFast: Bool
}

public enum ParsedEvent: Sendable {
    case usage(ParsedUsage)
    case title(sessionId: String, title: String)
}

public struct FileParseResult: Sendable {
    public var events: [ParsedEvent]
    /// 已完整解析到的字节偏移（最后一个换行符之后）
    public var endOffset: Int64
    public var bytesRead: Int64
    public var linesParsed: Int
}

/// Claude Code 会话日志（JSONL）的解析器。
///
/// 性能要点：
/// - 文件使用 mmap 读取，只从上次的偏移处开始增量处理；
/// - 每行先做字节级 `memmem` 预过滤，只有候选行才进入 JSON 解码；
/// - Decodable 结构只声明需要的字段，大体积的 `content` 会被跳过。
public enum TokenParser {
    private static let needleUsage = Array(#""usage""#.utf8)
    private static let needleAssistant = Array(#""type":"assistant""#.utf8)
    private static let needleTitle = Array(#""type":"custom-title""#.utf8)

    // MARK: 文件

    public static func parseFile(at url: URL, from offset: Int64) -> FileParseResult {
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]) else {
            return FileParseResult(events: [], endOffset: offset, bytesRead: 0, linesParsed: 0)
        }
        return parse(data: data, from: offset)
    }

    public static func parse(data: Data, from offset: Int64) -> FileParseResult {
        let decoder = JSONDecoder()
        var events: [ParsedEvent] = []
        var lines = 0
        let start = Int(max(0, offset))

        let end: Int = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress, start < raw.count else { return min(start, raw.count) }
            var pos = start
            while pos < raw.count {
                // 找不到换行符说明最后一行还在写入中，留到下一次增量处理
                guard let nl = memchr(base + pos, 0x0A, raw.count - pos) else { break }
                let lineEnd = base.distance(to: UnsafeRawPointer(nl))
                if lineEnd > pos {
                    let line = UnsafeRawBufferPointer(start: base + pos, count: lineEnd - pos)
                    if let event = parseLine(line, decoder: decoder) { events.append(event) }
                    lines += 1
                }
                pos = lineEnd + 1
            }
            return pos
        }
        return FileParseResult(events: events, endOffset: Int64(end), bytesRead: Int64(end - start), linesParsed: lines)
    }

    // MARK: 行

    static func parseLine(_ line: UnsafeRawBufferPointer, decoder: JSONDecoder) -> ParsedEvent? {
        if line.count < 8192, contains(line, needleTitle) {
            guard let row = decode(TitleRow.self, line, decoder),
                  row.type == "custom-title",
                  let sid = row.sessionId, let title = row.customTitle,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return .title(sessionId: sid, title: title)
        }

        guard contains(line, needleUsage), contains(line, needleAssistant),
              let row = decode(AssistantRow.self, line, decoder),
              row.type == "assistant",
              let message = row.message,
              let usage = message.usage,
              let model = message.model, model != "<synthetic>",
              let stamp = row.timestamp, let time = parseTimestamp(stamp)
        else { return nil }

        let written = usage.cache_creation_input_tokens ?? 0
        var write5m = usage.cache_creation?.ephemeral_5m_input_tokens ?? 0
        let write1h = usage.cache_creation?.ephemeral_1h_input_tokens ?? 0
        // 旧版日志没有 TTL 拆分，全部视为 5 分钟写入
        if write5m + write1h < written { write5m = written - write1h }

        let tokens = TokenCounts(
            input: usage.input_tokens ?? 0,
            output: usage.output_tokens ?? 0,
            cacheWrite5m: write5m,
            cacheWrite1h: write1h,
            cacheRead: usage.cache_read_input_tokens ?? 0
        )
        let key: UInt64
        if message.id != nil || row.requestId != nil {
            key = fnv1a(row.requestId ?? "", seed: fnv1a((message.id ?? "") + "|"))
        } else {
            key = fnv1a("\(stamp)|\(model)|\(tokens.input)|\(tokens.output)|\(tokens.cacheRead)")
        }

        return .usage(ParsedUsage(
            key: key,
            time: time,
            model: model,
            sessionId: row.sessionId ?? "unknown",
            cwd: row.cwd,
            gitBranch: row.gitBranch,
            isSidechain: row.isSidechain ?? false,
            tokens: tokens,
            webSearches: Int(usage.server_tool_use?.web_search_requests ?? 0),
            isFast: usage.speed == "fast"
        ))
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ line: UnsafeRawBufferPointer, _ decoder: JSONDecoder) -> T? {
        guard let base = line.baseAddress else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        return try? decoder.decode(T.self, from: data)
    }

    @inline(__always)
    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { n in memmem(base, haystack.count, n.baseAddress, n.count) != nil }
    }

    // MARK: 工具

    /// 快速解析 ISO 8601（`2026-09-28T14:40:53.806Z` / `+08:00`），返回 Unix 秒。
    public static func parseTimestamp(_ string: String) -> Double? {
        var s = string
        return s.withUTF8 { b -> Double? in
            guard b.count >= 19 else { return nil }
            func digit(_ i: Int) -> Int? {
                guard i < b.count else { return nil }
                let c = b[i]
                return (c >= 48 && c <= 57) ? Int(c &- 48) : nil
            }
            func number(_ i: Int, _ n: Int) -> Int? {
                var v = 0
                for k in 0..<n {
                    guard let d = digit(i + k) else { return nil }
                    v = v * 10 + d
                }
                return v
            }
            guard let year = number(0, 4), b[4] == 0x2D,
                  let month = number(5, 2), b[7] == 0x2D,
                  let day = number(8, 2), b[10] == 0x54 || b[10] == 0x20,
                  let hour = number(11, 2), b[13] == 0x3A,
                  let minute = number(14, 2), b[16] == 0x3A,
                  let second = number(17, 2)
            else { return nil }

            var i = 19
            var fraction = 0.0
            if i < b.count, b[i] == 0x2E {
                i += 1
                var scale = 0.1
                while let d = digit(i) {
                    fraction += Double(d) * scale
                    scale *= 0.1
                    i += 1
                }
            }
            var offset = 0
            if i < b.count, b[i] == 0x2B || b[i] == 0x2D {
                let sign = b[i] == 0x2B ? 1 : -1
                let oh = number(i + 1, 2) ?? 0
                let om = (i + 3 < b.count && b[i + 3] == 0x3A) ? (number(i + 4, 2) ?? 0) : (number(i + 3, 2) ?? 0)
                offset = sign * (oh * 3600 + om * 60)
            }
            let days = daysFromCivil(year, month, day)
            return Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction
        }
    }

    /// Howard Hinnant 的 days-from-civil 算法（公历日期 → 自 1970-01-01 起的天数）
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    @inline(__always)
    static func fnv1a(_ s: String, seed: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
        var h = seed
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }
}

// MARK: - 精简的 Decodable 结构（只声明需要的字段）

private struct TitleRow: Decodable {
    let type: String?
    let customTitle: String?
    let sessionId: String?
}

private struct AssistantRow: Decodable {
    let type: String?
    let timestamp: String?
    let requestId: String?
    let sessionId: String?
    let cwd: String?
    let gitBranch: String?
    let isSidechain: Bool?
    let message: Message?

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    struct Usage: Decodable {
        let input_tokens: Int64?
        let output_tokens: Int64?
        let cache_creation_input_tokens: Int64?
        let cache_read_input_tokens: Int64?
        let cache_creation: CacheCreation?
        let server_tool_use: ServerToolUse?
        let speed: String?
    }

    struct CacheCreation: Decodable {
        let ephemeral_5m_input_tokens: Int64?
        let ephemeral_1h_input_tokens: Int64?
    }

    struct ServerToolUse: Decodable {
        let web_search_requests: Int64?
    }
}
