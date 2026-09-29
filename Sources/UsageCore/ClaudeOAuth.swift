import Foundation

/// Claude Code 的登录凭据（钥匙串「Claude Code-credentials」里 JSON 的 `claudeAiOauth` 部分）与续期规则。
///
/// 续期完全照搬 Claude Code CLI（2.1.x）的做法，因此 App 与 Claude Code 可以同时运行、互不干扰：
/// 同样的续期锁、拿到锁后重新读取、同样的请求参数与合并规则、写回前再核对一次（见 `CredentialRenewal`）。
public enum ClaudeOAuth {
    public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code 的 OAuth 客户端（凭据里没有 `clientId` 时使用）
    public static let defaultClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let inferenceScope = "user:inference"
    /// Claude Code 登录 claude.ai 时申请的权限
    static let claudeAIScopes = ["user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers", "user:file_upload"]
    /// 续期时会保留下来的扩展权限
    static let preservableScopes = ["user:projects:read", "user:projects:write"]
    /// 与 Claude Code 一致：离过期不到 5 分钟就续期
    public static let refreshMargin: TimeInterval = 5 * 60

    public struct Credentials: Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date?
        public var scopes: [String]
        public var subscriptionType: String?
        public var rateLimitTier: String?
        public var clientID: String?
        /// refresh token 自身的有效期：到期后无法再续期，需要在 Claude Code 中重新登录
        public var refreshTokenExpiresAt: Date?

        public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, scopes: [String] = [],
                    subscriptionType: String? = nil, rateLimitTier: String? = nil, clientID: String? = nil,
                    refreshTokenExpiresAt: Date? = nil) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.scopes = scopes
            self.subscriptionType = subscriptionType
            self.rateLimitTier = rateLimitTier
            self.clientID = clientID
            self.refreshTokenExpiresAt = refreshTokenExpiresAt
        }

        /// 已过期或即将过期（与 Claude Code 判断续期的时机相同）
        public func needsRefresh(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return now.addingTimeInterval(ClaudeOAuth.refreshMargin) >= expiresAt
        }

        public func isExpired(now: Date = Date()) -> Bool {
            expiresAt.map { $0 <= now } ?? false
        }

        /// 与 Claude Code 相同的条件：有 refresh token，并且是 claude.ai 的登录
        public var isRefreshable: Bool {
            guard let refreshToken, !refreshToken.isEmpty else { return false }
            return scopes.contains(ClaudeOAuth.inferenceScope) || subscriptionType != nil
        }
    }

    /// 解析钥匙串（或 `~/.claude/.credentials.json`）中保存的 JSON
    public static func credentials(from data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        func date(_ key: String) -> Date? {
            (oauth[key] as? NSNumber).flatMap { $0.doubleValue > 0 ? Date(timeIntervalSince1970: $0.doubleValue / 1000) : nil }
        }
        return Credentials(
            accessToken: token,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: date("expiresAt"),
            scopes: (oauth["scopes"] as? [Any])?.compactMap { $0 as? String } ?? [],
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String,
            clientID: oauth["clientId"] as? String,
            refreshTokenExpiresAt: date("refreshTokenExpiresAt")
        )
    }

    /// 登录信息还在、令牌却被清空：Claude Code 续期被拒绝（通常是登录到期）后会这样处理，需要重新登录
    public static func hasClearedLogin(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any]
        else { return false }
        return (oauth["accessToken"] as? String)?.isEmpty ?? true
    }

    // MARK: 续期请求

    /// 续期时申请的权限：默认客户端申请 Claude Code 的整套权限（并保留已有的扩展权限）；
    /// `expanded` 表示与原有权限不同，服务端拒绝（`invalid_scope`）时可以退回原有权限重试。
    public static func refreshScopes(for c: Credentials) -> (scopes: [String], expanded: Bool) {
        let expanded = (c.scopes.contains(inferenceScope) || c.subscriptionType != nil) && c.clientID == nil
        guard expanded else { return (c.scopes, false) }
        var result: [String] = []
        for scope in claudeAIScopes + c.scopes.filter(preservableScopes.contains) where !result.contains(scope) {
            result.append(scope)
        }
        return (result, true)
    }

    public static func refreshRequest(refreshToken: String, scopes: [String], clientID: String?) -> URLRequest {
        var request = URLRequest(url: tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID ?? defaultClientID,
            "scope": (scopes.isEmpty ? claudeAIScopes : scopes).joined(separator: " "),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 续期成功后服务端返回的新令牌
    public struct Grant: Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String
        /// 毫秒时间戳（与 Claude Code 保存的格式相同）
        public var expiresAt: Int64
        public var refreshTokenExpiresAt: Int64?
        public var scopes: [String]

        /// 是否是 claude.ai 的登录（Claude Code 只保存这种令牌）
        public var isClaudeAILogin: Bool { scopes.contains(ClaudeOAuth.inferenceScope) }
    }

    /// - Parameter requestedScopes: 响应里没有 `scope` 时，按 OAuth 规范（RFC 6749 §5.1）授予的就是申请的权限
    public static func grant(from data: Data, previousRefreshToken: String, requestedScopes: [String] = [], now: Date = Date()) -> Grant? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty,
              let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0
        else { return nil }
        let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let refresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? previousRefreshToken
        return Grant(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: nowMs + Int64(expiresIn * 1000),
            refreshTokenExpiresAt: (json["refresh_token_expires_in"] as? NSNumber).map { nowMs + Int64($0.doubleValue * 1000) },
            scopes: (json["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? requestedScopes
        )
    }

    /// 续期失败的原因（按 OAuth 错误码区分）
    public enum RequestError: Error, Equatable {
        /// refresh token 已失效：需要在 Claude Code 中重新登录
        case invalidGrant
        /// 申请的权限不被接受
        case invalidScope
        case http(Int)
    }

    public static func requestError(status: Int, body: Data?) -> RequestError {
        var code: String?
        if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? String {
                code = error
            } else if let error = json["error"] as? [String: Any] {
                code = error["type"] as? String
            }
        }
        if (status == 400 || status == 401), code == "invalid_grant" { return .invalidGrant }
        if status == 400, code == "invalid_scope" { return .invalidScope }
        return .http(status)
    }

    // MARK: 写回

    /// 把新令牌合并进原有的 JSON（与 Claude Code 相同的规则）：只替换 `claudeAiOauth`，
    /// 其余内容（例如 MCP 服务器的登录）原样保留；订阅类型、速率档位、refresh token 的有效期沿用原值。
    public static func merged(_ original: Data, with grant: Grant, clientID: String?) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else { return nil }
        let old = root["claudeAiOauth"] as? [String: Any]
        func kept(_ key: String) -> Any? {
            guard let value = old?[key], !(value is NSNull) else { return nil }
            return value
        }
        var oauth: [String: Any] = [
            "accessToken": grant.accessToken,
            "refreshToken": grant.refreshToken,
            "expiresAt": grant.expiresAt,
            "scopes": grant.scopes,
            "subscriptionType": kept("subscriptionType") ?? NSNull(),
            "rateLimitTier": kept("rateLimitTier") ?? NSNull(),
        ]
        if let expires = grant.refreshTokenExpiresAt.map({ $0 as Any }) ?? kept("refreshTokenExpiresAt") {
            oauth["refreshTokenExpiresAt"] = expires
        }
        if let clientID { oauth["clientId"] = clientID }
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
    }

    /// 续期后的凭据（写回之后内存中使用）
    public static func credentials(from grant: Grant, previous: Credentials) -> Credentials {
        Credentials(
            accessToken: grant.accessToken,
            refreshToken: grant.refreshToken,
            expiresAt: Date(timeIntervalSince1970: Double(grant.expiresAt) / 1000),
            scopes: grant.scopes,
            subscriptionType: previous.subscriptionType,
            rateLimitTier: previous.rateLimitTier,
            clientID: previous.clientID,
            refreshTokenExpiresAt: grant.refreshTokenExpiresAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
                ?? previous.refreshTokenExpiresAt
        )
    }
}
