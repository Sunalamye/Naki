//
//  AutoPlayGateTests.swift
//  NakiTests
//
//  自動打牌觸發閘門的回歸測試。
//
//  這些案例來自 2026-08-01 的兩個 live bug：
//
//  1. 副露機會出現時，輪詢在推論完成前看到空推薦，把它當成「模型判斷不做」
//     主動送出「過」。實測一次模型說碰 85.9%，0.4 秒後仍送出過。
//  2. 「沒有 oplist 就別觸發」與「有對局就等待」兩道閘門互相打架造成死結。
//
//  兩個都不是單一條件寫錯，而是看不出新條件會擋掉哪條既有路徑。
//

import XCTest

@testable import Naki

final class AutoPlayGateTests: XCTestCase {

    // MARK: - Fixtures

    private func snapshot(types: [UInt32],
                          capturedAt: Date = Date(),
                          sequence: UInt64 = 1) -> LiqiOperationSnapshot {
        LiqiOperationSnapshot(
            sequence: sequence,
            seat: 0,
            operations: types.map { LiqiOperation(rawType: $0, combination: []) },
            timeAdd: 0,
            timeFixed: 300,
            contextTile: nil,
            source: "test",
            capturedAt: capturedAt)
    }

    private func rec(_ action: Recommendation.ActionType,
                     tile: String = "1m",
                     prob: Double = 0.9) -> Recommendation {
        // 與 AutoPlayDecisionResolverTests 用同一個 MJAI 字串 initializer
        Recommendation(tile: action == .discard ? tile : action.rawValue,
                       probability: prob,
                       actionType: action)
    }

    private func input(auto: Bool = true,
                       inFlight: Bool = false,
                       snapshot: LiqiOperationSnapshot?,
                       recs: [Recommendation] = [],
                       now: Date = Date(),
                       grace: TimeInterval = 2.0) -> AutoPlayGate.Input {
        .init(isAutoMode: auto,
              hasActionInFlight: inFlight,
              snapshot: snapshot,
              recommendations: recs,
              now: now,
              callPassGrace: grace)
    }

    // MARK: - 基本閘門

    func testSkipsWhenNotAutoMode() {
        let d = AutoPlayGate.evaluate(input(auto: false, snapshot: snapshot(types: [1])))
        XCTAssertEqual(d, .skip(.notAutoMode))
    }

    func testSkipsWhenActionInFlight() {
        let d = AutoPlayGate.evaluate(input(inFlight: true, snapshot: snapshot(types: [1])))
        XCTAssertEqual(d, .skip(.actionInFlight))
    }

    /// 沒有伺服器授權就不動——fail closed
    func testSkipsWithoutOplist() {
        let d = AutoPlayGate.evaluate(input(snapshot: nil, recs: [rec(.discard)]))
        XCTAssertEqual(d, .skip(.noOplist))
    }

    // MARK: - 副露送「過」的競態（真實 bug）

    /// 推論還沒完成就送「過」＝把模型的建議蓋掉。這是實測發生過的。
    func testDoesNotPassBeforeInferenceCompletes() {
        let now = Date()
        let fresh = snapshot(types: [3], capturedAt: now.addingTimeInterval(-0.4))   // 碰，剛到 0.4 秒
        let d = AutoPlayGate.evaluate(input(snapshot: fresh, recs: [], now: now))
        XCTAssertEqual(d, .skip(.awaitingInference),
                       "在寬限期內就送過，會蓋掉還沒算完的推薦")
    }

    /// 過了寬限期仍無推薦，才視為「模型判斷不做」
    func testPassesAfterGraceWhenStillNoRecommendation() {
        let now = Date()
        let old = snapshot(types: [3], capturedAt: now.addingTimeInterval(-3.0))
        let d = AutoPlayGate.evaluate(input(snapshot: old, recs: [], now: now))
        XCTAssertEqual(d, .sendPass)
    }

    /// 有推薦時完全不該走到「送過」那條路，不管寬限期
    func testNeverPassesWhenRecommendationExists() {
        let now = Date()
        let old = snapshot(types: [3], capturedAt: now.addingTimeInterval(-30))
        let d = AutoPlayGate.evaluate(input(snapshot: old, recs: [rec(.pon)], now: now))
        XCTAssertEqual(d, .proceed)
    }

    /// 非副露機會（例如只剩打牌）而無推薦時，不要亂送過
    func testDoesNotPassWhenNotACallOpportunity() {
        let now = Date()
        let old = snapshot(types: [1], capturedAt: now.addingTimeInterval(-30))
        let d = AutoPlayGate.evaluate(input(snapshot: old, recs: [], now: now))
        XCTAssertEqual(d, .skip(.noRecommendation))
    }

    // MARK: - 和牌絕不放過（漏和的成因）

    /// 伺服器提供和牌時，模型沒意見也必須交給 resolver
    func testForcesHoraWhenServerOffersItAndModelIsSilent() {
        let now = Date()
        // 9 = 榮和。它同時是 isCallOpportunity，所以舊版會走到「送過」＝自己棄和
        let s = snapshot(types: [9], capturedAt: now.addingTimeInterval(-30))
        let d = AutoPlayGate.evaluate(input(snapshot: s, recs: [], now: now))
        XCTAssertEqual(d, .forceHora)
    }

    /// 和牌優先於寬限期——不能因為「還在等推論」就錯過
    func testHoraOverridesGracePeriod() {
        let now = Date()
        let fresh = snapshot(types: [8], capturedAt: now.addingTimeInterval(-0.1))   // 自摸
        let d = AutoPlayGate.evaluate(input(snapshot: fresh, recs: [], now: now))
        XCTAssertEqual(d, .forceHora)
    }

    /// 碰＋榮和同時可用且模型沒意見 → 仍然和牌，不是送過
    func testHoraWinsOverPassWhenBothAvailable() {
        let now = Date()
        let s = snapshot(types: [3, 9], capturedAt: now.addingTimeInterval(-30))
        let d = AutoPlayGate.evaluate(input(snapshot: s, recs: [], now: now))
        XCTAssertEqual(d, .forceHora)
    }

    // MARK: - 打牌回合檢查

    /// 已換成別家回合時不要送遲到的打牌
    func testSkipsStaleDiscard() {
        let s = snapshot(types: [3])   // 只剩碰的機會，不是我們打牌
        let d = AutoPlayGate.evaluate(input(snapshot: s, recs: [rec(.discard)]))
        XCTAssertEqual(d, .skip(.notMyDiscardTurn))
    }

    func testProceedsOnRealDiscardTurn() {
        let s = snapshot(types: [1])
        let d = AutoPlayGate.evaluate(input(snapshot: s, recs: [rec(.discard)]))
        XCTAssertEqual(d, .proceed)
    }

    /// 立直也算輪到自己打牌
    func testRiichiCountsAsDiscardTurn() {
        let s = snapshot(types: [1, 7])
        let d = AutoPlayGate.evaluate(input(snapshot: s, recs: [rec(.discard)]))
        XCTAssertEqual(d, .proceed)
    }

    // MARK: - 閘門互不打架

    /// 所有 skip 都必須帶原因——沒有原因的 skip 就是查不出來的死結
    func testEverySkipCarriesAReason() {
        let cases: [AutoPlayGate.Input] = [
            input(auto: false, snapshot: snapshot(types: [1])),
            input(inFlight: true, snapshot: snapshot(types: [1])),
            input(snapshot: nil),
            input(snapshot: snapshot(types: [3], capturedAt: Date()), recs: []),
            input(snapshot: snapshot(types: [1], capturedAt: Date(timeIntervalSinceNow: -30)), recs: []),
            input(snapshot: snapshot(types: [3]), recs: [rec(.discard)])
        ]
        for c in cases {
            if case .skip(let reason) = AutoPlayGate.evaluate(c) {
                XCTAssertFalse(reason.rawValue.isEmpty)
            }
        }
    }
}
