//
//  ServicesIRCTests.swift
//  NakiTests
//
//  服務層 Intention-Revealing Code 工作包的回歸測試（SV-01、04、05 與行為改變的建議項）。
//

import XCTest

@testable import Naki

@MainActor
final class ServicesIRCTests: XCTestCase {

    // MARK: - SV-01 bot_sync 失敗結果符合自己的 outputSchema

    func testBotSyncFailureOutputSatisfiesOutputSchemaRequired() async throws {
        let store = GameStore()
        let send: SendActionAction = .unavailable("test_not_wired")
        let context = DefaultNakiMCPContext(dependencies: NakiMCPDependencies(
            store: store, ui: UIState(), settings: SettingsStore(),
            executeJavaScript: .unavailable, captureScreenshot: .unavailable,
            sendAction: send,
            startUnifiedMatch: StartUnifiedMatchAction(send: send),
            cancelUnifiedMatch: CancelUnifiedMatchAction(send: send),
            triggerAutoPlay: .unavailable, setAntiIdle: .unavailable,
            gameSnapshot: GameSnapshotAction(store: store, accountSource: nil),
            forceReconnect: ForceReconnectAction(stub: { .failed("page_not_loaded") })))

        let output = try await BotSyncTool(context: context).execute(arguments: [:]) as? [String: Any]

        let required = NakiToolOutputSchemas.schema(for: "bot_sync")["required"] as? [String] ?? []
        XCTAssertFalse(required.isEmpty)
        for key in required {
            XCTAssertNotNil(output?[key], "bot_sync 失敗輸出缺 required 欄位 \(key)")
        }
        XCTAssertEqual(output?["error"] as? String, "page_not_loaded", "原有 error 欄位保留")
    }

    // MARK: - SV-04 replay truncated 只在真的被 limit 截斷時為真

    func testReplayTruncatedOnlyWhenLimitDroppedDecisions() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/replay-20260803-020304.mjai.jsonl")
        let events = try GameRecorder.load(fixture)

        func run(limit: Int) async throws -> [String: Any] {
            let result = try await ReplaySupport.run(events: events, limit: limit, source: "t")
            return try XCTUnwrap(result as? [String: Any])
        }
        let full = try await run(limit: 10_000)
        let total = try XCTUnwrap(full["decisionCount"] as? Int)
        XCTAssertGreaterThan(total, 1)
        XCTAssertEqual(full["truncated"] as? Bool, false)

        let exact = try await run(limit: total)
        XCTAssertEqual(exact["decisionCount"] as? Int, total)
        XCTAssertEqual(exact["truncated"] as? Bool, false, "決策數恰等於 limit 時沒有丟任何決策")

        let cut = try await run(limit: total - 1)
        XCTAssertEqual(cut["decisionCount"] as? Int, total - 1)
        XCTAssertEqual(cut["truncated"] as? Bool, true)
    }

    // MARK: - SV-05 Origin 的 port 必須等於實際綁定的 port

    func testOriginPortMustMatchBoundPort() {
        let bound: UInt16 = 8765
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed("http://127.0.0.1:8765", boundPort: bound))
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed("http://localhost:8765", boundPort: bound))
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed("http://[::1]:8765", boundPort: bound))
        XCTAssertFalse(NakiMCPOriginPolicy.isAllowed("http://localhost:3000", boundPort: bound))
        XCTAssertFalse(NakiMCPOriginPolicy.isAllowed("http://127.0.0.1:8766", boundPort: bound))
        XCTAssertFalse(NakiMCPOriginPolicy.isAllowed("http://localhost", boundPort: bound), "無 port 即預設 80")
    }

    func testOriginWithoutHeaderAndNonLoopbackBehaviorUnchangedWhenBound() {
        let bound: UInt16 = 8765
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed(nil, boundPort: bound))
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed("", boundPort: bound))
        XCTAssertFalse(NakiMCPOriginPolicy.isAllowed("http://evil.example:8765", boundPort: bound))
        XCTAssertFalse(NakiMCPOriginPolicy.isAllowed("null", boundPort: bound))
    }

    func testOriginUnboundKeepsLegacyBehavior() {
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed("http://localhost:3000"))
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed("http://127.0.0.1:8766", boundPort: nil))
    }

    func testRequestGuardPassesBoundPortToOriginCheck() {
        func request(origin: String?) -> [String] {
            var lines = ["POST /js HTTP/1.1", "Host: 127.0.0.1:8765"]
            if let origin { lines.append("Origin: \(origin)") }
            return lines + ["", "body"]
        }
        XCTAssertNil(NakiMCPRequestGuard.rejection(lines: request(origin: "http://localhost:8765"), boundPort: 8765))
        XCTAssertNil(NakiMCPRequestGuard.rejection(lines: request(origin: nil), boundPort: 8765))
        XCTAssertNotNil(NakiMCPRequestGuard.rejection(lines: request(origin: "http://localhost:3000"), boundPort: 8765))
        XCTAssertNil(NakiMCPRequestGuard.rejection(lines: request(origin: "http://localhost:3000")), "未傳 boundPort 與 main 相同")
    }

    // MARK: - 共用 context

    private func makeContext(snapshot: [String: Any]? = nil,
                             forceReconnect: ForceReconnectAction = .unavailable) -> DefaultNakiMCPContext {
        let store = GameStore()
        let send: SendActionAction = .unavailable("test_not_wired")
        return DefaultNakiMCPContext(dependencies: NakiMCPDependencies(
            store: store, ui: UIState(), settings: SettingsStore(),
            executeJavaScript: .unavailable, captureScreenshot: .unavailable,
            sendAction: send,
            startUnifiedMatch: StartUnifiedMatchAction(send: send),
            cancelUnifiedMatch: CancelUnifiedMatchAction(send: send),
            triggerAutoPlay: .unavailable, setAntiIdle: .unavailable,
            gameSnapshot: snapshot.map { fixed in GameSnapshotAction(stub: { fixed }) }
                ?? GameSnapshotAction(store: store, accountSource: nil),
            forceReconnect: forceReconnect))
    }

    // MARK: - SV-19 來源標記看實際用的值

    func testAccountInfoSourceMarkerFollowsResolvedValue() async throws {
        let context = makeContext(snapshot: ["accountId": 4242])
        let tool = AccountInfoTool(context: context)

        let wrongType = try await tool.execute(arguments: ["account_id": "4242"]) as? [String: Any]
        XCTAssertEqual(wrongType?["account_id"] as? Int, 4242)
        XCTAssertEqual(wrongType?["accountIdSource"] as? String, "naki-login-capture", "字串型別的參數沒被採用")

        let given = try await tool.execute(arguments: ["account_id": 7]) as? [String: Any]
        XCTAssertEqual(given?["accountIdSource"] as? String, "argument")
    }

    func testLogFileNoteDescribesRetentionRule() async throws {
        let status = try await GetStatusTool(context: makeContext()).execute(arguments: [:]) as? [String: Any]
        let note = try XCTUnwrap(status?["logFileNote"] as? String)
        XCTAssertTrue(note.contains("保留最近 \(LogManager.sessionKeepCount) 次完整目錄"), note)
        XCTAssertTrue(note.contains("更舊且有錄影的只留 games/"), note)
    }

    func testStartUnifiedMatchSidSourceFollowsResolvedValue() async throws {
        isolateSharedObservedMatchSids(self)
        ObservedMatchSids.shared.record(sid: "observed-sid", clientVersionString: "v")
        let tool = StartUnifiedMatchTool(context: makeContext())

        let observed = try await tool.execute(arguments: [:]) as? [String: Any]
        XCTAssertEqual(observed?["match_sid"] as? String, "observed-sid")
        XCTAssertEqual(observed?["sidSource"] as? String, "observed")

        let wrongType = try await tool.execute(arguments: ["match_sid": 123]) as? [String: Any]
        XCTAssertEqual(wrongType?["match_sid"] as? String, "observed-sid")
        XCTAssertEqual(wrongType?["sidSource"] as? String, "observed", "型別不符的參數沒被採用")

        let given = try await tool.execute(arguments: ["match_sid": "mine"]) as? [String: Any]
        XCTAssertEqual(given?["match_sid"] as? String, "mine")
        XCTAssertEqual(given?["sidSource"] as? String, "argument")
    }
}
