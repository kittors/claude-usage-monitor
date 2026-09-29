import Darwin
import Foundation

/// 与 Claude Code 使用的 proper-lockfile 兼容的目录锁：
/// `mkdir` 成功即拿到锁；持有期间定期刷新目录的修改时间，超过 `stale` 秒没刷新的锁视为失效，可以被接管。
public final class DirectoryLock: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        /// 被其他进程持有
        case locked
        case system(Int32)
    }

    public let path: String
    let stale: TimeInterval
    let updateInterval: TimeInterval
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    /// 最近一次由自己写入的修改时间（用来确认锁仍属于自己）
    private var ownMtime: timespec?
    private var compromised = false

    public init(path: String, stale: TimeInterval, update: TimeInterval? = nil) {
        self.path = path
        self.stale = stale
        updateInterval = update ?? stale / 2
        queue = DispatchQueue(label: "claude-usage-monitor.lock", qos: .utility)
    }

    deinit { timer?.cancel() }

    /// 锁在持有期间是否被其他进程接管（例如长时间没能刷新）
    public var isCompromised: Bool { queue.sync { compromised } }

    /// 尝试获取一次，不等待
    public func acquire() throws {
        if mkdir(path, 0o777) == 0 { return didAcquire() }
        guard errno == EEXIST else { throw Failure.system(errno) }
        var info = stat()
        guard stat(path, &info) == 0 else {
            // 刚好被释放：再试一次
            if errno == ENOENT, mkdir(path, 0o777) == 0 { return didAcquire() }
            throw errno == ENOENT ? Failure.locked : Failure.system(errno)
        }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        guard modified < Date().timeIntervalSince1970 - stale else { throw Failure.locked }
        // 失效的锁（持有者已退出或卡住）：删除后重试一次
        if rmdir(path) != 0, errno != ENOENT { throw Failure.system(errno) }
        guard mkdir(path, 0o777) == 0 else { throw errno == EEXIST ? Failure.locked : Failure.system(errno) }
        didAcquire()
    }

    /// 释放：只删除仍属于自己的锁
    public func release() {
        queue.sync {
            timer?.cancel()
            timer = nil
            if !compromised, isStillOurs() { rmdir(path) }
            ownMtime = nil
        }
    }

    private func didAcquire() {
        queue.sync {
            compromised = false
            ownMtime = touch()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + updateInterval, repeating: updateInterval, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.refresh() }
            timer.resume()
            self.timer = timer
        }
    }

    /// 定期刷新修改时间，告诉其他进程锁仍然有效
    private func refresh() {
        guard !compromised else { return }
        guard isStillOurs() else {
            compromised = true
            timer?.cancel()
            timer = nil
            return
        }
        ownMtime = touch() ?? ownMtime
    }

    private func touch() -> timespec? {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: 0, tv_nsec: Int(UTIME_NOW))]
        guard utimensat(AT_FDCWD, path, &times, 0) == 0 else { return nil }
        var info = stat()
        return stat(path, &info) == 0 ? info.st_mtimespec : nil
    }

    private func isStillOurs() -> Bool {
        guard let own = ownMtime else { return false }
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return info.st_mtimespec.tv_sec == own.tv_sec && info.st_mtimespec.tv_nsec == own.tv_nsec
    }
}

/// Claude Code 在配置目录（`~/.claude`）下使用的几把锁。
public struct ClaudeCodeLocks: Sendable {
    public let configDirectory: URL

    public init(configDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.configDirectory = configDirectory
    }

    /// 续期锁：`~/.claude/.oauth_refresh.lock` 与旧版 Claude Code 使用的 `~/.claude.lock`，两把都拿到才算成功
    public func acquireRefreshLock() throws -> [DirectoryLock] {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let primary = DirectoryLock(path: configDirectory.appendingPathComponent(".oauth_refresh.lock").path, stale: 60, update: 5)
        try primary.acquire()
        let legacy = DirectoryLock(path: configDirectory.resolvingSymlinksInPath().path + ".lock", stale: 60, update: 5)
        do {
            try legacy.acquire()
        } catch {
            primary.release()
            throw error
        }
        return [primary, legacy]
    }

    /// 凭据写入锁：Claude Code 每次修改凭据都会先拿这把锁（`~/.claude/.storage-write.lock`）
    public func acquireStorageWriteLock() throws -> DirectoryLock {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let lock = DirectoryLock(path: configDirectory.appendingPathComponent(".storage-write.lock").path, stale: 15)
        try lock.acquire()
        return lock
    }
}
