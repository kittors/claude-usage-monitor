import Foundation
import Network
import Observation
import UsageCore

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
    /// 打开后，用来确认用量出口的那次 trace 只走 IPv4。IPv6 探测仍单独进行，用来发现直连。
    @ObservationIgnored var blockIPv6 = false
    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored private var inFlight = false

    /// 用量实际走的那条出口还没确认，或在中国大陆、香港、澳门。IPv6 直连只警告，不在这里拦截。
    var blocksOfficialUsage: Bool {
        guard let place, !failed else { return true }
        return place.restrictsUsage
    }

    /// 用量出口已确认，且不在中国大陆、香港、澳门。
    var exitIsSafe: Bool { !blocksOfficialUsage }

    /// IPv6 没有走代理，出口落在中国大陆、香港或澳门。
    var ipv6IsDirect: Bool { ipv6?.restrictsUsage == true }

    func refreshIfStale() {
        if let checkedAt, !failed, Date().timeIntervalSince(checkedAt) < 10 * 60 { return }
        refresh()
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        failed = false
        let proxy = proxy
        let blockIPv6 = blockIPv6
        Task {
            let found = await ClaudeExit.look(proxy: proxy, blockIPv6: blockIPv6)
            inFlight = false
            adopt(found)
            onUpdate?()
        }
    }

    /// 用同一次探测结果更新面板，不再额外触发官方用量。
    func adopt(_ found: ExitSighting) {
        ipv6 = found.ipv6
        if let place = found.place {
            self.place = place
            checkedAt = Date()
            failed = false
        } else if place == nil {
            failed = true
        }
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
