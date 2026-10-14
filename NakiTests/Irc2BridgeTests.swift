//
//  Irc2BridgeTests.swift
//  NakiTests
//
//  IRC 第二輪 Bridge 修正（BR-03／04／05／07／08／09）的回歸鎖。
//

import XCTest

@testable import Naki

@MainActor
final class Irc2BridgeTests: XCTestCase {

    private let accountId = 123456
    private static let ownSeat = 2
    private static let hand13 = ["1m", "2m", "3m", "4m", "6m", "7m", "8m", "9m", "1p", "2p", "3p", "4p", "5s"]

    // MARK: - Frames

    private func packed(_ values: [Int]) -> [UInt8] {
        values.flatMap { LiqiEncoder.encodeVarint(UInt64($0)) }
    }

    private func response(msgId: UInt16, fields: [LiqiField]) -> Data {
        Data(LiqiEncoder.encodeEnvelope(type: .response, msgId: msgId, method: "",
                                        payload: LiqiEncoder.encodeFields(fields)))
    }

    private func authGameRequest(msgId: UInt16) -> Data {
        Data(LiqiEncoder.encodeRequest(
            method: ".lq.FastTest.authGame",
            fields: [.varint(field: 1, value: UInt64(accountId)), .string(field: 2, value: "token"),
                     .string(field: 3, value: "game-uuid")],
            msgId: msgId))
    }

    private func prototype(_ name: String, _ fields: [LiqiField]) -> Data {
        var out: [UInt8] = [LiqiMsgType.notify.rawValue]
        out += LiqiEncoder.encodeStringField(field: 1, value: ".lq.ActionPrototype")
        let proto = LiqiEncoder.encodeFields([
            .varint(field: 1, value: 7), .string(field: 2, value: name),
            .bytes(field: 3, value: Array(liqiDecode(Data(LiqiEncoder.encodeFields(fields)))))
        ])
        out += LiqiEncoder.encodeLengthDelimited(field: 2, bytes: proto)
        return Data(out)
    }

    private func newRound(dora: String? = nil, doras: [String] = []) -> Data {
        var fields: [LiqiField] = [.varint(field: 1, value: 0), .varint(field: 2, value: 0), .varint(field: 3, value: 0)]
        fields += Self.hand13.map { .string(field: 4, value: $0) }
        if let dora { fields.append(.string(field: 5, value: dora)) }
        fields.append(.bytes(field: 6, value: packed([25000, 25000, 25000, 25000])))
        fields.append(.varint(field: 8, value: 0))
        fields += doras.map { .string(field: 14, value: $0) }
        return prototype("ActionNewRound", fields)
    }

    private func discard(seat: Int, tile: String, doras: [String] = []) -> Data {
        prototype("ActionDiscardTile", [.varint(field: 1, value: UInt64(seat)), .string(field: 2, value: tile)]
                  + doras.map { .string(field: 8, value: $0) })
    }

    private func pon(seat: Int, tiles: [String], froms: [Int]) -> Data {
        prototype("ActionChiPengGang", [.varint(field: 1, value: UInt64(seat)), .varint(field: 2, value: 1)]
                  + tiles.map { .string(field: 3, value: $0) } + [.bytes(field: 4, value: packed(froms))])
    }

    private func kakan(seat: Int, tile: String) -> Data {
        prototype("ActionAnGangAddGang",
                  [.varint(field: 1, value: UInt64(seat)), .varint(field: 2, value: 2), .string(field: 3, value: tile)])
    }

    private func startedBridge() -> MajsoulBridge {
        let bridge = MajsoulBridge(faultState: LiqiParseFaultState(), operations: LiqiOperationStore())
        _ = bridge.observeOutgoing(Data(LiqiEncoder.encodeRequest(method: ".lq.Lobby.oauth2Login", fields: [], msgId: 1)))
        _ = bridge.parse(response(msgId: 1, fields: [.varint(field: 2, value: UInt64(accountId))]))
        _ = bridge.observeOutgoing(authGameRequest(msgId: 41))
        _ = bridge.parse(response(msgId: 41, fields: [.bytes(field: 3, value: packed([3, 4, accountId, 5]))]))
        return bridge
    }

    private func doraMarkers(_ events: [[String: Any]]?) -> [String] {
        (events ?? []).filter { $0["type"] as? String == "dora" }.compactMap { $0["dora_marker"] as? String }
    }

    // MARK: - BR-03

    func testNewRoundWithBothDoraAndDorasKeepsNextKanDora() {
        let bridge = startedBridge()
        _ = bridge.parse(newRound(dora: "3p", doras: ["3p"]))

        let events = bridge.parse(discard(seat: 1, tile: "5p", doras: ["3p", "4p"]))

        XCTAssertEqual(doraMarkers(events), ["4p"], "field 5 與 field 14 並存時首張只算一次")
    }

    func testNewRoundWithOnlySingularDoraStillSeedsDoraList() {
        let bridge = startedBridge()
        let start = bridge.parse(newRound(dora: "3p"))
        XCTAssertEqual(start?.first?["dora_marker"] as? String, "3p")

        let events = bridge.parse(discard(seat: 1, tile: "5p", doras: ["3p", "4p"]))

        XCTAssertEqual(doraMarkers(events), ["4p"])
    }

    func testInvalidFirstDoraResetsPreviousRoundKanDoraCount() {
        let bridge = startedBridge()
        _ = bridge.parse(newRound(doras: ["1m"]))
        XCTAssertEqual(doraMarkers(bridge.parse(discard(seat: 1, tile: "5p", doras: ["1m", "2m", "3m"]))), ["2m", "3m"])

        let start = bridge.parse(newRound(doras: ["8z"]))
        XCTAssertEqual(start?.first?["type"] as? String, "start_kyoku", "測試前提：首張非法仍開局")
        let events = bridge.parse(discard(seat: 1, tile: "5p", doras: ["8z", "4p"]))

        XCTAssertEqual(doraMarkers(events), ["4p"], "上一局累積的 3 張不得讓這局的槓寶牌被吞掉")
    }

    func testNewRoundWithoutAnyDoraResetsPreviousRoundKanDoraCount() {
        let bridge = startedBridge()
        _ = bridge.parse(newRound(doras: ["1m"]))
        XCTAssertEqual(doraMarkers(bridge.parse(discard(seat: 1, tile: "5p", doras: ["1m", "2m", "3m"]))), ["2m", "3m"])

        _ = bridge.parse(newRound())
        let events = bridge.parse(discard(seat: 1, tile: "5p", doras: ["4p"]))

        XCTAssertEqual(doraMarkers(events), ["4p"], "新局沒帶任何寶牌時也要清掉上一局的清單")
    }

    func testNewRoundWithConflictingDoraAndDorasUsesDoras() {
        let bridge = startedBridge()

        let start = bridge.parse(newRound(dora: "3p", doras: ["5p"]))

        XCTAssertEqual(start?.first?["dora_marker"] as? String, "5p", "field 14（doras）為準")
    }

    // MARK: - BR-04

    func testAuthGameRequestParsedDataHasNoCredentials() {
        let bridge = MajsoulBridge(faultState: LiqiParseFaultState(), operations: LiqiOperationStore())

        _ = bridge.observeOutgoing(authGameRequest(msgId: 41))

        let data = bridge.lastParsed?["data"] as? [String: Any] ?? [:]
        XCTAssertNil(data["token"], "session token 不得留在 lastParsed")
        XCTAssertNil(data["accountId"], "ReqAuthGame.account_id 沒有讀取端，不解析")
        XCTAssertEqual(data["gameUuid"] as? String, "game-uuid")
    }

    // MARK: - BR-05

    func testSyncGameReplayOfOwnActionsDoesNotCountAsEcho() {
        let bridge = startedBridge()
        _ = bridge.parse(newRound())
        let restore: [LiqiField] = [.message(field: 2, fields: [
            .varint(field: 1, value: 1), .string(field: 2, value: "ActionDiscardTile"),
            .bytes(field: 3, value: LiqiEncoder.encodeFields([
                .varint(field: 1, value: UInt64(Self.ownSeat)), .string(field: 2, value: "5p")]))])]
        let before = SelfActionEchoTracker.shared.count

        _ = bridge.observeOutgoing(Data(LiqiEncoder.encodeRequest(method: ".lq.FastTest.syncGame", fields: [], msgId: 120)))
        let events = bridge.parse(response(msgId: 120, fields: [.message(field: 4, fields: restore)]))

        XCTAssertEqual(events?.last?["type"] as? String, "dahai", "測試前提：歷史動作照常轉成事件")
        XCTAssertEqual(SelfActionEchoTracker.shared.count, before, "重放的歷史自家動作不是伺服器對這次送出的回音")

        _ = bridge.parse(discard(seat: Self.ownSeat, tile: "6p"))
        XCTAssertEqual(SelfActionEchoTracker.shared.count, before + 1, "重放結束後的即時動作照常計數")
    }

    // MARK: - BR-07

    private func kakanConsumed(ponTiles: [String], froms: [Int], kakanTile: String) -> [String]? {
        let bridge = startedBridge()
        _ = bridge.parse(newRound())
        _ = bridge.parse(pon(seat: 1, tiles: ponTiles, froms: froms))
        let events = bridge.parse(kakan(seat: 1, tile: kakanTile))
        return events?.first { $0["type"] as? String == "kakan" }?["consumed"] as? [String]
    }

    func testKakanConsumedComesFromRecordedPonWithoutRedFive() {
        let consumed = kakanConsumed(ponTiles: ["5m", "5m", "5m"], froms: [1, 1, 0], kakanTile: "5m")
        XCTAssertEqual(consumed, ["5m", "5m", "5m"], "原碰沒有赤五就不得推定有")
    }

    func testKakanConsumedKeepsRedFiveOfRecordedPon() {
        let consumed = kakanConsumed(ponTiles: ["0m", "5m", "5m"], froms: [1, 1, 0], kakanTile: "5m")
        XCTAssertEqual(consumed?.sorted(), ["5m", "5m", "5mr"])
    }

    func testKakanOfRedFiveAfterPlainPonKeepsPlainConsumed() {
        let consumed = kakanConsumed(ponTiles: ["5p", "5p", "5p"], froms: [1, 1, 0], kakanTile: "0p")
        XCTAssertEqual(consumed, ["5p", "5p", "5p"])
    }

    func testKakanUsesThePonOfTheSameActorAndTile() {
        let bridge = startedBridge()
        _ = bridge.parse(newRound())
        _ = bridge.parse(pon(seat: 0, tiles: ["0m", "5m", "5m"], froms: [0, 0, 3]))
        _ = bridge.parse(pon(seat: 1, tiles: ["5m", "5m", "5m"], froms: [1, 1, 0]))

        let events = bridge.parse(kakan(seat: 1, tile: "5m"))

        XCTAssertEqual(events?.first?["consumed"] as? [String], ["5m", "5m", "5m"])
    }

    func testKakanWithoutRecordedPonFallsBackToInference() {
        let bridge = startedBridge()
        _ = bridge.parse(newRound())

        let events = bridge.parse(kakan(seat: 1, tile: "5m"))

        XCTAssertEqual(events?.first?["consumed"] as? [String], ["5mr", "5m", "5m"], "沒有碰紀錄（例如重連）維持舊推定")
    }

    func testKakanAfterPonWithoutFromsFallsBackToInference() {
        let bridge = startedBridge()
        _ = bridge.parse(newRound())
        let ponEvents = bridge.parse(prototype("ActionChiPengGang", [
            .varint(field: 1, value: 1), .varint(field: 2, value: 1),
            .string(field: 3, value: "0m"), .string(field: 3, value: "5m"), .string(field: 3, value: "5m")]))
        XCTAssertEqual(ponEvents?.first { $0["type"] as? String == "pon" }?["consumed"] as? [String], ["5mr", "5mr"],
                       "測試前提：froms 缺席時碰被記成重複赤五")

        let events = bridge.parse(kakan(seat: 1, tile: "5m"))

        XCTAssertEqual(events?.first { $0["type"] as? String == "kakan" }?["consumed"] as? [String], inferred)
    }

    private func snapshotSync(_ bridge: MajsoulBridge) {
        let snapshot = LiqiEncoder.encodeFields(
            [.varint(field: 1, value: 0), .varint(field: 2, value: 0)]
            + Self.hand13.map { .string(field: 6, value: $0) }
            + (0..<4).map { _ in .message(field: 9, fields: [.int(field: 1, value: 25000)]) })
        _ = bridge.observeOutgoing(Data(LiqiEncoder.encodeRequest(method: ".lq.FastTest.syncGame", fields: [], msgId: 121)))
        _ = bridge.parse(response(msgId: 121, fields: [.message(field: 4, fields: [.bytes(field: 1, value: snapshot)])]))
    }

    private func staleKakanConsumed(afterPonBy seat: Int = 1, _ clear: (MajsoulBridge) -> Void) -> [String]? {
        let bridge = startedBridge()
        _ = bridge.parse(newRound())
        _ = bridge.parse(pon(seat: seat, tiles: ["5m", "5m", "5m"], froms: [1, 1, 0]))
        clear(bridge)
        let events = bridge.parse(kakan(seat: seat, tile: "5m"))
        return events?.first { $0["type"] as? String == "kakan" }?["consumed"] as? [String]
    }

    private let inferred = ["5mr", "5m", "5m"]

    func testKakanConsumesTheRecordedPonOnlyOnce() {
        let consumed = staleKakanConsumed { bridge in _ = bridge.parse(self.kakan(seat: 1, tile: "5m")) }

        XCTAssertEqual(consumed, inferred, "原碰已被上一次加槓用掉，不得再被查到")
    }

    func testNewRoundClearsRecordedPons() {
        XCTAssertEqual(staleKakanConsumed { _ = $0.parse(self.newRound()) }, inferred)
    }

    func testResetClearsRecordedPons() {
        XCTAssertEqual(staleKakanConsumed { $0.reset() }, inferred)
    }

    func testSnapshotRestartClearsRecordedPons() {
        XCTAssertEqual(staleKakanConsumed { self.snapshotSync($0) }, inferred)
    }

    func testSnapshotWithoutDorasResetsPreviousKanDoraCount() {
        let bridge = startedBridge()
        _ = bridge.parse(newRound(doras: ["1m"]))
        XCTAssertEqual(doraMarkers(bridge.parse(discard(seat: 1, tile: "5p", doras: ["1m", "2m", "3m"]))), ["2m", "3m"])

        snapshotSync(bridge)
        let events = bridge.parse(discard(seat: 1, tile: "5p", doras: ["4p"]))

        XCTAssertEqual(doraMarkers(events), ["4p"], "快照沒帶寶牌時不得沿用上一局的清單")
    }

    // MARK: - BR-08

    func testFailedSendRevokesMsgIdRegistration() async {
        let sender = LiqiActionSender()
        sender.sendHandler = { _ in .failure("no_open_majsoul_connection") }

        let failed = await sender.send(LiqiRequestBuilder.pon())

        XCTAssertFalse(failed.success)
        XCTAssertFalse(LiqiMsgIdAllocator.shared.isIssued(failed.msgId))
    }

    func testMissingSendHandlerRevokesMsgIdRegistration() async {
        let result = await LiqiActionSender().send(LiqiRequestBuilder.pon())

        XCTAssertEqual(result.detail, "no_send_handler")
        XCTAssertFalse(LiqiMsgIdAllocator.shared.isIssued(result.msgId))
    }

    func testSuccessfulSendKeepsMsgIdRegistration() async {
        let sender = LiqiActionSender()
        sender.sendHandler = { _ in LiqiRawSendResult(success: true, detail: nil) }

        let result = await sender.send(LiqiRequestBuilder.pon())

        XCTAssertTrue(LiqiMsgIdAllocator.shared.isIssued(result.msgId))
        _ = LiqiMsgIdAllocator.shared.claim(result.msgId)
    }

    func testDefiniteFailuresRevokeMsgIdRegistration() async {
        for detail in ["no_game_gateway_connection", "invalid_base64", "decode_failed: x", "empty_payload", "send_failed: y"] {
            let sender = LiqiActionSender()
            sender.sendHandler = { _ in .failure(detail) }

            let result = await sender.send(LiqiRequestBuilder.pon())

            XCTAssertFalse(LiqiMsgIdAllocator.shared.isIssued(result.msgId), detail)
        }
    }

    func testAmbiguousFailuresKeepMsgIdRegistration() async {
        for detail in ["js_error: boom", "unparsable_js_result", "runtime_deallocated"] {
            let sender = LiqiActionSender()
            sender.sendHandler = { _ in .failure(detail) }

            let result = await sender.send(LiqiRequestBuilder.pon())

            XCTAssertTrue(LiqiMsgIdAllocator.shared.isIssued(result.msgId), "\(detail)：JS 可能已送出，不得撤銷")
            _ = LiqiMsgIdAllocator.shared.claim(result.msgId)
        }
    }

    // MARK: - BR-09

    func testRecordedStartGameUsesCloudPlaceholderNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("irc2-recorder-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let recorder = GameRecorder(directory: dir)
        let event: [String: Any] = ["type": "start_game", "id": 2, "is3P": false,
                                    "names": ["NickA", "NickB", "NickC", "NickD"]]

        recorder.startGame()
        recorder.record(event)
        recorder.record(["type": "end_game"])
        let url = try XCTUnwrap(recorder.finishGame())

        let recorded = try XCTUnwrap(GameRecorder.load(url).first)
        let cloud = KyokuStreamAccumulator.apiEvent(event, is3P: false)
        XCTAssertEqual(recorded["names"] as? [String], cloud["names"] as? [String])
        XCTAssertEqual(recorded["names"] as? [String], ["Player0", "Player1", "Player2", "Player3"])
        XCTAssertEqual(recorded["id"] as? Int, 2, "座位與三麻旗標照舊，replay 要用")
        XCTAssertEqual(recorded["is3P"] as? Bool, false)
        XCTAssertFalse(String(data: try Data(contentsOf: url), encoding: .utf8)!.contains("Nick"))
    }
}
