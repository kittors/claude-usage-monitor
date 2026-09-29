import Foundation

/// 凭据的一次读取结果：解析后的凭据与原始 JSON（写回时在原始 JSON 上合并）
public struct StoredCredentials: Sendable, Equatable {
    public var credentials: ClaudeOAuth.Credentials
    public var raw: Data

    public init(credentials: ClaudeOAuth.Credentials, raw: Data) {
        self.credentials = credentials
        self.raw = raw
    }
}

/// 续期登录：与 Claude Code CLI 的流程逐步对应，
/// 1. 拿续期锁（被占用时每 1～2 秒重试，最多 5 次）；
/// 2. 重新读取凭据：如果已经被别人续期（access token 变了）或已经不需要续期，直接采用；
/// 3. 先确认凭据可以写回（在写入锁内原样写回并核对）：续期会让旧的 refresh token 失效，存不回去就不能续；
/// 4. 请求新令牌（扩展权限被拒时退回原有权限重试一次）；
/// 5. 拿凭据写入锁，再读一次：refresh token 仍是刚才用的那个才写回，否则说明期间有人重新登录或续期，采用对方的结果。
public struct CredentialRenewal: Sendable {
    public enum Failure: Error, Equatable {
        /// 续期锁一直被占用（通常是 Claude Code 正在续期）
        case locked
        case noCredentials
        /// 没有 refresh token，或不是 claude.ai 的登录，无法续期
        case notRenewable
        /// 凭据无法写回（没有发起续期，原登录不受影响）
        case notWritable
        /// refresh token 已失效，需要在 Claude Code 中重新登录
        case signedOut
        case network(String)
        case server(String)
        /// 拿到了新令牌，但写回失败（新令牌仍可在本次使用）
        case saveFailed(ClaudeOAuth.Credentials)
    }

    public enum Result: Equatable {
        /// 本次完成了续期并写回
        case renewed(ClaudeOAuth.Credentials)
        /// 已被别人续期，或者不需要续期
        case current(ClaudeOAuth.Credentials)
        case failed(Failure)
    }

    public struct Response: Sendable {
        public var status: Int
        public var body: Data?

        public init(status: Int, body: Data?) {
            self.status = status
            self.body = body
        }
    }

    public var read: @Sendable () -> StoredCredentials?
    /// 写入并核对，返回是否成功
    public var write: @Sendable (Data) -> Bool
    /// 发送请求；网络错误时返回 nil
    public var send: @Sendable (URLRequest) -> Response?
    public var acquireRefreshLock: @Sendable () throws -> [DirectoryLock]
    public var acquireWriteLock: @Sendable () throws -> DirectoryLock
    public var sleep: @Sendable (TimeInterval) -> Void
    public var now: @Sendable () -> Date

    public init(
        read: @escaping @Sendable () -> StoredCredentials?,
        write: @escaping @Sendable (Data) -> Bool,
        send: @escaping @Sendable (URLRequest) -> Response?,
        acquireRefreshLock: @escaping @Sendable () throws -> [DirectoryLock],
        acquireWriteLock: @escaping @Sendable () throws -> DirectoryLock,
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.read = read
        self.write = write
        self.send = send
        self.acquireRefreshLock = acquireRefreshLock
        self.acquireWriteLock = acquireWriteLock
        self.sleep = sleep
        self.now = now
    }

    /// - Parameters:
    ///   - expected: 调用方手里的 access token（用来判断是否已被别人续期）
    ///   - force: 即使还没到期也续期（接口返回 401 时）
    public func renew(expected: String, force: Bool = false) -> Result {
        var locks: [DirectoryLock] = []
        for attempt in 0...5 {
            do {
                locks = try acquireRefreshLock()
                break
            } catch DirectoryLock.Failure.locked {
                if attempt == 5 { return .failed(.locked) }
                sleep(1 + Double.random(in: 0..<1))
            } catch {
                return .failed(.locked)
            }
        }
        defer { locks.forEach { $0.release() } }

        guard let stored = read() else { return .failed(.noCredentials) }
        let current = stored.credentials
        if current.accessToken != expected { return .current(current) }
        if !force, !current.needsRefresh(now: now()) { return .current(current) }
        guard current.isRefreshable, let refreshToken = current.refreshToken else { return .failed(.notRenewable) }
        guard canWrite() else { return .failed(.notWritable) }

        var (scopes, expanded) = ClaudeOAuth.refreshScopes(for: current)
        var response = send(ClaudeOAuth.refreshRequest(refreshToken: refreshToken, scopes: scopes, clientID: current.clientID))
        if expanded, let r = response, r.status != 200,
           ClaudeOAuth.requestError(status: r.status, body: r.body) == .invalidScope,
           current.scopes.contains(ClaudeOAuth.inferenceScope) {
            scopes = current.scopes
            response = send(ClaudeOAuth.refreshRequest(refreshToken: refreshToken, scopes: scopes, clientID: current.clientID))
        }

        guard let response else { return adoptOr(.network("网络错误"), expected: expected) }
        guard response.status == 200 else {
            let failure: Failure = switch ClaudeOAuth.requestError(status: response.status, body: response.body) {
            case .invalidGrant: .signedOut
            case .invalidScope: .server("权限不被接受")
            case .http(let status): .server("服务返回 \(status)")
            }
            return adoptOr(failure, expected: expected)
        }
        guard let body = response.body,
              let grant = ClaudeOAuth.grant(from: body, previousRefreshToken: refreshToken, requestedScopes: scopes, now: now())
        else { return .failed(.server("响应格式已变化")) }
        let renewed = ClaudeOAuth.credentials(from: grant, previous: current)
        // Claude Code 只保存 claude.ai 的登录令牌，这里保持一致
        guard grant.isClaudeAILogin else { return .failed(.saveFailed(renewed)) }
        return save(grant, renewed: renewed, usedRefreshToken: refreshToken, clientID: current.clientID)
    }

    /// 在写入锁内把当前内容原样写回并核对：确认续期后的令牌一定能保存
    private func canWrite() -> Bool {
        guard let lock = acquireWriteLockWaiting() else { return false }
        defer { lock.release() }
        guard let latest = read() else { return false }
        return write(latest.raw)
    }

    /// 与 Claude Code 相同的重试节奏：100 ms 起、每次翻倍、最长 1 秒；锁超过 15 秒没刷新会被视为失效
    private func acquireWriteLockWaiting() -> DirectoryLock? {
        var delay = 0.1
        for _ in 0..<20 {
            if let lock = try? acquireWriteLock() { return lock }
            sleep(delay)
            delay = min(1, delay * 2)
        }
        return nil
    }

    /// 失败后再读一次：如果期间别人已经续期成功，直接采用
    private func adoptOr(_ failure: Failure, expected: String) -> Result {
        if let latest = read()?.credentials, latest.accessToken != expected { return .current(latest) }
        return .failed(failure)
    }

    private func save(_ grant: ClaudeOAuth.Grant, renewed: ClaudeOAuth.Credentials, usedRefreshToken: String, clientID: String?) -> Result {
        guard let lock = acquireWriteLockWaiting() else { return .failed(.saveFailed(renewed)) }
        defer { lock.release() }

        guard let latest = read() else { return .failed(.saveFailed(renewed)) }
        if latest.credentials.refreshToken != usedRefreshToken { return .current(latest.credentials) }
        guard let data = ClaudeOAuth.merged(latest.raw, with: grant, clientID: clientID) else { return .failed(.saveFailed(renewed)) }
        for attempt in 0..<2 {
            if write(data) { return .renewed(renewed) }
            if attempt == 0 { sleep(1) }
        }
        return .failed(.saveFailed(renewed))
    }
}
