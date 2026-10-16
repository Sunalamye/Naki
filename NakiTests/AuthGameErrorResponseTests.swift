//
//  AuthGameErrorResponseTests.swift
//  NakiTests
//
//  伺服器拒絕 authGame（ResAuthGame.error）不是協定漂移：不得掛 blocking fault。
//

import XCTest

@testable import Naki

@MainActor
final class AuthGameErrorResponseTests: XCTestCase {

    private let accountId = 123456
    private let msgId: UInt16 = 41

    private func authGameResponse(_ fields: [LiqiField]) -> Data {
        Data(LiqiEncoder.encodeEnvelope(type: .response, msgId: msgId, method: "",
                                        payload: LiqiEncoder.encodeFields(fields)))
    }

    /// 回傳 authGame 回應的解析結果、bridge 事件與失敗狀態
    private func feed(_ fields: [LiqiField]) -> (parsed: [String: Any], events: [[String: Any]]?, state: LiqiParseFaultState) {
        let request = Data(LiqiEncoder.encodeRequest(
            method: ".lq.FastTest.authGame",
            fields: [.varint(field: 1, value: UInt64(accountId)), .string(field: 2, value: "token"), .string(field: 3, value: "uuid")],
            msgId: msgId))
        let loginRequest = Data(LiqiEncoder.encodeRequest(method: ".lq.Lobby.oauth2Login", fields: [], msgId: 1))
        let login = Data(LiqiEncoder.encodeEnvelope(type: .response, msgId: 1, method: "",
                                                    payload: LiqiEncoder.encodeFields([.varint(field: 2, value: UInt64(accountId))])))
        let response = authGameResponse(fields)

        let parser = LiqiParser()
        _ = parser.parse(loginRequest)
        _ = parser.parse(login)
        _ = parser.parse(request)
        let parsed = (parser.parse(response)?["data"] as? [String: Any]) ?? [:]

        let state = LiqiParseFaultState()
        let bridge = MajsoulBridge(faultState: state, operations: LiqiOperationStore())
        _ = bridge.observeOutgoing(loginRequest)
        _ = bridge.parse(login)
        _ = bridge.observeOutgoing(request)
        return (parsed, bridge.parse(response), state)
    }

    func testServerRejectionIsNotAProtocolFault() {
        let error: LiqiField = .message(field: 1, fields: [.varint(field: 1, value: 1203)])
        let (parsed, events, state) = feed([error])

        XCTAssertEqual(parsed["error"] as? Int, 1203)
        XCTAssertFalse((events ?? []).contains { $0["type"] as? String == "start_game" })
        XCTAssertNil(state.blocking)
        XCTAssertFalse(state.recent.contains { $0.site == "ResAuthGame.seat_list" })
    }

    func testMissingSeatListWithoutErrorStillBlocks() {
        let (parsed, events, state) = feed([])

        XCTAssertNil(parsed["error"])
        XCTAssertFalse((events ?? []).contains { $0["type"] as? String == "start_game" })
        XCTAssertEqual(state.blocking?.site, "ResAuthGame.seat_list")
    }

    func testValidSeatListStillStartsGame() {
        let seats = [2, 3, accountId, 4].flatMap { LiqiEncoder.encodeVarint(UInt64($0)) }
        let (parsed, events, state) = feed([.bytes(field: 3, value: seats)])

        XCTAssertNil(parsed["error"])
        XCTAssertEqual((events ?? []).filter { $0["type"] as? String == "start_game" }.count, 1)
        XCTAssertNil(state.blocking)
    }

    func testErrorTogetherWithSeatListStillStartsGame() {
        let seats = [2, 3, accountId, 4].flatMap { LiqiEncoder.encodeVarint(UInt64($0)) }
        let (parsed, events, state) = feed([.message(field: 1, fields: [.varint(field: 1, value: 1203)]),
                                            .bytes(field: 3, value: seats)])

        XCTAssertEqual(parsed["error"] as? Int, 1203)
        XCTAssertEqual((events ?? []).filter { $0["type"] as? String == "start_game" }.count, 1)
        XCTAssertNil(state.blocking)
    }

    /// 空的 `error {}`（bytes `0a 00`）沒有 seatList：視為被拒絕，不是漂移
    func testEmptyErrorWithoutSeatListIsRejection() {
        let (parsed, events, state) = feed([.bytes(field: 1, value: [])])

        XCTAssertEqual(parsed["error"] as? Int, 0)
        XCTAssertFalse((events ?? []).contains { $0["type"] as? String == "start_game" })
        XCTAssertNil(state.blocking)
        XCTAssertFalse(state.recent.contains { $0.site == "ResAuthGame.seat_list" })
    }
}
