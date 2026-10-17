//
//  PluginRegistryTests.swift
//  NakiTests
//
//  插件載入／匯入的安全邊界：id 與 entry 的字元集、移除只認實際目錄、
//  落地不可寫出 Plugins root、install 失敗不留半成品、非有限數值不進 grant。
//  全部用暫存目錄，不碰真的 Plugins 目錄。
//

import XCTest

@testable import Naki

final class PluginRegistryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("naki-plugin-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func manifestJSON(id: String, entry: String = "plugin.js", apiVersion: Int = 1,
                              settings: String? = nil) -> Data {
        let settingsPart = settings.map { ",\"settings\":\($0)" } ?? ""
        return Data("""
        {"schemaVersion":1,"apiVersion":\(apiVersion),"id":"\(id)","name":"n","version":"1.0",
        "entry":"\(entry)","capabilities":["observe"],"methods":[".lq.Foo"]\(settingsPart)}
        """.utf8)
    }

    @discardableResult
    private func writePlugin(dir: String, id: String, entry: String = "plugin.js",
                             apiVersion: Int = 1, settings: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try manifestJSON(id: id, entry: entry, apiVersion: apiVersion, settings: settings)
            .write(to: url.appendingPathComponent("plugin.json"))
        try Data("register({});".utf8).write(to: url.appendingPathComponent("plugin.js"))
        return url
    }

    private func imported(id: String, entry: String = "plugin.js",
                          files: [String: Data]? = nil) throws -> ImportedPlugin {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestJSON(id: id, entry: entry))
        return ImportedPlugin(id: id, manifest: manifest,
                              files: files ?? ["plugin.json": manifestJSON(id: id, entry: entry),
                                               entry: Data("register({});".utf8)],
                              sourceURL: "https://example.com/plugin.json", revision: nil,
                              updateSource: "https://example.com/plugin.json")
    }

    private func names(in url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    // MARK: - 字元集

    func testSafeNameAcceptsPlainIds() {
        XCTAssertTrue(PluginRegistry.isSafeName("naki-plugin-ex_1.2"))
        XCTAssertTrue(PluginRegistry.isSafeEntry("plugin.js"))
    }

    func testSafeNameRejectsTraversalAndInjectionCharacters() {
        for bad in ["", ".hidden", "..", "a..b", "../../x", "a/b", "a'b", "a\nb", "a b", "a\u{2028}b", "中文", "a\\b"] {
            XCTAssertFalse(PluginRegistry.isSafeName(bad), "應拒絕：\(bad.debugDescription)")
        }
        XCTAssertFalse(PluginRegistry.isSafeEntry("plugin.txt"))
        XCTAssertFalse(PluginRegistry.isSafeEntry("../evil.js"))
    }

    func testLoadMarksUnsafeIdInvalid() throws {
        let dir = try writePlugin(dir: "evil", id: "a'b")
        let d = PluginRegistry.load(directory: dir)
        XCTAssertFalse(d.isValid)
        XCTAssertEqual(d.id, "evil")
        XCTAssertEqual(d.failure?.code, "manifest_invalid")
    }

    func testLoadMarksUnsafeEntryInvalid() throws {
        let dir = try writePlugin(dir: "p", id: "p", entry: "../evil.js")
        XCTAssertEqual(PluginRegistry.load(directory: dir).failure?.code, "manifest_invalid")
    }

    func testInjectionScriptEscapesIdInsteadOfInterpolating() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestJSON(id: "x"))
        let d = PluginDescriptor(id: "x'\nalert(1)//", directory: root, manifest: manifest,
                                 entrySource: "register({});", failure: nil)
        let script = try XCTUnwrap(PluginRegistry.buildInjectionScript(
            descriptors: [d], enabled: [d.id]))
        XCTAssertFalse(script.contains("\nalert(1)"))
    }

    func testInjectionScriptBracketsPluginSourceWithBootstrapMarks() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestJSON(id: "x"))
        let d = PluginDescriptor(id: "x", directory: root, manifest: manifest,
                                 entrySource: "PLUGIN_BODY();", failure: nil)
        let script = try XCTUnwrap(PluginRegistry.buildInjectionScript(descriptors: [d], enabled: [d.id]))
        let begin = try XCTUnwrap(script.range(of: "__nakiPlugins.beginBootstrap()"))
        let body = try XCTUnwrap(script.range(of: "PLUGIN_BODY();"))
        let end = try XCTUnwrap(script.range(of: "__nakiPlugins.endBootstrap()"))
        XCTAssertLessThan(begin.lowerBound, body.lowerBound)
        XCTAssertLessThan(body.lowerBound, end.lowerBound)
        let hot = try XCTUnwrap(PluginRegistry.enableScript(for: d))
        XCTAssertFalse(hot.contains("Bootstrap"), "熱啟用不得帶 document-start 標記")
    }

    func testInjectionScriptBeginsOnceAndEndsAfterEveryPlugin() throws {
        let ds = try ["a", "b"].map { id -> PluginDescriptor in
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestJSON(id: id))
            return PluginDescriptor(id: id, directory: root, manifest: manifest,
                                    entrySource: "BODY_\(id.uppercased())();", failure: nil)
        }
        let script = try XCTUnwrap(PluginRegistry.buildInjectionScript(descriptors: ds, enabled: ["a", "b"]))
        XCTAssertEqual(script.components(separatedBy: "__nakiPlugins.beginBootstrap()").count - 1, 1)
        XCTAssertEqual(script.components(separatedBy: "__nakiPlugins.endBootstrap()").count - 1, 1)
        let end = try XCTUnwrap(script.range(of: "__nakiPlugins.endBootstrap()"))
        let first = try XCTUnwrap(script.range(of: "BODY_A();"))
        let second = try XCTUnwrap(script.range(of: "BODY_B();"))
        XCTAssertLessThan(first.lowerBound, end.lowerBound)
        XCTAssertLessThan(second.lowerBound, end.lowerBound)
    }

    // MARK: - 移除以實際目錄為準

    func testApiVersionMismatchDescriptorKeepsDirectoryIdentity() throws {
        try writePlugin(dir: "good", id: "good")
        let stale = try writePlugin(dir: "stale", id: "good", apiVersion: 2)
        let d = PluginRegistry.load(directory: stale)
        XCTAssertEqual(d.id, "stale")
        XCTAssertNil(PluginRegistry.remove(directory: d.directory, root: root))
        XCTAssertEqual(names(in: root), ["good"])
    }

    func testRemoveRefusesDirectoriesOutsideRoot() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("naki-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertNotNil(PluginRegistry.remove(directory: outside, root: root))
        XCTAssertNotNil(PluginRegistry.remove(directory: root.appendingPathComponent("../x"), root: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    // MARK: - 非有限數值

    func testGrantDropsNonFiniteOverrides() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestJSON(
            id: "p", settings: #"{"n":{"type":"number","default":3},"s":{"type":"string","default":"d"}}"#))
        let grant = PluginRegistry.grantDict(for: manifest, overrides: ["n": Double.nan, "s": "hi"])
        let settings = try XCTUnwrap(grant["settings"] as? [String: Any])
        XCTAssertEqual(settings["n"] as? Double, 3)
        XCTAssertEqual(settings["s"] as? String, "hi")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(grant))
        XCTAssertNotNil(PluginRegistry.grantJSON(for: manifest, overrides: ["n": Double.infinity]))
    }

    // MARK: - 匯入預覽與落地

    func testFinalizeRejectsUnsafeIdAndEntry() {
        for (id, entry) in [("../../../LaunchAgents", "plugin.js"), ("ok", "../../evil.js")] {
            let files = ["plugin.json": manifestJSON(id: id, entry: entry), entry: Data("x".utf8)]
            guard case .failure = PluginImportSource.finalize(
                files: files, sourceURL: "https://example.com", revision: nil, updateSource: "x")
            else { return XCTFail("應拒絕 id=\(id) entry=\(entry)") }
        }
    }

    func testInstallRefusesUnsafeIdAndEntryWithoutWriting() throws {
        for (id, entry) in [("../evil", "plugin.js"), ("ok", "../evil.js")] {
            guard case .failure = PluginImportSource.install(
                try imported(id: id, entry: entry, files: ["plugin.json": Data("{}".utf8), entry: Data("x".utf8)]),
                now: Date(), root: root) else { return XCTFail("應拒絕 id=\(id) entry=\(entry)") }
        }
        XCTAssertEqual(names(in: root), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent()
            .appendingPathComponent("evil").path))
    }

    func testInstallWritesFilesAndReceiptAndLeavesNoStaging() throws {
        guard case .success(let dir) = PluginImportSource.install(try imported(id: "p"), now: Date(), root: root)
        else { return XCTFail("應成功") }
        XCTAssertEqual(names(in: dir), ["install-receipt.json", "plugin.js", "plugin.json"])
        XCTAssertEqual(names(in: root), ["p"])
    }

    func testInstallReplacesExistingDirectory() throws {
        let old = try writePlugin(dir: "p", id: "p")
        try Data("stale".utf8).write(to: old.appendingPathComponent("leftover.txt"))
        guard case .success(let dir) = PluginImportSource.install(try imported(id: "p"), now: Date(), root: root)
        else { return XCTFail("應成功") }
        XCTAssertFalse(names(in: dir).contains("leftover.txt"))
    }

    func testFailedInstallKeepsExistingPluginAndCleansStaging() throws {
        pinAppLanguage()
        try writePlugin(dir: "p", id: "p")
        // 檔名超長：寫入時才會失敗，此時暫存目錄已建立
        let bad = try imported(id: "p", files: ["plugin.json": Data("{}".utf8),
                                                String(repeating: "a", count: 300): Data("x".utf8)])
        guard case .failure(let e) = PluginImportSource.install(bad, now: Date(), root: root)
        else { return XCTFail("應失敗") }
        XCTAssertTrue(e.text.hasPrefix("安裝失敗"))
        XCTAssertEqual(names(in: root), ["p"])
        XCTAssertTrue(PluginRegistry.load(directory: root.appendingPathComponent("p")).isValid)
    }

    // MARK: - 更新預覽

    func testUpdatePreviewReportsPermissionChange() throws {
        let old = try JSONDecoder().decode(PluginManifest.self, from: manifestJSON(id: "p"))
        let newJSON = Data("""
        {"schemaVersion":1,"apiVersion":1,"id":"p","name":"n","version":"2.0","entry":"plugin.js",
        "capabilities":["observe","injectSend"],"methods":[".lq.Foo"]}
        """.utf8)
        let fresh = try imported(id: "p", files: ["plugin.json": newJSON, "plugin.js": Data("x".utf8)])
        let changed = PluginUpdate(
            fresh: ImportedPlugin(id: "p", manifest: try JSONDecoder().decode(PluginManifest.self, from: newJSON),
                                  files: fresh.files, sourceURL: "", revision: nil, updateSource: ""),
            installed: old)
        XCTAssertEqual(changed.versionText, "v1.0 → v2.0")
        XCTAssertTrue(changed.permissionChange?.contains("injectSend") == true)
        XCTAssertNil(PluginUpdate(fresh: fresh, installed: old).permissionChange)
    }

    func testUpdatePreviewCoversRewriteAllowObserveAndFreshInstall() throws {
        pinAppLanguage()
        func manifest(_ extra: String) throws -> PluginManifest {
            try JSONDecoder().decode(PluginManifest.self, from: Data("""
            {"schemaVersion":1,"apiVersion":1,"id":"p","name":"n","version":"1.0","entry":"plugin.js",
            "capabilities":["observe"],"methods":[]\(extra)}
            """.utf8))
        }
        func update(old: PluginManifest?, new: PluginManifest) -> PluginUpdate {
            PluginUpdate(fresh: ImportedPlugin(id: "p", manifest: new, files: [:], sourceURL: "",
                                               revision: nil, updateSource: ""), installed: old)
        }
        let base = try manifest("")
        XCTAssertTrue(update(old: base, new: try manifest(",\"rewriteAllow\":[\".lq.Foo\"]"))
            .permissionChange?.contains("rewriteAllow 新增 .lq.Foo") == true)
        XCTAssertTrue(update(old: base, new: try manifest(",\"observeNakiTraffic\":true"))
            .permissionChange?.contains("observeNakiTraffic false → true") == true)
        XCTAssertTrue(update(old: nil, new: base).permissionChange?.contains("新安裝") == true)
    }
}
