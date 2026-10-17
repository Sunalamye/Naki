# 審查回應：送出守衛（N1、N2）與 PV2-B2

**審查**：Astra，原文 `.swfd/logs/pv2-b2-review/astra-review.md`（14 條：擋 7、應修 6、建議 1；總評 REWORK）
**回應者**：設計者（Opus 5.5）
**規則**：第 1–7 條與其他涉及外送、配對、並發正確性的條目，只能採納或附證據證明不可能。
**證據**：主 repo `.swfd/logs/pv2-b2-design/round2-*.log`。修前紅：`round2-red.log`；修後綠：`round2-green.log`；變異：`round2-mutation-js.log`。

## 統計

| 類別 | 數量 | 條目 |
|---|---|---|
| 採納 | 14 | 1–14 |
| 反駁 over-guard | 0 | — |
| 反駁 over-build | 0 | — |

## 逐條

### 1【擋】污染後關閉 L3 或撤掉宣告，仍可能原樣送出 — 採納

- **設計**：§3.3 表格的「熱重載」「L3」兩列、§3.5、§4.2 新增 `guard_revoked`、`outbound_disabled`。
- **規則**：已污染的守衛者，放行要同時滿足兩個條件才有效。一是目前 grant 的 `sendGuard` 仍含該方法，二是 L3 開著。原本那條「重新註冊後拿掉 `sendGuard` 仍能放行」的測試要求，改為反過來斷言。
- **spike**：`naki-plugins.js` 的 `guardFailure`。
- **測試**：`R1a (Astra 1)…L3 off…`、`R1b (Astra 1)…re-registered without sendGuard…`。原測試改名為 `N1: a re-registered tainted plugin that still guards the method must approve again`。
- **紅→綠**：R1a、R1b 在 `round2-red.log` 為 not ok，在 `round2-green.log` 為 ok。變異 `R1 L3 check removed`、`R1 revoked check removed` 被抓。

### 2【擋】非同步 hook 失敗被當成成功放行 — 採納

- **設計**：§4.2 新增 `async_hook`，並寫明守衛 hook 是同步契約。§4.4 新增「hook 回傳 Promise」一列。
- **spike**：`runChain` 取 hook 回傳值；thenable 不算放行。所有 hook 回傳的 thenable 都掛上 rejection 處理（`noteRejection`），rejection 計入失敗次數。
- **測試**：`R2 (Astra 2)…Promise or thenable never approves…`，涵蓋 rejected Promise 與永不 resolve 的 thenable。
- **紅→綠**：`round2-red.log` 的 R2 紅，但原因只有 unhandled rejection：當時測試 helper 沒有回傳 hook 的值，「放行」那一半沒有被測到。修正 helper 後，以重建修前行為的變異 `R2 pre-fix: thenable approves, rejection unhandled` 補紅證據，該變異被 R2 抓到。

### 3【擋】外層例外會撤銷已作出的阻擋判定 — 採納

- **設計**：§1.3（擋下後任何失敗都不退回送出）、§3.6 第 3–4 點、§6.1 第 3b 條。
- **spike**：
  - `blockSend` 自己不拋錯。
  - `guardedSend` 把守衛辨識之後的整段包在 try 內。
  - 接線 patch 的 `handleMessage` 拿到 block 就立刻回傳，不再編碼、也不送 Swift。
  - `handleMessage` 的 catch 改呼叫 `failSafe`。
  - `respondLocal` 的每一步各自 try。
- **測試**：
  - `R3 (Astra 3)…encoding failure…`：注入 Base64 編碼失敗。
  - `R3b (Astra 3)…error inside the bridge before dispatch…`：注入暱稱遮罩拋錯。
  - `N2: an internal dispatch error…`：沿用第一輪的測試。
- **紅→綠**：R3 在 `round2-red.log` 紅、`round2-green.log` 綠。R3b 是修後才加的，紅的證據是接線變異 `W4 handleMessage catch falls back to send`。另有 `W1 typed-array branch drops block early-return`、`R3 guard dispatch_error falls through` 兩個變異也被抓。

### 4【擋】Blob 缺口不能靠一次 live 計數為零關閉 — 採納

- **設計**：新增 §4.5，寫明策略與對遊戲的影響。§7.3 第 2 項改寫「不外送」的根據與證據等級。
- **策略**：只要有守衛者，雀魂連線上的 Blob 與 Other 型別送出一律同步拒送。守衛者包括已污染的插件，以及已註冊且宣告 `sendGuard` 的插件。拒送時不送出、不送 Swift、不合成回應。
- **對遊戲的影響**：遊戲送 Blob 時可能停在等待狀態。預期影響為零，因為 Unity 送的是 TypedArray，但這點沒有 live 證據。
- **範圍比審查寬**：連「已註冊、未污染」的情況也拒送（Deviation D9）。少了這一點，§7.3 的換稱號測試仍可能經 Blob 外送。
- **spike**：`refuseOpaqueSend`。接線 patch 在 `handleMessage` 開頭檢查。Blob 的非同步觀察副本不進守衛判定，所以不會再留下錯誤的 `local_error` 紀錄。
- **測試**：`R4 (Astra 4)`（已污染）、`R4c`（已註冊、未污染）、`R4b`（沒有守衛者時照送）。
- **紅→綠**：R4 紅轉綠。R4c 是修後才加的，紅的證據是變異 `R4 opaque refused only when tainted`。`W3`、`R4 opaque not refused` 兩個變異也被抓。

### 5【擋】非守衛方法改寫成守衛方法，可繞過污染守衛 — 採納

- **設計**：§4.1、§4.2 的 `rewritten`。
- **spike**：`guardedSend` 在原 method 沒有守衛者時，對鏈結果的最終 method 再跑一次 `guardFor`。最終 method 有守衛者就擋下，記錄的 method 是最終 method。
- **測試**：`R5 (Astra 5)…rewriting a non-guarded request into a guarded method…`。
- **紅→綠**：R5 紅轉綠。變異 `R5 final method unchecked` 被抓。

### 6【擋】`observeNakiTraffic` 會破壞 D4 的阻擋保證 — 採納

- **設計**：§4.2 新增 `naki_traffic`，isNaki 流量獨立阻擋。
- **spike**：`guardedSend` 在跑鏈之前檢查 `isNakiMsgId`，有守衛者就直接 `blockSend`，與 hook 是否存在、是否宣告 `observeNakiTraffic` 無關。
- **測試**：`R6 (Astra 6)…observeNakiTraffic…`。
- **紅→綠**：R6 紅轉綠。變異 `R6 naki not blocked independently` 被抓。

### 7【擋】擋下就地改寫時，交給 Swift 的不是原 REQUEST — 採納

- **設計**：§1.3、§4.2 末段。
- **spike**：`guardedSend` 在跑鏈之前複製完整原 REQUEST，block 結果帶著 `request: original`。`blockSend` 把遊戲那份 buffer 還原成原樣。接線 patch 的 `respondLocal` 用這份快照送 Swift，`handleMessage` 不再送 hook 改過的 bytes。
- **node 測試**：`R7 (Astra 7)…changes msgId in place…`。斷言 Swift 收到 REQUEST 206 與 RESPONSE 206，遊戲 buffer 也已還原。
- **Swift 測試**（NakiTests，`PluginSendGuardTests`）：
  - `testGuardErrorResponsePairsWithTheOriginalRequest`：配對成功，unmatched 為 0。
  - `testMutatedRequestIdWouldLeaveTheGuardResponseUnmatched`：重現 Astra 描述的錯配。
- **紅→綠**：R7 紅轉綠。變異 `R7 deliver mutated request` 被抓。

### 8【應修】略過合成事件，也略過了必要的回應結案 — 採納

- **設計**：§1.3。新增本地回應結案路徑 `__nakiPlugins.localResponse`。
- **spike**：交付遊戲之後才呼叫 `localResponse`。它清掉 `pendingMethods`；若 msgId 是插件注入的，把本地結果交給發起插件的 `onInjectResponse`（`ctx.local === true`），再清掉 `injectedMsgIds`。這條路徑不跑改寫鏈，也不再送 Swift。
- **測試**：`R8 (Astra 8)…onInjectResponse…`。同 msgId 之後再來一筆真回應，不會被重複路由。
- **紅→綠**：R8 紅轉綠。變異 `R8 local response not routed` 被抓。

### 9【應修】`setTimeout 0` 未解決跨 socket 的 msgId 配對競態 — 採納

- **證據**：無法證明 msgId 跨 socket 全域唯一，所以改用不依賴這個前提的做法：調整送 Swift 的時點。
- **設計**：§1.3。原 REQUEST 與合成 RESPONSE 在 `ws.send` 內的同一個 task 連續送 Swift，只有交付遊戲延到下一個 task。
  - JS 是單執行緒，這兩次 `postMessage` 之間不會有其他 `ws.send`。
  - `WebSocketInterceptor` 只有一個 `websocketBridge` handler（`WebSession.swift` 註冊），依序同步處理。
  - 因此 `pendingRequests[msgId]` 的登記與消耗之間，插不進別條連線的同 msgId 登記。
  - 不改 Swift parser 的前提因此成立。
- **測試**：
  - node `R9 (Astra 9)…back to back…`：斷言 Swift 收到的順序是 send、receive、send。
  - XCTest `testBackToBackDeliveryKeepsALaterSameIdRequestPaired`：後來的同 msgId `loginBeat` 仍正確配對。
- **紅→綠**：R9 紅轉綠。變異 `W2 Swift RESPONSE deferred into timer` 被抓。
- **未驗證**：WebKit 是否依序遞送 `postMessage`。目前是推論，未做 runtime 驗證。

### 10【應修】錯誤回應型別檢查不能晚於 N1／N2 交付 — 採納

- **設計**：§3.1。
- **規則**：`sendGuard` 只接受允許名單 `GUARDABLE_METHODS`，內容是 19 個在 `liqi.json` 確認回應型別 field 1 為 `Error` 的方法。PV2-C 合併後改成依 schema 檢查，名單可以擴大。
- **spike**：`register` 拒絕名單外的方法。
- **測試**：`register rejects sendGuard methods outside the confirmed-response allowlist (send-forbidden, cancel, FastTest, fetchServerTime)…`。
- **證據**：變異 `R10 allowlist bypass` 被抓。

### 11【應修】多守衛時，`respondLocally` 的終止順序互相矛盾 — 採納

- **設計**：§5.3「多守衛的順序」。
  - `respondLocally` 成功後鏈不停止。
  - 先到者的提案保留，後到者被拒（`already_responded`）。
  - 有本地回應提案的 REQUEST 永不送出。
  - 守衛者若拋錯、回傳非同步、提案被拒或回應不合規，結局是本地錯誤。
  - `not_on_chain`、`guard_revoked`、`outbound_disabled`、`rewritten` 四條只否決「送出」，不否決本地成功。
- **spike**：不涉及。B2a 實作，驗收以這一節為準。

### 12【應修】B2 共用本地回應 helper 前，須固定 bytes 的範圍與生命週期 — 採納

- **設計**：§3.6 第 4 點、§5.3。
- **規則**：`respondLocal` 進來時就對 request、response 做 `slice()`，複製出精確範圍與獨立 buffer，timer 只用這份快照。B2 的 `respondLocally` 在接受提案時也要複製一次。
- **spike**：已改接線 patch。
- **測試**：沒有獨立測試，因為目前守衛建構的都是新陣列，無法從外部注入 subarray。B2a 要補「提案用 subarray 與事後改 buffer」的測試，已列入 §5.3。

### 13【應修】Phase 4 gate 的時點文字仍不一致 — 採納

依 `plugin-system-design.md` §11 #6 與 `plugin-v2-adr-2026-10-14.md` 決定 4，統一為：**對局 (b) 補驗綠是 B2a 開工前置**。已改 §2 表格、§7.2、§8 的 B2a 前置欄。全文已搜尋，不再有「合併前補驗」的寫法。

### 14【建議】非守衛 observer 拋錯，不必自動否決所有守衛 — 採納

- **設計**：§4.2 的 `hook_threw` 改成只計守衛者。非守衛者的改動照現行規則還原，bytes 不變，所以不影響送出。
- **spike**：`runChain` 只在 `isGuard` 時記錄 `threw`。
- **測試**：`R14 (Astra 14)…non-guard observer…`。
- **紅→綠**：R14 紅轉綠。變異 `R14 non-guard throw vetoes` 被抓。

## 其他意見

Astra 對 D5 的意見是「JS 註冊拒絕足以守住入口，但 UI 應反映拒絕結果」。已在 §3.1 列入 N1 工作包：插件頁顯示 `register` 的拒絕原因。

---

# 第二輪（Astra 第二輪審查，`.swfd/logs/pv2-b2-review/astra-review2.md`）

Astra 核對第一輪第 1–7 條：6 條已修，第 3 條部分修正；另有新發現 7 條（擋 2、應修 5）。本輪證據為 `round3-*.log`。主線允許本輪在 spike 修改 `LiqiParser` 的配對狀態，合併前由主線向用戶確認。

## 統計

| 類別 | 數量 | 條目 |
|---|---|---|
| 採納 | 7 | 新發現 1–7 |
| 反駁 | 0 | — |

第一輪第 3 條的「部分」由新發現第 1 條一併處理。第一輪第 1 輪回應中寫的「把守衛辨識之後的整段包在 try 內」與當時實碼不符：辨識本身在 try 外。本輪已改為辨識、跑鏈、鏈後判定全部在 try 內，以下描述與實碼一致。

## 逐條

### 新 1【擋】守衛辨識與最終判定仍在例外保護外 — 採納

- **設計**：§1.3 第 3 步與「擋下的決定之前……拋錯」一段、§4.2 第 2 步、§3.6 第 2–3 點。
- **spike**：
  - `guardedSend` 把 `parseEnvelope`、`guardFor`、isNaki 判定、`runChain`、鏈後判定全部放進同一個 try。catch 時，只要已知是守衛方法，或頁面上有守衛者，就擋下。
  - 新增 `guardActive()`：已污染，或任一已註冊插件宣告了 `sendGuard`。查找本身出錯時當成「有」。
  - `failSafe` 改用 `guardActive()`，不再只看 `tainted.size`；自己不拋錯。
  - `dispatch` 的 send 方向直接進 `guardedSend`，不在 try 外先解析。
  - 接線 patch 的 `dispatchToPlugins` catch 改呼叫 `failSafe`。
- **測試**：
  - `R301 (Astra2 1)`：已污染，`guardFor` 查找拋錯。
  - `R302 (Astra2 1)`：未污染、已註冊守衛者，派發前出錯且查找拋錯。
- **紅→綠**：兩條在 `round3-red-js.log` 為 not ok，在 `round3-green-js.log` 為 ok。
- **變異**：J1（catch 改成直接拋出）被 `N2: an internal dispatch error…` 抓到。R301 在 J1 下仍綠，因為接線的 `failSafe` 是第二道防線。J2、J3 被 R302 抓到。
- **代價**：有守衛者時，Naki 內部錯誤也會擋下非守衛方法，且不合成回應（方法未知）。記為 D13。

### 新 2【擋】D10 無法保護已存在的跨 socket pending — 採納

- **設計**：§1.2、§1.3「配對隔離」、§6.3、§9。D10 降級為「同一連線內的補充」，不再作為不改 parser 的依據。
- **Swift 改動範圍**：
  - `LiqiParser`：`pendingRequests` 的鍵改成 `PendingKey(socketId, msgId)`；`parse(_:socketId:)` 預設值為 0；`parseRequest`、`parseResponse` 帶 `socketId`；log 改印 `socket:msgId`。
  - `MajsoulBridge`：`observeOutgoing(_:socketId:)`、`parse(_:socketId:)` 把 `socketId` 傳給 parser。
  - `WebSocketInterceptor.handleWebSocketMessage`：兩個呼叫點傳入訊息裡的 `socketId`（缺席時為 -1）。這兩行不在主線點名的檔案內，但不傳就無法依連線隔離（D12）。
  - `LiqiResponseStore`：只改一行註解。
- **所有讀寫點**：
  - `pendingRequests` 的寫入只有 `parseRequest`，讀取與移除只有 `parseResponse`（`grep` 全 `command/`）。
  - `LiqiResponseStore.capture` 讀的是 `parse` 的結果與全域 `LiqiMsgIdAllocator`。
  - `ObservedMatchSids` 在 `parseRequest`／`parseResponse` 內依 method 呼叫，不讀 `pendingRequests`。
  - `LiqiParser.isNakiSent` 只看 allocator 與插件號段。
  - 以上三者不需改。`LiqiActionSender` 的回應經 `sendRaw` 選定的那條連線回來，配對鍵一致。
- **測試**（XCTest，`PluginSendGuardTests`）：
  - `testLocalExchangeOnOneSocketDoesNotConsumeAnotherSocketsPending`：Astra 的反例。B 連線先送 `loginBeat(303)`，A 連線的 `changeCharacterSkin(303)` 被擋並本地結案，B 的真回應必須配到 `loginBeat`。
  - `testResponseOnADifferentSocketIsUnmatched`。
- **紅→綠**：`round3-red-swift.log` 中 B 的真回應為 nil（unmatched），修後 `round3-green-swift.log` 8／8 綠。紅版用的是當時的 API（沒有 `socketId` 參數），綠版只是在同一序列加上連線編號。
- **Swift 變異**：配對鍵退回只看 msgId（`socketId: 0`），2 條測試失敗（`round3-mutation-swift.log`）。

### 新 3【應修】分別 try 兩次 Swift 交付，會產生錯配的半套交易 — 採納

- **定義**（§1.3「成對交付」）：Swift 只會收到「REQUEST＋RESPONSE」一對，或什麼都不收。
- **spike**（接線 patch 的 `respondLocal`）：
  - request、response 都先編碼，任一失敗就都不送。
  - REQUEST 的 `sendToSwift` 拋錯時不送 RESPONSE。
  - response 為 null 時（原方法回應型別未確認），Swift 與遊戲都不送。
- **反方向不可能**（REQUEST 已送、RESPONSE 拋錯）：`naki-core.js` 的 `sendToSwift` 把 `postMessage` 包在自己的 try/catch 內，從不拋錯，而編碼已在送出前完成。`postMessage` 靜默遺失在兩個方向都無法從 JS 偵測，連線維度配對把影響限在同一條連線。
- **測試**：`R3c (Astra2 3)`，只讓 REQUEST 的 bridge 呼叫拋錯。
- **紅→綠**：紅轉綠。變異 W5 被抓。
- Astra 指出「`slice()` 與 timer 排程也在 try 外」：已移進 try，§1.3 的描述改為逐步列出各段 try。

### 新 4【應修】GUARDABLE_METHODS 沒有涵蓋被改寫前的回應型別 — 採納

- **設計**：§4.1、§4.2 末條。
- **規則**：
  - `rewriteSend` 的 `ctx.replace` 若會把 method 換成守衛方法，當場拒絕，原 REQUEST 照常送出（D14）。
  - 就地改 bytes 改成守衛方法：擋下。錯誤回應依原方法：原方法在 `GUARDABLE_METHODS` 才合成，否則不回應。
- **spike**：`makeCtx` 的 send 方向 `replace` 加上檢查；`blockSend` 多一個 `origMethod` 參數，依它決定是否合成回應。
- **測試**：
  - `R4d (Astra2 4)`：Astra 的 `fetchServerTime → changeCharacterSkin`。
  - `R4e (Astra2 4)`：就地把 `heatbeat` 改成 `useTitle`，擋下且遊戲收不到錯誤型別的回應。
  - `R5` 的期望隨政策更新：`replace` 被拒，原 `loginBeat` 照常送出。
- **紅→綠**：R4d、R4e 紅轉綠。變異 J4、J5 被抓。

### 新 5【應修】本地結案仍缺原始方法，且依賴遊戲可改動的 bytes — 採納

- **設計**：§1.3 末條、§3.6 第 4 點。
- **spike**：
  - block 結果帶 `msgId` 與 `method`（原方法），兩者在擋下當時決定。
  - `respondLocal` 交付遊戲的是另一份複本。
  - `localResponse(msgId, method, bytes)` 只用這三個值，不再解析交付後的 buffer。
- **測試**：`R5b (Astra2 5)`。遊戲 handler 改動收到的 buffer 的 msgId，`onInjectResponse` 仍收到原 msgId 與 `changeCharacterSkin`；之後同 msgId 的真回應不再被路由。
- **紅→綠**：紅轉綠。變異 J6、W6 被抓。

### 新 6【應修】連續 Promise rejection 永遠被重設為第一次失敗 — 採納

- **設計**：§4.2「放行」一條。
- **spike**：hook 回傳 thenable 時不先 `noteSuccess`。`settle` 在 fulfil 時 `noteSuccess`、在 reject 時 `noteFailure`（D16）。
- **測試**：`R6b (Astra2 6)`。12 次逐筆等待的 rejection 中，前 10 筆擋下，第 10 次後插件自動停用。未污染的插件停用後守衛解除，所以第 11、12 筆送出，與測試 6 的規則一致。
- **紅→綠**：紅轉綠（修前插件仍在註冊清單）。變異 J7 被抓。

### 新 7【應修】B2 本地成功仍有兩套判定與交付時序 — 採納

- **設計**：§4.2 改為單一步驟表，`respondLocally` 的本地成功是第 3b 步，排在 `not_on_chain`、`guard_revoked`、`outbound_disabled`、`rewritten` 之前。§5.3 只補 `respondLocally` 自己的規則（不停鏈、`already_responded` 記為 `respond_rejected`），不再另訂優先序。
- **時序**：§5.3 原本「回應在 `ws.send` 回傳後才送 Swift」的句子已改為與 §1.3 相同：Swift 在同一個 task 成對收到，只有遊戲延後。
- **spike**：不涉及（B2a 實作）。

## 第一輪第 8–12 條的「部分」

Astra 判定 8–11 部分、12 的 helper 已通過、B2 提案快照仍未實作。本輪對應的處理：

- 第 8 條：見新 5。
- 第 9 條：見新 2。
- 第 10 條：見新 4。
- 第 11 條：見新 7。
- 第 12 條：B2 的提案快照仍屬 B2a，已寫在 §5.3。

---

# 第三輪（Astra 第三輪審查，`.swfd/logs/pv2-b2-review/astra-review3.md`）

Astra 核對第二輪第 1–7 條：5 條已修，2 條部分（第 2、3 條）。另有新發現 6 條：擋 2、應修 3、建議 1。本輪證據為 `round4-*.log`。

**用戶裁決（2026-10-15）**：守衛收窄到只守大廳連線，再修一輪；第四輪審查若仍有【擋】，解鎖 v1 暫停。已寫入設計 §0 與 notes。

## 統計

| 類別 | 數量 | 條目 |
|---|---|---|
| 採納 | 5 | 新 1、2、3、5、6 |
| 採納（證明後果，修正另開工作包） | 1 | 新 4（依主線指示） |
| 反駁 | 0 | — |

## 逐條

### 新 1【擋】D13 會阻斷對局連線與 Naki 自送動作 — 採納

- **設計**：§0、§1.3「前提」與「擋下的決定之前」、§4.5。
- **spike**：
  - 新增 `isLobbyUrl`（url 含 `/gateway`；`/game-gateway` 不含它）。
  - `guardedSend` 一開頭判斷：非大廳連線直接走現行鏈（`plainChain`）。大廳上解析出 `.lq.FastTest.*` 也走現行鏈。兩者都在守衛查找之前。
  - `failSafe(data, url, socketId)`：非大廳直接回 undefined（照送）。
  - `refuseOpaqueSend(url)`：只在大廳拒送。
  - D13 改寫：大廳上，已知非守衛方法遇內部錯誤時還原原始 bytes 照送；只有守衛方法，或無法辨識且頁面上有守衛者，才拒送。
  - `replace` 的「改寫成守衛方法」檢查與污染判定，也一律以 `isLobbyUrl` 為準。
- **測試**：
  - `R4-1a`：查找拋錯時，對局 `inputOperation`、`inputChiPengGang` 照送。
  - `R4-1b`：查找拋錯時，Naki 自送的 `inputOperation` 照送。
  - `R4-1c`：守衛健康時，對局 Blob 照送。
  - `R4-1d`：大廳已知非守衛方法遇內部錯誤，還原後送出。
  - `R4-1e`：大廳上的 FastTest 照送。
  - `R4-1f`：對局連線的 bridge 錯誤仍照送。
  - `R4-1g`：對局連線的 `.lq.Route.heartbeat` 照送。
- **紅→綠**：R4-1a～d 在 `round4-red-js.log` 為 not ok、在 `round4-green-js.log` 為 ok。R4-1e、f、g 是修後才加的，紅的證據是變異 K2、K3、K1。
- **變異**：K1–K5 全被抓。

### 新 2【擋】JS 配對仍跨連線共用 — 採納

- **設計**：§1.3「配對隔離」。
- **spike**：
  - `msgKey(socketId, msgId)` 統一為鍵：`rememberIfRequest`、`resolveMethod`、改寫後登記、`injectedMsgIds`（登記用 `sendRaw` 回傳的 `socketId`）、注入回應路由、`localResponse(socketId, msgId, method, bytes)`。
  - verdict 帶 `socketId`。`guardState().log` 也記連線。
- **測試**：`R4-2 (Astra3 2)`，即 Astra 的 303 反例：B 連線先送 `loginBeat(303)`，A 連線的 `changeCharacterSkin(303)` 被擋並結案，B 的真回應仍呼叫 `onReceive`，且 method 是 `loginBeat`。
- **紅→綠**：紅轉綠。變異 K6（鍵不含連線）、W7（結案不帶連線）被抓。

### 新 3【應修】D15 把「不拋錯」誤當成「成對送達」 — 採納，D15 撤回

- **設計**：§1.3「成對交付」、§3.6 第 4 點。
- **新做法**：一對放在同一則 bridge 訊息。`websocket_message` 的 `direction:'send'` 帶 `localResponse`，`postMessage` 只呼叫一次。
- **Swift**：`WebSocketInterceptor.handleWebSocketMessage` 先解兩份 base64，任一解不開就整筆不處理；都好才依序處理 REQUEST 與回應。回應的處理抽成 `handleReceived`，與一般收訊共用。
- **測試**：
  - `R4-3 (Astra3 3)`：用正式 `naki-core` 的 `sendToSwift`，只替換底層 `postMessage`，並讓它在 send、receive 兩個方向各拋錯一次。Swift 兩次都是零筆或一對，遊戲照常收到本地錯誤。
  - `testLocalExchangeMessageIsProcessedAsOnePair`：一對處理完後，A 的登記已消耗，B 的登記不受影響。
  - `testUndecodableLocalResponseDropsTheWholeExchange`。
- **紅→綠**：R4-3 紅轉綠。變異 W8（拆回兩則訊息）被抓；Swift 變異 S1（不處理成對的回應）、S2（回應解不開仍處理 REQUEST）各被抓。

### 新 4【應修】Naki 身分與回應認領只看 msgId — 採納（依主線指示另開工作包；本輪只證明後果）

- **設計**：§4.6。
- **結論**：
  - 在守衛範圍內（大廳、守衛方法），誤判為 Naki 只會造成本地錯誤，也就是多擋（fail-closed）。
  - 誤判為遊戲時，請求要過與遊戲換裝請求完全相同的守衛條件，不會更容易被放出去。
  - 對局連線與 FastTest 不做這個判斷。
- **可用性影響**：遊戲 msgId 落在 Naki 最近 256 筆 `sendRaw` 號碼，或 64000–65500 時，大廳換裝請求會得到本地錯誤，重試換號後恢復。落在 64000–65500 時，約 1500 筆請求內的守衛方法都會被擋。
- Swift 端 `LiqiResponseStore` 的認領與 `isNakiSent` 的反例屬另開工作包。

### 新 5【應修】D14 就地改寫分支會讓正常心跳無回應 — 採納

- **設計**：§4.1、§4.2 末條。
- **spike**：`runChain` 在大廳 send 方向的 hook 成功後檢查：若同一個 buffer 被就地改成另一個守衛方法，就拋出錯誤。走既有的 catch 路徑：撤回這個 hook 的改動、計一次插件失敗。原本無守衛的 REQUEST 照常送出。`replace` 階段的拒絕（D14）保留。
- **測試**：`R4-5 (Astra3 5)`。`heatbeat` 被就地改成 `useTitle` 後，送出的是原本的 `heatbeat` bytes，並記一次 `obs` 插件拋錯。原 `R4e` 斷言舊政策，已刪除，由 R4-5 取代。
- **紅→綠**：紅轉綠。變異 K7 被抓。

### 新 6【建議】明訂缺 socketId 的相容語意 — 採納

- **設計**：§1.3「socketId 契約」。`WebSocketInterceptor` 原本的「-1 只用於 log」註解已改寫。
- **測試**：`testSocketIdDefaultsAndMissingValues`，涵蓋三種邊界：
  - 直接呼叫時兩端都省略 → 都是 0，配得上。
  - bridge 兩端都缺 → 都是 -1，配得上。
  - 只有一端缺 → 配不上。
- 另寫明：錄影 replay 不經這個 parser，replay 綠不能當配對證據。

## 第二輪第 2、3 條的「部分」

- 第 2 條：由新 2 補齊 JS 端。
- 第 3 條：由新 3 改為單一訊息。

# 第四輪（Astra 第四輪審查，`.swfd/logs/pv2-b2-review/astra-review4.md`）

Astra 核對第三輪第 1–6 條：4 條已修，2 條部分（第 1、4 條）。另有新發現 3 條：擋 1、應修 1、建議 1。本輪證據為 `round5-*.log`。

**用戶裁決（2026-10-17）**：解鎖守衛照「協定握手鎖定角色」繼續，送第五輪審查；不做整體架構抽象化；D22 維持另開工作包。已寫入設計 §0 與 notes。

## 統計

| 類別 | 數量 | 條目 |
|---|---|---|
| 採納 | 3 | 新 1、2、3 |
| 反駁 | 0 | — |

新 1、新 2 屬安全與可用性的擋與應修，只能採納。新 3 是 Astra 判為 over-guard 的建議，經檢查縮窄後不開外送缺口，採納。

## 逐條

### 新 1【擋】URL 子字串判定仍會把對局連線納入守衛 — 採納

- **處理方式**：不改成「解析 URL 比對 pathname」，而是依用戶裁決改為協定握手鎖定角色（D25）。理由：pathname 仍是對 URL 形狀的假設，大小寫與編碼別名要另訂規則；live 已證實每條連線第二個請求就揭露角色。
- **設計**：§0、§1.3「前提」、新增 §1.4（規則、空窗證明、unknown 上解析失敗照送的理由與風險、殘餘）、§3.6、§4.1、§4.5、§6.2。
- **spike**：
  - `isLobbyUrl` 刪除，所有呼叫點改以 socketId 查角色：`dispatch` 分流、`refuseOpaqueSend(socketId)`、`failSafe(data, socketId)`、`replace` 的改寫成守衛方法檢查、污染判定。
  - 新增閉包內的 `roles`、`lockRole`。鎖定在 `dispatch` 第一步，早於零插件早退與守衛判定；`failSafe` 也先鎖定。
  - 新增 `closed(socketId)`；`guardState()` 多回 `roles`。
  - 接線 patch：`failSafe` 與 `refuseOpaqueSend` 改傳 `wsId`，`close` listener 呼叫 `closed`。
- **測試**：
  - `R5-1a`：`/game-gateway?next=/gateway` 與 `gateway.maj-soul.com/game-gateway` 經 `authGame` 鎖成 game，查找拋錯時 `heartbeat` 照送。
  - `R5-1b`：守衛健康時，同類 URL 的對局連線 Blob 照送。
  - `R5-1c`：只做 `prepareLogin` 的備援大廳，URL 為 `/Gateway`、`/%67ateway`、`/gateway` 都鎖成 lobby 並受守衛。
  - `R5-1d`：同一筆 Lobby 請求先鎖定、再判定。
  - `R5-1e`：鎖定後不變。
  - `R5-1f`：unknown 上解析不出照送，lobby 上拒送。
  - `R5-1g`：關閉清除角色。
  - `R5-1h`：零插件也鎖定。
- **紅→綠**：R5-1a～g 在 `round5-red-js.log` 為 not ok，在 `round5-green-js.log` 為 ok。R5-1h 修前已綠，紅的證據是變異 M3。
- **變異**：M1（角色改回 URL）、M2（unknown 當 lobby）、M3（鎖定移到判定之後）、M7（不通知關閉）、M8（`failSafe` 不鎖定）全被抓。
- **殘餘**：設計 §1.4 三項，照規則接受，記為已知風險。

### 新 2【應修】FastTest 提早返回仍會回流守衛 catch 與鏈後檢查 — 採納

- **設計**：§1.3「擋下的決定之前」、§1.4 殘餘第二項、notes D26。
- **spike**：
  - FastTest 與非 lobby 連線在 `dispatch` 開頭就走 `runChain(raw, env, null, false)`，不進 `guardedSend`。`plainChain` 刪除。
  - `runChain` 的就地改寫檢查改由第四個參數決定，只有 `guardedSend` 傳 true；現行鏈不讀 `sendGuard`。
  - 鏈拋出的例外照 main 交給 `naki-websocket` 的 catch；`failSafe` 對 FastTest 與非 lobby 直接照送。
- **測試**：
  - `R5-2a`：Astra 的反例。大廳上的 `inputOperation`，另一插件的 `methods.indexOf` 拋錯，照送且 `guardState().log` 為空。
  - `R5-2b`：observer 就地改動 FastTest 的 method，大廳與對局連線上 `sendGuard` 讀取次數都不變。
- **紅→綠**：兩條紅轉綠。變異 M4（FastTest 不提早返回）、M6（就地改寫檢查改回看角色）被抓。
- **取捨**：完全繞過的代價是 lobby 上 FastTest 被就地改成守衛方法時不再撤回。live 未見 lobby 連線上的 FastTest，記為殘餘。

### 新 3【建議】D23 可縮小拒送範圍 — 採納

- **設計**：§1.3「擋下的決定之前」、§9 第 3c 項、notes D27（D23 標為已改寫）。
- **spike**：`guardedSend` 的 catch 在守衛未定且原方法與改寫後方法都不在 `GUARDABLE_METHODS` 時，還原原 bytes 照送；否則擋下。`failSafe` 的 catch 同規則。解析不出的請求維持「有守衛者才擋」。
- **不開外送缺口的理由**：插件能宣告的守衛方法只在 `GUARDABLE_METHODS` 內，放行的請求都不是可守衛方法；實際送出的是原 bytes。判斷只用閉包常數與 parser，不讀出錯的 grant。
- **測試**：
  - `R5-3`：以 Astra 的手法把既有 `sendGuard` 陣列的 `indexOf` 改壞。`heartbeat`、`loginBeat`、`fetchAccountInfo`、`startUnifiedMatch` 照送；`changeCharacterSkin`、`useTitle` 拒送並收到錯誤回應；解析不出的拒送。
  - `R5-3b`：派發前 bridge 出錯的路徑，同規則。
- **紅→綠**：兩條紅轉綠。變異 M5（D27 撤回）被抓。

## 第三輪第 1、4 條的「部分」

- 第 1 條：URL 誤分類由新 1 改為握手鎖定；FastTest 例外回流由新 2 處理。
- 第 4 條：依用戶裁決（2026-10-17）D22 維持另開工作包，本輪不動。

# 第五輪（Astra 第五輪審查，`.swfd/logs/pv2-b2-review/astra-review5.md`）

Astra 核對第四輪第 1–3 條：第 1、3 條已修，第 2 條部分（對應新 5）。新發現 6 條，全是應修；總評可進入「向用戶確認接線與 Swift 配對改動」，確認稿須帶入適用範圍。本輪證據為 `round5b-*.log`。

## 統計

| 類別 | 數量 | 條目 |
|---|---|---|
| 採納（程式修改） | 1 | 新 6（補變異時發現 D27 雙側檢查只會多擋，改為只看原方法） |
| 採納（保證範圍限定，寫進設計與確認稿） | 4 | 新 1、2、3、5 |
| 採納（文件論證修正） | 1 | 新 4 |
| 反駁 | 0 | — |

新 1、2、3 是外送類，只能採納；三者都無法證明情境不可能，所以採納為保證範圍限定。

## 逐條

### 新 1【應修】`sendRaw` 無大廳候選時退回 game — 採納（保證範圍限定，D28）

- **無法反駁的依據**：`naki-websocket.js` 的 `sendRaw` 在 Lobby 方法的候選為空時退回全部連線（`pick.length > 0 ? pick : conns`），可能選到 game。這個檔不得改，所以不能在 `sendRaw` 層排除。
- **設計**：§1.4「保證範圍」第 1 項。解鎖插件的保證只在「頁面上沒有其他 `injectSend` 插件」時成立，確認稿須揭露。
- **測試**：`R6-1` 重現 Astra 的情境並鎖住現行行為：污染後停用守衛、關閉大廳，共存插件的 `sendRequest(changeCharacterSkin)` 從 game 外送，守衛紀錄為空。

### 新 2【應修】殘餘二不能歸為惡意 — 採納（保證範圍限定，D29）

- **設計**：§1.4「保證範圍」第 2 項。保證只涵蓋遵守 `ctx.replace` 契約的插件，撤回「屬 U4」。快取封包誤用列為推測的非惡意成因。
- **不改程式的理由**：第四輪第 2 條要求現行鏈不讀守衛狀態。若對 unknown 連線的 Route、lobby 連線的 FastTest 加就地改寫檢查，就要回到現行鏈讀 `sendGuard`。
- **測試**：`R6-2`：unknown 連線的 Route、lobby 連線的 FastTest 被就地改成完整 `changeCharacterSkin` 後外送；unknown 連線的角色不變。

### 新 3【應修】Blob 空窗 — 採納（文件限定，不採程式修法，D30）

- **評估的程式修法**：`refuseOpaqueSend` 在 unknown 連線、頁面有守衛者時也拒送。
- **不採的理由**：
  - 它違反用戶裁決「unknown fail-open」。鎖定前的任何 Blob 都會被拒，包含對局握手。
  - 它救不回保證。若客戶端真的改用 Blob，lobby 上的 Blob 在有守衛者時全部拒送，大廳已不可用。所以「客戶端送 TypedArray」本來就是整個守衛的前提，不是本項獨有。
  - live 未見 Blob，且 `__nakiWebSocket.diagnostics().send.Blob` 可觀測。
- **設計**：§1.4 空窗證明限定為「同步可解析的原 REQUEST」；「保證範圍」第 3 項寫明非同步副本稍後才鎖 lobby、不補拒送；§4.5 的全稱句改為只涵蓋 lobby 連線。
- **測試**：`R6-3`：首筆 Lobby Blob 在 unknown 連線照送，非同步副本鎖成 lobby 後，同步的守衛方法照常擋下。

### 新 4【應修】D27 的名單不能單獨證明 I2 — 採納（文件論證修正，D31）

- **設計**：§1.3 的 D27 段改寫。名單只說明哪些方法可以宣告守衛。名單外方法（例如與 `changeCharacterSkin` 同為 `ResCommon` 的 `useBagItem`）的 I2，改依解鎖設計 `unlock-plugin.md` §3.7 的三個條件：不改背包與商店回應、攔不住的入口以縮小功能處理、live 出現表外方法時停用 F4–F9。另寫明 D27 不比守衛健康時多放行任何方法。本設計不單獨宣稱 I2。

### 新 5【應修】D26 的繞過須限定封包形態 — 採納（文件限定，D32）

- **設計**：§1.4「保證範圍」第 4 項。已鎖 game 的連線不受守衛拒送。lobby 上只有同步可辨識、未被改壞的 FastTest 繞過守衛；被改壞的 FastTest 若之後 bridge 出錯會被 `failSafe` 拒送；lobby 上的 FastTest Blob 由 `refuseOpaqueSend` 拒送。
- **不改程式的理由**：讓「lobby 上原方法是 FastTest 一律照送」要把原方法狀態帶進 `failSafe`，多一條跨呼叫狀態。live 未見 lobby 上的 FastTest（YAGNI）。
- **測試**：`R6-4` 鎖住兩種結局：同一個 observer 把 FastTest 的 type byte 改壞，並讓編碼失敗，lobby 上拒送、game 上照送。

### 新 6【應修】M3 沒有零插件紅證據 — 採納（補變異，並修一處程式，D33）

- **變異**：`round5b-mutation-js.log`，13／13 被抓。
  - N1 零插件直接返回：`R5-1h` 紅。這補上 M3 缺的零插件紅證據。
  - N2 `failSafe` 改變既有角色：被新測試 `R6-5`、`R6-4` 抓到。
  - N3 D27 改回雙側、N4 照送前漏還原：被 `R6-6` 抓到。
  - N5 鎖定後仍可改變角色：被 `R6-5` 抓到。
  - M1–M8 在新樹上重跑，全被抓。
- **程式**：寫 N3 的測試時發現，D27 的「改寫後方法」檢查只會多擋。查找出錯時送出的是還原後的原 bytes，改寫後的方法不會外送。改為只看原方法。`R6-6` 修前紅、修後綠。
- **殘餘反例**：R6-1～R6-4 鎖住新 1、2、3、5 的現行行為。對應的保證範圍限定寫在設計 §1.4。

## 第四輪第 2 條的「部分」

由新 5 以文件限定封包形態補齊（D32）。
