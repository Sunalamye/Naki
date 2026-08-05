//
//  GameHighlightScript.swift
//  Naki
//
//  遊戲畫面內高亮：由「模式 + 推薦 + 手牌 + oplist」算出要送給
//  `window.__nakiHighlight` 的那一行 JS。
//
//  輸出字串由 `GameHighlightScriptTests` 逐條鎖著。
//

import Foundation

/// 由「模式 + 推薦 + 手牌 + oplist」算出要送給 `window.__nakiHighlight` 的一行 JS。
///
/// 抽成 `nonisolated` 純函式的唯一理由是**可驗收**：「`.off` 時遊戲內高亮清空、
/// 切回 auto 恢復」這件事，只要腳本產生還綁著 `WebPage`，除了真的開一局之外
/// 就沒有辦法確認。與頁面解耦之後「送出去的腳本是什麼」才鎖得住
/// （真的染對顏色仍需 live 驗證）。
nonisolated enum GameHighlightScript {

    /// 清空所有標記
    static let clear = "window.__nakiHighlight?.clear();"

    /// - Parameters:
    ///   - mode: `.off` 一律回 `clear`——「關閉」關的就是顯示
    ///   - recommendations: 目前推薦（只看第一名）
    ///   - tehaiTiles: 自家手牌（MJAI），用來把非推薦牌調淡
    ///   - snapshot: 協定層 oplist（副露組合與彈出面板判斷都取自它，不用推測）
    static func make(mode: AutoPlayMode,
                     recommendations: [Recommendation],
                     tehaiTiles: [String],
                     snapshot: LiqiOperationSnapshot?) -> String {

        // `.off` 的語意是「不顯示推薦」。這裡不讀 mode 的話，關閉模式下遊戲畫面
        // 仍會照常染色——使用者關掉的東西還在動，是 AUDIT §13 那類「介面與行為不符」。
        // 回 clear 而不是「什麼都不送」：上一輪留在畫面上的標記也要收掉。
        guard mode.showRecommendation else { return clear }

        // 標記的是「哪一張牌」而不是「第幾張」。
        // JS 端從遊戲畫牌時的圖集 UV 認出牌面，所以這裡只要給牌名，
        // 不必知道它排在第幾個——手牌張數變動、立直抬牌、畫面邊緣混入別的牌
        // 都不再影響。
        var marks: [[String: Any]] = []

        if let top = recommendations.first {
            switch top.actionType {
            case .discard, .riichi:
                // 綠：建議打出的牌。顏色是乘在牌面貼圖上的，太深會看不見牌面，
                // 所以只壓非主色通道。
                marks.append(["tile": top.displayTile, "color": [0.45, 1.0, 0.5]])

                // 其餘手牌調淡，讓推薦那張自己浮出來。
                //
                // 只染推薦牌的話，在花色鮮豔的牌面皮膚上對比度不夠——
                // 把其他牌壓下去比把一張牌拉上來更有效，也比較不吵。
                // 第 4 個分量是 alpha 倍率，會乘在遊戲原本的 alpha 上。
                let recommended = top.displayTile
                for tile in Set(tehaiTiles).sorted() where tile != recommended {
                    marks.append(["tile": tile, "color": [0.62, 0.62, 0.68, 0.55]])
                }
            case .chi, .pon, .kan:
                // 橙：副露會用掉的手牌（組合取自協定層的 oplist，不是推測）
                let liqiType: LiqiOperationType? = {
                    switch top.actionType {
                    case .chi: return .chi
                    case .pon: return .pon
                    case .kan: return snapshot?.kanOperation
                    default: return nil
                    }
                }()
                let combo = liqiType.flatMap { snapshot?.operation(of: $0) }?.combination.first
                for tile in (combo?.split(separator: "|") ?? []).compactMap({
                    LiqiTile.mjai(fromMajsoul: String($0))
                }) {
                    marks.append(["tile": tile, "color": [1.0, 0.75, 0.4]])
                }
            default:
                break   // 和了 / 過：沒有對應的手牌可標
            }
        }

        // 副露彈出面板（吃／碰／跳過按鈕）：位置不在 uniform 裡，JS 端靠「只在有機會時
        // 才出現」自行辨識，這裡只負責告訴它「現在有機會、用什麼顏色」。
        //
        // **只在 Mortal 建議副露時才染色**。建議「過」時不要動它——
        // 把整個面板調暗會讓按鈕看起來像壞掉或被停用（實測畫面確認過），
        // 而且「沒有標記」本身就已經表達「這個機會不值得」。
        var popup = "null"
        if let top = recommendations.first, snapshot?.isCallOpportunity == true {
            switch top.actionType {
            case .chi, .pon, .kan, .hora: popup = "[0.45,1.0,0.5]"
            default: break
            }
        }

        guard !marks.isEmpty || popup != "null" else { return clear }

        let payload = (try? JSONSerialization.data(withJSONObject: marks))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "window.__nakiHighlight?.set(\(payload), \(popup));"
    }
}
