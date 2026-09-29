import Foundation
import Testing
@testable import UsageCore

// MARK: - 凭据与续期规则

private func json(_ data: Data?) -> [String: Any] {
    (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

private let storedJSON = """
{"claudeAiOauth":{"accessToken":"at-old","refreshToken":"rt-old","expiresAt":1790000000000,\
"scopes":["user:inference","user:profile","user:projects:read"],"subscriptionType":"max",\
"rateLimitTier":"default_claude_max_20x","refreshTokenExpiresAt":1799999999000,"legacyField":1},\
"mcpOAuth":{"server|abc":{"serverUrl":"https://example.com/mcp","accessToken":"mcp-token","expiresAt":1790000000123}}}
"""

@Test func parsesStoredCredentials() throws {
    let c = try #require(ClaudeOAuth.credentials(from: Data(storedJSON.utf8)))
    #expect(c.accessToken == "at-old")
    #expect(c.refreshToken == "rt-old")
    #expect(c.expiresAt == Date(timeIntervalSince1970: 1_790_000_000))
    #expect(c.scopes == ["user:inference", "user:profile", "user:projects:read"])
    #expect(c.subscriptionType == "max")
    #expect(c.clientID == nil)
    #expect(c.isRefreshable)
    #expect(c.refreshTokenExpiresAt == Date(timeIntervalSince1970: 1_799_999_999))
    // Claude Code 在续期被拒绝后会清空令牌：需要重新登录
    let cleared = Data(#"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"subscriptionType":"max"}}"#.utf8)
    #expect(ClaudeOAuth.credentials(from: cleared) == nil)
    #expect(ClaudeOAuth.hasClearedLogin(cleared))
    #expect(!ClaudeOAuth.hasClearedLogin(Data(storedJSON.utf8)))
    #expect(!ClaudeOAuth.hasClearedLogin(Data("not json".utf8)))
}

@Test func refreshesFiveMinutesBeforeExpiry() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var c = ClaudeOAuth.Credentials(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(6 * 60), scopes: ["user:inference"])
    #expect(!c.needsRefresh(now: now))
    c.expiresAt = now.addingTimeInterval(4 * 60)
    #expect(c.needsRefresh(now: now))
    #expect(!c.isExpired(now: now))
    c.expiresAt = nil
    #expect(!c.needsRefresh(now: now))
    // 不是 claude.ai 的登录，或没有 refresh token：不能续期
    #expect(!ClaudeOAuth.Credentials(accessToken: "a", refreshToken: "r", scopes: ["org:create_api_key"]).isRefreshable)
    #expect(!ClaudeOAuth.Credentials(accessToken: "a", refreshToken: "", scopes: ["user:inference"]).isRefreshable)
    #expect(ClaudeOAuth.Credentials(accessToken: "a", refreshToken: "r", subscriptionType: "pro").isRefreshable)
}

@Test func refreshRequestMatchesClaudeCode() throws {
    let c = try #require(ClaudeOAuth.credentials(from: Data(storedJSON.utf8)))
    let (scopes, expanded) = ClaudeOAuth.refreshScopes(for: c)
    #expect(expanded)
    #expect(scopes == ["user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers", "user:file_upload", "user:projects:read"])

    var custom = c
    custom.clientID = "other-client"
    #expect(ClaudeOAuth.refreshScopes(for: custom) == (c.scopes, false))

    let request = ClaudeOAuth.refreshRequest(refreshToken: "rt-old", scopes: scopes, clientID: nil)
    #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = json(request.httpBody)
    #expect(body["grant_type"] as? String == "refresh_token")
    #expect(body["refresh_token"] as? String == "rt-old")
    #expect(body["client_id"] as? String == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    #expect(body["scope"] as? String == scopes.joined(separator: " "))
    #expect(body.count == 4)
}

@Test func parsesTokenResponses() throws {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let data = Data(#"{"access_token":"at-new","refresh_token":"rt-new","expires_in":28800,"refresh_token_expires_in":2592000,"scope":"user:inference user:profile","token_type":"Bearer"}"#.utf8)
    let grant = try #require(ClaudeOAuth.grant(from: data, previousRefreshToken: "rt-old", now: now))
    #expect(grant.accessToken == "at-new")
    #expect(grant.refreshToken == "rt-new")
    #expect(grant.expiresAt == 1_790_000_000_000 + 28_800_000)
    #expect(grant.refreshTokenExpiresAt == Int64(1_792_592_000_000))
    #expect(grant.scopes == ["user:inference", "user:profile"])
    #expect(grant.isClaudeAILogin)

    // 服务端没有返回新的 refresh token：沿用原来的
    let kept = try #require(ClaudeOAuth.grant(from: Data(#"{"access_token":"x","expires_in":60,"scope":""}"#.utf8), previousRefreshToken: "rt-old", now: now))
    #expect(kept.refreshToken == "rt-old")
    #expect(kept.refreshTokenExpiresAt == nil)
    #expect(ClaudeOAuth.grant(from: Data(#"{"expires_in":60}"#.utf8), previousRefreshToken: "r") == nil)

    #expect(ClaudeOAuth.requestError(status: 400, body: Data(#"{"error":"invalid_grant","error_description":"Refresh token expired"}"#.utf8)) == .invalidGrant)
    #expect(ClaudeOAuth.requestError(status: 401, body: Data(#"{"error":{"type":"invalid_grant"}}"#.utf8)) == .invalidGrant)
    #expect(ClaudeOAuth.requestError(status: 400, body: Data(#"{"error":"invalid_scope"}"#.utf8)) == .invalidScope)
    #expect(ClaudeOAuth.requestError(status: 500, body: Data("oops".utf8)) == .http(500))
}

@Test func mergeKeepsEverythingElseLikeClaudeCode() throws {
    let grant = ClaudeOAuth.Grant(accessToken: "at-new", refreshToken: "rt-new", expiresAt: 1_790_028_800_000,
                                  refreshTokenExpiresAt: nil, scopes: ["user:inference", "user:profile"])
    let merged = try #require(ClaudeOAuth.merged(Data(storedJSON.utf8), with: grant, clientID: nil))
    let root = json(merged)
    let oauth = try #require(root["claudeAiOauth"] as? [String: Any])
    #expect(oauth["accessToken"] as? String == "at-new")
    #expect(oauth["refreshToken"] as? String == "rt-new")
    #expect((oauth["expiresAt"] as? NSNumber)?.int64Value == 1_790_028_800_000)
    #expect(oauth["scopes"] as? [String] == ["user:inference", "user:profile"])
    // 订阅类型、速率档位与 refresh token 有效期沿用原值
    #expect(oauth["subscriptionType"] as? String == "max")
    #expect(oauth["rateLimitTier"] as? String == "default_claude_max_20x")
    #expect((oauth["refreshTokenExpiresAt"] as? NSNumber)?.int64Value == 1_799_999_999_000)
    // 与 Claude Code 一样只保留已知字段；没有 clientId 时不写入
    #expect(oauth["legacyField"] == nil)
    #expect(oauth["clientId"] == nil)
    // 其他登录（MCP 服务器）原样保留
    let mcp = try #require((root["mcpOAuth"] as? [String: Any])?["server|abc"] as? [String: Any])
    #expect(mcp["accessToken"] as? String == "mcp-token")
    #expect((mcp["expiresAt"] as? NSNumber)?.int64Value == 1_790_000_000_123)
    #expect(!String(decoding: merged, as: UTF8.self).contains("\\/"))

    let withClient = try #require(ClaudeOAuth.merged(Data(#"{"claudeAiOauth":{"accessToken":"a"}}"#.utf8), with: grant, clientID: "c1"))
    let oauth2 = try #require(json(withClient)["claudeAiOauth"] as? [String: Any])
    #expect(oauth2["clientId"] as? String == "c1")
    #expect(oauth2["subscriptionType"] is NSNull)
}

// MARK: - 目录锁

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cum-lock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func setModified(_ path: String, secondsAgo: TimeInterval) throws {
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-secondsAgo)], ofItemAtPath: path)
}

@Test func directoryLockIsExclusiveAndRecoversStaleLocks() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("x.lock").path

    let a = DirectoryLock(path: path, stale: 60, update: 5)
    try a.acquire()
    #expect(FileManager.default.fileExists(atPath: path))
    let b = DirectoryLock(path: path, stale: 60, update: 5)
    #expect(throws: DirectoryLock.Failure.locked) { try b.acquire() }
    a.release()
    #expect(!FileManager.default.fileExists(atPath: path))
    try b.acquire()
    b.release()

    // 持有者退出后留下的锁：超过 stale 秒没有刷新，可以接管
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    try setModified(path, secondsAgo: 120)
    let c = DirectoryLock(path: path, stale: 60, update: 5)
    try c.acquire()
    // 锁被别人接管（修改时间变了）后，释放时不能删掉别人的锁
    try setModified(path, secondsAgo: 1)
    c.release()
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func refreshLockNeedsBothClaudeCodeLocks() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let config = dir.appendingPathComponent(".claude")
    let locks = ClaudeCodeLocks(configDirectory: config)
    let primary = config.appendingPathComponent(".oauth_refresh.lock").path
    let legacy = config.resolvingSymlinksInPath().path + ".lock"

    let held = try locks.acquireRefreshLock()
    #expect(FileManager.default.fileExists(atPath: primary))
    #expect(FileManager.default.fileExists(atPath: legacy))
    held.forEach { $0.release() }
    #expect(!FileManager.default.fileExists(atPath: primary))

    // 旧版 Claude Code 正持有 ~/.claude.lock：放弃，并释放已经拿到的新锁
    try FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: false)
    #expect(throws: DirectoryLock.Failure.locked) { try locks.acquireRefreshLock() }
    #expect(!FileManager.default.fileExists(atPath: primary))

    let write = try locks.acquireStorageWriteLock()
    #expect(FileManager.default.fileExists(atPath: config.appendingPathComponent(".storage-write.lock").path))
    write.release()
}

// MARK: - 续期流程

/// 模拟钥匙串与令牌接口
private final class FakeClaude: @unchecked Sendable {
    private let lock = NSLock()
    var stored: Data
    var writes: [Data] = []
    var requests: [[String: Any]] = []
    var responses: [CredentialRenewal.Response?]
    /// 模拟钥匙串不可写
    var writable = true
    /// 读取时执行（模拟其他进程在期间改动了凭据）
    var onRead: ((inout Data, Int) -> Void)?
    private var reads = 0
    let config: URL

    init(stored: String, responses: [CredentialRenewal.Response?]) throws {
        self.stored = Data(stored.utf8)
        self.responses = responses
        config = try temporaryDirectory().appendingPathComponent(".claude")
    }

    func renewal(now: Date) -> CredentialRenewal {
        let locks = ClaudeCodeLocks(configDirectory: config)
        return CredentialRenewal(
            read: { self.read() },
            write: { data in
                // 写回时必须持有 Claude Code 的凭据写入锁
                let held = FileManager.default.fileExists(atPath: self.config.appendingPathComponent(".storage-write.lock").path)
                return self.lock.withLock {
                    guard held, self.writable else { return false }
                    self.writes.append(data)
                    self.stored = data
                    return true
                }
            },
            send: { request in
                self.lock.withLock {
                    self.requests.append(json(request.httpBody))
                    return self.responses.isEmpty ? nil : self.responses.removeFirst()
                }
            },
            acquireRefreshLock: { try locks.acquireRefreshLock() },
            acquireWriteLock: { try locks.acquireStorageWriteLock() },
            sleep: { _ in },
            now: { now }
        )
    }

    private func read() -> StoredCredentials? {
        lock.withLock {
            reads += 1
            onRead?(&stored, reads)
            return ClaudeOAuth.credentials(from: stored).map { StoredCredentials(credentials: $0, raw: stored) }
        }
    }
}

private let expiring = Date(timeIntervalSince1970: 1_790_000_000 - 60)  // 距过期 1 分钟
private let okResponse = CredentialRenewal.Response(
    status: 200,
    body: Data(#"{"access_token":"at-new","refresh_token":"rt-new","expires_in":28800,"scope":"user:inference user:profile user:sessions:claude_code"}"#.utf8)
)

@Test func renewsAndWritesBackUnderClaudeCodeLocks() throws {
    let fake = try FakeClaude(stored: storedJSON, responses: [okResponse])
    let result = fake.renewal(now: expiring).renew(expected: "at-old")
    guard case .renewed(let c) = result else { Issue.record("unexpected \(result)"); return }
    #expect(c.accessToken == "at-new")
    #expect(c.refreshToken == "rt-new")
    #expect(c.subscriptionType == "max")
    // 响应里没有新的登录有效期：沿用原值（与 Claude Code 相同）
    #expect(c.refreshTokenExpiresAt == Date(timeIntervalSince1970: 1_799_999_999))
    #expect(fake.requests.count == 1)
    #expect(fake.requests[0]["refresh_token"] as? String == "rt-old")
    // 先原样写回一次确认可写，再写入新令牌
    #expect(fake.writes.count == 2)
    #expect(fake.writes.first == Data(storedJSON.utf8))
    let saved = try #require(ClaudeOAuth.credentials(from: fake.stored))
    #expect(saved.accessToken == "at-new" && saved.refreshToken == "rt-new")
    #expect(json(fake.stored)["mcpOAuth"] != nil)
    // 锁全部释放
    #expect(!FileManager.default.fileExists(atPath: fake.config.appendingPathComponent(".oauth_refresh.lock").path))
    #expect(!FileManager.default.fileExists(atPath: fake.config.appendingPathComponent(".storage-write.lock").path))
    #expect(!FileManager.default.fileExists(atPath: fake.config.path + ".lock"))
}

@Test func adoptsTokensRenewedByClaudeCode() throws {
    // 拿到锁后重新读取，发现 Claude Code 已经续期：直接采用，不发请求
    let fake = try FakeClaude(stored: storedJSON, responses: [okResponse])
    fake.onRead = { data, _ in
        data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "at-old", with: "at-cli").utf8)
    }
    let result = fake.renewal(now: expiring).renew(expected: "at-old")
    #expect(result == .current(try #require(ClaudeOAuth.credentials(from: fake.stored))))
    #expect(fake.requests.isEmpty)
    #expect(fake.writes.isEmpty)

    // 还没到续期时间也不发请求
    let fresh = try FakeClaude(stored: storedJSON, responses: [okResponse])
    guard case .current = fresh.renewal(now: Date(timeIntervalSince1970: 1_789_000_000)).renew(expected: "at-old") else {
        Issue.record("expected current"); return
    }
    #expect(fresh.requests.isEmpty)
}

@Test func doesNotOverwriteANewerLogin() throws {
    // 续期请求期间有人重新登录（refresh token 变了）：采用对方的结果，不覆盖
    let fake = try FakeClaude(stored: storedJSON, responses: [okResponse])
    fake.onRead = { data, count in
        // 第 1 次：拿到锁后重读；第 2 次：写回预检；第 3 次：写回前核对
        if count == 3 { data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "rt-old", with: "rt-login").utf8) }
    }
    let result = fake.renewal(now: expiring).renew(expected: "at-old")
    guard case .current(let c) = result else { Issue.record("unexpected \(result)"); return }
    #expect(c.refreshToken == "rt-login")
    #expect(fake.writes.count == 1)
    #expect(ClaudeOAuth.credentials(from: fake.stored)?.refreshToken == "rt-login")
}

@Test func fallsBackToStoredScopesAndReportsSignedOut() throws {
    let invalidScope = CredentialRenewal.Response(status: 400, body: Data(#"{"error":"invalid_scope"}"#.utf8))
    let fake = try FakeClaude(stored: storedJSON, responses: [invalidScope, okResponse])
    guard case .renewed = fake.renewal(now: expiring).renew(expected: "at-old") else { Issue.record("expected renewed"); return }
    #expect(fake.requests.count == 2)
    #expect(fake.requests[1]["scope"] as? String == "user:inference user:profile user:projects:read")

    let invalidGrant = CredentialRenewal.Response(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
    let dead = try FakeClaude(stored: storedJSON, responses: [invalidGrant])
    #expect(dead.renewal(now: expiring).renew(expected: "at-old") == .failed(.signedOut))
    #expect(dead.stored == Data(storedJSON.utf8))

    let offline = try FakeClaude(stored: storedJSON, responses: [nil])
    #expect(offline.renewal(now: expiring).renew(expected: "at-old") == .failed(.network("网络错误")))
}

@Test func givesUpWhenClaudeCodeHoldsTheLock() throws {
    let fake = try FakeClaude(stored: storedJSON, responses: [okResponse])
    try FileManager.default.createDirectory(at: fake.config.appendingPathComponent(".oauth_refresh.lock"), withIntermediateDirectories: true)
    #expect(fake.renewal(now: expiring).renew(expected: "at-old") == .failed(.locked))
    #expect(fake.requests.isEmpty)
}

@Test func neverRenewsWhatItCannotSave() throws {
    // 钥匙串不可写：不发起续期（续期会让旧的 refresh token 失效）
    let fake = try FakeClaude(stored: storedJSON, responses: [okResponse])
    fake.writable = false
    #expect(fake.renewal(now: expiring).renew(expected: "at-old") == .failed(.notWritable))
    #expect(fake.requests.isEmpty)

    // 响应里没有 scope：按申请的权限保存
    let noScope = CredentialRenewal.Response(status: 200, body: Data(#"{"access_token":"at-new","refresh_token":"rt-new","expires_in":28800}"#.utf8))
    let fake2 = try FakeClaude(stored: storedJSON, responses: [noScope])
    guard case .renewed(let c) = fake2.renewal(now: expiring).renew(expected: "at-old") else { Issue.record("expected renewed"); return }
    #expect(c.scopes.first == "user:profile")
    #expect(ClaudeOAuth.credentials(from: fake2.stored)?.scopes.contains("user:inference") == true)

    // 服务端返回了新的登录有效期：一并保存
    let extended = CredentialRenewal.Response(status: 200, body: Data(#"{"access_token":"at-new","refresh_token":"rt-new","expires_in":28800,"refresh_token_expires_in":2592000,"scope":"user:inference"}"#.utf8))
    let fake3 = try FakeClaude(stored: storedJSON, responses: [extended])
    guard case .renewed(let c3) = fake3.renewal(now: expiring).renew(expected: "at-old") else { Issue.record("expected renewed"); return }
    let until = expiring.addingTimeInterval(2_592_000)
    #expect(c3.refreshTokenExpiresAt == until)
    #expect(ClaudeOAuth.credentials(from: fake3.stored)?.refreshTokenExpiresAt == until)
}
