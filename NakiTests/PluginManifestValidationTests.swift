//
//  PluginManifestValidationTests.swift
//  NakiTests
//
//  `PluginManifest.validate` 的四條規則（id 字元集、entry 字元集、apiVersion、settings schema）
//  與目錄名比對各一條，以及載入／匯入預覽兩個呼叫端確實共用這份規則。
//

import XCTest

@testable import Naki

final class PluginManifestValidationTests: XCTestCase {

    private func manifest(id: String = "p", entry: String = "plugin.js", apiVersion: Int = 1,
                          settings: String? = nil) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: manifestJSON(
            id: id, entry: entry, apiVersion: apiVersion, settings: settings))
    }

    private func manifestJSON(id: String = "p", entry: String = "plugin.js", apiVersion: Int = 1,
                              settings: String? = nil) -> Data {
        let settingsPart = settings.map { ",\"settings\":\($0)" } ?? ""
        return Data("""
        {"schemaVersion":1,"apiVersion":\(apiVersion),"id":"\(id)","name":"n","version":"1.0",
        "entry":"\(entry)","capabilities":["observe"],"methods":[".lq.Foo"]\(settingsPart)}
        """.utf8)
    }

    private func isManifestInvalid(_ failure: PluginLoadFailure?) -> Bool {
        if case .manifestInvalid = failure { return true }
        return false
    }

    func testValidManifestPasses() throws {
        XCTAssertNil(try manifest().validate())
        XCTAssertNil(try manifest(settings: #"{"s":{"type":"string","default":"d"},"n":{"type":"number","default":1},"b":{"type":"boolean","default":true}}"#).validate())
    }

    func testRejectsUnsafeId() throws {
        for bad in ["../x", ".hidden", "a b", "a'b"] {
            XCTAssertTrue(isManifestInvalid(try manifest(id: bad).validate()), "id=\(bad)")
        }
    }

    func testRejectsUnsafeEntry() throws {
        for bad in ["../evil.js", "plugin.txt", "sub/plugin.js"] {
            XCTAssertTrue(isManifestInvalid(try manifest(entry: bad).validate()), "entry=\(bad)")
        }
    }

    func testRejectsAnyApiVersionButOne() throws {
        for v in [0, 2] {
            XCTAssertEqual(try manifest(apiVersion: v).validate(), .apiVersionUnsupported(v))
        }
    }

    func testRejectsInvalidSettingsSchema() throws {
        for bad in [#"{"s":{"type":"string","default":3}}"#,
                    #"{"s":{"type":"date","default":"x"}}"#] {
            XCTAssertTrue(isManifestInvalid(try manifest(settings: bad).validate()), bad)
        }
    }

    func testIdMustMatchDirectoryNameOnlyWhenGiven() throws {
        let m = try manifest(id: "p")
        XCTAssertNil(m.validate(directoryName: "p"))
        XCTAssertNil(m.validate())
        guard case .idMismatch = m.validate(directoryName: "other") else { return XCTFail("應回 idMismatch") }
    }

    /// 載入時 manifest 自稱的 id 與實際目錄名不同就拒絕，且 descriptor 以目錄名為準。
    func testLoadRejectsIdThatDiffersFromDirectoryName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("naki-idmismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try manifestJSON(id: "other").write(to: dir.appendingPathComponent("plugin.json"))
        try Data("register({});".utf8).write(to: dir.appendingPathComponent("plugin.js"))

        let d = PluginRegistry.load(directory: dir)
        XCTAssertEqual(d.failure?.code, "id_mismatch")
        XCTAssertEqual(d.id, dir.lastPathComponent)
    }

    /// 載入與匯入預覽都必須擋下同樣的四種壞 manifest（其中一邊自己再寫一份規則就會在這裡分歧）。
    func testLoadAndFinalizeRejectTheSameInvalidManifests() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("naki-manifest-validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cases: [(name: String, id: String, entry: String, apiVersion: Int, settings: String?)] = [
            ("id", "a'b", "plugin.js", 1, nil),
            ("entry", "p", "plugin.txt", 1, nil),
            ("apiVersion", "p", "plugin.js", 2, nil),
            ("schema", "p", "plugin.js", 1, #"{"s":{"type":"string","default":3}}"#),
        ]
        for c in cases {
            let json = manifestJSON(id: c.id, entry: c.entry, apiVersion: c.apiVersion, settings: c.settings)
            let dir = root.appendingPathComponent("p", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try json.write(to: dir.appendingPathComponent("plugin.json"))
            try Data("register({});".utf8).write(to: dir.appendingPathComponent("plugin.js"))
            try Data("register({});".utf8).write(to: dir.appendingPathComponent("plugin.txt"))

            XCTAssertFalse(PluginRegistry.load(directory: dir).isValid, "load 應拒絕 \(c.name)")
            let files = ["plugin.json": json, c.entry: Data("x".utf8)]
            guard case .failure(.invalidManifest) = PluginImportSource.finalize(
                files: files, sourceURL: "https://example.com", revision: nil, updateSource: "x")
            else { XCTFail("finalize 應拒絕 \(c.name)"); continue }
        }
    }
}
