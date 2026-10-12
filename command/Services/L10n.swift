//
//  L10n.swift
//  Naki
//
//  App 內語言選擇與給「不經 SwiftUI Text」的字串用的本地化入口。
//
//  SwiftUI 的 `Text("繁中 key")` 由 `ContentView` 與各 sheet 根的 `.appLocale()` 切換；
//  Services 產生的狀態列／橫幅訊息走 `L10n.text`。
//

import SwiftUI

/// App 內語言。`rawValue` 會被持久化，同時是 String Catalog 的語言代碼（`system` 除外）。
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case zhHant = "zh-Hant"
    case zhHans = "zh-Hans"
    case en
    case ja
    case ko

    nonisolated var id: String { rawValue }

    /// `system` 為 nil：交給系統語言，不覆寫。
    nonisolated var locale: Locale? {
        self == .system ? nil : Locale(identifier: rawValue)
    }

    /// 各語言自己的名稱（不翻譯）；`system` 沒有，由 UI 用本地化的「跟隨系統」。
    nonisolated var nativeName: String? {
        switch self {
        case .system: return nil
        case .zhHant: return "繁體中文"
        case .zhHans: return "简体中文"
        case .en:     return "English"
        case .ja:     return "日本語"
        case .ko:     return "한국어"
        }
    }
}

nonisolated enum L10n {

    /// 目前生效的 locale：使用者選的語言，`system` 時用系統的。iOS 一律系統的。
    ///
    /// 走 nonisolated 的 `loadAppLanguage`：Services 在任意 actor 呼叫，不該為了拿語言碰 MainActor。
    static var locale: Locale {
        #if os(macOS)
        SettingsStore.loadAppLanguage().locale ?? .current
        #else
        .current
        #endif
    }

    /// 取目前語言的翻譯。key 與 catalog 的 key 同格式（插值為 `%lld`／`%@`）。
    ///
    /// 必須經 `LocalizedStringResource`：`String(localized:locale:)` 的 locale 只管格式，
    /// 不會挑語言（實測 ja／zh-Hant 都回 en 的字串）。
    static func text(_ key: String.LocalizationValue, locale: Locale = L10n.locale) -> String {
        String(localized: LocalizedStringResource(key, locale: locale))
    }
}

// MARK: - SwiftUI

/// 把 `settings.locale` 套給子樹，讓 `Text("繁中 key")` 隨語言選單即時切換。
///
/// sheet／popover 在 macOS 是獨立視窗，`\.locale` 會被改回行程語言，每個內容根都要自己掛。
///
/// 必須是 View 層的 modifier、不能寫在 `App.body`：`App` 不會因 `@Observable` 變化重新求值（見 `PluginStore`），
/// 而且要放在 `.environment(\.naki, …)` **之內**才讀得到 settings。
struct AppLocale: ViewModifier {
    @Environment(\.naki) private var naki
    @Environment(\.locale) private var systemLocale

    func body(content: Content) -> some View {
        content.environment(\.locale, naki.settings.locale ?? systemLocale)
    }
}

extension View {
    func appLocale() -> some View { modifier(AppLocale()) }
}
