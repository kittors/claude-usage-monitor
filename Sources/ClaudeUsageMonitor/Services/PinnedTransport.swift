import Foundation
import Network
import UsageCore

/// 把一条 HTTPS 请求固定在 IPv4 上发出。主机名保持不变，所以代理的域名规则仍然生效。
enum PinnedTransport {
    static func perform(_ request: URLRequest, proxy explicit: OutboundProxy?) -> (HTTPURLResponse?, Data?, Error?) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (HTTPURLResponse?, Data?, Error?) = (nil, nil, nil)
        Task {
            result = await send(request, proxy: explicit)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    static func send(_ request: URLRequest, proxy explicit: OutboundProxy?) async -> (HTTPURLResponse?, Data?, Error?) {
        guard let url = request.url, let host = url.host, url.scheme == "https" else {
            return (nil, nil, URLError(.unsupportedURL))
        }
        let proxy = explicit ?? systemProxy(for: url)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        let params = NWParameters(tls: tls, tcp: tcp)
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        if let proxy, let port = NWEndpoint.Port(rawValue: UInt16(proxy.port)) {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.host), port: port)
            let privacy = NWParameters.PrivacyContext(description: "ClaudeUsageMonitor")
            privacy.proxyConfigurations = [
                proxy.socks
                    ? ProxyConfiguration(socksv5Proxy: endpoint)
                    : ProxyConfiguration(httpCONNECTProxy: endpoint),
            ]
            params.setPrivacyContext(privacy)
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: params)
        let payload = httpPayload(request, host: host)
        return await withCheckedContinuation { continuation in
            let once = TransportOnce()
            func finish(_ value: (HTTPURLResponse?, Data?, Error?)) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if error != nil {
                            finish((nil, nil, error))
                            return
                        }
                        read(connection, into: Data()) { data in
                            finish(parse(data, url: url))
                        }
                    })
                case .failed(let error):
                    finish((nil, nil, error))
                case .cancelled:
                    finish((nil, nil, URLError(.cancelled)))
                default:
                    break
                }
            }
            connection.start(queue: .global())
            let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 20
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish((nil, nil, URLError(.timedOut)))
            }
        }
    }

    private static func httpPayload(_ request: URLRequest, host: String) -> Data {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path.isEmpty == false ? request.url!.path : "/"
        let query = request.url?.query.map { "?\($0)" } ?? ""
        var lines = ["\(method) \(path)\(query) HTTP/1.1", "Host: \(host)", "Connection: close"]
        let body = request.httpBody ?? Data()
        if !body.isEmpty { lines.append("Content-Length: \(body.count)") }
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = key.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" { continue }
            lines.append("\(key): \(value)")
        }
        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(Data("\r\n\r\n".utf8))
        data.append(body)
        return data
    }

    private static func read(_ connection: NWConnection, into data: Data, done: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { chunk, _, isComplete, error in
            var data = data
            if let chunk { data.append(chunk) }
            if error != nil || isComplete || data.count > 1_000_000 {
                done(data)
                return
            }
            read(connection, into: data, done: done)
        }
    }

    private static func parse(_ data: Data, url: URL) -> (HTTPURLResponse?, Data?, Error?) {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)) else {
            return (nil, nil, URLError(.badServerResponse))
        }
        let head = String(data: data[..<marker.lowerBound], encoding: .utf8) ?? ""
        var body = Data(data[marker.upperBound...])
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let status = lines.first?.split(separator: " "), status.count >= 2, let code = Int(status[1]) else {
            return (nil, nil, URLError(.badServerResponse))
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = String(value)
        }
        if headers.first(where: { $0.key.lowercased() == "transfer-encoding" })?.value.lowercased().contains("chunked") == true {
            body = decodeChunked(body) ?? body
        }
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)
        return (response, body, nil)
    }

    private static func decodeChunked(_ data: Data) -> Data? {
        var result = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let lineEnd = data[index...].range(of: crlf) else { return nil }
            let line = String(data: data[index..<lineEnd.lowerBound], encoding: .utf8) ?? ""
            let hex = line.split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            index = lineEnd.upperBound
            if size == 0 { return result }
            guard data.distance(from: index, to: data.endIndex) >= size else { return nil }
            result.append(data[index..<data.index(index, offsetBy: size)])
            index = data.index(index, offsetBy: size)
            if data[index...].starts(with: crlf) { index = data.index(index, offsetBy: 2) }
        }
        return result
    }

    /// 空的应用代理表示沿用系统为这个地址选中的代理。
    private static func systemProxy(for url: URL) -> OutboundProxy? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else { return nil }
        let listed = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]] ?? []
        guard let first = listed.first else { return nil }
        let type = first[kCFProxyTypeKey as String] as? String
        if type == nil || type == (kCFProxyTypeNone as String) { return nil }
        guard let host = first[kCFProxyHostNameKey as String] as? String, !host.isEmpty else { return nil }
        let port = (first[kCFProxyPortNumberKey as String] as? Int)
            ?? (first[kCFProxyPortNumberKey as String] as? NSNumber)?.intValue
        guard let port, (1...65535).contains(port) else { return nil }
        let socks = type == (kCFProxyTypeSOCKS as String)
        let http = type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String)
        guard socks || http else { return nil }
        return OutboundProxy(host: host, port: port, socks: socks)
    }
}

private final class TransportOnce: @unchecked Sendable {
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
