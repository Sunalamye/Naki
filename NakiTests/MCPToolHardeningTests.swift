import XCTest

@testable import Naki

/// Debug／MCP 層的防禦性回歸：參數轉型不 trap、JSON 序列化不丟 ObjC 例外、
/// Host 驗證、錄影路徑限制、log 輪替保留錄影。
///
/// 只測純函式與 static 表；`DebugServer` 的 411／idle timeout 需要 live server，屬未驗證項。
final class MCPToolHardeningTests: XCTestCase {

    // MARK: - 參數轉型（E2）

    func testUInt32ArgumentRejectsOverflow() {
        XCTAssertThrowsError(try MCPArguments.uint32(["index": 4_294_967_296], "index"))
        XCTAssertThrowsError(try MCPArguments.uint32(Int.max, "room_id"))
    }

    func testUInt32ArgumentKeepsExistingSemantics() throws {
        XCTAssertEqual(try MCPArguments.uint32(["index": -5], "index"), 0, "負數夾成 0")
        XCTAssertEqual(try MCPArguments.uint32([:], "mode", default: 2), 2)
        XCTAssertEqual(try MCPArguments.uint32(["index": 4_294_967_295], "index"), UInt32.max)
    }

    @MainActor
    func testGameActionRejectsOversizedIndexInsteadOfTrapping() {
        XCTAssertThrowsError(try NakiGameAction.spec(
            action: "pon", arguments: ["index": 4_294_967_296], snapshot: nil))
        XCTAssertThrowsError(try NakiGameAction.spec(
            action: "discard", arguments: ["tile": "5m", "timeuse": 1 << 40], snapshot: nil))
    }

    // MARK: - hora fail-closed（E14）

    private func snapshot(_ types: [LiqiOperationType]) -> LiqiOperationSnapshot {
        LiqiOperationSnapshot(
            sequence: 1, seat: 0,
            operations: types.map { LiqiOperation(rawType: $0.rawValue) },
            timeAdd: 0, timeFixed: 300, contextTile: "9s", source: "test", capturedAt: Date())
    }

    @MainActor
    func testHoraWithoutSnapshotIsRefused() {
        XCTAssertThrowsError(try NakiGameAction.spec(action: "hora", arguments: [:], snapshot: nil))
    }

    @MainActor
    func testHoraWithoutHoraAuthorizationIsRefused() {
        XCTAssertThrowsError(try NakiGameAction.spec(
            action: "hora", arguments: [:], snapshot: snapshot([.discard])))
    }

    /// MCP 拔北：剛摸到的北由呼叫端帶 moqie=true，不帶時維持在手北的 `080b`
    @MainActor
    func testBabeiPassesMoqieArgument() throws {
        let drawn = try NakiGameAction.spec(action: "babei", arguments: ["moqie": true], snapshot: nil)
        XCTAssertEqual(LiqiEncoder.hexString(drawn.payload), "080b2801")
        let inHand = try NakiGameAction.spec(action: "babei", arguments: [:], snapshot: nil)
        XCTAssertEqual(LiqiEncoder.hexString(inHand.payload), "080b")
    }

    @MainActor
    func testHoraFollowsServerAuthorization() throws {
        let tsumo = try NakiGameAction.spec(action: "hora", arguments: [:], snapshot: snapshot([.tsumo]))
        XCTAssertEqual(tsumo.method, LiqiRequestBuilder.tsumo().method)
        XCTAssertEqual(tsumo.payload, LiqiRequestBuilder.tsumo().payload)

        let ron = try NakiGameAction.spec(action: "hora", arguments: [:], snapshot: snapshot([.ron]))
        XCTAssertEqual(ron.payload, LiqiRequestBuilder.ron().payload)
    }

    // MARK: - JSON 序列化（E3）

    /// `Date` 等非 JSON 型別過去會讓 `JSONSerialization` 丟 ObjC 例外，`try` 攔不到
    func testSanitizerMakesNonJSONTypesSerializable() throws {
        struct Opaque {}
        let payload: [String: Any] = [
            "date": Date(timeIntervalSince1970: 0),
            "nested": ["list": [Date(timeIntervalSince1970: 1), Opaque(), Double.nan]],
            "url": URL(string: "https://example.com")!,
            "ok": "text"
        ]

        let data = try JSONSanitizer.data(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["date"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(json["url"] as? String, "https://example.com")
        XCTAssertEqual(json["ok"] as? String, "text")
        let list = try XCTUnwrap((json["nested"] as? [String: Any])?["list"] as? [Any])
        XCTAssertEqual(list[0] as? String, "1970-01-01T00:00:01.000Z")
        XCTAssertTrue(list[1] is String)
        XCTAssertTrue(list[2] is NSNull)
    }

    /// 非 String key 的 dictionary 不是合法 JSON，會被轉成字串而不是走到 ObjC 例外
    func testSanitizerHandlesNonStringKeyDictionary() {
        let payload: [String: Any] = ["bad": [1: "non-string key"]]
        XCTAssertNoThrow(try JSONSanitizer.data(payload))
    }

    func testStructuredContentSurvivesDate() throws {
        let structured = NakiMCPProtocol.structuredContent(from: ["result": Date()])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(structured))
    }

    // MARK: - Host 驗證（E7）

    func testHostPolicy() {
        for ok in ["127.0.0.1", "127.0.0.1:8765", "localhost", "LOCALHOST:8766", "[::1]", "[::1]:8765"] {
            XCTAssertTrue(NakiMCPHostPolicy.isAllowed(ok), ok)
        }
        for bad in ["evil.example", "evil.example:8765", "127.0.0.1.evil.example",
                    "localhost.evil.example", "[::2]:8765", "[::1", "0.0.0.0:8765", "192.168.1.5:8765"] {
            XCTAssertFalse(NakiMCPHostPolicy.isAllowed(bad), bad)
        }
    }

    func testHostPolicyAllowsMissingHeader() {
        XCTAssertTrue(NakiMCPHostPolicy.isAllowed(nil))
    }

    func testRequestGuardRejectsBadHostOrOrigin() {
        func request(_ headers: String...) -> [String] { ["GET /logs HTTP/1.1"] + headers + ["", ""] }
        XCTAssertNil(NakiMCPRequestGuard.rejection(lines: request("Host: 127.0.0.1:8765")))
        XCTAssertNil(NakiMCPRequestGuard.rejection(lines: request()), "沒有 Host／Origin 的 curl 放行")
        let rebound = NakiMCPRequestGuard.rejection(lines: request("Host: evil.example:8765"))
        XCTAssertTrue(rebound?.reason.contains("host") == true)
        XCTAssertTrue(rebound?.body.contains("Forbidden host") == true)
        let crossSite = NakiMCPRequestGuard.rejection(
            lines: request("Host: 127.0.0.1:8765", "Origin: https://evil.example"))
        XCTAssertTrue(crossSite?.body.contains("Forbidden origin") == true)
    }

    /// DebugServer 是 MainActor 類別、需要 live server 才能跑 handler；這裡鎖「守衛在路由之前被呼叫」。
    /// 刪掉那個呼叫，上面的純函式測試不會變紅——只有這條會。
    func testDebugServerCallsRequestGuardBeforeRouting() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("command/Services/Debug/DebugServer.swift"), encoding: .utf8)
        let guardCall = try XCTUnwrap(source.range(of: "NakiMCPRequestGuard.rejection(lines: lines)"))
        let routing = try XCTUnwrap(source.range(of: "trace(\"Request:"))
        XCTAssertLessThan(guardCall.lowerBound, routing.lowerBound)
    }

    // MARK: - 錄影路徑限制（E33）

    func testReplayPathConfinedToLogsRoot() {
        let root = ReplaySupport.logsRoot
        XCTAssertTrue(ReplaySupport.isInsideLogsRoot(
            root.appendingPathComponent("20260101-000000/games/a.mjai.jsonl")))
        XCTAssertFalse(ReplaySupport.isInsideLogsRoot(URL(fileURLWithPath: "/etc/passwd")))
        XCTAssertFalse(ReplaySupport.isInsideLogsRoot(
            root.appendingPathComponent("20260101-000000/games/../../../../../../etc/passwd")))
        XCTAssertFalse(ReplaySupport.isInsideLogsRoot(root), "根目錄本身不是錄影檔")
    }

    @MainActor
    func testReplaySessionRejectsParentDirectory() {
        XCTAssertThrowsError(try ReplaySupport.gamesDirectory(session: ".."))
        XCTAssertThrowsError(try ReplaySupport.gamesDirectory(session: "a/b"))
    }

    // MARK: - log 輪替保留錄影（E15）

    func testPruneKeepsOnlyGamesOfOldSessionsWithRecordings() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("naki-prune-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let names = (1...10).map { String(format: "20260101-0000%02d", $0) }
        for name in names {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        // 最舊的一個有錄影；空的 games/ 不算
        let games = root.appendingPathComponent(names[0]).appendingPathComponent("games")
        try fm.createDirectory(at: games, withIntermediateDirectories: true)
        fm.createFile(atPath: games.appendingPathComponent("g.mjai.jsonl").path, contents: Data("x".utf8))
        let bigLog = root.appendingPathComponent(names[0]).appendingPathComponent("all.log")
        fm.createFile(atPath: bigLog.path, contents: Data("log".utf8))
        try fm.createDirectory(at: root.appendingPathComponent(names[1]).appendingPathComponent("games"),
                               withIntermediateDirectories: true)

        LogManager.pruneOldSessions(root: root, keep: 3)

        let left = Set(try fm.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(left, Set([names[0]] + Array(names.suffix(3))), "有錄影的舊 session 保留目錄，其餘只留最新 3 個")
        XCTAssertFalse(fm.fileExists(atPath: bigLog.path), "舊 session 的 log 要刪")
        XCTAssertTrue(fm.fileExists(atPath: games.appendingPathComponent("g.mjai.jsonl").path), "錄影保留")
    }
}
