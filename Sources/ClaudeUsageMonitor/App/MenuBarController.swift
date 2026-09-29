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
    /// 内容变矮时，等收起动画播完再缩小窗口
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
        menu.addItem(item(L10n.t("打开用量面板", "Open usage"), .gauge, "", #selector(menuOpen)))
        menu.addItem(item(L10n.t("立即刷新", "Refresh"), .refresh, "r", #selector(menuRefresh)))
        menu.addItem(.separator())
        menu.addItem(item(L10n.t("设置…", "Settings…"), .sliders, ",", #selector(menuSettings)))
        menu.addItem(item(L10n.t("退出 Claude Usage Monitor", "Quit Claude Usage Monitor"), .power, "q", #selector(menuQuit)))
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
            _ = prefs.showExitSafety
            _ = prefs.warningThreshold
            _ = NetworkPlace.shared.place
            _ = NetworkPlace.shared.ipv6
            _ = NetworkPlace.shared.failed
            _ = prefs.currency
            _ = ExchangeRates.shared.fetchedAt
            _ = Localization.shared.token
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
        let fraction: Double? = (five == nil && week == nil) ? nil : {
            switch prefs.menuBarMetric {
            case .fiveHour: five?.fraction ?? worst
            case .weekly: week?.fraction ?? worst
            default: worst
            }
        }()
        let network = NetworkPlace.shared
        let known = network.place != nil || network.failed
        let input = StatusIconRenderer.Input(
            icon: prefs.menuBarIcon, style: prefs.menuBarStyle, text: text ?? "–",
            primary: primary, secondary: week?.fraction ?? 0, fraction: fraction,
            pose: iconInput?.pose ?? .idle,
            showsSafety: (prefs.showExitSafety && known) || network.ipv6IsDirect,
            exitSafe: network.exitIsSafe,
            ipv6Direct: network.ipv6IsDirect,
            onDarkMenuBar: menuBarIsDark
        )
        iconInput = input
        statusItem.button?.image = StatusIconRenderer.image(input)
        var tip: [String] = []
        if let five, let week {
            tip.append(L10n.t("5 小时 \(five.percent)% · 本周 \(week.percent)%", "5-hour \(five.percent)% · Week \(week.percent)%"))
        } else if let five {
            tip.append(L10n.t("5 小时 \(five.percent)%", "5-hour \(five.percent)%"))
        } else if prefs.officialUsageEnabled {
            tip.append(L10n.t("官方用量：\(LimitsSection.shortReason(store.official.state))", "Official usage: \(LimitsSection.shortReason(store.official.state))"))
        }
        if let weekCost = snap?.week { tip.append(L10n.t("本周 \(money.string(weekCost.cost))", "This week \(money.string(weekCost.cost))")) }
        if network.ipv6IsDirect {
            tip.append(L10n.t("严重警告：IPv6 直连中国大陆、香港或澳门", "Severe warning: IPv6 connects directly from mainland China, Hong Kong, or Macau"))
        } else if prefs.showExitSafety, known {
            tip.append(network.exitIsSafe
                ? L10n.t("出口安全", "Exit is safe")
                : L10n.t("出口不安全", "Exit is not safe"))
        }
        statusItem.button?.toolTip = tip.isEmpty ? "Claude Usage Monitor" : tip.joined(separator: " · ")
    }

    private var menuBarIsDark: Bool {
        statusItem.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
        // SwiftUI 画布的高度固定、贴住窗口顶部，窗口变高变矮都不会让 SwiftUI 重新布局。
        // 否则每次改窗口尺寸都会打断正在进行的展开、收起动画，内容直接跳到终点。
        hosting.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: canvasHeight())
        hosting.autoresizingMask = [.width, .maxYMargin]
        let container = TopAnchoredView(frame: NSRect(origin: .zero, size: contentSize))
        container.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        // 先查一次，第一次打开面板时进程一栏就在，不会晚一拍再冒出来
        ClaudeProcesses.shared.refresh()
    }

    /// 画布高度：面板最高能长到的高度（屏幕可用高度加上阴影边距）
    private func canvasHeight() -> CGFloat {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        return (screen?.visibleFrame.height ?? 900) + Metrics.shadowInset * 2
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
        let canvas = canvasHeight()
        if abs(hosting.frame.height - canvas) > 0.5 {
            hosting.frame = NSRect(x: 0, y: 0, width: hosting.frame.width, height: canvas)
        }
        shrinkWork?.cancel()
        shrinkWork = nil
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

    /// 这里拿到的是动画终点的尺寸。SwiftUI 画布不随窗口变化，所以：
    /// 变高时立刻加高窗口，给展开动画留出位置；变矮时等收起动画播完再缩小，避免还没收完的内容被窗口截断。
    private func contentSizeChanged(_ size: CGSize) {
        guard size.height > 10 else { return }
        shrinkWork?.cancel()
        shrinkWork = nil
        guard abs(size.height - contentSize.height) > 0.5 else { return }
        if size.height > contentSize.height || !panel.isVisible {
            contentSize.height = size.height
            layoutPanel()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.shrinkWork = nil
            self.contentSize.height = size.height
            self.layoutPanel()
        }
        shrinkWork = work
        // 比展开、收起动画（`Animation.disclosure`）稍长
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
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
        let frame = NSRect(x: x, y: top - height, width: width, height: height)
        guard frame != panel.frame else { return }
        // 画布贴着窗口顶部、大小不变，改窗口尺寸只是露出或遮住下方透明的部分
        panel.setFrame(frame, display: false)
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

/// 面板的内容视图：坐标从左上角算起，窗口高度变化时里面的 SwiftUI 画布原地不动
private final class TopAnchoredView: NSView {
    override var isFlipped: Bool { true }
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
        panel.prompt = L10n.t("使用此目录", "Use this folder")
        panel.message = L10n.t("选择 Claude Code 的会话目录（通常是 ~/.claude/projects）", "Choose the Claude Code session folder (usually ~/.claude/projects)")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            prefs.dataDirectory = url.path
        }
    }
}
