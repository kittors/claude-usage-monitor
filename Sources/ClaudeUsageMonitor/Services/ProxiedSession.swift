import Foundation
import UsageCore

enum ProxiedSession {
    static func make(proxy: OutboundProxy?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.urlCache = nil
        if let proxy {
            if proxy.socks {
                config.connectionProxyDictionary = [
                    kCFNetworkProxiesSOCKSEnable as String: 1,
                    kCFNetworkProxiesSOCKSProxy as String: proxy.host,
                    kCFNetworkProxiesSOCKSPort as String: proxy.port,
                ]
            } else {
                config.connectionProxyDictionary = [
                    kCFNetworkProxiesHTTPEnable as String: 1,
                    kCFNetworkProxiesHTTPProxy as String: proxy.host,
                    kCFNetworkProxiesHTTPPort as String: proxy.port,
                    kCFNetworkProxiesHTTPSEnable as String: 1,
                    kCFNetworkProxiesHTTPSProxy as String: proxy.host,
                    kCFNetworkProxiesHTTPSPort as String: proxy.port,
                ]
            }
        }
        return URLSession(configuration: config)
    }
}
