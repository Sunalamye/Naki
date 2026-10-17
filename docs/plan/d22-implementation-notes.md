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

第二輪（回應 Astra 7 條，逐條見 `d22-review-response.md`）：

- **D8 注入登記還在的 RESPONSE 一律算 Naki。** 兩份登記壽命不同：`sendRaw` 登記由 Naki 與插件共用 256 筆，注入登記只計插件注入。所以以注入登記判斷。
- **D9 JS 登記加 `answered`。** RESPONSE 到達後，同線同號的 REQUEST 改判為遊戲自己的。同號 RESPONSE 仍算 Naki，否則第二個同號回應會被交給可改寫的一般鏈。標記放在 `handleMessage` 收訊記帳處，與 `lastRecvAt` 同一行，所以沒有插件也會標記。
- **D10 `isNakiSent` 加第三個選填參數 `pendingOnly`。** REQUEST 判斷（守衛、send 方向的鏈、`attributeSend`）帶真，RESPONSE 判斷不帶。
- **D11 Swift 綁定前窗口只在文件中限定範圍，不加嚴。** 加嚴的唯一做法是讓 `claim` 拒絕未綁定的登記，但那會讓先到的真回應遺失。Swift 端不知道「配號時的候選連線」。
- **D12 socketId 以實作為準。** JS 每個 frame 以隨機起點遞增配發，同頁不重用，重載後起點重抽。不建 session 身分。

第三輪（回應 Astra 第二輪 4 條）：

- **D13 Blob RESPONSE 在異步展開完成處補標記 `answered`。** 收訊記帳處讀不到 Blob。RESPONSE 判斷不讀 `answered`，所以標記早於或晚於插件派發都不影響這則回應本身。
- **D14 本地結案不標記 `answered`。** 被擋下的也可能是被誤認的遊戲請求，此時真正的 Naki 請求仍在路上。只標記「Naki 自己那筆」需要在 `sendRaw` 與 `respondLocal` 之間傳旗標，換到的只是少擋一些同線同號的遊戲請求。所以維持較嚴的一側，在設計與 API 列為例外。
- **D15 同線同號的 RESPONSE 持續誤認與注入錯認領只在文件中限定。** 兩者在 main 就存在。注入錯認領之後，真回應的方法已對不回，不會交給任何插件，所以沒有新的改寫機會。

第四輪（回應 Astra 第三輪 2 條）：

- **D16 登記帶遞增序號 `seq`，RESPONSE 只標記它抵達前就存在的登記。** Blob 在 listener 收到時先記下當下序號，展開後才比對。選序號而不是保留登記物件，是因為 Blob 展開前還不知道 msgId，抓不到是哪個物件。
- **D17 殘留的終止條件以實作為準。** 重送會重新進入待答，但不解除配對身分；只有淘汰會移除登記。
- **D18 序號是 Number，上限 2^53，到頂後不再遞增。** 每秒千筆也要約 28 萬年才會到頂，所以不加歸零或 epoch。


## Deviations

- **Swift 保留插件號段排除。** 派工要求把號段問題處理掉，但 Swift 沒有插件登記可查，要知道插件送了什麼得新增 bridge 訊息，超出可改範圍。保守選項是維持排除，寧可少學也不學錯。已記入設計 §8 風險。
- **契約與專案文件第一輪未改，第二輪已改。** 下列三處描述的是舊語意，第一輪不在可改清單內：
  - `docs/plugin-api-v1.md` 第 108、206 行：「登記表 ∪ 插件號段」，以及 `isNakiSent(msgId)`。
  - `CLAUDE.md` 第 108、146–149 行。
  - `AUDIT.md` 第 163 行。
- **改了既有測試的期望。** 下列兩個既有案例斷言的正是 D22 要改的語意，所以改寫：
  - `plugin-regression.cjs` 的 D9 plugin send：未登記的 64001 原本期望 `isNaki=true`。
  - `plugin-v2-regression.cjs` 的 plugin-range 案例：原本以頁面直接送 64002 來代表插件注入，現改為經 `sendRaw` 送出，另外斷言遊戲送的 64003 可被 rewrite。
- **第二輪碰了 `handleMessage` 的收訊記帳行。** 原則是「不改接收鏈」。D9 的標記要在每則 RESPONSE 上執行，最保守的位置是既有的 `lastRecvAt` 記帳，因為它與派發順序、改寫、交付都無關。沒有放進插件派發，因為沒有插件時派發會提前返回。
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

## 第二輪測試與變異

| 項目 | 結果 | log |
|---|---|---|
| node `plugin-regression.cjs <plugins>` | 33 pass、0 fail | `round2-plugin-regression.log` |
| node `plugin-v2-b2-regression.cjs` | 63 pass、0 fail | `round2-b2.log` |
| node `plugin-v2-regression.cjs` | 21 pass、0 fail | `round2-v2.log` |
| 全量 NakiTests | 1165 tests、0 failures | `round2-full-nakitests.log` |

紅燈證據：
- 對 ee3c167 的 JS，新的行為案例有 3 個紅：注入回應、同線碰撞（plugin-regression 與 b2 各一）。見 `round2-red-*.log`。
- 鏡像目錄沒有 Swift 原始檔，因此 plugin-regression 第 13、14 案例也紅，與本案無關。
- 重載案例、v2 補強、Swift 順序與號段案例鎖的是既有事實，以變異證明有效。

| 變異 | 抓到的測試 |
|---|---|
| R1 注入回應不再算 Naki | plugin-regression 31 |
| R2 RESPONSE 不標記已答 | plugin-regression 32、b2 63 |
| R3 忽略 `pendingOnly` | plugin-regression 32、b2 63 |
| R4 登記容量改 512 | plugin-regression 29、31 |
| R5 socketId 起點固定為 0 | plugin-regression 33 |
| R6 重連重用同一個 socketId | plugin-regression 30、33，以及 b2 多案 |
| R7 JS 加回插件號段 | plugin-regression 28、b2 61、v2 10 |
| R8 未綁定登記不再任一連線都認 | `testTrueResponseBeforeBindIsClaimed`、`testAmbiguousFailureKeepsAnUnboundRegistration` 等 6 個 |
| R9 Swift 拿掉插件號段 | `testGameStartUnifiedMatchInPluginRangeIsTreatedAsNaki`、`testIsNakiSentFollowsRegistryNotMsgIdRange` |
| R10 學習時不看連線 | `testGameStartUnifiedMatchOnAnotherSocketIsLearnedDespiteSameMsgId`、`testIsNakiSentRespectsTheBoundSocket` |
| R11 `js_error` 也撤銷登記 | `testAmbiguousFailureKeepsAnUnboundRegistration` |

每個變異的 log 是 `round2-mut-*.log`。

第二輪仍未驗證：
- live。
- WebKit 中 `sendRaw` 結果與 RESPONSE 抵達 Swift 的實際先後順序。
- 跨頁 socketId 撞號的實際機率。

## 第三輪測試與變異

| 項目 | 結果 | log |
|---|---|---|
| node `plugin-regression.cjs <plugins>` | 36 pass、0 fail | `round3-plugin-regression.log` |
| node `plugin-v2-b2-regression.cjs` | 66 pass、0 fail | `round3-b2.log` |
| node `plugin-v2-regression.cjs` | 21 pass、0 fail | `round3-v2.log` |
| 全量 NakiTests | 1165 tests、0 failures（Swift 本輪未改） | `round3-full-nakitests.log` |

紅燈證據：
- Blob 案例對 84b1f7f 是紅的（`round3-red-b2.log`）。
- 其餘 4 個新案例鎖的是既有行為與殘留，以變異證明有效。

| 變異 | 抓到的測試 |
|---|---|
| T1 同配對重送保留舊 `answered`（Astra 漏網變異之一） | plugin-regression 34 |
| T2 收到回應時標記所有連線的同號（Astra 漏網變異之二） | plugin-regression 35、b2 66 |
| T3 Blob 不標記 | b2 64 |
| T4 本地結案也標記 `answered` | b2 65 |
| T5 注入回應不消耗注入登記 | plugin-regression 36 |

每個變異的 log 是 `round3-mut-*.log`。

## 第四輪測試與變異

| 項目 | 結果 | log |
|---|---|---|
| node `plugin-regression.cjs <plugins>` | 36 pass、0 fail | `round4-plugin-regression.log` |
| node `plugin-v2-b2-regression.cjs` | 68 pass、0 fail | `round4-b2.log` |
| node `plugin-v2-regression.cjs` | 21 pass、0 fail | `round4-v2.log` |
| 全量 NakiTests | 1165 tests、0 failures（Swift 未改） | `round4-full-nakitests.log` |

紅燈證據：Blob 展開期間重送的案例（b2 第 67 案例）對 701d42e 是紅的，見 `round4-red-b2.log`。

| 變異 | 抓到的測試 |
|---|---|
| U1 拿掉序號比對 | b2 67 |
| U2 Blob 在展開後才取序號 | b2 67 |
| U4 本地結案標記已答 | b2 65、68 |

U3 是建構錯誤的等價變異：改動後的條件在測試路徑上恆為 false，等於沒改，所以丟棄，log 也已刪除。

