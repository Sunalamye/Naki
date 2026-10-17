# WP3 雲端錯誤提示 implementation notes

## 做法
- `CloudAPIError.errorDescription` 的 `.http` 分支只陳述可觀察狀態：
  - 401／403：「伺服器拒絕這把 key（HTTP <code>）」
  - 429：「伺服器限流（HTTP 429）」，有 retryAfter 接「，<n> 秒後再試」
  - 其他 code：維持「HTTP <code> — <message><hint>」；message 以 `<` 開頭或含 `<!DOCTYPE` 時顯示「（HTML 錯誤頁）」
- 不歸因：不提 key 多處使用、不提 key 外洩（403 + text/html 無法確認來源，429 也可能是配額）。

## 預設服務補充句放哪
- `CloudAPIError.http` 多一個 `isDefaultServer: Bool`，`AkagiApiClient.init` 以 normalize 後的 base 與 `SettingsStore.defaultCloudBaseURL` 比對（不分大小寫），`send` 拋錯時填入。
- 理由：`CloudAPIError` 與 client 是唯一同時知道錯誤與 base URL 的地方；不必碰 `NakiActions`／View，也不必在每個呼叫端重複判斷。
- 連帶改動：`CloudBot.swift` 的 `catch CloudAPIError.http(429, _, let retryAfter)` 補一個 `_`，邏輯不變。

## Deviations
- 四語：提示維持純 Swift 中文字串，不走 xcstrings，沿用 `errorDescription` 既有做法。
- 補充句只在 401／403／429 出現；其他 code 不附。
- `CloudBot.swift` 因 enum 多一個 associated value 而必須改一個 pattern，已限縮在該行。
- 既有測試 `test_httpError_surfacesServerMessage_andRetryAfter`、`test_httpError_redactsKeyEchoedBackByServer` 要求 429／401 文字仍含伺服器訊息（已遮 key）。保守選項：401／403／429 在固定前綴後以「：<message>」保留伺服器訊息；message 為空則省略，HTML 則換成「（HTML 錯誤頁）」。
