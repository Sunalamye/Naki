//
//  AutoPlayMode.swift
//  Naki
//
//  自動打牌模式，以及它唯一的持久化入口。
//
//  取代原本那個名為「自動打牌控制器」、實際上只是 mode 容器的 class（2026-08-02 刪除）。
//  它 166 行裡只有 `state.mode` 有人讀：
//  - 8 個動作 case 沒有任何建構點；
//  - `notifyMyTurn` / `notifyTurnEnd` / `setWebPage` 零呼叫，注入的 `webPage` 從未被使用；
//  - `state.actionDelay` 只被 UI Stepper 寫、沒有任何人讀（真正的送出延遲由
//    `ActionDelayModel` 依動作類型隨機決定，那是刻意設計）；
//  - `ObservableObject` / `@Published` 沒有任何 View 訂閱（它是 ViewModel 的 private var）。
//
//  真正的自動打牌流程在 `AutoPlayGate`（觸發閘門）、`AutoPlayDecisionResolver`（送出決策）
//  與 `LiqiActionSender`（送出）；mode 只是這條流程的一個開關值。
//

import Foundation

// MARK: - Auto Play Mode

/// 自動打牌模式
enum AutoPlayMode: String, CaseIterable {
    case off = "關閉"            // 不自動打牌，也不顯示推薦（側欄與遊戲內高亮都清空）
    case recommend = "推薦"      // 顯示推薦，需要手動打牌
    case auto = "自動"           // 顯示推薦，自動執行推薦動作

    /// 是否顯示推薦（側欄 `RecommendationView` 與遊戲內 `__nakiHighlight` 共用同一個閘門）
    ///
    /// 這個旗標曾經**沒有任何讀取者**：`.off` 只擋得住自動送出，側欄照列推薦、
    /// WebGL 高亮照染，於是「關閉」在畫面上跟「推薦」看起來一樣。
    /// 現在兩個顯示面都讀它（`RecommendationView`、`WebViewModel.syncGameHighlight`）。
    ///
    /// 注意語意邊界：`.off` 關的是**顯示與送出**，不是推論——
    /// Bot 仍在背景跟著牌局更新狀態，否則切回 `.recommend` 會是一片空白。
    var showRecommendation: Bool {
        return self != .off
    }

    /// 是否啟用自動打牌（只有自動模式）
    var isFullAuto: Bool {
        return self == .auto
    }

    /// Picker 上的短標籤（macOS toolbar 與 iOS toolbar 共用同一份，避免兩邊各寫一串字面值）
    var pickerLabel: String {
        switch self {
        case .off: return "關"
        case .recommend: return "推薦"
        case .auto: return "自動"
        }
    }
}

// MARK: - 路徑可用性

/// 哪些模式在「這條 WebView 路徑」上真的能執行。
///
/// 背景（p2-2）：自動送出的完整保護鏈（1 秒輪詢的 `AutoPlayGate`、forceHora／sendPass
/// 寬限、executionId 去抖、hora 送出重試）只長在 `WebViewModel`（WebPage，macOS/iOS 26+）
/// 那條路上。`LegacyWebViewModel`（iOS 17–25 的 WKWebView）雖然已經共用 resolver 與
/// executor，但沒有那層閘門與重試，而且**整條路無法在本機驗證**——macOS deployment target
/// 是 26，跑不到 Legacy；沒有 iOS 17–25 實機就沒有任何對局證據。
///
/// 在那個證據出現以前，Legacy 的自動送出一律關閉（AUDIT 的建議之一）：
/// 推薦顯示保留，動作由使用者自己下。這裡是那個決策的唯一定義點，
/// UI（picker 選項）與 ViewModel（模式收斂）都讀它，不各寫一份判斷。
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
    /// 兩條 path 的 `setAutoPlayMode` 與啟動時的沿用都走這一個函式，
    /// 所以「選了什麼、記住什麼、實際跑什麼」不可能各說各話——這正是先前
    /// Legacy 只改記憶體不寫存檔（重啟就沖掉）造成的問題。
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
/// 以前同一個設定散在兩個 key：ViewModel 讀寫 `naki.autoPlayMode`，
/// ContentView 的 `@AppStorage("AutoPlayMode")` 讀寫 `AutoPlayMode`。
/// 兩邊各存各的，UI picker 顯示的模式與 ViewModel 實際採用的模式可以不一致
/// （例如 Legacy 路徑改了模式根本沒寫進任何 key，重啟就被沖掉）。
/// 這裡收斂成 `naki.autoPlayMode` 一個 key，舊 key 做一次性遷移後刪除。
nonisolated enum AutoPlayModeStore {
    /// 目前唯一的 key（ViewModel 與 ContentView 的 `@AppStorage` 共用）
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
