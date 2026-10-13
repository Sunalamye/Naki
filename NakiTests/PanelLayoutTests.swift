//
//  PanelLayoutTests.swift
//  NakiTests
//
//  面板寬度、預設顯示、點擊目標與減少動態的純決策。
//

import SwiftUI
import XCTest

@testable import Naki

final class PanelLayoutTests: XCTestCase {

    func testMinTapTargetMeetsHIG() {
        XCTAssertEqual(PanelLayout.minTapTarget, 44)
    }

    func testPanelWidthByHorizontalSizeClass() {
        XCTAssertEqual(PanelLayout.iOSPanelWidth(horizontal: .compact), 220)
        XCTAssertEqual(PanelLayout.iOSPanelWidth(horizontal: .regular), 300)
        XCTAssertEqual(PanelLayout.iOSPanelWidth(horizontal: nil), 220)
    }

    func testPanelStartsHiddenOnlyWhenCompactWidthRegularHeight() {
        XCTAssertFalse(PanelLayout.startsVisible(horizontal: .compact, vertical: .regular))
        XCTAssertTrue(PanelLayout.startsVisible(horizontal: .compact, vertical: .compact))
        XCTAssertTrue(PanelLayout.startsVisible(horizontal: .regular, vertical: .regular))
        XCTAssertTrue(PanelLayout.startsVisible(horizontal: .regular, vertical: .compact))
        XCTAssertTrue(PanelLayout.startsVisible(horizontal: nil, vertical: nil))
    }

    func testReduceMotionDisablesAnimation() {
        XCTAssertNil(PanelLayout.animation(reduceMotion: true))
        XCTAssertNil(PanelLayout.animation(.linear, reduceMotion: true))
        XCTAssertNotNil(PanelLayout.animation(reduceMotion: false))
        XCTAssertEqual(PanelLayout.animation(.linear, reduceMotion: false), .linear)
        XCTAssertEqual(PanelLayout.animation(reduceMotion: false), PanelLayout.standard)
    }

    /// 三個動畫 token 的時長都不超過 0.4s（Doherty 閾值）；`Animation` 可比較，鎖住字面值。
    func testAnimationTokenDurations() {
        XCTAssertEqual(PanelLayout.valueChange, .smooth(duration: 0.4))
        XCTAssertEqual(PanelLayout.exit, .smooth(duration: 0.18))
        XCTAssertEqual(PanelLayout.standard, .easeInOut(duration: 0.2))
    }

    /// 端點用半步容差比：Stepper 步進累加出來的 0.5 不一定與字面值相等。
    func testDelayBoundLabel() {
        let range = SettingsStore.actionDelayRange, step = SettingsStore.actionDelayStep
        XCTAssertEqual(ActionDelayStepper.delayBoundLabel(range.lowerBound), "最快")
        XCTAssertEqual(ActionDelayStepper.delayBoundLabel(range.upperBound), "最慢")
        XCTAssertEqual(ActionDelayStepper.delayBoundLabel((0..<5).reduce(1.0) { v, _ in v - step }), "最快")
        XCTAssertEqual(ActionDelayStepper.delayBoundLabel((0..<20).reduce(1.0) { v, _ in v + step }), "最慢")
        XCTAssertNil(ActionDelayStepper.delayBoundLabel(range.lowerBound + step))
        XCTAssertNil(ActionDelayStepper.delayBoundLabel(range.upperBound - step))
        XCTAssertNil(ActionDelayStepper.delayBoundLabel(1.0))
    }
}
