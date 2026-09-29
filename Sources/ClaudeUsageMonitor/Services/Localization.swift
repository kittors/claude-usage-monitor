import Foundation
import Observation
import UsageCore

/// 界面语言。默认跟随系统：首选语言是中文则用简体中文，否则用英文。
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system, zhHans, en
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.tNow("跟随系统", "System")
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }
}

/// 当前界面语言。视图在取文案时读到 `token`，切换后会重绘。
@MainActor
@Observable
final class Localization {
    static let shared = Localization()

    private(set) var token = 0
    private(set) var isChinese: Bool

    var locale: Locale { isChinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US") }

    private init() {
        isChinese = Self.systemIsChinese
        Fmt.localizedChinese = isChinese
        L10n.setChinese(isChinese)
    }

    func apply(_ choice: AppLanguage) {
        let chinese = switch choice {
        case .zhHans: true
        case .en: false
        case .system: Self.systemIsChinese
        }
        isChinese = chinese
        Fmt.localizedChinese = chinese
        L10n.setChinese(chinese)
        token += 1
    }

    static var systemIsChinese: Bool {
        (Locale.preferredLanguages.first ?? "").hasPrefix("zh")
    }
}

@MainActor
enum L10n {
    nonisolated(unsafe) private static var chinese = true

    nonisolated static func setChinese(_ value: Bool) { chinese = value }

    static func t(_ zh: String, _ en: String) -> String {
        _ = Localization.shared.token
        return chinese ? zh : en
    }

    /// 后台线程上的文案（错误信息）。用最近一次在主线程确定的语言。
    nonisolated static func tNow(_ zh: String, _ en: String) -> String {
        chinese ? zh : en
    }

    static func currency(_ unit: MoneyFormat.Unit) -> String {
        switch unit {
        case .usd: t("美元 $", "US Dollar $")
        case .cny: t("人民币 ¥", "Chinese Yuan ¥")
        case .jpy: t("日元 JP¥", "Japanese Yen JP¥")
        case .gbp: t("英镑 £", "British Pound £")
        case .eur: t("欧元 €", "Euro €")
        case .hkd: t("港币 HK$", "Hong Kong Dollar HK$")
        case .sgd: t("新加坡元 S$", "Singapore Dollar S$")
        case .aud: t("澳元 A$", "Australian Dollar A$")
        case .cad: t("加元 C$", "Canadian Dollar C$")
        case .chf: t("瑞士法郎 CHF", "Swiss Franc CHF")
        case .krw: t("韩元 ₩", "Korean Won ₩")
        }
    }
}
