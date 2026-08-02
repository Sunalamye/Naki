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
| `Naki` | macOS 26.0 | `Naki/App/NakiApp.swift` | `WebViewModel`／WebPage |
| `Naki-M` | iOS 17.0 | `Naki-M/Naki_MApp.swift` | iOS 26+ WebPage；17–25 Legacy WKWebView |

`command/` 是 file-system-synchronized shared group，兩個 app target 共用 Swift 與 JavaScript 資源。

`WebViewModelProtocol` 只統一 UI-facing interface。resolver 現在兩條 path 都接了，但 Legacy 沒有 send 重試，且因為 macOS deployment target 是 26，這條路在本機跑不到、沒有 live 驗證。

## 啟動順序

新 WebPage 路徑的 `WebViewModel.init()`：

1. 建立 `NakiWebCoordinator`、navigation decider、dialog presenter。
2. 建立 `WKUserContentController`，註冊 `websocketBridge`。
3. 依序注入 2 個 Naki JavaScript modules（`naki-core.js` → `naki-websocket.js`）。
4. 建立 `WebPage`。
5. 建立 `NativeBotController` 與 `AutoPlayController`。
6. 設定 `LiqiActionSender` 的 JS send handler。
7. 啟動 loopback Debug／MCP server（預設 port 8765）。
8. 觀察頁面導覽與遊戲事件。

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

`NativeBotController` 維護手牌、摸牌、局況與推薦；`WebViewModel` 把 snapshot 同步進 `GameStateManager`。SwiftUI、`bot_status` 與 `game_state` 都讀這份 Naki 本機狀態，不是向雀魂重新查詢完整局面。

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

目前本機 package resolve 為 MortalSwift 0.5.0，但 package requirement 是 `[0.5.0,0.6.0)` 且 lockfile 未提交。模型是固定四麻 1012×34 observation／46 action；`is3P` 只改 Naki 自己的狀態與標籤，不會換成三麻模型。

## 自動打牌主路徑

```text
Mortal recommendations + LiqiOperationSnapshot
  → AutoPlayDecisionResolver
      - mode gate
      - server hora override
      - action-in-oplist
      - seat check
  → delay
  → stale snapshot check
  → LiqiActionSender
  → Swift encode request
  → __nakiWebSocket.sendRaw(base64)
  → correct gateway
```

純 resolver 規則已測；整合仍有兩個 P0：沒有 recommendation 時可能不進 resolver，以及 hora send failure 仍可能被 mark handled。完整修正方向見 canonical 文件的「自動打牌決策」。

Legacy path 走同一個 resolver 與同一組檢查，差別是失敗不重試（送一次，失敗等下一次推薦更新）。

## 送出與回應

`LiqiRequestBuilder` 建 payload，`LiqiEncoder` 建 request envelope 與 msgId，`LiqiActionSender` 選 request spec。JavaScript `sendRaw` 只負責把 bytes 送到正確 OPEN socket。

成功分三層：

1. JS／WebSocket 接受 bytes。
2. server 對同 msgId 回 RESPONSE 且無 error。
3. 權威 action／state 確認遊戲真的前進。

需要可靠驗收的動作不可把第 1 層當第 3 層。

## 遊戲內高亮

`WebViewModel.syncGameHighlight()` 把推薦牌名傳給 `window.__nakiHighlight`。`naki-core.js` 從 WebGL `_MainTex_ST` UV 辨識牌 identity，在單次 draw 前暫改 `_Tint`／`_Color` 並還原。

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

live MCP registry 是 42 個工具；工具表見 [mcp-server-guide.md](mcp-server-guide.md)。

## 測試分層

| 層 | 可證明 | 不能證明 |
|----|--------|----------|
| MortalSwift parity tests | 固定 fixtures 的 observation／mask 與 libriichi 一致 | 全狀態正確、牌力更強 |
| Naki unit tests | resolver、encoder、request builder 等純邏輯 | WebViewModel wiring、browser、server 接受 |
| live Debug／log | 實際 WS、request／response、權威 action | 未出現過的 failure path |
| screenshot／人工對局 | 視覺命中與完整體驗 | 大樣本牌力 |

本次 fresh 結果為 MortalSwift Debug／Release 各 47 tests 通過、NakiTests 75 tests 通過。仍需 live 補測自摸 override、send failure、Legacy、chi variants、槓與高亮視覺正確性。

## 主要程式位置

| 責任 | 檔案 |
|------|------|
| 平台 factory | `command/ViewModels/WebViewModelProtocol.swift` |
| 新／舊 view model | `command/ViewModels/WebViewModel.swift`、`LegacyWebViewModel.swift` |
| Web coordinator | `command/Views/WebViewController.swift` |
| WS injection | `command/Services/Bridge/WebSocketInterceptor.swift` |
| Liqi parsing | `command/Services/Bridge/LiqiParser.swift` |
| Liqi → MJAI | `command/Services/Bridge/MajsoulBridge.swift` |
| oplist | `command/Services/Bridge/LiqiOperationStore.swift` |
| sender | `command/Services/Bridge/LiqiActionSender.swift` |
| decision | `command/Services/Bot/AutoPlayDecisionResolver.swift` |
| AI controller | `command/Services/Bot/NativeBotController.swift` |
| Unity highlighter | `command/Resources/JavaScript/naki-core.js` |
| WS sendRaw | `command/Resources/JavaScript/naki-websocket.js` |
| Debug／MCP | `command/Services/Debug/`、`command/Services/MCP/` |
