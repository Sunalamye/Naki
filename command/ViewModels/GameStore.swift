//
//  GameStore.swift
//  Naki
//
//  牌局資料的單一真實來源（SwiftUI 側欄與 MCP 讀同一份）
//

import Foundation
import MortalSwift
import SwiftUI

// MARK: - Game Store

/// SwiftUI 側欄與 MCP／Debug 共同讀的那一份牌局狀態。
///
/// ## 為什麼需要它
///
/// 只有 `NativeBotController` → `GameStore` →（SwiftUI ／ MCP）一條線。
/// 兩個消費面讀同一個物件的同一個欄位，不可能差一幀，也不可能內容分歧。
///
/// **不要在旁邊再存一份鏡像**：兩份拷貝各自更新的話，「Bot 現在活著嗎」「現在是第幾局」
/// 就會在側欄與 `/bot/status`、`/game/state` 給出不同答案，而兩邊都自稱是真的。
///
/// ## 邊界
///
/// - 可用操作（oplist）的權威仍是 `LiqiOperationStore`，**不複製到這裡**
///   （`botStatus` 的六個 canXxx 旗標是 `NativeBotController.availableActions` 的導出值，
///   而那個 computed property 每次都現讀 store，不是快取）。
/// - Bot 的完整內部狀態仍在 `NativeBotController`；這裡只放「要被顯示／被查詢」的快照。
/// - 自動打牌模式的**持久化**權威仍是 `AutoPlayModeStore`（UserDefaults）、收斂權威仍是
///   `AutoPlayAvailability.commit`；這裡只放「現在生效的是哪一個」。
///   放進來的理由是 MCP：`bot_status` / `game_state` 都要輸出 `autoPlay.mode`，
///   而 MCP 的狀態面一律讀這個物件，不靠外部傳一個 closure 進去。
@Observable
@MainActor
final class GameStore {

    // MARK: - 牌局資料

    /// 局況（局數／本場／供託／點數／座位／寶牌）
    var gameState = GameState()

    /// Bot 狀態（是否活著、模型、座位、六個可用動作旗標）
    var botStatus = BotStatus()

    /// AI 推薦（機率由高到低）
    var recommendations: [Recommendation] = []

    /// `recommendations` 是針對哪一批 oplist 算出來的（`LiqiOperationSnapshot.sequence`）。
    /// 自動打牌的 `.proceed` 路徑用它確認「推薦」與「當前決策機會」同源——
    /// 推論是 async 的，新 oplist 可能在舊推薦還沒被新推論取代前就到達。
    var recommendationsOplistSequence: UInt64?

    /// 自家手牌（MJAI 表記）
    var tehaiTiles: [String] = []

    /// 這一巡摸到的牌（MJAI 表記）；不是自己的回合時為 nil
    var tsumoTile: String?

    /// 頁面載入失敗的原因；nil = 沒有失敗（或已重新載入成功）。
    ///
    /// 頁面載不起來時 Naki 什麼都做不了，而在此之前這件事只寫進 `statusMessage`
    /// ——那會被下一個事件蓋掉。使用者看到的是空白頁面與一句稍縱即逝的文字。
    var pageLoadFailure: String?

    /// 自動打牌停滯中（伺服器給了機會卻連續沒動作）；nil = 正常。
    ///
    /// 引擎所有的失敗與略過原本只走 log，而側欄的綠點讀的是 `botStatus.isActive`
    /// （推論層）——推論照跑它就照亮。結果是「一手都沒送出、畫面顯示運行中」。
    /// 這個欄位是那件事唯一能上畫面的路。
    var autoPlayStall: AutoPlayStall?

    /// 目前在遊戲畫面內標記的那一張牌。
    ///
    /// `.off` 模式必須是 nil——否則它會宣稱畫面上有一個其實已經被 `clear()` 掉的標記。
    /// 唯一的寫入點是 `updateHighlight(showRecommendation:)`。
    var highlightedTile: String?

    // MARK: - 模式

    /// 目前生效的自動打牌模式。
    ///
    /// **唯一的寫入點是 `NakiRuntime.setAutoPlayMode`**（它先過
    /// `AutoPlayAvailability.commit` 做收斂與持久化）。這裡只是「現在跑的是哪一個」，
    /// 不是設定的權威——直接寫這個欄位會跳過 Legacy 路徑的 `.auto` 降級。
    var autoPlayMode: AutoPlayMode = AutoPlayModeStore.defaultMode

    // MARK: - 連線與狀態列

    /// 雀魂 WebSocket 是否連線中
    var isConnected = false

    /// 狀態列文字（載入／連線／Bot 建立／MCP／錯誤都寫這裡）
    var statusMessage = ""

    // MARK: - Debug／MCP Server

    /// Debug／MCP server 是否在跑（工具列指示燈讀它）
    ///
    /// 寫入點：`DebugServer` 綁上 port 時，以及 `NakiRuntime.stopDebugServer()`。
    var isDebugServerRunning = false

    /// 實際綁到的 port（8765 被佔用時會往上找，所以不等於 preferred port）
    var debugServerPort: UInt16 = 8765

    // MARK: - 導出值

    /// 推薦數量（狀態列 badge）。
    ///
    /// 刻意是 computed 而不是另一個 stored property：另存一份計數就得在每個寫入
    /// `recommendations` 的地方跟著更新，漏一處就會與列表長度不一致。
    var recommendationCount: Int { recommendations.count }

    /// 是否真的在對局中（`/game/state` 的 `inGame`）。
    ///
    /// `botStatus.isActive` 只代表「Bot 物件存在」——Bot 在 authGame 當下就建立，
    /// 那時還沒發牌；重連時也可能先建 Bot 才進局。所以再要求真的有局在跑。
    var isInGame: Bool { botStatus.isActive && gameState.kyoku > 0 }

    /// 送給 `AutoPlayDecisionResolver` 的自家座位，**全專案唯一的定義點**。
    ///
    /// **不要改讀 `botStatus.playerId`**：兩者雖然都源自 `NativeBotController.playerId`，
    /// 但重置時機不同（`clearAfterBotDeleted()` 把 `botStatus` 打回預設值 0，`gameState`
    /// 不動），所以兩者對「座位是幾號」可以給出不同答案，而 resolver 的 `seat_mismatch`
    /// 是 fail-closed——判錯就整批 oplist 不動作。
    var autoPlaySeat: Int { gameState.playerId }

    // MARK: - Lifecycle

    /// `nonisolated`：`NakiEnvironment` 的 Preview 預設值要在 `@Entry` 生成的
    /// **nonisolated** `EnvironmentKey.defaultValue` 裡建起來。這個 init 只寫值型別
    /// 欄位，沒有任何 MainActor 語意代價。
    nonisolated init() {}

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit { }

    // MARK: - 寫入（唯一入口）

    /// 從 `NativeBotController` 取一份完整快照。
    ///
    /// **這是牌局資料唯一的寫入點**。
    ///
    /// 全部同步賦值、沒有 `DispatchQueue.main.async`：呼叫端（`@MainActor`）return 後，
    /// SwiftUI 與 `/bot/status`、`/game/state` 立刻讀得到同一組新值。改成非同步派發
    /// 會把寫入延到下一個 runloop，造成一幀不一致；回歸鎖在 `GameStoreTests`。
    ///
    /// - Parameters:
    ///   - controller: 推論剛跑完的 Bot 控制器
    ///   - showRecommendation: 目前模式是否顯示推薦（`.off` 時不標記任何牌）
    func apply(controller: NativeBotController, showRecommendation: Bool) {
        gameState = controller.gameState
        // `botState` 的 `isActive` 是 `bot != nil`，`canXxx` 由協定層 oplist 導出。
        // 原樣抄過來，不要在這裡覆寫 `isActive`——寫死 true 會讓 `/bot/status`
        // 在 bot 已經被刪掉之後還說它活著。
        botStatus = controller.botState
        tehaiTiles = controller.tehaiMjai
        tsumoTile = controller.lastTsumo
        recommendations = controller.lastRecommendations
        // provenance 由 controller 綁定（只在推薦真的刷新時更新），不是每個 event 都蓋
        recommendationsOplistSequence = controller.lastRecommendationsOplistSequence
        updateHighlight(showRecommendation: showRecommendation)
    }

    /// 依目前模式重算「標了哪一張」。模式一改就要立刻反映，不能等下一次 Bot 回應。
    func updateHighlight(showRecommendation: Bool) {
        guard showRecommendation, let top = recommendations.first,
              top.actionType.marksTileOnBoard else {
            // 首選是和了／過／拔北／九種九牌時，`GameHighlightScript` 不產生任何 mark。
            // 這裡若仍記一個 `"hora"`／`"none"`，就是宣稱畫面上有一個其實不存在的
            // 標記——`.off` 那條早就補了，動作類型這條沒有。
            highlightedTile = nil
            return
        }
        highlightedTile = top.displayTile
    }

    /// Bot 被刪除（對局開始前重建、對局結束、重連、換頁）時清掉屬於這一局的資料。
    ///
    /// **`gameState` 刻意不清**：它是 `autoPlaySeat` 的唯一來源，而 `deleteNativeBot()`
    /// 與「下一個 bot 建好」之間隔著一段 await；那段期間把座位打回 0 會讓 resolver 的
    /// `seat_mismatch`（fail-closed）誤判整批 oplist。保留最後已知局況也讓對局結束後的
    /// `/game/state` 與側欄講同一句話，而不是一邊說「東1局」（`GameState()` 預設值）、
    /// 一邊說實際打完的那一局。
    func clearAfterBotDeleted() {
        botStatus = BotStatus()
        recommendations = []
        recommendationsOplistSequence = nil
        tehaiTiles = []
        tsumoTile = nil
        highlightedTile = nil
        autoPlayStall = nil
    }
}
