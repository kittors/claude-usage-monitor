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
    /// 官方用量（准确的 5 小时 / 每周百分比）
    let official = OfficialUsageService()
    @ObservationIgnored var onSnapshot: ((UsageSnapshot) -> Void)?
    @ObservationIgnored private var watcher: SessionWatcher?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pendingScan: DispatchWorkItem?
    @ObservationIgnored private var lastScanAt = Date.distantPast
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private var lastProgressPush = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastCalibration = Date.distantPast
    /// 官方每周百分比的观测记录（识别中途重置）
    @ObservationIgnored private let weeklyTracker = WeeklyResetTracker()

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    func start() {
        official.onChange = { [weak self] in self?.officialChanged() }
        if prefs.officialUsageEnabled { official.refresh(force: true) } else { official.setEnabled(false) }
        observeOfficialToggle()

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
        official.refresh(force: true)
    }

    /// 弹窗打开时调用：官方数据有节流，不会频繁请求
    func panelOpened() {
        official.refresh()
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

    func recompute(pulse: Bool = false) {
        engine.compute(settings: effectiveSettings, now: Date()) { [weak self] snap, files in
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = snap
                self.indexedFiles = files
                self.lastUpdated = Date()
                self.phase = (snap?.hasData ?? false) ? .ready : (self.isScanning ? self.phase : .empty)
                if pulse { self.pulse += 1 }
                if let snap {
                    self.autoCalibrate(snap)
                    self.dropStaleOverride(snap)
                    self.onSnapshot?(snap)
                }
            }
        }
    }

    /// 有官方数据时，用官方窗口替换本地推算的窗口，保证本机费用与官方百分比口径一致
    private var effectiveSettings: UsageSettings {
        var settings = prefs.usageSettings
        settings.weeklyObservations = weeklyTracker.log.observations
        settings.weeklyResetFloor = weeklyTracker.log.resetFloorDate
        guard let usage = official.freshUsage else { return settings }
        settings.officialSyncedAt = usage.fetchedAt
        let now = Date()
        if let reset = usage.fiveHour?.resetsAt, reset > now {
            settings.fiveHourWindow = DateInterval(start: reset.addingTimeInterval(-UsageCalculator.fiveHours), end: reset)
        }
        if let reset = usage.sevenDay?.resetsAt, reset > now {
            settings.weeklyWindow = DateInterval(start: reset.addingTimeInterval(-7 * 86_400), end: reset)
        }
        return settings
    }

    private func officialChanged() {
        if let plan = official.detectedPlan, plan != prefs.plan { prefs.plan = plan }
        if let usage = official.freshUsage, let week = usage.sevenDay {
            weeklyTracker.record(week, at: usage.fetchedAt)
        }
        recompute()
    }

    /// 用官方百分比反推预算：用于「按当前速率」预测，以及离线时的估算
    private func autoCalibrate(_ snap: UsageSnapshot) {
        guard let usage = official.freshUsage, Date().timeIntervalSince(lastCalibration) > 600 else { return }
        var changed = false
        // 官方百分比对应的是同步那一刻的用量，要扣掉之后新增的本机费用
        if let f = usage.fiveHour?.fraction, f >= 0.08, snap.fiveHour.cost - snap.costSinceSync >= 2 {
            let budget = ((snap.fiveHour.cost - snap.costSinceSync) / f).rounded()
            if abs(budget - prefs.fiveHourBudget) / max(1, prefs.fiveHourBudget) > 0.03 { prefs.fiveHourBudget = budget; changed = true }
        }
        // 周预算只用差分推算的结果：直接用「本周费用 ÷ 百分比」会被中途重置之前的用量污染
        if let inferred = snap.weeklyInferredBudget {
            let budget = inferred.rounded()
            let reference = prefs.plan.weeklyBudget
            if budget > reference * 0.2, budget < reference * 5,
               abs(budget - prefs.weeklyBudget) / max(1, prefs.weeklyBudget) > 0.03 {
                prefs.weeklyBudget = budget
                changed = true
            }
        }
        if changed { prefs.budgetsCalibrated = true }
        lastCalibration = Date()
    }

    /// 手动指定的起算时间只在当前周期内有效
    private func dropStaleOverride(_ snap: UsageSnapshot) {
        if let override = prefs.weeklyStartOverride, override <= snap.weeklyCycleStart {
            prefs.weeklyStartOverride = nil
        }
    }

    private func observeOfficialToggle() {
        withObservationTracking {
            _ = prefs.officialUsageEnabled
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.official.setEnabled(self.prefs.officialUsageEnabled)
                self.observeOfficialToggle()
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
        // 活跃会话会持续写文件：最多每 2.5 秒扫描一次，且不会被持续的事件无限推迟
        let since = Date().timeIntervalSince(lastScanAt)
        scheduleScan(after: max(0.3, 2.5 - since))
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 时间窗口会随时间滑动；同时作为 FSEvents 的兜底
                if Date().timeIntervalSince(self.lastScanAt) > 55 { self.scan() } else { self.recompute() }
                self.official.refresh()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
            MainActor.assumeIsolated { self?.scheduleScan(after: 2) }
        })
    }
}
