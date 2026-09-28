import Foundation

/// 官方用量接口（`GET https://api.anthropic.com/api/oauth/usage`，即 Claude Code `/usage` 使用的接口）的一项限额。
public struct OfficialLimit: Sendable, Equatable {
    /// 已用百分比（0～100，可能超过 100）
    public var utilization: Double
    public var resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public var fraction: Double { utilization / 100 }
}

/// 按模型划分的周额度（例如 Fable）
public struct ScopedLimit: Sendable, Equatable, Identifiable {
    public var modelName: String
    public var limit: OfficialLimit
    public var id: String { modelName }
}

public struct OfficialUsage: Sendable, Equatable {
    public var fiveHour: OfficialLimit?
    public var sevenDay: OfficialLimit?
    public var sevenDaySonnet: OfficialLimit?
    public var sevenDayOpus: OfficialLimit?
    public var scoped: [ScopedLimit]
    public var fetchedAt: Date

    public init(fiveHour: OfficialLimit? = nil, sevenDay: OfficialLimit? = nil, sevenDaySonnet: OfficialLimit? = nil,
                sevenDayOpus: OfficialLimit? = nil, scoped: [ScopedLimit] = [], fetchedAt: Date = Date()) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayOpus = sevenDayOpus
        self.scoped = scoped
        self.fetchedAt = fetchedAt
    }

    public static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> OfficialUsage {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        func limit(_ l: Raw.Limit?) -> OfficialLimit? {
            guard let l, let u = l.utilization else { return nil }
            return OfficialLimit(utilization: u, resetsAt: l.resets_at?.date)
        }
        let scoped: [ScopedLimit] = (raw.limits ?? []).compactMap { item in
            guard item.kind == "weekly_scoped", let name = item.scope?.model?.display_name, let percent = item.percent else { return nil }
            return ScopedLimit(modelName: name, limit: OfficialLimit(utilization: percent, resetsAt: item.resets_at?.date))
        }
        return OfficialUsage(
            fiveHour: limit(raw.five_hour),
            sevenDay: limit(raw.seven_day),
            sevenDaySonnet: limit(raw.seven_day_sonnet),
            sevenDayOpus: limit(raw.seven_day_opus),
            scoped: scoped,
            fetchedAt: fetchedAt
        )
    }

    private struct Raw: Decodable {
        struct Limit: Decodable {
            let utilization: Double?
            let resets_at: FlexibleDate?
        }

        struct Scoped: Decodable {
            let kind: String?
            let percent: Double?
            let resets_at: FlexibleDate?
            let scope: Scope?

            struct Scope: Decodable {
                let model: Model?
                struct Model: Decodable { let display_name: String? }
            }
        }

        let five_hour: Limit?
        let seven_day: Limit?
        let seven_day_sonnet: Limit?
        let seven_day_opus: Limit?
        let limits: [Scoped]?
    }
}

/// `resets_at` 既可能是 ISO 8601 字符串，也可能是 Unix 秒数
private struct FlexibleDate: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            date = TokenParser.parseTimestamp(s).map { Date(timeIntervalSince1970: $0) }
        } else if let n = try? c.decode(Double.self) {
            date = Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        } else {
            date = nil
        }
    }
}
