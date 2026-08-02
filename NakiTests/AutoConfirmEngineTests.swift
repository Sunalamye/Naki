//
//  AutoConfirmEngineTests.swift
//  NakiTests
//
//  p2-5：`AutoPlayEngine` 局間確認的整合驗收。
//
//  驗收條件 #2（模式閘門）：`.off`/`.recommend` 不送、`.auto` 才送、三麻不送。
//  驗收條件 #3（送出失敗保留 pending 並重試，成功才收工）：這裡驗引擎層的 pending
//  生命週期（confirmPending 何時保留、何時清）；dispatcher 的重試細節在
//  `AutoConfirmDispatcherTests`。
//
//  confirmNewRound 的實際送出通道用 `Timing.confirmSend` 注入，避免碰
//  `LiqiResponseStore` 單例——與 `AutoPlayEngine` 把時間常數做成參數同一個理由。
//

import XCTest

@testable import Naki

/// 可控時鐘：測試推進 `now` 來驅動 watchdog（取代注入 runConfirmCycle 的時間參數）。
private final class ClockBox {
    var now: Date
    init(_ start: Date) { now = start }
}

@MainActor
final class AutoConfirmEngineTests: XCTestCase {

    // MARK: - 共用

    private func confirmed() -> LiqiToolSendOutcome {
        LiqiToolSendOutcome(
            sent: LiqiSendResult(method: ".lq.FastTest.confirmNewRound",
                                 msgId: 60001, byteCount: 20, success: true, detail: "socket=0"),
            response: LiqiResponseRecord(msgId: 60001, method: ".lq.FastTest.confirmNewRound",
                                         fields: [:], receivedAt: Date()))
    }

    private func sendFailure() -> LiqiToolSendOutcome {
        LiqiToolSendOutcome(
            sent: LiqiSendResult(method: ".lq.FastTest.confirmNewRound",
                                 msgId: 60001, byteCount: 20, success: false,
                                 detail: "no_game_gateway_connection"),
            response: nil)
    }

    private func makeEngine(mode: AutoPlayMode,
                            isSanma: Bool = false,
                            isReady: Bool = true,
                            confirmAckWatchdog: TimeInterval = 6.0,
                            maxWatchdogResends: Int = 3,
                            clock: (() -> Date)? = nil,
                            confirmSend: @escaping () async -> LiqiToolSendOutcome)
        -> AutoPlayEngine {
        var timing = AutoPlayEngine.Timing()
        timing.poll = 1.0
        timing.confirmGrace = 0
        timing.confirmAckWatchdog = confirmAckWatchdog
        timing.confirmMaxWatchdogResends = maxWatchdogResends
        if let clock { timing.clock = clock }
        timing.confirmPolicy = .init(maxAttempts: 3, delay: 0, awaitResponseMs: 0)
        timing.confirmSend = confirmSend
        return AutoPlayEngine(
            store: LiqiOperationStore(),
            sender: LiqiActionSender(),
            timing: timing,
            context: {
                AutoPlayEngine.Context(mode: mode,
                                       recommendations: [],
                                       seat: 0,
                                       isSanma: isSanma,
                                       tsumoTile: nil,
                                       isReady: isReady)
            })
    }

    // MARK: - 模式閘門（驗收條件 #2）

    /// `.auto`：局間結算後真的送 confirmNewRound
    func testAutoModeSendsConfirm() async {
        var calls = 0
        let engine = makeEngine(mode: .auto,
                                confirmSend: { calls += 1; return self.confirmed() })

        engine.roundDidEnd()
        XCTAssertTrue(engine.confirmPending)

        let result = await engine.runConfirmCycle()

        XCTAssertEqual(result, .dispatched(.confirmed(attempts: 1)))
        XCTAssertEqual(calls, 1)
        // p5 #3：第 2 層（RESPONSE 無 error）達成後不立即清 pending——要等權威
        // ActionNewRound（第 3 層）。pending 保留、進入「已受理等下一局」狀態。
        XCTAssertTrue(engine.confirmPending, "受理後仍要等 ActionNewRound，pending 不能立刻清")
        XCTAssertNotNil(engine.confirmAckedAt, "已受理，記下時間交給 watchdog")

        // ActionNewRound 到達 → 這時才真的清
        engine.roundDidBegin()
        XCTAssertFalse(engine.confirmPending)
        XCTAssertNil(engine.confirmAckedAt)
    }

    /// p5 #3：受理後在 watchdog 內安靜等 ActionNewRound（不重送）；逾時才重送。
    func testConfirmWaitsForActionNewRoundThenResendsOnWatchdogTimeout() async {
        var calls = 0
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clockBox = ClockBox(t0)
        // watchdog 設 2 秒好測：受理後 2 秒沒進下一局就重送
        let engine = makeEngine(mode: .auto,
                                confirmAckWatchdog: 2.0,
                                clock: { clockBox.now },
                                confirmSend: { calls += 1; return self.confirmed() })
        engine.roundDidEnd()

        // 第一次：送出並受理（ack 記在 clock 當下 = t0）
        _ = await engine.runConfirmCycle()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(engine.confirmPending)

        // watchdog 內（+1s）：安靜等，不重送
        clockBox.now = t0.addingTimeInterval(1.0)
        let waiting = await engine.runConfirmCycle()
        XCTAssertEqual(waiting, .awaitingRound)
        XCTAssertEqual(calls, 1, "watchdog 內不該重送")

        // 逾時（+2.5s）：ActionNewRound 遲遲不到 → 重送
        clockBox.now = t0.addingTimeInterval(2.5)
        _ = await engine.runConfirmCycle()
        XCTAssertEqual(calls, 2, "逾時未進下一局要重送，否則整局卡在結算畫面")
    }

    /// p5 #3（Codex 復核）：watchdog 重送用完仍等不到 ActionNewRound → 放掉 pending，
    /// 避免「瀏覽器已進下一局、我們漏收 frame」時 confirm 無限重送把自動打牌餓死。
    func testWatchdogAbandonsAfterMaxResendsToAvoidStarvation() async {
        var calls = 0
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let clockBox = ClockBox(t0)
        let engine = makeEngine(mode: .auto,
                                confirmAckWatchdog: 1.0,
                                maxWatchdogResends: 2,
                                clock: { clockBox.now },
                                confirmSend: { calls += 1; return self.confirmed() })
        engine.roundDidEnd()

        _ = await engine.runConfirmCycle()           // 送出並受理
        var elapsed = 1.0
        // 每次把時鐘推過 watchdog → 重送，直到用完上限
        for _ in 0..<2 {
            elapsed += 1.5
            clockBox.now = t0.addingTimeInterval(elapsed)
            let r = await engine.runConfirmCycle()
            XCTAssertEqual(r, .dispatched(.confirmed(attempts: 1)))
        }
        // 超過上限這一次：放掉 pending
        elapsed += 1.5
        clockBox.now = t0.addingTimeInterval(elapsed)
        let abandoned = await engine.runConfirmCycle()
        XCTAssertEqual(abandoned, .abandoned)
        XCTAssertFalse(engine.confirmPending, "放掉待確認，自動打牌才不會被永久餓死")
    }

    /// p5 #3（Codex 二次復核）：進入 recovery 後重送**一直回 .failed**，也必須消耗 budget
    /// 並最終放掉 pending——否則 confirmAckedAt 停在 nil、counter 卡住、confirm 永久佔住 tick。
    func testFailedResendsStillConsumeBudgetAndAbandon() async {
        var calls = 0
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        let clockBox = ClockBox(t0)
        var succeed = true
        let engine = makeEngine(mode: .auto,
                                confirmAckWatchdog: 1.0,
                                maxWatchdogResends: 2,
                                clock: { clockBox.now },
                                confirmSend: {
                                    calls += 1
                                    // 第一次 ACK 成功進入等待；之後 server 已推進，重送一律失敗
                                    return succeed ? self.confirmed() : self.sendFailure()
                                })
        engine.roundDidEnd()

        _ = await engine.runConfirmCycle()           // 第一次：ACK 成功
        XCTAssertTrue(engine.confirmPending)
        succeed = false                              // 之後重送一律 .failed

        // 每次逾時 → recovery 重送（回 .failed，但仍消耗 budget）
        var last: AutoConfirmCycleResult = .noPending
        for i in 1...4 {
            clockBox.now = t0.addingTimeInterval(Double(i) * 1.5)
            last = await engine.runConfirmCycle()
            if last == .abandoned { break }
        }
        XCTAssertEqual(last, .abandoned, "失敗的重送也要消耗 budget，用完就放掉，不能無限佔 tick")
        XCTAssertFalse(engine.confirmPending)
    }

    /// `.off`：不送，pending 保留（使用者自己在遊戲內確認）
    func testOffModeDoesNotSend() async {
        var calls = 0
        let engine = makeEngine(mode: .off,
                                confirmSend: { calls += 1; return self.confirmed() })

        engine.roundDidEnd()
        let result = await engine.runConfirmCycle()

        XCTAssertEqual(result, .skipped(.notAutoMode))
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(engine.confirmPending, "非自動模式不送，但 pending 不主動清")
    }

    /// `.recommend`：同樣不自動送
    func testRecommendModeDoesNotSend() async {
        var calls = 0
        let engine = makeEngine(mode: .recommend,
                                confirmSend: { calls += 1; return self.confirmed() })

        engine.roundDidEnd()
        let result = await engine.runConfirmCycle()

        XCTAssertEqual(result, .skipped(.notAutoMode))
        XCTAssertEqual(calls, 0)
    }

    /// 三麻 fail-closed：即使 `.auto` 也不送
    func testSanmaFailsClosed() async {
        var calls = 0
        let engine = makeEngine(mode: .auto, isSanma: true,
                                confirmSend: { calls += 1; return self.confirmed() })

        engine.roundDidEnd()
        let result = await engine.runConfirmCycle()

        XCTAssertEqual(result, .skipped(.sanmaUnsupported))
        XCTAssertEqual(calls, 0)
    }

    // MARK: - pending 生命週期（驗收條件 #3）

    /// 送出失敗 → 用滿次數後 .failed，且 confirmPending 保留給下一輪
    func testSendFailureKeepsPending() async {
        var calls = 0
        let engine = makeEngine(mode: .auto,
                                confirmSend: { calls += 1; return self.sendFailure() })

        engine.roundDidEnd()
        let result = await engine.runConfirmCycle()

        XCTAssertEqual(result, .dispatched(.failed(attempts: 3)))
        XCTAssertEqual(calls, 3, "bounded retry 要用滿")
        XCTAssertTrue(engine.confirmPending, "沒確認成功前不可以清 pending")
    }

    /// 通道恢復後的下一輪，對同一個待確認再送一次並成功
    func testPendingCanBeRetriedByNextCycle() async {
        var calls = 0
        var succeed = false
        let engine = makeEngine(mode: .auto,
                                confirmSend: {
                                    calls += 1
                                    return succeed ? self.confirmed() : self.sendFailure()
                                })

        engine.roundDidEnd()
        let first = await engine.runConfirmCycle()
        XCTAssertEqual(first, .dispatched(.failed(attempts: 3)))
        XCTAssertTrue(engine.confirmPending)

        // 通道恢復
        succeed = true
        let second = await engine.runConfirmCycle()
        XCTAssertEqual(second, .dispatched(.confirmed(attempts: 1)))
        // p5 #3：受理後等 ActionNewRound，pending 保留到下一局開始
        XCTAssertTrue(engine.confirmPending)
        engine.roundDidBegin()
        XCTAssertFalse(engine.confirmPending)
    }

    // MARK: - 生命週期訊號

    /// 沒有 end_kyoku 就沒有待確認：runConfirmCycle 直接 .noPending，一次都不送
    func testNoPendingDoesNothing() async {
        var calls = 0
        let engine = makeEngine(mode: .auto,
                                confirmSend: { calls += 1; return self.confirmed() })

        let result = await engine.runConfirmCycle()

        XCTAssertEqual(result, .noPending)
        XCTAssertEqual(calls, 0)
    }

    /// 下一局開始（ActionNewRound → roundDidBegin）→ 清 pending，不再送
    func testRoundDidBeginClearsPending() async {
        var calls = 0
        let engine = makeEngine(mode: .auto,
                                confirmSend: { calls += 1; return self.confirmed() })

        engine.roundDidEnd()
        engine.roundDidBegin()   // 權威 action 到達
        XCTAssertFalse(engine.confirmPending)

        let result = await engine.runConfirmCycle()
        XCTAssertEqual(result, .noPending)
        XCTAssertEqual(calls, 0)
    }

    /// 終局（NotifyGameEndResult → gameDidEnd）取消待確認：不對終局送 confirmNewRound
    func testGameDidEndCancelsPendingConfirm() async {
        var calls = 0
        let engine = makeEngine(mode: .auto,
                                confirmSend: { calls += 1; return self.confirmed() })

        engine.roundDidEnd()     // 最後一局的 end_kyoku
        engine.gameDidEnd()      // 緊接著的終局訊號
        XCTAssertFalse(engine.confirmPending, "終局不進下一局，取消待確認")

        let result = await engine.runConfirmCycle()
        XCTAssertEqual(result, .noPending)
        XCTAssertEqual(calls, 0, "終局不得送 confirmNewRound")
    }

    /// WebView 尚未就緒：保留 pending，不送
    func testNotReadyKeepsPending() async {
        var calls = 0
        let engine = makeEngine(mode: .auto, isReady: false,
                                confirmSend: { calls += 1; return self.confirmed() })

        engine.roundDidEnd()
        let result = await engine.runConfirmCycle()

        XCTAssertEqual(result, .notReady)
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(engine.confirmPending)
    }

    /// stop() 清掉待確認（App 收掉 / 測試結束）
    func testStopClearsPending() {
        let engine = makeEngine(mode: .auto, confirmSend: { self.confirmed() })

        engine.roundDidEnd()
        XCTAssertTrue(engine.confirmPending)
        engine.stop()
        XCTAssertFalse(engine.confirmPending)
    }
}
