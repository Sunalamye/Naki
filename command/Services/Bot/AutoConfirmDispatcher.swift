//
//  AutoConfirmDispatcher.swift
//  Naki
//
//  局間結算 → 送 `confirmNewRound` 的送出與收工策略。
//
//  背景（p2-5）：對局跑到局間結算會停在結算窗口等人點確認，整局無法自動打完。
//  舊實作（note/dev-notes/2025-12-03-auto-confirm-game-end.md）靠點 Laya 的
//  `uiscript.UI_GameEnd` 按鈕——Unity WebGL 下 `uiscript` 不存在，整條已死。
//  協定層的正解是送 `.lq.FastTest.confirmNewRound`（`ReqCommon`，空 payload）。
//
//  本型別**只**負責「送出並判定是否真的被接受」，時機與閘門在 `AutoPlayEngine`。
//  抽成獨立型別的理由與 `AutoPassDispatcher` 相同：可單測。把送出通道與「權威 action
//  是否已到」做成參數後，「送出失敗保留 pending、成功才收工、下一局到就停手」
//  三件事就有機械驗收依據，不必真打一局。
//
//  ## 三層成功判準（與和牌 / 動作送出同一套，見 CLAUDE.md）
//
//    1. `sendRaw` 成功——只代表 WebSocket 接受了 bytes。
//    2. 同 msgId 的 RESPONSE 無 error——伺服器真的受理了這次確認。
//    3. 權威 action（下一局的 `ActionNewRound`）到達——對局真的往前走了。
//
//  第 3 層由 `isSuperseded`（外部把 `ActionNewRound` 到達翻成 true）表達：一旦下一局
//  已經開始，就沒有東西要確認，停手。第 2 層達成即回 `.confirmed`；只到第 1 層
//  （送出成功但沒等到 RESPONSE，或 RESPONSE 有 error）都算尚未確認，bounded retry。
//

import Foundation

/// 送 `confirmNewRound` 的結果
///
/// `nonisolated`：與 `AutoPlayCycleOutcome` 同理，讓它能被嵌進 `AutoConfirmCycleResult`
/// （nonisolated）並在測試端（未開 MainActor 預設隔離）做 `XCTAssertEqual` 不冒 isolation 告警。
nonisolated enum AutoConfirmOutcome: Equatable {
    /// 送出成功且同 msgId RESPONSE 無 error（第 2 層達成）
    case confirmed(attempts: Int)
    /// 用完重試次數仍未確認；pending 保留給下一輪重試
    case failed(attempts: Int)
    /// 一次都沒送、或送到一半下一局已開始（`ActionNewRound` 權威推進）→ 停手
    case superseded
}

/// 送出 `confirmNewRound`，並套用三層成功判準。
enum AutoConfirmDispatcher {

    /// 重試參數
    ///
    /// 與和牌 / 「過」同型：次數有限、間隔短。用完次數**不**清 pending——保留才能讓
    /// 下一輪輪詢重試（伺服器結算窗口有數十秒到數分鐘，多等幾輪沒有代價，
    /// 靜默放棄整局卡死才有）。
    struct RetryPolicy {
        var maxAttempts: Int = 6
        var delay: TimeInterval = 0.4
        /// 每次送出後等 RESPONSE 的毫秒數（`<= 0` 表示不等，只看 sendRaw）
        var awaitResponseMs: Int = 800

        static let `default` = RetryPolicy()
    }

    /// - Parameters:
    ///   - policy: 重試次數、間隔與等待 RESPONSE 的時間
    ///   - isSuperseded: 下一局是否已開始（`ActionNewRound` 到達）或執行已被取消；
    ///     為 true 時停手（本輪的確認不再需要）
    ///   - log: 診斷輸出（要進 events.log）
    ///   - send: 實際送出並（可選）等 RESPONSE（正式路徑是
    ///     `LiqiActionSender.sendAwaitingResponse(confirmNewRound)`）
    @discardableResult
    static func send(
        policy: RetryPolicy = .default,
        isSuperseded: () -> Bool = { false },
        log: (String) -> Void = { _ in },
        send: () async -> LiqiToolSendOutcome
    ) async -> AutoConfirmOutcome {

        var attempts = 0
        while attempts < policy.maxAttempts {
            // 下一局已開始（權威 action 到達）→ 沒有東西要確認了。
            guard !isSuperseded() else {
                log("⏭️ confirmNewRound: 下一局已開始，停止確認 (attempts=\(attempts))")
                return .superseded
            }

            attempts += 1
            let outcome = await send()

            if let sent = outcome.sent, sent.success {
                if let response = outcome.response {
                    if !response.hasError {
                        log("✅ confirmNewRound 已被伺服器受理 msgId=\(sent.msgId) (第 \(attempts) 次)")
                        return .confirmed(attempts: attempts)
                    }
                    // RESPONSE 帶 error：伺服器拒絕了這次確認，記錄後重試。
                    log("❌ confirmNewRound 被伺服器拒絕: "
                        + (response.errorDescription ?? "error（未收錄）") + " (第 \(attempts) 次)")
                } else {
                    // sendRaw 成功但沒等到 RESPONSE：不當成功也不當失敗，保守重試
                    // （下一輪若 ActionNewRound 已到，開頭的 isSuperseded 會停手）。
                    log("⚠️ confirmNewRound 已送出但尚未收到 RESPONSE (第 \(attempts) 次)")
                }
            } else {
                log("❌ confirmNewRound sendRaw 失敗: "
                    + (outcome.sent?.detail ?? outcome.unavailableReason ?? "unknown")
                    + " (第 \(attempts) 次)")
            }

            guard attempts < policy.maxAttempts else { break }
            if policy.delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(policy.delay * 1_000_000_000))
            }
        }

        log("❌ confirmNewRound 未確認 \(attempts) 次, 保留 pending 等下一輪")
        return .failed(attempts: attempts)
    }
}
