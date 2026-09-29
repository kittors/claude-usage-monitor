import Foundation

/// `1.2.0` 或 `v1.2.0`。
public struct AppVersion: Comparable, Sendable, Equatable {
    public var components: [Int]

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: ".")
        guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        components = parts.map { Int($0)! }
    }

    public var text: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// GitHub Release 里的安装包。
public struct AppRelease: Sendable, Equatable {
    public var version: AppVersion
    public var zipURL: URL
    public var checksumURL: URL?

    public init(version: AppVersion, zipURL: URL, checksumURL: URL?) {
        self.version = version
        self.zipURL = zipURL
        self.checksumURL = checksumURL
    }

    /// `GET /repos/{owner}/{repo}/releases/latest`
    public static func decodeGitHub(_ data: Data) throws -> AppRelease {
        struct Raw: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
            let tag_name: String
            let assets: [Asset]
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard let version = AppVersion(raw.tag_name) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "tag"))
        }
        let zip = raw.assets.first { $0.name.hasSuffix("-macOS.zip") }
        guard let zip, let zipURL = URL(string: zip.browser_download_url) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "zip"))
        }
        let checksum = raw.assets.first { $0.name == zip.name + ".sha256" }.flatMap { URL(string: $0.browser_download_url) }
        return AppRelease(version: version, zipURL: zipURL, checksumURL: checksum)
    }
}
