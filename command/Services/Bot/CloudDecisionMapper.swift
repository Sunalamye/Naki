//
//  CloudDecisionMapper.swift
//  Naki
//
//  把 `/v3/react` 的回應（reaction + 粗標籤 candidates）映射成 Naki 的
//  `[Recommendation]`——雲端決策生效的**唯一通道**。
//
//  自動打牌真正消費的是 `store.recommendations`（executor 取第一個對應
//  actionType 的列；立直宣言牌取**清單順序**第一個 discard），所以：
//  - 第一列固定由 `reaction` 映射（雲端選的動作）
//  - `reaction` 是立直時，第二列是雲端第二段解出的立直捨牌
//    （executor 的 `first(where: .discard)` 拿到的就是它）
//  - 其餘 candidates 依伺服器排序附在後面（UI 的 top-k 顯示；
//    「放棄副露也是一種選擇」——pass 是真實的一列，不是雜訊）
//
//  標籤詞彙來自 Akagi v3 `label_pais_candidate`：`dahai:<pai>`、`reach`、
//  `pon`、`chi_low|chi_mid|chi_high`、`kan`、`hora`、`ryukyoku`、`nukidora`、
//  `none`。`nukidora`（拔北）對應 `.kita`（2026-08-05 三麻自動打鏈）；
//  `ryukyoku` 無對應 ActionType，略過該列。未知標籤一律略過，不猜。
//

import Foundation

enum CloudDecisionMapper {

    /// 雲端回應 → 推薦清單。回 nil 表示 reaction 解析不出來（呼叫端退回本地）。
    /// - Parameters:
    ///   - reaction: 伺服器回的 mjai 事件（非 null）
    ///   - candidates: top-k；`candidates[0]` 對應 reaction
    ///   - reachDiscard: reaction 是立直時、第二段呼叫解出的捨牌（mjai 字串）
    static func recommendations(reaction: [String: Any],
                                candidates: [CloudCandidate],
                                reachDiscard: String?) -> [Recommendation]? {
        let topProb = candidates.first?.prob ?? 1.0
        guard var rows = reactionRows(reaction, prob: topProb,
                                      reachDiscard: reachDiscard) else {
            return nil
        }

        var seen = Set(rows.map(\.id))
        for candidate in candidates.dropFirst() {
            guard let row = recommendation(fromCandidate: candidate.action,
                                           prob: candidate.prob),
                  seen.insert(row.id).inserted else { continue }
            rows.append(row)
        }
        return rows
    }

    /// reaction → 開頭一或兩列。立直時第二列是捨牌（見檔頭）。
    private static func reactionRows(_ reaction: [String: Any], prob: Double,
                                     reachDiscard: String?) -> [Recommendation]? {
        guard let type = reaction["type"] as? String else { return nil }

        switch type {
        case "dahai":
            guard let pai = reaction["pai"] as? String else { return nil }
            return [Recommendation(tile: pai, probability: prob, actionType: .discard)]

        case "reach":
            guard let discard = reachDiscard else { return nil }
            return [
                Recommendation(tile: "reach", probability: prob, actionType: .riichi),
                Recommendation(tile: discard, probability: prob, actionType: .discard),
            ]

        case "pon":
            let detail = (reaction["pai"] as? String).map { "碰 \($0)" }
            return [Recommendation(tile: "pon", probability: prob, actionType: .pon,
                                   detail: detail)]

        case "chi":
            guard let pai = reaction["pai"] as? String,
                  let consumed = reaction["consumed"] as? [String],
                  let variant = chiVariant(called: pai, consumed: consumed) else {
                return nil
            }
            // 雲端 reaction 帶實際牌組——顯示「用哪兩張吃哪張」，
            // 不再只有 ①②③ 的相對位置（2026-08-05 顯示掃描的增強）
            return [Recommendation(tile: "chi_\(variant)", probability: prob,
                                   actionType: .chi,
                                   detail: "用 \(consumed.joined(separator: "·")) 吃 \(pai)")]

        case "daiminkan", "ankan", "kakan":
            let detail = (reaction["consumed"] as? [String]).map { $0.joined(separator: "·") }
            return [Recommendation(tile: "kan", probability: prob, actionType: .kan,
                                   detail: detail)]

        case "hora":
            return [Recommendation(tile: "hora", probability: prob, actionType: .hora)]

        case "none":
            return [Recommendation(tile: "none", probability: prob, actionType: .none)]

        case "kita":
            // 拔北（三麻）。伺服器 schema 是 `{"type":"kita","actor":N,"pai":"N"}`
            return [Recommendation(tile: "kita", probability: prob, actionType: .kita)]

        default:
            // 未知動作型別不硬映射——回 nil 讓本地決策生效。
            return nil
        }
    }

    /// 粗標籤 → 一列推薦。無法（或不需要）映射回 nil。
    static func recommendation(fromCandidate action: String,
                               prob: Double) -> Recommendation? {
        if action.hasPrefix("dahai:") {
            let pai = String(action.dropFirst("dahai:".count))
            guard !pai.isEmpty else { return nil }
            return Recommendation(tile: pai, probability: prob, actionType: .discard)
        }
        switch action {
        case "reach":
            return Recommendation(tile: "reach", probability: prob, actionType: .riichi)
        case "pon":
            return Recommendation(tile: "pon", probability: prob, actionType: .pon)
        case "chi_low":
            return Recommendation(tile: "chi_0", probability: prob, actionType: .chi)
        case "chi_mid":
            return Recommendation(tile: "chi_1", probability: prob, actionType: .chi)
        case "chi_high":
            return Recommendation(tile: "chi_2", probability: prob, actionType: .chi)
        case "kan":
            return Recommendation(tile: "kan", probability: prob, actionType: .kan)
        case "hora":
            return Recommendation(tile: "hora", probability: prob, actionType: .hora)
        case "nukidora":
            // Akagi 的粗標籤用 nukidora，reaction 事件型別用 kita——同一個動作
            return Recommendation(tile: "kita", probability: prob, actionType: .kita)
        case "none":
            return Recommendation(tile: "none", probability: prob, actionType: .none)
        default:
            return nil
        }
    }

    /// chi 變體：0＝被吃的牌最小（consumed 都比它大）、1＝中間、2＝最大。
    /// 與 `LiqiOperationSnapshot.chiCombinationIndex` 的推導同一套。
    static func chiVariant(called: String, consumed: [String]) -> Int? {
        guard let calledNumber = tileNumber(called),
              consumed.count == 2 else { return nil }
        let numbers = consumed.compactMap(tileNumber)
        guard numbers.count == 2 else { return nil }

        let below = numbers.filter { $0 < calledNumber }.count
        let above = numbers.filter { $0 > calledNumber }.count
        if above == 2 { return 0 }
        if below == 2 { return 2 }
        if below == 1 && above == 1 { return 1 }
        return nil
    }

    /// mjai 數牌字串的數字（"3m" → 3、"5mr" → 5）；字牌回 nil（chi 用不到）。
    private static func tileNumber(_ tile: String) -> Int? {
        guard let first = tile.first, let number = first.wholeNumberValue,
              (1...9).contains(number) else { return nil }
        return number
    }
}
