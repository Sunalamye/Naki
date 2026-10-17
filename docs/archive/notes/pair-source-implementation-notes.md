# pair-source 實作 notes（跨來源 msgId 配對隔離）

基準 main `13abe49`，分支 `feat/pair-source`。設計：`docs/archive/plan/pair-source-design-2026-10-17.md`。證據 log 在主 repo `.swfd/logs/pair-source/`。

## 做了什麼

- `naki-plugins.js`：
  - `nextPluginMsgId` 輪用時跳過任一連線上未答配對的號碼，以及遊戲計數器接下來 256 個號碼。
  - `dispatch` 記錄遊戲最後的 REQUEST msgId，經 `sendRaw` 登記的（Naki 自送與插件注入）不算。
  - 注入的配對存在注入登記 `{ id, method }`：`remember` 跳過這次注入，RESPONSE 先比對注入登記並以注入方法派發，不消耗遊戲配對。
  - `closed` 清該連線的注入登記；`diagnostics().pendingInjections`。
- 測試：`GG11-4` 改正向斷言（`GG11-4 / PS-1`），新增 `PS-2`～`PS-6`（`plugin-v2-b2-regression.cjs`）；`plugin-regression.cjs` 的 D22-3 殘餘測試改成新語意。
- 變異：`guard-gaps-mutate.cjs` 加 `PS1`～`PS8`。
- 契約 `plugin-api-v1.md`：號段段落、注入錯認領、跨來源配對隔離、配對表容量。`plugin-v2-b2.md` §1.4 第 5 項與第十四輪摘要。

## 先紅後綠

| 階段 | 結果 | log |
|---|---|---|
| 新測試套在 `13abe49` 原碼 | 5 紅：PS-1～PS-3 注入拿到 64000；PS-4 注入回應被派成 `fetchCharacterInfo`（派錯實證）；PS-5 沒有 `pendingInjections` | `red-b2-on-13abe49.log` |
| 實作後 | b2 182／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全綠 | `final-*.log` |

PS-5 修前的紅只來自缺診斷欄位，不是行為紅：連線關閉後舊連線的注入登記鍵帶舊 socketId，原本就不會誤派，只占容量。PS-6 修前即綠，用來固定「Naki 自送與注入本身不移動遊戲窗口」，殺 PS7。

## 變異

| 範圍 | 結果 | log |
|---|---|---|
| 本包 PS1～PS8 | 8/8 殺 | `mutate-ps.log` |
| 全量 0–50、50–98（分段前景） | 49/50、47/48；存活只有等價的 U10、T7 | `mutate-full-a.log`、`mutate-full-b.log` |

## Swift

- `JSContractTests`＋`PluginSendGuardTests`：19 tests，0 failures（`test-targeted.log`）。
- 全量 `NakiTests`：1184 tests，0 failures（`test-full.log`）。DerivedData 在主 repo `.swfd/dd-pair-source`。

## Deviations

1. **不採派工建議的「改寫 msgId、回來還原」**。派工單的前提是「遊戲永不看到注入的 RESPONSE，因為 D22 已把 Naki 自送回應攔下」。`naki-websocket.js` 接收路徑沒有攔下 Naki 回應的程式；`respondLocal` 以 `ws.dispatchEvent` 把本地錯誤回應交給遊戲。所以號碼必須在配發時避開，改寫無益。選較保守的避號，不改 `naki-websocket.js`。
2. **`naki-websocket.js` 沒改**。可改清單包含它，但避號與分槽都在 `naki-plugins.js` 內完成。
3. **「重連後號段重設」的解讀**。輪用指標不歸零：遊戲計數器跨連線遞增，歸零反而可能撞到遊戲。改成連線關閉時清掉該連線的注入登記與配對，重連後舊號碼的回應不交給任何人、新注入正常往返（PS-5）。
4. **拿掉兩個冗餘判斷**（第二輪推翻前半，見下）。注入登記不納入避號：輪一圈 1501 號，注入登記上限 256，被淘汰前不會輪回。`blockSend` 不特判注入：同號遊戲配對已被避開，撤銷只會撤到空鍵。實作中曾加過「注入本身不算遊戲號碼」的位元比對，變異 PS8（舊編號）存活，原因是注入經 `sendRaw` 已登記為 Naki、被 `isNakiSent` 排除，於是刪掉。
5. **`msgid_busy`**（第二輪起可達，見下）：避號上限 512 個（配對 256＋窗口 256），小於號段 1501 個，找不到的分支不可達，沒有測試、沒有變異。

## 已知風險

- 窗口 256 是啟發式。遊戲在一次注入往返內送超過 256 筆，或注入一直沒回應，遊戲仍可能走到注入未答的號碼。這時配對各自正確：第一則 RESPONSE 歸注入，下一則對回遊戲方法（PS-4）。遊戲那筆依 D22 算 Naki，若是守衛方法會被 `naki_traffic` 擋下。遊戲層也可能把注入的回應當成自己的，這是協定層同號，未處理。
- 回應順序假設：同號的兩則 RESPONSE 依送出順序抵達。伺服器若亂序，注入與遊戲會互換，未驗證。
- Naki 自送（60000–63999）與遊戲之間沒有隔離（D22 範圍）。
- 遊戲計數器的繞回點未知。若繞回點低於 64000，遊戲永遠不進插件號段，窗口無作用也無害。
- 未 live 驗證。

## 第二輪（Astra 第一輪：2 擋 4 應修 1 建議，主線全採納）

審查原文：主 repo `.swfd/logs/pair-source-review/astra-review1.md`。main 仍在 `13abe49`，不需 rebase。Astra 確認接收前提修正成立。

| 條 | 處理 | 測試 |
|---|---|---|
| 擋 1 跳號提前繞回、覆寫未答注入 | 避號集合納入所有連線的未答注入登記 | PS-7 |
| 擋 2 `pendingMethods` 不涵蓋全部在途遊戲請求 | 每連線另記遊戲最後號碼與未答集合，不論有無插件；RESPONSE 與 `blockSend` 消耗；上限 256，超過即失準，該連線關閉前拒發 `msgid_busy` | PS-8、PS-9、PS-10 |
| 應修 3 只比 msgId | 以完整 bytes 辨識注入（派發、鏈首登記、判決後提交、`failSafe` 照送） | GG3-2 補回應斷言、PS-14 |
| 應修 4 零消耗者不消耗注入登記 | 早退前 RESPONSE 先消耗同鍵注入登記，否則消耗遊戲配對 | PS-11 |
| 應修 5 遊戲本地錯誤消耗注入登記 | 判決帶 `injected`，`localResponse` 只認注入本身被擋 | PS-12 |
| 應修 6 歧義回應進可改寫鏈 | 注入回應抵達時同鍵有遊戲配對 ⇒ 標歧義，下一則當 Naki 流量（只觀察） | PS-13、D22-3 改反序不同方法 |
| 建議 7 | 設計文件撤回無條件敘述，列未驗證前提；契約同步 | — |

注入登記上限是 256（Astra 指正；第一輪的 512 是排除數上界），文件已同步。

### 先紅後綠

| 階段 | 結果 | log |
|---|---|---|
| 第二輪測試套在 `6f3ae42` 的 JS | b2 7 紅：GG3-2、PS-7、PS-8、PS-9、PS-11、PS-12、PS-13；plugin-regression D22-3 紅。另 2 紅（plugin-regression 第 13、14 條）是暫存樹沒有 Swift 原始檔的環境假紅 | `r2-red-b2-on-6f3ae42.log`、`r2-red-plugin-regression-on-6f3ae42.log` |
| PS-10、PS-14 | 舊版即綠或在本輪新增，用來殺 PS10、PS11、PS17 | — |
| 實作後 | b2 190／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9 | `r2-final-*.log` |

### 變異

| 範圍 | 結果 | log |
|---|---|---|
| 本包 PS1～PS17 | 17/17 殺 | `r2-mutate-ps.log` |
| 全量 0–54、54–107 | 53/54、52/53；存活只有 U10、T7 | `r2-mutate-full-a.log`、`r2-mutate-full-b.log` |

既有 17 條變異的替換字串隨程式碼更新（BB1～BB4、Y1、X1、X2、W1、P2、P3、M1），語意不變。

### Swift

`JSContractTests`＋`PluginSendGuardTests` 19／0（`r2-test-targeted.log`），全量 `NakiTests` 1184／0（`r2-test-full.log`）。

### 第二輪 Deviations

1. **應修 3 不採一次性認領**。主線指示「以注入請求物件／交易代號比對」。實作過「派發只認領一次」，`GG4-6` 隨即轉紅：相同 bytes 的重入派發先認領後，真正的注入走一般路徑，繞過注入退回檢查而送出。這違反 guard-gaps Deviation 11（相同 bytes 碰撞兩筆都擋）。改用完整 bytes 比對（msgId＋內容），能修 Astra 的反例（同號不同內容），相同 bytes 的重入照 Deviation 11 兩筆都當注入。
2. **擋 2 滿時策略選拒發**。被淘汰的號碼無從得知何時答覆，擴大窗口仍可能撞上，所以拒發到該連線關閉。正常對局每筆請求都有回應，256 筆未答只在異常時出現。
3. **歧義標記只在注入回應抵達時設**。同鍵遊戲配對若之後被 FIFO 淘汰，標記仍在，下一則同鍵回應照樣只觀察；標記容量 256、連線關閉時清。
4. **`naki-websocket.js` 改一處**：`respondLocal` 呼叫 `localResponse` 時多傳 `verdict.injected`。

### 第二輪已知風險

- 窗口 256 與失準拒發都是保守啟發式：遊戲計數器步進、繞回、重連後的行為，以及遊戲收到陌生 msgId 回應的行為，都沒有 live 證據。
- 同號兩則 RESPONSE 依送出順序抵達的假設未驗證。歧義的那一則只觀察，不派給一般鏈。
- 連線數超過 2 且各自大量未答時，可用號碼可能被占滿而回 `msgid_busy`（PS-9 驗了失準路徑，占滿路徑沒有獨立測試）。
- 未 live 驗證。

## 第三輪（Astra 第二輪 8～14 條；主線裁決：注入身分改為宿主交易代號）

審查原文：主 repo `.swfd/logs/pair-source-review/astra-review2.md`。main 仍在 `13abe49`。第二輪 Deviations 採納；第二輪應修 3 的 bytes 比對被本輪的代號方案取代。

### 做了什麼

- `naki-websocket.js`：
  - `sendRaw(base64, sender)` 把送進 `ws.send` 的 buffer 記進 `WeakMap`：注入記代號，Swift 呼叫記 `'naki'`。
  - `handleMessage` 查出送出者，傳給 `dispatch`（`raw.sender`）與 `failSafe`（第三參數）。
- `naki-plugins.js`：
  - `sendRequest` 配代號 `{ id, method }`，記進 `WeakSet`，注入登記的值就是代號。`raw.injected` 只看代號是否存活。`injecting` 只剩守衛用途：相同 bytes 的重入派發一併做注入退回判定。
  - `api.dispatch` 包一層：送出判決確定外送後才記遊戲未答；原派發本體移為閉包內的 `dispatchRaw`。`failSafe` 照送出口也記。`blockSend` 對注入不撤銷 `pendingMethods`，對遊戲撤回已記的未答。
  - RESPONSE 沒被同鍵注入登記認領才消耗遊戲未答。非大廳鏈尾 `pairWith` 跳過注入。
  - 歧義鍵超過 256 個時，有鍵的連線整條標成歧義到關閉。零消耗者早退的清理也看歧義標記。

| 條 | 處理 | 測試 |
|---|---|---|
| 擋 8 | 遊戲＝沒有送出者，不看 `isNakiSent`；注入回應不碰遊戲未答 | PS-15 |
| 應修 9 | `blockSend` 依代號，不撤銷同鍵遊戲配對 | PS-16 |
| 應修 10 | 非大廳鏈尾依 `raw.injected`（入口固定，不受鏈中改動影響） | PS-17 |
| 應修 11 | 歧義滿時整條連線只觀察到關閉 | PS-18 |
| 應修 12 | 判決確定外送後才記未答；派發後 `failSafe` 才擋的由 `blockSend` 撤回 | PS-19、PS-22 |
| 應修 13 | 配對來源看代號，相同 bytes 的遊戲請求照常登記；守衛仍兩筆都擋 | PS-20、GG4-6 |
| 應修 14 | 零消耗者清理含歧義標記 | PS-21 |

### 先紅後綠

| 階段 | 結果 | log |
|---|---|---|
| 第三輪測試套在 `85c6fd1` 的 JS | PS-15～PS-21 共 7 紅，皆為審查反例的語意紅：PS-15 配號序列再次出現 64000；PS-16 配對被撤銷；PS-17 配對 2→3；PS-18 改寫鏈收到 64000、1990；PS-19 `msgid_busy`；PS-20、PS-21 回呼缺失 | `r3-red-b2-on-85c6fd1.log` |
| PS-22 | 本輪補，殺變異 PS11（派發後 `failSafe` 才擋的撤回路徑） | — |
| 實作後 | b2 198／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9 | `r3-final-*.log` |

### 變異

| 範圍 | 結果 | log |
|---|---|---|
| 全量 0–58、58–115 | 56/58、57/57；存活只有 U10、T7；本包 PS1～PS25 全殺（新增 PS18～PS25 共 8 條） | `r3-mutate-full-a.log`、`r3-mutate-full-b.log` |

既有變異隨程式碼更新替換字串：BB3、AA4、AA5、X1、N3、M1、M2、PS8、PS10、PS16、PS17。P2、P3 改定義：bytes 比對已不是來源判定，所以改成「注入退回只認代號」（`GG4-6` 殺）與「相同 bytes 也當注入來源」（`PS-20` 殺）。

### Swift

`JSContractTests`＋`PluginSendGuardTests` 19／0（`r3-test-targeted.log`），全量 `NakiTests` 1184／0（`r3-test-full.log`）。Swift 呼叫 `sendRaw` 仍只傳一個參數，送出者記為 Naki。

### 第三輪 Deviations

1. **`failSafe` 照送記未答沒有獨立變異**：只有「派發本身拋錯」才走這個出口。現有 harness 沒有能讓 `dispatch` 拋錯、又照送的情境，所以未加這條變異。「派發後才擋」的撤回由 PS-22 覆蓋。
2. **偽造代號**（第四輪更正，原敘述「不影響其他插件或遊戲的配對」不實）：插件直接呼叫 `sendRaw(b64, 任意物件)` 時，物件不在 `WeakSet` 內，會被當成 Naki 自送，登記進共用配對表。遊戲同號請求未答時，這筆會覆寫遊戲的配對，吃掉遊戲方法的回呼（Astra 第三輪第 17 條已重現）。包裝全域 `sendRaw` 也能取得真代號。影響範圍見第四輪 Deviations 2。

### 第三輪已知風險

- 歧義滿時整條連線只觀察，代價是該連線之後所有 RESPONSE 都沒有一般鏈與 `replace`，直到關閉。只在 256 個歧義鍵同時存在時觸發。
- 第二輪列的 live 前提仍未驗證：計數器步進、繞回、重連、陌生 msgId 回應的客戶端行為、回應順序。
- 未 live 驗證。

## 第四輪（Astra 第三輪 15～18 條；全採納）

審查原文：主 repo `.swfd/logs/pair-source-review/astra-review3.md`。main 仍在 `13abe49`，不需 rebase。第三輪 Deviations 採納（第 2 條依第 17 條更正）。

### 做了什麼

- `naki-plugins.js`：
  - 遊戲記帳分兩段。`api.dispatch` 一進入就把遊戲 REQUEST 的號碼放進 `gameDispatching`，派發結束（含拋錯）移除；`nextPluginMsgId` 把保留號碼當未答，也從它推前方窗。保留不占容量、不觸發失準。
  - 提交（`gameSent`）回傳復原紀錄：提交前的未答集合與失準旗標。`dispatch` 存到 `gameUndo`，下一次派發入口清除。`failSafe` 取走它，擋下遊戲送出時以 `revertGameSend` 整個還原（連線與 msgId 都相符才套用）。
  - `blockSend` 不再動遊戲未答，先前同號、已外送的未答留著。
  - 注入代號一次性：`sendRaw` 返回即從 `liveTokens` 移除。
- `naki-websocket.js` 未改。

| 條 | 處理 | 測試 |
|---|---|---|
| 擋 15 | 派發中保留號碼與其後 256 個，同步 hook 內的注入避開 | PS-23（守衛／非守衛兩路） |
| 應修 16 | 容量變更可撤回：`failSafe` 擋下時還原未答、淘汰項與失準；派發拋錯不套用上一筆紀錄；`blockSend` 不清先前同號未答 | PS-24、PS-27、PS-28 |
| 應修 17 | 設計、契約、Deviations 改寫偽造代號影響；選做項只做低成本的一次性代號，不做呼叫者檢查 | PS-25 |
| 建議 18 | 契約與設計揭露外層包裝遺失代號；三種包裝各一測試 | PS-26 |

### 先紅後綠

| 階段 | 結果 | log |
|---|---|---|
| 第四輪測試套在 `dd932a8` 的 JS | PS-23 紅（非守衛路注入取得 64000）、PS-24 紅（注入 `msgid_busy`）、PS-25 紅（重放被當注入，配對 0 筆）。PS-26 綠：它揭露的是現行行為 | `r4-red.log` |
| PS-27、PS-28 | 實作後補，殺存活變異 PS34 與新增的 PS35 | — |
| 實作後 | b2 204／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r4-final-*.log` |

### 變異

| 範圍 | 結果 | log |
|---|---|---|
| 本輪新增 PS26～PS35 | 10/10 殺 | `r4-mutate-new2.log`、`r4-mutate-full.log` |
| 全量 0–124 | 122/124；存活只有 U10、T7 | `r4-mutate-full.log` |

PS11（擋下不消耗遊戲未答）隨 `blockSend` 的 `gameDone` 移除；它在第一次全量時存活，因為還原已完整取代那一行。既有變異替換字串更新：N2、N3、X1、PS8、PS19、PS23。

### Swift

`JSContractTests`＋`PluginSendGuardTests` 19／0（`r4-test-targeted.log`），全量 `NakiTests` 1184／0（`r4-test-full.log`）。

### 第四輪 Deviations

1. **`last` 不還原**：第 16 條要求完整回復 `lost` 與淘汰項。`last` 是遊戲計數器的位置，被擋的請求雖沒上 wire，計數器已前進。還原 `last` 會讓窗口後退，較不保守，所以保留。
2. **偽造代號的實際影響**：任何頁面程式都能呼叫 `sendRaw`。傳假物件時以 Naki 自送登記進共用表，可覆寫遊戲同號配對，屬 D22 共用配對限制。包裝全域 `sendRaw` 能在呼叫期間取得真代號並冒用。對齊 U4 同 realm 信任模型，不宣稱防惡意。
3. **選做的呼叫者檢查不做**：同 realm 內 `sendRaw` 無法可靠分辨呼叫者，檢查只會給假保證。改做一次性代號，成本一行，只擋事後重放。
4. **外層包裝遺失代號只揭露不修**：主線裁決為揭露。改以 `data.buffer` 查表可修好 `new Uint8Array(buffer)` 那一種，但 `slice` 與漏傳仍無解，故一併揭露。
5. **復原紀錄的殘餘窗口**：紀錄在下一次派發入口清除。若遊戲連續兩次送同一 msgId，且第二次在派發前就出錯而由 `failSafe` 擋下，會套用第一次的紀錄。這需要遊戲重送同號又在派發前拋錯，未加測試。

### 第四輪已知風險

- 保留清單不分連線：任一連線派發中的號碼對所有連線都避開，只會更保守。
- 第二輪列的 live 前提仍未驗證：計數器步進、繞回、重連、陌生 msgId 回應的客戶端行為、回應順序。
- 未 live 驗證。
