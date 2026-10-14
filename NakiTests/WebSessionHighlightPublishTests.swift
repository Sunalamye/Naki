import XCTest

@testable import Naki

/// `WebSession.syncHighlight` 實際送給頁面的腳本。牌面染色已移交插件，這裡只鎖發布內容。
@MainActor
final class WebSessionHighlightPublishTests: XCTestCase {

    nonisolated deinit {}

    private func rec(_ action: Recommendation.ActionType, _ tile: String = "") -> Recommendation {
        Recommendation(tile: tile.isEmpty ? action.rawValue : tile, probability: 0.9, actionType: action)
    }

    private func snapshot(_ types: [LiqiOperationType], combination: [String] = []) -> LiqiOperationSnapshot {
        LiqiOperationSnapshot(
            sequence: 7, seat: 0,
            operations: types.map { LiqiOperation(rawType: $0.rawValue, combination: combination) },
            timeAdd: 0, timeFixed: 300, contextTile: "3m", source: "test", capturedAt: Date())
    }

    private func script(show: Bool = true,
                        _ recs: [Recommendation],
                        tehai: [String] = [],
                        tsumo: String? = nil,
                        snapshot: LiqiOperationSnapshot? = nil,
                        sequence: UInt64? = nil) -> String {
        WebSession.recommendationScript(show: show, recommendations: recs, tehaiTiles: tehai,
                                        tsumoTile: tsumo, snapshot: snapshot,
                                        recommendationsOplistSequence: sequence)
    }

    private func context(_ script: String) throws -> [String: Any] {
        let line = try XCTUnwrap(script.split(separator: "\n").first {
            $0.hasPrefix("window.__nakiRecommendationContext = ")
        })
        let json = line.dropFirst("window.__nakiRecommendationContext = ".count).dropLast()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testRecommendationsJSONSurvivesNonFiniteProbability() throws {
        let recs = [Recommendation(tile: "1m", probability: .nan, actionType: .discard),
                    Recommendation(tile: "2m", probability: .infinity, actionType: .discard)]
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(WebSession.recommendationsJSON(recs).utf8)) as? [[String: Any]])
        XCTAssertEqual(parsed.map { $0["probability"] as? Double }, [0, 0])
    }

    func testOffPublishesNothingAndClears() throws {
        let out = script(show: false, [rec(.pon)], tehai: ["1m"], tsumo: "2m",
                         snapshot: snapshot([.pon], combination: ["3m|3m"]), sequence: 7)
        XCTAssertTrue(out.contains("window.__nakiRecommendations = [];"))
        XCTAssertTrue(out.hasSuffix(GameHighlightScript.clear))
        let ctx = try context(out)
        XCTAssertEqual(ctx["hand"] as? [String], [])
        XCTAssertEqual(ctx["callTiles"] as? [String], [])
    }

    func testShownPublishesRecommendationsAndHandWithDrawnTile() throws {
        let out = script([rec(.discard, "5m")], tehai: ["1m", "5m"], tsumo: "9p")
        XCTAssertFalse(out.contains("window.__nakiRecommendations = [];"))
        XCTAssertFalse(out.hasSuffix(GameHighlightScript.clear))
        XCTAssertEqual(try context(out)["hand"] as? [String], ["1m", "5m", "9p"])
    }

    func testPonPublishesCombinationAndCallOpportunity() throws {
        let ctx = try context(script([rec(.pon)], snapshot: snapshot([.pon], combination: ["3m|3m"]), sequence: 7))
        XCTAssertEqual(ctx["callTiles"] as? [String], ["3m", "3m"])
        XCTAssertEqual(ctx["isCallOpportunity"] as? Bool, true)
    }

    func testKanWithSeveralCombinationsPublishesNoCallTiles() throws {
        let ctx = try context(script([rec(.kan)], snapshot: snapshot([.minkan], combination: ["4m|4m|4m", "4m|4m|0m"]),
                                     sequence: 7))
        XCTAssertEqual(ctx["callTiles"] as? [String], [])
    }

    func testSnapshotFromAnotherOplistPublishesNoCall() throws {
        let ctx = try context(script([rec(.pon)], snapshot: snapshot([.pon], combination: ["3m|3m"]), sequence: 6))
        XCTAssertEqual(ctx["callTiles"] as? [String], [])
        XCTAssertEqual(ctx["isCallOpportunity"] as? Bool, false)
    }
}
