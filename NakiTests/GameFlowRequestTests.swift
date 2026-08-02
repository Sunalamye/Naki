//
//  GameFlowRequestTests.swift
//  NakiTests
//
//  p2-5：局間確認 / 清除離開 / 投票結束的 request 位元組對拍，以及局間確認的閘門。
//
//  這些 request 都是 `.lq.FastTest.*`（走 game-gateway）。confirmNewRound / clearLeaving
//  是 `ReqCommon`（空 payload），voteGameEnd 是 `ReqVoteGameEnd { yes }`——**不是** task
//  表寫的 ReqCommon，以 docs/protocol/liqi.json 為準。
//
//  ⚠️ 驗證的是「編碼正確」，不是「伺服器會接受」；後者需 live 對局（未驗證）。
//

import XCTest

@testable import Naki

final class GameFlowRequestTests: XCTestCase {

    // MARK: - confirmNewRound envelope（p2-5 驗收條件 #1）

    /// method 名稱、空 payload、走 game-gateway（`.lq.FastTest.` 前綴）
    func testConfirmNewRoundMethodAndEmptyPayload() {
        let spec = LiqiRequestBuilder.confirmNewRound()

        XCTAssertEqual(spec.method, ".lq.FastTest.confirmNewRound")
        XCTAssertTrue(spec.payload.isEmpty, "ReqCommon 是空 message，payload 必須是 0 bytes")
        // naki-websocket.js 以 `.lq.FastTest.` 前綴判 isGameMethod → 送 game-gateway
        XCTAssertTrue(spec.method.hasPrefix(".lq.FastTest."),
                      "FastTest 方法才會被 sendRaw 送到 game-gateway")
    }

    /// 完整 envelope：空 payload 仍輸出 `12 00`（與 heatbeat / startRoom 等 ReqCommon 一致）
    func testConfirmNewRoundEnvelopeBytes() {
        let spec = LiqiRequestBuilder.confirmNewRound()

        // msgId 60000 → little-endian 60 ea
        let bytes = spec.encoded(msgId: 60000)
        // 0a 1c <28 bytes method> 12 00
        let methodHex = "2e6c712e46617374546573742e636f6e6669726d4e6577526f756e64"
        XCTAssertEqual(LiqiEncoder.hexString(Array(bytes.dropFirst(3))),
                       "0a1c" + methodHex + "1200")
        XCTAssertEqual(bytes[0], 0x02, "REQUEST")
        XCTAssertEqual(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8), 60000)
    }

    /// 自動配號時 msgId 落在 Naki 保留區段（60000+），且 round-trip 解得回來
    func testConfirmNewRoundAutoMsgIdInReservedRange() {
        let spec = LiqiRequestBuilder.confirmNewRound()
        let (msgId, bytes) = LiqiEncoder.encodeRequest(method: spec.method, fields: spec.fields)

        XCTAssertGreaterThanOrEqual(msgId, LiqiMsgIdAllocator.rangeStart)
        XCTAssertLessThanOrEqual(msgId, LiqiMsgIdAllocator.rangeEnd)

        guard case .success(let envelope) = LiqiEnvelope.decode(Data(bytes)) else {
            return XCTFail("confirmNewRound envelope 應該解得開")
        }
        XCTAssertEqual(envelope.type, .request)
        XCTAssertEqual(envelope.msgId, msgId)
        XCTAssertEqual(envelope.method, ".lq.FastTest.confirmNewRound")
        XCTAssertTrue(envelope.payload.isEmpty)
    }

    // MARK: - clearLeaving（ReqCommon，空 payload）

    func testClearLeavingIsEmptyCommonRequest() {
        let spec = LiqiRequestBuilder.clearLeaving()

        XCTAssertEqual(spec.method, ".lq.FastTest.clearLeaving")
        XCTAssertTrue(spec.payload.isEmpty)
        XCTAssertTrue(spec.method.hasPrefix(".lq.FastTest."))
    }

    // MARK: - voteGameEnd（ReqVoteGameEnd，不是 ReqCommon）

    /// yes=true → field 1 bool（08 01）
    func testVoteGameEndYesPayloadBytes() {
        let spec = LiqiRequestBuilder.voteGameEnd(yes: true)

        XCTAssertEqual(spec.method, ".lq.FastTest.voteGameEnd")
        XCTAssertEqual(LiqiEncoder.hexString(spec.payload), "0801",
                       "ReqVoteGameEnd { yes = 1 }：yes=true 是 field 1 的 bool")
    }

    /// yes=false → proto3 省略預設值，payload 為空
    func testVoteGameEndNoOmitsDefault() {
        let spec = LiqiRequestBuilder.voteGameEnd(yes: false)

        XCTAssertTrue(spec.payload.isEmpty, "proto3 false 會被省略")
    }

    // MARK: - 局間確認閘門（p2-5 驗收條件 #2 的純函式面）

    /// `.auto` 才放行；`.off`/`.recommend` 一律 `.skip(.notAutoMode)`
    func testAllowsConfirmOnlyInAutoMode() {
        XCTAssertEqual(AutoPlayGate.allowsConfirm(isAutoMode: true, isSanma: false), .proceed)
        XCTAssertEqual(AutoPlayGate.allowsConfirm(isAutoMode: false, isSanma: false),
                       .skip(.notAutoMode))
    }

    /// 三麻 fail-closed：即使自動模式也不送（內建模型只有四麻一份）
    func testAllowsConfirmFailsClosedOnSanma() {
        XCTAssertEqual(AutoPlayGate.allowsConfirm(isAutoMode: true, isSanma: true),
                       .skip(.sanmaUnsupported))
    }

    /// 模式先於三麻判斷：非自動模式一律先被 notAutoMode 擋
    func testAllowsConfirmModeCheckedBeforeSanma() {
        XCTAssertEqual(AutoPlayGate.allowsConfirm(isAutoMode: false, isSanma: true),
                       .skip(.notAutoMode))
    }
}
