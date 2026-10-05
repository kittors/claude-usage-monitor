import AppKit
import SwiftUI

/// App 图标（1024 画布，遵循 macOS 图标网格：824 主体 + 100 边距）：深色底 + 微微倾斜的 Clawd。
struct AppIconView: View {
    var body: some View {
        let body = RoundedRectangle(cornerRadius: 186, style: .continuous)
        ZStack {
            body
                .fill(LinearGradient(colors: [Color(hex: 0x2A2826), Color(hex: 0x1E1D1B)], startPoint: .top, endPoint: .bottom))
                .overlay {
                    body.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 3
                    )
                }
                .shadow(color: .black.opacity(0.3), radius: 18, x: 0, y: 12)
                .frame(width: 824, height: 824)
            MascotView(width: 560)
                .rotationEffect(.degrees(-6))
                .offset(y: 10)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
enum AssetExporter {
    static func export(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = 1
        renderer.isOpaque = false
        if let cg = renderer.cgImage,
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("AppIcon-1024.png"))
        }

        // 菜单栏图标预览（@4x，便于检查像素对齐）
        typealias Value = StatusIconRenderer.Value
        let one = [Value(label: "5小时", text: "71%", fraction: 0.71)]
        let several = [
            Value(label: "5小时", text: "4%", fraction: 0.04),
            Value(label: "本周", text: "98%", fraction: 0.98),
            Value(label: "Fable", text: "0%", fraction: 0),
            Value(label: "今日", text: "$776", fraction: nil),
        ]
        let english = [
            Value(label: "5H", text: "4%", fraction: 0.04),
            Value(label: "WEEK", text: "98%", fraction: 0.98),
            Value(label: "FABLE", text: "0%", fraction: 0),
        ]
        typealias Input = StatusIconRenderer.Input
        let holding = MascotFrame(pose: .front(arms: .oneUp))
        func shield(_ name: String, safe: Bool = false, severe: Bool = false, loading: Bool = false, dark: Bool) -> (String, Input) {
            (name, Input(
                icon: .mascot, style: .iconPercent, values: one, primary: 0.71, secondary: 0.65, fraction: 0.71, frame: holding,
                showsSafety: true, exitSafe: safe, ipv6Direct: severe, shieldLoading: loading, shieldPhase: .pi / 3, onDarkMenuBar: dark
            ))
        }
        let previews: [(String, Input)] = [
            ("menubar-mascot", Input(icon: .mascot, style: .iconPercent, values: one, primary: 0.71, secondary: 0.65, fraction: 0.71)),
            ("menubar-mascot-armsup", Input(icon: .mascot, style: .iconPercent, values: one, primary: 0.71, secondary: 0.65, fraction: 0.71, frame: MascotFrame(pose: .armsUp))),
            ("menubar-logo", Input(icon: .logo, style: .iconPercent, values: one, primary: 0.71, secondary: 0.65, fraction: 0.71)),
            ("menubar-logo-shield", Input(icon: .logo, style: .iconPercent, values: one, primary: 0.71, secondary: 0.65, fraction: 0.71, showsSafety: true, exitSafe: true)),
            ("menubar-ring", Input(icon: .mascot, style: .ringPercent, values: one, primary: 0.71, secondary: 0.65, fraction: 0.71)),
            ("menubar-bars-warning", Input(icon: .mascot, style: .dualBars, values: [], primary: 0.86, secondary: 0.65, fraction: 0.86)),
            shield("menubar-shield-safe", safe: true, dark: false),
            shield("menubar-shield-safe-dark", safe: true, dark: true),
            shield("menubar-shield-risk-dark", dark: true),
            shield("menubar-shield-severe-dark", severe: true, dark: true),
            shield("menubar-shield-loading-dark", loading: true, dark: true),
            ("menubar-shield-no-usage-dark", Input(icon: .mascot, style: .icon, values: [], primary: 0, secondary: 0, fraction: nil, frame: holding, showsSafety: true, exitSafe: true)),
            ("menubar-stacked", Input(icon: .mascot, style: .iconPercent, values: several, primary: 0.04, secondary: 0.98, fraction: 0.98, frame: holding, showsSafety: true, exitSafe: true, onDarkMenuBar: false)),
            ("menubar-stacked-dark", Input(icon: .mascot, style: .iconPercent, values: several, primary: 0.04, secondary: 0.98, fraction: 0.98, frame: holding, showsSafety: true, exitSafe: true, onDarkMenuBar: true)),
            ("menubar-stacked-en-dark", Input(icon: .logo, style: .iconPercent, values: english, primary: 0.04, secondary: 0.98, fraction: 0.98, onDarkMenuBar: true)),
        ]
        for (name, input) in previews {
            let image = StatusIconRenderer.image(input)
            write(snapshot([[image]], gap: 0, dark: name.hasSuffix("-dark")), to: dir.appendingPathComponent("\(name).png"))
        }

        // 官方动画逐帧：每段一行，Clawd 拿着安全盾牌
        let base = Input(icon: .mascot, style: .icon, values: [], primary: 0, secondary: 0, fraction: 0.3, showsSafety: true, exitSafe: true)
        var sequences: [[MascotFrame]] = [[holding] + MascotAnimation.blink(holding)]
        sequences += MascotAnimation.allCases.map(\.frames)
        let rows: [[NSImage]] = sequences.map { frames in
            frames.map { frame -> NSImage in
                var input = base
                input.frame = frame == .rest ? holding : frame
                return StatusIconRenderer.image(input)
            }
        }
        write(snapshot(rows, gap: 3, dark: true), to: dir.appendingPathComponent("mascot-animations.png"))

        try? ClaudeBrand.logoSVG.write(to: dir.appendingPathComponent("claude-logo.svg"), atomically: true, encoding: .utf8)
        let iconsDir = dir.appendingPathComponent("Icons")
        try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
        for icon in Icon.allCases {
            try? icon.markup.write(to: iconsDir.appendingPathComponent("\(icon.rawValue).svg"), atomically: true, encoding: .utf8)
        }
        print("exported to \(dir.path)")
    }

    /// 把若干行图片按 @4x 拼成一张（便于检查像素对齐）
    private static func snapshot(_ rows: [[NSImage]], gap: CGFloat, dark: Bool) -> NSBitmapImageRep? {
        let cell = rows.flatMap { $0 }.reduce(NSSize.zero) { NSSize(width: max($0.width, $1.size.width), height: max($0.height, $1.size.height)) }
        let columns = rows.map(\.count).max() ?? 0
        let size = NSSize(
            width: CGFloat(columns) * cell.width + CGFloat(max(0, columns - 1)) * gap,
            height: CGFloat(rows.count) * cell.height + CGFloat(max(0, rows.count - 1)) * gap
        )
        let scale: CGFloat = 4
        guard size.width > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
        NSRect(origin: .zero, size: size).fill()
        for (r, row) in rows.enumerated() {
            for (c, image) in row.enumerated() {
                let origin = NSPoint(x: CGFloat(c) * (cell.width + gap), y: size.height - CGFloat(r + 1) * cell.height - CGFloat(r) * gap)
                image.draw(in: NSRect(origin: origin, size: image.size))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep?, to url: URL) {
        try? rep?.representation(using: .png, properties: [:])?.write(to: url)
    }
}
