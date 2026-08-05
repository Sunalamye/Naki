//
//  CloudKeyStore.swift
//  Naki
//
//  雲端推論 API key 的 Keychain 存取。
//
//  key 不進 UserDefaults：專案邊界明文禁止 credential 落入可被 bug report
//  附上的檔案，而 UserDefaults 的 plist 就是那種檔案。Akagi 把 key 寫在
//  `settings.toml` 並自認是暫時措施（roadmap 上是 OS keychain）；Naki 直接做對。
//
//  範圍刻意只有「一把 key」：generic password，固定 service/account。
//  讀寫失敗（例如 Keychain 鎖定）以空字串／忽略處理——雲端推論會因
//  `isActive == false` 安靜退回本地模型，不會讓 App 掛掉。
//

import Foundation
import Security

/// 雲端推論 API key 的唯一持久化入口。
///
/// 成員全標 `nonisolated`：`SettingsStore.cloudAPIKey` 的 stored property 預設值
/// 在 `nonisolated init()` 的脈絡求值（見該檔 `@Entry` 註解），而 app target 開了
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。Security API 本身執行緒安全。
enum CloudKeyStore {

    nonisolated static let service = "org.naki.cloud-inference"
    nonisolated static let account = "api-key"

    private nonisolated static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// 讀出 key；沒有存過或讀取失敗回空字串。
    nonisolated static func load() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return ""
        }
        return key
    }

    /// 寫入 key；空字串＝刪除。
    nonisolated static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }
        let data = Data(trimmed.utf8)

        var update = baseQuery
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(update as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            update[kSecValueData as String] = data
            SecItemAdd(update as CFDictionary, nil)
        }
    }
}
