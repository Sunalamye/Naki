# CLAUDE.md

Naki（鳴き）是原生 macOS／iOS 雀魂 AI 助手。Swift 解析 Liqi、MortalSwift／Core ML 在本機推論，SwiftUI 顯示推薦；自動模式會在使用者自己的測試帳號送出遊戲動作。

## 不可違反的邊界

- 只操作使用者自己的測試帳號；不可使用主帳號。
- 不得提交 session token、credential、account id 或完整敏感 log。
- 修改 WebSocket bridge、自動打牌或任何會送 Liqi request 的行為前先確認。
- 動作、匹配、建房、強制重連與帳號外觀變更都不是唯讀查詢。
- destructive operation 要先做 preflight、備份／rollback、非零失敗與 cleanup。

## 查詢 Naki 的規則

所有「目前 Naki 是什麼狀態」的回答，先以正在執行的 Naki loopback API 查證，再用 source／test 解釋；不能拿舊文件自證。

唯讀順序：

```bash
curl http://127.0.0.1:8765/status
curl http://127.0.0.1:8765/bot/status
curl http://127.0.0.1:8765/game/state
curl http://127.0.0.1:8765/game/hand
curl http://127.0.0.1:8765/game/ops
```

需要頁面能力 probe 才用 `/js`，且 code 是 function body，必須寫 `return`：

```bash
curl -X POST http://127.0.0.1:8765/js \
  -d 'return JSON.stringify({canvas:!!document.getElementById("unity-canvas"),laya:typeof window.Laya})'
```

`/game/*`／`/bot/*` 回傳的是 Naki 從 WebSocket 累積的 Swift state，不是 server 即時完整 snapshot。沒有 live App 或沒有對局時要明確標「未做 runtime 驗證」。

<IMPORTANT>
所有 Naki MCP 操作使用 `.claude/skills/naki-mcp-proxy/SKILL.md`；工具數一律先 `tools/list` 或 `get_status.toolsCount` 現查（程式端唯一來源是 `MCPToolRegistry.registerBuiltInTools()`，回報欄位直接數 registry，文件不再寫死數字），不要依記憶呼叫舊 Laya 工具。Debug HTTP endpoint 清單查 `GET /`（由路由表產生）。
</IMPORTANT>

## 專案基準

| Property | Current value |
|----------|---------------|
| App version | 2.6.0（`MARKETING_VERSION`；MCP `serverInfo.version`／`get_status.appVersion`／Debug 首頁都讀 `NakiAppVersion` 這一份） |
| macOS target | 26.0 |
| iOS target | 17.0 |
| Swift | 5.0 project setting |
| Web client | Unity WebGL `chs_t-WebGL-release-4.0.45(45)`（2026-08-01 live） |
| AI package | local resolution MortalSwift 0.5.0／`802dc3d…` |
| Debug／MCP | loopback port 8765，same process／same port |

Xcode dependency requirement 是 MortalSwift `[0.5.0,0.6.0)`，不是 exact；`Package.resolved` 被 ignore，clone 不保證同 revision。

## Build／test

```bash
open Naki.xcodeproj
xcodebuild build -project Naki.xcodeproj -scheme Naki
xcodebuild test -project Naki.xcodeproj -scheme Naki -only-testing:NakiTests
```

開始前先看 `git status`、Xcode／package resolution 與現有 Naki process。

log 每次啟動寫進 `~/Library/Logs/Naki/<timestamp>/`（`all.log`、`events.log`、六個分類、保留 8 次），所以 test host 與正式 App 不再共用檔名。仍建議不要在 live 對局期間跑 tests——test host 會另外啟一個 App instance。

記憶體 log 只有 `LogManager` 一份：`DebugServer.log()` 寫進去，`GET /logs`／`get_logs` 從 `LogManager.recentLogLines()` 讀（依 `timestamp` 排序）。`DebugServer.onStatusMessage` 只更新 UI 狀態列，不是第二條 log 通道——在那裡再呼叫一次 `bridgeLog` 就會恢復成每條訊息出現兩次。

## 現行架構

```text
Majsoul Unity WebGL
  → naki-websocket.js
  → websocketBridge
  → LiqiParser
  → MajsoulBridge
  → MJAIEventStream
  → NativeBotController / MortalSwift / Core ML
  → recommendations

OptionalOperationList
  → LiqiOperationStore
  → AutoPlayDecisionResolver
  → LiqiActionSender
  → __nakiWebSocket.sendRaw
```

主要檔案：

| 責任 | 檔案 |
|------|------|
| 平台 factory | `command/ViewModels/WebViewModelProtocol.swift` |
| WebPage path | `command/ViewModels/WebViewModel.swift` |
| Legacy path | `command/ViewModels/LegacyWebViewModel.swift` |
| coordinator | `command/Views/WebViewController.swift` |
| WS injection | `command/Services/Bridge/WebSocketInterceptor.swift` |
| parser／bridge | `command/Services/Bridge/LiqiParser.swift`、`MajsoulBridge.swift` |
| oplist／sender | `command/Services/Bridge/LiqiOperationStore.swift`、`LiqiActionSender.swift` |
| decision | `command/Services/Bot/AutoPlayDecisionResolver.swift` |
| action 送出 | `command/Services/Bot/AutoPlayActionExecutor.swift`（兩條 WebView path 共用的唯一 7-case switch；成功才 markHandled） |
| AI | `command/Services/Bot/NativeBotController.swift` |
| WebGL highlighter | `command/Resources/JavaScript/naki-core.js` |
| sendRaw | `command/Resources/JavaScript/naki-websocket.js` |

## Unity 與 Liqi 必知事實

- `Laya`、`GameMgr`、`uiscript`、`view.DesktopMgr`、`cfg`、`app.NetAgent` 不存在。
- 狀態與動作一律走 Liqi；不可用 DOM tile、Laya sprite 或座標點擊。
- JS 仍可做 WebSocket、WebGL、resource 與頁面 probe；不是整層 JS 都失效。
- request envelope：`[type][msgId LE][protobuf{field1=method,field2=payload}]`。
- normal ActionPrototype 需 XOR；sync restore payload 不再 XOR。
- FastTest 對局 request 走 `/game-gateway`，lobby request 走 `/gateway`。
- `sendRaw` 成功只代表 WebSocket 接受 bytes；真正成功要看同 msgId RESPONSE／權威 action。
- field number 只查 `docs/protocol/liqi.json`。2026-08-01 repo snapshot 與 live CDN byte-identical。
- MJAI 字牌 `E/S/W/N/P/F/C`；雀魂字牌 `1z`–`7z`。

## 平台差距

`WebViewModelFactory`：OS 26+ 用 WebPage `WebViewModel`；iOS 17–25 用 `LegacyWebViewModel`。macOS deployment target 是 26，所以 macOS 不走 Legacy。

兩條 path 現在都走 `AutoPlayDecisionResolver`（oplist 合法性、seat、stale、fail-closed、server hora override），送出也都走同一個 `AutoPlayActionExecutor`（7-case switch、chi 組合對照、成功才 markHandled、診斷輸出）；`sendRaw` 的腳本字串與回傳值解析同樣只剩 `NakiWebSocketScript` 一份。差別在重試框架：新 path 會在 hora send 失敗時重試（15 次，每次重跑 resolver），Legacy 送一次就結束、失敗等下一次推薦更新。重試刻意留在呼叫端而不是 executor 裡——盲目重送等於拿舊決策操作可能已換批的 oplist。Legacy 路徑沒有 live 驗證（macOS deployment target 是 26，跑不到這條）。

## 自摸問題的 current truth

resolver 純邏輯會讓 server tsumo／ron 凌駕 AI，且 13 個專項 tests 通過；但 integration 還有兩個 P0：

1. `WebViewModel` 仍要求 recommendations 非空才進主動作。空推薦 + type 8 可能完全不呼叫 resolver。
2. hora sender 沒把 `LiqiSendResult` 回給外層；呼叫後可能不論失敗都 `markHandled`。

`WebViewModel` 的其他 failure path 已收斂成同一語意（`AutoPassDispatcher` + 轉換失敗不標記）：沒有送出成功就不消化 oplist。這只有單測，沒有 live 驗證。

`.off` 現在同時關掉顯示：`RecommendationView` 與 `GameHighlightScript.make()` 都讀 `showRecommendation`，關閉時側欄顯示「推薦顯示已關閉」、遊戲內送 `__nakiHighlight.clear()`。AI 仍在背景計算（否則切回來會一片空白），`/bot/status` 的 recommendations 也照舊為真。腳本內容有單測，**畫面實際效果未 live 驗證**。

正確修法：由 oplist arrival 驅動、先處理 hora；sender 回傳結果，收到成功 send／最好同 msgId RESPONSE 或 `ActionHule` 後才 handled；失敗保留 pending、bounded retry；Legacy 收斂到同一 resolver。

在完成 live fixture「server `[1,7,8]` + AI discard → resolver hora → RESPONSE → ActionHule」前，不得宣稱漏自摸已修復。

## MortalSwift／模型

- local resolution 是 0.5.0；2026-08-01 官方 remote 最高公開 tag 也是 v0.5.0，但 bundled Core ML 仍是固定 Mortal v4 四麻模型。
- observation `1012 × 34`，action mask 46。
- libriichi parity 是兩套固定 fixtures 的逐格測試；Debug／Release 各 47 tests 通過，不是全狀態證明。
- 0.5.0 沒換 model blobs；沒有千局級 strength benchmark。不得稱「最新最強模型」。
- `is3P` 不會換模型；三麻仍送進四麻 model，不應宣稱支援。

## WebGL 高亮

現行 `__nakiHighlight` 以 `_MainTex_ST` UV 解 tile identity，在 `drawElements(count===6)` 前暫改 `_Tint`／`_Color`，draw 後還原。

live tinted counter 證明 hook 有執行，不證明每次染對。已知限制：同名牌全染、只攔特定 WebGL2 draw、popup 是 frequency heuristic、沒有 screenshot regression。

MCP 已沒有手動高亮工具（6 個 `highlight_*` 失敗樁於 2026-08-02 移除，呼叫回 `Unknown tool`）；App 內建自動 highlighter 由 `syncGameHighlight()` 驅動，與 MCP 無關。

## 假功能不得留在 UI／文件

位置校準、推薦溫度、旋轉 Laya 高亮三組無效控制已從 UI 移除，底層仍依賴不存在的 `uiscript`，不可掛回 UI。

隱藏玩家名稱已用協定層重做：`naki-websocket.js` 的 `__nakiHideNames` 在遊戲解析封包前，就地把 `ResAuthGame` 的 nickname bytes 覆寫成等長 ASCII。等長是硬性條件——改長度就要連動所有外層 protobuf 長度前綴。範圍只有 authGame RESPONSE；syncGame 重連與 NotifyGameEndResult 結算畫面仍顯示原名。node 合成 frame 測過（等長、關閉不動、非 authGame 不動、垃圾 bytes 不丟例外），**沒有 live 對局驗證**。

## 專案結構的坑

`Naki.xcodeproj` 的 `membershipExceptions` 是**包含清單**不是排除清單——新增的 Swift 檔要手動加進對應的 exception set（跟著同目錄既有檔案加），否則不會被編譯，錯誤訊息是 `cannot find 'X' in scope`，看起來像 import 問題。

MCP 工具需要 `import MCPKit`。

app target 開了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，`NakiTests` target 沒開。後果是**單測釋放任何 MainActor 隔離的 app class 會直接 SIGABRT**（`pointer being freed was not allocated`，堆疊在 `swift_task_deinitOnExecutor` → `TaskLocal::StopLookupScope::~StopLookupScope()`），test host 崩掉重啟，畫面上像「那批測試莫名其妙沒跑」而不是 fail。要單測的 MainActor class 得補一行 `nonisolated deinit { }`（`GameStateManager`、`NativeBotController` 已補）。最小重現已確認：`@MainActor final class` 崩、同一個 class 加 `nonisolated deinit` 過、`nonisolated final class` 過。

## 測試腳本

| 腳本 | 用途 |
|------|------|
| `scripts/soak-test.sh N` | 連續跑 N 局（友人房+人機），逐局收集異常、停滯自救 |
| `scripts/action-shots.sh [dir]` | 輪到自己或出現異常時自動截圖（JPEG） |
| `scripts/replay-check.sh` | 重跑所有對局錄影，決策指紋與 baseline diff |

改完決策相關的程式碼後用 `replay-check.sh` 驗，不必真打一局。它**只**能驗事件流之內的東西（encoder／resolver／推論／決策順序），送出通道、oplist 時序、高亮、UI 都驗不到——不要拿它的綠燈當成全部驗過。

`soak-test.sh` 用 `[協調器] start_game` / `end_game` 判斷局的邊界，**不用 `/game/state` 的 `inGame`**（結束後不會歸位）。開局走 `room_quick_test` + 必要時 `bot_sync`——`startRoom` 只讓伺服器開局，客戶端常常不會自己進場。

MCP 回應是「JSON 包在 JSON 字串裡」，比對前要先 `tr -d '\\'` 去掉跳脫，否則 `grep '"serverAccepted":false'` 永遠對不上。

## 文件

- `docs/majsoul-unity-protocol.md`：唯一 Unity／Liqi／AI／高亮 current truth。
- `docs/architecture-deep-dive.md`：Naki current code architecture。
- `docs/majsoul-config-tables.md`：由 live manifest fresh parse 的 config 附錄。
- `docs/protocol/liqi.json`：協定欄位 schema。
- `AUDIT.md`：當前驗證差距與完成判準，不是歷史日誌。

## 驗收回報

回報必須分開：已修改、已驗證、未驗證、已知風險。單測通過不能替代 WebView／server／視覺與 failure-path 驗收；沒有可重查 evidence 的推論不得寫成事實。
