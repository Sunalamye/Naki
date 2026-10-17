//
//  PluginSourceReceiptTests.swift
//  NakiTests
//
//  詳情頁的「來源」讀 install-receipt.json 的 sourceURL：只認 http／https，其餘一律 nil。
//

import XCTest

@testable import Naki

final class PluginSourceReceiptTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("naki-receipt-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
        {"schemaVersion":1,"apiVersion":1,"id":"demo","name":"n","version":"1.0",
        "entry":"plugin.js","capabilities":["observe"],"methods":[".lq.Foo"]}
        """.utf8).write(to: dir.appendingPathComponent("plugin.json"))
        try Data("console.log(1)".utf8).write(to: dir.appendingPathComponent("plugin.js"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func writeReceipt(_ text: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent("install-receipt.json"))
    }

    func testValidReceiptGivesSourceURL() throws {
        try writeReceipt(#"{"sourceURL":"https://github.com/o/r/plugin.json","updateSource":"o/r"}"#)
        let d = PluginRegistry.load(directory: dir)
        XCTAssertTrue(d.isValid)
        XCTAssertEqual(d.sourceURL, URL(string: "https://github.com/o/r/plugin.json"))
    }

    func testMissingReceiptGivesNil() {
        XCTAssertNil(PluginRegistry.load(directory: dir).sourceURL)
    }

    func testMalformedReceiptGivesNil() throws {
        try writeReceipt("{not json")
        XCTAssertNil(PluginRegistry.load(directory: dir).sourceURL)
    }

    func testNonHTTPSourcesGiveNil() throws {
        for bad in ["file:///etc/passwd", "file://localhost/etc/passwd", "smb://evil/share", "javascript:alert(1)", "not a url", "https://", ""] {
            try writeReceipt(#"{"sourceURL":"\#(bad)"}"#)
            XCTAssertNil(PluginRegistry.load(directory: dir).sourceURL, bad)
        }
    }
}
