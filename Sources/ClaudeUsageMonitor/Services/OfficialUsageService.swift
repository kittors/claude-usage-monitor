import Foundation
import Observation
import Security
import UsageCore

/// Claude Code 的登录凭据（只读取，绝不修改或刷新，以免影响 Claude Code 自身的登录状态）
struct ClaudeCredentials {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
    let rateLimitTier: String?

    var isExpired: Bool { expiresAt.map { $0 < Date().addingTimeInterval(30) } ?? false }
}

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
        case "claude_team", "claude_enterprise": return .team
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

enum CredentialStore {
    enum Failure: Error, Equatable {
        case notFound
        case denied
        case invalid
    }

    static let service = "Claude Code-credentials"

    /// 读取凭据。可能触发系统的钥匙串授权弹窗，务必在后台线程调用。
    static func load() -> Result<ClaudeCredentials, Failure> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let credentials = parse(data) else { return .failure(.invalid) }
            return .success(credentials)
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .failure(.denied)
        default:
            // 部分环境（例如 Linux 风格的配置）把凭据放在文件里
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            if let data = try? Data(contentsOf: file), let credentials = parse(data) { return .success(credentials) }
            return .failure(.notFound)
        }
    }

    static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expires,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }
}

/// 官方用量：与 Claude Code `/usage` 相同的接口，提供准确的 5 小时 / 每周百分比与重置时间。
@MainActor
@Observable
final class OfficialUsageService {
    enum State: Equatable {
        case disabled
        case connecting
        case connected
        case noCredentials
        case denied
        case expired
        case failed(String)
    }

    private(set) var state: State = .connecting
    private(set) var usage: OfficialUsage?
    /// 来自服务端账号资料的套餐（无法确定时为 nil）
    private(set) var detectedPlan: Plan?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var credentials: ClaudeCredentials?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var lastAttempt = Date.distantPast
    @ObservationIgnored private var backoffUntil = Date.distantPast
    /// 连续被限流的次数（指数退避）
    @ObservationIgnored private var rateLimitStreak = 0
    @ObservationIgnored private var lastProfileFetch = Date.distantPast
    @ObservationIgnored private let queue = DispatchQueue(label: "claude-usage-monitor.official", qos: .utility)

    nonisolated static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// 自动同步的间隔。接口有频率限制（每分钟请求一次，十几次后就会返回 429），
    /// 两次同步之间由本机用量实时推算（见 `LimitRows`）
    static let syncInterval: TimeInterval = 5 * 60

    /// 官方数据是否可用（最近 20 分钟内成功获取过）
    var freshUsage: OfficialUsage? {
        guard let usage, Date().timeIntervalSince(usage.fetchedAt) < 20 * 60 else { return nil }
        return usage
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            if state == .disabled { state = .connecting }
            refresh(force: true)
        } else {
            state = .disabled
            usage = nil
            credentials = nil
            onChange?()
        }
    }

    /// - Parameter force: 用户主动触发（手动刷新、重新连接）时不受同步间隔限制，但仍遵守限流退避
    func refresh(force: Bool = false) {
        guard state != .disabled, !inFlight else { return }
        let now = Date()
        if rateLimitStreak > 0, now < backoffUntil { return }
        if !force {
            if now < backoffUntil || state == .denied { return }
            if now.timeIntervalSince(lastAttempt) < Self.syncInterval - 5 { return }
        } else if now.timeIntervalSince(lastAttempt) < 10 {
            return
        }
        inFlight = true
        lastAttempt = now
        let cached = credentials
        let wantsProfile = Date().timeIntervalSince(lastProfileFetch) > 6 * 3600

        queue.async {
            let outcome = Self.fetch(cached: cached, wantsProfile: wantsProfile)
            DispatchQueue.main.async {
                self.inFlight = false
                self.apply(outcome)
            }
        }
    }

    private enum Outcome {
        case success(OfficialUsage, ClaudeCredentials, AccountProfile?)
        case credentialFailure(CredentialStore.Failure)
        case unauthorized
        case rateLimited(TimeInterval)
        case failed(String)
    }

    private func apply(_ outcome: Outcome) {
        defer { Self.log(outcome, state: state, usage: usage, plan: detectedPlan?.title) }
        switch outcome {
        case .success(let usage, let credentials, let profile):
            self.usage = usage
            self.credentials = credentials
            if let profile {
                detectedPlan = profile.plan
                lastProfileFetch = Date()
            }
            state = .connected
            backoffUntil = .distantPast
            rateLimitStreak = 0
        case .credentialFailure(let failure):
            credentials = nil
            state = failure == .denied ? .denied : .noCredentials
        case .unauthorized:
            credentials = nil
            state = .expired
            backoffUntil = Date().addingTimeInterval(5 * 60)
        case .rateLimited(let retryAfter):
            // 5 分钟起，每次翻倍，最长 30 分钟
            rateLimitStreak += 1
            let backoff = min(30 * 60, 5 * 60 * pow(2, Double(rateLimitStreak - 1)))
            backoffUntil = Date().addingTimeInterval(max(retryAfter, backoff))
            if freshUsage == nil { state = .failed("请求过于频繁") }
        case .failed(let message):
            backoffUntil = Date().addingTimeInterval(60)
            if usage == nil || state != .connected { state = .failed(message) }
        }
        onChange?()
    }

    /// 只记录结果、状态与百分比，不记录任何凭据
    private static func log(_ outcome: Outcome, state: State, usage: OfficialUsage?, plan: String?) {
        let result = switch outcome {
        case .success: "ok"
        case .credentialFailure(let f): "credentials-\(f)"
        case .unauthorized: "unauthorized"
        case .rateLimited(let retry): "rate-limited retry-after=\(Int(retry))s"
        case .failed(let message): "failed \(message)"
        }
        let five = usage?.fiveHour.map { String(format: "%.0f%%", $0.utilization) } ?? "-"
        let week = usage?.sevenDay.map { String(format: "%.0f%%", $0.utilization) } ?? "-"
        print("[official] \(Date().formatted(date: .omitted, time: .standard)) \(result) state=\(state) plan=\(plan ?? "-") 5h=\(five) week=\(week)")
        fflush(stdout)
    }

    // MARK: 后台请求

    nonisolated private static func fetch(cached: ClaudeCredentials?, wantsProfile: Bool) -> Outcome {
        var credentials = cached
        var freshlyRead = false
        if credentials == nil || credentials!.isExpired {
            switch CredentialStore.load() {
            case .success(let c): credentials = c; freshlyRead = true
            case .failure(let f): return .credentialFailure(f)
            }
        }
        guard var current = credentials else { return .credentialFailure(.notFound) }

        var result = request(token: current.accessToken)
        if case .unauthorized = result, !freshlyRead {
            // Claude Code 可能已经刷新了 token：重新读一次钥匙串再试（不会自己刷新）
            if case .success(let reloaded) = CredentialStore.load(), reloaded.accessToken != current.accessToken {
                current = reloaded
                result = request(token: current.accessToken)
            }
        }
        switch result {
        case .success(let usage): return .success(usage, current, wantsProfile ? profile(token: current.accessToken) : nil)
        case .unauthorized: return .unauthorized
        case .rateLimited(let t): return .rateLimited(t)
        case .failed(let m): return .failed(m)
        }
    }

    private enum RequestResult {
        case success(OfficialUsage)
        case unauthorized
        case rateLimited(TimeInterval)
        case failed(String)
    }

    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    nonisolated static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// 与 Claude Code 登录时相同的请求，获取服务端实时的套餐档位
    nonisolated private static func profile(token: String) -> AccountProfile? {
        var request = URLRequest(url: profileEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("claude-usage-monitor/1.0", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        var profile: AccountProfile?
        session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { return }
            profile = AccountProfile.decode(data)
        }.resume()
        semaphore.wait()
        return profile
    }

    nonisolated private static func request(token: String) -> RequestResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-usage-monitor/1.0", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var result = RequestResult.failed("无响应")
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failed((error as NSError).code == NSURLErrorNotConnectedToInternet ? "网络未连接" : "网络错误")
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200:
                // 调试：CUM_DEBUG_OFFICIAL=1 时输出原始响应（只含用量数据，不含凭据）
                if ProcessInfo.processInfo.environment["CUM_DEBUG_OFFICIAL"] == "1", let data {
                    print("[official] raw=\(String(decoding: data, as: UTF8.self))")
                }
                if let data, let usage = try? OfficialUsage.decode(data) {
                    result = .success(usage)
                } else {
                    result = .failed("响应格式已变化")
                }
            case 401, 403:
                result = .unauthorized
            case 429:
                result = .rateLimited(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 120)
            default:
                result = .failed("服务返回 \(http.statusCode)")
            }
        }
        task.resume()
        semaphore.wait()
        return result
    }
}
