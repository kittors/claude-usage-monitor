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
        for (name, input) in [
            ("menubar-mascot", StatusIconRenderer.Input(icon: .mascot, style: .iconPercent, text: "71%", primary: 0.71, secondary: 0.65, level: .normal)),
            ("menubar-mascot-armsup", StatusIconRenderer.Input(icon: .mascot, style: .iconPercent, text: "71%", primary: 0.71, secondary: 0.65, level: .normal, pose: .armsUp)),
            ("menubar-logo", StatusIconRenderer.Input(icon: .logo, style: .iconPercent, text: "71%", primary: 0.71, secondary: 0.65, level: .normal)),
            ("menubar-ring", StatusIconRenderer.Input(icon: .mascot, style: .ringPercent, text: "71%", primary: 0.71, secondary: 0.65, level: .normal)),
            ("menubar-bars-warning", StatusIconRenderer.Input(icon: .mascot, style: .dualBars, text: nil, primary: 0.86, secondary: 0.65, level: .warning)),
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
            NSColor.white.setFill()
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
