//
//  AkaDiscardActionIndexTests.swift
//  NakiTests
//
//  MortalSwift p0-1 的 Naki 下游回歸鎖：mask 索引 34–36 是「打出紅五」，不是保留槽。
//
//  上游 `PlayerState.ActionIndex` 把 34–36 註解成「保留 (3麻用)」是事實錯誤：
//  `ObsEncoder.applyAkaToCandidates` 在「手上只有紅五、沒有普通五」時，會把普通五的
//  格子設 0、把紅五的格子（34/35/36）設 1。
//
//  下游因此壞了兩處：
//  1. `updateAvailableActions` 掃 `mask.prefix(discardEnd + 1)` ＝ `prefix(34)`，
//     看不到紅五格 → 那一手被判成「沒有牌可打」。（該方法本來就零呼叫，已隨 p1-4 移除。）
//  2. `actionIndexToRecommendation(34/35/36)` 落到 `default: return nil`
//     → 推薦是空的 → 側欄空白、自動打牌因為 `recommendations.isEmpty` 而不動，
//     一路等到伺服器逾時代打。實測情境：立直後摸進紅五，唯一合法打就是那張紅五。
//
//  這批測試鎖第 2 條（第 1 條的程式碼已不存在，靠 `noDiscardIndexIsSilentlyDropped`
//  確保沒有人把「打牌索引到 33 為止」的假設寫回來）。
//

import XCTest
import MortalSwift

@testable import Naki

@MainActor
final class AkaDiscardActionIndexTests: XCTestCase {

    /// 34/35/36 必須解成紅五萬／紅五筒／紅五索的打牌，不是 nil
    func testAkaDiscardIndexesDecodeToRedFives() {
        let mapper = MortalActionMapper()

        let expected: [(Int, String)] = [(34, "5mr"), (35, "5pr"), (36, "5sr")]
        for (index, tile) in expected {
            guard let rec = mapper.actionIndexToRecommendation(index, probability: 0.9) else {
                return XCTFail("index \(index) 應解成打 \(tile)，實際是 nil（推薦會整批消失）")
            }
            XCTAssertEqual(rec.actionType, .discard, "index \(index) 應是打牌")
            XCTAssertEqual(rec.displayTile, tile)
            XCTAssertEqual(rec.probability, 0.9, accuracy: 0.0001)
        }
    }

    /// 一般打牌索引不受影響（確認上面不是把所有索引都改掉的假綠燈）
    func testNormalDiscardIndexesUnchanged() {
        let mapper = MortalActionMapper()

        let expected: [(Int, String)] = [
            (0, "1m"), (8, "9m"),
            (9, "1p"), (17, "9p"),
            (18, "1s"), (26, "9s"),
            (27, "E"), (33, "C")
        ]
        for (index, tile) in expected {
            let rec = mapper.actionIndexToRecommendation(index, probability: 0.5)
            XCTAssertEqual(rec?.displayTile, tile, "index \(index)")
            XCTAssertEqual(rec?.actionType, .discard, "index \(index)")
        }
    }

    /// 打牌區間（含紅五）沒有任何索引會被靜默丟掉
    ///
    /// 「回 nil」在這條路上不是錯誤而是**沉默**：recommendations 少一筆，
    /// 少到零就變成「AI 沒有意見」，看不出是解碼漏了。
    func testNoDiscardIndexIsSilentlyDropped() {
        let mapper = MortalActionMapper()
        for index in 0...36 {
            XCTAssertNotNil(mapper.actionIndexToRecommendation(index, probability: 0.1),
                            "打牌索引 \(index) 被解成 nil → 該手推薦會缺一筆")
        }
    }

    /// 非打牌動作仍走原本的對應
    func testNonDiscardActionsStillMap() {
        let mapper = MortalActionMapper()
        typealias AI = PlayerState.ActionIndex

        XCTAssertEqual(mapper.actionIndexToRecommendation(AI.riichi, probability: 0.5)?.actionType,
                       .riichi)
        XCTAssertEqual(mapper.actionIndexToRecommendation(AI.pon, probability: 0.5)?.actionType,
                       .pon)
        XCTAssertEqual(mapper.actionIndexToRecommendation(AI.hora, probability: 0.5)?.actionType,
                       .hora)
        XCTAssertEqual(mapper.actionIndexToRecommendation(AI.pass, probability: 0.5)?.actionType,
                       Recommendation.ActionType.none)
    }
}
