# D22：Naki 自送身分加上連線

**狀態**：方案 A 已有 spike（分支 `d22-naki-identity`，基準 main `f720dc1`），未合併。第二、三輪已回應 Astra，見 `d22-review-response.md`。
**來源**：`plugin-v2-b2.md` §4.6；`plugin-v2-b2-review-response.md` 第三輪第 4 條；Astra 原文 `.swfd/logs/pv2-b2-review/astra-review3.md` 第 4 條。

## 1. 目標

「這筆是不是 Naki（含插件）送的」改以 **(連線, msgId)** 判斷，不再只看號碼。目標是消除兩種誤判：
- **純號段誤判**：遊戲 msgId 落在插件號段 64000–65500，就被當成 Naki。
- **跨連線誤判**：Naki 在 A 線用過的號，遊戲在 B 線用到同號，也被當成 Naki。

**不在目標內**：同一連線上的同號無法區分來源，留有四種殘留：REQUEST 在途碰撞、本地結案例外、RESPONSE 持續誤認、注入錯認領，見 §8。本設計不宣稱遊戲 msgId 進入 60000–65500 後一律不再被誤認。

## 2. 現況（main `f720dc1`）

live 事實（`.swfd/logs/unlock-handshake-20261017/README.md`）：遊戲 msgId 計數器全域遞增、跨連線共用。Naki 自送用 60000–63999，插件用 64000–65500。

| 位置 | 判斷 | 誤判後果 |
|---|---|---|
| JS `naki-plugins.js` `isNakiMsgId` | 插件號段，或 `sendRaw` 最近 256 筆 msgId | 遊戲 msgId 進 64000–65500 後，該段約 1500 筆大廳守衛方法全被 `naki_traffic` 擋（本地錯誤 code 6）；插件一般鏈看不到這段遊戲流量 |
| JS `naki-websocket.js` `attributeSend` | 同一份 msgId 登記 | Naki 在 A 送過 N，B 上遊戲的 N 不算選線證據 |
| Swift `LiqiParser.isNakiSent` | `LiqiMsgIdAllocator.isIssued` 或插件號段 | `ObservedMatchSids` 漏學遊戲自己的 `startUnifiedMatch`，被拒時也不清待回填 |
| Swift `LiqiResponseStore.capture` | `allocator.claim(msgId)` | 別條連線上遊戲的同號回應被當成 Naki 的回應認領 |

## 3. 時序邊界

- **JS**：`sendRaw` 選定連線後才送出。登記放在「選定之後、`ws.send` 之前」，此時連線已知。包過的 `send` 會同步跑 `attributeSend` 與插件 dispatch，所以登記必須在 `ws.send` 之前。
- **Swift**：`LiqiMsgIdAllocator.next()` 在組 envelope 時登記，此時還不知道連線。連線要等 `sendRaw` 的結果回到 Swift 才知道。REQUEST 回聲與 RESPONSE 經 bridge 到 `LiqiParser.parse`，可能早於這個結果。
- **插件號段**：JS 自配發，經 `sendRaw` 送出。Swift 沒有任何登記。

## 4. 方案比較

| | 做法 | 修到守衛誤擋？ | 代價 |
|---|---|---|---|
| **A** | 登記改為 (連線, msgId)，JS 拿掉「插件號段即 Naki」，Swift 先登記後綁定 | 純號段與跨連線：是。同線在途碰撞：否 | 頁面 API 加選填參數；`plugin-api-v1.md` 改字；插件可見差異 |
| B | 維持號段，但只在 Naki 自己送過的連線上成立 | **否**：Naki 自送幾乎都在大廳，守衛也只在大廳 | 多一份「送過的連線」狀態 |
| C | 不改 | 否 | 長連線後大廳換裝一段時間全失敗；Swift 認領與學習持續誤判 |

**選 A。** 原因如下：
- B 沒解決主問題。
- 插件 `sendRequest` 本來就經 `sendRaw` 送出，已在登記表內。號段判斷只會多認出「沒經 `sendRaw` 的號段 msgId」，那是遊戲自己的。
- Swift 綁定採「未綁定時不看連線」。只有在已綁定、而且查詢帶連線時，判斷才比 D22 前準。其餘情況與 D22 前相同，見 §8。

## 5. 方案 A 的規則

**JS**（`naki-websocket.js`）
- 登記表鍵為 `socketId:msgId`，值記 `answered`。上限 256 筆，**所有連線共用**，FIFO；同配對重送刷新成最新、`answered` 歸零。
- `sendRaw` 先選連線（proven 或 recency），登記 `(conn.id, msgId)` 後才 `ws.send`。
- 收到 RESPONSE 時，把同一配對（只限同一連線）標成 `answered`。ArrayBuffer／TypedArray 在 `handleMessage` 收訊記帳處標記，與 `lastRecvAt` 同一行；Blob 讀不到，在異步展開完成處標記。兩處都在插件鏈之外，而 RESPONSE 的判斷不讀 `answered`，所以先標記不影響這則回應本身。
- 本地結案（守衛擋下後的本地錯誤回應）不標記，理由見 §8。
- `isNakiSent(msgId, socketId?, pendingOnly?)`：給連線時精確比對，不給時查任一連線。`pendingOnly` 為真時只認未答的配對。
- `attributeSend` 以該連線、`pendingOnly` 查。

**JS**（`naki-plugins.js`）
- `isNakiMsgId(msgId, socketId, request)` 只查登記表，不看插件號段。REQUEST（守衛第 1 步、send 方向的鏈）只認未答；RESPONSE 認任一登記。
- 注入登記（`injectedMsgIds`，以 (連線, msgId) 為鍵）還在的 RESPONSE 一律算 Naki，即使 `sendRaw` 登記已被淘汰。

**Swift**
- `LiqiMsgIdAllocator` 每筆登記帶 `socketId?`。`next()` 登記為未綁定，`bind(msgId, socketId:)` 綁定。
- `isIssued`／`claim` 有選填的 `socketId`。比對規則是：查詢沒給連線、或登記未綁定，就不看連線；否則連線必須相同。
- `LiqiRawSendResult.socketId` 由 `NakiWebSocketScript.sendResult` 解出。`LiqiActionSender.send` 成功且有連線時呼叫 `bind`。結果無法判定（`js_error` 等）時保留未綁定登記。
- `LiqiParser` 的 RESPONSE 結果帶 `socketId`。`LiqiResponseStore.capture` 以它認領，所以正式路徑的查詢一定帶連線。

## 6. 不變條件

- 守衛語意 D25–D34 不變。只有「誰是 Naki」的輸入變準，判定流程與結局種類不變。
- 不接觸雀魂伺服器。改動只在本地判斷。
- 對局自動打牌路徑：`claim` 綁定後只拒別條連線的同號；未綁定時與現在相同。
- `isNaki` 的意思仍是「這筆是 Naki 或插件自己送的」。插件自己 `sendRequest` 的請求與回應仍是 `isNaki`，仍不給 rewrite。

## 7. 明確不做

- 不改接收鏈的派發順序、守衛接線、就地改寫。
- 不改 `LiqiResponseStore.response(forMsgId:)` 的讀取鍵。
- 不讓 Swift 知道插件送了什麼（需要新 bridge 訊息）。
- 不建跨頁面的 session 身分。
- 不做 live 驗證。

## 8. 殘留與風險

- **JS 同線同號的殘留。** 以下都只在遊戲用到「同一連線上、Naki 用過的同一 msgId」時發生。這些都存在於 main，D22 沒有讓它們更鬆。
  - **REQUEST 在途碰撞**：Naki 的 REQUEST 還沒收到 RESPONSE 時，遊戲同號 REQUEST 仍被當成 Naki，守衛方法得到本地錯誤。RESPONSE 到達後恢復。
  - **REQUEST 本地結案例外**：Naki（或注入）的守衛方法請求被擋下後，只有本地錯誤回應，配對維持待答，直到淘汰或重送。不標記的理由是：被擋下的也可能是被誤認的遊戲請求，此時真正的 Naki 請求仍在路上。把所有本地錯誤都當成已答，會讓在途碰撞更鬆。維持待答是較嚴的一側。
  - **RESPONSE 持續誤認**：Naki 往返結束後，遊戲同號 REQUEST 會恢復，但它的 RESPONSE 仍算 Naki，直到淘汰或重送。一般 observer 收不到這則回應，也沒有 `replace`。RESPONSE 分不出是哪一筆的回應，所以寧可少給 rewrite。
  - **注入錯認領**：注入的 `sendRaw` 登記已淘汰、注入登記還在時，遊戲同號 RESPONSE 先到，會被交給 `onInjectResponse` 並消耗注入登記。之後真回應不再有 callback，方法也對不回，所以不會交給任何插件。
  - 不建 session 身分來消除這些殘留。
- **Swift 綁定前窗口。** 保證只涵蓋「已綁定、而且查詢帶連線」。窗口內未綁定的登記交給先到的同號回應：
  - 別條線上遊戲的同號回應先到，就會被認領並存進以 msgId 為鍵的 store。之後的 `bind` 找不到登記，A 線的真回應也無法認領。
  - 真回應先到時正常認領，之後的 `bind` 不起作用。
  - 窗口長度與 WebKit 的實際先後順序都未驗證。
  - 若要更嚴，就得讓 `claim` 拒絕未綁定的登記，但那會讓先到的真回應遺失。所以不做，只在文件中限定範圍。
- **Swift 插件號段排除。** 三個消費端的行為不同：
  - parser 的 sid 學習：遊戲在號段內送的 `startUnifiedMatch` 被當成 Naki，不學。
  - parser 的拒絕回應清理：同號段的被拒回應不清待回填。這與 D22 前相同，是驗收例外。
  - `LiqiResponseStore` 認領：沒有號段判斷，只認 Swift 配發登記，所以不會因為落在 64000 就認領。
  - JS 守衛不讀 Swift 判斷，不受這個不對稱影響。保留排除的理由：學到插件猜的 sid 會變成工具預設，錯誤自我餵養（2026-08-09 實測）。
- **socketId 的事實。** JS 每個 frame 以隨機起點 `floor(random·1e6)·1e6` 遞增配發，同頁連線關閉後不重用。重載後起點重抽，不是從 1 開始，但與舊頁面撞號仍有機率。重載會清掉 JS 登記；Swift 的舊綁定可能還在，撞號時的最壞情況與 D22 前「只看號碼」相同。
- **契約變更對插件可見。** 遊戲在 64000–65500 的流量改走一般鏈。審查重現了兩例：遊戲 `authGame#64003` 的回應會觸發 name-hider 關閉遮罩，也會讓 gist-logger 新增紀錄。tile-highlighter 的 ActionPrototype 與推薦更新路徑不受影響。合併前需用戶確認。
- **登記表容量。** 256 筆由所有連線共用。注入回應另以注入登記判斷，不受送出登記淘汰影響。
