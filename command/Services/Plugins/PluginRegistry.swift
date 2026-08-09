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
    /// 選用的設定 schema（§7.10a）：key → 欄位定義。型別只有 string/number/boolean。
    let settings: [String: PluginSettingField]?
    /// 禁改名單解除（§8.2/§11 #5）：列出的 method 即使在禁改名單也放行 rewrite。
    let rewriteAllow: [String]?
}

/// 設定 schema 的單一欄位（§7.10a）。`default` 型別依 `type` 而定。
nonisolated struct PluginSettingField: Decodable, Sendable, Equatable {
    let type: String            // "string" | "number" | "boolean"
    let description: String?
    let defaultValue: PluginSettingValue

    enum CodingKeys: String, CodingKey { case type, description, defaultValue = "default" }

    /// schema 有效性：型別是三種之一，且 default 與 type 相符。
    var isValid: Bool {
        switch type {
        case "string":  if case .string = defaultValue { return true }; return false
        case "number":  if case .number = defaultValue { return true }; return false
        case "boolean": if case .boolean = defaultValue { return true }; return false
        default: return false
        }
    }
}

/// 設定值（string/number/boolean 三型）。
nonisolated enum PluginSettingValue: Decodable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // 順序重要：Bool 不會從數字解出，Double 不會從字串解出。
        if let b = try? c.decode(Bool.self) { self = .boolean(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "settings default 必須是 string/number/boolean")
        }
    }

    /// 給 JSONSerialization 用的原生值
    var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let d): return d
        case .boolean(let b): return b
        }
    }
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

        // settings schema 有效性（§7.10a）：型別必須是 string/number/boolean 且 default 相符。
        // 無效 ⇒ 整個插件不載入（與其它 manifest 錯誤同語意）。
        if let schema = manifest.settings {
            for (key, field) in schema where !field.isValid {
                return PluginDescriptor(id: manifest.id, directory: directory, manifest: nil,
                                        entrySource: nil,
                                        failure: .manifestInvalid("settings.\(key) schema 無效（type 或 default 不合）"))
            }
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
                                     enabled: Set<String>,
                                     mayModifyOutbound: Bool = false,
                                     overridesFor: (String) -> [String: Any] = { _ in [:] }) -> String? {
        let active = descriptors.filter { $0.isValid && enabled.contains($0.id) }
        guard !active.isEmpty else { return nil }

        // grants：{ id: { capabilities, methods, priority, observeNakiTraffic, settings?, rewriteAllow? } }
        var grants: [String: Any] = [:]
        for d in active {
            guard let m = d.manifest else { continue }
            grants[m.id] = grantDict(for: m, overrides: overridesFor(m.id))
        }

        guard let grantsData = try? JSONSerialization.data(withJSONObject: grants, options: [.sortedKeys]),
              let grantsJSON = String(data: grantsData, encoding: .utf8) else {
            return nil
        }

        var parts: [String] = []
        parts.append("// === Naki 插件注入（第二個 WKUserScript，共 \(active.count) 個）===")
        parts.append("window.__nakiPluginsMayModifyOutbound = \(mayModifyOutbound ? "true" : "false");")
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

    /// 單一插件的 grant dict。`overrides` 是使用者對 settings 的覆寫值（key → 值）。
    static func grantDict(for manifest: PluginManifest, overrides: [String: Any] = [:]) -> [String: Any] {
        var grant: [String: Any] = [
            "capabilities": manifest.capabilities,
            "methods": manifest.methods,
            "priority": manifest.priority ?? 100,
            "observeNakiTraffic": manifest.observeNakiTraffic ?? false
        ]
        if let allow = manifest.rewriteAllow { grant["rewriteAllow"] = allow }
        if let schema = manifest.settings {
            // settings 值 = 使用者覆寫 ?? default（§7.10a）
            var resolved: [String: Any] = [:]
            for (key, field) in schema {
                resolved[key] = overrides[key] ?? field.defaultValue.jsonValue
            }
            grant["settings"] = resolved
        }
        return grant
    }

    static func grantJSON(for manifest: PluginManifest, overrides: [String: Any] = [:]) -> String? {
        let grant = grantDict(for: manifest, overrides: overrides)
        guard let data = try? JSONSerialization.data(withJSONObject: grant, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// 熱**啟用**單一插件的 JS（`setGrant` 下發權威 grant，再跑插件源碼 → register 立即生效）。
    /// 函式體語意（fire-and-forget，不需 `return`）。插件源碼包在 try/catch，語法/執行錯不外溢。
    static func enableScript(for descriptor: PluginDescriptor,
                             overrides: [String: Any] = [:],
                             mayModifyOutbound: Bool = false) -> String? {
        guard let manifest = descriptor.manifest,
              let source = descriptor.entrySource,
              let grantJSON = grantJSON(for: manifest, overrides: overrides) else { return nil }
        let idLit = jsStringLiteral(descriptor.id)
        return """
        window.__nakiPluginsMayModifyOutbound = \(mayModifyOutbound ? "true" : "false");
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
