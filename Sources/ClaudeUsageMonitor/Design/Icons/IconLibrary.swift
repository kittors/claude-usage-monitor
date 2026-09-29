import SwiftUI

/// 原创矢量图标库。每个图标都是一段标准 SVG（24×24 网格，1.7 线宽，圆角端点），
/// 半透明填充部分构成双色调效果。运行时由 `SVGDocument` 解析为 `Path` 绘制。
enum Icon: String, CaseIterable {
    case layers, gauge, hourglass, calendar, receipt, history
    case arrowIn, arrowOut, cacheWrite, bolt, target, leaf
    case chart, pie, sliders, refresh, power, folder
    case crown, star, users, diamond, coin, bell, rocket, info
    case chevronDown, chevronLeft, chevronRight, check, close, plus, minus
    case cpu, flame, sparkles, terminal, branch, warning, clock, globe
    case pulse, menuBar, crosshair, database, external, wand, trendUp
    case message, hexagon, upgrade

    var markup: String {
        let body: String
        switch self {
        case .layers: body = """
            <path d="M12 3.2 3.4 7.6 12 12l8.6-4.4L12 3.2Z" fill="currentColor" fill-opacity=".22"/>
            <path d="m3.4 12 8.6 4.4 8.6-4.4"/>
            <path d="m3.4 16.4 8.6 4.4 8.6-4.4"/>
            """
        case .gauge: body = """
            <path d="M4.3 18a8.6 8.6 0 1 1 15.4 0"/>
            <path d="M12 6.4v1.4M6.5 8.7l1 1M17.5 8.7l-1 1" stroke-opacity=".5"/>
            <path d="m12 14.2 3.6-4.4"/>
            <circle cx="12" cy="14.2" r="1.9" fill="currentColor" stroke="none"/>
            """
        case .hourglass: body = """
            <path d="M6.5 3.5h11M6.5 20.5h11"/>
            <path d="M8 3.5v2.3c0 1.6.8 3 2.1 3.9L12 11l1.9-1.3A4.7 4.7 0 0 0 16 5.8V3.5"/>
            <path d="M8 20.5v-2.3c0-1.6.8-3 2.1-3.9L12 13l1.9 1.3a4.7 4.7 0 0 1 2.1 3.9v2.3"/>
            <path d="M9.4 19.3c0-1.4 1.2-2.4 2.6-2.4s2.6 1 2.6 2.4Z" fill="currentColor" fill-opacity=".5" stroke="none"/>
            """
        case .calendar: body = """
            <rect x="3.5" y="5" width="17" height="15.5" rx="3.6" fill="currentColor" fill-opacity=".1"/>
            <path d="M3.5 9.8h17"/>
            <path d="M8 3v3.6M16 3v3.6"/>
            <rect x="7" y="13" width="3.4" height="3.4" rx="1" fill="currentColor" stroke="none"/>
            <path d="M13.6 14.7h3.4" stroke-opacity=".5"/>
            """
        case .receipt: body = """
            <path d="M5.5 20.5V4.4a1.2 1.2 0 0 1 1.2-1.2h10.6a1.2 1.2 0 0 1 1.2 1.2v16.1l-1.63-1.4-1.62 1.4-1.63-1.4-1.62 1.4-1.63-1.4-1.62 1.4-1.63-1.4-1.62 1.4Z" fill="currentColor" fill-opacity=".14"/>
            <path d="M9 8h6M9 11.5h6M9 15h3.4"/>
            """
        case .history: body = """
            <path d="M4.4 12a7.8 7.8 0 1 0 2.3-5.5L4.4 8.8"/>
            <path d="M4.4 4.6v4.2h4.2"/>
            <path d="M12 8v4.2l2.8 1.8"/>
            """
        case .arrowIn: body = """
            <path d="M12 3.5v10.2"/>
            <path d="m7.8 9.6 4.2 4.2 4.2-4.2"/>
            <path d="M4 14.8v2.4a3.3 3.3 0 0 0 3.3 3.3h9.4a3.3 3.3 0 0 0 3.3-3.3v-2.4"/>
            """
        case .arrowOut: body = """
            <path d="M12 14V3.8"/>
            <path d="m7.8 8 4.2-4.2L16.2 8"/>
            <path d="M4 14.8v2.4a3.3 3.3 0 0 0 3.3 3.3h9.4a3.3 3.3 0 0 0 3.3-3.3v-2.4"/>
            """
        case .cacheWrite: body = """
            <ellipse cx="10.5" cy="5.8" rx="6.5" ry="2.6" fill="currentColor" fill-opacity=".22"/>
            <path d="M4 5.8v5.6c0 1.44 2.9 2.6 6.5 2.6 1.2 0 2.3-.13 3.3-.36"/>
            <path d="M17 5.8v4.4"/>
            <path d="M4 11.4V17c0 1.44 2.9 2.6 6.5 2.6"/>
            <path d="M18 14v6M15 17h6"/>
            """
        case .bolt: body = """
            <path d="M13.2 2.8 5.4 13.2h6.1l-1 8 7.9-10.6h-6.1l.9-7.8Z" fill="currentColor" fill-opacity=".24"/>
            """
        case .target: body = """
            <circle cx="12" cy="12" r="8.6"/>
            <circle cx="12" cy="12" r="4.9" stroke-opacity=".6"/>
            <circle cx="12" cy="12" r="1.8" fill="currentColor" stroke="none"/>
            """
        case .leaf: body = """
            <path d="M5 19c0-8.3 5.2-13.4 14.4-14 .4 9.4-4.9 14.6-13.2 14.6" fill="currentColor" fill-opacity=".2"/>
            <path d="M5 19c2.6-3.8 5.8-6.8 9.4-8.8"/>
            """
        case .chart: body = """
            <path d="M3.8 20.2h16.4"/>
            <rect x="5.6" y="11.4" width="3" height="5.8" rx="1.1" fill="currentColor" fill-opacity=".22"/>
            <rect x="10.5" y="5.6" width="3" height="11.6" rx="1.1" fill="currentColor" fill-opacity=".22"/>
            <rect x="15.4" y="8.8" width="3" height="8.4" rx="1.1" fill="currentColor" fill-opacity=".22"/>
            """
        case .pie: body = """
            <path d="M11 5.2a7.8 7.8 0 1 0 7.8 7.8H11Z" fill="currentColor" fill-opacity=".14"/>
            <path d="M14.6 3.4v6h6a6 6 0 0 0-6-6Z" fill="currentColor" fill-opacity=".5"/>
            """
        case .sliders: body = """
            <path d="M4 7.5h8.4M16.8 7.5H20M4 16.5h3.2M11.6 16.5H20"/>
            <circle cx="14.6" cy="7.5" r="2.2" fill="currentColor" fill-opacity=".22"/>
            <circle cx="9.4" cy="16.5" r="2.2" fill="currentColor" fill-opacity=".22"/>
            """
        case .refresh: body = """
            <path d="M19.6 10.6A7.8 7.8 0 0 0 6.1 7.1L4.4 8.8"/>
            <path d="M4.4 4.6v4.2h4.2"/>
            <path d="M4.4 13.4a7.8 7.8 0 0 0 13.5 3.5l1.7-1.7"/>
            <path d="M19.6 19.4v-4.2h-4.2"/>
            """
        case .power: body = """
            <path d="M12 3.4v8"/>
            <path d="M7.2 6.2a7.8 7.8 0 1 0 9.6 0"/>
            """
        case .folder: body = """
            <path d="M3.5 7.4c0-1.3 1-2.4 2.4-2.4h3.5c.6 0 1.2.3 1.6.7l1.2 1.4h5.9c1.3 0 2.4 1.1 2.4 2.4v7.7c0 1.3-1.1 2.4-2.4 2.4H5.9c-1.3 0-2.4-1.1-2.4-2.4Z" fill="currentColor" fill-opacity=".14"/>
            <path d="M3.5 10.4h17" stroke-opacity=".5"/>
            """
        case .crown: body = """
            <path d="M4.2 8.2 7.9 12 12 5.6l4.1 6.4 3.7-3.8-1.5 9.3H5.7Z" fill="currentColor" fill-opacity=".22"/>
            <path d="M6 20.6h12"/>
            """
        case .star: body = """
            <path d="m12 3.6 2.5 5.2 5.7.8-4.1 4 1 5.6L12 16.5l-5.1 2.7 1-5.6-4.1-4 5.7-.8Z" fill="currentColor" fill-opacity=".22"/>
            """
        case .users: body = """
            <circle cx="9" cy="8.4" r="3.2" fill="currentColor" fill-opacity=".22"/>
            <path d="M3.4 19.2c.6-3 2.9-4.9 5.6-4.9s5 1.9 5.6 4.9"/>
            <path d="M15.4 5.4a3.2 3.2 0 0 1 0 6.1M17.2 14.6c1.7.5 3 2 3.4 4.6"/>
            """
        case .diamond: body = """
            <path d="M7 4.2h10l3.6 5-8.6 10.6L3.4 9.2Z" fill="currentColor" fill-opacity=".2"/>
            <path d="M3.4 9.2h17.2M9.6 4.2 8.2 9.2l3.8 10.6 3.8-10.6-1.4-5" stroke-opacity=".55"/>
            """
        case .coin: body = """
            <circle cx="12" cy="12" r="8.6" fill="currentColor" fill-opacity=".1"/>
            <path d="M14.7 9.3c-.4-.9-1.5-1.6-2.8-1.6-1.6 0-2.8.8-2.8 2 0 2.9 5.8 1.4 5.8 4.3 0 1.2-1.3 2.1-2.9 2.1-1.4 0-2.5-.6-2.9-1.6"/>
            <path d="M12 6.2v1.5M12 16.1v1.6"/>
            """
        case .bell: body = """
            <path d="M6.2 16.4V11a5.8 5.8 0 0 1 11.6 0v5.4l1.6 2.1H4.6Z" fill="currentColor" fill-opacity=".14"/>
            <path d="M10 21h4"/>
            """
        case .rocket: body = """
            <path d="M12.3 15.6 8.4 11.7C10.3 6.6 13.9 3.8 20.2 3.8c0 6.3-2.8 9.9-7.9 11.8Z" fill="currentColor" fill-opacity=".16"/>
            <path d="M8.4 11.7H5.2l2.3-3.3h4"/>
            <path d="M12.3 15.6v3.2l3.3-2.3v-4"/>
            <circle cx="15.4" cy="8.6" r="1.4"/>
            <path d="M6.6 16.2c-1.4.6-2.2 2.6-2.2 3.4.8 0 2.8-.8 3.4-2.2"/>
            """
        case .upgrade: body = """
            <circle cx="12" cy="12" r="8.6" fill="currentColor" fill-opacity=".16"/>
            <path d="M12 16.4V7.9"/>
            <path d="m8.3 11.5 3.7-3.6 3.7 3.6"/>
            """
        case .info: body = """
            <circle cx="12" cy="12" r="8.6"/>
            <path d="M12 11v5.2"/>
            <circle cx="12" cy="7.9" r="1.1" fill="currentColor" stroke="none"/>
            """
        case .chevronDown: body = #"<path d="m6.5 9.5 5.5 5.5 5.5-5.5"/>"#
        case .chevronLeft: body = #"<path d="M14.5 6.5 9 12l5.5 5.5"/>"#
        case .chevronRight: body = #"<path d="m9.5 6.5 5.5 5.5-5.5 5.5"/>"#
        case .check: body = #"<path d="m5.4 12.6 4.3 4.3 8.9-9.6"/>"#
        case .close: body = #"<path d="m6.6 6.6 10.8 10.8M17.4 6.6 6.6 17.4"/>"#
        case .plus: body = #"<path d="M12 5v14M5 12h14"/>"#
        case .minus: body = #"<path d="M5 12h14"/>"#
        case .cpu: body = """
            <rect x="6" y="6" width="12" height="12" rx="2.8" fill="currentColor" fill-opacity=".14"/>
            <rect x="9.4" y="9.4" width="5.2" height="5.2" rx="1.2" fill="currentColor" fill-opacity=".5" stroke="none"/>
            <path d="M9.6 2.8V6M14.4 2.8V6M9.6 18v3.2M14.4 18v3.2M2.8 9.6H6M2.8 14.4H6M18 9.6h3.2M18 14.4h3.2"/>
            """
        case .flame: body = """
            <path d="M12 21.2c-3.8 0-6.6-2.6-6.6-6.3 0-3.3 2.2-5.3 3.8-8 .4 1.6 1.3 2.7 2.5 3.3.3-3 1.8-5.6 4.2-7.3-.5 2.9.5 5 1.9 7 1 1.4 1.8 2.9 1.8 5 0 3.8-2.9 6.3-7.6 6.3Z" fill="currentColor" fill-opacity=".18"/>
            <path d="M12 21.2c-1.7 0-3-1.2-3-2.9 0-1.8 1.7-2.8 2.3-4.5 1.5 1 3.7 2.6 3.7 4.5 0 1.7-1.3 2.9-3 2.9Z" fill="currentColor" fill-opacity=".6" stroke="none"/>
            """
        case .sparkles: body = """
            <path d="M10.2 3.6 11.8 8l4.4 1.6-4.4 1.6-1.6 4.4-1.6-4.4-4.4-1.6L8.6 8Z" fill="currentColor" fill-opacity=".22"/>
            <path d="m18 14.2.8 2.1 2.1.8-2.1.8-.8 2.1-.8-2.1-2.1-.8 2.1-.8Z" fill="currentColor" stroke="none"/>
            """
        case .terminal: body = """
            <rect x="3.2" y="4.6" width="17.6" height="14.8" rx="3.6" fill="currentColor" fill-opacity=".12"/>
            <path d="m7.6 9.8 2.6 2.4-2.6 2.4"/>
            <path d="M12.8 14.6h3.8"/>
            """
        case .branch: body = """
            <circle cx="6.8" cy="5.6" r="2.1"/>
            <circle cx="6.8" cy="18.4" r="2.1"/>
            <circle cx="17.2" cy="7.8" r="2.1"/>
            <path d="M6.8 7.7v8.6"/>
            <path d="M17.2 9.9c0 3.9-4.6 3.9-9 6.9"/>
            """
        case .warning: body = """
            <path d="M10.3 4.4 3 17.3a2 2 0 0 0 1.7 3h14.6a2 2 0 0 0 1.7-3L13.7 4.4a2 2 0 0 0-3.4 0Z" fill="currentColor" fill-opacity=".14"/>
            <path d="M12 9.6v4.2"/>
            <circle cx="12" cy="16.9" r="1" fill="currentColor" stroke="none"/>
            """
        case .clock: body = """
            <circle cx="12" cy="12" r="8.6" fill="currentColor" fill-opacity=".1"/>
            <path d="M12 7.4V12l3.1 2"/>
            """
        case .globe: body = """
            <circle cx="12" cy="12" r="8.6"/>
            <path d="M3.6 12h16.8"/>
            <path d="M12 3.4c2.2 2.3 3.4 5.2 3.4 8.6s-1.2 6.3-3.4 8.6c-2.2-2.3-3.4-5.2-3.4-8.6S9.8 5.7 12 3.4Z"/>
            """
        case .pulse: body = #"<path d="M3 12.4h3.8l2.4-5.8 4.6 11.2 2.5-5.4H21"/>"#
        case .menuBar: body = """
            <rect x="3" y="4.4" width="18" height="15.2" rx="3.4" fill="currentColor" fill-opacity=".1"/>
            <path d="M3 8.6h18"/>
            <circle cx="16.2" cy="6.5" r=".9" fill="currentColor" stroke="none"/>
            <circle cx="18.4" cy="6.5" r=".9" fill="currentColor" stroke="none"/>
            """
        case .crosshair: body = """
            <circle cx="12" cy="12" r="6.8" fill="currentColor" fill-opacity=".1"/>
            <path d="M12 2.6v4M12 17.4v4M2.6 12h4M17.4 12h4"/>
            <circle cx="12" cy="12" r="1.7" fill="currentColor" stroke="none"/>
            """
        case .database: body = """
            <ellipse cx="12" cy="6" rx="7.4" ry="2.9" fill="currentColor" fill-opacity=".22"/>
            <path d="M4.6 6v12c0 1.6 3.3 2.9 7.4 2.9s7.4-1.3 7.4-2.9V6"/>
            <path d="M4.6 12c0 1.6 3.3 2.9 7.4 2.9s7.4-1.3 7.4-2.9"/>
            """
        case .external: body = """
            <path d="M14 4h6v6M20 4l-8.4 8.4"/>
            <path d="M18 13.6v3.9a2.5 2.5 0 0 1-2.5 2.5h-9A2.5 2.5 0 0 1 4 17.5v-9A2.5 2.5 0 0 1 6.5 6h3.9"/>
            """
        case .wand: body = """
            <path d="m4.2 19.8 10.6-10.6"/>
            <path d="m13.2 7.6 3.2 3.2"/>
            <path d="M17.4 3v2.8M16 4.4h2.8M20.4 8.8v2M19.4 9.8h2M8.4 3.6v2M7.4 4.6h2"/>
            """
        case .trendUp: body = """
            <path d="m3.8 16.4 5.4-5.4 3.6 3.6 7.4-7.4"/>
            <path d="M14.6 7.2h5.6v5.6"/>
            """
        case .message: body = """
            <path d="M4.4 6.8c0-1.5 1.2-2.7 2.7-2.7h9.8c1.5 0 2.7 1.2 2.7 2.7v7c0 1.5-1.2 2.7-2.7 2.7H11l-4.1 3.4v-3.4c-1.4 0-2.5-1.2-2.5-2.7Z" fill="currentColor" fill-opacity=".14"/>
            <path d="M8.4 9h7.2M8.4 12h4.4"/>
            """
        case .hexagon: body = """
            <path d="M12 3.2 19.6 7.6v8.8L12 20.8l-7.6-4.4V7.6Z" fill="currentColor" fill-opacity=".14"/>
            <path d="M12 8.2 15.3 10v4L12 15.8 8.7 14v-4Z" fill="currentColor" fill-opacity=".5" stroke="none"/>
            """
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
        \(body)
        </svg>
        """
    }

    @MainActor private static var cache: [Icon: SVGDocument] = [:]

    @MainActor var document: SVGDocument {
        if let doc = Self.cache[self] { return doc }
        let doc = SVGDocument.parse(markup)
        Self.cache[self] = doc
        return doc
    }
}

// MARK: - 渲染

/// 以矢量方式绘制 `Icon`。前景色跟随 `.foregroundStyle`。
/// 默认为纯线条风格；`duotone` 打开时绘制半透明的双色调填充。
struct SVGIcon: View {
    let icon: Icon
    var size: CGFloat = 16
    var lineWidth: CGFloat?
    var accent: AnyShapeStyle?
    var draw: CGFloat = 1
    var duotone = false

    init(_ icon: Icon, size: CGFloat = 16, lineWidth: CGFloat? = nil, accent: AnyShapeStyle? = nil, draw: CGFloat = 1, duotone: Bool = false) {
        self.icon = icon
        self.size = size
        self.lineWidth = lineWidth
        self.accent = accent
        self.draw = draw
        self.duotone = duotone
    }

    var body: some View {
        let doc = icon.document
        ZStack {
            ForEach(doc.elements.indices, id: \.self) { i in
                element(doc.elements[i], viewBox: doc.viewBox)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func element(_ e: SVGDocument.Element, viewBox: CGRect) -> some View {
        let shape = SVGShape(path: e.path, viewBox: viewBox)
        if e.fill != .none, duotone || e.fillOpacity >= 1 {
            shape.fill(style(e.fill, accent: e.isAccent))
                .opacity(e.opacity * e.fillOpacity * Double(min(1, draw * 1.6)))
        }
        if e.stroke != .none {
            shape.trim(from: 0, to: draw)
                .stroke(
                    style(e.stroke, accent: e.isAccent),
                    style: StrokeStyle(lineWidth: (lineWidth ?? e.strokeWidth) * size / viewBox.width, lineCap: .round, lineJoin: .round)
                )
                .opacity(e.opacity * e.strokeOpacity)
        }
    }

    private func style(_ paint: SVGDocument.Paint, accent isAccent: Bool) -> AnyShapeStyle {
        switch paint {
        case .current: isAccent ? (accent ?? AnyShapeStyle(.foreground)) : AnyShapeStyle(.foreground)
        case .color(let c): AnyShapeStyle(c)
        case .none: AnyShapeStyle(Color.clear)
        }
    }
}

struct SVGShape: Shape {
    let path: Path
    let viewBox: CGRect

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let dx = rect.midX - viewBox.midX * scale
        let dy = rect.midY - viewBox.midY * scale
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }
}

// MARK: - NSImage（用于 AppKit 菜单）

extension Icon {
    @MainActor
    func nsImage(size: CGFloat = 16, color: NSColor = .labelColor, template: Bool = true) -> NSImage {
        let doc = document
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = min(rect.width / doc.viewBox.width, rect.height / doc.viewBox.height)
            ctx.translateBy(x: rect.midX - doc.viewBox.midX * scale, y: rect.midY - doc.viewBox.midY * scale)
            ctx.scaleBy(x: scale, y: scale)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for e in doc.elements {
                let cg = e.path.cgPath
                if e.fill != .none, e.fillOpacity >= 1 {
                    ctx.setFillColor(color.withAlphaComponent(CGFloat(e.opacity * e.fillOpacity)).cgColor)
                    ctx.addPath(cg)
                    ctx.fillPath()
                }
                if e.stroke != .none {
                    ctx.setStrokeColor(color.withAlphaComponent(CGFloat(e.opacity * e.strokeOpacity)).cgColor)
                    ctx.setLineWidth(e.strokeWidth)
                    ctx.addPath(cg)
                    ctx.strokePath()
                }
            }
            return true
        }
        image.isTemplate = template
        return image
    }
}
