import Foundation

/// 本周期内官方每周百分比的观测记录，用来识别「中途重置」：
/// 周额度偶尔会被提前清零，但例行重置时间不变。这时本机费用如果仍从周期起点算起就会偏大，
/// 由此反推的周预算也会被污染。
public struct WeeklyObservationLog: Codable, Sendable, Equatable {
    /// 本周期的例行重置时间（官方 `resets_at`），用来区分周期
    public private(set) var cycleEnd: Double = 0
    /// 检测到中途重置时，重置前最后一次看到原有水平的时间（重置发生在它之后）
    public private(set) var resetFloor: Double?
    /// 百分比每次变化时的首次观测
    public private(set) var observations: [WindowObservation] = []
    /// 明显下降的观测：等下一次观测确认，避免接口偶发的异常值被当成重置
    private var pendingDrop: WindowObservation?
    /// 最近一次观测的时间（忽略同一次请求的重复记录）
    private var lastSeen: Double = 0
    /// 最近一次看到正常水平（没有下降）的时间
    private var levelSeen: Double = 0

    public static let maxObservations = 500

    public init() {}

    public var resetFloorDate: Date? { resetFloor.map { Date(timeIntervalSince1970: $0) } }

    /// 记录一次官方观测；返回是否被接受（同一次请求的结果重复传入会被忽略）。
    /// 百分比不变时也会更新「最近一次看到正常水平」的时间，调用方应当保存。
    @discardableResult
    public mutating func record(utilization: Double, resetsAt: Date, at time: Date) -> Bool {
        let t = time.timeIntervalSince1970
        let end = resetsAt.timeIntervalSince1970
        guard end > t else { return false }
        let sample = WindowObservation(time: t, utilization: utilization)

        // 新的周期（例行重置，或官方调整了周期）：重新开始记录
        guard abs(cycleEnd - end) < 3600, !observations.isEmpty else {
            self = WeeklyObservationLog()
            cycleEnd = end
            observations = [sample]
            lastSeen = t
            levelSeen = t
            return true
        }
        guard t > lastSeen + 1 else { return false }
        lastSeen = t
        let last = observations[observations.count - 1]

        if utilization <= last.utilization - 3 {
            guard let first = pendingDrop else {
                pendingDrop = sample
                return true
            }
            // 连续两次明显低于之前：确认发生了中途重置，只保留重置之后的观测
            resetFloor = levelSeen
            observations = utilization == first.utilization ? [first] : [first, sample]
            pendingDrop = nil
            levelSeen = t
            return true
        }
        pendingDrop = nil
        levelSeen = t
        // 只记录百分比变化的时刻：此时本机累计费用与官方百分比的对应关系最清楚
        guard utilization != last.utilization else { return true }
        observations.append(sample)
        if observations.count > Self.maxObservations {
            observations.removeFirst(observations.count - Self.maxObservations)
        }
        return true
    }
}
