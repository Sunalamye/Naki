//
//  ActionDelayModelTests.swift
//  NakiTests
//
//  延遲模型的性質測試。
//
//  重點不是「某次算出幾秒」——那是隨機的。要驗的是**分布的性質**：
//  有沒有變異（固定值就是指紋）、有沒有上限、驗證模式有沒有真的拉長。
//
//  2026-08-07 起模型改成對照真人牌譜校準的混合分布（routine 快切群 + 真思考群，
//  手切／摸切分開、依牌種不同）。這批測試同步改成驗那些性質。
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

    /// 要有右偏的尾巴。log-normal 本身就右偏，另外還有 2% 的長考。
    ///
    /// 沒有這條尾巴，分布會缺一塊而變得可分——真人確實會偶爾停下來重數牌河。
    func testHasRightSkewedTail() {
        let xs = samples(.discard, count: 3000).sorted()
        let median = xs[xs.count / 2]
        let mean = self.mean(xs)

        XCTAssertGreaterThan(mean, median,
                             "均值必須大於中位數（右偏）；對稱或左偏都不像人")
        let long = xs.filter { $0 > median * 3 }.count
        XCTAssertGreaterThan(long, 0, "完全沒有長尾")
        XCTAssertLessThan(Double(long) / Double(xs.count), 0.15, "長尾太肥會像卡頓")
    }

    /// **摸切明顯比手切快**——真人不必從手上挑牌。
    /// 這是校準模型最主要的一個維度，前一版完全沒有（兩者同一個分布）。
    func testTsumogiriIsFasterThanTedashi() {
        func sampleMean(tsumogiri: Bool) -> Double {
            var g = SeededGenerator(seed: 42)
            return mean((0..<3000).map { _ in
                ActionDelayModel.delay(for: .discard, tile: "5m",
                                       tsumogiri: tsumogiri, using: &g)
            })
        }
        XCTAssertLessThan(sampleMean(tsumogiri: true), sampleMean(tsumogiri: false),
                          "摸切要比手切快，否則兩者是同一個分布換名字")
    }

    /// 牌種要有差異：中張思考最久，字牌最快（實測如此）。
    func testTileClassAffectsThinkTime() {
        func sampleMean(_ tile: String) -> Double {
            var g = SeededGenerator(seed: 42)
            return mean((0..<3000).map { _ in
                ActionDelayModel.delay(for: .discard, tile: tile, using: &g)
            })
        }
        XCTAssertLessThan(sampleMean("E"), sampleMean("5m"),
                          "字牌應比中張快")
        XCTAssertLessThan(sampleMean("1m"), sampleMean("5m"),
                          "么九應比中張快")
    }

    /// 牌種分類本身
    func testTileClassification() {
        XCTAssertEqual(ActionDelayModel.tileClass(of: "E"), .honor)
        XCTAssertEqual(ActionDelayModel.tileClass(of: "C"), .honor)
        XCTAssertEqual(ActionDelayModel.tileClass(of: "1m"), .terminal)
        XCTAssertEqual(ActionDelayModel.tileClass(of: "9s"), .terminal)
        XCTAssertEqual(ActionDelayModel.tileClass(of: "5p"), .middle)
        XCTAssertEqual(ActionDelayModel.tileClass(of: "5mr"), .middle)
        // 認不出來時當中張——那是思考最久的一類，最保守
        XCTAssertEqual(ActionDelayModel.tileClass(of: "???"), .middle)
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
    /// 用和牌（中位數約 1.2s，最短的一個分布）降低觸頂機率；觸頂的樣本會被
    /// `maximum` 截掉而破壞比例，所以下面跳過任何一邊已經觸頂的 index。
    func testScaleScalesEachSampleProportionally() {
        let base = samples(.hora, scale: 1.0, count: 300)
        let half = samples(.hora, scale: 0.5, count: 300)
        let doubled = samples(.hora, scale: 2.0, count: 300)

        XCTAssertEqual(base.count, 300)
        var compared = 0
        for i in 0..<base.count where doubled[i] < ActionDelayModel.maximum {
            XCTAssertEqual(half[i], base[i] * 0.5, accuracy: 1e-9,
                           "scale=0.5 應把每一筆延遲縮成一半")
            XCTAssertEqual(doubled[i], base[i] * 2.0, accuracy: 1e-9,
                           "scale=2.0 應把每一筆延遲拉成兩倍")
            compared += 1
        }
        XCTAssertGreaterThan(compared, 250, "絕大多數樣本不該觸頂，否則這條測不到比例")
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
