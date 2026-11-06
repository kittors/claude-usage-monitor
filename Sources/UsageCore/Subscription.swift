import Foundation

/// 订阅的官方状态，来自账号资料（`GET /api/oauth/profile`）。
///
/// 订阅还在不在，以资料里认得出的付费套餐为准。Claude Code 也是这样：它只按 `organization_type` 判断订阅，不读状态字段。
/// `organization.subscription_status` 用的是 Stripe 的状态名，很可能只反映网页付款的那条订阅：
/// 改从 App Store、Google Play 订阅，或者以前的订阅取消过，它都可能停在 canceled，套餐却还在。
/// 所以它只用来发现付款问题，另外再看续费付款要不要验证（`payment_auth_hosted_invoice_url` 不为空）。
///
/// Claude Code 的登录令牌拿不到续费日期：账单接口 `subscription_details` 只接受 claude.ai 网页登录，
/// 所以本期什么时候结束按设置里的每月扣费日算（`SubscriptionTerm`），这里只判断订阅还在不在、付款有没有出问题。
public enum SubscriptionHealth: Equatable, Sendable {
    /// 还认得出付费套餐，或者状态是 active、trialing
    case active
    /// past_due：续费扣款没成功，Stripe 还在重试
    case paymentFailed
    /// 续费付款需要验证（例如银行卡的 3D Secure）
    case actionRequired
    /// 认不出付费套餐，状态也是 canceled、unpaid、incomplete_expired、paused 这类已经结束的状态
    case inactive

    /// - Parameters:
    ///   - status: `subscription_status` 原样传入
    ///   - paymentActionRequired: `payment_auth_hosted_invoice_url` 不为空
    ///   - hasPaidPlan: 账号资料里还认得出付费套餐
    /// - Returns: 认不出套餐、状态也说明不了什么时返回 nil，不下结论
    public init?(status: String?, paymentActionRequired: Bool, hasPaidPlan: Bool) {
        let raw = status?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch raw {
        case "canceled", "cancelled", "unpaid", "incomplete", "incomplete_expired", "paused", "expired", "ended":
            // 套餐还在，订阅就还在，结束的只是这条付款记录。已经结束的付款记录也不再要求付款
            self = hasPaidPlan ? .active : .inactive
        case _ where paymentActionRequired:
            self = .actionRequired
        case "past_due":
            self = .paymentFailed
        case "active", "trialing":
            self = .active
        default:
            // 没有状态（例如由组织付费的 Team）或认不出的新状态：套餐还在，订阅就还在。
            // 认不出套餐不等于没有套餐，不下结论
            guard hasPaidPlan else { return nil }
            self = .active
        }
    }
}

/// 本期订阅：按设置里的每月扣费日算，和「本月周期」是同一个时刻（扣费日的每周重置时刻）
public struct SubscriptionTerm: Equatable, Sendable {
    public var start: Date
    public var end: Date
    /// 还剩几天，按当地日历数：扣费日当天是 0，前一天是 1
    public var daysLeft: Int

    /// 到期前提醒的天数
    public static let reminderDays = [3, 1]

    public init(now: Date, anchorDay: Int, hour: Int = 0, minute: Int = 0, second: Int = 0, calendar: Calendar) {
        let period = UsageCalculator.billingInterval(
            now: now, anchorDay: anchorDay, hour: hour, minute: minute, second: second, calendar: calendar
        )
        start = period.start
        end = period.end
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: period.end)).day
        daysLeft = max(0, days ?? 0)
    }

    /// 还剩 3 天以内
    public var isEnding: Bool { daysLeft <= Self.reminderDays[0] }

    /// 刚进入新的一期（1 天以内）：续费有没有扣成功，要勤一点看官方状态
    public func justStarted(at now: Date) -> Bool {
        now.timeIntervalSince(start) < 86_400
    }

    /// 现在该发的到期提醒：还剩的天数落进了哪个提醒点（取最近的那个），这个点这一期还没提醒过才返回。
    /// 错过了 3 天那次（例如那几天没开机），到 1 天时只提醒一次。
    public func dueReminder(sent: Set<Int>) -> Int? {
        guard let point = Self.reminderDays.filter({ daysLeft <= $0 }).min(), !sent.contains(point) else { return nil }
        return point
    }
}
