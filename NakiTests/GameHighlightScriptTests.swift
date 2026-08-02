//
//  GameHighlightScriptTests.swift
//  NakiTests
//
//  p1-4 回歸鎖：模式 `.off` 必須真的把遊戲內高亮關掉。
//
//  舊行為：`AutoPlayMode.showRecommendation` 沒有任何讀取者。選了「關閉」之後
//  自動送出的確被擋住，但側欄照列推薦、`__nakiHighlight` 照染色——
//  使用者關掉的東西還在動。這是語意分歧，不是小瑕疵：
//  「關閉」在畫面上跟「推薦」看起來一模一樣。
//
//  ⚠️ 這裡驗的是「送出去的腳本內容」。JS 端有沒有真的把那張牌染對顏色
//  仍然只能 live 驗證（WebGL draw hook 沒有 screenshot regression）。
//

import XCTest

@testable import Naki

final class GameHighlightScriptTests: XCTestCase {

    // MARK: - Fixtures

    private func rec(_ action: Recommendation.ActionType, _ tile: String) -> Recommendation {
        Recommendation(tile: tile.isEmpty ? action.rawValue : tile,
                       probability: 0.9,
                       actionType: action)
    }

    private func snapshot(_ types: [LiqiOperationType],
                          combination: [String] = []) -> LiqiOperationSnapshot {
        LiqiOperationSnapshot(
            sequence: 1,
            seat: 0,
            operations: types.map { LiqiOperation(rawType: $0.rawValue, combination: combination) },
            timeAdd: 0,
            timeFixed: 300,
            contextTile: "3m",
            source: "test",
            capturedAt: Date())
    }

    // MARK: - `.off` 一律清空

    /// 有推薦、有手牌、還有副露機會——`.off` 仍然只能送 clear()
    func testOffModeAlwaysClears() {
        let script = GameHighlightScript.make(
            mode: .off,
            recommendations: [rec(.discard, "5m")],
            tehaiTiles: ["1m", "2m", "5m"],
            snapshot: snapshot([.chi], combination: ["3m|4m"]))

        XCTAssertEqual(script, GameHighlightScript.clear,
                       "關閉模式必須清空遊戲內高亮，不得繼續染色")
        XCTAssertFalse(script.contains("set("), "關閉模式不得送出任何 set()")
    }

    /// 副露機會（會染彈出面板）在 `.off` 下也要清空
    func testOffModeClearsCallPopupToo() {
        let script = GameHighlightScript.make(
            mode: .off,
            recommendations: [rec(.pon, "")],
            tehaiTiles: [],
            snapshot: snapshot([.pon], combination: ["3m|3m"]))

        XCTAssertEqual(script, GameHighlightScript.clear)
    }

    // MARK: - 切回來要恢復

    /// `.recommend` / `.auto` 都要照常染色——確認上面不是「永遠清空」的假綠燈
    func testRecommendAndAutoModesStillHighlight() {
        for mode in [AutoPlayMode.recommend, .auto] {
            let script = GameHighlightScript.make(
                mode: mode,
                recommendations: [rec(.discard, "5m")],
                tehaiTiles: ["1m", "5m"],
                snapshot: nil)

            XCTAssertTrue(script.contains("__nakiHighlight?.set("),
                          "\(mode.rawValue) 模式應送出 set()，實際: \(script)")
            XCTAssertTrue(script.contains("\"5m\"") || script.contains("5m"),
                          "推薦牌應出現在 payload 裡")
            XCTAssertNotEqual(script, GameHighlightScript.clear)
        }
    }

    /// 沒有推薦時本來就是 clear——`.off` 的 clear 不是靠這條混過去的
    func testNoRecommendationClearsEvenWhenShowing() {
        let script = GameHighlightScript.make(
            mode: .auto, recommendations: [], tehaiTiles: ["1m"], snapshot: nil)
        XCTAssertEqual(script, GameHighlightScript.clear)
    }

    // MARK: - 內容（非 off 路徑的既有行為不得被改壞）

    /// 推薦牌染綠、其餘手牌調淡
    func testDiscardHighlightsRecommendedAndDimsRest() {
        let script = GameHighlightScript.make(
            mode: .auto,
            recommendations: [rec(.discard, "5m")],
            tehaiTiles: ["1m", "5m", "9p"],
            snapshot: nil)

        XCTAssertTrue(script.contains("0.45"), "推薦牌的綠色分量應在 payload 裡")
        XCTAssertTrue(script.contains("0.62"), "其餘手牌的調淡分量應在 payload 裡")
        // 推薦牌不得同時被調淡（Set 去重 + 排除自己）
        XCTAssertEqual(script.components(separatedBy: "\"5m\"").count - 1, 1,
                       "推薦牌只能出現一次（不得又染綠又調淡）")
    }

    /// 建議「過」時不要染彈出面板——把面板調暗會讓按鈕看起來像壞掉
    func testPassRecommendationDoesNotTintPopup() {
        let script = GameHighlightScript.make(
            mode: .auto,
            recommendations: [rec(.none, "")],
            tehaiTiles: [],
            snapshot: snapshot([.pon]))

        XCTAssertEqual(script, GameHighlightScript.clear,
                       "建議過時沒有任何標記，應直接 clear")
    }

    /// 建議副露時才染彈出面板
    func testCallRecommendationTintsPopup() {
        let script = GameHighlightScript.make(
            mode: .auto,
            recommendations: [rec(.pon, "")],
            tehaiTiles: [],
            snapshot: snapshot([.pon], combination: ["3m|3m"]))

        XCTAssertTrue(script.contains("[0.45,1.0,0.5]"), "副露面板應被染色，實際: \(script)")
    }
}
