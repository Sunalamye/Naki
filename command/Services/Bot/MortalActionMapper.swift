//
//  MortalActionMapper.swift
//  Naki
//
//  MortalSwift action space（46 格）→ Naki `Recommendation` 的唯一解碼器。
//  自 `NativeBotController` 抽出（2026-08-05 protocol 重構），邏輯原樣搬移，
//  `AkaDiscardActionIndexTests` 是它的回歸鎖。
//
//  手牌經 `hand` closure 讀取：手牌是**遊戲**狀態（權威在
//  `NativeBotController.updateInternalState`，UI/MCP 匯出也讀那份），
//  解碼器只在紅五判斷時讀、永不寫。
//

import Foundation
import MortalSwift

struct MortalActionMapper {

    /// 讀當前手牌（tehai＋自摸）。預設空手：純索引解碼不需要手牌，
    /// 只有 0–33 的「5 該丟紅還是普通」判斷會用到。
    var hand: () -> (tehai: [Tile], tsumo: Tile?) = { ([], nil) }

    /// MortalSwift action space 中「打出紅五」的三個索引。
    ///
    /// 上游 `PlayerState.ActionIndex` 在 0.5.1 仍把它們命名為 `reserved34/35/36`
    /// 並註解成「保留 (3麻用)」——那是事實錯誤，`ObsEncoder` 一直都在用它們表示
    /// 打出紅五萬／紅五筒／紅五索（`applyAkaToCandidates`：手上只有紅五時，
    /// 普通五的格子是 0、紅五的格子才是 1）。上游 p0-1 已改名為
    /// `akaDiscardMan5/Pin5/Sou5`，但本專案 pin 的是 0.5.x，還沒有那組符號，
    /// 所以在這裡自己定名，不再讓 34–36 被當成不存在的格子。
    enum AkaDiscardIndex {
        static let man5 = 34
        static let pin5 = 35
        static let sou5 = 36
    }

    /// 將 Tile 轉換為對應的打牌動作索引
    func discardActionIndex(for tile: Tile) -> Int? {
        switch tile {
        // 紅五走專屬索引：普通五與紅五在 mask 裡是**兩個不同的動作**，
        // 都塞回 4/13/22 會讓「手上只有紅五」與「兩張都有」看起來一樣。
        case .man(5, true): return AkaDiscardIndex.man5
        case .pin(5, true): return AkaDiscardIndex.pin5
        case .sou(5, true): return AkaDiscardIndex.sou5
        case .man(let num, _): return num - 1           // 0-8 for 1m-9m
        case .pin(let num, _): return 9 + (num - 1)     // 9-17 for 1p-9p
        case .sou(let num, _): return 18 + (num - 1)    // 18-26 for 1s-9s
        case .east: return 27
        case .south: return 28
        case .west: return 29
        case .north: return 30
        case .white: return 31
        case .green: return 32
        case .red: return 33
        case .unknown: return nil
        }
    }

    /// 判斷丟 5 牌時是否應該丟紅寶牌
    /// 邏輯：如果手牌中只有紅寶牌（沒有普通的 5），才丟紅寶牌
    /// 如果有普通的 5，優先丟普通的（保留紅寶牌的價值）
    ///
    /// 註（2026-08-02）：接上 34–36 之後，這個判斷在**正常 mask 下應該永遠回 false**——
    /// 「手上只有紅五」時 encoder 會關掉普通五的格子（4/13/22）、只留 34–36，
    /// 走不到這裡。保留它是為了 mask 與手牌不一致時仍給得出合理答案，
    /// 不是因為它還在承擔紅五的判斷。（這個推論來自 encoder 原始碼，**未 live 驗證**。）
    private func shouldDiscardRedDora(suit: String) -> Bool {
        let (tehai, tsumo) = hand()
        var allTiles = tehai
        if let t = tsumo { allTiles.append(t) }

        var hasRed = false
        var hasNormal = false

        for tile in allTiles {
            switch (tile, suit) {
            case (.man(5, let red), "m"):
                if red { hasRed = true } else { hasNormal = true }
            case (.pin(5, let red), "p"):
                if red { hasRed = true } else { hasNormal = true }
            case (.sou(5, let red), "s"):
                if red { hasRed = true } else { hasNormal = true }
            default:
                continue
            }
        }

        // 只有在「有紅寶牌」且「沒有普通牌」的情況下才丟紅寶牌
        return hasRed && !hasNormal
    }

    /// mask 索引 → 推薦。
    ///
    /// 34–36（打紅五）是 live 才會遇到、又剛好靜默失敗的一組索引，
    /// `AkaDiscardActionIndexTests` 直接對它寫回歸測試。
    func actionIndexToRecommendation(_ index: Int, probability: Double) -> Recommendation? {
        typealias AI = PlayerState.ActionIndex

        // 打出紅五（34/35/36）。
        //
        // 這三格以前落到最後的 `default: return nil`，於是「唯一合法的打牌是紅五」
        // （立直後摸進紅五、手上沒有普通五）那一手會產生**空推薦**：側欄什麼都不顯示，
        // 自動打牌因為 `recommendations.isEmpty` 而不動，一路等到伺服器逾時代打。
        // 見 MortalSwift p0-1：mask 一直都會設 34–36，是下游沒有接。
        switch index {
        case AkaDiscardIndex.man5:
            return Recommendation(tile: "5mr", probability: probability, actionType: .discard)
        case AkaDiscardIndex.pin5:
            return Recommendation(tile: "5pr", probability: probability, actionType: .discard)
        case AkaDiscardIndex.sou5:
            return Recommendation(tile: "5sr", probability: probability, actionType: .discard)
        default:
            break
        }

        // 打牌動作 (0-33)
        if index >= AI.discardStart && index <= AI.discardEnd {
            // 萬子 (0-8 -> 1m-9m)
            if index <= 8 {
                let num = index + 1
                if num == 5 {
                    let tileStr = shouldDiscardRedDora(suit: "m") ? "5mr" : "5m"
                    return Recommendation(tile: tileStr, probability: probability, actionType: .discard)
                }
                return Recommendation(tile: "\(num)m", probability: probability, actionType: .discard)
            }
            // 筒子 (9-17 -> 1p-9p)
            else if index <= 17 {
                let num = index - 8
                if num == 5 {
                    let tileStr = shouldDiscardRedDora(suit: "p") ? "5pr" : "5p"
                    return Recommendation(tile: tileStr, probability: probability, actionType: .discard)
                }
                return Recommendation(tile: "\(num)p", probability: probability, actionType: .discard)
            }
            // 索子 (18-26 -> 1s-9s)
            else if index <= 26 {
                let num = index - 17
                if num == 5 {
                    let tileStr = shouldDiscardRedDora(suit: "s") ? "5sr" : "5s"
                    return Recommendation(tile: tileStr, probability: probability, actionType: .discard)
                }
                return Recommendation(tile: "\(num)s", probability: probability, actionType: .discard)
            }
            // 字牌 (27-33 -> E/S/W/N/P/F/C)
            else {
                let honorTiles = ["E", "S", "W", "N", "P", "F", "C"]
                let honorIndex = index - 27
                if honorIndex < honorTiles.count {
                    return Recommendation(tile: honorTiles[honorIndex], probability: probability, actionType: .discard)
                }
            }
        }

        // 其他動作
        switch index {
        case AI.riichi:
            return Recommendation(tile: "reach", probability: probability, actionType: .riichi)
        case AI.chiLow:
            return Recommendation(tile: "chi_0", probability: probability, actionType: .chi)
        case AI.chiMid:
            return Recommendation(tile: "chi_1", probability: probability, actionType: .chi)
        case AI.chiHigh:
            return Recommendation(tile: "chi_2", probability: probability, actionType: .chi)
        case AI.pon:
            return Recommendation(tile: "pon", probability: probability, actionType: .pon)
        case AI.kan:
            return Recommendation(tile: "kan", probability: probability, actionType: .kan)
        case AI.hora:
            return Recommendation(tile: "hora", probability: probability, actionType: .hora)
        case AI.pass:
            return Recommendation(tile: "none", probability: probability, actionType: .none)
        default:
            return nil
        }
    }
}
