//
//  CloudInferenceConfig.swift
//  Naki
//
//  雲端推論設定的值快照。
//
//  `NativeBotController` 在**每個決策點**經 `cloudConfigProvider` 重讀一份
//  （Akagi 實戰做法：修 key、換模型局中即生效，任何變更會 reset 斷路器）。
//  Equatable 是為了「有沒有變」這一個判斷——變了才重建 client / 清 tombstone。
//

import Foundation

/// 雲端推論的生效值。來源是 `SettingsStore.cloudConfig`（key 在 Keychain）。
struct CloudInferenceConfig: Equatable {
    /// 總開關（UI Toggle）
    var enabled: Bool
    /// 推論伺服器 base URL（`https://host` 或 `http://127.0.0.1:8080`）
    var baseURL: String
    /// Bearer API key（不落 UserDefaults，見 `CloudKeyStore`）
    var apiKey: String
    /// 四麻模型 id；空字串 ⇒ 不送 `model` 欄位、伺服器用預設
    var model4P: String
    /// 三麻模型 id；空字串 ⇒ 伺服器用預設
    var model3P: String

    /// 與 Akagi `NativeApiConfig.is_active()` 同語意：
    /// 開關開著、URL 與 key 都非空才算「已設定完成」。
    var isActive: Bool {
        enabled
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 還缺哪些條件才會生效；空陣列代表 `isActive == true`。
    ///
    /// 生效條件是三個分開的控制（開關、URL、key），而開關在設定畫面上排在 key 欄位
    /// **上方**——「貼完 key 就走」是最常見的狀態，結果是一份看起來已配置、行為卻
    /// 完全是本地模型的設定。設定畫面拿這個陣列直接把缺口寫出來，
    /// 判定與 `isActive` 共用同一份定義，不會漂。
    var missingRequirements: [String] {
        var missing: [String] = []
        if !enabled { missing.append("上方的「啟用雲端推論」開關") }
        if baseURL.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("伺服器 URL") }
        if apiKey.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("API Key") }
        return missing
    }

    /// 依對局人數選模型 id（空字串 ⇒ 呼叫端不送 `model` 欄位）。
    func model(is3P: Bool) -> String {
        (is3P ? model3P : model4P).trimmingCharacters(in: .whitespaces)
    }

    /// key 的後四碼（log 與 UI 顯示用；完整 key 不得出現在任何 log）。
    var keyLast4: String {
        String(apiKey.trimmingCharacters(in: .whitespaces).suffix(4))
    }
}
