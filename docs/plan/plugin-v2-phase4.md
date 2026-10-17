# 插件 v2 Phase 4：receive 側變長 replace／drop／injectReceive

**資料日期**：2026-10-17
**狀態**：設計草案＋第一輪 spike（分支 `plugin-v2-phase4`，基於 main `2d02a03`，未合併、未 push）。spike 只含 capture 攔截、合成事件重派、變長 `replace`、`drop`、禁改名單、fail-open、kill-switch。`injectReceive`、`respondLocally` 只有設計。
**gate**：`plugin-system-design.md` §11 #6「probe 綠才實作」。live probe 結果見 `plugin-v2.md` §9.6，用戶 2026-10-17 裁決開工。
**決策紀錄**：repo 根 `plugin-v2-phase4-implementation-notes.md`（含 Deviations）。
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

- 樣本 1，只有對局連線上的 `.lq.Route.heartbeat` RESPONSE。
- `ActionPrototype` 等牌局訊息吃不吃合成事件沒有直接證據，只能從「同一個 `onmessage` 不看 `isTrusted`」推論。
- 大廳連線沒有被攔過。允許大廳的變長改寫也是推論，理由是 (c) 顯示每條連線都只有一個 `onmessage`。

所以第一版：牌局真相來源與連線層一律禁改（§4）。放寬要補 probe 樣本。

---

## 1. 問題 1：listener 改 capture 的時機與順序

### 1.1 註冊

Naki 在 `new WebSocket()` 包裝器裡註冊 `message` listener，第三個參數改為 `true`（capture）。註冊時點不變，仍是建構當下。

順序保證分兩種情況：

- **遊戲用非 capture 註冊**（現況，`onmessage`）：Naki 是第一個註冊的 listener，capture 與否都排第一。
- **遊戲日後改用 capture 註冊**：依 (d)，WebKit 在 target 上先跑全部 capture，再跑非 capture。Naki 若維持非 capture，就會排在遊戲的 capture 之後，遊戲會先看到原事件。改成 capture 後，capture 之間依註冊順序，Naki 仍是第一個。

因此改 capture 不依賴 (d) 也正確，(d) 只說明「不改會出事」。

### 1.2 交付順序

零插件、或插件只做等長改寫時，交付與 main 完全相同：

```
Naki capture listener(event)
  1. markNakiAnswered、nakiNicknameMask.observe   不變
  2. dispatch → 插件鏈（等長就地改）              不變
  3. sendToSwift(就地改後的 bytes)                 不變
遊戲 onmessage(同一個 event)                      不變
```

變長 `replace` 或 `drop` 成立時，第 3 步之後改走 `deliverReshaped`：

```
  3'. 建合成 MessageEvent（data 為新 bytes 的 ArrayBuffer 複本，帶原 origin、lastEventId），登記進 syntheticEvents
  4'. event.stopImmediatePropagation()
  5'. replace：sendToSwift(新 bytes)；drop：不送
  6'. replace：ws.dispatchEvent(合成事件)，同步、在原事件的 listener 裡
      合成事件再進 Naki listener 時第一行就略過
遊戲 onmessage(合成事件)
```

- 第 3'、4' 任一步失敗：原事件照常交付，Swift 收原 bytes，計一次 `fallback`。
- Swift 先收再重派。遊戲的 handler 若因這則訊息送出請求，Swift 看到的仍是「先收後送」。
- 同步重派。下一則網路訊息是另一個 task，不會插到前面。

### 1.3 binaryType 與 data 型別

| 原事件 data | 變長 replace／drop | 合成事件 data |
|---|---|---|
| ArrayBuffer（`binaryType = 'arraybuffer'`） | 提供 | ArrayBuffer，與原事件一致 |
| Blob（`binaryType = 'blob'`） | **不提供**，維持 observe-only | 不產生 |
| 字串 | 不派發給插件（現況） | 不產生 |

- Blob 只能非同步展開。展開完才攔就太遲。若先攔住、展開後再重派，後面的訊息會先交付，順序會亂。所以 Blob 不做。
- `injectReceive` 與 `respondLocally` 沒有原事件可參考，合成時要照當下 `ws.binaryType` 決定型別，`'blob'` 用 `new Blob([bytes])`。
- 已知缺口：main 的 `respondLocal`（送出守衛的本地回應）一律給 ArrayBuffer，不看 `binaryType`。本輪不改，記入未決問題。

### 1.4 對既有路徑的影響

- `syntheticEvents` 取代原本只給本地回應用的 `localEvents`。兩種合成事件都由產生者顯式送 Swift，Naki listener 一律略過。
- `markNakiAnswered` 只在原事件上跑一次。改寫不能改 msgId 與 type，所以合成事件不必再標。
- 守衛的本地回應路徑不變。

---

## 2. 問題 2：原語

### 2.1 `ctx.replace(bytes)`

capability 仍是 `rewriteReceive`（L2），沿用 `plugin-v2.md` §4.2。

- **等長**：就地改，與 v1 完全相同，不碰事件。等長因此不是變長的特例，而是保留原路徑的快捷分支：遊戲讀的仍是原 ArrayBuffer。
- **長度不等**：整包換掉，條件全部成立才回 `true`：
  - 這則是 ArrayBuffer 原事件，頁面未鎖死。
  - method 不在禁改名單（§4）。不成立時回 `false`，不計失敗，與 v1「長度不等回 false」的語意相同。
  - 新 bytes 通過 `isWellFormed`：每個欄位在界內。NOTIFY 的 field 1 必須非空；RESPONSE 的 field 1 可省。
  - type、msgId 不變。
  - NOTIFY 的 method 不變。RESPONSE 不得帶非空 method。
  - 以上不成立時回 `false`，計一次 `replace` 失敗。
- 換掉後，後續插件拿到新 bytes 與重新解析的 `payload`。method 不會變，所以鏈不中止。

### 2.2 `ctx.drop()`

- capability `dropReceive`。依 `plugin-system-design.md` §8.1，它是 L3，每次呼叫都檢查總開關 `pluginsMayModifyOutbound`，關著回 `false`。
- 只限 NOTIFY。RESPONSE 被丟，遊戲會一直等同 msgId 的回應，與 send 側不提供裸 drop 的理由相同（`plugin-v2.md` §4.3）。要改 RESPONSE 請用 `replace`。
- 成立時：遊戲與 Swift 都收不到這則，鏈立即中止。

### 2.3 `ctx.injectReceive(method, payload)`（只設計）

- capability `injectReceive`（L3），受總開關把關，關著回 `{ok:false, reason:'outbound_disabled'}`。
- Naki 自己組 NOTIFY envelope，一定寫出 field 1。插件只給 method 與 payload，不給整包。
- 目標連線是呼叫當下 ctx 的那條。第一版只允許已鎖定為大廳的連線，對局連線一律回 `{ok:false, reason:'game_connection'}`。
- method 必須不在禁改名單，且不是 RESPONSE。
- 交付：排程到目前 dispatch 結束之後（`setTimeout 0`）。先 `sendToSwift`，再登記進 `syntheticEvents` 並 `dispatchEvent`。不能在 hook 裡同步重派，否則注入的那則會比正在處理的這則先交給遊戲。
- 不進任何插件的改寫鏈。宣告 `observeNakiTraffic` 的 observer 看得到，`isNaki = true`。
- I2 規則見 §6。

### 2.4 多插件鏈

| 情況 | 結果 |
|---|---|
| A replace，B 之後 | B 看到 A 的新 bytes 與 payload |
| A replace，B drop | drop 勝，兩邊都不交付 |
| A drop | 鏈中止，B 收不到 |
| A replace 後拋錯 | A 的改動全部撤回，包含整包替換與就地改寫 |
| A drop 後拋錯 | drop 撤回，原事件照常交付 |
| A 等長就地改，B 變長 replace | B 的 bytes 交付。B 的輸入是 A 改過的內容 |

順序沿用 v1：`priority` 升冪，同值按 id 字典序。

### 2.5 fail-open 總表

| 失敗點 | 結果 |
|---|---|
| hook 拋錯 | 撤回該 hook 的全部改動，鏈繼續 |
| 新 bytes 不合規 | `replace` 回 `false`，不改 |
| 合成事件建不出來 | 原事件交付，Swift 收原 bytes，`fallback` 加一 |
| 攔不下原事件 | 同上 |
| `dispatchEvent` 本身拋錯 | 遊戲收不到這則，Swift 已收到。實務上不會發生，因為新建的事件不會處於派發中 |
| 遊戲處理合成事件時拋錯 | 本頁面鎖死（§5） |

---

## 3. 問題 3：D22 身分登記與 RESPONSE 認領

- 合成事件**不**再經 `markNakiAnswered`。原事件進 listener 時已經標過，而改寫不能改 msgId 與 type，所以標記結果相同。
- Naki 自送（`sendRaw` 登記）與插件注入的 RESPONSE 是 `isNaki`。`isNaki` 流量的鏈上沒有 `replace` 與 `drop`，宣告 `observeNakiTraffic` 的 observer 也沒有。判斷用的是 b2 守衛同一張 `(連線, msgId)` 登記表。
- 因此 Swift 的 `LiqiResponseStore` 等待的回應不會被插件丟掉或換掉。
- D22 的殘留照舊。例如「RESPONSE 持續誤認」會讓遊戲自己的某則 RESPONSE 被當成 Naki 的，於是不給改寫。這是保守的一側，不新增風險。
- 合成 RESPONSE 只能經 `respondLocally`，msgId 必須是被丟棄的那筆 REQUEST（`plugin-v2.md` §4.5 #3），本輪不實作。

---

## 4. 問題 4：禁改名單

變長 `replace` 與 `drop` 共用一張表，`rewriteAllow` 解不開：

| 項 | 理由 |
|---|---|
| `.lq.ActionPrototype` | 牌局動作載體，payload 還有 XOR |
| `.lq.NotifyGameEndResult` | 終局結算 |
| 全部 `.lq.FastTest.*`（含 `authGame`、`syncGame`、`enterGame`） | 對局連線的 RESPONSE 是 Naki 判斷牌局與自動打牌的來源 |
| 全部 `.lq.Route.*` | 連線層（heartbeat、requestConnection）。probe 樣本正是 heartbeat，但只證明內容不變時遊戲吃得下 |
| `isNaki` 流量 | 見 §3，結構上不給 |
| method 對不回（null）的 RESPONSE | 無法判斷是否在表內 |

等長改寫仍沿用 v1 的禁改名單與 `rewriteAllow`，本輪不動。

**放寬條件**，每一類分開判斷：

1. 對該 method 補 live probe，在測試帳號的對局中至少命中 3 次。內容不變、只重派。
2. 三次都要：遊戲 handler 恰收到一次合成事件且無拋錯、連線維持 OPEN、`/game/state` 照常前進、`soak-test.sh` 1 局無異常。
3. 牌局類（`ActionPrototype`、`FastTest.*`）另加：`replay-check.sh` 零插件指紋與 baseline 相同，且 Naki 推薦與畫面一致。
4. 大廳連線：放給使用者前，至少要有一則大廳訊息的 probe 樣本。spike 階段只靠 §0 的推論。

---

## 5. 問題 5：失敗模式與 kill-switch

**觀測遊戲在合成事件上拋錯**：

- 事件 listener 拋出的例外不會傳回 `dispatchEvent`，而是回報到 `window` 的 `error` 事件。
- Naki 在重派前後設一個旗標。旗標開著時收到 `error`，就算遊戲處理合成事件時拋錯，計入 `gameErrors`。
- 這是 probe 的 `errors` 做法的生產版：不包遊戲的 handler，只看 `window` 的 `error`。
- **未驗證**：WebKit 是否在 `dispatchEvent` 回傳前同步送出 `error` 事件。若不是同步，這個觀測會漏，只剩下一次 live 驗收能抓。

**kill-switch**：

| 開關 | 現況 | 作用 |
|---|---|---|
| 插件頁總開關 | **不存在**。只有每個插件的啟用開關與 L3 總開關 `pluginsMayModifyOutbound` | — |
| 停用插件 | 已存在（熱停用） | 零插件時從不攔事件，行為與 main 相同 |
| L3 總開關 | 已存在 | 關掉後 `drop` 一律回 `false`。變長 `replace` 是 L2，不受它影響 |
| 頁面鎖死（本輪新增） | 遊戲在合成事件上拋錯一次就鎖 | 之後不再給插件變長 `replace`／`drop`，頁面重載才解。送一行 log（插件 id `naki`） |
| 自動停用（已存在） | 某 hook 連續失敗 10 次 | 該插件本頁面停用 |

`window.__nakiWebSocket.diagnostics()` 多了 `reshape: {replaced, dropped, fallback, gameErrors}` 與 `reshapeLocked`。

---

## 6. I2：receive 側不能被用來讓遊戲送出未擁有物品的請求

receive 側的改寫不會送出任何東西。但變長 `replace`、`drop`、`injectReceive`、`respondLocally` 都會讓遊戲以為伺服器回了某些內容，遊戲可能接著送出引用未擁有物品的請求。規則如下：

1. **守衛照擋**：送出守衛只看送出的 REQUEST，與 receive 側用哪個原語無關。守衛方法的請求不會原樣外送。
2. **污染**：宣告 `sendGuard` 的插件只要在大廳連線上改了或丟了一則，就污染到頁面重載。本輪已實作：變長 `replace` 經 bytes 比對、`drop` 另外判斷。
3. **`injectReceive`／`respondLocally`（設計）**：在大廳連線上，只開放給宣告非空 `sendGuard` 的插件，而且呼叫一次就污染。沒有守衛的插件不能用它們偽造大廳狀態。對局連線一律不開放。
4. **不宣稱 I2 全域成立**：沒有宣告 `sendGuard` 的插件仍可改大廳回應。這與 v1 等長改寫的現況相同。名單外方法的 I2 仍依解鎖設計 `unlock-plugin.md` §3.7，與 `plugin-v2-b2.md` §1.3 D31 一致。

---

## 7. 問題 6：測試策略

**node**（`scripts/plugin-v2-p4-regression.cjs`，17 條）：

- 假 dispatcher 照 probe 三種：`capture`（target 上 capture 先跑，WebKit 實測）、`order`（照註冊順序）、`nostop`（`stopImmediatePropagation` 無效）。
- `nostop` 只做特性測試：遊戲會收到原事件與合成事件兩份。它說明 probe (a) 為什麼是 gate。
- 遊戲以 `onmessage` 註冊，與 (c) 相同。另外加一個後註冊的 capture listener，模擬遊戲日後改用 capture。

**Swift**（`JSContractTests.testMessageListenerIsRegisteredInCapturePhase`）：在 JavaScriptCore 載入正式模組，確認 message listener 只有一個且是 capture。

**變異**（`.swfd/logs/p4/mutate.cjs`，16 條全被抓）：

| # | 變異 |
|---|---|
| M1 | listener 改回非 capture |
| M2 | 不略過合成事件 |
| M3 | Swift 晚於重派 |
| M4 | 禁改名單漏 `FastTest.*`／`Route.*` |
| M5 | RESPONSE 可 drop |
| M6 | drop 不看 L3 |
| M7 | 拋錯不撤回 drop |
| M8 | 先攔原事件再建合成事件 |
| M9 | 遊戲拋錯不鎖死 |
| M10 | RESPONSE 可帶 method |
| M11 | 不驗 envelope |
| M12 | drop 不短路 |
| M13 | drop 不污染 |
| M14 | 合成事件不帶 origin |
| M15 | Blob 也可改 |
| M16 | 鎖死後仍給變長改寫 |

Swift 測試另做一次變異：拿掉 capture，`testMessageListenerIsRegisteredInCapturePhase` 變紅。

**合併前的 live 驗收（本輪未做）**：

1. 零插件 `replay-check.sh` 指紋與 baseline 相同、`soak-test.sh` ≥3 局。capture 註冊改的是所有人的主路徑。
2. 範例插件對一則大廳 NOTIFY 做變長 replace 與 drop，確認畫面、`diagnostics().reshape`、Naki log。
3. 在遊戲 handler 拋錯的情況下確認 `gameErrors` 會增加（§5 的未驗證項）。

---

## 8. 未決問題（給 Astra 審）

1. `window` 的 `error` 事件在 WebKit 是否於 `dispatchEvent` 內同步送出。kill-switch 依賴它。
2. 大廳連線沒有 probe 樣本。spike 依 (c) 推論允許大廳變長改寫，放給使用者前是否要求先補樣本（§4 第 4 條）。
3. 變長 `replace` 是否應升 L3。現為 L2，沿用 `plugin-v2.md` §4.2，但它比等長改寫更能偽造伺服器狀態。
4. RESPONSE 永不提供 `drop`，是否需要 `respondLocally` 之外的替代。
5. `injectReceive` 用 `setTimeout 0` 交付，中間可能插進網路訊息。是否需要佇列保證「緊接在當前這則之後」。
6. `respondLocal` 不看 `binaryType`（main 既有）。Unity 實際用的 binaryType 只能從 live 的 `diagnostics().receive` 推斷，本輪未查。
7. 頁面鎖死是全頁、不分插件。是否要歸責到這則訊息的改寫者，改成只停用該插件。
8. `drop` 讓 Swift 也看不到這則 NOTIFY。這與 §11 #4「Naki 看遊戲實際收到的」一致，但 Naki 的狀態會與伺服器分叉。需要確認大廳 NOTIFY 被丟時沒有 Swift 端依賴。
9. 契約變更：v1 的 `ctx.replace` 長度不等回 `false`，現在會整包替換。`naki-plugins` repo 的三個範例插件都沒有呼叫 `ctx.replace`，其他第三方插件的影響未知。
10. capture 註冊改的是零插件主路徑。node 與 JSC 都只證明登記參數，WebKit 實際的派發順序只有 probe (d) 一個樣本。
