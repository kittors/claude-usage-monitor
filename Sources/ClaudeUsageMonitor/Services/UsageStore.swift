import AppKit
import Foundation
import Observation
import UsageCore

/// 后台引擎：持有增量索引，所有操作都在私有串行队列上执行。
final class UsageEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "claude-usage-monitor.engine", qos: .userInitiated)
    private var index: UsageIndex?
    private var snapshot: IndexSnapshot?
    private var dirty = true
    private var lastWrite = Date.distantPast
    private var writeScheduled = false
    let cacheURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheURL = base.appendingPathComponent("ClaudeUsageMonitor/index-v3.bin")
    }

    /// 读取磁盘缓存；返回是否命中
    func prepare(signature: String, completion: @escaping (Bool) -> Void) {
        queue.async {
            if let loaded = try? UsageIndex.read(from: self.cacheURL), loaded.sourceSignature == signature {
                self.index = loaded
                self.dirty = true
                completion(true)
            } else {
                self.index = UsageIndex(sourceSignature: signature)
                self.dirty = true
                completion(false)
            }
        }
    }

    func reset(signature: String) {
        queue.async {
            self.index = UsageIndex(sourceSignature: signature)
            self.snapshot = nil
            self.dirty = true
            try? FileManager.default.removeItem(at: self.cacheURL)
        }
    }

    func scan(roots: [URL], progress: ((Int, Int) -> Void)?, completion: @escaping (ScanStats) -> Void) {
        queue.async {
            guard let index = self.index else { return }
            let stats = index.scan(roots: roots, progress: progress)
            if stats.changed { self.dirty = true }
            if stats.filesParsed > 0 { self.persistSoon() }
            completion(stats)
        }
    }

    func compute(settings: UsageSettings, now: Date, completion: @escaping (UsageSnapshot?, Int) -> Void) {
        queue.async {
            guard let index = self.index else {
                completion(nil, 0)
                return
            }
            if self.dirty || self.snapshot == nil {
                self.snapshot = index.makeSnapshot()
                self.dirty = false
            }
            let result = self.snapshot.map { UsageCalculator.snapshot(of: $0, settings: settings, now: now) }
            completion(result, index.fileCount)
        }
    }

    /// 缓存写入节流：活跃会话时文件每秒都在变，最多每 45 秒落盘一次
    private func persistSoon() {
        let elapsed = Date().timeIntervalSince(lastWrite)
        if elapsed > 45 {
            persist()
        } else if !writeScheduled {
            writeScheduled = true
            queue.asyncAfter(deadline: .now() + (45 - elapsed)) {
                self.writeScheduled = false
                self.persist()
            }
        }
    }

    private func persist() {
        guard let index else { return }
        try? index.write(to: cacheURL)
        lastWrite = Date()
    }

    func flush() {
        queue.sync { self.persist() }
    }

    var cacheSize: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.size] as? Int64) ?? 0
    }
}

/// 面向 UI 的数据仓库。
@MainActor
@Observable
final class UsageStore {
    enum Phase: Equatable {
        case launching
        case indexing(Double)
        case ready
        case empty
    }

    private(set) var phase: Phase = .launching
    private(set) var snapshot: UsageSnapshot?
    private(set) var lastUpdated: Date?
    private(set) var isScanning = false
    /// 每次有新数据都会 +1，驱动 Logo 的脉冲动画
    private(set) var pulse = 0
    private(set) var lastScan: ScanStats?
    private(set) var indexedFiles = 0

    @ObservationIgnored let prefs: Preferences
    @ObservationIgnored let engine = UsageEngine()
    /// 官方用量（5 小时 / 每周百分比）
    let official = OfficialUsageService()
    /// 本机数据或官方数据有更新（刷新菜单栏、检查提醒）
    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored private var watcher: SessionWatcher?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pendingScan: DispatchWorkItem?
    @ObservationIgnored private var lastScanAt = Date.distantPast
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private var lastProgressPush = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    func start() {
        official.onChange = { [weak self] in self?.officialChanged() }
        official.autoRenew = prefs.autoRenewLogin
        official.outboundProxy = OutboundProxy.parse(prefs.officialProxy)
        official.blockIPv6 = prefs.blockIPv6
        NetworkPlace.shared.proxy = official.outboundProxy
        NetworkPlace.shared.blockIPv6 = prefs.blockIPv6
        NetworkPlace.shared.onUpdate = { [weak self] in
            guard let self, !NetworkPlace.shared.blocksOfficialUsage, self.sessionActive() else { return }
            self.official.claudeActive = true
            self.official.refresh(.timer)
        }
        NetworkPlace.shared.refresh()
        if prefs.officialUsageEnabled {
            // 启动时不主动访问 Anthropic。只有 Claude Code 正在用，才同步一次。
            if sessionActive() {
                official.claudeActive = true
                official.refresh(.timer)
            }
        } else {
            official.setEnabled(false)
        }
        ExchangeRates.shared.refreshIfStale()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { AppUpdate.shared.checkIfStale() }
        observeOfficialSettings()

        engine.prepare(signature: prefs.sourceSignature) { hadCache in
            DispatchQueue.main.async {
                if hadCache { self.recompute() } else { self.phase = .indexing(0) }
                self.scan(initial: true)
                self.startWatching()
                self.startTimer()
                self.observePreferences()
                self.observeDataDirectory()
                self.observeSystem()
            }
        }
    }

    // MARK: 扫描与计算

    func refreshNow() {
        pulse += 1
        pendingScan?.cancel()
        pendingScan = nil
        scan()
        official.refresh(.manual)
    }

    /// 弹窗打开时调用：数据超过 1 分钟就同步一次（仍受频率限制保护）
    func panelOpened() {
        NetworkPlace.shared.refreshIfStale()
        official.refresh(.panel)
        ExchangeRates.shared.refreshIfStale()
        AppUpdate.shared.checkIfStale()
    }

    /// 在终端中登录 Claude Code，登录完成后自动恢复官方用量
    func signInToClaudeCode() {
        guard ClaudeLogin.openInTerminal() else { return }
        official.watchForLogin()
    }

    private func scan(initial: Bool = false) {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        let showProgress = phase != .ready
        var progress: ((Int, Int) -> Void)?
        if showProgress {
            progress = { [weak self] done, total in
                DispatchQueue.main.async { self?.pushProgress(done: done, total: total) }
            }
        }
        engine.scan(roots: prefs.dataRoots, progress: progress) { [weak self] stats in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                self.lastScan = stats
                self.lastScanAt = Date()
                if !initial, stats.filesParsed > 0 { self.noteSessionActivity() }
                if stats.changed || self.snapshot == nil {
                    self.recompute(pulse: !initial && stats.changed)
                } else {
                    self.lastUpdated = Date()
                }
                if self.rescanRequested {
                    self.rescanRequested = false
                    self.scheduleScan(after: 1)
                }
            }
        }
    }

    private func pushProgress(done: Int, total: Int) {
        guard phase != .ready else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProgressPush) > 0.05 || done == total else { return }
        lastProgressPush = now
        phase = .indexing(total > 0 ? Double(done) / Double(total) : 1)
    }

    /// 计费周期配置。重置时刻用官方每周限额（面板上的「周六 22:00」），还没同步过时用上次记下的时刻。
    func billingSettings() -> UsageSettings {
        var settings = prefs.usageSettings
        if let reset = official.usage?.weeklyReset() ?? prefs.weeklyResetAt {
            settings.weeklyReset = reset
            let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: reset)
            if let hour = parts.hour { settings.billingAnchorHour = hour }
            if let minute = parts.minute { settings.billingAnchorMinute = minute }
            if let second = parts.second { settings.billingAnchorSecond = second }
        }
        return settings
    }

    /// 已确定的重置时刻：当前官方数据优先，否则用上次同步记下的时刻
    var learnedResetClock: (hour: Int, minute: Int)? {
        if let clock = official.usage?.weeklyResetClock(calendar: .current) { return clock }
        if let hour = prefs.billingAnchorHour, let minute = prefs.billingAnchorMinute { return (hour, minute) }
        return nil
    }

    func recompute(pulse: Bool = false) {
        engine.compute(settings: billingSettings(), now: Date()) { [weak self] snap, files in
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = snap
                self.indexedFiles = files
                self.lastUpdated = Date()
                self.phase = (snap?.hasData ?? false) ? .ready : (self.isScanning ? self.phase : .empty)
                if pulse { self.pulse += 1 }
                self.onUpdate?()
            }
        }
    }

    private func officialChanged() {
        if let plan = official.detectedPlan, plan != prefs.plan { prefs.plan = plan }
        // 记下每周限额的重置时刻，下次启动、还没同步完时周期也不会退回 0:00
        if let reset = official.usage?.weeklyReset() {
            if prefs.weeklyResetAt != reset { prefs.weeklyResetAt = reset }
            let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: reset)
            if let hour = parts.hour, prefs.billingAnchorHour != hour { prefs.billingAnchorHour = hour }
            if let minute = parts.minute, prefs.billingAnchorMinute != minute { prefs.billingAnchorMinute = minute }
            if let second = parts.second, prefs.billingAnchorSecond != second { prefs.billingAnchorSecond = second }
        }
        onUpdate?()
    }

    private func observeOfficialSettings() {
        withObservationTracking {
            _ = prefs.officialUsageEnabled
            _ = prefs.autoRenewLogin
            _ = prefs.officialProxy
            _ = prefs.blockIPv6
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let renewTurnedOn = self.prefs.autoRenewLogin && !self.official.autoRenew
                self.official.autoRenew = self.prefs.autoRenewLogin
                self.official.outboundProxy = OutboundProxy.parse(self.prefs.officialProxy)
                self.official.blockIPv6 = self.prefs.blockIPv6
                NetworkPlace.shared.proxy = self.official.outboundProxy
                NetworkPlace.shared.blockIPv6 = self.prefs.blockIPv6
                NetworkPlace.shared.refresh()
                if self.prefs.officialUsageEnabled == (self.official.state == .disabled) {
                    self.official.setEnabled(self.prefs.officialUsageEnabled)
                } else if renewTurnedOn, self.official.state == .expired {
                    self.official.refresh(.manual)
                }
                self.observeOfficialSettings()
            }
        }
    }

    private func scheduleScan(after delay: TimeInterval) {
        guard pendingScan == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingScan = nil
            self.scan()
        }
        pendingScan = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 数据源变化（或手动重建）：丢弃索引后重新全量扫描
    func rebuildIndex() {
        watcher?.stop()
        snapshot = nil
        phase = .indexing(0)
        engine.reset(signature: prefs.sourceSignature)
        scan(initial: true)
        startWatching()
    }

    func flush() { engine.flush() }

    var cacheSize: Int64 { engine.cacheSize }

    // MARK: 监听

    private func startWatching() {
        watcher?.stop()
        let paths = prefs.dataRoots.map(\.path)
        watcher = SessionWatcher(paths: paths) { [weak self] in
            MainActor.assumeIsolated { self?.filesChanged() }
        }
        watcher?.start()
    }

    private func filesChanged() {
        noteSessionActivity()
        // 活跃会话会持续写文件：最多每 2.5 秒扫描一次，且不会被持续的事件无限推迟
        let since = Date().timeIntervalSince(lastScanAt)
        scheduleScan(after: max(0.3, 2.5 - since))
    }

    /// 会话日志刚写过，或 Claude Code 进程还在。安静超过 10 分钟后不再后台请求官方用量。
    private var lastLogActivity = Date.distantPast

    private func noteSessionActivity() {
        lastLogActivity = Date()
        official.claudeActive = true
        official.refresh(.timer)
    }

    private func sessionActive() -> Bool {
        if Date().timeIntervalSince(lastLogActivity) < 10 * 60 { return true }
        return ClaudeProcess.isRunning()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 时间窗口会随时间滑动；同时作为 FSEvents 的兜底
                if Date().timeIntervalSince(self.lastScanAt) > 55 { self.scan() } else { self.recompute() }
                self.official.claudeActive = self.sessionActive()
                self.official.refresh(.timer)
                ExchangeRates.shared.refreshIfStale()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private enum ClaudeProcess {
        static func isRunning() -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", "claude"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }

    private func observePreferences() {
        withObservationTracking {
            _ = prefs.usageSettings
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.recompute()
                self?.observePreferences()
            }
        }
    }

    private func observeDataDirectory() {
        withObservationTracking {
            _ = prefs.dataDirectory
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.rebuildIndex()
                self?.observeDataDirectory()
            }
        }
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let recompute: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: recompute))
        observers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: recompute))
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleScan(after: 2)
                self?.official.refresh(.panel)
            }
        })
    }
}
