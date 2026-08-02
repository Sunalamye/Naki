//
//  AutoConfirmDispatcherTests.swift
//  NakiTests
//
//  p2-5：局間 confirmNewRound 的送出與收工判準。
//
//  三層成功判準（與和牌 / 動作送出同一套）：
//    1. sendRaw 成功；2. 同 msgId RESPONSE 無 error → confirmed；
//    3. 權威 action（ActionNewRound）由 isSuperseded 表達 → 停手。
//  失敗（sendRaw 失敗 / RESPONSE 有 error / 只送出沒回應）都算尚未確認，bounded retry，
//  用完次數保留 pending（回 .failed），不靜默吞掉。
//

import XCTest

@testable import Naki

final class AutoConfirmDispatcherTests: XCTestCase {

    // MARK: - Fixtures

    private let noDelay = AutoConfirmDispatcher.RetryPolicy(
        maxAttempts: 3, delay: 0, awaitResponseMs: 0)

    private func sent(success: Bool) -> LiqiSendResult {
        LiqiSendResult(method: ".lq.FastTest.confirmNewRound",
                       msgId: 60001, byteCount: 20,
                       success: success,
                       detail: success ? "socket=0 bytes=20" : "no_game_gateway_connection")
    }

    /// RESPONSE 紀錄：hasError 由 `fields["field1"]` 是否存在決定（ResCommon.error = field 1）
    private func response(hasError: Bool) -> LiqiResponseRecord {
        LiqiResponseRecord(msgId: 60001,
                           method: ".lq.FastTest.confirmNewRound",
                           fields: hasError ? ["field1": "CAE="] : [:],
                           receivedAt: Date())
    }

    private func outcome(success: Bool, response: LiqiResponseRecord?) -> LiqiToolSendOutcome {
        LiqiToolSendOutcome(sent: sent(success: success), response: response)
    }

    // MARK: - 成功才收工（第 2 層達成）

    /// sendRaw 成功 + RESPONSE 無 error → confirmed，只送一次
    @MainActor
    func testConfirmedWhenResponseHasNoError() async {
        var sends = 0
        let result = await AutoConfirmDispatcher.send(policy: noDelay, send: {
            sends += 1
            return self.outcome(success: true, response: self.response(hasError: false))
        })

        XCTAssertEqual(result, .confirmed(attempts: 1))
        XCTAssertEqual(sends, 1)
    }

    /// RESPONSE 有 error 先重試，之後乾淨的 RESPONSE 才 confirmed
    @MainActor
    func testRetriesWhenServerRejectsThenAccepts() async {
        var sends = 0
        let result = await AutoConfirmDispatcher.send(policy: noDelay, send: {
            sends += 1
            let hasError = sends < 2   // 第一次被拒、第二次受理
            return self.outcome(success: true, response: self.response(hasError: hasError))
        })

        XCTAssertEqual(result, .confirmed(attempts: 2))
        XCTAssertEqual(sends, 2)
    }

    // MARK: - 失敗保留 pending（第 1 層都沒過）

    /// sendRaw 一路失敗 → 用滿次數後 .failed（呼叫端據此保留 pending）
    @MainActor
    func testFailedAfterRepeatedSendFailure() async {
        var sends = 0
        let result = await AutoConfirmDispatcher.send(policy: noDelay, send: {
            sends += 1
            return self.outcome(success: false, response: nil)
        })

        XCTAssertEqual(result, .failed(attempts: 3))
        XCTAssertEqual(sends, 3, "重試次數要用滿")
    }

    /// sendRaw 成功但**沒收到 RESPONSE**：不算確認（第 2 層沒達成），用滿次數仍 .failed。
    /// 這條鎖住「sendRaw 成功不等於伺服器受理」。
    @MainActor
    func testSendRawSuccessWithoutResponseIsNotConfirmed() async {
        var sends = 0
        let result = await AutoConfirmDispatcher.send(policy: noDelay, send: {
            sends += 1
            return self.outcome(success: true, response: nil)
        })

        XCTAssertEqual(result, .failed(attempts: 3))
        XCTAssertEqual(sends, 3)
    }

    // MARK: - 下一局到達就停手（第 3 層：權威 action）

    /// isSuperseded 一開始就 true（ActionNewRound 已到）→ 一次都不送
    @MainActor
    func testSupersededDoesNotSend() async {
        var sends = 0
        let result = await AutoConfirmDispatcher.send(
            policy: noDelay,
            isSuperseded: { true },
            send: {
                sends += 1
                return self.outcome(success: false, response: nil)
            })

        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(sends, 0, "下一局已開始，不必再送")
    }

    /// 送到一半下一局開始 → 下一輪迭代停手
    @MainActor
    func testSupersededMidwayStops() async {
        var sends = 0
        var superseded = false
        let result = await AutoConfirmDispatcher.send(
            policy: noDelay,
            isSuperseded: { superseded },
            send: {
                sends += 1
                superseded = true   // 第一次送出後，下一局到達
                return self.outcome(success: false, response: nil)
            })

        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(sends, 1, "送過一次後被下一局取代，就不再送")
    }

    /// p5 #5（Codex 復核）：`send()` 的 await 期間對局結束（superseded 變 true），
    /// 即使回來的 RESPONSE 無 error，也不能記成 `.confirmed`——那會讓狀態機誤認為
    /// 「我這次確認推進了下一局」。在途的 bytes 收不回（grace 已把機率壓低），但至少不誤認。
    @MainActor
    func testCleanResponseArrivingAfterSupersessionIsNotConfirmed() async {
        var superseded = false
        let result = await AutoConfirmDispatcher.send(
            policy: noDelay,
            isSuperseded: { superseded },
            send: {
                // 送出的 await 期間對局結束了（gameDidEnd/roundDidBegin 清了 pending）
                superseded = true
                return self.outcome(success: true, response: self.response(hasError: false))
            })

        XCTAssertEqual(result, .superseded,
                       "RESPONSE 雖無 error，但送出期間對局已結束，不能當成推進下一局的確認")
    }

    // MARK: - 不靜默

    /// 失敗時要留下可追的 log（拒絕原因 + 保留 pending）
    @MainActor
    func testFailureIsLogged() async {
        var logs: [String] = []
        _ = await AutoConfirmDispatcher.send(
            policy: noDelay,
            log: { logs.append($0) },
            send: { self.outcome(success: false, response: nil) })

        XCTAssertTrue(logs.contains { $0.contains("sendRaw 失敗") },
                      "sendRaw 失敗的原因要進 log")
        XCTAssertTrue(logs.contains { $0.contains("保留 pending") },
                      "放棄時要說清楚 pending 沒被消化")
    }
}
