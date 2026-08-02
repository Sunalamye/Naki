//
//  GameStoreTests.swift
//  NakiTests
//
//  p3-1 回歸鎖：牌局資料只准有一份，而且寫入必須在**同一個 main runloop turn** 內就讀得到。
//
//  這批 test 取代 `GameStateManagerTests`。原本的問題有兩層：
//
//  1.（p0-3）`GameStateManager` 的每個 mutator 各包一層 `DispatchQueue.main.async`，
//     而呼叫端本來就在 MainActor 上——SwiftUI 讀 VM 鏡像拿到「這一幀」，
//     `/bot/status`、`/game/state` 讀 `GameStateManager` 拿到「上一幀」。
//  2.（p3-1）就算兩邊同幀，寫進去的東西本來就不一樣：VM 鏡像抄 `controller.botState`
//     （`isActive` = bot 物件是否存在），`GameStateManager.syncFrom` 硬寫 `isActive = true`；
//     `deleteNativeBot()` 也只重置其中一份的 `gameState`。同一個問題兩個答案。
//
//  所以這裡鎖三件事：合併後只剩一份（原始碼掃描）、寫入立即可讀（沒有 await 的斷言）、
//  以及「寫進去的值來自 controller，不是硬編的樂觀值」。
//
//  ⚠️ 驗不到的：SwiftUI 真的重畫了沒有、live 對局中兩個面是否逐幀一致（要實機對局）。
//

import XCTest

@testable import Naki

@MainActor
final class GameStoreTests: XCTestCase {

    // MARK: - apply（Bot 回應後的唯一寫入點）

    /// 新建的 `NativeBotController` 沒有 bot、kyoku 仍是 0，而 `GameState()` 的預設 kyoku 是 1。
    /// 這個差異讓「有沒有真的同步過」可被區分——不是兩邊剛好都是預設值的假綠燈。
    func testApplyIsReadableImmediately() {
        let store = GameStore()
        let controller = NativeBotController()

        // 前置：初始狀態確實是「還沒同步過」
        XCTAssertEqual(store.gameState.kyoku, 1, "GameState() 預設 kyoku 應為 1")
        XCTAssertFalse(store.botStatus.isActive)

        store.apply(controller: controller, showRecommendation: true)

        // 沒有 await、沒有等下一個 runloop：呼叫回來就必須看得到
        XCTAssertEqual(store.gameState, controller.gameState)
        XCTAssertEqual(store.gameState.kyoku, 0,
                       "同步後應是 controller 的 kyoku(0)，不是 GameState() 預設的 1")
        XCTAssertEqual(store.tehaiTiles, controller.tehaiMjai)
        XCTAssertEqual(store.tsumoTile, controller.lastTsumo)
        XCTAssertEqual(store.recommendationCount, controller.lastRecommendations.count)
    }

    /// `isActive` 必須來自 controller（bot 物件是否存在），不得硬寫 true。
    ///
    /// 合併前 `/bot/status` 讀的 `GameStateManager.syncFrom` 就是硬寫 `true`：
    /// 只要同步過一次，Bot 就永遠「活著」，即使 bot 根本沒建立起來。
    /// 側欄讀的 VM 鏡像抄的是 `controller.botState`，於是兩邊講不同的話。
    func testApplyTakesIsActiveFromControllerNotOptimism() {
        let store = GameStore()
        let controller = NativeBotController()   // 沒有 createBot → bot == nil

        store.apply(controller: controller, showRecommendation: true)

        XCTAssertFalse(controller.isInitialized, "前置：這個 controller 還沒有 bot")
        XCTAssertFalse(store.botStatus.isActive,
                       "isActive 是「bot 物件存在嗎」，不能因為同步過就宣稱 true")
        XCTAssertFalse(store.isInGame, "沒有 bot、kyoku 也還是 0，不可能在對局中")
    }

    /// `botStatus` 的六個可用動作旗標來自協定層 oplist（`/bot/status` 的 canXxx 資料面）
    func testApplyCarriesAvailableActionFlags() {
        let opStore = LiqiOperationStore.shared
        opStore.reset()
        defer { opStore.reset() }

        opStore.record(seat: 0,
                       operations: [LiqiOperation(type: .discard), LiqiOperation(type: .riichi)],
                       source: "test")

        let store = GameStore()
        store.apply(controller: NativeBotController(), showRecommendation: true)

        XCTAssertTrue(store.botStatus.canDiscard)
        XCTAssertTrue(store.botStatus.canRiichi)
        XCTAssertFalse(store.botStatus.canAgari)
        XCTAssertEqual(store.botStatus.modelName, "mortal", "只有四麻模型，標籤不得造假")
    }

    // MARK: - 導出值

    /// `recommendationCount` 是 computed，不可能與列表長度漂移。
    ///
    /// 合併前 VM 與 `GameStateManager` 各存一份 stored `recommendationCount`，
    /// 都靠「寫完 recommendations 之後記得再寫一次」維持一致。
    func testRecommendationCountFollowsList() {
        let store = GameStore()
        XCTAssertEqual(store.recommendationCount, 0)

        store.recommendations = [
            Recommendation(tile: "5m", probability: 0.7, actionType: .discard),
            Recommendation(tile: "1p", probability: 0.2, actionType: .discard),
        ]
        XCTAssertEqual(store.recommendationCount, 2)

        store.recommendations = []
        XCTAssertEqual(store.recommendationCount, 0)
    }

    /// `isInGame`＝「Bot 存在 **且** 真的有局在跑」；只有 bot 不算（authGame 當下還沒發牌）
    func testIsInGameNeedsBothBotAndKyoku() {
        let store = GameStore()

        store.botStatus.isActive = true
        store.gameState.kyoku = 0
        XCTAssertFalse(store.isInGame, "kyoku 仍為 0（尚未 start_kyoku）時不算在局中")

        store.gameState.kyoku = 3
        XCTAssertTrue(store.isInGame)

        store.botStatus.isActive = false
        XCTAssertFalse(store.isInGame)
    }

    // MARK: - highlight（模式閘門）

    func testUpdateHighlightFollowsMode() {
        let store = GameStore()
        store.recommendations = [Recommendation(tile: "5m", probability: 0.9, actionType: .discard)]

        store.updateHighlight(showRecommendation: true)
        XCTAssertEqual(store.highlightedTile, "5m")

        // `.off`：畫面上的標記會被 clear()，欄位不跟著空就是在說謊
        store.updateHighlight(showRecommendation: false)
        XCTAssertNil(store.highlightedTile)

        // 切回來要立刻標回目前的第一推薦，不必等下一次 Bot 回應
        store.updateHighlight(showRecommendation: true)
        XCTAssertEqual(store.highlightedTile, "5m")
    }

    func testApplyClearsHighlightWhenRecommendationHidden() {
        let store = GameStore()
        store.recommendations = [Recommendation(tile: "5m", probability: 0.9, actionType: .discard)]
        store.updateHighlight(showRecommendation: true)

        store.apply(controller: NativeBotController(), showRecommendation: false)

        XCTAssertNil(store.highlightedTile)
    }

    // MARK: - clearAfterBotDeleted（deleteNativeBot 會直接呼叫）

    /// `deleteNativeBot()` 呼叫完就緊接著 `syncGameHighlight()`，中間沒有 await：
    /// 清除若被延後，那一輪高亮還會拿到上一局的推薦。
    func testClearAfterBotDeletedIsVisibleImmediately() {
        let store = GameStore()
        store.apply(controller: NativeBotController(), showRecommendation: true)
        store.botStatus.isActive = true
        store.recommendations = [Recommendation(tile: "5m", probability: 0.9, actionType: .discard)]
        store.tehaiTiles = ["1m", "2m"]
        store.tsumoTile = "3m"
        store.updateHighlight(showRecommendation: true)

        store.clearAfterBotDeleted()

        XCTAssertEqual(store.botStatus, BotStatus())
        XCTAssertTrue(store.recommendations.isEmpty)
        XCTAssertEqual(store.recommendationCount, 0)
        XCTAssertTrue(store.tehaiTiles.isEmpty)
        XCTAssertNil(store.tsumoTile)
        XCTAssertNil(store.highlightedTile)
        XCTAssertFalse(store.isInGame)
    }

    /// **`gameState` 不清**：它是 `autoPlaySeat` 的唯一來源，`deleteNativeBot()` 與
    /// 「下一個 bot 建好」之間隔著 await，那段期間把座位打回 0 會讓 resolver 的
    /// `seat_mismatch`（fail-closed）誤判整批 oplist。
    func testClearAfterBotDeletedKeepsSeatAndRound() {
        let store = GameStore()
        store.gameState.playerId = 2
        store.gameState.kyoku = 5
        store.gameState.honba = 3

        store.clearAfterBotDeleted()

        XCTAssertEqual(store.gameState.playerId, 2, "座位是 autoPlaySeat 的唯一來源，不得歸零")
        XCTAssertEqual(store.gameState.kyoku, 5)
        XCTAssertEqual(store.gameState.honba, 3)
    }

    /// 連線狀態與狀態列不屬於「一局的資料」，Bot 被刪不該把它們一起吃掉
    func testClearAfterBotDeletedKeepsConnectionAndStatusLine() {
        let store = GameStore()
        store.isConnected = true
        store.statusMessage = "已連線到雀魂服务器"

        store.clearAfterBotDeleted()

        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(store.statusMessage, "已連線到雀魂服务器")
    }
}

// MARK: - 結構鎖（合併後只准有一份）

/// 「四份拷貝 → 兩份」是結構性約束，型別系統看不見，只能掃原始碼。
///
/// 掃法與 `PlatformDivergenceTests` 同一套：跳過純註解行，只看會被編譯的程式碼。
final class SingleGameStoreSourceTests: XCTestCase {

    private func commandSourceRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // NakiTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("command")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("找不到原始碼目錄 \(root.path)（repo 被搬走時這個鎖失效）")
        }
        return root
    }

    private func codeLines(in root: URL) -> [(file: String, line: Int, text: String)] {
        var out: [(String, Int, String)] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return out }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                out.append((relative, index + 1, String(raw)))
            }
        }
        return out
    }

    /// `GameStateManager` 整個型別已刪除，不得有任何殘留引用
    func testGameStateManagerIsGone() throws {
        let root = try commandSourceRoot()
        let hits = codeLines(in: root).filter { $0.text.contains("GameStateManager") }

        XCTAssertTrue(
            hits.isEmpty,
            "`GameStateManager` 已被 `GameStore` 取代，不該再出現；實際: "
                + hits.map { "\($0.file):\($0.line)" }.joined(separator: ", "))
    }

    /// 狀態層與組裝層不得再自己存一份牌局資料——鏡像屬性正是雙重真實來源的載體。
    ///
    /// p3-4：掃描範圍從 `ViewModels/` 擴到 `App/`（組裝點）與 `Services/Web/`
    /// （頁面 service）——view model 已刪除，鏡像如果要復活會長在這兩個地方。
    func testStateHoldersDeclareNoMirrorState() throws {
        let root = try commandSourceRoot()
        let scanned = ["ViewModels/", "App/", "Services/Web/"]
        let mirrors = ["statusMessage", "isConnected", "recommendationCount", "gameState",
                       "botStatus", "recommendations", "tehaiTiles", "tsumoTile",
                       "highlightedTile"]
        let declaration = try NSRegularExpression(
            pattern: #"var\s+(\#(mirrors.joined(separator: "|")))\s*(:|=)"#)

        let hits = codeLines(in: root)
            .filter { line in scanned.contains { line.file.hasPrefix($0) } }
            .filter { $0.file != "ViewModels/GameStore.swift" }
            .filter { line in
                let range = NSRange(line.text.startIndex..., in: line.text)
                return declaration.firstMatch(in: line.text, range: range) != nil
            }

        XCTAssertTrue(
            hits.isEmpty,
            "牌局狀態只准宣告在 `GameStore`；實際: "
                + hits.map { "\($0.file):\($0.line)" }.joined(separator: ", "))
    }
}
