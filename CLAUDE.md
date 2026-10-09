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
| App version | 2.14.0（`MARKETING_VERSION`；MCP `serverInfo.version`／`get_status.appVersion`／Debug 首頁都讀 `NakiAppVersion` 這一份） |
| macOS target | 26.0 |
| iOS target | 17.0 |
| Swift | 5.0 project setting |
| Web client | Unity WebGL `chs_t-WebGL-release-4.0.45(45)`（2026-08-01 live） |
| AI package | MortalSwift 0.5.3／`51cf407…`（由已提交的 `Package.resolved` 釘住；含紅五 decode／振聽／食い替え等修正） |
| Debug／MCP | loopback port 8765，same process／same port |
| MCP 協定 | 雙版本並存：帶 `_meta.io.modelcontextprotocol/protocolVersion` 走 2026-07-28（stateless、`server/discover`、`resultType`），`initialize` handshake 服務 2025-03-26～2025-11-25 |

Xcode dependency requirement 是 MortalSwift `[0.5.3,0.6.0)`（`upToNextMinorVersion`、`minimumVersion = 0.5.3`，`project.pbxproj:1203`），不是 exact——**0.5.0 會編不過**，因為 `NativeBotController` 呼叫的 `bot.inferCurrentState()` 是 0.5.1 才有的 API。範圍下界只是保護，真正決定 revision 的是 `Package.resolved`（`Naki.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`）：它已從 `.gitignore` 移出並提交，clean clone 會拿到同一個 `51cf407`。**改 requirement 或跑 `-resolvePackageDependencies` 之後，要把重寫的 `Package.resolved` 一起 commit**，否則 lockfile 又會跟 requirement 漂開。

## Build／test

```bash
open Naki.xcodeproj
xcodebuild build -project Naki.xcodeproj -scheme Naki
xcodebuild test -project Naki.xcodeproj -scheme Naki -only-testing:NakiTests
```

開始前先看 `git status`、Xcode／package resolution 與現有 Naki process。

log 每次啟動寫進 `~/Library/Logs/Naki/<timestamp>/`（`all.log`、`events.log`、六個分類）。只保留最近 8 次的完整目錄；更舊的 session 若有 `games/` 錄影就只留 `games/`，否則整個刪除；test host（有 `XCTestConfigurationFilePath`）不輪替（`command/Services/LogManager.swift:186`、`:204`）。仍建議不要在 live 對局期間跑 tests——test host 會另外啟一個 App instance。

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
| App 組裝點 | `command/App/NakiRuntime.swift`（唯一一份接線；Scene 顯式注入） |
| View 環境 | `command/App/NakiEnvironment.swift`（`@Entry var naki`：store／settings／actions；預設值僅供 Preview） |
| 使用者設定 | `command/App/SettingsStore.swift` |
| 頁面 service | `command/Services/Web/WebSession.swift`（載入／JS／導覽／高亮；`callJavaScript` 一律函式體語意） |
| 平台分歧 | `command/Services/Web/WebSessionBackends.swift`（WebPage vs WKWebView，唯一 `#available` 在 `WebSession.init`） |
| 牌局狀態單一來源 | `command/ViewModels/GameStore.swift`（SwiftUI 與 MCP 讀同一份） |
| coordinator | `command/Services/Bridge/NakiWebCoordinator.swift`（兩條 path 共用；持有 bot、直接寫 GameStore） |
| WS injection | `command/Services/Bridge/WebSocketInterceptor.swift` |
| parser／bridge | `command/Services/Bridge/LiqiParser.swift`、`MajsoulBridge.swift` |
| oplist／sender | `command/Services/Bridge/LiqiOperationStore.swift`、`LiqiActionSender.swift` |
| decision | `command/Services/Bot/AutoPlayDecisionResolver.swift` |
| 自動打牌狀態機 | `command/Services/Bot/AutoPlayEngine.swift`（單一 Task 迴圈：輪詢＋延遲＋重試都用 `Task.sleep`；執行狀態是 enum，進出只有 `occupy(...)` 一個作用域） |
| 對局結束後自動排下一場 | `command/Services/Bot/AutoRematchEngine.swift`（只有 `.fullAuto` 會動；`end_game` 或大廳按「開始」觸發） |
| match_sid 觀察／持久化 | `command/Services/Bridge/ObservedMatchSids.swift`（只學**遊戲自己送的**：msgId 不在 `LiqiMsgIdAllocator` 登記、也不在插件號段 64000–65500，見 `LiqiParser.isNakiSent`） |
| 段位場房間門檻表 | `command/Services/Bridge/MatchModeTable.swift`（`lqc.lqbin` 解出；只用來挑候選，權威仍在伺服器） |
| action 送出 | `command/Services/Bot/AutoPlayActionExecutor.swift`（兩條 WebView path 共用的唯一動作 switch，9 種動作 + unknown；成功才 markHandled） |
| AI | `command/Services/Bot/NativeBotController.swift` |
| 自動打牌停滯回報 | `AutoPlayEngine.onStallChanged` → `GameStore.autoPlayStall` → `BotStatusView`（「該動而沒動」唯一上得了畫面的路；其餘失敗只走 log，且 log 對同一原因只印一行） |
| 牌面圖像 | `command/Views/TileImage.swift`（MJAI → Asset Catalog；赤五是獨立資產 `5mr`，不再用 Unicode glyph 染紅。牌面圖案要疊 `Utility/front` 牌身，資產本身背景透明） |
| WebGL highlighter | `command/Resources/JavaScript/naki-core.js` |
| sendRaw | `command/Resources/JavaScript/naki-websocket.js` |

## Unity 與 Liqi 必知事實

- `Laya`、`GameMgr`、`uiscript`、`view.DesktopMgr`、`cfg`、`app.NetAgent` 不存在。
- `unityInstance`／`Module`／`SendMessage` 也不存在（instance 存在 script scope）。但攔 `WebAssembly.instantiate*`（頁面覆蓋不掉的入口）就能拿到 **wasm heap**；`naki-core.js` 已這樣做，唯讀存進 `window.__nakiHeap()`。暱稱在 heap 裡是標準 IL2CPP `System.String`，可讀可改——但**改了畫面不會變**（TextMeshPro 已烘成 mesh），所以隱藏名字不能走這條。
- 狀態與動作一律走 Liqi；不可用 DOM tile、Laya sprite 或座標點擊。
- JS 仍可做 WebSocket、WebGL、resource 與頁面 probe；不是整層 JS 都失效。
- request envelope：`[type][msgId LE][protobuf{field1=method,field2=payload}]`。
- normal ActionPrototype 需 XOR；sync restore payload 不再 XOR。
- FastTest 對局 request 走 `/game-gateway`，lobby request 走 `/gateway`。
- `sendRaw` 成功只代表 WebSocket 接受 bytes；真正成功要看同 msgId RESPONSE／權威 action。
- field number 只查 `docs/protocol/liqi.json`。⚠️ **「與 live CDN byte-identical」不代表
  schema 正確**：那個 CDN 資源（`res/proto/liqi.json`）是 Laya 時代的遺留檔，resource
  prefix `v0.11.243.w` 落後 client `4.0.45` 好幾版；雀魂遷 Unity 後真正的 descriptor 改放
  asset bundle 的 `Protol/*_pb.lua`，那個 JSON 不再更新。實證：repo 這份的
  `ReqSelfOperation` 曾缺 `auto_operation`（2026-10-09 依 Akagi 的 liqi.proto 4.0.47 補上，
  其餘 Naki 用到的 26 個訊息逐欄一致）。`scripts/check-liqi-drift.sh` 比對的是同一個
  過期基準，**結構上驗不到這種漂移**（見 task #16）。
- MJAI 字牌 `E/S/W/N/P/F/C`；雀魂字牌 `1z`–`7z`。
- **段位場入口已換人**（2026-08-09 實測）：`.lq.Lobby.matchGame` 對 match_mode
  1／2／3 一律回 **error 1306**；現行入口是 `.lq.Lobby.startUnifiedMatch`
  （`ReqStartUnifiedMatch`：`match_sid` 是 **string**，不是舊的 uint32 match_mode）。
  `lobby_start_match` 因此已標為過時，改用 `lobby_start_unified_match`。
- **`match_sid` 猜不出來**：形狀是 `"{match_group}:{mode_id}"`（實測 `"1:2"` ＝銅之間
  四人東），但 `liqi.json` 裡**沒有任何訊息會產生它**，`lqc.lqbin` 的 41 表 263 sheets
  也沒有 sid 欄位。唯一來源是攔玩家自己點入口時送出的那一筆
  （`ObservedMatchSids`，已持久化）。搭配的 `client_version_string` 是
  `"WebGL_2022-0.16.257"`——**不是** `version.json` 的 `0.11.252.w`。
  ⚠️ 記錄時必須濾掉 Naki 自送的，否則猜錯的嘗試值會被記成「觀察到的真值」再變成預設，
  錯誤自我餵養（2026-08-09 踩過）。判斷是 **msgId 登記制**而非號段：遊戲自己的 msgId
  跑久了也會進 60000+。`LiqiMsgIdAllocator.isIssued`（未認領的 Naki 自送）或插件號段
  （JS 自配發、不在登記表）＝ Naki 側（`LiqiEncoder.swift:257`、`LiqiParser.swift:188`）；
  `LiqiResponseStore` 只收登記過的回應（`claim`，`LiqiResponseStore.swift:205`）。

## 平台差距

`WebSession.init` 的 `#available`：OS 26+ 用 `WebPageBackend`（WebPage），iOS 17–25 用 `LegacyWebBackend`（WKWebView）。macOS deployment target 是 26，所以 macOS 不走 Legacy。p3-4 之後**兩條 path 只差三件事**：怎麼執行 JS（WebPage 原生函式體 vs WKWebView 的 IIFE 包裝）、怎麼重連（關 WebSocket vs 整頁重載）、交出哪個 View。其餘（bot、event stream、autoplay engine、MCP、狀態）全部共用一份。

兩條 path 都走 `AutoPlayDecisionResolver`（oplist 合法性、seat、stale、fail-closed、server hora override）、同一個 `AutoPlayActionExecutor`（動作 switch、chi 組合對照、成功才 markHandled、診斷輸出）、同一個 `AutoPlayEngine`（輪詢閘門、擬人延遲、去抖、bounded retry 15 次）；`sendRaw` 的腳本字串與回傳值解析只剩 `NakiWebSocketScript` 一份。**Legacy 不自動送出**這件事現在只由一個值表達：`LegacyWebBackend.supportsAutoPlay == false` → `AutoPlayAvailability.commit` 把模式收斂掉 `.auto` → `AutoPlayGate` 第一關 `.skip(.notAutoMode)`，而且 MCP 的動作類能力一律 `.unavailable("legacy_path_action_send_disabled")`。Legacy 路徑沒有 live 驗證（macOS deployment target 是 26，跑不到這條）。

## 自摸問題的 current truth

resolver 純邏輯會讓 server tsumo／ron 凌駕 AI；下面兩個 integration P0 在 source 層都已收斂（有單測與注入式 fixture），**仍缺 live 對局驗證**：

1. ~~主動作仍要求 recommendations 非空~~ **2026-08-07 修**：擋住伺服器授權和牌的其實有
   **三道**關卡，各自開了例外——`AutoPlayGate` 的 `notMyDiscardTurn`（榮和視窗的 oplist
   沒有 discard，而 stale 推薦是 discard）、`AutoPlayEngine` 輪詢路徑的 stale guard
   （自摸視窗）、手動路徑的 stale guard（MCP `bot_trigger`）。fixture F 三條 + 一條反向鎖
   （沒有和牌機會時 stale 推薦仍然擋下），三次獨立 mutation 各自驗過。手動路徑在推薦為空時，
   只要 oplist 有和牌也會交給 resolver（`AutoPlayEngine.swift:577-582`、`BotTools.swift:64`）。
   **仍缺 live fixture。**
2. ~~hora sender 沒把 `LiqiSendResult` 回給外層~~ 已收斂到 `AutoPlayActionExecutor`
   （回傳 `LiqiSendResult?`，只有 `success == true` 才 `markHandled`）。仍缺 live 驗證。

其他 failure path 已收斂成同一語意（`AutoPassDispatcher` + 轉換失敗不標記）：沒有送出成功就不消化 oplist。這只有單測，沒有 live 驗證。

`.off` 現在同時關掉顯示：`RecommendationView` 與 `GameHighlightScript.make()` 都讀 `showRecommendation`，關閉時側欄顯示「推薦顯示已關閉」、遊戲內送 `__nakiHighlight.clear()`。AI 仍在背景計算（否則切回來會一片空白），`/bot/status` 的 recommendations 也照舊為真。腳本內容有單測，**畫面實際效果未 live 驗證**。

正確修法：由 oplist arrival 驅動、先處理 hora；sender 回傳結果，收到成功 send／最好同 msgId RESPONSE 或 `ActionHule` 後才 handled；失敗保留 pending、bounded retry；Legacy 收斂到同一 resolver。

在完成 live fixture「server `[1,7,8]` + AI discard → resolver hora → RESPONSE → ActionHule」前，不得宣稱漏自摸已修復。

## MortalSwift／模型

- 目前解到 0.5.3／`51cf407`（`Package.resolved`）；bundled Core ML 仍是固定 Mortal v4 四麻模型。
- 0.5.2 移除 `PlayerState` 的 `isAllLast`／`isWRiichi`／`kansOnBoard`／`dorasOwned`／`dorasSeen`／`atIppatsu`，Naki 全都沒用到。
- 0.5.3：`handleReach` 在自家宣言後打開 `canDiscard`，`BundledCoreMLBot` 因此在 `react` 回 `reach` 時餵合成 `reach` 再 `inferCurrentState()`，推薦列的打牌項是立直後的第二次推論（失敗退回立直前的打牌項）。
- observation `1012 × 34`，action mask 46。
- libriichi parity 是兩套固定 fixtures 的逐格測試；Debug／Release 各 47 tests 通過，不是全狀態證明。
- 0.5.x 沒換 model blobs；沒有千局級 strength benchmark。不得稱「最新最強模型」。
- **三麻本地引擎是 Akagi 三麻**（2026-10-09 D23，取代 D15 的雲端-only）：
  `NativeBotController` 在 `is3P` 時建 `CloudBot(local: AkagiSanmaBot, …)`，雲端優先、
  本地接手；bundled 四麻模型仍不碰三麻（obs 1012×34 對三麻是結構性無效）。
  `AkagiSanmaBot` 是 MortalSwift `AkagiSanma`（純 Swift、Akagi v3 三麻 BC 權重，
  **模仿天鳳人類，強度不是 Mortal 等級**），動作類別由 `LiqiOperationStore.pending`
  授權（和牌只看形狀、不判役）；pending 缺失或不是本家時只剩捨牌與 pass。
  自動送出另有三層 fail-closed（gate 逐決策看 `sanmaCapableDecision`＝推薦來自雲端 3p
  或 `source == "local-akagi3p"`、resolver 降級、`runManualCycle` 自己擋），
  **伺服器授權的和牌三層都放行**（和牌不需要模型）：
  `AutoPlayGate.swift:86`、`AutoPlayDecisionResolver.swift:86-95`、`AutoPlayEngine.swift:570`。
  其餘動作仍擋。三麻仍**沒有 live 對局驗證**。

## 2026-09-30 審查修正後的行為

以下都有單測（NakiTests 714 個 0 failures，2026-10-01 整合閘），**除非註明否則沒有 live 驗證**。

- **背景保活**：`naki-core.js` 的 `__nakiKeepAlive`（隱藏時以計時器驅動 rAF、對頁面偽裝可見）＋ `WebSession` 的 tick 迴圈（`callJavaScript` 定期喚醒被系統暫停的 WebContent）；`SettingsStore.keepAliveInBackground` 預設開、設定頁可關。**live 效果未驗證**：短時間對照（隱藏 60 秒）開關的心跳一樣，長時間對照結果未定（見 `code-audit-implementation-notes.md`），之前不得宣稱有效。
- **插件**：插件 script 只注入 main frame（`WebSession.swift:168`）；內建 WS 攔截仍是 `forMainFrameOnly: false`（`WebSocketInterceptor.swift:265`）。匯入的 `id`／`entry` 限 `[A-Za-z0-9._-]`（`PluginRegistry.isSafeName`／`isSafeEntry`），不合即 `manifestInvalid`。「檢查更新」先預覽再確認，確認前不落地（`PluginImportSource.swift:381`）。
- **Debug server**（`DebugServer.swift`）：Origin 與 Host 由 `NakiMCPRequestGuard` 單一入口檢查，非 loopback 回 403（沒有 Host header 放行）；chunked 或「無 Content-Length 卻帶 body」回 411（無 body 的 POST 照常）；每連線 30 秒內必須收齊 request。`execute_js` 有 `timeout`（預設 30、上限 60，`UITools.swift:66`），逾時後頁面端 Promise 仍可能在跑。`/js` 回傳非 JSON 型別（Date 等）經 `JSONSanitizer` 轉字串，不再崩潰。403／411 已有單測在 loopback 高位 port 起真 server 驗過（`DebugServerFramingTests`）；逾時與 live server 仍未測。
- **負分**：`LiqiWire.decodeSignedVarint`（`LiqiEnvelope.swift:106`）讓 int32 欄位（scores）能解負數；`decodeVarint` 維持非負契約。
- **分數／場風解析失敗**（例如超出 Int32、`chang`／`ju` 型別錯）：`MajsoulBridge.roundBlocked` 讓**本局**不餵 bot，但 `end_kyoku` 與 oplist 照常處理，所以伺服器授權的和牌仍會送（`MajsoulBridge.swift:514`）。

## WebGL 高亮

現行 `__nakiHighlight` 以 `_MainTex_ST` UV 解 tile identity，在 `drawElements(count===6)` 前暫改 `_Tint`／`_Color`，draw 後還原。

live tinted counter 證明 hook 有執行，不證明每次染對。已知限制：同名牌全染、只攔特定 WebGL2 draw、popup 是 frequency heuristic、沒有 screenshot regression。

MCP 已沒有手動高亮工具（6 個 `highlight_*` 失敗樁於 2026-08-02 移除，呼叫回 `Unknown tool`）；App 內建自動 highlighter 由 `syncGameHighlight()` 驅動，與 MCP 無關。

## 假功能不得留在 UI／文件

位置校準、推薦溫度、旋轉 Laya 高亮三組無效控制已從 UI 移除，底層仍依賴不存在的 `uiscript`，不可掛回 UI。

隱藏玩家名稱是**兩層**：

- **協定層**（`naki-websocket.js` 的 `__nakiHideNames`）在遊戲解析封包前，就地把 `ResAuthGame` 的 nickname bytes 覆寫成等長 ASCII。等長是硬性條件——改長度就要連動所有外層 protobuf 長度前綴。範圍只有 authGame RESPONSE；syncGame 重連與 NotifyGameEndResult 結算畫面不在內。只對「開啟之後才開始的對局」生效。node 合成 frame 測過，**沒有 live 對局驗證**。
- **渲染層**（`naki-core.js` 的 `setNameMask`）在 draw 時把名字那個 draw 的 `_Color` alpha 設 0，**即時生效**，中途開關也有效。難點是認出「哪個 draw 是名字」——shader、貼圖、字數全部試過且都不穩（字數在人機場直接失效，「電腦（簡單）」由客戶端產生）。成立的判準是**幾何**：四家分坐四方，遮掉名字會讓變動像素散在 ≥3 個象限且總量很少。開啟時自我校準（逐一試遮 + `readPixels` 比對），認不到就什麼都不遮。**已 live 驗證**（銅之間・四人東：四家名字消失，稱號／分數／局數／手牌／按鈕／頭像完好）。詳見 `docs/unity-heap-access.md`。

UI 文字 draw 的識別特徵是 `_TextureSampleAdd`，不是 `_Tint`／`_Color`——3D 牌的 shader 也有 `_Tint`，用它當條件會把整桌的牌混進候選。

## 專案結構的坑

`#Preview` 的內容在 **Release 也會被編譯**（`ENABLE_PREVIEWS = YES` 兩個 configuration 都開，而 `DEBUG` 只在 Debug 定義）。用到 `#if DEBUG` 才存在的東西（例如 Action 的 `init(stub:)`）的 Preview 必須自己包一層 `#if DEBUG`，否則 `xcodebuild -configuration Release` 會失敗，而 Debug build 完全看不出來。

`Naki.xcodeproj` 的 `membershipExceptions` 是**包含清單**不是排除清單——新增的 Swift 檔要手動加進對應的 exception set（跟著同目錄既有檔案加），否則不會被編譯，錯誤訊息是 `cannot find 'X' in scope`，看起來像 import 問題。這只適用於 app target；`NakiTests` 是 synchronized group、沒有 exception set，新測試檔不必登記（2026-10-09 實測）。

MCP 工具需要 `import MCPKit`。

app target 開了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，`NakiTests` target 沒開。後果是**單測釋放任何 MainActor 隔離的 app class 會直接 SIGABRT**（`pointer being freed was not allocated`，堆疊在 `swift_task_deinitOnExecutor` → `TaskLocal::StopLookupScope::~StopLookupScope()`），test host 崩掉重啟，畫面上像「那批測試莫名其妙沒跑」而不是 fail。要單測的 MainActor class 得補一行 `nonisolated deinit { }`（`GameStore`、`NativeBotController` 已補）。最小重現已確認：`@MainActor final class` 崩、同一個 class 加 `nonisolated deinit` 過、`nonisolated final class` 過。

## 測試腳本

| 腳本 | 用途 |
|------|------|
| `scripts/soak-test.sh N` | 連續跑 N 局（友人房+人機），逐局收集異常、停滯自救 |
| `scripts/action-shots.sh [dir]` | 輪到自己或出現異常時自動截圖（JPEG） |
| `scripts/replay-check.sh` | 重跑所有對局錄影，決策指紋與 baseline diff |

改完決策相關的程式碼後用 `replay-check.sh` 驗，不必真打一局。它**只**能驗事件流之內的東西（encoder／resolver／推論／決策順序），送出通道、oplist 時序、高亮、UI 都驗不到——不要拿它的綠燈當成全部驗過。

`soak-test.sh` 用 `[協調器] start_game` / `end_game` 判斷局的邊界，**不用 `/game/state` 的 `inGame`**（結束後不會歸位）。開局走 `room_quick_test` + 必要時 `bot_sync`——`startRoom` 只讓伺服器開局，客戶端常常不會自己進場。

MCP 工具結果現在同時回 `structuredContent`（真的 JSON 物件）與 `content[0].text`（同一份 JSON 的字串化，留給舊 client）。腳本比對一律讀 `structuredContent`——`soak-test.sh` 的 `structured()` 先把回應切到該欄位再比對，舊的 `tr -d '\\'` 去跳脫 workaround 已移除。

## 文件

- `docs/majsoul-unity-protocol.md`：唯一 Unity／Liqi／AI／高亮 current truth。
- `docs/architecture-deep-dive.md`：Naki current code architecture。
- `docs/majsoul-config-tables.md`：由 live manifest fresh parse 的 config 附錄。
- `docs/protocol/liqi.json`：協定欄位 schema。
- `AUDIT.md`：當前驗證差距與完成判準，不是歷史日誌。
- `docs/design-review-vs-akagi.md`：對照 Akagi v3 的**架構**檢討（2026-08-01）。
- `docs/akagi-audit-p0-decisions.md`：掃 Akagi 89 個 issue 對照出的**具體 bug**與修法
  取捨（2026-08-07），含兩個被推翻的判斷。

## 文件與程式碼的一致性

**查 Naki 現況不可拿 `CLAUDE.md` 與 `AUDIT.md` 自證。** 這兩份都漂開過，而且不只一次：

| 曾經寫錯的 | 實際 | 發現於 |
|---|---|---|
| iOS target 編不了（無 SDK） | 三個 build 全 `BUILD SUCCEEDED` | 2026-08-07 |
| executor 是「7-case switch」 | 9 種動作 + unknown | 2026-08-07 |
| 三麻仍送進四麻 model | 已改雲端-only，本地模型根本不建構 | 2026-08-07 |
| liqi.json「與 CDN byte-identical」＝已驗證 | 那個 CDN 基準本身就過期 | 2026-08-07 |
| `LiqiParser` 註解「負分 `parseVarint` 解得出來」 | 原本解不出來（10-byte varint 被 `shift >= 63` 拒絕），現以有號版本解 | 2026-09-30 |
| 文件「Liqi generic protobuf tag 只讀一 byte，field > 31 會錯」 | `parseProtobufBlocks` 的 tag 早已是 varint（基準 `48add0a` 就是） | 2026-09-30 |
| 程式把 `timeFixed`／`timeAdd` 當秒 | 單位是毫秒（同訊息推定，**未 live 驗證**），已改 | 2026-09-30 |
| 「msgId ≥ 60000 ＝ Naki 自送」 | 遊戲自己的 msgId 跑久了也進 60000+；改為登記制 | 2026-09-30 |
| 「log 保留 8 次」「三麻一律不自動送」 | 舊 session 可能只剩 `games/`；三麻的伺服器授權和牌照送 | 2026-09-30 |
| `LiqiResponseStore` 的 error 一律在 field 1 | 20 個 Res 不是（如 `ResServerTime` 在 field 2），曾把「被拒」讀成成功 | 2026-09-30 |

回答「目前是什麼狀態」一律以**執行中的 Naki loopback API、原始碼、或當場跑一次
build/test** 為準；文件只用來解釋「為什麼是這樣」。改了行為就順手改文件——
上面每一條都是「改了程式碼、沒改文件」累積出來的。

## 驗收回報

回報必須分開：已修改、已驗證、未驗證、已知風險。單測通過不能替代 WebView／server／視覺與 failure-path 驗收；沒有可重查 evidence 的推論不得寫成事實。
