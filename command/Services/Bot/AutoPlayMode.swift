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
    case off = "關閉"            // 不自動打牌；目前 AI、側欄與 WebGL 高亮仍可能更新
    case recommend = "推薦"      // 顯示推薦，需要手動打牌
    case auto = "自動"           // 顯示推薦，自動執行推薦動作

    /// 產品意圖上的顯示旗標；目前 View／WebGL highlighter 尚未讀取它（見 p1-4）。
    var showRecommendation: Bool {
        return self != .off
    }

    /// 是否啟用自動打牌（只有自動模式）
    var isFullAuto: Bool {
        return self == .auto
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
enum AutoPlayModeStore {
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
