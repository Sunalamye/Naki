//
//  ActionDelayModelTests.swift
//  NakiTests
//
//  延遲模型的性質測試。
//
//  重點不是「某次算出幾秒」——那是隨機的。要驗的是**分布的性質**：
//  有沒有變異（固定值就是指紋）、有沒有上限、驗證模式有沒有真的拉長。
//

import XCTest

@testable import Naki

final class ActionDelayModelTests: XCTestCase {

    /// 可重現的亂數，讓測試不會偶爾紅
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    override func tearDown() {
        ActionDelayModel.verificationScale = 1.0
        super.tearDown()
    }

    private func samples(_ action: Recommendation.ActionType?, count: Int = 500) -> [TimeInterval] {
        var g = SeededGenerator(seed: 42)
        return (0..<count).map { _ in ActionDelayModel.delay(for: action, using: &g) }
    }

    /// 舊實作每種動作回固定值——那正是要消除的指紋
    func testDelayIsNotConstant() {
        for action in [Recommendation.ActionType.discard, .pon, .hora, Recommendation.ActionType.none] {
            let unique = Set(samples(action).map { ($0 * 1000).rounded() })
            XCTAssertGreaterThan(unique.count, 50,
                                 "\(action.rawValue) 的延遲幾乎沒有變異，等於固定值")
        }
    }

    /// 動作類型之間要有可辨識的差異，不是同一個分布換名字
    func testActionTypesDifferInCentralTendency() {
        func mean(_ xs: [TimeInterval]) -> Double { xs.reduce(0, +) / Double(xs.count) }
        let horaMean = mean(samples(.hora))
        let discardMean = mean(samples(.discard))
        let callMean = mean(samples(.pon))

        // 和牌是明確的單鍵，應該最快；副露要在彈出面板再選一次
        XCTAssertLessThan(horaMean, discardMean)
        XCTAssertLessThan(horaMean, callMean)
    }

    /// 永遠不能超過上限——延遲再長也不該讓對局停住
    func testNeverExceedsMaximum() {
        for action in [Recommendation.ActionType.discard, .pon, .hora] {
            for value in samples(action, count: 2000) {
                XCTAssertLessThanOrEqual(value, ActionDelayModel.maximum)
                XCTAssertGreaterThan(value, 0)
            }
        }
    }

    /// 要有右偏的尾巴（偶發思考停頓），否則只是一個乾淨的均勻區間
    func testHasOccasionalLongPause() {
        let xs = samples(.discard, count: 2000)
        let base = ActionDelayModel.discard.high
        let long = xs.filter { $0 > base }.count
        XCTAssertGreaterThan(long, 0, "完全沒有思考停頓，分布是純均勻的")
        // 停頓應該是少數；太多就不像人而像卡頓
        XCTAssertLessThan(Double(long) / Double(xs.count), 0.30)
    }

    /// 驗證模式要真的把窗口拉長，否則截圖仍然來不及
    func testVerificationScaleLengthensDelay() {
        let normal = samples(.discard, count: 300)
        ActionDelayModel.verificationScale = 3.0
        let scaled = samples(.discard, count: 300)

        func mean(_ xs: [TimeInterval]) -> Double { xs.reduce(0, +) / Double(xs.count) }
        XCTAssertGreaterThan(mean(scaled), mean(normal) * 1.5)
        // 但仍受上限保護
        XCTAssertLessThanOrEqual(scaled.max() ?? 0, ActionDelayModel.maximum)
    }

    /// 同一顆種子必須給同一串結果，否則測試本身不可信
    func testDeterministicWithSameSeed() {
        XCTAssertEqual(samples(.discard, count: 20), samples(.discard, count: 20))
    }
}
