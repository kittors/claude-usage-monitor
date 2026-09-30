import AppKit
import SwiftUI
import UsageCore

/// 菜单栏图标绘制（CoreGraphics 实时绘制矢量）。
/// 有官方用量时按占用上色；没有时用模板色，跟随菜单栏的深浅。
@MainActor
enum StatusIconRenderer {
    /// 菜单栏上的一个数值：小标签说明含义，数值本身按占用上色
    struct Value: Equatable {
        var label: String
        var text: String
        /// 限额的占用比例；费用为 nil（不上色）
        var fraction: Double?
        /// 整列的不透明度（设置页预览里突出某一列、或预览将要加入的一列）
        var emphasis: Double = 1
    }

    struct Input: Equatable {
        var icon: MenuBarIcon
        var style: MenuBarStyle
        /// 一个时单行显示；两个以上时每个数值一列，上面是小标签
        var values: [Value]
        /// 圆环 / 上方条：主指标占比
        var primary: Double
        /// 下方条：每周占比
        var secondary: Double
        /// 图标和数值的颜色。没有官方用量时为 nil。
        var fraction: Double?
        var pose: MascotPose = .idle
        /// 数值右侧的出口盾牌
        var showsSafety: Bool = false
        var exitSafe: Bool = false
        /// IPv6 直连。比普通不安全更重，盾牌用实心警示。
        var ipv6Direct: Bool = false
        /// 安全出口正在重新确认：盾牌轮廓不变，里面的勾换成同一套绿色的短弧。
        var shieldLoading: Bool = false
        var shieldPhase: CGFloat = 0
        /// 菜单栏是深色时，无用量的图标用白色
        var onDarkMenuBar: Bool = true
    }

    static func image(_ input: Input) -> NSImage {
        let glyph = glyphColor(input)
        let showsText = input.style == .iconPercent || input.style == .ringPercent
        let stacked = showsText && input.values.count > 1
        // 两行（小标签 + 数值）需要整条菜单栏的高度
        let height: CGFloat = stacked ? 22 : 18
        let top = (height - 18) / 2

        // 单行：只有一个数值
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: glyph]
        let text = showsText && !stacked ? (input.values.first?.text ?? "–") : nil
        let textSize = text.map { ($0 as NSString).size(withAttributes: attributes) } ?? .zero

        // 多列：每列上面是小标签，下面是数值，列内居中
        let columns = stacked ? input.values.map { Column($0, input: input) } : []
        let columnGap: CGFloat = 7

        let iconWidth: CGFloat = 16
        let shield: CGFloat = 13
        var width = iconWidth
        if text != nil { width += 4 + ceil(textSize.width) }
        if !columns.isEmpty { width += 5 + columns.reduce(0) { $0 + $1.width } + columnGap * CGFloat(columns.count - 1) }
        if input.style == .dualBars { width += 5 + 18 }
        if input.showsSafety { width += 4 + shield }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: top)
            if input.style == .ringPercent {
                drawRing(ctx, in: CGRect(x: 0, y: 1, width: 16, height: 16), fraction: input.primary, color: markColor(input.primary, input: input, fallback: glyph))
            } else {
                drawIcon(ctx, input.icon, pose: input.pose, color: glyph)
            }
            ctx.restoreGState()

            var cursor = iconWidth
            if let text {
                cursor += 4
                (text as NSString).draw(at: CGPoint(x: cursor, y: (height - textSize.height) / 2), withAttributes: attributes)
                cursor += ceil(textSize.width)
            }
            if !columns.isEmpty {
                cursor += 5
                for (index, column) in columns.enumerated() {
                    if index > 0 { cursor += columnGap }
                    column.draw(at: cursor, height: height)
                    cursor += column.width
                }
            }
            if input.style == .dualBars {
                let x = iconWidth + 5
                drawBar(ctx, CGRect(x: x, y: top + 5, width: 18, height: 3), fraction: input.primary, color: markColor(input.primary, input: input, fallback: glyph))
                drawBar(ctx, CGRect(x: x, y: top + 10, width: 18, height: 3), fraction: input.secondary, color: markColor(input.secondary, input: input, fallback: glyph))
                cursor = x + 18
            }
            if input.showsSafety {
                drawShield(
                    ctx,
                    in: CGRect(x: cursor + 4, y: (height - shield) / 2, width: shield, height: shield),
                    safe: input.exitSafe,
                    severe: input.ipv6Direct,
                    loading: input.shieldLoading,
                    phase: input.shieldPhase
                )
            }
            return true
        }
        image.isTemplate = input.fraction == nil && !input.showsSafety && input.values.allSatisfy { $0.fraction == nil }
        return image
    }

    /// 多个数值时的一列：小标签在上、数值在下，两行居中对齐
    private struct Column {
        let label: NSAttributedString
        let value: NSAttributedString
        let width: CGFloat

        init(_ item: Value, input: Input) {
            // 标签和费用用中性色（深色菜单栏为白、浅色为黑），只有限额的数值按占用上色
            let base = input.onDarkMenuBar ? NSColor.white : NSColor.black
            let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
            label = NSAttributedString(string: item.label, attributes: [
                .font: labelFont,
                .foregroundColor: base.withAlphaComponent(0.62 * item.emphasis),
                .kern: 0.2,
            ])
            let valueColor: NSColor = (item.fraction.map {
                let rgb = UsageTone.tone(for: $0).components
                return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            } ?? base).withAlphaComponent(item.emphasis)
            value = NSAttributedString(string: item.text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: valueColor,
            ])
            width = ceil(max(label.size().width, value.size().width))
        }

        func draw(at x: CGFloat, height: CGFloat) {
            let labelSize = label.size()
            let valueSize = value.size()
            label.draw(at: CGPoint(x: x + (width - labelSize.width) / 2, y: 0.5))
            value.draw(at: CGPoint(x: x + (width - valueSize.width) / 2, y: height - valueSize.height + 0.5))
        }
    }

    private static func glyphColor(_ input: Input) -> NSColor {
        guard let fraction = input.fraction else {
            return input.onDarkMenuBar ? .white : .black
        }
        let rgb = UsageTone.tone(for: fraction).components
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// 和面板图标同一套语言：圆角细线、浅填充。安全是勾，不安全是叹号。直连时填充加重。
    /// 确认中用警示红，勾的位置换成一段圆头短弧，大小和位置都不变。
    private static func drawShield(_ ctx: CGContext, in rect: CGRect, safe: Bool, severe: Bool, loading: Bool, phase: CGFloat) {
        let rgb = (safe && !severe && !loading ? UsageTone.calm : UsageTone.critical).components
        let color = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + 0.7))
        path.addLine(to: CGPoint(x: rect.maxX - 0.9, y: rect.minY + 2.6))
        path.addLine(to: CGPoint(x: rect.maxX - 0.9, y: rect.minY + rect.height * 0.52))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY - 0.55),
            control: CGPoint(x: rect.maxX - 1.1, y: rect.maxY - 1.5)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 0.9, y: rect.minY + rect.height * 0.52),
            control: CGPoint(x: rect.minX + 1.1, y: rect.maxY - 1.5)
        )
        path.addLine(to: CGPoint(x: rect.minX + 0.9, y: rect.minY + 2.6))
        path.closeSubpath()

        ctx.setLineWidth(severe ? 1.45 : 1.15)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.setFillColor(color.withAlphaComponent(severe ? 0.72 : 0.22).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.strokePath()

        if loading {
            let center = CGPoint(x: rect.midX, y: rect.midY + 0.35)
            let radius: CGFloat = 2.35
            ctx.setLineWidth(1.2)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(color.withAlphaComponent(0.28).cgColor)
            ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
            ctx.setStrokeColor(color.cgColor)
            let start = -CGFloat.pi / 2 + phase
            ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start + .pi * 1.25, clockwise: false)
            ctx.strokePath()
            return
        }
        if severe {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
        }
        if safe && !severe {
            ctx.move(to: CGPoint(x: rect.midX - 2.35, y: rect.midY - 0.15))
            ctx.addLine(to: CGPoint(x: rect.midX - 0.7, y: rect.midY + 1.55))
            ctx.addLine(to: CGPoint(x: rect.midX + 2.45, y: rect.midY - 1.85))
            ctx.strokePath()
        } else {
            ctx.move(to: CGPoint(x: rect.midX, y: rect.midY - 2.15))
            ctx.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 0.35))
            ctx.strokePath()
            if !severe { ctx.setFillColor(color.cgColor) }
            ctx.fillEllipse(in: CGRect(x: rect.midX - 0.7, y: rect.midY + 1.35, width: 1.4, height: 1.4))
        }
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

    private static func markColor(_ fraction: Double, input: Input, fallback: NSColor) -> NSColor {
        guard input.fraction != nil else { return fallback }
        let rgb = UsageTone.tone(for: fraction).components
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
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
