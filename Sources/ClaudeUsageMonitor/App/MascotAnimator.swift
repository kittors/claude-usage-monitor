import AppKit
import Observation

/// 菜单栏里 Clawd 的动作编排。动作全部取自 Claude Code（`MascotAnimation`，每帧 60 毫秒），这里只决定什么时候做哪一个：
/// 平时隔几秒眨眨眼、张望一下，或者随机做一个原地动作；Claude Code 正在用时动得勤一些，有新数据时跳一下，点一下图标也会动。
/// 拿着盾牌时，休息姿态是单手举起（官方拿东西的姿态）。出口不安全时只做张望、躲藏这类动作，正在确认出口时一直左右张望。
/// 系统开启「减弱动态效果」、屏幕休眠、切到其他用户或菜单栏看不见时停下，只保留休息姿态。
@MainActor
@Observable
final class MascotAnimator {
    enum Mood: Equatable {
        /// 出口安全，或者没有显示盾牌
        case calm
        /// 出口不安全
        case wary
        /// 正在重新确认出口
        case checking
    }

    static let shared = MascotAnimator()

    /// 当前这一帧。菜单栏和设置里的预览都画它。
    private(set) var frame = MascotFrame.rest
    /// 换了一帧：菜单栏只重画图标，不重算数值
    @ObservationIgnored var onFrame: ((MascotFrame) -> Void)?

    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var holdsShield = false
    @ObservationIgnored private var mood = Mood.calm
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var awake = true
    @ObservationIgnored private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// 正在播放的动作还没放完的帧
    @ObservationIgnored private var queue: ArraySlice<MascotFrame> = []
    @ObservationIgnored private var timer: Timer?
    /// 已经开始动了（停下时清掉）
    @ObservationIgnored private var started = false
    @ObservationIgnored private var hasEntered = false
    @ObservationIgnored private var lastAnimation: MascotAnimation?
    /// 最近一次有新的用量数据（Claude Code 正在用）
    @ObservationIgnored private var lastData = Date.distantPast
    @ObservationIgnored private var lastCheer = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// 不安全时只做这些：张望、躲起来再探头、四下看、跺脚
    private static let cautious: [MascotAnimation] = [.look, .peekaboo, .spin, .tap]
    /// 有新数据时跳一下：原地跳、跳完蹲一下、跳起来在空中转一圈
    private static let hops: [MascotAnimation] = [.jump, .celebrate, .coinHop]
    /// 有新数据后这么久之内算「正在用」
    private static let busyWindow: TimeInterval = 90

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ change: @escaping @MainActor (MascotAnimator) -> Void) {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    change(self)
                    self.update()
                }
            })
        }
        on(NSWorkspace.screensDidSleepNotification) { $0.awake = false }
        on(NSWorkspace.screensDidWakeNotification) { $0.awake = true }
        on(NSWorkspace.sessionDidResignActiveNotification) { $0.awake = false }
        on(NSWorkspace.sessionDidBecomeActiveNotification) { $0.awake = true }
        on(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            $0.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    private var isRunning: Bool { enabled && visible && awake && !reduceMotion }
    private var isPlaying: Bool { !queue.isEmpty }

    /// 休息时的姿态：拿着盾牌就单手举着
    private var restFrame: MascotFrame {
        MascotFrame(pose: .front(arms: holdsShield ? .oneUp : .down))
    }

    // MARK: 外部输入

    /// 菜单栏每次重画都会调用；只有设置、盾牌或出口状态变了才会改动作安排
    func configure(enabled: Bool, holdsShield: Bool, mood: Mood) {
        guard enabled != self.enabled || holdsShield != self.holdsShield || mood != self.mood else { return }
        let moodChanged = mood != self.mood
        self.enabled = enabled
        self.holdsShield = holdsShield
        self.mood = mood
        // 正在做的动作做完再说，下一个按新的状态挑
        guard isRunning, started, !isPlaying else { return update() }
        if !moodChanged {
            show(restFrame)
        } else if mood == .checking {
            // 开始确认出口：立刻张望
            glance()
        } else {
            rest()
        }
    }

    /// 菜单栏是否看得见（全屏应用隐藏菜单栏时看不见）
    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        update()
    }

    /// 有新的用量数据：跳一下。不打断正在做的动作，也不会跳得太密。
    func dataArrived() {
        let now = Date()
        lastData = now
        guard isRunning, started, !isPlaying, mood == .calm, now.timeIntervalSince(lastCheer) > 8 else { return }
        lastCheer = now
        play(pick(from: Self.hops))
    }

    /// 点了一下菜单栏图标：官方点 Clawd 时随机做一个原地动作。正在做动作时不理会。
    func poke() {
        guard isRunning, started, !isPlaying else { return }
        switch mood {
        case .calm: play(pick(from: MascotAnimation.inPlace))
        case .wary: play(pick(from: Self.cautious))
        case .checking: break
        }
    }

    // MARK: 编排

    /// 能动就开始，不能动就停在休息姿态
    private func update() {
        guard isRunning else { return stop() }
        guard !started else { return }
        started = true
        // 第一次像官方入场那样随机来一段，之后从休息开始
        if !hasEntered {
            hasEntered = true
            if mood == .calm { return play(pick(from: MascotAnimation.entrances)) }
        }
        rest()
    }

    private func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        queue = []
        show(restFrame)
    }

    private func play(_ animation: MascotAnimation) {
        lastAnimation = animation
        play(animation.frames)
    }

    private func play(_ frames: [MascotFrame]) {
        queue = frames[...]
        advance()
    }

    private func advance() {
        guard let next = queue.popFirst() else {
            rest()
            return
        }
        // 官方动作最后回到站立；拿着盾牌时回到举盾
        show(queue.isEmpty && next == .rest ? restFrame : next)
        wait(MascotAnimation.frameDuration) { $0.advance() }
    }

    /// 休息一会儿再做下一个动作
    private func rest() {
        queue = []
        show(restFrame)
        let busy = Date().timeIntervalSince(lastData) < Self.busyWindow
        let pause: ClosedRange<TimeInterval> = switch mood {
        case .checking: 0.2...0.5
        case .wary: 1.6...3.2
        case .calm: busy ? 1.2...2.8 : 2.4...5.2
        }
        wait(.random(in: pause)) { $0.nextMove() }
    }

    private func nextMove() {
        let roll = Double.random(in: 0..<1)
        switch mood {
        case .checking:
            glance()
        case .wary:
            if roll < 0.25 { blink() } else if roll < 0.7 { glance() } else { play(pick(from: Self.cautious)) }
        case .calm:
            if roll < 0.3 { blink() } else if roll < 0.45 { glance() } else { play(pick(from: MascotAnimation.inPlace)) }
        }
    }

    private func blink() {
        play(MascotAnimation.blink(restFrame))
    }

    /// 只动眼睛的张望：手里的盾牌不放下
    private func glance() {
        let pose = restFrame.pose
        play(
            Array(repeating: MascotFrame(pose: pose.eyes(.right)), count: 5)
                + Array(repeating: MascotFrame(pose: pose.eyes(.left)), count: 5)
                + [restFrame]
        )
    }

    /// 随机挑一个，不连着做同一个
    private func pick(from animations: [MascotAnimation]) -> MascotAnimation {
        let choices = animations.count > 1 ? animations.filter { $0 != lastAnimation } : animations
        return choices.randomElement() ?? .look
    }

    private func show(_ frame: MascotFrame) {
        guard frame != self.frame else { return }
        self.frame = frame
        onFrame?(frame)
    }

    private func wait(_ seconds: TimeInterval, then action: @escaping @MainActor (MascotAnimator) -> Void) {
        timer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                action(self)
            }
        }
        timer.tolerance = min(0.1, seconds * 0.15)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
