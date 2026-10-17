# 插件系統 v2：送出守衛（N1、N2）與 PV2-B2 變長原語

**資料日期**：2026-10-15
**狀態**：設計已提議，未拍板。審查第一輪（Astra 14 條）與第二輪（新發現 7 條）已改，見 `plugin-v2-b2-review-response.md`。第五輪（2026-10-17）改以協定握手鎖定連線角色（§1.4）。第三輪起 spike 也改了 `LiqiParser` 的配對狀態（§1.2），與接線一樣，合併前要經主線向用戶確認。N1／N2 有最小 spike（分支 `pv2-b2-design`，基準 main `4761f6e`，落後 main，見 §9）：`naki-plugins.js` 的守衛判定、污染狀態、錯誤回應建構、本地回應結案，加 `PluginRegistry.swift` 的 `sendGuard` 欄位。`naki-websocket.js` 的接線**未改**，以 patch 提出（§3.6，待用戶確認）。PV2-B2 四個原語只有設計。
**決策紀錄**：`docs/archive/notes/plugin-v2-b2-implementation-notes.md`（含 Deviations）。
**上位文件**：`docs/archive/plan/plugin-v2.md`（§4 原語與順序、§4.3 respondLocally、§4.4 rewriteSend、§4.5 不變條件、§9 probe、§12.3 protobuf 保真）、`docs/plugin-system-design.md` §11 #6（Phase 4 gate）、`docs/plugin-api-v1.md`（現行契約）。本文件不推翻任何拍板。
**需求來源**：naki-plugins repo 分支 `local-unlock-v01` 的 `docs/plan/unlock-plugin.md` §3.5–3.7、§8.2（N1–N6）。

---

## 0. 用戶裁決

**2026-10-17**：解鎖守衛照「協定握手鎖定角色」繼續，送第五輪審查。不做整體架構抽象化。D22（Naki 自送身分只看 msgId）維持另開工作包。

- 範圍判定改為連線角色（§1.4）：N1 守衛與 N2 失敗拒送（含 `failSafe`、`refuseOpaqueSend`）只作用在協定握手鎖定為 lobby 的連線，URL 不參與。
- game 與 unknown 連線、所有 `.lq.FastTest.*` 在 `dispatch` 開頭就走現行鏈，行為與 main 相同。任何內部錯誤都不得擋下它們，也不得擋下 Naki 自送的對局動作（§1.3）。

**2026-10-15**：守衛收窄到只守大廳連線，再修一輪；第四輪審查若仍有【擋】，解鎖 v1 暫停。第四輪仍有 1 條【擋】（URL 子字串判定），依此暫停（notes D24），2026-10-17 由上一條裁決恢復。

- Naki 自送身分只看 msgId 是既存缺口，另開工作包；本輪只證明它在守衛範圍內的後果（§4.6）。

---

## 1. 目標、模組邊界、資料流

### 1.1 目標

1. **N1 送出守衛**：插件在 manifest 宣告守衛方法。插件「已污染」後，守衛方法的 REQUEST 到頁面重載前都不會原樣送出，即使插件被停用、自動停用、熱重載失敗或 L3 關掉。
2. **N2 送出側 fail-closed**：守衛方法的 REQUEST 只有三種結局：插件放行而原樣送出、本地成功、本地錯誤。不存在「hook 出錯就撤回成原樣送出」。
3. **PV2-B2**：變長 receive `replace`、receive `drop`、`injectReceive`、`respondLocally`（`plugin-v2.md` §4.2–§4.3 的設計照用，本文件補上與守衛的關係與 live 證據）。

### 1.2 模組邊界

| 模組 | 責任 | 本包是否改 |
|---|---|---|
| `PluginRegistry.swift` | manifest `sendGuard` 驗證（非空、`.lq.Lobby.*`、在 `methods` 內），放進 grant | spike 已改 |
| `naki-plugins.js` | 守衛判定、污染狀態、錯誤回應 bytes、每筆 msgId 的結局紀錄；B2 原語的合規檢查與鏈 | spike 已改守衛部分 |
| `naki-websocket.js` | 依 `dispatch` 的結果決定送什麼、交給遊戲什麼、交給 Swift 什麼；本地回應的交付；略過自己合成的事件 | **未改**，patch 待用戶確認（§3.6） |
| `WebSocketInterceptor.handlePluginEvent`、插件頁 | 顯示已污染、停用時提示重載 | 未改（N1 工作包） |
| `LiqiParser`、`MajsoulBridge`、`WebSocketInterceptor.handleWebSocketMessage` | `pendingRequests` 改以「連線＋msgId」為鍵；`socketId` 從 bridge 訊息一路傳到 `LiqiParser.parse`（審查第二輪第 2 條）。`handleWebSocketMessage` 處理帶 `localResponse` 的本地交易：兩份都解得開才依序處理 REQUEST 與 RESPONSE（第三輪第 3 條）。`majsoulBridge` 改為 `private(set)` 供測試讀 `lastParsed` | spike 已改，**合併前需用戶確認** |
| `LiqiResponseStore`、`ObservedMatchSids`、`LiqiParser.isNakiSent` | 不讀 `pendingRequests`：前兩者吃 `parse` 的結果，`isNakiSent` 只看全域的 `LiqiMsgIdAllocator`。連線維度不影響它們 | 只改 `LiqiResponseStore` 一行註解 |
| `AutoPlay*`、`LiqiActionSender` | 不改。`LiqiActionSender` 的回應經 `sendRaw` 選定的那條連線回來，配對鍵自然一致 | 不碰 |

### 1.3 資料流

**send（守衛方法，§3、§4）**

```
ws.send(data)
  前提：以下守衛步驟只在角色已鎖定為 lobby 的連線上發生（§1.4）。dispatch 先鎖定角色再分流：game、unknown 連線
        與任何連線上的 .lq.FastTest.* 直接走現行鏈，鏈內例外與鏈後檢查都不經守衛。failSafe、refuseOpaqueSend 都先看角色。
  0. Blob 等無法同步辨識的送出：lobby 連線上有守衛者時 refuseOpaqueSend ⇒ 拒送（§4.5）
  1. attributeSend(原始 data)                         不變
  2. nakiNicknameMask.observe                         不變（這裡或之後出錯 ⇒ failSafe 仍擋守衛方法）
  3. dispatch → 鎖定角色 → guardedSend（跑鏈與鏈後判定在 try 內；拋錯時只擋可守衛方法，見下文）
       先複製完整原 REQUEST（original），守衛者為空 ⇒ 照現行鏈；鏈結果的最終 method 若是守衛方法 ⇒ 擋下
       否則：isNaki ⇒ 直接擋下；跑鏈，記錄每個守衛者的 放行／拋錯／非同步，再判定（§4.2）
     dispatch 本身或 handleMessage 在派發前出錯 ⇒ failSafe（同樣規則，自己不拋錯）
         放行 ⇒ 回 undefined（原物件送出）
         擋下 ⇒ 遊戲 buffer 還原，回 { block:true, reason, request: original, response: 錯誤回應或 null, msgId, method: 原方法 }
         [B2] respondLocally 成功 ⇒ 回 { block:true, local:'ok', request: original, response: 插件給的 RESPONSE }
  4. 擋下：handleMessage 立刻回傳 block，不再編碼、不再送 Swift；ws.send 不呼叫 originalSend，改 respondLocal
       respondLocal（同一個 task 內）：複製 request、response 的精確範圍，兩份都先編碼
                    兩份都編碼成功才送 Swift，而且是**同一則**訊息：{ direction:'send', data: request, localResponse: response }
                    response 為 null（原方法回應型別未確認）⇒ Swift 與遊戲都不送
       下一個 task：遊戲那份另複製一次，合成 MessageEvent 登記進 localEvents，ws.dispatchEvent   ← Naki listener 略過
                    __nakiPlugins.localResponse(連線, msgId, 原方法, 自己的快照)   ← 清 (連線, msgId) 對照；插件注入的請求交回 onInjectResponse
  5. 放行：照現行送 Swift（一次）與 originalSend
```

- **配對隔離**（審查第二輪第 2 條、第三輪第 2 條）：JS 端 `pendingMethods`（`rememberIfRequest`、`resolveMethod`、改寫後登記）、`injectedMsgIds`、`localResponse` 一律以「連線＋msgId」為鍵，verdict 帶 `socketId`；`sendRequest` 以 `sendRaw` 實際選到的連線登記（測試 `R4-2`：A 連線本地結案後，B 連線 `loginBeat(303)` 的真回應仍交給 `onReceive`）。Swift 的 `pendingRequests` 以「連線＋msgId」為鍵。A 連線被擋的合成 RESPONSE 只會消耗 A 的登記；B 連線先送出、仍在等的同 msgId 不受影響（`PluginSendGuardTests.testLocalExchangeOnOneSocketDoesNotConsumeAnotherSocketsPending`，修前紅、修後綠）。
- 同一連線內，原 REQUEST 與合成 RESPONSE 在同一個 task 連續送 Swift（D10）。這只排除「兩次交付之間插入新的同 msgId 請求」，已存在的登記由上一條處理。WebKit 依序遞送 `postMessage` 是推論，未 runtime 驗證。
- **成對交付**（審查第二輪第 3 條、第三輪第 3 條）：Swift 只會收到「REQUEST＋RESPONSE」一對，或什麼都不收。
  - 做法：一對放在**同一則** bridge 訊息（`localResponse` 欄位）。`postMessage` 只呼叫一次，失敗時兩份一起不見。`naki-core.js` 的 `sendToSwift` 會吞掉 `postMessage` 的例外，所以 JS 無法得知是否送達；改成單一訊息後，這件事不再影響成對性。
  - Swift 端：`handleWebSocketMessage` 先解 REQUEST 與 `localResponse` 兩份 base64，任一解不開就整筆不處理；兩份都好才依序 `observeOutgoing`、處理回應（`testLocalExchangeMessageIsProcessedAsOnePair`、`testUndecodableLocalResponseDropsTheWholeExchange`）。
  - 第三輪記的 D15「反方向不可能」論證撤回：Astra 以正式 `sendToSwift` 重現了兩種半套（`postMessage` 拋錯被 core 吞掉）。測試 `R4-3` 以正式 core 讓 `postMessage` 在兩個方向各失敗一次，Swift 都是零筆或一對。
- **socketId 契約**（第三輪第 6 條）：
  - JS 一律帶 `socketId`（每條連線的 `wsId`）。
  - bridge 訊息缺 `socketId` 時，Swift 以 -1 代替，而且 -1 **參與配對**：兩端都缺值時彼此配得上，只有一端缺值時配不上，缺值的訊息之間無法依連線隔離。
  - 直接呼叫 `LiqiParser.parse`／`MajsoulBridge` 而省略參數時是 0，0 與 -1 不互通。
  - 測試：`testSocketIdDefaultsAndMissingValues`（三種邊界）。錄影 replay 直接消費 MJAI 事件、不經這個 parser，replay 綠不能當配對證據。
- 交給 Swift 的是 hook 執行前的完整快照，不是 hook 改過的 bytes（審查第 7 條）。
- 遊戲在 `ws.send` 回傳**之後**才收到回應（`setTimeout 0`）。理由見 `plugin-v2.md` §4.3：遊戲可能在 `send` 回傳後才登記回應等待（推測，未驗證）。
- 擋下的決定作出後，記錄、編碼、送 Swift、建構回應、交付任一步失敗，都不會退回送出（審查第 3 條）：`blockSend` 不拋錯；`handleMessage` 拿到 block 就回傳；`respondLocal` 的編碼與送 Swift（同一個 try）、排程、交付、結案各有 try，`ws.send` 拿到 block 後只呼叫 `respondLocal`、不會再走到 `originalSend`。
- 擋下的決定之前（辨識、跑鏈、鏈後判定）拋錯（審查第二輪第 1 條、第三輪第 1 條、第四輪第 2、3 條）：
  - game、unknown 連線與 `.lq.FastTest.*`：在 `dispatch` 開頭就走現行鏈，不進 `guardedSend` 的 try。鏈拋出的例外照 main 由 `naki-websocket` 的 catch 接住，`failSafe` 依角色與方法照送（測試 `R4-1a`、`R4-1b`、`R4-1e`、`R4-1f`、`R4-1g`、`R5-1a`、`R5-2a`）。現行鏈的「就地改寫成守衛方法」檢查只在 `guardedSend` 呼叫的鏈上做，所以這些流量完全不讀 `sendGuard`（`R5-2b`）。
  - lobby、已知是守衛方法：擋下（`dispatch_error`）。
  - lobby、守衛查找拋錯：原方法或改寫後的方法在 `GUARDABLE_METHODS` ⇒ 擋下（`guard_error`；原方法可守衛時合成錯誤回應）。其他已解析的請求還原原始 bytes 照送（D27，測試 `R5-3`、`R4-1d`）。
  - lobby、封包解析不出：頁面上有守衛者（`guardActive`，查找本身出錯也算有）才擋下（`guard_error`），不合成回應；沒有守衛者照送（`R5-1f`）。
  - `dispatchToPlugins` 與 `handleMessage` 的 catch 都改呼叫 `failSafe(data, socketId)`，規則相同；`failSafe` 也先鎖定角色（`R3b`、`R302`、`R5-3b`）。
  - D27 只看原方法：實際送出的是還原後的原 bytes，改寫後的方法不會外送（D33，測試 `R6-6`）。判斷只用閉包內的常數名單與 parser，不讀出錯的 grant。
  - D27 與 I2 的關係（D31）：名單只說明「哪些方法可以宣告守衛」，不證明名單外的方法不會引用未擁有物品。例如 `useBagItem` 與 `changeCharacterSkin` 同為 `ResCommon`，查找出錯時照送。D27 本身不比「守衛健康時」多放行任何方法：名單外的方法在守衛健康時本來就不經守衛。I2 對名單外方法成立，要靠解鎖設計（naki-plugins `local-unlock-v01` 的 `unlock-plugin.md` §3.7）的三個條件：插件不改背包與商店回應、攔不住的入口以縮小功能處理、live 驗收出現表外方法時停用 F4–F9。本設計不單獨宣稱 I2。
  - 代價：守衛查找壞掉期間，守衛方法仍全數拒送（換裝失敗），直到頁面重載或插件修好。心跳、`fetchAccountInfo`、`startUnifiedMatch` 等照送。
- 一般插件看不到守衛合成的 RESPONSE（它不經改寫鏈）。發起請求的插件（`sendRequest`）經 `onInjectResponse` 收到，`ctx.local === true`、`ctx.method` 是原方法（審查第 8 條、第二輪第 5 條）。結案用擋下當時記下的連線、msgId 與原方法，bytes 是交付前另存的快照；遊戲改動它收到的那份不影響結案（測試 `R5b`）。結局另記在 `__nakiPlugins.guardState().log` 與 Swift log。

**receive（B2，§5.2）**：Naki listener 改 capture 註冊；變長 `replace` 時 `stopImmediatePropagation`，Swift 收到新 bytes 一次，遊戲收到合成事件；`drop` 時兩者都收不到。等長或不改時與現行相同。

**inject（B2，§5.4）**：先 `sendToSwift`，再合成事件交給遊戲，Naki listener 略過。

### 1.4 連線角色鎖定（第五輪，D25）

**live 依據**（2026-10-17，測試帳號，主 repo `.swfd/logs/unlock-handshake-20261017/`）：每條連線第一個請求是 `.lq.Route.requestConnection`，第二個才揭露角色。`/gateway` 是 `.lq.Lobby.oauth2Login`（登入）或 `.lq.Lobby.prepareLogin`（備援，之後只有 `.lq.Route.heartbeat`）；`/game-gateway` 是 `.lq.FastTest.authGame`。對局結束後的重連序列相同。

**規則**（`naki-plugins.js` 的 `roles`、`lockRole`；與 `pendingMethods` 同在閉包，以 socketId 為鍵）：

| 事件 | 角色 |
|---|---|
| 新連線 | unknown（不在 `roles`） |
| 第一個解析成功的 `.lq.Lobby.*` REQUEST | lobby |
| 第一個 `.lq.FastTest.*` REQUEST | game |
| `.lq.Route.*`、RESPONSE、解析失敗 | 不變 |
| 已鎖定之後的任何請求 | 不變 |
| 連線關閉（接線呼叫 `closed(socketId)`） | 清除 |

- 只有 lobby 進守衛路徑；unknown 與 game 走現行鏈（fail-open）。URL 不參與任何判定。
- 鎖定是 `dispatch` 的第一步，早於「零插件就返回」。沒有插件時，每條連線也只解析到鎖定為止；之後才啟用的守衛一開始就認得大廳（`R5-1h`）。`failSafe` 同樣先鎖定，所以派發前出錯的第一個 Lobby 請求也適用（變異 M8）。
- 角色只活在閉包裡，插件碰不到。守衛查找依賴的 grant 可能被插件改壞，但不影響角色判定。

**證明：鎖定前的空窗漏不出守衛方法（限同步可解析的原 REQUEST）**

適用範圍：遊戲或插件以 ArrayBuffer／TypedArray 送出、`parseEnvelope` 解得開、且送出的 bytes 就是鏈開始時的原 REQUEST。Blob 只能非同步解析，改由 `refuseOpaqueSend` 處理（guard-gaps c，見下方「保證範圍」）。就地改寫成守衛方法會在 hook 後撤回（guard-gaps b），所以送出的 bytes 仍是原 REQUEST。

1. 守衛方法 ⊆ `GUARDABLE_METHODS`（`register` 驗證），全部是 `.lq.Lobby.*`。
2. `dispatch` 對 send 方向先解析並 `lockRole`，**之後**才判斷角色。守衛方法的 REQUEST 送進 unknown 連線時，同一次呼叫裡先把連線鎖成 lobby，再以 lobby 的規則判定自己。測試 `R5-1d`：`requestConnection` 之後直接送 `changeCharacterSkin`，守衛 hook 拋錯 ⇒ 擋下。變異 M3（鎖定移到判定之後）有 12 條測試失敗。
3. 連線已是 lobby 時直接適用。已是 game 時見下方「保證範圍」第 5 項。
4. 因此 unknown 連線上走現行鏈的只有 `.lq.Route.*`、RESPONSE、解析不出的 bytes。前兩者不是守衛方法，被就地改成守衛方法時撤回；解析不出的見下。unknown 上的 Blob 在有守衛者時拒送。

**unknown 連線上解析失敗的請求照現行鏈送出**

- 理由：遊戲自己的封包 Naki 向來解得開，unknown 只存在於握手前兩個請求之間。若拒送，握手前任何解析問題都會讓大廳或對局連不上，違反 §0 的 fail-open。
- 風險：Naki 解析不出、伺服器卻解得開的守衛方法若出現在 unknown 連線上，會原樣送出。插件改寫產生的 bytes 不會落到這裡：`rewriteSend` 只掛在 `.lq.Lobby.*` 請求上，那筆請求已把連線鎖成 lobby，改寫結果由 lobby 的鏈後檢查處理（`rewritten`、`isWellFormed`）。

**保證範圍（第五輪審查後改寫，D28–D32；guard-gaps 2026-10-17 修掉 D28–D30）**

守衛保證：已鎖定為 lobby 的連線上，同步可解析、經 `ctx.replace` 契約改寫的守衛方法不原樣外送。guard-gaps 另外補上三條，原本是本節第 1–3 項：

- **插件注入退回非大廳連線**（原 D28，測試 `R6-1`、三條 `guard-gaps a`、`GG2-2`、`GG2-3`、`GG2-6a`、`GG2-6b`）：`ctx.sendRequest` 呼叫 `sendRaw` 期間設一個注入標記（msgId＋是否用過），`finally` 還原外層標記。標記只認同 msgId 的**第一次**送出派發，用過即失效；hook 在這次派發裡同步送出的同號請求不算注入。若連線不是 lobby、方法屬 `GUARDABLE_METHODS`、而且有守衛者，就以 `tainted_fallback` 擋下，與大廳上的 `naki_traffic` 同一規則：未污染的已註冊守衛者也算。不可能有守衛的方法先以常數排除，不讀 `sendGuard`。插件看到的結果與大廳相同，`sendRequest` 回 `ok:true`，之後 `onInjectResponse` 收到 `ctx.local === true` 的錯誤回應。守衛查找出錯時擋下（方法已在 `GUARDABLE_METHODS`）。Naki 自送與遊戲自己的請求不經這個判定。`naki-websocket.js` 不改。
- **非大廳連線上改寫成守衛方法**（原 D29，測試 `R6-2`、`guard-gaps b`、`GG2-1`、`GG2-4`、`GG2-6c`）：大廳以外的連線（game、unknown，以及大廳上的 FastTest），hook 不論就地改 `ctx.bytes` 或經 `rewriteSend` 的 `ctx.replace`，改後能解析成 `GUARDABLE_METHODS` 的任一方法，就當成 hook 失敗並撤回這個 hook 的改動，先前 hook 的合法改寫保留。判斷只用閉包常數，不讀 `sendGuard`，第四輪第 2 條（`R5-2b`）不受影響。成功記帳在驗證之後，連續 10 次違規自動停用。大廳上維持 §4.1：就地改成另一個守衛方法時撤回，經 `replace` 改成守衛方法在 `replace` 當下拒絕，同方法改內容由鏈後 `rewritten` 擋下。撤回後送出的不含改寫成的守衛方法，不必再污染。
- **Blob 空窗**（原 D30，測試 `R6-3`、`guard-gaps c`、`GG2-5`）：角色未定的連線比照 lobby，有守衛者時拒送 Blob，紀錄原因 `opaque_unknown_role`。被拒的 Blob 不派發，所以不鎖定角色。只有已鎖 game 的連線照送（`R4-1c`、`R5-1b`）。
  - **獨立風險（第二輪第 5 條）**：若客戶端只把對局連線的握手（`authGame`）改用 Blob、大廳維持 TypedArray，頁面上有守衛者時大廳正常，對局連線每次重試都被拒、角色一直是 unknown、沒有本地回應，**不會自行恢復**。要停用所有宣告 `sendGuard` 的插件；若已污染，還要重載頁面（重載後守衛插件若仍啟用，會再次拒送）。這不是「大廳本來就不可用」能涵蓋的情況。live 證據是客戶端送 TypedArray；可觀測 `__nakiWebSocket.diagnostics().send.Blob` 與 `guardState().log` 的 `opaque_unknown_role`。

以下情境仍不在保證內，確認稿須逐條揭露；不以 U4（惡意插件）帶過，因為誤用也可能觸發：

1. **D26 的繞過限定封包形態**（D32，測試 `R6-4`）：已鎖 game 的連線不受守衛拒送。lobby 上只有同步可辨識、未被改壞的 FastTest 繞過守衛；被 observer 改壞成無法解析的 FastTest，若之後 bridge 出錯，`failSafe` 依改後 bytes 判為無法解析而拒送；lobby 上的 FastTest Blob 由 `refuseOpaqueSend` 拒送。live 未見 lobby 上的 FastTest。
2. **已鎖 game 的連線上出現 `.lq.Lobby.*` 請求**：照規則不改角色、不守衛（`R5-1e`）。插件注入的由上面第一條擋下；hook 經就地或 `ctx.replace` 改成可守衛方法、或改動既有可守衛方法的內容，都會撤回。仍會原樣外送的來源：Naki 自送經 `sendRaw` 退回（Naki 的 Swift 端目前沒有送任何可守衛方法）、遊戲本身（live 未見）、插件改寫成 Naki 解析不出的 bytes（見第 3 項）、hook 在派發之外改寫保留的 buffer 參照（同步派發之外不檢查）。
3. **Naki 解析不出、伺服器解得開的守衛方法**：unknown 連線上照送（上方「unknown 連線上解析失敗」）。非大廳連線上 hook 改寫成這種 bytes 也不撤回，因為判斷依賴解析；`rewriteSend` 的 `replace` 另有 `isWellFormed` 把關，就地改寫沒有。
4. 角色在連線關閉時清除，只靠接線呼叫 `closed`。沒呼叫時只是記憶體不回收；socketId 每頁單調遞增、不重用，不影響判定（變異 M7 只讓 `R5-1g` 失敗）。

---

## 2. 依據的既有決策與 live 事實

| 來源 | 內容 | 對本設計的約束 |
|---|---|---|
| `plugin-system-design.md` §11 #6 | probe (a)(b)(c) 全綠才開工 Phase 4 | 對局 (b) 補驗綠是 B2a 開工前置（§7） |
| `plugin-v2.md` §4.3 | respondLocally：被丟棄的 REQUEST 仍送 Swift；回應延到 `ws.send` 回傳後；禁用名單＝送出禁改名單加 `cancelUnifiedMatch`、`cancelMatch` | 守衛的錯誤回應走同一條交付路徑與同一份禁用名單 |
| `plugin-v2-adr-2026-10-14.md` 主線決定 | 動到 `ws.send` 接線前依 CLAUDE.md 先向用戶確認 | spike 不改 `naki-websocket.js`（Deviation D1） |
| U4（`design-review-2026-10-12-decisions.md`） | 授權防誤用、不防惡意 | 污染狀態放在插件碰不到的閉包，但不宣稱防惡意插件 |
| live 2026-10-15（`.swfd/logs/live-20261015/`） | 大廳兩條連線與對局連線：遊戲都只用 `onmessage` 註冊（`gameVia.addEventListener 0`、`onmessage 1`）；同步在 listener 內 `dispatchEvent` 合成事件，遊戲收到一次 | 合成事件交付機制在大廳已有 live 證據 |
| `docs/protocol/liqi.json` | §3.6 的 19 個守衛方法，回應型別 field 1 都是 `Error`；Lobby 全部 419 個方法中有 19 個不是（例如 `fetchServerTime`） | 錯誤回應只寫 field 1；不是這種形狀的方法不得進 `sendGuard`（§3.4） |

---

## 3. N1 送出守衛

### 3.1 manifest

```json
{ "methods": [".lq.Lobby.changeCharacterSkin", ".lq.Lobby.fetchCharacterInfo"],
  "sendGuard": [".lq.Lobby.changeCharacterSkin"] }
```

- `sendGuard` 選用。宣告時必須非空；每個方法必須以 `.lq.Lobby.` 開頭且列在 `methods` 內。不合 ⇒ `manifestInvalid`，整個插件不載入（Swift，`PluginManifest.validate`）。
- **只能是已確認回應型別的方法**（審查第 10 條）：`naki-plugins.js` 的 `GUARDABLE_METHODS`，即 `unlock-plugin.md` §3.6 的 19 個方法；它們的回應型別 field 1 都是 `Error`（`liqi.json`）。不在名單內 ⇒ `register` 拒絕並記 log。名單內沒有送出禁改名單與 `cancelUnifiedMatch`、`cancelMatch` 的方法，所以那兩條規則由它涵蓋。例：`fetchServerTime` 的 field 1 是 `server_time`，被拒（測試 `register rejects sendGuard methods outside the confirmed-response allowlist…`）。
- PV2-C 把 `liqi.json` 打包進 App 後，改成依 schema 檢查「回應型別 field 1 是 `Error`」，名單可擴大。在那之前名單是唯一入口，作者無法繞過。
- 被拒的插件不會註冊；N1 工作包的插件頁要顯示拒絕原因（Astra 對 D5 的意見）。

### 3.2 「已污染」的定義與觸發

插件 P 宣告了 `sendGuard`，且在本頁面中第一次發生下列任一事件時，P 進入已污染：

1. P 的 `onReceive` 成功結束，且**大廳連線**（url 不含 `game-gateway`）的這則訊息 bytes 與 hook 執行前不同。等長 `replace`、直接改 `ctx.bytes` 都算（spike 已實作，以 hook 前的快照比對）。
2. [B2] P 對大廳訊息做變長 `replace` 成功。
3. [B2] P 的 `respondLocally` 成功。

污染紀錄是「P → 污染當下 P 的 `sendGuard` 方法集合」。之後 P 若以新 grant 再次污染，集合取聯集；**只增不減**。

觸發條件比 `unlock-plugin.md` §8.2 寫的「變長改寫或 respondLocally」寬：等長改寫同樣可以讓大廳顯示未擁有項目（Deviation D2）。

### 3.3 污染狀態存在哪裡、如何持續生效

**位置**：`naki-plugins.js` IIFE 閉包內的 `tainted`（`Map<id, Set<method>>`）。

- 插件程式碼拿不到這個變數；`__nakiPlugins` 對外的 `disable`、`setGrant`、`register` 都不清它。對外只有唯讀的 `guardState()` 複本與 `list()` 的 `tainted` 旗標。
- 頁面重載才清空：新文件是新的 realm，`naki-plugins.js` 重跑，閉包重建。頁面重載時遊戲也重新從伺服器取資料，污染同時解除。
- **不放 Swift 端**：送出判定必須在 `ws.send` 內同步完成，Swift 沒有同步否決權。Swift 只收 `plugin_event`（`kind: 'tainted'`，每個插件第一次污染時送一次）供插件頁顯示與重載提示。
- **不是安全邊界**（U4）：惡意插件可以直接換掉 `ws.send` 或 `WebSocket.prototype.send`。守衛防的是「正常插件被停用、出錯、被關 L3 之後，遊戲把換裝請求原樣送出」。

**各種撤銷情境**（spike 的 node 測試名稱見 §6.3）：

| 情境 | 實際發生的事 | 守衛 |
|---|---|---|
| 使用者在插件頁停用 | `disable(id)`：移出 registry、刪 grant；`tainted` 不動 | P 不在鏈上 ⇒ 守衛方法一律本地錯誤（`not_on_chain`） |
| 連續失敗自動停用 | `noteFailure` 從 registry 刪除；`tainted` 不動 | 同上 |
| 存設定觸發熱重載 | `disable` → `setGrant` → 重跑源碼（`PluginRegistry.enableScript`，同一段腳本；JS 單執行緒，期間不會插入 message 事件） | 重跑成功：P 回到鏈上。P 的放行只在**新 grant 仍把該方法列在 `sendGuard`** 時有效，否則 `guard_revoked`（審查第 1 條）；`methods` 不含該方法時 hook 不會跑 ⇒ `not_on_chain`。重跑拋錯：P 停在停用 ⇒ 本地錯誤 |
| L3 總開關關掉 | 已污染者的放行無效 ⇒ `outbound_disabled`（審查第 1 條）；未污染者照常 | 守衛只「不送出」並交付本地錯誤，不需要 L3；但 L3 關掉是一種撤回，已污染插件不能再讓守衛方法送出 |
| 頁面重載 | 新 realm | 污染與守衛一起解除 |

### 3.4 守衛擋下時合成的錯誤回應

**形狀**（`guardErrorResponse`）：

```
[0x03][msgId LE 2B][0x0a 0x00][0x12 len][ 0x0a len [ 0x08 code ] ]
 type   同一個 msgId  field1=""   field2=payload   payload.field1 = Error{ code }
```

- **msgId**：被擋下那筆 REQUEST 的 msgId。遊戲與 Swift 都以它配對。
- **field 1 一定寫出空字串**：與官方伺服器的回應形狀相同（`0a 00`，`LiqiEnvelope` 註解）。Swift 自 issue #2 修正後已按欄位號取 payload，省略也解得開；寫出它是為了讓遊戲與任何按位置讀的舊 parser 看到與伺服器一致的 bytes。變異測試「回應省略 field 1」被抓到（`mutation-js.log` M9）。
- **payload 只有 `Res*.error`（field 1）**：19 個守衛方法的回應型別 field 1 都是 `Error`（`liqi.json` 盤點）。其他欄位一律省略（proto3 預設值）。
- **錯誤碼**：spike 用常數 `GUARD_ERROR_CODE = 6`。選擇依據：
  1. 非 0：Naki 與遊戲都以非 0 判定失敗（`LiqiResponseRecord.errorCode`；遊戲端判定是推測）。
  2. 排除 session 層的碼：1004（socket 未登入）可能讓遊戲重連或重新登入。
  3. 優先用伺服器實際回過的碼，讓遊戲有既有的處理路徑：6 是送錯連線時伺服器回的「method not found」（CLAUDE.md `sendRaw` 段）。1023、1105、1306 語意是建房與配對，會誤導使用者。
- **未驗證**：遊戲收到 code 6 時的畫面與後續行為（只跳提示、或重試、或斷線）。**需 live**，而且這個驗證本身安全：守衛擋下時伺服器什麼都沒收到（§7.3 步驟）。live 結果不好就換候選碼，常數只有一處。

### 3.5 與 L3 總開關的關係

- 守衛擋下與錯誤回應不需要 L3：不送任何東西給伺服器。
- 已污染者的放行需要 L3 開著；L3 關時已污染者守衛的方法一律本地錯誤（`outbound_disabled`）。
- `respondLocally`（B2）受 L3 限制：L3 關時呼叫被拒。被拒的若是守衛方法，結局是本地錯誤（N2），不是原樣送出。
- 未污染且在鏈上的守衛者，放行不看 L3：此時頁面沒有被補入未擁有項目。

### 3.6 `naki-websocket.js` 接線（提議，待用戶確認）

CLAUDE.md：「修改 WebSocket bridge……前先確認」；ADR 主線決定：「動到 `ws.send` 接線前……先向用戶確認」。spike 因此**沒有改檔**，改動以 patch 提出：`.swfd/logs/pv2-b2-design/proposed-ws-send-wiring.patch`（第五輪重產，`git apply --check` 通過；套用後與測試在記憶體套用的接線逐 byte 相同）。node 測試在記憶體裡套同一段改動（`scripts/plugin-v2-b2-regression.cjs` 的 `PROPOSED_WIRING`），所以測試驗的是套用 patch 後的行為。內容：

1. `ws.send`：`handleMessage` 回 `{ block:true }` 時不呼叫 `originalSend`，改 `respondLocal(ws, wsId, verdict)`。
2. `dispatchToPlugins`：send 方向也把 `{ block:true }` 原樣交回；catch 在 send 方向改回 `failSafe(bytes, socketId)`（審查第二輪第 1 條；角色不是 lobby 一律照送）。
3. `handleMessage`：
   - 開頭：Blob／Other 的送出，`refuseOpaqueSend(wsId)` 為真就回 block（§4.5；只在 lobby 連線）。
   - 兩個 binary 分支：拿到 block 立刻回傳，不編碼、不送 Swift（審查第 3 條）。
   - `catch`：send 方向改回 `failSafe(data, socketId)`，規則見 §1.3。
4. 新增 `localEvents`（WeakSet）與 `respondLocal`：
   - 進來時複製 response 的精確範圍；request、response 都先編碼（審查第 12 條）。
   - 成對送 Swift：兩份都編碼成功才送，而且是同一則 `websocket_message`（`direction:'send'`，回應放在 `localResponse`；第三輪第 3 條）。
   - 遊戲那份另複製一次，下一個 task 交付；之後以擋下當時的連線、msgId、原方法與自己的快照呼叫 `__nakiPlugins.localResponse`（第二輪第 5 條、第三輪第 2 條）。
   - 編碼與送 Swift（同一個 try）、排程、交付、結案各有 try。Naki 的 message listener 第一行略過 `localEvents` 內的事件。
5. `close` listener：呼叫 `__nakiPlugins.closed(wsId)` 清除該連線的角色（§1.4）。

**不套這段 patch，N1／N2 在 App 裡完全不生效**：`dispatchToPlugins` 只認 `Uint8Array`，`{ block:true }` 會被當成「沒改」而送出原 bytes。node 測試 `without the proposed wiring the verdict is ignored (fail-open)` 鎖住這個事實，避免誤以為 spike 已經生效。零插件、零污染時這段 patch 是惰性的（測試 `zero plugins and no taint`）。

---

## 4. N2 送出側 fail-closed

### 4.1 適用範圍

只對「守衛方法的 REQUEST」生效。守衛方法 m 的守衛者 = 目前註冊且 `sendGuard` 含 m 的插件 ∪ 已污染且污染集合含 m 的插件（`guardFor`）。

- 原 method 沒有守衛者時照現行鏈執行，但不得變成守衛方法（審查第 5 條、第二輪第 4 條）：
  - `rewriteSend` 的 `ctx.replace` 若會把 method 換成守衛方法，當場拒絕（回 `false`），原 REQUEST 照常送出（測試 `R4d`、`R5`）。
  - 就地改 bytes 改成守衛方法：當成那個 hook 拋錯，撤回它的改動並計一次插件失敗，原本無守衛的 REQUEST 照常送出（第三輪第 5 條，測試 `R4-5`）。不再擋下，心跳之類的請求不會因插件誤用而沒有回應。
  - 以上只在 `guardedSend` 跑的鏈上檢查（lobby 連線的非 FastTest 請求）；game、unknown 連線與 FastTest 不做守衛查找（§1.4）。
- 守衛者為空、也沒有被改寫進守衛方法時，fail-open 不變。

### 4.2 判定（單一契約，`guardedSend`＋`guardFailure`）

守衛方法的 REQUEST 依下列步驟判定。B2 的 `respondLocally` 是第 3 步的獨立分支，§5.3 只補它自己的檢查，不另訂優先序（審查第二輪第 7 條）。

| 步 | 條件 | 結局 | 理由碼 |
|---|---|---|---|
| 1 | 流量是 isNaki（Naki 自送、插件號段）。**不跑鏈**，與 `observeNakiTraffic` 無關 | 本地錯誤 | `naki_traffic` |
| 2 | 辨識、跑鏈或鏈後判定拋錯（`guardedSend` 的 catch），或 bridge 在派發前出錯（`failSafe`） | 本地錯誤 | `dispatch_error`／`guard_error`／`bridge_error` |
| 3 | 守衛者有任何失敗：`onSend` 拋錯（只計守衛者）、回傳 Promise 或 thenable、[B2] `respondLocally` 被拒或回應不合規 | 本地錯誤 | `hook_threw`／`async_hook`／[B2] `respond_rejected`／`response_invalid` |
| 3b | [B2] 第 3 步不成立，且有守衛者的 `respondLocally` 被接受 | 本地成功（交付提案回應） | — |
| 4 | 有守衛者沒有同步放行：已停用、沒有 `onSend`、`methods` 不含 m、鏈提早停止 | 本地錯誤 | `not_on_chain` |
| 5 | 已污染的守衛者，目前 grant 的 `sendGuard` 已不含 m | 本地錯誤 | `guard_revoked` |
| 6 | 有已污染的守衛者，且 L3 關閉 | 本地錯誤 | `outbound_disabled` |
| 7 | 鏈跑完後 bytes 與原 REQUEST 不同 | 本地錯誤 | `rewritten` |
| 8 | 以上皆否 | 原樣送出（原物件） | — |

- 第 3b 步排在第 4–7 步之前：這四條只否決「送出」。本地成功時伺服器什麼都沒收到，不需要其他守衛者放行。
- 「放行」＝守衛者的 `onSend` 同步正常返回、回傳值不是 thenable、沒有呼叫 `respondLocally`。守衛 hook 是同步契約。回傳 thenable 時，成功或失敗等它有結果才計入，連續失敗照常累計到自動停用（第二輪第 6 條，測試 `R6b`）。
- `rewritten` 一律擋下（Deviation D3）：守衛者放行的是原 bytes，排在後面的 `rewriteSend` 插件可能改掉被引用的 id。
- 擋下時遊戲那份 buffer 還原成原樣，交給 Swift 的是完整原始快照（審查第 7 條）。
- 非守衛方法被就地改寫成守衛方法時，撤回改動照原樣送出（§4.1），不進這張表。
- 錯誤回應只為 `GUARDABLE_METHODS` 內的原方法合成；守衛者都經允許名單驗證，所以表內的擋下都會有回應。只有第 2 步「無法辨識」時方法未知，不回應。

### 4.3 每筆 msgId 的結局紀錄

- `guardState().log`：最近 256 筆守衛方法 REQUEST，`{ msgId, method, outcome: 'sent'|'local_ok'|'local_error', reason, guards, at }`。供 `unlock-plugin.md` §7.5 的外送證明，以 `/js` 讀取。
- 擋下時另送一筆 `plugin_event` 給 Swift（`[Plugin] <ids>：守衛擋下 <method> msgId=<n>（<reason>）`），Swift 不需改碼即可記進 log。
- 拒送的 Blob 記成 `{ msgId: null, method: null, outcome: 'refused_opaque' }`：拒送當下不解析內容。

### 4.4 與現行 fail-open 契約的差異與相容性

| 項目 | 現行（`plugin-api-v1.md` §7） | 守衛方法 |
|---|---|---|
| hook 拋錯 | 撤回它的改動，原樣送出 | 守衛者拋錯：撤回改動，**不送出**，本地錯誤；非守衛者拋錯照現行 |
| hook 回傳 Promise | 忽略回傳值 | 守衛者：不算放行，本地錯誤；rejection 由 Naki 接住 |
| Blob 送出 | 送出後非同步觀察 | 有守衛者時拒送 |
| 插件不在鏈上 | 原樣送出 | 已污染或已註冊的守衛者缺席 ⇒ 本地錯誤 |
| 其他插件改寫 | 送改後 bytes | 本地錯誤 |

相容性：沒有宣告 `sendGuard` 的插件與所有非守衛方法，行為與 main 相同；例外是「有守衛者時拒送 Blob」與「被改寫成守衛方法時擋下」。既有 `plugin-regression.cjs` 29 條、`plugin-v2-regression.cjs` 21 條在 spike 上全綠。所有 hook 回傳的 rejected Promise 現在都由 Naki 接住並計入失敗次數，不再成為 unhandled rejection。

### 4.5 無法同步辨識的送出（Blob 等）

- **策略**：只要有守衛者（任一插件已污染，或已註冊且宣告 `sendGuard`），**角色為 lobby 或尚未鎖定的連線**上的 Blob 與其他非 binary、非字串的送出一律拒送（`refuseOpaqueSend(socketId)`；unknown 自 guard-gaps c 起）。已鎖 game 的連線的 Blob 照常送出（測試 `R4-1c`、`R5-1b`）。不送出、不送 Swift、不合成回應（沒有 msgId 可配對）。字串照舊送出：Liqi 是 binary，text frame 不可能是 Liqi REQUEST。
- **對遊戲的影響**：被拒的那一筆，伺服器與 Swift 都收不到，遊戲也收不到回應，可能停在等待狀態。目前的證據是 Unity 送 TypedArray（`naki-websocket.js` 註解）。所以預期影響為零，但沒有 live 證據；live 讀 `__nakiWebSocket.diagnostics().send.Blob` 與 `guardState().log` 的 `refused_opaque` 筆數可以看到是否發生。
- **適用範圍比審查要求寬**：審查要求「有任何污染時」拒送；這裡連「已註冊、未污染」也拒送（Deviation D9），讓守衛方法在 lobby 連線上不會經 Blob 繞過 N2。unknown 連線上的 Blob 自 guard-gaps c 起同樣拒送（§1.4）。
- 沒有守衛者的頁面行為不變（測試 `R4b`）。
- Blob 的非同步觀察副本（`mutable: false`）不進守衛判定，只觀察，不會留下錯誤的 `local_error` 紀錄。

### 4.6 Naki 自送身分只看 msgId 的後果（第三輪第 4 條，另開工作包）

`isNakiMsgId` 只看號碼：插件號段 64000–65500，或 `sendRaw` 最近 256 筆登記。它不知道連線，也不保證與遊戲的號碼互斥。本輪不修，只證明在守衛範圍內的後果：

- **誤判為 Naki（遊戲的請求被當成 Naki 自送）**：只會走第 1 步 `naki_traffic`，結局是本地錯誤。也就是守衛方法被多擋（fail-closed），不會被放出去。非守衛方法不受影響（`naki_traffic` 只在有守衛者時成立）。
- **誤判為遊戲（Naki 自送被當成遊戲）**：請求照遊戲請求的規則走鏈，要守衛者同步放行、未被改寫、未撤銷、L3 等條件全成立才送出，與真正的遊戲換裝請求同一條件。所以不會比遊戲自己的請求更容易被放出去。
- **以上只在大廳守衛方法上成立**；對局連線與 FastTest 不做這個判斷（§0）。
- **對大廳換裝的可用性影響**：遊戲自己的 msgId 落在下列兩種號碼時，換裝請求會得到本地錯誤（code 6），重試換到下一個 msgId 才會恢復。
  - 落在 Naki 最近 256 筆 `sendRaw` 的號碼：要 Naki 剛在大廳自送過同號請求，機率低。
  - 落在 64000–65500：遊戲長時間連線後計數器才會到達。到了之後，該連線約 1500 筆請求內的所有守衛方法都會被擋。
- Swift 端 `LiqiResponseStore` 的認領（`allocator.claim`）與 `LiqiParser.isNakiSent` 同樣只看號碼。它們不在守衛判定路徑上，後果見審查原文，屬另開的工作包。

### 4.7 已知缺口

- **惡意插件**：U4，不防。

---

## 5. PV2-B2 原語

`plugin-v2.md` §4.2–§4.5 的設計照用。本節只寫補充與修正。

### 5.1 Naki listener 改 capture 與合成事件略過

- 建構時以 `addEventListener('message', fn, true)` 註冊。live (d)=true：WebKit at-target 階段 capture listener 先於非 capture 執行；遊戲三條連線都只用 `onmessage`（非 capture），所以 Naki 必然先跑。
- 第一行略過 `localEvents` 內的事件。`localEvents` 與 §3.6 是同一個 WeakSet：守衛本地回應、`respondLocally`、變長 `replace`、`injectReceive` 的合成事件都登記在這裡。

### 5.2 變長 receive `replace` 與 receive `drop`

- `ctx.replace(newBytes)` 在 receive 方向不再要求等長。檢查：envelope 逐欄位在界內（`isWellFormed` 擴成 RESPONSE 版：field 1 必須**存在**，可為空字串，與伺服器形狀一致）、type 與 msgId 不變、NOTIFY 的 method 不變、改後 method 不在禁改名單（`rewriteAllow` 可解）。
- 等長成功時沿用就地改（遊戲與 Swift 讀同一份 buffer）；長度不同時 `dispatch` 回新 bytes，listener：`stopImmediatePropagation` → `sendToSwift(新 bytes)` → 合成事件登記 → `ws.dispatchEvent`。live probe 的攔截器就是在 listener 內同步 `dispatchEvent`，遊戲收到恰好一次。
- `ctx.drop()` 只對 NOTIFY（type 1）存在。RESPONSE 不能 drop：遊戲會卡在等回應，Swift 的 `pendingRequests` 也不會清。這是對 `plugin-v2.md` §4.2 的收窄。
- 污染：守衛插件對大廳訊息做任一種成功改寫或 drop ⇒ §3.2。

### 5.3 `respondLocally`

- capability `respondLocally`（L3）。`ctx.respondLocally(responseBytes)` 只在 send 方向、非 isNaki、method 不在禁用名單（送出禁改名單＋`cancelUnifiedMatch`、`cancelMatch`）時存在。
- 檢查：L3 開、type 3、msgId 等於這筆 REQUEST、field 1 存在、envelope 在界內。通過時**當場複製精確範圍**存成提案回應，之後插件再改它的 buffer 也不影響交付（審查第 12 條；`respondLocal` 交付時再複製一次）。
- **多守衛**（審查第 11 條）：判定只照 §4.2 的單一表格。這裡只補 `respondLocally` 自己的規則：
  1. 呼叫被接受後鏈**不停止**，其餘插件照常執行。
  2. 第二個呼叫 `respondLocally` 的插件被拒（`already_responded`）。先到者的提案保留，被拒的那一方記為 `respond_rejected`，依 §4.2 第 3 步整筆改為本地錯誤。
  3. 結局與交付一律 `{ block:true, request: original, response, msgId, method }`，與守衛擋下同一條路徑（§1.3）。
- 被拒：非守衛方法回 `{ ok:false, reason }`，REQUEST 照常送出（插件自行處理）；守衛方法依 N2 改為本地錯誤。
- Swift 配對與 §1.3 相同：原 REQUEST 與 RESPONSE 在 `ws.send` 內同一個 task 成對送 Swift（以連線＋msgId 配對），只有交付遊戲延到 `ws.send` 回傳後。加一條契約測試（Swift 單測讀 bundle 內 `naki-plugins.js`）：`LiqiParser` 送出方向有副作用的方法常數（`startUnifiedMatchMethod`、`cancelUnifiedMatchMethod`、`cancelMatchMethod`）與 `loginResponseMethods` 全部出現在 JS 禁用名單。`LiqiResponseStore` 只收 Naki 配發的 msgId，遊戲的 msgId 不進去。

### 5.4 `injectReceive`

`plugin-v2.md` §4.2 照用：只能是 NOTIFY、不得是禁改名單或 `.lq.ActionPrototype`、先送 Swift 再交付、L3。解鎖插件不需要它（`unlock-plugin.md` N4），列為 B2 的選做尾段（§8）。

### 5.5 禁改名單對各原語的適用

| 原語 | receive 禁改名單（`ActionPrototype`、`syncGame`、`NotifyGameEndResult`） | `rewriteAllow` 能否解開 | 送出禁改名單 | `cancelUnifiedMatch`／`cancelMatch` |
|---|---|---|---|---|
| receive 等長 `replace`（v1） | 禁 | 能 | — | — |
| receive 變長 `replace` | 禁 | 能 | — | — |
| receive `drop` | 禁 | 不能 | — | — |
| `injectReceive` | 禁產生 | 不能 | — | — |
| `rewriteSend`（B1） | — | 不能 | 改前改後都禁 | 不在名單（現行） |
| `respondLocally` | — | 不能 | 禁 | 禁 |
| `sendGuard` 宣告 | — | 不能 | 禁 | 禁 |

---

## 6. 不變條件、取捨、明確不做、驗證分級

### 6.1 不變條件

1. 守衛方法的 REQUEST 只有三種結局：原樣送出、本地成功、本地錯誤。
2. 已污染只增不減，頁面重載前不解除；不受停用、自動停用、熱重載、L3 影響。
3. 守衛擋下時伺服器收不到任何 bytes；Swift 收到完整原 REQUEST 一次、合成 RESPONSE 一次，兩者連續且 REQUEST 先。
3b. 擋下的決定作出後，任何後續失敗都不會退回送出。
4. 遊戲在 `ws.send` 回傳後才收到本地回應。
5. 零插件且零污染時，`ws.send` 送出原物件，Swift 收一次（`plugin-v2.md` §4.5-6 照舊）。
6. isNaki 流量永不給改寫、drop、`respondLocally`（`plugin-v2.md` §4.5-1）。
7. Naki listener 只處理每則真實訊息一次，永不處理自己合成的事件。

### 6.2 取捨

| 選擇 | 採用 | 放棄的方案與理由 |
|---|---|---|
| 連線角色 | 協定握手鎖定（第一個 Lobby／FastTest 請求，§1.4） | URL 子字串：hostname、query 會誤中（第四輪第 1 條）；解析 URL 比對 pathname：仍是對 URL 形狀的假設，大小寫與編碼別名要另訂規則，而 live 已證實第二個請求就揭露角色 |
| 污染狀態的位置 | `naki-plugins.js` 閉包 | Swift 端：送出判定要同步，Swift 否決不了；`window` 全域：插件可改寫 |
| 守衛判定時點 | 鏈跑完後一次判定 | 每個 hook 後判定：要處理鏈中途停止與後續改寫，規則更多 |
| 錯誤回應的 payload | 只寫 `Error{code}` | 依方法組完整 Res：要 schema，PV2-C 之前做不到，而且遊戲只需要知道失敗 |
| 守衛方法被改寫 | 一律擋下 | 允許改寫後再請守衛者確認：守衛者看到的是改寫前的 bytes，順序規則複雜 |
| 可守衛方法 | JS 允許名單（19 個已確認回應型別的方法） | 只檢查禁改名單：會放行回應型別不合的方法（審查第 10 條） |
| 交付時點 | Swift 同一個 task 連續收；遊戲 `setTimeout 0` | Swift 也延到 timer：跨連線同 msgId 會插隊（審查第 9 條）；遊戲同步交付：遊戲可能還沒登記回應等待（推測） |
| Blob | 有守衛者時拒送 | 送出後補記：守衛方法已外送（審查第 4 條）；只在污染時拒送：已註冊未污染的守衛方法可經 Blob 繞過 N2 |

### 6.3 明確不做

- 不改 `AutoPlay*`、`LiqiActionSender`。`LiqiParser`、`MajsoulBridge`、`WebSocketInterceptor` 只改配對鍵與 `socketId` 傳遞（§1.2）。
- 不防惡意插件（U4）。
- 守衛不涵蓋 `.lq.FastTest.*` 與對局連線（`broadcastInGame` 等攔不住的入口由插件縮小功能處理，`unlock-plugin.md` §3.7）。
- spike 不做：變長 replace、drop、`injectReceive`、`respondLocally`、插件頁的污染顯示、拒絕原因與重載按鈕、依 schema 的回應型別檢查（目前以允許名單代替）。

### 6.3b 審查第二輪的驗證

修前紅、修後綠：`.swfd/logs/pv2-b2-design/round2-red.log`（11 條反例紅）、`round2-green.log`（27／27）。R2 第一次紅的原因只有 unhandled rejection（測試 helper 當時沒有回傳 hook 的值），「Promise 不算放行」另以重建修前行為的變異補證（`round2-mutation-js.log` 的 `R2 pre-fix`）。R3b、R4c 是修後才加的，紅的證據是對應變異（`W4`、`R4 opaque refused only when tainted`）。

### 6.3c 審查第三輪（Astra 第二輪新發現）的驗證

- 修前紅：`round3-red-js.log`（7 條反例：R301、R302、R3c、R4d、R4e、R5b、R6b）、`round3-red-swift.log`（`testLocalExchangeOnOneSocketDoesNotConsumeAnotherSocketsPending` 失敗：B 的真回應 unmatched）。
- 修後綠：`round3-green-js.log`、`round3-green-swift.log`。
- 變異：`round3-mutation-js.log`（9／9 被抓）、`round3-mutation-swift.log`（配對鍵退回只看 msgId：2 條測試失敗）。

### 6.3d 審查第四輪（Astra 第三輪新發現）的驗證

- 修前紅：`round4-red-js.log`（7 條反例：R4-1a、R4-1b、R4-1c、R4-1d、R4-2、R4-3、R4-5）。
- 修後綠：`round4-green-js.log`、`round4-green-swift.log`。R4-1e、R4-1f、R4-1g 是修後才加的，紅的證據是對應變異 K2、K3、K1。
- 變異：`round4-mutation-js.log`（10／10 被抓）、`round4-mutation-swift-S1.log`（成對訊息的回應不處理）、`round4-mutation-swift-S2.log`（回應解不開仍處理 REQUEST），兩個 Swift 變異都被抓。

### 6.3e 審查第五輪（Astra 第四輪三條）的驗證

- 修前紅：`round5-red-js.log`，11 條反例 not ok（R5-1a～g、R5-2a、R5-2b、R5-3、R5-3b）。R5-1h 修前就綠：舊判定恰好以 URL 認得 `/gateway`。它鎖的是「零插件也鎖定」，紅的證據是變異 M3。
- 修後綠：`round5-green-js.log`（55／55）。既有 `round5-plugin-regression.log`（29／29，naki-plugins `94fa197`）、`round5-plugin-v2-regression.log`（21／21）。
- 既有測試調整兩條，都是讓連線先握手：`game-gateway rewrites do not pollute` 先送 `authGame`，`R4c` 先送 `loginBeat`。理由是 URL 不再參與，未握手的連線依規則是 unknown。
- 變異：`round5-mutation-js.log`，8／8 被抓。M1 角色改回 URL、M2 unknown 當 lobby、M3 鎖定移到判定之後、M4 FastTest 不提早返回、M5 D27 撤回、M6 就地改寫檢查改回看角色、M7 接線不通知關閉、M8 `failSafe` 不鎖定。
- Swift：`round5-green-swift.log`（`PluginSendGuardTests` 11／11）、`round5-test-full.log`（NakiTests 1149 個、0 failures，與第四輪相同；本輪未改 Swift）。
- 接線 patch：`round5-patch-check.log`。

### 6.3f 審查第五輪 b（Astra 第五輪六條）的驗證

- 程式改動只有一處：D27 改為只看原方法（D33）。修前紅：`round5b-red-js.log`（`R6-6` not ok）。R6-1～R6-5 鎖的是現行行為與保證範圍，修前即綠；紅的證據是變異。
- 修後綠：`round5b-green-js.log`（61／61）、`round5b-plugin-regression.log`（29／29）、`round5b-plugin-v2-regression.log`（21／21）、`round5b-green-swift.log`（`PluginSendGuardTests` 11／11）。
- 變異：`round5b-mutation-js.log`，13／13 被抓。本輪獨立變異 N1 零插件直接返回（`R5-1h` 紅，補第五輪 M3 缺的零插件紅證據）、N2 `failSafe` 改變既有角色、N3 D27 改回雙側、N4 照送前漏還原、N5 鎖定後仍可改變角色；M1–M8 在新樹上重跑。
- 接線未改，patch 未重產：`round5b-patch-check.log`。全量 NakiTests 未重跑（未改 Swift），沿用 `round5-test-full.log`。

### 6.4 驗證分級

| 項目 | 分級 | 證據 |
|---|---|---|
| 守衛方法 hook 拋錯 ⇒ 不送出；Swift 先收 REQUEST 再收合成 RESPONSE、各一次；遊戲在 `send` 回傳後才收到 | 已驗證（node） | `plugin-v2-b2-regression.cjs`：`N2: guard hook throws ⇒ nothing goes out…` |
| 污染後停用 ⇒ 守衛方法不送出、遊戲收到錯誤；非守衛方法照送 | 已驗證（node） | `N1: after pollution, disabling the plugin keeps the guard…` |
| 自動停用、熱重載失敗、L3 關 ⇒ 守衛照常 | 已驗證（node） | `N1: auto-disable after repeated failures, failed hot reload, and L3 off all keep the guard` |
| 重新註冊的已污染插件要再次放行；新 grant 的 `methods` 不含該方法時無法放行 | 已驗證（node） | `N1: a re-registered tainted plugin must approve again…` |
| 未污染時停用 ⇒ 守衛解除 | 已驗證（node） | `without pollution, disabling a guard plugin releases its guard` |
| 對局連線改寫不污染；非守衛插件不污染 | 已驗證（node） | `game-gateway rewrites do not pollute…` |
| 守衛方法被其他插件改寫 ⇒ 擋下 | 已驗證（node） | `guarded request rewritten by another plugin is blocked…` |
| 污染後 Naki 自送也擋下 | 已驗證（node） | `after pollution, Naki-sent (sendRaw) guarded requests are blocked too` |
| 鏈內部錯誤 ⇒ 擋下而非送出 | 已驗證（node） | `N2: an internal dispatch error on a guarded request blocks it…` |
| `register` 拒絕禁改、取消配對、非 Lobby、不在 `methods` 的 `sendGuard` | 已驗證（node） | `register rejects sendGuard methods…` |
| 不套接線 patch 時守衛無效 | 已驗證（node） | `without the proposed wiring the verdict is ignored (fail-open)…` |
| 上列守衛邏輯的 12 個變異（停用清污染、忽略拋錯／缺席／改寫、不污染、對局也污染、污染者不守、register 不驗、回應省略 field 1、零插件提早返回、鏈錯誤時送出、污染隨 grant 縮小） | 已驗證：12／12 被抓 | `.swfd/logs/pv2-b2-design/mutation-js.log` |
| 審查第二輪反例（R1a、R1b、R2、R3、R3b、R4、R4b、R4c、R5、R6、R7、R8、R9、R14） | 已驗證（node，套用接線 patch 後的行為） | `plugin-v2-b2-regression.cjs` 同名測試；`round2-red.log`、`round2-green.log` |
| 第二輪修正點與接線的 20 個變異 | 已驗證：20／20 被抓 | `round2-mutation-js.log` |
| 合成錯誤回應與原 REQUEST 在 `LiqiParser` 配對；就地改 msgId 的反例會 unmatched；連續送 Swift 時後來同 msgId 的請求仍正確配對 | 已驗證（XCTest） | `PluginSendGuardTests.testGuardErrorResponsePairsWithTheOriginalRequest`、`testMutatedRequestIdWouldLeaveTheGuardResponseUnmatched`、`testBackToBackDeliveryKeepsALaterSameIdRequestPaired` |
| manifest `sendGuard` 驗證與進 grant | 已驗證（XCTest） | `PluginSendGuardTests` 3 條 |
| 既有插件契約不變 | 已驗證（node） | `plugin-regression.cjs` 29／29、`plugin-v2-regression.cjs` 21／21 |
| 合成錯誤回應在真 WebKit 上被遊戲接受、畫面顯示、之後連線正常 | **需 live**（§7.3） | — |
| 遊戲送出不走 Blob（拒送策略對遊戲無影響） | **需 live**（§4.5） | — |
| WebKit 依序遞送兩次 `postMessage`、Swift 依序處理 | **未驗證**（推論：單一 handler、同步處理）。第二輪起配對以連線隔離，正確性不再只靠這個順序 | — |
| 跨連線同 msgId 的配對隔離 | 已驗證（XCTest，修前紅、修後綠＋變異） | `testLocalExchangeOnOneSocketDoesNotConsumeAnotherSocketsPending`、`testResponseOnADifferentSocketIsUnmatched` |
| 守衛辨識、鏈後判定、fallback 拋錯時擋下 | 已驗證（node＋變異 J1–J3） | `R301`、`R302` |
| 成對交付：單一訊息；正式 core 下 `postMessage` 任一方向失敗都不會半套；Swift 兩份都解得開才處理 | 已驗證（node＋XCTest＋變異 W8、S1、S2） | `R4-3`、`R3c`、`testLocalExchangeMessageIsProcessedAsOnePair`、`testUndecodableLocalResponseDropsTheWholeExchange` |
| 改寫成守衛方法：`replace` 拒絕；就地改寫撤回並照原樣送出 | 已驗證（node＋變異 J5、K7） | `R4d`、`R5`、`R4-5` |
| 守衛只作用在大廳：對局連線、FastTest、對局 Blob、對局 bridge 錯誤都照送 | 已驗證（node＋變異 K1–K4） | `R4-1a`、`R4-1b`、`R4-1c`、`R4-1e`、`R4-1f`、`R4-1g` |
| 大廳上已知非守衛方法遇內部錯誤時還原並送出 | 已驗證（node＋變異 K5） | `R4-1d` |
| JS 配對以連線＋msgId 為鍵 | 已驗證（node＋變異 K6、W7） | `R4-2`、`R8`、`R5b` |
| socketId 缺值與預設值契約 | 已驗證（XCTest） | `testSocketIdDefaultsAndMissingValues` |
| 本地結案用原方法與獨立快照 | 已驗證（node＋變異 J6、W6） | `R5b` |
| 非同步 rejection 連續累計到自動停用 | 已驗證（node＋變異 J7） | `R6b` |
| 插件頁顯示污染與重載提示 | **未實作** | — |
| B2 四個原語 | **未實作** | — |

---

## 7. Phase 4 gate 判定

### 7.1 live 結果（2026-10-15，`.swfd/logs/live-20261015/probe/`）

| 連線 | 目標 | (a) | (b) | (c) addEventListener／onmessage | (d) | 檔案 |
|---|---|---|---|---|---|---|
| 對局 `route-4 /game-gateway` | `NotifyGameBroadcast`（target seq 43） | 綠 | `b_auto` true；60 秒後仍 OPEN、事件持續推進；**畫面表情未驗證**（截圖晚 3 秒） | 綠／綠 | true | `05-read-after-emoji.json`、`07-read-60s.json` |
| 大廳 `route-4 /gateway` | heartbeat | 綠 | 綠（`loginBeat` 持續） | 綠／綠 | true | `11-lobby-read-1.json`、`12-lobby-read-60s.json` |
| 大廳 `route-5 /gateway` | heartbeat | 綠 | 綠 | 綠／綠 | true | 同上 |

注意兩點：

- 三條連線的遊戲 handler 都只走 `onmessage`（`gameVia.addEventListener` 都是 0）。(c) 的 addEventListener 路徑是由 probe 自己的 handler 代表。
- 大廳 (b) 的目標是 heartbeat 回應。遊戲對**業務回應**（例如 `fetchCharacterInfo`）的合成事件是否同樣接受，仍屬 N3 的 `respondLocally` 端到端驗收。

### 7.2 判定

| 範圍 | 判定 | 理由 |
|---|---|---|
| 大廳連線的合成事件機制 | **已滿足** (a)(b)(c) | 兩條大廳連線全綠 |
| 對局連線 | **未全綠**：(b) 只差畫面表情 | 依 `plugin-system-design.md` §11 #6，(a)(b)(c) 全綠才可開工 |
| PV2-B2 | 可以設計；**對局 (b) 補驗綠是 B2a 開工的前置**（審查第 13 條，依 `plugin-system-design.md` §11 #6 與 `plugin-v2-adr-2026-10-14.md` 決定 4） | B2 的變長 `replace` 作用於所有連線 |
| N1／N2 | 交付路徑只在大廳連線（`sendGuard` 限 `.lq.Lobby.*`），所依賴的大廳證據已全綠 | 不受對局 (b) 阻擋；但仍需 §7.3 第 2 項的錯誤回應 live 驗收與用戶確認接線 |

### 7.3 補驗方法（測試帳號，由主線或用戶執行）

1. **對局 (b)**：在大廳重新載入頁面（新頁面）→ 依 `plugin-v2.md` §9.3 步驟 1 安裝 probe → 開一局（友人房＋人機）→ 送一個表情（`game_emoji`）→ **1 秒內**截圖（`/screenshot`），確認表情顯示 → 60 秒後再讀一次 verdict 與 `/game/state`。四項都成立才算 (b) 綠。
2. **N1／N2 錯誤回應**（套用接線 patch 的建置）：裝一個只觀察的測試插件，`sendGuard: [".lq.Lobby.useTitle"]`、`onSend` 一律拋錯 → 在遊戲裡換一次稱號 → 確認 `guardState().log` 是 `local_error`、外送觀察沒有 `useTitle`、遊戲畫面行為（提示文字、是否重試或斷線）、Swift log 沒有 unmatched fault。另讀 `__nakiWebSocket.diagnostics().send.Blob` 與 `refused_opaque` 筆數。伺服器收不到 `useTitle` 的根據：binary 送出由守衛擋下（node 測試），Blob 送出因為已註冊守衛者而拒送（§4.5，測試 `R4c`）。這兩條都只有 node 證據，live 才能確認 WebKit 上同樣成立。
3. **N3**（B2 實作後）：大廳 `respondLocally` 端到端，依 `unlock-plugin.md` §8.2 N3。

---

## 8. 工作包切分與順序

| 包 | 內容 | 前置 | 檔案 |
|---|---|---|---|
| **N1／N2** 送出守衛 | spike 補完：套接線 patch；插件頁顯示污染、停用已污染插件時提示重載並提供按鈕（對局中不重載）；`plugin-api-v1.md` 新增 §守衛；PV2-C 合併後加「`sendGuard` 方法的回應型別 field 1 必須是 `Error`」載入檢查；§7.3 第 2 項 live | **修改 `naki-websocket.js` 前取得用戶確認**；錯誤碼 live 驗收 | `naki-plugins.js`、`naki-websocket.js`、`PluginRegistry.swift`、`WebSocketInterceptor.swift`（`plugin_event` kind 分派）、插件頁 View、`plugin-api-v1.md`、node 與 XCTest |
| **PV2-C** protobuf API | `plugin-v2.md` §12.3 照做，涵蓋 `unlock-plugin.md` N5 的型別；`envelope.response(msgId, payload)` 一定寫 field 1 | 無 gate；`liqi.json` 打包已獲用戶允許（ADR） | 新 proto 模組 JS、`NakiRuntime.swift`、`PluginRegistry.swift`（`protobuf` 欄位）、`project.pbxproj`、fixture |
| **PV2-B2a** 變長 replace＋respondLocally | §5.1–§5.3；Swift 契約測試；canonical 三種變形 fixture；`replay-check.sh` 零插件指紋相同；`soak-test.sh` ≥3 局 | **開工前**：對局 (b) 補驗綠、N1／N2 與 PV2-C 已合併；修改接線前用戶確認 | `naki-plugins.js`、`naki-websocket.js`、NakiTests 契約測試 |
| **PV2-B2b** receive drop＋injectReceive（選做） | §5.2 drop、§5.4 | B2a 合併；有實際需求的插件 | 同 B2a |

**依賴與並行**：

- N1／N2 與 PV2-C 可並行。兩者都改 `PluginRegistry.swift`（N1 的 `sendGuard` 已在 spike；C 加 `protobuf`），衝突只在 manifest struct 與 `grantDict`，後合併者 rebase 即可。
- B2a 必須在 N1／N2 之後：共用 `respondLocal`、`localEvents` 與 `guardedSend`，而且同改兩個 JS 檔。B2a 也必須在 PV2-C 之後：沒有編碼器，變長改寫幾乎不可用。
- 建議順序：**N1／N2 ∥ PV2-C → PV2-B2a → （PV2-B2b）**。`unlock-plugin.md` v1 需要 N1、N2、N3、N4（＝B2a）、N5（＝C）、N6（PV2-A 的 `json`）。

---

## 9. 未驗證與已知風險

1. 錯誤碼 6 在遊戲端的行為（§3.4），需 live。拒送 Blob 對遊戲的影響（§4.5），需 live。
2. 本地回應延到 `setTimeout 0` 是否必要、是否足夠（遊戲何時登記回應等待），需 live。
3. Swift 對合成 RESPONSE 的配對：`LiqiParser`／`MajsoulBridge` 層有 XCTest，且以連線隔離；WebKit `postMessage` 順序是推論。`WebSocketInterceptor` 傳 `socketId` 的那兩行沒有單測（只經編譯與全量測試）。
3b. 連線維度配對對真實流量的影響：遊戲的 RESPONSE 一定回到送出 REQUEST 的那條連線（WebSocket RPC），但 live 未驗；bridge 訊息缺 `socketId` 時以 -1 處理，同一條連線的訊息一致。
3c. lobby 上守衛查找持續拋錯時，守衛方法與解析不出的請求被拒送，其他照送（D27，§1.3）。對遊戲的影響未 live 驗證。
3d. 遊戲 msgId 落在 Naki 號碼時大廳換裝被多擋（§4.6），未 live 觀察。
4. 遊戲送出是否從不走 Blob（§4.5），需 live。
5. 大廳合成事件只對 heartbeat 驗過；業務回應屬 N3。
6. 對局 (b) 畫面未驗證（§7）。
7. 接線 patch 未套用；在套用前 N1／N2 在 App 內不生效（§3.6）。`LiqiParser` 的連線維度配對已在 spike 內，合併前同樣需要用戶確認。
8. 守衛的保證範圍（§1.4）：lobby 上 FastTest 的封包形態限定、game 連線上 Naki 自送與遊戲自送的 Lobby 請求、unknown 上解析不出的守衛方法、角色清除只靠 `closed`。`sendRaw` 退回、就地改寫、Blob 空窗已由 guard-gaps 修掉。確認稿須逐條揭露；I2 的成立另依解鎖設計 §3.7（§1.3 D27）。握手序列 live 只觀察過一次登入與一次對局重連；對局中途斷線重連的第二個請求是否仍為 `authGame`、大廳換裝請求落在哪條 `/gateway`，都未驗證。
9. 分支基底落後 main（main 已到 `fd74f63`），本包未 rebase。NakiTests 1149 只能與第四輪對照，合併前要在 main 上重跑。
