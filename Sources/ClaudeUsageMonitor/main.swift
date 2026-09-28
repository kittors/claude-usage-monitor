import AppKit

MainActor.assumeIsolated {
    // 构建脚本使用：导出 App 图标与 Logo SVG
    if let i = CommandLine.arguments.firstIndex(of: "--export-assets") {
        let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "."
        AssetExporter.export(to: URL(fileURLWithPath: dir))
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
