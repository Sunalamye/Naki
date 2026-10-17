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
