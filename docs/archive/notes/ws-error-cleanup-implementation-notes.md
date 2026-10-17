# ws-error-cleanup implementation notes

## 問題
遊戲頁內 `new WebSocket('ws://127.0.0.1:…')` 被 WebKit 拒絕時只觸發 `error`、readyState 直接為 3，沒有 `close`。清理只掛在 `close`，`getConnections()` 殘留 readyState 3 的項目（live：`.swfd/logs/pv2-b2-live/c-03-probe-open-localhost.json`）。

## 做法
`naki-websocket.js` 抽出每條連線一份的 `release()`（刪連線表、通知插件 `closed(wsId)`，旗標保證只一次）。`close` 與「`error` 且 `readyState === CLOSED`」都呼叫它。派發、改寫、交付、送往 Swift 的事件不變。

## 驗證
- `plugin-regression.cjs` 新增 2 案；還原 JS 後案 (a) 紅（`not ok 37`），案 (b) 在舊碼本就綠（防回歸用），還原後 38/38 綠。
- `plugin-v2-b2-regression.cjs` 68、`plugin-v2-regression.cjs` 21 全綠。
- `NakiWebSocketScriptTests` 與 `JSContractTests` 共 18 測試 0 失敗。
- 未驗證：live 實機（未碰執行中的 Naki）。

## Deviations
無。

## 第二輪（2026-10-17 live 後修正，commit 5c41a4f）
live 證實上面「error 且 readyState === CLOSED」條件不成立：WebKit 觸發 error 回呼時 readyState 仍是 0，下個 tick 才變 3（頁內失敗連線 3 次殘留 3 筆）。離線替身在 error 時就把 readyState 設 3，所以假綠。

- 做法：選 (b)，`error` 一律 `release()`；之後的 `close` 仍照送 `websocket_close` 給 Swift，但靠 `released` 旗標不重複清理、不重複通知插件。不選 (a)（setTimeout 後再查），因為多一個計時器、且仍依賴 readyState 的時序。
- 替身改 WebKit 時序（error 時 readyState=0，之後才 3 並 close）。舊 JS 上新案 `not ok 37` 紅，修後 80/21/24/39 全綠（b2/v2/p4/plugin-regression）。另加「error 後 close 也到」冪等案。
- log 措辭：Swift `WebSocketInterceptor` 對帶 `localResponse` 的 send 記「Blocked request: <method> (<reason>)」，其餘仍「Sent request」。JS `respondLocal` 在該則訊息多帶 `reason`（只加一欄，不動 guard 邏輯）。
- 變異 6/6 殺：error 不 release、去掉冪等旗標、退回 readyState 條件、close 不 release、reason 不送（JS，log `mutations.log`）；Swift 條件改 `if false`（`PluginSendGuardTests` 新案紅）。
- `PluginSendGuardTests`＋`JSContractTests` 19 測試 0 失敗。
- 未驗證：live 實機（未碰執行中的 Naki）。

## Deviations
Swift 端新增的 log 測試靠 `LogManager` 以 main.async 寫入，測試用 200ms sleep 等待，屬 conservative 選擇而非重構 log 路徑。
