import Foundation

/// 官方请求的出口。留空表示用 macOS 系统代理；填写后用量和续期都从这里出去。
public struct OutboundProxy: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var socks: Bool

    public init(host: String, port: Int, socks: Bool) {
        self.host = host
        self.port = port
        self.socks = socks
    }

    /// `127.0.0.1:7890`、`http://127.0.0.1:7890`、`socks5://127.0.0.1:7890`
    public static func parse(_ raw: String) -> OutboundProxy? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var socks = false
        let lower = text.lowercased()
        if lower.hasPrefix("socks5://") {
            socks = true
            text.removeFirst("socks5://".count)
        } else if lower.hasPrefix("socks://") {
            socks = true
            text.removeFirst("socks://".count)
        } else if lower.hasPrefix("http://") {
            text.removeFirst("http://".count)
        } else if lower.hasPrefix("https://") {
            text.removeFirst("https://".count)
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
        let host = String(parts[0])
        guard !host.isEmpty, !host.contains(" ") else { return nil }
        return OutboundProxy(host: host, port: port, socks: socks)
    }
}
