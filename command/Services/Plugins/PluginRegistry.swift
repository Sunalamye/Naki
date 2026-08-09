//
//  PluginRegistry.swift
//  Naki
//
//  第三方插件的發現與載入（Swift 側）。apiVersion: 1。
//  契約見 docs/plugin-system-design.md §6 與 docs/plugin-api-v1.md。
//
//  這裡**只讀檔、驗 manifest、產出注入源碼**——掃描本身不執行任何插件程式碼。
//  插件的實際執行在頁面裡（naki-plugins.js 的 register/dispatch）。
//
//  設計成 enum（全 static，無實例狀態）：
//  - 無 MainActor deinit 的 SIGABRT 坑（見 CLAUDE.md「專案結構的坑」）
//  - 純函式，好單測（給一個暫存目錄就能驗掃描與驗證規則）
//
//  無簽章、無雜湊驗證——這是刻意的（假的完整性檢查比沒有更糟）。安裝插件＝信任作者。
//

import Foundation

// MARK: - Manifest

/// `plugin.json` 的解碼形狀。必填欄位是非 optional——缺了 `JSONDecoder` 會 throw，
/// 於是自動落進 `manifestInvalid`（不必逐欄位手寫檢查）。
nonisolated struct PluginManifest: Decodable, Sendable, Equatable {
    let schemaVersion: Int
    let apiVersion: Int
    let id: String
    let name: String
    let version: String
    let entry: String
    let capabilities: [String]
    let methods: [String]

    // 選用
    let priority: Int?
    let observeNakiTraffic: Bool?
    let license: String?
    let homepage: String?
    let description: String?
}

// MARK: - 載入失敗

/// 一個插件目錄載不進來的原因。沿用 `JSModuleFailure` 的分級精神：
/// 分開是因為處置不同（打包漏檔 vs 格式錯 vs 版本不合）。
nonisolated enum PluginLoadFailure: Sendable, Equatable {
    case noManifest                    // 目錄下沒有 plugin.json
    case manifestInvalid(String)       // plugin.json 解不開或缺必填欄位
    case apiVersionUnsupported(Int)    // apiVersion != 1（exact match，見 §7.10(b)）
    case idMismatch(String)            // manifest id != 目錄名
    case entryUnreadable(String)       // entry 指的 JS 讀不到或為空

    var text: String {
        switch self {
        case .noManifest: return "找不到 plugin.json"
        case .manifestInvalid(let d): return "manifest 無效：\(d)"
        case .apiVersionUnsupported(let v): return "apiVersion \(v) 不支援（只收 1）"
        case .idMismatch(let d): return "id 與目錄名不符：\(d)"
        case .entryUnreadable(let d): return "進入點讀不到：\(d)"
        }
    }

    /// 機械可判讀的原因碼（給 UI／status）
    var code: String {
        switch self {
        case .noManifest: return "no_manifest"
        case .manifestInvalid: return "manifest_invalid"
        case .apiVersionUnsupported: return "api_version_unsupported"
        case .idMismatch: return "id_mismatch"
        case .entryUnreadable: return "entry_unreadable"
        }
    }
}

// MARK: - Descriptor

/// 掃描一個插件目錄的結果。有效插件帶 manifest 與 entry 源碼；無效插件帶 failure。
nonisolated struct PluginDescriptor: Sendable {
    /// 有效插件用 manifest.id；無效插件退回目錄名（UI 至少有個可顯示的識別）
    let id: String
    let directory: URL
    let manifest: PluginManifest?
    /// entry JS 的原始碼（只有有效插件才有）
    let entrySource: String?
    let failure: PluginLoadFailure?

    var isValid: Bool { manifest != nil && failure == nil }
}

// MARK: - Registry

nonisolated enum PluginRegistry {

    /// 插件根目錄。
    /// macOS：`~/Library/Application Support/Naki/Plugins/`（App Sandbox = NO，不觸 TCC）。
    /// iOS：App 容器內 `Application Support/Plugins/`（同一段程式碼）。
    static var pluginsDirectory: URL? {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("Naki", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    /// 掃描目錄下的每個子目錄，各產出一個 `PluginDescriptor`。
    /// 目錄不存在或讀不到 ⇒ 回空陣列（沒有插件是正常狀態，不是錯誤）。
    static func scan(in directory: URL? = pluginsDirectory) -> [PluginDescriptor] {
        guard let directory else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }

        var out: [PluginDescriptor] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            out.append(load(directory: entry))
        }
        return out.sorted { $0.id < $1.id }
    }

    /// 讀單一插件目錄並驗證（不執行任何插件程式碼）。
    static func load(directory: URL) -> PluginDescriptor {
        let dirName = directory.lastPathComponent
        let manifestURL = directory.appendingPathComponent("plugin.json")

        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            return PluginDescriptor(id: dirName, directory: directory,
                                    manifest: nil, entrySource: nil, failure: .noManifest)
        }

        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        } catch {
            return PluginDescriptor(id: dirName, directory: directory, manifest: nil,
                                    entrySource: nil,
                                    failure: .manifestInvalid("\(error.localizedDescription)"))
        }

        // apiVersion exact match（§7.10(b)）
        guard manifest.apiVersion == 1 else {
            return PluginDescriptor(id: manifest.id, directory: directory, manifest: nil,
                                    entrySource: nil,
                                    failure: .apiVersionUnsupported(manifest.apiVersion))
        }

        // id 必須與目錄名相同（避免同一份插件用不同 id 重複註冊）
        guard manifest.id == dirName else {
            return PluginDescriptor(id: dirName, directory: directory, manifest: nil,
                                    entrySource: nil,
                                    failure: .idMismatch("manifest '\(manifest.id)' ≠ 目錄 '\(dirName)'"))
        }

        // entry 源碼
        let entryURL = directory.appendingPathComponent(manifest.entry)
        guard let source = try? String(contentsOf: entryURL, encoding: .utf8),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PluginDescriptor(id: manifest.id, directory: directory, manifest: nil,
                                    entrySource: nil,
                                    failure: .entryUnreadable(manifest.entry))
        }

        return PluginDescriptor(id: manifest.id, directory: directory,
                                manifest: manifest, entrySource: source, failure: nil)
    }

    /// 產出「第二個 WKUserScript」的內容：先設 grants，再串接各啟用插件的原始碼。
    ///
    /// grants 是**權威**——插件在 JS 裡自稱什麼 capability 一律以這裡下發的為準。
    /// 沒有任何啟用且有效的插件 ⇒ 回 nil（呼叫端就不加第二個 script）。
    ///
    /// Phase 1 限制：所有插件串進同一個 script。一個插件的**語法**錯誤會讓整個第二
    /// script parse 失敗（但 bundled 的第一個 script 不受影響——這是驗收要求的隔離層級）。
    /// 插件間的語法隔離（每插件一個 WKUserScript）留待 Phase 2。
    static func buildInjectionScript(descriptors: [PluginDescriptor],
                                     enabled: Set<String>) -> String? {
        let active = descriptors.filter { $0.isValid && enabled.contains($0.id) }
        guard !active.isEmpty else { return nil }

        // grants：{ id: { capabilities, methods, priority, observeNakiTraffic } }
        var grants: [String: Any] = [:]
        for d in active {
            guard let m = d.manifest else { continue }
            grants[m.id] = [
                "capabilities": m.capabilities,
                "methods": m.methods,
                "priority": m.priority ?? 100,
                "observeNakiTraffic": m.observeNakiTraffic ?? false
            ]
        }

        guard let grantsData = try? JSONSerialization.data(withJSONObject: grants, options: [.sortedKeys]),
              let grantsJSON = String(data: grantsData, encoding: .utf8) else {
            return nil
        }

        var parts: [String] = []
        parts.append("// === Naki 插件注入（第二個 WKUserScript，共 \(active.count) 個）===")
        parts.append("window.__nakiPluginGrants = \(grantsJSON);")
        for d in active {
            guard let source = d.entrySource else { continue }
            // 每個插件的**執行**包在 try/catch（runtime 錯誤隔離；語法錯見上方 Phase 1 限制）
            parts.append("// --- plugin: \(d.id) ---")
            parts.append("try {\n\(source)\n} catch (e) { console.error('[Naki Plugin] \(d.id) 載入錯誤', e); }")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - 熱插拔（runtime enable/disable，免 reload）

    /// 單一插件的 grant JSON（capabilities / methods / priority / observeNakiTraffic）。
    static func grantJSON(for manifest: PluginManifest) -> String? {
        let grant: [String: Any] = [
            "capabilities": manifest.capabilities,
            "methods": manifest.methods,
            "priority": manifest.priority ?? 100,
            "observeNakiTraffic": manifest.observeNakiTraffic ?? false
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: grant, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// 熱**啟用**單一插件的 JS（`setGrant` 下發權威 grant，再跑插件源碼 → register 立即生效）。
    /// 函式體語意（fire-and-forget，不需 `return`）。插件源碼包在 try/catch，語法/執行錯不外溢。
    static func enableScript(for descriptor: PluginDescriptor) -> String? {
        guard let manifest = descriptor.manifest,
              let source = descriptor.entrySource,
              let grantJSON = grantJSON(for: manifest) else { return nil }
        let idLit = jsStringLiteral(descriptor.id)
        return """
        if (window.__nakiPlugins && window.__nakiPlugins.setGrant) {
          window.__nakiPlugins.setGrant(\(idLit), \(grantJSON));
          try {
        \(source)
          } catch (e) { console.error('[Naki Plugin] enable 失敗', e); }
        }
        """
    }

    /// 熱**停用**單一插件的 JS。
    static func disableScript(id: String) -> String {
        let idLit = jsStringLiteral(id)
        return "if (window.__nakiPlugins && window.__nakiPlugins.disable) { window.__nakiPlugins.disable(\(idLit)); }"
    }

    /// 安全的 JS 字串字面值（用 JSONSerialization 逸出，避免 id 內有特殊字元破壞注入）。
    private static func jsStringLiteral(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s]),
           let arr = String(data: data, encoding: .utf8) {
            return String(arr.dropFirst().dropLast())   // ["x"] → "x"
        }
        return "\"\(s)\""
    }
}
