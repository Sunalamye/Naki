# H1 雀魂連線 User-Agent／header 實作筆記

## 範圍
- 設定：`majsoulUserAgent`（空＝WebKit 預設）、`majsoulExtraHeaders`（`[String: String]`，UserDefaults key `MajsoulUserAgent`／`MajsoulExtraHeaders`）。
- `MajsoulRequestBuilder`：`request(url:extraHeaders:)`、`issue(name:value:)`、`userAgent(_:)`。
- Backend `load` 改吃 `URLRequest`，新增 `customUserAgent`；`WebSession` 每次載入前同步 UA。
- 設定頁 `MajsoulConnectionSettingsBox`；動作 `ConnectionSettingsAction`（apply／defaultUserAgent）。

## 查證
- `WebPage` 有 `customUserAgent`（可讀寫）與 `load(_ request: URLRequest)`（Xcode 27 SDK 的 WebKit.swiftinterface）。
- loopback 測試：WebPage 與 WKWebView 的主文件請求都帶出自訂 header 與 UA。
- 限制：自訂 header 只在主文件請求；子資源與 WebSocket 握手不帶；UA 套用到全部請求。

## Deviations
- 保留名稱除指定的 Host／Content-Length／Cookie 外，另擋 Apple 文件列的 Authorization、Connection、Proxy-*、WWW-Authenticate，加 Transfer-Encoding、Upgrade、User-Agent（UA 有專用欄位）。理由：保守，避免被 URL 載入系統靜默忽略。
- header 值為空白視為非法而非送出空值。
- `URLRequest.allHTTPHeaderFields` 會把名稱正規化大小寫；設定存的是原樣，實際請求的大小寫由 WebKit 決定。
- 預設 UA 讀自用完即丟的 `WKWebView`，不是 `WebPage` 本身；兩者是否一致未驗證。
- `WebSession.load(_ server:)` 的設定到請求這段沒有單測（載入目標是真實雀魂網址）；純函式部分已測。
- 新檔案要加進 `project.pbxproj` 兩份 `command` 資料夾成員清單（Naki／Naki-M），否則不會被編譯。
