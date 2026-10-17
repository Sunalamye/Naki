# guard-gaps 實作紀錄（2026-10-17）

分支 `feat/guard-gaps`（基底 main `c6f0df4`）。目標：v2.20.0 release note「已知限制」第 2 條的三項，原本在第五輪審查以「保證範圍限定」收掉（ADR D28–D30）。用戶裁決能修就修。只改 `naki-plugins.js`，`naki-websocket.js` 不動。

## 判斷

| 項 | 判斷 | 依據 |
|---|---|---|
| (a) `sendRaw` 退回對局，共存插件 `sendRequest` 外送守衛方法 | 可修 | `sendRaw` 同步呼叫包裝過的 `ws.send`，會在同一個呼叫堆疊回到 `dispatch`。插件層在 `sendRequest` 期間記下 msgId，就能在 `dispatch` 認出注入，不必改選線 |
| (b) 不經 `ctx.replace` 的就地改寫 | 可修 | 送出方向沒有就地的 `replace`（`rewriteSend` 換 buffer），所以「物件沒換、內容變了」就是不經契約。判斷只用閉包常數 `GUARDABLE_METHODS`，不讀 `sendGuard`，第四輪第 2 條不衝突 |
| (c) 角色未定時的第一筆 Blob | 可修，有代價 | Blob 無法同步解析。插件層拿不到 `originalSend`，延後送出會打亂順序。改為比照 lobby 規則拒送 |

## 做法

- (a) `ctx.sendRequest` 呼叫 `sendRaw` 前把 msgId 存進 `injectingMsgId`，`finally` 還原舊值，可重入。`dispatch` 看到同 msgId、連線不是 lobby，就呼叫 `injectedFallback`：這個方法有守衛者時以 `tainted_fallback` 走 `blockSend`。結果與大廳 `naki_traffic` 相同，`sendRequest` 回 `ok:true`，`onInjectResponse` 收到本地錯誤。守衛查找拋錯時只擋 `GUARDABLE_METHODS`。
- (b) `runChain` 原本只在大廳鏈上做的「就地改寫成守衛方法」檢查，擴到所有送出。大廳維持 `guardFor`，其他連線改看 `GUARDABLE_METHODS`。命中時拋錯，由既有 catch 撤回並計失敗。
- (c) `refuseOpaqueSend` 的條件由「是 lobby」改成「不是 game」，紀錄原因 `opaque_unknown_role`，並補記 socketId。

## Deviations

1. **(a) 擋在 `dispatch`，不在 `sendRequest` 入口拒送。** 主線預期在 `sendRequest` 直接拒送，但那會改掉大廳上的既有契約：`R8` 鎖住「被擋的注入回 `ok:true`，再經 `onInjectResponse` 收到本地錯誤」。在 `dispatch` 擋，大廳與退回兩條路對插件看起來一樣。
2. **(a) 條件比主線寬。** 主線寫「有任何插件已污染」。這裡用大廳 `naki_traffic` 的同一條件：這個方法有守衛者，未污染的已註冊守衛者也算。比較保守，也讓兩條路一致。紀錄原因仍用主線指定的 `tainted_fallback`，所以未污染時名稱不完全貼切。
3. **(b) 撤回，不污染。** 主線寫「視同改寫（污染＋同守衛規則）」。撤回之後送出的是原 bytes，沒有改寫結果外送，污染沒有作用。污染還要讀 grant 的 `sendGuard`，正是第四輪第 2 條要避免的。
4. **(b) 非大廳連線比大廳嚴。** 只看閉包常數，所以改成任何可守衛方法都撤回，不管頁面有沒有守衛者。同方法只改內容也撤回，順帶收窄了 §1.4「game 連線上的 Lobby 請求」那一項。大廳維持原規則，因為 `R6-6` 要靠大廳上「改成未守衛的可守衛方法照送」，才能殺掉 D33 的變異。
5. **(c) 比照 lobby 規則，不採延後。** 主線給兩個選項。延後需要原始的 `ws.send`。插件層只能再呼叫包裝過的 `send`，會讓這筆排到之後的同步送出後面，握手順序可能亂掉。比照 lobby 的代價：若客戶端改用 Blob，有守衛者時對局連線的握手也會被拒。但在那種情況下大廳本來就不可用（D30 原文），所以守衛的前提仍是「客戶端送 TypedArray」，沒有新增前提。條件也比主線寬，用的是任何守衛者，不限已污染，與 lobby 一致。
6. **`R4-1c` 改設定。** 原測試的「game 連線」其實沒送過 `authGame`，角色是 unknown。修後 unknown 上的 Blob 會被拒，所以先送 `authGame` 鎖 game，測的仍是原意。另加 `guard-gaps c` 鎖「沒有守衛者時 unknown 的 Blob 照送」。

## 驗證

log 都在主 repo `.swfd/logs/guard-gaps/`。

| 項目 | 結果 | log |
|---|---|---|
| 基線（改動前） | b2 73、v2 21、p4 24、plugin-regression 38，全綠 | `baseline-*.log` |
| 新測試套在 main 的 `naki-plugins.js` | 7 條紅，就是新增與改寫的 a／b／c 案例 | `red-b2-on-main-js.log` |
| 修後 node 四套 | b2 78／0、v2 21／0、p4 24／0、plugin-regression 38／0 | `green-*.log` |
| 變異 | 11／11 被殺 | `mutation.log` |
| `JSContractTests`＋`PluginSendGuardTests` | 18／0 | `swift-targeted.log` |
| 全量 NakiTests 第一次 | test host 在 `BotToolsTests.testStartDebugServerIsNoOpWhileFlagSet` 崩潰重啟，其餘 0 failure | `test-full.log` |
| 該測試單獨重跑 | 4／0 | `swift-bottools.log` |
| 全量 NakiTests 第二次 | 1181／0 | `test-full-2.log` |

第一次全量的崩潰沒有找到 crash report，原因未查明。它單獨重跑與第二次全量都綠，測試數與 v2.20.0 發版前全量相同（1181）。本包只改 JS，該測試不經守衛路徑，但 test host 會注入 `naki-plugins.js`，所以不能完全排除關聯。

## 未驗證

- live：可守衛方法都是換裝類，I2 禁止對真伺服器送出，實擋仍只有單測覆蓋（同 v2.20.0）。
- 退回情境在真實頁面上是否出現：live 從未觀察到「沒有大廳連線、只有對局連線」時有插件注入。
- 客戶端是否從不送 Blob：同 §4.5，看 `__nakiWebSocket.diagnostics().send.Blob`。

## 已知風險與殘餘

- Naki 自送經 `sendRaw` 退回到對局連線的守衛方法不擋，這是主線指定的範圍。Naki 的 Swift 端目前沒有送任何可守衛方法（`command/` 下 grep 19 個方法名為零）。`execute_js` 之類的通用入口不在此列。
- 就地改寫成「Naki 解析不出、伺服器解得開」的守衛方法不撤回，因為判斷依賴解析。歸入 §1.4 剩下的第 3 項。
- hook 保留 `ctx.bytes` 的參照、在之後的派發外改寫不在範圍內。派發到 `originalSend` 是同步的，非同步改寫趕不上這一筆。遊戲重用同一塊 heap view 的情況未驗證。

## 第二輪（Astra 第一輪審查：1【擋】5【應修】，主線全採納）

審查原文：主 repo `.swfd/logs/guard-gaps-review/astra-review1.md`。五個 Deviations 主線採納。

| 條 | 內容 | 處理 |
|---|---|---|
| 擋 1 | 鎖 game、污染 SKIN 後，hook 以 `ctx.replace` 把 `fetchCharacterInfo` 換成 SKIN，仍外送且無紀錄 | `runChain` 的送出改寫檢查涵蓋 `replace`：非大廳的鏈上，改後解析為 `GUARDABLE_METHODS` 就撤回並計 hook 失敗，不污染、不讀 `sendGuard`。大廳不變。§1.4 第 2 項改列實際剩餘來源，不再寫「插件改寫來源已收完」（`GG2-1`） |
| 應修 2 | 注入標記只比 msgId，注入派發中 hook 在另一條 game 連線同步送同號 SKIN 被誤擋 | 標記改成 `{ msgId, used }`，同 msgId 的第一次送出派發用掉它；之後同號的派發不算注入（`GG2-2`） |
| 應修 3 | game 上 `sendRequest(OP)` 多讀一次 `sendGuard` | `injectedFallback` 先以 `GUARDABLE_METHODS` 排除（`GG2-3`） |
| 應修 4 | `noteSuccess` 在違規檢查前，連續違規永遠記「第 1 次」 | 成功記帳移到檢查之後（`GG2-4`：第 10 次自動停用） |
| 應修 5 | Blob 代價被「大廳本來就不可用」帶過 | 設計 §1.4、ADR、契約明載獨立風險：只有 `authGame` 改用 Blob 時，對局連線持續被拒、角色持續 unknown、不會自行恢復；補混合型別案例（`GG2-5`）。保留拒送策略 |
| 應修 6 | 「還原 null」「僅正常返回時還原」兩個變異存活 | `GG2-6a`（`sendRaw` 拋錯後標記清掉）、`GG2-6b`（`sendRaw` 前巢狀注入，外層標記恢復）；型別矩陣與前 hook 合法改寫保留入固定回歸（`GG2-6c`） |

### 第二輪 Deviations

7. **擋 1 撤回的是「這個 hook 的改動」，不是整鏈。** 先前 hook 的合法改寫保留（`GG2-6c`）。與主線「送原 bytes」的差別只在多插件鏈；單一插件時就是原 bytes。這沿用既有 catch 的語意（契約「hook 拋錯」段）。
8. **應修 2 用「第一次派發用掉」綁定，不帶連線 id。** `sendRaw` 選線之後才知道連線，插件層拿不到。從設標記到包裝的 `ws.send` 進入 `dispatch`，中間不會跑插件程式碼（`sendRaw` 只做解碼與選線），除非頁面替換了 `sendRaw`（`GG2-6b` 模擬這種情況）。所以第一次同號送出派發就是這次注入。
9. **「還原 null 而非 prev」只在設標記與派發之間有巢狀注入時可觀測。** 正常的巢狀注入發生在外層派發的 hook 裡，那時外層標記已用掉，還原成 null 或 prev 結果相同。`GG2-6b` 以替換 `sendRaw` 製造派發前的巢狀注入，殺掉這個變異。
10. **恢復條件寫得比主線精確。** 主線寫「不會自行恢復」。實際要停用所有宣告 `sendGuard` 的插件；已污染時還要重載頁面，而重載後守衛插件若仍啟用會再次拒送。

### 第二輪驗證（log：主 repo `.swfd/logs/guard-gaps/r2-*`）

| 項目 | 結果 | log |
|---|---|---|
| 新測試套在第一輪 HEAD `65a7865` 的 JS | 4 紅（`GG2-1`～`GG2-4`）；`GG2-5`、`GG2-6a`～`GG2-6c` 鎖既有行為與殺變異，修前即綠 | `r2-red-b2-on-65a7865.log` |
| 修後 node 四套 | b2 86／0、v2 21／0、p4 24／0、plugin-regression 38／0 | `r2-green-*.log` |
| 變異 | 17／17 被殺（新增 N1～N7，第一輪 M 系列依新程式更新字串後重跑） | `r2-mutation.log` |
| `JSContractTests`＋`PluginSendGuardTests` | 18／0 | `r2-swift-targeted.log` |
| 全量 NakiTests（等另一個 xcodebuild 結束後跑，一次） | 1181／0，無 test host 重啟 | `r2-test-full.log` |

## 第三輪（Astra 第二輪審查：2【擋】1【應修】1【建議】，主線全採納）

審查原文：主 repo `.swfd/logs/guard-gaps-review/astra-review2.md`。Deviations 7–10 主線採納。兩個擋都是第二輪引入的回歸。

| 條 | 內容 | 處理 |
|---|---|---|
| 擋 1 | 第二輪把記帳移到驗證之後，連 `settle()` 一起移了；`settle` 呼叫 `then`，而 `then` 同步改回 SKIN 時已過了驗證 | `settle` 移回驗證前：先接管 thenable，再驗證，再記帳。`then` 同步給出的結果先暫存，驗證通過才記；判違規後不再記（`GG3-1`、`GG3-1b`） |
| 擋 2 | 「第一次派發用掉」可被注入前的同號派發（包裝選中 socket 的 `send`）用掉 | 標記改成 `{ msgId, bytes }`，同 msgId 且 bytes 與注入 envelope 完全相同才算注入，不再消耗（`GG3-2`）。第二輪 Deviation 8 的前提「除非替換 `sendRaw`」不成立，撤回 |
| 應修 3 | 同步違規拋錯跳過 `settle`，回傳的 rejected Promise 無人接 | 因擋 1 的順序，違規前已接管；catch 判違規後 rejection 被接住、不再計數，同次違規只計 1 次（`GG3-3`） |
| 建議 4 | 三個組合收進固定回歸 | `GG3-4a`（派發前內層注入拋錯、外層仍擋）、`GG3-4b`（`sendRaw` 回 `success:false` 後，同 bytes 的遊戲請求照送）、`GG3-4c`（近似方法＋補成 TITLE，兩種優先序都撤回） |

另：`GG2-6a` 的遊戲請求改成與那次注入 bytes 完全相同，否則改用 bytes 綁定後它殺不到「只在正常返回時還原」的變異。

### 第三輪 Deviations

11. **bytes 綁定的副作用。** 注入期間若有別的派發送出與注入 envelope 完全相同的守衛方法（同 msgId、同方法、同 payload），會被當成注入，在非大廳連線上擋下。這比放行保守，而且遊戲恰好送出完全相同的 bytes 只是理論情況。
12. **未採「保留參照比對」。** 主線給了「雜湊或參照」兩個選項。`sendRaw` 從 base64 重新解碼，送進 `dispatch` 的是新 buffer，參照不可能相同，所以比對內容。

### 第三輪驗證（log：主 repo `.swfd/logs/guard-gaps/r3-*`）

| 項目 | 結果 | log |
|---|---|---|
| 新測試套在第二輪 HEAD `8b7b097` 的 JS | 3 紅（`GG3-1`、`GG3-2`、`GG3-3`）；`GG3-1b`、`GG3-4a`～`GG3-4c` 鎖既有行為與殺變異，修前即綠 | `r3-red-b2-on-8b7b097.log` |
| 修後 node 四套 | b2 93／0、v2 21／0、p4 24／0、plugin-regression 38／0 | `r3-green-*.log` |
| 變異 | 23／23 被殺；新增 P1～P7，其中 P1、P2 是 Astra 兩個反例的變異形式 | `r3-mutation.log` |
| `JSContractTests`＋`PluginSendGuardTests` | 18／0 | `r3-swift-targeted.log` |
| 全量 NakiTests（一次） | 1181／0，無 test host 重啟 | `r3-test-full.log` |

## 第四輪（Astra 第三輪審查：1【擋】1【應修】1【建議】，主線全採納；rebase main）

審查原文：主 repo `.swfd/logs/guard-gaps-review/astra-review3.md`。Deviations 11、12 主線採納。

先 `git rebase main`（`ffe0670`）。JS 無文字衝突；ADR 尾端新增章節衝突，兩段都保留（main 的「已知限制不得只列不測」在前，guard-gaps 裁決在後）。main 把 `pluginLog` 改成回傳是否送達，本包沒有用到回傳值。rebase 後重跑四套全綠：b2 100、v2 21、p4 24、plugin-regression 38（`r4-rebased-*.log`）。

| 條 | 內容 | 處理 |
|---|---|---|
| 擋 1 | 驗證後的記帳仍執行插件程式碼：reject 值的 `message` getter、第 10 次的 `onDisable` 改保留的 bytes 成 SKIN，外送與 Swift 都是 SKIN | 每個 hook 在驗證（或撤回）完成時取送出快照，記帳放在快照之後，記帳完一律把 `raw.bytes` 參照、內容、`drop` 還原成快照。`noteFailure` 的錯誤訊息只讀一次並設防。快照、撤回、還原改用載入時取得的原生 `slice`／`set`（`GG4-1`～`GG4-5b`） |
| 應修 2 | §1.4 第 2 項混淆「派發後 buffer 被改」與「本次外送被改」 | 改寫成三段：本次外送內容（派發內無可改時點）、派發後改保留參照（不影響已提交資料，WebSocket `send` 提交語義）、另列「遊戲重用 buffer」前提 |
| 建議 3 | sink 只留參照 | 測試 Socket 的 `send` 在入口複製成 `committed`，與 `sent` 參照分開；收進 getter／cleanup 反例、完全相同 bytes 撞號（`GG4-6`）、雙 thenable 兩種順序（`GG4-7`）、延後 resolve 重設失敗計數（`GG4-8`） |

### 第四輪 Deviations

13. **送出快照以「記帳後還原到快照」實作，不回傳新 buffer。** 主線要求之後的外送路徑只用快照。回傳新 buffer 會改變送出物件的同一性（既有測試鎖「原物件送出」），也要動 `naki-websocket.js`。鏈結束到原生 `send`、送 Swift 編碼之間不執行插件程式碼，所以把內容還原成快照，與只用快照外送等價。
14. **一併修掉的既有缺口。** 同步 `throw` 一個 `message` getter 會改 bytes 的物件，在 `65a7865` 之前就能繞過撤回（撤回在 `noteFailure` 之前）。快照機制同時涵蓋（`GG4-1b`）。
15. **原生方法擷取只防實例覆寫。** 插件改 `Uint8Array.prototype` 屬同 realm 的惡意行為，沿用 U4，不宣稱防範。

### 第四輪驗證（log：主 repo `.swfd/logs/guard-gaps/r4-*`）

| 項目 | 結果 | log |
|---|---|---|
| 新測試套在 rebase 後未改的 `2e32b99` JS | 7 紅（`GG4-1`～`GG4-5b`）；`GG4-6`～`GG4-8` 鎖既有行為，修前即綠 | `r4-red-b2-on-2e32b99.log` |
| 變異 | 29／29 被殺；新增 Q1～Q6，Q6 一度存活，補 `GG4-5b` 後被殺 | `r4-mutation.log` |
| 修後 node 四套 | b2 110／0、v2 21／0、p4 24／0、plugin-regression 38／0 | `r4-green-*.log` |
| `JSContractTests`＋`PluginSendGuardTests` | 18／0 | `r4-swift-targeted.log` |
| 全量 NakiTests（一次，基底 main `ffe0670`） | 1183／0，無 test host 重啟（main 比上一輪多 2 個測試） | `r4-test-full.log` |

## 第五輪（Astra 第四輪審查：2【擋】2【應修】，主線全採納；撤回 Deviation 13）

審查原文：主 repo `.swfd/logs/guard-gaps-review/astra-review4.md`。

**主線裁決**：撤回 Deviation 13，改採根治。送出鏈上插件只拿宿主副本，外送只用宿主快照。原 ADR D28「`naki-websocket.js` 不得改」由主線解除，理由是 Astra 兩輪證明「保留原物件同一性」與只用快照外送不等價。

| 條 | 內容 | 處理 |
|---|---|---|
| 擋 1 | 原生 `slice` 會讀 `constructor`（species），插件在實例上定義 getter 就能在快照時改內容 | 宿主不再對插件拿過的陣列呼叫 `slice`；物化只用保存的 `%TypedArray%` 原型 `length` getter 與 `set`，都只讀內部槽（`GG5-1`，含 `sendRaw`＋`observeNakiTraffic`） |
| 擋 2 | 還原後仍有插件程式碼執行點：`sent.byteLength` getter、後插件的 `onSend` getter | 插件從不拿原物件或宿主快照，外送物件上沒有插件定義的屬性；前插件保留的副本被改也不影響（`GG5-2`、`GG5-3`） |
| 應修 3 | 錯誤訊息讀兩次 | 先存 `err.message` 一次再格式化（`GG5-5` 斷言讀取 1 次、`lastError` 是第一次的值） |
| 應修 4 | 重用 buffer 時第二筆照送 SKIN | 遊戲 buffer 不外露，第二筆是遊戲原內容 OP（`GG5-4`）；§1.4 該項改為「不適用」 |

### 實作

- `runChain` 的送出鏈（`raw.mutable !== false` 的 send）：
  - 鏈開始時 `cur = hostCopy(原件)`。
  - 每個 hook：`raw.bytes = hostCopy(cur)` 交給 `makeCtx`；hook 與 `then` 跑完後，`staged = hostCopy(raw.bytes)` 物化（含 `replace` 換上的新 bytes），驗證 `staged`，通過才 `cur = staged`；之後才記帳。
  - 鏈結束：內容與原件相同回 `undefined`（送原物件），不同回 `cur`。
- `hostCopy`：`new U8(taLength.call(b))` 加 `u8set.call(c, b)`。`U8`、`taLength`、`u8set` 載入時保存。
- receive 方向不變，第四輪的「記帳後還原」只留給 receive。
- `naki-websocket.js` 未改：`ws.send` 包裝本來就是 `originalSend(out || data)`，送 Swift 也是 `rewritten || data`。

### 第五輪 Deviations

16. **內容沒變時送原物件，不送快照。** 主線寫「外送只用快照」。原物件在送出鏈上從不交給插件，鏈結束到原生 `send` 之間也不執行插件程式碼，所以內容沒變時它與快照位元相同。這樣做保留了既有測試鎖住的「原物件送出」，也不必改 `naki-websocket.js`。內容有變時一律送宿主快照。
17. **`R6-4` 行為改變。** observer 只改副本，bridge 出錯時 `failSafe` 拿到遊戲的原 bytes。大廳上被改壞的 FastTest 從「拒送」變成「照送原內容」。送出的是遊戲自己未被修改的請求，比拒送保守。§1.4 第 1 項（D32）已同步。
18. **分離檢查改為依賴原生 `set` 拋錯。** 主線沒有指定。副本由宿主建立，buffer 不可調整大小；只有分離會讓內容不可讀，而分離時 `set` 會拋 TypeError。原先另寫的長度比對是死碼，已刪（`GG5-6`）。
19. **第四輪 Q1～Q3、Q5、Q6 變異不再適用。** 它們針對送出鏈的「記帳後還原」，這段程式只剩 receive 使用，送出鏈改由 S1～S8 覆蓋。

### 第五輪驗證（log：主 repo `.swfd/logs/guard-gaps/r5-*`）

| 項目 | 結果 | log |
|---|---|---|
| 新測試套在第四輪 HEAD `8ed6f1b` 的 JS | 8 紅（`GG5-1`～`GG5-6`、`GG5-8`、改寫後的 `R6-4`）；`GG5-7` 鎖既有行為，修前即綠 | `r5-red-b2-on-8ed6f1b.log` |
| 變異 | 30／30 被殺；新增 S1～S8 | `r5-mutation.log` |
| 修後 node 四套 | b2 118／0、v2 21／0、p4 24／0、plugin-regression 38／0 | `r5-green-*.log` |
| `JSContractTests`＋`PluginSendGuardTests` | 18／0 | `r5-swift-targeted.log` |
| 全量 NakiTests（一次） | 1183／0，無 test host 重啟 | `r5-test-full.log` |
| `git diff main --check` | 無警告（ADR、notes 檔尾空白行已修） | |
