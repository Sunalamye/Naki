//
//  AutoPassDispatcherTests.swift
//  NakiTests
//
//  「主動送過」的收工判準回歸測試。
//
//  來源是 AUDIT P0-1：`.sendPass` 分支在 `await pass()` **之前**就 markHandled。
//  送出失敗（沒有 game-gateway、JS 端沒有 OPEN 的雀魂連線、callJavaScript 丟例外）
//  時這批 oplist 已經被消化，重試框架再也看不到它——log 上卻只有一行
//  「自動送出過」，看起來像成功。和牌路徑早就是「成功才收工」，這裡鎖住同一語意。
//

import XCTest

@testable import Naki

final class AutoPassDispatcherTests: XCTestCase {

    // MARK: - Fixtures

    /// 建一個只含「碰」機會的 store，回傳 (store, sequence)
    private func storeWithCallOpportunity() -> (LiqiOperationStore, UInt64) {
        let store = LiqiOperationStore()
        let snapshot = store.record(
            seat: 0,
            operations: [LiqiOperation(type: .pon, combination: ["5m|5m"])],
            source: "test")
        return (store, snapshot.sequence)
    }

    private func result(success: Bool, detail: String? = nil) -> LiqiSendResult {
        LiqiSendResult(method: ".lq.FastTest.inputChiPengGang",
                       msgId: 0x3F00,
                       byteCount: 24,
                       success: success,
                       detail: detail)
    }

    private let noDelay = AutoPassDispatcher.RetryPolicy(maxAttempts: 3, delay: 0)

    // MARK: - 成功才收工

    /// 送出成功 → 這批 oplist 才算處理完（pending 清空）
    @MainActor
    func testSuccessMarksHandled() async {
        let (store, sequence) = storeWithCallOpportunity()
        var sendCount = 0

        let outcome = await AutoPassDispatcher.send(
            sequence: sequence, store: store, policy: noDelay,
            send: {
                sendCount += 1
                return self.result(success: true, detail: "socket=0 bytes=24")
            })

        XCTAssertEqual(outcome, .handled(attempts: 1))
        XCTAssertEqual(sendCount, 1)
        XCTAssertNil(store.pending, "送出成功後這批 oplist 必須被消化")
        XCTAssertNotNil(store.latest, "latest 仍保留，供診斷用")
    }

    /// 第一次失敗、第二次成功 → 仍然只在成功那次 markHandled
    @MainActor
    func testRetriesUntilSuccess() async {
        let (store, sequence) = storeWithCallOpportunity()
        var sendCount = 0

        let outcome = await AutoPassDispatcher.send(
            sequence: sequence, store: store, policy: noDelay,
            send: {
                sendCount += 1
                return self.result(success: sendCount >= 2, detail: "no_open_majsoul_connection")
            })

        XCTAssertEqual(outcome, .handled(attempts: 2))
        XCTAssertEqual(sendCount, 2)
        XCTAssertNil(store.pending)
    }

    // MARK: - 失敗保留 pending

    /// 這是 P0-1 的主張：送出失敗時 oplist 必須仍然 pending，才可能重試
    @MainActor
    func testFailureKeepsSnapshotPending() async {
        let (store, sequence) = storeWithCallOpportunity()
        var sendCount = 0

        let outcome = await AutoPassDispatcher.send(
            sequence: sequence, store: store, policy: noDelay,
            send: {
                sendCount += 1
                return self.result(success: false, detail: "no_open_majsoul_connection")
            })

        XCTAssertEqual(outcome, .failed(attempts: 3))
        XCTAssertEqual(sendCount, 3, "重試次數要用滿")
        XCTAssertEqual(store.pending?.sequence, sequence,
                       "一個 request 都沒送出去，不可以把這批機會當成處理完")
    }

    /// 用完次數放棄之後，下一輪（1 秒輪詢）還能對同一批 oplist 再送一次並成功
    @MainActor
    func testPendingSnapshotCanBeRetriedByNextRound() async {
        let (store, sequence) = storeWithCallOpportunity()

        let first = await AutoPassDispatcher.send(
            sequence: sequence, store: store, policy: noDelay,
            send: { self.result(success: false, detail: "no_gateway") })
        XCTAssertEqual(first, .failed(attempts: 3))
        XCTAssertEqual(store.pending?.sequence, sequence)

        // 通道恢復後的下一輪
        let second = await AutoPassDispatcher.send(
            sequence: sequence, store: store, policy: noDelay,
            send: { self.result(success: true) })

        XCTAssertEqual(second, .handled(attempts: 1))
        XCTAssertNil(store.pending)
    }

    /// 失敗時要留下可追的 log，不能靜默
    @MainActor
    func testFailureIsLogged() async {
        let (store, sequence) = storeWithCallOpportunity()
        var logs: [String] = []

        _ = await AutoPassDispatcher.send(
            sequence: sequence, store: store, policy: noDelay,
            log: { logs.append($0) },
            send: { self.result(success: false, detail: "no_open_majsoul_connection") })

        XCTAssertTrue(logs.contains { $0.contains("no_open_majsoul_connection") },
                      "JS 端回報的原因要進 log")
        XCTAssertTrue(logs.contains { $0.contains("保留 oplist") },
                      "放棄時要說清楚 oplist 沒有被消化")
    }

    // MARK: - 不該送出的情況

    /// 這批 oplist 已被換掉 → 一次都不送，也不碰新的那批
    @MainActor
    func testDoesNotSendWhenOplistRotated() async {
        let (store, sequence) = storeWithCallOpportunity()
        let newer = store.record(seat: 0,
                                 operations: [LiqiOperation(type: .discard)],
                                 source: "test-newer")
        var sendCount = 0

        let outcome = await AutoPassDispatcher.send(
            sequence: sequence, store: store, policy: noDelay,
            send: {
                sendCount += 1
                return self.result(success: true)
            })

        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(sendCount, 0, "遲到的『過』會落在下一批機會上")
        XCTAssertEqual(store.pending?.sequence, newer.sequence, "新的那批不可以被消化")
    }

    /// 執行已被新的觸發取代 → 一次都不送，oplist 保持 pending
    @MainActor
    func testDoesNotSendWhenExecutionSuperseded() async {
        let (store, sequence) = storeWithCallOpportunity()
        var sendCount = 0

        let outcome = await AutoPassDispatcher.send(
            sequence: sequence, store: store, policy: noDelay,
            isCurrent: { false },
            send: {
                sendCount += 1
                return self.result(success: true)
            })

        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(store.pending?.sequence, sequence)
    }
}
