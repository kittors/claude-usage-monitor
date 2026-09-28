import Foundation

/// 紧凑的单次请求记录（POD，可直接内存转储到磁盘缓存）。
public struct UsageRecord: Sendable, Equatable {
    public var key: UInt64
    public var time: Double
    public var input: UInt32
    public var output: UInt32
    public var cacheWrite5m: UInt32
    public var cacheWrite1h: UInt32
    public var cacheRead: UInt32
    /// 会话表下标
    public var session: UInt32
    /// 模型表下标
    public var model: UInt16
    public var webSearches: UInt16
    public var flags: UInt8

    public static let sidechainFlag: UInt8 = 1 << 0
    public static let fastFlag: UInt8 = 1 << 1

    public var isSidechain: Bool { flags & Self.sidechainFlag != 0 }
    public var isFast: Bool { flags & Self.fastFlag != 0 }

    public var tokens: TokenCounts {
        TokenCounts(
            input: Int64(input), output: Int64(output),
            cacheWrite5m: Int64(cacheWrite5m), cacheWrite1h: Int64(cacheWrite1h),
            cacheRead: Int64(cacheRead)
        )
    }
}

/// 单个会话的元数据（用于 Context Window 展示）。
public struct SessionMeta: Codable, Sendable, Hashable {
    public var id: String
    public var cwd: String?
    public var gitBranch: String?
    public var title: String?
    /// 最近一次主链 assistant 消息使用的模型
    public var model: String?
    public var lastActivity: Double
    /// 最近一次主链 assistant 消息的 usage，即当前上下文占用
    public var context: TokenCounts
    public var contextTime: Double
}

/// 每个 JSONL 文件的增量读取游标。
public struct FileCursor: Codable, Sendable, Hashable {
    public var size: Int64
    public var mtime: Double
    public var inode: UInt64
    public var offset: Int64
}

public struct ScanStats: Sendable {
    public var filesTotal = 0
    public var filesParsed = 0
    public var bytesRead: Int64 = 0
    public var linesParsed = 0
    public var recordsAdded = 0
    public var recordsUpdated = 0
    public var duration: TimeInterval = 0
    public var changed: Bool { recordsAdded > 0 || recordsUpdated > 0 || titlesChanged }
    public var titlesChanged = false
}

/// 增量索引：维护所有请求记录（全局去重）、会话表、模型表与文件游标。
///
/// 非线程安全，调用方需要在同一个串行队列上使用。
public final class UsageIndex: @unchecked Sendable {
    public private(set) var records: [UsageRecord] = []
    public private(set) var models: [String] = []
    public private(set) var sessions: [SessionMeta] = []
    public let sourceSignature: String

    private var keyIndex: [UInt64: Int32] = [:]
    private var modelIndex: [String: UInt16] = [:]
    private var sessionIndex: [String: UInt32] = [:]
    private var cursors: [String: FileCursor] = [:]

    public init(sourceSignature: String) {
        self.sourceSignature = sourceSignature
    }

    public var fileCount: Int { cursors.count }

    // MARK: 扫描

    struct FileEntry {
        let url: URL
        let size: Int64
        let mtime: Double
        let inode: UInt64
    }

    /// 扫描所有数据源目录，只解析新增或变化的部分。
    @discardableResult
    public func scan(roots: [URL], progress: ((_ done: Int, _ total: Int) -> Void)? = nil) -> ScanStats {
        let began = Date()
        var stats = ScanStats()
        let files = Self.enumerate(roots: roots)
        stats.filesTotal = files.count

        struct Job { let entry: FileEntry; let start: Int64 }
        var jobs: [Job] = []
        for entry in files {
            let path = entry.url.path
            if let cursor = cursors[path] {
                if cursor.inode == entry.inode, cursor.size == entry.size, cursor.mtime == entry.mtime { continue }
                if cursor.inode == entry.inode, entry.size >= cursor.offset {
                    jobs.append(Job(entry: entry, start: cursor.offset))
                } else {
                    jobs.append(Job(entry: entry, start: 0))  // 文件被替换或截断，重新读取（去重保证不会重复计数）
                }
            } else {
                jobs.append(Job(entry: entry, start: 0))
            }
        }

        // 已删除的文件只移除游标，历史记录保留在索引里
        let alive = Set(files.map(\.url.path))
        for path in cursors.keys where !alive.contains(path) { cursors.removeValue(forKey: path) }

        guard !jobs.isEmpty else {
            stats.duration = Date().timeIntervalSince(began)
            return stats
        }

        // 大文件优先，均衡并行负载
        jobs.sort { ($0.entry.size - $0.start) > ($1.entry.size - $1.start) }
        let results = UnsafeMutableBufferPointer<FileParseResult?>.allocate(capacity: jobs.count)
        results.initialize(repeating: nil)
        defer { results.deallocate() }

        let lock = NSLock()
        var finished = 0
        let jobList = jobs
        DispatchQueue.concurrentPerform(iterations: jobList.count) { i in
            let job = jobList[i]
            let result = TokenParser.parseFile(at: job.entry.url, from: job.start)
            lock.lock()
            results[i] = result
            finished += 1
            let done = finished
            lock.unlock()
            progress?(done, jobList.count)
        }

        // 串行合并：按时间先后合并，保证会话的「最新上下文」判断稳定
        for (i, job) in jobs.enumerated() {
            guard let result = results[i] else { continue }
            stats.filesParsed += 1
            stats.bytesRead += result.bytesRead
            stats.linesParsed += result.linesParsed
            for event in result.events {
                switch event {
                case .usage(let usage):
                    switch merge(usage) {
                    case .added: stats.recordsAdded += 1
                    case .updated: stats.recordsUpdated += 1
                    case .unchanged: break
                    }
                case .title(let sid, let title):
                    let idx = internSession(sid)
                    if sessions[Int(idx)].title != title {
                        sessions[Int(idx)].title = title
                        stats.titlesChanged = true
                    }
                }
            }
            cursors[job.entry.url.path] = FileCursor(
                size: job.entry.size, mtime: job.entry.mtime, inode: job.entry.inode, offset: result.endOffset
            )
        }

        stats.duration = Date().timeIntervalSince(began)
        return stats
    }

    enum MergeResult { case added, updated, unchanged }

    func merge(_ u: ParsedUsage) -> MergeResult {
        let sIdx = internSession(u.sessionId)
        let mIdx = internModel(u.model)

        var meta = sessions[Int(sIdx)]
        if let cwd = u.cwd, !cwd.isEmpty, !u.isSidechain || meta.cwd == nil { meta.cwd = cwd }
        if let branch = u.gitBranch, !branch.isEmpty, !u.isSidechain || meta.gitBranch == nil { meta.gitBranch = branch }
        meta.lastActivity = max(meta.lastActivity, u.time)
        if !u.isSidechain, u.time >= meta.contextTime {
            meta.context = u.tokens
            meta.contextTime = u.time
            meta.model = u.model
        }
        sessions[Int(sIdx)] = meta

        var flags: UInt8 = 0
        if u.isSidechain { flags |= UsageRecord.sidechainFlag }
        if u.isFast { flags |= UsageRecord.fastFlag }
        let record = UsageRecord(
            key: u.key,
            time: u.time,
            input: Self.clamp(u.tokens.input),
            output: Self.clamp(u.tokens.output),
            cacheWrite5m: Self.clamp(u.tokens.cacheWrite5m),
            cacheWrite1h: Self.clamp(u.tokens.cacheWrite1h),
            cacheRead: Self.clamp(u.tokens.cacheRead),
            session: sIdx,
            model: mIdx,
            webSearches: UInt16(clamping: u.webSearches),
            flags: flags
        )

        if let existing = keyIndex[u.key] {
            let old = records[Int(existing)]
            // 流式写入时同一条消息会落多行，中间行的 output 只是部分值，取数值最大的那一行
            let better = record.output > old.output
                || (record.output == old.output && record.tokens.prompt > old.tokens.prompt)
            guard better else { return .unchanged }
            var merged = record
            merged.time = min(old.time, record.time)
            merged.session = old.session
            records[Int(existing)] = merged
            return .updated
        }
        keyIndex[u.key] = Int32(records.count)
        records.append(record)
        return .added
    }

    private static func clamp(_ v: Int64) -> UInt32 { UInt32(clamping: max(0, v)) }

    private func internModel(_ id: String) -> UInt16 {
        if let idx = modelIndex[id] { return idx }
        let idx = UInt16(clamping: models.count)
        models.append(id)
        modelIndex[id] = idx
        return idx
    }

    private func internSession(_ id: String) -> UInt32 {
        if let idx = sessionIndex[id] { return idx }
        let idx = UInt32(sessions.count)
        sessions.append(SessionMeta(id: id, lastActivity: 0, context: .zero, contextTime: 0))
        sessionIndex[id] = idx
        return idx
    }

    static func enumerate(roots: [URL]) -> [FileEntry] {
        var result: [FileEntry] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let path = url.path
                var st = stat()
                guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                guard seen.insert(path).inserted else { continue }
                let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                result.append(FileEntry(url: url, size: Int64(st.st_size), mtime: mtime, inode: UInt64(st.st_ino)))
            }
        }
        return result
    }

    // MARK: 持久化

    private static let magic = Array("CUMIDX03".utf8)

    private struct Header: Codable {
        var sourceSignature: String
        var recordStride: Int
        var recordCount: Int
        var models: [String]
        var sessions: [SessionMeta]
        var cursors: [String: FileCursor]
    }

    public func write(to url: URL) throws {
        let header = Header(
            sourceSignature: sourceSignature,
            recordStride: MemoryLayout<UsageRecord>.stride,
            recordCount: records.count,
            models: models,
            sessions: sessions,
            cursors: cursors
        )
        let headerData = try JSONEncoder().encode(header)
        var out = Data(capacity: 12 + headerData.count + records.count * MemoryLayout<UsageRecord>.stride)
        out.append(contentsOf: Self.magic)
        var length = UInt32(headerData.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(headerData)
        records.withUnsafeBytes { out.append(contentsOf: $0) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> UsageIndex {
        let data = try Data(contentsOf: url)
        guard data.count >= 12, Array(data.prefix(8)) == magic else { throw CocoaError(.fileReadCorruptFile) }
        let length = data.subdata(in: 8..<12).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        let headerEnd = 12 + Int(length)
        guard data.count >= headerEnd else { throw CocoaError(.fileReadCorruptFile) }
        let header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 12..<headerEnd))
        let stride = MemoryLayout<UsageRecord>.stride
        guard header.recordStride == stride, data.count == headerEnd + header.recordCount * stride else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let index = UsageIndex(sourceSignature: header.sourceSignature)
        index.records = [UsageRecord](unsafeUninitializedCapacity: header.recordCount) { buffer, count in
            data.withUnsafeBytes { raw in
                if let dst = buffer.baseAddress, let src = raw.baseAddress {
                    memcpy(dst, src + headerEnd, header.recordCount * stride)
                }
            }
            count = header.recordCount
        }
        index.models = header.models
        index.sessions = header.sessions
        index.cursors = header.cursors
        for (i, r) in index.records.enumerated() { index.keyIndex[r.key] = Int32(i) }
        for (i, m) in header.models.enumerated() { index.modelIndex[m] = UInt16(i) }
        for (i, s) in header.sessions.enumerated() { index.sessionIndex[s.id] = UInt32(i) }
        return index
    }
}
