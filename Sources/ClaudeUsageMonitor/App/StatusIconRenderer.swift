import AppKit
import SwiftUI

/// 菜单栏图标绘制（CoreGraphics 实时绘制矢量）。
/// 低于预警阈值时为模板图像（自动适配浅色 / 深色菜单栏），超过阈值时变为警示色。
@MainActor
enum StatusIconRenderer {
    enum Level { case normal, warning, critical }

    struct Input: Equatable {
        var icon: MenuBarIcon
        var style: MenuBarStyle
        var text: String?
        /// 圆环 / 上方条：主指标占比
        var primary: Double
        /// 下方条：每周占比
        var secondary: Double
        var level: Level
        var pose: MascotPose = .idle
    }

    static func image(_ input: Input) -> NSImage {
        let height: CGFloat = 18
        let color: NSColor = switch input.level {
        case .normal: .black
        case .warning: NSColor(red: 0.89, green: 0.64, blue: 0.29, alpha: 1)
        case .critical: NSColor(red: 0.9, green: 0.35, blue: 0.31, alpha: 1)
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let showsText = input.style == .iconPercent || input.style == .ringPercent
        let text = showsText ? (input.text ?? "–") : nil
        let textSize = text.map { ($0 as NSString).size(withAttributes: attributes) } ?? .zero

        let iconWidth: CGFloat = 16
        var width = iconWidth
        if text != nil { width += 4 + ceil(textSize.width) }
        if input.style == .dualBars { width += 5 + 18 }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(color.cgColor)

            if input.style == .ringPercent {
                drawRing(ctx, in: CGRect(x: 0, y: 1, width: 16, height: 16), fraction: input.primary, color: color)
            } else {
                drawIcon(ctx, input.icon, pose: input.pose, color: color)
            }

            if let text {
                (text as NSString).draw(at: CGPoint(x: iconWidth + 4, y: (height - textSize.height) / 2), withAttributes: attributes)
            }
            if input.style == .dualBars {
                let x = iconWidth + 5
                drawBar(ctx, CGRect(x: x, y: 5, width: 18, height: 3), fraction: input.primary, color: color)
                drawBar(ctx, CGRect(x: x, y: 10, width: 18, height: 3), fraction: input.secondary, color: color)
            }
            return true
        }
        image.isTemplate = input.level == .normal
        return image
    }

    private static func drawIcon(_ ctx: CGContext, _ icon: MenuBarIcon, pose: MascotPose, color: NSColor) {
        ctx.setFillColor(color.cgColor)
        switch icon {
        case .mascot:
            // 1pt × 2pt 的整数像素，Retina 下边缘锐利
            let path = Mascot.path(pose, in: CGRect(x: 0, y: 4, width: 16, height: 10), pixelAspect: 2)
            ctx.addPath(path.cgPath)
        case .logo:
            let rect = CGRect(x: 0.5, y: 1.5, width: 15, height: 15)
            let path = SVGShape(path: ClaudeBrand.logoPath, viewBox: ClaudeBrand.logoViewBox).path(in: rect)
            ctx.addPath(path.cgPath)
        }
        ctx.fillPath()
    }

    private static func drawRing(_ ctx: CGContext, in rect: CGRect, fraction: Double, color: NSColor) {
        let lineWidth: CGFloat = 2.2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2 - lineWidth / 2 - 0.5
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color.withAlphaComponent(0.25).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        let f = min(1, max(0, fraction))
        guard f > 0.005 else { return }
        ctx.setStrokeColor(color.cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * f, clockwise: false)
        ctx.strokePath()
    }

    private static func drawBar(_ ctx: CGContext, _ rect: CGRect, fraction: Double, color: NSColor) {
        let radius = rect.height / 2
        ctx.setFillColor(color.withAlphaComponent(0.25).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        let f = min(1, max(0, fraction))
        guard f > 0.01 else { return }
        var fill = rect
        fill.size.width = max(rect.height, rect.width * f)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: fill, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }
}
