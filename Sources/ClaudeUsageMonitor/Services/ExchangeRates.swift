import Foundation
import Observation
import UsageCore

/// 美元对其它货币的牌价。启动时和每小时从 Frankfurter 拉一次，失败时沿用上次的结果。
@MainActor
@Observable
final class ExchangeRates {
    static let shared = ExchangeRates()

    private(set) var perUSD: [String: Double]
    private(set) var fetchedAt: Date?

    @ObservationIgnored private var inFlight = false
    nonisolated static let endpoint = URL(string: "https://api.frankfurter.app/latest?from=USD")!
    static let refreshInterval: TimeInterval = 60 * 60

    private init() {
        let d = UserDefaults.standard
        perUSD = d.dictionary(forKey: "fxPerUSD") as? [String: Double] ?? [:]
        if let stamp = d.object(forKey: "fxFetchedAt") as? Double {
            fetchedAt = Date(timeIntervalSince1970: stamp)
        }
    }

    func rate(for unit: MoneyFormat.Unit) -> Double {
        if unit == .usd { return 1 }
        if let rate = perUSD[unit.code], rate > 0, rate.isFinite { return rate }
        return unit.fallbackPerUSD
    }

    func refreshIfStale() {
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.refreshInterval { return }
        refresh()
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        Task {
            let data = try? await URLSession.shared.data(from: Self.endpoint).0
            let parsed = data.flatMap { try? FXRates.perUSD(fromFrankfurter: $0) }
            inFlight = false
            guard let parsed, parsed["EUR"] != nil else { return }
            perUSD = parsed
            fetchedAt = Date()
            let d = UserDefaults.standard
            d.set(parsed, forKey: "fxPerUSD")
            d.set(fetchedAt?.timeIntervalSince1970, forKey: "fxFetchedAt")
        }
    }
}
