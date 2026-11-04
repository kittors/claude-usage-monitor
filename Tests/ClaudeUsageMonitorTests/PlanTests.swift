import Foundation
import Testing
import UsageCore
@testable import ClaudeUsageMonitor

@Test func subscriptionNamesKeepPublishedCacheValues() throws {
    #expect(Plan.allCases.map(\.title) == ["Pro", "Max", "Ultra", "Team", "Enterprise"])
    for (raw, title) in [("pro", "Pro"), ("max5x", "Max"), ("max20x", "Ultra"),
                         ("team", "Team"), ("enterprise", "Enterprise")] {
        let plan = try #require(Plan(rawValue: raw))
        #expect(plan.title == title)
        #expect(try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(plan)) == plan)
    }
    #expect(Plan(rawValue: "unknown") == nil)
}

@Test func profileRecognizesCurrentAndLegacySubscriptions() throws {
    let samples: [(String, String?, String)] = [
        ("claude_pro", nil, "Pro"),
        ("claude_max", nil, "Max"),
        ("claude_max", "default_claude_max_5x", "Max"),
        ("claude_max", "default_claude_max_20x", "Ultra"),
        ("CLAUDE_MAX", "DEFAULT_CLAUDE_MAX_20X", "Ultra"),
        ("claude_team", nil, "Team"),
        ("claude_enterprise", nil, "Enterprise"),
    ]
    for (organization, tier, title) in samples {
        var fields = ["organization_type": organization]
        fields["rate_limit_tier"] = tier
        let data = try JSONSerialization.data(withJSONObject: ["organization": fields])
        let profile = try #require(AccountProfile.decode(data))
        #expect(profile.plan?.title == title, "\(organization), \(tier ?? "no tier")")
    }
    #expect(AccountProfile.decode(Data(#"{"organization":{}}"#.utf8))?.plan == nil)
    #expect(AccountProfile.decode(Data(#"{"organization":{"organization_type":"unknown"}}"#.utf8))?.plan == nil)
    #expect(AccountProfile.decode(Data("invalid".utf8)) == nil)
}

@Test func profileReadsTheSubscriptionStatus() throws {
    // 和 2026-11 官方响应同样的结构（数值是编的）
    let active = try #require(AccountProfile.decode(Data("""
    {"account":{"has_claude_max":true},"organization":{"organization_type":"claude_max",
    "rate_limit_tier":"default_claude_max_20x","billing_type":"stripe_subscription",
    "subscription_created_at":"2026-01-02T03:04:05.000000Z","subscription_status":"active",
    "payment_auth_hosted_invoice_url":null}}
    """.utf8)))
    #expect(active.plan == .ultra)
    #expect(active.subscriptionStatus == "active")
    #expect(active.paymentActionURL == nil)
    #expect(active.health == .active)

    let unpaid = try #require(AccountProfile.decode(Data("""
    {"organization":{"organization_type":"claude_pro","subscription_status":"past_due",
    "payment_auth_hosted_invoice_url":"https://invoice.stripe.com/i/example"}}
    """.utf8)))
    #expect(unpaid.paymentActionURL?.host == "invoice.stripe.com")
    #expect(unpaid.health == .actionRequired)

    let failed = try #require(AccountProfile.decode(Data(#"{"organization":{"organization_type":"claude_max","subscription_status":"past_due","payment_auth_hosted_invoice_url":""}}"#.utf8)))
    #expect(failed.paymentActionURL == nil)
    #expect(failed.health == .paymentFailed)

    // 订阅结束后没有状态，也认不出付费套餐
    let ended = try #require(AccountProfile.decode(Data(#"{"organization":{"organization_type":"claude_free"}}"#.utf8)))
    #expect(ended.plan == nil)
    #expect(ended.health == .inactive)

    // 只有旧字段：照旧认出套餐，订阅状态不下结论
    let legacy = try #require(AccountProfile.decode(Data(#"{"organization":{"organization_type":"claude_team"}}"#.utf8)))
    #expect(legacy.plan == .team)
    #expect(legacy.health == nil)
}

@Test @MainActor func missingFiveHourLimitDoesNotCreateAnIdleLimit() throws {
    // Synthetic usage response: Ultra can have weekly limits without a 5-hour limit.
    for fiveHour in ["", #""five_hour":null,"#] {
        let usage = try OfficialUsage.decode(Data("""
        {\(fiveHour)"seven_day":{"utilization":42,"resets_at":"2099-01-01T00:00:00Z"}}
        """.utf8))
        let rows = UsageStore.rows(from: usage, now: Date())
        #expect(rows.map(\.id) == ["week"])
        #expect(rows.first?.percent == 42)
    }
}

@Test @MainActor func explicitIdleFiveHourLimitStillShows() {
    let usage = OfficialUsage(fiveHour: OfficialLimit(utilization: 0, resetsAt: nil))
    let rows = UsageStore.rows(from: usage, now: Date())
    #expect(rows.count == 1)
    #expect(rows.first?.id == "five")
    #expect(rows.first?.percent == 0)
    #expect(rows.first?.reset == .idle)
}

@Test @MainActor func reportedLimitsRemainVisibleForEveryPlan() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let reset = now.addingTimeInterval(3600)
    let usage = OfficialUsage(
        fiveHour: OfficialLimit(utilization: 12, resetsAt: reset),
        sevenDay: OfficialLimit(utilization: 42, resetsAt: reset),
        scoped: [ScopedLimit(modelName: "Fable", limit: OfficialLimit(utilization: 25, resetsAt: reset))]
    )
    let rows = UsageStore.rows(from: usage, now: now)
    #expect(rows.map(\.id) == ["five", "week", "scoped-Fable"])
    #expect(rows.map(\.percent) == [12, 42, 25])
    #expect(rows.first?.reset == .countdown(reset))
}
