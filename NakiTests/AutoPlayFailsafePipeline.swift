//
//  AutoPlayFailsafePipeline.swift
//  NakiTests
//
//  把自動打牌路徑壓成「可注入、可斷言」的最小序列。
//
//  為什麼要有這個東西：AUDIT §12 的兩個 P0 fail-safe **至今從未被執行過**
//  （§15.4 live 實測記載）。它們的前提在正常對局撞不到——模型幾乎總是給出
//  `hora@99.6%` 以上的推薦、送出幾乎第一次就成功。防守程式碼靠正常對局驗證
//  本來就是矛盾的，要驗只能注入。
//
//  歷史：p0-5 建立這個 harness 時，它**自己抄了一份順序**（gate → resolver →
//  送出 switch → markHandled），因為 `WebViewModel` 在測試裡建不出來
//  （要 WebPage、Timer、DebugServer，而且是 `@MainActor class`）。
//  那份拷貝的風險寫在當時的檔頭：產品程式碼漂移時 fixture 不會轉紅。
//
//  收斂分兩步完成：
//  - p2-1：送出那一格換成正式的 `AutoPlayActionExecutor`。
//  - p3-2：**整條順序**換成正式的 `AutoPlayEngine`。本檔從此只剩「擺參數」，
//    一行決策邏輯都沒有——fixture A–E 測的是產品狀態機本身。
//
//  它仍然不證明 live 對局真的會走到這裡（那需要 live fixture，仍未驗證），
//  也不證明 `AutoPlayEngine` 的輪詢迴圈在真實時序下的行為（那由
//  `AutoPlayEngineTests` 的迴圈測試與 live soak 分別涵蓋）。
//

import Foundation

@testable import Naki

/// 一輪「輪詢 → 決策 → 送出」的完整走法（參數 → `AutoPlayEngine`）
@MainActor
struct AutoPlayFailsafePipeline {

    // MARK: - 輸入

    /// oplist 儲存體（正式路徑是 `LiqiOperationStore.shared`）
    let store: LiqiOperationStore
    /// 動作送出器（測試注入假的 `sendHandler`，走的仍是真正的 protobuf 編碼）
    let sender: LiqiActionSender
    /// 使用者選的模式
    var mode: AutoPlayMode = .auto
    /// 自家座位（resolver 會拿它跟 oplist 的 seat 對照）
    var seat: Int = 0
    /// 模型此刻的推薦（可為空——那正是 P0-1 的前提）
    var recommendations: [Recommendation] = []
    /// 送出失敗時的重試上限（正式路徑 `AutoPlayEngine.Timing.live.maxAttempts` 是 15）
    var maxAttempts: Int = 15
    /// 重試間隔（fixture 預設 0；正式路徑和牌是 0.2 秒）
    var retryDelay: TimeInterval = 0
    /// 副露機會等推論的寬限期，取正式路徑的同一個常數
    var callPassGrace: TimeInterval = AutoPlayEngine.Timing.live.callPassGrace

    // MARK: - 輸出（型別本體在產品端）

    typealias Outcome = AutoPlayCycleOutcome
    typealias Run = AutoPlayCycle

    // MARK: - 執行

    /// 跑一輪。`now` 可注入，用來擺出「寬限期內／已過」的前提。
    func run(now: Date = Date()) async -> Run {
        await engine().runCycle(now: now)
    }

    /// 手動觸發：MCP 的 `bot_trigger` → `NakiRuntime.triggerAutoPlayNow()`。
    ///
    /// 這條路**不經閘門**（閘門只掛在輪詢與推薦更新上），所以 resolver 自己的
    /// 模式閘門（`.recommend` → `surfaceOnly`、`.off` → `none`）只有在這裡看得到。
    func runManualTrigger(now: Date = Date()) async -> Run {
        await engine().runManualCycle(now: now)
    }

    // MARK: - 組裝

    /// 每輪一個引擎：fixture 之間不共用去抖／執行位狀態（與 p0-5 的原始語意相同）
    private func engine() -> AutoPlayEngine {
        var timing = AutoPlayEngine.Timing()
        timing.callPassGrace = callPassGrace
        timing.maxAttempts = maxAttempts
        timing.passAttempts = maxAttempts
        timing.horaRetry = retryDelay
        timing.passRetry = retryDelay
        timing.retry = retryDelay
        timing.passPolicy = .init(maxAttempts: maxAttempts, delay: retryDelay)
        // fixture 不該真的等 1–3 秒的擬人延遲
        timing.actionDelay = { _, _ in 0 }

        return AutoPlayEngine(
            store: store,
            sender: sender,
            timing: timing,
            context: {
                AutoPlayEngine.Context(mode: mode,
                                       recommendations: recommendations,
                                       seat: seat,
                                       isSanma: false,
                                       tsumoTile: nil,
                                       isReady: true,
                                       // 推薦對應當前 oplist（p5 #1）——fixture 走正常同源路徑
                                       recommendationsOplistSequence: store.pending?.sequence)
            })
    }
}
