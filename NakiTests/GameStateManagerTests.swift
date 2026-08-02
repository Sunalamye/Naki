//
//  GameStateManagerTests.swift
//  NakiTests
//
//  p0-3 回歸鎖：`GameStateManager` 的寫入必須在**同一個 main runloop turn** 內就讀得到。
//
//  舊版每個 mutator 都自己包一層 `DispatchQueue.main.async`，而呼叫端
//  （`WebViewModel` / `LegacyWebViewModel`，兩者皆 `@MainActor`）本來就在 main 上。
//  結果是：SwiftUI 讀 WebViewModel 的鏡像屬性拿到「這一幀」的值，MCP 的
//  `/bot/status`、`/game/state` 讀 `GameStateManager` 拿到「上一幀」的值——
//  同一時刻兩個資料面互相打架，而且只在對局中間看得出來，事後看 log 完全正常。
//
//  這批 test 全部是「呼叫完立刻斷言」，中間沒有 await、沒有 expectation、
//  沒有 runloop spin。只要有人把 async dispatch 加回去，這裡就會紅。
//

import XCTest

@testable import Naki

@MainActor
final class GameStateManagerTests: XCTestCase {

    // MARK: - syncFrom（主路徑：Bot 回應後同步）

    /// 新建的 `NativeBotController` 沒有 bot、kyoku 仍是 0，而 `GameState()` 的預設 kyoku 是 1。
    /// 這個差異讓「有沒有真的同步過」可被區分——不是兩邊剛好都是預設值的假綠燈。
    func testSyncFromLeavesStateReadableImmediately() {
        let manager = GameStateManager()
        let controller = NativeBotController()

        // 前置：初始狀態確實是「還沒同步過」
        XCTAssertNil(manager.lastUpdateTime)
        XCTAssertFalse(manager.botStatus.isActive)
        XCTAssertEqual(manager.gameState.kyoku, 1, "GameState() 預設 kyoku 應為 1")

        manager.syncFrom(controller: controller)

        // 沒有 await、沒有等下一個 runloop：呼叫回來就必須看得到
        XCTAssertNotNil(manager.lastUpdateTime,
                        "syncFrom 回來後 lastUpdateTime 仍是 nil → 寫入被延到下一個 runloop")
        XCTAssertTrue(manager.botStatus.isActive)
        XCTAssertEqual(manager.gameState, controller.gameState)
        XCTAssertEqual(manager.gameState.kyoku, 0,
                       "同步後應是 controller 的 kyoku(0)，不是 GameState() 預設的 1")
        XCTAssertEqual(manager.recommendationCount, controller.lastRecommendations.count)
    }

    /// `syncFrom` 也要把 controller 的可用動作旗標一起帶過去（`/bot/status` 的 canXxx 來源）。
    func testSyncFromCopiesBotFlagsFromController() {
        let manager = GameStateManager()
        let controller = NativeBotController()

        manager.syncFrom(controller: controller)

        let bot = manager.botStatus
        XCTAssertEqual(bot.modelName, "mortal", "只有四麻模型，標籤不得造假")
        XCTAssertEqual(bot.playerId, controller.gameState.playerId)
        XCTAssertEqual(bot.is3P, controller.gameState.is3P)
        XCTAssertEqual(bot.canDiscard, controller.canDiscard)
        XCTAssertEqual(bot.canRiichi, controller.canRiichi)
        XCTAssertEqual(bot.canChi, controller.canChi)
        XCTAssertEqual(bot.canPon, controller.canPon)
        XCTAssertEqual(bot.canKan, controller.canKan)
        XCTAssertEqual(bot.canAgari, controller.canAgari)

        // isInGame 要求「Bot 存在 **且** 真的有局在跑」；kyoku 還是 0 就不算在局中
        XCTAssertFalse(manager.isInGame,
                       "kyoku 仍為 0（尚未 start_kyoku）時 isInGame 必須是 false")
    }

    // MARK: - 逐個 mutator

    func testUpdateGameStateIsVisibleImmediately() {
        let manager = GameStateManager()
        var state = GameState()
        state.kyoku = 5
        state.honba = 3
        state.kyotaku = 2
        state.playerId = 2

        manager.updateGameState(state)

        XCTAssertEqual(manager.gameState, state)
        XCTAssertEqual(manager.roundDisplay, "南1局")
        XCTAssertEqual(manager.honbaDisplay, "3 本場")
        XCTAssertEqual(manager.kyotakuDisplay, "2 供託")
        XCTAssertNotNil(manager.lastUpdateTime)
    }

    func testUpdateBotStatusIsVisibleImmediately() {
        let manager = GameStateManager()
        var status = BotStatus()
        status.isActive = true
        status.playerId = 3
        status.canAgari = true

        manager.updateBotStatus(status)

        XCTAssertEqual(manager.botStatus, status)
        XCTAssertTrue(manager.botStatus.canAgari)
    }

    func testUpdateRecommendationsIsVisibleImmediately() {
        let manager = GameStateManager()

        manager.setCalculating(true)
        XCTAssertTrue(manager.isCalculating, "setCalculating 也不得延後生效")

        let recs = [
            Recommendation(tile: "5m", probability: 0.7, actionType: .discard),
            Recommendation(tile: "1p", probability: 0.2, actionType: .discard),
        ]
        manager.updateRecommendations(recs)

        XCTAssertEqual(manager.recommendations.count, 2)
        XCTAssertEqual(manager.recommendationCount, 2)
        XCTAssertTrue(manager.hasRecommendations)
        XCTAssertEqual(manager.topRecommendation?.displayTile, "5m")
        XCTAssertFalse(manager.isCalculating, "有推薦就代表算完了")
        XCTAssertNotNil(manager.lastUpdateTime)

        manager.clearRecommendations()
        XCTAssertEqual(manager.recommendationCount, 0)
        XCTAssertFalse(manager.hasRecommendations)
    }

    func testSetErrorIsVisibleImmediately() {
        let manager = GameStateManager()
        manager.setError("送出失敗")
        XCTAssertEqual(manager.errorMessage, "送出失敗")
        manager.setError(nil)
        XCTAssertNil(manager.errorMessage)
    }

    // MARK: - reset（deleteNativeBot 會直接呼叫）

    /// `WebViewModel.deleteNativeBot()` 呼叫完 `reset()` 之後緊接著就 `syncGameHighlight()`，
    /// 中間沒有 await。reset 若被延後，那一輪高亮還會拿到上一局的推薦。
    func testResetIsVisibleImmediately() {
        let manager = GameStateManager()
        manager.syncFrom(controller: NativeBotController())
        manager.updateRecommendations([Recommendation(tile: "5m", probability: 0.9, actionType: .discard)])
        manager.setError("boom")

        XCTAssertTrue(manager.botStatus.isActive)
        XCTAssertEqual(manager.recommendationCount, 1)

        manager.reset()

        XCTAssertEqual(manager.gameState, GameState())
        XCTAssertEqual(manager.botStatus, BotStatus())
        XCTAssertTrue(manager.recommendations.isEmpty)
        XCTAssertEqual(manager.recommendationCount, 0)
        XCTAssertFalse(manager.isCalculating)
        XCTAssertNil(manager.errorMessage)
        XCTAssertNil(manager.lastUpdateTime)
        XCTAssertFalse(manager.isInGame)
    }
}
