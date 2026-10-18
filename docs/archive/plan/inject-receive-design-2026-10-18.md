# inject-receive：injectReceive、respondLocally、連線退化事件（設計，2026-10-18）

基底 main `d51e22b`（pair-source 已合併）。依據：`plugin-v2.md` §4.2、§4.3、§4.5；`plugin-v2-b2.md` §1.3、§4.2、§5.3～§5.5、§1.4 第 5 項殘餘（Astra pair-source 第十二輪第 46 條）；`pair-source-design-2026-10-17.md`。本文件只寫決策與取捨，實作待主線裁決。

每項格式：選項／採用／理由。

---

## 1. `injectReceive`

### 1.1 交付時機與入隊位置

- 選項：
  - (a) hook 內同步 `dispatchEvent`。
  - (b) 下一個 microtask。
  - (c) 下一個 task（`setTimeout 0`）交付遊戲與 Swift，交付當下再把觀察用項目排進 `recvQueue` 尾。
  - (d) 直接排進 `recvQueue` 尾，flush 時才交付遊戲。
- 採用：(c)。
- 理由：
  - Naki listener 是 capture，跑的時候目前這則還沒交給遊戲 handler。(a) 會讓合成訊息先於目前這則到遊戲，違反「排在目前這則之後」。
  - 瀏覽器派發的事件在每個 listener 回呼結束、呼叫堆疊清空時就跑 microtask，仍在同一次 event dispatch 中、遊戲 handler 之前，所以 (b) 同樣違反。這是依 HTML 規範的推論，未 live 驗證；node harness 也重現不了，實作時以 WebKit 單測或 live 驗收確認。
  - (d) 把遊戲交付綁在插件觀察的佇列上：前面有待展開的 Blob 時，遊戲會被延後，而遊戲原本對 Blob 的收到時刻不受 Naki 影響，兩者不對稱。
  - (c) 與 `respondLocal` 同一個排程方式。遊戲看到的順序是「目前這則 → 合成」；中間可能插入其他網路訊息，符合 §4.2 的弱順序。
  - 觀察項在交付當下入隊，插件觀察到的順序就等於遊戲收到的順序。前面有待展開的 Blob 時，觀察跟著等，與排隊的同步封包同一規則（pair-source 第十輪）。

### 1.2 交付步驟（task 內）

1. 重查連線仍在 `wsConnections`、未接收不可信。不成立就丟棄，以 `pluginLog` 記錄，不回呼。
2. `sendToSwift('websocket_message', {direction:'receive', data, type:'binary', synthetic:true})`。先讓 LiqiParser 看到，§4.5 第 4 條。
3. 建 `MessageEvent`，登記進 `syntheticEvents`，`ws.dispatchEvent`。Naki listener 略過它，所以 Swift 只收一次。
4. 觀察項 `{ view: 快照, ready: true, synthetic: 插件 id }` 排進 `recvQueue` 尾，再 `flushReceive`。

第 2 步失敗就不做第 3 步（遊戲與 Swift 不分叉，§4.2 理由）。第 3 步有 listener 拋錯時，只記 log，不鎖死：合成 NOTIFY 不攔原事件，與變長改寫的故障語意不同。

### 1.3 是否經 hook 鏈

- 選項：
  - (a) 進一般鏈。
  - (b) 只給 `observeNakiTraffic` observer，`isNaki = true`。
  - (c) 誰都不給。
- 採用：(b)。
- 理由：
  - 插件自己造的內容不應讓其他插件改寫，§4.5 第 1 條。
  - (c) 會讓 Naki observer 與 Swift 看到的流量不一致。
- ctx 標記：
  - `ctx.synthetic = 'injectReceive'`，`ctx.syntheticBy = 發起插件 id`。
  - 沒有 `replace`、`drop`、`sendRequest`、`injectReceive`、`respondLocally`。
  - 沒有 `injectReceive` 是為了切斷「觀察合成 → 再注入」的回授迴圈。

### 1.4 與 pair-source 紀錄的關係

- 選項：(a) 與一般接收相同處理；(b) 完全不碰配對、注入登記、歧義、未答與 D22。
- 採用：(b)。
- 理由：
  - 只允許 NOTIFY，NOTIFY 沒有 msgId，本來就對不到任何紀錄。
  - 實作上 `raw.synthetic` 在 `dispatchRaw` 開頭就跳過所有記帳分支，作為保險，並有變異守住。
  - 不取水位，`watermark` 留空。

### 1.5 拒收條件（回 `{ok:false, reason}`）

| 條件 | reason |
|---|---|
| L3 關 | `outbound_disabled` |
| 沒有 capability `injectReceive` | ctx 沒有這個函式 |
| 呼叫的 ctx 是 isNaki 或合成 | ctx 沒有這個函式 |
| 不是 TypedArray，或長度超過 1 MiB | `bad_bytes` |
| `isWellFormed` 不過、type 不是 1、method 空 | `bad_envelope` |
| method 落在 `isReshapeForbidden`（以 Swift 消費端為來源，含 `ActionPrototype`、`NotifyGameEndResult`、`.lq.FastTest.*`、`.lq.Route.*`）或 `FORBIDDEN_METHODS`；`rewriteAllow` 解不開 | `forbidden_method` |
| 目標連線不在、已關閉 | `no_connection` |
| 目標連線接收不可信 | `receive_untrusted` |
| 該連線待交付超過 32 筆 | `inject_busy` |

- 目標連線：只用 ctx 的連線，不依 method 路由到別條。
  - 放棄依 method 路由：大廳類與對局類 NOTIFY 的歸屬表沒有 live 證據。
- 入口立即複製精確範圍；之後插件改自己的 buffer 不影響交付。
- 回 `{ ok:true }` 的意思是「已排入」，不是「已交付」。第 1.2 步丟棄時不回呼。
  - 不新增回呼，理由是不擴大 API；丟棄只發生在連線關閉或接收不可信，兩者都另有通知（§3）。
- hook 返回後仍可呼叫，例如計時器。弱順序本來就只保證晚於呼叫當下正在處理的那則。

### 1.6 關閉與上限

- 連線釋放時清空該連線的待交付清單，與 `recvQueue` 一起清。之後才到的 task 找不到項目，什麼都不做。
- 上限：每連線 32 筆待交付，超過拒新、不淘汰舊的。
  - 被拒的是呼叫者當下知道的事；淘汰舊的會靜默丟掉已回 `ok:true` 的項目。

---

## 2. `respondLocally`

### 2.1 交付路徑

- 選項：(a) 新的交付函式；(b) 與守衛本地錯誤同一條路徑。
- 採用：(b)。
- 路徑：判決回 `{ block:true, local:'ok', request: original, response, socketId, msgId, method }`。
  - `ws.send` 不呼叫 `originalSend`，改走既有 `respondLocal`。
  - Swift 在同一則訊息收到成對的兩份，其中 `localResponse` 欄位是回應。
  - `ws.send` 回傳後的下一個 task，遊戲收到合成 RESPONSE，再 `localResponse` 結案。
- 理由：成對交付、延後交付、失敗不退回送出，這些性質在守衛路徑已過多輪審查，不再複製一份。

### 2.2 可用條件

`ctx.respondLocally` 只在以下全部成立時存在：
- send 方向。
- 非 isNaki：Naki 自送與插件注入都是 isNaki，所以都沒有，§4.5 第 1 條。
- 非延後派發：Blob 送出已經外送，無從回應。
- capability `respondLocally`。
- 原方法不在禁用名單。

禁用名單＝`isSendForbidden`（非 `.lq.Lobby.*` 一律禁，含全部 `.lq.FastTest.*`、`.lq.Route.*`、登入類、`startUnifiedMatch`、`matchGame`），加 `.lq.Lobby.cancelUnifiedMatch`、`.lq.Lobby.cancelMatch`。

- 名單來源：`plugin-v2.md` §4.3，即 LiqiParser 送出方向有副作用的方法。
- 新增 Swift 契約測試：LiqiParser 的 `startUnifiedMatchMethod`、`cancelUnifiedMatchMethod`、`cancelMatchMethod` 與 `loginResponseMethods` 必須全部出現在 JS 禁用名單，缺一即紅。

### 2.3 呼叫檢查（回 `{ok:false, reason}`）

| 條件 | reason |
|---|---|
| L3 關 | `outbound_disabled` |
| hook 已返回（ctx 過期） | `too_late` |
| 不是 TypedArray，或長度超過 1 MiB | `bad_bytes` |
| `isWellFormed` 不過、type 不是 3、msgId 不等於這筆 REQUEST | `bad_envelope` |
| 本筆已被前面的 hook `replace` 換過內容 | `rewritten` |
| 已有別的插件的提案 | `already_responded` |

- 通過時當場複製精確範圍，存為提案（`plugin-v2-b2.md` 審查第 12 條）。
- `rewritten` 的理由：Swift 收到的是 hook 前的原 REQUEST 快照。被換過的請求再本地回應，兩邊對到的方法不一致。
- RESPONSE 的 field 1（method）可有可無，與變長 receive `replace` 的 RESPONSE 規則一致。

### 2.4 多插件與鏈

- 先到先得。
- 提案被接受後鏈不停止，其他插件照常跑。
- 提案之後的 `ctx.replace` 回 `false`：請求不會送出，改寫沒有意義。
- 第二個呼叫的插件拿到 `already_responded`。
  - 原方法是守衛方法時，依 `plugin-v2-b2.md` §4.2 第 3 步整筆改為本地錯誤（`respond_rejected`）。這裡只看守衛者的呼叫。
  - 原方法不是守衛方法時，先到者的提案保留。

### 2.5 與守衛判定（§4.2）

- 守衛方法依既有表：第 3 步失敗優先，3b 本地成功，4～7 否決送出。
- 非守衛方法：
  - 鏈跑完有提案 ⇒ 本地成功。
  - 鏈拋錯或判決出錯時，若交易上已有提案，仍交付提案。
- 判決之後的 `failSafe`：提案存在 `tx.local`（每筆送出的交易物件，pair-source 第五輪），沒有共用槽位。
  - `failSafe` 看到 `tx.local` 就回本地成功，不照送原請求。
  - 理由：插件已拿到 `ok:true`。照送等於伺服器收到插件說不要送的請求。

### 2.6 記帳結案（pair-source 對齊）

- 派發中保留：`gameDispatching` 照現行在 `dispatch` 結束時移除。
- 未答不提交：伺服器沒收到，現行 `if (game && !block) commitGameSend` 已如此。
- 新增：本地結局，含守衛本地錯誤與 `respondLocally`，要更新遊戲 `last`，但不記未答。
  - 理由：遊戲計數器已經用掉這個號碼。`last` 不前進，避號視窗就落後於遊戲。連續多筆本地結局後，注入可能配到遊戲即將用到的號碼。
  - 這是 pair-source 留下的既有缺口，守衛本地錯誤也有。本包一併修，並補測試。
- 配對：`blockSend` 已在擋下當時撤銷鏈首登記的配對。合成 RESPONSE 經 `syntheticEvents` 略過 Naki listener，不進 `recvQueue`，也不消耗任何紀錄。
- 一般插件看不到這則回應，與守衛本地錯誤相同。只有呼叫 `respondLocally` 的插件知道內容。
- 注入登記與歧義：isNaki 拿不到 `respondLocally`，所以不涉及。

### 2.7 L3 與外送

- L3 只在呼叫當下檢查。
- 同一筆送出的判決是同步完成的，期間只有插件程式碼能改 L3 旗標，屬 U4。

---

## 3. 連線退化事件（Astra 第 46 條）

### 3.1 形狀

- 選項：
  - (a) 新 hook `onConnectionDegraded(ctx)`。
  - (b) 塞進 `onReceive` 的特殊 ctx。
  - (c) 只寫 Swift log。
- 採用：(a)。
- 理由：
  - (b) 會讓方法白名單過濾掉它。
  - (c) 插件無從得知。
- ctx 欄位（唯讀，沒有任何送出或改寫函式）：

| 欄位 | 內容 |
|---|---|
| `socketId`、`url` | 造成退化的連線 |
| `reason` | 見 3.2 |
| `scope` | `'connection'` 或 `'page'` |
| `effects` | 字串陣列：`responses_observe_only`、`notify_observe_only`、`injections_refused`、`reshape_disabled` |
| `recovery` | `'reconnect'`（該連線關閉後恢復）或 `'reload'` |
| `at` | 時間戳 |

- 不要 manifest 宣告：只透露 Naki 自己的狀態，不含任何封包內容。
- 所有已註冊、有這個 hook 的插件都收到，不看 methods、`observeNakiTraffic`，也不看有沒有未答注入。
- 失敗計數與自動停用沿用每 hook 規則。

### 3.2 觸發點

| reason | 觸發點 | scope | effects | recovery |
|---|---|---|---|---|
| `receive_blob_failed` | flush 處理到讀取失敗的項目（`receiveLost`） | connection | responses_observe_only、notify_observe_only、injections_refused | reconnect |
| `receive_queue_overflow` | 佇列超過 256（`receiveLost`） | connection | 同上 | reconnect |
| `send_blob` | 遊戲 Blob 送出（`markUntrusted`） | page | injections_refused | reconnect（該連線） |
| `send_inflight_overflow` | 遊戲未答超過 256（`g.lost`），只在交易結算且未撤回時發 | page | injections_refused | reconnect（該連線） |
| `ambiguity_overflow` | 歧義鍵超過 256，整條連線只觀察 | connection | responses_observe_only | reconnect |
| `reshape_locked` | 變長交付故障鎖死（`reshapeLocked`） | page | reshape_disabled | reload |

- 每個 (連線, reason) 只發一次，連線關閉時清除。
- 不列入：
  - 注入淘汰：只影響發起插件，已有 `response_lost`（`evicted`）。
  - 配對表與 D22 的 FIFO 淘汰：不是模式改變，只是單筆遺失。
- `injections_refused` 的 scope 是 page：沿用 `untrustedSockets` 的全域效果，pair-source 已揭露。

### 3.3 交付順序

- 選項：(a) 觸發點同步呼叫；(b) microtask；(c) 排在造成退化的那則處理完之後、下一則之前。
- 採用：(c)。
- 做法：觸發時只記入 `pendingDegraded`。以下時點才交付：
  - 最外層 `dispatch` 結束（finally）。
  - flush 處理完造成退化的項目之後、取下一項之前。
  - `sendSettled`。
  - `reshapeLocked`。
- 理由：
  - (a) 會在別的插件 hook 中途呼叫其他插件，PS-63 那類重入中尤其如此。
  - (b) 在 flush 同步迴圈裡會晚於後續已排隊的項目，插件會先看到「只觀察」的回應，才知道退化。
- 同時寫一行 `pluginLog('naki', …)`，沿用既有 `plugin_event` kind `log`，Swift 不必改。

---

## 4. 不變條件（`plugin-v2.md` §4.5）與 I2、U4

| §4.5 | injectReceive | respondLocally | 退化事件 |
|---|---|---|---|
| 1 isNaki 不給改寫類 | isNaki、合成 ctx 都不給 | 同左（注入、Naki 自送都是 isNaki） | ctx 無任何寫入函式 |
| 2 禁改名單適用所有原語 | `isReshapeForbidden`＋`FORBIDDEN_METHODS`，`rewriteAllow` 解不開 | 送出禁改名單＋兩個取消方法，`rewriteAllow` 解不開 | 不適用 |
| 3 合成只限 NOTIFY／指定 RESPONSE | type 必須是 1，不得是 `ActionPrototype` | type 必須是 3，msgId 必須是被丟棄的那筆 | 不適用 |
| 4 合成 NOTIFY 讓 LiqiParser 只看一次 | 先顯式送 Swift，再交付，listener 略過 | Swift 收成對的一則；遊戲那份 listener 略過 | 不適用 |
| 5 改寫後可被既有 parser 重讀 | `isWellFormed`、method 非空 | `isWellFormed`、type、msgId | 不適用 |
| 6 零插件行為不變 | 沒有呼叫端 | 沒有提案就走現行路徑；物件同一性測試不變 | 沒有接收者時只寫 log |
| 7 受 L3 把關 | 呼叫時檢查 | 呼叫時檢查 | 不受 L3（唯讀） |

### 4.1 I2：都不新增外送路徑

- **injectReceive**：
  - 交付只呼叫 `sendToSwift` 與 `ws.dispatchEvent`，程式路徑上沒有 `originalSend`、`sendRaw`。
  - 間接效果：遊戲收到合成 NOTIFY 後可能自行送出請求。那是遊戲的送出，照常經守衛與送出禁改名單，與現行 receive 改寫（含變長 `replace`）同級。
  - 禁止產生 Swift 消費的方法，所以 Naki 自己不會因此送出（自動打牌依 `ActionPrototype`，已禁）。
- **respondLocally**：
  - 只減少外送：本地成功時 `ws.send` 走 `respondLocal`，不呼叫 `originalSend`。
  - `failSafe` 看到 `tx.local` 也不照送。
  - 被拒時原請求照現行送出，與沒呼叫相同。
- **退化事件**：唯讀 ctx，沒有 `sendRequest`、`injectReceive`、`respondLocally`。

### 4.2 U4 新增項（同 realm 不防）

- 頁面程式本來就能直接 `ws.dispatchEvent` 偽造訊息。Naki listener 會把它當真處理，這是既有行為。`injectReceive` 不提供比這更強的能力，只多了「讓 Swift 也看到」。
- 偽造或竄改 `syntheticEvents` 判定做不到：它在閉包內。
- 插件保存 ctx、事後呼叫 `respondLocally` 會被 `too_late` 拒絕。保存 ctx、事後呼叫 `injectReceive` 是允許的（§1.5）。
- 包裝 `window.__nakiPlugins.dispatch` 改寫 `raw.tx.local`，可讓別筆送出被本地回應，與 pair-source 的 `raw.tx.commit` 同級。

---

## 5. 測試計畫

- 套件：併入 `scripts/plugin-v2-b2-regression.cjs`，新段落 `IR-*`。
  - 理由：沿用 `page()` harness、FileReader 與 Blob 替身。變異 harness 已固定跑 b2／v2／p4，新開檔案要再改 harness。
- 反例與行為測試（實作時先紅）：
  - injectReceive：
    - 遊戲順序晚於目前這則。
    - 觀察順序：前面有待展開 Blob 時等待。
    - Swift 只一次。
    - 不碰配對、注入登記、未答。
    - 每個拒收條件各一。
    - 關閉時清空。
    - 32 筆上限。
    - 接收不可信時拒收，交付前轉為不可信則丟棄。
    - 合成 ctx 沒有寫入函式。
  - respondLocally：
    - 成對交付與延後交付。
    - 禁用名單兩側。
    - `too_late`、`rewritten`、`already_responded`。
    - 守衛方法第 3 步與 3b 步。
    - `failSafe` 看到 `tx.local`。
    - 本地結局更新 `last`，連續 300 筆本地結局後注入不落入遊戲下一號。
    - 零插件物件同一性不變。
  - 退化事件：
    - 六個 reason 各觸發一次，只發一次。
    - 順序：在造成它的那則之後、下一則之前。
    - 無未答注入的一般插件也收到。
    - ctx 唯讀。
    - 撤回的 `send_inflight_overflow` 不發。
- 變異目標，預計 ≥15：
  - 交付改 microtask 或同步。
  - 觀察項不入隊。
  - 合成進一般鏈。
  - 合成 ctx 帶寫入函式。
  - 合成消耗紀錄。
  - 禁用名單少一項。
  - 拒收各條件。
  - `tx.local` 被 `failSafe` 忽略。
  - 本地結局不更新 `last`。
  - 退化事件同步交付、重複發、漏發。
- Swift：
  - `JSContractTests` 新增 respondLocally 禁用名單反查測試。
  - `PluginsPageView` 的 L3 開關說明補上 `injectReceive`、`respondLocally`。
  - 其餘 Swift 不改：合成 NOTIFY 與成對本地交易都走既有 bridge 訊息。
  - 跑 `JSContractTests`＋`PluginSendGuardTests`，再跑全量。
- live（另案，測試帳號）：
  - 一則無害 NOTIFY 的 `injectReceive`。
  - 一個非守衛、無副作用方法的 `respondLocally`。
  - 確認遊戲在 `ws.send` 回傳後收到回應不卡。
  - 未 live 前只宣稱單測。

---

## 6. 不做什麼

- 不依 method 自動路由 `injectReceive` 的目標連線。
- 不做 `injectReceive` 交付結果回呼，不做 `onSocketClose`。
- 不讓 `rewriteAllow` 解開任何本包原語。
- 不改 LiqiParser、MajsoulBridge、LiqiActionSender、AutoPlay。

## 7. 待裁決的取捨

1. 本地結局更新遊戲 `last`（§2.6）會連帶改變守衛本地錯誤的行為（更保守），是否同包修。
2. `injectReceive` 的 32 筆上限與 1 MiB 長度上限是啟發式，沒有 live 數據。
3. `reshape_locked` 納入退化事件，會讓既有的鎖死多一個插件可見的通知。
4. 實作會改 `naki-websocket.js`（WebSocket bridge），依 Naki CLAUDE.md 須先確認。本包的外送面只減不增（§4.1），裁決時請一併確認。

## 8. 裁決（2026-10-18，主線）

15 項全採納。待裁決四項：(1) 同包修，本地結局更新遊戲 `last`；(2) 32 筆與 1 MiB 接受為啟發式，具名常數集中放，未以 live 量測；(3) `reshape_locked` 納入；(4) 可改 `naki-websocket.js`，依據是用戶 2026-10-17「都自動」裁決，且三功能都不新增 Liqi 外送。另補：`setTimeout 0` 的順序推論標未 live 驗證並列入 live 另案；退化事件的恢復方式寫明為連線關閉後重連。實作與偏離見 `docs/archive/notes/inject-receive-implementation-notes.md`。

## 9. 第二輪修訂（Astra 第一輪，2026-10-18 主線裁決）

Astra 4【擋】7【應修】全採納、根治。下列各點取代本文件對應段落，現行契約以 `docs/plugin-api-v1.md` 為準，逐條回應見 notes「審查回應」。

- §2.4 多守衛：回到 b2 §4.2 判定表，守衛方法上只收守衛者的提案，非守衛者回 `not_guardian`；守衛者的拒絕以呼叫當時的身分計入第 3 步。
- §2.6 遊戲 `last`：依遊戲進入送出的順序更新（不比號碼大小）；本地回應交付前另保留號碼，不算未答。
- §3.3 交付順序：退化事件改在觸發後的下一個 task 交付，取代「最外層 dispatch 結束」的深度判斷。
- §1 `injectReceive`：觀察項與網路接收共用佇列上限；交付當下重查連線仍是同一筆紀錄且 OPEN。
- §4.1 I2：宣告 `sendGuard` 的插件，`injectReceive`／`respondLocally` 一被接受就污染。

## 10. 第三輪修訂（Astra 第二輪，2026-10-18 主線裁決）

0 擋 4 應修 1 建議全採納。取代對應段落：

- Swift 副作用方法改為共用來源 `LiqiSideEffectMethods`（在 `LiqiRequestBuilder.swift`），bridge 分支只引用它；契約測試對照集合，另以原始碼規則禁止集合外的 `.lq.` 字面值與 builder 方法常數。
- 退化事件一次只交付當時的批次，回呼內新觸發的排到下一個 task；hook 的取得與呼叫一起隔離。
- 本地回應保留號碼加容量政策：每連線 256 筆待交付的 `respondLocally`，滿了回 `local_busy`；排程失敗立即釋放；`diagnostics().localPending`。

## 11. 第四輪修訂（Astra 第三輪，2026-10-18 主線裁決）

0 擋 5 應修 1 建議全採納。取代對應段落：

- 本地回應的號碼保留以送出交易為單位：`respondLocally` 接受當下就建立並計入每連線 256 筆上限，守衛擋下、本地成功、failSafe 再結案都沿用同一筆；交付、排程失敗、沒有回應可交付、連線關閉時移出。每筆交易至多一筆、至多釋放一次（以保留物件的集合成員為準，重複移出無作用）。
- `injectReceive` 排不進 task 時撤回入隊項，回 `schedule_failed`。退化事件的「已排程」旗標在排程成功後才設；失敗不拋進觸發點、不主動重試，事件留著，下一次退化觸發排程成功時一起交付。
- Swift 集合完整性：`LiqiSideEffectMethods` 的每個常數必須併進 `consumed`／`all`；掃描範圍擴到 `command/Services`，以集合外的字面值與 builder 方法常數名為準，例外改為逐檔整行比對、只用一次、過期也紅。builder 本體以完整性那條覆蓋。
- 連線關閉時排隊中的合成通知各寫一行插件 log（補交付，契約不改）。
- 守衛擋下不受容量上限；契約不稱有界佇列，耗用資源屬 U4。

## 12. 第五輪修訂（Astra 第四輪，2026-10-18 主線裁決）

0 擋 3 應修全採納。取代對應段落：

- 退化事件的「去重入隊」與「喚醒排程」分開：同一個 (連線, reason) 只入隊一次，但任何觸發（含同 key）在有待交付事件且未排程時都重排。
- builder 常數解析支援型別註記與 `static var`；本體裡解析器認不出的宣告形式或宣告外的 `.lq.` 字面值明確報紅；builder 本體也逐行掃描，只略過常數宣告與 `LiqiRequestSpec(method:)` 送出定義。
- `respondLocally` 被拒的結局限定為「非守衛方法、且整筆沒有已接受提案時照常送出」；守衛方法一律依 b2 §4.2，已有接受提案時交付先到者。
