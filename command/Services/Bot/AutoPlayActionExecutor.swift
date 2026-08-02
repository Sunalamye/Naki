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
    @discardableResult
    static func execute(
        action: Recommendation.ActionType,
        tile: String,
        snapshot: LiqiOperationSnapshot?,
        recommendations: [Recommendation],
        tsumoTile: String? = nil,
        sender: LiqiActionSender,
        store: LiqiOperationStore,
        log: (String) -> Void = { _ in },
        event: (String) -> Void = { _ in }
    ) async -> LiqiSendResult? {

        let result: LiqiSendResult

        switch action {
        case .discard:
            guard let majsoulTile = LiqiTileCode.majsoul(fromMJAI: tile) else {
                // 轉換失敗＝一個 request 都沒送出去。舊版在這裡照樣消化 oplist，
                // 等於自己把這批機會吃掉，重試框架再也看不到它。
                event("❌ 打牌: 無法轉換牌字串 \(tile)，未送出，保留 oplist")
                return nil
            }
            let moqie = (tsumoTile == tile)
            log("執行: 打牌 \(tile) → \(majsoulTile) (moqie=\(moqie))")
            result = await sender.discard(tile: majsoulTile, moqie: moqie)

        case .riichi:
            // Mortal 把「立直宣言」與「捨牌」拆成兩個動作，但 ReqSelfOperation(type=7)
            // 必須同時帶上捨牌，因此取同一批推薦中機率最高的打牌當宣言牌。
            // ⚠️ 未驗證：此選法是否與 Mortal 立直後的第二次推論結果一致。
            guard let discardRec = recommendations.first(where: { $0.actionType == .discard }),
                  let majsoulTile = LiqiTileCode.majsoul(fromMJAI: discardRec.displayTile)
            else {
                // 同上：沒有宣言牌就沒有 request，不能當成「這批 oplist 處理完了」。
                event("❌ 立直: 找不到可宣言的捨牌，未送出，保留 oplist")
                return nil
            }
            let moqie = (tsumoTile == discardRec.displayTile)
            log("執行: 立直 + 捨 \(discardRec.displayTile) → \(majsoulTile)")
            result = await sender.riichi(tile: majsoulTile, moqie: moqie)

        case .chi:
            // 從 tileName 解析 chi 變體（chi_0 / chi_1 / chi_2）
            var variant = 0
            if tile.hasPrefix("chi_"), let index = Int(String(tile.dropFirst(4))) {
                variant = index
            }
            // 舊實作靠 Laya UI 的組合順序反推索引；改用 oplist 的 combination
            // 與被吃的牌直接對照，得到雀魂端的 combination 索引。
            let resolved = snapshot?.chiCombinationIndex(variant: variant)
            let index = UInt32(resolved ?? 0)
            let combos = snapshot?.operation(of: .chi)?.combination.joined(separator: ", ") ?? "-"
            log("執行: 吃 mortal=chi_\(variant) → index=\(index) [\(combos)]"
                + (resolved == nil ? " ⚠️ 無法對照組合, 退回 0" : ""))
            result = await sender.chi(index: index)

        case .pon:
            // combination 通常只有一組；含紅五時可能有兩組（取捨規則未驗證，先取第 0 組）
            log("執行: 碰...")
            result = await sender.pon()

        case .kan:
            let kanType = snapshot?.kanOperation ?? .ankan
            log("執行: 槓 (type=\(kanType.rawValue))")
            result = await sender.kan(type: kanType)

        case .hora:
            // 和牌型由伺服器給的 oplist 決定，不是猜的
            let horaType = snapshot?.horaOperation ?? .tsumo
            log("執行: 和牌 (type=\(horaType.rawValue))")
            result = horaType == .ron ? await sender.ron() : await sender.tsumo()

        case .none:
            // 跳過：回應他家打牌走 inputChiPengGang，自家回合的選項走 inputOperation
            let channel: LiqiActionChannel =
                (snapshot?.isCallOpportunity ?? true) ? .chiPengGang : .selfOperation
            log("執行: 過 (\(channel.method))")
            result = await sender.pass(channel: channel)

        case .unknown:
            event("❌ 未知動作類型，未送出，保留 oplist")
            return nil
        }

        // 送出成功才把這批 oplist 標記為已處理；失敗留給呼叫端的重試框架再送一次。
        // 沒有 snapshot 時不標記——那代表沒有任何一批機會可以被消化。
        if result.success, let sequence = snapshot?.sequence {
            store.markHandled(sequence)
        }
        return result
    }
}
