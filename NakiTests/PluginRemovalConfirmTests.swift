//
//  PluginRemovalConfirmTests.swift
//  NakiTests
//
//  插件移除原地確認的狀態機（設計文件 §5 WP-C 驗收 1–5、7 的邏輯層；6 需 UI 測試，待 WP-F）。
//

import XCTest

@testable import Naki

final class PluginRemovalConfirmTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // §5 WP-C 1、7：沒 arm 不能刪；確認成功即收起，刪除失敗時 View 不必另外清狀態。
    func testConfirmRemovesOnlyAfterArmAndClearsState() {
        var r = RemovalConfirm()
        XCTAssertFalse(r.confirm("a", now: t0))
        r.arm("a", now: t0)
        XCTAssertEqual(r.pending, "a")
        XCTAssertTrue(r.confirm("a", now: at(1)))
        XCTAssertEqual(r, RemovalConfirm())
        XCTAssertFalse(r.confirm("a", now: at(1.5)))
    }

    // §5 WP-C 2：guardInterval 內的確認不算數，確認面留著。
    func testConfirmWithinGuardIntervalIsIgnored() {
        var r = RemovalConfirm()
        r.arm("a", now: t0)
        XCTAssertFalse(r.confirm("a", now: at(RemovalConfirm.guardInterval - 0.001)))
        XCTAssertEqual(r.pending, "a")
        XCTAssertTrue(r.confirm("a", now: at(RemovalConfirm.guardInterval)))
    }

    // §5 WP-C 3：逾時只收起仍是同一目標的確認面；逾時常數是 4 秒。
    func testExpireClearsOnlyTheSameTarget() {
        XCTAssertEqual(RemovalConfirm.timeout, .seconds(4))
        var r = RemovalConfirm()
        r.arm("a", now: t0)
        r.arm("b", now: at(1))
        r.expire("a")
        XCTAssertEqual(r.pending, "b")
        r.expire("b")
        XCTAssertEqual(r, RemovalConfirm())
    }

    // §5 WP-C 4：A 開著時改選 B，A 收起、B 不會被刪、選回 A 不重現；選同一個不收。
    func testSwitchTargetClearsAndOtherTargetCannotBeConfirmed() {
        var r = RemovalConfirm()
        r.arm("a", now: t0)
        XCTAssertFalse(r.confirm("b", now: at(1)))
        r.switchTarget("a")
        XCTAssertEqual(r.pending, "a")
        r.switchTarget("b")
        r.switchTarget("a")
        XCTAssertNil(r.pending)
        XCTAssertFalse(r.confirm("a", now: at(2)))
    }

    // §5 WP-C 5：取消後重開，防雙擊與逾時都從新的 armedAt 起算（.task(id:) 以整個狀態為 id）。
    func testCancelThenReArmRestartsFromNewArmTime() {
        var r = RemovalConfirm()
        r.arm("a", now: t0)
        let first = r
        r.cancel()
        r.arm("a", now: at(3))
        XCTAssertNotEqual(r, first)
        XCTAssertFalse(r.confirm("a", now: at(3.1)))
        XCTAssertTrue(r.confirm("a", now: at(3.3)))
    }
}
