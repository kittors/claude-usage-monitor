import AppKit
import Foundation
import Observation
import SwiftUI
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
    /// 用户发起的刷新（点「立即刷新」或打开面板）还在进行：官方查询回来后才结束
    private(set) var isRefreshing = false

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
        lastSeenSync = official.usage?.fetchedAt
        NetworkPlace.shared.proxy = official.outboundProxy
        NetworkPlace.shared.onUpdate = { [weak self] in self?.exitChecked() }
        NetworkPlace.shared.refresh()
        // 启动时不主动访问 Anthropic：第一次算出本机用量后，Claude Code 正在使用才查一次
        if !prefs.officialUsageEnabled { official.setEnabled(false) }
        ExchangeRates.shared.refreshIfStale()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { AppUpdate.shared.checkIfStale() }
        observeOfficialSettings()

        engine.prepare(signature: prefs.sourceSignature) { hadCache in
            DispatchQueue.main.async {
                if hadCache { self.recompute() } else { self.phase = .indexing(0) }
                self.scan(initial: true)
                self.startWatching()
                self.startTimer()
                self.startAutoSync()
                self.observePreferences()
                self.observeDataDirectory()
                self.observeSystem()
            }
        }
    }

    // MARK: 扫描与计算

    func refreshNow() {
        pulse += 1
        rescanNow()
        isRefreshing = requestOfficial(.manual)
    }

    /// 弹窗打开时调用：默认刷新一次（「设置 › 用量 › 打开面板时刷新」可以关闭）
    func panelOpened() {
        NetworkPlace.shared.refreshIfStale()
        if prefs.refreshOnOpen {
            rescanNow()
            // 上次同步之后没有新的 Token 消耗，官方数字不会变，再查一次没有意义；等待登录时只读本地钥匙串，照常检查
            if official.state.awaitingLogin || hasNewUsageSinceSync() {
                isRefreshing = requestOfficial(.opened)
            } else {
                // 刚写进日志的消耗可能还没扫到：几秒内扫到新消耗就补查一次
                openCheckUntil = Date().addingTimeInterval(5)
            }
        }
        ExchangeRates.shared.refreshIfStale()
        AppUpdate.shared.checkIfStale()
    }

    private func rescanNow() {
        pendingScan?.cancel()
        pendingScan = nil
        scan()
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
                // 已经在显示数据时，新数字滚动、进度条缓动过去；第一次出现不做动画
                if self.snapshot != nil, snap != nil, self.phase == .ready {
                    withAnimation(.smooth(duration: 0.5)) { self.snapshot = snap }
                } else {
                    self.snapshot = snap
                }
                self.indexedFiles = files
                self.lastUpdated = Date()
                self.phase = (snap?.hasData ?? false) ? .ready : (self.isScanning ? self.phase : .empty)
                if pulse { self.pulse += 1 }
                self.trackConsumption(snap)
                self.onUpdate?()
            }
        }
    }

    private func officialChanged() {
        if isRefreshing, !official.isFetching { isRefreshing = false }
        if let fetched = official.usage?.fetchedAt, fetched != lastSeenSync {
            // 新的一次成功查询：请求发出之前的消耗都已经体现在官方数字里
            syncedCost = requestCost ?? observedCost
            lastSeenSync = fetched
            requestCost = nil
        }
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
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let renewTurnedOn = self.prefs.autoRenewLogin && !self.official.autoRenew
                self.official.autoRenew = self.prefs.autoRenewLogin
                self.official.outboundProxy = OutboundProxy.parse(self.prefs.officialProxy)
                NetworkPlace.shared.proxy = self.official.outboundProxy
                NetworkPlace.shared.refresh()
                if self.prefs.officialUsageEnabled == (self.official.state == .disabled) {
                    self.official.setEnabled(self.prefs.officialUsageEnabled)
                } else if renewTurnedOn, self.official.state == .expired {
                    self.requestOfficial(.manual)
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
        observedCost = nil
        syncedCost = nil
        lastCostIncrease = nil
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
                ExchangeRates.shared.refreshIfStale()
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
            MainActor.assumeIsolated {
                self?.scheduleScan(after: 2)
                self?.evaluateAutoSync(.resume)
            }
        })
    }

    // MARK: 自动查询官方用量

    /// 本机累计消耗（按 API 价格折算）。增加了就说明 Claude Code 有新的 Token 消耗
    @ObservationIgnored private var observedCost: Double?
    /// 最近一次看到累计消耗增加的时间
    @ObservationIgnored private var lastCostIncrease: Date?
    /// 上次成功查询时（请求发出那一刻）的累计消耗
    @ObservationIgnored private var syncedCost: Double?
    /// 正在进行的请求发出时的累计消耗
    @ObservationIgnored private var requestCost: Double?
    /// 已经处理过的官方数据获取时间（用来发现新的一次成功查询）
    @ObservationIgnored private var lastSeenSync: Date?
    @ObservationIgnored private var autoSyncTimer: Timer?
    @ObservationIgnored private var runningCheck: (at: Date, running: Bool)?
    @ObservationIgnored private var launchSyncPending = true
    /// 展开面板时没有新消耗而没查：这个时间之前扫到新消耗就补查一次
    @ObservationIgnored private var openCheckUntil = Date.distantPast
    @ObservationIgnored private var exitWasAllowed = false

    /// 每 2 秒按「设置 › 用量 › 自动查询」判断一次；没有新消耗时几乎不做事
    private func startAutoSync() {
        autoSyncTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateAutoSync(.tick) }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        autoSyncTimer = timer
    }

    private func trackConsumption(_ snap: UsageSnapshot?) {
        guard let snap else { return }
        let cost = snap.lifetimeCost
        var increased = false
        if let observed = observedCost {
            if cost > observed + 0.000_001 {
                lastCostIncrease = Date()
                increased = true
            } else if cost < observed {
                syncedCost = cost
            }
        }
        observedCost = cost
        if syncedCost == nil { syncedCost = cost }
        if increased, Date() < openCheckUntil {
            openCheckUntil = .distantPast
            isRefreshing = requestOfficial(.opened)
        }
        if launchSyncPending {
            launchSyncPending = false
            evaluateAutoSync(.resume)
        } else if increased {
            evaluateAutoSync(.tick)
        }
    }

    /// 上次官方同步之后，本机有没有新的 Token 消耗。
    /// 同时看两样：这次运行里累计消耗是否增加；最新一条记录是否晚于官方数据的获取时间（重启后也能判断）
    private func hasNewUsageSinceSync() -> Bool {
        guard let fetched = official.usage?.fetchedAt else { return true }
        if let cost = observedCost, let synced = syncedCost, cost > synced + 0.000_001 { return true }
        if let last = snapshot?.lastRecord, last > fetched { return true }
        return false
    }

    /// 最近一次消耗：会话记录的时间与看到累计消耗增加的时间，取较晚的一个
    private func consumptionActivity() -> AutoSyncPolicy.Activity {
        let cost = observedCost ?? 0
        return AutoSyncPolicy.Activity(
            claudeCodeRunning: false,
            lastConsumption: [snapshot?.lastRecord, lastCostIncrease].compactMap { $0 }.max(),
            unsyncedCost: max(0, cost - (syncedCost ?? cost)),
            hasNewUsage: hasNewUsageSinceSync()
        )
    }

    /// 自动查询：只有 Claude Code 正在使用（终端或桌面版）、出口可用时才会发出
    private func evaluateAutoSync(_ occasion: AutoSyncPolicy.Occasion) {
        guard prefs.officialUsageEnabled, official.state != .disabled else { return }
        let now = Date()
        var activity = consumptionActivity()
        // 最近没有消耗就不必再检查进程
        guard AutoSyncPolicy.hasRecentConsumption(activity, now: now) else { return }
        activity.claudeCodeRunning = claudeCodeRunning(now)
        guard AutoSyncPolicy.shouldSync(
            mode: prefs.autoSyncMode, occasion: occasion, activity: activity,
            lastRequest: official.lastAttempt, windowReset: official.windowHasReset(now), now: now
        ) else { return }
        guard !NetworkPlace.shared.blocksOfficialUsage else {
            // 出口还没确认，或上次确认时不可用：重新确认，变为可用后会再判断一次
            NetworkPlace.shared.refreshIfStale(maxAge: 60)
            return
        }
        requestOfficial(.auto)
    }

    /// 返回是否真的发出了查询
    @discardableResult
    private func requestOfficial(_ trigger: OfficialUsageService.Trigger) -> Bool {
        let cost = observedCost
        guard official.refresh(trigger) else { return false }
        requestCost = cost
        return true
    }

    /// 进程检查每 10 秒最多做一次
    private func claudeCodeRunning(_ now: Date) -> Bool {
        if let check = runningCheck, now.timeIntervalSince(check.at) < 10 { return check.running }
        let running = ClaudeProcesses.isClaudeCodeRunning()
        runningCheck = (now, running)
        return running
    }

    /// 出口确认完成：从不可用变为可用时，正在使用就查一次
    private func exitChecked() {
        let allowed = !NetworkPlace.shared.blocksOfficialUsage
        defer { exitWasAllowed = allowed }
        if allowed, !exitWasAllowed { evaluateAutoSync(.resume) }
    }
}
