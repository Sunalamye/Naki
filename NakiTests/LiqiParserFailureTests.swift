//
//  LiqiParserFailureTests.swift
//  NakiTests
//
//  p4-1 回歸鎖：解析失敗必須是**顯式**的，不得偽裝成正常資料。
//
//  舊行為（三種偽裝）：
//  1. `parsePackedInt32` 解不出 4 個合理分數 → 回 `[25000, 25000, 25000, 25000]`；
//     `MajsoulBridge` 再 `?? [25000, ...]` 一次。於是「解析失敗」與「大家都是起始分」
//     在 Bot 眼裡完全相同，而 Mortal 的決策吃順位與點差。
//  2. `parseActionPrototype` 找不到 field 3 → 抓任何一個 wireType 2 的 block 當 data，
//     XOR 解碼後餵給 Bot。schema 一改就靜默解錯，log 看起來一切正常。
//  3. authGame 回應沒有 seatList → 只 log 一行；`start_game` 不發、Bot 不建立、
//     整局沒有推薦，而畫面顯示「已連線」。
//
//  這批 test 鎖四件事：
//  A. 垃圾 bytes → 顯式失敗（沒有預設值、沒有頂替欄位），且帶得出解析上下文。
//  B. 正常 bytes → 行為不變（分數照 wire 解、start_game／start_kyoku 照發）。
//  C. 不可容忍的失敗（座位、start_kyoku）→ 進入 blocking 狀態，UI 看得見。
//  D. 保留下來的 heuristic（用 players 順序頂 seat_list）必須標記信心，不得混充 exact。
//

import XCTest

@testable import Naki

@MainActor
final class LiqiParserFailureTests: XCTestCase {

    // MARK: - Fixtures

    private let accountId = 123456

    /// 乾淨的失敗狀態（不碰 `LiqiParseFaultState.shared`，避免測試互相汙染）
    private func makeBridge() -> (MajsoulBridge, LiqiParseFaultState) {
        let state = LiqiParseFaultState()
        return (MajsoulBridge(faultState: state), state)
    }

    /// notify envelope：`[1][field1=method][field2=payload]`（notify 沒有 msgId）
    private func notifyFrame(method: String, payload: [UInt8]) -> Data {
        var out: [UInt8] = [LiqiMsgType.notify.rawValue]
        out += LiqiEncoder.encodeStringField(field: 1, value: method)
        out += LiqiEncoder.encodeLengthDelimited(field: 2, bytes: payload)
        return Data(out)
    }

    /// `ActionPrototype`（liqi.json：1=step, 2=name, 3=data）。
    /// notify 路徑的 data 需要 XOR——`liqiDecode` 是對合函數，拿它來加密。
    private func actionPrototypeFrame(name: String?, data: [UInt8]?, extraStringField: Int? = nil) -> Data {
        var fields: [LiqiField] = [.varint(field: 1, value: 7)]
        if let name { fields.append(.string(field: 2, value: name)) }
        if let data {
            fields.append(.bytes(field: 3, value: Array(liqiDecode(Data(data)))))
        }
        if let extraStringField {
            fields.append(.string(field: extraStringField, value: "unexpected-new-field"))
        }
        return notifyFrame(method: ".lq.ActionPrototype",
                           payload: LiqiEncoder.encodeFields(fields))
    }

    /// packed repeated 數值欄位的 bytes（不含 tag）
    private func packed(_ values: [Int]) -> [UInt8] {
        values.flatMap { LiqiEncoder.encodeVarint(UInt64($0)) }
    }

    /// `ActionNewRound`（liqi.json：1=chang, 2=ju, 3=ben, 4=tiles, 6=scores, 8=liqibang）
    private func newRoundPayload(scores: LiqiField?, tiles: [String] = []) -> [UInt8] {
        var fields: [LiqiField] = [
            .varint(field: 1, value: 0),
            .varint(field: 2, value: 0),
            .varint(field: 3, value: 0)
        ]
        fields += tiles.map { .string(field: 4, value: $0) }
        if let scores { fields.append(scores) }
        fields.append(.varint(field: 8, value: 0))
        return LiqiEncoder.encodeFields(fields)
    }

    /// authGame request（帶 account_id）＋ response 一組；msgId 必須一致才配得起來
    private func authGameRequest(msgId: UInt16) -> Data {
        Data(LiqiEncoder.encodeRequest(method: ".lq.FastTest.authGame",
                                       fields: [
                                        .varint(field: 1, value: UInt64(accountId)),
                                        .string(field: 2, value: "token"),
                                        .string(field: 3, value: "game-uuid")
                                       ],
                                       msgId: msgId))
    }

    private func authGameResponse(msgId: UInt16, fields: [LiqiField]) -> Data {
        Data(LiqiEncoder.encodeEnvelope(type: .response,
                                        msgId: msgId,
                                        method: "",
                                        payload: LiqiEncoder.encodeFields(fields)))
    }

    /// 一組 `PlayerGameView`（liqi.json：1=account_id, 4=nickname）
    private func playerFields(_ ids: [Int]) -> [LiqiField] {
        ids.map { id in
            .message(field: 2, fields: [
                .varint(field: 1, value: UInt64(id)),
                .string(field: 4, value: "P\(id)")
            ])
        }
    }

    /// 讓 bridge 進入「已知自家座位 0」的狀態（後續 action 測試的前置）
    @discardableResult
    private func authenticate(_ bridge: MajsoulBridge, msgId: UInt16 = 41) -> [[String: Any]]? {
        _ = bridge.parse(authGameRequest(msgId: msgId))
        return bridge.parse(authGameResponse(msgId: msgId, fields: [
            .bytes(field: 3, value: packed([accountId, 2, 3, 4]))
        ]))
    }

    // MARK: - A. 垃圾 bytes → 顯式失敗

    /// 分數解不開時**不得**回預設 25000；欄位直接不存在，並記一筆帶上下文的 fault。
    func testGarbageScoresProduceFaultInsteadOfDefault() {
        let parser = LiqiParser()
        // 0xff 是沒有結尾的 varint：packed 區段解不完 → 顯式失敗
        let frame = actionPrototypeFrame(name: "ActionNewRound",
                                         data: newRoundPayload(scores: .bytes(field: 6, value: [0xff, 0xff])))

        let parsed = parser.parse(frame)
        let data = parsed?["data"] as? [String: Any]
        let action = data?["data"] as? [String: Any]

        XCTAssertNotNil(action, "其餘欄位仍要解得出來（失敗只影響 scores）")
        XCTAssertNil(action?["scores"], "解不開的分數不得以 [25000, 25000, 25000, 25000] 頂替")

        let fault = parser.faults.first { $0.site == "ActionNewRound.scores" }
        XCTAssertNotNil(fault, "失敗要帶解析上下文回報")
        XCTAssertEqual(fault?.fieldId, 6, "field number 依 docs/protocol/liqi.json")
        XCTAssertEqual(fault?.byteCount, 2)
        XCTAssertEqual(fault?.severity, .degraded, "解析器只報事實，嚴重度由呼叫端判定")
    }

    /// 正常 packed 分數照 wire 解，不是回一組固定值。
    func testValidScoresAreParsedFromWire() {
        let parser = LiqiParser()
        let frame = actionPrototypeFrame(name: "ActionNewRound",
                                         data: newRoundPayload(scores: .bytes(field: 6,
                                                                              value: packed([31200, 24800, 25000, 19000]))))

        let action = (parser.parse(frame)?["data"] as? [String: Any])?["data"] as? [String: Any]

        XCTAssertEqual(action?["scores"] as? [Int], [31200, 24800, 25000, 19000])
        XCTAssertTrue(parser.faults.isEmpty, "正常 fixture 不得產生 fault")
    }

    /// repeated 標量也可能逐筆出現（wireType 0）：要累積，不能被最後一個 block 覆蓋。
    func testNonPackedScoresAreAccumulated() {
        let parser = LiqiParser()
        let fields: [LiqiField] = [
            .varint(field: 1, value: 0),
            .varint(field: 2, value: 0),
            .int(field: 6, value: 25000),
            .int(field: 6, value: 26000),
            .int(field: 6, value: 24000),
            .int(field: 6, value: 25000)
        ]
        let frame = actionPrototypeFrame(name: "ActionNewRound",
                                         data: LiqiEncoder.encodeFields(fields))

        let action = (parser.parse(frame)?["data"] as? [String: Any])?["data"] as? [String: Any]

        XCTAssertEqual(action?["scores"] as? [Int], [25000, 26000, 24000, 25000])
        XCTAssertTrue(parser.faults.isEmpty)
    }

    /// 沒有 field 3 時**不得**拿別的 wireType 2 欄位頂替（schema 漂移的靜默解錯來源）。
    func testMissingActionDataIsNotSubstitutedByAnotherField() {
        let parser = LiqiParser()
        // 只有 step / name / 一個未知的字串欄位；沒有 field 3
        let frame = actionPrototypeFrame(name: "ActionDealTile", data: nil, extraStringField: 9)

        let parsed = parser.parse(frame)

        XCTAssertNil(parsed?["data"], "解不出 action → 不得回半份結果")
        XCTAssertNotNil(parsed?["rawData"], "原始 bytes 仍保留供診斷")

        let fault = parser.faults.first { $0.site == "ActionPrototype.data" }
        XCTAssertNotNil(fault)
        XCTAssertEqual(fault?.fieldId, 3)
    }

    /// 沒有 name 就無法判斷這是哪一種動作 → 顯式失敗（舊版會去 data 裡猜一個字串當 name）。
    func testMissingActionNameIsExplicitFailure() {
        let parser = LiqiParser()
        let frame = actionPrototypeFrame(name: nil, data: [0x08, 0x01])

        XCTAssertNil(parser.parse(frame)?["data"])
        XCTAssertEqual(parser.faults.first?.site, "ActionPrototype.name")
    }

    /// 和牌詳情不再只留「幾個 block」：seat／點數等欄位要真的解出來。
    func testHuleDetailsArePreserved() {
        let parser = LiqiParser()
        let huleInfo: [LiqiField] = [
            .string(field: 1, value: "1m"),
            .string(field: 3, value: "5p"),
            .varint(field: 4, value: 2),      // seat
            .bool(field: 5, value: true),     // zimo
            .varint(field: 11, value: 4),     // count（飜）
            .varint(field: 13, value: 40),    // fu
            .varint(field: 19, value: 8000)   // point_sum
        ]
        let payload = LiqiEncoder.encodeFields([
            .message(field: 1, fields: huleInfo),
            .bytes(field: 5, value: packed([33000, 25000, 21000, 21000]))
        ])
        let frame = actionPrototypeFrame(name: "ActionHule", data: payload)

        let action = (parser.parse(frame)?["data"] as? [String: Any])?["data"] as? [String: Any]
        let hules = action?["hules"] as? [[String: Any]]

        XCTAssertEqual(hules?.count, 1)
        XCTAssertEqual(hules?.first?["seat"] as? Int, 2)
        XCTAssertEqual(hules?.first?["zimo"] as? Bool, true)
        XCTAssertEqual(hules?.first?["count"] as? Int, 4)
        XCTAssertEqual(hules?.first?["fu"] as? Int, 40)
        XCTAssertEqual(hules?.first?["pointSum"] as? Int, 8000)
        XCTAssertEqual(hules?.first?["huTile"] as? String, "5p")
        XCTAssertEqual(action?["scores"] as? [Int], [33000, 25000, 21000, 21000],
                       "scores 是 field 5，不是舊版誤用的 field 3（delta_scores）")
    }

    // MARK: - B. 正常路徑不變

    func testNormalAuthGameStartsGameWithoutFault() {
        let (bridge, state) = makeBridge()

        let events = authenticate(bridge)

        XCTAssertEqual(events?.first?["type"] as? String, "start_game")
        XCTAssertEqual(events?.first?["id"] as? Int, 0, "accountId 在 seatList 的第 0 位")
        XCTAssertEqual(events?.first?["is3P"] as? Bool, false)
        XCTAssertNil(state.blocking)
        XCTAssertEqual(state.totalCount, 0, "正常 fixture 不得產生任何 fault")
    }

    func testNormalNewRoundStillEmitsStartKyoku() {
        let (bridge, state) = makeBridge()
        authenticate(bridge)

        let tiles = ["1m", "2m", "3m", "4m", "5m", "6m", "7m", "8m", "9m", "1p", "2p", "3p", "4p"]
        let frame = actionPrototypeFrame(name: "ActionNewRound",
                                         data: newRoundPayload(scores: .bytes(field: 6,
                                                                              value: packed([31200, 24800, 25000, 19000])),
                                                               tiles: tiles))

        let events = bridge.parse(frame)
        let startKyoku = events?.first { ($0["type"] as? String) == "start_kyoku" }

        XCTAssertNotNil(startKyoku)
        XCTAssertEqual(startKyoku?["scores"] as? [Int], [31200, 24800, 25000, 19000])
        XCTAssertNil(state.blocking)
    }

    /// 重連快照：`GameSnapshot` 的欄位編號改對之後，手牌與點數要真的解得出來
    /// （舊對照 4=tiles/5=doras/6=scores/7=liqibang 沒有一個對）。
    func testGameSnapshotFieldsFollowSchema() {
        let (bridge, state) = makeBridge()
        authenticate(bridge)

        let snapshot = LiqiEncoder.encodeFields([
            .varint(field: 1, value: 1),     // chang
            .varint(field: 2, value: 2),     // ju
            .varint(field: 3, value: 3),     // ben
            .varint(field: 4, value: 0),     // index_player
            .varint(field: 5, value: 42),    // left_tile_count
            .string(field: 6, value: "1m"),  // hands
            .string(field: 6, value: "2m"),
            .string(field: 7, value: "3p"),  // doras
            .varint(field: 8, value: 1),     // liqibang
            .message(field: 9, fields: [.int(field: 1, value: 28000)]),
            .message(field: 9, fields: [.int(field: 1, value: 26000)]),
            .message(field: 9, fields: [.int(field: 1, value: 24000)]),
            .message(field: 9, fields: [.int(field: 1, value: 22000)])
        ])
        let payload = LiqiEncoder.encodeFields([
            .message(field: 4, fields: [.bytes(field: 1, value: snapshot)])
        ])

        let msgId: UInt16 = 77
        _ = bridge.parse(Data(LiqiEncoder.encodeRequest(method: ".lq.FastTest.syncGame",
                                                        fields: [], msgId: msgId)))
        let events = bridge.parse(Data(LiqiEncoder.encodeEnvelope(type: .response,
                                                                  msgId: msgId,
                                                                  method: "",
                                                                  payload: payload)))

        let startKyoku = events?.first { ($0["type"] as? String) == "start_kyoku" }
        XCTAssertNotNil(startKyoku, "重連後備路徑要發得出 start_kyoku")
        XCTAssertEqual(startKyoku?["scores"] as? [Int], [28000, 26000, 24000, 22000],
                       "點數在 players[].score（field 9 → PlayerSnapshot field 1）")
        XCTAssertEqual(startKyoku?["kyoku"] as? Int, 3)
        XCTAssertEqual(startKyoku?["kyotaku"] as? Int, 1)
        XCTAssertEqual(startKyoku?["dora_marker"] as? String, "3p")
        XCTAssertNil(state.blocking)
    }

    // MARK: - C. 不可容忍的失敗 → App 進入明確錯誤狀態

    /// 壞 frame（authGame 回應沒有 seat_list、也沒有 players）：
    /// 不發 start_game，且進入 blocking 狀態讓 UI 掛得出橫幅。
    func testAuthGameWithoutSeatListEntersBlockingState() {
        let (bridge, state) = makeBridge()

        _ = bridge.parse(authGameRequest(msgId: 51))
        let events = bridge.parse(authGameResponse(msgId: 51, fields: [
            .bool(field: 4, value: true)   // 只有 is_game_start
        ]))

        XCTAssertNil(events?.first { ($0["type"] as? String) == "start_game" },
                     "拿不到座位就不得建立 Bot")
        XCTAssertEqual(state.blocking?.site, "ResAuthGame.seat_list")
        XCTAssertEqual(state.blocking?.severity, .blocking)
        XCTAssertNotNil(state.bannerSummary, "UI 橫幅要有東西可顯示")
        XCTAssertEqual(state.statusPayload["liqiParseBlocked"] as? Bool, true)
    }

    /// accountId 不在 seatList 裡（座位判不出來）同樣是 blocking，不是靜默跳過。
    func testAccountIdMissingFromSeatListEntersBlockingState() {
        let (bridge, state) = makeBridge()

        _ = bridge.parse(authGameRequest(msgId: 52))
        let events = bridge.parse(authGameResponse(msgId: 52, fields: [
            .bytes(field: 3, value: packed([1, 2, 3, 4]))
        ]))

        XCTAssertNil(events?.first { ($0["type"] as? String) == "start_game" })
        XCTAssertEqual(state.blocking?.severity, .blocking)
    }

    /// 壞掉的 scores → 不發 start_kyoku（不拿假分數推論），並進入 blocking。
    func testNewRoundWithUnparsableScoresBlocksInsteadOfFakingThem() {
        let (bridge, state) = makeBridge()
        authenticate(bridge)

        let frame = actionPrototypeFrame(name: "ActionNewRound",
                                         data: newRoundPayload(scores: .bytes(field: 6, value: [0xff, 0xff])))
        let events = bridge.parse(frame)

        XCTAssertNil(events?.first { ($0["type"] as? String) == "start_kyoku" },
                     "拿不到起始點數就不得開局（假分數會讓 Mortal 的順位判斷整局是錯的）")
        XCTAssertEqual(state.blocking?.site, "ActionNewRound.scores")
        XCTAssertNotNil(state.bannerSummary)
    }

    /// blocking 是可恢復的：下一局解析成功就收掉橫幅（否則錯誤會永遠掛著）。
    func testBlockingStateClearsOnNextHealthyRound() {
        let (bridge, state) = makeBridge()
        authenticate(bridge)

        _ = bridge.parse(actionPrototypeFrame(name: "ActionNewRound",
                                              data: newRoundPayload(scores: .bytes(field: 6, value: [0xff]))))
        XCTAssertNotNil(state.blocking)

        _ = bridge.parse(actionPrototypeFrame(name: "ActionNewRound",
                                              data: newRoundPayload(scores: .bytes(field: 6,
                                                                                   value: packed([25000, 25000, 25000, 25000])))))
        XCTAssertNil(state.blocking, "解析恢復正常後橫幅要消失")
        XCTAssertFalse(state.recent.isEmpty, "但曾經失敗過要查得到")
    }

    /// p5 #4：authGame 失敗（座位缺、Bot 沒建）留下的 blocking，**不該**被一個
    /// 分數合法的 ActionNewRound 清掉——否則橫幅消失、宣告恢復，但 Bot 根本不存在。
    func testAuthGameBlockingSurvivesAHealthyNewRound() {
        let (bridge, state) = makeBridge()

        // authGame 拿不到座位 → blocking（Bot 沒建）
        _ = bridge.parse(authGameRequest(msgId: 71))
        _ = bridge.parse(authGameResponse(msgId: 71, fields: [.bool(field: 4, value: true)]))
        XCTAssertEqual(state.blocking?.site, "ResAuthGame.seat_list")

        // 之後來一個分數完全正常的 ActionNewRound
        _ = bridge.parse(actionPrototypeFrame(name: "ActionNewRound",
                                              data: newRoundPayload(scores: .bytes(field: 6,
                                                                                   value: packed([25000, 25000, 25000, 25000])))))

        // 座位那個前提還沒解決，橫幅必須留著
        XCTAssertEqual(state.blocking?.site, "ResAuthGame.seat_list",
                       "start_kyoku 的成功不代表 authGame／座位好了；Bot 仍不存在，橫幅不能消失")
    }

    /// 對照：scores 造成的 blocking 由後續健康的 NewRound 清掉（同前提才清）。
    func testScoresBlockingIsClearedByHealthyNewRound() {
        let state = LiqiParseFaultState()
        state.record(LiqiParseFault(site: "ActionNewRound.scores", byteCount: 2,
                                    reason: "packed int32 解不出來", severity: .blocking))
        state.clearBlocking(matchingSitePrefixes: ["ActionNewRound", "GameSnapshot"])
        XCTAssertNil(state.blocking, "同前提（start_kyoku）恢復就該清")

        // 但 authGame 前綴的清除指令不會動到它（若它是 authGame 造成的）
        state.record(LiqiParseFault(site: "ResAuthGame.seat_list", byteCount: 0,
                                    reason: "沒有 seatList", severity: .blocking))
        state.clearBlocking(matchingSitePrefixes: ["ActionNewRound", "GameSnapshot"])
        XCTAssertNotNil(state.blocking, "不同前提的清除指令不該動到它")
        state.clearBlocking(matchingSitePrefixes: ["ResAuthGame"])
        XCTAssertNil(state.blocking, "對應前提的清除才生效")
    }

    /// p5 #4（Codex 復核）：A（authGame）失敗 → B（scores）也失敗 → B 恢復，
    /// A 的前提從未恢復，橫幅不能消失。單一 slot 會被 B 蓋掉再被清空 → 漏掉 A。
    func testMultiplePrerequisitesTrackedIndependently() {
        let state = LiqiParseFaultState()

        // A：座位缺（Bot 沒建）
        state.record(LiqiParseFault(site: "ResAuthGame.seat_list", byteCount: 0,
                                    reason: "沒有 seatList", severity: .blocking))
        // B：接著 scores 也壞
        state.record(LiqiParseFault(site: "ActionNewRound.scores", byteCount: 2,
                                    reason: "解不出來", severity: .blocking))
        XCTAssertNotNil(state.blocking, "兩個前提都失敗，當然 blocking")

        // B 恢復（健康 NewRound）→ 只清 round domain
        state.clearBlocking(matchingSitePrefixes: ["ActionNewRound", "GameSnapshot"])
        XCTAssertEqual(state.blocking?.site, "ResAuthGame.seat_list",
                       "B 恢復不代表 A（座位／Bot）恢復——橫幅必須留著 A")
        XCTAssertEqual(state.statusPayload["liqiParseBlocked"] as? Bool, true)

        // A 也恢復 → 這時才真的沒有 blocking
        state.clearBlocking(matchingSitePrefixes: ["ResAuthGame"])
        XCTAssertNil(state.blocking)
    }

    // MARK: - D. 保留的 heuristic 必須標記信心

    /// 沒有 seat_list 時可以用 players 的順序頂替，但**必須標成 heuristic**。
    func testSeatListFromPlayersIsMarkedHeuristic() {
        let (bridge, state) = makeBridge()

        _ = bridge.parse(authGameRequest(msgId: 61))
        let raw = bridge.parseRaw(authGameResponse(msgId: 61,
                                                   fields: playerFields([accountId, 2, 3, 4])))
        let data = raw?["data"] as? [String: Any]

        XCTAssertEqual(data?["seatList"] as? [Int], [accountId, 2, 3, 4])
        XCTAssertEqual(data?["seatListConfidence"] as? String,
                       LiqiParseConfidence.heuristic.rawValue,
                       "猜出來的座位不得混充 exact")
        XCTAssertTrue(state.recent.contains { $0.site == "ResAuthGame.seat_list" },
                      "heuristic 要在 log/狀態裡查得到")
        XCTAssertNil(state.blocking, "有座位可用就不是 blocking")
    }

    /// 有 seat_list 時要標 exact（否則「查出來的」與「猜出來的」又混在一起）。
    func testSeatListFromSchemaIsMarkedExact() {
        let (bridge, _) = makeBridge()

        _ = bridge.parse(authGameRequest(msgId: 62))
        let raw = bridge.parseRaw(authGameResponse(msgId: 62, fields: [
            .bytes(field: 3, value: packed([accountId, 2, 3, 4]))
        ] + playerFields([accountId, 2, 3, 4])))
        let data = raw?["data"] as? [String: Any]

        XCTAssertEqual(data?["seatListConfidence"] as? String,
                       LiqiParseConfidence.exact.rawValue)
    }

    // MARK: - 狀態容器

    func testFaultStateKeepsRecentAndReports() {
        let state = LiqiParseFaultState()
        XCTAssertNil(state.bannerSummary)

        for i in 0..<(LiqiParseFaultState.historyLimit + 5) {
            state.record(LiqiParseFault(site: "X.\(i)", byteCount: i, reason: "r"))
        }

        XCTAssertEqual(state.recent.count, LiqiParseFaultState.historyLimit, "近期清單要有上限")
        XCTAssertEqual(state.totalCount, LiqiParseFaultState.historyLimit + 5, "但總數不截斷")
        XCTAssertNil(state.bannerSummary, "degraded 不掛橫幅")

        state.record(LiqiParseFault(site: "ResAuthGame.seat_list", fieldId: 3,
                                    byteCount: 0, reason: "沒有座位", severity: .blocking))
        XCTAssertNotNil(state.bannerSummary)
        XCTAssertTrue(state.bannerSummary?.contains("field 3") ?? false, "橫幅要帶得出欄位編號")

        state.reset()
        XCTAssertNil(state.blocking)
        XCTAssertEqual(state.totalCount, 0)
    }

    // MARK: - E. 索引用的欄位必須先驗範圍

    /// `chang` 會直接拿去索引 `BAKAZE_NAMES`（4 個元素）。
    ///
    /// 它是沒有上界的 parsed varint，而 Swift 的陣列越界是 **trap**：不是可捕捉的
    /// 錯誤，是整個 App 當場結束——連 fault 都記不下來，log 裡什麼都沒有。
    /// 所以範圍檢查必須在索引之前，而且失敗要走既有的 blocking 路徑。
    func testOutOfRangeChangBlocksInsteadOfIndexingOutOfBounds() {
        let (bridge, state) = makeBridge()
        authenticate(bridge)

        let payload = LiqiEncoder.encodeFields([
            .varint(field: 1, value: 7),        // chang：合法只有 0..<4
            .varint(field: 2, value: 0),
            .varint(field: 3, value: 0),
            .bytes(field: 6, value: packed([25000, 25000, 25000, 25000])),
            .varint(field: 8, value: 0)
        ])
        let events = bridge.parse(actionPrototypeFrame(name: "ActionNewRound", data: payload))

        XCTAssertNil(events?.first { ($0["type"] as? String) == "start_kyoku" },
                     "chang 超出範圍不得開這一局")
        XCTAssertEqual(state.blocking?.site, "ActionNewRound.chang/ju")
        XCTAssertNotNil(state.bannerSummary, "使用者要看得到這一局為什麼沒有推薦")
    }

    /// `ju` 同理：它會變成 `oya` 與 `kyoku` 進 MJAI 事件流。
    func testOutOfRangeJuBlocksTheRound() {
        let (bridge, state) = makeBridge()
        authenticate(bridge)

        let payload = LiqiEncoder.encodeFields([
            .varint(field: 1, value: 0),
            .varint(field: 2, value: 9),        // ju
            .varint(field: 3, value: 0),
            .bytes(field: 6, value: packed([25000, 25000, 25000, 25000])),
            .varint(field: 8, value: 0)
        ])
        let events = bridge.parse(actionPrototypeFrame(name: "ActionNewRound", data: payload))

        XCTAssertNil(events?.first { ($0["type"] as? String) == "start_kyoku" })
        XCTAssertEqual(state.blocking?.site, "ActionNewRound.chang/ju")
    }

    /// action 的 `seat` 會原樣變成 MJAI 的 `actor`，而下游 MortalSwift 拿它算
    /// `(seat - playerId + 4) % 4` 之後直接索引固定 4 格的 `kawa`。
    ///
    /// 範圍外的正值不會崩——會被 `% 4` 折回去，把別人的動作**靜默記到自己頭上**，
    /// 污染 observation 而且畫面上完全看不出來。那比丟掉一個事件糟得多。
    func testOutOfRangeSeatDropsTheEventAndRecordsDegradedFault() {
        let (bridge, state) = makeBridge()
        authenticate(bridge)

        _ = bridge.parse(actionPrototypeFrame(
            name: "ActionNewRound",
            data: newRoundPayload(scores: .bytes(field: 6,
                                                 value: packed([25000, 25000, 25000, 25000])))))

        let payload = LiqiEncoder.encodeFields([
            .varint(field: 1, value: 9),        // seat：四麻合法只有 0..<4
            .string(field: 2, value: "1m")
        ])
        let events = bridge.parse(actionPrototypeFrame(name: "ActionDealTile", data: payload))

        XCTAssertNil(events?.first { ($0["type"] as? String) == "tsumo" },
                     "座位超出範圍的摸牌事件必須被丟棄，不能原樣送進事件流")
        XCTAssertGreaterThan(state.totalCount, 0, "丟棄要留下可查的記錄，不能靜默")
        XCTAssertNil(state.blocking, "丟一個事件是 degraded，不該讓整局停擺")
    }

    /// 未知的 action 不得靜默丟棄。
    ///
    /// 這裡曾經是整套 `LiqiParseFault` 機制唯一逃得掉的路徑（`default: break`）。
    /// `liqi.json` 有 24 個 `Action*` 而 bridge 處理 9 個，沒處理的多屬活動場——
    /// 而活動場正是雀魂最常改動的部分。靜默丟棄的表象只是「某個情況下不給推薦」，
    /// log 裡一個字都沒有。
    func testUnknownActionIsRecordedInsteadOfSilentlyDropped() {
        let (bridge, state) = makeBridge()
        authenticate(bridge)

        let payload = LiqiEncoder.encodeFields([.varint(field: 1, value: 0)])
        _ = bridge.parse(actionPrototypeFrame(name: "ActionSelectGap", data: payload))

        XCTAssertGreaterThan(state.totalCount, 0, "未知 action 必須留下記錄")
        XCTAssertNil(state.blocking,
                     "多數未知 action 與牌局進行無關，擋掉整局太重——degraded 就好")
    }

    /// 同一個未知 action 只記一次，否則每局都會洗版。
    func testUnknownActionIsReportedOnlyOnce() {
        let (bridge, state) = makeBridge()
        authenticate(bridge)

        let payload = LiqiEncoder.encodeFields([.varint(field: 1, value: 0)])
        for _ in 0..<5 {
            _ = bridge.parse(actionPrototypeFrame(name: "ActionSelectGap", data: payload))
        }
        let afterSameAction = state.totalCount

        _ = bridge.parse(actionPrototypeFrame(name: "ActionUnveilTile", data: payload))
        XCTAssertGreaterThan(state.totalCount, afterSameAction,
                             "不同的未知 action 要各記一次")
    }

    // MARK: - F. 產出層：MJAI 事件的欄位正確性

    /// 鳴牌的 `target` 必須指向**放銃者**，不是自己。
    ///
    /// `MajsoulBridge` 是 959 行的 Liqi→MJAI 核心，而它產出的事件是否正確
    /// 幾乎沒有直接測試——唯一接近的 `ReplayFingerprintTests` 驗的是決策指紋
    /// （整條鏈的雜湊），指紋對不上時看不出是哪個欄位錯了。
    ///
    /// Akagi #69 就是這個欄位錯成 `target == actor`。
    func testPonTargetPointsAtDiscarderNotSelf() {
        let (bridge, _) = makeBridge()
        authenticate(bridge)
        _ = bridge.parse(actionPrototypeFrame(
            name: "ActionNewRound",
            data: newRoundPayload(scores: .bytes(field: 6,
                                                 value: packed([25000, 25000, 25000, 25000])))))

        // 座位 2 碰座位 1 打出的牌（liqi ActionChiPengGang：
        // 1=seat, 2=type, 3=tiles, 4=froms）
        let payload = LiqiEncoder.encodeFields([
            .varint(field: 1, value: 2),
            .varint(field: 2, value: 1),           // 1 = pon
            .string(field: 3, value: "3m"),
            .string(field: 3, value: "3m"),
            .string(field: 3, value: "3m"),
            .bytes(field: 4, value: packed([2, 2, 1]))   // 前兩張自己的，第三張來自座位 1
        ])
        let events = bridge.parse(actionPrototypeFrame(name: "ActionChiPengGang", data: payload))

        let pon = events?.first { ($0["type"] as? String) == "pon" }
        XCTAssertNotNil(pon, "應產生 pon 事件")
        XCTAssertEqual(pon?["actor"] as? Int, 2)
        XCTAssertEqual(pon?["target"] as? Int, 1,
                       "target 要指向放銃者；等於 actor 就是 Akagi #69 那個 bug")
        XCTAssertEqual(pon?["pai"] as? String, "3m", "pai 是被鳴的那一張")
        XCTAssertEqual((pon?["consumed"] as? [String])?.count, 2,
                       "consumed 是自己手上的兩張")
    }

    /// 摸牌與打牌的 actor 要如實反映座位，不得被折回自己。
    func testDealAndDiscardCarryCorrectActor() {
        let (bridge, _) = makeBridge()
        authenticate(bridge)
        _ = bridge.parse(actionPrototypeFrame(
            name: "ActionNewRound",
            data: newRoundPayload(scores: .bytes(field: 6,
                                                 value: packed([25000, 25000, 25000, 25000])))))

        let discard = LiqiEncoder.encodeFields([
            .varint(field: 1, value: 3),
            .string(field: 2, value: "7p")
        ])
        let events = bridge.parse(actionPrototypeFrame(name: "ActionDiscardTile", data: discard))

        let dahai = events?.first { ($0["type"] as? String) == "dahai" }
        XCTAssertEqual(dahai?["actor"] as? Int, 3)
        XCTAssertEqual(dahai?["pai"] as? String, "7p")
    }
}
