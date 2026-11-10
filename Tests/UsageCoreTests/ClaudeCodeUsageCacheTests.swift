import Foundation
import Testing
@testable import UsageCore

// MARK: - Claude Code 缓存的官方用量

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let account = "00000000-0000-4000-8000-000000000001"

/// 与 Claude Code 2.1.321 写进 `~/.claude.json` 的结构相同（只留用得到的字段）
private func config(fetchedAt: Date = now, cachedAccount: String? = account, signedIn: String? = account,
                    utilization: String = #"{"five_hour":null,"seven_day":{"utilization":1,"resets_at":"2026-11-14T14:00:00.670325+00:00"},"limits":[{"kind":"weekly_all","group":"weekly","percent":1,"severity":"normal","resets_at":"2026-11-14T14:00:00.670325+00:00","scope":null,"is_active":true},{"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":"2026-11-14T14:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}],"extra_usage":{"is_enabled":false}}"#) -> Data {
    var cached = ""
    if let cachedAccount { cached = #","accountUuid":"\#(cachedAccount)""# }
    var oauth = ""
    if let signedIn { oauth = #""oauthAccount":{"accountUuid":"\#(signedIn)","emailAddress":"someone@example.com"},"# }
    let ms: Int = Int(fetchedAt.timeIntervalSince1970) * 1000
    let text: String = "{" + oauth + #""numStartups":12,"cachedUsageUtilization":{"fetchedAtMs":"# + String(ms)
        + cached + #","utilization":"# + utilization + "}}"
    return Data(text.utf8)
}

@Test func readsTheUsageClaudeCodeCached() throws {
    let cache = try #require(ClaudeCodeUsageCache.parse(config()))
    #expect(cache.accountUUID == account)
    #expect(cache.usage.fetchedAt == now)
    #expect(cache.usage.fiveHour == nil)
    #expect(cache.usage.sevenDay?.percent == 1)
    let reset = try #require(cache.usage.sevenDay?.resetsAt)
    let gap: Double = reset.timeIntervalSince1970 - 1_794_664_800.670325
    #expect(abs(gap) < 0.001)
    #expect(cache.usage.scoped.map(\.modelName) == ["Fable"])
    #expect(cache.usage.extraUsageEnabled == false)
}

@Test func ignoresCachesThatAreMissingOrBelongToAnotherLogin() {
    // 没有缓存、不是 JSON
    #expect(ClaudeCodeUsageCache.parse(Data(#"{"numStartups":1}"#.utf8)) == nil)
    #expect(ClaudeCodeUsageCache.parse(Data("not json".utf8)) == nil)
    // 没记下账号的不用：分不清是谁的数字
    #expect(ClaudeCodeUsageCache.parse(config(cachedAccount: nil)) == nil)
    // Claude Code 已经换了账号登录：与它自己的判断一样，旧账号的缓存不算数
    #expect(ClaudeCodeUsageCache.parse(config(signedIn: "00000000-0000-4000-8000-000000000002")) == nil)
    // 配置里没有登录信息时只看缓存自己记的账号
    #expect(ClaudeCodeUsageCache.parse(config(signedIn: nil))?.accountUUID == account)
    // 一项限额都没有（例如接口返回了错误）
    #expect(ClaudeCodeUsageCache.parse(config(utilization: #"{"error":{"type":"rate_limit_error"}}"#)) == nil)
    #expect(ClaudeCodeUsageCache.parse(config(utilization: "[]")) == nil)
}

@Test func onlyNewerNumbersOfTheSameAccountReplaceWhatIsShown() throws {
    let cache = try #require(ClaudeCodeUsageCache.parse(config()))
    // 比现在显示的新、同一个账号：换上
    #expect(cache.replaces(now.addingTimeInterval(-41 * 60), account: account, now: now))
    #expect(cache.replaces(nil, account: account, now: now))
    // 不比现在显示的新
    #expect(!cache.replaces(now, account: account, now: now))
    #expect(!cache.replaces(now.addingTimeInterval(30), account: account, now: now))
    // 还不知道本 App 的账号，或者是别的账号
    #expect(!cache.replaces(nil, account: nil, now: now))
    #expect(!cache.replaces(nil, account: "00000000-0000-4000-8000-000000000002", now: now))
    // 来自未来（系统时间不准）
    #expect(!cache.replaces(nil, account: account, now: now.addingTimeInterval(-5 * 60)))
}

@Test func onlyJustCheckedNumbersStandInForARequest() throws {
    let cache = try #require(ClaudeCodeUsageCache.parse(config()))
    #expect(cache.isFresh(at: now.addingTimeInterval(30)))
    #expect(!cache.isFresh(at: now.addingTimeInterval(ClaudeCodeUsageCache.freshness)))
    #expect(!cache.isFresh(at: now.addingTimeInterval(10 * 60)))
}

@Test func findsClaudeCodesGlobalConfig() {
    let home = URL(fileURLWithPath: "/Users/someone")
    let plain: [String] = ClaudeCodeUsageCache.configFiles(environment: [:], home: home).map(\.path)
    #expect(plain == ["/Users/someone/.claude.json"])
    let custom: [String] = ClaudeCodeUsageCache.configFiles(environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude"], home: home).map(\.path)
    #expect(custom == ["/tmp/claude/.claude.json", "/Users/someone/.claude.json"])
}
