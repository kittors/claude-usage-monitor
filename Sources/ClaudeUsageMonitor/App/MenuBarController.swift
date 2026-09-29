import AppKit
import SwiftUI
import UsageCore

/// 管理状态栏图标与弹窗面板。
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = PopoverPanel()
    private let presentation = PanelPresentation()
    private let store: UsageStore
    private let prefs: Preferences
    private let openSettings: () -> Void

    private var hosting: NSHostingView<PopoverView>!
    private var contentSize = CGSize(width: Metrics.popoverWidth + Metrics.shadowInset * 2, height: 760)
    private var anchor: NSRect = .zero
    private var monitors: [Any] = []
    private var shrinkWork: DispatchWorkItem?
    /// 最近一次因「点击外部」而收起的时间
    private var lastOutsideClick = Date.distantPast

    // 状态栏图标动画
    private var iconInput: StatusIconRenderer.Input?
    private var poseReset: DispatchWorkItem?
    private var lastPulse = 0

    var isOpen: Bool { presentation.isVisible }

    init(store: UsageStore, prefs: Preferences, openSettings: @escaping () -> Void) {
        self.store = store
        self.prefs = prefs
        self.openSettings = openSettings
        super.init()
        setupStatusItem()
        setupPanel()
        observeIconInputs()
    }

    // MARK: 状态栏

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.toolTip = "Claude Usage Monitor"
        renderIcon()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            hide()
            showContextMenu()
        } else {
            toggle()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)
        func item(_ title: String, _ icon: Icon, _ key: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.image = icon.nsImage(size: 15)
            return item
        }
        menu.addItem(item("打开用量面板", .gauge, "", #selector(menuOpen)))
        menu.addItem(item("立即刷新", .refresh, "r", #selector(menuRefresh)))
        menu.addItem(.separator())
        menu.addItem(item("设置…", .sliders, ",", #selector(menuSettings)))
        menu.addItem(item("退出 Claude Usage Monitor", .power, "q", #selector(menuQuit)))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpen() { show() }
    @objc private func menuRefresh() { store.refreshNow() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    /// 本机数据或官方数据有更新时刷新状态栏图标
    func refresh() {
        renderIcon()
    }

    private func observeIconInputs() {
        withObservationTracking {
            _ = prefs.menuBarIcon
            _ = prefs.menuBarStyle
            _ = prefs.menuBarMetric
            _ = prefs.warningThreshold
            _ = prefs.currency
            _ = prefs.exchangeRate
            _ = store.pulse
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.store.pulse != self.lastPulse {
                    self.lastPulse = self.store.pulse
                    self.cheer()
                }
                self.renderIcon()
                self.observeIconInputs()
            }
        }
    }

    private func renderIcon() {
        let snap = store.snapshot
        // 百分比只用官方数据：没有官方数据时显示「–」，不做估算
        let rows = store.limitRows
        let five = rows.first { $0.id == "five" }
        let week = rows.first { $0.id == "week" }
        let money = prefs.money
        let text: String? = switch prefs.menuBarMetric {
        case .fiveHour: five.map { "\($0.percent)%" }
        case .weekly: week.map { "\($0.percent)%" }
        case .today: snap.map { money.compact($0.day.cost) }
        case .week: snap?.week.map { money.compact($0.cost) }
        case .cycle: snap.map { money.compact($0.billing.cost) }
        }
        let primary = (prefs.menuBarMetric == .weekly ? week : five)?.fraction ?? 0
        let worst = max(five?.fraction ?? 0, week?.fraction ?? 0)
        let level: StatusIconRenderer.Level = worst >= 0.95 ? .critical : (worst >= prefs.warningThreshold ? .warning : .normal)
        let input = StatusIconRenderer.Input(
            icon: prefs.menuBarIcon, style: prefs.menuBarStyle, text: text ?? "–",
            primary: primary, secondary: week?.fraction ?? 0, level: level, pose: iconInput?.pose ?? .idle
        )
        iconInput = input
        statusItem.button?.image = StatusIconRenderer.image(input)
        var tip: [String] = []
        if let five, let week {
            tip.append("5 小时 \(five.percent)% · 本周 \(week.percent)%")
        } else if let five {
            tip.append("5 小时 \(five.percent)%")
        } else if prefs.officialUsageEnabled {
            tip.append("官方用量：\(LimitsSection.shortReason(store.official.state))")
        }
        if let weekCost = snap?.week { tip.append("本周 \(money.string(weekCost.cost))") }
        statusItem.button?.toolTip = tip.isEmpty ? "Claude Usage Monitor" : tip.joined(separator: " · ")
    }

    /// 有新数据时 Clawd 举一下手
    private func cheer() {
        guard var input = iconInput, input.icon == .mascot else { return }
        poseReset?.cancel()
        input.pose = .armsUp
        iconInput = input
        statusItem.button?.image = StatusIconRenderer.image(input)
        let work = DispatchWorkItem { [weak self] in
            guard let self, var input = self.iconInput else { return }
            input.pose = .idle
            self.iconInput = input
            self.statusItem.button?.image = StatusIconRenderer.image(input)
        }
        poseReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    // MARK: 面板

    private func setupPanel() {
        let actions = PopoverActions(
            openSettings: { [weak self] in
                self?.hide()
                self?.openSettings()
            },
            quit: { NSApp.terminate(nil) },
            chooseDataDirectory: { [weak self] in
                self?.hide()
                DataDirectoryPicker.choose(prefs: self?.prefs)
            }
        )
        let root = PopoverView(store: store, prefs: prefs, presentation: presentation, actions: actions) { [weak self] size in
            self?.contentSizeChanged(size)
        }
        hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    func toggle() {
        if presentation.isVisible {
            hide()
        } else if Date().timeIntervalSince(lastOutsideClick) > 0.4 {
            // 兜底：按下图标时若已被当作外部点击收起，松手时不再重新打开
            show()
        }
    }

    func show() {
        guard let button = statusItem.button, let window = button.window else { return }
        anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        layoutPanel()
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
        installMonitors()
        store.panelOpened()
        DispatchQueue.main.async { self.presentation.isVisible = true }
    }

    func hide() {
        guard presentation.isVisible else { return }
        presentation.isVisible = false
        statusItem.button?.highlight(false)
        removeMonitors()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, !self.presentation.isVisible else { return }
            self.panel.orderOut(nil)
        }
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard size.height > 10 else { return }
        let grew = size.height > contentSize.height
        shrinkWork?.cancel()
        if grew || !panel.isVisible {
            contentSize.height = size.height
            layoutPanel()
        } else {
            // 等 SwiftUI 收起动画结束再缩小窗口，避免内容被截断
            let work = DispatchWorkItem { [weak self] in
                self?.contentSize.height = size.height
                self?.layoutPanel()
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private func layoutPanel() {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let inset = Metrics.shadowInset
        let width = contentSize.width
        let height = min(contentSize.height, visible.height + inset)
        let anchorPoint = anchor == .zero ? NSPoint(x: visible.maxX - 200, y: visible.maxY) : NSPoint(x: anchor.midX, y: anchor.minY)
        var x = anchorPoint.x - width / 2
        x = min(max(x, visible.minX - inset + 6), visible.maxX - width + inset - 6)
        let top = anchorPoint.y - 5 + inset
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
    }

    // MARK: 事件监听

    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { monitors.append(global) }

        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown], handler: { [weak self] event in
            let info = LocalEvent(event)
            let consumed = MainActor.assumeIsolated { self?.handleLocal(info) ?? false }
            return consumed ? nil : event
        }) { monitors.append(local) }
    }

    /// 点击落在状态栏图标上时交给按钮自己切换，否则会「按下时收起、松手时又打开」
    private func clickedOutside() {
        if isOnStatusItem(NSEvent.mouseLocation) { return }
        lastOutsideClick = Date()
        hide()
    }

    private func isOnStatusItem(_ point: NSPoint) -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return frame.insetBy(dx: -2, dy: -2).contains(point)
    }

    /// 返回 true 表示事件已处理、不再继续分发
    private func handleLocal(_ event: LocalEvent) -> Bool {
        if event.isMouseDown {
            // 下拉菜单是另一扇窗口，点菜单项不能当成点到面板外面
            if event.windowNumber != panel.windowNumber, !Self.isMenuWindow(event.windowNumber) { clickedOutside() }
            return false
        }
        if event.keyCode == 53 {  // Esc
            hide()
            return true
        }
        guard event.command else { return false }
        switch event.key {
        case "r": store.refreshNow()
        case ",": hide(); openSettings()
        case "w": hide()
        case "q": NSApp.terminate(nil)
        default: return false
        }
        return true
    }

    private static func isMenuWindow(_ number: Int) -> Bool {
        guard let window = NSApp.window(withWindowNumber: number) else { return false }
        return String(describing: type(of: window)).contains("Menu")
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}

/// 本地事件监听中需要的字段（`NSEvent` 不是 Sendable，不能直接带进主线程隔离的闭包）
private struct LocalEvent: Sendable {
    let isMouseDown: Bool
    let windowNumber: Int
    let keyCode: UInt16
    let command: Bool
    let key: String?

    init(_ event: NSEvent) {
        isMouseDown = event.type == .leftMouseDown
        windowNumber = event.windowNumber
        keyCode = isMouseDown ? 0 : event.keyCode
        command = event.modifierFlags.contains(.command)
        key = isMouseDown ? nil : event.charactersIgnoringModifiers?.lowercased()
    }
}

/// 选择数据目录
@MainActor
enum DataDirectoryPicker {
    static func choose(prefs: Preferences?) {
        guard let prefs else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "使用此目录"
        panel.message = "选择 Claude Code 的会话目录（通常是 ~/.claude/projects）"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            prefs.dataDirectory = url.path
        }
    }
}
