//
//  AutoPlayMode.swift
//  Naki
//
//  自動打牌模式，以及它唯一的持久化入口。
//
//  真正的自動打牌流程在 `AutoPlayGate`（觸發閘門）、`AutoPlayDecisionResolver`（送出決策）
//  與 `LiqiActionSender`（送出）；mode 只是這條流程的一個開關值。
//
//  送出延遲不在這裡：由 `ActionDelayModel` 依動作類型隨機決定，模式本身不帶延遲設定。
//

import Foundation

// MARK: - Auto Play Mode

/// 自動打牌模式
enum AutoPlayMode: String, CaseIterable {
    case off = "關閉"            // 不自動打牌，也不顯示推薦（側欄與遊戲內高亮都清空）
    case recommend = "推薦"      // 顯示推薦，需要手動打牌
    case auto = "自動"           // 顯示推薦，自動執行推薦動作
    case fullAuto = "全自動"     // 自動打牌 ＋ 對局結束後自動排下一場

    /// 是否顯示推薦（側欄 `RecommendationView` 與遊戲內 `__nakiHighlight` 共用同一個閘門）
    ///
    /// 兩個顯示面都必須讀它（`RecommendationView`、`GameHighlightScript.make()`）：
    /// 漏掉任一邊，`.off` 就只擋得住自動送出，該面照列推薦／照染高亮，
    /// 於是「關閉」在畫面上跟「推薦」看起來一樣。
    ///
    /// 注意語意邊界：`.off` 關的是**顯示與送出**，不是推論——
    /// Bot 仍在背景跟著牌局更新狀態，否則切回 `.recommend` 會是一片空白。
    var showRecommendation: Bool {
        return self != .off
    }

    /// 是否啟用自動送出（`.auto` 與 `.fullAuto` 都送）
    ///
    /// ⚠️ 名字沿用歷史，語意是「**這一手**由 Naki 自己送」，不是「整場全自動」。
    /// 新增模式時務必讓這裡涵蓋到：Legacy 路徑的能力收斂（`AutoPlayAvailability`）
    /// 就是用它過濾的，漏掉會讓不支援自動送出的裝置選得到、然後靜靜地送出去。
    var isFullAuto: Bool {
        return self == .auto || self == .fullAuto
    }

    /// 對局結束後是否自動排下一場（只有 `.fullAuto`）
    ///
    /// 與 `isFullAuto` 分開的理由：自動打「這一手」和自動開「下一場」是兩種不同的授權。
    /// 前者只影響進行中的對局，後者會**主動把帳號排進伺服器隊列**——使用者可能只想要前者。
    var autoRematch: Bool {
        return self == .fullAuto
    }

    /// Picker 上的短標籤（macOS toolbar 與 iOS toolbar 共用同一份，避免兩邊各寫一串字面值）
    var pickerLabel: String {
        switch self {
        case .off: return "關"
        case .recommend: return "推薦"
        case .auto: return "自動"
        case .fullAuto: return "全自動"
        }
    }
}

// MARK: - 路徑可用性

/// 哪些模式在「這條 WebView 路徑」上真的能執行。
///
/// Legacy 路徑（iOS 17–25 的 WKWebView）的自動送出一律關閉，因為**整條路無法在本機
/// 驗證**——macOS deployment target 是 26，跑不到 Legacy；沒有 iOS 17–25 實機就沒有
/// 任何對局證據。在那個證據出現以前，推薦顯示保留，動作由使用者自己下。
///
/// 起點的值是 `LegacyWebBackend.supportsAutoPlay == false`；收斂規則只定義在這裡，
/// picker 選項（`ContentView`）與模式收斂（`NakiRuntime.setAutoPlayMode`）都讀它，
/// 不各寫一份判斷。
enum AutoPlayAvailability {

    /// Legacy 路徑不提供自動送出的原因，直接顯示在設定頁上。
    ///
    /// 寫成使用者看得懂的一句話而不是「未實作」：這是刻意的取捨結果，不是缺漏。
    static let autoUnavailableReason =
        "此裝置走 iOS 17–25 的舊版 WebView 路徑，該路徑的自動送出缺少輪詢閘門與重試保護，"
        + "也沒有任何實機對局驗證，因此只提供推薦顯示；動作請自己下。"

    /// 這條路徑可以選的模式（順序即 picker 上的順序）
    static func modes(autoPlaySupported: Bool) -> [AutoPlayMode] {
        autoPlaySupported
            ? AutoPlayMode.allCases
            : AutoPlayMode.allCases.filter { !$0.isFullAuto }
    }

    /// 把「使用者選的／存檔讀到的」模式收斂成這條路徑真的能執行的模式。
    ///
    /// 不支援自動送出時 `.auto` 一律降級成 `.recommend`——降級而不是 `.off`，
    /// 因為使用者要的是「幫我看牌」，把顯示一起關掉會是另一個他沒選的行為。
    static func clamp(_ mode: AutoPlayMode, autoPlaySupported: Bool) -> AutoPlayMode {
        (!autoPlaySupported && mode.isFullAuto) ? .recommend : mode
    }

    /// 「決定採用某個模式」時該發生的全部事情：收斂 → 寫進存檔 → 回傳生效值。
    ///
    /// `NakiRuntime.setAutoPlayMode` 與啟動時的沿用都走這一個函式，
    /// 所以「選了什麼、記住什麼、實際跑什麼」不可能各說各話。繞過它只改記憶體，
    /// 使用者的選擇重啟就會被沖掉。
    ///
    /// - Returns: 實際生效（可能已降級）的模式。
    @discardableResult
    static func commit(_ mode: AutoPlayMode,
                       autoPlaySupported: Bool,
                       defaults: UserDefaults = .standard) -> AutoPlayMode {
        let effective = clamp(mode, autoPlaySupported: autoPlaySupported)
        AutoPlayModeStore.save(effective, to: defaults)
        return effective
    }
}

// MARK: - Persistence

/// `AutoPlayMode` 的單一持久化來源。
///
/// 全 App 只有 `naki.autoPlayMode` 一個 key。這個設定曾經散在兩個 key，
/// 兩邊各存各的，UI picker 顯示的模式與實際採用的模式因此可以不一致；
/// `legacyKey` 只剩一次性遷移的用途，遷移後刪除，不要再新增第二個讀寫點。
nonisolated enum AutoPlayModeStore {
    /// 目前唯一的 key（`NakiRuntime` 與 `ContentView` 的 `@AppStorage` 共用）
    static let key = "naki.autoPlayMode"

    /// 被合併掉的舊 key（ContentView 舊版 `@AppStorage("AutoPlayMode")`）
    static let legacyKey = "AutoPlayMode"

    /// 沒有任何存檔時的預設模式
    static let defaultMode: AutoPlayMode = .auto

    /// 一次性遷移：舊 key 有值而新 key 沒有時，把值搬過去；不論搬不搬都刪掉舊 key。
    ///
    /// 冪等，重複呼叫安全——App 進入點與 `load()` 都會呼叫。
    /// - Returns: 是否真的把舊值搬進新 key。
    @discardableResult
    static func migrateLegacyKeyIfNeeded(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: legacyKey) != nil else { return false }
        // 舊 key 一律清掉：留著只會讓下次啟動再判一次「還沒遷移」。
        defer { defaults.removeObject(forKey: legacyKey) }

        // 新 key 已經有值就以新 key 為準（它才是實際驅動送出的那一個）。
        guard defaults.string(forKey: key) == nil,
              let raw = defaults.string(forKey: legacyKey),
              AutoPlayMode(rawValue: raw) != nil
        else { return false }

        defaults.set(raw, forKey: key)
        return true
    }

    /// 讀取持久化的模式（含一次性遷移）
    static func load(_ defaults: UserDefaults = .standard) -> AutoPlayMode {
        migrateLegacyKeyIfNeeded(defaults)
        return defaults.string(forKey: key).flatMap(AutoPlayMode.init(rawValue:)) ?? defaultMode
    }

    /// 寫入模式
    static func save(_ mode: AutoPlayMode, to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}
