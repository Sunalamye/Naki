# Naki 現行架構

**資料日期**：2026-08-01  
**範圍**：只描述目前 `command/` 與 Xcode project 的活路徑。Unity／Liqi／AI 的證據與限制集中在 [majsoul-unity-protocol.md](majsoul-unity-protocol.md)。

## 系統圖

```text
Majsoul Unity WebGL
  │
  ├─ WebSocket frames ───────────────┐
  │                                  ▼
  └─ WebGL draw calls          WebSocketInterceptor
          │                          │
          ▼                          ▼
  __nakiHighlight              LiqiParser
                                     │
                                     ▼
                              MajsoulBridge
                                     │ MJAI events + oplist
                    ┌────────────────┴────────────────┐
                    ▼                                 ▼
             MJAIEventStream                  LiqiOperationStore
                    │                                 │
                    ▼                                 │
          NativeBotController                        │
          MortalSwift / Core ML                      │
                    │ recommendations                 │
                    └────────────────┬────────────────┘
                                     ▼
                         AutoPlayDecisionResolver
                                     │
                                     ▼
                          LiqiActionSender → sendRaw

Swift 狀態同時提供給 SwiftUI、Debug HTTP 與 MCP。
```

## Targets 與平台分流

| Target | Deployment | Entry point | Web path |
|--------|------------|-------------|----------|
| `Naki` | macOS 26.0 | `Naki/App/NakiApp.swift` | `WebPageBackend`／WebPage |
| `Naki-M` | iOS 17.0 | `Naki-M/Naki_MApp.swift` | iOS 26+ WebPage；17–25 Legacy WKWebView |

`command/` 是 file-system-synchronized shared group，兩個 app target 共用 Swift 與 JavaScript 資源。

p3-4 之後不再有 `WebViewModelProtocol`：平台差異全部收在 `WebSessionBackend` 的兩份實作（WebPage vs WKWebView），而它們只負責「怎麼跑 JS、怎麼載入／重連、交出哪個 View」。決策層、bot、event stream、autoplay engine、MCP 與狀態兩條 path 完全共用。Legacy 仍然不自動送出（`supportsAutoPlay == false` → 模式收斂掉 `.auto`），因為 macOS deployment target 是 26，這條路在本機跑不到、沒有 live 驗證。

## 啟動順序

Scene（`NakiApp` / `Naki_MApp`）持有一份 `NakiRuntime`，並以 `.environment(\.naki, runtime.environment)` **顯式注入**（`@Entry` 的預設值只給 Preview）。`NakiRuntime.init()`：

1. 建立 `GameStore` 與 `SettingsStore`。
2. 建立 `NakiWebCoordinator`（它擁有 `NativeBotController`、`MJAIEventStream`、`WebSocketMessageHandler`，並直接寫 `GameStore`）。
3. 建立 `WebSession`：組 `WKUserContentController`（註冊 `websocketBridge` + 注入 2 個 JS modules：`naki-core.js` → `naki-websocket.js`），然後由**全專案唯一的 `#available`** 挑 backend（`WebPageBackend` 或 `LegacyWebBackend`）。
4. 互相接線：`coordinator.observer = runtime`、`session.lifecycle = coordinator`、`settings.adoptAutoPlaySupport(session.supportsAutoPlay)`。
5. 設定 `LiqiActionSender` 的 JS send handler（走 `WebSession.callJavaScript`）。
6. 從 `AutoPlayModeStore` 讀回上次選的模式，經 `AutoPlayAvailability.commit` 收斂。
7. 啟動 `AutoPlayEngine`（兩條 path 都啟動；Legacy 由模式閘門擋住）。
8. 組 `NakiActions`（View 層可用的副作用全集）。
9. 啟動 loopback Debug／MCP server（預設 port 8765）。

頁面本身在 `WebSession.makeView()` 的 `.task` 裡才首次載入（與遷移前主路徑的 `NakiWebView.task` 同一個時機）。
8. 啟動 `AutoPlayEngine`（單一 Task 迴圈；p3-2 之前這一步是 `Timer.scheduledTimer(1.0)`）。
9. 觀察頁面導覽與遊戲事件。

## 接收與狀態

### WebSocket → MJAI

```text
naki-websocket.js
  → websocketBridge
  → NakiWebCoordinator
  → MajsoulBridge.parse
  → LiqiParser
  → MJAI dictionary event
  → MJAIEventStream
  → NativeBotController.react
```

正常 `.lq.ActionPrototype` payload 需 XOR decode；sync restore actions 不再 decode。`docs/protocol/liqi.json` 是欄位 schema，不得以舊碼或記憶猜 field number。

`MajsoulBridge` 另外把 action 上的 `OptionalOperationList` 記錄到 `LiqiOperationStore`。這份 snapshot 是合法動作、seat、staleness 與 send channel 的資料來源。

### UI state

`NativeBotController` 維護手牌、摸牌、局況與推薦；ViewModel 用 `GameStore.apply(controller:showRecommendation:)` 把 snapshot 寫進 `GameStore`（`@Observable @MainActor`）。SwiftUI、`bot_status` 與 `game_state` 讀的是**同一個** `GameStore` 物件，不是向雀魂重新查詢完整局面。

p3-1 之前這裡有兩份鏡像（ViewModel 的 9 個屬性給 SwiftUI、`GameStateManager` 給 MCP），寫入內容還會分歧（`botStatus.isActive` 一邊抄 `controller.botState`、一邊硬寫 `true`；`deleteNativeBot()` 只重置其中一份的 `gameState`）。現在只剩 `GameStore` 與 `LiqiOperationStore`（oplist 權威）兩份狀態。

## Game lifecycle

```text
authGame response
  → start_game
  → event stream 開新局
  → 刪除舊 MortalBot
  → 建立新 MortalBot

ActionNewRound   → start_kyoku
ActionDealTile   → tsumo
ActionDiscardTile / ChiPengGang / ... → 對應 MJAI events
ActionHule / ActionNoTile             → end_kyoku
NotifyGameEndResult                   → end_game → 清 Bot 與 UI state
```

sync／reconnect 會重放 restore actions 或 snapshot 以恢復狀態；不應額外製造第二個 `start_game`。

## 推論

`NativeBotController` 建立 `MortalBot(playerId:version:4,useBundledModel:true)`。MortalBot 是 actor，Core ML 推論非同步執行。

package requirement 是 `[0.5.1,0.6.0)`（0.5.0 缺 `inferCurrentState` 會編不過），實際 revision 由已提交的 `Package.resolved` 釘在 MortalSwift 0.5.1／`78b048e`。模型是固定四麻 1012×34 observation／46 action；`is3P` 只改 Naki 自己的狀態與標籤，不會換成三麻模型。

## 自動打牌主路徑

```text
AutoPlayEngine（單一 Task 迴圈，@MainActor）
  → AutoPlayGate                     觸發閘門（模式／三麻／oplist／寬限期／回合）
      .forceHora / .sendPass / .proceed
  → delay（Task.sleep，ActionDelayModel 抽樣）＋去抖
  → stale snapshot check             閘門看到的那一份 snapshot 一路往下傳
  → AutoPlayDecisionResolver
      - mode gate
      - server hora override
      - action-in-oplist
      - seat check
  → AutoPlayActionExecutor
  → LiqiActionSender
  → Swift encode request
  → __nakiWebSocket.sendRaw(base64)
  → correct gateway
```

p3-2 之前這整條散在 `WebViewModel`（p3-4 已刪除），混用 `Timer.scheduledTimer`、`DispatchQueue.main.asyncAfter`、`Task { @MainActor }` 與深度 15 的 async 遞迴；執行位是一個裸 `UUID?`，「每條 return 都要記得歸零」只寫在註解裡（殘留＝輪詢永久停用）。現在輪詢／延遲／重試都是同一個迴圈裡的 `Task.sleep`，執行位是 enum 且只能經 `occupy(...)` 進出。

純 resolver 規則已測；整合的兩個 P0（空推薦時不進 resolver、hora send failure 被 mark handled）source 已收斂並有注入式 fixture，**live 仍未驗證**。完整判準見 canonical 文件的「自動打牌決策」。

p3-4 之後 Legacy path 走同一個引擎，只是模式永遠不是 `.auto`，所以閘門第一關就 skip。

## 送出與回應

`LiqiRequestBuilder` 建 payload，`LiqiEncoder` 建 request envelope 與 msgId，`LiqiActionSender` 選 request spec。JavaScript `sendRaw` 只負責把 bytes 送到正確 OPEN socket。

成功分三層：

1. JS／WebSocket 接受 bytes。
2. server 對同 msgId 回 RESPONSE 且無 error。
3. 權威 action／state 確認遊戲真的前進。

需要可靠驗收的動作不可把第 1 層當第 3 層。

## 遊戲內高亮

`WebSession.syncHighlight()` 把推薦牌名傳給 `window.__nakiHighlight`。腳本內容由純函式 `GameHighlightScript.make(mode:recommendations:tehaiTiles:snapshot:)` 產生——模式 `.off` 一律回 `clear()`，這是「關閉真的關掉顯示」唯一可機械驗收的地方。`naki-core.js` 從 WebGL `_MainTex_ST` UV 辨識牌 identity，在單次 draw 前暫改 `_Tint`／`_Color` 並還原。

這條路徑不依賴 Laya 或螢幕座標。它目前只有 hook 活性證據，沒有視覺正確性測試；同名牌全染與 popup heuristic 是已知限制。

## Debug HTTP／MCP

`DebugServer` 以 Network.framework 只綁 loopback，HTTP 與 MCP 共用 port 8765。

唯讀診斷優先順序：

1. `/status`
2. `/bot/status`
3. `/game/state`、`/game/hand`、`/game/ops`
4. `/logs`
5. 必要時才用 `/js` 做 read-only Unity／WebSocket／WebGL probe

`/js` 的 code 是 function body，要取得值必須顯式 `return`。遊戲動作、強制重連、建房、匹配與外觀變更都不是唯讀操作，只能在測試帳號與明確授權下執行。

MCP registry 的靜態註冊是 38 個工具（2026-08-02 移除 6 個高亮失敗樁後；2026-08-01 live 為 42）。live 數字請以 `tools/list` 或 `get_status.tools_count` 為準；工具表見 [mcp-server-guide.md](mcp-server-guide.md)。

## 測試分層

| 層 | 可證明 | 不能證明 |
|----|--------|----------|
| MortalSwift parity tests | 固定 fixtures 的 observation／mask 與 libriichi 一致 | 全狀態正確、牌力更強 |
| Naki unit tests | resolver、encoder、request builder 等純邏輯 | WebSession wiring、browser、server 接受 |
| live Debug／log | 實際 WS、request／response、權威 action | 未出現過的 failure path |
| screenshot／人工對局 | 視覺命中與完整體驗 | 大樣本牌力 |

本次 fresh 結果為 MortalSwift Debug／Release 各 47 tests 通過、NakiTests 75 tests 通過。仍需 live 補測自摸 override、send failure、Legacy、chi variants、槓與高亮視覺正確性。

## 主要程式位置

| 責任 | 檔案 |
|------|------|
| App 組裝點 | `command/App/NakiRuntime.swift` |
| View 環境 | `command/App/NakiEnvironment.swift`、`command/App/SettingsStore.swift` |
| 頁面 service | `command/Services/Web/WebSession.swift` |
| 平台分歧（唯一） | `command/Services/Web/WebSessionBackends.swift` |
| 牌局狀態單一來源 | `command/ViewModels/GameStore.swift` |
| Web coordinator | `command/Services/Bridge/NakiWebCoordinator.swift` |
| WS injection | `command/Services/Bridge/WebSocketInterceptor.swift` |
| Liqi parsing | `command/Services/Bridge/LiqiParser.swift` |
| Liqi → MJAI | `command/Services/Bridge/MajsoulBridge.swift` |
| oplist | `command/Services/Bridge/LiqiOperationStore.swift` |
| sender | `command/Services/Bridge/LiqiActionSender.swift` |
| decision | `command/Services/Bot/AutoPlayDecisionResolver.swift` |
| 自動打牌狀態機 | `command/Services/Bot/AutoPlayEngine.swift` |
| AI controller | `command/Services/Bot/NativeBotController.swift` |
| Unity highlighter | `command/Resources/JavaScript/naki-core.js` |
| WS sendRaw | `command/Resources/JavaScript/naki-websocket.js` |
| Debug／MCP | `command/Services/Debug/`、`command/Services/MCP/` |
