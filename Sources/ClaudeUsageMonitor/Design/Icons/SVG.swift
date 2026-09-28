import SwiftUI

/// 一个轻量的 SVG 渲染引擎：把 SVG 标记解析成 SwiftUI `Path`，
/// 从而以真正的矢量方式绘制图标（任意尺寸清晰、可做描边动画、可填充渐变）。
///
/// 支持 `path / circle / ellipse / rect / line / polyline / polygon / g`，
/// 以及 `fill / stroke / stroke-width / opacity / fill-opacity / stroke-opacity / transform`
/// 和自定义属性 `data-tone="accent"`（使用强调色绘制）。
struct SVGDocument {
    enum Paint: Equatable {
        case none
        case current
        case color(Color)
    }

    struct Element {
        var path: Path
        var fill: Paint
        var stroke: Paint
        var strokeWidth: CGFloat
        var opacity: Double
        var fillOpacity: Double
        var strokeOpacity: Double
        var isAccent: Bool
    }

    var viewBox: CGRect
    var elements: [Element]

    static func parse(_ markup: String) -> SVGDocument {
        let builder = SVGBuilder()
        let parser = XMLParser(data: Data(markup.utf8))
        parser.delegate = builder
        parser.parse()
        return SVGDocument(viewBox: builder.viewBox, elements: builder.elements)
    }
}

// MARK: - XML → 元素

private final class SVGBuilder: NSObject, XMLParserDelegate {
    var viewBox = CGRect(x: 0, y: 0, width: 24, height: 24)
    var elements: [SVGDocument.Element] = []

    private struct Style {
        var fill: SVGDocument.Paint = .color(.black)
        var stroke: SVGDocument.Paint = .none
        var strokeWidth: CGFloat = 1
        var opacity: Double = 1
        var fillOpacity: Double = 1
        var strokeOpacity: Double = 1
        var isAccent = false
        var transform: CGAffineTransform = .identity
    }

    private var stack: [Style] = [Style()]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        var style = stack.last ?? Style()
        style.opacity = 1  // opacity 不继承相乘到子元素之外，这里在绘制时单独处理
        if let v = a["fill"] { style.fill = Self.paint(v) }
        if let v = a["stroke"] { style.stroke = Self.paint(v) }
        if let v = a["stroke-width"], let n = Double(v) { style.strokeWidth = n }
        if let v = a["fill-opacity"], let n = Double(v) { style.fillOpacity = n }
        if let v = a["stroke-opacity"], let n = Double(v) { style.strokeOpacity = n }
        if let v = a["opacity"], let n = Double(v) { style.opacity = (stack.last?.opacity ?? 1) * n } else { style.opacity = stack.last?.opacity ?? 1 }
        if a["data-tone"] == "accent" { style.isAccent = true }
        if let v = a["transform"] { style.transform = Self.transform(v).concatenating(style.transform) }
        stack.append(style)

        if name == "svg", let vb = a["viewBox"] {
            let n = Self.numbers(vb)
            if n.count == 4 { viewBox = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
            return
        }

        guard var path = Self.shape(name, a) else { return }
        if style.transform != .identity { path = path.applying(style.transform) }
        elements.append(.init(
            path: path, fill: style.fill, stroke: style.stroke, strokeWidth: style.strokeWidth,
            opacity: style.opacity, fillOpacity: style.fillOpacity, strokeOpacity: style.strokeOpacity,
            isAccent: style.isAccent
        ))
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }

    private static func shape(_ name: String, _ a: [String: String]) -> Path? {
        func v(_ key: String) -> CGFloat { CGFloat(Double(a[key] ?? "") ?? 0) }
        switch name {
        case "path":
            return a["d"].map { SVGPathParser.parse($0) }
        case "circle":
            let r = v("r")
            return Path(ellipseIn: CGRect(x: v("cx") - r, y: v("cy") - r, width: 2 * r, height: 2 * r))
        case "ellipse":
            return Path(ellipseIn: CGRect(x: v("cx") - v("rx"), y: v("cy") - v("ry"), width: 2 * v("rx"), height: 2 * v("ry")))
        case "rect":
            let rect = CGRect(x: v("x"), y: v("y"), width: v("width"), height: v("height"))
            let rx = a["rx"] != nil ? v("rx") : v("ry")
            let ry = a["ry"] != nil ? v("ry") : rx
            return rx > 0 ? Path(roundedRect: rect, cornerSize: CGSize(width: rx, height: ry), style: .continuous) : Path(rect)
        case "line":
            var p = Path()
            p.move(to: CGPoint(x: v("x1"), y: v("y1")))
            p.addLine(to: CGPoint(x: v("x2"), y: v("y2")))
            return p
        case "polyline", "polygon":
            let n = numbers(a["points"] ?? "")
            guard n.count >= 4 else { return nil }
            var p = Path()
            p.move(to: CGPoint(x: n[0], y: n[1]))
            var i = 2
            while i + 1 < n.count {
                p.addLine(to: CGPoint(x: n[i], y: n[i + 1]))
                i += 2
            }
            if name == "polygon" { p.closeSubpath() }
            return p
        default:
            return nil
        }
    }

    private static func paint(_ value: String) -> SVGDocument.Paint {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        if v == "none" || v == "transparent" { return .none }
        if v == "currentcolor" { return .current }
        if v.hasPrefix("#"), let color = Color(svgHex: String(v.dropFirst())) { return .color(color) }
        if v == "white" { return .color(.white) }
        if v == "black" { return .color(.black) }
        return .current
    }

    static func numbers(_ s: String) -> [CGFloat] {
        var tokenizer = SVGTokenizer(s)
        var result: [CGFloat] = []
        while let n = tokenizer.number() { result.append(n) }
        return result
    }

    private static func transform(_ s: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        let pattern = #/(matrix|translate|scale|rotate)\s*\(([^)]*)\)/#
        for match in s.matches(of: pattern) {
            let n = numbers(String(match.output.2))
            var t = CGAffineTransform.identity
            switch match.output.1 {
            case "matrix" where n.count == 6:
                t = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            case "translate":
                t = CGAffineTransform(translationX: n.first ?? 0, y: n.count > 1 ? n[1] : 0)
            case "scale":
                t = CGAffineTransform(scaleX: n.first ?? 1, y: n.count > 1 ? n[1] : (n.first ?? 1))
            case "rotate":
                let angle = (n.first ?? 0) * .pi / 180
                if n.count == 3 {
                    t = CGAffineTransform(translationX: n[1], y: n[2]).rotated(by: angle).translatedBy(x: -n[1], y: -n[2])
                } else {
                    t = CGAffineTransform(rotationAngle: angle)
                }
            default: break
            }
            // SVG 的变换列表从左到右依次作用：M = T1 · T2 · …
            result = t.concatenating(result)
        }
        return result
    }
}

// MARK: - Path 数据

enum SVGPathParser {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var t = SVGTokenizer(d)
        var command: UInt8 = 0
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?

        while !t.isAtEnd {
            let before = t.index
            if let c = t.command() {
                command = c
            } else if command == 0 || command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                break  // 缺少命令字母
            }
            let relative = command >= UInt8(ascii: "a")
            let base = relative ? current : .zero
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }

            switch command | 0x20 {  // 转小写
            case UInt8(ascii: "m"):
                guard let x = t.number(), let y = t.number() else { return path }
                current = point(x, y)
                subpathStart = current
                path.move(to: current)
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")  // 后续坐标对视为 lineto
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "l"):
                guard let x = t.number(), let y = t.number() else { return path }
                current = point(x, y)
                path.addLine(to: current)
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "h"):
                guard let x = t.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "v"):
                guard let y = t.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "c"):
                guard let x1 = t.number(), let y1 = t.number(), let x2 = t.number(), let y2 = t.number(),
                      let x = t.number(), let y = t.number() else { return path }
                let c2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: point(x1, y1), control2: c2)
                lastCubic = c2; lastQuad = nil
            case UInt8(ascii: "s"):
                guard let x2 = t.number(), let y2 = t.number(), let x = t.number(), let y = t.number() else { return path }
                let c1 = lastCubic.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubic = c2; lastQuad = nil
            case UInt8(ascii: "q"):
                guard let x1 = t.number(), let y1 = t.number(), let x = t.number(), let y = t.number() else { return path }
                let c = point(x1, y1)
                current = point(x, y)
                path.addQuadCurve(to: current, control: c)
                lastQuad = c; lastCubic = nil
            case UInt8(ascii: "t"):
                guard let x = t.number(), let y = t.number() else { return path }
                let c = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                current = point(x, y)
                path.addQuadCurve(to: current, control: c)
                lastQuad = c; lastCubic = nil
            case UInt8(ascii: "a"):
                guard let rx = t.number(), let ry = t.number(), let rotation = t.number(),
                      let large = t.flag(), let sweep = t.flag(),
                      let x = t.number(), let y = t.number() else { return path }
                let end = point(x, y)
                addArc(to: &path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, largeArc: large, sweep: sweep)
                current = end
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = subpathStart
                lastCubic = nil; lastQuad = nil
            default:
                return path
            }
            if t.index == before { break }  // 防御：没有任何进展
        }
        return path
    }

    /// SVG 椭圆弧（端点参数化）→ 若干段三次贝塞尔曲线（SVG 1.1 规范 F.6.5）
    private static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat,
                               rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        guard p0 != p1 else { return }
        var rx = abs(rx0), ry = abs(ry0)
        guard rx > 0, ry > 0 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s; ry *= s
        }
        let rx2 = rx * rx, ry2 = ry * ry
        let num = max(0, rx2 * ry2 - rx2 * y1 * y1 - ry2 * x1 * x1)
        let den = rx2 * y1 * y1 + ry2 * x1 * x1
        var coef = den == 0 ? 0 : sqrt(num / den)
        if largeArc == sweep { coef = -coef }
        let cxp = coef * (rx * y1 / ry)
        let cyp = coef * -(ry * x1 / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi } else if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2) - 0.001)))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let ex = rx * x, ey = ry * y
            return CGPoint(x: cosPhi * ex - sinPhi * ey + cx, y: sinPhi * ex + cosPhi * ey + cy)
        }
        var theta = theta1
        for _ in 0..<segments {
            let c1 = cos(theta), s1 = sin(theta)
            let theta2 = theta + step
            let c2 = cos(theta2), s2 = sin(theta2)
            path.addCurve(
                to: map(c2, s2),
                control1: map(c1 - k * s1, s1 + k * c1),
                control2: map(c2 + k * s2, s2 - k * c2)
            )
            theta = theta2
        }
    }
}

/// SVG 数字 / 命令的词法扫描器。
struct SVGTokenizer {
    private let bytes: [UInt8]
    private(set) var index = 0

    init(_ string: String) { bytes = Array(string.utf8) }

    var isAtEnd: Bool {
        mutating get {
            skipSeparators()
            return index >= bytes.count
        }
    }

    private mutating func skipSeparators() {
        while index < bytes.count {
            let c = bytes[index]
            guard c == 0x20 || c == 0x2C || c == 0x09 || c == 0x0A || c == 0x0D else { break }
            index += 1
        }
    }

    mutating func command() -> UInt8? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        let c = bytes[index]
        let isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
        guard isLetter, c != UInt8(ascii: "e"), c != UInt8(ascii: "E") else { return nil }
        index += 1
        return c
    }

    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "0"): index += 1; return false
        case UInt8(ascii: "1"): index += 1; return true
        default: return nil
        }
    }

    mutating func number() -> CGFloat? {
        skipSeparators()
        let start = index
        func isDigit(_ i: Int) -> Bool { i < bytes.count && bytes[i] >= 0x30 && bytes[i] <= 0x39 }
        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
        var sawDigit = false
        while isDigit(index) { index += 1; sawDigit = true }
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            while isDigit(index) { index += 1; sawDigit = true }
        }
        guard sawDigit else { index = start; return nil }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            var j = index + 1
            if j < bytes.count, bytes[j] == 0x2B || bytes[j] == 0x2D { j += 1 }
            if isDigit(j) {
                index = j
                while isDigit(index) { index += 1 }
            }
        }
        guard let s = String(bytes: bytes[start..<index], encoding: .ascii), let v = Double(s) else { return nil }
        return CGFloat(v)
    }
}

extension Color {
    init?(svgHex hex: String) {
        var s = hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}
