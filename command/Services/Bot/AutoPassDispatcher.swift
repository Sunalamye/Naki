//
//  AutoPassDispatcher.swift
//  Naki
//
//  「模型判斷不做副露 → 主動送過」的送出與收工策略。
//

import Foundation

/// 主動送「過」的結果
enum AutoPassOutcome: Equatable {
    /// 送出成功；該批 oplist 已在**送出成功之後**標記為已處理
    case handled(attempts: Int)
    /// 用完重試次數仍送不出去；oplist 保留 pending，留給下一輪重試
    case failed(attempts: Int)
    /// 一次都沒送：執行已被新的觸發取代，或這批 oplist 已被換掉
    case superseded
}

/// 送出「過」，並且**只在送出成功之後**才消化 oplist。
///
/// 這段原本直接寫在 `WebViewModel.checkAndRetriggerAutoPlay` 的 `.sendPass` 分支，
/// 順序是「先 `markHandled` 再 `await pass()`」。只要送出失敗（沒有 game-gateway、
/// JS 端沒有 OPEN 的雀魂連線、`callJavaScript` 丟例外），這批機會就在**沒有送出
/// 任何 request** 的情況下被消化掉，重試框架再也看不到它，對局只能等伺服器
/// 逾時代打。和牌路徑早就改成「成功才收工」，這裡補上同一個語意。
///
/// 抽成獨立型別的理由是**可單測**：`WebViewModel` 要有 WebPage 和整套 UI，
/// 測試裡建不出來。把送出通道、oplist 儲存體、「是否仍是當前執行」全部做成參數後，
/// 「失敗保留 pending、成功才 handled」就有機械驗收依據。
enum AutoPassDispatcher {

    /// 重試參數
    ///
    /// 與和牌路徑同型：短間隔、次數有限。用完次數**不** markHandled——
    /// 保留 pending 才能讓 1 秒輪詢在下一輪重新嘗試（伺服器給 300 秒思考時間，
    /// 多等幾輪沒有代價，靜默放棄機會才有）。
    struct RetryPolicy {
        var maxAttempts: Int = 5
        var delay: TimeInterval = 0.2

        static let `default` = RetryPolicy()
    }

    /// - Parameters:
    ///   - sequence: 觸發這次「過」的 oplist 序號；送出成功後才用它 `markHandled`
    ///   - store: oplist 儲存體（正式路徑是 `LiqiOperationStore.shared`）
    ///   - policy: 重試次數與間隔
    ///   - isCurrent: 這次執行是否仍是當前執行（`currentExecutionId` 比對）
    ///   - log: 診斷輸出
    ///   - send: 實際送出（`LiqiActionSender.pass(channel:)`）
    @discardableResult
    static func send(
        sequence: UInt64,
        store: LiqiOperationStore,
        policy: RetryPolicy = .default,
        isCurrent: () -> Bool = { true },
        log: (String) -> Void = { _ in },
        send: () async -> LiqiSendResult
    ) async -> AutoPassOutcome {

        var attempts = 0
        while attempts < policy.maxAttempts {
            // 被新的觸發取代就停手：那條路徑會自己決定要送什麼。
            guard isCurrent() else { return .superseded }

            // 這批 oplist 已被換掉（對局往前走了）就不要再送——
            // 遲到的「過」會落在下一批機會上，等於替下一個決策做主。
            guard store.pending?.sequence == sequence else {
                log("⏭️ 過: oplist 已更新，捨棄這次送出 (seq=\(sequence))")
                return .superseded
            }

            attempts += 1
            let result = await send()
            log(result.logLine)

            if result.success {
                // 只有這裡才消化 oplist。
                store.markHandled(sequence)
                return .handled(attempts: attempts)
            }

            guard attempts < policy.maxAttempts else { break }
            log("⚠️ 過送出失敗, 重試 \(attempts + 1)/\(policy.maxAttempts)")
            if policy.delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(policy.delay * 1_000_000_000))
            }
        }

        log("❌ 過送出失敗 \(attempts) 次, 保留 oplist 等下一輪 (seq=\(sequence))")
        return .failed(attempts: attempts)
    }
}
