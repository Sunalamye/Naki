# 插件 v2 Phase 4：receive 側變長 replace／drop／injectReceive

**資料日期**：2026-10-17（第二輪，回應 Astra 第一輪審查）
**狀態**：設計草案＋spike（分支 `plugin-v2-phase4`，基於 main `2d02a03`，未合併、未 push）。spike 含 capture 攔截、合成事件重派、變長 `replace`（需 `reshapeReceive`）、`drop`、禁改名單、建構期 fail-open、攔後故障狀態、kill-switch、stop 失效哨兵。`injectReceive`、`respondLocally` 只有設計。
**gate**：`plugin-system-design.md` §11 #6「probe 綠才實作」。probe 結果見 `plugin-v2.md` §9.6，用戶 2026-10-17 裁決開工。**合併 gate**：§8 的 live 清單全部通過（Astra 第一輪第 3 條，主線裁決）。
**決策紀錄**：repo 根 `plugin-v2-phase4-implementation-notes.md`（含 Deviations）；審查回應 `plugin-v2-phase4-review-response.md`。
**上位文件**：`plugin-system-design.md`（§7.4、§7.5、§8、§11）、`plugin-v2.md`（§4、§9）、`plugin-api-v1.md`、`d22-naki-identity.md`、`plugin-v2-b2-adr-2026-10-17.md`。本文件不推翻任何拍板。

---

## 0. 前提與已知限制

probe 的事實（`plugin-v2.md` §9.6，第二輪）：

| 項 | 結果 |
|---|---|
| (a) capture 階段 `stopImmediatePropagation` 擋得住遊戲 handler | 綠 |
| (b) 遊戲吃合成 `MessageEvent` | 綠 |
| (c) 遊戲每條連線只用 `onmessage` 註冊一次 | 綠 |
| (d) target 上後註冊的 capture 先於先註冊的非 capture | true |

限制直接當成設計前提：

- 樣本 1，只有對局連線上的 `.lq.Route.heartbeat` RESPONSE，內容不變。
- 牌局訊息吃不吃合成事件沒有直接證據。
- 大廳連線沒有被攔過。允許大廳變長改寫只是推論，放給使用者前必須補樣本（§8）。
- 錯誤路徑（遊戲在合成事件上拋錯）沒有任何 live 樣本。

---

## 1. 問題 1：listener 改 capture 的時機與順序

### 1.1 註冊

Naki 在 `new WebSocket()` 包裝器裡註冊兩個 `message` listener，時點都是建構當下：

1. **主 listener**，capture。依 (d)，WebKit 在 target 上先跑 capture，capture 之間照註冊順序，所以它永遠第一。
2. **哨兵**，非 capture，排在所有非 capture 之首。它只偵測一種失效：已被攔下的原事件**抵達哨兵**，代表 `stopImmediatePropagation` 沒生效，記故障並鎖死。偵測範圍與盲區見 §5「哨兵」。

### 1.2 與 main 的差異（型別 × 遊戲註冊方式）

| 原事件 data | 遊戲註冊方式 | 零插件、等長改寫 | 變長 replace／drop |
|---|---|---|---|
| ArrayBuffer | 非 capture（現況，`onmessage`） | **與 main 相同**：Naki → Swift → 遊戲，讀同一份 ArrayBuffer。已以 main 差異比較測試鎖住 | 攔下原事件，遊戲收到合成事件（§1.3） |
| ArrayBuffer | 遊戲改用 capture | **行為變更**：main 的 Naki 是非 capture，會排在遊戲 capture 之後；HEAD 刻意讓 Naki 優先。等長改寫時，遊戲當下讀到的也從原值變成改寫值 | 同上 |
| TypedArray | 只出現在 send | send 路徑不變（含 byteOffset 非 0 的 view，已測） | 不適用 |
| Blob | 任何方式 | 遊戲同步先收到原事件；插件與 Swift 在非同步展開後才處理。不是「Naki → Swift → 遊戲」 | **不提供** |
| 字串 | 任何方式 | 不派發給插件 | 不提供 |

### 1.3 變長交付順序

```
主 listener(event)
  1. markNakiAnswered、nakiNicknameMask.observe、插件鏈           與 main 相同
  建構期（任一步失敗 ⇒ fail-open：原事件照常交付、Swift 收原 bytes、fallback +1）
  2. 新 bytes 編成 base64
  3. 建合成 MessageEvent（ArrayBuffer 複本，帶原 origin、lastEventId），登記進 syntheticEvents
  4. event.stopImmediatePropagation()
  交付期（攔下之後；任一步失敗 ⇒ 故障：鎖死＋診斷，不重送原事件）
  5. drop：結束，dropped +1
  6. sendToSwift(新 bytes)；回 false 或拋錯 ⇒ 故障 bridge_rejected，仍做第 7 步
  7. ws.dispatchEvent(合成事件)，同步；拋錯 ⇒ 故障 dispatch_threw
  8. 6、7 都成功才 delivered +1
遊戲 onmessage(合成事件)；主 listener 第一行就略過它
```

- 可失敗的編碼與建構都在第 4 步之前，所以 fail-open 只發生在原事件還沒被攔的時候。
- bridge 拒收時仍交付合成事件：Swift 已經缺這一則，遊戲至少不會卡在等它。
- 攔下之後的故障不重送原事件。遊戲可能已收到一部分，重送會讓它收兩份。
- Swift 先收再重派。遊戲 handler 因這則送出的請求不會排到它前面。
- `sendToSwift`（naki-core）改為回傳是否送達：`postMessage` 成功回 `true`，例外或沒有 bridge 回 `false`。既有呼叫端不看回傳值，不受影響。

### 1.4 binaryType

- 變長改寫只對 ArrayBuffer 原事件提供，合成事件的 data 也是 ArrayBuffer。
- Blob 只能非同步展開。先攔再重派會讓後續訊息先交付，順序會亂。
- `injectReceive`、`respondLocally` 沒有原事件可參考，合成時要照當下 `ws.binaryType` 決定型別。
- 已知缺口：main 的 `respondLocal` 一律給 ArrayBuffer，本輪不改，適用範圍待 live 確認。

### 1.5 對既有路徑的影響

- `syntheticEvents` 取代原本只給本地回應用的 `localEvents`，兩種合成事件都由產生者顯式送 Swift。
- `markNakiAnswered` 只在原事件上跑。改寫不能改 msgId 與 type，標記結果相同。
- 守衛的本地回應路徑不變。

---

## 2. 問題 2：原語

### 2.1 `ctx.replace(bytes)`

- **等長**：`rewriteReceive`，就地改，與 v1 相同，不碰事件。
- **長度不等**：需要 `rewriteReceive`＋**`reshapeReceive`**。沒宣告 `reshapeReceive` 的插件照 v1 回 `false`，控制流程不變。
  - `reshapeReceive` 是明確選用。`PluginManifest.validate` 認得它：只宣告 `reshapeReceive` 不宣告 `rewriteReceive` 視為 manifest 無效。grant 原樣下發到 JS。
  - Swift validate 是**選用條件，不是隔離邊界**。grant 與 L3 開關在 JS 同 realm 可寫，插件可直接改 grant 或經 `setGrant` 重新註冊而不經 validate。沿用既有信任模型（`plugin-api-v1.md` §8）。
  - 等級仍是 L2（Astra 表態 #3：長度不是可靠的分級界線）。
- 長度不等時，以下全部成立才回 `true`：
  - 這則是 ArrayBuffer 原事件，頁面未鎖死。
  - method 不在禁改名單（§4）。不成立時回 `false`，不計失敗。
  - 新 bytes 通過 `isWellFormed`。NOTIFY 的 field 1 必須非空；RESPONSE 的 field 1 可省。
  - type、msgId 不變；NOTIFY 的 method 不變；RESPONSE 不得帶非空 method。不成立時回 `false`，計一次 `replace` 失敗。
- 換掉後，後續插件拿到新 bytes 與重新解析的 `payload`，鏈不中止。

### 2.2 `ctx.drop()`

- capability `dropReceive`，L3，每次呼叫檢查總開關 `pluginsMayModifyOutbound`，關著回 `false`。
- 只限 NOTIFY。RESPONSE 被丟，遊戲會一直等。不另設替代（Astra 表態 #4）。
- 成立時：遊戲與 Swift 都收不到這則，鏈立即中止。

### 2.3 `ctx.injectReceive(method, payload)`（只設計）

- capability `injectReceive`，L3，關著回 `{ok:false, reason:'outbound_disabled'}`。
- Naki 自己組 NOTIFY envelope，一定寫出 field 1。
- 目標連線是呼叫當下 ctx 的那條。第一版只允許已鎖定為大廳的連線，對局連線回 `{ok:false, reason:'game_connection'}`。
- method 不在禁改名單，且只能是 NOTIFY。
- **弱順序契約**：只保證在當前這則交付給遊戲**之後**才交付，中間可能插進其他網路訊息。不保證「緊接下一則」。要更強的順序要另設交付佇列，本輪不做。
- 交付以 `setTimeout 0` 排程。先 `sendToSwift`，再登記進 `syntheticEvents` 並 `dispatchEvent`。攔後故障規則同 §1.3。
- 不進插件改寫鏈。宣告 `observeNakiTraffic` 的 observer 看得到，`isNaki = true`。
- I2 規則見 §6。

### 2.4 多插件鏈

hook 拋錯時，鏈**回到該 hook 進入前的狀態**。先前成功的插件結果保留。

| 情況 | 結果 |
|---|---|
| A replace，B 之後 | B 看到 A 的新 bytes 與 payload |
| A replace，B drop | drop 勝，兩邊都不交付 |
| A drop | 鏈中止，B 收不到 |
| A replace 成功，B 改寫或 drop 後拋錯 | 撤回 B，交付 A 的結果（已測） |
| 只有 A，A replace 或 drop 後拋錯 | 撤回 A，原事件照常交付 |
| A 等長就地改，B 變長 replace | 交付 B 的 bytes，B 的輸入是 A 改過的內容 |

順序沿用 v1：`priority` 升冪，同值按 id 字典序。改了 bytes 或 drop 的插件記為**候選改寫者**，隨故障診斷一起記錄。

### 2.5 失敗總表

| 失敗點 | 階段 | 結果 |
|---|---|---|
| hook 拋錯 | 鏈 | 回到該 hook 進入前的鏈狀態，鏈繼續 |
| 新 bytes 不合規 | 鏈 | `replace` 回 `false`，不改 |
| 編碼失敗 | 建構期 | fail-open，`fallback` +1，不鎖 |
| 合成事件建不出來 | 建構期 | 同上 |
| 攔不下原事件（呼叫拋錯） | 建構期 | 同上 |
| bridge 拒收 | 交付期 | **已記錄的降級交付**：故障 `bridge_rejected`，鎖死；合成事件仍交付給遊戲；不算 delivered |
| `dispatchEvent` 拋錯 | 交付期 | 故障 `dispatch_threw`，鎖死；不重送原事件；不算 delivered |
| 合成派發期間有 listener 拋錯 | 交付期 | 故障 `synthetic_dispatch_error`，鎖死 |
| 攔下後原事件抵達哨兵 | 交付後 | 故障 `stop_ineffective`，鎖死。這一則遊戲已收到兩份，無法挽回 |

---

## 3. 問題 3：D22 身分登記與 RESPONSE 認領

- 合成事件不再經 `markNakiAnswered`。原事件已標過，改寫不能改 msgId 與 type。
- Naki 自送與插件注入的 RESPONSE 是 `isNaki`，鏈上沒有 `replace` 與 `drop`，observer 也沒有。判斷用 b2 守衛同一張 `(連線, msgId)` 登記表。
- `LiqiResponseStore` 只認領 Naki 登記過的回應，那些都是 `isNaki`，插件改不到。
- D22 的殘留照舊，都落在「少給改寫」的一側。
- 合成 RESPONSE 只能經 `respondLocally`，msgId 必須是被丟棄的那筆 REQUEST。本輪不實作。

---

## 4. 問題 4：禁改名單

變長 `replace` 與 `drop` 共用一張表。`rewriteAllow` 解不開。以 canonical 全名比對，不做大小寫或別名推測（Astra 第 9 條）。

**來源是 Swift 消費端清單**：Swift 據以改牌局、帳號或匹配狀態的 NOTIFY／RESPONSE。

| method | Swift 消費端 |
|---|---|
| `.lq.ActionPrototype` | `MajsoulBridge`、`LiqiParser`：牌局動作 |
| `.lq.FastTest.authGame`、`syncGame`、`enterGame` | `MajsoulBridge`：`start_game`、重連還原 |
| `.lq.NotifyGameEndResult`、`.lq.NotifyGameTerminate` | `MajsoulBridge`：`end_game` |
| `.lq.Lobby.login`、`oauth2Login`、`emailLogin` | `LiqiParser.loginResponseMethods`：accountId 決定座位 |
| `.lq.Lobby.oauth2Auth` | `LiqiParser`：刻意不解析 token |
| `.lq.Lobby.startUnifiedMatch` | `LiqiParser.parseResponse`：被拒時作廢待回填 |
| `.lq.NotifyGameBroadcast` | `LiqiResponseStore`：表情廣播紀錄 |

另加兩個前綴：全部 `.lq.FastTest.*`（對局 RESPONSE，例如 `inputOperation`，是自動打牌的依據）與全部 `.lq.Route.*`（連線層）。結構上另外排除 `isNaki` 流量，以及 method 對不回的 RESPONSE。

**一致性測試**：`JSContractTests.testReshapeForbiddenListCoversEverySwiftConsumedMethod` 從 `MajsoulBridge.swift`、`LiqiParser.swift` 抽出所有 `".lq.…"` 字面值，再加上 `loginResponseMethods`、`startUnifiedMatchMethod`、`broadcastMethod`，逐一呼叫 JS 的 `__nakiPlugins.isReshapeForbidden`，缺一即紅。

這是**兩檔字面值＋三組常數的明確盤點**，不是語意分析。其他檔案的常數引用、動態拼接的 method，或以前綴判斷涵蓋的方法都抽不到。所以不宣稱日後新增的 Swift 消費端必被擋下；新增時要同步更新名單或測試的掃描範圍。

**允許變長的合法用例**：名單沒有封鎖全部 Lobby。`.lq.Lobby.fetchCharacterInfo`、`fetchAccountCharacterInfo`、`fetchAccountInfo`、`fetchAllCommonViews` 不是 Swift 消費端，刻意允許變長 replace，這是解鎖類插件的目標用例。

等長改寫仍沿用 v1 的禁改名單與 `rewriteAllow`，本輪不動。

**放寬條件**，每一類分開判斷：

1. 對該 method 補 live probe，在測試帳號至少命中 3 次，內容不變、只重派。
2. 三次都要：遊戲 handler 恰收到一次合成事件且無拋錯、連線維持 OPEN、`/game/state` 照常前進、`soak-test.sh` 1 局無異常。
3. 牌局類另加 `replay-check.sh` 零插件指紋與 baseline 相同，且 Naki 推薦與畫面一致。
4. 一致性測試目前沒有豁免清單。放寬 Swift 消費端的 method 時，要在測試裡加豁免並寫明理由，不能只改 JS。

---

## 5. 問題 5：失敗模式與 kill-switch

**故障診斷**：`window.__nakiWebSocket.diagnostics()` 帶出：

- `reshape: {attempted, delivered, dropped, fallback, faults}`。「嘗試」與「交付」分開計。
- `reshapeLocked`。
- `reshapeFaults`：最近 32 筆，每筆有 `kind`、`socketId`、`method`、`msgId`、`candidates`（候選改寫者）、`error`、`at`。

`kind` 有四種：`bridge_rejected`、`dispatch_threw`、`synthetic_dispatch_error`、`stop_ineffective`。

**合成派發期間錯誤**：listener 拋出的例外不會傳回 `dispatchEvent`，而是回報到 `window` 的 `error` 事件。Naki 在重派期間保存這則的中繼資料，期間收到 `error` 就記為 `synthetic_dispatch_error`。

- 名稱刻意不寫「遊戲拋錯」：同一次派發內的任何 listener 都可能是來源。
- 歸責只到「候選改寫者」：多個插件共同產出時，不能可靠歸給單一插件。
- **未驗證**：WebKit 是否在 `dispatchEvent` 回傳前同步送出 `error`。若不是，這個觀測會漏。這是合併前必跑的 live 項（§8）。
- 非同步解碼錯誤（遊戲在之後的 task 才解析）不在這個觀測範圍內。

**kill-switch**：

| 開關 | 現況 | 作用 |
|---|---|---|
| 插件頁總開關 | **不存在**。只有每個插件的開關與 L3 總開關 | — |
| 停用插件 | 已存在（熱停用） | 零插件時從不攔事件 |
| L3 總開關 | 已存在 | 關掉後 `drop` 一律回 `false`。變長 `replace` 是 L2，不受影響 |
| 頁面鎖死（本包） | 任何一種故障發生一次就鎖 | 之後不再提供變長 `replace`／`drop`，頁面重載才解。停用某個插件不解鎖（Astra 表態 #7）。送一行 log，插件 id `naki`，帶 kind、method、msgId、候選改寫者 |
| 自動停用（已存在） | 某 hook 連續失敗 10 次 | 該插件本頁面停用 |

鎖死無法修復已經分叉的那一則，只能防止下一則。鎖死**只停後續的變長 replace／drop**：不重同步 Swift，不停遊戲，不停等長改寫，也不停自動操作。

**已記錄的降級交付（bridge 拒收）**：遊戲收到新 bytes，Swift 沒收到任一版本。選這條是為了不重送原事件、也不讓遊戲卡在等 RESPONSE。

**驗收要把計數一起看**：`sendToSwift` 回 `true` 只代表 `postMessage` 沒有同步拋錯；`delivered` 也不代表遊戲解碼成功。listener 拋錯時可能同時 `delivered` +1、`faults` +1。判定交付正常要看 `delivered` 等於嘗試次數**且** `faults` 為 0。

**哨兵**：

- 只偵測「已攔下的原事件抵達哨兵」。正常的合成事件不在 `stoppedEvents`，不會誤鎖。
- **已知盲區一**：原事件的 stop 無效，而遊戲在 Naki 之後註冊的 capture handler 又以有效的 stop 阻斷原事件。那個 handler 收到合成與原事件兩份，哨兵沒執行，`faults` 為 0、不鎖。node 反例測試鎖住這個行為。實際 WebKit 是否出現此條件未驗證。
- **已知盲區二**：哨兵沒註冊成功或自身失效時，沒有獨立的偵測。
- 零插件主路徑多一次 listener 呼叫與一次 WeakMap 查找，沒有多複製 bytes。
- 順序證據只來自 P4 的多 listener harness 與 live L4–L6。舊 harness 改成「保留第一個 listener」只為讓舊案例照常執行，它略過了哨兵，**不能當順序證據**。

---

## 6. I2：receive 側不能被用來讓遊戲送出未擁有物品的請求

receive 側的改寫不會送出任何東西。但變長 `replace`、`drop`、`injectReceive`、`respondLocally` 都會讓遊戲以為伺服器回了某些內容，遊戲可能接著送出引用未擁有物品的請求。規則如下：

1. **守衛照擋**：送出守衛只看送出的 REQUEST，與 receive 側用哪個原語無關。
2. **污染**：宣告 `sendGuard` 的插件只要在大廳連線上改了或丟了一則，就污染到頁面重載。已實作並測試：變長 `replace` 經 bytes 比對，`drop` 另外判斷。
3. **`injectReceive`／`respondLocally`（設計）**：在大廳連線上只開放給宣告非空 `sendGuard` 的插件，呼叫一次就污染。對局連線一律不開放。
4. **不宣稱 I2 全域成立**：沒有 `sendGuard` 的插件仍可改大廳回應，與 v1 等長改寫的現況相同。名單外方法的 I2 依解鎖設計 `unlock-plugin.md` §3.7，與 `plugin-v2-b2.md` §1.3 D31 一致。

---

## 7. 問題 6：測試策略

**node**（`scripts/plugin-v2-p4-regression.cjs`，24 條）：

- 假 dispatcher 三種：`capture`（WebKit 實測）、`order`（(d)=false）、`nostop`。
- `nostop` **不是通過證據**。它只證明攔截失效時遊戲會收兩份，以及原事件抵達哨兵時會記 `stop_ineffective` 並鎖死。另有一條反例斷言盲區一：後註冊的遊戲 capture handler 阻斷原事件時，哨兵不執行、不鎖。
- 故障注入三案：編碼失敗、bridge 拒收、dispatch 拋錯。每案斷言故障狀態、計數與「沒有記成交付」。
- main 差異比較：同一串事件分別跑 main（`2d02a03`）與 HEAD 的 JS，比對遊戲收到的 bytes 與順序、Swift 序列、socket 送出物件。零插件與等長改寫兩組都逐一相同。事件串含 byteOffset 非 0 的 TypedArray 送出。
- Blob：假 dispatcher 補 `FileReader`，斷言遊戲先收到原 Blob 事件、Swift 收到完整 bytes、插件沒有 `replace`／`drop`。
- 鏈：A 成功、B 拋錯，交付 A 的結果。
- 選用：沒有 `reshapeReceive` 時長度不等回 `false`，等長仍可。
- **限制**：三種 dispatcher 都把 `error` 同步送出。這只能測 Naki 自己的判斷，不能證明 WebKit 的行為。

**Swift**：

- `JSContractTests.testMessageListenerIsRegisteredInCapturePhase`：主 listener capture、哨兵非 capture。
- `JSContractTests.testReshapeForbiddenListCoversEverySwiftConsumedMethod`：§4 的一致性。
- `PluginManifestValidationTests.testReshapeReceiveRequiresRewriteReceive`：選用規則與 grant 下發。

**變異**（`.swfd/logs/p4/mutate.cjs`，26 條全被抓）：第一輪 16 條沿用，錨點隨程式調整；新增 10 條：

| # | 變異 | 對應 |
|---|---|---|
| N1 | 名單漏 `NotifyGameTerminate` | 擋 1 |
| N2 | 名單漏登入回應 | 擋 1 |
| N3 | bridge 失敗不記故障 | 擋 2 |
| N4 | bridge 失敗仍記成交付 | 擋 2 |
| N5 | dispatch 拋錯不記故障 | 擋 2 |
| N6 | 故障時重送原事件 | 擋 2 |
| N7 | 不看 `reshapeReceive` | 應修 6 |
| N8 | 拋錯撤回到鏈起點而非 hook 進入前 | 應修 7 |
| N9 | 哨兵失效 | 應修 8 |
| N10 | 候選改寫者不記 | 應修 5 |

Swift 變異：JS 名單拿掉 `NotifyGameTerminate`，一致性測試變紅（第一輪另驗過拿掉 capture 會讓 listener 測試變紅）。

---

## 8. live 驗收清單（**合併前必跑**）

主線裁決：本輪只修 spike 與文件，下列由後續 live 包在測試帳號執行。任一項未過，不合併。

| # | 項目 | 判準 |
|---|---|---|
| L1 | kill-switch 同步性 | 範例插件對一則大廳 NOTIFY 變長 replace，並讓頁面上一個 listener 對合成事件拋錯。`dispatchEvent` 回傳前 `reshapeLocked` 已為 true，`reshapeFaults` 有一筆 `synthetic_dispatch_error` |
| L2 | 大廳變長樣本 | 至少一則大廳 NOTIFY 與一則大廳 RESPONSE，各變長 replace 3 次：遊戲畫面反映、連線 OPEN、`delivered` 等於嘗試次數、`faults` 為 0 |
| L3 | 大廳 drop 樣本 | 一則大廳 NOTIFY drop 3 次：遊戲與 Swift 都沒收到，對局與大廳照常 |
| L4 | 零插件 replay 指紋 | `replay-check.sh` 與 baseline 相同 |
| L5 | 三局 soak | 零插件 `soak-test.sh 3` 無異常。capture 註冊與哨兵改的是所有人的主路徑 |
| L6 | 等長改寫回歸 | 既有等長改寫插件在 live 上行為不變 |
| L7 | binaryType | 讀 `diagnostics().receive` 確認大廳與對局連線的實際 data 型別，決定 `respondLocal` 缺口是否需要修 |

---

## 9. 未決問題（第一輪表態後剩下的）

| # | 問題 | 狀態 |
|---|---|---|
| 1 | WebKit `error` 是否同步 | 需 live（L1） |
| 2 | 大廳沒有 probe 樣本 | 需 live（L2、L3），放給使用者前必補 |
| 3 | 變長 replace 是否升 L3 | 已定：維持 L2，另加 `reshapeReceive` 明確選用 |
| 4 | RESPONSE 永不 drop | 已定：不加替代 |
| 5 | `injectReceive` 插隊 | 已定：弱順序契約（§2.3） |
| 6 | `respondLocal` 不看 binaryType | 本輪不改，需 live（L7） |
| 7 | 全頁或單插件鎖死 | 已定：全頁，記候選改寫者 |
| 8 | drop 造成 Swift 分叉 | 已處理：以 Swift 消費端補齊名單並加一致性測試 |
| 9 | 長度不等語意變更 | 已處理：`reshapeReceive` 選用，未選用維持 v1 |
| 10 | capture 主路徑樣本不足 | 需 live（L4、L5、L6）；差異已改寫成 §1.2 的型別表 |
