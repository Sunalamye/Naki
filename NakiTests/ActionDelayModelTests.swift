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

    private func samples(_ action: Recommendation.ActionType?,
                         scale: Double = 1.0,
                         count: Int = 500) -> [TimeInterval] {
        var g = SeededGenerator(seed: 42)
        return (0..<count).map { _ in ActionDelayModel.delay(for: action, scale: scale, using: &g) }
    }

    private func mean(_ xs: [TimeInterval]) -> Double { xs.reduce(0, +) / Double(xs.count) }

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

    // MARK: - p2-6：延遲 stepper 的縮放係數

    /// scale=1.0 與「不帶 scale 參數」逐位元等價——加入 stepper 沒有偷改現行行為。
    ///
    /// 兩者用同一顆種子、同一組動作抽樣：`delay(for:using:)`（scale 預設 1.0）與
    /// `delay(for:scale:1.0,using:)` 必須給出完全相同的序列。抽樣順序沒動、scale 只乘在
    /// 最後、1.0 是乘法單位元，所以這是結構保證而不是巧合。
    func testScaleOfOneEqualsUnscaledBehavior() {
        for action in [Recommendation.ActionType.discard, .pon, .hora, Recommendation.ActionType.none] {
            var g1 = SeededGenerator(seed: 7)
            var g2 = SeededGenerator(seed: 7)
            let unscaled = (0..<300).map { _ in ActionDelayModel.delay(for: action, using: &g1) }
            let scaledOne = (0..<300).map { _ in
                ActionDelayModel.delay(for: action, scale: 1.0, using: &g2)
            }
            XCTAssertEqual(unscaled, scaledOne, "\(action.rawValue)：scale=1.0 必須等於現行行為")
        }
    }

    /// 同輸入、不同 scale → 每一筆延遲**逐筆**按係數縮放（比例正確，不是換成固定值）。
    ///
    /// 用和牌（區間＋思考停頓上限 (1.6+4.0)×2.0=11.2s < 12s 上限）避免觸頂，
    /// 所以在 0.5／1.0／2.0 三檔可以要求精確比例。同一顆種子 ⇒ 抽樣值相同 ⇒
    /// `scaled[i] == factor × base[i]`。
    func testScaleScalesEachSampleProportionally() {
        let base = samples(.hora, scale: 1.0, count: 300)
        let half = samples(.hora, scale: 0.5, count: 300)
        let doubled = samples(.hora, scale: 2.0, count: 300)

        XCTAssertEqual(base.count, 300)
        for i in 0..<base.count {
            XCTAssertEqual(half[i], base[i] * 0.5, accuracy: 1e-9,
                           "scale=0.5 應把每一筆延遲縮成一半")
            XCTAssertEqual(doubled[i], base[i] * 2.0, accuracy: 1e-9,
                           "scale=2.0 應把每一筆延遲拉成兩倍")
        }
    }

    /// 分布整體隨 scale 平移：均值單調上升，且 stepper 拉大真的變慢（driver 的驗收語意）。
    func testScaleShiftsDistributionMean() {
        let slow = mean(samples(.discard, scale: 0.5, count: 2000))
        let normal = mean(samples(.discard, scale: 1.0, count: 2000))
        let fastNo = mean(samples(.discard, scale: 3.0, count: 2000))
        XCTAssertLessThan(slow, normal, "0.5 檔應比 1.0 檔快")
        XCTAssertLessThan(normal, fastNo, "3.0 檔應比 1.0 檔慢")
    }

    /// 上限是絕對硬線：即使 scale 拉到最大，延遲仍不得超過 `maximum`（保護對局不停住）。
    func testScaleStillRespectsAbsoluteMaximum() {
        for value in samples(.discard, scale: 3.0, count: 3000) {
            XCTAssertLessThanOrEqual(value, ActionDelayModel.maximum,
                                     "scale 只放大分布，maximum 仍是絕對上限")
            XCTAssertGreaterThan(value, 0)
        }
    }
}
