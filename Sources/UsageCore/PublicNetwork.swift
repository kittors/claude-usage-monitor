import Foundation

/// 当前出口网络。官方用量是否发出，只看这个地址是不是中国大陆、香港或澳门。
public struct PublicNetwork: Sendable, Equatable {
    public var ip: String
    public var countryCode: String
    public var region: String?
    public var city: String?

    public init(ip: String, countryCode: String, region: String?, city: String?) {
        self.ip = ip
        self.countryCode = countryCode.uppercased()
        self.region = region
        self.city = city
    }

    /// 中国大陆、香港、澳门。这些出口绝不查询官方用量。
    public var restrictsUsage: Bool {
        Self.restrictsUsage(countryCode: countryCode)
    }

    public static func restrictsUsage(countryCode: String) -> Bool {
        switch countryCode.uppercased() {
        case "CN", "HK", "MO": true
        default: false
        }
    }

    public var isUnitedStates: Bool { countryCode == "US" }

    public var isIPv6: Bool { ip.contains(":") }

    /// 国旗。两位国家码转成区域指示符。
    public var flag: String {
        let base: UInt32 = 127397
        return countryCode.unicodeScalars.compactMap { UnicodeScalar(base + $0.value).map(String.init) }.joined()
    }

    public static func decode(_ data: Data) throws -> PublicNetwork {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "network"))
        }
        if let success = json["success"] as? Bool, success == false {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "lookup failed"))
        }
        guard let ip = json["ip"] as? String, !ip.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "ip"))
        }
        let code = (json["country_code"] as? String) ?? (json["country"] as? String)
        guard let code, code.count == 2 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "country"))
        }
        func text(_ key: String) -> String? {
            guard let value = json[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return PublicNetwork(ip: ip, countryCode: code, region: text("region"), city: text("city"))
    }

    /// Cloudflare 在 Claude 域名上的 trace：`ip=` 是访问该域名时的出口，`loc=` 是地区。
    public static func decodeTrace(_ text: String) -> PublicNetwork? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let sign = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<sign])
            let value = String(line[line.index(after: sign)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        guard let ip = fields["ip"], let loc = fields["loc"], loc.count == 2 else { return nil }
        return PublicNetwork(ip: ip, countryCode: loc, region: fields["colo"], city: nil)
    }
}
