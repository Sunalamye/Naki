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

    /// 依對局人數選模型 id（空字串 ⇒ 呼叫端不送 `model` 欄位）。
    func model(is3P: Bool) -> String {
        (is3P ? model3P : model4P).trimmingCharacters(in: .whitespaces)
    }

    /// key 的後四碼（log 與 UI 顯示用；完整 key 不得出現在任何 log）。
    var keyLast4: String {
        String(apiKey.trimmingCharacters(in: .whitespaces).suffix(4))
    }
}
