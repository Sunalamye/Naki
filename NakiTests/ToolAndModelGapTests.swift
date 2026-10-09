//
//  ToolAndModelGapTests.swift
//  NakiTests
//
//  MCP 工具與模型顯示的邊界：execute_js 的逾時競態、replay 的路徑限制、
//  server 拒絕判斷、BotStatus 顯示名稱、設定的持久化寫入。
//

import SwiftUI
import XCTest

@testable import Naki

@MainActor
final class ToolAndModelGapTests: XCTestCase {

    private func context(js: ExecuteJavaScriptAction = .unavailable) -> DefaultNakiMCPContext {
        DefaultNakiMCPContext(dependencies: makeTestDependencies(store: GameStore(), executeJavaScript: js))
    }

    // MARK: - execute_js

    func testExecuteJSReturnsResultOfFirstFinisher() async throws {
        let tool = ExecuteJSTool(context: context(js: ExecuteJavaScriptAction(stub: { _ in "ok" })))
        let out = try await tool.execute(arguments: ["code": "return 'ok'"]) as? [String: Any]
        XCTAssertEqual(out?["result"] as? String, "ok")
    }

    func testExecuteJSPropagatesScriptErrorInsteadOfHanging() async {
        let tool = ExecuteJSTool(context: context(js: ExecuteJavaScriptAction(stub: { _ in
            throw NSError(domain: "NakiTests", code: 7) })))
        do {
            _ = try await tool.execute(arguments: ["code": "boom"])
            XCTFail("腳本錯誤要原樣丟出")
        } catch {
            XCTAssertEqual((error as NSError).code, 7)
        }
    }

    func testExecuteJSTimesOutWhenScriptNeverFinishes() async {
        let tool = ExecuteJSTool(context: context(js: ExecuteJavaScriptAction(stub: { _ in
            try await Task.sleep(for: .seconds(30)); return nil })))
        let started = Date()
        do {
            _ = try await tool.execute(arguments: ["code": "x", "timeout": 0])
            XCTFail("應逾時")
        } catch {
            XCTAssertTrue("\(error)".contains("逾時"), "\(error)")
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "timeout 0 夾成 1 秒")
        }
    }

    func testExecuteJSTimeoutBelowOneSecondIsClampedUp() async throws {
        let tool = ExecuteJSTool(context: context(js: ExecuteJavaScriptAction(stub: { _ in
            try await Task.sleep(for: .milliseconds(300)); return "late" })))
        let out = try await tool.execute(arguments: ["code": "x", "timeout": 0]) as? [String: Any]
        XCTAssertEqual(out?["result"] as? String, "late", "timeout 0 夾成 1 秒，不是立刻逾時")
    }

    // MARK: - replay

    func testReplayRunRejectsSeatOutsideByteRange() async {
        for id in [300, -1] {
            do {
                _ = try await ReplaySupport.run(events: [["type": "start_game", "id": id]], limit: 1, source: "t")
                XCTFail("id=\(id) 應拒絕")
            } catch {
                XCTAssertTrue("\(error)".contains("0–255"), "id=\(id)：\(error)")
            }
        }
    }

    func testReplayGameRejectsAbsolutePathOutsideLogsRoot() async {
        let tool = ReplayGameTool(context: context())
        do {
            _ = try await tool.execute(arguments: ["file": "/nonexistent-naki-test/x.mjai.jsonl"])
            XCTFail("應拒絕")
        } catch {
            XCTAssertTrue("\(error)".contains("Logs/Naki"), "要是『限 log 根目錄』的訊息，而不是『檔案不存在』：\(error)")
        }
    }

    func testGamesDirectoryRejectsEscapingSessionNames() {
        for bad in ["../x", "a/b", "..", "."] {
            XCTAssertThrowsError(try ReplaySupport.gamesDirectory(session: bad), bad)
        }
    }

    func testGamesDirectoryAcceptsPlainSessionName() throws {
        let dir = try ReplaySupport.gamesDirectory(session: "20260101-000000")
        XCTAssertEqual(dir.lastPathComponent, "games")
        XCTAssertEqual(dir.deletingLastPathComponent().lastPathComponent, "20260101-000000")
    }

    // MARK: - server 拒絕判斷

    func testServerAcceptedFollowsErrorField() {
        func record(_ fields: [String: Any]) -> LiqiResponseRecord {
            LiqiResponseRecord(msgId: 60001, method: ".lq.Lobby.matchGame", fields: fields, receivedAt: Date())
        }
        XCTAssertTrue(LiqiToolResult.serverAccepted(record([:])))
        XCTAssertFalse(LiqiToolResult.serverAccepted(record(["field1": "COwH"])))
    }

    // MARK: - 吃的標籤

    func testChiLabelClampsIndexIntoCircledDigits() {
        func label(_ l: String) -> String { Recommendation(actionType: .chi, probability: 1, label: l).displayLabel }
        XCTAssertEqual(label("chi_0"), "吃①")
        XCTAssertEqual(label("chi_1"), "吃②")
        XCTAssertEqual(label("chi_2"), "吃③")
        XCTAssertEqual(label("chi_7"), "吃③")
        XCTAssertEqual(label("chi_-4"), "吃①")
    }

    // MARK: - BotStatus 顯示名稱

    private func key(_ k: LocalizedStringKey) -> String {
        Mirror(reflecting: k).children.first { $0.label == "key" }?.value as? String ?? ""
    }

    private func status(_ model: String, is3P: Bool = false, source: String = "local") -> BotStatus {
        var s = BotStatus()
        s.modelName = model; s.is3P = is3P; s.decisionSource = source
        return s
    }

    func testModelDisplayNamesForFourPlayer() {
        XCTAssertEqual(key(status("mortal").modelDisplayKey), "Mortal (4P)")
        XCTAssertEqual(key(status("mortal3p").modelDisplayKey), "Mortal (3P)")
        XCTAssertEqual(key(status("custom-x").modelDisplayKey), "custom-x")
        XCTAssertEqual(key(status("cloud-only").modelDisplayKey), "cloud-only", "四麻沒有三麻專用名稱")
    }

    func testModelDisplayWarnsOnlyWhenThreePlayerRunsWithoutCloudDecision() {
        XCTAssertEqual(key(status("cloud-only", is3P: true, source: "local").modelDisplayKey), "雲端推論 (3P) ⚠️ 未生效，無推論")
        XCTAssertEqual(key(status("cloud-only", is3P: true, source: "cloud:m").modelDisplayKey), "雲端推論 (3P)")
        XCTAssertEqual(key(status("akagi-sanma-bc", is3P: true, source: "local-akagi3p").modelDisplayKey), "Akagi 三麻・default strength")
        XCTAssertEqual(key(status("cloud+akagi-sanma-bc", is3P: true, source: "cloud:m").modelDisplayKey), "雲端推論 (3P)")
        XCTAssertEqual(key(status("mortal", is3P: true, source: "local-akagi3p").modelDisplayKey), "Mortal (4P)")
        XCTAssertTrue(key(status("mortal", is3P: true, source: "local").modelDisplayKey).hasSuffix("⚠️ 三麻無專用模型"))
        XCTAssertEqual(key(status("mortal", is3P: true, source: "cloud:m").modelDisplayKey), "Mortal (4P)")
    }

    // MARK: - 設定持久化

    func testSettingsWritesChangesThroughToUserDefaults() {
        let defaults = UserDefaults.standard
        let keys = [SettingsStore.keepAliveInBackgroundKey, SettingsStore.autoCheckUpdateKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { zip(keys, saved).forEach { defaults.set($1, forKey: $0) } }

        let store = SettingsStore()
        for flip in [false, true] {
            store.keepAliveInBackground = flip
            store.autoCheckUpdate = flip
            XCTAssertEqual(defaults.object(forKey: SettingsStore.keepAliveInBackgroundKey) as? Bool, flip)
            XCTAssertEqual(defaults.object(forKey: SettingsStore.autoCheckUpdateKey) as? Bool, flip)
        }
    }
}
