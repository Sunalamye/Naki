//
//  GameStore.swift
//  Naki
//
//  p3-1：牌局資料的單一真實來源（取代 `GameStateManager` 與 ViewModel 的鏡像屬性）
//

import Foundation
import MortalSwift
import SwiftUI

// MARK: - Game Store

/// SwiftUI 側欄與 MCP／Debug 共同讀的那一份牌局狀態。
///
/// ## 為什麼需要它
///
/// 在這之前，同一份牌局資料有四份拷貝：`NativeBotController`（真值）、
/// `LiqiOperationStore`（oplist 權威）、`WebViewModel`／`LegacyWebViewModel` 的鏡像屬性
/// （SwiftUI 讀）、`GameStateManager`（`/bot/status`、`/game/state` 讀，**沒有任何 View 讀**）。
/// 兩份鏡像在 `updateUIAfterBotResponse` 裡被連續寫兩次，而且寫進去的東西並不相同：
///
/// - `botStatus`：VM 鏡像抄 `controller.botState`（`isActive` = bot 物件是否存在），
///   `GameStateManager.syncFrom` 卻硬寫 `isActive = true`。同一時刻「Bot 活著嗎」
///   側欄與 `/bot/status` 可以給出不同答案。
/// - `gameState`：`deleteNativeBot()` 只重置 `GameStateManager` 那一份，VM 鏡像留著。
///   於是對局結束後 `/game/state` 說「東1局」（`GameState()` 預設值），
///   側欄說的是實際打完的那一局。
///
/// 現在只剩 `NativeBotController` → `GameStore` →（SwiftUI ／ MCP）一條線。
/// 兩個消費面讀同一個物件的同一個欄位，不可能差一幀，也不可能內容分歧。
///
/// ## 邊界
///
/// - 可用操作（oplist）的權威仍是 `LiqiOperationStore`，**不複製到這裡**
///   （`botStatus` 的六個 canXxx 旗標是 `NativeBotController.availableActions` 的導出值，
///   而那個 computed property 每次都現讀 store，不是快取）。
/// - Bot 的完整內部狀態仍在 `NativeBotController`；這裡只放「要被顯示／被查詢」的快照。
/// - 自動打牌模式的**持久化**權威仍是 `AutoPlayModeStore`（UserDefaults）、收斂權威仍是
///   `AutoPlayAvailability.commit`；這裡只放「現在生效的是哪一個」（p3-3）。
///   放進來的理由是 MCP：`bot_status` / `game_state` 都要輸出 `autoPlay.mode`，
///   而 p3-3 之後 MCP 的狀態面一律讀這個物件，不再靠 ViewModel 傳一個 closure 進去。
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

    /// 自家手牌（MJAI 表記）
    var tehaiTiles: [String] = []

    /// 這一巡摸到的牌（MJAI 表記）；不是自己的回合時為 nil
    var tsumoTile: String?

    /// 目前在遊戲畫面內標記的那一張牌。
    ///
    /// `.off` 模式必須是 nil——否則它會宣稱畫面上有一個其實已經被 `clear()` 掉的標記。
    /// 唯一的寫入點是 `updateHighlight(showRecommendation:)`。
    var highlightedTile: String?

    // MARK: - 模式

    /// 目前生效的自動打牌模式。
    ///
    /// **唯一的寫入點是 ViewModel 的 `setAutoPlayMode`**（它先過
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
    /// 寫入點：`DebugServer` 綁上 port 時、以及 ViewModel 的 `stopDebugServer()`。
    /// 先前這是 ViewModel 的 stored property，由 `DebugServer.onPortChanged` closure
    /// 回寫——那個 closure 是 p3-3 要拆掉的九跳之一。
    var isDebugServerRunning = false

    /// 實際綁到的 port（8765 被佔用時會往上找，所以不等於 preferred port）
    var debugServerPort: UInt16 = 8765

    // MARK: - 導出值

    /// 推薦數量（狀態列 badge）。
    ///
    /// 刻意是 computed 而不是另一個 stored property：先前 VM 與 `GameStateManager`
    /// 各存一份 `recommendationCount`，各自在寫入 `recommendations` 之後再寫一次，
    /// 只要有一條路徑漏寫就會與列表長度不一致。
    var recommendationCount: Int { recommendations.count }

    /// 是否真的在對局中（`/game/state` 的 `inGame`）。
    ///
    /// `botStatus.isActive` 只代表「Bot 物件存在」——Bot 在 authGame 當下就建立，
    /// 那時還沒發牌；重連時也可能先建 Bot 才進局。所以再要求真的有局在跑。
    var isInGame: Bool { botStatus.isActive && gameState.kyoku > 0 }

    /// 送給 `AutoPlayDecisionResolver` 的自家座位，**全專案唯一的定義點**。
    ///
    /// 先前 Legacy path 讀 `botStatus.playerId`、主 path 讀 `gameState.playerId`
    /// （定義在 `WebViewModelProtocol` 的 extension 裡，p3-4 隨協定一起刪除）。
    /// 兩者雖然都源自 `NativeBotController.playerId`，但重置時機不同
    /// （`clearAfterBotDeleted()` 把 `botStatus` 打回預設值 0，`gameState` 不動），
    /// 所以「座位對不對」在兩條路上可以得到不同答案，而 resolver 的 `seat_mismatch`
    /// 是 fail-closed——判錯就整批 oplist 不動作。
    var autoPlaySeat: Int { gameState.playerId }

    // MARK: - Lifecycle

    /// `nonisolated`：`NakiEnvironment` 的 Preview 預設值要在 `@Entry` 生成的
    /// **nonisolated** `EnvironmentKey.defaultValue` 裡建起來。這個 init 只寫值型別
    /// 欄位，沒有任何 MainActor 語意代價。
    nonisolated init() {}

    /// deinit 標 `nonisolated`——**沒有它，任何碰到本 class 的單元測試都會讓 test host 崩掉**。
    ///
    /// app target 是 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，MainActor 隔離的 class
    /// 連隱含的 deinit 都走 `swift_task_deinitOnExecutor`；在 NakiTests 的 host 進程裡釋放
    /// 這種物件會在 `TaskLocal::StopLookupScope::~StopLookupScope()` 觸發
    /// `pointer being freed was not allocated` 而 SIGABRT——測試不是 fail 而是整個 host
    /// 掛掉重啟，看起來像「測試莫名其妙不跑」。本 class 的 deinit 只釋放值型別欄位，
    /// nonisolated 沒有語意代價。（同 `NativeBotController`；見 CLAUDE.md「專案結構的坑」。）
    nonisolated deinit { }

    // MARK: - 寫入（唯一入口）

    /// 從 `NativeBotController` 取一份完整快照。
    ///
    /// **這是牌局資料唯一的寫入點**。以前這件事分兩段做（先寫 VM 鏡像、再
    /// `gameStateManager.syncFrom`），兩段之間可以漏抄、可以抄成不同的值。
    ///
    /// 全部同步賦值、沒有 `DispatchQueue.main.async`：呼叫端（`@MainActor` 的 ViewModel）
    /// return 後，SwiftUI 與 `/bot/status`、`/game/state` 立刻讀得到同一組新值。
    /// p0-3 修掉的就是「寫入被延到下一個 runloop」造成的一幀不一致，
    /// 回歸鎖在 `GameStoreTests`。
    ///
    /// - Parameters:
    ///   - controller: 推論剛跑完的 Bot 控制器
    ///   - showRecommendation: 目前模式是否顯示推薦（`.off` 時不標記任何牌）
    func apply(controller: NativeBotController, showRecommendation: Bool) {
        gameState = controller.gameState
        // `botState` 的 `isActive` 是 `bot != nil`，`canXxx` 由協定層 oplist 導出。
        // 先前 `GameStateManager.syncFrom` 在這裡硬寫 `isActive = true`，
        // 於是 `/bot/status` 永遠說 Bot 活著，即使 bot 已經被刪掉。
        botStatus = controller.botState
        tehaiTiles = controller.tehaiMjai
        tsumoTile = controller.lastTsumo
        recommendations = controller.lastRecommendations
        updateHighlight(showRecommendation: showRecommendation)
    }

    /// 依目前模式重算「標了哪一張」。模式一改就要立刻反映，不能等下一次 Bot 回應。
    func updateHighlight(showRecommendation: Bool) {
        highlightedTile = showRecommendation ? recommendations.first?.displayTile : nil
    }

    /// Bot 被刪除（對局開始前重建、對局結束、重連、換頁）時清掉屬於這一局的資料。
    ///
    /// **`gameState` 刻意不清**：它是 `WebViewModelProtocol.autoPlaySeat` 的唯一來源，
    /// 而 `deleteNativeBot()` 與「下一個 bot 建好」之間隔著一段 await；那段期間把座位
    /// 打回 0 會讓 resolver 的 `seat_mismatch`（fail-closed）誤判整批 oplist。
    /// 保留最後已知局況也讓對局結束後的 `/game/state` 與側欄講同一句話
    /// ——先前 `GameStateManager.reset()` 會把它打回 `GameState()`（東1局），
    /// 而側欄讀的 VM 鏡像仍停在實際打完的那一局。
    func clearAfterBotDeleted() {
        botStatus = BotStatus()
        recommendations = []
        tehaiTiles = []
        tsumoTile = nil
        highlightedTile = nil
    }
}
