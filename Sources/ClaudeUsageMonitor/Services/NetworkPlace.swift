import Foundation
import Network
import Observation
import SystemConfiguration
import UsageCore

/// 菜单栏出口盾牌的四种样子。加载只出现在「安全出口正在重新确认」。
enum MenuShield: Equatable {
    case none, safe, risk, severe, loading
}

/// 查询当前出口的 IP 和地区。位置不明，或在中国大陆、香港、澳门时，不请求官方用量。
@MainActor
@Observable
final class NetworkPlace {
    static let shared = NetworkPlace()

    private(set) var place: PublicNetwork?
    /// 强制走 IPv6 连上 Claude 时的出口。没有 IPv6 路线时为空。
    private(set) var ipv6: PublicNetwork?
    private(set) var checkedAt: Date?
    private(set) var failed = false

    @ObservationIgnored var proxy: OutboundProxy?
    /// 确认用量出口的 trace 只走 IPv4。IPv6 探测仍单独进行，用来发现直连。
    @ObservationIgnored var blockIPv6 = true
    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored private var inFlight = false
    /// 确认过程中路径或代理又变了：这次结束后再确认一次。
    @ObservationIgnored private var routeDirty = false
    @ObservationIgnored private var routeDebounce: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathSignature: String?
    @ObservationIgnored private var interfaceNames: Set<String>?
    @ObservationIgnored private var proxyWatch: SystemProxyWatch?
    /// 路径、代理连跳时并成一次确认。隧道握手往往连续回调好几次。
    private static let routeQuiet: Duration = .milliseconds(500)

    /// 用量实际走的那条出口还没确认，或在中国大陆、香港、澳门。IPv6 直连只警告，不在这里拦截。
    var blocksOfficialUsage: Bool {
        guard let place, !failed else { return true }
        return place.restrictsUsage
    }

    /// 用量出口已确认，且不在中国大陆、香港、澳门。
    var exitIsSafe: Bool { !blocksOfficialUsage }

    /// IPv6 没有走代理，出口落在中国大陆、香港或澳门。
    var ipv6IsDirect: Bool { ipv6?.restrictsUsage == true }

    /// 菜单栏盾牌。安全出口正在重新确认时是加载；风险出口确认期间保持警示，不插入加载。
    var menuShield: MenuShield {
        if checkingSafeExit { return .loading }
        if ipv6IsDirect { return .severe }
        if let place {
            return (failed || place.restrictsUsage) ? .risk : .safe
        }
        if failed { return .risk }
        return heldShield ?? .none
    }

    /// 这次确认开始时，盾牌上是安全勾。
    private(set) var checkingSafeExit = false
    /// `replacing` 会先清掉地址。清掉之后菜单栏仍沿用确认前的盾牌，避免警示闪一下就没了。
    private var heldShield: MenuShield?

    /// 上次确认超过 `maxAge` 才重新确认
    func refreshIfStale(maxAge: TimeInterval = 10 * 60) {
        if let checkedAt, !failed, Date().timeIntervalSince(checkedAt) < maxAge { return }
        refresh()
    }

    /// `replacing`：路线已经变了。先拿掉旧地址，确认失败也不再显示它。
    func refresh(replacing: Bool = false) {
        guard !inFlight else {
            routeDirty = true
            return
        }
        routeDebounce?.cancel()
        routeDebounce = nil
        routeDirty = false
        rememberShield()
        if replacing {
            place = nil
            ipv6 = nil
        }
        inFlight = true
        failed = false
        let proxy = proxy
        let blockIPv6 = blockIPv6
        Task {
            let found = await ClaudeExit.look(proxy: proxy, blockIPv6: blockIPv6)
            inFlight = false
            if routeDirty {
                scheduleRouteRefresh()
            } else {
                adopt(found, replacing: replacing)
                endShieldCheck()
            }
            onUpdate?()
        }
    }

    /// 监听网络路径、网卡和系统代理。只有变化时才重新确认，空闲时不发请求。
    func startWatching() {
        guard pathMonitor == nil else { return }
        let queue = DispatchQueue(label: "io.github.kittors.ClaudeUsageMonitor.network", qos: .utility)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let signature = Self.pathSignature(path)
            Task { @MainActor in
                NetworkPlace.shared.notePath(signature)
            }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor

        let watch = SystemProxyWatch()
        watch.onProxyChange = {
            Task { @MainActor in
                NetworkPlace.shared.scheduleRouteRefresh(fromProxy: true)
            }
        }
        watch.onInterfaces = { names in
            Task { @MainActor in
                NetworkPlace.shared.noteInterfaces(names)
            }
        }
        let names = watch.start(queue: queue)
        proxyWatch = watch
        if let names { noteInterfaces(names) }
    }

    /// 第一次回调是当前路径，不是变化。之后签名变了才确认。
    private func notePath(_ signature: String) {
        if pathSignature == nil {
            pathSignature = signature
            return
        }
        guard pathSignature != signature else { return }
        pathSignature = signature
        scheduleRouteRefresh()
    }

    /// 一次出口确认开始。官方用量发出前的那次确认也走这里。
    func beginShieldCheck() { rememberShield() }

    /// 确认结束。路线变化触发的下一次还没开始时才收起加载。
    func endShieldCheck() {
        guard !inFlight, !routeDirty, routeDebounce == nil else { return }
        checkingSafeExit = false
        heldShield = nil
    }

    /// 记下确认前的盾牌。只有当时是安全勾，确认期间才换成加载。
    private func rememberShield() {
        if checkingSafeExit || heldShield != nil { return }
        if ipv6IsDirect {
            heldShield = .severe
        } else if exitIsSafe {
            heldShield = .safe
            checkingSafeExit = true
        } else if place != nil || failed {
            heldShield = .risk
        }
    }

    /// 虚拟网卡不改默认路径，只出现或消失。名单没变（例如地址续租）不确认。
    private func noteInterfaces(_ names: Set<String>) {
        let previous = interfaceNames
        interfaceNames = names
        guard ExitSignals.interfacesChanged(from: previous, to: names) else { return }
        scheduleRouteRefresh()
    }

    /// 应用里指定了官方代理时，系统代理不影响这条出口。
    private func scheduleRouteRefresh(fromProxy: Bool = false) {
        if fromProxy, proxy != nil { return }
        routeDirty = true
        routeDebounce?.cancel()
        routeDebounce = Task { [weak self] in
            try? await Task.sleep(for: Self.routeQuiet)
            guard !Task.isCancelled, let self else { return }
            self.routeDebounce = nil
            self.refresh(replacing: true)
        }
    }

    nonisolated private static func pathSignature(_ path: NWPath) -> String {
        let faces = path.availableInterfaces
            .map { "\($0.name):\($0.type)" }
            .sorted()
            .joined(separator: ",")
        return "\(path.status)|\(path.unsatisfiedReason)|\(path.isExpensive)|\(path.isConstrained)|\(path.supportsIPv4)|\(path.supportsIPv6)|\(faces)"
    }

    /// 用同一次探测结果更新面板，不再额外触发官方用量。
    func adopt(_ found: ExitSighting, replacing: Bool = false) {
        let next = ExitSignals.apply(
            current: .init(place: place, failed: failed),
            found: found.place,
            replacing: replacing
        )
        place = next.place
        failed = next.failed
        ipv6 = found.ipv6
        if found.place != nil { checkedAt = Date() }
        endShieldCheck()
    }

}

/// 一次出口检查：系统实际选中的地址，以及强制 IPv6 的结果。
struct ExitSighting: Sendable {
    var place: PublicNetwork?
    var ipv6: PublicNetwork?
}

/// 访问 Claude 域名时的出口。官方用量发出前必须再用同一次连接方式确认。
enum ClaudeExit {
    /// 先看用量接口所在的域名，打不开再看 claude.ai。两者都走 Claude 的分流规则，而不是普通 IP 查询站。
    static let traceURLs = [
        URL(string: "https://api.anthropic.com/cdn-cgi/trace")!,
        URL(string: "https://claude.ai/cdn-cgi/trace")!,
    ]

    static func probe(proxy: OutboundProxy?, blockIPv6: Bool) -> ExitSighting {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var found = ExitSighting(place: nil, ipv6: nil)
        Task {
            found = await look(proxy: proxy, blockIPv6: blockIPv6)
            semaphore.signal()
        }
        semaphore.wait()
        return found
    }

    static func look(proxy: OutboundProxy?, blockIPv6: Bool) async -> ExitSighting {
        async let place = trace(proxy: proxy, blockIPv6: blockIPv6)
        async let ipv6 = ipv6Trace()
        return ExitSighting(place: await place, ipv6: await ipv6)
    }

    private static func trace(proxy: OutboundProxy?, blockIPv6: Bool) async -> PublicNetwork? {
        for url in traceURLs {
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
            let data: Data?
            let status: Int?
            if blockIPv6 {
                let (response, body, _) = await PinnedTransport.send(request, proxy: proxy)
                data = body
                status = response?.statusCode
            } else {
                let session = ProxiedSession.make(proxy: proxy)
                let loaded = try? await session.data(for: request)
                data = loaded?.0
                status = (loaded?.1 as? HTTPURLResponse)?.statusCode
            }
            guard status == 200, let data, let text = String(data: data, encoding: .utf8),
                  let place = PublicNetwork.decodeTrace(text) else { continue }
            return place
        }
        return nil
    }

    /// 只走 IPv6 访问用量接口的 trace。连不上表示没有 IPv6 路线，不据此判不安全。
    private static func ipv6Trace() async -> PublicNetwork? {
        let host = "api.anthropic.com"
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 3
        let params = NWParameters(tls: tls, tcp: tcp)
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v6
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: params)
        return await withCheckedContinuation { continuation in
            let once = Once()
            func finish(_ value: PublicNetwork?) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = "GET /cdn-cgi/trace HTTP/1.1\r\nHost: \(host)\r\nAccept: text/plain\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if error != nil { finish(nil); return }
                        receive(connection, into: Data(), finish: finish)
                    })
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }

    private static func receive(_ connection: NWConnection, into data: Data, finish: @escaping (PublicNetwork?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, isComplete, error in
            var data = data
            if let chunk { data.append(chunk) }
            if error != nil || isComplete || data.count > 16384 {
                finish(traceBody(data))
                return
            }
            receive(connection, into: data, finish: finish)
        }
    }

    private static func traceBody(_ data: Data) -> PublicNetwork? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let body: String
        if let range = text.range(of: "\r\n\r\n") {
            body = String(text[range.upperBound...])
        } else {
            body = text
        }
        return PublicNetwork.decodeTrace(body)
    }
}

/// 系统代理，以及网卡出现或消失。Clash 的虚拟网卡不改默认路径，也不改系统代理。
private final class SystemProxyWatch: @unchecked Sendable {
    private var store: SCDynamicStore?
    var onProxyChange: @Sendable () -> Void = {}
    var onInterfaces: @Sendable (Set<String>) -> Void = { _ in }

    func start(queue: DispatchQueue) -> Set<String>? {
        guard store == nil else { return nil }
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(nil, "io.github.kittors.ClaudeUsageMonitor.proxy" as CFString, { store, changed, info in
            guard let info else { return }
            let watch = Unmanaged<SystemProxyWatch>.fromOpaque(info).takeUnretainedValue()
            let keys = changed as NSArray as? [String] ?? []
            if keys.contains(where: { $0.contains("Proxies") }) { watch.onProxyChange() }
            if keys.contains(where: { $0.contains("/Interface/") }) {
                watch.onInterfaces(interfaceNames(in: store))
            }
        }, &context) else { return nil }
        let patterns = [
            "State:/Network/Interface/.*/IPv4",
            "State:/Network/Interface/.*/IPv6",
        ] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/Proxies"] as CFArray, patterns) else { return nil }
        let names = interfaceNames(in: store)
        guard SCDynamicStoreSetDispatchQueue(store, queue) else { return nil }
        self.store = store
        return names
    }
}

private func interfaceNames(in store: SCDynamicStore) -> Set<String> {
    let patterns = [
        "State:/Network/Interface/.*/IPv4",
        "State:/Network/Interface/.*/IPv6",
    ]
    let keys = patterns.flatMap { SCDynamicStoreCopyKeyList(store, $0 as CFString) as? [String] ?? [] }
    return ExitSignals.interfaceNames(in: keys)
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
