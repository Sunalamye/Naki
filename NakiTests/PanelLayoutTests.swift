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
    }
}
