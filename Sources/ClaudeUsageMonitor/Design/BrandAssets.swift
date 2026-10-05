import SwiftUI

// Claude 标志与吉祥物 Clawd 均为 Anthropic 的商标素材，这里原样取自官方资源：
// - 标志：Claude 桌面应用内置的矢量资源（248×248，#D97757）
// - Clawd：Claude Code（2.1.285）终端里的方块字形，包括眼睛、手臂、脚三个部件，转身用的 13 幅字形，以及欢迎屏的 15 段动画

enum ClaudeBrand {
    static let orange = Color(hex: 0xD97757)
    static let orangeNS = NSColor(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)

    static let logoViewBox = CGRect(x: 0, y: 0, width: 248, height: 248)

    static let logoPathData = "M52.4285 162.873L98.7844 136.879L99.5485 134.602L98.7844 133.334H96.4921L88.7237 132.862L62.2346 132.153L39.3113 131.207L17.0249 130.026L11.4214 128.844L6.2 121.873L6.7094 118.447L11.4214 115.257L18.171 115.847L33.0711 116.911L55.485 118.447L71.6586 119.392L95.728 121.873H99.5485L100.058 120.337L98.7844 119.392L97.7656 118.447L74.5877 102.732L49.4995 86.1905L36.3823 76.62L29.3779 71.7757L25.8121 67.2858L24.2839 57.3608L30.6515 50.2716L39.3113 50.8623L41.4763 51.4531L50.2636 58.1879L68.9842 72.7209L93.4357 90.6804L97.0015 93.6343L98.4374 92.6652L98.6571 91.9801L97.0015 89.2625L83.757 65.2772L69.621 40.8192L63.2534 30.6579L61.5978 24.632C60.9565 22.1032 60.579 20.0111 60.579 17.4246L67.8381 7.49965L71.9133 6.19995L81.7193 7.49965L85.7946 11.0443L91.9074 24.9865L101.714 46.8451L116.996 76.62L121.453 85.4816L123.873 93.6343L124.764 96.1155H126.292V94.6976L127.566 77.9197L129.858 57.3608L132.15 30.8942L132.915 23.4505L136.608 14.4708L143.994 9.62643L149.725 12.344L154.437 19.0788L153.8 23.4505L150.998 41.6463L145.522 70.1215L141.957 89.2625H143.994L146.414 86.7813L156.093 74.0206L172.266 53.698L179.398 45.6635L187.803 36.802L193.152 32.5484H203.34L210.726 43.6549L207.415 55.1159L196.972 68.3492L188.312 79.5739L175.896 96.2095L168.191 109.585L168.882 110.689L170.738 110.53L198.755 104.504L213.91 101.787L231.994 98.7149L240.144 102.496L241.036 106.395L237.852 114.311L218.495 119.037L195.826 123.645L162.07 131.592L161.696 131.893L162.137 132.547L177.36 133.925L183.855 134.279H199.774L229.447 136.524L237.215 141.605L241.8 147.867L241.036 152.711L229.065 158.737L213.019 154.956L175.45 145.977L162.587 142.787H160.805V143.85L171.502 154.366L191.242 172.089L215.82 195.011L217.094 200.682L213.91 205.172L210.599 204.699L188.949 188.394L180.544 181.069L161.696 165.118H160.422V166.772L164.752 173.152L187.803 207.771L188.949 218.405L187.294 221.832L181.308 223.959L174.813 222.777L161.187 203.754L147.305 182.486L136.098 163.345L134.745 164.2L128.075 235.42L125.019 239.082L117.887 241.8L111.902 237.31L108.718 229.984L111.902 215.452L115.722 196.547L118.779 181.541L121.58 162.873L123.291 156.636L123.14 156.219L121.773 156.449L107.699 175.752L86.304 204.699L69.3663 222.777L65.291 224.431L58.2867 220.768L58.9235 214.27L62.8713 208.48L86.304 178.705L100.44 160.155L109.551 149.507L109.462 147.967L108.959 147.924L46.6977 188.512L35.6182 189.93L30.7788 185.44L31.4156 178.115L33.7079 175.752L52.4285 162.873Z"

    static let logoPath: Path = SVGPathParser.parse(logoPathData)

    static var logoSVG: String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 248 248"><path d="\(logoPathData)" fill="#D97757"/></svg>
        """
    }
}

/// 官方 Claude 标志
struct ClaudeLogo: View {
    var size: CGFloat = 16
    var color: Color = ClaudeBrand.orange

    var body: some View {
        SVGShape(path: ClaudeBrand.logoPath, viewBox: ClaudeBrand.logoViewBox)
            .fill(color)
            .frame(width: size, height: size)
    }
}

// MARK: - 吉祥物 Clawd

/// Clawd 的一个姿态。正面由眼睛、手臂、脚三个部件拼成；转身时换成侧面、背面的整幅字形。
enum MascotPose: Hashable, Sendable {
    case front(eyes: Eyes = .open, arms: Arms = .down, feet: Feet = .both)
    case turned(Facing)

    enum Eyes: Hashable, Sendable, CaseIterable { case open, left, right, closed, wink }
    /// 手臂。单手举起是官方拿东西时的姿态（Claude Code 里举着魔杖）。
    enum Arms: Hashable, Sendable, CaseIterable { case down, up, oneUp }
    /// 脚。只着地一边时是在踏步。
    enum Feet: Hashable, Sendable, CaseIterable { case both, left, right }
    /// 转身：从正面往右转到背面，再从左边转回来
    enum Facing: Hashable, Sendable, CaseIterable {
        case right12, right30, right55, right75, edge, back105, back125, back150, back, left75, left55, left30, left12
    }

    static let idle = MascotPose.front()
    static let armsUp = MascotPose.front(arms: .up)
    static let lookLeft = MascotPose.front(eyes: .left)
    static let lookRight = MascotPose.front(eyes: .right)

    /// 换一双眼睛，手脚不变（转身时没有眼睛可换）
    func eyes(_ eyes: Eyes) -> MascotPose {
        guard case .front(_, let arms, let feet) = self else { return self }
        return .front(eyes: eyes, arms: arms, feet: feet)
    }

    static let all: [MascotPose] =
        Eyes.allCases.flatMap { eyes in
            Arms.allCases.flatMap { arms in Feet.allCases.map { MascotPose.front(eyes: eyes, arms: arms, feet: $0) } }
        } + Facing.allCases.map { .turned($0) }
}

enum Mascot {
    /// 终端里一个字符格的宽高比约 1:2，所以每个象限像素是竖长的
    static let pixelAspect: CGFloat = 2.2
    /// 官方的画框：9 个字符宽、3 行高，每个字符是 2×2 个象限像素
    static let frameColumns = 18
    static let frameRows = 6
    /// 正面姿态共用的包围盒（列 1…17，行 0…4），切换姿态时不会跳动。最左一列和最下一行在任何姿态里都是空的。
    static let columns = 1...17
    static let rows = 0...4

    // 以下字形逐字取自 Claude Code。每行 9 个字符。

    /// 手臂：第一行两端、第二行两端
    private static func arms(_ arms: MascotPose.Arms) -> (r1L: String, r1R: String, r2L: String, r2R: String) {
        switch arms {
        case .down: (" ▐", "", "▝▜", "█▀")
        case .up: ("▗▟", "▄", " ▜", "█▘")
        case .oneUp: (" ▐", "▄", "▝▜", "█▘")
        }
    }

    /// 眼睛：第一行第 2 列起的 6 个字符。闭眼的格子是一道眼睑（`lid`），整格填满、只在底部留一道缝。
    private static func eyes(_ eyes: MascotPose.Eyes) -> [(glyphs: String, lid: Bool)] {
        switch eyes {
        case .open: [("▛███▛█", false)]
        case .left: [("▟███▟█", false)]
        case .right: [("█▟███▟", false)]
        case .closed: [("▂", true), ("███", false), ("▂", true), ("█", false)]
        case .wink: [("▛███", false), ("▂", true), ("█", false)]
        }
    }

    private static func feet(_ feet: MascotPose.Feet) -> String {
        switch feet {
        case .both: " ▝▝   ▝▝ "
        case .left: " ▝▝      "
        case .right: "      ▝▝ "
        }
    }

    private static func turned(_ facing: MascotPose.Facing) -> [String] {
        switch facing {
        case .right12: [" ▐█▜██▛█ ", "▝▜██████▀", " ▝▝   ▝▝ "]
        case .right30: ["  █▛██▛▌ ", " ▝█████▛ ", "  ▘▘  ▘▘ "]
        case .right55: ["  ▐█▛█▜  ", "  ▐████  ", "  ▝▝ ▝▝  "]
        case .right75: ["   ██▛▌  ", "   ███▌  ", "   ▘  ▘  "]
        case .edge: ["   ▐██   ", "   ▐██   ", "   ▝ ▝   "]
        case .back105: ["   ███▌  ", "   ███▌  ", "   ▘  ▘  "]
        case .back125: ["  ▐████  ", "  ▐████  ", "  ▝▝ ▝▝  "]
        case .back150: ["  █████▌ ", " ▝█████▛ ", "  ▘▘  ▘▘ "]
        case .back: [" ▐██████ ", "▝▜██████▀", " ▝▝   ▝▝ "]
        case .left75: ["   ▛██▌  ", "   ███▌  ", "   ▘  ▘  "]
        case .left55: ["  ▐▜▛██  ", "  ▐████  ", "  ▝▝ ▝▝  "]
        case .left30: ["  ▛██▛█▌ ", " ▝█████▛ ", "  ▘▘  ▘▘ "]
        case .left12: [" ▐▛███▜█ ", "▝▜██████▀", " ▝▝   ▝▝ "]
        }
    }

    /// 象限字符 → (左上, 右上, 左下, 右下)
    private static func quadrants(_ c: Character) -> (Bool, Bool, Bool, Bool) {
        switch c {
        case "█": (true, true, true, true)
        case "▐": (false, true, false, true)
        case "▌": (true, false, true, false)
        case "▀": (true, true, false, false)
        case "▄": (false, false, true, true)
        case "▛": (true, true, true, false)
        case "▜": (true, true, false, true)
        case "▟": (false, true, true, true)
        case "▙": (true, false, true, true)
        case "▝": (false, true, false, false)
        case "▘": (true, false, false, false)
        case "▗": (false, false, false, true)
        case "▖": (false, false, true, false)
        default: (false, false, false, false)
        }
    }

    /// 象限像素的填充：空、满、只有上半格（眼睑下面那道缝）
    enum Pixel: UInt8 { case empty, full, upperHalf }

    /// 解码为画框里的象限像素：`[行][列]`，6 行 × 18 列
    static func pixels(_ pose: MascotPose) -> [[Pixel]] {
        var grid = Array(repeating: Array(repeating: Pixel.empty, count: frameColumns), count: frameRows)
        func put(_ glyphs: String, line: Int, column: Int) {
            for (offset, ch) in glyphs.enumerated() {
                let q = quadrants(ch)
                let c = (column + offset) * 2, r = line * 2
                guard c + 1 < frameColumns else { continue }
                if q.0 { grid[r][c] = .full }
                if q.1 { grid[r][c + 1] = .full }
                if q.2 { grid[r + 1][c] = .full }
                if q.3 { grid[r + 1][c + 1] = .full }
            }
        }
        switch pose {
        case .front(let eyes, let arms, let feet):
            let a = self.arms(arms)
            put(a.r1L, line: 0, column: 0)
            var column = 2
            for span in self.eyes(eyes) {
                if span.lid {
                    // 字符「▂」用底色画在身体色的格子上：整格是身体，底部四分之一是缝
                    for c in column * 2...column * 2 + 1 {
                        grid[0][c] = .full
                        grid[1][c] = .upperHalf
                    }
                } else {
                    put(span.glyphs, line: 0, column: column)
                }
                column += span.glyphs.count
            }
            put(a.r1R, line: 0, column: 8)
            put(a.r2L, line: 1, column: 0)
            put("█████", line: 1, column: 2)
            put(a.r2R, line: 1, column: 7)
            put(self.feet(feet), line: 2, column: 0)
        case .turned(let facing):
            for (line, glyphs) in turned(facing).enumerated() {
                put(glyphs, line: line, column: 0)
            }
        }
        return grid
    }

    private static let cache: [MascotPose: [[Pixel]]] = Dictionary(
        uniqueKeysWithValues: MascotPose.all.map { ($0, pixels($0)) }
    )

    /// 宽高比（宽 / 高）
    static func aspectRatio(pixelAspect: CGFloat = pixelAspect) -> CGFloat {
        CGFloat(columns.count) / (CGFloat(rows.count) * pixelAspect)
    }

    /// 按画框画出 Clawd：`origin` 是画框左上角，`unit` 是一个象限像素的大小。每一行连续的像素合并成一个矩形。
    static func path(_ pose: MascotPose, origin: CGPoint, unit: CGSize) -> Path {
        let grid = cache[pose] ?? pixels(pose)
        var path = Path()
        for (r, row) in grid.enumerated() {
            var c = 0
            while c < row.count {
                let pixel = row[c]
                guard pixel != .empty else { c += 1; continue }
                let start = c
                while c < row.count, row[c] == pixel { c += 1 }
                path.addRect(CGRect(
                    x: origin.x + CGFloat(start) * unit.width,
                    y: origin.y + CGFloat(r) * unit.height,
                    width: CGFloat(c - start) * unit.width,
                    height: pixel == .upperHalf ? unit.height / 2 : unit.height
                ))
            }
        }
        return path
    }

    /// 把吉祥物放进 `rect`（等比居中）
    static func path(_ pose: MascotPose, in rect: CGRect, pixelAspect: CGFloat = pixelAspect) -> Path {
        let unitW = min(rect.width / CGFloat(columns.count), rect.height / (CGFloat(rows.count) * pixelAspect))
        let unitH = unitW * pixelAspect
        let totalW = unitW * CGFloat(columns.count), totalH = unitH * CGFloat(rows.count)
        let origin = CGPoint(
            x: rect.midX - totalW / 2 - CGFloat(columns.lowerBound) * unitW,
            y: rect.midY - totalH / 2 - CGFloat(rows.lowerBound) * unitH
        )
        return path(pose, origin: origin, unit: CGSize(width: unitW, height: unitH))
    }
}

// MARK: - 动画

/// 动画里的一帧。位移以字符为单位：一行是 2 个象限像素高，一列是 2 个象限像素宽。
struct MascotFrame: Hashable, Sendable {
    var pose: MascotPose
    /// 往下沉几行。正数沉到地面以下，被画框挡住；负数在画框上方，还没落下来。
    var offset = 0
    /// 横向偏移几列。负数表示还在画框左边，正在走进来。
    var x = 0
    /// 落地时两侧扬起的尘土
    var poof: Poof?
    /// 跳到半空时地上的影子
    var shadow: Shadow?

    /// 「·」「~」
    enum Poof: Hashable, Sendable { case dot, wave }
    /// 「▁▁▁」从第 3 列起，「▁」在第 4 列
    enum Shadow: Hashable, Sendable { case wide, narrow }

    static let rest = MascotFrame(pose: .idle)
}

/// Claude Code 欢迎屏里的 Clawd 动画。帧序列原样取自官方，每帧 60 毫秒。
enum MascotAnimation: String, CaseIterable, Sendable {
    case jump, look, celebrate, skip, spin, peekaboo, drop, waddle, peek, wink, boop, tap, sneeze, turn, coinHop

    static let frameDuration: TimeInterval = 0.06

    /// 官方入场时随机挑一个（不含 celebrate）
    static let entrances: [MascotAnimation] = [.skip, .jump, .look, .spin, .peekaboo, .drop, .waddle, .peek, .wink, .boop, .tap, .sneeze, .turn, .coinHop]
    /// 原地开始的动作：官方点一下 Clawd 时从这些里随机挑
    static let inPlace = entrances.filter { ($0.frames.first?.x ?? 0) == 0 }

    /// 自动播放时的待机：站一会儿，往右看，再往左看
    static let idleLoop = hold(.idle, 12) + hold(.lookRight, 5) + hold(.lookLeft, 5)

    /// 眨一下眼，`rest` 是眨完回到的姿态
    static func blink(_ rest: MascotFrame = .rest) -> [MascotFrame] {
        hold(rest.pose.eyes(.closed), 1) + [rest]
    }

    var frames: [MascotFrame] {
        typealias M = MascotAnimation
        switch self {
        case .jump:
            return M.jumping
        case .look:
            return M.hold(.lookRight, 5) + M.hold(.lookLeft, 5) + M.hold(.idle, 1)
        case .celebrate:
            return M.jumping + M.hold(.idle, 3, offset: 1)
        case .skip:
            return M.hold(.idle, 1, offset: 1, x: -9)
                + M.hold(.armsUp, 2, x: -6) + M.hold(.idle, 1, x: -6) + M.hold(.idle, 1, offset: 1, x: -6)
                + M.hold(.armsUp, 2, x: -3) + M.hold(.idle, 1, x: -3) + M.hold(.idle, 1, offset: 1, x: -3)
                + M.hold(.armsUp, 2) + M.landing + M.hold(.idle, 1)
        case .spin:
            return M.hold(.lookLeft, 2) + M.hold(.lookRight, 2) + M.hold(.lookLeft, 2) + M.hold(.armsUp, 3) + M.hold(.idle, 1)
        case .peekaboo:
            return M.hold(.idle, 1, offset: 3) + M.hold(.idle, 3, offset: 2)
                + M.hold(.lookRight, 3, offset: 2) + M.hold(.lookLeft, 3, offset: 2)
                + M.hold(.idle, 2, offset: 2) + M.hold(.idle, 1, offset: 1)
                + M.hold(.armsUp, 4) + M.hold(.idle, 2) + M.blink()
        case .drop:
            return M.hold(.armsUp, 1, offset: -3) + M.hold(.armsUp, 2, offset: -2) + M.hold(.armsUp, 2, offset: -1)
                + M.hold(.armsUp, 1) + M.landing + M.hold(.idle, 3) + M.blink()
        case .waddle:
            return M.hold(.lookRight, 1, x: -9)
                + [-6, -5, -4, -3, -2, -1].flatMap { M.hold(.front(eyes: .right, feet: $0 % 2 == 0 ? .left : .right), 2, x: $0) }
                + M.hold(.lookRight, 2) + M.hold(.idle, 2) + M.blink()
        case .peek:
            return M.hold(.lookRight, 1, x: -9) + M.hold(.lookRight, 5, x: -6) + M.hold(.lookRight, 3, x: -9)
                + M.hold(.lookRight, 4, x: -5) + M.hold(.armsUp, 2, x: -3) + M.hold(.armsUp, 2) + M.landing + [.rest]
        case .wink:
            return M.hold(.front(eyes: .wink), 5) + [.rest]
        case .boop:
            return M.hold(.front(eyes: .closed), 1, offset: 1, poof: .dot) + M.hold(.front(eyes: .closed), 2, offset: 1, poof: .wave)
                + M.hold(.lookLeft, 4) + M.hold(.idle, 2) + M.blink()
        case .tap:
            let left = MascotPose.front(feet: .left), right = MascotPose.front(feet: .right)
            return M.hold(left, 2) + M.hold(right, 2) + M.hold(left, 2) + M.hold(right, 2) + M.hold(left, 1) + M.hold(right, 1)
                + M.hold(.armsUp, 3) + [.rest]
        case .sneeze:
            return M.hold(.front(eyes: .closed, arms: .up), 4) + M.hold(.front(eyes: .closed), 2, offset: 1, poof: .wave)
                + M.hold(.front(eyes: .closed), 2) + M.hold(.idle, 2) + M.blink()
        case .turn:
            return M.turning([.right12, .right30, .right55, .right75, .edge])
                + M.turning([.back105, .back125, .back150, .back, .back])
                + M.turning([.back150, .back125, .back105, .edge])
                + M.turning([.left75, .left55, .left30, .left12]) + [.rest]
        case .coinHop:
            return M.hold(.idle, 2, offset: 1) + M.hold(.armsUp, 1, shadow: .wide)
                + M.turning([.right55, .edge, .back125, .back], shadow: .narrow)
                + M.turning([.back125, .edge, .left55], shadow: .narrow)
                + M.hold(.armsUp, 1, shadow: .wide) + M.landing + [.rest]
        }
    }

    /// 蹲下扬起尘土
    private static let landing = [
        MascotFrame(pose: .idle, offset: 1, poof: .dot),
        MascotFrame(pose: .idle, offset: 1, poof: .wave),
    ]

    private static let jumping = landing + hold(.armsUp, 3) + hold(.idle, 1) + landing + hold(.armsUp, 3) + hold(.idle, 1)

    private static func hold(
        _ pose: MascotPose, _ count: Int, offset: Int = 0, x: Int = 0,
        poof: MascotFrame.Poof? = nil, shadow: MascotFrame.Shadow? = nil
    ) -> [MascotFrame] {
        Array(repeating: MascotFrame(pose: pose, offset: offset, x: x, poof: poof, shadow: shadow), count: count)
    }

    private static func turning(_ facings: [MascotPose.Facing], shadow: MascotFrame.Shadow? = nil) -> [MascotFrame] {
        facings.map { MascotFrame(pose: .turned($0), shadow: shadow) }
    }
}

// MARK: - 视图

struct MascotShape: Shape {
    var pose: MascotPose = .idle

    func path(in rect: CGRect) -> Path {
        Mascot.path(pose, in: rect)
    }
}

/// Clawd：像素画保持硬切换，不做补间
struct MascotView: View {
    var width: CGFloat = 32
    var pose: MascotPose = .idle
    var color: Color = ClaudeBrand.orange

    var body: some View {
        MascotShape(pose: pose)
            .fill(color)
            .frame(width: width, height: width / Mascot.aspectRatio())
    }
}

/// 左右张望的 Clawd（用于加载中）：官方自动播放时的待机动作
struct LookingAroundMascot: View {
    var width: CGFloat = 40
    private let frames = MascotAnimation.idleLoop

    var body: some View {
        TimelineView(.periodic(from: .now, by: MascotAnimation.frameDuration)) { context in
            let i = Int(context.date.timeIntervalSinceReferenceDate / MascotAnimation.frameDuration) % frames.count
            MascotView(width: width, pose: frames[i].pose)
        }
    }
}
