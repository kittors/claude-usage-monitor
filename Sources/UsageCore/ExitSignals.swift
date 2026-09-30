import Foundation

/// 出口要不要重查。默认路径看不出 Clash 这类虚拟网卡：它不改默认路由，只多挂一块网卡。
public enum ExitSignals {
    /// `State:/Network/Interface/utun9/IPv4` 里的网卡名。
    public static func interfaceName(inDynamicStoreKey key: String) -> String? {
        let parts = key.split(separator: "/")
        guard parts.count >= 5, parts[0] == "State:", parts[1] == "Network", parts[2] == "Interface" else { return nil }
        guard parts[4].hasPrefix("IPv") else { return nil }
        let name = String(parts[3])
        return name.isEmpty ? nil : name
    }

    public static func interfaceNames(in keys: some Sequence<String>) -> Set<String> {
        Set(keys.compactMap(interfaceName(inDynamicStoreKey:)))
    }

    /// 第一次看到的名单只是基线。之后多一块或少一块网卡，才要重新确认。
    public static func interfacesChanged(from previous: Set<String>?, to next: Set<String>) -> Bool {
        guard let previous else { return false }
        return previous != next
    }

    public struct HeldExit: Equatable, Sendable {
        public var place: PublicNetwork?
        public var failed: Bool

        public init(place: PublicNetwork? = nil, failed: Bool = false) {
            self.place = place
            self.failed = failed
        }
    }

    /// 路线变了之后这次确认失败，就清掉上一条出口。没变路线时，一次失败仍留着上次的结果。
    public static func apply(current: HeldExit, found: PublicNetwork?, replacing: Bool) -> HeldExit {
        if let found {
            return HeldExit(place: found, failed: false)
        }
        if replacing || current.place == nil {
            return HeldExit(place: nil, failed: true)
        }
        return current
    }
}
