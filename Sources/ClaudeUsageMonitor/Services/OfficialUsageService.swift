import Foundation
import Observation
import OSLog
import SwiftUI
import UsageCore

/// 账号资料（`GET /api/oauth/profile`）：服务端实时的套餐档位和订阅状态。
/// 注意凭据里也存有 `rateLimitTier`，但那是登录时的快照，升级套餐后不会更新，不能用来判断套餐。
struct AccountProfile: Equatable {
    let organizationType: String?
    let rateLimitTier: String?
    /// Stripe 的订阅状态（active、past_due、canceled…）
    var subscriptionStatus: String? = nil
    /// 续费付款需要验证时，官方给出的付款页面（Stripe 托管的账单）
    var paymentActionURL: URL? = nil
    /// 账号的 uuid（`account.uuid`）：用来确认 Claude Code 缓存的用量是不是同一个账号的
    var accountUUID: String? = nil

    /// 订阅还在不在、付款有没有出问题；认不出时为 nil
    var health: SubscriptionHealth? {
        SubscriptionHealth(status: subscriptionStatus, paymentActionRequired: paymentActionURL != nil, hasPaidPlan: plan != nil)
    }

    var plan: Plan? {
        let tier = (rateLimitTier ?? "").lowercased()
        // 服务端仍沿用改名前的档位；Max 20x 现在称为 Ultra。
        if tier.contains("20x") { return .ultra }
        if tier.contains("5x") { return .max }
        switch organizationType?.lowercased() {
        case "claude_pro": return .pro
        case "claude_max": return .max
        case "claude_team": return .team
        case "claude_enterprise": return .enterprise
        default: return nil
        }
    }

    static func decode(_ data: Data) -> AccountProfile? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let org = json["organization"] as? [String: Any]
        let account = (json["account"] as? [String: Any])?["uuid"] as? String
        return AccountProfile(
            organizationType: org?["organization_type"] as? String,
            rateLimitTier: org?["rate_limit_tier"] as? String,
            subscriptionStatus: org?["subscription_status"] as? String,
            paymentActionURL: (org?["payment_auth_hosted_invoice_url"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
            accountUUID: account.flatMap { $0.isEmpty ? nil : $0 }
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
        /// 自动查询：时机由 `AutoSyncPolicy` 决定（Claude Code 正在使用时），这里再确认出口与间隔
        case auto
        /// 用户手动刷新 / 重新连接：只要求出口可用
        case manual
        /// 打开面板时刷新：和手动一样只要求出口可用；10 秒内或限流中就安静地跳过
        case opened
        /// 等待用户完成登录：先只读取钥匙串，登录后才发请求
        case login
    }

    private(set) var state: State = .connecting
    /// 最近一次成功获取的官方数据（同步失败时继续展示，并标明同步时间）
    private(set) var usage: OfficialUsage?
    /// 来自服务端账号资料的套餐（无法确定时为 nil）
    private(set) var detectedPlan: Plan?
    /// 官方订阅状态（和套餐一起从账号资料读取）。还没读到或认不出时为 nil
    private(set) var subscriptionHealth: SubscriptionHealth?
    /// 上次读到账号资料的时间
    private(set) var profileCheckedAt: Date?
    /// 最近一次由本 App 完成续期的时间
    private(set) var lastRenewal: Date?
    /// Claude Code 登录（refresh token）的有效期：到期后无法续期，需要重新登录
    private(set) var loginExpiresAt: Date?
    /// 上一次请求被官方限流了（冷却与之后放慢的节奏由请求预算管着）
    private(set) var isRateLimited = false
    /// 现在显示的数字是 Claude Code 自己查到的（读自它的全局配置，本 App 没有发请求）
    private(set) var usageFromClaudeCode = false
    /// 手动刷新没有发出请求时的简短说明，几秒后消失
    private(set) var notice: String?
    /// 正在查询
    private(set) var isFetching = false

    @ObservationIgnored var onChange: (() -> Void)?
    /// 多久读一次账号资料。平时 6 小时；快到扣费日、刚进入新的一期或订阅出了问题时，UsageStore 改成 1 小时
    @ObservationIgnored var profileInterval: TimeInterval = 6 * 3600
    /// 登录快过期时自动续期（与偏好设置同步，默认开启）
    @ObservationIgnored var autoRenew = true
    /// 非空时，用量和续期都从这里出去；空则使用系统代理
    @ObservationIgnored var outboundProxy: OutboundProxy?
    /// 官方请求固定走 IPv4，不向 Claude 发起 IPv6 连接。
    @ObservationIgnored var blockIPv6 = true
    @ObservationIgnored private var credentials: ClaudeOAuth.Credentials?
    /// 最近一次发出请求的时间（自动查询按它控制间隔）
    @ObservationIgnored private(set) var lastAttempt = Date.distantPast
    @ObservationIgnored private var lastTrigger: Trigger = .auto
    /// 失败后的重试时间（手动刷新不受限制）
    @ObservationIgnored private var retryAfter = Date.distantPast
    @ObservationIgnored private var noticeWork: DispatchWorkItem?
    /// 本 App 登录的账号（来自账号资料，跨重启保留）：只换上同一个账号的 Claude Code 缓存
    @ObservationIgnored private var accountUUID: String?
    /// 上次读 Claude Code 配置文件时它们的修改时间：没变就不用再解析
    @ObservationIgnored private var claudeConfigStamps: [String: Date] = [:]
    @ObservationIgnored private var checkingClaudeCode = false
    @ObservationIgnored private let cacheQueue = DispatchQueue(label: "claude-usage-monitor.claude-code-cache", qos: .utility)
    @ObservationIgnored private var lastProfileFetch = Date.distantPast
    /// 已被服务端拒绝的 refresh token：不再重复尝试，直到 Claude Code 重新登录
    @ObservationIgnored private var deadRefreshToken: String?
    @ObservationIgnored private var loginWatch: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "claude-usage-monitor.official", qos: .utility)
    /// 请求预算：平时平均每 20 分钟最多 1 次，被限流后先停一阵、再放慢；跨重启保留，免得重启后又去碰限额
    @ObservationIgnored private var budget = OfficialUsageService.loadBudget() {
        didSet { Self.saveBudget(budget) }
    }

    init() {
        loadCachedUsage()
        // 上次运行时被限流、冷却还没结束：重启不会让官方的额度恢复，接着等
        if budget.cooldown(at: Date()) > 0 {
            isRateLimited = true
            state = .failed(Self.rateLimitedReason)
        }
    }

    /// 被官方限流时的简短说明
    static var rateLimitedReason: String { L10n.tNow("官方接口限流", "Rate limited by Claude") }

    /// 被限流时，离最早的下一次自动查询还有多久（要等冷却结束、预算攒够）
    func retryWait(at now: Date) -> TimeInterval? {
        guard isRateLimited else { return nil }
        let wait = budget.wait(manual: false, at: now)
        return wait > 0 ? wait : nil
    }

    nonisolated static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    nonisolated static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    nonisolated private static let log = Logger(subsystem: "io.github.kittors.ClaudeUsageMonitor", category: "official")

    /// 任意两次请求的最短间隔（自动与手动都遵守）
    static let minimumSpacing = AutoSyncPolicy.minimumSpacing

    func setEnabled(_ enabled: Bool) {
        if enabled {
            if state == .disabled { state = .connecting }
            loadCachedUsage()
            refresh(.manual)
        } else {
            state = .disabled
            usage = nil
            usageFromClaudeCode = false
            credentials = nil
            // 不再读取账号资料：订阅状态不再更新，不留着旧的结论
            subscriptionHealth = nil
            profileCheckedAt = nil
            lastProfileFetch = .distantPast
            onChange?()
        }
    }

    /// 发起一次查询，返回是否真的发出了。发出前在后台先读登录，再用同一条线路确认出口。
    @discardableResult
    func refresh(_ trigger: Trigger) -> Bool {
        guard state != .disabled, !isFetching else { return false }
        let now = Date()
        let sinceAttempt = now.timeIntervalSince(lastAttempt)
        // 预算里已经算上了被限流后的冷却
        switch trigger {
        case .auto:
            // 出口在中国大陆、香港或澳门，或还没确认位置时，不自动访问官方用量
            guard !NetworkPlace.shared.blocksOfficialUsage,
                  state != .denied, now >= retryAfter, sinceAttempt >= Self.minimumSpacing,
                  budget.allows(manual: false, at: now) else { return false }
        case .manual:
            let wait = max(Self.minimumSpacing - sinceAttempt, budget.wait(manual: true, at: now))
            guard wait <= 0 else {
                // 被限流之后要等的是官方的额度恢复，不是用户点得太快
                flash(isRateLimited
                    ? L10n.tNow("官方接口限流中，\(Self.waitText(wait))后可再试", "Claude is limiting usage checks. Try again in \(Self.waitText(wait))")
                    : L10n.tNow("刚刚查询过，\(Self.waitText(wait))后可再试", "Just checked. Try again in \(Self.waitText(wait))"))
                return false
            }
        case .opened:
            guard sinceAttempt >= Self.minimumSpacing, budget.allows(manual: false, at: now) else { return false }
        case .login:
            guard state.awaitingLogin, sinceAttempt >= 2, budget.allows(manual: true, at: now) else { return false }
        }
        isFetching = true
        lastAttempt = now
        lastTrigger = trigger
        // 发请求前会在后台再确认一次出口，盾牌不变：只有网络真的变了才显示加载
        let request = FetchRequest(
            cached: credentials,
            autoRenew: autoRenew,
            wantsProfile: now.timeIntervalSince(lastProfileFetch) > profileInterval,
            deadRefreshToken: deadRefreshToken,
            proxy: outboundProxy,
            blockIPv6: blockIPv6,
            // 等待登录时要确认的是本机的登录，不拿 Claude Code 的缓存代替
            claudeCodeAccount: trigger == .login ? nil : accountUUID,
            shownAt: usage?.fetchedAt
        )
        queue.async {
            let outcome = Self.fetch(request)
            DispatchQueue.main.async {
                self.isFetching = false
                self.apply(outcome)
            }
        }
        return true
    }

    /// 还要等多久：不到一分钟按秒，否则按分钟（向上取整）
    private static func waitText(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            let s = max(1, Int(seconds.rounded(.up)))
            return L10n.tNow("\(s) 秒", "\(s) s")
        }
        let minutes = Int((seconds / 60).rounded(.up))
        return L10n.tNow("约 \(minutes) 分钟", "about \(minutes) min")
    }

    /// 在状态栏位置显示几秒的说明（手动刷新没有发出请求时）
    private func flash(_ message: String) {
        notice = message
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// 看看 Claude Code 有没有查到更新的数字：只读本机的配置文件，不发请求；文件没变时什么都不做。
    /// 被限流期间界面也能跟上 Claude Code 查到的数字。
    func checkClaudeCode() {
        // 还不知道自己的账号（第一次读到账号资料之前）时不换，免得换上别的账号的数字
        guard state != .disabled, !isFetching, !checkingClaudeCode, accountUUID != nil else { return }
        checkingClaudeCode = true
        let stamps = claudeConfigStamps
        cacheQueue.async {
            let (cache, latest) = Self.readClaudeCodeCache(skipping: stamps)
            DispatchQueue.main.async {
                self.checkingClaudeCode = false
                self.claudeConfigStamps = latest
                // 正在查询时以那次的结果为准
                guard let cache, !self.isFetching, self.state != .disabled,
                      cache.replaces(self.usage?.fetchedAt, account: self.accountUUID, now: Date()) else { return }
                self.apply(.claudeCode(cache.usage))
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

    // MARK: 结果

    private struct FetchRequest: Sendable {
        var cached: ClaudeOAuth.Credentials?
        var autoRenew: Bool
        var wantsProfile: Bool
        var deadRefreshToken: String?
        var proxy: OutboundProxy?
        var blockIPv6: Bool
        /// 本 App 的账号：Claude Code 刚查到同一账号的数字时直接用，不再发请求。为 nil 时不看 Claude Code 的缓存
        var claudeCodeAccount: String?
        /// 现在显示的数字是什么时候查到的
        var shownAt: Date?
    }

    private enum Outcome {
        case success(OfficialUsage, ClaudeOAuth.Credentials, AccountProfile?, renewed: Bool)
        /// Claude Code 查到的更新的数字（读自它的全局配置，没有发请求）
        case claudeCode(OfficialUsage)
        case credentialFailure(CredentialStore.Failure)
        /// 登录已过期，且不能或不允许续期
        case expired
        /// 续期被拒绝（附带被拒绝的 refresh token）
        case signedOut(String?)
        case renewFailed(String, retryIn: TimeInterval)
        case unauthorized
        /// 被限流：服务器要求等的秒数（没给时为 nil）、响应里的错误类型（记日志用），以及顺带读到的账号资料
        case rateLimited(TimeInterval?, String?, AccountProfile?)
        case failed(String)
        /// 出口不是 Claude 的可用出口，没有发送用量请求
        case exitBlocked

        /// 只读取了钥匙串、没有发出请求（等待登录时会频繁出现）
        var isLocal: Bool {
            switch self {
            case .credentialFailure, .expired, .signedOut(.none), .exitBlocked: true
            default: false
            }
        }

        /// 真的向用量接口发了请求，计入请求预算
        var reachedUsageEndpoint: Bool {
            switch self {
            case .success, .unauthorized, .rateLimited, .failed: true
            default: false
            }
        }
    }

    private func apply(_ outcome: Outcome) {
        let now = Date()
        let previous = state
        if outcome.reachedUsageEndpoint {
            budget.spend(at: now)
            // 这次请求没有被限流：之前的限流已经过去（冷却和放慢的节奏仍由预算管着）
            if case .rateLimited = outcome {} else { isRateLimited = false }
        }
        switch outcome {
        case .success(let usage, let credentials, let profile, let renewed):
            // 数字滚动、进度条缓动到新值
            withAnimation(self.usage == nil ? nil : .smooth(duration: 0.6)) { self.usage = usage }
            usageFromClaudeCode = false
            self.credentials = credentials
            loginExpiresAt = credentials.refreshTokenExpiresAt
            deadRefreshToken = nil
            if renewed { lastRenewal = now }
            if let profile { adopt(profile, at: now) }
            state = .connected
            retryAfter = .distantPast
            budget.succeeded()
            saveCachedUsage(usage)
        case .claudeCode(let usage):
            withAnimation(self.usage == nil ? nil : .smooth(duration: 0.6)) { self.usage = usage }
            usageFromClaudeCode = true
            saveCachedUsage(usage)
            // 数字已经是新的了：暂时性的失败（包括限流）不再显示；登录失效之类需要用户处理的照旧
            switch state {
            case .connecting, .failed: state = .connected
            default: break
            }
        case .credentialFailure(let failure):
            credentials = nil
            state = switch failure {
            case .denied: .denied
            case .signedOut: .signedOut
            case .notFound, .invalid: .noCredentials
            case .locked: .failed(L10n.tNow("钥匙串已锁定", "Keychain is locked"))
            case .unreadable: .failed(L10n.tNow("无法读取钥匙串", "Could not read the keychain"))
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
            state = autoRenew ? .failed(L10n.tNow("授权失败", "Authorization failed")) : .expired
            retryAfter = now.addingTimeInterval(5 * 60)
        case .rateLimited(let retry, _, let profile):
            // 同一账号的 Claude Code 等客户端共用这份额度：先停一阵（15 分钟起，冷却期间又被拒就翻倍，最长 1 小时），
            // 之后更慢地攒，没有再被限流时慢慢恢复
            budget.rateLimited(retryAfter: retry, at: now)
            isRateLimited = true
            if let profile { adopt(profile, at: now) }
            state = .failed(Self.rateLimitedReason)
        case .failed(let message):
            state = .failed(message)
            retryAfter = now.addingTimeInterval(60)
        case .exitBlocked:
            // 出口不可用，没有发出请求。手动刷新时说明原因
            if lastTrigger == .manual {
                flash(NetworkPlace.shared.place?.restrictsUsage == true
                    ? L10n.tNow("出口在中国大陆、香港或澳门，没有查询", "The exit is in mainland China, Hong Kong, or Macau. Not checked")
                    : L10n.tNow("无法确认出口，没有查询", "Could not confirm the exit. Not checked"))
            }
        }
        // 等待登录期间状态不变的检查不重复记录
        if state != previous || !outcome.isLocal { Self.record(outcome, state: state, usage: usage) }
        onChange?()
    }

    /// 读到了账号资料：套餐、订阅状态，以及这次登录的账号
    private func adopt(_ profile: AccountProfile, at now: Date) {
        detectedPlan = profile.plan
        subscriptionHealth = profile.health
        lastProfileFetch = now
        profileCheckedAt = now
        if let account = profile.accountUUID { accountUUID = account }
    }

    /// 需要重新登录：清掉与这次登录相关的信息，重新登录（可能换了账号）后重新获取套餐
    private func signedOut() {
        loginExpiresAt = nil
        subscriptionHealth = nil
        profileCheckedAt = nil
        lastProfileFetch = .distantPast
    }

    /// 只记录结果、状态与百分比，不记录任何凭据
    private static func record(_ outcome: Outcome, state: State, usage: OfficialUsage?) {
        let result = switch outcome {
        case .success(_, _, _, let renewed): renewed ? "ok (renewed login)" : "ok"
        case .claudeCode(let usage): "from Claude Code (fetched \(Int(Date().timeIntervalSince(usage.fetchedAt)))s ago)"
        case .credentialFailure(let f): "credentials-\(f)"
        case .expired: "login expired"
        case .signedOut: "signed out, sign in again in Claude Code"
        case .renewFailed(let message, _): "renewal failed: \(message)"
        case .unauthorized: "unauthorized"
        case .rateLimited(let retry, let detail, _):
            "rate-limited retry-after=\(retry.map { "\(Int($0))s" } ?? "none")\(detail.map { " (\($0))" } ?? "")"
        case .failed(let message): "failed \(message)"
        case .exitBlocked: "exit blocked"
        }
        let five = usage?.fiveHour.map { "\($0.percent)%" } ?? "-"
        let week = usage?.sevenDay.map { "\($0.percent)%" } ?? "-"
        log.notice("\(result, privacy: .public) state=\(String(describing: state), privacy: .public) 5h=\(five, privacy: .public) week=\(week, privacy: .public)")
    }

    // MARK: 后台请求

    /// 调试：`CUM_FORCE_RENEW=1` 时，启动后第一次同步强制续期一次（用于验证续期流程；只在后台队列访问）
    nonisolated(unsafe) private static var forceRenewPending = ProcessInfo.processInfo.environment["CUM_FORCE_RENEW"] == "1"

    nonisolated private static func fetch(_ r: FetchRequest) -> Outcome {
        // Claude Code 刚查过同一账号的数字：直接用，不再去碰共用的额度
        if r.claudeCodeAccount != nil, let cache = readClaudeCodeCache(skipping: [:]).cache {
            let now = Date()
            if cache.isFresh(at: now), cache.replaces(r.shownAt, account: r.claudeCodeAccount, now: now) {
                return .claudeCode(cache.usage)
            }
        }
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
        // 登录已经过期又不能续期：不用发任何请求
        if current.isExpired() {
            if !(r.autoRenew && current.isRefreshable) { return .expired }
            if let dead = r.deadRefreshToken, dead == current.refreshToken { return .signedOut(nil) }
        }

        // 发请求（续期或查询）之前，用同一条线路再确认一次出口
        let exit = ClaudeExit.probe(proxy: r.proxy, blockIPv6: r.blockIPv6)
        DispatchQueue.main.async { NetworkPlace.shared.adopt(exit) }
        guard let place = exit.place, !place.restrictsUsage else { return .exitBlocked }

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

        var result = request(token: current.accessToken, proxy: r.proxy, blockIPv6: r.blockIPv6)
        if case .unauthorized = result {
            // 与 Claude Code 收到 401 时的处理相同：钥匙串里已有新令牌就直接用，否则强制续期后重试
            if case .success(let loaded) = CredentialStore.load(), loaded.stored.credentials.accessToken != current.accessToken {
                current = loaded.stored.credentials
                result = request(token: current.accessToken, proxy: r.proxy, blockIPv6: r.blockIPv6)
            } else {
                switch renew(current, request: r, force: true) {
                case .renewed(let c):
                    current = c
                    renewed = true
                    result = request(token: c.accessToken, proxy: r.proxy, blockIPv6: r.blockIPv6)
                case .current(let c) where c.accessToken != current.accessToken:
                    current = c
                    result = request(token: c.accessToken, proxy: r.proxy, blockIPv6: r.blockIPv6)
                case .current:
                    break
                case .unavailable(let outcome):
                    return outcome
                }
            }
        }
        switch result {
        case .success(let usage):
            return .success(usage, current, r.wantsProfile ? profile(token: current.accessToken, proxy: r.proxy, blockIPv6: r.blockIPv6) : nil, renewed: renewed)
        case .unauthorized: return .unauthorized
        case .rateLimited(let retry, let detail):
            // 账号资料是另一个接口：到了该读的时候照常读，限流期间也知道套餐和账号（换上 Claude Code 的数字要用到账号）
            return .rateLimited(retry, detail, r.wantsProfile ? profile(token: current.accessToken, proxy: r.proxy, blockIPv6: r.blockIPv6) : nil)
        case .failed(let m): return .failed(m)
        }
    }

    /// 读 Claude Code 的全局配置，取出它缓存的用量（有几个配置文件时取最新的一份）。
    /// 修改时间与 `stamps` 里记下的相同的文件不再解析；返回这次看到的修改时间。只在后台队列调用。
    nonisolated private static func readClaudeCodeCache(skipping stamps: [String: Date]) -> (cache: ClaudeCodeUsageCache?, stamps: [String: Date]) {
        var newest: ClaudeCodeUsageCache?
        var seen: [String: Date] = [:]
        for url in ClaudeCodeUsageCache.configFiles() {
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            seen[url.path] = modified
            guard stamps[url.path] != modified,
                  let data = try? Data(contentsOf: url),
                  let cache = ClaudeCodeUsageCache.parse(data) else { continue }
            if newest.map({ cache.usage.fetchedAt > $0.usage.fetchedAt }) ?? true { newest = cache }
        }
        return (newest, seen)
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
            return .unavailable(.renewFailed(L10n.tNow("钥匙串已锁定", "Keychain is locked"), retryIn: 60))
        }

        let locks = ClaudeCodeLocks()
        let renewal = CredentialRenewal(
            read: {
                guard case .success(let latest) = CredentialStore.load(), latest.location == location else { return nil }
                return latest.stored
            },
            write: { CredentialStore.save($0, to: location) },
            send: { send($0, proxy: r.proxy, blockIPv6: r.blockIPv6) },
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
            case .locked: return .unavailable(.renewFailed(L10n.tNow("Claude Code 正在续期", "Claude Code is renewing"), retryIn: 30))
            case .noCredentials:
                if case .failure(let failure) = CredentialStore.load() { return .unavailable(.credentialFailure(failure)) }
                return .unavailable(.credentialFailure(.notFound))
            case .notRenewable: return .unavailable(.expired)
            case .notWritable: return .unavailable(.renewFailed(L10n.tNow("无法写入钥匙串", "Could not write the keychain"), retryIn: 5 * 60))
            case .signedOut: return .unavailable(.signedOut(c.refreshToken))
            case .network(let message): return .unavailable(.renewFailed(message, retryIn: 60))
            case .server(let message): return .unavailable(.renewFailed(L10n.tNow("续期失败（\(message)）", "Renewal failed (\(message))"), retryIn: 5 * 60))
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
        case rateLimited(TimeInterval?, String?)
        case failed(String)
    }

    /// 不设置单独的客户端名字。未指定代理时沿用系统代理，指定后用量和续期都从那里出去。
    nonisolated private static func makeSession(proxy: OutboundProxy?) -> URLSession {
        ProxiedSession.make(proxy: proxy)
    }

    /// 同步发送请求（只在后台队列调用）
    nonisolated private static func perform(_ request: URLRequest, proxy: OutboundProxy?, blockIPv6: Bool) -> (HTTPURLResponse?, Data?, Error?) {
        if blockIPv6 { return PinnedTransport.perform(request, proxy: proxy) }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (HTTPURLResponse?, Data?, Error?) = (nil, nil, nil)
        makeSession(proxy: proxy).dataTask(with: request) { data, response, error in
            result = (response as? HTTPURLResponse, data, error)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }

    nonisolated private static func send(_ request: URLRequest, proxy: OutboundProxy?, blockIPv6: Bool) -> CredentialRenewal.Response? {
        let (response, data, _) = perform(request, proxy: proxy, blockIPv6: blockIPv6)
        return response.map { CredentialRenewal.Response(status: $0.statusCode, body: data) }
    }

    /// 与 Claude Code 登录时相同的请求，获取服务端实时的套餐档位
    nonisolated private static func profile(token: String, proxy: OutboundProxy?, blockIPv6: Bool) -> AccountProfile? {
        var request = URLRequest(url: profileEndpoint, timeoutInterval: 12)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (response, data, _) = perform(request, proxy: proxy, blockIPv6: blockIPv6)
        guard response?.statusCode == 200, let data else { return nil }
        return AccountProfile.decode(data)
    }

    nonisolated private static func request(token: String, proxy: OutboundProxy?, blockIPv6: Bool) -> RequestResult {
        var request = URLRequest(url: endpoint, timeoutInterval: 12)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (response, data, error) = perform(request, proxy: proxy, blockIPv6: blockIPv6)
        if let error {
            return .failed((error as NSError).code == NSURLErrorNotConnectedToInternet ? L10n.tNow("网络未连接", "Offline") : L10n.tNow("网络错误", "Network error"))
        }
        guard let response else { return .failed(L10n.tNow("无响应", "No response")) }
        switch response.statusCode {
        case 200:
            // 调试：CUM_DEBUG_OFFICIAL=1 时输出原始响应（只含用量数据，不含凭据）
            if ProcessInfo.processInfo.environment["CUM_DEBUG_OFFICIAL"] == "1", let data {
                print("[official] raw=\(String(decoding: data, as: UTF8.self))")
            }
            guard let data, let usage = try? OfficialUsage.decode(data) else { return .failed(L10n.tNow("响应格式已变化", "Unexpected response")) }
            return .success(usage)
        case 401, 403:
            return .unauthorized
        case 429:
            // 实测这个接口限流时 Retry-After 是 0，等多久由请求预算决定
            let retry = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(retry, errorSummary(data))
        default:
            return .failed(L10n.tNow("服务返回 \(response.statusCode)", "Server returned \(response.statusCode)"))
        }
    }

    /// 错误响应的类型与说明（只记日志用，不含凭据）：官方的 JSON 错误取 `error.type` 和 `error.message`，
    /// 其他内容（例如网关返回的网页）只取开头一小段
    nonisolated static func errorSummary(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            let type = error["type"] as? String ?? "error"
            let message = (error["message"] as? String).map { ": " + String($0.prefix(120)) } ?? ""
            return type + message
        }
        let text = String(decoding: data.prefix(120), as: UTF8.self)
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : "non-JSON: " + text
    }

    // MARK: 请求预算

    private static let budgetKey = "officialRequestBudget"

    private static func loadBudget() -> RequestBudget {
        guard let data = UserDefaults.standard.data(forKey: budgetKey),
              let budget = try? JSONDecoder().decode(RequestBudget.self, from: data) else { return RequestBudget() }
        return budget
    }

    private static func saveBudget(_ budget: RequestBudget) {
        guard let data = try? JSONEncoder().encode(budget) else { return }
        UserDefaults.standard.set(data, forKey: budgetKey)
    }

    // MARK: 上次的官方数字（不含登录）

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ClaudeUsageMonitor/official-usage.json")
    }

    private struct UsageCache: Codable {
        struct Item: Codable {
            var utilization: Double
            var resetsAt: Date?
        }
        struct Scoped: Codable {
            var modelName: String
            var utilization: Double
            var resetsAt: Date?
        }
        var fetchedAt: Date
        var fiveHour: Item?
        var sevenDay: Item?
        var sevenDaySonnet: Item?
        var sevenDayOpus: Item?
        var scoped: [Scoped]
        /// 旧版本写的缓存里没有这一项
        var extraUsageEnabled: Bool?
        /// 本 App 登录的账号（1.7.2 起）
        var accountUUID: String?
        /// 这份数字是 Claude Code 查到的（1.7.2 起）
        var fromClaudeCode: Bool?
    }

    private func loadCachedUsage() {
        guard let data = try? Data(contentsOf: Self.cacheURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let cache = try? decoder.decode(UsageCache.self, from: data) else { return }
        func limit(_ item: UsageCache.Item?) -> OfficialLimit? {
            item.map { OfficialLimit(utilization: $0.utilization, resetsAt: $0.resetsAt) }
        }
        usage = OfficialUsage(
            fiveHour: limit(cache.fiveHour),
            sevenDay: limit(cache.sevenDay),
            sevenDaySonnet: limit(cache.sevenDaySonnet),
            sevenDayOpus: limit(cache.sevenDayOpus),
            scoped: cache.scoped.map {
                ScopedLimit(modelName: $0.modelName, limit: OfficialLimit(utilization: $0.utilization, resetsAt: $0.resetsAt))
            },
            extraUsageEnabled: cache.extraUsageEnabled,
            fetchedAt: cache.fetchedAt
        )
        usageFromClaudeCode = cache.fromClaudeCode ?? false
        if let account = cache.accountUUID { accountUUID = account }
        if state == .connecting || state == .disabled { state = .connected }
    }

    private func saveCachedUsage(_ usage: OfficialUsage) {
        func item(_ limit: OfficialLimit?) -> UsageCache.Item? {
            limit.map { UsageCache.Item(utilization: $0.utilization, resetsAt: $0.resetsAt) }
        }
        let cache = UsageCache(
            fetchedAt: usage.fetchedAt,
            fiveHour: item(usage.fiveHour),
            sevenDay: item(usage.sevenDay),
            sevenDaySonnet: item(usage.sevenDaySonnet),
            sevenDayOpus: item(usage.sevenDayOpus),
            scoped: usage.scoped.map {
                UsageCache.Scoped(modelName: $0.modelName, utilization: $0.limit.utilization, resetsAt: $0.limit.resetsAt)
            },
            extraUsageEnabled: usage.extraUsageEnabled,
            accountUUID: accountUUID,
            fromClaudeCode: usageFromClaudeCode
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(cache) else { return }
        let url = Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
