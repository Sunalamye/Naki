//
//  PluginSettingsUITests.swift
//  NakiTests
//
//  插件自帶設定頁（manifest `settingsUI`，docs/plan/plugin-v2.md §A）：manifest 驗證、
//  檔案必須在插件目錄內、bridge 只收 schema 宣告的 key 與型別，寫入後 SettingsStore 讀得回。
//

import XCTest

@testable import Naki

final class PluginSettingsUITests: XCTestCase {

    private var tmp: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/plugins/com.naki.example.settings-page")
    private let id = "com.naki.example.settings-page"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("naki-settingsui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        suiteName = "naki.tests.pluginsettingsui.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func installFixture() throws -> URL {
        let dir = tmp.appendingPathComponent(id)
        try FileManager.default.copyItem(at: fixture, to: dir)
        return dir
    }

    private func manifest(settingsUI: String?, settings: String? = #"{"s":{"type":"string","default":"d"}}"#) throws -> PluginManifest {
        let ui = settingsUI.map { ",\"settingsUI\":\"\($0)\"" } ?? ""
        let s = settings.map { ",\"settings\":\($0)" } ?? ""
        return try JSONDecoder().decode(PluginManifest.self, from: Data("""
        {"schemaVersion":1,"apiVersion":1,"id":"p","name":"n","version":"1","entry":"plugin.js",
        "capabilities":["observe"],"methods":[]\(ui)\(s)}
        """.utf8))
    }

    private func isManifestInvalid(_ failure: PluginLoadFailure?) -> Bool {
        if case .manifestInvalid = failure { return true }
        return false
    }

    // MARK: - manifest

    func testSettingsUIAcceptsSingleHtmlFileName() throws {
        XCTAssertNil(try manifest(settingsUI: "settings.html").validate())
        XCTAssertNil(try manifest(settingsUI: nil).validate())
    }

    func testSettingsUIRejectsUnsafeOrNonHtmlNames() throws {
        for bad in ["../settings.html", "sub/settings.html", ".settings.html", "settings.js", "settings.html?x=1"] {
            XCTAssertTrue(isManifestInvalid(try manifest(settingsUI: bad).validate()), "settingsUI=\(bad)")
        }
    }

    func testSettingsUIRequiresSettingsSchema() throws {
        XCTAssertTrue(isManifestInvalid(try manifest(settingsUI: "settings.html", settings: nil).validate()))
        XCTAssertTrue(isManifestInvalid(try manifest(settingsUI: "settings.html", settings: "{}").validate()))
    }

    // MARK: - 載入

    func testFixtureLoadsWithSettingsPageInsidePluginDirectory() throws {
        let dir = try installFixture()
        let d = PluginRegistry.load(directory: dir)
        XCTAssertTrue(d.isValid, "\(String(describing: d.failure))")
        XCTAssertEqual(d.settingsPageURL?.lastPathComponent, "settings.html")
        XCTAssertEqual(d.settingsPageURL?.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
    }

    func testMissingSettingsPageRejectsWholePlugin() throws {
        let dir = try installFixture()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("settings.html"))
        let d = PluginRegistry.load(directory: dir)
        XCTAssertFalse(d.isValid)
        XCTAssertTrue(isManifestInvalid(d.failure))
    }

    func testSettingsPageSymlinkLeavingPluginDirectoryIsRejected() throws {
        let dir = try installFixture()
        let outside = tmp.appendingPathComponent("outside.html")
        try Data("<p>x</p>".utf8).write(to: outside)
        let page = dir.appendingPathComponent("settings.html")
        try FileManager.default.removeItem(at: page)
        try FileManager.default.createSymbolicLink(at: page, withDestinationURL: outside)
        XCTAssertTrue(isManifestInvalid(PluginRegistry.load(directory: dir).failure))
    }

    func testSettingsPageThatIsADirectoryIsRejected() throws {
        let dir = try installFixture()
        let page = dir.appendingPathComponent("settings.html")
        try FileManager.default.removeItem(at: page)
        try FileManager.default.createDirectory(at: page, withIntermediateDirectories: false)
        XCTAssertTrue(isManifestInvalid(PluginRegistry.load(directory: dir).failure))
    }

    // MARK: - bridge

    @MainActor
    func testBridgeWriteIsReadBackThroughSettingsStoreOverrides() throws {
        let schema = try XCTUnwrap(PluginRegistry.load(directory: try installFixture()).manifest?.settings)
        let settings = SettingsStore(defaults: defaults)
        let reply = { (body: [String: Any]) in
            PluginSettingsBridge.reply(
                to: body, schema: schema,
                read: { settings.pluginSettingValue(pluginId: self.id, key: $0) },
                write: { settings.setPluginSettingValue(pluginId: self.id, key: $0, value: $1) })
        }

        XCTAssertEqual(reply(["op": "set", "key": "note", "value": "改過"]).0 as? Bool, true)
        XCTAssertEqual(reply(["op": "set", "key": "repeat", "value": NSNumber(value: 3)]).0 as? Bool, true)
        XCTAssertEqual(reply(["op": "set", "key": "enabled", "value": NSNumber(value: false)]).0 as? Bool, true)

        let overrides = settings.pluginSettingOverrides(pluginId: id, keys: Array(schema.keys))
        XCTAssertEqual(overrides["note"] as? String, "改過")
        XCTAssertEqual(overrides["repeat"] as? Double, 3)
        XCTAssertEqual(overrides["enabled"] as? Bool, false)
        XCTAssertEqual(reply(["op": "get", "key": "note"]).0 as? String, "改過")
        let all = try XCTUnwrap(reply(["op": "get"]).0 as? [String: Any])
        XCTAssertEqual(all["repeat"] as? Double, 3)
    }

    /// 真的建設定頁 WebView：頁面 JS 只有 `window.naki`，碰不到遊戲頁的任何 Naki 全域；
    /// `set` 經 WKScriptMessageHandlerWithReply 寫進 SettingsStore，型別錯誤以 Promise reject 回到頁面。
    @MainActor
    func testSettingsPageBridgeEndToEndInIsolatedWebView() async throws {
        let dir = try installFixture()
        let d = PluginRegistry.load(directory: dir)
        let schema = try XCTUnwrap(d.manifest?.settings)
        let settings = SettingsStore(defaults: defaults)
        let coordinator = PluginSettingsWebView.Coordinator()
        coordinator.handle = { body in
            PluginSettingsBridge.reply(
                to: body, schema: schema,
                read: { settings.pluginSettingValue(pluginId: self.id, key: $0) },
                write: { settings.setPluginSettingValue(pluginId: self.id, key: $0, value: $1) })
        }
        let webView = PluginSettingsWebView.makeWebView(
            pageURL: try XCTUnwrap(d.settingsPageURL), directory: d.directory, coordinator: coordinator)
        for _ in 0..<100 where webView.isLoading || webView.url == nil {
            try await Task.sleep(for: .milliseconds(50))
        }

        let globals = try await webView.callAsyncJavaScript(
            "return [typeof window.naki, typeof window.__nakiPlugins, typeof window.__nakiWebSocket, typeof window.__nakiCore].join(',')",
            contentWorld: .page) as? String
        XCTAssertEqual(globals, "object,undefined,undefined,undefined")

        let ok = try await webView.callAsyncJavaScript(
            "return await window.naki.set('note', 'e2e')", contentWorld: .page) as? Bool
        XCTAssertEqual(ok, true)
        XCTAssertEqual(settings.pluginSettingValue(pluginId: id, key: "note") as? String, "e2e")

        let rejected = try await webView.callAsyncJavaScript(
            "try { await window.naki.set('repeat', true); return 'resolved'; } catch (e) { return String(e.message || e); }",
            contentWorld: .page) as? String
        XCTAssertEqual(rejected, "type_mismatch")
        XCTAssertNil(settings.pluginSettingValue(pluginId: id, key: "repeat"))

        // 主框架只能停在 manifest 指定的設定頁：同目錄的其他文件與外站導覽都被取消
        try Data("<p>other</p>".utf8).write(to: dir.appendingPathComponent("other.html"))
        for target in ["other.html", "https://example.invalid/"] {
            _ = try await webView.callAsyncJavaScript("location.href = '\(target)'; return true", contentWorld: .page)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(webView.url?.lastPathComponent, "settings.html", target)
        }
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // MARK: - 審查第二輪（Astra 2／8／10／13）

    /// 更新包缺設定頁必須在 finalize 就被拒，才不會先替換掉可用的舊版。
    func testImportFinalizeRequiresSettingsPageBeforeInstall() throws {
        var files = [String: Data]()
        for name in ["plugin.json", "plugin.js", "settings.html"] {
            files[name] = try Data(contentsOf: fixture.appendingPathComponent(name))
        }
        let ok = PluginImportSource.finalize(files: files, sourceURL: "u", revision: nil, updateSource: "u")
        if case .failure(let e) = ok { XCTFail("\(e)") }
        files["settings.html"] = nil
        guard case .failure(.invalidManifest) = PluginImportSource.finalize(files: files, sourceURL: "u", revision: nil, updateSource: "u") else {
            return XCTFail("缺 settings.html 仍被接受")
        }
    }

    /// grant 與設定頁 bridge 用同一條型別規則：錯型別或非有限值一律退回 default，兩端看到同一份值。
    func testGrantAndBridgeAgreeOnStaleOverrides() throws {
        let manifest = try XCTUnwrap(PluginRegistry.load(directory: try installFixture()).manifest)
        let schema = try XCTUnwrap(manifest.settings)
        let stale: [String: Any] = ["note": NSNumber(value: 3), "repeat": NSNumber(value: Double.nan), "enabled": NSNumber(value: 1)]
        let resolved = try XCTUnwrap(PluginRegistry.grantDict(for: manifest, overrides: stale)["settings"] as? [String: Any])
        let bridged = try XCTUnwrap(PluginSettingsBridge.reply(to: ["op": "get"], schema: schema,
                                                               read: { stale[$0] }, write: { _, _ in }).0 as? [String: Any])
        for key in schema.keys {
            XCTAssertEqual(resolved[key] as? NSObject, bridged[key] as? NSObject, key)
        }
        XCTAssertEqual(resolved["note"] as? String, "hello")
        XCTAssertEqual(resolved["repeat"] as? Double, 1)
        XCTAssertEqual(resolved["enabled"] as? Bool, true)
        XCTAssertNotNil(PluginRegistry.grantJSON(for: manifest, overrides: stale))
    }

    /// 版本、頁面內容或 schema 任一變了，設定頁身分就不同（View 以它重建 WebView）。
    func testSettingsPageIdentityChangesWithVersionPageOrSchema() throws {
        let dir = try installFixture()
        let identity = { PluginRegistry.load(directory: dir).settingsPageIdentity }
        let base = try XCTUnwrap(identity())
        XCTAssertEqual(identity(), base)

        let page = dir.appendingPathComponent("settings.html")
        try Data("<p>v2</p>".utf8).write(to: page)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: page.path)
        let afterPage = try XCTUnwrap(identity())
        XCTAssertNotEqual(afterPage, base)

        let manifestURL = dir.appendingPathComponent("plugin.json")
        let json = try String(contentsOf: manifestURL, encoding: .utf8)
        try json.replacingOccurrences(of: #""type": "number""#, with: #""type": "string""#)
            .replacingOccurrences(of: #""default": 1,"#, with: #""default": "1","#)
            .write(to: manifestURL, atomically: true, encoding: .utf8)
        let afterSchema = try XCTUnwrap(identity())
        XCTAssertNotEqual(afterSchema, afterPage)

        try json.replacingOccurrences(of: #""version": "0.1.0""#, with: #""version": "0.2.0""#)
            .write(to: manifestURL, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try XCTUnwrap(identity()), afterSchema)
    }

    func testBridgeGetFallsBackToDefaultWhenUnsetOrStoredTypeIsStale() throws {
        let schema = try XCTUnwrap(PluginRegistry.load(directory: try installFixture()).manifest?.settings)
        let stored: [String: Any] = ["repeat": "not a number"]
        let get = { (key: String) in
            PluginSettingsBridge.reply(to: ["op": "get", "key": key], schema: schema,
                                       read: { stored[$0] }, write: { _, _ in }).0
        }
        XCTAssertEqual(get("note") as? String, "hello")
        XCTAssertEqual(get("repeat") as? Double, 1)
        XCTAssertEqual(get("enabled") as? Bool, true)
    }

    func testBridgeRejectsUndeclaredKeysWrongTypesAndNonFiniteNumbers() throws {
        let schema = try XCTUnwrap(PluginRegistry.load(directory: try installFixture()).manifest?.settings)
        var writes = 0
        let set = { (key: String, value: Any) in
            PluginSettingsBridge.reply(to: ["op": "set", "key": key, "value": value], schema: schema,
                                       read: { _ in nil }, write: { _, _ in writes += 1 }).1
        }
        XCTAssertEqual(set("other", "x"), "unknown_key")
        XCTAssertEqual(set("repeat", NSNumber(value: true)), "type_mismatch")
        XCTAssertEqual(set("enabled", NSNumber(value: 1)), "type_mismatch")
        XCTAssertEqual(set("note", NSNumber(value: 1)), "type_mismatch")
        XCTAssertEqual(set("repeat", NSNumber(value: Double.nan)), "type_mismatch")
        XCTAssertEqual(set("repeat", NSNumber(value: Double.infinity)), "type_mismatch")
        XCTAssertEqual(PluginSettingsBridge.reply(to: ["op": "drop"], schema: schema,
                                                  read: { _ in nil }, write: { _, _ in }).1, "unknown_op")
        XCTAssertEqual(PluginSettingsBridge.reply(to: "x", schema: schema,
                                                  read: { _ in nil }, write: { _, _ in }).1, "bad_message")
        XCTAssertEqual(writes, 0)
    }
}
