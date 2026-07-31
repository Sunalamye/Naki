# Naki 稽核與整修紀錄（AUDIT）

**日期**: 2026-07（本輪整修）
**範圍**: 全流程梳理 → 邏輯稽核 → 死碼收斂 → 邏輯修正 → Accessibility → macOS 測試地基
**基準 build**: macOS `Naki` scheme（Xcode 26 / macOS 26），停用簽章時 **BUILD SUCCEEDED / 0 error / 0 warning**
**變動規模**: 22 檔、+966 / −1811 行；新增 `NakiTests/`、`NakiUITests/`
**紀律**: 全程只改工作區、**未 commit / 未 push**（依 CLAUDE.md：commit 前須確認 why、NEVER 自動 push）。

> 驗收語彙：**已驗證**=編譯/plutil/build-for-testing 等事實佐證；**未驗證**=需真人對局或簽章環境才能確認的行為。

---

## 1. 建置 / 測試現況（Phase 0 + 3a）

- 需 **Xcode 26 / macOS 26**（deployment target 26.0、macOS 26+ `WebPage` API）。README/CLAUDE 舊稱「macOS 13.0+」已更正。
- 本機**缺 Mac Development 簽章憑證**（team `YRJZ6WG9VC`）→ 一般 `xcodebuild build` 會因簽章失敗；驗證時以 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` 繞過（純編譯驗證）。**簽章需你本機憑證。**
- 新增 macOS 測試 target：`NakiTests`（unit，host=Naki）、`NakiUITests`（UI，target=Naki），已加入 shared `Naki` scheme 的 TestAction。
  - `xcodebuild build-for-testing -scheme Naki`（停用簽章）= **TEST BUILD SUCCEEDED**。
  - **執行**測試（`xcodebuild test`）需簽章 + GUI session，headless 未跑；你本機可跑。
  - 測試檔：`NakiTests/NakiTests.swift`（牌名、#8 jikaze 公式 smoke test）、`NakiUITests/NakiUITests.swift`（用新 accessibilityIdentifier 斷言 app 啟動與工具列可定位）。

## 2. 文件漂移校正（Phase 0c）

已把 `CLAUDE.md`、`FLOW_COMPARISON.md`、`docs/architecture-deep-dive.md` 對齊真實 code：路徑 `Naki/`→`command/`；行號；FFI→純 Swift+Core ML；JS 載入點/handler 名/5 module；1.0s timer；DebugServer 內嵌 MCP（同一 server）；Bot 重建「已實作」非「待修復」；Xcode 雙平台結構。

## 3. 安全

- **外洩 PAT（已處理 git 端）**：`MortalSwift/.git/config` 原內嵌 `ghp_…` classic token。已 `git remote set-url origin git@github.com:Sunalamye/MortalSwift.git` scrub 掉。
  - **⚠️ 待你本人做**：到 GitHub 撤銷/輪替該 token（我無法代撤）。
- **#22 DebugServer 收斂（已驗證編譯）**：NWListener 綁 `requiredInterfaceType = .loopback`（阻止同網段裝置）、CORS `*`→`http://localhost:<port>`。本機 curl/MCP proxy 不受影響。

## 4. 死碼收斂（Phase 1，−1525 行）

| 刪除 | 原因 |
|---|---|
| typed MJAI pipeline（`MajsoulBridge.parseTyped*`、`NativeBotController.react(event:MJAIEvent)` 等） | 活路徑只走 dict 版；兩份會漂移（#8 即源於此） |
| `AutoPlayService.swift`（整檔 661 行） | `triggerAction` 從未被呼叫，死碼 |
| `AutoPlayController` 排序索引 discard 路徑 | 消滅打錯牌 #1；`/bot/trigger` 收斂走 WebViewModel 主路徑 |

> 關鍵發現：`/bot/trigger` 的「排序索引」分支在 baseline 就已是死路（`lastAction` 只由死掉的 typed react 寫入），故收斂為**行為保留**。

## 5. 邏輯修正（Phase 2，23 項）

| # | 嚴重度 | 狀態 | 摘要 |
|---|---|---|---|
| 1 | HIGH | ✅ 已修（Phase 1c 收斂） | AutoPlayController 排序索引打錯牌 |
| 2 | HIGH | ✅ 已修 | NativeBotController → @MainActor + generation token，丟棄舊 bot inflight 結果 |
| 3 | HIGH | ⚠️ 部分（硬限制） | is3P 已貫通到 createBot 邊界；但 **MortalSwift 無三麻模型/參數**，推論仍四麻 |
| 4 | HIGH | ✅ 已修 | currentExecutionId 全終止路徑守衛式清除（消除自動打牌黏著） |
| 5 | MED-HIGH | ✅ 已修 | MJAIEventStream continuation 同步保存（不漏 live 事件） |
| 6 | MED-HIGH | ✅ 已修 | WS 事件單一序列化通道（FIFO + bot-ready-before-consume） |
| 7 | MED-HIGH | ✅ 已修 | timer 觸發套用事件路徑去抖 + discard 前校驗回合 |
| 8 | MED-HIGH | ✅ 已修 | dict 版 jikaze 差一 → `(kyoku-1)%n` |
| 9 | MED | ✅ 已修 | 重連只重放 actions 發 start_kyoku（不再與 snapshot 重複） |
| 10 | MED | ✅ 已修 | 找不到 seat → 不發 start_game、log error（不再猜 0） |
| 11 | MED | ✅ 已修 | 空 catch 加記錄 |
| 12 | MED | ✅ 已修 | LogManager 檔案寫入序列化 + deinit close |
| 13 | MED | ✅ 已修 | pendingReachAccepted 榮和丟棄 + end_kyoku 清 |
| 14 | LOW | ✅ 已修 | GameStateManager → @Observable |
| 15 | LOW | ✅ 已修 | 隨 #2 actor 化，syncFrom 一致 isolation |
| 16 | LOW | ✅ 已修 | JS discard 越界回失敗（不再 clamp 掩蓋） |
| 17 | LOW | ✅ 已修 | protobuf length 溢位防護 + 未知 wireType 正確跳過 |
| 18 | LOW | ✅ 已修 | 重連補發 kan-dora（第 2 個以後 dora） |
| 19 | LOW | ✅ 已修 | DebugServer 依 Content-Length 累積讀取完整 body |
| 20 | LOW | ⏸ deferred | parseChiPengGang consumed 啟發式 — **需真人對局真實 payload 才能驗** |
| 21 | LOW | ✅ 已修 | kyotaku 持久化到 gameState |
| 22 | 安全 | ✅ 已修 | DebugServer 綁 loopback + 收緊 CORS |
| 23 | LOW | ✅ 已修 | XOR 契約顯式化（移除 default 參數） |

## 6. Accessibility（Phase 3b–3f，全 5 View）

- **ContentView**：工具列/設定所有 icon 按鈕、Picker、Stepper、Slider、Toggle 補 identifier/label/value；連線·MCP 狀態燈 combine + 文字替代；`.font(size:8)`→`.caption2`。
- **BotStatusView**：運行燈、ActionBadge（可用/不可用）、DoraIndicators（中文牌名）、ScoreLabel（「我」）。
- **RecommendationView**：機率條分級文字、牌名、最佳標記、RecommendationRow combine + identifier。
- **LogPanel**：Picker/toggle/清除/搜尋補 id+label、LogEntryRow combine。
- **WebViewController**：Majsoul WebGL canvas `.accessibilityElement(children:.ignore)` + label「雀魂遊戲畫面」+ id `majsoul-webview`（VoiceOver 不卡、測試可斷言）。
- 共用 helper：`MahjongTile.accessibleName`（復用既有 `displayName`，中文牌名 + 紅寶牌前綴）。
- `Color+Extension.swift` 已用語意色，保留為範式。

---

## 7. 待你本人執行（handoff）

1. **撤銷 GitHub PAT**（`ghp_…`，MortalSwift）— git 端已 scrub，token 本身仍需你在 GitHub 撤銷。
2. **真人對局驗證（Phase 4b，帳號風險，只能你做）** — 觀察：
   - 自動打牌不黏著（#4）、不重複/遲發（#7）、打對牌（#1/#16）
   - 連續兩局 / 斷線重連不污染狀態（#2/#5/#6/#9/#18）
   - 三麻：is3P 是否正確帶到 UI/自風（#3；推薦品質仍受四麻模型限制）
   - `/bot/status` 不再回報過時推薦（#15）
3. **#20 chi consumed** — 抓真實 `ActionChiPengGang` payload 驗證 froms/consumed 補正。
4. **三麻推論** — 需 MortalSwift 提供三麻模型 + sanma 建構參數才能真正支援（#3）。
5. **commit** — 依 CLAUDE.md，commit 前用 AskUserQuestion 確認 why；本輪所有變動仍在工作區未 commit。
6. （可選）清理殘留：`WebViewModel.swift` header 2 行 AutoPlayService 註解、`GameStateManager` 未用的 Combine import、AutoPlayController 既有無關死碼。

## 8. 備份位置（本 session scratchpad）

- `project.pbxproj.bak`、`Naki.xcscheme.bak`（3a 前狀態，若需回退測試 target）。

---

## 9. Unity 遷移發現（2026-07）

**日期**: 2026-07-31
**性質**: 外部環境變動（非本專案 code 造成），由 runtime 實測發現
**紀律**: 本節只記錄事實與影響範圍。**本輪（文件更新）只改 `.md`，未動任何 `.swift` / `.js`。**

> ⚠️ **並行變更提醒**：撰寫本節期間（22:25–22:31）工作區同時有**他處的 code 變更**進入，
> 包括新檔 `command/Services/Bridge/LiqiEncoder.swift`（Swift 端 Liqi envelope 編碼器）
> 與 `naki-websocket.js` / `naki-game-api.js` / `naki-autoplay.js` / `naki-coordinator.js` 的修改。
> **那些不是本輪文件作業的產物**。下方 9.2 的「失效」判定依 2026-07-31 22:2x 讀到的 code 為準，
> 若並行工作已修好某些路徑，以實際 code 為準。

### 9.1 事實（全部 = 已驗證，runtime 實測）

1. **雀魂客戶端已從 Laya 換成 Unity WebGL**，版本 `chs_t-WebGL-release-4.0.45(45)`
   （`loader.js` / `framework.js.gz`）。
2. 全域只剩 `createUnityInstance`、`unityFramework`、`getUnityElements`、`onUnityReady`；
   DOM 為 `<div id="unity-container">` + `<canvas id="unity-canvas" width=2560 height=1440>`。
3. **已確認不存在**：`window.Laya`、`window.GameMgr`、`window.uiscript`、
   `window.view.DesktopMgr`、`window.cfg`、`window.app.NetAgent`。
4. **Liqi wire protocol 完全沒變**：
   - Envelope = `[type:1][msgId:2 LE][protobuf{ field1=method 字串, field2=payload }]`，
     type 1=NOTIFY / 2=REQUEST / 3=RESPONSE。
   - 實測 REQUEST (34B)：
     `028d000a132e6c712e526f7574652e686561727462656174120808001000180b200f`
     → REQUEST, msgId=141, method=`.lq.Route.heartbeat`, payload=`08 00 10 00 18 0b 20 0f`
   - 實測 RESPONSE (7B)：`038d000a001200` → RESPONSE, msgId=141
   - **method 明文、request 無 XOR**；XOR 僅用於 NOTIFY 的 `ActionPrototype.data`。
5. **自組 Liqi 請求送出可行（已驗證）**：自組同構封包（msgId=60000）送出，
   伺服器正確回應 msgId=60000。
6. WebSocket 訊息橋接仍正常（2 條 live `wss://route-N.maj-soul.com/gateway`）；
   Swift `LiqiParser` 解碼仍正常。
7. 送出通道：`window.__nakiWebSocket.getMajsoulConnections()` 回傳含原始 `ws` 物件，
   可直接 `.send()`。

### 9.2 影響範圍

| Naki 元件 | 影響 |
|-----------|------|
| `naki-websocket.js`（攔截 + `getMajsoulConnections`） | ✅ 無影響 |
| `LiqiParser` / `MajsoulBridge` / `MJAIEventStream` | ✅ 無影響（協議沒變） |
| `NativeBotController` + MortalSwift 推論 | ✅ 無影響（吃 MJAI 事件） |
| `naki-game-api.js`（`DesktopMgr` 讀手牌/dora/oplist） | ❌ 全失效 |
| `naki-autoplay.js`（找牌、模擬點擊） | ❌ 全失效 |
| `naki-coordinator.js` 的 `state` / `action` / `auto` / `lobby` / `visual` | ❌ 全失效 |
| `naki-coordinator.js` 的 `network`（`getConnections` / `forceReconnect`） | ✅ 無影響 |
| `naki-core.js` 的 `__nakiAntiIdle`（`clientHeatBeat`） | ❌ 失效 |
| `WebViewModel.executeAutoPlayActionWithRetry`（讀 `oplist`、tile-index 映射） | ❌ 失效 |
| Debug Server `/game/*`、`/ui/names` 與對應 MCP 工具 | ❌ 失效（底層走上述 JS） |
| Debug Server `/js`、`/logs`、`/bot/*` | ✅ 大致可用 |

> 連帶影響：AUDIT §5 的 #1/#16（打牌/越界）與 #7（去抖）等修正，其**驗收對象**
> （Laya 打牌路徑）已消失，第 7 節 handoff 的「真人對局驗證」清單需依新架構重寫。
> #20（`parseChiPengGang` consumed）仍待真實封包驗證，**不受遷移影響**（協議層）。

### 9.3 尚未驗證（不得當事實引用）

- 各遊戲動作（`inputOperation` 等）的 **payload schema 未實測**。
- 大廳（`createRoom` / `matchGame` / `fetchAccountInfo` 等）的 **payload schema 未實測**；
  連完整 Liqi 方法名前綴（`.lq.Lobby.` / `.lq.FastTest.`）都只是舊 Laya 時代的線索。
- Unity 內部（wasm 佈局、`unityFramework` 可呼叫面）**完全未探測**。
- Naki 自行補送 `.lq.Route.heartbeat` 防閒置是否可行 / 是否會被風控注意 → 未驗證。
- 自送的請求會被 Naki 自己的 `ws.send` wrapper 收到（讀 `naki-websocket.js` 推導），
  對 Swift 端解析的實際影響**未實測**。

### 9.4 本輪文件變更（只動 `.md`）

| 檔案 | 動作 |
|------|------|
| `docs/majsoul-unity-protocol.md` | **新建** — Unity 時代唯一有效參考 |
| `docs/majsoul-webui-objects-reference.md` | 作廢改寫（59KB → 精簡；刪 Laya 食譜、留協議線索） |
| `docs/majsoul-webui-api-architecture.md` | 作廢改寫（38KB → 精簡；同上） |
| `docs/majsoul-minigame-snowball-reference.md` | 加作廢橫幅 + 移除已失效的本地設定修改段 |
| `CLAUDE.md` | 架構段加 Unity 事實表、Liqi envelope 速查；`cfg` 段標作廢；文件索引更新 |
| `AUDIT.md` | 本節 |
| `docs/README.md`、`docs/architecture-deep-dive.md`、`docs/debug-api-help-endpoint.md` | 加失效指標／替換失效範例，避免索引誤導 |

> 被刪掉的 Laya 原文可由 git history 取回：
> `git show 1201c74 -- docs/majsoul-webui-objects-reference.md`、
> `git show 49487a1 -- docs/majsoul-webui-api-architecture.md`。

> 另：`docs/majsoul-unity-protocol.md` 已補記並行開發中的
> `window.__nakiWebSocket.sendRaw(base64)` + `LiqiEncoder.swift` 通道（**讀 code 得知，未 runtime 驗證**）。

### 9.5 建議的下一步（待你決定，本輪未做）

1. 抓一局完整 WebSocket frame log（方向 / type / msgId / method），拆 `inputOperation` payload。
2. 先用高位 msgId 重放**無害查詢類**請求確認送出路徑，再碰動作類。
3. 依實測結果重寫 `naki-game-api.js` / `naki-autoplay.js` 的替代方案（protobuf 版），
   或改為 Swift 端直接組包後交由 JS 送出。
4. 決定 `naki-coordinator.js` 失效方法的處置：移除 vs. 保留但明確回報 unsupported。

---

## 10. Unity 遷移第二輪：決策、取捨與教訓（2026-07-31 後半）

> §9 記的是「發現了什麼事實」。本節記的是**為什麼這樣做**與**踩到什麼坑**。

### 10.1 執行路線：自組 Liqi 請求送出（用戶拍板）

三個選項與取捨：

| 方案 | 為什麼не選 / 選 |
|------|------|
| 只做推薦、不自動執行 | 風險最低、工作量最小，但放棄自動打牌 |
| **自組 Liqi 請求送出**（採用） | 功能最全；Unity 下唯一可靠的執行面 |
| canvas 合成滑鼠事件 | **否決**：Unity 不對 JS 暴露任何 per-tile 幾何，座標只能推算，隨畫面解析度/版面漂移，維護成本極高 |

**代價（用戶知情後接受）**：不經 UI 直接送請求，與人手操作的行為特徵差異較大。
**明確界線**：只實作動作傳送本身，不實作任何以隱藏工具存在為目的的功能
（同 CLAUDE.md 的 Never 條款）。

### 10.2 編碼器放 Swift，JS 當笨管子

**為什麼**：decoder（`LiqiParser`）本來就在 Swift、遊戲狀態與牌面映射也在 Swift。
若編碼放 JS，等於把協定知識切成兩半、兩邊各自漂移（這正是 §4 typed/dict 雙實作的老毛病）。
JS 只保留 `sendRaw(base64)` 一個函數 → 脆弱面最小，且 Swift 端可用 XCTest 做**位元組級對拍**。

### 10.3 用 liqi.json 取代「等用戶打牌抓封包」（關鍵轉折）

原本卡在「payload schema 只能靠真實對局抓封包」→ 需要用戶登入並操作。
**改為直接從遊戲自己的 CDN 取官方協定定義**：

```
/1/version.json → 0.11.252.w
/1/resversion0.11.252.w.json → res/proto/liqi.json 的 prefix
/1/v0.11.243.w/res/proto/liqi.json  （286KB，已存 docs/protocol/liqi.json）
```

得到 **1061 個 message、Lobby 419 + FastTest 17 + Route 3 個 method** 的完整定義。

**為什麼比抓封包好**：抓封包只能得到「用戶剛好操作到的那幾個」，且需要對方配合；
協定定義是**完整且權威**的，零依賴。這條路徑應作為往後查任何欄位的**唯一事實來源**，
不要憑記憶、不要從舊 Laya 文件推測。

順帶交叉驗證通過：`Route.heartbeat{delay,no_operation_counter,platform,network_quality}`
與實測封包 `08 00 10 00 18 0b 20 0f` 完全吻合。

### 10.4 根因：`start_game` 缺 `names` → Bot 永遠待機

MortalSwift `StartGameEvent.names: [String]` 是**非 optional**，decode 走
`try container.decode([String].self, forKey: .names)`。
而 `MajsoulBridge` 發的 start_game 只有 `{type, id, is3P}` → 每局 `bot.react` 拋
`keyNotFound("names")` → Mortal 對局初始化失敗 → 手牌恆 0、推薦恆空。

**這是「bot 一直待機」的根因，且真實對局同樣會壞**，與 Unity 遷移無關（是既有 bug）。
修法：從 authGame 回應的 players 取暱稱，取不到補佔位名（Mortal 不用 names 做推論，
只要求欄位存在）。**已改 `MajsoulBridge.swift`，build 過，行為未驗證。**

### 10.5 兩個會靜默咬人的工程陷阱

1. **pbxproj membershipExceptions 白名單**：`command/` 雖是 synchronized folder，
   但 target 實際靠 `PBXFileSystemSynchronizedBuildFileExceptionSet.membershipExceptions`
   決定收哪些檔。**新增 .swift 檔沒登記 → app 編得過但該檔根本沒編進去**，
   直到別處引用才報 "cannot find X in scope"。必須同時加進
   Naki / Naki-M / Naki-MUITests 三份清單。
2. **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`**：未標註的 class 會得到 isolated deinit，
   在同步 XCTest 中釋放會讓 host app abort（`swift_task_deinitOnExecutorImpl` → malloc abort）。
   純資料/工具類要標 `nonisolated`。

### 10.6 流程教訓（用戶當場指正，必須記住）

1. **核心壞著就別先補工具**。本輪在 Bot 完全出不了推薦的情況下去重寫 47 個 MCP 工具，
   用戶連問兩次才停。正確順序：先讓主功能可跑，再談周邊。
2. **不要反覆重建/重啟用戶已登入的 App**。每次 rebuild→relaunch 都會殺掉登入 session，
   然後又回頭問用戶「你登入了嗎」。要嘛一次把 build 弄對後就不再動它，
   要嘛用不需登入的路徑驗證。
3. **能自己解就別要求協助**。本輪一度連續要求用戶：登入、跑友人房流程、授權螢幕錄製。
   後來證明三件都不必要——協定定義可自取（10.3）、Bot 可用**合成封包本地注入**驅動
   （`window.__nakiSendToSwift('websocket_message', {data, direction})` →
   LiqiParser → Bridge → MJAI → Bot，實測可建立 Bot）。
4. **「已驗證」只能指 runtime 事實**。本輪大量「已驗證」其實只是編譯/單元測試通過。
   編譯綠對「送出去伺服器接不接受」「Bot 會不會出推薦」沒有證據力。

### 10.7 本節結束時的未解狀態（誠實記錄）

- `names` 修正**未驗證**行為
- ④ MCP 工具重寫**被中斷在半途**（DebugServer 已被改動），工作區是否仍 build 綠**未確認**
- ②③ 的動作/大廳 protobuf 路徑**從未經真實對局驗證**；只有 heartbeat 實測過伺服器會接受
- 操作 type 數值、ron 走哪個 method、立直宣言牌選法、`GameDetailRule` 伺服器實際接受欄位 → 全未驗
- `NakiUITests` 跑不起來（Early unexpected exit）；NakiTests 62 個正常

---

## 11. Unity 遷移第三輪：送出面攔截失效（2026-07-31 深夜）

### 11.1 已驗證（runtime 事實）

1. **工作區 build 綠**：`build-for-testing` 與 `build` 皆 `SUCCEEDED`（§10.7 的「DebugServer 改到一半」疑慮解除）。
2. **§10.4 的 `names` 修正有效**：以合成 Liqi 封包走完
   `authGame(req+resp) → ActionNewRound → ActionDealTile`，log 出現
   `Bot 創建成功: playerId=0` → `start_kyoku` → `tsumo` →
   `bot.react returned: {"pai":"1p","type":"dahai"}`，`/bot/status` 回傳 14 條推薦。
   **`keyNotFound("names")` 不再發生**，Bot 能出推薦。
3. **真正讓 Bot 在真實對局待機的根因（本輪新發現，非 §10.4）**：
   `naki-websocket.js` 的 `handleMessage` 只判 `ArrayBuffer` / `Blob` / `string`，
   而 **Unity WebGL 送出的是 `Uint8Array`**（探針實測 `ctor="Uint8Array", isAB=false, len=34`）
   → **所有送出封包被靜默丟棄**（全 log `[WS] →` 幀數 = **0**）。

   連鎖後果（皆有 log 佐證）：
   - `LiqiParser.pendingRequests` 從不登記 REQUEST 的 msgId
   - → 每筆 RESPONSE 都命中 `no pending request for msgId=NN` 而被丟棄
   - → **`.lq.FastTest.authGame` 的 RESPONSE 收不到 → 不發 `start_game` → Bot 永不建立**
   - → 登入 RESPONSE 同樣被丟 → `accountId` 恆為 `0`（log: `重置 (accountId 已保留: 0)`）

   實測佐證（16:11:50 那局真實對局）：只有 `ActionMJStart` / `ActionNewRound` 進來，
   **沒有任何 authGame、沒有 `start_game`、沒有 Bot**，`seat` 用的是殘留值。

4. **修正後送出面恢復（runtime 驗證）**：熱修補後 log 出現
   `[WS] → 34 bytes` + `Sent request: .lq.Route.heartbeat`
   + `parseResponse msgId=187, pending=[187]` → **REQUEST/RESPONSE 配對成功**。

5. **`GameStateManager.reset()` 全專案從未被呼叫**（`rg` 確認）。
   `deleteNativeBot()` 只清 `WebViewModel` 自己的欄位，但 `/bot/status` 與 SwiftUI 面板
   讀的是 `gameStateManager` → **對局結束後畫面永遠停在上一局的手牌與推薦**。

### 11.2 本輪變更

| 檔案 | 變更 |
|------|------|
| `command/Resources/JavaScript/naki-websocket.js` | `handleMessage` 增加 `ArrayBuffer.isView(data)` 分支（TypedArray / DataView），修 Unity 送出面 |
| `command/ViewModels/WebViewModel.swift` | `deleteNativeBot()` 補呼叫 `gameStateManager.reset()` |
| 執行中的 App（未重建） | 以 `/js` 熱修補送出攔截：既有 2 條連線 + constructor 級包裝（新連線亦涵蓋）。**重啟即失效，正式修正靠上面的原始碼。** |

### 11.3 流程教訓（本輪自身踩到）

**用合成封包驗證會污染 bridge 真實狀態。** 本輪注入的假 authGame 讓
`seat=0` / `hasReceivedAuthGame=true` 殘留，之後用戶開真實對局時牌型顯示錯誤
（用戶當場回報「牌型都是錯誤、寶牌是四萬」）。
合成注入前應先確認用戶不在對局中，注入後應主動送 `end_game` 並告知狀態已被改動。

### 11.4 自動打牌三個致命 bug（同輪稍後，全部 runtime 實證）

送出面修好後才暴露出來的三層問題，**都不是 Unity 遷移造成的，是既有的錯誤實作**：

1. **`sendRaw` 送錯連線**（最致命）
   雀魂同時開 `wss://…/gateway`（大廳）與 `wss://…/game-gateway`（對局）兩種連線，
   `sendRaw` 卻寫死 `conns[0]`。對局方法送到大廳時伺服器回：
   ```
   error code 6, "method not found"   ← 實測 payload: 08 06 28 01 32 10 "method not found"
   ```
   → **所有打牌都靜默失敗**。修法：從 envelope 取明文方法名，
   `.lq.FastTest.*` 走 game-gateway，其餘走大廳。
   修正後實測 `detail: socket=9 bytes=40, serverAccepted: true`，牌真的打出去。

2. **`LiqiParser` 的 operation 欄位編號全錯**
   對照 `docs/protocol/liqi.json`（§10.3 訂為唯一事實來源）逐一核對：

   | Action | operation 正確編號 | 舊碼誤標 | 連帶錯誤 |
   |--------|------------------|---------|---------|
   | ActionDealTile | 4 | 11 | field 4 被當成 tile；doras 6→8、zhenting 7 錯位 |
   | ActionDiscardTile | 4 | 11 | is_wliqi 誤標 7（實為 9） |
   | ActionNewRound | 7 | — | field 7 被當 liqibang（實為 8）→ **kyotaku 是垃圾值** |
   | ActionChiPengGang | 6 | 5 | 5 其實是 liqi |
   | ActionAnGangAddGang | 4 | 5 | — |
   | ActionBaBei | 4 | 缺 | — |

   → `LiqiOperationStore` 永遠是空的 → 自動打牌無法判斷「是否輪到自己」。
   修正後實測：`oplist 更新: ActionDiscardTile seat=0 types=[2] tile=3p seq=12`（type 2 = 碰）。

3. **`operation_list` 是 repeated 卻被當單一 block**
   `OptionalOperationList.operation_list` 在 wire 上是多個 field 2 block，
   舊碼每遇到一個就覆寫 `result["operationList"]`，還把單筆 OptionalOperation
   再拆一層當清單解 → 即使欄位編號對了也解不出可用操作。
   已改為逐筆累積 + 新增 `parseOptionalOperation`，並刪掉錯誤的 `parseOperationList`。

**連鎖症狀解釋**：因為 (2)(3) 讓 oplist 恆空，`executeAutoPlayActionWithRetry` 的
discard 分支走「無 oplist，直接送出」硬送（有時撞對回合、有時沒有），
而吃碰槓／pass 分支則卡在 50 次重試後放棄 → **每次副露機會都會讓對局停住**
（實測 16:46:58–16:49:14 卡了 2 分鐘，手動送 pass 才恢復）。

### 11.5 Unity 渲染層可控面（推翻先前「做不到」的判定）

先前 §11 與 `majsoul-unity-protocol.md` 都判定「單張牌染色做不到」，
理由是 `SendMessage` 只有 `GameLoader.OnLuaGC`、Emscripten 匯出無 Il2Cpp 符號。
**那個判定不完整**——漏掉了渲染層。實測（全部 runtime）：

| 事實 | 數值 |
|------|------|
| 一幀 draw call 數 | ~533 |
| shader program / texture | 13 / 31 |
| 麻將牌繪製 | `drawElements(count=606)`，每幀約 98 次，**每張牌一次獨立呼叫** |
| 牌的 uniform | `hlslcc_mtx4x4unity_ObjectToWorld`（位置）、`_Tint`、`_ColorLight`、`_ColorUnlight` |
| `_Tint` 實測值 | 全部 `[1,1,1,1]` — 遊戲沒有使用，可安全覆寫 |
| UI（按鈕）繪製 | `count` 為 quad 倍數（6/12/18/24…） |
| UI 的 uniform | `hlslcc_mtx4x4unity_ObjectToWorld`、`glstate_matrix_projection`、**`_Color`** |

結論：**牌與按鈕的位置和顏色，遊戲每幀都主動交給我們**。
不需要掃描像素、不需要推算螢幕座標、不需要疊畫覆蓋層。

### 11.6 流程教訓（用戶當場指正，第二次）

§10.6 已記過「能自己解就別要求協助」，本輪犯的是同型的另一版：
**能查到現成資料就別自己算**。

本輪為了做手牌高亮，依序走了：截圖 → 掃描像素找牌的亮區段 → 自建座標校準 →
自己畫覆蓋色塊。用戶連續質疑「為什麼都要自己找自己算 / 明明應該會有很詳細的座標資料 /
他要顯示牌就一定會有位置阿」，才轉去攔 WebGL draw call，
**一次就拿到遊戲自己算好的世界座標矩陣與染色參數**。

同一個模式在本輪出現三次：
1. §10.3 用 `liqi.json` 取代抓封包（正確做法，上一輪已學到）
2. §11.4 的欄位編號 bug——舊碼憑 Laya 時代猜測，對照 `liqi.json` 才發現全錯
3. 本節——憑像素自建座標，實際上 uniform 裡就有

**判準**：動手算之前先問「這個資料，產生它的那一方有沒有留下來？」
遊戲要畫出牌，就一定持有牌的位置；要送出請求，就一定有協定定義。
自算出來的東西沒有權威性，且會隨版面/版本漂移。

### 11.7 新增工具

`room_quick_test`（`RoomTools.swift`）：createRoom → addRoomRobot 補滿 → startRoom
一次跑完並逐步回報，用於快速驗證自動打牌。
回應帶 `reconnect_hint`——**協定層建的房，Unity 客戶端 UI 不知情，開局後不會自動進去**，
必須再觸發一次 `forceReconnect()`，客戶端才會以斷線重連路徑進入該局（實測有效）。

### 11.8 驗證狀態（2026-07-31 16:50 重啟後）

**已驗證（runtime，真實對局）**：
- 送出攔截原生生效（無熱修補）：`[WS] → 34 bytes` + `Sent request: …`
- 重啟後**登入與對局皆保留**（localStorage token → 自動 `oauth2Login` → 重連進 game-gateway）
- 打牌全鏈路：`inputOperation` → 伺服器接受 → `dahai actor=0` 確認（多次）
- pass（取消副露）：`payloadHex=1801` → `serverAccepted: true` → 對局恢復流動
- oplist 解析：`types=[2]` 碰機會被正確辨識
- 友人房協定路徑：createRoom / addRoomRobot ×3 / startRoom 全部 serverAccepted

**自動打牌全循環已驗證（16:52–16:53 連續觀測）**：
- oplist 依動作類型正確更新：`types=[1]`（自摸後可打牌）、`types=[3]`（吃）、
  `types=[1,7]`（打牌＋立直）、`types=[2]`（碰）
- 兩種送出通道都由自動打牌自主送出，無人工介入：
  - `inputOperation`（打牌，如 `payload=08011a02366d` → 6m）
  - `inputChiPengGang`（副露決策，`payload=1801` → cancel_operation 取消）
- **對局自主推進：東1 → 東4 → 南1**（半莊戰打完一整個東場）
- 統計：自動送出 **26 筆，失敗 0 筆**（無 `method not found` / `send_failed` / `no_game_gateway`）

**仍未驗證**：
- 立直宣言（oplist 出現過 type 7，但該局未實際立直）、和了（ron/tsumo）送出
- 吃／碰**接受**（本次觀測 Mortal 都判斷「過」，只驗到 cancel 路徑）
- `GameMode.mode` 數值語意、`ai_level` 有效範圍

