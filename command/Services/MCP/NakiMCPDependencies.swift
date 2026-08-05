//
//  NakiMCPDependencies.swift
//  Naki
//
//  p3-3：MCP 工具層的依賴表，一次注入。
//
//  取代先前那條四跳 closure 鏈（`WebViewModel` → `DebugServer` → `MCPHandler`
//  → `DefaultNakiMCPContext` → tool）。每一跳都有一組 `var x: ((A) -> B)?`，
//  中間兩層（DebugServer / MCPHandler）**只是轉發**——它們不使用那些 closure，
//  只是把它們往下傳。九個欄位 × 三層轉發 = 27 行沒有語意的搬運，
//  而且漏接任何一個都只在執行期以 `xxx_callback_not_configured` 現形。
//
//  現在：view model 組出這一個 struct，`DebugServer.init` 吃它，工具經
//  `DefaultNakiMCPContext` 讀它。DebugServer 從此只負責 HTTP（socket、路由、回應），
//  MCPHandler 只負責 JSON-RPC。
//
//  「狀態」與「副作用」在這裡是分開的兩種東西：
//  - 狀態一律讀 `store`（`GameStore`，SwiftUI 與 MCP 同一份，p3-1）
//  - 副作用一律走 Action（`NakiActions.swift`，可 stub）
//

import Foundation

// MARK: - Dependencies

/// MCP／Debug HTTP 這一層需要的全部能力。
///
/// 值型別：注入之後不會被外部改寫，也就不存在「跑到一半某個 closure 被換掉」
/// 這種只在 live 才撞得到的狀態。
@MainActor
struct NakiMCPDependencies {

  /// 牌局狀態的唯一真實來源（SwiftUI 側欄讀同一個物件）
  let store: GameStore

  /// 在遊戲頁面執行 JS（`execute_js` / `POST /js`）
  let executeJavaScript: ExecuteJavaScriptAction

  /// 視窗截圖（`GET /screenshot`）
  let captureScreenshot: CaptureScreenshotAction

  /// 送出 Liqi REQUEST（動作類與大廳類工具的共同出口）
  let sendAction: SendActionAction

  /// 段位場排隊 / 取消排隊
  let startMatch: StartMatchAction
  let cancelMatch: CancelMatchAction

  /// 手動觸發自動打牌（`bot_trigger`）
  let triggerAutoPlay: TriggerAutoPlayAction

  /// 自動心跳開關（`lobby_anti_idle`）
  let setAntiIdle: SetAntiIdleAction

  /// 協定層遊戲快照（`game_state` / `game_hand` / `bot_deep`）
  let gameSnapshot: GameSnapshotAction

  /// 強制斷線重連（`bot_sync`）
  let forceReconnect: ForceReconnectAction

  /// Debug／MCP 這一層的訊息歸宿：**LogManager 一份**，外加狀態列。
  ///
  /// 先前 `DebugServer.log()` 做 `bridgeLog` + `onStatusMessage?()`，
  /// 而 `MCPHandler` 另外經 `context.logCallback` 繞回同一個方法。
  /// 兩條路寫同一個地方，卻靠三個 closure 接起來。
  ///
  /// `onStatusMessage` 不是第二條 log 通道——它只把最後一句話貼到畫面上
  /// （在這裡再呼叫一次 `bridgeLog` 就會恢復成每條訊息出現兩次）。
  func log(_ message: String) {
    bridgeLog(message)
    store.statusMessage = message
  }
}

// MARK: - 狀態輸出（純導出，沒有副作用）

/// 把 `GameStore` 攤成 MCP／HTTP 的 JSON 形狀。
///
/// 這些是**導出值**不是狀態：先前它們是兩份手寫 closure（`WebViewModel` 與
/// `LegacyWebViewModel` 各一份的 `debugServer?.getBotStatus`），兩份的
/// `tsumoTile` 空值寫法還不一樣。收成一份之後可以被單測直接呼叫。
@MainActor
enum NakiStatePayload {

  /// `bot_status` / `GET /bot/status`
  static func botStatus(store: GameStore) -> [String: Any] {
    [
      "botStatus": [
        "isActive": store.botStatus.isActive,
        "playerId": store.botStatus.playerId,
        // ☁️ 這批推薦由誰算出（"local" / "cloud:<model>"）；cloudHost 非 null
        // ＝對局事件正在送往該主機。純增量欄位，既有讀者不受影響。
        "decisionSource": store.botStatus.decisionSource,
        "cloudHost": store.botStatus.cloudHost ?? NSNull(),
      ],
      "gameState": [
        "bakaze": store.gameState.bakazeDisplay,
        "kyoku": store.gameState.kyoku,
        "honba": store.gameState.honba,
      ],
      // 註：`isMyTurn` / `hasPendingAction` 已移除（來源恆 false／恆 nil 的假欄位）
      "autoPlay": [
        "mode": store.autoPlayMode.rawValue
      ],
      "recommendations": recommendations(store: store),
      "tehaiCount": store.tehaiTiles.count,
      "tsumoTile": store.tsumoTile ?? NSNull(),
    ]
  }

  /// `game_state` / `bot_deep` / `GET /game/state`
  ///
  /// ⚠️ 這是 **Naki 自己看到的狀態**，不是向伺服器查詢的結果；
  /// 若 Naki 錯過封包（例如中途啟動），這裡會不完整——用 `bot_sync` 觸發重連重建。
  static func gameSnapshot(store: GameStore, accountId: Int) -> [String: Any] {
    let state = store.gameState
    let bot = store.botStatus

    var snapshot: [String: Any] = [
      "source": "swift-protocol-layer",
      "note": "Unity 客戶端沒有 JS 遊戲物件；本資料由 Liqi 封包在 Swift 端重建",
      "accountId": accountId,
      "gameState": [
        "bakaze": state.bakazeString,
        "bakazeDisplay": state.bakazeDisplay,
        "kyoku": state.kyoku,
        "kyokuDisplay": state.kyokuDisplayName,
        "honba": state.honba,
        "kyotaku": state.kyotaku,
        "jikaze": state.jikazeString,
        "scores": state.scores,
        "doraIndicators": state.doraIndicators,
        "seat": state.playerId,
        "is3P": state.is3P,
        "inGame": store.isInGame,
      ],
      "bot": [
        "isActive": bot.isActive,
        "model": bot.modelName,
        "seat": bot.playerId,
        "is3P": bot.is3P,
        "canDiscard": bot.canDiscard,
        "canRiichi": bot.canRiichi,
        "canChi": bot.canChi,
        "canPon": bot.canPon,
        "canKan": bot.canKan,
        "canAgari": bot.canAgari,
      ],
      "hand": [
        "tehai": store.tehaiTiles,
        "tehaiCount": store.tehaiTiles.count,
        "tsumo": store.tsumoTile as Any? ?? NSNull(),
        "notation": "MJAI（5mr = 紅五萬；E/S/W/N/P/F/C = 字牌）",
      ] as [String: Any],
      "recommendations": recommendations(store: store),
      // 註：`isMyTurn` / `hasPendingAction` 已移除——它們的來源欄位
      // 從來沒有人寫過真值（恆 false / 恆 nil）。
      // 要判斷「輪到誰」請看 `operations.pending`（server-authoritative）。
      "autoPlay": [
        "mode": store.autoPlayMode.rawValue
      ],
    ]

    // 可用操作（協定層 oplist；pending = 尚未被動作層消化）
    let opStore = LiqiOperationStore.shared
    var operations: [String: Any] = [:]
    operations["pending"] = opStore.pending?.dictionary ?? NSNull()
    operations["latest"] = opStore.latest?.dictionary ?? NSNull()
    snapshot["operations"] = operations

    return snapshot
  }

  /// 推薦列表的 JSON 形狀（`bot_status` 與 `game_state` 共用同一份）
  private static func recommendations(store: GameStore) -> [[String: Any]] {
    store.recommendations.map { rec in
      [
        "tile": rec.displayTile,
        "action": rec.actionType.rawValue,
        "label": rec.displayLabel,
        "prob": rec.probability,
        "percentage": rec.percentageString,
      ] as [String: Any]
    }
  }
}
