# Naki 當前驗證報告

**驗證日期**：2026-08-01

**程式基準**：`main`，盤點起點 `7de0a04` 加目前工作樹

**完整技術基準**：[docs/majsoul-unity-protocol.md](docs/majsoul-unity-protocol.md)

本檔只保留目前仍成立的驗證結果與差距，不保存歷次遷移、除錯或已被推翻的結論。

## 結論

Naki 的 Unity WebSocket → Liqi → MortalSwift → Liqi sender 主鏈已存在，四麻 observation／mask fixtures 與 resolver 純邏輯也有測試。兩個可直接造成漏和的整合漏洞在 source 層已收斂，並自 2026-08-02 起有注入式 fixture 逐條驗（§15.5）；但「能自摸時必定自摸」的**端到端**驗收仍未完成——那條路要 live 對局才走得到。因此不能宣稱問題已完全修復，也不能把目前 bundled 權重稱為最新最強模型。

## 已驗證

| 項目 | 證據 | 結果 |
|------|------|------|
| 客戶端 | live Naki `/js` 唯讀 probe | Unity WebGL 4.0.45；Laya／DesktopMgr／uiscript 不存在 |
| Debug API | live `/status`、`/bot/status`、`/game/*` | loopback server 與 Swift protocol state 可用 |
| MCP registry | live `tools/list`（2026-08-01） | 42 tools；含 6 個已於 2026-08-02 移除的 highlight 失敗樁，移除後靜態計數 38，**未 live 複查** |
| Liqi schema | live manifest fresh download + byte compare | repo `liqi.json` 與 CDN 完全相同 |
| config | live manifest fresh download + repo parser | 41 tables／263 sheets／119,289 rows |
| Mortal parity | fresh Debug／Release tests | 各 47 tests 通過；固定 fixtures obs／mask 零落差 |
| Naki unit tests | fresh NakiTests（2026-08-02 Debug，`-derivedDataPath /tmp/naki-wf-dd`） | 218 tests 通過；resolver 專項 13、fail-safe fixture 10、log／版本／endpoint 單一來源 13 |
| runtime ron | request／response／ActionHule trace | type 9 走 `inputOperation` 成功 |
| runtime pon | request／response／ActionChiPengGang trace | type 3 走 `inputChiPengGang` 成功 |
| WebGL hook | live `__nakiHighlight.state()` | hook 與染色分支有執行 |

## 已確認差距

### P0：自摸 resolver 仍可能不被呼叫（source 已收斂，live 未驗證）

原始差距：`AutoPlayDecisionResolver` 本身會讓 server oplist 的 tsumo／ron 凌駕 AI，但 `WebViewModel` 以 Mortal recommendation 是否非空作為進入自動動作的條件；空推薦時 timer 只補副露 pass。結果是 server 即使給 type 8，只要 Mortal 回空推薦就可能完全不進 resolver。

現況：1 秒輪詢改走 `AutoPlayGate`，空推薦 ＋ `snapshot.horaOperation != nil` 回 `.forceHora`，`triggerAutoPlayNow(forcedAction: .hora)` 不受「無推薦就不觸發」限制。

機械驗收（2026-08-02）：`NakiTests/AutoPlayFailsafeFixtureTests` 的 fixture A（空推薦 ＋ oplist `[8]`）與 D（老化 3 秒的 `[3,9]`）以注入的 oplist 走完 gate → resolver → sender，斷言送出的 bytes 是 `12020808`／`12020809`。實跑 mutation：拿掉 gate 的 `forceHora` 分支 → A、B、B'、D 四個測試轉紅。
**仍未驗證**：live 對局沒有出現過這個分支（§15.4：兩次和牌模型都給 `hora@99.6%` 以上）。

### P0：hora send 失敗仍可能被標成完成（source 已收斂，live 未驗證）

原始差距：外層在呼叫 sender 後，只看 resolved action 是 `.hora` 就 `markHandled`，沒有拿到實際 `LiqiSendResult`；沒有 game-gateway、JS send 失敗或 server 拒絕時，pending opportunity 會被吃掉且不重試。

現況：`executeAutoPlayAction` 回傳 `LiqiSendResult?`，只有 `success == true` 才 `markSnapshotHandled`；和牌失敗走 bounded retry（15 次 × 0.2 秒），用完仍不標記。

機械驗收（2026-08-02）：fixture B（第 1 次 `no_open_majsoul_connection`、第 2 次成功）斷言重試期間看到的 oplist 序號沒變、成功後才 `pending == nil`；fixture B'（一路失敗）斷言 3 次用完後 `pending` 仍在，且通道恢復後同一批 oplist 還能送成功。實跑 mutation：把 `markHandled` 搬到送出之前 → B、B' 轉紅。
**這個 mutation 動的是測試 harness，不是 `WebViewModel`**：正式的「成功才 `markHandled`」寫在 `WebViewModel.executeAutoPlayAction` 裡，測試建不出 `WebViewModel`，所以鎖住的是語意規格而不是那幾行 source（p2-1 抽出 executor 後才能直接鎖）。
**仍未驗證**：live 對局沒有出現過 send 失敗（§15.4：兩次都是第 1 次就成功）。

### P0：Legacy iOS 沒有 server-authoritative 保護

iOS 17–25 的 `LegacyWebViewModel` 直接使用 AI 第一推薦，沒有 resolver、oplist action 檢查、seat check、stale check 或 fail-closed。新舊路徑功能不一致。

手動 MCP／HTTP `game_action(action=hora)` 另有相同類型的缺口：沒有 oplist snapshot 時目前會猜 tsumo，應改成 fail closed。

### 已處理：off mode 的顯示語意（2026-08-02）

`.off` 現在同時關掉顯示：`RecommendationView` 讀 `autoPlayMode.showRecommendation`，關閉時顯示「推薦顯示已關閉」；`GameHighlightScript.make()` 在 `.off` 一律回 `__nakiHighlight.clear()`，切回 `.recommend`／`.auto` 恢復染色。`setAutoPlayMode` 會立刻重推一次，不必等下一個 Bot 回應。AI 仍在背景計算（刻意：否則切回來是空白）。

腳本內容有 7 條單測（`GameHighlightScriptTests`）。**畫面上真的清空／恢復未 live 驗證**——WebGL hook 沒有 screenshot regression。

### 已處理：其他 failure path 不再過早消化 snapshot

`WebPage` 路徑（`WebViewModel`）三條路徑已改成「沒送出去就不消化 oplist」：

- 空推薦的副露 pass 改由 `AutoPassDispatcher` 送出，只有 `LiqiSendResult.success == true` 才 `markHandled`；失敗保留 pending、bounded retry（5 次 × 0.2 秒），用完次數仍不標記，留給 1 秒輪詢的下一輪。送出期間佔用 `currentExecutionId` 當互斥，避免同一批 oplist 被送兩次過。
- 打牌字串轉換失敗、立直找不到宣言牌：只 log，不 `markHandled`。

機械驗收：`NakiTests/AutoPassDispatcherTests`（7 tests，含「先 mark 再送」的 mutation 會讓 4 個測試轉紅）。
**仍未驗證**：live 對局的副露 pass 行為、以及送出失敗時實際的重試節奏。

### P1：模型版本宣稱過度

- 本機 resolve 到 MortalSwift 0.5.0，但 package requirement 是 `[0.5.0,0.6.0)`，lockfile 又未提交。
- 0.5.0 修的是 encoder／計算與 parity；bundled model blobs 沒換。
- 沒有大規模實戰 benchmark。

正確說法是「目前使用 MortalSwift 0.5.0 的 encoder/parity 修正版」；不能說「已換最新最強權重」。

### P1：三麻沒有專用模型（2026-08-02 改為 fail-closed）

`is3P` 只改 Naki 狀態與標籤；推論仍建立同一個 Mortal v4 四麻 model。三麻不應宣稱支援。

2026-08-02 起（MortalSwift p3-1「不做」路線的驗收項）：

- **自動送出在三麻一律停用**，三層 fail-closed：`AutoPlayGate`（1 秒輪詢，含**繞過 resolver 的
  `.sendPass`** 那條路）、`AutoPlayDecisionResolver`（`.auto` 降級成 `.recommend`）、
  `WebViewModel.triggerAutoPlayNow`（手動／MCP `bot_trigger` 入口）。
- **UI 明示**：`BotStatusView` 的 `SanmaUnsupportedNotice` 顯示
  「三麻不支援：內建只有四麻模型，推薦結果無效；自動打牌已停用。」
  模型標籤仍是 `Mortal (4P) ⚠️ 三麻無專用模型`。

單元測試覆蓋三層 fail-closed（gate 4 條、resolver 4 條）。**沒有 live 三麻對局驗證**。

### 已處理：可用動作六欄不再恆 false（2026-08-02）

`canDiscard/canRiichi/canChi/canPon/canKan/canAgari` 的唯一寫入點曾是零呼叫的
`NativeBotController.updateAvailableActions()`（`updateInternalState` 尾巴只留了
「移到 react() 後處理」的註解），所以 `BotStatusView` 六個徽章與 `/bot/status` 六個欄位永遠 false。

現在改為協定層 oplist 的投影（`BotAvailableActions(snapshot:)` 讀 `LiqiOperationStore.pending`）：
權威與送出端（`AutoPlayGate` / resolver / sender）一致，不會出現「徽章亮著但送不出去」。
`updateAvailableActions()` 與同樣無人讀的 `lastCandidates` 一併移除。

單元測試 10 條（`BotAvailableActionsTests`，含 controller 與 `GameStateManager` 兩層）。
**沒有 live `/bot/status` 複查**——需要對局中的 oplist。

### 已處理：MCP 6 個 highlight 失敗樁已移除（2026-08-02）

`highlight_tile` / `reset_tile_color` / `highlight_status` / `highlight_settings` /
`show_recommendations` / `hide_highlight` 直接移除（呼叫回 `Unknown tool`）。
它們的參數契約源自 Laya 牌物件、從未接到 `__nakiHighlight`，且有明確替代面
（`bot_status` / `game_hand` 讀推薦；內建高亮由 `syncGameHighlight()` 驅動）。
靜態註冊數 44 → 38。**live `tools/list` 未複查**。

### 已處理：無效 UI 控制已移除

位置校準、推薦溫度、旋轉 Laya 高亮與隱藏玩家名稱四組控制都已從 UI 移除。
底層名稱 API 仍依賴 live 已確認不存在的 `uiscript`，所以不可重新掛回 UI；若要恢復功能，必須另做真正的 Unity 實作。

### P1：遊戲內高亮只有活性證據

現行 `__nakiHighlight` 會攔 WebGL draw 並執行 tint，但尚未用 screenshot／視覺測試證明每次命中正確牌或按鈕。同名牌全染與 popup heuristic 是已知風險。目前工作樹另有字牌 UV 索引修正與「其餘手牌帶 alpha 調淡」變更，兩者都仍屬未提交、未做視覺回歸的 candidate。

## 正確修正順序

1. 以 oplist arrival 驅動 resolver，先處理 hora，不依賴 recommendation。
2. 讓 action execution 回傳結果；hora 只有在 send 成功，最好收到同 msgId RESPONSE／權威 action 後才 handled。
3. 對失敗保留 pending、bounded retry、sequence guard 與明確錯誤 log。
4. Legacy 共用同一 resolver／sender，或在完成前禁用 Legacy 自動模式。
5. 建立端到端 fixture：AI discard + server tsumo、空推薦 + tsumo、send failure、server reject、stale snapshot、recommend/off。
6. 固定 MortalSwift dependency，再做千局級牌力評估；不要用 package 版本代替模型強度證據。

## 未驗證

- 最新 source 在「AI 想 discard、server 有 tsumo」情境能否穩定 override 並收到 `ActionHule`（決策層已有 fixture C，live 仍缺）。
- 空 recommendation + tsumo 的 live 重現（fixture A 已覆蓋決策層）。
- server reject（送出成功但伺服器不接受）／中斷 cleanup；send failure 只有 fixture B／B' 的注入版本。
- Legacy iOS 17–25 實機完整對局。
- chi variants、赤五 combination、ankan／minkan／kakan。
- WebGL 高亮與 action popup 的視覺正確性（含 `.off` 是否真的在畫面上清空、切回是否恢復）。
- 三麻對局的 fail-closed 行為（只有單測）。
- 移除 6 個 highlight 工具後的 live `tools/list` 數量。
- `/bot/status` 六個 canXxx 在 live 對局中的真值。
- 持紅五（mask 34–36）時能否正常打出。
- AI 相對其他模型的實戰強度。

## 驗證環境與副作用

- Fresh app-hosted tests 曾初始化共用 temp `LogManager`，使當時正在執行的 Naki 日誌發生一次 rotation；最舊的一份歷史 rotation 可能因此被擠掉。
- 最後以 live `/status` 加 process file descriptor 重查：目前 Naki PID 寫入的檔案已與 `/status` 回傳的 `akagi_websocket.log` 相同，active-log mismatch 已解除。
- 最後 build 使用獨立 `/tmp/naki-doc-build.*` DerivedData，結束後已清除；沒有啟動或停止 Naki。

## 完成判準

只有在下列條件同時成立後，才可對外寫「漏自摸已修復」：

- source 層兩個 P0 integration gap 已消失。（2026-08-02：source 已收斂，見上面兩節）
- resolver／integration tests 覆蓋上述正常與 failure paths。（2026-08-02：決策層已覆蓋 §15.5；`WebViewModel` 的重試框架本體仍只有註解與 log）
- 測試帳號 live 對局重現原始 `[discard, riichi, tsumo] + AI discard` 情境。（仍未做）
- log 顯示 resolver 選 hora、送到 game-gateway、同 msgId 成功 RESPONSE，並收到 `ActionHule`。
- 測試後沒有 stale pending、重複 request、殘留 process 或非預期帳號操作。

---

## 14. 高亮、日誌與副露後推薦（2026-08-01 live 對局實測）

本節的每一條都由**執行中的 Naki** 驗出，不是讀 code 推論。

### 14.1 字牌高亮會染錯牌

`naki-core.js` 的 `tileFromST` 在字牌分支寫的是 `Math.round(u * 10) - 1`。

live 對局取樣（手牌 `E W W P C`，`count===6` 的 `_MainTex_ST`）：

| `u` | 次數 | 應為 | 原本算成 |
|-----|-----:|------|---------|
| 0 | 37 | E | null |
| 0.2 | **74** | W（兩張） | S |
| 0.4 | 37 | P | N |
| 0.6 | 37 | C | F |

數牌（`v` = 0.5/0.25/0.75）全部正確，3m 出現 74 次正好對應手上兩張。
**問題不是解不出來，是解成別張。** 推薦打 `E` 時會去染 `S`。已移除那個 `-1`。

> 探測時踩過的坑：`hlslcc_mtx4x4unity_ObjectToWorld[0]` 只回矩陣第一欄，
> 位移在 `[3]`。用 `[0]` 取位置會拿到一組看起來合理但無意義的數字。

### 14.2 牌的 shader 還有沒用到的參數

`count===606`（牌的 3D 本體，與高亮用的 `count===6` 是不同 program）：

```
_MainTex_ST  _TileTex_ST  _SplitThreshold
_ColorLight  _ColorUnlight  _Tint  _WorldSpaceLightPos0
hlslcc_mtx4x4unity_ObjectToWorld / WorldToObject / MatrixVP
```

`_ColorLight` / `_ColorUnlight` / `_SplitThreshold` 代表牌的受光面與背光面是分開的，
可做比整張染色更細緻的效果。**尚未使用。**

（先前推測 `_AlphaScale` / `_AlbedoIntensity` 也在牌上——**推測錯誤**，
那兩個屬於別的 shader program。）

### 14.3 副露彈出面板的判準換掉了

原本：「出現頻率 < 25% 的 draw 就當成按鈕」。
實測結果是**整個畫面被染色**——動畫、特效、過場 UI 全都是低頻的。

改為**基準線比對**：沒有副露機會時持續收集 draw 簽章當基準，
有機會時只染基準線裡沒出現過的。按鈕是「機會出現才有」的東西，
這個判準比頻率精確得多。實測基準線約 54 個簽章即穩定。

### 14.4 日誌分級與分檔

先前所有東西寫進同一個檔，而 LiqiParser 每解一個 protobuf 欄位就寫一行。
實測比例：

| 檔案 | 大小 |
|------|-----:|
| `naki-events.log`（對局時間軸） | 1.4 KB |
| `akagi_websocket.log`（合併，已排除 trace） | 43 KB |
| `naki-liqi.log`（解析細節） | **191 KB** |

要回答「剛剛有沒有出現過和牌機會」得靠 grep 才找得到。現在 `tail naki-events.log`
就看得完。分級為 `trace` / `info` / `event`，各類別另有完整檔案。

同時修掉一個重複：`DebugServer.log` 自己加時間戳後又透過 `onLog` 送進 `bridgeLog`
再加一次，檔案裡變成 `[ts] [Bridge] [ts] 訊息`，且同一件事出現兩行。

**2026-08-02 後續**：檔案那份修好了，但 `/logs` 那份沒有——`DebugServer` 仍保留自己的
`logBuffer`，`get_logs` 把它與 `LogManager.entries` 合併再用**字典序** `.sorted()`，
所以每條 DebugServer 訊息在 `/logs` 出現兩次。現已刪掉 `logBuffer`：`DebugServer.log()`
只寫 LogManager，`onLog` 改名 `onStatusMessage` 並只更新 UI；`/logs` 走
`LogManager.recentLogLines()`，依 `timestamp`（毫秒）排序。`liqiSender.logHandler`
兩處原本 `addLog` 與 `bridgeLog` 都寫，也收斂成一條。
單測涵蓋排序與單行；**「live `/logs` 同一事件只出現一次」未 live 複查**。

### 14.5 副露後的推薦是假的

**這是「有時候不會丟最推薦的牌」的真正原因。**

```
bot.react returned nil (no action needed)
自己碰/吃後，需要選擇打牌
updateRecommendationsFromCurrentMask: mask has 9 valid actions
Using uniform probabilities for 9 actions      ← 均勻分布
Generated 8 recommendations after meld
→ 自動檢查: discard-4m
```

MJAI 協定在自己吃／碰／槓之後不會再送事件要你打牌，`bot.react` 回 nil。
為了不讓對局卡住，程式改從 action mask 生推薦——但那是**均勻機率**，
等於「拿 mask 裡第一個合法的牌」，完全沒有經過模型。

| 情境 | 推薦來源 |
|------|---------|
| 摸牌後打牌 | Mortal 真的推論（機率有差異） |
| **吃／碰／槓之後** | **均勻分布，等於沒推論** |

**影響比 §12 的兩個 P0 更大**：P0 要撞到和牌機會才觸發，這個每次副露都會發生。
而且側欄顯示得與真推薦一模一樣，使用者看不出差別——正是 §13 要防的那類問題。

修法與驗收見 task #6。**在修好之前，副露後的推薦不應被當成 AI 判斷。**

## 15. 本輪修正（2026-08-01）

### 15.1 §14.5 副露後假推薦 — 已修

`MortalSwift 0.5.1` 加了 `inferCurrentState()`：直接用當前 state 編 observation
與 mask 跑一次推論，不需要有 MJAI 事件觸發。`NativeBotController` 的
`updateRecommendationsFromCurrentMask` 改呼叫它。

均勻分布的路徑沒有刪掉，但降級成**只有推論真的失敗才走**，而且會留下明確警告——
以前它是正常路徑且靜默，那才是問題所在。

**驗收**：event log 出現 `[Bot] 副露後推論:` 而不是 `退回均勻分布`。
需要一次真實的吃／碰。**未 live 驗證。**

### 15.2 Legacy path 接上 resolver — 已修

`LegacyWebViewModel.triggerAutoPlayNow` 以前直接送 `recommendations.first`：
沒有 oplist 合法性檢查、沒有座位檢查、沒有過期檢查、沒有 fail-closed。
也就是說「伺服器說可以自摸但 AI 想打牌」時，它會忠實把和牌牌打掉——
那正是主路徑用 resolver 擋住的情況。

現在兩條路共用 `AutoPlayDecisionResolver` + 送出前的 stale 檢查，
並補上「oplist 有和牌但模型無推薦 → 仍交給 resolver」的閘門。

剩下的差異是**重試**：主路徑 hora send 失敗會重試，Legacy 送一次就結束。
這是刻意保留的——Legacy 是舊 WKWebView，不想在沒有 live 驗證的路徑上加重試迴圈。

**未 live 驗證**：macOS deployment target 是 26，本機跑不到 Legacy。

### 15.3 隱藏玩家名稱 — 用協定層重做

舊實作靠 `uiscript.UI_DesktopInfo`，Unity 客戶端沒有這東西（§13）。
新實作在 `naki-websocket.js`：`message` listener 在 WebSocket 建構當下註冊，
一定排在遊戲自己的 handler 前面，而 `event.data` 的 ArrayBuffer 是同一份記憶體，
就地改 bytes 遊戲就會讀到改過的內容。

**等長覆寫是硬性條件。** protobuf string 前面有 varint 長度前綴，改長度就得
連動外層每一層 nested message 的長度，一路錯到底。等長則完全不碰結構，
最壞情況只是名字變成怪字串，不會讓遊戲解析爆掉。

範圍刻意收窄到 `.lq.FastTest.authGame` 的 RESPONSE（`ResAuthGame.players` /
`.robots` 的 `PlayerGameView.nickname`），因為名牌是在那裡設定的。解析中途
遇到看不懂的東西一律 return、維持原狀——fail-open 成「名字照常顯示」，
而不是 fail 成壞封包。

**已驗證（node 合成 frame）**：長度不變、關閉時 bytes 完全不動、非 authGame
的 RESPONSE 不動、垃圾 bytes 不丟例外、短名字降級成 `P1` 而非截斷成 `Pl`。

**已知限制（不是 bug，是範圍）**：
- 斷線重連走 `syncGame`／`ResEnterGame`，不在範圍內。
- 終局結算走 `NotifyGameEndResult`，不在範圍內。
- 對局中途才打開不會生效——名牌在 authGame 當下就畫好了。

**未 live 驗證**：沒有實際對局確認名牌真的變成 Player 1–4。

### 15.4 live 驗證結果（2026-08-01 17:46–17:57，人機場）

`naki-events.log` 的實際紀錄，不是推論：

| 項目 | 證據 | 結論 |
|------|------|------|
| 副露後真推論 | `17:48:58` 8 動作 → 43.1/40.4/12.4/0.1/0.0/0.0；`17:56:50` 7 動作 → 91.8/8.0/0.1/0/0/0 | ✅ 均勻分布會是 12.5%／14.3%，實測明顯非均勻 |
| 副露後送出閉環 | `17:56:50` ActionChiPengGang → 推論 → `17:56:51` `ops=[1] → discard` | ✅ |
| 自摸 | `17:53:16` `types=[8]` → hora@99.7% → `✅ 已宣告和牌` → `end_kyoku` | ✅ 三層成功都到齊（送出／宣告／權威 action） |
| 榮和 | `17:57:28` `types=[3,9]` → hora@99.6% → `✅ 已宣告和牌` | ✅ |
| 立直 | `17:52:18` `types=[1,7]` → riichi@37.2% → 送出 | ✅ |
| 暱稱改寫觸發 | `getStatus()` 回 `maskedFields: 4` | ✅ 改寫有執行；**畫面顯示未確認** |

**兩個 P0 的分支都沒有被執行。** 這不是失敗，是它們的本質——它們是 fail-safe：

- P0-1 需要「推薦為空 + oplist 有和牌」。實測兩次和牌，模型都給了 `hora@99.6%` 以上，推薦不是空的。
- P0-2 需要 hora send 失敗。兩次都是第 1 次嘗試就成功。

**所以「漏自摸已修復」仍然只能說到「正常路徑已驗證」。** CLAUDE.md 要求的那個
fixture（server `[1,7,8]` + **AI 想 discard** → resolver 覆蓋成 hora）沒有出現，
因為模型自己就選了和牌，從頭到尾沒有分歧。防守程式碼要靠正常對局驗證，本來就是
矛盾的——真要驗只能注入假 oplist，那是另一件事。

### 15.5 兩個 P0 分支的注入式驗收（2026-08-02）

上一段講的「另一件事」已經做了：`NakiTests/AutoPlayFailsafeFixtureTests`（10 tests）
用注入的 oplist ／推薦，讓兩個分支第一次真的被執行。

| fixture | 前提 | 斷言 |
|---------|------|------|
| A | 空推薦 ＋ oplist `[8]` | gate `.forceHora` → resolver hora → 送出 bytes 結尾 `12020808`、成功後才 `markHandled` |
| B | hora send 第 1 次失敗、第 2 次成功 | 重試期間 oplist 序號不變、成功後才消化、失敗原因進 log |
| B' | hora send 一路失敗 | 用完 3 次仍 `pending`，通道恢復後同一批還能送成功 |
| C | server `[1,7,8]` ＋ AI `discard@87%` | resolver 覆蓋成 hora，送出的是自摸不是打牌，log 有「決策覆蓋」 |
| D / D' | 老化 3 秒的 `[3,9]` ／ `[3]` | 有和牌就和（`12020809`）、沒有才送過（`12021801`） |
| E | 推薦由 `NativeBotController` 注入 | 模型輸出 → 決策層這一段接得起來 |

注入入口（`LiqiOperationStore.injectForTesting`、`NativeBotController.injectRecommendationsForTesting`）
都在 `#if DEBUG` 內；Release binary 用 `nm` 查為 0 個符號，Debug dylib 有 4 個。

**NakiTests 沒有 Release 版**：`ENABLE_TESTABILITY = YES` 只設在 Debug config，
`xcodebuild test -configuration Release` 會停在 `Unable to find module dependency: 'Naki'`
（`@testable import` 需要 testability）。這是既有專案設定，不是本次改動造成的；
Release 能驗的是 `xcodebuild build -configuration Release` 成功（已跑）＋ 上面的符號檢查。

**這些走的是 `AutoPlayFailsafePipeline`（測試 harness），不是 `WebViewModel` 本體**：
證明的是 gate → resolver → sender → markHandled 這條組合的語意，不含 asyncAfter 延遲、
去抖與 `currentExecutionId` 互斥。CLAUDE.md 要求的 live fixture
（RESPONSE → `ActionHule`）**仍未驗證**。

仍未驗證：P0-1／P0-2 的 live 重現、Legacy 路徑（macOS 跑不到）、暱稱在畫面上的實際顯示、
非推薦牌透明度的視覺結果。

## 16. Soak test 與截圖（2026-08-01）

### 16.1 `/screenshot`：為什麼是 `cacheDisplay`

`GET /screenshot` 回整個視窗的 PNG（Naki 側欄 + 遊戲畫面）。

試過三條路，兩條淘汰：

| 做法 | 淘汰原因 |
|------|---------|
| OS `screencapture` | 要「螢幕錄製」權限（實測直接 `could not create image from display`），而且視窗被遮住／在其他 Space／最小化就拍不到 |
| `cacheDisplay` + `WebPage.exported(as:.image())` 合成 | 多餘。而且 web 影像的 frame 與底圖對不齊，畫面底部出現重複的功能列；`exported` 在 macOS 回的是 **TIFF** 不是 PNG |
| **`contentView.cacheDisplay`** | ✅ macOS 26 上就抓得到 WKWebView 內容 |

合成那條是為了防「WKWebView 跨 process 渲染、`cacheDisplay` 抓不到」。那個顧慮在 macOS 26 不成立——`?mode=view` 拍到的載入畫面可證。**先驗證前提再決定架構，不要為想像中的問題預先加層。**

### 16.2 兩支測試腳本

- `scripts/soak-test.sh` — 連續跑 N 局、自動開局、逐局收集異常
- `scripts/action-shots.sh` — 輪到自己 / 出現錯誤時自動截圖

`action-shots` 截「推薦產生的當下」而不是送出之後：自動打牌會等 1.0–1.9 秒才送，那段時間正是高亮與半透明在畫面上的樣子，送出後牌已經打掉了。同時 tail events 與 bridge 兩個 log——`❌`、`時發生錯誤` 只在 bridge，`均勻分布`、`決策覆蓋` 只在 events，只看一個會漏一半。存 JPEG 而非 PNG：全解析度 PNG 一張 4 MB，一局 80 手 × 10 局 = 3 GB。

`soak-test` 用 log marker（`[消費者] start_game` / `end_game`）判斷局的邊界，不用 `/game/state` 的 `inGame`——後者對局結束後不會歸位（§16.4），拿它判斷會永遠卡在 true。

### 16.3 sendRaw 選錯 socket（已修）

```javascript
const conn = pick.length > 0 ? pick[pick.length - 1] : conns[0];
```

雀魂會同時開兩條 `/gateway`，但 `oauth2Login` 只在其中一條做過。`pick.length - 1` 照**建立順序**取最後一條，剛好選中沒登入的那條，伺服器回 error 1004。

影響範圍不只匹配——**所有 lobby 請求都會中獎**，連唯讀的 `fetchAccountInfo` 也失敗，機率取決於哪條 socket 後建立。而且它靜默：JS 回報 `success: true`（bytes 確實送出去了），要挖到 RESPONSE 的 `field1` base64 解出 1004 才看得到。

改成選「**最近收到過伺服器訊息**」的那條——伺服器只會在活著的 session 上推訊息，這是有事實根據的訊號，不是猜建立順序。平手才退回原順序。

### 16.4 `match_mode` 對照表整組是錯的

`lobby_match_modes` 的數值來自 Laya 時代的觀察，從未以真實封包驗證。實際攔到遊戲自己送的 `.lq.Lobby.fetchCurrentMatchInfo`，銅之間畫面輪詢的是 `[2, 3, 17, 18]`：

| 入口 | 真實值 | 舊表 |
|------|-------|------|
| 銅之間 四人東 | **2** | 1 ❌ |
| 銅之間 四人南 | **3** | 2 ❌ |
| 銅之間 三人東 | 17 | 缺 |
| 銅之間 三人南 | 18 | 缺 |

整組偏移一格。送舊表的值伺服器回 1306。

已把 warning 改成明講這張表是錯的，並**移除 mode 白名單**——白名單本身就是錯的，會擋掉正確值，比不擋更糟；合法性交給伺服器判斷。其他房間的正確值尚未攔到，標明不要照用。

**一個被推翻的推論**：先前判斷「銅之間是初心專用房、雀士1 進不去」是錯的。畫面上銅之間四個入口都在且顯示線上人數。1306 是 mode 值不存在，與段位無關。

錯誤碼語意（實測歸納，非官方文件）：1004 = 送到未登入 socket，或已在對局中還想匹配；1306 = match_mode 不存在。

### 16.5 `room_quick_test` 少了最後一步（已修）

`room_quick_test`（createRoom → 3× addRoomRobot → startRoom）四步全部 `serverAccepted: true`，但 `/game/state` 顯示 `inGame: false`，看起來像失敗。

實際上 `startRoom` 讓**伺服器**真的開了局——`fetchGamingInfo` 查得到 `connect_token` 與 `game_uuid`。問題是 WebView 客戶端沒收到 `NotifyRoomGameStart`，停在大廳。

補 `bot_sync`（強制重連）後伺服器把進行中的對局推回來，客戶端才進場。已實測 `inGame: true` / 東1局 / seat 1 / 手牌 13。

**這是「三層成功」的又一個案例**：request 被接受 ≠ 遊戲真的前進。四個 `serverAccepted: true` 完全沒有保證客戶端進場。

### 16.6 掃 log 找到但**尚未修**的四個問題

1. **立直後空轉 5 秒印 ❌**（17:52 出現兩次）。立直後客戶端自己摸切，伺服器不再送 oplist，Naki 卻進重試迴圈等 50×0.1s。行為安全（fail-closed，沒亂送），但白等且 log 看起來像出事。
2. **`end_game` 時 `botNotInitialized`**。`end_kyoku` 已清掉 Bot，`end_game` 才到。無害但每局結束都走錯誤路徑。
3. **`naki-mjai.log` / `naki-system.log` 是 0 bytes**。`mjaiLog()` / `systemLog()` 各有 0 個呼叫點——建了分類卻沒遷移，`/status` 仍列出它們，等於謊報。
4. **對局結束後 `inGame` 不歸位**。`/game/state` 停在 `inGame: true` / 東0局 / seat 0。

刻意留著讓 10 局 soak 在「未修狀態」下跑，測出來的東西才乾淨。

## 17. Liqi 錯誤碼與 socket 選線（2026-08-01）

### 17.1 錯誤碼對照表（實測歸納，非官方文件）

`sendRaw` 回 `success: true` 只代表 bytes 送出去了。真正的結果藏在 RESPONSE 的
`field1` base64 裡，要解 varint 才看得到。這張表是這輪 soak test 撞出來的：

| 碼 | 意義 | 觸發情境 |
|----|------|---------|
| 1004 | 該 socket 未完成登入 | 送到沒做過 `oauth2Login` 的那條 `/gateway` |
| 1023 | 對局進行中 | 局中送 `createRoom` / `leaveRoom` |
| 1105 | 已在友人房中 | 上一局的房沒離開就再 `createRoom` |
| 1306 | `match_mode` 不存在 | 送舊對照表的值（見 §16.4） |

**這四個碼原本在 Naki 的文件裡完全沒有。** 每一個都是「請求被接受、事情沒發生」
的靜默失敗，只有解 base64 才查得出來。

### 17.2 sendRaw 選線：三次迭代才對

雀魂同時開 2–3 條 `/gateway`，只有一條完成 `oauth2Login`。送到別條一律 1004。

| 版本 | 判準 | 為什麼失敗 |
|------|------|-----------|
| 原始 | `pick[pick.length - 1]`（建立順序最後一條） | 純粹碰運氣 |
| v2 | 最近收到過伺服器訊息 | 兩條都收心跳，時間戳常常**完全相同**，平手退回順序＝沒判 |
| v3 | 遊戲自己送過 lobby 請求的那條 | `.lq.Lobby.heatbeat` 也算 lobby，兩條都中 |
| v4 | 登入 > 一般 RPC | **優先序反了**：客戶端會在多條線嘗試登入，選到已放棄的那條 |
| **v5** | **一般 lobby RPC > 登入，心跳不算** | ✅ 實測 accepted=True |

**教訓：證據強度和直覺相反。** 登入看起來是最強證據，實際上最弱——嘗試登入不代表
登入成功。持續跑 `fetchCurrentMatchInfo` 這類 RPC 才證明 session 活在那條線上。

排除 Naki 自己送的（msgId ≥ 60000）也是必要的，否則會把自己送錯的那次記成正確答案，
錯誤自我強化。

### 17.3 harness 自己的四個 bug（都已修）

寫測試工具時踩的坑，比被測程式還多：

1. **grep 抓錯結束標記**。`end_game` 只有 `[協調器]` 版本；`[消費者]` 那條在 handler
   拋錯時格式會變成「處理 end_game 時發生錯誤」，而 `botNotInitialized` 每局都發生
   （§16.6.2）。計數永遠 0，腳本安靜卡死 10 分鐘。
   **§16.6.2 原本被我歸類成「無害」——它直接讓測試工具失效。**

2. **跳脫 JSON 比對**。MCP 回應是「JSON 包在 JSON 字串裡」，引號變成 `\"`。
   `grep '"serverAccepted":false'` 和 `grep '"success"'` 都對不上（後者因為
   `success` 後面是反斜線不是引號）。**連踩三次**才改成「先 `tr -d '\\'` 去掉
   反斜線再比對」——逐個 pattern 處理跳脫是治標，這才是根除。

3. **腳本自己踩自己**。無條件 `bot_sync` 會拆掉剛建好的連線，下一輪 `createRoom`
   就打在沒登入的 socket 上。改成「先給客戶端 16 秒自己進場，真的沒進去才重連」。

4. **用 `tehaiCount` 判斷在不在局中**。對局剛開始時手牌是 0，會誤判成閒置去建房
   → error 1023。改用 `fetchGamingInfo` 有沒有 `connect_token`。

### 17.4 截圖時機不足以驗證高亮

`action-shots.sh` 在推薦產生時觸發，但自動打牌 1.0–1.9 秒後就送出，而 `/screenshot`
回傳 4 MB 全解析度 PNG，編碼加傳輸要 1–2 秒。**常常拍到牌已經打掉之後的畫面。**

因此先前「非推薦牌暗化沒有生效」的結論**證據不足，已收回**。可能高亮與暗化都正常，
只是拍太晚。目前只有一張（18:41:47）清楚拍到綠色高亮。

修法是給 `/screenshot` 加 `scale` 參數縮圖加速，但那要重建重啟、會中斷正在跑的 soak，
所以排在 soak 之後。

### 17.5 已確認在畫面上生效

- **綠色高亮**：九萬綠色，側欄 `#1 打 九萬 59.9%`，對得上。
- **隱藏玩家名稱**：自家名牌顯示 `Player 1`。協定層等長改寫第一次拿到視覺證據
  （先前只知道 bytes 被改了）。人機的「電腦（簡單）」沒被遮，那是客戶端本地字串
  不是伺服器 nickname，不在範圍內。

## 18. 副露自動送「過」蓋掉模型建議（2026-08-01，已修）

### 18.1 現象與根因

使用者回報「碰／過都不會自動」。實際情況比「沒反應」嚴重：**Naki 主動送出了「過」，
把模型的建議蓋掉。**

`checkAndRetriggerAutoPlay` 是 1 秒輪詢，推論是非同步的：

```
oplist 到達 → (~50–100ms) 推論完成 → updateUIAfterBotResponse 同步到 view model
                ↑
          輪詢跑在這中間，看到的是「上一巡清空後的空清單」
```

它把 `recommendations.isEmpty` 解讀成「Mortal 判斷不做」，於是主動送 cancel。

live 實測兩次：

| 時間 | 序列 |
|------|------|
| 20:57:10 | oplist `.704` → **`.707` 送出過** → `.791` 推論才完成 |
| 20:57:47 | oplist `.183` → `.238` 推薦 `pon@85.9%` → **`.638` 仍送出過** |

第二次直接把 85.9% 的碰蓋成過。

### 18.2 修法與取捨

加 2 秒寬限期：快照 `capturedAt` 未滿 2 秒不送「過」。

**為什麼是等待而不是「檢查推薦是否對應這批 oplist」**：後者要在推薦上帶 sequence
並貫穿 controller → view model，改動面大；而這裡的不對稱極端——伺服器思考時間
實測 300 秒，**多等 2 秒零代價，搶在推論完成前送出則不可逆**。實測延遲在 100ms
量級，2 秒有 20 倍餘裕。

自動送過這條路本身要保留：Mortal 判斷不值得吃碰時 `react` 回 nil，沒人送 cancel
的話對局會停到伺服器逾時代打。

### 18.3 同一類錯誤：沒有 oplist 也照樣重試

`triggerAutoPlayNow` 以前不管有沒有 oplist 都排進 `executeAutoPlayActionWithRetry`，
在「伺服器根本還沒授權」時空轉 50×0.1s 然後印 `❌ 放棄`（§16.6.1）。

修法：觸發前先確認 `LiqiOperationStore.shared.pending` 存在；重試上限從 50 降到 15。
觸發點已確認過 oplist，重試只需涵蓋「延遲期間 oplist 剛好換批」的短暫空窗——
等 5 秒不會讓它更可能成功，只會讓訊息晚 3.5 秒出現。訊息也從 `❌ 放棄` 改成
`⏭️ 這次不送（等下一批）`，因為那是安全機制生效，不是故障。

`forcedAction`（伺服器有和牌但模型無推薦）不受此限：那條路的前提就是 oplist 裡有和牌。

### 18.4 貫穿本輪的思路缺陷

§16、§17、§18 的多個 bug 是同一種錯誤：**把瞬時狀態當成穩定狀態**。

- 「此刻推薦是空的」→ 當成「模型決定不做」
- 「此刻 fetchGamingInfo 沒有對局」→ 當成「可以建房」（客戶端正在進場）
- 「此刻建房被拒」→ 當成「系統性失敗，該退出」（其實是競態）
- 「此刻有對局」→ 當成「該等待」（其實是客戶端沒進場，該重連）

判準應該是「這個狀態穩定了嗎」而不是「這個狀態現在成立嗎」。停滯 watchdog 是唯一
一開始就設計成「有上限的自救」而非二元判斷的機制，那個方向才對。

## 19. 參考 Akagi 後的實作（2026-08-01）

設計對照見 `docs/design-review-vs-akagi.md`。這一節記實作的取捨。

### 19.1 錯誤碼自動解碼

`LiqiResponseRecord` 自己解 `Error.code` 的 varint，並附已知語意表。

**取捨：未收錄的碼必須明說「未收錄，語意未知，不要猜」。** 表只有四個碼，全部由
2026-08-01 實測歸納。誘惑是照數字範圍編一個描述，但那會製造出比「不解碼」更糟的
東西——一個看起來權威的錯誤答案。測試裡明確斷言未知碼要含「未收錄」。

**為什麼值得做**：那輪為了找出這四個碼，人工 base64 → hex → varint 解了四次，
而每一次的表象都是 `sendRaw` 回 `success: true`。

### 19.2 per-session log 目錄

改成 `~/Library/Logs/Naki/<timestamp>/`，保留 8 次。

**解決的不只是整潔**：`xcodebuild test` 是 app-hosted，test host 會用同一組固定
檔名，所以「跑測試」與「App 正在跑」互斥——那輪必須先停 soak 才能跑單元測試。
另外輪替可能在對局中途發生，log 從中間斷掉；分析工具也要從共用檔案裡切範圍，
soak 的異常統計因此變成累計而非單次。

### 19.3 對局錄製：只存完整對局

`GameRecorder` 掛在 `MJAIEventStream`，`end_game` 時才寫檔。

**取捨：中途斷線的半截緩衝直接丟棄，不寫「部分錄影」。** 半局的 replay 結果無法
解讀——你不知道決策的差異是程式改動造成的還是錄影本身就斷了。留著只會讓人以為
有資料可用。

**錄的是 MJAI 事件不是原始 WS frame**：replay 的目的是重跑決策，而決策的輸入就是
這一層。原始 frame 另有 liqi log 可查，兩者用途不同。

**replay 用獨立的 Bot**，不重用正在對局的 controller——replay 會把狀態機從頭走
一遍，混進 live 對局會直接毀掉當前那局。

### 19.4 replay-check：能驗什麼要寫在檔頭

`scripts/replay-check.sh` 重跑所有錄影，用「事件序 + 動作」的 sha256 當決策指紋，
與 baseline diff。

**必須寫清楚界線**：能驗 observation encoder、resolver 規則、副露後推論、決策順序；
**不能**驗送出通道、oplist 時序、WebGL 高亮、UI——那些不在事件流裡。不寫清楚的話，
下次會有人拿 replay 綠燈當成「全部驗過了」，那正是這個工具最危險的失敗模式。

指紋不同時腳本明說：「這不一定是壞事——修 bug 本來就會改變決策，但你必須能解釋
每一個變化。無法解釋的差異就是回歸。」

### 19.5 soak 進場延遲：早送的重連是無效的

原本 `startRoom` 後 3 秒送第一次 `bot_sync`，實測**永遠無效**（連續兩局），要等
90 秒逾時後第二次才成功，每局固定浪費約 2 分鐘。

改成先給 8 秒讓伺服器把局準備好再重連，沒進去就每 20 秒再試，最多 3 輪。

**教訓**：重試的間隔要對應「被等待的事情需要多久」，不是「我想多快知道結果」。
3 秒那次不是運氣不好，是機制上不可能成功。

### 19.6 專案結構的坑

`Naki.xcodeproj` 的 `membershipExceptions` 在這個專案是**包含清單**，不是排除清單。
新增的 Swift 檔不手動加進去就不會被編譯，而錯誤訊息是 `cannot find 'X' in scope`,
看起來像 import 問題。`GameRecorder.swift` 與 `ReplayTools.swift` 都踩到。

MCP 工具要 `import MCPKit`（型別在獨立 module，不在 Naki target）。
