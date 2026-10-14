//
//  RyukyokuActionIndexTests.swift
//  NakiTests
//
//  mask 索引 44 是九種九牌（`PlayerState.ActionIndex.ryukyoku`，MortalSwift da7238c 的
//  `ObsEncoder` 在 `canRyukyoku` 時設 mask[44]）。解碼器漏掉它時，推薦清單少一列，
//  自動模式會送出第一列的打牌而不是模型選的九種九牌。
//

import XCTest
import MortalSwift

@testable import Naki

@MainActor
final class RyukyokuActionIndexTests: XCTestCase {

    func testIndex44DecodesToRyukyoku() {
        let rec = MortalActionMapper().actionIndexToRecommendation(44, probability: 0.8)
        XCTAssertEqual(rec?.actionType, .ryukyoku)
        XCTAssertEqual(rec?.displayTile, "ryukyoku")
        XCTAssertEqual(PlayerState.ActionIndex.ryukyoku, 44)
    }

    /// 模型選九種九牌、oplist 有 kyushu：resolver 送出 `.ryukyoku`，不是第二列的打牌
    func testResolverSendsRyukyokuWhenItIsTheTopRecommendation() {
        let store = LiqiOperationStore()
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .discard), LiqiOperation(type: .kyushu)],
                                    timeFixed: 300_000, contextTile: "1m", source: "ActionDealTile")
        let mapper = MortalActionMapper()
        let recommendations = [(44, 0.7), (0, 0.2)]
            .compactMap { mapper.actionIndexToRecommendation($0.0, probability: $0.1) }

        let decision = AutoPlayDecisionResolver.resolve(
            snapshot: snapshot, recommendations: recommendations, mode: .auto, seat: 0,
            isSanma: false, sanmaCapableDecision: false,
            recommendationsOplistSequence: snapshot.sequence)

        XCTAssertEqual(decision, .send(action: .ryukyoku, tile: "ryukyoku"))
    }
}
