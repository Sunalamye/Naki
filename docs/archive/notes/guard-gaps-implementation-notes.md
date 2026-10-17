# guard-gaps 實作紀錄（2026-10-17）

分支 `feat/guard-gaps`（基底 main `c6f0df4`）。目標：v2.20.0 release note「已知限制」第 2 條的三項，原本在第五輪審查以「保證範圍限定」收掉（ADR D28–D30）。用戶裁決能修就修。只改 `naki-plugins.js`，`naki-websocket.js` 不動。

## 判斷

| 項 | 判斷 | 依據 |
|---|---|---|
| (a) `sendRaw` 退回對局，共存插件 `sendRequest` 外送守衛方法 | 可修 | `sendRaw` 同步呼叫包裝過的 `ws.send`，會在同一個呼叫堆疊回到 `dispatch`。插件層在 `sendRequest` 期間記下 msgId，就能在 `dispatch` 認出注入，不必改選線 |
| (b) 不經 `ctx.replace` 的就地改寫 | 可修（第七輪起：就地改不得換 type／msgId／method，鏈尾另以目前狀態終判；第八輪起放行綁定註冊實例與污染版本、就地改要過結構檢查） | 送出方向沒有就地的 `replace`（`rewriteSend` 換 buffer），所以「物件沒換、內容變了」就是不經契約。判斷只用閉包常數 `GUARDABLE_METHODS`，不讀 `sendGuard`，第四輪第 2 條不衝突 |
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
    - **第六輪更正**：第五輪寫「buffer 不可調整大小」不成立。當時送出 `replace` 以 `new Uint8Array(newBytes)` 包裝，插件傳 `ArrayBuffer`／`SharedArrayBuffer`／resizable 時，`raw.bytes` 是插件持有的 buffer。第六輪起 `replace` 先 `hostCopy`，送出鏈上的 `raw.bytes` 一律是宿主 `new U8(n)` 建的固定長度 buffer，這句才成立。插件仍能分離它拿到的副本，分離時原生 `set` 拋錯，照撤回處理（`GG5-6`）。
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

## 第六輪（Astra 第五輪審查：1【擋】1【建議】，主線全採納）

審查原文：主 repo `.swfd/logs/guard-gaps-review/astra-review5.md`。Deviations 16–19 主線採納，Astra 確認 17 成立。

| 條 | 內容 | 處理 |
|---|---|---|
| 擋 1 | 送出 `replace` 以 `new Uint8Array(newBytes)` 包裝插件的 `ArrayBuffer`（帶自有 `length`）、SAB 或 resizable，與插件共用記憶體；入口驗 INFO 後插件改成 SKIN，hook 結束因 `replaced` 跳過守衛檢查，SKIN 外送且守衛紀錄為空；改 msgId 1204→1205 也外送 | 入口先 `hostCopy(newBytes)` 物化，只收 TypedArray，失敗回 `false`；驗證與採用同一份副本。hook 結束一律完整重驗：經 `replace` 的跑 `sendViolation`（envelope 完整、type REQUEST、msgId 不變、不在送出禁改名單），就地改的驗 type 與 msgId，兩者都過守衛規則，不再因 `replaced` 跳過（`GG6-1`、`GG6-1b`、`GG6-2`、`GG6-2b`、`GG6-2c`、`GG6-6`）。Dev 18 已更正 |
| 建議 2 | 固定入口型別矩陣 | `GG6-3`（replace 參數）、`GG6-4`（hook 回傳值），見下表 |

### 入口型別矩陣（現行行為，`GG6-3`／`GG6-4` 固定）

| 輸入 | 送出 `ctx.replace` 參數 | hook 回傳值 |
|---|---|---|
| `Uint8Array` | 接受（複製） | 不替換，hook 成功 |
| 跨 realm `Uint8Array` | 接受（內部槽與 realm 無關） | 不替換，hook 成功 |
| `Uint16Array`（元素都是 byte 值） | 接受，逐元素轉成 uint8 | 不替換，hook 成功 |
| SAB 上的 `Uint8Array` | 接受，複製當下內容 | 不替換，hook 成功 |
| resizable 上長度追蹤的 `Uint8Array` | 接受，複製當下內容 | 不替換，hook 成功 |
| 自有 `length` getter 會拋錯的 `Uint8Array` | 接受，getter 不被讀 | 不替換，hook 成功 |
| `Uint8Array` 的 Proxy | `false`，不計失敗 | 不替換，hook 成功 |
| array-like Proxy | `false`，不計失敗 | 不替換，hook 成功 |
| 普通陣列 | `false`，不計失敗 | 不替換，hook 成功 |
| `DataView` | `false`，不計失敗 | 不替換，hook 成功 |
| `ArrayBuffer`（含帶自有 `length`） | `false`，不計失敗 | 不替換，hook 成功 |
| `SharedArrayBuffer`（含帶自有 `length`） | `false`，不計失敗 | 不替換，hook 成功 |
| resizable `ArrayBuffer`（含帶自有 `length`） | `false`，不計失敗 | 不替換，hook 成功 |
| 已分離的 `Uint8Array` | `false`，不計失敗（原生 `set` 拋錯） | 不替換，hook 成功 |
| 越界的 `Uint8Array`（resizable 縮小） | `false`，不計失敗（原生 `set` 拋錯） | 不替換，hook 成功 |
| `null` | `false`，不計失敗 | 不替換，hook 成功 |

- 接受後內容不合規（type／msgId／method／禁改名單／envelope 不完整）照舊回 `false` 並計一次 `replace` 失敗；大廳上改成另一個有守衛者的方法也是。
- hook 回傳值只讀 `then`，其餘一律不看。`then` getter 拋錯算 hook 失敗（第二輪起的既有行為，不在本表）。
- 「不讀自有屬性」現在同時適用 `replace` 入口與物化步驟。receive 等長 `replace` 仍讀 `newBytes.length` 決定走等長或變長，等長時用原生 `set` 寫入後重新解析，未在本輪改動。

### 第六輪 Deviations

20. **`GG6-1` 斷言「守衛紀錄為空」，不是主線寫的「非空」。** 修後 `replace` 收到 buffer 就回 `false`，INFO 照原樣送出，SKIN 從未形成，守衛沒有東西可記。測試改斷言更強的條件：wire 與 Swift 都是原 INFO，且 Swift 收到的請求沒有任何一筆是 SKIN。
21. **receive 方向的變長 `replace`（`reshapeReceive`）一併改為先物化。** 主線只點名送出。它有同樣的共用記憶體問題：驗證後改傳入的 buffer，後續插件與遊戲看到的就不是驗過的內容。改法相同，保守處理（`GG6-5`）。
22. **（第七輪撤回，見 Deviation 26）就地改的完整重驗只驗 type 與 msgId，不套送出禁改名單與 envelope 完整性。** 主線寫「完整重驗（type／msgId／method／守衛）」。就地改沒有 `rewriteSend` 能力也能做，既有測試（`GG5-8`、`guard-gaps b`、`GG2-6c` 等）鎖住「合法就地改照送」，FastTest 與 Route 方法都不在 `.lq.Lobby.` 底下，套禁改名單會全數撤回。method 由守衛規則把關。經 `replace` 的內容照 `rewriteSend` 規則全驗。
23. **就地改的新增撤回會計 hook 失敗。** 改 type 或 msgId 的就地改寫從「照送」變成「撤回並計一次 onSend 失敗」，連續 10 次自動停用。遊戲在等原 msgId 的回應，照送會讓遊戲掛住，撤回較保守（`GG6-2b`）。
24. **（第七輪撤回，見 Deviation 26）鏈中斷條件不變。** 只有經 `replace` 換了 method 才停止後續插件；就地改 method 照舊繼續。試過改成一律中斷，會改變 `GG3-4c` 的既有語意，已回退。
25. **`T7` 為等價變異，不計入。** hook 結束對 `replace` 內容跑的 `sendViolation` 與入口是同一個純函式、同一份宿主副本（插件拿不到它）、同一個 msgId，結果必然相同。主線要求一律重驗，程式保留，作為縱深防禦。守衛規則那一半（`T8`）不等價：入口之後新出現的守衛會被 hook 結束的重驗擋下，由 `GG6-6` 殺掉。

### 第六輪驗證（log：主 repo `.swfd/logs/guard-gaps/r6-*`）

| 項目 | 結果 | log |
|---|---|---|
| 新測試套在第五輪 HEAD `f004e53` 的 JS | 5 紅：`GG6-1`、`GG6-2`、`GG6-2b`、`GG6-3`、`GG6-5`。`GG6-1b`、`GG6-2c`、`GG6-4`、`GG6-6` 修前即綠，用來固定行為（傳 view 時舊碼本來就複製） | `r6-red-b2-on-f004e53.log` |
| rebase | 到 main `92dbe39`，無衝突 | |
| 變異（b2＋v2＋p4 三套，扣除變異目錄的基線失敗） | 38／39 被殺。新增 T1～T9，T7 為等價變異（Deviation 25） | `r6-mutation.log` |
| rebase 後 node 四套 | b2 127／0、v2 21／0、p4 24／0、plugin-regression 39／0；另 keepalive 11／0 | `r6-green-*.log` |
| `JSContractTests`＋`PluginSendGuardTests` | 19／0 | `r6-swift-targeted.log` |
| 全量 NakiTests（一次） | 1184／0，無 test host 重啟 | `r6-test-full.log` |
| `git diff main --check` | 無警告 | |

- 變異基線：p4 的 `main parity` 在變異目錄（不在 git 工作樹內）必紅，與變異無關，每個變異的失敗都先扣掉它。上一輪的 `r5-mutation.log` 只跑 b2，沒有這個問題。

### 第六輪未驗證與風險

- WebKit 上 `hostCopy` 對 SAB、resizable、跨 realm TypedArray 的行為只在 node 驗過，未在 WebKit 實測。依規範內部槽行為一致，未驗證。
- 插件在別的執行緒經 SAB 改內容與 `hostCopy` 的競態未測。複製後的副本與 SAB 無關，競態只影響「複製到哪一刻的內容」，複製後的內容仍會完整驗證。
- 就地改 type／msgId 由「照送」改為「撤回並計失敗」。既有插件若依賴這種改寫會開始累計失敗，naki-plugins 回歸 39／0，未見依賴。
- live 擋下未驗證（I2）。

## 第七輪（Astra 第六輪審查：2【擋】2【應修】1【建議】，主線全採納）

審查原文：主 repo `.swfd/logs/guard-gaps-review/astra-review6.md`。主線撤回 Deviation 22、24，採納 20、21、23、25。

| 條 | 內容 | 處理 |
|---|---|---|
| 擋 2（主裁決） | 就地改可把 `fetchServerTime` 換成同長的禁改方法 `fetchOauth2Info`，type／msgId 不變就外送且不計失敗 | hook 結束時就地改的 method 與原 method 不同即撤回、計 onSend 失敗，與 type／msgId 同級。換 method 只能經 `replace`（`GG7-1`，`fetchOauth2Info` 與 `loginBeat` 兩例、大廳與對局） |
| 擋 1 | 前 hook 就地改成當時未受守衛的 `useTitle`，後 hook 註冊守衛；最終候選不再判定，撤回點停在違規的中間快照；同步 receive 重入污染亦同 | 鏈尾終判 `finalViolation`：最終候選須 type／msgId 不變、不在送出禁改名單、過守衛規則，不過就整筆退回遊戲原內容，失敗記在最後改動者（`GG7-5`）。`guardedSend` 鏈後以目前 `guardFor` 重算守衛者，鏈中新增者未放行即 `not_on_chain`（`GG7-3`、`GG7-4`、`GG7-4b`） |
| 應修 3 | 就地換 method 後回應配對與後續 hook 的 `ctx.method` 過期 | 擋 2 之後就地改不會換 method；另外每次採用改動都重新解析 `env`，後續 hook 的 `ctx.method`／`ctx.payload` 依當前快照（`GG7-2`：RESPONSE 交給 wire 上的方法的插件） |
| 應修 4 | receive 假 `length` 讓 9-byte RESPONSE 走等長路徑，原生 `set` 只覆寫前段，殘留尾碼成為第二個 payload | 入口先 `hostCopy`，以實際長度選路；寫入與還原用保存的原生 `set`，`raw.bytes` 的長度也只讀內部槽（`GG7-6`、`GG7-6b`） |
| 建議 5 | ADR 保證範圍段仍寫「lobby 上被改壞的 FastTest 會被拒送」；§1.4 角色回收未提 `error` | 兩處已更正 |

### 第七輪 Deviations

26. **撤回 22、24 後的規則。** 就地改不得換 method，所以「就地換 method 後鏈繼續」的情況不再存在；鏈只在經 `replace` 換了 method 時停止。`GG3-4c` 的期望改為原 OP：近似方法那一步本身就是就地換 method，第一步就撤回。
27. **hook 層撤回仍回到前一個快照，只有鏈尾終判退回原始。** 主線寫「撤回永遠回到原始快照」。hook 層若也退回原始，會丟掉前面插件的合法改動，違反契約「前面插件的合法改寫保留」與 `GG4-7`、`GG7-7` 等既有測試。Astra 的反例是「撤回停在已變成違規的中間快照」，鏈尾終判對最終候選以目前狀態再判，任何留下的違規都會整筆退回原始，已涵蓋。採這個解讀。
28. **「B 再改 payload ⇒ 退回原始」在新規則下結果不同。** A 就地換成 `useTitle` 在 A 的 hook 結束就撤回，B 的合法 payload 改動作用在原 `fetchServerTime` 上，照送。`GG7-3` 斷言 wire 是「原 method＋B 的 payload」、沒有任何 `useTitle`。
29. **主線的 replace 版反例（A `replace` 成 `useTitle`、B 再註冊守衛）走不到 B。** `replace` 換了 method 鏈就停，B 不會執行。鏈中新增守衛者改以同 method 的版本驗：`GG7-4` 用 `changeCharacterSkin`，分註冊與同步 receive 重入 `ctx.taint()` 再停用兩種，各含有改／沒改內容；`GG7-4b` 是原本已有守衛者、鏈中再加一個。
30. **鏈中才出現的守衛者，即使內容沒改也擋。** 新守衛者的 hook 不在這次的鏈上，無法放行。依 N1「守衛者全部放行才送」擋下並回本地錯誤。下一筆兩者都在鏈上，正常放行（`GG7-4b`）。
31. **鏈尾的送出禁改名單也套在「同 method 改內容」。** 原本就地改禁改方法（登入、憑證類）的 payload 沒有任何檢查。鏈尾終判一律不讓禁改方法帶著改動外送（`GG7-5`）。FastTest、Route 不在名單內，照舊可就地改 payload。
32. **receive `replace` 只收 TypedArray。** 先物化的直接結果。普通陣列以前可以，現在回 `false`。p4、v2、naki-plugins 回歸都沒有傳陣列。
33. **`reshapeReceive` 不再自己複製。** 它只由 receive `replace` 呼叫，收到的已是入口物化的副本。第六輪的 `T5` 因此不再適用，已自變異清單移除。
34. **兩個等價變異不計入。** `T7` 同第六輪 Deviation 25。新加的 `U10`（變長入口改傳 `new Uint8Array(newBytes)`）也等價：入口已確認是 TypedArray，以 TypedArray 建構時同樣只讀內部槽並複製。第六輪 `T8`、第二輪 `N6`、`M11` 在加了鏈尾終判後一度存活，因為鏈尾會接住同一個違規；`GG7-7` 斷言 hook 層撤回會保留前面插件的合法改動，而且沒有鏈尾終判紀錄，三者重新被殺。

### 第七輪驗證（log：主 repo `.swfd/logs/guard-gaps/r7-*`）

| 項目 | 結果 | log |
|---|---|---|
| 新測試套在第六輪 HEAD `87f7d73` 的 JS | 8 紅：`GG7-1`～`GG7-6`、`GG7-4b`、改寫後的 `GG3-4c`。`GG7-6b`、`GG7-7` 修前即綠，用來固定 hook 層行為 | `r7-red-b2-on-87f7d73.log` |
| rebase | main 仍是 `92dbe39`，分支已在其上，無需再 rebase | |
| 變異（b2＋v2＋p4，扣基線） | 46／48 被殺。新增 U1～U9 全殺；存活的 `T7`、`U10` 為等價變異（Deviation 34） | `r7-mutation.log` |
| node 五套 | b2 136／0、v2 21／0、p4 24／0、plugin-regression 39／0、keepalive 11／0 | `r7-green-*.log` |
| `JSContractTests`＋`PluginSendGuardTests` | 19／0 | `r7-swift-targeted.log` |
| 全量 NakiTests（一次） | 1184／0，無 test host 重啟 | `r7-test-full.log` |
| `git diff main --check` | 無警告 | |

### 第七輪未驗證與風險

- 鏈中才出現的守衛者會讓當筆守衛方法改回本地錯誤，即使內容沒改。實務上熱啟用由 Swift 的 `evaluateJavaScript` 觸發，不會在同步派發中途發生；同步 receive 重入污染只在插件於 `onSend` 裡同步派發 receive 時出現，live 未見。
- 就地改登入、憑證類禁改方法的 payload，從照送改為整筆退回並計失敗。naki-plugins 回歸 39／0，未見依賴。
- WebKit、live 未驗證（I2）。

## 第八輪（Astra 第七輪審查：1【擋】4【應修】，主線全採納）

審查原文：主 repo `.swfd/logs/guard-gaps-review/astra-review7.md`。Deviations 26–34 主線採納。

| 條 | 內容 | 處理 |
|---|---|---|
| 擋 1 | 守衛先放行，之後同一筆送出中被污染（後 hook 同步 receive、另一條大廳連線），或同 id 停用再註冊，舊放行仍有效；實際 local-unlock 插件 2301 外送、2302 才擋 | registry 實例帶遞增 `token`，`taint` 改變污染狀態時遞增版本。放行紀錄是 `{ id, token, version }`，`version` 在 hook 執行前取。`guardFailure` 核對目前實例與版本，任一不符即 `not_on_chain`（`GG8-1` 同／異連線、`GG8-2` 重新註冊後下一筆跑新 `onSend`、`GG8-3` 實際插件 2301 與 2302 都擋） |
| 應修 2 | 鏈尾違規前先 `noteSuccess` 歸零，永遠是第 1 次，不會自動停用 | 送出鏈的成功（含 thenable 的判定）延後到鏈尾判決之後；違規者 `judge` 記失敗、thenable 結果不再算（`GG8-4`，含 thenable，第 10 次停用） |
| 應修 3 | 最後改動者取自插件可改的 `spec.id`，能停用別人 | `register` 只讀一次 `spec.id`，存在 registry 實例的 `id`；鏈、歸責、停用、`onDisable` 的 log 都用它（`GG8-5`）。晚到的 thenable 結果只算給當時的實例（`GG8-10`） |
| 應修 4 | 唯一未污染守衛在鏈中停用，重算讀到 null 拋錯，誤擋成 `dispatch_error` | 重算後沒有守衛者、且開頭的守衛者沒有拋錯或 thenable：本筆解除守衛，送原請求，記 `sent`／`guard_left`（`GG8-6`）。還有其他守衛者：其餘依放行判定（`GG8-7`） |
| 應修 5 | 等長 receive `replace` 把 payload 長度 2 改 127 仍回 true；A 合法 replace 後 B 就地破壞長度照送 | 兩條路都加 `isWellFormed`：receive 回 `false` 並還原，就地改撤回並計失敗（`GG8-8`、`GG8-9`）。FastTest／Route 合法同方法改寫的既有測試不變 |

### 第八輪 Deviations

35. **污染版本只在污染狀態改變時遞增。** 主線寫「每次 taint 遞增」。已污染的守衛者在自己的 `onSend` 再呼叫 `ctx.taint()`、方法集合沒變時，遞增會讓它自己這一筆的放行作廢，違反契約「重複呼叫沒有副作用」。改為第一次污染或多了守衛方法才遞增（`GG8-13`，變異 `V15`）。Astra 的反例都是第一次污染，照樣擋下。
36. **放行用的污染版本在 hook 執行前取。** 守衛者自己的 hook 裡同步觸發 receive、讓自己第一次被污染，這次放行也作廢。比在記帳時取保守（變異 `V3`）。
37. **開頭的守衛者拋錯或回 thenable 後全部退出，仍然擋。** 主線寫「唯一守衛自停用或被停用 ⇒ 本筆解除守衛」。守衛者拋錯在 N2 就是擋下的理由，第 10 次拋錯會自動停用，若照解除處理，第 10 次的拋錯反而變成照送。只有正常返回後退出才解除（`GG8-14`，變異 `V16`）。
38. **解除守衛時送遊戲原請求，插件的改動不送。** 照主線「照送原請求」。
39. **成功記帳只對送出鏈延後。** receive 鏈沒有鏈尾判決，維持原本「驗證完成即記帳、記帳後還原」。
40. **鏈尾記帳之後再判一次。** 記帳會執行插件程式碼，例如 thenable 早到的 rejection 累計到第 10 次時的 `onDisable`，它能在判決之後註冊守衛者。第二次判定不過時只退回原內容並寫 log，不再記帳，之後不再有插件程式碼執行（`GG8-11`）。
41. **`finalViolation` 不加 `isWellFormed`。** 每個 hook 結束時，就地改已驗結構，`replace` 已由 `sendViolation` 驗過，鏈尾再驗是等價的死碼。試加後該變異存活，已移除。
42. **實際 local-unlock 插件整合放在 b2 回歸。** 沿用 naki-plugins 的 `tests/local-unlock-naki.cjs` harness，不另寫一份；找不到 naki-plugins 時略過，路徑可用 `NAKI_PLUGINS_DIR` 指定（`GG8-3`）。naki-plugins 自己的整合測試另跑一次。
43. **`T3`、`T9` 一度存活。** 鏈尾也查 type／msgId，單一插件時兩層結果相同。`GG8-12` 斷言違規在 hook 層撤回、保留前面插件的合法改動，而且沒有鏈尾終判紀錄。

### 第八輪驗證（log：主 repo `.swfd/logs/guard-gaps/r8-*`）

| 項目 | 結果 | log |
|---|---|---|
| 新測試套在第七輪 HEAD `eccac35` 的 JS | 10 紅：`GG8-1`～`GG8-6`、`GG8-8`～`GG8-10`、`GG8-14`。`GG8-7`、`GG8-11`～`GG8-13` 修前即綠，用來固定行為 | `r8-red-b2-on-eccac35.log` |
| rebase | main 仍是 `92dbe39`，分支已在其上 | |
| 變異（b2＋v2＋p4，扣基線；`NAKI_PLUGINS_DIR` 指向 naki-plugins，`GG8-3` 不略過） | 61／63 被殺。新增 V1～V13、V15、V16 全殺；存活的 `T7`、`U10` 為既有等價變異 | `r8-mutation.log` |
| node 五套 | b2 150／0（0 略過）、v2 21／0、p4 24／0、plugin-regression 39／0、keepalive 11／0 | `r8-green-*.log` |
| naki-plugins `local-unlock-naki.cjs`（NAKI_ROOT＝本 worktree） | 9／0 | `r8-green-local-unlock-naki.log` |
| `JSContractTests`＋`PluginSendGuardTests` | 19／0 | `r8-swift-targeted.log` |
| 全量 NakiTests（一次） | 1184／0，無 test host 重啟 | `r8-test-full.log` |
| `git diff main --check` | 無警告 | |

### 第八輪未驗證與風險

- 同一筆送出中守衛者被污染或重新註冊時，這一筆改回本地錯誤，即使內容沒改。live 上污染由大廳回應改寫觸發，與換裝請求同步交錯的機率低，未見。
- 未污染守衛者在一筆送出中途停用時，這一筆送遊戲原請求，不送其他插件的改動。
- WebKit、live 未驗證（I2）。

## 第九輪（Astra 第八輪審查：2【應修】1【建議】，主線全採納）

審查原文：主 repo `.swfd/logs/guard-gaps-review/astra-review8.md`。Deviations 35–43 主線採納。

| 條 | 內容 | 處理 |
|---|---|---|
| 應修 1 | 唯一守衛自停用後 `replace` 把 SKIN 換成 loginBeat：wire 退回原 SKIN（`guard_left`），RESPONSE 卻派給 loginBeat 插件 | 大廳鏈的 `runChain` 不再自己登記配對；`guardedSend` 在判決之後，依 `raw.bytes`（擋下、解除守衛、退回原內容時都已還原成原請求）呼叫 `pairWith` 提交。非大廳鏈沒有守衛判決，維持鏈尾提交（`GG9-1`） |
| 應修 2 | 記帳以 id 查表：舊實例延後的成功清掉新實例的計數、舊實例的鏈尾違規算給新實例、晚到 rejection 的 `message` getter 換實例後算給新實例 | `noteFailure`／`noteSuccess` 改收註冊實例，讀完錯誤訊息後才核對 `registry.get(id) === entry`，不符就丟棄；停用也只停那個實例。所有呼叫端（鏈、`replace`、`onInjectResponse`、`onRecommendations`、thenable）都傳實例（`GG9-2`、`GG9-2b`） |
| 建議 3 | 契約「由其餘守衛者照常判定」沒交代退出前已否決的情況 | 契約補例外；`GG9-3` 鎖住拋錯與 thenable 兩種，修前即綠 |

### 第九輪 Deviations

44. **配對以判決後的 `raw.bytes` 為準，不另算。** 擋下（`blockSend`）、`guard_left` 與例外路徑都先把 `raw.bytes` 還原成遊戲原物件，放行時 `raw.bytes` 是要送的快照，所以一個出口統一提交，不在每個分支各寫一次。
45. **（第十輪改寫，原前提被 Astra 第九輪推翻）** 原文說擋下後 `respondLocal` 結案「先刪」配對、因此觀察不到。實際順序是先把合成錯誤交給遊戲、再於 `localResponse` 刪配對，遊戲在回呼內以同 msgId 新送的請求配對會被刪掉，而且結案前抵達的同號 RESPONSE 會被派給被擋的方法。第十輪改成擋下當下撤銷配對、本地結案不碰配對，補 `GG10-1`（三種擋下原因）與 `GG10-1b`（擋下後不留配對）。Blob 與無法辨識、沒有回應的路徑不經這段，本來就不建立也不清配對。
46. **實例核對放在 `noteFailure`／`noteSuccess` 裡，不只放在鏈上。** 主線點名鏈尾與 thenable。放在記帳函式本身，`replace`、`onInjectResponse`、`onRecommendations` 也一併受保護，第八輪 thenable 入口的個別核對就不需要了。第八輪變異 `V12` 因此不再適用，由 `W3`、`W4` 取代。
47. **`runChain` 在大廳上也登記配對的變異是等價的。** `guardedSend` 判決後一定會用同一個 key 覆寫，所以不列入變異。

### 第九輪驗證（log：主 repo `.swfd/logs/guard-gaps/r9-*`）

| 項目 | 結果 | log |
|---|---|---|
| 新測試套在第八輪 HEAD `78b14a3` 的 JS | 3 紅：`GG9-1`、`GG9-2`、`GG9-2b`。`GG9-3` 修前即綠，用來固定建議 3 的行為 | `r9-red-b2-on-78b14a3.log` |
| rebase | main 仍是 `92dbe39`，分支已在其上 | |
| 變異（b2＋v2＋p4，扣基線，`NAKI_PLUGINS_DIR` 指向 naki-plugins） | 64／66 被殺。新增 W1、W3、W4、W5 全殺；存活的 `T7`、`U10` 為既有等價變異 | `r9-mutation.log` |
| node 五套 | b2 154／0（0 略過）、v2 21／0、p4 24／0、plugin-regression 39／0、keepalive 11／0 | `r9-green-*.log` |
| naki-plugins `local-unlock-naki.cjs` | 9／0 | `r9-green-local-unlock-naki.log` |
| `JSContractTests`＋`PluginSendGuardTests` | 19／0 | `r9-swift-targeted.log` |
| 全量 NakiTests（一次） | 1184／0，無 test host 重啟 | `r9-test-full.log` |
| `git diff main --check` | 無警告 | |

### 第九輪未驗證與風險

- 舊實例的記帳整筆丟棄，包括 log。插件停用或重新註冊前一刻的失敗不會出現在 log。
- WebKit、live 未驗證（I2）。

## 第十輪（Astra 第九輪審查：2【應修】1【建議】，主線全採納）

審查原文：主 repo `.swfd/logs/guard-gaps-review/astra-review9.md`。Deviations 44–47 主線採納，45 前提被推翻，已改寫。

| 條 | 內容 | 處理 |
|---|---|---|
| 應修 1 | 遊戲在合成錯誤回呼內以同 socket／msgId 送 loginBeat：wire 已送，但舊 `localResponse` 隨後刪掉新配對，真 RESPONSE 的 method 變成 null；`hook_threw`、`guard_error`、`dispatch_error` 都重現 | 採「擋下當下清舊配對」：`blockSend` 撤銷被擋請求在鏈首登記的配對，`guardedSend` 只在沒擋下時提交配對，`localResponse` 不再碰 `pendingMethods`。清理在 `ws.send` 同步返回前完成，早於任何遊戲回呼（`GG10-1` 三路、`GG10-1b`） |
| 應修 2 | 舊 A 的 `onDisable` 註冊同 id 新 A 並連錯九次，外層 `disable` 返回時無條件刪掉新 A 的 failures 與 grant，第十次沒停用 | `disable` 在 `cleanup` 之後，只在 registry 沒有同 id 實例時才清 failures 與 grant（`GG10-2`） |
| 建議 3 | §1.4 仍寫「就地改寫沒有結構檢查」，第 2 項亦引用 | §1.4 第 2、3 項與保證範圍第 8 項改寫：原請求在 unknown 上解析失敗照送（殘餘風險）；hook 產生的解析不出或結構不完整改寫一律撤回；殘餘只剩 parser 與伺服器的解析差異 |

### 第十輪 Deviations

48. **配對清理放在 `naki-plugins.js`，不改 `naki-websocket.js`。** 主線給兩個選項：拆開 `respondLocal` 的清理與通知，或刪除帶交易代號。本包可改清單不含 `naki-websocket.js`，所以採第一個選項的語意、在插件層完成：擋下當下（同步、在 `setTimeout` 排的遊戲回呼之前）就撤銷配對，結案時不刪。效果等於「先清舊配對，再通知遊戲」，不需要交易代號。
49. **擋下的請求不提交配對，連 `failSafe`、`tainted_fallback` 路徑也一樣。** 三條路都經 `blockSend`，在那裡撤銷一次即可。被擋的請求不上 wire，留著配對只會讓同號的 RESPONSE 被派給被擋的方法（`GG10-1b` 修前即重現：結案前抵達的同號 RESPONSE 派給了 SKIN 插件）。撤銷依 (連線, msgId) 刪除；若同號有更早、仍在路上的請求，它的配對也會一併消失，這與修前 `localResponse` 的行為相同，遊戲在同連線重用未答的 msgId live 未見。
50. **`onDisable` 內只換 grant、沒有重新註冊時，grant 照舊刪除。** 主線條件是「registry 沒有新實例才清」。沒有實例掛著的 grant 不屬於任何註冊，保守起見刪掉；要重新啟用由 Swift 照 `setGrant` → `register` 順序再做。
51. **自動停用路徑不需要同樣修正。** `noteFailure` 達上限時只 `registry.delete`＋`cleanup`，之後不清 failures 或 grant；`onDisable` 內重新註冊會由 `register` 重設計數，與 `GG10-2` 的預期一致。

### 第十輪驗證（log：主 repo `.swfd/logs/guard-gaps/r10-*`）

| 項目 | 結果 | log |
|---|---|---|
| 新測試套在第九輪 HEAD `a0e4930` 的 JS | 3 紅：`GG10-1`、`GG10-2`、`GG10-1b`。`GG10-1` 三種原因各自單跑：修前各 1 紅，修後各 0 | `r10-red-b2-on-a0e4930.log` |
| rebase | main 前進到 `b35c57c`（只在 ADR 尾端加一段 devLogSeal 裁決），已 rebase。每個 commit 的 ADR 尾端附加衝突以「main 段在前、本包段在後」兩邊並存解決；rebase 後與 rebase 前的樹只差 main 那段 ADR。node 五套與 local-unlock 在 rebase 後重跑，結果同下表。Swift 指定與全量是 rebase 前跑的；rebase 只多了 ADR 文字，程式與測試檔逐位元相同，未重跑 | `r10-rebased-*.log` |
| 變異（b2＋v2＋p4，扣基線，`NAKI_PLUGINS_DIR` 指向 naki-plugins） | 69／71 被殺。新增 X1–X5 全殺；W1 改成新字串仍被殺；存活的 `T7`、`U10` 為既有等價變異 | `r10-mutation.log` |
| node 五套 | b2 157／0（0 略過）、v2 21／0、p4 24／0、plugin-regression 39／0、keepalive 11／0 | `r10-green-*.log` |
| naki-plugins `local-unlock-naki.cjs` | 9／0（`NAKI_ROOT` 指向本 worktree，0 略過） | `r10-green-local-unlock-naki.log` |
| `JSContractTests`＋`PluginSendGuardTests` | 19／0 | `r10-swift-targeted.log` |
| 全量 NakiTests（一次） | 1184／0 | `r10-test-full.log` |

### 第十輪未驗證與風險

- 擋下時依 (連線, msgId) 撤銷配對，同號更早的未答請求的配對會一併消失（Deviation 49）。
- 遊戲在合成錯誤回呼內重送的行為只在 node 替身驗證；WebKit、live 未驗證（I2）。

## 第十一輪（Astra 第十輪審查：1【應修】1【建議】，主線全採納）

審查原文：主 repo `.swfd/logs/guard-gaps-review/astra-review10.md`。Deviations 48–51 主線採納。開工前 rebase 到 main `d95d5b1`（devLogSeal），無衝突。

| 條 | 內容 | 處理 |
|---|---|---|
| 應修 1 | `replace` 把 fetchCharacterInfo 換成 loginBeat 後，送 Swift 的編碼拋錯，`failSafe` 照送遊戲原 fetchCharacterInfo，但配對仍是派發時提交的 loginBeat，真 RESPONSE 派給 loginBeat 插件。main 上既有缺口 | `failSafe` 照送原 bytes 的三個出口（非大廳／FastTest／無守衛者的解析失敗、大廳非守衛方法、查找出錯的非守衛方法）都經 `sendOriginal` 依原請求重新提交配對；擋下的出口照舊由 `blockSend` 撤銷（`GG11-1` 有無頁面守衛兩情境與健康對照、`GG11-1b`、`GG11-1c`） |
| 建議 2 | Dev 49–51 的邊界與同號碰撞反例只有探針 | 固定回歸：`GG11-1b`（bridge_error 擋下、回呼內同號重送）、`GG11-2`（tainted_fallback 回呼內重送）、`GG11-3`（只換 grant 不重註冊、自動停用後重註冊 1–10 重新累計）、`GG11-4`（遊戲 INFO 64000 未答、插件注入 SKIN 同為 64000 被擋，INFO 的 RESPONSE 對不回 method）。§1.4 新增第 5 項、契約新增「沒有跨來源的配對隔離」 |

### 第十一輪 Deviations

52. **`failSafe` 照送時依原請求重新提交配對，不判斷派發是否改過。** `failSafe` 拿不到派發的中間狀態，一律以遊戲原 bytes 覆寫同鍵配對最簡單，也涵蓋「派發前就出錯、根本沒登記」的情況（修前這種情況沒有配對，修後有，與實際上 wire 的請求一致）。原 bytes 解析不出時沒有 msgId，什麼都不做；這時派發也不會跑鏈，不會留下改寫後的配對。
53. **`GG11-2` 以 Naki 流量觀察者驗證。** tainted_fallback 的注入號碼在 `sendRaw` 登記為 Naki 自送且未答，遊戲在回呼內以同號重送，依契約「REQUEST 本地結案例外」仍算 Naki，所以一般觀察者看不到它的 RESPONSE，只有宣告 `observeNakiTraffic` 的看得到。測試斷言配對保留（method 是重送的 inputOperation），不改歸屬規則。
54. **同號碰撞只固定現行行為、揭露，不修。** 主線指示固定反例並明載。修法（配對帶來源或交易代號）會改動 `naki-websocket.js` 的 `sendRaw` 號段與登記，超出本包可改清單。
55. **測試 harness 加 `encode` 選項。** `GG11-1c` 要讓守衛查找只在 `failSafe` 內拋錯，需要在編碼失敗那一刻才武裝；既有 `breakBase64` 是固定的拋錯函式，接不到時機。只改 b2 回歸腳本的 `page()`，預設不影響其他測試。

### 第十一輪驗證（log：主 repo `.swfd/logs/guard-gaps/r11-*`）

| 項目 | 結果 | log |
|---|---|---|
| rebase | 先 rebase 到 main `d95d5b1`，無衝突；rebase 後 b2 166／0 | |
| 新測試套在第十輪 HEAD `eead829`（rebase 後）的 JS | 2 紅：`GG11-1`、`GG11-1c`。`GG11-1` 兩個故障情境各自單跑：修前各 1 紅，修後各 0。`GG11-1b`、`GG11-2`、`GG11-3`、`GG11-4` 修前即綠，用來固定建議 2 的行為 | `r11-red-b2-on-eead829.log` |
| 變異（b2＋v2＋p4，扣基線） | 73／75 被殺。新增 Y1–Y4 全殺（Y3、Y4 初跑存活，補 `GG11-1c` 後被殺）；存活的 `T7`、`U10` 為既有等價變異 | `r11-mutation.log` |
| node 五套 | b2 172／0（0 略過）、v2 21／0、p4 24／0、plugin-regression 39／0、keepalive 11／0 | `r11-green-*.log` |
| naki-plugins `local-unlock-naki.cjs` | 9／0（`NAKI_ROOT` 指向本 worktree，0 略過） | `r11-green-local-unlock-naki.log` |
| `JSContractTests`＋`PluginSendGuardTests` | 19／0 | `r11-swift-targeted.log` |
| 全量 NakiTests（一次） | 1184／0 | `r11-test-full.log` |

### 第十一輪未驗證與風險

- 跨來源 msgId 碰撞沒有配對隔離（Deviation 54，§1.4 第 5 項）。
- bridge 故障只以 node 替身的編碼拋錯注入驗證；WebKit、live 未驗證（I2）。

## 第十二輪（Astra 第十一輪審查：1【應修】1【建議】，主線全採納）

審查原文：主 repo `.swfd/logs/guard-gaps-review/astra-review11.md`。Deviations 52–55 主線採納。main 仍是 `d95d5b1`，不需 rebase。

| 條 | 內容 | 處理 |
|---|---|---|
| 應修 1 | 第十一輪的 `failSafe` 配對入口直接寫表、不套 `PENDING_LIMIT`；零插件時 receive 提早返回，沒人消耗；`closed` 只清角色。零插件＋`breakBase64` 送收 300 筆後殘留 300，重連再跑 600 | 新增唯一寫入口 `remember`：套 `PENDING_LIMIT`（FIFO，同鍵先刪再寫算最新）；`registry` 與 `tainted` 都空時不登記，與 `dispatch` 的零插件提早返回同一條件。`pairWith`、`rememberIfRequest` 都經它。`closed` 清該連線前綴的配對。`diagnostics()` 加 `pendingPairs`（`GG12-1`） |
| 建議 2 | `plugin-v2-b2.md` 開頭仍稱接線未套用、§4.6 仍稱身分只看號碼 | 檔頭加歷史文件標記，指向 §1.4 與契約守衛段；§4.6 加「已被 D22 取代」註記，保留原文 |

### 第十二輪 Deviations

56. **採「零插件不登記」，不採「零插件也消耗」。** 主線給兩個選項。`dispatch` 在沒有插件也沒有污染時本來就提早返回、不跑鏈，送出也從不登記；讓 `failSafe` 守同一條件，零插件頁面的配對表永遠是空的，receive 路徑不必改。代價：送出時沒有插件、回應到達前才啟用的插件，這筆 RESPONSE 對不回 method，與修前 `dispatch` 的行為相同。
57. **同鍵重寫先刪再寫。** `Map.set` 覆寫不改插入順序，最新寫入的配對可能被當成最舊的淘汰。刪後再寫讓 FIFO 以最後一次寫入為準。修前 `rememberIfRequest` 沒這樣做，影響只在表滿時的淘汰順序。
58. **`diagnostics()` 新增 `pendingPairs`。** 測試要觀察表的大小，閉包外沒有其他讀法。只加一個唯讀數字欄位；Swift 端 `NakiRuntime.pluginDiagnostics` 把結果當字串收進 `PluginDiagnostics.report`，不解析欄位（已讀原始碼確認）。
59. **修前紅以「只補讀數」的舊 JS 跑。** 舊 JS 沒有 `pendingPairs`，直接跑只會因欄位不存在而紅。紅測目錄在 `190d97e` 的 JS 上只補那一行讀數、不改行為，紅在實際數量（零插件殘留 300），與 Astra 探針一致。

### 第十二輪驗證（log：主 repo `.swfd/logs/guard-gaps/r12-*`）

| 項目 | 結果 | log |
|---|---|---|
| 新測試套在第十一輪 HEAD `190d97e` 的 JS（只補 `pendingPairs` 讀數） | 1 紅：`GG12-1`，零插件送收 300 筆後殘留 300（預期 0） | `r12-red-b2-on-190d97e.log` |
| 變異（b2＋v2＋p4，扣基線） | 78／80 被殺。新增 Z1–Z5 全殺；存活的 `T7`、`U10` 為既有等價變異 | `r12-mutation.log` |
| node 五套 | b2 173／0（0 略過）、v2 21／0、p4 24／0、plugin-regression 39／0、keepalive 11／0 | `r12-green-*.log` |
| naki-plugins `local-unlock-naki.cjs` | 9／0（`NAKI_ROOT` 指向本 worktree，0 略過） | `r12-green-local-unlock-naki.log` |
| Swift | 主線指示純 JS 與文件不需重跑；本輪沒有改 Swift 檔，未重跑 | |
| `git diff main --check` | 無警告 | |

### 第十二輪未驗證與風險

- 送出時沒有插件、回應到達前才啟用插件，這筆 RESPONSE 對不回 method（Deviation 56，與修前相同）。
- WebKit、live 未驗證（I2）。

## 第十三輪（Astra 第十二輪審查：1【應修】1【建議】，主線全採納）

審查原文：主 repo `.swfd/logs/guard-gaps-review/astra-review12.md`。Deviations 56–59 主線採納。main 仍是 `d95d5b1`，不需 rebase。

| 條 | 內容 | 處理 |
|---|---|---|
| 應修 1 | 唯一插件把 INFO 改成 loginBeat、同一 `onSend` 停用自己：wire 是 loginBeat，但鏈尾 `remember` 因零插件早退，鏈首依原請求登記的 INFO 配對留著；回應前註冊的觀察者收到 INFO。`190d97e` 同一探針收到 loginBeat | `remember` 先刪同鍵舊配對，再判 `noConsumers()`：沒人消耗時只撤銷、不新增；有人消耗時以最終 wire 的 method 重寫（`GG13-1` 兩情境：唯一插件撤銷、仍有其他插件更正為 loginBeat） |
| 建議 2 | 零插件條件在 `remember` 與 `dispatch` 各寫一次 | 抽成 `noConsumers()` 兩處共用；`GG13-2` 鎖住「有污染、無註冊插件」仍算有人消耗 |

### 第十三輪 Deviations

60. **沒人消耗時撤銷，不更正。** 主線指示零插件且無污染時撤銷。`190d97e` 在這個探針上會更正成 loginBeat（觀察者收到 loginBeat），本輪則是撤銷（觀察者收不到）。撤銷後表不留沒人消耗的登記，第十二輪的容量回歸維持成立；代價與 Dev 56 相同：送出時沒人消耗、回應前才註冊的插件看不到這筆 RESPONSE，但不會看到錯的 method。
61. **`seen11` 測試 helper 改用遞增 id 並斷言註冊成功。** 原本以陣列位置當 id，同一頁面呼叫兩次會撞 id、第二次註冊靜默失敗；`GG13-1` 的「仍有其他插件」情境因此一度沒有 INFO 觀察者。改後所有用到它的測試照綠。
62. **修前對照以探針記錄觀察者收到的 method。** `GG13-1` 在 `190d97e` 上也紅，但只因為那版留了一筆更正後的配對（`pendingPairs` 1），方向與本輪不同。探針拿掉筆數斷言，三版的觀察者結果：`e18ce82` 收到 INFO（錯）、`190d97e` 收到 loginBeat、本輪收不到（撤銷）。

### 第十三輪驗證（log：主 repo `.swfd/logs/guard-gaps/r13-*`）

| 項目 | 結果 | log |
|---|---|---|
| 新測試套在第十二輪 HEAD `e18ce82` 的 JS | 1 紅：`GG13-1`（唯一插件情境殘留 1 筆配對）；探針顯示觀察者收到 INFO。`190d97e` 對照見 Dev 62 | `r13-red-b2-on-e18ce82.log` |
| 變異（b2＋v2＋p4，扣基線） | 83／85 被殺。新增 AA1–AA5 全殺（撤銷順序、`remember` 與 `dispatch` 各自改成只看 registry 或只看 tainted）；Z1 改成新字串仍被殺；存活的 `T7`、`U10` 為既有等價變異 | `r13-mutation.log` |
| node 五套 | b2 175／0（0 略過）、v2 21／0、p4 24／0、plugin-regression 39／0、keepalive 11／0 | `r13-green-*.log` |
| naki-plugins `local-unlock-naki.cjs` | 9／0（`NAKI_ROOT` 指向本 worktree，0 略過） | `r13-green-local-unlock-naki.log` |
| Swift | 本輪只改 JS 與文件，沒有改 Swift 檔，依主線指示未重跑 | |
| `git diff main --check` | 無警告 | |

### 第十三輪未驗證與風險

- 送出時沒人消耗（含唯一插件在鏈中停用自己）的請求，回應前才註冊的插件看不到它的 RESPONSE（Dev 60）。是否會看到錯的 method 見第十四輪。
- WebKit、live 未驗證（I2）。

## 第十四輪（Astra 第十三輪審查：1【應修】，主線採納）

審查原文：主 repo `.swfd/logs/guard-gaps-review/astra-review13.md`。Deviations 60–62 主線採納。main 仍是 `d95d5b1`，不需 rebase。

| 條 | 內容 | 處理 |
|---|---|---|
| 應修 1 | 送 INFO → 停用唯一插件 → INFO 回應交遊戲（配對沒清）→ 同連線重用 msgId 送 loginBeat → 註冊觀察者 → 回應派成 INFO。收、送都在 `dispatch` 的零消耗者早退處跳過配對，`remember` 的撤銷到不了。`190d97e`、`e18ce82` 已存在 | `dispatch` 在 `noConsumers()` 早退前，表內有配對時解析一次：RESPONSE 刪同鍵配對，REQUEST 也刪同鍵舊配對（與 `remember` 沒人消耗時的撤銷一致）。契約、§1.4、第十三輪 notes 的「不會看到錯的 method」改成有條件敘述（`GG14-1` 三情境） |

### 第十四輪 Deviations

63. **零消耗者的送出也撤銷同鍵舊配對。** 主線點名的是 RESPONSE 消耗。實測舊配對未答時（INFO 沒有回應就重用 msgId），只清 RESPONSE 不夠，觀察者仍收到 INFO；所以送出方向也比照 `remember`，同鍵新請求撤銷舊配對。`GG14-1` 的「INFO 未答」情境鎖住這條，變異 BB2 由它殺掉。
64. **只在表內有配對時才解析。** 零插件頁面的表一直是空的（第十二輪），所以平常不多解析；只有插件剛停用、表內還有殘留時才解析一次。
65. **「不會派成錯的 method」的保證範圍。** 同一來源依序重用 msgId 時成立：RESPONSE 只會派成最後送出那筆的 method，或對不回（送出時沒人消耗）。例外有兩種：跨來源同號碰撞可能派錯或對不回（§1.4 第 5 項）；表滿淘汰只會移除配對，被淘汰那筆的 RESPONSE 對不回 method，不會派錯。主線列的「容量淘汰」殘餘因此寫成「對不回」，不寫成「派錯」。

### 第十四輪驗證（log：主 repo `.swfd/logs/guard-gaps/r14-*`）

| 項目 | 結果 | log |
|---|---|---|
| 新測試套在第十三輪 HEAD `127b058` 的 JS | 1 紅：`GG14-1`。逐情境探針：INFO 已答／未答且觀察者在重用後註冊時，修前收到 INFO、修後收不到；觀察者在重用前註冊時兩版都收到 loginBeat | `r14-red-b2-on-127b058.log` |
| 變異（b2＋v2＋p4，扣基線） | 87／89 被殺。新增 BB1–BB4 全殺（RESPONSE 不消耗、送出不撤銷、完全不碰、方向對調）；AA4、AA5 改成新字串仍被殺；存活的 `T7`、`U10` 為既有等價變異 | `r14-mutation.log` |
| node 五套 | b2 176／0（0 略過）、v2 21／0、p4 24／0、plugin-regression 39／0、keepalive 11／0 | `r14-green-*.log` |
| naki-plugins `local-unlock-naki.cjs` | 9／0（`NAKI_ROOT` 指向本 worktree，0 略過） | `r14-green-local-unlock-naki.log` |
| Swift | 本輪只改 JS 與文件，沒有改 Swift 檔，依主線指示未重跑 | |
| `git diff main --check` | 無警告 | |

### 第十四輪未驗證與風險

- 跨來源同號碰撞可能派錯或對不回；表滿淘汰的配對對不回 method（Dev 65）。
- WebKit、live 未驗證（I2）。
