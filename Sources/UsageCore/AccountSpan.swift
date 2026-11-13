import Foundation

/// 本机从 `since` 起登录的是哪个 Claude 账号，一直到下一段开始。
///
/// 本机的消耗记录里没有账号。换过账号的那一周，本机花的有一部分是别的账号的：记下每次换账号的时刻，
/// 折算额度时把登录别的账号那几段花的分出去，不占现在这个账号的额度，也不拿去对应它的百分比。
public struct AccountSpan: Codable, Equatable, Sendable {
    /// 账号的 uuid
    public var account: String
    public var since: Date

    public init(account: String, since: Date) {
        self.account = account
        self.since = since
    }

    /// 只记最近这么久：额度按周算，用不到更早的
    public static let kept: TimeInterval = 8 * 86_400

    /// 在 `now` 从 `previous` 换成 `next` 之后的记录。第一次换时补上「之前一直是 `previous`」；
    /// 比 8 天更早的段只留最后一个（它一直延续到下一段开始）
    public static func switching(_ spans: [AccountSpan], from previous: String, to next: String, at now: Date) -> [AccountSpan] {
        var spans = spans
        if spans.isEmpty { spans.append(AccountSpan(account: previous, since: .distantPast)) }
        spans.append(AccountSpan(account: next, since: now))
        let cutoff = now.addingTimeInterval(-kept)
        if let recent = spans.firstIndex(where: { $0.since >= cutoff }), recent > 1 {
            spans.removeFirst(recent - 1)
        }
        return spans
    }

    /// 本机登录的不是 `account` 的那几段
    public static func away(from account: String, in spans: [AccountSpan]) -> [DateInterval] {
        var result: [DateInterval] = []
        for (i, span) in spans.enumerated() where span.account != account {
            let end = i + 1 < spans.count ? spans[i + 1].since : .distantFuture
            if end > span.since { result.append(DateInterval(start: span.since, end: end)) }
        }
        return result
    }
}
