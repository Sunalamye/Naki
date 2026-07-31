# Naki 全流程梳理 · 邏輯稽核 · 作業流程強化

## Context（為什麼做這件事）

你要「完整梳理 Naki 的所有流程 + 相關套件 + code，找出邏輯/寫法異常，逐一調整，最後加上 Accessibility 讓 mac app 測試更友好」。但你也明說「還有很多細節與流程沒定，先幫我看整套流程與保存方向能加強什麼」。

所以這份 plan 的定位是：**先把事實攤開 + 對你提的 9 步流程做壓力測試**，把會讓後續 sub-agent 做白工或做錯的風險前置暴露出來，讓你在動工前拍板幾個岔路，再進入實作。

本次分析由 4 個平行探索 agent 完成（相依套件 / 流程+文件地圖 / 流程程式碼地圖 / Accessibility+build），並經主線獨立抽查驗證關鍵事實（MortalSwift 已非 FFI、PAT 外洩、路徑漂移）。

---

## Part 0 — 一個貫穿全案的前提：嚴重的「文件↔code 漂移」

這是最先要講的，因為它會**污染你後續每一個 sub-agent 的輸入**。若不先處理，第 7 步「用 sub-agent 一個個調整」很可能改到死碼、用錯路徑、照著過時行號動手。

已確認的漂移（節錄，完整 12 條在 Part 4）：

| 文件宣稱 | 實際 code |
|---|---|
| code 在 `Naki/ViewModels/…`、`Naki/Services/…`、`Naki/Resources/…` | 全部在 **`command/…`** |
| build `-scheme Naki`、`macOS 13.0+` | 主 target 是 macOS **Naki**（`productName=akagi`），但 deployment target 是 **macOS 26.0 / Xcode 26**，用 macOS 26+ `WebPage` API |
| 「Core ML via **MortalSwift FFI**」 | MortalSwift v0.3.0 已改**純 Swift + Core ML**；舊 FFI 檔 `MortalBot.swift` 仍在但已被 build 排除 |
| AutoPlay 重試在 `AutoPlayService.swift` | 活路徑在 `WebViewModel.executeAutoPlayActionWithRetry`（`command/ViewModels/WebViewModel.swift:816`）；`AutoPlayService` 幾乎是死碼 |
| JS 注入在 `WebViewController.init()`、bridge 叫 `window.nakaMessenger`、4 個 JS module | 注入在 `WebViewModel.init()`（`:112-115`）、handler 名 `websocketBridge`、**5** 個 module（`naki-recommendation-shimmer.js`/`naki-webgl-shimmer.js` 已不存在） |
| timer「每 2 秒」 | 實際 **1.0 秒**（`WebViewModel.swift:201`） |
| `WebViewModel.swift:1162`、`NativeBotController.swift:902` 等 Key Files 行號 | 佔位式虛構行號（NativeBotController 全檔 904 行，:902 是 `}`） |

> `FLOW_COMPARISON.md` 甚至自相矛盾：中段把「Bot 重建/end_game 清理」當「待修復」並給與真實類名不符的 pseudo-code，文末又標「✅ 已修復」。實際上這些修復**已落地**在 `NakiWebCoordinator.handleMJAIEvent`。

---

## Part 1 — 主要流程文件清單（你要的第一個輸出）

### 描述 Naki 自身流程/架構的核心文件
| 文件 | 描述哪條流程 | 漂移 |
|---|---|---|
| `CLAUDE.md` | 頂層 pipeline 總覽 + 三層規則 + XOR/生命週期要點 | 🔴 重度（路徑、行號、FFI、timer） |
| `FLOW_COMPARISON.md` | Python(Akagi) vs Swift 訊息處理逐段對照：Bot 重建 / XOR 差異 / syncGame 重連 / 生命週期 | 🟠 自相矛盾（待修復 vs 已修復） |
| `docs/architecture-deep-dive.md` | 最深技術細節：pipeline、service 初始化、JS 注入、重試、生命週期狀態機、Debug 端點 | 🔴 重度（路徑、注入點、module、重試檔、timer 全錯） |
| `README.md` | 使用者向功能 + 概念架構圖 | 🟡 輕度（JS module 漏列） |
| `note/async-stream-event-management.md` | `MJAIEventStream` AsyncStream/歷史重放設計 | 🟡 路徑類 |

### 屬「Majsoul 遊戲 WebUI 逆向」參考（常被誤當 Naki 架構文件）
- `docs/majsoul-webui-objects-reference.md`（Laya `DesktopMgr.Inst` 物件/效果/按鈕/大廳/心跳）
- `docs/majsoul-webui-api-architecture.md`、`docs/majsoul-minigame-snowball-reference.md`

### 工具/troubleshooting/meta（非流程，列出避免誤判）
`docs/shell-tools-guide.md`、`docs/mcp-server-guide.md`、`docs/debug-api-help-endpoint.md`、`note/DIAGNOSIS_AND_SOLUTION.md`、`note/TROUBLESHOOT_RECOMMENDATIONS.md`（此二者引用**已不存在**的 shimmer JS）、`note/red-dora-discard-fix.md` 等。

---

## Part 2 — 真實 runtime 流程（以 `command/` 為準）

```
啟動  Naki/App/NakiApp.swift:10  @main(macOS) → ContentView()
      ContentView.swift:13  @State viewModel = WebViewModel()（唯一實例）→ .environment 注入

WebViewModel.init()  command/ViewModels/WebViewModel.swift:94-165
  建 NakiWebCoordinator/Decider/Presenter → 注冊 handler "websocketBridge"
  → 注入 5 個 JS module → 建 WebPage → NativeBotController → AutoPlayController
  → startDebugServer()(:153, port 8765) → setMode(.auto)(預設全自動)
  → startAutoPlayCheckTimer()(1.0s, :201) → observeNavigations()

主鏈：
  JS hook window.WebSocket（WebSocketInterceptor.swift:26-32，注入序 core→autoplay→game-api→websocket→coordinator）
   → websocketBridge → handleWebSocketMessage(:316) → MajsoulBridge.parse(:133)
   → LiqiParser.parse + convertToMJAI(:153, dict 版=活路徑)
        login→accountId；authGame Res→emit start_game{id:seat}(:219)
        .lq.ActionPrototype→parseAction(:270)→start_kyoku/tsumo/dahai/chi/pon/kan/dora
        syncGame/enterGame→parseSyncGameRestore(:674，只重播 actions，不發 start_game)
        NotifyGameEndResult→end_game
   → onMJAIEvent → NakiWebCoordinator.handleMJAIEvent(WebViewController.swift:159)
        start_game→eventStream.startNewGame()+deleteNativeBot()+createNativeBot()+startEventConsumer()
        end_game→清理；default→eventStream.emit()
   → MJAIEventStream(AsyncStream+歷史重放) → viewModel.processNativeEvent(:284)
   → NativeBotController.react(dict, :208) → await bot.react(MortalSwift actor/Core ML) → updateRecommendations(:622)
   → updateUIAfterBotResponse(:347) 同步狀態 + gameStateManager.syncFrom(:361)
        + JS 高亮 window.__nakiRecommendHighlight + triggerAutoPlayIfNeeded(:550)
   → triggerAutoPlayNow(:775) → executeAutoPlayActionWithRetry(:816, 50×0.1s)
        → JS window.naki.action.discard/chi/pon/kan/hora/pass/riichi(naki-coordinator.js)

Bot 生命週期：每次 start_game 都 delete+create Bot（已對齊 Akagi）；斷線→resyncBot() 重放歷史
Server：DebugServer(port 8765) 內嵌 MCPHandler → REST 端點與 POST /mcp（JSON-RPC, 47 tools）走同一套工具
```

### 相依套件生態（`相關套件`那部分）
Naki（app）依賴兩個 SPM：
- **MortalSwift** 0.3.0（純 Swift + 內嵌 `mortal.mlmodelc` Core ML；AI 引擎）
- **MCPWebKit** 0.2.2 → 內含 **MCPKit** 0.2.1 + **WebViewBridge** 0.1.1（AI 驅動 WebView）

同層 sibling repo：`MCPKit`、`WebViewBridge`、`MCPWebKit`、`MCPWebKitApp`（demo）、`AGARIO`（另一個用同 stack 的 app，port 8766）。全部屬 `github.com/Sunalamye`。
> **架構味道**：Naki 一邊 link MCPWebKit，一邊在 `command/Services/MCP/` **自帶一套平行 MCP 實作**（MCPContext/Handler/Tool/Registry 重複了 MCPKit 的 Core）+ Naki 專屬 47 工具。兩套 MCP 不是同一份 code。

---

## Part 3 — 邏輯/寫法問題清單（依嚴重度）

> 已檢查判定 **OK**：XOR 邊界正確（`liqiDecode` 用 `UInt8(u & 0xFF)`；反而 CLAUDE.md 文件裡的 `UInt8(u)` 會 trap）；主自動打牌 discard 路徑先 `findTileInHand(name)` 轉 UI index，已避開索引不匹配。

### 🔴 HIGH
1. **AutoPlayController 用「排序後的 Swift tehai 索引」當 UI 手牌索引 → 打錯牌**（`AutoPlayController.swift:198-199` → `naki-coordinator.js:466`）。這是 docs 明令禁止的老 bug 的殘留第二條路徑，經 `/bot/trigger`（HTTP/MCP）觸發。**修法**：改傳牌名走 `findTileInHand`，或直接刪此並行路徑統一走 WebViewModel。
2. **舊 Bot inflight 推論與新 Bot 競態 → 跨局污染 / 可能崩潰**。`NativeBotController` 非 actor / 非 @MainActor，`await bot.react` 有暫停點；重連/`start_game` 換掉 MortalBot 後，舊 react 恢復仍寫共享 `tehai/lastRecommendations`。**修法**：NativeBotController 改 actor 或 @MainActor 序列化；換 bot 前 await/cancel inflight；用 generation token 丟棄過期回應。
3. **`is3P` 永遠 false，三麻旗標從未傳到 MortalBot → 三麻推薦全錯**（`WebViewModel.swift:273` 預設 false；`NativeBotController.swift:96` 硬編 version:4、無 sanma 參數）。**修法**：由 seatList/`start_game.names.count==3` 決定並傳入。
4. **多條終止/錯誤路徑漏清 `currentExecutionId` → 自動打牌黏著卡死**。pass 成功、直接執行、catch 路徑都沒清（`WebViewModel.swift:894/911/1008`），而 1 秒輪詢以 `== nil` 為重觸發前提（:222）。**修法**：所有終止路徑統一 `defer { currentExecutionId = nil }`。

### 🟠 MEDIUM-HIGH
5. **MJAIEventStream continuation 指派競態 → 消費者啟動後最初幾個 live 事件遺失**（continuation 指派被丟進延遲 `Task`，`MJAIEventStream.swift:100-102`）。start_game 後緊接的 start_kyoku/tsumo 可能遺失。**修法**：在建 stream 的閉包內同步保存 continuation，勿跨 Task hop。
6. **每則 WS 訊息各包一個獨立 Task → 事件亂序 / 早於 bot 建立**（`WebViewController.swift:108-114`）。**修法**：單一序列化通道（actor + AsyncStream）保證 FIFO 且 bot ready 後才消費。
7. **事件驅動與 1 秒 timer 兩套觸發、去抖不一致 → 重複/遲發動作**；discard 重試路徑跳過 oplist 直接執行（:856）。**修法**：timer 路徑套同一去抖鍵，discard 前校驗仍是自己回合。
8. **dict 路徑自風(jikaze)差一**（`NativeBotController.swift:506` 用 `kyoku%n`，typed 版用正確 `(kyoku-1)%n`）。顯示用但兩版不一致。**修法**：dict 版對齊 `(kyoku-1)%n`。

### 🟡 MEDIUM / LOW（表列）
| # | 位置 | 問題 | 修法 |
|---|---|---|---|
| 9 | `MajsoulBridge.swift:674-750` | 重連時 snapshot 與重放 actions 各發一次 start_kyoku（重複） | 二選一，對齊 Akagi |
| 10 | `MajsoulBridge.swift:216-232` | 找不到 accountId 時 seat 靜默預設 0 → 全推薦錯 | 拒建 bot/上報錯誤 |
| 11 | `WebViewModel.swift:239/263/753` | 空 catch 吞掉所有 JS 失敗（疊加 #4 靜默卡死） | 至少記錄 + 退避重試 |
| 12 | `LogManager.swift:103-109` | FileHandle 跨執行緒 seek+write 無同步、never close | 序列 queue/actor 包裝 |
| 13 | `MajsoulBridge.swift:83,483` | pendingReachAccepted 榮和情境誤發、end_kyoku 不清 | reset 時清除 |
| 14 | `GameStateManager.swift:18` | `ObservableObject` 與 WebViewModel 的 `@Observable` 混用 → UI 可能不更新 | 統一 @Observable |
| 15 | `WebViewModel.swift:1193` | GameStateManager 只寫不清 → MCP `/bot/status` 回報**過時推薦** | end_game 清理 + 隨 #2 actor 化 |
| 16 | `naki-coordinator.js:466` | discard 索引 `Math.min` 靜默夾取 → 掩蓋 #1 | 越界回傳失敗 |
| 17 | `LiqiParser.swift:117-133` | protobuf length 未防溢位；未知 wireType 直接中止整條 | 加上限 + 正確跳過欄位 |
| 18 | `MajsoulBridge.swift:743-748` | 重連只取第一個寶牌，漏 kan-dora | 逐一補發 dora 事件 |
| 19 | `DebugServer.swift:179-187` | HTTP 單次 receive 假設整包 ≤64KB → 大 `/js`·`/mcp` body 跨 TCP 段被截斷 | 累積讀取直到 body 完整 |
| 20 | `MajsoulBridge.swift:540-579` | `parseChiPengGang` 在 `froms` 缺失時用啟發式猜 consumed（註解自標「備用」） | 對真實 chi payload 驗證，補正 |
| 21 | `NativeBotController.swift:859` | `GameState.kyotaku` 永遠 0（bridge 有解析但 controller 未寫入）TODO | controller 持久化 kyotaku 到 gameState |
| 22 | `DebugServer.swift:117,554` | CORS `*` + `execute_js` 曝露 → 任何本機 process/頁面可驅動 47 工具（含遊戲 context 執行） | 帳號安全審視：綁 127.0.0.1 / 加 token / 收斂 origin |
| 23 | `LiqiParser.swift:359` | XOR 契約靠單一 default 參數 `xorDecode:true`，新 caller 忘記 flag 會靜默雙重解碼（無測試護欄） | 顯式化參數 + 加 guard/測試 |

### 死碼 / 重複實作（是多個 bug 的溫床）
- **強型別 MJAI pipeline 全未使用**：`MajsoulBridge.parseTyped/convertToTypedMJAI`（:768+）、`NativeBotController.react(event:MJAIEvent)`（:114）— 活路徑只走 dict 版。兩份會（且已）漂移（#8 就是這樣來的）。
- **`AutoPlayService`（661 行）近乎死碼**：被 delegate/setWebPage 綁定但 `triggerAction()` 從未被呼叫；用 `NetAgent.sendReq2MJ`（與活路徑 `window.naki.action.*` 不同機制）。
- **3 套 autoplay 實作**：WebViewModel(主) / AutoPlayController(管 mode + 危險的 #1 路徑) / AutoPlayService(死)。

### 🔐 安全（獨立於本案，但應處理）
`MortalSwift/.git/config` 的 origin URL 內嵌一個 classic GitHub PAT（`ghp_jx3X…`，已驗證存在）。**應撤銷/輪替**，並改用 SSH remote（與你 CLAUDE.md 的 remote 規範一致）。

---

## Part 4 — 對「你提的 9 步流程」的強化建議（本案重點）

你的原始流程：①梳理 ②分析異常 ③輸出流程文件 ④從流程分析 logic ⑤找問題 ⑥輸出修法 ⑦sub-agent 逐一調整 ⑧反覆 check + 確定能 build ⑨加 Accessibility。

方向正確，但有 6 個會讓它翻車或事倍功半的缺口：

1. **【最高槓桿】文件漂移要在 sub-agent 動工前先校正。** 你的 ⑦「sub-agent 一個個調整」若讀到現有 CLAUDE.md/docs，會被錯路徑、虛構行號、"FFI"、"2 秒 timer"、"重試在 AutoPlayService" 直接誤導 → 改到死碼或錯檔。**建議加 Phase 0：把 CLAUDE.md / FLOW_COMPARISON / architecture-deep-dive 校正到與 `command/` 一致**（或至少產出一份「校正過的 brief」餵給每個 sub-agent）。

2. **「確定能 build」要當 Phase 0，不是 Phase 8。** 沒有先建立 green baseline，就無法分辨 build 壞是你改的還是本來就壞。且本專案需 **Xcode 26 / macOS 26**，要先確認此機器能否 build（很可能是第一個卡點）。文件裡的 `xcodebuild test -scheme Naki` 還**跑不到測試**（測試綁在 iOS Naki-M，且無 Naki-M shared scheme）。

3. **「修 vs 刪」要先拍板，再逐一調整。** 3 套 autoplay + 死的 typed pipeline 是 #1/#8 等 bug 的來源。若不先決定「刪掉死路徑、統一單一實作」，sub-agent 會出現「修了一份、另一份繼續漂移」或「修到該刪的碼」。**建議：去重/收斂決策前置。**

4. **bug 要分級分流，不要一律「一個個 sub-agent 平行改」。** 18 項裡，並發/生命週期類（#2/#5/#6/#15）是**架構級改動、彼此耦合**，平行丟給獨立 sub-agent 會互撞、且難驗證；機械級（#8 差一、#16 夾取、#10 預設 0）才適合平行。**建議分兩組：(A) 安全機械修 → 可平行；(B) 並發/生命週期重構 → 單一序列化、配測試謹慎做。**

5. **「mac app 測試更友好」缺一個 macOS 測試載體。** 現有 test target 都是 **iOS Naki-M**，沒有 macOS 測試 target/scheme；UITests 全是空殼（`app.launch()` 無斷言、零 accessibilityIdentifier）。只加 accessibility label 只會改善 VoiceOver，**不會讓「測試」更友好**。**建議：先補 macOS 測試 target + shared scheme（讓 accessibilityIdentifier 有 XCUIElement 可抓），再鋪 Accessibility。** 這是 ⑨ 的前置，不是附帶。

6. **驗收紀律（對照你的 CLAUDE.md）。** 每個 sub-agent 的產出是**候選**，要用事實驗（build 輸出 / diff / 實際行為）。但這是有帳號風險的自動打牌 bot——autoplay/bot 生命週期類的修正**無法只靠單元測試驗**，需定義「哪些可單測、哪些需真人對局測」。**建議每項修正預先標註驗收方式**，避免只驗 happy path 就宣稱完成。

### 保存方向（你問的「保存方向」）建議
分三層，互不重疊：
- **就地修文件**（durable）：把 CLAUDE.md / FLOW_COMPARISON / architecture-deep-dive 改到不再說謊 —— 這是最有價值的保存。
- **凍結本次稽核**：用一份 `AUDIT.md`（或你的 `charter-forge` skill）把「18 項發現 + 修/刪決策 + 驗收方式」固化，給下一個 session 接手。
- **跨 session 決策入 mempal**：刪/留、target 方向、Accessibility 範圍等決策 ingest 到本 repo wing。
- （可選）加一個輕量「doc↔code 路徑檢查」防止再漂移。

---

## Part 5 — 定案執行流程

> **已確認決策（4/4 採建議）**：① 先做 Phase 0；② 死碼/重複實作**刪除收斂成單一實作**；③ **新建 macOS 測試 target + shared scheme**；④ 保存 = **就地修文件 + AUDIT.md + mempal**。

```
Phase 0  地基（阻斷級，先做，全綠才進 Phase 1）
  0a 確認 Xcode 26 / macOS 26 可 build → xcodebuild build -scheme Naki，抓 green baseline
     （若此機器無法 build，這是第一個要解決的卡點，先回報再議）
  0b 記錄現有測試現況（確認需 -scheme Naki-M 才跑得到，且都是空殼）
  0c 校正三份文件 → 對齊 command/ 真實：CLAUDE.md、FLOW_COMPARISON.md、docs/architecture-deep-dive.md
     （路徑 Naki/→command/、行號、FFI→CoreML、2s→1s timer、注入點、JS module 5 個、
      DebugServer=MCP 同一 server；FLOW_COMPARISON 的「待修復」標記改為「已落地」）
  0d 撤銷/輪替 MortalSwift/.git/config 的外洩 PAT，remote 改 SSH（依你的 CLAUDE.md remote 規範）

Phase 1  去重收斂（先刪，縮小後續修正面）
  1a 刪未使用的 typed MJAI pipeline：MajsoulBridge.parseTyped/convertToTypedMJAI/parseTyped*、
     NativeBotController.react(event:MJAIEvent)+updateInternalState(from:MJAIEvent)
     → dict 版成為唯一 canonical（#8 jikaze 之後只需在 dict 版修一處）
  1b 刪近乎死碼的 AutoPlayService（661 行）及其 delegate/setWebPage 綁定
  1c autoplay 收斂為 WebViewModel 單一路徑：移除 AutoPlayController 危險的
     executeAction/generateJavaScript「排序索引 discard」路徑（= 直接消滅 #1），
     保留 AutoPlayController 的 mode 管理；/bot/trigger 改走 WebViewModel.findTileInHand
  1d 每刪一塊即 build 驗證仍綠（易刪錯，逐塊 commit）

Phase 2  邏輯修正（分兩組）
  A 組 安全機械修（可平行 sub-agent，彼此無耦合）：
     #8 dict 版 jikaze 改 (kyoku-1)%n ｜ #10 找不到 seat 拒建 bot/上報 ｜ #13 pendingReachAccepted 於 reset 清除
     #16 naki-coordinator.js discard 越界回失敗（配合 #1 收斂）｜ #18 重連補發 kan-dora
     #11 空 catch 至少記錄 ｜ #12 LogManager 檔案寫入序列化 ｜ #14 GameStateManager 統一 @Observable
     #17 protobuf length 上限 + 未知 wireType 正確跳過
  B 組 並發/生命週期重構（單一序列處理，不平行，配測試謹慎做）：
     核心：NativeBotController 改 actor 或 @MainActor 序列化（#2）
     連帶：#5 continuation 同步保存 ｜ #6 事件單一序列化通道 FIFO ｜ #4 currentExecutionId 全路徑 defer 清除
           #7 timer 路徑套同一去抖鍵 + discard 前校驗回合 ｜ #15 隨 #2 actor 化提供快照讀取
     修 #3：由 seatList/start_game.names.count==3 決定 is3P 並傳入 MortalBot（含 createNativeBot 移除誤導預設）
  C 組 補完項（穩健性/安全/正確性，多為機械可平行；#20 需資料驗證）：
     #19 DebugServer 累積讀取完整 HTTP body ｜ #20 parseChiPengGang consumed 對真實 payload 驗證補正
     #21 controller 持久化 kyotaku 到 gameState ｜ #22 DebugServer 綁 127.0.0.1/加 token（帳號安全）
     #23 XOR 契約顯式化 + 加測試護欄
  每項標註驗收：可單測（#8/#10/#13/#16/#17/#18/#19/#21/#23）｜ 需資料/對局驗（#1/#2/#3/#4/#7/#20/#22）

Phase 3  測試地基 + Accessibility（涵蓋全部 5 個 View，依 Accessibility 稽核完整缺口清單）
  3a 新建 macOS 測試 target（unit + UI）+ shared Naki scheme（含 test plan）→ 讓測試真的跑得動
  3b 補 accessibilityIdentifier（所有互動元件）→ XCUIElement 可抓（測試友好的核心前置）
  3c 補 accessibilityLabel/Value：icon-only 按鈕、顏色-only 狀態（連線/MCP/Bot 燈、ActionBadge 可用性、
     機率條分級）、麻將 Unicode 牌轉人類可讀（「五萬」「紅五萬」）
  3d 組合破碎 row 為單一可讀元素：RecommendationRow / LogEntryRow / ScoreLabel / Dora
  3e WKWebView（Laya/WebGL 黑盒）標 accessibilityHidden，原生側板作為可測面 + 給容器 identifier
  3f Dynamic Type / 對比（最後，最動版面）：.font(size:8) 換 text style、移除會截斷的固定寬、低透明度徽章對比
  ＊Color+Extension.swift 已用語意色，保留為擴充範式

Phase 4  反覆 check + 驗收 + 保存
  4a build 綠（Naki macOS）+ 新 macOS 測試跑得動 + UITest 用 identifier 斷言
  4b 高風險項（autoplay/bot 生命週期）真人對局驗，回報 已完成/已驗證/未驗證/已知風險
  4c 保存：三份文件已就地修正（0c）+ 寫 AUDIT.md 凍結 18 項發現與修/刪決策 + 關鍵決策 ingest mempal 本 repo wing
```

### 執行方式（sub-agent 分工）
- Phase 0/1：主線親自或單一 sub-agent 序列處理（刪碼與改文件不宜平行，易衝突）。
- Phase 2-A：可派多個 surgical-executor 型 sub-agent 平行，各領一個機械修正。
- Phase 2-B：**單一** sub-agent 序列處理整組並發重構（彼此耦合，平行會互撞），配測試。
- Phase 3：測試 target 先建（阻斷級），Accessibility 再依 View 分派平行 sub-agent。
- 每個 sub-agent 產出視為**候選**，主線用 build 輸出 / diff / 實際行為驗，符合你 CLAUDE.md 驗收紀律。

---

## 驗證方式（End-to-End）
- **Build baseline**：`xcodebuild build -project Naki.xcodeproj -scheme Naki`（macOS Naki target）→ 記錄是否綠。
- **測試現況**：確認需 `-scheme Naki-M`（或新建 macOS 測試 scheme）才跑得到測試。
- **邏輯修正**：可單測項寫 XCTest；autoplay/bot 生命週期項以 Debug Server（`curl localhost:8765/bot/status`、`/logs`）+ 真人對局觀察。
- **Accessibility**：Accessibility Inspector 逐元件檢查 label/value；新 macOS UITest 用 `app.buttons["<identifier>"]` 斷言。
- **每步驗收區分**：已完成 / 已驗證 / 未驗證 / 已知風險（對照你的 CLAUDE.md 驗收紀律）。

---

## 已確認決策（4/4 採建議）
1. **先做 Phase 0**（校正文件漂移 + build/test baseline）再碰 logic。
2. 死碼/重複實作 → **刪除收斂成單一實作**（typed pipeline、AutoPlayService 刪；autoplay 收斂為 WebViewModel 一條路徑）。
3. 測試載體 → **新建 macOS 測試 target + shared scheme**（讓 accessibilityIdentifier 有 XCUIElement 可抓）。
4. 保存方向 → **就地修文件 + AUDIT.md + mempal**。

## 完整性保證（本 plan 涵蓋範圍）
- 全部 **23 項**邏輯/寫法發現（HIGH 4 + MED-HIGH 4 + MED/LOW 15），無遺漏。
- 死碼收斂（typed MJAI pipeline、AutoPlayService、3 套 autoplay）。
- 文件漂移 12 條 → 校正三份核心文件。
- 安全（外洩 PAT #0d、DebugServer 曝露 #22）。
- 測試地基（macOS test target + scheme + test plan）。
- Accessibility 全部 5 個 View 的完整缺口（identifier / label / value / 組合 row / WebView / Dynamic Type / 對比）。
- 保存（就地修文件 + AUDIT.md 凍結 + mempal ingest）。
- 有先後順序（Phase 0→4，阻斷級先行），但範圍完整不砍項。

---

# Part 6 — 各 Phase 完整設計（implementation-ready）

> 「先後順序」= Phase 0→4 依序；「完整」= 每一項都設計到可直接交 sub-agent 執行。下面把每個 Phase 展開到檔案/符號/改法/依賴/驗收。

## Phase 0 — 地基（阻斷級）

**0a build baseline**
- 指令：`xcodebuild -project Naki.xcodeproj -scheme Naki -destination 'platform=macOS' build 2>&1 | tail -40`
- 記錄：成功/失敗、警告數、Swift/SDK 版本、baseline commit hash。
- **卡點處理**：若因 Xcode 26 / macOS 26 缺失無法 build → 立即回報（這是全案第一前置），不進 Phase 1。

**0b test 現況**
- `xcodebuild -scheme Naki -destination 'platform=macOS' test`（預期 scheme TestAction 空 → 無測試執行）。
- 確認 Naki-MTests/UITests 綁 iOS `Naki-M.app` host、只有 user scheme。記錄「測試目前跑不動」為事實 baseline。

**0c 文件校正（三份，逐條對映）**
- `CLAUDE.md`：Code Structure 樹 `Naki/…`→`command/…`；Key Files 行號改真實錨點（WebViewModel 1381 行、MajsoulBridge 1176、NativeBotController 903）；「Core ML via MortalSwift **FFI**」→「pure Swift + Core ML」；build 段補 macOS 26/Xcode 26 需求、修正 test scheme 說明。
- `FLOW_COMPARISON.md`：「Swift 流程（需要修復）」整段改為「已落地於 `NakiWebCoordinator.handleMJAIEvent`（`command/Views/WebViewController.swift:165-194`）」；pseudo-code 類名 `WebViewController.Coordinator`→`NakiWebCoordinator`；刪除「待修復 vs ✅ 已修復」時態矛盾。
- `docs/architecture-deep-dive.md`：全路徑 `Naki/`→`command/`；JS 注入點 `WebViewController.init`→`WebViewModel.init`（`:112-115`）；`window.nakaMessenger`→handler `websocketBridge` + `window.naki`；JS module 4→**5**（core/autoplay/game-api/websocket/coordinator，注入序）；重試位置 `AutoPlayService`→`WebViewModel.executeAutoPlayActionWithRetry:816`；timer 2s→**1.0s**；Xcode 結構補 Naki-M/兩 test target/`command` synchronized folder/雙平台事實；「MortalSwift FFI」段更新為 CoreML。
- 驗收：三份文件內每個路徑/行號/名稱可在 `command/` 對得上（抽查 5 處）。

**0d PAT 撤銷（依你 CLAUDE.md remote 規範，NEVER 刪舊 remote）**
- `git -C ../MortalSwift remote rename origin old_origin`
- `git -C ../MortalSwift remote add origin git@github.com:Sunalamye/MortalSwift.git`
- 提示**你本人**到 GitHub 撤銷該 `ghp_` classic token（我無法代撤）。
- 驗收：`git -C ../MortalSwift remote -v` 不再含 token。

---

## Phase 1 — 去重收斂（先刪，逐塊 commit，每塊 build 綠）

**1a 刪 typed MJAI pipeline**
- `MajsoulBridge.swift`：刪 `parseTyped`（:142-147）、`convertToTypedMJAI`（:768+）、`parseTyped*` 全族與 `parseTypedGameState`。
- `NativeBotController.swift`：刪 `react(event: MJAIEvent)`（:114-171）、`updateInternalState(from: MJAIEvent)`（:306-351）、typed `handleStartKyoku`（:370 等 typed 系）。
- 前置檢查：`rg 'parseTyped|convertToTypedMJAI|react\(event: MJAIEvent'` 確認除自身無 caller；確認 `MJAIEvent`/`MJAIAction` 型別是否仍被 MortalSwift 或 dict 路徑引用（是→保留型別，只刪未用方法）。
- 驗收：build 綠、活路徑（dict）行為不變 → commit。

**1b 刪 AutoPlayService**
- 刪整檔 `command/Services/AutoPlay/AutoPlayService.swift`。
- `WebViewModel.swift:146-147`：移除 `autoPlayService.delegate=self`、`setWebPage`、相關 property 與 `AutoPlayServiceDelegate` conformance。
- `rg 'AutoPlayService|triggerAction'` 確認無殘留引用。驗收 build 綠 → commit。

**1c autoplay 收斂為單一路徑（消滅 #1）**
- `AutoPlayController.swift`：移除 `executeAction`/`generateJavaScript` 的「排序索引 discard」路徑（:198-299）；**保留** mode enum/state/`setMode`。
- `WebViewModel.swift:1227-1242`（`/bot/trigger` 回呼）：不再用 `AutoPlayController.lastAction` 的 index，改呼叫 WebViewModel 主路徑（`findTileInHand(name)` → `window.naki.action.discard(uiIndex)`）。
- 驗收：`/bot/trigger` 打出的牌與主自動路徑一致（真人對局或 debug log 對照）→ commit。

---

## Phase 2 — 邏輯修正（A 平行 / B 序列 / C 補完）

### A 組（無耦合，可平行 sub-agent，多為單測可驗）
- **#8 jikaze**：`NativeBotController.swift:506` 改 `(playerId - ((kyoku-1) % n) + n) % n`。單測：kyoku=1→oya=0。
- **#10 seat 預設 0**：`MajsoulBridge.swift:216-232` 找不到 accountId → 不發 `start_game`、`log.error` + emit error，阻止建 bot。單測：seatList 不含 accountId 時不 emit start_game。
- **#13 pendingReachAccepted**：`MajsoulBridge.swift`：end_kyoku/reset 時清 nil；下個 action 為 `ActionHule` 時丟棄 pending（立直棒未實放）。
- **#16 JS discard 夾取**：`naki-coordinator.js:466` 移除 `Math.min(...)`，越界 `return {success:false, reason:'index out of range'}`。
- **#18 kan-dora**：`parseGameState`（`MajsoulBridge.swift:743`）對 `doraList[1...]` 逐一補發 `dora` event。
- **#11 空 catch**：`WebViewModel.swift:239/263/753` 加 `log.error`（保留不中斷語意）。
- **#12 LogManager 檔案寫入**：`LogManager.swift:103-109` 用專用 serial `DispatchQueue`（或 actor）包 `seekToEndOfFile+write`；加 `deinit` close fileHandle。
- **#14 觀察模型統一**：`GameStateManager.swift:18` `ObservableObject`+`@Published`→`@Observable`；View 端取用改直接屬性存取（確認無 `@ObservedObject` 依賴）。
- **#17 protobuf 穩健**：`LiqiParser.swift:117-133` 加 `length` 上限與 `offset+length<=data.count` 溢位防護；未知 wireType（3/4/5）依 varint/fixed64/fixed32 正確跳過而非中止整條。單測：餵含未知欄位的 buffer。

### B 組（彼此耦合的並發/生命週期重構，**單一 sub-agent 序列**做，配測試）
- **#2 核心：NativeBotController 序列化**。將 class 改 `actor`（`react`/`updateRecommendations`/`updateInternalState` 已 async；caller `processNativeEvent:284` 已 await）；加 **generation token**：每次 `createBot` `generation += 1`，`react` 進入時捕獲 `gen`，寫回 `tehai/lastRecommendations/lastAction` 前檢查 `gen == generation`，不符則丟棄（消滅舊 bot inflight 污染）。
- **#5 continuation 競態**：`MJAIEventStream.swift:100-102` continuation 指派移出延遲 `Task`，在 `AsyncStream { c in self.continuation = c }` 建立閉包內**同步**保存。
- **#6 事件序列化**：`WebViewController.swift:108-114` 每訊息獨立 `Task` → 改為單一序列化 mailbox（actor 或串接的 AsyncStream），保證 `handleMJAIEvent` FIFO，且 `start_game` 的 `createNativeBot` 完成前不消費後續事件。
- **#4 currentExecutionId 全清**：`WebViewModel.swift` `executeAutoPlayActionWithRetry` 與 `checkAndRetryIfNeeded` 所有終止路徑（成功/放棄/錯誤/catch，:894/911/1008）以 `defer { currentExecutionId = nil }` 統一清除。
- **#7 觸發去抖統一**：`checkAndRetriggerAutoPlay:210-243` 套用 `triggerAutoPlayIfNeeded` 的 `lastTriggerKey/Time` 去抖；discard 執行前校驗 oplist/仍為自己回合。
- **#15 快照讀取**：隨 #2 actor 化，`GameStateManager.syncFrom:163` 改讀 controller 提供的 snapshot（值型別）而非直接讀可變屬性。
- **#3 sanma 旗標貫通**：`MajsoulBridge` `start_game` event 帶 `names`/`playerCount`；`WebViewController.handleMJAIEvent` 傳 `is3P = names.count == 3` 給 `createNativeBot`；`NativeBotController.createBot` 接 `is3P` 傳給 `MortalBot`。**依賴驗證**：先確認 MortalSwift 是否提供三麻模型/參數（`MortalBot(... is3P:)` 或 mortal3p mlmodel）；若無 → 標記為「需 MortalSwift 支援」的已知風險，不硬塞。
- **#9 重連重複 start_kyoku**：`parseSyncGameRestore`（`MajsoulBridge.swift:674-710`）目前先由 snapshot 發一個 `start_kyoku`（`parseGameState:750`），再重放 `actions[]`，其中 `ActionNewRound` 又發一個（`parseNewRound:392`）→ 兩個 start_kyoku 破壞局狀態。**修法**：對齊 Akagi，重連時**只重放 actions、不由 snapshot 發 start_kyoku**（snapshot 僅用來補 dora/scores 等 #18 用途）；或反之只用 snapshot。二選一並加註解說明。驗收：斷線重連後手牌/局狀態與斷線前一致（真人對局 + `/bot/status` 對照）。
- B 組驗收：可單測部分（generation token 丟棄邏輯、去抖鍵）寫 XCTest；事件順序/重連污染需真人對局（斷線重連、連續兩局、三麻）觀察。

### C 組（穩健性/安全/正確性補完）
- **#19 HTTP body 截斷**：`DebugServer.swift:179-187` 依 `Content-Length` 累積 `connection.receive` 直到 body 收滿再解析。
- **#20 chi consumed 啟發式**：`MajsoulBridge.swift:540-579` 抓真實 `ActionChiPengGang` payload（debug log）驗 `froms`/consumed，補正缺失 fallback。需資料。
- **#21 kyotaku**：`NativeBotController.swift:859` 將 bridge `start_kyoku` 帶的 kyotaku 持久化寫入 `gameState.kyotaku`（移除 TODO 的常數 0）。
- **#22 DebugServer 曝露（帳號安全）**：NWListener 綁 `127.0.0.1`；CORS `*` 收斂；可選加 token header。**對照你 CLAUDE.md「Modifying WebSocket/auto-play 需 Ask」**→ 此項改動前先與你確認範圍。
- **#23 XOR 契約硬化**：`LiqiParser.swift:359` `parseActionPrototype` 移除 `xorDecode` default，所有 caller 顯式傳；補 normal(XOR) vs reconnect(no-XOR) 的單測護欄，避免新 caller 靜默雙重解碼。

---

## Phase 3 — 測試地基 + Accessibility

**3a 新建 macOS 測試 target（阻斷級：Accessibility 測試的前置）**
- 在 `Naki.xcodeproj` 新增 macOS **unit**（`NakiTests`）與 **UI**（`NakiUITests`）target，`SDKROOT=macosx`、`TEST_HOST/BUNDLE_LOADER` 指 `Naki.app`。
- 把它們掛進 shared `Naki.xcscheme` 的 TestAction（或建 `Naki.xctestplan`）。
- 樣板 UITest：`app.launch()` + 對主容器 identifier 斷言。
- **風險提示**：手改 pbxproj 建 target 風險高 → 建議用 Xcode GUI 建（較安全），或 xcodegen；plan 標記此為需謹慎的手動/半自動步驟，建完先驗 `xcodebuild -scheme Naki test` 能跑再繼續。

**3b–3f Accessibility（逐 View，依稽核完整缺口）**
- **ContentView**：gear/reload/log-toggle/panel-toggle 加 `accessibilityLabel`+`accessibilityIdentifier`+（toggle 類）`accessibilityValue(on/off)`；AutoPlayMode `Picker` 與 delay `Stepper`/設定 `Slider` 加 label+value；MCP/連線指示（Circle+text）用 `.accessibilityElement(children:.combine)`+value（已連接/未連接、port）；`.font(.system(size:8))`（:123/215/363）→ 可縮放 text style。
- **BotStatusView**：reload label；running `Circle` 加 value（運行中/待機）；`ActionBadge`（:222）加 `accessibilityValue(可用/不可用)`+`.accessibilityAddTraits`；`DoraIndicatorsView` Unicode 牌 → 人類可讀 label（「五萬」「紅五萬」）；`ScoreLabel` isPlayer → label「（我）」。
- **LogPanel**：category `Picker` label；autoScroll toggle label+value；clear/trash 按鈕 label；search `TextField` identifier；`LogEntryRow` `.accessibilityElement(children:.combine)`。
- **RecommendationView**：reload label；機率條加 `accessibilityValue`（如「推薦度高 45%」）；tile glyph→牌名；top 推薦加 label「最佳」；`RecommendationRow` combine 成「第1推薦，打五萬，45%，最佳」+identifier；固定字級/寬（:41/70/77）改可縮放。
- **WebViewController**：`NakiWebView`（Laya/WebGL 黑盒）`.accessibilityHidden(true)`，容器給 identifier「majsoul-webview」供測試斷言存在。
- **Dynamic Type/對比**（最後）：移除會截斷的固定 frame（toolbar 160/80、設定 400×550、推薦 40pt）；低透明度徽章（`color.opacity(0.2)`）驗 WCAG 對比 / 加 increase-contrast 路徑；`Color+Extension.swift` 已用語意色 → 保留為範式。
- 驗收：每 View 用 Accessibility Inspector 檢查 label/value；`NakiUITests` 用 `app.buttons["<identifier>"]`/`app.pickers` 斷言可定位。

---

## Phase 4 — 反覆 check + 驗收 + 保存

**4a 建置與測試**
- `xcodebuild -scheme Naki -destination 'platform=macOS' build` 綠；新 macOS test（unit + UI）跑得動；UITest 以 identifier 斷言通過。

**4b 高風險真人對局驗**（無法只靠單測）
- 進遊戲觀察：自動打牌（#1/#4/#7）、推薦正確（#8/#10）、斷線重連（#2/#5/#6/#9/#18）、連兩局（#2）、三麻（#3，或標已知風險）。
- 回報格式：**已完成 / 已驗證 / 未驗證 / 已知風險**（對照你 CLAUDE.md 驗收紀律）。

**4c 保存（就地修文件已在 0c + AUDIT.md + mempal）**
- `AUDIT.md`：23 findings 表（狀態 fixed/deferred/風險）+ 修/刪決策 + 每項驗收方式 + 殘留風險（如 #3 依 MortalSwift、#22 待確認）。
- `mempal ingest`（本 repo wing）：關鍵決策 —— 死碼刪除收斂、autoplay 單一路徑、macOS 測試 target 方向、Accessibility 範圍、PAT 已輪替。

---

## 逐 Phase gate（每個 Phase 全綠才進下一個）
- G0：能 build（否則全案停）+ 三份文件對齊 + PAT 已處理。
- G1：三塊死碼刪完、build 仍綠、活路徑行為不變。
- G2：A/B/C 三組修正完成，可單測項綠、對局項已驗或標風險。
- G3：macOS 測試 target 可跑、五 View accessibility 補齊、UITest 以 identifier 斷言。
- G4：全綠 + AUDIT.md + mempal 保存完成。
