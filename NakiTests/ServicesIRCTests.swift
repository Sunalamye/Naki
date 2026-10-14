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

    // MARK: - SV-17 送出結果的三種狀態

    func testSendOutcomeStatesAreExclusive() {
        let sent = LiqiSendResult(method: "m", msgId: 1, byteCount: 2, success: true, detail: nil)
        let unavailable = LiqiToolSendOutcome.unavailable("why")
        XCTAssertNil(unavailable.sent)
        XCTAssertEqual(unavailable.unavailableReason, "why")
        let attempted = LiqiToolSendOutcome(sent: sent)
        XCTAssertEqual(attempted.sent?.msgId, 1)
        XCTAssertNil(attempted.unavailableReason)
        XCTAssertNil(attempted.response)

        let dict = LiqiToolResult.dictionaryLoggingRejection(
            unavailable, spec: LiqiRequestSpec(method: "m", fields: []))
        XCTAssertEqual(dict["error"] as? String, "liqi_sender_unavailable")
        XCTAssertEqual(dict["reason"] as? String, "why")
    }

    // MARK: - SV-18 bot_trigger 錯誤碼判斷順序與 main 一致

    func testBotTriggerWithoutOplistAndRecommendationKeepsMainErrorCode() async throws {
        let shared = LiqiOperationStore.shared
        shared.reset()
        defer { shared.reset() }

        let result = try await BotTriggerTool(context: makeContext()).execute(arguments: [:]) as? [String: Any]

        XCTAssertEqual(result?["error"] as? String, "no_recommendation")
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

    // MARK: - SV-20 room_quick_test 與 room_create 共用參數解析

    func testRoomConfigParserSharesRulesAndOnlyTimeFixedDefaultDiffers() throws {
        let create = try RoomConfigParser.parse([:], playerCount: 4, defaultTimeFixed: 300, acceptsRuleOverrides: true)
        let quick = try RoomConfigParser.parse([:], playerCount: 4, defaultTimeFixed: 60, acceptsRuleOverrides: false)
        XCTAssertEqual(create.config.timeFixed, 300)
        XCTAssertEqual(quick.config.timeFixed, 60)
        XCTAssertEqual(create.config.mode, 2)
        XCTAssertEqual(create.config.doraCount, quick.config.doraCount)
        XCTAssertEqual(create.config.initPoint, quick.config.initPoint)

        let sanma = try RoomConfigParser.parse(
            ["mode": 1, "dora_count": 5, "ai_level": 2], playerCount: 3, defaultTimeFixed: 60, acceptsRuleOverrides: true)
        XCTAssertEqual(sanma.config.mode, 11)
        XCTAssertTrue(sanma.resolved.adjusted)
        XCTAssertEqual(sanma.config.doraCount, 5)
        XCTAssertEqual(sanma.config.aiLevel, 2)
        XCTAssertThrowsError(try RoomConfigParser.parse(
            ["time_fixed": 1 << 40], playerCount: 4, defaultTimeFixed: 60, acceptsRuleOverrides: false))
    }

    /// 與 main 逐欄位相同：quick test 只吃 mode、time_fixed、time_add、ai_level
    func testRoomQuickTestRequestIgnoresRuleOverrides() async throws {
        var sent: [LiqiRequestSpec] = []
        let send = SendActionAction(stub: { spec, _ in
            sent.append(spec)
            return .unavailable("stop_after_create")
        })
        let store = GameStore()
        let context = DefaultNakiMCPContext(dependencies: NakiMCPDependencies(
            store: store, ui: UIState(), settings: SettingsStore(),
            executeJavaScript: .unavailable, captureScreenshot: .unavailable,
            sendAction: send,
            startUnifiedMatch: StartUnifiedMatchAction(send: send),
            cancelUnifiedMatch: CancelUnifiedMatchAction(send: send),
            triggerAutoPlay: .unavailable, setAntiIdle: .unavailable,
            gameSnapshot: GameSnapshotAction(store: store, accountSource: nil),
            forceReconnect: .unavailable))
        let tool = RoomQuickTestTool(context: context)

        _ = try await tool.execute(arguments: [
            "mode": 1, "time_fixed": 20, "time_add": 3, "ai_level": 2,
            "dora_count": 5, "shiduan": 0, "init_point": 1000, "fandian": 2000,
            "public_live": true, "enable_ai": true, "client_version_string": "x"
        ])

        var expected = LiqiFriendRoomConfig(playerCount: 4)
        expected.mode = 1
        expected.timeFixed = 20
        expected.timeAdd = 3
        expected.aiLevel = 2
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.payload, LiqiRequestBuilder.createRoom(config: expected).payload)
    }

    // MARK: - SV-22 bot_ops 與 game_ops 輸出相同

    func testBotOpsAndGameOpsShareOneOutput() async throws {
        let shared = LiqiOperationStore.shared
        shared.reset()
        defer { shared.reset() }
        shared.record(seat: 0, operations: [LiqiOperation(type: .discard)], contextTile: "5p")
        let context = makeContext()

        let bot = try await BotOpsTool(context: context).execute(arguments: [:]) as? [String: Any]
        let game = try await GameOpsTool(context: context).execute(arguments: [:]) as? [String: Any]

        XCTAssertEqual(bot?["hasPending"] as? Bool, true)
        let required = NakiToolOutputSchemas.schema(for: "bot_ops")["required"] as? [String] ?? []
        for key in required {
            XCTAssertNotNil(bot?[key], key)
            XCTAssertNotNil(game?[key], key)
        }
        XCTAssertEqual(bot?["source"] as? String, game?["source"] as? String)
    }

    // MARK: - SV-27 輪替只認時間戳目錄

    func testPruneIgnoresDirectoriesThatAreNotSessionStamps() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("naki-prune-stamp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let shortName = "20260101-00000"
        let names = ["20260101-000001", "abcdefg-hijklmn", "20261301-000000", shortName]
        for name in names {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        LogManager.pruneOldSessions(root: root, keep: 0)

        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: root.path)), [shortName],
                       "判斷只看 15 字元且含「-」，與 main 相同；14 字元不是 session 目錄")
    }

    func testLogFileNoteDescribesRetentionRule() async throws {
        let status = try await GetStatusTool(context: makeContext()).execute(arguments: [:]) as? [String: Any]
        let note = try XCTUnwrap(status?["logFileNote"] as? String)
        XCTAssertTrue(note.contains("保留最近 \(LogManager.sessionKeepCount) 次完整目錄"), note)
        XCTAssertTrue(note.contains("更舊且有錄影的只留 games/"), note)
    }

    func testLogFileNoteUsesRetentionConstant() {
        XCTAssertEqual(LogManager.sessionKeepCount, 8)
        XCTAssertEqual(LogManager.logsRoot.lastPathComponent, "Naki")
        XCTAssertTrue(ReplaySupport.isInsideLogsRoot(LogManager.logsRoot.appendingPathComponent("x/games/a.jsonl")))
    }

    // MARK: - SV-15 JSON-RPC 標準碼

    func testJSONRPCStandardCodesKeepWireValues() {
        XCTAssertEqual(NakiMCPProtocol.parseErrorCode, -32700)
        XCTAssertEqual(NakiMCPProtocol.invalidRequestCode, -32600)
        XCTAssertEqual(NakiMCPProtocol.methodNotFoundCode, -32601)
        XCTAssertEqual(NakiMCPProtocol.invalidParamsCode, -32602)
        XCTAssertEqual(NakiMCPProtocol.internalErrorCode, -32603)
    }

    // MARK: - SV-13 預設等待毫秒數只命名、不改值

    func testAwaitDefaultsKeepValuesAndDescriptionsQuoteThem() {
        XCTAssertEqual(MCPArguments.inGameAwaitMs, 800)
        XCTAssertEqual(MCPArguments.lobbyAwaitMs, 1500)
        XCTAssertEqual(MCPArguments.roomAwaitMs, 2000)
        XCTAssertEqual(GameDiscardTool.inputSchema.properties["awaitResponseMs"]?.description?.contains("預設 800"), true)
        XCTAssertEqual(AccountInfoTool.inputSchema.properties["awaitResponseMs"]?.description?.contains("預設 1500"), true)
        XCTAssertEqual(RoomStartTool.inputSchema.properties["awaitResponseMs"]?.description?.contains("預設 2000"), true)
    }

    // MARK: - 強化：變異存活者

    func testOriginWithoutPortUsesSchemeDefault() {
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed("http://localhost", boundPort: 80))
        XCTAssertFalse(NakiMCPOriginPolicy.isAllowed("http://localhost", boundPort: 443))
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed("https://localhost", boundPort: 443))
        XCTAssertFalse(NakiMCPOriginPolicy.isAllowed("https://localhost", boundPort: 80))
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed("https://localhost:8765", boundPort: 8765), "明寫的 port 優先於 scheme 預設")
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
