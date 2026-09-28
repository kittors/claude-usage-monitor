import Foundation
import UsageCore

/// 持续记录官方每周百分比（持久化，重启不丢），用于识别周额度的中途重置。
@MainActor
final class WeeklyResetTracker {
    private static let key = "weeklyResetTracker"
    private let defaults: UserDefaults
    private(set) var log: WeeklyObservationLog

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        log = defaults.string(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(WeeklyObservationLog.self, from: Data($0.utf8)) }
            ?? WeeklyObservationLog()
    }

    func record(_ limit: OfficialLimit, at time: Date) {
        guard let resetsAt = limit.resetsAt,
              log.record(utilization: limit.utilization, resetsAt: resetsAt, at: time),
              let data = try? JSONEncoder().encode(log)
        else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.key)
    }
}
