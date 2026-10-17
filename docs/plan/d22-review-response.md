# D22 審查回應（Astra 第一輪）

審查原文：`.swfd/logs/d22-review/astra-review1.md` 第 4490–4530 行。結果是 0【擋】、5【應修】、2【建議】。

本輪 7 條全部採納，沒有反駁。log 在 `.swfd/logs/d22/round2-*.log`。

## 1.【應修】淘汰後的注入回應取得改寫能力：採納

**修法**：`runChain` 先查注入登記（`injectedMsgIds`，以 (連線, msgId) 為鍵）。注入登記還在的 RESPONSE 一律算 Naki，不再只看 `sendRaw` 登記（`naki-plugins.js`）。

**證據**：plugin-regression 第 31 案例「injected RESPONSE stays Naki after its sendRaw registration is evicted by the other /gateway」。
- 第二條 /gateway 送出 256 筆後，第一條上的注入登記已被淘汰。這一點已斷言，證明 256 筆由兩條線共用。
- 之後原回應到達，`onInjectResponse` 拿到的是 `isNaki=true`，而且沒有 `replace`。
- 這個案例對 ee3c167 是紅的（`round2-red-plugin-regression.log`）。
- 變異 R1 拿掉注入判斷、R4 把容量改成 512，兩者都會被它抓到。

## 2.【應修】Swift 綁定前窗口：採納（文件限定範圍，並補測試）

**評估**：要更嚴，就得在 `claim` 時拒絕未綁定的登記。但 Swift 不知道配號時的候選連線，拒絕未綁定登記會讓先到的真回應遺失。所以不加嚴，只在文件中限定範圍。

**文件**：設計 §4、§8 寫明保證只涵蓋「已綁定、而且查詢帶連線」，並列出窗口內兩種先後順序的結果。正式路徑的 `capture` 一定帶連線，因為解析結果帶 `socketId`。

**測試**（`LiqiResponseStoreTests`）：
- `testUnboundRegistrationGoesToTheFirstResponseOnAnySocket`：別條線先到就被它認領，之後的綁定與真回應都落空。這是鎖住殘留。
- `testTrueResponseBeforeBindIsClaimed`：真回應先到時正常認領，之後的 `bind` 不起作用。
- `testAmbiguousFailureKeepsAnUnboundRegistration`：`js_error` 時保留未綁定登記，任一連線都認。

**變異**：R8 讓未綁定登記不再任一連線都認，被 6 個測試抓到。R11 讓 `js_error` 也撤銷登記，被抓到。

**未驗證**：窗口長度，以及 WebKit 實際的先後順序。

## 3.【應修】同線同號仍誤擋：採納（目標改字，並收窄殘留）

**目標**：設計 §1 改為「消除純號段誤判與跨連線誤判」，同線在途碰撞明列為殘留（§8）。

**收窄**：JS 登記加 `answered`。RESPONSE 到達時把同配對標成已答，之後同線同號的 REQUEST 是遊戲自己的。

**不會更鬆的理由**：
- 已答只影響 REQUEST 的判斷。
- 同號 RESPONSE 仍算 Naki，即使有第二個同號回應也不會交給可改寫的鏈。
- Naki 自己的 REQUEST 一定在 RESPONSE 之前經過判斷。
- Naki 重送同號會重新登記，並把已答歸零。

**位置**：標記放在 `handleMessage` 收訊記帳處，與 `lastRecvAt` 同一行。它不改派發順序、改寫或交付。這一點記在 notes 的 Deviations。

**證據**：
- b2 第 63 案例重現 Astra 的情境：大廳 `sendRaw(loginBeat#60003)` 後，遊戲同線送 `changeCharacterSkin#60003`。RESPONSE 到達前得到 `naki_traffic`，這是殘留；到達後送出。
- plugin-regression 第 32 案例另外驗證：RESPONSE 本身仍是 Naki，第二個同號 RESPONSE 也是 Naki。
- 兩個案例對 ee3c167 都是紅的。變異 R2、R3 都會被抓到。

## 4.【應修】契約同步：採納

- **`docs/plugin-api-v1.md` 第 108 行**：改為「當前 (socketId, msgId) 在登記表內（REQUEST 只認未答），或是你注入請求的回應」。
- **`docs/plugin-api-v1.md` 第 206 行一帶**：拿掉「∪ 插件號段」。寫明 256 筆所有連線共用、同配對重送刷新、`isNakiSent(msgId, socketId?, pendingOnly?)` 省略連線時查任一連線。
- **可見差異**：照 Astra 重現寫明。遊戲 `authGame#64003` 的回應會觸發 name-hider 關閉遮罩，也會讓 gist-logger 新增紀錄；tile-highlighter 不受影響。沒有寫「既有插件完全無行為差異」。
- **溢出邊界段**：改為容量由所有連線共用，注入回應不受此邊界影響。
- **`CLAUDE.md` 第 108 行與第 146–149 行一帶**：改為 (連線, msgId) 登記、先登記後綁定、綁定前窗口、Swift 插件號段只影響 `ObservedMatchSids`、JS 規則以契約為準。
- **`AUDIT.md` 第 163 行**：改為 (連線, msgId) 登記制，並列出殘留。

## 5.【應修】socketId 事實寫錯：採納

**文件**：設計 §8 改寫。每個 frame 以隨機起點 `floor(random·1e6)·1e6` 遞增配發，同頁不重用。重載後起點重抽，不是從 1 開始，但跨頁撞號仍有機率。重載清掉 JS 登記，Swift 舊綁定可能留存。不建 session 身分。

**測試**：plugin-regression 第 33 案例。
- 固定隨機值 0.25 時，重載後 id 相同；換成 0.5 就不同。
- JS 登記不跨重載保留。
- 同頁重連會得到新 id，舊登記只對舊 id 成立。

**變異**：R5 把起點固定成 0、R6 讓重連重用 id，兩者都會被抓到。

## 6.【建議】Swift 保留號段排除，分開描述三個消費端：採納

**文件**：設計 §8 分開描述三個消費端：parser 的 sid 學習、parser 的拒絕回應清理、`LiqiResponseStore` 認領。前兩者把號段當 Naki，是驗收例外；後者沒有號段判斷。不加插件登記 bridge。

**測試**：`testGameStartUnifiedMatchInPluginRangeIsTreatedAsNaki` 鎖住殘留：號段內的請求不學，被拒的回應也不清待回填。變異 R9 拿掉號段排除，被抓到。

## 7.【建議】補強弱斷言：採納

- **v2 第 10 案例**：遊戲送的 64003 實際改寫，並核對送出的 bytes。
- **學習案例**：Naki 這條線改用不同的 sid（`guess`），斷言觀察表只有 `ranked`。
- **五類案例都已補上**，各至少一個變異：綁定前認領順序（R8）、雙線淘汰（R4）、同線碰撞（R2、R3）、號段內拒絕回應（R9）、重載與重連（R5、R6）。

## 結果

| 項目 | 結果 |
|---|---|
| node 三套回歸 | 33／0、63／0、21／0 |
| 全量 NakiTests | 1165 tests、0 failures |
| 第二輪變異 | 11 個，全數被抓 |

未驗證：
- live。
- Swift 綁定前窗口的長度。
- WebKit 的訊息先後順序。
- 跨頁 socketId 撞號的實際機率。

---

# 第三輪（Astra 第二輪）

審查原文：`.swfd/logs/d22-review/astra-review2.md` 第 5097–5172 行。第一輪 7 條中，1、2、5、6、7 判已修，3、4 判部分。新發現是 0【擋】、2【應修】、2【建議】。

4 條全部採納。log 在 `.swfd/logs/d22/round3-*.log`。

## 1.【應修】answered 漏掉 Blob；本地結案：採納

**Blob**：在 `data.arrayBuffer()` 展開完成處補 `markNakiAnswered`（`naki-websocket.js`）。
- b2 第 64 案例：Blob 的 `loginBeat#60003` RESPONSE 展開後，遊戲同線 `changeCharacterSkin#60003` 正常送出。
- 這個案例對 84b1f7f 是紅的（`round3-red-b2.log`），變異 T3 會被它抓到。

**本地結案**：維持不標記，在設計 §5、§8 與 API 列為例外。理由是：被擋下的也可能是被誤認的遊戲請求，此時真正的 Naki 請求仍在路上；全部當成已答會讓在途碰撞更鬆。
- b2 第 65 案例鎖住例外：本地錯誤回應交付後，同號遊戲請求仍是 `naki_traffic`。
- 變異 T4（本地結案也標記）會被它抓到。

## 2.【應修】殘留敘述不足：採納（文件限定）

設計 §1、§8、`plugin-api-v1.md` 與 `AUDIT.md` 第 163 行，都把殘留分成下列幾種，並寫明它們在 main 就存在：
- REQUEST 在途碰撞。
- REQUEST 本地結案例外。
- RESPONSE 持續誤認：遊戲 REQUEST 恢復，但其 RESPONSE 仍算 Naki 直到淘汰或重送，一般 observer 收不到，也沒有 `replace`。
- 注入錯認領。

注入錯認領由 plugin-regression 第 36 案例鎖住：遊戲同號 RESPONSE 先被交給 `onInjectResponse`，真回應之後沒有 callback，也不會交給任何插件。變異 T5 會被它抓到。

不建 session 身分。

## 3.【建議】變異缺口：採納

- **已答、重送、再次待答**：plugin-regression 第 34 案例，驗證 isNaki 與選線證據。Astra 的漏網變異「重送保留舊 answered」即 T1，已被抓到。
- **雙 /gateway 同號、只一線已答**：plugin-regression 第 35 案例驗 isNaki 與選線證據，b2 第 66 案例驗守衛結果與實際外送。isNaki 決定是否給 `replace`。Astra 的漏網變異「標記所有連線同號」即 T2，兩案都抓到。
- **Blob**：見第 1 條，T3。
- **本地結案**：見第 1 條，T4。
- **注入同號先到**：見第 2 條，T5。

## 4.【建議】API 文字：採納

`plugin-api-v1.md` 已補上下列內容：
- 省略 `pendingOnly` 等同 `false`。
- 省略 `socketId` 或傳 `null` 時查任一連線。
- `isNakiSent(60003, null, true)` 的範例。
- 同配對重送會變回待答。
- 只有同一連線上的 RESPONSE 才標記已答。
- Blob 也算。
- 頁面 API 只查 `sendRaw` 登記、不含注入登記，所以不等於 `ctx.isNaki`，並附上淘汰情境的例子。

## 結果

| 項目 | 結果 |
|---|---|
| node 三套回歸 | 36／0、66／0、21／0 |
| 全量 NakiTests | 1165 tests、0 failures |
| 第三輪變異 | 5 個，全數被抓 |

未驗證：
- live。
- WebKit 的訊息先後順序與綁定窗口。
- 實機 Blob 的 binaryType：雀魂實際用 ArrayBuffer 還是 Blob，本輪沒有 live 查證。

