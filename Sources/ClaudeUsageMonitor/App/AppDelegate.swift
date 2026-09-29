import AppKit
import SwiftUI
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let prefs = Preferences.shared
    private(set) lazy var store = UsageStore(prefs: prefs)
    private var menuBar: MenuBarController?
    private let settings = SettingsWindowController()
    private let notifier = Notifier()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = MenuBarController(store: store, prefs: prefs) { [weak self] in
            self?.openSettings()
        }
        self.menuBar = menuBar
        store.onUpdate = { [weak self] in
            guard let self else { return }
            self.menuBar?.refresh()
            self.notifier.evaluate(self.store.limitRows, prefs: self.prefs)
        }
        store.start()

        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { menuBar.show() }
        }
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.openSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
    }

    func openSettings() {
        settings.show(prefs: prefs, store: store)
    }
}

/// 设置窗口：透明标题栏 + 暗色毛玻璃。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(prefs: Preferences, store: UsageStore) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Claude Usage Monitor 设置"
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.delegate = self
            let host = NSHostingView(rootView: SettingsView(prefs: prefs, store: store))
            host.sizingOptions = []
            window.contentView = host
            window.center()
            self.window = window
        }
        // 菜单栏 App 从非激活面板打开窗口时，协作式激活可能不会让出前台，需要显式置前
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
