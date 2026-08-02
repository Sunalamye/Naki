//
//  AutoPlayActionExecutor.swift
//  Naki
//
//  「已經決定要做什麼」之後，真正把它組成 Liqi request 送出去的那一層。
//
//  由來（p2-1）：同一個 7-case switch（discard / riichi / chi / pon / kan / hora / pass）
//  原本有三份拷貝，而且已經漂移：
//
//      WebViewModel.executeAutoPlayAction          85 行，有完整診斷輸出
//      LegacyWebViewModel.sendAction               46 行，**一行 log 都沒有**
//      AutoPlayFailsafePipeline.send（測試 harness）自己 markHandled
//
//  漂移的實際後果：
//  - Legacy 路徑送出去的是什麼、吃的組合對到第幾個索引、為什麼沒送，全部看不到。
//  - Legacy 沒有「chi 組合對照失敗 → 退回索引 0」的警告，等於靜默送出可能錯的吃。
//  - harness 自己 markHandled，所以 fail-safe fixture 測到的是 harness 的語意，
//    不是 `WebViewModel` 的（AutoPlayFailsafeFixtureTests 檔頭原本就註明「要等 p2-1」）。
//
//  收成一份之後，**markHandled 的語意內聚在這裡**：只有 `sendRaw` 回 success 才消化
//  這批 oplist（p0-1 的結論——沒有送出成功就不能把機會當成處理完）。
//  呼叫端不需要、也不應該自己標記。
//
//  ⚠️ 重試刻意**不**在這一層。
//  主路徑的 15 次重試寫在 `WebViewModel.executeAutoPlayActionWithRetry`，它每一次都會
//  重跑 `AutoPlayDecisionResolver.resolve` 與 `isStillValid`——因為延遲期間 oplist 可能
//  已經換批，盲目重送等於拿舊決策操作新機會。把次數搬進本層只有兩種結果：
//  變成不重新決策的盲送，或與外層相乘（15×N）。Legacy 沒有重試框架（送一次就結束），
//  差異因此留在呼叫端，收斂計畫見 p2-2／p3-2。
//

import Foundation

/// 自動打牌動作的唯一送出點。
///
/// 做成獨立型別而不是 `WebViewModel` 的方法，是為了可單測：`WebViewModel` 要有
/// WebPage、Timer、DebugServer，而且是 `@MainActor class`（在 NakiTests host 釋放會
/// SIGABRT，見 CLAUDE.md）。把 sender、oplist 儲存體、log 通道都做成參數之後，
/// 「哪個動作送出哪一種 request」「成功才 markHandled」就有機械驗收依據。
enum AutoPlayActionExecutor {

    /// 送出一個已經決定好的動作。
    ///
    /// - Parameters:
    ///   - action: resolver 裁決後的動作（不是 AI 的原始推薦）
    ///   - tile: 動作附帶的牌名（MJAI 格式）；吃是 `chi_0` / `chi_1` / `chi_2`
    ///   - snapshot: 這次動作依據的 oplist 快照；index／槓型／和牌型／pass 通道都由它推導
    ///   - recommendations: 目前的推薦清單（立直要從裡面找宣言牌）
    ///   - tsumoTile: 這一巡摸到的牌，用來判斷 moqie；nil 表示不是摸切
    ///   - sender: 動作送出器
    ///   - store: oplist 儲存體（正式路徑是 `LiqiOperationStore.shared`）
    ///   - log: 逐步細節（主路徑接 `debugServer.addLog`）
    ///   - event: 「為什麼沒送出」這種必須留在 events.log 的關鍵事件
    /// - Returns: 送出結果；**`nil` 代表一個 request 都沒組出來**（牌字串轉不了、
    ///   找不到宣言牌、未知動作）。這與「送出失敗」不同，但兩者都不會消化 oplist。
    /// - Parameter awaitResponseMs: > 0 時等同 msgId 的 RESPONSE 並驗第 2 層（伺服器有沒有
    ///   受理，見 p5-verify）。0＝只驗第 1 層（`sendRaw` 送進 WebSocket）——測試預設值，
    ///   保留舊語意。正式路徑傳 > 0，讓「送成功但伺服器拒絕」不再被靜默當成功。
    @discardableResult
    static func execute(
        action: Recommendation.ActionType,
        tile: String,
        snapshot: LiqiOperationSnapshot?,
        recommendations: [Recommendation],
        tsumoTile: String? = nil,
        sender: LiqiActionSender,
        store: LiqiOperationStore,
        awaitResponseMs: Int = 0,
        log: (String) -> Void = { _ in },
        event: (String) -> Void = { _ in }
    ) async -> LiqiSendResult? {

        // ① 把動作組成 request spec（組不出來的三種情況一律 return nil，不消化 oplist）
        let spec: LiqiRequestSpec

        switch action {
        case .discard:
            guard let majsoulTile = LiqiTile.majsoul(fromMJAI: tile) else {
                event("❌ 打牌: 無法轉換牌字串 \(tile)，未送出，保留 oplist")
                return nil
            }
            let moqie = (tsumoTile == tile)
            log("執行: 打牌 \(tile) → \(majsoulTile) (moqie=\(moqie))")
            spec = LiqiRequestBuilder.discard(tile: majsoulTile, moqie: moqie)

        case .riichi:
            // Mortal 把「立直宣言」與「捨牌」拆成兩個動作，但 ReqSelfOperation(type=7)
            // 必須同時帶上捨牌，因此取同一批推薦中機率最高的打牌當宣言牌。
            // ⚠️ 未驗證：此選法是否與 Mortal 立直後的第二次推論結果一致。
            guard let discardRec = recommendations.first(where: { $0.actionType == .discard }),
                  let majsoulTile = LiqiTile.majsoul(fromMJAI: discardRec.displayTile)
            else {
                event("❌ 立直: 找不到可宣言的捨牌，未送出，保留 oplist")
                return nil
            }
            let moqie = (tsumoTile == discardRec.displayTile)
            log("執行: 立直 + 捨 \(discardRec.displayTile) → \(majsoulTile)")
            spec = LiqiRequestBuilder.riichi(tile: majsoulTile, moqie: moqie)

        case .chi:
            var variant = 0
            if tile.hasPrefix("chi_"), let index = Int(String(tile.dropFirst(4))) {
                variant = index
            }
            let resolved = snapshot?.chiCombinationIndex(variant: variant)
            let index = UInt32(resolved ?? 0)
            let combos = snapshot?.operation(of: .chi)?.combination.joined(separator: ", ") ?? "-"
            log("執行: 吃 mortal=chi_\(variant) → index=\(index) [\(combos)]"
                + (resolved == nil ? " ⚠️ 無法對照組合, 退回 0" : ""))
            spec = LiqiRequestBuilder.chi(index: index)

        case .pon:
            log("執行: 碰...")
            spec = LiqiRequestBuilder.pon()

        case .kan:
            let kanType = snapshot?.kanOperation ?? .ankan
            log("執行: 槓 (type=\(kanType.rawValue))")
            spec = LiqiRequestBuilder.kan(type: kanType)

        case .hora:
            let horaType = snapshot?.horaOperation ?? .tsumo
            log("執行: 和牌 (type=\(horaType.rawValue))")
            spec = horaType == .ron ? LiqiRequestBuilder.ron() : LiqiRequestBuilder.tsumo()

        case .none:
            let channel: LiqiActionChannel =
                (snapshot?.isCallOpportunity ?? true) ? .chiPengGang : .selfOperation
            log("執行: 過 (\(channel.method))")
            spec = LiqiRequestBuilder.cancel(channel: channel)

        case .unknown:
            event("❌ 未知動作類型，未送出，保留 oplist")
            return nil
        }

        // ② 送出，並依 awaitResponseMs 決定驗到第幾層
        let result = await sendAndVerify(action: action, spec: spec,
                                         sender: sender, awaitResponseMs: awaitResponseMs, event: event)

        // ③ 只有**確認**才消化 oplist；失敗／拒絕／逾時都保留給重試框架
        //    （重試迴圈開頭的 isStillValid 會在 oplist 換批時停手，所以逾時重試不會雙送）。
        if result.success, let sequence = snapshot?.sequence {
            store.markHandled(sequence)
        }
        return result
    }

    /// 送出並套用三層成功判準。`awaitResponseMs == 0` 時只看第 1 層（sendRaw）。
    private static func sendAndVerify(
        action: Recommendation.ActionType,
        spec: LiqiRequestSpec,
        sender: LiqiActionSender,
        awaitResponseMs: Int,
        event: (String) -> Void
    ) async -> LiqiSendResult {

        guard awaitResponseMs > 0 else {
            return await sender.send(spec)   // 舊語意（測試預設）
        }

        let outcome = await sender.sendAwaitingResponse(spec, awaitResponseMs: awaitResponseMs)
        guard let raw = outcome.sent else {
            return LiqiSendResult(method: spec.method, msgId: 0, byteCount: 0,
                                  success: false, detail: "no_send_handler")
        }

        // 第 1 層就沒送出去（sendRaw 失敗）
        guard raw.success else { return raw }

        if let response = outcome.response {
            if response.hasError {
                // 第 2 層：伺服器拒絕了——這正是「sendRaw 回 success 但其實沒打成」的靜默失敗
                // （error 1004/1023/… 藏在 RESPONSE 裡）。不消化 oplist，交給重試框架。
                event("❌ 伺服器拒絕 \(action.rawValue): "
                      + (response.errorDescription ?? "error \(response.errorCode.map(String.init) ?? "?")")
                      + " → 保留 oplist 重試")
                return LiqiSendResult(method: raw.method, msgId: raw.msgId, byteCount: raw.byteCount,
                                      success: false,
                                      detail: "server_rejected:\(response.errorCode.map(String.init) ?? "?")")
            }
            // 第 2 層達成：伺服器受理
            return LiqiSendResult(method: raw.method, msgId: raw.msgId, byteCount: raw.byteCount,
                                  success: true, detail: "confirmed")
        }

        // 送出成功但沒等到 RESPONSE：不當成功。重試框架的 isStillValid 會判斷——
        // 若其實已打成，oplist 會換批 → 停手（不雙送）；若真的沒送到 → 再送一次。
        event("⚠️ \(action.rawValue) 已送出但 \(awaitResponseMs)ms 內沒有 RESPONSE → 保留 oplist")
        return LiqiSendResult(method: raw.method, msgId: raw.msgId, byteCount: raw.byteCount,
                              success: false, detail: "no_response")
    }
}
