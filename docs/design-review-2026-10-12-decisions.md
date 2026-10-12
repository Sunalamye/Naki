# Naki 設計審查裁決（2026-10-12）

- 裁決基準（四份審查報告）：HEAD `813aa88`（main）；各 WP 的 diff 基準見 §12，工作樹只有未追蹤的 `build-ios-dev/`（`git status --short`）。
- 輸入：`.swfd/logs/design-review/{arch,bot,bridge,ui}.md` 第二版（檔案時間 16:50:21／16:46:51／16:37:47／16:42:41）。四份都是靜態審查，沒有 runtime 驗證。
- 裁決方法：每個「必須改」「建議改」項目都親自打開程式碼核對（清單見第 10 節）。核對不成立的寫在第 8 節。
- 既有決策出處：`note/dev-notes/2026-08-02-swiftui-target-pattern.md:24-26`（Bridge／Bot 維持 service 形態、Action 是無狀態接縫、`@Entry` 預設值只給 Preview）。2026-08-05 的 422 事故出處：mempal wing `naki`，`docs/cloud-inference-decisions.md` D16 段落，與 `MajsoulBridge.swift:94-103` 的註解一致。
- 用詞：「做」＝本輪排入工作包；「延後」＝成立但本輪不排，列出重啟條件；「不做」＝不成立或成本大於效益；「需用戶裁決」只用於不可逆、改對外 MCP 工具清單、改協定語意、兩個既有決策衝突。其餘一律「裁決員代決」。

## 1. 總結

這輪審查的核心問題只有一個：**全域單例與測試路徑脫鉤**。`LiqiOperationStore.shared` 只注入到引擎鏈，bridge／bot／replay 直讀單例（arch S12），結果三麻 replay 讀到 live 牌局（arch M1）；bridge 測試走的是正式路徑跑不到的 authGame REQUEST 分支（bridge M1），27 條測試驗的接線在 app 裡不存在。其餘發現是這個問題的衍生物（靜默丟棄、假訊號、死碼、文件漂移）。

整體方向：不引入框架、不改既有決策，沿用專案已有的「建構子參數預設 `.shared`」寫法把注入縫補齊，讓測試走正式路徑；行為改動一律先補 log 與 fault 收集證據，再決定。三個會改對外語意的項目交給用戶。

工作包共 13 個（WP0–WP12），WP0 是 spike。順序：WP0 → WP1 與 WP2 可平行 → WP3 → WP4 → WP5 → WP6 → WP7a → WP7b → WP7c → WP8 → WP9 與 WP10 可平行 → WP11 → WP12（文件，最後）。延後項目另列，不排進本輪。

## 2. 需用戶裁決

### U1 移除過時的 `matchGame` 鏈（arch v1 S10、bridge 無、bot 無）
- 問題：`lobby_start_match`／`lobby_cancel_match`／`lobby_match_modes` 三個 MCP 工具與 `StartMatchAction`、`CancelMatchAction`、`ObservedMatchModes` 仍在 `tools/list` 裡；工具描述自己寫「已過時，match_mode 1／2／3 一律回 error 1306」（`LobbyTools.swift:97-101`）。
- 選項：A 直接移除整條鏈（改變對外工具清單，4–5 檔）；B 保留，只在描述加「驗證用」（現狀已是如此）。
- 建議：A。工具保留的唯一理由是「驗證舊路徑是否復活」，而 `lobby_start_unified_match` 已是現行入口。移除前用 MCP 呼叫一次 `lobby_start_match`（測試帳號、大廳狀態）確認仍回 1306，當作最後證據。
- 不選建議的後果：`tools/list` 持續列出已知必失敗的工具；arch S6 的「4 個匹配 Action」清理只能做一半。

### U2 「proto3 缺席視為 0」是否套到 seat／type（bridge M3 步驟 2）
- 問題：`MajsoulBridge` 對 `chang`／`ju` 已採「缺席＝0」（`:608-610`），對 action 的 `seat` 與 `ChiPengGang.type` 缺席則丟棄事件且不記 fault（`:177-179`、`:794-798`、`:922-926`）。schema 裡這些欄位都是 singular `uint32`。
- 選項：A 本輪只做「丟棄點記 degraded fault」（WP5，不改事件輸出）；B 同時改成缺席視為 0，在 `LiqiParser` 統一補，並手工組「欄位省略」fixture。
- 建議：A。沒有任何 live 證據顯示官方伺服器會省略 seat=0（bridge 報告自己標未驗證）；B 會改變事件語意，若判斷錯，座位 0 的玩家會被記到錯誤座位且畫面看不出來。先用 A 的 fault 計數收集一局以上的證據再決定。
- 不選建議的後果：若伺服器或代理真的省略 seat=0，自家座位 0 時自動打牌整局不動；但 A 的 fault 會讓這件事在 `/status` 看得到。

### U3 全新安裝的預設模式是 `.auto`（bot §1、arch 範圍外觀察）
- 問題：`AutoPlayModeStore.defaultMode = .auto`（`AutoPlayMode.swift:150`），沒有存檔的裝置第一局就會自動送出動作。
- 選項：A 改為 `.recommend`，已有存檔的使用者不受影響；B 維持 `.auto`。
- 建議：A。CLAUDE.md 的邊界是「自動模式會在使用者自己的測試帳號送出遊戲動作」，預設就送出與「送 Liqi request 前先確認」的精神相反。1 檔 1 行，`AutoPlayModeStoreTests` 有 `defaultMode` 斷言要跟著改。
- 不選建議的後果：新安裝者在未閱讀任何說明前就會以自動模式打牌。

### U4 插件授權與送出總開關可被 page world 改寫（bridge D10）
- 問題：`window.__nakiPluginGrants`、`window.__nakiPluginsMayModifyOutbound` 是可寫全域變數，`window.__nakiPlugins.setGrant` 是公開函數（`naki-plugins.js:33-39`、`:270-274`、`:475-480`）。註解與 `docs/plugin-api-v1.md` 宣稱「插件自稱什麼一律不算數」，實際不成立。
- 選項：A 本輪只改文件與註解為「授權防誤用、不防惡意插件」（WP12）；B 鎖住這兩個全域變數並讓 `setGrant` 要求 Swift 產生的 nonce（改插件 API 契約，2 檔）。
- 嚴重度（裁決員評估）：中。插件要先被使用者匯入並啟用才會注入，所以這不是遠端攻擊面；但一旦啟用，插件可以在使用者沒開 L3 總開關的情況下改寫送出的 ActionPrototype，而文件與 `naki-plugins.js:33` 註解都宣稱做不到。只裝自己寫的插件時風險低；若會安裝第三方插件，應選 B。
- 建議：A。插件是使用者自己安裝的，信任邊界本來就包含插件（bridge 報告第 5 節也這樣判）；B 會改 `apiVersion: 1` 的契約，需要確認現有插件是否呼叫 `setGrant`。
- 不選建議的後果：文件繼續宣稱一個不存在的保證。

## 3. 判定總表

欄位：來源:編號 / 判定 / 嚴重度（審查員給的） / 併入 WP / 一句理由。「延後」項目的重啟條件寫在第 6 節或 WP 清單末的延後表。

### 3.1 arch.md（第二版）

| 來源 | 判定 | 嚴重度 | WP | 理由 |
|---|---|---|---|---|
| arch:M1 三麻 replay 讀 live oplist | 做 | 必須 | WP2 | 已核對 `ReplayTools.swift:152-156`、`NativeBotController.swift:62-64`、`AkagiSanmaBot.swift:48-51`；錄影無 oplist，replay 輸出必須標示授權不可用 |
| arch:M2 降級提示被覆蓋 | 做 | 必須 | WP3 | `NakiRuntime.swift:283-291` 同步兩次寫 `statusMessage`，成立 |
| arch:S1 `isReady` 恆 true | 做（刪除） | 建議 | WP7c | `WebSessionBackends.swift:40`、`:219` 都是 `{ true }`；刪除假訊號不改行為 |
| arch:S2 fail-open 預設值 | 做（只刪寬鬆方向） | 建議 | WP7c | 三處正式呼叫端都有明傳；刪預設值只影響測試檔；`Context.mode`／`isReady` 預設不動（`isReady` 隨 S1 刪） |
| arch:S3 手動路徑手抄閘門 | 做 | 建議 | WP7c | 與 bot R14 同一處；收成 `AutoPlayGate` 的靜態判斷式，不併進 `evaluate` 流程，保留 `:107-108` 的理由 |
| arch:S4 隔離標註兩套 | 做 | 建議 | WP6 | 10 條 Swift 6 錯誤級警告已在 `test-813aa88.log` 核對；LogManager 的 `DispatchQueue.main.async` 不動 |
| arch:S5 MCP 四層轉發、31 處轉型 | 做步驟 1；步驤 2 不做 | 建議 | WP7b | `grep -c` 31 處、27 處同一 else，成立；刪單一實作的協定沒有必要，代決不做 |
| arch:S6 4 個匹配 Action | 延後 | 建議 | — | 等 U1；U1 選 A 後只剩 unified 一對，再決定是否收斂 |
| arch:S7 動作→request 兩份 | 做 | 建議 | WP7c | 與 bot R15 同；`GameTools.swift:54`、`:126-127` 與 executor `:125-138` 已核對 |
| arch:S8 牌碼表 7 處、chi 變體字串 | 做 | 建議 | WP11 | 不改行為；`Recommendation` 已有 `kanKind` 先例 |
| arch:S9 Service 反向建 Action | 做 | 建議 | WP7a | `WebSessionBackends.swift:80-82` 成立；依 2026-08-02 決策方向應修 |
| arch:S10 字典管線與 `last*` 旁路 | 延後 | 建議 | — | 與 bridge D1／D2 同；跨 3–4 檔結構改動，等 WP5 的 fault 先收集到哪些丟棄點真的會發生 |
| arch:S11 同一狀態兩種形狀 | 延後 | 建議 | — | `BotStatus.canX` 是 `/bot/status` 的對外欄位名，重整要保證 JSON 形狀不變；本輪不做 |
| arch:S12 `LiqiOperationStore.shared` 只注入一半 | 做 | 建議 | WP0、WP2 | 26 處引用已統計；`MajsoulBridge.init(faultState: = .shared)` 是現成寫法 |
| arch:S13 多餘 actor hop | 部分做 | 建議 | WP6 | `LiqiParser` 三處與 `MCPHandler` 兩處改直接呼叫；連線事件進 `SerialEventIntake` 延後（見 bridge S5）；`LogManager` hop 不動 |
| arch:S14 Legacy `bot_trigger` 假成功 | 做 | 建議 | WP3 | `TriggerAutoPlayAction.unavailable` 是空閉包（`NakiActions.swift:426-431`），工具回 `queued: true`（`BotTools.swift:71-76`）成立；改在 `BotTriggerTool` 查 `supportsAutoPlay`，不改 Action 簽章 |
| arch:S15 死碼 | 做（兩項除外） | 建議 | WP7a、WP7b | `lastResult` 與 `markCurrentHandled()` 有測試呼叫端，不刪（見第 8 節）；`verificationScale` 是測試縫，不刪 |
| arch:S16 同形重複 | 部分做 | 建議 | WP7a、WP7b | 局間確認歸零只收成 `resetConfirm()`，enum 改寫延後（bot R13）；「過」重試設定兩份延後；`NakiActions` init 移 extension 需 build 驗證 |
| arch:S17 命名 | 部分做 | 建議 | WP7c | `isFullAuto` → `sendsActions` 做（5 檔機械改名）；`Timing`、getter、檔名不動 |
| arch:S18 目錄名與 Views 繞過 environment | 部分做 | 建議 | WP8 | `fetchAny` Action 做；`ViewModels/` 改名延後；Services 讀 `SettingsStore` 常數不動；`createUserScript` 副作用交 WP8 設計判斷 |
| arch:S19 文件漂移 | 做 | 建議 | WP12 | 併入第 7 節總表 |
| arch:S20 12 處 `print` | 做 | 建議 | WP1 | `grep -c` 12 處成立；重連先後證據要靠它 |
| arch:S21 兩套 fire-and-forget 錯誤策略 | 做 | 建議 | WP7a | `NakiRuntime.swift:430`、`:464` 的 `try?` 改走 `WebSession` 帶 log 的入口；`reactionFailed` 刪 |
| arch:K1–K8 | 不做 | 可不動 | — | 同意審查員理由 |

### 3.2 bridge.md（第二版）

| 來源 | 判定 | 嚴重度 | WP | 理由 |
|---|---|---|---|---|
| bridge:M1 authGame REQUEST 分支正式路徑跑不到 | 做 | 必須 | WP0 | 已核對 `WebSocketInterceptor.swift:527-533` 只呼叫 `parseRaw`，`parseRaw` 不進 `convertToMJAI`；測試 helper `LiqiParserFailureTests.swift:113-118` 走 `parse`；27 處呼叫。刪整個 request 分支，不接回送出面；「ReqAuthGame 當第二 accountId 來源」代決不做（理由見 WP0） |
| bridge:M2 配不到 request 只 trace | 做（log 升級＋degraded fault，不加 blocking） | 必須 | WP1 | `LiqiParser.swift:251-255`、`liqiLog` 預設 `.trace`（`LogManager.swift:420`）成立；degraded 不觸發橫幅（`LiqiParseFault.swift:159` 只看 blocking），所以不會吵 |
| bridge:M3 丟棄點不記 fault | 做步驟 1 | 必須 | WP5 | 四個丟棄點已核對；步驟 2 見 U2 |
| bridge:M4 reset 延後到 Task | 做 | 必須 | WP5 | `NakiWebCoordinator.swift:93-101` 成立；把 `websocketHandler.reset()` 提到 Task 外是純提前，不改其他順序；配合 WP1 的 M2 log 做 runtime 對照 |
| bridge:D1 字典中間表示 | 延後 | 建議 | — | 同 arch S10 |
| bridge:D2 `last*` 旁路 | 延後 | 建議 | — | 同上；M2 的「配不到 request」先以 log／fault 命名，不改簽章 |
| bridge:D3 -1 哨兵值 | 延後 | 建議 | — | `LiqiOperationSnapshot.seat` 改 optional 會動 resolver 的理由碼，等 D1 一起 |
| bridge:D4 死碼 | 做 | 建議 | WP5、WP7a | `setAccountId` 零呼叫端、`currentMsgId` 只寫、parser 只產生 `accountId` 已核對；`syncing` 保留到 echo 決定（見 S2 回音項）；`zhenting` 等未消費欄位不刪 |
| bridge:D5 `parseChiPengGang` 125 行 | 延後 | 建議 | — | `?? tile` 改成丟棄會改事件輸出；重啟條件：先寫三種 froms 情境的鎖定測試 |
| bridge:D6 命名 | 部分做 | 建議 | WP5 | `WebSocketInterceptor` 改 `enum` 做；`parseRaw` 改名為送出面語意做（測試 12 處跟改）；`reset` 不改名，註解已夠 |
| bridge:D7 隔離慣例統一 | 延後 | 建議 | — | 需要 build 實驗（拿掉 `nonisolated final class` 看是否編得過）；與 arch K2／K3 同根因，另開實驗 |
| bridge:D8 JS API 名稱散落 | 做 | 建議 | WP10 | `?.` 讓改名靜默 no-op；契約測試照 `BridgeMessageContractTests` 形式 |
| bridge:D9 JS 三份 envelope 解析、60000 號段 | 做 | 建議 | WP10 | `naki-websocket.js:400`、`naki-plugins.js:377` 已核對；Swift 端 2026-09-30 已改登記制，JS 落後 |
| bridge:D10 grants 可寫 | 需用戶裁決 | 建議 | U4 | 改插件 API 契約 |
| bridge:S1 msgId 跨 socket 共用一張表 | 延後 | 建議 | — | 先在 WP1 把 `socketId` 寫進 wsLog；重啟條件：live 看到同 msgId 跨 socket |
| bridge:S2 可注入性不一致 | 做 | 建議 | WP0 | 同 arch S12 |
| bridge:S2 重放會灌回音 | 延後 | 建議 | — | WP1 加「syncing 期間記到回音」log；有證據再決定是接 `syncing` 還是刪 |
| bridge:S3 契約只鎖 type 與 socketId | 做 | 建議 | WP5 | 缺欄位走既有 `warnMalformed`；`type: "text"` 不再試 base64 |
| bridge:S4 所有 frame 都能送訊息 | 延後 | 建議 | — | 重啟條件：第 6 節第 8 項的 iframe probe 結果 |
| bridge:S5 重連兩條路動 bot | 延後 | 建議 | — | 等 WP1 的 `bridgeLog` 拿到先後證據 |
| bridge:S6 protobuf 截斷只 trace | 延後 | 低 | — | 要改 `parseProtobufBlocks` 回傳值，等 D1 |
| bridge:S6 doras 寫法 4 次 | 做 | 低 | WP5 | 同檔收斂，不改輸出 |
| bridge:S6 Blob 亂序 | 延後 | 低 | — | 第 6 節第 9 項先量 |
| bridge:S6 WebPage 無 WebContent 終止處理 | 延後 | 低 | — | 第 6 節第 10 項先驗 |
| bridge:S6 文件漂移 | 做 | 低 | WP12 | 併入第 7 節 |
| bridge:第 5 節可不動 | 不做 | — | — | 同意 |

### 3.3 bot.md（第二版，16:46:51）

| 來源 | 判定 | 嚴重度 | WP | 理由 |
|---|---|---|---|---|
| bot:R1 test host 起完整 runtime | 做（server＋engine）；首次載頁延後 | 建議（條件升級） | WP3 | `NakiRuntime.init` 無條件 `startDebugServer()` 已核對；載頁是否發生見第 6 節第 3 項，確認後再擴 |
| bot:R2 吃對照失敗送 index 0 | 做（只收緊） | 建議（條件升級）→ 裁決員視為正確性缺陷 | WP7c | 已核對 `AutoPlayActionExecutor.swift:106-107` 與 `chiCombinationIndex`（`LiqiOperationStore.swift:200-222`）、既有測試只有單組（`AutoPlayActionExecutorTests.swift:155-174`）。改法只往保守方向：combination 恰好一組才退回 0，多組且對照失敗回 nil 不送、保留 oplist；`chi_` 前綴解析失敗補 log。這只減少送出、不新增送出，屬裁決員代決；WP 執行前由主線依 CLAUDE.md 向用戶報備一句 |
| bot:R3 三麻 replay 讀 live 單例 | 做 | 建議 | WP2 | 同 arch M1 |
| bot:R4 本地與雲端錯誤語意不一致 | 部分做 | 建議 | WP4 | 世代不符不 rethrow 做；nil 分支清推薦延後（改顯示行為，無 live 證據） |
| bot:R5 取消被記成雲端故障 | 做 | 建議 | WP4 | `CloudBot.swift:220-226` 成立；catch 先看 `Task.isCancelled` |
| bot:R6 雲端顯示只在決策點更新 | 延後 | 建議 | — | 顯示落後，不送資料；第 6 節第 16 項先驗 |
| bot:R7 重連重建兩次 bot | 延後；先改 log | 建議 | WP1 | 同 bridge S5 |
| bot:R8 Debug server 端點與重啟 | 部分做 | 建議 | WP3、WP7b | `startDebugServer` guard 改看 `store.isDebugServerRunning` 做；`getLogs`／`clearLogs`、`dropFirst()` 死碼刪；`/bot/chi`、`/bot/pon` 讀 body 不做（新增能力，MCP 已有） |
| bot:R9 `AutoRematchEngine.cancel` 承諾不符 | 做註解；重載時 cancel 延後 | 建議 | WP12 | 行為改動要先確認 |
| bot:R10 三麻授權來源與雲端不同 | 延後；先加 log | 建議 | WP1 | 在 `AkagiSanmaBot.react` 記 `pending.sequence != 事件 seq` 的次數 |
| bot:R11 三麻推論在 MainActor | 延後 | 建議 | — | 第 6 節第 4 項先量 |
| bot:R12 決策來源字串 | 做（常數） | 建議 | WP7c | `"local"` 7 處、`"cloud:"` 1 處已核對；只收常數，不換型別 |
| bot:R13 局間確認四變數 | 延後；本輪只收 `resetConfirm()` | 建議 | WP7b | enum 改寫碰 watchdog，等 `AutoConfirmEngineTests` 鎖住後另開 |
| bot:R14 stale 判斷兩份 | 做 | 建議 | WP7c | 同 arch S3；engine 內兩份收成一個判斷式，不併進 gate |
| bot:R15 動作→request 兩份 | 做 | 建議 | WP7c | 同 arch S7 |
| bot:R16 chi 變體字串 | 做 | 建議 | WP11 | 同 arch S8；連帶消除 R2 的前綴解析失敗 |
| bot:R17 `NativeBotController` API 表面 | 做（以編譯器為準） | 建議 | WP7b | `react(events:)` 批次版、`jikaze`、`reactionFailed` 零外部引用已核對；`bakaze`／`doraIndicators` 的外部命中是 `GameState` 的同名成員，刪 controller 版前要 build 確認 |
| bot:R18 `RetryPolicy` optional 繞隔離 | 做 | 建議 | WP6 | 隨 arch S4 一起標 `nonisolated` |
| bot:R19 `LiqiToolSendOutcome` 三 optional | 延後；`eventLog` 副作用併 arch S21 | 建議 | WP7a | 型別改寫成本大於效益 |
| bot:R20 `isFullAuto` 命名 | 做 | 建議 | WP7c | 改名 `sendsActions` |
| bot:R21 `MahjongBot.reset()` 無呼叫者 | 做註解 | 建議 | WP12 | 同意只改註解 |
| bot:R22 `MCPToolRegistry` fork | 不做 | 建議 | — | 上游化在 repo 外；fork 註解已說明；下轉型由 arch S5 的 `naki()` 處理 |
| bot:R23 隔離、await、命名空間 | 做 | 建議 | WP6 | 多餘 `await` 實際 grep 為 9 處（審查員寫 11）；命名空間 enum 統一 |
| bot:§1 預設模式 `.auto` | 需用戶裁決 | — | U3 | 行為語意 |
| bot:§3 註解漂移 | 做 | — | WP12 | 併入第 7 節 |
| bot:§4 `NakiActions` 檔頭缺兩種形狀的規則 | 做 | 低 | WP7a | 只補檔頭說明；`.unavailable`／`.noop` 兩種名字在 `noop` 刪除後自然收斂 |
| bot:§5 time-bank 扣時 | 延後 | 已知 | — | 單獨成 WP，不在本輪；最小改點 `AutoPlayEngine.swift:546` 傳剩餘時限 |
| bot:§6 可不動 | 不做 | — | — | 同意 |
| bot:§7 測試缺口 | 做 | — | WP4、WP7c | 世代守衛、取消、R4 → WP4；多組吃、九種九牌經 executor → WP7c；同類多組槓 index 維持已知未實作 |

### 3.4 ui.md（第二版）

| 來源 | 判定 | 嚴重度 | WP | 理由 |
|---|---|---|---|---|
| ui:C1 iOS 缺 `PageLoadFailureBanner` | 做 | 必須 | WP3 | `ContentView.swift:455-467` 四個 inset、macOS `:275-282` 五個，成立 |
| ui:C2 隱藏名稱 Swift 鏈死碼 | 做（刪） | 必須 | WP7a | `settings.hidePlayerNames` 無讀取端；JS API 保留 |
| ui:C3 `SettingsStore` 兩條註解相反 | 做 | 必須 | WP12 | `:179`、`:485-486` 成立 |
| ui:S1 View 直讀單例、`fetchAny` | 做 | 建議 | WP8 | 違反既有決策；Opus 判斷 Preview 預設值該指向單例還是新實例 |
| ui:S2 `SettingsStore` 綁死 `.standard` | 做 | 建議 | WP9 | 33 處 `UserDefaults.standard`；測試改寫真實設定是實害 |
| ui:S3 降級提示被覆蓋 | 做 | 建議 | WP3 | 同 arch M2 |
| ui:S4 三麻可用兩份定義 | 延後 | 建議 | — | 第 6 節第 7 項先驗；`|| cloudConfig.isActive` 死碼留給 WP8 順手刪 |
| ui:S5 插件設定不受觀察 | 延後 | 建議 | — | 第 6 節第 5 項先驗 |
| ui:S6 `pinMajsoulServer` 走 `@AppStorage` | 延後 | 建議 | — | 第 6 節第 6 項先驗；審查員自己標推測 |
| ui:S7 遷移呼叫三次 | 做 | 建議 | WP7a | `load()` 本身會遷移（`AutoPlayMode.swift:173-174`）；`@AppStorage` 讀模式 key 的讀者已不存在 |
| ui:S8 `NakiActions` 無人用的成員、`noop` | 做 | 建議 | WP7a | 11 個 `noop` 零引用；5 個成員只有測試用 |
| ui:S9 manifest 驗證兩份 | 做 | 建議 | WP9 | `PluginRegistry.swift:213-222` 與 `PluginImportSource.swift:244-262` 四條規則與字串重複，成立 |
| ui:S10 寫設定兩種慣例 | 部分做 | 建議 | WP7a、WP8 | `ChooseServerAction` 無效分支刪（WP7a）；`MajsoulConnectionSettingsBox.apply` 字典移進 Action（WP8） |
| ui:S11 View 內重複與雙寫 | 做 | 建議 | WP8 | `actionName` 兩處、更新橫幅雙寫、`GamePanel` 多餘 Binding 都已核對 |
| ui:S12 `operationalSettings` 200 行、縮排錯位 | 做 | 建議 | WP8 | 同檔內拆成每個 GroupBox 一個 private 屬性，符合該檔既有寫法 |
| ui:S13 命名 | 部分做 | 建議 | WP7b、WP12 | `TileImage` 兩個 Set 合併；`GameStore` 檔頭改寫；`ViewModels/` 改名延後；`NakiWebViewHost.swift` 改檔名不做（app target 檔名進 pbxproj membership exception） |
| ui:S14 `nonisolated` 風格、`UIState` 缺 deinit | 做 | 建議 | WP3、WP6 | `UIState` 補 `nonisolated deinit` 一行（WP3）；enum 風格統一（WP6） |
| ui:S15 `NakiEnvironment` 預設參數 | 做 | 建議 | WP7a | 唯一呼叫端已全傳 |
| ui:四 範本測試 | 做 | — | WP7a | `Naki-MTests`、`Naki-MUITests` 是 `PBXFileSystemSynchronizedRootGroup`，刪檔不動 pbxproj |
| ui:四 `hasFault` 環境單測、C1 斷言 | 做 | — | WP8、WP3 | 隨對應修正補 |
| ui:五 文件漂移 | 做 | — | WP12 | 併入第 7 節 |
| ui:三 可不動 | 不做 | — | — | 同意 |

## 4. 工作包

共用規則：
- 每個 WP 一個 worktree，worktree 放在 `~/` 底下的非 symlink 路徑，不得放 `/tmp`（三條架構 lint 測試會假紅，見 auto-memory `naki-tmp-worktree-test-pitfall`）。同時編譯的 worktree 上限 2。
- 既有驗證指令（照 `CLAUDE.md` 原文）：
  - build：`xcodebuild build -project Naki.xcodeproj -scheme Naki`
  - test：`xcodebuild test -project Naki.xcodeproj -scheme Naki -only-testing:NakiTests`
  - replay：`scripts/replay-check.sh --baseline docs/replay-baseline.txt`（需要執行中的 Naki 與含 `games/` 的 session；baseline 檔存在，`--session` 用法見腳本檔頭）
  - JS：`node scripts/keepalive-regression.cjs`；`node scripts/plugin-regression.cjs <path-to-naki-plugins>`（插件 repo 路徑未在本 repo 找到，需主線確認）
  - 變異測試：`scripts/mutate.py --diff base..head [--files …] [--tests …]`（用法見檔頭）
  - iOS 實機 build（照 `.swfd/logs/merge-main/iphone-build.log:2` 原文）：`xcodebuild build -project Naki.xcodeproj -scheme Naki-M -configuration Debug -destination id=<device> -allowProvisioningUpdates -derivedDataPath build-ios-dev`
  - Release build：`CLAUDE.md` 只寫「`xcodebuild -configuration Release` 會失敗」，完整指令未找到，需主線確認；建議形式 `xcodebuild build -project Naki.xcodeproj -scheme Naki -configuration Release`。
- 基線：`test-813aa88.log` 顯示 NakiTests `Executed 890 tests, with 0 failures`；`command/` 52 條不重複警告，其中 10 條 Swift 6 錯誤級。每個需編譯的 WP 完成後測試數不得減少（刪除測試的 WP 要寫明刪了幾條），警告數不得增加。
- 每個 WP 依專案 CLAUDE.md 維護一份 `<wp>-implementation-notes.md`，偏離計畫寫在「Deviations」。
- 「可略過清理與強化」三條件：改動 ≤5 檔、無新增邏輯分支、機械式。

### WP0（spike）Bridge 測試走正式路徑＋`MajsoulBridge` oplist 注入
- 目標：驗證兩個架構假設——(a) 「建構子參數預設 `.shared`」的注入縫可以在正式路徑零改動下讓測試隔離；(b) 測試改走正式路徑（`parseRaw` 餵 REQUEST、登入回應餵 accountId）後，哪些測試是靠死碼過的。
- 範圍（可改）：`command/Services/Bridge/MajsoulBridge.swift`、`NakiTests/LiqiParserFailureTests.swift`。
- 不得碰：`WebSocketInterceptor.swift`、`NakiRuntime.swift`、`LiqiParser.swift`、任何 JS。
- 內容：
  1. `MajsoulBridge.init(faultState: LiqiParseFaultState = .shared, operations: LiqiOperationStore = .shared)`，6 處 `LiqiOperationStore.shared` 改成 `operations`。
  2. 刪除 `convertToMJAI` 裡 `.lq.FastTest.authGame && request` 整個分支（`:286-301`）。它在正式路徑永不執行；接回送出面會重演 2026-08-05 的 seat 歸零事故。「從 ReqAuthGame 取 accountId 當第二來源」代決不做：正式路徑從未有過這條，登入回應缺 accountId 時 authGame 回應會記 blocking fault（`:353-363`），使用者看得到；加第二權威違反 D16 的單一來源取捨。
  3. 測試 helper `authenticate` 改成：`parseRaw(登入 REQUEST)` → `parse(登入 RESPONSE，field 2 = accountId)` → `parseRaw(authGame REQUEST)` → `parse(authGame RESPONSE)`。登入 fixture 依 `LiqiParser.parseLoginResponse`（`:1109-1135`，field 2 直接 account_id）組 bytes。
  4. 測試裡 3 處 `LiqiOperationStore.shared` 改用注入的 store 實例。
  5. 因此失敗的測試，修法只能是「改 fixture 走正式路徑」或「每個情境新建 bridge」，不得把任何狀態重置加回正式碼。
- 依賴：無。
- 路由：Opus 5.5 medium（判斷哪些失敗是真問題）。
- 略過清理三條件：不符合（新 fixture 是新邏輯）。
- 驗證閘：`xcodebuild test -project Naki.xcodeproj -scheme Naki -only-testing:NakiTests/LiqiParserFailureTests`，再跑完整 `-only-testing:NakiTests`；`grep -n "LiqiOperationStore.shared" command/Services/Bridge/MajsoulBridge.swift` 必須為 0；`grep -c "parse(authGameRequest" NakiTests/LiqiParserFailureTests.swift` 必須為 0；`git diff --stat` 只有兩檔。要補的測試：`testLoginResponseProvidesAccountIdOnProductionPath`（登入回應→authGame 回應→`start_game` 帶正確 seat）。
- 風險與回退：若 ≥10 條測試失敗且原因是「同一個 bridge 跨兩局重用」，表示 request 分支曾替測試做換局重置，這是測試設計問題，仍不接回；回退為 `git revert` 單一 commit。
- 資源：需編譯，1 個 worktree。

### WP1 診斷補強（不改行為）
- 目標：為延後項目收集 runtime 證據。
- 範圍：`command/Services/Bridge/MJAIEventStream.swift`、`NakiWebCoordinator.swift`、`LiqiParser.swift`、`WebSocketInterceptor.swift`、`MajsoulBridge.swift`、`command/Services/Bot/AkagiSanmaBot.swift`。
- 不得碰：任何會改變事件輸出或送出行為的程式碼；`LiqiParseFaultState` 的 blocking 路徑。
- 內容：
  1. 12 處 `print` 改 `bridgeLog`／`mjaiLog`（arch S20、bot R7）。
  2. `LiqiParser.parseResponse` 配不到 request：改 `.info` 級 log，同一條連線只報首次與累計次數；另記一筆 degraded fault（site `LiqiParser.unmatchedResponse`）；不得記 blocking（bridge M2）。
  3. `handleWebSocketMessage` 的 `wsLog` 加上 `socketId`（bridge S1 的證據）。
  4. `MajsoulBridge` 在 `syncing == true` 期間記到回音時寫一行 `bridgeLog`（bridge S2 回音項）。
  5. `AkagiSanmaBot.react` 在 `snapshot()?.sequence` 與事件 `MJAIEventKey.oplistSequence` 不一致時寫一行 `botLog`（bot R10）。
- 依賴：WP0（同時改 `MajsoulBridge.swift`，順序避免衝突）。可與 WP2 平行。
- 路由：Sonnet 5.5 medium。
- 略過清理三條件：不符合（6 檔）。
- 驗證閘：build＋`-only-testing:NakiTests`；`grep -rn "^\s*print(" command/Services/Bridge/MJAIEventStream.swift command/Services/Bridge/NakiWebCoordinator.swift` 必須為 0。要補的測試：`LiqiParserFailureTests.testUnmatchedResponseRecordsDegradedFaultNotBlocking`。
- 風險與回退：log 量增加；回退 revert。
- 資源：需編譯。

### WP2 `NativeBotController`／`ReplayTools` oplist 注入
- 目標：三麻 replay 與 live 隔離（arch M1、bot R3、arch S12 的 controller 部分）。
- 範圍：`command/Services/Bot/NativeBotController.swift`、`command/Services/MCP/Tools/ReplayTools.swift`、`NakiTests/NativeBotControllerTests.swift`、`NakiTests/ReplayFingerprintTests.swift`。
- 不得碰：`BotTools.swift`、`GameTools.swift`、`WebSession.swift`、`NakiMCPDependencies.swift` 的 `.shared` 讀取（它們是 live 查詢，留著正確）。
- 內容：`NativeBotController.init(operations: LiqiOperationStore = .shared)`，5 處 `.shared` 改 `operations`，`makeSanmaLocal` 的 snapshot 閉包讀注入的 store；`ReplayTools.run` 傳 `LiqiOperationStore()`；replay 回傳在 `is3P` 時加 `"sanmaAuthorization": "unavailable_no_oplist_in_recording"`；`NativeBotControllerTests` 3 處 `.shared.reset()`／`.record` 改用注入實例。
- 依賴：WP0 確認注入模式。可與 WP1 平行。
- 路由：Sonnet 5.5 medium。
- 略過清理三條件：不符合（新增回傳欄位是新分支）。
- 驗證閘：build＋`-only-testing:NakiTests`；`grep -n "LiqiOperationStore.shared" command/Services/Bot/NativeBotController.swift` 為 0。要補的測試：`ReplayFingerprintTests.testSanmaReplayDoesNotReadSharedOperationStore`（先在 `.shared` 放一筆授權 pon 的 pending，replay 三麻錄影，斷言輸出不含 pon 且帶 `sanmaAuthorization` 欄位）。三麻錄影來源：`.swfd/logs/s3-live-5/20261009-164439.mjai.jsonl`（第 6 節第 13 項）。
- 風險與回退：四麻 replay 指紋不得改變，用 `scripts/replay-check.sh --baseline docs/replay-baseline.txt` 驗（需執行中的 Naki）；回退 revert。
- 資源：需編譯。

### WP3 Runtime／UI 小修
- 目標：五個一行級正確性修正。
- 範圍：`command/App/NakiRuntime.swift`、`command/Services/MCP/Tools/BotTools.swift`、`command/Views/ContentView.swift`、`command/ViewModels/UIState.swift`、`Naki-MUITests/DecisionHUDTouchTests.swift`。
- 內容：
  1. `setAutoPlayMode` 的第二次 `statusMessage` 寫入移到沒有降級的分支（arch M2／ui S3）。
  2. `BotTriggerTool.execute` 在 `settings.supportsAutoPlay == false` 時回 `["success": false, "error": "legacy_path_action_send_disabled", "queued": false]`（arch S14）；不改 `TriggerAutoPlayAction`。
  3. `startDebugServer` 的 guard 改看 `store.isDebugServerRunning`，失敗後 `debugServer = nil`（bot R8）。
  4. `NakiRuntime.init` 在 `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil` 時略過 `startAutoPlayEngine()` 與 `startDebugServer()`（bot R1）。首次載頁略過等第 6 節第 3 項確認後再加。
  5. iOS 版面補 `.safeAreaInset(edge: .top) { PageLoadFailureBanner() }`（ui C1）；`DecisionHUDTouchTests` 加 `page-load-failure-banner` identifier 可出現的斷言（若 UI 測試環境不可控，記在 Deviations）。
  6. `UIState` 補 `nonisolated deinit {}`（ui S14）。
- 依賴：無。可與 WP4 平行。
- 路由：Sonnet 5.5 medium。
- 略過清理三條件：不符合（第 2、4 項是新分支）。
- 驗證閘：build＋`-only-testing:NakiTests`；`NakiEnvironmentTests` 必須仍全綠（它斷言預設環境不起 server）；iOS 用 `Naki-M` scheme build 一次。要補的測試：`BotToolsTests.testBotTriggerReportsLegacyShortCode`（以 `supportsAutoPlay = false` 的 `SettingsStore` 建 context）。
- 風險與回退：第 4 項若有測試依賴 test host 自起的 server，會在這裡暴露；審查員已 grep 無此依賴。回退 revert。
- 資源：需編譯（macOS＋iOS）。

### WP4 Bot 錯誤語意
- 目標：取消不算故障；舊世代錯誤不寫新局。
- 範圔：`command/Services/Bot/CloudBot.swift`、`command/Services/Bot/NativeBotController.swift`、`NakiTests/CloudBotTests.swift`、`NakiTests/NativeBotControllerTests.swift`。
- 內容：`CloudBot.cloudOverride` 的 catch 先判 `Task.isCancelled`，取消直接回 nil、不碰 `breaker`（bot R5）；`NativeBotController.react` 的 catch 在 `gen != generation` 時回 nil 不 rethrow（bot R4 的一半）。
- 依賴：WP2（同檔）。
- 路由：Sonnet 5.5 medium。
- 略過清理三條件：不符合（新分支）。
- 驗證閘：build＋`-only-testing:NakiTests`。要補的測試：`CloudBotTests.testCancelledReactDoesNotTripBreaker`；`NativeBotControllerTests.testStaleGenerationResultIsDiscarded`（補 bot §7 列的世代守衛缺口）；`testStaleGenerationErrorIsNotRethrown`。
- 風險與回退：revert。
- 資源：需編譯。

### WP5 Bridge 強化
- 目標：丟棄點可見、契約鎖欄名、reset 時序、bridge 死碼。
- 範圍：`command/Services/Bridge/MajsoulBridge.swift`、`LiqiParser.swift`、`WebSocketInterceptor.swift`、`NakiWebCoordinator.swift`、`command/Services/Web/WebSession.swift`（僅 `WebSocketInterceptor` 改 enum 連帶）、`NakiTests/LiqiParserFailureTests.swift`、`NakiTests/BridgeMessageContractTests.swift`。
- 不得碰：事件輸出的欄位與值；`reset()` 保留 seat／is3P 的規則；任何 JS。
- 內容：
  1. bridge M3 步驟 1：`actorSeat` 缺 seat、`parseDiscardTile` 缺 tile 或牌碼轉不出、`parseChiPengGang` 缺 seat／type 或 opType 越界、`parseAnGangAddGang` 缺 tiles／type、`parseDealTile` 自家缺牌，各記一筆 degraded fault，同一 site 只報一次（沿用 `reportedUnknownActions` 的去重）。
  2. bridge S3：`handleWebSocketMessage` 缺 `direction`／`data` 走 `warnMalformed`；`type == "text"` 不試 base64；`BridgeMessageContractTests` 比對每個 type 的欄名；修正該測試訊息「Swift 端只讀這個欄位」。
  3. bridge M4：`websocketHandler.reset()` 移到 `onWebSocketStatusChanged` 的 Task 之外同步執行（只提前，其餘留在 Task）。
  4. bridge D6：`class WebSocketInterceptor` → `enum`；`parseRaw` 改名為表達送出面登記的名稱（例如 `observeOutgoing`），呼叫端與測試跟改。
  5. bridge D4／arch S16：刪 `currentMsgId`、`setAccountId`、登入回應的 `account_id` 兩個死 fallback、DealTile 只寫 log 的迴圈、`MajsoulBridge.swift:453-459` 只寫 log 的分支；`fullReset()` 先呼叫 `reset()` 再清額外欄位；doras 累加 4 處收成一個 helper。`tiles as? String` 分支刪前先讀 `LiqiParser` 的 ChiPengGang 解析確認只產生陣列（`LiqiParser.swift:745` 的字串版屬 AnGangAddGang）。`syncing` 保留，等 WP1 的回音 log。
- 依賴：WP0、WP1。
- 路由：Opus 5.5 medium（bridge 是 422 事故區）。
- 略過清理三條件：不符合。
- 驗證閘：build＋`-only-testing:NakiTests`；`scripts/replay-check.sh --baseline docs/replay-baseline.txt`（事件輸出不得改變）。要補的測試：每個丟棄點一條 `test<Site>MissingFieldRecordsDegradedFault`；`BridgeMessageContractTests.testEveryTypeDeclaresFieldsSwiftReads`；`testMissingDirectionGoesThroughWarnMalformed`；`testResetRunsBeforeNextMessage`（用 handler 的 dispatch 連續餵 `websocket_connected` 與一則 REQUEST，斷言 REQUEST 的 msgId 仍在 pending）。
- 風險與回退：M4 是時序改動，runtime 對照見第 6 節第 1 項；任何一步失敗單獨 revert（五項各自 commit）。
- 資源：需編譯。

### WP6 隔離標註與 Swift 6 警告
- 目標：10 條錯誤級警告歸零，統一型別層級 `nonisolated`。
- 範圔：警告清單對應的檔（`AutoPlayMode.swift`、`LogManager.swift`、`MCPProtocolSpec.swift`、`MajsoulRequestBuilder.swift`、`AutoPlayEngine.swift`、`AutoPassDispatcher.swift`、`AutoConfirmDispatcher.swift`、`CloudDecisionMapper.swift`、`MatchModeTable.swift`、`GameHighlightScript.swift`、`DebugServer.swift`、`AutoPlayGate.swift`、`AutoPlayDecisionResolver.swift`、`ActionDelayModel.swift`、`LiqiParser.swift`、`MCPHandler.swift`、MCP Tools 的 9 處多餘 `await`、`UpdateChecker.swift`、`AppVersion.swift`、`L10n.swift`、`CloudKeyStore.swift`）。
- 不得碰：`LogManager.log()`／`clear()` 的 `DispatchQueue.main.async`（arch S13 標為推測，留註解不改）；`NakiActions.swift` 的 `nonisolated(unsafe)`（決策代價，K1）。
- 內容：純值型別、純命名空間 enum 與其巢狀型別改成型別層級 `nonisolated`（arch S4、bot R23、ui S14）；`AutoPassDispatcher.RetryPolicy`／`AutoConfirmDispatcher.RetryPolicy` 標 `nonisolated` 後 `Timing.passPolicy`／`confirmPolicy` 改非 optional（bot R18）；`AutoPlayEngine.swift:313` 預設參數改在 init 本體取 `.shared`；`DebugServer` 的 `NWConnection` 回呼用 `MainActor.assumeIsolated`；`LogManager` 三個 handle 改 `let`；刪 9 處多餘 `await`；`LiqiParser` 三處 `Task { @MainActor }` 與 `MCPHandler` 兩處 `MainActor.run` 改直接呼叫（arch S13、bridge D7 步驟 1）；`AutoPlayDecisionResolver`／`ActionDelayModel` 改 `enum`。
- 依賴：WP5（`LiqiParser` 衝突）。
- 路由：Sonnet 5.5 medium。
- 略過清理三條件：不符合（檔數多）。
- 驗證閘：`xcodebuild build -project Naki.xcodeproj -scheme Naki 2>&1 | grep -c "warning:"` 相對 `test-813aa88.log` 的 52 條下降；`grep -c "Swift 6 language mode"` 為 0；`-only-testing:NakiTests` 全綠；Release build 一次（Preview 的 `#if DEBUG` 陷阱）。不新增測試。
- 風險與回退：`nonisolated(unsafe)` 能否移除未驗證，不在本 WP 嘗試；分批 commit，每批 build。
- 資源：需編譯，Debug 與 Release 各一次。

### WP7a 死碼與重複：App／Actions／Settings
- 範圍：`command/Actions/NakiActions.swift`、`command/App/NakiRuntime.swift`、`command/App/NakiEnvironment.swift`、`command/App/SettingsStore.swift`、`command/Services/Web/WebSession.swift`、`command/Services/Web/WebSessionBackends.swift`、`Naki/App/NakiApp.swift`、`Naki-M/Naki_MApp.swift`、`command/Services/MCP/LiqiToolResult.swift`、`NakiTests/NakiEnvironmentTests.swift`、`NakiTests/AutoPlayModeStoreTests.swift`、`Naki-MTests/Naki_MTests.swift`、`Naki-MUITests/Naki_MUITests.swift`。
- 內容：刪 11 個 `static let noop`；從 `NakiActions` 移除 `executeJavaScript`、`rescanPlugins`、`startFullAutoNow`、`triggerAutoPlay`、`setHidePlayerNames`（型別保留給 `NakiMCPDependencies`），測試改用型別直接建構；刪隱藏名稱 Swift 鏈（`SettingsStore.hidePlayerNames` 與 key、`SetHidePlayerNamesAction`、`WebSession.setHidePlayerNames`、`applyHideNamesIfNeeded`、`hasAppliedHideNames`；JS 的 `__nakiHideNames`、`setNameMask` 必須保留）；刪 `Naki_MApp.init()` 與 `NakiRuntime.swift:72-77` 的遷移呼叫，改 `NakiApp.swift:17-18` 註解與 `AutoPlayModeStoreTests.swift:101` 訊息；`NakiEnvironment.init` 刪兩個預設值、改檔頭「五樣東西」；`ChooseServerAction` 刪無效分支；`WebSessionBackends.forceReconnect` 直接呼叫 `callJavaScript(NakiWebSocketScript.forceReconnect)`，刪 `ExecuteJavaScriptAction.init(backend:)` 與 `ForceReconnectAction.init(javaScript:)`（arch S9）；`NakiRuntime` 的 `accountLevel`／`lobbyProbe` 收成一個 private 方法；`NakiRuntime.swift:430`、`:464` 的 `try?` 改走 `WebSession` 新增的 `fireJavaScript(_:label:)`（失敗一律 `bridgeLog`，arch S21）；`LiqiToolResult.dictionary` 的 `eventLog` 移到呼叫端或改名；`SettingsStore.swift:14-20` 的 doc comment 移到 `:74` 前（ui S9 第一版）；刪兩個範本測試；嘗試把 `NakiActions` 的 `nonisolated init()` 移到 extension 讓編譯器合成 memberwise init（arch S16，build 不過就放棄並記 Deviations）。
- 依賴：WP3（同時改 `NakiRuntime.swift`）。
- 路由：Sonnet 5.5 medium。
- 略過清理三條件：不符合。
- 驗證閘：build（macOS＋iOS，因改 `Naki_MApp.swift`）＋`-only-testing:NakiTests`；`grep -rn "\.noop\b\|hidePlayerNames\|setHidePlayerNames" command Naki Naki-M` 為 0；`grep -rn "__nakiHideNames\|setNameMask" command/Resources/JavaScript` 不得減少。測試數會因刪範本與移除 `setHidePlayerNames` 斷言而減少，寫明數字。
- 風險與回退：revert。
- 資源：需編譯。

### WP7b 死碼與重複：Bot／MCP／Debug
- 範圍：`command/Services/Bot/NativeBotController.swift`、`BundledCoreMLBot.swift`、`CloudBot.swift`、`AutoPlayEngine.swift`、`command/Models/GameModels.swift`、`command/Services/Bridge/GameRecorder.swift`、`command/Services/MCP/Tools/ReplayTools.swift`、`command/Services/MCP/MCPContext.swift`、`command/Services/MCP/MCPToolRegistry.swift`、`command/Services/MCP/Tools/*.swift`（8 檔）、`command/Services/Debug/DebugServer.swift`、`command/Services/LogManager.swift`、`command/Views/TileImage.swift`、對應測試。
- 內容：`extension MCPContext { func naki() throws -> NakiMCPContext }`，31 處 guard 改一行（arch S5 步驟 1）；`MCPToolRegistry` 刪 `registerAll`、`hasToolNamed`、`generateToolsJSON`、`reset()`；`DebugServer` 刪 `getLogs()`／`clearLogs()`、`:316` 的 `dropFirst()`、11 個一行轉發（路由表直接呼叫 `callToolAndRespond`）；`NativeBotController` 刪 `react(events:)` 批次版、`jikaze`、`doraIndicators`、`bakaze` 轉發、6 個 `canX` 轉發（測試改讀 `availableActions`）、`NativeBotError.reactionFailed`，`MARK` 的「Legacy」與檔頭「強類型」字樣改掉，加 `final`（以編譯器為準，編不過的項目保留並記 Deviations）；`BundledCoreMLBot` 刪 `is3P` 參數；`GameModels` 刪 `tileUnicode`、`unicode`、`mjaiToUnicode`（先 build 確認無引用）；`ReplayTools` 改用 `GameRecorder.recordedGames()`；推薦摘要字串收成 `[Recommendation]` extension（3 處）；`BundledCoreMLBot` mask→推薦迴圈收成 private 函式；`AutoPlayEngine` 五處四行歸零收成 `resetConfirm()`；`ISO8601DateFormatter` 與 `"yyyyMMdd-HHmmss"` 改共用 static；`TileImage` 兩個相同 Set 合併。
- 不得碰：`LiqiActionSender.lastResult`、`LiqiOperationStore.markCurrentHandled()`、`ActionDelayModel.verificationScale`（測試在用）；`BotStatus.canX` 欄位（對外 JSON）。
- 依賴：WP4（`NativeBotController`）、WP6（`DebugServer`、`MCPHandler`）。
- 路由：Sonnet 5.5 medium。
- 略過清理三條件：不符合。
- 驗證閘：build＋`-only-testing:NakiTests`；`grep -rc "context as? NakiMCPContext" command/Services/MCP/Tools` 合計 0；MCP `tools/list` 數量不變（`get_status.toolsCount` 現查，或 `MCPProtocolSpecTests`）。
- 風險與回退：revert；分三個 commit（MCP／Debug／Bot）。
- 資源：需編譯。

### WP7c 引擎規則收斂（安全相關）
- 範圍：`command/Services/Bot/AutoPlayEngine.swift`、`AutoPlayGate.swift`、`AutoPlayDecisionResolver.swift`、`AutoPlayActionExecutor.swift`、`AutoPlayMode.swift`、`AutoRematchEngine.swift`、`MahjongBot.swift`、`BundledCoreMLBot.swift`、`CloudBot.swift`、`NativeBotController.swift`、`command/Services/Bridge/LiqiOperationStore.swift`、`command/Services/MCP/Tools/GameTools.swift`、`command/Services/Web/WebSession.swift`、`WebSessionBackends.swift`、對應測試。
- 內容：
  1. 刪 `isReady`（協定成員、`WebSession.isReady`、兩個 Context 欄位、6 個 guard 與 `web_view_not_ready` 理由；arch S1）。
  2. 刪寬鬆方向預設值：gate 與 resolver 的 `isSanma`、gate 的 `recommendationsOplistSequence`、executor 的 `awaitResponseMs`／`echoTimeoutMs`；嚴格方向保留（arch S2）。測試補顯式參數。
  3. stale 與三麻放行收成 `AutoPlayGate` 的兩個靜態判斷式，輪詢與手動兩條路共用；`evaluate` 的 `.forceHora` 流程不動（arch S3、bot R14）。
  4. 決策來源收成常數與建構函式（`"local"`、`"cloud:"` 前綴、`AkagiSanmaBot.source`；bot R12）。
  5. `LiqiOperationSnapshot` 加 `horaRequest`、`passChannel`、`defaultKanType` 三個計算屬性，executor 與 `NakiGameAction.spec` 都改讀（arch S7、bot R15）。
  6. `isFullAuto` 改名 `sendsActions`（9 處引用；arch S17、bot R20）。
  7. 吃對照失敗（bot R2）：`chiCombinationIndex` 回 nil 時，只有 `combination.count == 1` 才退回 0 並保留既有警告；多組回 nil 不送、不 `markHandled`；`chi_` 前綴解析失敗寫一行 log。不改 `chiCombinationIndex` 本身。
- 依賴：WP6（同檔）、WP7b。
- 路由：Opus 5.5 medium（和牌與三麻 fail-closed 區）。
- 略過清理三條件：不符合。
- 驗證閘：build＋`-only-testing:NakiTests`；`scripts/replay-check.sh --baseline docs/replay-baseline.txt`；`scripts/mutate.py --diff <base>..HEAD --files AutoPlayGate.swift AutoPlayEngine.swift --tests AutoPlayEngineTests AutoPlayGateTests`，存活變異為 0 或逐條說明；三組 fixture F（CLAUDE.md「自摸問題」第 1 點）必須仍綠。要補的測試：`AutoPlayActionExecutorTests.testChiWithMultipleCombinationsAndNoMatchDoesNotSend`（兩組 combination、推薦變體對不上，斷言 sender 未被呼叫且 oplist 未消化）、`testRyukyokuGoesThroughExecutor`（九種九牌經 executor 送出，補 bot §7 缺口）；既有單組退回 0 的測試保留。既有 `isReady: false` 的測試會被刪，寫明條數。
- 風險與回退：每項獨立 commit，任何一項 mutation 存活即 revert 該項。第 7 項是自動送出行為的收緊，主線依 CLAUDE.md 在 WP7c 開工前向用戶報備一句。
- 資源：需編譯。

### WP8 View → Environment
- 範圔：`command/App/NakiEnvironment.swift`、`command/Actions/NakiActions.swift`、`command/App/NakiRuntime.swift`、`command/Views/LogPanel.swift`、`StatusBanners.swift`、`PluginsPageView.swift`、`ContentView.swift`、`DecisionSidebar.swift`、`AdvancedSettingsSheet.swift`、`MajsoulConnectionSettingsBox.swift`、`command/Models/GameModels.swift`、`command/Services/Bridge/WebSocketInterceptor.swift`（`createUserScript` 副作用，可選）、`NakiTests/NakiEnvironmentTests.swift`。
- 內容：`FetchPluginImportAction`、`ClearLogsAction`、`DismissUpdateAction(skip:)` 三個 Action（ui S1、S11、arch S18）；`NakiEnvironment` 加 `logManager`、`jsInjection`、`parseFault` 三個 ref，Preview 預設值由 Opus 判斷（`LogManager` 可指向 `.shared`；另兩個建議用新實例以符合「Preview 無副作用」）；`StatusBar.hasFault` 改讀 environment；`Recommendation.actionName` 計算屬性取代 `DecisionSidebar` 兩處；`GamePanel` 刪多餘 `@Binding showLog`；`MajsoulConnectionSettingsBox.apply` 的字典組裝移進 `connectionSettings` Action（ui S10）；`AdvancedSettingsSheet.operationalSettings` 同檔拆成每個 GroupBox 一個 private 屬性並修縮排（ui S12）；`ContentView.swift:129` 刪死碼 `|| naki.settings.cloudConfig.isActive`；`createUserScript` 是否改回傳 outcome 由 Opus 決定。
- 不得碰：`NakiEnvironment` 的 `@Entry` 預設值策略；單例的寫入端。
- 依賴：WP7a。
- 路由：Opus 5.5 medium。
- 略過清理三條件：不符合。
- 驗證閘：build（macOS＋iOS）＋`-only-testing:NakiTests`；`grep -rn "LogManager.shared\|JSInjectionState.shared\|LiqiParseFaultState.shared\|PluginImportSource.fetchAny" command/Views` 為 0。要補的測試：`NakiEnvironmentTests.testHasFaultReadsFourSourcesFromEnvironment`；架構 lint 擴充：`command/Views` 不得出現 `.shared`。
- 風險與回退：Release build 一次（Preview 陷阱）；revert。
- 資源：需編譯。

### WP9 `SettingsStore` defaults 注入＋插件 manifest 驗證收斂
- 範圔：`command/App/SettingsStore.swift`、`NakiTests/NakiViewActionTests.swift`、`NakiTests/AppLanguageTests.swift`、`NakiTests/ToolbarControlsRealTests.swift`、`command/Services/Plugins/PluginRegistry.swift`、`command/Services/Plugins/PluginImportSource.swift`、`NakiTests/PluginRegistryTests.swift`、`NakiTests/PluginImportGapTests.swift`。
- 內容：`SettingsStore.init(defaults: UserDefaults = .standard)`，33 處 `UserDefaults.standard` 改 `defaults`；`nonisolated init()` 保留；三個測試檔改用獨立 suite，刪 setUp／tearDown 的備份還原（ui S2）；`PluginManifest.validate() -> PluginLoadFailure?` 一份，`PluginRegistry.load` 與 `PluginImportSource` 都呼叫（ui S9）。舊 key 不改名。
- 依賴：WP7a（`SettingsStore` 衝突）。可與 WP10 平行。
- 路由：Sonnet 5.5 medium。
- 略過清理三條件：不符合。
- 驗證閘：build＋`-only-testing:NakiTests`；`grep -c "UserDefaults.standard" command/App/SettingsStore.swift` 只剩預設參數那 1 處。要補的測試：`SettingsStoreInjectionTests.testInstanceUsesInjectedSuite`（類別在 `SettingsStoreTests.swift` 內，2026-10-13 更正類別名）；`PluginManifestValidationTests` 四條規則各一。
- 風險與回退：revert。
- 資源：需編譯。

### WP10 JS 契約
- 範圍：`command/Resources/JavaScript/naki-core.js`、`naki-websocket.js`、`naki-plugins.js`、`command/Services/Bridge/NakiWebSocketScript.swift`、`command/Services/Web/WebSession.swift`、`command/Services/Web/GameHighlightScript.swift`、`scripts/plugin-regression.cjs`、新測試檔。
- 內容：Swift 端所有 `window.__naki*` 呼叫字串集中到 `NakiWebSocketScript`（可改名涵蓋整個頁面 API），`GameHighlightScript.make` 維持純函式；新增測試：Swift 字串裡出現的每個 `window.__nakiX.method` 必須在 bundle JS 裡找得到定義（bridge D8）；`sendRaw` 補 `?.`，缺模組回 `{success:false, reason:'no_websocket_module'}`；`naki-core.js` 匯出 `readVarint`／`parseEnvelope`，兩檔改用；`sendRaw` 登記送出過的 msgId（上限 256 的 Set），`attributeSend` 與 `naki-plugins.js` 的 `isNaki` 改查登記表，插件號段 64000–65500 仍由 `naki-plugins.js` 判斷（bridge D9、v1 S2）。
- 不得碰：`parseEnvelopeBody` 必須仍在遊戲解析前同步完成的結構；禁改名單。
- 依賴：WP5。可與 WP9 平行。
- 路由：Opus 5.5 medium（JS 解析在遊戲之前跑，出錯整頁失明）。
- 略過清理三條件：不符合。
- 驗證閘：`node scripts/keepalive-regression.cjs`；`node scripts/plugin-regression.cjs <path-to-naki-plugins>`（路徑需主線確認）；`-only-testing:NakiTests`（含新契約測試與 `BridgeMessageContractTests`）；live 一局（第 6 節第 12 項）。
- 風險與回退：JS 全有或全無注入，壞掉會在 `JSInjectionFailureBanner` 顯示；revert。
- 資源：需編譯＋node。

### WP11 型別收斂：牌碼與 chi 變體
- 範圍：`command/Services/Bridge/LiqiTile.swift`、`LiqiOperationStore.swift`、`command/Services/Bot/AkagiSanmaBot.swift`、`MortalActionMapper.swift`、`ActionDelayModel.swift`、`CloudDecisionMapper.swift`、`AutoPlayActionExecutor.swift`、`command/Models/GameModels.swift`、`command/Services/Web/WebSession.swift`、`command/Views/TileImage.swift`、對應測試。
- 內容：字牌表與數字牌號收進 `LiqiTile`（`honors`、`number(of:)`），6 處改呼叫；`Recommendation` 加 `chiVariant: Int?`，三個產生點填值、三個解析點改讀欄位，`label` 字串保留顯示；chi 的 below／above 分類收成一個 static 函式（arch S8、bot R16）。
- 依賴：WP7c。
- 路由：Sonnet 5.5 medium。
- 略過清理三條件：不符合。
- 驗證閘：build＋`-only-testing:NakiTests`；`scripts/replay-check.sh --baseline docs/replay-baseline.txt`（決策指紋不得變）。要補的測試：`RecommendationTests.testChiVariantFieldMatchesLegacyLabelParsing`。
- 風險與回退：revert。
- 資源：需編譯。

### WP12 文件、註解與對外說明漂移
- 範圍：第 7 節總表列出的所有檔，加 `docs/README.md`、三份 README、`FLOW_COMPARISON.md`。
- 內容：依第 7 節逐條修正；`CLAUDE.md` 的行號改成函式名；測試數改成「2026-10-09 整合閘 890 tests、0 failures（`.swfd/logs/merge-main/test-813aa88.log`）」；`docs/README.md` 補索引與「歷史工作紀錄（非 current truth）」一節，implementation-notes 不搬檔（專案 CLAUDE.md 規定維護位置，搬走會讓後續 WP 寫錯地方）；`FLOW_COMPARISON.md` 檔頭加一行「歷史文件，引用的 `WebViewController.swift` 已不存在」；README 三語補插件（含 L3 風險）與五語選單一段；`docs/plugin-api-v1.md` 補 D10 的「授權防誤用、不防惡意插件」（除非 U4 選 B）；`docs/majsoul-unity-protocol.md:27`、`:331` 改為「三麻 live 已驗（2026-10-09 三局）」，證據見第 6 節第 14 項。
- 依賴：全部 WP 之後（行號與型別名才穩定）。
- 路由：Sonnet 5.5 low。
- 略過清理三條件：符合（純文字，但檔數超過 5，記為「機械式但多檔」）。
- 驗證閘：`xcodebuild build -project Naki.xcodeproj -scheme Naki`（`SystemTools.swift`、`MCPToolRegistry.swift` 等是程式碼字串）；`grep -rn "BotStatusView\|RecommendationView\b\|SanmaUnsupportedNotice\|uiscript\|syncGameHighlight" CLAUDE.md AUDIT.md docs command/Services --include=*.swift --include=*.md` 只剩歷史標記段落；`grep -n "714\|0.5.2\|6223548" CLAUDE.md AUDIT.md docs/README.md docs/architecture-deep-dive.md` 為 0。
- 風險與回退：revert。
- 資源：需一次 build。

### 延後項目（本輪不排，附重啟條件）

| 項目 | 來源 | 重啟條件 |
|---|---|---|
| `ViewModels/` → `Stores/` 改名 | arch S18、ui S13 | 有人要動 pbxproj membership exception 時順手做；需同時改 `GameStoreTests.swift:362`、`:371` 掃描路徑 |
| time-bank 剩餘時限 | bot §5、memory `akagi-sync-baseline` | 單獨 WP：`AutoPlayEngine.swift:546` 傳 `deadline - (now - snapshot.capturedAt)`；live 量一局延遲分佈 |
| 字典管線改 typed、`last*` 旁路、-1 哨兵 | arch S10、bridge D1–D3 | WP5 的 fault 計數跑過 ≥3 局 live 後，依真的發生的丟棄點決定 typed 範圍 |
| `parseChiPengGang` 三段 fallback | bridge D5 | 先寫 froms 正常／缺失／長度不符三條鎖定測試 |
| 隔離慣例統一、NakiTests 隔離設定實驗 | bridge D7、arch K2／K3 | 獨立實驗 worktree：NakiTests target 加 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，看 33 處 `nonisolated deinit` 與 3 個 NSLock 能否移除 |
| msgId 鍵加 socketId | bridge S1 | WP1 的 wsLog 顯示同 msgId 跨 socket |
| frame 過濾 | bridge S4 | 第 6 節第 8 項 probe 顯示遊戲不在 iframe 且頁面有第三方 iframe |
| 連線事件進 `SerialEventIntake` | bridge S5、bot R7、arch S13 | WP1 的 log 顯示 `resyncBot` 與 `start_game` 先後不穩定 |
| 回音 `syncing` 接通或刪除 | bridge S2 | WP1 的 log 顯示 syncing 期間確實記到回音 |
| 局間確認 enum | bot R13、arch S16 | WP7b 的 `resetConfirm()` 之後，`AutoConfirmEngineTests` 鎖住行為再改 |
| 雲端-only nil 分支清推薦 | bot R4 後半 | 三麻雲端-only 退路在 live 出現過期推薦的截圖 |
| `reconcileSession` 移到每事件 | bot R6 | 第 6 節第 16 項證實落後超過一手 |
| `SanmaEngine` 包 actor | bot R11 | 第 6 節第 4 項量到超過一個 frame |
| `LiqiToolSendOutcome` enum | bot R19 | 無；成本大於效益，再審時重看 |
| 三麻授權用事件 seq | bot R10 | WP1 的 log 顯示不一致次數 > 0 |
| `AutoRematchEngine.cancel` 於重載 | bot R9 | 用戶確認重載時要取消續局 |
| `LiqiResponseStore` 注入 | arch S12 | WP0 模式成立後，`AutoPlayActionExecutorTests` 14 處 `.shared.reset()` 改注入 |
| 4 個匹配 Action 收斂 | arch S6 | U1 定案 |
| 插件 grants 鎖定 | bridge D10 | U4 選 B |
| ui S4／S5／S6 | ui | 第 6 節第 5、6、7 項實測結果 |
| test host 略過首次載頁 | bot R1 | 第 6 節第 3 項證實會載頁 |
| `/bot/chi`、`/bot/pon` 讀 body | bot R8 | 無；Debug HTTP 不新增能力 |

## 5. Spike 說明與 codex 審查重點

### 為什麼是 WP0
- 它同時驗兩個假設：注入縫（`operations: = .shared`）與「測試走正式路徑」。`MajsoulBridge` 已有 `faultState` 的同款參數，成功機率高，失敗也只會在測試層暴露。
- 範圍只有 2 檔，正式路徑 diff 可以用一條 grep 驗（`LiqiOperationStore.shared` 在該檔為 0、`NakiRuntime.swift` 零改動）。
- 它是最高風險區（422 事故）裡最低風險的改動：刪的是正式路徑永不執行的分支。
- 結果直接決定 WP2、WP5、延後表的 `LiqiResponseStore` 注入是否照同一模式做。

### codex 唯讀審查重點（WP0 完成後）
1. `git diff 813aa88..HEAD -- command/` 是否只有 `MajsoulBridge.swift`；該檔 diff 是否只有 init 簽章、6 處 `.shared` → `operations`、刪除 request 分支三類。任何其他改動都是越界。
2. 用 `grep -rn "convertToMJAI\|parseRaw\|observeOutgoing" command` 確認送出面仍然不會進 `convertToMJAI`；刪除 request 分支後正式路徑行為零變化的論證是否成立。
3. 登入 fixture 的欄位號是否對 `docs/protocol/liqi.json` 的 `ResLogin`／`ResOauth2Login`（account_id 的 field 2 或 `account.account_id` 的嵌套）；`parseLoginResponse` 兩條路徑是否都有 fixture。
4. 失敗後被修的每條測試：修法是「走正式路徑」還是「放寬斷言」。列出每一條。
5. `reset()` 仍保留 seat／is3P；全檔沒有新增任何把 seat 歸零的路徑（只允許 `fullReset()` 與 authGame RESPONSE）。
6. `LiqiParserFailureTests` 裡是否還有跨兩局重用同一個 bridge 的測試，若有，它現在靠什麼換局。
7. 新的 `operations` 參數是否被 `NakiRuntime` 或任何正式路徑傳入非 `.shared` 的值（必須沒有）。

## 6. runtime 驗證清單

| # | 待驗證點 | 來源 | 最便宜的驗證方式 | 影響的判定 |
|---|---|---|---|---|
| 1 | reset 延後是否真的吞掉第一個 REQUEST | bridge M4、M2 | WP1 合併後 live 做一次強制重連（工具列重連或 MCP force reconnect），`grep "RESPONSE 配不到 request" ~/Library/Logs/Naki/<ts>/all.log`（WP1 新增的 .info 字串；原 trace 行「no pending request」不進 all.log）；WP5 合併後再做一次比對次數 | WP5 第 3 項是否保留 |
| 2 | `resyncBot` 與 authGame `start_game` 先後 | bridge S5、bot R7 | 同一次重連，看 `[協調器] WebSocket 已重連` 與 `start_game` 在 `all.log` 的順序 | 延後表「連線事件進 intake」 |
| 3 | test host 是否載入雀魂頁並登入 | bot R1 | 非 live 時跑一次 `-only-testing:NakiTests`，看最新 `~/Library/Logs/Naki/<ts>/all.log` 有無導覽／載入 majsoul 的行 | WP3 第 4 項是否擴到載頁 |
| 4 | 三麻 `SanmaEngine.decide` 在 main 的耗時 | bot R11 | 三麻友人房一局，`rockettrace` 錄 main thread，或暫時在 `AkagiSanmaBot.react` 前後記時間差（不進 WP） | 延後表「包 actor」 |
| 5 | 停用插件的設定 Toggle 是否重繪 | ui S5 | App 內開插件頁，對未啟用的插件切一次設定 Toggle | 延後表 ui S5 |
| 6 | `pinMajsoulServer` 改讀 settings 會不會閃主版面 | ui S6 | 分別在有 pin／無 pin 下啟動各一次 | 延後表 ui S6 |
| 7 | 四麻 bot 存在時 `coordinator.bot.supports3P` 是否為 false | ui S4 | 四麻局中 `curl http://127.0.0.1:8765/bot/status` 看 identity，再開全自動設定表選三麻 | 延後表 ui S4 |
| 8 | 遊戲是否在 iframe、頁面有無第三方 iframe | bridge S4 | `curl -X POST http://127.0.0.1:8765/js -d 'return JSON.stringify({top: window.top===window, iframes: document.querySelectorAll("iframe").length})'` | 延後表「frame 過濾」 |
| 9 | Blob 路徑是否真的走到 | bridge S6 | `curl -X POST http://127.0.0.1:8765/js -d 'return JSON.stringify(window.__nakiWebSocket.diagnostics())'` 看 Blob 計數 | 延後表 Blob |
| 10 | WebPage 的 WebContent 終止後 `isConnected` 是否卡 true | bridge S6 | Activity Monitor 強制結束 Naki 的 WebContent 行程，`curl /status` | 延後表 WebContent |
| 11 | Legacy path：降級提示、`bot_trigger` 短碼 | arch M2、S14 | iOS 17–25 模擬器跑 `Naki-M`，切 `.auto` 看狀態列，MCP 呼叫 `bot_trigger` 看回傳 | WP3 第 1、2 項的驗收 |
| 12 | 長時間 session 後 `attributeSend` 是否因 60000 號段失效 | bridge D9 | WP10 前後各一局 ≥30 分鐘，`/js` 讀 `__nakiWebSocket.diagnostics()` 的選線依據 | WP10 驗收 |
| 13 | 三麻 replay 輸出帶 `sanmaAuthorization` 欄位 | arch M1 | MCP `replay_game` 餵 `.swfd/logs/s3-live-5/20261009-164439.mjai.jsonl` | WP2 驗收 |
| 14 | 三麻 live 是否已驗（文件矛盾） | ui 漂移 #19 | 已驗：`.swfd/logs/s3-live-{4,5,6}` 的 `live-bot.log`／`all.log` 含 `is3P=true`（本次 grep）；`CLAUDE.md` 這邊正確，`majsoul-unity-protocol.md:27`、`:331` 過期 | WP12 直接修 |
| 15 | NakiTests 隔離設定能否移除 `nonisolated deinit` | arch K2、bridge D7 | 獨立 worktree 改 NakiTests target 設定後 build＋test | 延後表實驗 |
| 16 | 雲端關閉後 `cloudHost` 顯示落後多久 | bot R6 | 局中關雲端，連續 `curl /bot/status` 看 `cloudHost` 何時變 nil | 延後表 R6 |
| 17 | syncing 期間是否記到回音 | bridge S2 | WP1 的 log，重連一次後 grep | 延後表回音 |
| 18 | 三麻授權 seq 不一致次數 | bot R10 | WP1 的 log，三麻一局後 grep | 延後表 R10 |
| 19 | `lobby_start_match` 仍回 1306 | U1 | 測試帳號在大廳，MCP 呼叫一次 | U1 的最後證據 |
| 20 | 吃對照失敗的實際發生率與當時 combination 組數 | bot R2 | 現有 log 已有「無法對照組合」字樣；`grep -c "無法對照組合" ~/Library/Logs/Naki/*/all.log`，再對照同行的 `[...]` 組合清單數組數 | bot R2 是否該升為必須改；WP7c 第 7 項的驗收 |

## 7. 文件漂移總表（WP12）

| # | 文件:行號 | 文件說 | 程式碼是 | 證據 |
|---|---|---|---|---|
| 1 | `CLAUDE.md:110` | 停滯顯示在 `BotStatusView` | `DecisionAlerts`（`DecisionSidebar.swift:648`） | `grep BotStatusView command/Views` 只命中註解 |
| 2 | `CLAUDE.md:170`、`AUDIT.md:61`、`docs/majsoul-unity-protocol.md:193`、`:329` | `.off` 由 `RecommendationView` 讀 | `DecisionSidebar.swift:34` 讀，關閉畫面是 `RecommendationsDisabledView`（`:738`） | 同上 |
| 3 | `CLAUDE.md:170`、`AutoPlayMode.swift:24-26` | `GameHighlightScript.make()` 是顯示面 | 正式路徑只用 `.clear`（`WebSession.swift:336`），`make` 只有測試呼叫 | `grep GameHighlightScript.make( command`＝1（註解） |
| 4 | `CLAUDE.md:163`、`:193` | `AutoPlayEngine.swift:577-582`、`:570` | `:585-597`、`:580` | `sed -n 578,598p` |
| 5 | `CLAUDE.md:202`、`AUDIT.md:25` | NakiTests 714 個 | 890 個，0 failures（2026-10-09） | `test-813aa88.log` 的 `Executed 890 tests` |
| 6 | `CLAUDE.md:220` | 三組無效控制「底層仍依賴 `uiscript`」 | 底層已於 `341f1a6` 刪除 | `git log --oneline -1 341f1a6` |
| 7 | `CLAUDE.md:222-225` | 隱藏名稱是內建兩層功能 | 內建開關於 `c0b7564` 移除，Swift 端不再觸發，JS API 保留供插件 | `WebSession.swift:452-458` |
| 8 | `AUDIT.md:114`、`:126` | `BotStatusView` 的 `SanmaUnsupportedNotice`、六個徽章 | 型別不存在 | grep 0 命中 |
| 9 | `AUDIT.md:22` | `liqi.json` 與 CDN 完全相同（已驗證表） | 2026-10-09 補 `ReqSelfOperation.auto_operation`（field 11）後已不同 | `CLAUDE.md` 「Unity 與 Liqi 必知事實」段 |
| 10 | `AUDIT.md:77`、`:81` | MortalSwift 0.5.2／`6223548`，`[0.5.2,0.6.0)`，`pbxproj:1203` | 0.6.0／`da7238c`，`[0.6.0,0.7.0)`，`pbxproj:1233-1234` | `Package.resolved:18-19` |
| 11 | `AUDIT.md:21`、`:141`、`docs/README.md:32`、`docs/architecture-deep-dive.md:175`、`docs/majsoul-unity-protocol.md:42`、`:306`、`MCPToolRegistry.swift:160` | 42、38 或 40 個工具 | 43 個 `static let name`，43 處 `register(` | `grep -c` 於 `MCPToolRegistry.swift:182-246` 與 `Tools/*.swift` |
| 12 | `docs/README.md:28-32` | MortalSwift 0.5.2；三麻無專用模型；兩個 P0 未收斂；tools 42 | 0.6.0；`AkagiSanmaBot`；`AUDIT.md:32`、`:43` 已收斂；43 | 同上 |
| 13 | `docs/architecture-deep-dive.md:56`、`docs/majsoul-unity-protocol.md:101-104` | 注入 2 個 JS modules | 3 個（`naki-plugins`） | `WebSocketInterceptor.swift:172-176` |
| 14 | `docs/architecture-deep-dive.md:54-66` | 啟動順序缺遷移與插件掃描；步驟 8、9 重複 | `NakiRuntime.swift:77`、`:100-101` | `sed -n 60,105p NakiRuntime.swift` |
| 15 | `docs/architecture-deep-dive.md:89` | ViewModel 用 `GameStore.apply` | `NakiWebCoordinator` 寫 | `NakiWebCoordinator.swift:150`、`:162` |
| 16 | `docs/architecture-deep-dive.md:113-115`、`:186` | `MortalBot(playerId:version:4,useBundledModel:true)`；0.5.2；75 tests | `BundledCoreMLBot`／`AkagiSanmaBot`／`CloudBot`；0.6.0；890 | `NativeBotController.swift:155-191` |
| 17 | `docs/plugin-api-v1.md:4` | 實作尚未存在 | `PluginRegistry`、`naki-plugins.js` 都存在；同檔 `:32` 已寫熱插拔 | 檔案存在 |
| 18 | `docs/plugin-api-v1.md:333`、`docs/plugin-system-design.md:278`、`PluginRegistry.swift:147` | iOS 目錄 `Application Support/Plugins/` | `Application Support/Naki/Plugins/` | `PluginRegistry.swift:148-156` |
| 19 | `docs/plugin-api-v1.md:333` | iOS 經 document picker 匯入 | 無此實作，只能 URL 匯入 | `grep fileImporter\|UIDocumentPicker` 0 命中 |
| 20 | `docs/plugin-api-v1.md`、`naki-plugins.js:33` 註解 | 插件自稱什麼一律不算數 | grants 與總開關是可寫全域變數 | `naki-plugins.js:475-480`；視 U4 |
| 21 | `docs/mcp-server-guide.md:267` | Legacy 沒有 resolver | 兩條 path 共用 resolver，Legacy 不自動送 | `NakiRuntime.swift:172-174`、CLAUDE.md 平台差距段 |
| 22 | `docs/mcp-server-guide.md:268` | 三麻沒有專用 AI model | `AkagiSanmaBot` | `NativeBotController.swift:61` |
| 23 | `docs/mcp-server-guide.md` 工具表 | 缺 `game_confirm_new_round`、`game_vote_game_end`、`lobby_cancel_unified_match`、`lobby_match_sids`、`lobby_start_unified_match` | 5 個都已註冊 | `grep -c` 於文件為 0、程式為 1–2 |
| 24 | `docs/majsoul-unity-protocol.md:27`、`:331` | 無 live 三麻驗證 | 2026-10-09 三局已驗 | `.swfd/logs/s3-live-{4,5,6}` 含 `is3P=true` |
| 25 | `SettingsStore.swift:179` | 插件開關下次載頁才生效 | 熱插拔（`NakiRuntime.swift:397-407`） | `setPluginEnabled` → `hotApplyPlugin` |
| 26 | `SettingsStore.swift:485-486` | 雲端是唯一真三麻路徑 | 本地 `AkagiSanmaBot` | `NativeBotController.swift:61-62` |
| 27 | `SettingsStore.swift:110`、`:115` | UI 的 Toggle 讀寫隱藏名稱 | 已無 Toggle（WP7a 連同屬性刪除） | `AdvancedSettingsSheet.swift:450` |
| 28 | `SettingsStore.swift:14-20` | `SettingsStore` 的型別註解 | 黏在 `MajsoulServer` 上 | `sed -n 12,30p`（WP7a 處理） |
| 29 | `WebSession.swift:15`、`:482-483` | 隱藏名稱重載後補推 | `applyHideNamesIfNeeded` 是 no-op | `WebSession.swift:452-458` |
| 30 | `CloudBot.swift:24`、`:309`；`AutoPlayEngine.swift:167`；`NakiWebCoordinator.swift:280`；`NativeBotController.swift:559` | 雲端逾時預算 2s | 3.0（`d0072fa`） | `AkagiApiClient.swift:158` |
| 31 | `AutoPlayActionExecutor.swift:7`、`AutoPlayEngine.swift:820` | 7-case switch | 9 種動作＋unknown | `AutoPlayActionExecutor.swift:68-158` |
| 32 | `AutoPlayDecisionResolver.swift:50` | isSanma 時一律不自動送出 | 三麻引擎決策與和牌兩個例外 | `:71-72`、`:91-101` |
| 33 | `BundledCoreMLBot.swift:34-36`、`NativeBotController.swift:383-384` | 三麻仍送進四麻 model；三麻本地引擎是 nil | `AkagiSanmaBot`（D23） | `NativeBotController.swift:157-176` |
| 34 | `MortalActionMapper.swift:29` | pin 的是 0.5.x | 0.6.0 | `Package.resolved:19` |
| 35 | `AutoPlayEngine.swift:141` | `isReady` 是 `webPage != nil` | 恆 true（WP7c 刪） | `WebSessionBackends.swift:40`、`:219` |
| 36 | `SystemTools.swift:119-122`（MCP 對外說明字串） | 內建 `__nakiHighlight` 自動染色由 `syncGameHighlight()` 驅動 | 內建染色於 `c0b7564` 移除；函式名不存在 | `grep syncGameHighlight command` 只命中該字串 |
| 37 | `LiqiTile.swift:9-11`、`:18` | 牌碼全專案只有本檔知道；`NativeBotController.tileToDiscardActionIndex` | 另有 6 處（WP11）；函式已是 `MortalActionMapper.discardActionIndex` | `MortalActionMapper.swift:38` |
| 38 | `MahjongBot.swift:50-51` | `reset()` 由呼叫端觸發 | 正式路徑沒有呼叫者，換局一律重建 | `CloudBot.swift:132-138`、`NativeBotController.swift:199-205` |
| 39 | `AutoRematchEngine.swift:157` | 頁面重載或 App 收攤時取消 | 只有模式改變時呼叫 | `NakiRuntime.swift:308`；`webNavigationDidStart` 無呼叫 |
| 40 | `NakiApp.swift:17-18`、`Naki_MApp.swift:17-19` | 遷移要早於 View 的 `@AppStorage` 讀取 | 已無讀模式 key 的 `@AppStorage` | `grep AppStorage` 只剩 `pinMajsoulServerKey` |
| 41 | `NakiEnvironment.swift:7-8`、`ContentView.swift:57` | View 只讀三樣東西 | 五個欄位 | `NakiEnvironment.swift:42-51` |
| 42 | `PluginsPageView.swift:15-16` | body 讀 `recentLogLines()` | 讀 `entries` | `:644-647` |
| 43 | `GameStore.swift:1-6` | 牌局資料的單一真實來源 | 也放更新提示、Debug server 狀態、載頁失敗 | `:67-80`、`:117-125` |
| 44 | `NakiUITests.swift:18` | Laya/WebGL 黑盒 | Unity | CLAUDE.md |
| 45 | `FLOW_COMPARISON.md:14`、`:107` | `command/Views/WebViewController.swift` | 檔案不存在 | find 0 命中 |
| 46 | `docs/README.md` 索引 | — | 18 份文件未索引 | `ls docs` |
| 47 | `README.md`、`README.en.md`、`README.ja.md` | 未提插件系統與 App 內語言 | 兩者都是一級 UI | `PluginsPageView.swift:446`、`L10n.swift:14-21` |
| 48 | `l10n-implementation-notes.md:61` | 726 tests | 歷史快照，標日期即可 | — |

## 8. 審查員誤判與修正

| 來源 | 審查員說 | 我的核對 | 修正 |
|---|---|---|---|
| arch S15 | `LiqiActionSender.lastResult` 外部沒有讀取點，刪除 | `NakiTests/AutoPlayFailsafeFixtureTests.swift:90`、`:535`、`AutoPlayActionExecutorTests.swift:64` 讀它 | 不刪；它是測試縫 |
| arch S15 | `LiqiOperationStore.markCurrentHandled()` 全專案沒有呼叫端 | `NakiTests/BotAvailableActionsTests.swift:140` 呼叫 | 不刪 |
| arch S15 | `ActionDelayModel.verificationScale` 刪除改用 `scale` | 只有測試設值，是測試縫；刪除要改測試且無產品收益 | 不做 |
| bot R23 | 多餘 `await` 共 11 處 | `grep` 為 9 處，與 arch 報告一致 | 以 9 為準 |
| bot R17 | `bakaze`、`doraIndicators` 沒有讀取者 | 外部命中 `GameState.bakaze`（`GameStoreTests.swift:214`）與 `GameState.doraIndicators`（`DecisionSidebar.swift:272`、`NakiMCPDependencies.swift:146`），是同名的另一個型別成員 | controller 版可能真的無人用，但要以 build 為準，WP7b 標「編譯器確認」 |
| bridge M1 步驟 3 | 「保留 ReqAuthGame 取 accountId 當第二來源」需用戶確認 | 正式路徑從未有這條；加第二權威違反 D16 單一來源取捨；缺 accountId 已有 blocking fault 可見 | 代決不做，不送用戶 |
| bridge S1 | 鍵改 (socketId, msgId) 需用戶確認 | 內部簿記，不改協定語意 | 代決延後（先量） |
| arch S5 步驟 2 | 刪單一實作的協定需用戶決定 | 內部型別 | 代決不做 |
| ui 漂移 #19 | 三麻 live 哪邊對未驗證 | `.swfd/logs/s3-live-{4,5,6}` 含 `is3P=true` | `CLAUDE.md` 對，protocol 文件過期 |
| ui S12（第二版） | 整段多縮一層「看起來像巢狀」 | `AdvancedSettingsSheet.swift:382` 起確實多縮一層 | 成立，但這是縮排錯位，不是邏輯問題；併 WP8 |
| bridge（兩版）、ui（第二版） | 「mempal 搜不到 2026-08-02 決策原文」 | 原文在 `note/dev-notes/2026-08-02-swiftui-target-pattern.md:24-26`（arch 第二版找到） | 決策有據可依，不是只有轉述 |

### 8.1 審查員分歧的裁決

**View 可否直讀 `LogManager.shared`、`JSInjectionState.shared`、`LiqiParseFaultState.shared`**
- UI 審查員：違反既有決策（ui S1）。Bridge 審查員：這三個是 service 自身健康狀態，維持 service 形態合理。Bot 審查員（§4）：View 只讀不寫，符合既有決策。
- 裁決：兩邊各對一半。**service 形態保留**（Bridge 審查員對）：這三個型別不套 Store／Action，不改成 `@Observable` Store。**View 的取得路徑改走 environment**（UI 審查員對）：2026-08-02 決策原文第 24-26 行寫的是「View 透過 `@Entry` 拿到它需要的一切，正式 Scene 顯式注入，`@Entry` 預設值只給 Preview」；View 直接寫 `.shared` 繞過了這個注入點，Preview 與單測因此無法替換 fault／injection 狀態，`LogPanel` 的 `clear()` 更是 View 直接呼叫 service 的寫入。所以 WP8 在 `NakiEnvironment` 加三個 ref、`clear()` 改成 Action，單例本身不動。
- Bot 審查員「只讀所以符合決策」的前提不成立：`PluginsPageView.swift:466` 的 `PluginImportSource.fetchAny` 與 `LogPanel.swift:54` 的 `clear()` 都是寫入或 I/O。

**bot R2（吃對照失敗送 index 0）是否升為必須改**
- Bot 審查員：條件升級，live 出現多組且對照失敗才升。
- 裁決：維持「建議改」但本輪就做（WP7c 第 7 項），理由是修法只往保守方向（少送、不多送），且沒有 live 證據時更應該選不送。發生率由第 6 節第 20 項用既有 log 字樣統計，不必等新 log。

## 9. 主線需更新的記憶項

- `akagi-sync-baseline.md`：「#264／#265：Naki `AkagiApiClient.reactTimeout = 2.0` 仍是舊值」已過期。程式碼是 `3.0`（`AkagiApiClient.swift:158`，commit `d0072fa`「跟上 Akagi 4.0.47 schema 與 react 逾時 3 秒」）。該條應改為「已吸收」。
- `MEMORY.md` 索引的 `akagi-sync-baseline` hook 寫「已到 2026-08-09/PR #232」，但記憶檔本文已是「2026-09-29（cd68865，v3.7.1）」；索引 hook 要同步。同一記憶檔「`liqi.json` 仍缺 `auto_operation`」也已過期（2026-10-09 補上，見 `CLAUDE.md`）。
- 剩餘未吸收項「延遲扣時與 time-bank caps」仍正確（`AutoPlayEngine.swift:540-546` 傳總時限），本輪列延後。
- 「時限單位毫秒」與程式一致（`/ 1000`）；「保活靠 Swift 喚醒」與 `WebSession` tick 一致。兩條不需改。
- 可新增一條 project 記憶：「bridge 測試 helper 曾走正式路徑跑不到的 authGame REQUEST 分支（bridge M1）；WP0 之後測試一律用 `parseRaw`／登入回應 fixture」。等 WP0 完成再寫。

## 10. 證據基礎：實際打開核對過的檔案

程式碼（以 `sed`／`grep` 讀取指定範圍或全檔搜尋）：
- `command/App/NakiRuntime.swift`（60-120、140-147、183-258、270-300、328-400、544-552、605）
- `command/App/NakiEnvironment.swift`（1-12、50-75）
- `command/App/SettingsStore.swift`（12-30、72-78、108-125、175-182、215-224、278-286、480-490、517）
- `command/Actions/NakiActions.swift`（410-435、917-938、1104-1201、1150-1158、1455-1475）
- `command/Models/GameModels.swift`（176-202、262、339-365）
- `command/ViewModels/UIState.swift`（grep deinit）
- `command/Services/Bot/NativeBotController.swift`（22、50-70、97-107、207、265-305、381-386）
- `command/Services/Bot/AkagiSanmaBot.swift`（12-24、40-80）
- `command/Services/Bot/CloudBot.swift`（100-122、200-230、267）
- `command/Services/Bot/AkagiApiClient.swift`（158、165-169、228）
- `command/Services/Bot/AutoPlayEngine.swift`（128-131、157-168、195-200、229-234、285-302、353-414、471-472、530-548、569-620、789、818-822）
- `command/Services/Bot/AutoPlayGate.swift`（46-58、95-110）
- `command/Services/Bot/AutoPlayDecisionResolver.swift`（48-60）
- `command/Services/Bot/AutoPlayActionExecutor.swift`（5-9、55-60、99-140）
- `command/Services/Bot/AutoPassDispatcher.swift`（36-43）
- `command/Services/Bot/AutoRematchEngine.swift`（30-50、155-165、200-210）
- `command/Services/Bot/AutoPlayMode.swift`（36-44、146-152、165-180）
- `command/Services/Bot/ActionDelayModel.swift`（178-185）
- `command/Services/Bot/BundledCoreMLBot.swift`（24-39、121-145）
- `command/Services/Bot/MortalActionMapper.swift`（27-38、160-164）
- `command/Services/Bot/MahjongBot.swift`（52）
- `command/Services/Bridge/MajsoulBridge.swift`（5-9、74-77、85-160、170-185、255-370、388-395、451-460、525-540、600-615、748-766、790-808、828-870、912-930）
- `command/Services/Bridge/LiqiParser.swift`（86、101、195-260、631-646、659-663、745、1100-1135、1335-1345）
- `command/Services/Bridge/LiqiOperationStore.swift`（330-345）
- `command/Services/Bridge/LiqiResponseStore.swift`（236-241）
- `command/Services/Bridge/LiqiEncoder.swift`（92-102）
- `command/Services/Bridge/LiqiParseFault.swift`（52-54、105-197 的 blocking／banner 相關行）
- `command/Services/Bridge/LiqiTile.swift`（8-19）
- `command/Services/Bridge/WebSocketInterceptor.swift`（133、170-178、248-301、253-268、369、478-560）
- `command/Services/Bridge/NakiWebCoordinator.swift`（75-120、260-305）
- `command/Services/Bridge/MJAIEventStream.swift`（grep print）
- `command/Services/Bridge/NakiWebSocketScript.swift`（18-45）
- `command/Services/Web/WebSession.swift`（12-18、48、123-140、327-336、370-390、405-408、423-427、450-460）
- `command/Services/Web/WebSessionBackends.swift`（40、78-84、219、312）
- `command/Services/MCP/MCPContext.swift`（121-125）
- `command/Services/MCP/MCPToolRegistry.swift`（15-25、52、77、110、158-186）
- `command/Services/MCP/LiqiToolResult.swift`（24-30、86）
- `command/Services/MCP/Tools/BotTools.swift`（55-80）
- `command/Services/MCP/Tools/GameTools.swift`（50-56、124-129）
- `command/Services/MCP/Tools/LobbyTools.swift`（68-105、130-152）
- `command/Services/MCP/Tools/ReplayTools.swift`（130-165）
- `command/Services/MCP/Tools/SystemTools.swift`（117-123、168、191）
- `command/Services/Debug/DebugServer.swift`（125-172、314-318、757-766、819-825、854-864）
- `command/Services/LogManager.swift`（186、420-432）
- `command/Services/L10n.swift`（47-51）
- `command/Services/Plugins/PluginRegistry.swift`（144-158、211-224、291-292、347）
- `command/Services/Plugins/PluginImportSource.swift`（242-264）
- `command/Views/ContentView.swift`（125-133、226-240、273-290、453-468、680-686）
- `command/Views/DecisionSidebar.swift`（481-489、608-614）
- `command/Views/StatusBanners.swift`（17、43、64-71、115-120、166、230-240）
- `command/Views/PluginsPageView.swift`（15、460-470、486-492、645）
- `command/Views/LogPanel.swift`（12）
- `command/Views/AdvancedSettingsSheet.swift`（372-388）
- `command/Views/MajsoulConnectionSettingsBox.swift`（112-124）
- `command/Views/TileImage.swift`（120-125）
- `command/Resources/JavaScript/naki-websocket.js`（110-125、216-232、395-405）
- `command/Resources/JavaScript/naki-plugins.js`（31-40、123-140、268-276、375-379、473-482）
- `Naki/App/NakiApp.swift`（10-25）、`Naki-M/Naki_MApp.swift`（全檔）
- `Naki.xcodeproj/project.pbxproj`（140-146、236-242、288-300、885-1155 的 SWIFT_* 設定、1233-1242）
- `Naki.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`（9-19）

測試與腳本：
- `NakiTests/LiqiParserFailureTests.swift`（82-125、867-878）
- `NakiTests/NakiEnvironmentTests.swift`（50-175）
- `NakiTests/NativeBotControllerTests.swift`（54-86 的 `.shared` 行）
- `NakiTests/GameStoreTests.swift`（355-375）
- `NakiTests/NakiViewActionTests.swift`（20-32）
- `NakiTests/AutoPlayModeStoreTests.swift`（96-104）
- `NakiTests/`（`func test` 靜態計數 890；`ReplayFingerprintTests.swift` 存在）
- `Naki-MTests/Naki_MTests.swift`、`NakiUITests/NakiUITests.swift`（15-20）
- `scripts/replay-check.sh`（1-30、SESSION 相關行）、`scripts/plugin-regression.cjs`（1-12）、`scripts/keepalive-regression.cjs`（1）、`scripts/mutate.py`（1-25）
- `docs/replay-baseline.txt`（1-3）

文件：
- `CLAUDE.md`（全檔，系統注入）、`AUDIT.md`（18-26、59-63、75-83、112-128、139-143）
- `docs/README.md`（24-34）、`docs/architecture-deep-dive.md`（50-68、87-91、111-115、173-177、186）、`docs/majsoul-unity-protocol.md`（25-29、40-44、99-106、191-195、304-308、327-333）、`docs/plugin-api-v1.md`（1-6、30-34、331-335）、`docs/plugin-system-design.md`（276-280）、`docs/mcp-server-guide.md`（265-269、工具名 grep）、`docs/akagi-audit-p0-decisions.md`（190-196）、`FLOW_COMPARISON.md`（grep）
- `note/dev-notes/2026-08-02-swiftui-target-pattern.md`（20-30）

審查報告版本：四份都以第 1 節列出的檔案時間為準全文重讀；`bot.md` 16:46:51 版的 R 編號與 16:42 版不同，本文件第 3.3 節與所有 `bot Rn` 引用都已對到 16:46:51 版。

日誌與歷史：
- `.swfd/logs/merge-main/test-813aa88.log`（警告統計、`Executed 890 tests`）、`iphone-build.log:2`
- `.swfd/logs/s3-live-{4,5,6}`（`is3P=true` grep）
- `git log`：`c0b7564`、`341f1a6`、`d0072fa`、2026-08-04～08-07 區間；`git status --short`
- mempal：`mempal search "authGame request seat 歸零 422" --wing naki`（命中 `cloud-inference-decisions.md` D16）
- auto-memory：`akagi-sync-baseline.md`、`naki-tmp-worktree-test-pitfall.md`

## 11. 用戶裁決結果（2026-10-12）

| 項 | 裁決 | 併入 | 備註 |
|---|---|---|---|
| U1 matchGame 鏈 | **移除整條鏈**（採建議 A） | WP7b | 移除前必須先以 MCP 呼叫一次 `lobby_start_match` 確認仍回 error 1306，把輸出存進 `.swfd/logs/wp7b/` 當最後證據 |
| U2 seat／type 缺席 | **缺席視為 0，同時在該點記 degraded fault**（用戶選 B，未採建議 A） | WP5 | 風險：若伺服器省略欄位且語意不是 0，座位會錯記且畫面看不出；fault 是唯一可觀察訊號，因此 fault 不得省略。對應測試必須新增「欄位缺席的 fixture」 |
| U3 預設模式 `.auto` | **維持現狀**（未採建議 A） | 不改 | WP12 文件須明寫「新安裝預設自動送出」 |
| U4 插件授權 | **只改文件**（統帥代決，採建議 A） | WP12 | 插件由使用者自行安裝，信任邊界本來就包含插件 |
| commit 系列 why | **一次授權** | 全部 WP | push 仍每次單獨授權 |

既有決策補充：不引入 InnoDI。理由：DI 面積只有一個 `@Entry` 與 `NakiRuntime.init` 十行有序接線，框架無問題可解；`@DIContainer` 不支援自訂 init；沿用「預設參數 = .shared」注入縫即可。完整筆記在本機 `note/dev-notes/2026-10-12-no-innodi.md`（`note/` 不納入 git，與 2026-08-02 決策檔同慣例）。

## 12. WP0 結果與 codex 審查處理（2026-10-12，統帥代決）

### WP0 結果
- 合併到 main：`1e840a8`（diff 基準 `71ecee3..1e840a8`，兩檔）。獨立復驗裁決「可合併」，宣稱與實測全部一致（`.swfd/logs/wp0-verify/`）。
- 兩個架構假設都成立：(a) 「預設參數 = .shared」注入縫在正式路徑零改動下讓測試隔離，6 個人工變異全被殺；(b) 只刪 authGame REQUEST 死分支時 55 條測試有 23 條失敗、全部是 accountId=0，證明這 23 條原本靠死碼取得 accountId。
- 復驗員核對成立的既有問題（WP0 之前就存在）：`LiqiParser.swift:346-348` 把 `.lq.Lobby.oauth2Auth` 回應交給 `parseLoginResponse`，`ResOauth2Auth` field 2 是 string（access_token），`parseLoginResponse` 不檢查 wireType 直接 parseVarint，token 首 byte 會被當 accountId 並通過 `> 0` 檢查覆寫；是否被後續 ResLogin 蓋回取決於 live 登入順序，無法靜態判定。`MajsoulBridge.swift:275-282` 的 `msgData["account"]` 巢狀分支在標準編碼下是死碼。
- 基準說明：本文件 §1 與 §5 寫的審查基準 `813aa88` 是**四份審查報告**的基準；各 WP 的 diff 基準是其 worktree 分支點（WP0 為 `71ecee3`）。後續復驗一律以 WP 自己的分支點為 base。

### codex 審查（gpt-5.5 xhigh，唯讀 sandbox；帳號不支援 gpt-5.4，由代跑員改用同家族 gpt-5.5，統帥接受）
總評原句：「需先修正後再展開。修正項：把 oauth2Auth response parser/wireType 問題排成 WP0.5 或提前到 WP1 前；把 WP3 測試 host side-effect 與 WP7c 吃牌 fail-closed 拆早；在 U2 實作規格補清楚『缺席才補 0，malformed 不補』。」完整回覆：`.swfd/codex/design-review-wp0/reply.txt`。

| codex 意見 | 處理 | 理由 |
|---|---|---|
| 單一根因收斂太窄，降級提示覆蓋、吃對照退 index 0、oauth2Auth 是獨立問題 | 接受措辭修正：§1 的「核心問題」指**最大的一簇**，不是唯一根因；三項獨立問題各自已有 WP（WP3、WP4、WP0.5） | 不影響 WP 內容 |
| WP3（test host 起 engine 與 server）應緊接 WP0 | **接受**。新順序：WP0 → **WP0.5 ‖ WP3** → WP1 ‖ WP2 → WP4 → WP5 → WP6 → WP7a → WP7b → WP7c → WP8 → WP9 ‖ WP10 → WP11 → WP12 | 兩包都小、互不相干，可平行且不超過 2 棵編譯樹 |
| WP7c 第 7 項（吃對照失敗只收緊、不送）應提前 | **接受**。移到 WP4（Bot 錯誤語意），WP7c 刪除該項 | 同屬「少送、不多送」的保守收緊，WP4 已是行為語意包。用戶已在裁決前被告知此項（§8 R2） |
| oauth2Auth parser 應排 WP0.5 | **接受**，見下方 WP0.5 | accountId 是 D16 單一來源，被汙染會讓 seat 找不到並 blocking |
| U2 實作規格要補「缺席才補 0，malformed 不補」 | **接受**，見下方 U2 實作邊界 | 用戶裁決 B 的前提是「proto3 缺席＝0」，malformed 不在此前提內 |
| 同一 bridge 跨局只靠 authGame 回應不是完整重置（codex 推測） | 列入 §6 runtime 驗證清單：同頁跨局時 `reset()` 是否每局都被呼叫，用 WP1 的 log 證實 | 既有風險，非 WP0 回歸 |

### WP0.5 登入回應 parser 只接受 varint accountId
- 目標：`accountId` 的唯一來源只能是 ResLogin 形狀的回應，且欄位必須是 varint。
- 範圖：`command/Services/Bridge/LiqiParser.swift`；測試檔用既有的 parser 測試檔（實作者先 `grep -l parseLoginResponse NakiTests/*.swift` 找；找不到就用 `NakiTests/LiqiParserFailureTests.swift`）。
- 不得碰：`MajsoulBridge.swift`、`WebSocketInterceptor.swift`、`LiqiEnvelope.swift`、JS。
- 內容：
  1. 依 `docs/protocol/liqi.json` 列出回應型別為 `ResLogin` 的 method（預期：`.lq.Lobby.login`、`.lq.Lobby.oauth2Login`、`.lq.Lobby.emailLogin`；實作者必須用 jq 證實並寫進報告）。`.lq.Lobby.oauth2Auth`（`ResOauth2Auth`，無 account id）不再交給 `parseLoginResponse`。
  2. `parseLoginResponse` 的 field 2 與 `account.account_id` 只在 wireType 為 varint 時採用；非 varint 不設 accountId，記一筆 degraded fault（site `LiqiParser.loginResponse.wireType`），不得 blocking。
  3. 測試：(a) oauth2Auth 回應帶 token 字串不設 accountId、不記 blocking；(b) ResLogin field 2 varint 仍設 accountId；(c) field 3 巢狀 `account.account_id` 仍設；(d) field 2 為 length-delimited 時不設且記 degraded fault。
- 依賴：WP0。可與 WP3 平行。
- 路由：Sonnet 5.5 medium。
- 略過清理三條件：不符合（新分支）。
- 驗證閘：build＋`-only-testing:NakiTests`（基準 892 條 0 失敗）；`grep -n "oauth2Auth" command/Services/Bridge/LiqiParser.swift` 的每一處都不得指向 `parseLoginResponse`。
- 風險與回退：若某區服登入實際只回 oauth2Auth 而不回 ResLogin，accountId 會缺、authGame 回應記 blocking fault（使用者看得到），比錯座位好。回退 revert。
- 資源：需編譯。

### U2 實作邊界（WP5 必須遵守）
1. **只有「欄位缺席」才補 0**；欄位存在但 wireType 錯、解析失敗、值越界，一律視為 malformed：丟棄事件並記 fault（不補 0）。不得用 `as? Int ?? 0` 這類把兩種情況混在一起的寫法。
2. **`ActionChiPengGang.type` 缺席補 0（＝chi）的前提**是 `pai` 與 `consumed` 都存在且解析成功；任一缺席即 malformed，丟棄並記 fault。不得產出空 `pai`／`consumed` 的事件。
3. **不套到 repeated 權威欄位**（`seat_list` 等），它們已有 exact／heuristic／fault 語意（`LiqiParser.swift:919-960`）。
4. 每個補 0 的點都記 degraded fault（用戶裁決），fixture 必須涵蓋「缺席補 0」與「malformed 丟棄」兩種形狀。
5. 預設 fixture 的自家座位改為非 0（復驗員第 2 項：26 條測試坐在 seat 0 分不出座位對錯）。

### 流程修正
- 實作者在自己的分支 commit；主線只在獨立復驗裁決「可合併」後 `--ff-only` 合併到 main。WP0 已照此做。

### WP0.5 結果（2026-10-12）
- 合併到 main：`408035e`（基準 `be8ea47`，兩檔）。復驗裁決「可合併」（`.swfd/logs/wp05-verify/`）：896/896，7 個變異全殺，oauth2Auth 回應回 `[:]` 不進 `lastParsed`。
- 復驗員列出的後續項（不擋合併），歸屬：
  - `MajsoulBridge.swift:266-267` 登入條件仍列 oauth2Auth，現為死碼只印誤導 log → WP5。
  - `parseLoginResponse` field 3 為 varint、或 field 2 為 wireType 1／5 時不記 fault（後者因 `LiqiEnvelope.parseProtobufBlocks` 直接跳過）→ 延後表，等 live 證據。
  - `ResLogin` field 1 `error` 以 varint 解、恆為 8，全 repo 無讀取者 → WP7a 死碼清理時一併刪或改。
  - 測試 (d) 補 fault 的 fieldId 斷言 → WP5。

### WP3 結果（2026-10-12）
- 合併到 main：merge commit `c1b12e6`（WP3 原 sha `9721f0d`，基準 `be8ea47`，6 檔）。復驗裁決「可合併」（`.swfd/logs/wp3-verify/`）：894/894，iOS build 成功，test host 不再綁 8765。合併態在 main 全套 898/898（`.swfd/logs/merge-main/test-c1b12e6.log`）。
- 紀律偏離（統帥接受）：實作者改了範圖外 `MCPContext.swift`（協定加唯讀 `supportsAutoPlay`，5 行）。復驗專項結論：必要；唯一不改協定的做法是借 `setAntiIdle(nil,nil)` 的接線當探針，會讓 `bot_trigger` 依賴心跳接線這個不相干細節，不採。協定唯一 conformer 是 `DefaultNakiMCPContext`，無 mock 受影響。
- 自報偏離：第 3 項「失敗後 `debugServer = nil`」改為下次啟動時替換舊實例（`DebugServer` 失敗無回呼且不在範圍）；第 5 項 UI 測試斷言略過（需在 `command/` 加注入掛鉤）。
- 復驗員列出的後續項，歸屬：
  - `DebugServer` 的 `.failed`／`.cancelled` handler 不把 `isDebugServerRunning` 設回 false，曾 ready 後全敗時 guard 仍回「已在運行」→ WP7b（需改 `DebugServer.swift`）。
  - Legacy 不可用時各工具短碼放置不一致（`bot_trigger` 放 `error`，`sendLiqi` 系列放 `reason`，`lobby_anti_idle` 另一碼）；短碼字串在 `BotTools.swift:62` 與 `NakiRuntime.swift:342` 各寫一份 → WP7b。
  - 第 3 項 guard 的鎖法（預設 `isDebugServerRunning = true` 與隨機高位 port 後呼叫 `startDebugServer()`）與第 1 項降級提示的測試（備份還原 `naki.autoPlayMode` key）都可做、不必等 WP9 → WP7b 補測。
  - 第 4 項只鎖 server 未鎖 engine 略過 → WP7b 補測。
  - `BotTools.swift:79` note 過時 → WP12。
  - UI 測試驗 iOS 橫幅需 launch argument 注入 `pageLoadFailure` → 延後表。
- 新順序下一步：WP1（進行中）‖ WP2。

### WP1 結果（2026-10-12）
- 合併到 main：merge commit `ae40747`（WP1 原 sha `1123a84`，基準 `10d81cd`，7 檔）。復驗裁決「可合併」（`.swfd/logs/wp1-verify/`）：「不改行為」逐 hunk 獨立成立，5 個變異獨立重現全殺，898/898，改動檔 0 新警告。合併態 main 全套 900/900（`.swfd/logs/merge-main/test-ae40747.log`）。
- 解讀偏離（統帥接受復驗建議，保留）：配不到 request 的 `.info` 在第 1、2、4、8… 次報並帶累計，fault 只記首次。理由：log 行數為 log2(N) 上界又保留量級，正是 bridge M4 要對照的資訊。
- 復驗員指出的文件問題已修：§6 第 1 條 grep 字串改為 WP1 新增的 `.info` 字串（原 trace 行不進 all.log）。
- 措辭備註：log 寫「本連線累計」，實際是一個 reset 週期內所有雀魂 socket 的合計（lobby 與 game-gateway 共用同一個 parser）；對照要靠前一行 `[WS] socket N ← bytes`。歸 WP12。
- 實作 notes 寫 5 條 `wsLog`，實際 6 條；同函式另 2 條 `[Action]` wsLog 未帶 socketId。歸 WP5。
- 已知未驗證量級：三麻 syncGame 重放後序號不一致 log 可能每次重連多出數十行 `.info`（復驗員推測）。列入 §6 runtime 驗證，live 一局後決定是否降 `.trace`。

### WP2 結果（2026-10-12）
- 合併到 main：merge commit `f5edbb8`（WP2 原 sha `1c77b27`，基準 `ee309a7`，5 檔含三麻錄影 fixture 47016 bytes、暱稱已匿名）。復驗裁決「可合併」（`.swfd/logs/wp2-verify/`）：900/900，變異 1 與 6 證實三麻隔離斷言不是恆真，正式路徑唯一建構點 `NakiWebCoordinator.swift:47` 零改動。合併態 main 全套見 `.swfd/logs/merge-main/test-f5edbb8.log`。
- 復驗員列出的後續項，歸屬：
  - `testSanmaReplayDoesNotReadSharedOperationStore` 在 replay 全部 throw 時 pon／isDisjoint 斷言會空轉成立 → **WP4 補 `decisionCount > 0` 與 `errors.isEmpty` 斷言**（WP4 範圍加入 `ReplayFingerprintTests.swift`）。
  - §6 第 13 項的 runtime 驗收照原文跑不起來：`ReplayGameTool` 只接受 `~/Library/Logs/Naki/` 內的檔，`.swfd/logs/s3-live-5/…` 會被拒 → 整合驗收時先複製到某 session 的 `games/` 下。
  - `sanmaAuthorization` 未列進 `replay_game` 的 outputSchema properties（`MCPToolOutputSchema.swift:94-107`，`additionalProperties: true` 所以不違約）→ WP7b。
  - 變異 5（`opsSummary` 純 log 字串）存活，不補攔截縫 → 不處理。
  - 四麻 `scripts/replay-check.sh` 未跑（需執行中 Naki）→ 整合驗收。

### WP4 進行中裁決（2026-10-12）
- 復驗（HEAD `4695b79`）裁決「要修正」，唯一阻擋項：雲端-only 路徑取消時不累加 `cloudFallbackStreak`（`CloudBot.swift:178`）無測試鎖住，復驗員自選變異存活。
- 統帥裁決：**補測試，不撤回該行**。理由：該行方向正確（取消不應誤記故障，與 R5 同一精神），缺的是鎖不是正確性；撤回會讓斷線期間 UI 顯示錯誤的降級計數。修正以新 commit 進行，再交同一復驗員對新 HEAD 復驗。
- 復驗確認的其他結論：8 個 hunk 無一增加送出；「沒有任何組合也不送」為安全收緊（正式路徑唯一可達情況是 combination 解析缺陷，不送後引擎重試 15 次再退避，不卡死、不擋 pass 通道）；舊世代結果回 nil 可能暫時抹掉新局 `botFailure` 顯示，只影響顯示不影響送出，列已知風險。

### WP4 結果（2026-10-12）
- 合併到 main：merge commit `79096b6`（WP4 原 sha `4695b79` ＋ 修正 `5bc131e`，基準 `d861648`，7 檔）。復驗兩輪（`.swfd/logs/wp4-verify/`）：第一輪「要修正」（雲端-only 取消判斷無測試鎖），補測試後第二輪「可合併」，新測試經兩個變異實證同時鎖住 `CloudBot.swift:178` 與 `:223`。910/910；合併態 main 全套見 `.swfd/logs/merge-main/test-79096b6.log`。
- 行為變更（已向用戶報備）：吃對照失敗只收緊——恰一組才退回 index 0，多組或沒有任何組合都不送、不消化 oplist。復驗判定安全：正式路徑唯一可達的情況是 combination 解析缺陷，不送後引擎重試 15 次再退避，不卡死、不擋 pass 通道。
- 已知風險：舊世代結果回 nil 走成功路徑可能暫時抹掉新局 `botFailure` 顯示（只影響顯示）；吃對照失敗每輪重試會記 15 次 event log（噪音）。
- 復驗員列出的後續項，歸屬：
  - `resolveReachDiscard` 的 catch-all 在取消時仍 `recordFailure`，`try? await Task.sleep` 吞掉取消（`CloudBot.swift:279-285`）→ WP7b。
  - R4 另一半（本地丟錯清推薦 vs 雲端失敗保留舊推薦不一致）→ 延後表，等 live 證據決定統一方向。
  - `testChiWithoutAnyCombinationDoesNotSend` 測的是正式路徑到不了的 nil snapshot，可達的「有 chi 但 combination 為空」未直接測 → WP7c 補。
  - 同類多組槓一律送 index 0 仍是已知未實作（WP5 等 live 抓包）。

### WP5 進行中裁決（2026-10-12）
- 復驗（HEAD `57a27ee`）裁決「要修正」，阻擋項：`ActionChiPengGang.type` 缺席補 0（chi）的路徑未檢查順子形狀與三麻。proto3 缺席即 chi，chi 只能是同花色三張連續數牌，「type 缺席但不是順子」自相矛盾，依 U2 第 1 點屬 malformed 應丟棄；WP5 前這類封包被丟棄，不補就會變成 chi 事件送進 bot（復驗推定自家字牌 chi 可能觸發 MortalSwift `AgariCalculator.swift:330-338` `kinds[kind]` 越界，可達性未驗證）。
- 統帥裁決：**補形狀檢查＋`!is3P`，只加在 type 缺席路徑**，type 顯式 0 的既有曝險不動（不擴大 WP5 範圍）。順帶修 malformed seat 的 bridge fault 文字（-1 被寫成「越界」）。
- 復驗推翻的證據：§4 WP5 驗證閘「四麻指紋測試證明事件輸出不變」**無效**——`ReplayFingerprintTests` 重放的是 MJAI 事件流，不經 LiqiParser／MajsoulBridge。現在「格式正確封包輸出不變」只靠逐 hunk 論證＋錄影 fixture 證據（cf38b77 時代 bridge 要求 seat／type key 存在才發事件，錄影裡 actor 0 的事件 56 條、chi 4 條，代表 live 直連顯式送 0）。**後續：補一條「Liqi bytes 進、MJAI 事件出」的 bridge 黃金測試 → WP7c**。
- 其他復驗結論：巢狀 `account.accountId` 顯式 0 覆寫是既有行為（d861648 相同），非本包引入；Deviation 7 改測試輸入合理（保留「自家打牌」語意）；Deviation 2（malformed oplist seat 以 -1 建快照，不 clear）接受——resolver 以 `seat_mismatch` fail-closed，且 `pending != nil` 會亮停滯橫幅，是可見訊號；改 `clear()` → WP7b 評估。
- 給 live 驗證的訊號：依錄影證據，live 直連下 `.absent` fault 照理不會出現；出現就代表中間有代理或重新序列化（寫進 §6）。
- 延後表新增：MortalSwift `kinds[kind]` 無 `< 3` 守衛（上游，type 顯式 0 的字牌 chi 也會走到）；`LiqiActionSender.swift:23`、`LiqiEnvelope.swift:23`、`docs/plugin-system-design.md` 的 `parseRaw` 文件漂移 → WP12。

### WP5 結果（2026-10-12）
- 合併到 main：merge commit `f4fd238`（五項各自 commit `46ecc1c`／`bb08e47`／`1e1c59f`／`f3a6b7f`／`57a27ee` ＋ 修正 `43c0787`，基準 `d861648`，6 檔 `WebSession.swift` 零改動）。復驗兩輪（`.swfd/logs/wp5-verify/`）：第一輪「要修正」（type 缺席補 chi 未檢查形狀與三麻），第二輪「可合併」。902 → 920 條；合併態 main 全套見 `.swfd/logs/merge-main/test-f4fd238.log`。備份分支 `wp5-backup-pre-amend` 已刪（patch-id 已核對一致）。
- U2 落地：六個 seat 補 0 點（五個 action ＋ oplist）與 `ChiPengGang.type` 各記 `<site>.absent` degraded fault、同 site 一次；malformed（wireType 錯／越界）給 -1 後丟棄不補 0；type 缺席補 chi 的前提是四人局、pai 與 consumed 三張同花色連號（赤視為 5）。預設 fixture 自家座位改 2，只 5 條測試需修（非 WP0 估的 26 條）。
- 流程偏離（已核可）：實作者送報告前 amend Commit 1 補強測試並 cherry-pick 其餘四個；復驗以 patch-id 證實 c2–c5 不變、amend 只動測試檔。**規則補強：之後的包不得改寫已結案的 commit，補強一律新 commit。**
- 可合併後補（歸屬）：
  - Deviation 2：malformed oplist seat 以 -1 建快照而非 `clear()`（resolver fail-closed、停滯橫幅可見）→ WP7b 評估。
  - 赤寶牌連號正向測試（4m 0m 6m type 缺席應補 chi）→ WP7c。
  - bridge 黃金測試「Liqi bytes 進、MJAI 事件出」（指紋閘不經 bridge）→ WP7c。
  - `MajsoulBridge.swift:774` `guard let opType` else 分支靜默丟棄不記 fault（parser 一律寫 Int，目前走不到）→ WP7b。
  - MortalSwift `AgariCalculator.swift:330-338` `kinds[kind]` 無 `< 3` 守衛 → 延後表（上游）。
  - `parseRaw` 文件漂移（`LiqiActionSender.swift:23`、`LiqiEnvelope.swift:23`、`docs/plugin-system-design.md`）→ WP12。
  - §6 第 1 項 live 重連對照（M4 reset 提前）未做 → 整合驗收。

### WP6 結果（2026-10-12）
- 合併到 main：merge commit `be11e5b`（三批 `7d7cf90`／`1673921`／`f2818d7`，基準 `9398a2d`，23 檔）。復驗「可合併」（`.swfd/logs/wp6-verify/`）：乾淨 build（獨立 derivedData）app target `warning:` 1 條且為 appintents 工具訊息、`Swift 6 language mode` 0；§4 目標的 10 條 `command/` Swift 6 警告 10/10 歸零；928/928 不變；Release 與 iOS build 皆過。合併態 main 全套見 `.swfd/logs/merge-main/test-be11e5b.log`。
- 五處 actor hop 移除判定安全（呼叫點皆 MainActor；`ObservedMatchSids` 同步後 `gameDidStart` 讀到 sid 的時序等於或優於原本）；`assumeIsolated` 前提成立（全檔唯一 `NWConnection` 來源 `start(queue: .main)`）。動態證據弱：parser 測試的 `Task.yield` 迴圈同步與延後都會過。
- 測試 target 剩 4 條警告不歸零：`MCPTestSupport.swift:14`／`ToolAndModelGapTests.swift:17` 根因是 `ExecuteJavaScriptAction.unavailable` 為 MainActor static 當預設引數（K1 禁區，**WP7a 動 `NakiActions.swift` 時順手評估**）；另兩條 `#NoUsage` 非隔離類 → WP7c 一併清。
- 流程：批 2 commit 漏 `Claude-Session` 尾行，由 merge commit 補記；規格寫 9 處多餘 `await` 實為 11 處；`GameHighlightScript.swift` 的警告隨 `AutoPlayMode` 改 `nonisolated` 自然消失，未直接改。
- 可合併後補（歸屬）：
  - `AutoPlayEngine.init` 的 `echo: nil` 現等於 `.shared`，與 `AutoPlayActionExecutor` 同名參數「nil = 不等回音」語意相反，stored `echo` 型別仍 optional → WP7b（改名或改非 optional）。
  - `LiqiParserLearningTests.swift:17`、`ObservedMatchSidsTests` 的 `Task.yield` 等待已多餘且守不住新時序 → WP7c 補一條不 yield 直接斷言的測試。
  - 純 wire 層被 `liqiLog` 綁在 MainActor（arch S4 殘餘，需動 `LiqiEnvelope.swift` 與全域 log 函式）→ 延後表。

### WP7a 結果（2026-10-12）
- 合併到 main：merge commit `a252f3d`（四批 `3f815f9`／`f5bc2bc`／`dce9760`／`b462815`，基準 `9398a2d`，15 檔 +105/−411）。復驗「可合併」（`.swfd/logs/wp7a-verify/`）：每個刪除項在 main 全專案 grep 無人用；JS 隱藏名稱鏈 3 → 3 行、JS diff 為空；macOS Debug／Release／iOS 三個 clean build 皆過；927/927（−2 `hidePlayerNames` 測試、+1 `testFireJavaScriptLogsFailureWithLabel`）。合併態 main 全套見 `.swfd/logs/merge-main/test-a252f3d.log`。
- arch S16 memberwise init 合成成功（`nonisolated init()` 移到 extension，刪 55 行手寫 init；參數仍全必填）。Deviation 1（`ForceReconnectAction` 三條測試改建真 `WebSession` 放假 `__nakiWebSocket`）語意等價，重複 10 次 0 失敗、每條約 0.1 秒。Deviation 3 多刪 `RescanPluginsAction` 型別，main 上無 MCP 引用，不是錯刪。
- JS 側：`__nakiHideNames` 在 Swift 與 bundled 插件已無呼叫端、plugin-api-v1 未記載 → WP12 判定是否移除；`setNameMask` 是 plugin-api-v1 記載的 API，保留。
- 可合併後補（歸屬）：
  - `AutoPlayModeStoreTests` 的遷移測試都先手動呼叫 migrate，沒有一條鎖「只呼叫 `load()` 就完成遷移」；顯式呼叫已刪，`load()` 內是唯一路徑 → **WP7c 補一條只寫舊 key 直接 `load()` 的測試**。
  - `project.pbxproj` 的 `Naki-MTests` 成為孤兒 target（無原始檔、資料夾不存在、不在任何 scheme）→ WP12 刪 target 或延後表。
  - 規格項「`LiqiToolResult.dictionary` 的 `eventLog` 移到呼叫端或改名」未做（需動 MCP Tools 二十多處，屬 WP7b 檔）→ **交接 WP7b**。
  - `AutoPlayMode.swift:150` doc 仍寫「App 進入點與 load() 都會呼叫」→ WP7c。
  - 基底就有：`build-for-testing -scheme Naki-M` 在 Naki-MUITests target 報 `akagi.entitlements` 重複複製（`Unexpected duplicate tasks`），純 build 不受影響 → 延後表。
  - `fireJavaScript` 測試只驗失敗寫 log，未驗成功不寫 → 次要，WP7c 順手。

### U1 拆出 WP7b（2026-10-12，統帥代決）
- §11 把 U1（移除 `matchGame` 鏈）排進 WP7b，前置條件是「先以 MCP 呼叫一次 `lobby_start_match` 確認仍回 error 1306」。這需要執行中的 Naki 與登入的測試帳號在大廳，只有用戶能提供；實作者不得啟動 app、不得連網。
- 裁決：U1 從 WP7b 拆出成獨立小包 **WP7d**，排在 WP7c 之後、WP8 之前，**等用戶提供 1306 證據後才派**（證據存 `.swfd/logs/wp7d/`）。不先拆掉程式碼再補證據，因為 U1 是用戶裁決的行為移除，證據鏈順序不能反。
- WP7d 範圔：`lobby_start_match`／`cancel_match`／`match_modes` 三個 MCP 工具、`StartMatchAction`／`CancelMatchAction`、`ObservedMatchModes` 與對應測試；`tools/list` 數量會減 3（契約變更，WP12 文件同步）。arch S6 的 4 個匹配 Action 收斂在 WP7d 一併定案。

### WP7b 進行中裁決（2026-10-12）
- 復驗（HEAD `6580ab0`）裁決「要修正」，阻擋項：新 lifecycle 測試 `DebugServerFramingTests.swift:176` 的 port 等式斷言機制性 flaky（40 次失敗 1 次；`occupyPorts` 只佔 base 與 base+1，macOS 臨時 port 範圍 49152–65535 涵蓋測試用區間）。修法：改 `>= base + 2`。
- 統帥裁決附帶兩項：(1) **恢復 listener 身分 guard**——實作者以「main queue FIFO 所以等價」為由把存活變異判為等價並移除 guard，復驗判定跨 listener 事件入隊次序無 Network.framework API 保證，40/40 未觀察到反轉只是「未觀察到」，依「變異存活即 revert 該項」恢復；(2) `occupyPorts` 失敗改 `XCTSkip`。
- 規則補強：**實作者不得自行把存活變異判為「等價變異」後移除被測的 guard**；判等價必須附證明（API 契約或窮舉），否則保留原碼、記為未鎖。
- 其他復驗結論：13 項一致；`eventLog` 改名只改 Swift 名稱不改輸出 key，非契約變更；`resetConfirm` 五處逐處等價；`resolveReachDiscard` 取消在 sleep 期間與飛行中都不記故障，變異兩邊都紅。
- 可合併後補：`DebugServer.swift:675` 的 Task 在 await 期間強持有 self，重啟時舊實例遲到的 `.cancelled` 理論上可清掉新 server 旗標（窗口極窄，推測未實測）→ 延後表；`docs/cloud-inference-plan.md:69,112`、`docs/ui-reference/implementation-decisions.md:12` 提到已刪符號 → WP12。

### WP7b 結果（2026-10-12）
- 合併到 main：merge commit `03ac6b8`（`468cd0b` MCP／`ae77c56` Debug／`e6e6eb2` Bot／`36404b3`／`6580ab0` 補強／`2a1e662` 修正，基準 `a8536e7`，30 檔 +435/−425）。復驗兩輪（`.swfd/logs/wp7b-verify/`）：第一輪「要修正」（lifecycle 測試 port 等式 flaky），第二輪「可合併」。927 → 937 條（+10）；合併態 main 全套見 `.swfd/logs/merge-main/test-03ac6b8.log`。
- 完成：arch S5 `MCPContext.naki()` 31 處機械等價；`MCPToolRegistry` 四個死方法、`DebugServer` 13 個轉發、`NativeBotController` 批次 react／轉發／`canX`、`GameModels` unicode 系列刪除（main 全專案 grep 無人用）；`resetConfirm`／mask 迴圈／摘要字串／`sessionStampFormatter` 收斂逐處等價；工具數 43 不變並加斷言鎖住。
- 後續項處置：`sanmaAuthorization` 進 outputSchema（string，與輸出一致）；legacy 短碼共用常數；`eventLog` 改名 `dictionaryLoggingRejection`（只改 Swift 名）；DebugServer `.cancelled` 歸零旗標＋listener 身分 guard；`resolveReachDiscard` 取消不記故障（sleep 期間與飛行中皆驗）；`echo` → `echoOverride` 且 stored 改非 optional；`MajsoulBridge:778` else 補 `ActionChiPengGang.type.invalid` fault；Deviation 2 評估後不改（`autoPlaySeat` 恆 ≥ 0，-1 無授權路徑）；短碼放置不一致只盤點（notes），改欄位留 WP12 文件化後再議。
- 未做（寫明）：engine 側「只鎖 server 未鎖 engine」測試與啟動降級 log 測試（`autoPlayEngine` 為 private 無縫）；`MajsoulBridge` 新 fault 無測（走不到）。
- 可合併後補（歸屬）：
  - listener 身分 guard 反向變異全綠，**guard 未被測試鎖住** → WP7c 補一條能殺變異的測試。
  - 跨實例窗口：`DebugServer.swift:675` Task 在 await 期間強持有舊實例，重啟時舊實例 `stop()` 後遲到的 `.cancelled` 走 nil 分支會清掉共用 store 旗標（窄窗口，推測未實測）→ 延後表。
  - 立直第二段取消時 `cloudOverride` 仍多寫一行「呼叫失敗」log（WP4 範圍）→ 延後表（只是 log）。
  - `docs/cloud-inference-plan.md:69,112`、`docs/ui-reference/implementation-decisions.md:12`、`CLAUDE.md` 內 `LogManager`／`AutoPlayEngine`／`BotTools` 行號 → WP12。

### WP7c 結果（2026-10-12）
- 合併到 main：merge commit `86792ea`（`c6f5f70` 刪 isReady／`b326603` 刪寬鬆預設值／`a30c870` stale 與三麻判斷式／`c2d488f` DecisionSource／`799a04d` snapshot 共用規則／`5f1246a` 改名 sendsActions／`a3a980d` 後續項測試／`b86f329` GameModels 三行，基準 `7a53245`，33 檔）。復驗「可合併」（`.swfd/logs/wp7c-verify/`）：937 → 949 條；fixture F 四條綠；`mutate.py` 11/11 殺；復驗自選手工變異 6/6 殺；合併態 main 全套見 `.swfd/logs/merge-main/test-86792ea.log`。
- **送出行為變更（已向用戶報備）**：executor 收到 `.hora` 但 oplist 無和牌授權時，改前送 tsumo、改後不送且不消化 oplist（與 MCP 一致，取嚴格邊）。復驗確認正式路徑不可達（resolver 只在 `horaOperation` 非 nil 時給 `.hora`；`bot_trigger` 走同一條路），靜態推論無 live 驗證；測試 `testHoraWithoutAuthorizationSendsNothingAndKeepsOplist` 四斷言鎖住。
- 預設值判定：刪掉的六個全為寬鬆方向（復驗逐一獨立判定一致）；保留的嚴格預設值 `sanmaCapableDecision`／`sanmaEngineAvailable` 各只有一條測試防護（單點，可接受）。實作者保留三個規格未點名的寬鬆預設值（executor `echo=nil`、Context 的 `isSanma`／`recommendationsOplistSequence`／`seat`）→ 延後表（正式路征都明傳）。
- 後續項九條全部完成，含 bridge 黃金測試（復驗依封包語意手算三個期望值一致）、`load()` 遷移測試、listener guard 測試（變異 5/5 紅）。
- **流程事故與規則補強**：實作者結案凍結後收到主線遲到的 GameModels 核准，直接當成解凍在同一 worktree 開 commit 8 跑變異，干擾復驗員在 `a3a980d` 的動態閘門約 10 分鐘；主線改以新 HEAD `b86f329` 復驗。**規則：凍結中收到任何遲到的核准或訊息，一律先回問主線，不得自行動工；主線核准連帶檔的訊息應在派工 brief 內或結案前送達，結案後的核准視為下一輪指示。**
- 可合併後補：`AutoPlayModeStoreTests.swift:14` 檔頭過時註解 → WP12；Localizable 一個無引用 key → WP12；`passChannel` 對 ron-only 走 chiPengGang 而 `sendPass` 用 `LiqiOperationType.channel` 兩套規則不一致（本包未改任一邊）→ 延後表等 live 證據；`NakiRuntime` weak-self 退路只剩 `.off` 無測試 → 延後表。

### WP9 結果（2026-10-12）
- 合併到 main：merge commit `53d173e`（`a8d2f8f` defaults 注入／`b23b71d` manifest 收斂，基準 `35e0f01`，7 檔 +401/−104）。復驗「可合併」（`.swfd/logs/wp9-verify/`）：949 → 959；合併態 main 全套見 `.swfd/logs/merge-main/test-53d173e.log`，跑前跑後真實設定檔 sha 相同（dc1ed5359702 → dc1ed5359702）。
- Deviation（核可）：規格的 `init(defaults: = .standard)` 做不到——`nonisolated init()` 不能覆寫 19 個 `@Observable` 屬性（復驗實驗證實 error）；改成另加 MainActor `init(defaults:)` 無預設值、覆蓋全部 19 個 UserDefaults 屬性（復驗逐一核對完整），直接寫備份欄位繞過 `didSet` 無副作用；正式路徑 `SettingsStore()` 行為與基底相同。
- manifest 收斂：復驗自製差異表，四條規則兩邊相同、無任何一邊放寬；對外可見變化只有 import 的 schema 訊息變長。`validate(directoryName:)` 比規格多一參數以保留 load 檢查順序。
- **事故與證據問題**：實作者第一輪變異寫了三個值到用戶真實設定檔 `~/Library/Preferences/org.39c154f25912233a.akagi.plist`（`naki.cloud.model4p`／`MajsoulExtraHeaders`／`naki.appLanguage`），已還原。但 logs 內標示「變異前快照」的檔是 23:35 事後拍的（晚於所有變異）；復驗從實作者 scratchpad 找回 23:20:12 的真實檔 SHA 指紋與副本（早於第一次變異），證實現值逐位元組相同。**規則：證據檔的時間戳必須早於它宣稱證明的事件，復驗員核對時間線；關鍵證據不得只放 scratchpad。**
- 關鍵發現（WP12 補進 CLAUDE.md 坑）：**NakiTests 的 test host 與 Naki app 共用 `.standard`，就是用戶真實設定檔**；`TEST_RUNNER_CFFIXED_USER_HOME` 隔離不了。本包三個測試檔已不再寫它，但範圍外仍有 5 處備份還原寫法（`MajsoulRequestBuilderTests:101-110`、`ToolAndModelGapTests:193-205`、`WebLayerGapTests:107-112`、`ObservedMatchSidsTests:20-28`、`NakiTests.swift:48` `pinAppLanguage` 7 處呼叫）→ **ui S2 剩餘實害，新增 WP9b（Sonnet medium，排 WP11 後）**。WP10 在 wp9 汙染時段出現停滯訊息變日文的 flaky，歸因於此。
- 可合併後補：`SettingsStore.swift:78` 註解不實（另有 10 個 `= .standard` 預設參數）→ WP9b 一併改成 `SettingsStore.standard`；m6／m8 在乾淨機器仍存活（近似等價：把預設值物化回同一 suite）→ WP9b 用計數子類補「init 期間不寫入」斷言；`Localizable.xcstrings:1396` stale key → WP12；規格閘門類別名應為 `SettingsStoreInjectionTests` → WP12；`removePersistentDomain` 不刪檔，`~/Library/Preferences` 已有 8580 個 `naki.tests.*` 空殼 plist（基底模式）＋實作者留下的 `naki.mutation.leak.plist` → 報用戶決定是否清理。

### WP10 結果（2026-10-12）
- 合併到 main：merge commit `a919a37`（`fc10cd9` D8 字串集中與 JS 契約測試／`744a1dd` sendRaw 缺模組短碼／`26c63fc` envelope 解析收進 core／`302ed1a` D9 送出登記表，基準 `35e0f01`，7 檔 +347/−165）。復驗「可合併」（`.swfd/logs/wp10-verify/`）：949 → 952；plugin-regression 23 → 29；合併態 main 全套與兩支 node 腳本見 `.swfd/logs/merge-main/test-a919a37.log`、`keepalive-a919a37.log`、`plugin-a919a37.log`。
- 同步性：三模組新增行無任何非同步寫法；遮名解析仍在建構時註冊的 listener 內同步執行。fail-open 替身只在「core 跑完但未匯出新函式」時生效，影響限遮名停擺與插件不派發，Swift 照常收封包；無新的整頁失明路徑。
- 特徵化：30 萬筆語料復驗重跑數字逐字相同；778 筆插件差異全來自 varint 統一到乘法版（位移版在 >2^31 回繞，乘法版與 BigInt 真值一致）。
- **D9 契約變更（已授權，WP12 必須同步文件）**：`ctx.isNaki` 符號不變、語意從「msgId ≥ 60000 號段猜測」改為「送出登記表 ∪ 插件號段」；`docs/plugin-api-v1.md:108`、`:204` 現已不成立；新頁面 API `__nakiWebSocket.isNakiSent` 要補記。復驗八格真值表逐格相符：修正兩格舊 bug（頁面自送 60000+ 不再被誤認 Naki）；兩格放寬——(a) 繞過 sendRaw 直接 ws.send 的送出被當遊戲證據（command/、插件 repo、用戶插件皆無此路徑，只有手動 execute_js）；(b) **溢出窗口**：Naki 送出後又經 sendRaw 送 ≥256 筆且全部往返完成、Naki 那筆回應才到 → isNaki 變 false，違反 v1:258「isNaki 流量永不給 rewrite」；判定實務不可達（需回應延遲到數百次往返之後），WP12 在 :258 註明邊界。插件 sendRequest 與 Naki 共用同一 Set，只加快門檻湊滿，不是觸發路徑。
- plugin-regression 的 `<root>` 是插件 repo 結構 `<root>/plugins/<id>/plugin.js`，App Support 目錄少一層，不能直接指過去；本輪用 `/Users/suoie/Documents/tools/coremltools/naki-plugins`（`c35e61d`）。
- 實作者 c2 一次 flaky（停滯訊息變日文）：復驗歸因 wp9 首輪變異寫 `naki.appLanguage=ja` 到真實設定檔的時間窗，字母序重跑 6 次皆過，非本包；精確寫入時刻無 log，歸因未驗證。
- 可合併後補：JSContractTests 補 `atob` polyfill 讓 Commit 4 在 Swift 側也鎖住、補涵蓋全域變數賦值（`NakiRuntime.swift:453`、`PluginRegistry.swift:291/292/347`、`NakiWebSocketScript.swift:44-45`——JS 改名會靜默失效，送出總開關落到關閉屬安全方向）、每模組載入後清 `JSContext.exception`、修 `naki-websocket.js:29` fail-open 註解 → 併入 WP9b 改名 **WP9b「測試隔離與契約加固」**；選做加固「插件號段 id 不進登記表」→ 延後表（重啟條件：live 看到插件注入量大）；v1 文件既有漂移（onSocketClose／drop／dropReceive／dropSend／rewriteSend 基底即 0 出現）→ WP12。
- 未驗證：live 一局（§6 第 12 項）；量測方法改讀剔除 ws 物件後的 `getMajsoulConnections()` 加 `isNakiSent(msgId)`。

### WP11 進行中裁決（2026-10-13）
- 復驗（`.swfd/logs/wp11-verify/`）對 `e42ce17` 裁「要修正」，兩阻擋：(A) `CloudDecisionMapper` 的 chi case 對非 MJAI 輸入（`0m` 類赤五寫法）基底回 nil 退回本地、HEAD 產出吃的列，方向 fail-open，上游 `AkagiApiClient` 不驗證 JSON 所以程式上可達；(B) 與 wp8 文字合併乾淨但語意衝突——wp8 測試用 `Recommendation(tile:"chi_N", actionType:.chi)` 期待「吃①②③」，WP11 把變體改藏在欄位後這三格退化成「吃」，實作者還為此改寫了兩條既有測試。
- **統帥代決**：(A) 在 mapper 分類前加 `majsoul(fromMJAI:) != nil` guard，不動 `LiqiTile.chiVariant`，接受集合變成基底子集（fail-closed）；(B) 選復驗方案 (a)：`Recommendation` 兩個 init 遇 `.chi` 且未傳變體時在建構邊界解一次 label，函式層行為回到基底，兩條被改寫的既有測試還原原文。理由：(a) 最接近零行為改動，且不需要 WP8 配合改測試；若選 (b) 改 wp8 測試，等於承認 Recommendation 的建構契約變了，之後所有用 label 建構 chi 的呼叫端都要跟改。
- 另補：executor `first(where: .chi)`→`first` 變異存活（正式路徑等價但無測試）→ 補測試；`LiqiTile.swift:37` 註解不準。復驗更正了主線 brief 的一個前提：基底與 HEAD 對「無變體」都是以 0 對照，規格 :318「多組且對照失敗才不送」才是正確描述，非 WP11 造成。
- 復驗附帶：`ReplayFingerprintTests` 只雜湊 bot 的 MJAI action，對 chi 路徑無覆蓋力（弱證據）；live log 無任何「執行: 吃」，chi combination 恆為兩張未驗證；test host 每跑一次會在 `~/Library/Logs/Naki` 建 session 目錄（既有行為，plist 以外的環境副作用，WP9b 一併看）；實作者與復驗員都用過系統 `python3`（違反 proto 規則，已提醒）。

### WP8 結果（2026-10-13）
- 合併到 main：merge commit `edf0841`（七個 commit `2f8369e`…`3ef11de`，基準 `1b38673`，12 檔 +653/−284）。復驗「可合併」（`.swfd/logs/wp8-verify/`）：959 → 970；macOS Debug／Release 與 iOS generic build 皆成功、警告不增；合併態 main 全套見 `.swfd/logs/merge-main/test-edf0841.log`。
- Deviation（核可）：Preview 的 `logManager`／`jsInjection`／`parseFault` 不用新實例，改為 private optional 備份欄位＋計算屬性 `injected ?? .shared`。復驗重現：nonisolated Preview init 直接取 `.shared` 或呼叫 MainActor init 會多三條警告（Swift 6 模式變 error），消除需在範圍外 `LiqiParseFault.swift` 補 `nonisolated init`。副作用判定：兩個 state 的 init 是純值；`LogManager.shared` 首次存取會建 `~/Library/Logs/Naki` session 目錄並 prune，但基底 View 早已觸發同一件事，非回歸。Observation 追蹤依賴建立在解析出的實例上，橫幅仍會重繪（推理，未 runtime 驗證）。若日後要新實例：兩個 class 各補 `nonisolated init() {}`（`PluginStore` 有先例）。
- 唯一正式路徙語意差異（核可記錄）：`DismissUpdate(skip:)` 改在點擊當下讀 `availableUpdate?.version`，原為 body 求值時捕捉。只在「選單手動檢查更新在橫幅顯示期間完成、GitHub 恰好發新版、點擊落在重繪前的窗口」才不同；舊碼記使用者看到的版本較貼近語意。可達但極窄，兩條測試鎖值與順序。
- revert 依賴：`fc97077` → `f3a34b5` → `3ef11de` 線性堆疊（LogPanel 的 `@Environment` 在 `fc97077` 引入），偏離「每項可獨立 revert」，成組 revert 即可，已揭露。
- 與 WP11：文字合併乾淨；對舊 `e42ce17` 有語意衝突（復驗實測三格「吃」≠「吃①②③」），WP11 補強 `d8abb30` 後消解（復驗實測綠）。**WP11 必須以 `a15950f` 或之後版本合併，若 `d8abb30` 被撤則 wp8 測試三個 chi case 要補 `chiVariant:`。**
- 可合併後補 → WP9b：lint 補規格 grep 的四個名稱（`fetchAny` 等）並斷言掃到行數 > 0（V10 不帶點 `shared`、V11 直呼 `fetchAny` 存活；目錄不存在時會空轉通過）；`NakiRuntime` 三條 Action 接線無鎖（V16 把 `clearLogs` 換 no-op 12 條全綠）；`NakiEnvironment.swift:96-101` 註解仍寫「全新的空 store」→ WP12。
- 程序備註：復驗員自報一次短暫寫 /tmp scratchpad（10 秒內刪除）；兩位都新增 `naki.tests.wp8.*` suite plist 共 7 個（`removePersistentDomain` 不刪檔，既有模式）。

### WP11 結果（2026-10-13）
- 合併到 main：merge commit `4f7ab10`（`f4a4b87`／`c9422fd`／`e42ce17` 原三項＋補強 `de9ce16` 雲端 chi MJAI guard／`d8abb30` 建構邊界解 label／`a15950f` executor 選列測試與註解，基準 `a787989`）。兩輪復驗（`.swfd/logs/wp11-verify/`），第二輪「可合併」：962 → 985；合併態 main（含 WP8）全套見 `.swfd/logs/merge-main/test-4f7ab10.log`，WP8 的 chi 斷言在合併態綠。
- 兩阻擋項關閉：(A) guard 接受集合恰為 37 張合法 MJAI 牌，該集合上新舊分類已由窮舉證明相同，所以修後接受集合是基底子集；`0m` 類輸入回到基底 nil；`4z·5z`／`1z·2z`／`5·6·7`／`5x` 四組基底會產出吃的列、現在退回本地（fail-closed，兩組入測）。端到端測試斷言打過雲端且 `source == "local"`。(B) 三個 init 共用 `parsedChiVariant`，明確傳入值優先；兩條被改寫的既有測試還原原文；對 wp8 `3ef11de` 與 main 三個版本試合皆 exit 0。
- 六筆第二輪變異全殺（R1–R6）。
- 殘餘（記錄，非阻擋）：`WebSession.syncHighlight` 的 `top.chiVariant ?? 0` 無測試鎖（WebSession 無注入縫；差異限 DebugServer 注入或 Preview 的 `chi_x` 與插件高亮 context）→ 延後表；「chi combination 恆為兩張」需 live 確認（`LiqiOperationStore.swift:23` 自註待驗，live log 無任何「執行: 吃」）→ 整合驗收；`replay-check.sh` 未驗證；`ReplayFingerprintTests` 對 chi 路徑無覆蓋力。
- 程序備註：第一輪實作者用系統 python3 寫探針（proto 違規），第二輪已改 shell；notes 一處「test-final.log」應為 test-final2.log（WP12 不管，屬 log 內部）。

### WP9b 結果（2026-10-13）
- 合併到 main：merge commit `d1e9775`（九個 commit `a2ba756`…`10545ea`，基準 `3852d7b`，13 檔 +246/−55）。復驗「可合併」（`.swfd/logs/wp9b-verify/`）：973 → 979；合併態 main 全套與 node 兩腳本見 `.swfd/logs/merge-main/test-d1e9775.log`、`keepalive-d1e9775.log`、`plugin-d1e9775.log`；合併態跑前跑後真實設定檔 sha dc1ed5359702 → dc1ed5359702、mtime 1791828234 → 1791828674。
- 正式路徑零行為改動（復驗逐 hunk）：十個預設參數等價改寫；`L10n.defaults` 為 `nonisolated(unsafe) static var`，正式碼無寫入點；`ObservedMatchSids.redirect` 只在 DEBUG；JS 兩行註解屬實。
- 驗收本體：全套測試對真實設定檔的 mtime 變動基底 ≥3 次 → HEAD 1 次（sha 全程不變）；跳過 `BotToolsTests/testSetAutoPlayModeDegradeKeepsNoticeAndPersistsClampedMode` 後 0 次。復驗以 `defaults` CLI 實驗證實同值 `set` 不碰檔（奈秒 mtime 不變），所以「mtime 變、sha 不變」= 寫入不同值後寫回。
- **新發現（WP12 補進 CLAUDE.md 坑）**：test host 就是 App 本體，`NakiApp.swift:17` 的 `@State runtime = NakiRuntime()` 在任何 setUp 前就跑 `adoptStoredAutoPlayMode` 對 `.standard` 做同值寫入；本機 key 已存在所以看不到，**沒有 `naki.autoPlayMode` 的乾淨機器上任何一次測試執行都會新建此 key**（基底即有，WP9b 範圍外）。
- 剩餘寫入者三處：`BotToolsTests:79`（走 `AutoPlayAvailability.commit` 的 `.standard` 預設）、六條建構正式 `NakiRuntime()` 的測試（BotTools 3＋新 `NakiRuntimeWiringTests` 3，同值）、host 啟動（同值）。
- **統帥代決**：開 **WP9c**（Sonnet medium，極小）只做復驗估算的 A 塊——`AutoPlayModeStore` 加與 `L10n.defaults` 同型注入點、`AutoPlayMode.swift` 四個預設參數改取它、`BotToolsTests` 與 `NakiRuntimeWiringTests` 換隔離 suite，目標是全套 mtime 變動 0 次。B 塊（host 啟動同值寫入）**不做**→ 延後表：解法需改正式碼（`commit` 同值跳過或 test host 不持久化），對用戶可觀察行為等價但屬為測試衛生改正式路徑，重啟條件：在乾淨 CI 機器跑測試時。C 塊（鎖 `dismissUpdate(skip:true)`）→ 延後表，與 arch S12「`LiqiResponseStore` 注入」同類，重啟條件相同。
- 證據紀律缺口（記錄）：實作者 `probe/*.log` 只有 xcodebuild 輸出、無 mtime 讀數；`test-noBT` 在 `10545ea` 之前跑（該 commit 只改測試檔，復驗已在 HEAD 補跑）。
- 環境：`~/Library/Preferences` 的 `naki.tests.*` 空殼 plist 已達 10273 個（本輪各包累積），待用戶決定清理；全套期間 test host 短暫監聽 55054–55056（推測 `DebugServerFramingTests`，未逐條歸因）。
- **WP12 啟動裁決**：WP12 與 WP9c 平行開。WP9c 只動 `AutoPlayMode.swift` 四行與兩個測試檔，對文件行號影響可忽略。WP7d（U1）仍無 1306 證據：WP12 依現狀（matchGame 鏈仍在、tools 43 個）寫文件；WP7d 若日後執行，由它自行更新文件與工具數。
