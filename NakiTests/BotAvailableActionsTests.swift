//
//  BotAvailableActionsTests.swift
//  NakiTests
//
//  p1-4 回歸鎖：「可用動作」六個欄位必須是真值。
//
//  舊行為：`canDiscard/canRiichi/canChi/canPon/canKan/canAgari` 的唯一寫入點是
//  `NativeBotController.updateAvailableActions()`，而那個 private 方法**零呼叫**
//  （`updateInternalState` 尾巴只留了「移到 react() 後處理」的註解）。
//  於是 `BotStatusView` 的六個徽章與 `/bot/status` 的六個欄位永遠是 false——
//  介面上有東西、背後沒有任何資料，正是 AUDIT §13 要防的假功能。
//
//  現在它們是協定層 oplist 的投影。這批測試鎖住那個對應關係：
//  只要有人把 mask 掃描或恆 false 寫回去，這裡就會紅。
//

import XCTest

@testable import Naki

final class BotAvailableActionsTests: XCTestCase {

    // MARK: - Fixtures

    private func snapshot(_ types: [LiqiOperationType],
                          seat: Int = 0,
                          sequence: UInt64 = 1) -> LiqiOperationSnapshot {
        LiqiOperationSnapshot(
            sequence: sequence,
            seat: seat,
            operations: types.map { LiqiOperation(rawType: $0.rawValue) },
            timeAdd: 0,
            timeFixed: 300,
            contextTile: "9s",
            source: "test",
            capturedAt: Date())
    }

    // MARK: - 沒有授權 = 全部 false

    /// 沒有 oplist 代表「伺服器沒有授權任何動作」，不是「不知道」
    func testNoSnapshotMeansNothingAvailable() {
        let actions = BotAvailableActions(snapshot: nil)
        XCTAssertEqual(actions, .none)
        XCTAssertFalse(actions.hasAny)
    }

    // MARK: - 逐項對應

    func testDiscardAndRiichi() {
        let actions = BotAvailableActions(snapshot: snapshot([.discard, .riichi]))
        XCTAssertTrue(actions.canDiscard)
        XCTAssertTrue(actions.canRiichi)
        XCTAssertFalse(actions.canChi)
        XCTAssertFalse(actions.canPon)
        XCTAssertFalse(actions.canKan)
        XCTAssertFalse(actions.canAgari)
    }

    func testChiAndPon() {
        let actions = BotAvailableActions(snapshot: snapshot([.chi, .pon]))
        XCTAssertTrue(actions.canChi)
        XCTAssertTrue(actions.canPon)
        XCTAssertFalse(actions.canDiscard)
    }

    /// 槓有三種，任一種都算「可以槓」——只認其中一種會讓徽章在暗槓時不亮
    func testEveryKanVariantCounts() {
        for kan in [LiqiOperationType.ankan, .kakan, .minkan] {
            let actions = BotAvailableActions(snapshot: snapshot([kan]))
            XCTAssertTrue(actions.canKan, "\(kan) 應該算可槓")
        }
    }

    /// 和了兩種（自摸 / 榮和）都要點亮
    func testBothHoraVariantsCount() {
        for hora in [LiqiOperationType.tsumo, .ron] {
            let actions = BotAvailableActions(snapshot: snapshot([hora]))
            XCTAssertTrue(actions.canAgari, "\(hora) 應該算可和")
        }
    }

    /// 真實漏和那一手：ops = [discard, riichi, tsumo]
    func testRealMissedHoraSnapshot() {
        let actions = BotAvailableActions(snapshot: snapshot([.discard, .riichi, .tsumo]))
        XCTAssertTrue(actions.canDiscard)
        XCTAssertTrue(actions.canRiichi)
        XCTAssertTrue(actions.canAgari)
        XCTAssertTrue(actions.hasAny)
    }

    /// 只有「過」以外的無關操作時不得亂點亮
    func testUnknownTypeLightsNothing() {
        let unknown = LiqiOperationSnapshot(
            sequence: 1, seat: 0,
            operations: [LiqiOperation(rawType: 99)],
            timeAdd: 0, timeFixed: 300,
            contextTile: nil, source: "test", capturedAt: Date())
        XCTAssertEqual(BotAvailableActions(snapshot: unknown), .none)
    }

    // MARK: - BotStatus 套用

    func testApplyAvailableActionsWritesAllSixFields() {
        var status = BotStatus()
        XCTAssertFalse(status.hasAvailableAction)

        status.applyAvailableActions(BotAvailableActions(snapshot: snapshot([.discard, .ron])))

        XCTAssertTrue(status.canDiscard)
        XCTAssertTrue(status.canAgari)
        XCTAssertTrue(status.hasAvailableAction)

        // 再套一次空的必須把旗標關掉（不能只會點亮、不會熄滅）
        status.applyAvailableActions(.none)
        XCTAssertFalse(status.hasAvailableAction)
    }

    // MARK: - Controller 端（`/bot/status` 與側欄徽章的實際來源）

    /// `NativeBotController` 的六個 canXxx 必須跟著 store 的 `pending` 走。
    ///
    /// 這條在修好之前一定紅：舊實作永遠回 false。
    @MainActor
    func testControllerFlagsFollowPendingOplist() {
        let store = LiqiOperationStore.shared
        store.reset()
        defer { store.reset() }

        let controller = NativeBotController()
        XCTAssertFalse(controller.canPon, "沒有 oplist 時不得有任何可用動作")

        store.record(seat: 0, operations: [LiqiOperation(type: .pon)], source: "test")

        XCTAssertTrue(controller.canPon, "oplist 有碰，徽章與 /bot/status 就必須是 true")
        XCTAssertFalse(controller.canChi)
        XCTAssertTrue(controller.botState.canPon)

        // 送出後標記已處理 → pending 消失 → 徽章要熄滅（不能停在上一批機會）
        store.markCurrentHandled()
        XCTAssertFalse(controller.canPon, "已處理過的 oplist 不該繼續點亮徽章")
    }

    /// `GameStateManager.syncFrom` 是 `/bot/status` 的實際資料面，必須帶到同一組值
    @MainActor
    func testGameStateManagerSyncCarriesRealFlags() {
        let store = LiqiOperationStore.shared
        store.reset()
        defer { store.reset() }

        store.record(seat: 0,
                     operations: [LiqiOperation(type: .discard), LiqiOperation(type: .riichi)],
                     source: "test")

        let manager = GameStateManager()
        manager.syncFrom(controller: NativeBotController())

        XCTAssertTrue(manager.botStatus.canDiscard)
        XCTAssertTrue(manager.botStatus.canRiichi)
        XCTAssertFalse(manager.botStatus.canAgari)
    }
}
