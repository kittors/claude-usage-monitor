import Foundation

/// Claude Code 自己查到的官方用量。
///
/// Claude Code 每次读官方用量接口（`/usage`、额度快到顶时等），都会把原始响应连同查询时间和账号，
/// 存进全局配置（`~/.claude.json`）的 `cachedUsageUtilization`。数字和本 App 自己查的完全一样，读它不用发任何请求：
/// 官方接口被限流时，界面也能跟上 Claude Code 刚查到的数字；Claude Code 刚查过时，本 App 也就不必再查一次。
public struct ClaudeCodeUsageCache: Sendable, Equatable {
    public var usage: OfficialUsage
    /// 这份数字属于哪个账号（Claude Code 的 `accountUuid`，与账号资料接口的 `account.uuid` 相同）
    public var accountUUID: String

    public init(usage: OfficialUsage, accountUUID: String) {
        self.usage = usage
        self.accountUUID = accountUUID
    }

    /// 刚查到这么久以内的，直接当作本 App 这次查到的（与 Claude Code 自己复用这份缓存的时限相同）
    public static let freshness: TimeInterval = 60

    /// Claude Code 的全局配置文件：设置了 `CLAUDE_CONFIG_DIR` 时在那个目录里，否则是 `~/.claude.json`
    public static func configFiles(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var files: [URL] = []
        if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            for part in config.split(separator: ",") where !part.isEmpty {
                files.append(URL(fileURLWithPath: String(part)).appendingPathComponent(".claude.json"))
            }
        }
        files.append(home.appendingPathComponent(".claude.json"))
        return files
    }

    /// 从配置文件的内容里取出缓存的用量。没有缓存、格式认不出、没有任何限额，
    /// 或者配置里当前登录的账号已经换了（与 Claude Code 自己的判断相同）时为 nil
    public static func parse(_ data: Data) -> ClaudeCodeUsageCache? {
        ClaudeCodeConfig.parse(data)?.usage
    }

    static func parse(json: [String: Any]) -> ClaudeCodeUsageCache? {
        guard let cached = json["cachedUsageUtilization"] as? [String: Any],
              let ms = (cached["fetchedAtMs"] as? NSNumber)?.doubleValue, ms.isFinite, ms > 0,
              let account = cached["accountUuid"] as? String, !account.isEmpty,
              let body = cached["utilization"] as? [String: Any],
              let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let usage = try? OfficialUsage.decode(bodyData, fetchedAt: Date(timeIntervalSince1970: ms / 1000))
        else { return nil }
        if let current = (json["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, current != account {
            return nil
        }
        let hasLimit = usage.fiveHour != nil || usage.sevenDay != nil || usage.sevenDaySonnet != nil
            || usage.sevenDayOpus != nil || !usage.scoped.isEmpty
        return hasLimit ? ClaudeCodeUsageCache(usage: usage, accountUUID: account) : nil
    }

    /// 能不能换上这份数字：同一个账号（本 App 还不知道自己的账号时不换），比现在显示的新，
    /// 而且不是来自未来（系统时间不准时宁可不用）
    public func replaces(_ shown: Date?, account: String?, now: Date) -> Bool {
        guard let account, account == accountUUID else { return false }
        let fetched = usage.fetchedAt
        guard fetched.timeIntervalSince(now) < 60 else { return false }
        guard let shown else { return true }
        return fetched.timeIntervalSince(shown) > 1
    }

    /// 刚查到不久，可以代替本 App 这次的查询
    public func isFresh(at now: Date) -> Bool {
        abs(now.timeIntervalSince(usage.fetchedAt)) < Self.freshness
    }
}

/// Claude Code 现在登录的账号（全局配置里的 `oauthAccount`）。
///
/// Claude Code 登录（`/login`、`claude auth login`）时和钥匙串里的令牌一起写进去，退出登录时删掉，
/// 所以不用发请求就能知道换没换账号。套餐那两项是它从账号资料缓存的，刚登录完可能还没有。
public struct ClaudeCodeAccount: Sendable, Equatable {
    /// 与账号资料接口的 `account.uuid` 相同
    public var uuid: String
    public var email: String?
    /// 与账号资料里的 `organization_type`、`rate_limit_tier` 相同
    public var organizationType: String?
    public var rateLimitTier: String?

    public init(uuid: String, email: String? = nil, organizationType: String? = nil, rateLimitTier: String? = nil) {
        self.uuid = uuid
        self.email = email
        self.organizationType = organizationType
        self.rateLimitTier = rateLimitTier
    }

    init?(json: [String: Any]) {
        func text(_ key: String) -> String? {
            (json[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let uuid = text("accountUuid") else { return nil }
        self.init(uuid: uuid, email: text("emailAddress"), organizationType: text("organizationType"),
                  rateLimitTier: text("organizationRateLimitTier"))
    }
}

/// 读一次 Claude Code 全局配置拿到的两样：现在登录的账号，和它缓存的用量
public struct ClaudeCodeConfig: Sendable, Equatable {
    /// 为 nil 时配置里没有登录（退出登录了，或者从来没登录过）
    public var account: ClaudeCodeAccount?
    public var usage: ClaudeCodeUsageCache?

    public init(account: ClaudeCodeAccount?, usage: ClaudeCodeUsageCache?) {
        self.account = account
        self.usage = usage
    }

    /// 不是 JSON 对象时为 nil
    public static func parse(_ data: Data) -> ClaudeCodeConfig? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ClaudeCodeConfig(
            account: (json["oauthAccount"] as? [String: Any]).flatMap(ClaudeCodeAccount.init(json:)),
            usage: ClaudeCodeUsageCache.parse(json: json)
        )
    }

    /// 和本 App 读的钥匙串条目「Claude Code-credentials」对应的那份配置。
    /// Claude Code 设置了 `CLAUDE_CONFIG_DIR` 时令牌存在另一个条目里，那份配置里的账号和本 App 用的登录对不上
    public static func homeFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude.json")
    }
}
