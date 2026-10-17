# v2.20.0 已知限制 live 驗證（2026-10-17）

宿主是執行中的 `/Applications/Naki.app` 2.20.0（8765），測試帳號。證據都在主 repo `.swfd/logs/known-limits-live/`（下稱 `kl/`）。每段 `<段>.json` 是觀察器紀錄（`attempt`＝遊戲呼叫 `ws.send`，`wire`＝實際上線），`<段>.png` 是同時的截圖。觀察器沿用 unlock-v1 第二輪的 `observer.js`，每次重啟或重載後在 gateway 建立前裝上（每段 `conns` 的第一筆是登入的 `/gateway`）。

## 逐條結果

| # | 原文（摘） | 現況 | 證據 |
|---|---|---|---|
| 1 | 守衛「真的擋下請求」沒有 live 驗證 | **已驗證** | `kl/A10`、`A12`、`B1`、`B4`、`B6`、`B8`、`C2`、`C4`、`C5-guard-state-final.json`、`B8-resrec.json`、`C6-after-reload.json` |
| 2 | 守衛不涵蓋 `sendRaw` 退回、就地改寫、第一筆 Blob | **修正中**：`feat/guard-gaps`（`d90b8a7` 起）未合併；本包未 live 驗 | 分支 log |
| 3 | 整包替換改寫顯示值後畫面是否跟著變 | **部分驗證**：等長改寫顯示值畫面會變（unlock-v1 §12）；長度不等的整包替換仍未驗 | `naki-plugins/docs/local-unlock-v1.md` §12、本包 `kl/A5-profile-taint.png` |
| 4 | `injectReceive` 與 `respondLocally` 尚未實作 | **未實作**（原始碼只有註解提到） | `naki-plugins.js`、`naki-websocket.js` grep |
| 5a | 對局結束誤報只有離線測試 | **已驗證** | `kl/E1-*`、`E2-*`、`E3-*`、`E4-*` |
| 5b | 連線失敗清理只有離線測試 | **live 驗證失敗：修正無效**（根因已找到，未修） | `kl/D1`–`D3-wsfail-run*.json`、`D4-readystate-probe.json`、`D5`–`D7-forcereconnect-run*.json` |

## 1. 守衛實擋

臨時插件 `naki-plugin-tmp-guard-live`（副本 `kl/tmp-guard-plugin-copy/`）的 manifest 宣告 `observe`＋`rewriteReceive`，`sendGuard` 是全部 19 個 `GUARDABLE_METHODS`。`onSend` 一律放行。`onReceive` 對遊戲自己請求的 `fetchAccountStatisticInfo`／`fetchCommentList` 回應，把一個 varint 的 bit0 翻轉（個人資料統計數字差 1，只影響本機顯示）。手放插件後重啟 App rescan，用插件頁 AXPress 啟用；打開個人資料頁觸發改寫後 `guardState().tainted` 含 19 個方法（`kl/A5-taint-state.json`）。

「使用」對已裝備角色時遊戲不送任何請求（`kl/A8`：只有 heartbeat）。所以改用宿舍兩個**已擁有**角色：選取後再點一次卡片＝送 `changeMainCharacter`。當時伺服器主角色是 200002（二階堂，`kl/A4-lobby.json` 的 fetchInfo）。

| 情境 | 次數 | 結果 |
|---|---|---|
| (i) L3 關、守衛者在鏈上且放行 | 4（200001 三次、200002 一次） | 每次 `attempt 1／wire 0`；`guardState().log` 為 `local_error／outbound_disabled`；遊戲收到本地錯誤回應（`received` raw 0、game 1）；插件日誌「守衛擋下 … 改回本地錯誤」 |
| (ii) L3 開（插件頁「權限」分頁開關＋確認）、守衛者放行 | 2（都送 200002＝伺服器現值） | `attempt 1／wire 1`；log `sent`；伺服器回應 `0344000a001200`（payload 空＝無 error，`kl/B8-resrec.json`） |
| (iii) 插件頁停用插件後（L3 關） | 2（200001、200002） | `attempt 1／wire 0`；log `local_error／not_on_chain`；沒有伺服器回應 |

擋下的理由是 `outbound_disabled`，不是 `not_approved`：插件在鏈上且放行，但已污染者放行另外要求 L3 開（`guardFailure`）。重載後 `fetchInfo` 主角色仍是 200002（`kl/C6-after-reload.json`），污染隨重載清空。

觀察到的副作用與問題：

- **遊戲畫面先樂觀更新**：被擋下時宿舍立刻顯示被點角色「使用中」（`kl/A10-click-other-again.png`），但伺服器沒變。重載後畫面回到伺服器值。
- **Swift log 措辭誤導**：被擋下的請求，Swift 端仍記「Sent request: .lq.Lobby.changeMainCharacter」（`kl/A10-naki-logs.txt`）。要以 `guardState().log` 或插件日誌判斷。
- 帳號開著「隨機主角色」（`fetchInfo` 的 `random_character.enabled=1`，池內兩個角色都在）。伺服器每次登入可能換主角色：`kl/F1-reload-check.json` 讀到 200001，之後重連畫面又是二階堂。這不是本包請求造成的；本包送上線的只有兩筆 200002。

## 3. 改寫顯示值

unlock-v1 第二輪（`naki-plugins/docs/local-unlock-v1.md` §12）：`fetchAccountInfo` 的 `avatar_id` 400201→400101 改寫後，大廳立繪與個人資料立繪跟著變。那次是**等長**改寫（`reshape.attempted=0`）。本包 `kl/A5-profile-taint.png` 也是等長改寫後的個人資料頁。原文說的「整包替換」（長度不等）改寫顯示值，仍未 live 驗證。

## 5a. 對局結束誤報

修正（`fd74f63`）：`ResAuthGame` 只帶 error 時記「伺服器拒絕 authGame，code N」，不掛 blocking fault。舊行為是「authGame 回應中找不到 seatList」＋blocking fault，畫面顯示「…持續出現代表雀魂改了協定欄位」。

| 局 | 流程 | 結果 |
|---|---|---|
| E1 | 四人東自動打完（南 2 局結束）→ 點「確認」回房 → `bot_sync` | 對局中、結算、回房都無 blocking fault、無橫幅；回房後重連沒有重送 authGame |
| E2 | 四人東自動打完 → 結算畫面上立即 `bot_sync` | 客戶端重送 authGame，伺服器沒回 ResAuthGame 就關 game-gateway（`kl/E2-10-post-end-all.txt`）；無 fault、無橫幅 |
| E3、E4 | 投票結束 → `room_leave` → `bot_sync`（unlock-v1 §12 的觸發法） | authGame 回應只有 `error`，log「伺服器拒絕 authGame，code 1202」；`liqiParseBlocked=false`；遊戲顯示自己的「之前的對局已結束（1202）」對話框，Naki 無橫幅（`kl/E3-9-lines.txt`、`E4-9-lines.txt`、`E4-8-after-sync.png`） |

四局 `liqiParseFaultTotal` 都是 1，來源是 `ActionPrototype.ActionMJStart`（degraded，未處理的開局動作），與這條修正無關，不觸發橫幅。

## 5b. 連線失敗清理

修正（`058b9a7`）只在 `error` 事件當下 `readyState === CLOSED` 時清理。live 結果：

- 頁面內 `new WebSocket('ws://127.0.0.1:47231/gateway')` 三次，每次只有 `error`、沒有 `close`。2 秒後 `getConnections()` 仍留著該筆 readyState 3，三次累積 3 筆（`kl/D1`–`D3`）。
- 根因（`kl/D4-readystate-probe.json`）：WebKit 派發 `error` 時 readyState 仍是 **0**，同一 macrotask 的 microtask 也是 0，下一個 `setTimeout(0)` 才變 3。修正的條件永遠不成立。
- `forceReconnect` 三次（關閉路徑，`kl/D5`–`D7`）：舊連線與 `guardState().roles` 都清掉，新連線 OPEN。這條路徑本來就正常。
- 頁面重載會清掉殘留（`kl/E2-0` 後 `getConnections()` 只剩兩條 OPEN）。

建議修法（未實作，交主線裁決）：`error` 時改成「不是 OPEN 就延後一個 tick 再檢查 CLOSED 後清理」，或 `error` 一律 `release()`（失敗連線不會再 OPEN）。測試要用真的 WebKit 時序，現有 `plugin-regression.cjs` 案 (a) 假設 error 當下已是 CLOSED，所以沒抓到。

## 環境與收尾

- 開始前備份 `kl/plist-before.plist`；結束後與 plist diff 為空（`kl/Z2-prefs-diff.txt` 0 行）。L3 結束為 false，`enabledIds` 只有原本兩個。
- 插件目錄回到三個（`kl/00-plugins-dir-before.txt` 與 `Z1-plugins-dir-after.txt` 相同）。臨時插件已刪，刪後重啟 App rescan。
- 途中兩次遇到其他代理的 `xcodebuild test`（test host 是第二個 App 實例），都等它結束才繼續。
- 本 session 的檔案 log 在 19:14 後停止增長（`~/Library/Logs/Naki/20261017-191436/`），之後的證據取自 `/logs` 記憶體 log（環形緩衝，最早只回溯到 11:39Z）。原因未查。

## Deviations

- 原計畫 (i) 是對「目前裝備中」的角色再點「使用」。實測遊戲對已裝備角色不送請求，改用兩個已擁有角色互換（CLAUDE.md 例外允許）。被擋下的 200001 從未上線；上線的兩筆都是當時的伺服器現值 200002。
- 污染用的大廳回應改成 `fetchAccountStatisticInfo`／`fetchCommentList`：遊戲在大廳不自己送 `fetchServerTime`，個人資料頁也不送 `fetchAccountInfo`。
- 第 5a 條多做兩局（E3、E4）：前兩局的自然流程都沒有走到「伺服器回 error」的修正路徑。
- E2 第一次嘗試時 `room_create` 回 `no_open_majsoul_connection`，腳本仍連送三次 `bot_sync`，遊戲出現「伺服器繁忙」。重載頁面後重做，該次證據移到 `kl/E2-aborted/`，腳本已改為建房失敗即停。
