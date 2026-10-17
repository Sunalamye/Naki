# D22：Naki 自送身分加上連線

**狀態**：方案 A 已有 spike（分支 `d22-naki-identity`，基準 main `f720dc1`），未合併。
**來源**：`plugin-v2-b2.md` §4.6；`plugin-v2-b2-review-response.md` 第三輪第 4 條；Astra 原文 `.swfd/logs/pv2-b2-review/astra-review3.md` 第 4 條。

## 1. 目標

「這筆是不是 Naki（含插件）送的」改以 **(連線, msgId)** 判斷，不再只看號碼。
遊戲的 msgId 跑進 60000–65500 時，不得再被誤認成 Naki。

## 2. 現況（main `f720dc1`）

live 事實（`.swfd/logs/unlock-handshake-20261017/README.md`）：遊戲 msgId 計數器全域遞增、跨連線共用。Naki 自送用 60000–63999，插件用 64000–65500。

| 位置 | 判斷 | 誤判後果 |
|---|---|---|
| JS `naki-plugins.js` `isNakiMsgId` | 插件號段，或 `sendRaw` 最近 256 筆 msgId | 遊戲 msgId 進 64000–65500 後，該段約 1500 筆大廳守衛方法全被 `naki_traffic` 擋（本地錯誤 code 6）；插件一般鏈看不到這段遊戲流量 |
| JS `naki-websocket.js` `attributeSend` | 同一份 msgId 登記 | Naki 在 A 送過 N，B 上遊戲的 N 不算選線證據 |
| Swift `LiqiParser.isNakiSent` | `LiqiMsgIdAllocator.isIssued` 或插件號段 | `ObservedMatchSids` 漏學遊戲自己的 `startUnifiedMatch`，被拒時也不清待回填 |
| Swift `LiqiResponseStore.capture` | `allocator.claim(msgId)` | 別條連線上遊戲的同號回應被當成 Naki 的回應認領 |

已有的基礎：`LiqiParser.pendingRequests` 以 `(socketId, msgId)` 為鍵；`parse` 收得到 socketId；JS `sendRaw` 回傳 `socketId`；`injectedMsgIds` 以 `(socketId, msgId)` 為鍵。

## 3. 時序邊界

- **JS**：`sendRaw` 選定連線後才送出。登記可以放在「選定之後、`ws.send` 之前」，此時連線已知。包過的 `send` 會同步跑 `attributeSend` 與插件 dispatch，所以登記必須在 `ws.send` 之前。
- **Swift**：`LiqiMsgIdAllocator.next()` 在組 envelope 時登記，此時還不知道連線。連線要等 `sendRaw` 的結果回到 Swift 才知道。REQUEST 回聲經 bridge 到 `LiqiParser.parse`，可能早於這個結果。
- **插件號段**：JS 自配發，經 `sendRaw` 送出。Swift 沒有任何登記。

## 4. 方案比較

| | 做法 | 修到守衛誤擋？ | 代價 |
|---|---|---|---|
| **A** | JS 與 Swift 登記都改為 (連線, msgId)。JS 拿掉「插件號段即 Naki」。Swift 送出前登記不綁連線，`sendRaw` 回報連線後再綁定。 | 是 | 改 JS 頁面 API 簽名（以選填參數相容）；`plugin-api-v1.md` 的 isNaki 定義要改字 |
| B | 維持號段，但只在 Naki 自己送過的連線上成立 | **否**：Naki 自送幾乎都在大廳，守衛也只在大廳，遊戲大廳 msgId 進號段照樣被擋 | 多一份「送過的連線」狀態 |
| C | 不改 | 否 | 長連線後大廳換裝一段時間全失敗；Swift 認領與學習持續誤判 |

**選 A。** 原因如下：
- B 沒解決要修的主問題，只縮小了範圍。
- 插件的 `sendRequest` 本來就經 `sendRaw` 送出，所以已在 (連線, msgId) 登記表內。號段判斷只會多認出「沒經 `sendRaw` 的號段 msgId」，那正是遊戲自己的。
- Swift 綁定採「未綁定時不看連線」。綁定前與 D22 前同樣寬，綁定後只會更準，沒有任何情況比現在鬆。

## 5. 方案 A 的規則

**JS**（`naki-websocket.js`）
- 登記表鍵為 `socketId:msgId`，上限 256 筆，FIFO，與 D9 相同。
- `sendRaw` 先選連線（proven 或 recency），登記 `(conn.id, msgId)` 後才 `ws.send`。
- `isNakiSent(msgId, socketId)`：給連線時精確比對。不給連線時回答「任一連線上有沒有」，維持頁面 API 相容。
- `attributeSend` 以該連線的 id 查。

**JS**（`naki-plugins.js`）
- `isNakiMsgId(msgId, socketId)` 只查登記表，不再看插件號段。
- 守衛第 1 步 `naki_traffic` 與 `runChain` 的 `isNaki` 都帶 `raw.wsId`。

**Swift**
- `LiqiMsgIdAllocator` 每筆登記帶 `socketId?`。`next()` 登記為未綁定，`bind(msgId, socketId:)` 綁定。
- `isIssued`／`claim` 新增選填的 `socketId`。比對規則是：查詢沒給連線、或登記未綁定，就不看連線；否則連線必須相同。
- `LiqiRawSendResult.socketId` 由 `NakiWebSocketScript.sendResult` 從 JS 回報解出。`LiqiActionSender.send` 成功且有連線時呼叫 `bind`。
- `LiqiParser` 的 RESPONSE 結果帶 `socketId`。`LiqiResponseStore.capture` 以它認領。
- `LiqiParser.isNakiSent(msgId:socketId:)` 以連線查登記。**插件號段仍整段排除**，理由見 §8。

## 6. 不變條件

- 守衛語意 D25–D34 不變。只有「誰是 Naki」的輸入變準，判定流程與結局種類不變。
- 不接觸雀魂伺服器。改動只在本地判斷。
- 對局自動打牌路徑只能更準：`claim` 綁定後只拒別條連線的同號，未綁定時與現在相同。
- `isNaki` 對插件的意思仍是「這筆是 Naki 或插件自己送的」（`plugin-api-v1.md` 第 108 行）。插件自己 `sendRequest` 的流量仍是 `isNaki`，仍不給 rewrite。

## 7. 明確不做

- 不改接收鏈、守衛接線、就地改寫。
- 不改 `LiqiResponseStore.response(forMsgId:)` 的讀取鍵。認領已帶連線，讀取端只拿得到認領過的。
- 不讓 Swift 知道插件送了什麼。這需要新的 bridge 訊息，超出本包範圍。
- 不改 `plugin-api-v1.md`、`CLAUDE.md`、`AUDIT.md`。三處文字要由主線同步，見 notes 的 Deviations。
- 不做 live 驗證。

## 8. 風險

- **Swift 插件號段仍排除。** 遊戲 msgId 在 64000–65500 時送的 `startUnifiedMatch` 不會被學到，被拒時也不清待回填，與 D22 前相同。選這邊的理由是：少學一次，下次換號會再學到；學到插件猜的值則會變成工具預設，錯誤自我餵養（`LiqiParser.parseRequest` 註解記載的 2026-08-09 實測）。
- **綁定前的窗口。** `sendRaw` 結果回到 Swift 之前，Swift 的登記不看連線，與現在一樣寬。這段通常是毫秒級，未實測。
- **頁面重載後 socketId 重用。** JS 的 `wsIdCounter` 重載後從 1 起算，Swift 登記表可能還留著舊頁面的綁定。最壞情況與 D22 前「只看號碼」相同，不會更鬆。
- **契約文字變更。** `plugin-api-v1.md` 寫「登記表 ∪ 插件號段」，spike 拿掉了號段。這對插件可見：遊戲在號段內的流量改走一般鏈，可被 observe／rewrite。合併前要由主線改契約文字，並向用戶確認。
- **未綁定的 `js_error` 類失敗。** 結果不帶連線就不綁定，維持現狀。
