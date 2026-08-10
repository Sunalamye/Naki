//
//  PluginImportSource.swift
//  Naki
//
//  從使用者指定的 URL 一次性匯入插件（§6.5）。gist 或任意 HTTPS。
//
//  定性：**使用者指定來源的一次性匯入器，不是執行期載入器**。
//  - 來源由使用者貼入（Naki 不內建任何 URL／清單／推薦）。
//  - 只在匯入當下抓一次（fetch-once）：抓下來的 bytes 進記憶體，預覽／確認／落地
//    全用同一份，中間不重抓——「你確認的就是之後執行的」。
//  - 落地後與手放檔案走完全相同的路徑（PluginRegistry 掃描、驗證、熱插拔）。
//
//  網路只發生在這裡（匯入當下）。頁面載入與執行期零網路請求。
//

import Foundation
import CryptoKit

// MARK: - 錯誤

nonisolated enum PluginImportError: Error, Sendable {
    case badURL
    case notHTTPS
    case network(String)
    case gistNoFiles
    case noPluginJson
    case crossOrigin(String)
    case tooLarge(String)
    case invalidManifest(String)

    var text: String {
        switch self {
        case .badURL: return "URL 格式不對"
        case .notHTTPS: return "只接受 HTTPS"
        case .network(let d): return "抓取失敗：\(d)"
        case .gistNoFiles: return "gist 沒有檔案"
        case .noPluginJson: return "找不到 plugin.json"
        case .crossOrigin(let d): return "引用檔案跨來源（不允許）：\(d)"
        case .tooLarge(let d): return "超過尺寸上限：\(d)"
        case .invalidManifest(let d): return "manifest 無效：\(d)"
        }
    }
}

// MARK: - 匯入結果

nonisolated struct ImportedPlugin: Sendable {
    let id: String                      // manifest id（＝落地目錄名）
    let manifest: PluginManifest
    let files: [String: Data]           // 檔名 → bytes（fetch-once 的同一份）
    let sourceURL: String               // redirect 後最終 URL
    let revision: String?               // gist version（若適用）

    /// 給確認畫面顯示的 entry 源碼
    var entrySource: String {
        guard let data = files[manifest.entry] else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - 匯入器

nonisolated enum PluginImportSource {

    static let manifestMax = 64 * 1024
    static let bundleMax = 5 * 1024 * 1024

    /// 抓取並正規化（fetch-once）。不落地——落地是 `install`。
    static func fetch(urlString: String) async -> Result<ImportedPlugin, PluginImportError> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host else {
            return .failure(.badURL)
        }
        if host.contains("gist.github.com") {
            return await fetchGist(url)
        }
        return await fetchHTTP(url)
    }

    // MARK: gist

    private static func fetchGist(_ url: URL) async -> Result<ImportedPlugin, PluginImportError> {
        // gist.github.com/<user>/<id> 或 gist.github.com/<id> → 取最後一段當 id
        let id = url.pathComponents.filter { $0 != "/" }.last ?? ""
        guard !id.isEmpty else { return .failure(.badURL) }
        let apiURL = URL(string: "https://api.github.com/gists/\(id)")!

        let data: Data
        do { data = try await get(apiURL, max: bundleMax) }
        catch let e as PluginImportError { return .failure(e) }
        catch { return .failure(.network("\(error.localizedDescription)")) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filesObj = json["files"] as? [String: Any], !filesObj.isEmpty else {
            return .failure(.gistNoFiles)
        }

        var files: [String: Data] = [:]
        for (name, v) in filesObj {
            guard let f = v as? [String: Any] else { continue }
            // 小檔 gist API 直接帶 content；truncated 才另抓 raw_url
            if let truncated = f["truncated"] as? Bool, truncated,
               let raw = f["raw_url"] as? String, let rawURL = URL(string: raw) {
                if let d = try? await get(rawURL, max: bundleMax) { files[name] = d }
            } else if let content = f["content"] as? String {
                files[name] = Data(content.utf8)
            }
        }

        let revision = (json["history"] as? [[String: Any]])?.first?["version"] as? String
        return finalize(files: files, sourceURL: (json["html_url"] as? String) ?? url.absoluteString,
                        revision: revision)
    }

    // MARK: 任意 HTTPS

    private static func fetchHTTP(_ url: URL) async -> Result<ImportedPlugin, PluginImportError> {
        guard url.scheme?.lowercased() == "https" else { return .failure(.notHTTPS) }
        // URL 必須直接指向 plugin.json
        guard url.lastPathComponent == "plugin.json" else { return .failure(.noPluginJson) }

        let manifestData: Data
        do { manifestData = try await get(url, max: manifestMax) }
        catch let e as PluginImportError { return .failure(e) }
        catch { return .failure(.network("\(error.localizedDescription)")) }

        guard let manifest = try? JSONDecoder().decode(PluginManifest.self, from: manifestData) else {
            return .failure(.invalidManifest("plugin.json 解不開"))
        }
        var files: [String: Data] = ["plugin.json": manifestData]

        // 依 entry 抓同源檔案（相對 plugin.json）
        let base = url.deletingLastPathComponent()
        let entryURL = base.appendingPathComponent(manifest.entry)
        guard entryURL.host == url.host, entryURL.scheme == url.scheme else {
            return .failure(.crossOrigin(manifest.entry))
        }
        do { files[manifest.entry] = try await get(entryURL, max: bundleMax) }
        catch let e as PluginImportError { return .failure(e) }
        catch { return .failure(.network("entry: \(error.localizedDescription)")) }

        return finalize(files: files, sourceURL: url.absoluteString, revision: nil)
    }

    // MARK: GitHub repo（多插件）

    /// 統一入口：回**一批** ImportedPlugin。
    /// - `github.com/<owner>/<repo>` 或 `<owner>/<repo>` → repo 內所有 `plugins/*/plugin.json`（多個）
    /// - `gist.github.com/…` → 單一
    /// - 任意 `https://…/plugin.json` → 單一
    static func fetchAny(urlString: String) async -> Result<[ImportedPlugin], PluginImportError> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // 允許裸 owner/repo（無 scheme）
        let normalized = normalizeInput(trimmed)
        guard let url = URL(string: normalized), let host = url.host else {
            return .failure(.badURL)
        }
        if host.contains("gist.github.com") {
            return (await fetchGist(url)).map { [$0] }
        }
        if host.contains("github.com") {
            return await fetchGitHubRepo(url)
        }
        return (await fetchHTTP(url)).map { [$0] }
    }

    /// 裸 `owner/repo` → `https://github.com/owner/repo`；已是 URL 則原樣。
    private static func normalizeInput(_ s: String) -> String {
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        let parts = s.split(separator: "/")
        if parts.count == 2 { return "https://github.com/\(parts[0])/\(parts[1])" }
        return s
    }

    /// 從 GitHub repo 抓所有 `plugins/<id>/plugin.json` 插件（多個），釘 commit sha。
    static func fetchGitHubRepo(_ url: URL) async -> Result<[ImportedPlugin], PluginImportError> {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return .failure(.badURL) }
        let owner = parts[0], repo = parts[1]

        // 1) default branch
        guard let repoData = try? await get(URL(string: "https://api.github.com/repos/\(owner)/\(repo)")!, max: manifestMax),
              let repoJSON = try? JSONSerialization.jsonObject(with: repoData) as? [String: Any],
              let branch = repoJSON["default_branch"] as? String else {
            return .failure(.network("讀不到 repo \(owner)/\(repo)"))
        }
        // 2) recursive tree（一次拿全部路徑）；top sha ＝ revision
        guard let treeData = try? await get(URL(string: "https://api.github.com/repos/\(owner)/\(repo)/git/trees/\(branch)?recursive=1")!, max: bundleMax),
              let treeJSON = try? JSONSerialization.jsonObject(with: treeData) as? [String: Any],
              let tree = treeJSON["tree"] as? [[String: Any]] else {
            return .failure(.network("讀不到 repo tree"))
        }
        let revision = treeJSON["sha"] as? String
        let pin = revision ?? branch

        // 3) 找 plugins/<id>/plugin.json
        var dirs: [String] = []
        for entry in tree {
            guard let path = entry["path"] as? String, (entry["type"] as? String) == "blob" else { continue }
            let comps = path.split(separator: "/").map(String.init)
            if comps.count == 3, comps[0] == "plugins", comps[2] == "plugin.json" {
                dirs.append(comps[1])
            }
        }
        guard !dirs.isEmpty else { return .failure(.noPluginJson) }

        // 4) 每個插件：抓 plugin.json + entry（raw，釘 pin）
        var out: [ImportedPlugin] = []
        for dir in dirs {
            let base = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(pin)/plugins/\(dir)"
            guard let mURL = URL(string: "\(base)/plugin.json"),
                  let mData = try? await get(mURL, max: manifestMax),
                  let manifest = try? JSONDecoder().decode(PluginManifest.self, from: mData) else { continue }
            var files: [String: Data] = ["plugin.json": mData]
            if let eURL = URL(string: "\(base)/\(manifest.entry)"),
               let eData = try? await get(eURL, max: bundleMax) {
                files[manifest.entry] = eData
            }
            if case .success(let p) = finalize(files: files, sourceURL: "\(base)/plugin.json", revision: revision) {
                out.append(p)
            }
        }
        guard !out.isEmpty else { return .failure(.invalidManifest("repo 裡沒有有效插件")) }
        return .success(out)
    }

    // MARK: 共用

    /// 驗 manifest（apiVersion/id/欄位），組 ImportedPlugin。
    private static func finalize(files: [String: Data], sourceURL: String,
                                 revision: String?) -> Result<ImportedPlugin, PluginImportError> {
        guard let mData = files["plugin.json"] else { return .failure(.noPluginJson) }
        guard let manifest = try? JSONDecoder().decode(PluginManifest.self, from: mData) else {
            return .failure(.invalidManifest("plugin.json 缺欄位或格式錯"))
        }
        guard manifest.apiVersion == 1 else {
            return .failure(.invalidManifest("apiVersion \(manifest.apiVersion) 不支援（只收 1）"))
        }
        guard files[manifest.entry] != nil else {
            return .failure(.invalidManifest("找不到 entry：\(manifest.entry)"))
        }
        // settings schema 有效性（與 PluginRegistry.load 同規則）
        if let schema = manifest.settings {
            for (key, field) in schema where !field.isValid {
                return .failure(.invalidManifest("settings.\(key) schema 無效"))
            }
        }
        let total = files.values.reduce(0) { $0 + $1.count }
        guard total <= bundleMax else { return .failure(.tooLarge("整包 \(total) bytes")) }

        return .success(ImportedPlugin(id: manifest.id, manifest: manifest, files: files,
                                       sourceURL: sourceURL, revision: revision))
    }

    /// 抓一個 URL，帶尺寸上限。allow redirect；回最終資料。
    private static func get(_ url: URL, max: Int) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw PluginImportError.network("HTTP \(http.statusCode)")
        }
        guard data.count <= max else { throw PluginImportError.tooLarge("\(data.count) bytes") }
        return data
    }

    // MARK: 落地

    /// 把 fetch-once 的 bytes 寫進 Plugins/<id>/，並寫 install-receipt.json。
    /// 覆蓋同 id 的既有目錄（＝更新）。回落地目錄。
    static func install(_ imported: ImportedPlugin, now: Date) -> Result<URL, PluginImportError> {
        guard let root = PluginRegistry.pluginsDirectory else {
            return .failure(.network("找不到插件目錄"))
        }
        let dir = root.appendingPathComponent(imported.id, isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var receipts: [String: String] = [:]
            for (name, data) in imported.files {
                try data.write(to: dir.appendingPathComponent(name))
                receipts[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            // install-receipt.json：出處紀錄（不是完整性驗證）。PluginRegistry 掃描時忽略它。
            let iso = ISO8601DateFormatter().string(from: now)
            var receipt: [String: Any] = [
                "sourceURL": imported.sourceURL,
                "importedAt": iso,
                "sha256": receipts
            ]
            if let rev = imported.revision { receipt["revision"] = rev }
            if let rData = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
                try? rData.write(to: dir.appendingPathComponent("install-receipt.json"))
            }
            return .success(dir)
        } catch {
            return .failure(.network("寫入失敗：\(error.localizedDescription)"))
        }
    }
}
