//
//  AutoPlayFailsafePipeline.swift
//  NakiTests
//
//  把 `WebViewModel` 的自動打牌路徑壓成「可注入、可斷言」的最小序列。
//
//  為什麼要有這個東西：AUDIT §12 的兩個 P0 fail-safe **至今從未被執行過**
//  （§15.4 live 實測記載）。它們的前提在正常對局撞不到——模型幾乎總是給出
//  `hora@99.6%` 以上的推薦、送出幾乎第一次就成功。防守程式碼靠正常對局驗證
//  本來就是矛盾的，要驗只能注入。
//
//  而 `WebViewModel` 在測試裡建不出來：它要 WebPage、Timer、DebugServer，
//  而且是 `@MainActor class`（在 NakiTests host 釋放會 SIGABRT，見 CLAUDE.md）。
//  所以這裡把它的**順序**原樣搬過來，每一格都用正式的那一份元件：
//
//      WebViewModel.checkAndRetriggerAutoPlay          → AutoPlayGate.evaluate
//      WebViewModel.triggerAutoPlayNow(delay:forcedAction:)
//                                                      → forceHora 用 pending 的 contextTile
//      WebViewModel.executeAutoPlayActionWithRetry     → resolver + isStillValid + 和牌重試
//      WebViewModel.executeAutoPlayAction              → AutoPlayActionExecutor（正式那一份）
//
//  ⚠️ 這是 harness，不是正式路徑。它證明的是
//  「gate → resolver → sender → markHandled」這條**組合**的語意；
//  它不證明 WebViewModel 的 asyncAfter 延遲、去抖、`currentExecutionId` 互斥，
//  也不證明 live 對局真的會走到這裡（那需要 live fixture，仍未驗證）。
//
//  p2-1 之後「實際送出」那一格不再是抄來的第三份 switch，而是直接呼叫正式的
//  `AutoPlayActionExecutor`——「成功才 markHandled」現在測到的是產品程式碼本身。
//
//  p3-2 抽出 `AutoPlayEngine` 之後，把 `run()` 的內容換成呼叫 engine 即可，
//  三個 fixture（AutoPlayFailsafeFixtureTests）不必改——那正是它們存在的目的。
//

import Foundation

@testable import Naki

/// 一輪「輪詢 → 決策 → 送出」的完整走法
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
    /// 和牌送出失敗時的重試上限（正式路徑 `WebViewModel.maxRetryAttempts` 是 15）
    var maxAttempts: Int = 15
    /// 重試間隔（fixture 預設 0；正式路徑和牌是 0.2 秒）
    var retryDelay: TimeInterval = 0
    /// 副露機會等推論的寬限期，取正式路徑的同一個常數
    var callPassGrace: TimeInterval = WebViewModel.callPassGrace

    // MARK: - 輸出

    /// 這一輪走完之後的結果
    ///
    /// 「過」那條路刻意**不**直接帶 `AutoPassOutcome`：那個型別在 app target
    /// （`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`），塞進來會讓本 enum 合成的 `==`
    /// 直接呼叫 MainActor 隔離的 `==`，編譯出一行 isolation 告警。
    /// 攤成 `attempts`／`handled` 之後語意不變，build 也乾淨。
    enum Outcome: Equatable {
        /// 閘門擋下，附原因
        case skipped(AutoPlayGate.Reason)
        /// 真的送出去了；`action`／`tile` 是 **resolver 裁決後**的，不是 AI 推薦的
        case sent(action: Recommendation.ActionType, tile: String, attempts: Int)
        /// 有值得做的動作，但模式不允許自動送出
        case surfaced(Recommendation.ActionType)
        /// 沒送：resolver 判斷不該送（帶 resolver 自己的原因字串）
        case notSent(reason: String)
        /// 送了但沒成功；此時 **oplist 必須仍然 pending**
        case sendFailed(action: Recommendation.ActionType, attempts: Int)
        /// 走「主動送過」那條路（實際送出由 `AutoPassDispatcher` 負責）；
        /// `handled` 就是「有沒有消化 oplist」，失敗時必須是 false
        case passed(attempts: Int, handled: Bool)
        /// 「過」一次都沒送：執行被取代，或這批 oplist 已經換掉
        case passSuperseded
    }

    /// 一輪的完整軌跡（斷言要看得到中間發生什麼，不能只有結果）
    nonisolated struct Run {
        /// 閘門的結論；nil 代表這一輪沒經過閘門（手動觸發）
        let gate: AutoPlayGate.Decision?
        let outcome: Outcome
        /// 這一輪的診斷輸出（對應正式路徑的 `logAutoPlayEvent`）
        let log: [String]
        /// resolver 覆蓋 AI 推薦時的紀錄；nil 代表沒有覆蓋
        let overrode: (requested: Recommendation.ActionType,
                       resolved: Recommendation.ActionType)?
    }

    // MARK: - 執行

    /// 跑一輪。`now` 可注入，用來擺出「寬限期內／已過」的前提。
    func run(now: Date = Date()) async -> Run {
        // ① 閘門（WebViewModel.checkAndRetriggerAutoPlay 的第一段）
        let gate = AutoPlayGate.evaluate(.init(
            isAutoMode: mode == .auto,
            hasActionInFlight: false,
            snapshot: store.pending,
            recommendations: recommendations,
            now: now,
            callPassGrace: callPassGrace))

        switch gate {
        case .skip(let reason):
            return Run(gate: gate, outcome: .skipped(reason), log: [], overrode: nil)

        case .sendPass:
            guard let pending = store.pending,
                  let callOp = pending.operations.compactMap(\.type)
                    .first(where: { $0.isCallOpportunity })
            else {
                return Run(gate: gate, outcome: .notSent(reason: "no_call_operation"),
                           log: [], overrode: nil)
            }
            var log: [String] = []
            let outcome = await AutoPassDispatcher.send(
                sequence: pending.sequence,
                store: store,
                policy: .init(maxAttempts: maxAttempts, delay: retryDelay),
                log: { log.append($0) },
                send: { await sender.pass(channel: callOp.channel) })
            let passed: Outcome
            switch outcome {
            case .handled(let attempts): passed = .passed(attempts: attempts, handled: true)
            case .failed(let attempts): passed = .passed(attempts: attempts, handled: false)
            case .superseded: passed = .passSuperseded
            }
            return Run(gate: gate, outcome: passed, log: log, overrode: nil)

        case .forceHora:
            // WebViewModel.triggerAutoPlayNow(delay:forcedAction:)：牌名取 pending 的 contextTile
            return await execute(requested: .hora,
                                 requestedTile: store.pending?.contextTile ?? "",
                                 gate: gate)

        case .proceed:
            guard let top = recommendations.first else {
                return Run(gate: gate, outcome: .notSent(reason: "no_recommendation"),
                           log: [], overrode: nil)
            }
            return await execute(requested: top.actionType,
                                 requestedTile: top.displayTile,
                                 gate: gate)
        }
    }

    /// 手動觸發：MCP 的 `trigger_autoplay` → `WebViewModel.triggerAutoPlayNow()`。
    ///
    /// 這條路**不經閘門**（閘門只掛在 1 秒輪詢與推薦更新上），所以 resolver 自己的
    /// 模式閘門（`.recommend` → `surfaceOnly`、`.off` → `none`）只有在這裡看得到。
    func runManualTrigger() async -> Run {
        guard let top = recommendations.first else {
            return Run(gate: nil, outcome: .notSent(reason: "no_recommendation"),
                       log: [], overrode: nil)
        }
        return await execute(requested: top.actionType,
                             requestedTile: top.displayTile,
                             gate: nil)
    }

    // MARK: - 決策 ＋ 送出（對應 executeAutoPlayActionWithRetry）

    private func execute(requested: Recommendation.ActionType,
                         requestedTile: String,
                         gate: AutoPlayGate.Decision?) async -> Run {
        var log: [String] = []
        var overrode: (requested: Recommendation.ActionType,
                       resolved: Recommendation.ActionType)?
        var attempt = 0

        while attempt < maxAttempts {
            attempt += 1

            guard let snapshot = store.pending else {
                log.append("⏭️ 尚無 oplist，這次不送")
                return Run(gate: gate, outcome: .notSent(reason: "no_oplist"),
                           log: log, overrode: overrode)
            }

            // ② 送出前的唯一決策點：終局保護、模式閘門、動作是否真的在 oplist 裡
            let decision = AutoPlayDecisionResolver.resolve(
                snapshot: snapshot,
                recommendations: recommendations,
                mode: mode,
                seat: seat)

            let action: Recommendation.ActionType
            let tile: String
            switch decision {
            case .send(let resolvedAction, let resolvedTile):
                action = resolvedAction
                tile = resolvedTile.isEmpty ? requestedTile : resolvedTile
            case .surfaceOnly(let resolvedAction, _):
                log.append("模式非自動，僅顯示不送出: \(resolvedAction.rawValue)")
                return Run(gate: gate, outcome: .surfaced(resolvedAction),
                           log: log, overrode: overrode)
            case .none(let reason):
                log.append("⏭️ 不送出: \(reason)")
                return Run(gate: gate, outcome: .notSent(reason: reason),
                           log: log, overrode: overrode)
            }

            if action != requested {
                overrode = (requested: requested, resolved: action)
                log.append("⚠️ 決策覆蓋: AI 建議 \(requested.rawValue) → 實際送出 \(action.rawValue)")
            }

            // ③ 送出前最後確認這批 oplist 沒被換掉
            guard AutoPlayDecisionResolver.isStillValid(
                decidedOn: snapshot, current: store.pending)
            else {
                log.append("⏭️ oplist 已更新，捨棄過期決策 (seq=\(snapshot.sequence))")
                return Run(gate: gate, outcome: .notSent(reason: "stale_oplist"),
                           log: log, overrode: overrode)
            }

            // ④ 實際送出：走正式的 executor（markHandled 的語意也在它裡面，
            //    成功才消化這批 oplist——失敗留給重試框架再送一次）
            let result = await AutoPlayActionExecutor.execute(
                action: action,
                tile: tile,
                snapshot: snapshot,
                recommendations: recommendations,
                sender: sender,
                store: store,
                log: { log.append($0) },
                event: { log.append($0) })
            log.append(result?.logLine ?? "❌ 未送出（組不出 request）: \(action.rawValue)")

            if result?.success == true {
                return Run(gate: gate,
                           outcome: .sent(action: action, tile: tile, attempts: attempt),
                           log: log, overrode: overrode)
            }

            // 和牌失敗一定要重試（漏和不可逆）；其餘動作這一輪就結束，等下一次輪詢
            guard action == .hora else {
                return Run(gate: gate,
                           outcome: .sendFailed(action: action, attempts: attempt),
                           log: log, overrode: overrode)
            }

            if attempt < maxAttempts {
                log.append("⚠️ 和牌送出失敗, 重試 \(attempt + 1)/\(maxAttempts)")
                if retryDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                }
            }
        }

        log.append("❌ 和牌送出失敗 \(attempt) 次, 放棄（oplist 保留給下一輪）")
        return Run(gate: gate,
                   outcome: .sendFailed(action: requested, attempts: attempt),
                   log: log, overrode: overrode)
    }

}
