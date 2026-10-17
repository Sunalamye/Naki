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
