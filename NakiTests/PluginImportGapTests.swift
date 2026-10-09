//
//  PluginImportGapTests.swift
//  NakiTests
//
//  匯入器的分流與邊界（不碰網路）：host 分流靠「會在網路之前就回 badURL 的 URL」辨認，
//  finalize 的尺寸邊界、install 的檔名／衝突判斷、暫存目錄清理的時間邊界。
//

import XCTest

@testable import Naki

final class PluginImportGapTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("naki-import-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func manifestJSON(id: String = "p") -> Data {
        Data("""
        {"schemaVersion":1,"apiVersion":1,"id":"\(id)","name":"n","version":"1.0",
        "entry":"plugin.js","capabilities":["observe"],"methods":[".lq.Foo"]}
        """.utf8)
    }

    private func imported(files: [String: Data]? = nil) throws -> ImportedPlugin {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestJSON())
        return ImportedPlugin(id: "p", manifest: manifest,
                              files: files ?? ["plugin.json": manifestJSON(), "plugin.js": Data("x".utf8)],
                              sourceURL: "https://example.com/plugin.json", revision: nil,
                              updateSource: "https://example.com/plugin.json")
    }

    private func isBadURL<T>(_ r: Result<T, PluginImportError>) -> Bool {
        if case .failure(.badURL) = r { return true }
        return false
    }

    // MARK: - host 分流

    func testFetchRoutesGistHostBeforeAnyNetwork() async {
        let r = await PluginImportSource.fetch(urlString: "https://gist.github.com/")
        XCTAssertTrue(isBadURL(r), "gist 網址缺 id 要在送出任何請求前就回 badURL")
    }

    func testFetchAnyRoutesGistHostBeforeAnyNetwork() async {
        let r = await PluginImportSource.fetchAny(urlString: "https://gist.github.com/")
        XCTAssertTrue(isBadURL(r))
    }

    func testFetchAnyRoutesGitHubHostsToRepoFetcher() async {
        for url in ["https://github.com/onlyowner", "https://www.github.com/onlyowner", "onlyowner/"] {
            let r = await PluginImportSource.fetchAny(urlString: url)
            XCTAssertTrue(isBadURL(r), "\(url) 要走 repo 分支（路徑不足 owner/repo 即 badURL）")
        }
    }

    func testFetchAnyDoesNotTreatLookalikeHostAsGitHub() async {
        let r = await PluginImportSource.fetchAny(urlString: "http://github.com.evil.example/onlyowner")
        guard case .failure(.notHTTPS) = r else { return XCTFail("應走一般 HTTP 分支並因非 HTTPS 被拒：\(r)") }
    }

    // MARK: - finalize 尺寸邊界

    private func filesTotaling(_ total: Int) -> [String: Data] {
        let manifest = manifestJSON()
        return ["plugin.json": manifest, "plugin.js": Data(count: total - manifest.count)]
    }

    func testFinalizeAcceptsExactlyBundleMaxAndRejectsOneMore() {
        for (total, shouldPass) in [(PluginImportSource.bundleMax, true), (PluginImportSource.bundleMax + 1, false)] {
            let r = PluginImportSource.finalize(files: filesTotaling(total), sourceURL: "u", revision: nil, updateSource: "u")
            switch r {
            case .success: XCTAssertTrue(shouldPass, "total=\(total)")
            case .failure(.tooLarge): XCTAssertFalse(shouldPass, "total=\(total)")
            case .failure(let e): XCTFail("非預期錯誤 \(e)")
            }
        }
    }

    // MARK: - install

    func testInstallRefusesFileNamesThatEscapeTheDirectory() throws {
        for bad in ["a/b", "..", "."] {
            var files = ["plugin.json": manifestJSON(), "plugin.js": Data("x".utf8)]
            files[bad] = Data("x".utf8)
            guard case .failure(.invalidManifest) = PluginImportSource.install(
                try imported(files: files), now: Date(), root: root)
            else { return XCTFail("檔名 \(bad) 應被擋成 invalidManifest") }
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [], [])
    }

    func testInstallIgnoresUnrelatedSiblingDirectories() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
        guard case .success = PluginImportSource.install(try imported(), now: Date(), root: root)
        else { return XCTFail("無關的兄弟目錄不是大小寫衝突") }
    }

    func testInstallRejectsCaseOnlyClash() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("P"), withIntermediateDirectories: true)
        guard case .failure(.installFailed) = PluginImportSource.install(try imported(), now: Date(), root: root)
        else { return XCTFail("與既有 P 只差大小寫要拒絕") }
    }

    // MARK: - PluginRegistry

    func testRemoveStaleStagingKeepsFreshAndDeletesOld() throws {
        let fm = FileManager.default
        let old = root.appendingPathComponent(".install-old"), fresh = root.appendingPathComponent(".install-fresh")
        for d in [old, fresh] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)

        PluginRegistry.removeStaleStaging(in: root, olderThan: 3600)

        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
    }

    func testSafeNameBoundaries() {
        XCTAssertTrue(PluginRegistry.isSafeName(String(repeating: "a", count: 128)))
        XCTAssertFalse(PluginRegistry.isSafeName(String(repeating: "a", count: 129)))
        for ok in ["0", "9", "a", "z", "A", "Z", "_", "-", "x.y"] { XCTAssertTrue(PluginRegistry.isSafeName(ok), ok) }
        for bad in ["/", ":", "@", "[", "`", "{", " ", "é"] { XCTAssertFalse(PluginRegistry.isSafeName(bad), bad) }
    }

    func testRemoveByEmptyIdReportsEmptyId() {
        XCTAssertEqual(PluginRegistry.remove(id: ""), L10n.text("id 為空"))
    }
}
