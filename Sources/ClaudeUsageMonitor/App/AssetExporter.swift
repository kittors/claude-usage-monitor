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
        for (name, input) in [
            ("menubar-mascot", StatusIconRenderer.Input(icon: .mascot, style: .iconPercent, values: one, primary: 0.71, secondary: 0.65, fraction: 0.71)),
            ("menubar-mascot-armsup", StatusIconRenderer.Input(icon: .mascot, style: .iconPercent, values: one, primary: 0.71, secondary: 0.65, fraction: 0.71, pose: .armsUp)),
            ("menubar-logo", StatusIconRenderer.Input(icon: .logo, style: .iconPercent, values: one, primary: 0.71, secondary: 0.65, fraction: 0.71)),
            ("menubar-ring", StatusIconRenderer.Input(icon: .mascot, style: .ringPercent, values: one, primary: 0.71, secondary: 0.65, fraction: 0.71)),
            ("menubar-bars-warning", StatusIconRenderer.Input(icon: .mascot, style: .dualBars, values: [], primary: 0.86, secondary: 0.65, fraction: 0.86)),
            ("menubar-stacked", StatusIconRenderer.Input(icon: .mascot, style: .iconPercent, values: several, primary: 0.04, secondary: 0.98, fraction: 0.98, showsSafety: true, exitSafe: true, onDarkMenuBar: false)),
            ("menubar-stacked-dark", StatusIconRenderer.Input(icon: .mascot, style: .iconPercent, values: several, primary: 0.04, secondary: 0.98, fraction: 0.98, showsSafety: true, exitSafe: true, onDarkMenuBar: true)),
            ("menubar-stacked-en-dark", StatusIconRenderer.Input(icon: .logo, style: .iconPercent, values: english, primary: 0.04, secondary: 0.98, fraction: 0.98, onDarkMenuBar: true)),
        ] {
            let image = StatusIconRenderer.image(input)
            let scale: CGFloat = 4
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            (name.hasSuffix("-dark") ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
            NSRect(origin: .zero, size: image.size).fill()
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }

        try? ClaudeBrand.logoSVG.write(to: dir.appendingPathComponent("claude-logo.svg"), atomically: true, encoding: .utf8)
        let iconsDir = dir.appendingPathComponent("Icons")
        try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
        for icon in Icon.allCases {
            try? icon.markup.write(to: iconsDir.appendingPathComponent("\(icon.rawValue).svg"), atomically: true, encoding: .utf8)
        }
        print("exported to \(dir.path)")
    }
}
