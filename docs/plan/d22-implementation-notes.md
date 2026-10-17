# D22 implementation notes

設計：`docs/plan/d22-naki-identity.md`。分支 `d22-naki-identity`，基準 main `f720dc1`。log 在主 repo 的 `.swfd/logs/d22/`。

## 決策

- **D1 選方案 A。** 方案 B 修不到大廳守衛誤擋，因為 Naki 自送和守衛都在大廳。
- **D2 JS 拿掉「插件號段即 Naki」。** 插件 `sendRequest` 經 `sendRaw` 送出，本來就在 (連線, msgId) 登記表內。號段只會多認出遊戲自己的 msgId。
- **D3 JS 登記移到「選定連線之後、`ws.send` 之前」。** 兩條送出路徑（proven、recency）合成一段，登記、送出、回傳都只寫一次。
- **D4 `isNakiSent(msgId, socketId)` 的連線是選填。** 不給連線時回答「任一連線」，因為 `plugin-api-v1.md` 已公開單參數形式。內部呼叫一律帶連線。
- **D5 Swift 登記「先登記、後綁定」。** 未綁定或查詢不帶連線時不看連線，保證任何時刻都不比 D22 前鬆。
- **D6 連線經 `LiqiRawSendResult.socketId` 傳回。** 不解析 `detail` 字串，`detail` 格式維持原樣供 log 使用。新欄位有預設值，既有呼叫端不用改。
- **D7 RESPONSE 解析結果加 `socketId` 鍵。** `MajsoulBridge.swift` 不在可改範圍，`capture(parsed)` 的簽名因此不動，改由 `capture` 從解析結果讀連線。只在 RESPONSE 加這個鍵。

## Deviations

- **Swift 保留插件號段排除。** 派工要求把號段問題處理掉，但 Swift 沒有插件登記可查，要知道插件送了什麼得新增 bridge 訊息，超出可改範圍。保守選項是維持排除，寧可少學也不學錯。已記入設計 §8 風險。
- **契約與專案文件未改。** 下列三處描述的是舊語意，但不在可改清單內，留給主線同步：
  - `docs/plugin-api-v1.md` 第 108、206 行：「登記表 ∪ 插件號段」，以及 `isNakiSent(msgId)`。
  - `CLAUDE.md` 第 108、146–149 行。
  - `AUDIT.md` 第 163 行。
- **改了既有測試的期望。** 下列兩個既有案例斷言的正是 D22 要改的語意，所以改寫：
  - `plugin-regression.cjs` 的 D9 plugin send：未登記的 64001 原本期望 `isNaki=true`。
  - `plugin-v2-regression.cjs` 的 plugin-range 案例：原本以頁面直接送 64002 來代表插件注入，現改為經 `sendRaw` 送出，另外斷言遊戲送的 64003 可被 rewrite。
- **`JSContractTests` 不在可改清單內。** 但派工的可改範圍包含「對應測試」，而 `isNakiSent` 的簽名變了，所以補了帶連線的斷言，原本的單參數斷言保留。

## 測試

| 項目 | 結果 | log |
|---|---|---|
| node `plugin-regression.cjs <plugins>` | 30 pass、0 fail | `final-plugin-regression.log` |
| node `plugin-v2-b2-regression.cjs` | 62 pass、0 fail | `final-plugin-v2-b2-regression.cjs.log` |
| node `plugin-v2-regression.cjs` | 21 pass、0 fail | `final-plugin-v2-regression.cjs.log` |
| 全量 NakiTests | 1161 tests、0 failures | `full-nakitests.log` |

紅燈證據：
- JS 新案例在實作前 4 個紅（`red-plugin-regression.log`、`red-b2.log`）。
- 改寫後的 v2 案例對 main 的 JS 是紅的（`red-plugin-v2.log`）。
- Swift 新案例對「API 存在但忽略連線」的退化版共有 12 個斷言失敗（`red-swift.log`）。

新增案例：
- JS 4 個：D22 per connection、號段內遊戲請求正常守衛、對局連線的 Naki msgId 不影響大廳同號、注入流量仍是 Naki 而號段本身不是。
- Swift 7 個：綁定比對、capture 只認綁定連線、`isNakiSent` 帶連線、sender 綁定、RESPONSE 帶 socketId、`sendResult` 解出 socketId、別條連線的 `startUnifiedMatch` 照學。
- 另在 `JSContractTests` 既有案例內補了帶連線的斷言。

## 變異（12 個，全數被抓）

| 變異 | 抓到的測試 |
|---|---|
| M1 JS 加回插件號段 | plugin-regression 28、b2 61、v2 10 |
| M2 JS 登記表忽略連線 | plugin-regression 30、b2 62 |
| M3 JS 送出後才登記 | plugin-regression 26/28/30、b2 21/23/31、v2 9/10 |
| M4 守衛不帶連線 | b2 62 |
| M5 `attributeSend` 不帶連線 | plugin-regression 30 |
| M6 `runChain` 的 isNaki 不帶連線 | plugin-regression 30、b2 62 |
| S1 配發器忽略綁定的連線 | 5 個 Swift 測試 |
| S2 sender 不綁定 | `testSenderBindsTheReportedSocket` |
| S3 capture 不帶連線 | `testCaptureClaimsOnlyOnTheBoundSocket` |
| S4 `isNakiSent` 不帶連線 | 學習測試、`testIsNakiSentRespectsTheBoundSocket` |
| S5 `sendResult` 不解 socketId | `testSendResultCarriesSocketId`、`JSContractTests` |
| S6 RESPONSE 不帶 socketId 鍵 | `testParsedResponseCarriesSocketId` |

每個變異的 log 是 `mut-*.log`。

## 未驗證

- live：沒有在真實雀魂連線上驗證。
- Swift 綁定前窗口的實際長度。
- 頁面重載後 socketId 重用的實際情況。
