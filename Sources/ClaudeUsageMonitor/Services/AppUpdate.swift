import AppKit
import CryptoKit
import Foundation
import Observation
import UsageCore
@preconcurrency import UserNotifications

/// 从 GitHub Releases 检查并安装更新。只访问 GitHub，不使用 Claude 登录。
@MainActor
@Observable
final class AppUpdate {
    static let shared = AppUpdate()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// 安装包下载进度，0 到 1。
    private(set) var downloadFraction: Double = 0
    private(set) var notesVisible = false
    private(set) var notes = ""
    private(set) var notesReady = false
    private(set) var notesVersion: String?
    private(set) var pageURL: URL?

    @ObservationIgnored private var release: AppRelease?
    @ObservationIgnored private var lastCheck = Date.distantPast
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var wantsNotes = false

    static let endpoint = URL(string: "https://api.github.com/repos/kittors/claude-usage-monitor/releases/latest")!
    private static let interval: TimeInterval = 12 * 60 * 60
    private static let notifiedKey = "notifiedUpdateVersion"

    var canInstall: Bool {
        if case .available = phase { return true }
        return false
    }

    var showsNotice: Bool {
        switch phase {
        case .available, .downloading, .installing, .failed: true
        default: false
        }
    }

    var statusText: String {
        switch phase {
        case .idle: L10n.t("当前 \(Self.currentText)", "Current \(Self.currentText)")
        case .checking: L10n.t("正在检查…", "Checking…")
        case .upToDate: L10n.t("已是最新 \(Self.currentText)", "Up to date \(Self.currentText)")
        case .available(let version): L10n.t("发现新版本 \(version)", "Version \(version) is available")
        case .downloading: L10n.t("正在下载 \(Fmt.percent(downloadFraction))", "Downloading \(Fmt.percent(downloadFraction))")
        case .installing: L10n.t("正在安装，即将重新打开", "Installing, reopening shortly")
        case .failed(let message): message
        }
    }

    func checkIfStale() {
        guard Date().timeIntervalSince(lastCheck) >= Self.interval else { return }
        check(interactive: false)
    }

    func check(interactive: Bool = true) {
        guard !inFlight else { return }
        guard let current = Self.current else {
            if interactive { phase = .failed(L10n.t("开发版无法检查更新", "Development builds cannot check for updates")) }
            return
        }
        inFlight = true
        if interactive || phase == .idle { phase = .checking }
        lastCheck = Date()
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsageMonitor", forHTTPHeaderField: "User-Agent")
        Task {
            defer { inFlight = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.unavailable }
                let found = try AppRelease.decodeGitHub(data)
                release = found
                notes = found.notes
                notesReady = true
                notesVersion = found.version.text
                pageURL = found.pageURL
                if wantsNotes { notesVisible = true }
                if found.version > current {
                    phase = .available(found.version.text)
                    remind(found.version.text)
                } else {
                    phase = .upToDate
                }
            } catch {
                if interactive {
                    phase = .failed(L10n.t("暂时无法检查更新", "Could not check for updates"))
                } else if case .available = phase {
                    // 保留已经发现的版本
                } else {
                    phase = .idle
                }
            }
        }
    }

    /// 展开这个版本的更新说明。还没拉到说明时先检查一次。
    func toggleNotes() {
        if notesVisible {
            notesVisible = false
            return
        }
        notesVisible = true
        if !notesReady {
            wantsNotes = true
            check()
        }
    }

    func openReleasePage() {
        guard let pageURL else { return }
        NSWorkspace.shared.open(pageURL)
    }

    func install() {
        guard case .available = phase, let release, !inFlight else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            phase = .failed(L10n.t("请先把应用放进「应用程序」再更新", "Move the app into Applications before updating"))
            return
        }
        inFlight = true
        downloadFraction = 0
        phase = .downloading
        let zipURL = release.zipURL
        let checksumURL = release.checksumURL
        let target = Bundle.main.bundleURL
        Task { [weak self] in
            guard let self else { return }
            do {
                let zip = try await Self.download(zipURL) { fraction in
                    self.downloadFraction = fraction
                }
                if let checksumURL {
                    let sum = try await Self.download(checksumURL)
                    let expected = String(decoding: sum, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased()
                    let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
                    guard expected == actual else { throw UpdateError.checksum }
                } else {
                    throw UpdateError.checksum
                }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-monitor-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let archive = folder.appendingPathComponent("update.zip")
                try zip.write(to: archive, options: .atomic)
                let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
                try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
                try ditto.run()
                ditto.waitUntilExit()
                guard ditto.terminationStatus == 0 else { throw UpdateError.unpack }
                let app = unpacked.appendingPathComponent("Claude Usage Monitor.app")
                guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError.unpack }
                phase = .installing
                try Self.relaunch(replacing: target, with: app)
            } catch {
                inFlight = false
                phase = .failed(L10n.t("更新没有完成，可以稍后再试", "The update did not finish. Try again later."))
            }
        }
    }

    private func remind(_ version: String) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.notifiedKey) != version else { return }
        defaults.set(version, forKey: Self.notifiedKey)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = L10n.tNow("发现新版本 \(version)", "Version \(version) is available")
            content.body = L10n.tNow("点击即可更新 Claude Usage Monitor", "Click to update Claude Usage Monitor")
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "app-update", content: content, trigger: nil))
        }
    }

    private static var current: AppVersion? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
        return AppVersion(raw)
    }

    private static var currentText: String { current?.text ?? L10n.t("开发版", "dev") }

    private static func download(_ url: URL, onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let box = DownloadBox(onProgress: onProgress, continuation: continuation)
            let session = URLSession(configuration: .ephemeral, delegate: box, delegateQueue: nil)
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.setValue("ClaudeUsageMonitor", forHTTPHeaderField: "User-Agent")
            box.session = session
            session.downloadTask(with: request).resume()
        }
    }

    /// 等当前进程退出后替换应用并重新打开。安装包已用发布时的 SHA-256 核对过。
    private static func relaunch(replacing target: URL, with source: URL) throws {
        let script = """
        #!/bin/zsh
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do
          sleep 0.2
        done
        /bin/rm -rf \(shellQuote(target.path))
        /usr/bin/ditto \(shellQuote(source.path)) \(shellQuote(target.path))
        /usr/bin/xattr -dr com.apple.quarantine \(shellQuote(target.path)) || true
        /usr/bin/open \(shellQuote(target.path))
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-monitor-update-\(UUID().uuidString).zsh")
        try Data(script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "nohup /bin/zsh \(shellQuote(file.path)) >/dev/null 2>&1 &"]
        try process.run()
        process.waitUntilExit()
        NSApp.terminate(nil)
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private enum UpdateError: Error {
        case unavailable, checksum, unpack
    }
}

private final class DownloadBox: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let onProgress: (@MainActor (Double) -> Void)?
    private let continuation: CheckedContinuation<Data, Error>
    var session: URLSession?

    init(onProgress: (@MainActor (Double) -> Void)?, continuation: CheckedContinuation<Data, Error>) {
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, let onProgress else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        Task { @MainActor in onProgress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let data = try Data(contentsOf: location)
            guard !data.isEmpty else {
                finish(.failure(URLError(.badServerResponse)))
                return
            }
            finish(.success(data))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let first = !finished
        if first { finished = true }
        lock.unlock()
        guard first else { return }
        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }
}
