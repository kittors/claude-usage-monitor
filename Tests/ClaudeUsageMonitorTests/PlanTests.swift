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
