import Foundation
import Observation
import OSLog
import UsageCore

/// 账号资料（`GET /api/oauth/profile`）：服务端实时的套餐档位。
/// 注意凭据里也存有 `rateLimitTier`，但那是登录时的快照，升级套餐后不会更新，不能用来判断套餐。
struct AccountProfile: Equatable {
    let organizationType: String?
    let rateLimitTier: String?

    var plan: Plan? {
        let tier = (rateLimitTier ?? "").lowercased()
        if tier.contains("20x") { return .max20x }
        if tier.contains("5x") { return .max5x }
        switch organizationType?.lowercased() {
        case "claude_pro": return .pro
        case "claude_max": return .max5x
        case "claude_team": return .team
        case "claude_enterprise": return .enterprise
        default: return nil
        }
    }

    static func decode(_ data: Data) -> AccountProfile? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let org = json["organization"] as? [String: Any]
        return AccountProfile(
            organizationType: org?["organization_type"] as? String,
            rateLimitTier: org?["rate_limit_tier"] as? String
        )
    }
}

/// Claude Code 的凭据存储：macOS 上是钥匙串条目「Claude Code-credentials」，个别环境是 `~/.claude/.credentials.json`。
/// 读写方式与 Claude Code 完全相同，都通过系统自带的 `/usr/bin/security` 访问同一条目：
/// 这个条目由 `security` 创建，也只信任 `security`；Claude Code 每次改写条目都会重置其他 App 的授权，
/// 如果改用系统钥匙串接口直接读取，每次续期之后都会弹出要求输入登录密码的钥匙串对话框。
enum CredentialStore {
    enum Failure: Error, Equatable {
        case notFound
        /// 钥匙串已锁定
        case locked
        case denied
        case invalid
        /// 登录信息还在，但令牌已被 Claude Code 清空（登录到期或续期被拒绝），需要重新登录
        case signedOut
        /// `security` 读取失败（附带退出码）
        case unreadable(Int32?)
    }

    enum Location: Equatable, Sendable {
        case keychain(account: String)
        case file
    }

    struct Loaded: Sendable {
        var stored: StoredCredentials
        var location: Location
    }

    static let service = "Claude Code-credentials"

    /// 与 Claude Code 相同的账户名：当前用户名，不符合规则时用固定的名称
    static var account: String {
        let name = ProcessInfo.processInfo.environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        return name.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil ? name : "claude-code-user"
    }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    /// 读取凭据（会启动 `security` 进程，务必在后台线程调用）
    static func load() -> Result<Loaded, Failure> {
        let account = account
        let (status, output) = KeychainTool.read(account: account, service: service)
        switch status {
        case 0:
            guard let data = KeychainTool.decodePassword(output) else { return .failure(.invalid) }
            return parse(data, location: .keychain(account: account))
        case 44:
            // 钥匙串里没有：与 Claude Code 一样退回到明文文件
            guard let data = try? Data(contentsOf: fileURL) else { return .failure(.notFound) }
            return parse(data, location: .file)
        case 36: return .failure(.locked)
        case 51, 128: return .failure(.denied)
        default: return .failure(.unreadable(status))
        }
    }

    private static func parse(_ data: Data, location: Location) -> Result<Loaded, Failure> {
        if let credentials = ClaudeOAuth.credentials(from: data) {
            return .success(Loaded(stored: StoredCredentials(credentials: credentials, raw: data), location: location))
        }
        return .failure(ClaudeOAuth.hasClearedLogin(data) ? .signedOut : (location == .file ? .notFound : .invalid))
    }

    /// 写回续期后的凭据（位置与读取时相同），并读回核对
    static func save(_ data: Data, to location: Location) -> Bool {
        switch location {
        case .keychain(let account):
            // `security -i` 的退出码不反映命令是否成功，只能以读回的内容为准
            _ = KeychainTool.update(data, account: account, service: service)
            guard case .success(let written) = load(), written.location == location else { return false }
            return written.stored.raw == data
        case .file:
            do {
                try data.write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                return true
            } catch {
                return false
            }
        }
    }
}

/// 调用系统自带的 `security` 命令，与 Claude Code 读写凭据的方式保持一致
enum KeychainTool {
    private static let executable = URL(fileURLWithPath: "/usr/bin/security")
    /// `security -i` 单行命令的长度上限（与 Claude Code 相同）
    private static let interactiveLimit = 4032

    /// 与 Claude Code 相同：`security find-generic-password -a <账户> -w -s <服务>`。
    /// 退出码 44 表示没有这个条目，36 表示钥匙串已锁定。
    static func read(account: String, service: String) -> (status: Int32?, output: Data) {
        run(["find-generic-password", "-a", account, "-w", "-s", service], input: nil, captureOutput: true)
    }

    /// `-w` 输出的内容：可打印的文本原样输出（末尾带换行），否则输出十六进制
    static func decodePassword(_ output: Data) -> Data? {
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let data = Data(text.utf8)
        if (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
        guard text.count.isMultiple(of: 2), text.allSatisfy(\.isHexDigit) else { return data }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return data }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// 更新已有条目：十六进制内容经标准输入传入，令牌不会出现在进程参数里。
    /// 注意 `security -i` 只执行以换行结尾的行，而且无论成败退出码都是 0，调用方需要读回核对。
    static func update(_ data: Data, account: String, service: String) -> Bool {
        guard account.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return false }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = #"add-generic-password -U -a "\#(account)" -s "\#(service)" -X "\#(hex)""#
        if command.utf8.count <= interactiveLimit {
            return run(["-i"], input: Data((command + "\n").utf8)).status == 0
        }
        return run(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex], input: nil).status == 0
    }

    /// 默认钥匙串是否处于锁定状态（与 Claude Code 的判断相同）
    static var isLocked: Bool { run(["show-keychain-info"], input: nil).status == 36 }

    private static func run(_ arguments: [String], input: Data?, captureOutput: Bool = false,
                            timeout: TimeInterval = 10) -> (status: Int32?, output: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = captureOutput ? stdout : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return (nil, Data()) }

        // 在另一个线程读取输出，避免输出较多时子进程阻塞
        nonisolated(unsafe) var output = Data()
        let reading = DispatchGroup()
        if captureOutput {
            DispatchQueue.global(qos: .utility).async(group: reading) {
                output = stdout.fileHandleForReading.readDataToEndOfFile()
            }
        }
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = reading.wait(timeout: .now() + 1)
            return (nil, Data())
        }
        _ = reading.wait(timeout: .now() + 2)
        return (process.terminationStatus, output)
    }
}

/// 官方用量：与 Claude Code `/usage` 相同的接口，提供 5 小时 / 每周百分比与重置时间。
/// Claude Code 的登录约 8 小时过期，开启自动续期后按 Claude Code 相同的流程续期，保证数据不断档。
@MainActor
@Observable
final class OfficialUsageService {
    enum State: Equatable {
        case disabled
        case connecting
        case connected
        case noCredentials
        case denied
        /// 登录已过期，且没有开启自动续期
        case expired
        /// 登录已失效（续期被拒绝），需要在 Claude Code 中重新登录
        case signedOut
        case failed(String)

        /// 只有在 Claude Code 中登录（或 Claude Code 自己续期）才能恢复
        var awaitingLogin: Bool {
            switch self {
            case .noCredentials, .signedOut, .expired: true
            default: false
            }
        }
    }

    enum Trigger {
        /// 定时同步
        case timer
        /// 打开面板
        case panel
        /// 用户手动刷新 / 重新连接
        case manual
        /// 等待用户完成登录：只读取钥匙串，间隔很短
        case login
    }

    private(set) var state: State = .connecting
    /// 最近一次成功获取的官方数据（同步失败时继续展示，并标明同步时间）
    private(set) var usage: OfficialUsage?
    /// 来自服务端账号资料的套餐（无法确定时为 nil）
    private(set) var detectedPlan: Plan?
    /// 最近一次由本 App 完成续期的时间
    private(set) var lastRenewal: Date?
    /// Claude Code 登录（refresh token）的有效期：到期后无法续期，需要重新登录
    private(set) var loginExpiresAt: Date?

    @ObservationIgnored var onChange: (() -> Void)?
    /// 登录过期时自动续期（与偏好设置同步）
    @ObservationIgnored var autoRenew = true
    @ObservationIgnored private var credentials: ClaudeOAuth.Credentials?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var lastAttempt = Date.distantPast
    /// 失败后的重试时间（手动刷新不受限制）
    @ObservationIgnored private var retryAfter = Date.distantPast
    /// 被限流后的退避时间（任何请求都要等待）
    @ObservationIgnored private var rateLimitedUntil = Date.distantPast
    @ObservationIgnored private var rateLimitStreak = 0
    @ObservationIgnored private var lastProfileFetch = Date.distantPast
    /// 已被服务端拒绝的 refresh token：不再重复尝试，直到 Claude Code 重新登录
    @ObservationIgnored private var deadRefreshToken: String?
    @ObservationIgnored private var loginWatch: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "claude-usage-monitor.official", qos: .utility)

    nonisolated static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    nonisolated static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    nonisolated private static let log = Logger(subsystem: "io.github.kittors.ClaudeUsageMonitor", category: "official")

    /// 定时同步的间隔：接口有频率限制（每分钟请求一次，十几次后就会返回 429）
    static let syncInterval: TimeInterval = 5 * 60
    /// 打开面板、窗口重置等即时同步的最小间隔
    static let minimumSpacing: TimeInterval = 60

    func setEnabled(_ enabled: Bool) {
        if enabled {
            if state == .disabled { state = .connecting }
            refresh(.manual)
        } else {
            state = .disabled
            usage = nil
            credentials = nil
            onChange?()
        }
    }

    func refresh(_ trigger: Trigger = .timer) {
        guard state != .disabled, !inFlight else { return }
        let now = Date()
        guard now >= rateLimitedUntil else { return }
        let sinceAttempt = now.timeIntervalSince(lastAttempt)
        switch trigger {
        case .timer:
            guard state != .denied, now >= retryAfter else { return }
            // 定时同步；窗口到了重置时间也立即同步，尽快拿到新窗口的数据；等待登录时每分钟读取一次钥匙串
            guard sinceAttempt >= Self.syncInterval - 5 || (windowHasReset(now) && sinceAttempt >= Self.minimumSpacing)
                || state.awaitingLogin else { return }
        case .panel:
            if state.awaitingLogin {
                // 等待登录时只读取钥匙串、不发请求：打开面板就检查一次，登录后立即恢复
                guard sinceAttempt >= 3 else { return }
            } else {
                guard state != .denied, now >= retryAfter, sinceAttempt >= Self.minimumSpacing else { return }
                if let usage, now.timeIntervalSince(usage.fetchedAt) < Self.minimumSpacing { return }
            }
        case .manual:
            guard sinceAttempt >= 10 else { return }
        case .login:
            guard state.awaitingLogin, sinceAttempt >= 2 else { return }
        }
        inFlight = true
        lastAttempt = now
        let request = FetchRequest(
            cached: credentials,
            autoRenew: autoRenew,
            wantsProfile: now.timeIntervalSince(lastProfileFetch) > 6 * 3600,
            deadRefreshToken: deadRefreshToken
        )
        queue.async {
            let outcome = Self.fetch(request)
            DispatchQueue.main.async {
                self.inFlight = false
                self.apply(outcome)
            }
        }
    }

    /// 在终端中打开登录后调用：每 3 秒检查一次钥匙串（最长 15 分钟），登录完成立即恢复
    func watchForLogin() {
        loginWatch?.invalidate()
        let started = Date()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.state.awaitingLogin, Date().timeIntervalSince(started) < 15 * 60 else {
                    timer.invalidate()
                    return
                }
                self.refresh(.login)
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        loginWatch = timer
    }

    /// 上次同步之后，是否有窗口已经到了重置时间
    private func windowHasReset(_ now: Date) -> Bool {
        guard let usage else { return false }
        return [usage.fiveHour?.resetsAt, usage.sevenDay?.resetsAt].contains { reset in
            guard let reset else { return false }
            return reset <= now && usage.fetchedAt < reset
        }
    }

    // MARK: 结果

    private struct FetchRequest: Sendable {
        var cached: ClaudeOAuth.Credentials?
        var autoRenew: Bool
        var wantsProfile: Bool
        var deadRefreshToken: String?
    }

    private enum Outcome {
        case success(OfficialUsage, ClaudeOAuth.Credentials, AccountProfile?, renewed: Bool)
        case credentialFailure(CredentialStore.Failure)
        /// 登录已过期，且不能或不允许续期
        case expired
        /// 续期被拒绝（附带被拒绝的 refresh token）
        case signedOut(String?)
        case renewFailed(String, retryIn: TimeInterval)
        case unauthorized
        case rateLimited(TimeInterval)
        case failed(String)

        /// 只读取了钥匙串、没有发出请求（等待登录时会频繁出现）
        var isLocal: Bool {
            switch self {
            case .credentialFailure, .expired, .signedOut(.none): true
            default: false
            }
        }
    }

    private func apply(_ outcome: Outcome) {
        let now = Date()
        let previous = state
        switch outcome {
        case .success(let usage, let credentials, let profile, let renewed):
            self.usage = usage
            self.credentials = credentials
            loginExpiresAt = credentials.refreshTokenExpiresAt
            deadRefreshToken = nil
            if renewed { lastRenewal = now }
            if let profile {
                detectedPlan = profile.plan
                lastProfileFetch = now
            }
            state = .connected
            retryAfter = .distantPast
            rateLimitStreak = 0
        case .credentialFailure(let failure):
            credentials = nil
            state = switch failure {
            case .denied: .denied
            case .signedOut: .signedOut
            case .notFound, .invalid: .noCredentials
            case .locked: .failed("钥匙串已锁定")
            case .unreadable: .failed("无法读取钥匙串")
            }
            if state.awaitingLogin { signedOut() }
            retryAfter = now.addingTimeInterval(60)
        case .expired:
            credentials = nil
            state = .expired
            // 只读取钥匙串、不发请求：Claude Code 续期后一分钟内就能恢复
            retryAfter = now.addingTimeInterval(60)
        case .signedOut(let token):
            credentials = nil
            if let token { deadRefreshToken = token }
            state = .signedOut
            signedOut()
            retryAfter = now.addingTimeInterval(60)
        case .renewFailed(let message, let delay):
            state = .failed(message)
            retryAfter = now.addingTimeInterval(delay)
        case .unauthorized:
            credentials = nil
            state = autoRenew ? .failed("授权失败") : .expired
            retryAfter = now.addingTimeInterval(5 * 60)
        case .rateLimited(let retry):
            // 5 分钟起，每次翻倍，最长 30 分钟
            rateLimitStreak += 1
            let backoff = min(30 * 60, 5 * 60 * pow(2, Double(rateLimitStreak - 1)))
            rateLimitedUntil = now.addingTimeInterval(max(retry, backoff))
            state = .failed("请求过于频繁")
        case .failed(let message):
            state = .failed(message)
            retryAfter = now.addingTimeInterval(60)
        }
        // 等待登录期间状态不变的检查不重复记录
        if state != previous || !outcome.isLocal { Self.record(outcome, state: state, usage: usage) }
        onChange?()
    }

    /// 需要重新登录：清掉与这次登录相关的信息，重新登录（可能换了账号）后重新获取套餐
    private func signedOut() {
        loginExpiresAt = nil
        lastProfileFetch = .distantPast
    }

    /// 只记录结果、状态与百分比，不记录任何凭据
    private static func record(_ outcome: Outcome, state: State, usage: OfficialUsage?) {
        let result = switch outcome {
        case .success(_, _, _, let renewed): renewed ? "ok (renewed login)" : "ok"
        case .credentialFailure(let f): "credentials-\(f)"
        case .expired: "login expired"
        case .signedOut: "signed out, sign in again in Claude Code"
        case .renewFailed(let message, _): "renewal failed: \(message)"
        case .unauthorized: "unauthorized"
        case .rateLimited(let retry): "rate-limited retry-after=\(Int(retry))s"
        case .failed(let message): "failed \(message)"
        }
        let five = usage?.fiveHour.map { "\($0.percent)%" } ?? "-"
        let week = usage?.sevenDay.map { "\($0.percent)%" } ?? "-"
        log.notice("\(result, privacy: .public) state=\(String(describing: state), privacy: .public) 5h=\(five, privacy: .public) week=\(week, privacy: .public)")
    }

    // MARK: 后台请求

    /// 调试：`CUM_FORCE_RENEW=1` 时，启动后第一次同步强制续期一次（用于验证续期流程；只在后台队列访问）
    nonisolated(unsafe) private static var forceRenewPending = ProcessInfo.processInfo.environment["CUM_FORCE_RENEW"] == "1"

    nonisolated private static func fetch(_ r: FetchRequest) -> Outcome {
        var renewed = false
        var current: ClaudeOAuth.Credentials
        if let cached = r.cached, !cached.needsRefresh() {
            current = cached
        } else {
            // 没有缓存或即将过期：重新读取（Claude Code 可能已经续期）
            switch CredentialStore.load() {
            case .success(let loaded): current = loaded.stored.credentials
            case .failure(let failure): return .credentialFailure(failure)
            }
        }

        // 与 Claude Code 一样，过期前 5 分钟就续期
        let force = forceRenewPending
        forceRenewPending = false
        if current.needsRefresh() || force {
            switch renew(current, request: r, force: force) {
            case .renewed(let c):
                current = c
                renewed = true
            case .current(let c):
                current = c
            case .unavailable(let outcome):
                // 还没真正过期就先用着，下次同步再续
                if current.isExpired() { return outcome }
            }
        }

        var result = request(token: current.accessToken)
        if case .unauthorized = result {
            // 与 Claude Code 收到 401 时的处理相同：钥匙串里已有新令牌就直接用，否则强制续期后重试
            if case .success(let loaded) = CredentialStore.load(), loaded.stored.credentials.accessToken != current.accessToken {
                current = loaded.stored.credentials
                result = request(token: current.accessToken)
            } else {
                switch renew(current, request: r, force: true) {
                case .renewed(let c):
                    current = c
                    renewed = true
                    result = request(token: c.accessToken)
                case .current(let c) where c.accessToken != current.accessToken:
                    current = c
                    result = request(token: c.accessToken)
                case .current:
                    break
                case .unavailable(let outcome):
                    return outcome
                }
            }
        }
        switch result {
        case .success(let usage):
            return .success(usage, current, r.wantsProfile ? profile(token: current.accessToken) : nil, renewed: renewed)
        case .unauthorized: return .unauthorized
        case .rateLimited(let t): return .rateLimited(t)
        case .failed(let m): return .failed(m)
        }
    }

    private enum RenewStep {
        case renewed(ClaudeOAuth.Credentials)
        case current(ClaudeOAuth.Credentials)
        case unavailable(Outcome)
    }

    nonisolated private static func renew(_ c: ClaudeOAuth.Credentials, request r: FetchRequest, force: Bool) -> RenewStep {
        guard r.autoRenew, c.isRefreshable else { return .unavailable(.expired) }
        if let dead = r.deadRefreshToken, dead == c.refreshToken { return .unavailable(.signedOut(nil)) }
        let location: CredentialStore.Location
        switch CredentialStore.load() {
        case .success(let loaded): location = loaded.location
        case .failure(let failure): return .unavailable(.credentialFailure(failure))
        }
        if case .keychain = location, KeychainTool.isLocked {
            return .unavailable(.renewFailed("钥匙串已锁定", retryIn: 60))
        }

        let locks = ClaudeCodeLocks()
        let renewal = CredentialRenewal(
            read: {
                guard case .success(let latest) = CredentialStore.load(), latest.location == location else { return nil }
                return latest.stored
            },
            write: { CredentialStore.save($0, to: location) },
            send: { send($0) },
            acquireRefreshLock: { try locks.acquireRefreshLock() },
            acquireWriteLock: { try locks.acquireStorageWriteLock() }
        )
        let result = renewal.renew(expected: c.accessToken, force: force)
        switch result {
        case .renewed(let renewed):
            log.notice("renewed Claude Code login (saved and verified)")
            return .renewed(renewed)
        case .current(let latest):
            log.notice("login already renewed elsewhere")
            return .current(latest)
        case .failed(let failure):
            log.error("renewal failed: \(String(describing: failure), privacy: .public)")
            switch failure {
            case .locked: return .unavailable(.renewFailed("Claude Code 正在续期", retryIn: 30))
            case .noCredentials:
                if case .failure(let failure) = CredentialStore.load() { return .unavailable(.credentialFailure(failure)) }
                return .unavailable(.credentialFailure(.notFound))
            case .notRenewable: return .unavailable(.expired)
            case .notWritable: return .unavailable(.renewFailed("无法写入钥匙串", retryIn: 5 * 60))
            case .signedOut: return .unavailable(.signedOut(c.refreshToken))
            case .network(let message): return .unavailable(.renewFailed(message, retryIn: 60))
            case .server(let message): return .unavailable(.renewFailed("续期失败（\(message)）", retryIn: 5 * 60))
            case .saveFailed(let renewed):
                // 新令牌仍然有效，本次照常使用；但钥匙串里还是旧的，Claude Code 下次可能需要重新登录
                log.fault("renewed login could not be saved to the keychain")
                return .renewed(renewed)
            }
        }
    }

    // MARK: 网络

    private enum RequestResult {
        case success(OfficialUsage)
        case unauthorized
        case rateLimited(TimeInterval)
        case failed(String)
    }

    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// 同步发送请求（只在后台队列调用）
    nonisolated private static func perform(_ request: URLRequest) -> (HTTPURLResponse?, Data?, Error?) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (HTTPURLResponse?, Data?, Error?) = (nil, nil, nil)
        session.dataTask(with: request) { data, response, error in
            result = (response as? HTTPURLResponse, data, error)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }

    nonisolated private static func send(_ request: URLRequest) -> CredentialRenewal.Response? {
        var request = request
        request.setValue("claude-usage-monitor", forHTTPHeaderField: "User-Agent")
        let (response, data, _) = perform(request)
        return response.map { CredentialRenewal.Response(status: $0.statusCode, body: data) }
    }

    /// 与 Claude Code 登录时相同的请求，获取服务端实时的套餐档位
    nonisolated private static func profile(token: String) -> AccountProfile? {
        var request = URLRequest(url: profileEndpoint, timeoutInterval: 12)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-usage-monitor", forHTTPHeaderField: "User-Agent")
        let (response, data, _) = perform(request)
        guard response?.statusCode == 200, let data else { return nil }
        return AccountProfile.decode(data)
    }

    nonisolated private static func request(token: String) -> RequestResult {
        var request = URLRequest(url: endpoint, timeoutInterval: 12)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-usage-monitor", forHTTPHeaderField: "User-Agent")

        let (response, data, error) = perform(request)
        if let error {
            return .failed((error as NSError).code == NSURLErrorNotConnectedToInternet ? "网络未连接" : "网络错误")
        }
        guard let response else { return .failed("无响应") }
        switch response.statusCode {
        case 200:
            // 调试：CUM_DEBUG_OFFICIAL=1 时输出原始响应（只含用量数据，不含凭据）
            if ProcessInfo.processInfo.environment["CUM_DEBUG_OFFICIAL"] == "1", let data {
                print("[official] raw=\(String(decoding: data, as: UTF8.self))")
            }
            guard let data, let usage = try? OfficialUsage.decode(data) else { return .failed("响应格式已变化") }
            return .success(usage)
        case 401, 403:
            return .unauthorized
        case 429:
            return .rateLimited(Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 120)
        default:
            return .failed("服务返回 \(response.statusCode)")
        }
    }
}
