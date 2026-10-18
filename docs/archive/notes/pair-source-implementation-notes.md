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
5. **（已被第五輪取代）復原紀錄的殘餘窗口**：紀錄在下一次派發入口清除。若遊戲連續兩次送同一 msgId，且第二次在派發前就出錯而由 `failSafe` 擋下，會套用第一次的紀錄。這需要遊戲重送同號又在派發前拋錯，未加測試。

### 第四輪已知風險

- 保留清單不分連線：任一連線派發中的號碼對所有連線都避開，只會更保守。
- 第二輪列的 live 前提仍未驗證：計數器步進、繞回、重連、陌生 msgId 回應的客戶端行為、回應順序。
- 未 live 驗證。

## 第五輪（Astra 第四輪 19～20 條；全採納）

審查原文：主 repo `.swfd/logs/pair-source-review/astra-review4.md`。main 仍在 `13abe49`，不需 rebase。第四輪 Deviations 採納，Deviation 5 由本輪根治。

### 做了什麼

- `naki-websocket.js`：`handleMessage` 在送出入口建立交易物件 `tx`，傳給 `dispatch`（`raw.tx`）與兩處 `failSafe`（第四參數）。Blob 的非同步派發也帶同一個 `tx`，但之後沒有 `failSafe`。
- `naki-plugins.js`：
  - 移除共用槽位 `gameUndo`。`dispatch` 把提交記在 `raw.tx.commit`，`failSafe` 只撤 `tx.commit`。交易物件隨 `handleMessage` 結束即釋放。
  - 未答 `inflight` 改為 Map：msgId → 提交紀錄 `{ msgId, prev, evicted, lostSet, version }`。每連線加 `version`，新增、消耗、撤回都遞增。
  - `revertGameSend(c)`：msgId 仍屬 `c` 才移除，有 `prev` 就放回。版本等於提交當時才放回淘汰項、清除失準，否則保守不回復。

| 條 | 處理 | 測試 |
|---|---|---|
| 擋 19 | 逐筆交易物件，dispatch 與 failSafe 經參數共用，無「最近一次」槽位 | PS-29（BEAT 真外送後同號 SKIN 派發前故障）、PS-30（第 257 筆編碼期間另一連線重入並拋錯） |
| 擋 20 | 只撤自己的增量；版本衝突不回復淘汰與失準 | PS-31（同線新增）、PS-32（同線消耗）、PS-33（同線容量）、PS-34（同號重入）、PS-35（先前同號提交放回）、PS-36（容量下消耗衝突） |

### 先紅後綠

| 階段 | 結果 | log |
|---|---|---|
| PS-29～PS-33 套在 `686b4af` 的 JS | 5 紅，皆為反例語意紅：PS-29、PS-31 注入取得 64000；PS-30 `msgid_busy`；PS-32 取 64001（已答號碼被快照帶回）；PS-33 失準被清掉 | `r5-red.log` |
| PS-34～PS-36 | 實作後補，殺新增變異 PS36、PS37、PS39 | — |
| 實作後 | b2 212／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r5-final-*.log` |

### 變異

| 範圍 | 結果 | log |
|---|---|---|
| 本輪新增 PS34、PS36～PS40，改寫 PS29～PS31 | 9/9 殺（另含 PS35 共 10/10） | `r5-mutate-new.log` |
| 全量 0–129 | 127/129；存活只有 U10、T7 | `r5-mutate-full.log` |

第四輪的 PS34（派發入口不清舊復原紀錄）隨共用槽位移除，改為「dispatch 不把提交記進交易」。PS2、PS23 替換字串隨程式更新。

### Swift

`JSContractTests`＋`PluginSendGuardTests` 19／0（`r5-test-targeted.log`），全量 `NakiTests` 1184／0（`r5-test-full.log`）。

### 第五輪 Deviations

1. **衝突判定以整條連線的版本為單位**：同一條連線上，提交與撤回之間只要有任何新增、消耗或撤回，就不回復淘汰與失準，即使變動與這筆無關。這是主線指定的保守處理，代價是極少見的重入情境會失準到連線關閉。
2. **自己的 msgId 撤回不看版本**：只看該號碼是否仍屬這筆提交，所以衝突時仍移除自己那筆，符合主線「只移除自己那筆」。
3. **交易物件不主動清空**：它是 `handleMessage` 的區域變數，送出結束即不可達，不另設清理。

### 第五輪已知風險

- 直接呼叫 `__nakiPlugins.dispatch`／`failSafe` 而不帶交易的程式，提交無法撤回，只會更保守。
- 未 live 驗證；第二輪列的計數器步進、繞回、重連、回應順序前提仍未驗證。

## 第六輪（Astra 第五輪 21～25 條；全採納）

審查原文：主 repo `.swfd/logs/pair-source-review/astra-review5.md`。main 仍在 `13abe49`，不需 rebase。第五輪 Deviations 採納。

### 做了什麼

- `naki-websocket.js`：
  - `ws.send` 包裝建立交易物件 `tx`，傳進 `handleMessage`（新增第七參數）。`originalSend` 拋錯時以 `sendSettled(tx, true)` 撤回並照拋原例外，其餘以 `sendSettled(tx, false)` 結束。結算本身的錯誤只記 log。
  - 遊戲的 Blob 送出在 `arrayBuffer()` 前呼叫 `blobSend(wsId, 1)`，派發或展開失敗後 `blobSend(wsId, -1)`。
- `naki-plugins.js`：
  - 未答表改存提交序號，不存紀錄物件。撤回資料只在 `openCommits`，由 `commitGameSend` 掛上交易，`sendSettled` 釋放。
  - `gameDone` 找不到號碼時，作廢進行中交易裡同號的淘汰項。
  - `revertGameSend` 只處理仍在 `openCommits` 的紀錄。放回先前同號提交時排到最新。
  - `failSafe` 照送時，交易已有派發的提交就不重複提交。
  - 有待展開的遊戲 Blob 時，`nextPluginMsgId` 回 null（`msgid_busy`）。
  - `diagnostics()` 新增 `gameInflight`、`openCommits`。

| 條 | 處理 | 測試 |
|---|---|---|
| 擋 21 | Blob 待展開期間拒發注入（選拒發，不排隊） | PS-37（無守衛大廳、有守衛對局連線） |
| 應修 22 | 交易期間被回答的淘汰項作廢 | PS-38 |
| 應修 23 | 撤回資料與未答分離，交易結束釋放 | PS-39、PS-43 |
| 應修 24 | 交易涵蓋底層 send，拋錯撤回後照拋；失敗交易不收晚到的 Blob 提交 | PS-40、PS-42 |
| 建議 25 | 放回先前提交不恢復原 FIFO 位置，文件寫明 | PS-41 |
| 文件 | 包裝公開 `dispatch` 可改寫交易，依 U4 不列阻擋，契約與設計寫明 | — |

### 先紅後綠

| 階段 | 結果 | log |
|---|---|---|
| PS-37～PS-41 套在 `ea86d74` 的 JS | 5 紅。PS-37、PS-38、PS-40 是行為紅：注入未被拒、`msgid_busy`、`msgid_busy`。PS-39、PS-41 只因新的量測欄位不存在而紅；拿掉量測斷言後只剩前三條紅，PS-41 的行為在舊版已成立，屬建議 25 的釘死測試 | `r6-red-on-ea86d74.log`、`r6-red-behavior-on-ea86d74.log` |
| PS-42、PS-43 | 實作後補，殺變異 PS46、PS48 | — |
| 實作後 | b2 219／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r6-final-*.log` |

### 變異

| 範圍 | 結果 | log |
|---|---|---|
| 本輪新增 PS41～PS48 | 8/8 殺 | `r6-mutate-new.log` |
| 全量 0–137 | 135/137；存活只有 U10、T7 | `r6-mutate-full.log` |

替換字串隨程式更新：PS9、PS23、PS34、PS36、PS37、PS39、PS40。

### Swift

`JSContractTests`＋`PluginSendGuardTests` 19／0（`r6-test-targeted.log`），全量 `NakiTests` 1184／0（`r6-test-full.log`）。

### 第六輪 Deviations

1. **（已被第七輪取代）Blob 拒發不分連線**：主線指示「該連線有 pending Blob」。注入配號時還不知道 `sendRaw` 會選哪條連線，所以任一連線有待展開的遊戲 Blob 就拒發，較保守。
2. **CONNECTING 拋錯的路徑未經真 WebKit 驗證**：PS-40、PS-42 用假 socket 在 `readyState === 0` 時拋 `InvalidStateError`。真 WebKit 在 CONNECTING 時是否同步拋錯、拋什麼，沒有 live 證據。
3. **可達紀錄數以診斷欄位量測**：測試無法走訪閉包，改以 `gameInflight`（未答）與 `openCommits`（撤回資料）兩個計數斷言。未答表的值是數字，不可能形成 `prev` 鏈。
4. **底層 send 拋錯時，`handleMessage` 已送給 Swift 的那一筆不收回**：本包只管插件層的未答記帳，Swift 端的觀察紀錄維持原樣。

### 第六輪已知風險

- Blob 送出頻繁的頁面，注入會在展開期間反覆收到 `msgid_busy`。現行 Unity 客戶端送出是 TypedArray，live 未觀察到遊戲 Blob 送出。
- 未 live 驗證；第二輪列的計數器步進、繞回、重連、回應順序前提仍未驗證。

## 第七輪（Astra 第六輪 26～30 條；主線裁決 Blob 連線不可信）

審查原文：主 repo `.swfd/logs/pair-source-review/astra-review6.md`。main 仍在 `13abe49`，不需 rebase。第六輪 Deviations 採納；Deviation 1 與 Blob 待展開計數器被本輪取代。

### 做了什麼

- `naki-websocket.js`：
  - `handleMessage` 在守衛拒送檢查之後、`try` 之前，看到遊戲的 Blob 送出就呼叫 `markUntrusted(wsId)`。
  - Blob 展開後先檢查 `wsConnections.has(ws)`，連線已釋放就丟棄（送出與接收兩方向）。之後以 `deferred` 派發；拋錯時不呼叫 `failSafe`。
  - 移除 `blobSend` 計數。
- `naki-plugins.js`：
  - `untrustedSockets` 取代 `blobSends`：`markUntrusted` 加入，`closed` 清除，任一連線不可信時 `nextPluginMsgId` 回 null。
  - `dispatch` 的遊戲判定排除 `raw.deferred`，所以 Blob 不保留號碼、不提交。
  - Blob 不再提交後，`commitGameSend` 的「交易已失敗／已結束」檢查與 `sendSettled` 的 `aborted`、`settled` 旗標成了死碼，一併移除。
  - `diagnostics()` 新增 `untrustedSockets`。
- `scripts/guard-gaps-mutate.cjs`：變異可用第三欄指定目標檔（預設 `naki-plugins.js`），本輪三個變異套在 `naki-websocket.js`。

| 條 | 處理 | 測試 |
|---|---|---|
| 擋 26 | 展開 reject 不解除：不可信只在關閉時清除 | PS-44（reject） |
| 擋 27 | Blob 不更新 `last`，窗口不會倒退 | PS-37（展開後不記帳） |
| 應修 28 | 非同步派發先確認連線未釋放 | PS-45 |
| 應修 29 | Blob 不提交，不會復活已答請求 | PS-37 |
| 建議 30 | 標記在入口同步完成，與展開成敗無關 | PS-44（同步拋錯） |
| 補測 | Blob 後注入 busy、關閉後新連線恢復、守衛拒送的 Blob 不標、展開後配對照常 | PS-37 |

第六輪的 PS-37（展開後恢復配號）依裁決改寫，PS-42（CONNECTING 的 Blob 不補提交）因 Blob 不再提交而刪除。

### 先紅後綠

| 階段 | 結果 | log |
|---|---|---|
| PS-37、PS-44、PS-45 套在 `752bb3b` 的 JS | 3 紅。先遇到新診斷欄位不存在；拿掉 `untrustedSockets` 斷言後仍 3 紅，皆為行為紅：展開後注入恢復、reject 後注入恢復、舊連線角色被重建為 lobby | `r7-red-on-752bb3b.log`、`r7-red-behavior-on-752bb3b.log` |
| 實作後 | b2 220／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r7-final-*.log` |

### 變異

| 範圍 | 結果 | log |
|---|---|---|
| 本輪新增 PS49～PS55 | 7/7 殺 | `r7-mutate-full.log` |
| 全量 0–140 | 138/140；存活只有 U10、T7 | `r7-mutate-full.log` |

刪除 PS41、PS42（計數器）、PS46、PS47（晚到提交，程式已移除）。PS9、PS45 替換字串隨程式更新。

### Swift

`JSContractTests`＋`PluginSendGuardTests` 19／0（`r7-test-targeted.log`），全量 `NakiTests` 1184／0（`r7-test-full.log`）。

### 第七輪 Deviations

1. **（已被第八輪撤回）延後派發拋錯不走 `failSafe`**：Blob 早已外送，`failSafe` 沒有可擋的送出，原本只會照送路徑替它補記帳。原說法「harness 無法讓延後派發本身拋錯」不成立：observer 的 `onSend` getter 拋錯即可，第八輪已補 PS-48 與變異 PS62。
2. **底層 send 拋錯的 Blob 仍標不可信**：標記在送出前完成，送出失敗不撤回標記，較保守。
3. **接收方向的 Blob 也套用釋放檢查**：主線要求「所有非同步派發」，D22 的已答標記也在檢查之後，關閉後不再寫入。

### 第七輪已知風險

- 若客戶端改用 Blob 送出，該連線存在期間所有注入都回 `msgid_busy`，需另開包做可信配號。
- 未 live 驗證；第二輪列的計數器步進、繞回、重連、回應順序前提仍未驗證。

## 第八輪（Astra 第七輪 31～33 條；全採納）

審查原文：主 repo `.swfd/logs/pair-source-review/astra-review7.md`。main 仍在 `13abe49`，不需 rebase。第七輪 Deviations 採納，Deviation 1 由第 33 條撤回。

### 做了什麼

- `naki-plugins.js`：
  - 遊戲提交與配對共用序號 `gameSeq`。`pendingMethods` 的值改為 `{ method, seq }`。
  - 新增 `watermark()` 回傳目前序號，以及 `newerThan(watermark, seq)`。
  - `gameDone`、暫時淘汰項作廢、`resolveMethod`、零消耗者的配對消耗都帶 `raw.watermark`：比水位新的不消耗。沒有水位（同步派發）時行為不變。
- `naki-websocket.js`：
  - 接收 Blob 抵達時同步取水位，展開後以 `{ watermark }` 延後派發。
  - `ws.send` 入口：連線不在 `wsConnections` 就直接 `originalSend`，不標記、不記帳。
- `scripts/plugin-v2-b2-regression.cjs`：harness 補 `FileReader` 模型。`blobToBase64` 讀原型的 `arrayBuffer`，不受測試替換的展開影響。以前缺 `FileReader` 時，每個 Blob 送出都會在同步轉碼拋錯、多走一次 `failSafe`，與延後派發的例外混在一起。

| 條 | 處理 | 測試 |
|---|---|---|
| 擋 31 | 延後回應只消耗水位以下的未答、淘汰項與配對 | PS-46（有消耗者，含 payload 區分）、PS-49（零消耗者） |
| 應修 32 | `ws.send` 入口排除已釋放連線；§1.4 第 4 項改寫 | PS-47 |
| 建議 33 | Dev 1 撤回；補延後派發拋錯回歸與變異；harness 補 FileReader | PS-48 |

### 先紅後綠

| 階段 | 結果 | log |
|---|---|---|
| PS-46～PS-48 套在 `db788ea` 的 JS | PS-46、PS-47 紅，皆為行為紅：INFO 未答被晚到回應消耗（1→0）、已釋放連線留下不可信標記。PS-48 綠：舊版已有 `!deferred`，這條是回歸，由變異 PS62 驗有效 | `r8-red-on-db788ea.log` |
| PS-49、PS-46 的 payload 斷言 | 實作後補，殺變異 PS57、PS59 | — |
| 實作後 | b2 224／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r8-final-*.log` |

### 變異

| 範圍 | 結果 | log |
|---|---|---|
| 本輪新增 PS56～PS62 | 7/7 殺 | `r8-mutate-new.log` |
| 全量 0–147 | 145/147；存活只有 U10、T7 | `r8-mutate-full.log` |

替換字串隨程式更新：BB1、BB2、BB4、AA2、AA3、Z1、PS6、PS10、PS39、PS43。

### Swift

`JSContractTests`＋`PluginSendGuardTests` 19／0（`r8-test-targeted.log`），全量 `NakiTests` 1184／0（`r8-test-full.log`）。

### 第八輪 Deviations

1. **（已被第九輪撤回）水位不套用在注入登記與歧義標記**：Astra 第八輪第 34 條證明避號前提不成立：注入可在 Blob 抵達後、展開前取得同號。原說明：注入配號會避開遊戲未答與未答注入，水位以下的同號注入不會在 Blob 抵達後新建。歧義標記只在注入回應時建立，同理。
2. **延後回應遇到較新配對時方法對不回**：BEAT 的回應若晚於同號 INFO 送出才展開，BEAT 的配對已被 INFO 覆寫，這則回應以無方法派發。這是 D22 同鍵覆寫的既有限制，本輪只保證不消耗 INFO。（第九輪補明：無方法派發＝鏈為空，不派任何一般 hook，也無 `replace`。但第八輪時它仍會先消耗同鍵歧義鍵與注入登記；第九輪改為「未匹配延後回應」統一處理，不再消耗任何紀錄。）

### 第八輪已知風險

- 水位只涵蓋接收方向的 Blob。同步派發的 RESPONSE 不帶水位，依現行順序消耗。
- 未 live 驗證；第二輪列的計數器步進、繞回、重連、回應順序前提仍未驗證。

## 第九輪（Astra 第八輪 34～35 條；主線裁決：水位統一套所有可消耗紀錄）

審查原文：主 repo `.swfd/logs/pair-source-review/astra-review8.md`。main 仍在 `13abe49`，不需 rebase。第八輪 Deviation 1 撤回，Deviation 2 補明。

### 做了什麼

- `naki-websocket.js`：
  - 新增 `nextSeq()`，遞增 D22 的 `nakiSentSeq`。
  - 接收 Blob 的水位改用既有的 `arrivedAtSeq`，與 D22 已答標記同一個值。移除插件層的 `watermark()`。
- `naki-plugins.js`：
  - 所有可消耗紀錄都以 `nextSeq()` 蓋序號：遊戲提交、配對、注入代號（`token.seq`）、歧義鍵（`ambiguousPairs` 改為 Map）。沒有 websocket 時退回本地計數，只在不載入 websocket 的 harness 出現。
  - `injectionFor(key, wm)`、`pairWaiting(key, wm)`、`consumeAmbiguous(socketId, key, wm)` 三個函式各自包含水位判定。`dispatchRaw` 的遊戲未答消耗、零消耗者分支與 `runChain` 都經由它們。
  - 未匹配延後回應在 `runChain` 走到方法為 null，鏈為空，不派任何 hook。

| 條 | 處理 | 測試 |
|---|---|---|
| 擋 34 | 注入登記蓋序號，延後回應只認領抵達前的；零消耗者分支同樣 | PS-50（兩路）、PS-52 |
| 擋 35 | 歧義鍵蓋序號，消耗與水位判定在同一函式 | PS-51 |
| Dev 2 補明 | 無方法派發＝不派 hook；改為未匹配延後回應統一處理 | PS-50、PS-51 |

### 先紅後綠

| 階段 | 結果 | log |
|---|---|---|
| PS-50、PS-51 套在 `185b94e` 的 JS | 2 紅，皆為行為紅：注入登記被舊 Blob 認領（1→0）、真 INFO 回應取得改寫權 | `r9-red-on-185b94e.log` |
| PS-52 | 實作後補，殺變異 PS66 | — |
| 實作後 | b2 227／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r9-final-*.log` |

### 變異

| 範圍 | 結果 | log |
|---|---|---|
| 本輪新增 PS63～PS67 | 5/5 殺 | `r9-mutate-new.log` |
| 全量 0–151 | 149/151；存活只有 U10、T7 | `r9-mutate-full.log` |

替換字串隨程式更新：BB1、BB2、BB4、PS6、PS10、PS13、PS18、PS21、PS22、PS58、PS60。PS59 與新增的 PS67 改動同一行，刪除 PS59。

### Swift

`JSContractTests`＋`PluginSendGuardTests` 19／0（`r9-test-targeted.log`），全量 `NakiTests` 1184／0（`r9-test-full.log`）。

### 第九輪 Deviations

1. **D22 身分查詢不帶水位**：`isNakiSent` 曾加上第四參數 `maxSeq`，後來移除，因為觀察不到差異。延後回應要走到 `isNaki` 判定，必須先匹配到抵達前的配對或注入；而同鍵在抵達後若有新的 D22 登記，`sendRaw` 的派發一定先覆寫或撤銷那筆配對，回應就成了未匹配。D22 的已答標記原本就用 `arrivedAtSeq`。
2. **未匹配延後回應沒有另寫分支**：主線要求「只給 observeNakiTraffic 觀察」。它的方法為 null，而所有 observer 都以方法白名單過濾，所以實際上沒有任何 hook 收到它。另寫提早 return 是等價程式，會留下存活變異，所以不寫。
3. ~~**整條連線的歧義不看水位**：容量溢出後整條連線都算歧義，延後回應也一律算歧義（只觀察），不消耗任何東西，較保守。~~ 第十輪依 38 條改述：不消耗的只有整條歧義旗標本身，其他匹配紀錄照常消耗，注入回派優先於一般 observer 分流（見第十輪）。

### 第九輪已知風險

- 水位只涵蓋接收方向的 Blob；同步派發的 RESPONSE 依現行順序消耗。
- 未 live 驗證；第二輪列的計數器步進、繞回、重連、回應順序前提仍未驗證。

## 第十輪（Astra 第九輪 36～38 條；主線裁決：接收依抵達順序排隊處理）

第九輪 Dev 1、Dev 2 經 Astra 證實成立；Dev 3 依 38 條改述（見上）。

### 做了什麼

- `naki-websocket.js`：
  - 連線紀錄新增 `recvQueue`。`handleMessage` 對接收方向：Blob 一律入隊；佇列非空時 ArrayBuffer／TypedArray 也入隊（`enqueueReceive`）。佇列為空時同步封包照舊同步處理。
  - 入隊時同步記水位（`nakiSentSeq`）。同步封包先複製 bytes、標為就緒，再做暱稱遮罩與送 Swift；這兩步拋錯不卡佇列。
  - Blob 展開完成、reject 或同步拋錯都會設就緒（失敗時沒有 bytes），再呼叫 `flushReceive`：從隊首依序處理已就緒項，隊首未就緒即停。沒有 bytes 的項目略過（未匹配，不派）。Blob 項目在處理時才補 D22 已答標記。處理一律走延後派發（不可改寫、帶水位）。`flushing` 旗標防重入，重入時由外層迴圈接手。
  - `release` 清空佇列。原本 Blob 分支只剩送出方向（及已釋放連線上的接收），不再帶接收水位。
- `naki-plugins.js`：`markAmbiguous` 記所保護配對的序號（`pendingMethods.get(key).seq`），兩個呼叫點都已先確認配對在等。

| 條 | 處理 | 測試 |
|---|---|---|
| 擋 36 | 每連線接收佇列，認領順序＝抵達順序；水位保留 | PS-53（混合、雙 Blob 逆序）、PS-50、PS-51（改寫）、PS-55、PS-56、PS-57、PS-58 |
| 應修 37 | 歧義標記綁配對世代 | PS-54；PS-51 在只有佇列、沒有世代時也紅 |
| 應修 38 | Dev 3 改述；契約同步 | 文件 |
| 文件 | 序號頁面共用、重連不歸零、重載歸零、2^53 理論極限 | 設計「前提與未驗證」 |

### PS-50、PS-51 改寫

兩條原本編碼的是「舊 Blob 待展開時，後到的同步回應先被處理」，佇列後這個時序不再可能。改為斷言佇列下的等價結果：後到的回應排在 Blob 之後，INFO 未答期間注入避開 64000；展開後依序處理，舊 Blob 不認領任何紀錄。第九輪「舊 Blob 不認領之後才建立的注入」改由 PS-58 以重複回應情境覆蓋。

### 先紅後綠

| 階段 | 結果 | log |
|---|---|---|
| PS-50～PS-58 套在 `1b2c83e` 的 JS | 6 紅（PS-50、51、53、54、55、56），皆為行為紅：同步回應先認領注入、尾值錯派、未排隊。PS-52、PS-57、PS-58 綠：PS-52 是既有行為，PS-57 守 PS74 變異，PS-58 守水位 | `r10-red-old.log` |
| 只有佇列、`naki-plugins.js` 仍是 `1b2c83e` | PS-51、PS-54 紅（歧義標記用新序號），其餘綠 | `r10-red-queue-only.log` |
| 實作後 | b2 233／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r10-{b2,v2,p4,keepalive,plugin-regression,local-unlock}.log` |

### 變異

| 範圍 | 結果 | log |
|---|---|---|
| 本輪新增 PS68～PS74 | 7/7 殺 | `r10-mutate-new.log` |
| PS60 改寫（排隊接收不取水位） | 殺 | `r10-mutate-ps60.log` |
| 全量 0–157 | 155/157；存活只有 U10、T7 | `r10-mutate-full.log` |

新增：PS68 同步封包不排隊、PS69 依展開順序派發、PS70 歧義標記用新序號、PS71 reject 卡佇列、PS72 同步拋錯卡佇列、PS73 釋放不丟佇列、PS74 送 Swift 後才就緒。PS60 字串隨程式更新。PS64 移除（見 Deviation 1）。

### Swift

`JSContractTests`＋`PluginSendGuardTests` 19／0（`r10-swift-targeted.log`），全量 `NakiTests` 1184／0（`r10-swift-full.log`）。

### 第十輪 Deviations

1. **`consumeAmbiguous` 的水位比較保留，但變異 PS64 移除**：有接收佇列後，任何回應處理時看得到的歧義標記，都由比它先抵達的回應（或抵達前的同步回應）建立。標記記的配對世代不大於建立它那則回應的水位，也就不大於後抵達回應的水位，所以比較必定成立，PS64 是等價變異。裁決要求以世代比水位，保守起見保留比較，只移除無法殺死的變異。
2. **排隊的同步封包只能觀察**：它抵達時已交給遊戲，延後處理時無法改寫，所以不給 `replace`、變長改寫或 drop。只在同一連線混用 Blob 與同步封包時發生；Unity 客戶端 live 未觀察到 Blob 接收。
3. **flush 不另查連線是否仍在**：`release` 清空佇列，之後才就緒的 Blob 項目已不在佇列；檢查會是死碼，所以不寫。PS-56 與變異 PS73 守住清空。

### 第十輪已知風險

- Swift 端收到 Blob 的順序仍可能晚於後到的同步封包（`blobToBase64` 非同步），不在本包範圍。
- ~~隊首 Blob 永遠不 settle 時，該連線之後的接收全部排隊、插件收不到，直到連線關閉。瀏覽器的 `Blob.arrayBuffer()` 必定 settle，只有頁面替換它時才可能。~~ 第十一輪撤回（42 條）：File API 沒有完成期限，「必定 settle」不是已驗證前提；改以佇列容量 256 界定。
- 未 live 驗證；計數器步進、繞回、重連、回應順序前提仍未驗證。

## 第十一輪（Astra 第十輪 39～42 條；主線裁決全採納）

第十輪 Deviations 經 Astra 核對採納。

### 做了什麼

- `naki-plugins.js`：
  - 新增 `receiveLost(socketId)`：標記不可信（拒發新注入）與接收不可信（`recvLostSockets`）；該連線既有注入登記全部以 `ctx.error = 'response_lost'`、空 bytes 交回發起插件並清空。
  - `runChain` 的 `isNaki` 加上「RESPONSE 且連線接收不可信」，所以只給 Naki observer、沒有 `replace`；配對、未答照常消耗。注入認領不另擋：登記已清空、之後拒發，認領不到。
  - `closed` 清除接收不可信；`diagnostics().receiveLost` 為數量。
- `naki-websocket.js`：
  - 入隊條件加上 `info.flushing`（第 40 條）。flush 迴圈本身會接著處理重入入隊的項目，不需另掃。
  - 讀取失敗的項目記 `failed`；flush 處理到它時呼叫 `receiveLost`（在佇列中的位置生效，前面已處理的不受影響）。
  - 同步封包：先遮罩、再快照、再就緒；遮罩拋錯時以遮罩前複製的原內容快照並記 log（第 41 條）。送 Swift 在就緒之後，拋錯照舊由 `handleMessage` 記 log。
  - 佇列超過 256 項：`receiveLost`、所有未就緒項目改為就緒且無內容（放棄），再 flush。放棄的 Blob 之後才完成時，它已不在佇列，不派發。容量檢查放在 `finally`，送 Swift 拋錯也照樣檢查。
  - 每項記抵達時間；`__nakiWebSocket.diagnostics().recvQueue` 列出每條非空佇列的 `socketId`、`length`、`headWaitMs`。

| 條 | 處理 | 測試 |
|---|---|---|
| 擋 39 | 讀取失敗＝接收不可信：既有注入 `response_lost`、之後回應只觀察、拒發新注入 | PS-59（reject、同步拋錯）、PS-55（改寫） |
| 應修 40 | flush 中入隊 | PS-60 |
| 應修 41 | 遮罩後快照；遮罩拋錯以原內容快照 | PS-61（正常、遮罩拋錯） |
| 建議 42 | 撤回 settle 前提；`recvQueue` 診斷；超過 256 視同 39；不設時間逾時 | PS-62 |

PS-55 改寫：第十輪斷言「失敗項以未匹配處理、之後恢復一般鏈」，與 39 條相反；改為斷言接收不可信。

### 先紅後綠

| 階段 | 結果 | log |
|---|---|---|
| PS-55～PS-62 套在 `b1fefec` 的 JS | PS-55、59、60、61、62 紅；PS-62 含診斷欄位缺少的形式紅 | `r11-red-on-b1fefec.log` |
| 同上，刪去診斷斷言 | 同五條紅，皆為行為紅：失敗後回應進一般鏈或交給注入者、重入繞過佇列、插件拿到遮罩前內容、溢出不處理。PS-56～58 為既有守門測試，綠 | `r11-red-behavior-on-b1fefec.log` |
| 實作後 | b2 237／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r11-{b2,v2,p4,keepalive,plugin-regression,local-unlock}.log` |

### 變異

| 範圍 | 結果 | log |
|---|---|---|
| PS68～PS84（含本輪新增 PS75～PS84 十個） | 17/17 殺 | `r11-mutate-new.log` |
| 全量 0–167 | 165/167；存活只有 U10、T7 | `r11-mutate-full.log` |

替換字串隨程式更新：PS15、PS68、PS74。全量第二段 PS15 先報過期，更新後單獨補跑已殺（同一 log 末段）。

### Swift

`JSContractTests`＋`PluginSendGuardTests` 19／0（`r11-swift-targeted.log`），全量 `NakiTests` 1184／0（`r11-swift-full.log`）。

### 第十一輪 Deviations

1. ~~**`runChain` 不另擋接收不可信連線的注入認領**：~~ 第十二輪撤回（Astra 43 條證明不成立：在途注入在 `sendRaw` 期間連線轉為接收不可信，返回後仍會登記）。原文：`receiveLost` 已清空該連線注入登記，且同時標記不可信，之後 `nextPluginMsgId` 一律回 null，所以不會再有可認領的登記。另寫判斷是死碼，變異殺不掉。
2. **放棄項的晚到完成不另設守衛**：放棄時項目已就緒，下一次 flush 就移出佇列；之後才完成只改到已移出的物件，不派發。
3. ~~**NOTIFY 不套「只觀察」**：~~ 第十二輪依 45 條改為 NOTIFY 也只觀察，理由見第十二輪。原文：裁決寫的是「回應」；NOTIFY 沒有配對或注入可認領，歸屬不受讀取失敗影響。

### 第十一輪已知風險

- 接收不可信會讓整頁注入回 `msgid_busy` 直到該連線關閉（沿用 `untrustedSockets` 的全域效果）。
- `response_lost` 時請求可能已被伺服器處理，結果未知；插件須自行處理。
- 容量 256 是啟發式；`headWaitMs` 沒有 live 數據。
- Swift 端收到 Blob 的順序仍可能晚於後到的同步封包，不在本包範圍。
- 未 live 驗證。

## 第十二輪（Astra 第十一輪 43～45 條；主線裁決全採納）

第十一輪 Dev 1 撤回（43 條反例），Dev 2 經 Astra 核對成立，Dev 3 依 45 條改寫。

### 做了什麼

- `naki-plugins.js`：
  - 抽出 `injectionLost(socketId, msgId, injection)`，`receiveLost` 與 `sendRequest` 共用。
  - `sendRequest`：`sendRaw` 成功後、登記之前，若該連線已接收不可信，不登記，回 `ok:true` 與 msgId，以 `Promise.resolve().then` 在下一個 microtask 呼叫 `injectionLost`（第 43 條）。
  - `injectionFor`：鍵所屬連線接收不可信時一律回 undefined（防線）。一般鏈認領、零消耗者分支與遊戲未答消耗都經過它，所以遊戲未答在接收不可信時照常消耗。
  - `runChain` 的接收不可信條件從「RESPONSE」改為「接收方向」，NOTIFY 也當成 Naki 流量（第 45 條），因此沒有 `replace`、`drop` 與變長改寫。
- `naki-websocket.js`：排隊同步封包遮罩拋錯時 `view.set(original)` 還原共享內容，再以原內容快照（第 44 條）。

| 條 | 處理 | 測試 |
|---|---|---|
| 擋 43 | 登記前檢查、microtask 結案；認領入口防線 | PS-63（讀取拋錯、第 257 項） |
| 應修 44 | 還原共享 view | PS-61 新增「改後拋錯」 |
| 建議 45 | NOTIFY 也只觀察；揭露狀態可能不完整、恢復＝重連 | PS-64；設計、契約 |

### 先紅後綠

| 階段 | 結果 | log |
|---|---|---|
| PS-61～PS-64 套在 `726ca07` 的 JS | PS-61（改後拋錯：遊戲 `P1   ` 與插件 `Alice` 分歧）、PS-63（登記 1）、PS-64（一般 hook 收到失敗後的 NOTIFY）紅，皆為行為紅；PS-62 既有，綠 | `r12-red-on-726ca07.log` |
| 實作後 | b2 239／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r12-{b2,v2,p4,keepalive,plugin-regression,local-unlock}.log` |

### 變異

| 範圍 | 結果 | log |
|---|---|---|
| PS75～PS89（含本輪新增 PS85～PS89）與更新字串的 PS15 | PS89 存活，其餘全殺；本輪新增計入的 PS85～PS88 4/4 殺 | `r12-mutate-new.log` |
| 全量 0–171（PS89 不列入） | 169/171；存活只有 U10、T7 | `r12-mutate-full.log` |

替換字串隨程式更新：PS15、PS76、PS77。

### Swift

`JSContractTests`＋`PluginSendGuardTests` 19／0（`r12-swift-targeted.log`），全量 `NakiTests` 1184／0（`r12-swift-full.log`）。

### 第十二輪 Deviations

1. ~~**認領入口防線保留，但變異 PS89 不列入**：~~ 第十三輪改述：「登記與回傳之間沒有插件程式碼可重入」不成立。復驗證明 `token.seq = nextSeq()` 經可包裝的 `window.__nakiWebSocket.nextSeq` 可在檢查之後、登記之前重入（`verify-pair-source/cx1-*`）。第十三輪把取序號移到檢查之前。原文：裁決要求 `injectionFor` 加防線。現行能建立注入登記的只有 `sendRequest`；它在登記前已檢查接收不可信，`receiveLost` 也清空既有登記，登記與回傳之間沒有插件程式碼可重入。所以接收不可信連線上不存在可認領的登記，防線不可達。試跑 PS89 存活（`r12-mutate-new.log`）。保守起見保留程式碼，只把變異從清單移除，以維持「全量存活只 T7／U10」。若主線認為防線應可測，需要另一條登記入口才測得到。
2. **在途注入結案用 microtask**：裁決允許同步或下一 tick。同步呼叫會讓插件在 `sendRequest` 回傳 msgId 之前就收到結案，對不上自己的請求，所以延到下一個 microtask。期間插件若已停用，就不回派（與 `receiveLost` 相同）。

### 第十二輪已知風險

- 接收不可信後 NOTIFY 也不能改寫，依賴改寫 NOTIFY 的插件在該連線關閉前失效（保守取捨）。
- 讀取失敗後插件狀態可能不完整，只能靠重連恢復；Naki 不主動重連。
- 未 live 驗證。

## 第十三輪（復驗回饋小修；主線裁決四項）

### 做了什麼

- `naki-plugins.js`：
  - `sendRequest`：`token.seq = nextSeq()` 移到接收不可信檢查之前；檢查之後到登記之間不再呼叫任何可被包裝的外部函式（第 1 項）。
  - 注入登記超過 256 筆時，被淘汰那筆在下一個 microtask 以 `response_lost`、`reason: 'evicted'` 結案（第 3 項）。為此登記時在代號上記 `socketId` 與 `msgId`。
  - `injectionLost` 增加 `reason` 參數；接收不可信結案的 `reason` 是 `receive_untrusted`。
- 文件：
  - 契約「代號不防惡意」段把 `nextSeq` 與 `sendRaw`、`dispatch` 並列（第 2 項）。
  - 契約補上 `reason` 的兩個值與淘汰結案。
  - Astra 第十二輪第 46 條（接收不可信後一般插件無從得知退化，建議提供帶 socketId、原因與恢復提示的狀態事件）列為後續另案，寫進 `plugin-v2-b2.md` §1.4 第 5 項殘餘（第 4 項）。

| 項 | 處理 | 測試 |
|---|---|---|
| 1 | 先取序號再檢查 | PS-65（復驗 cx1 情境） |
| 2 | 契約 | — |
| 3 | 淘汰以 `response_lost`／`evicted` 結案 | PS-66 |
| 4 | 第 46 條列為後續另案 | — |

### 先紅後綠

| 階段 | 結果 | log |
|---|---|---|
| PS-65、PS-66 套在 `5a95ffc` 的 JS | 2 紅，皆為行為紅：nextSeq 重入後仍登記（1）、淘汰無回呼 | `r13-red-on-5a95ffc.log` |
| 實作後 | b2 241／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r13-{b2,v2,p4,keepalive,plugin-regression,local-unlock}.log` |

### 變異

| 範圍 | 結果 | log |
|---|---|---|
| PS85～PS92（含 PS89 與本輪新增 PS90～PS92） | PS89 存活，其餘全殺；PS90～PS92 3/3 殺；PS86 字串更新後補跑已殺 | `r13-mutate-new.log` |
| 全量 0–174（PS89 不列入） | 172/174；存活只有 U10、T7 | `r13-mutate-full.log` |

### Swift

`JSContractTests`＋`PluginSendGuardTests` 19／0（`r13-swift-targeted.log`），全量 `NakiTests` 1184／0（`r13-swift-full.log`）。

### 第十三輪 Deviations

1. **PS89 仍殺不掉，未放回清單**：裁決要求放回並確認殺掉，實跑後存活（`r13-mutate-new.log`）。原因：取序號移到檢查之前以後，檢查到登記之間沒有外部呼叫，接收不可信連線上不會再出現注入登記；`receiveLost` 也會清空既有登記，連登記後 `pluginLog` 經 `sendToSwift` 的重入也一樣被清掉。認領入口的防線因此再度不可達。殺得掉的唯一方法是讓登記能在不可信連線上留存，那正是第 1 項要消除的缺陷。保守起見保留防線程式碼，PS89 不列入，由主線裁決。
2. **`reason` 也給 `receive_untrusted`**：裁決只要求淘汰帶原因。兩種結案共用 `response_lost`，只在其中一種帶原因會讓插件無從分辨，所以兩種都帶。

### 第十三輪已知風險

- 包裝 `nextSeq` 的同 realm 程式可竄改序號，影響水位判定；屬 U4 不防範圍，已寫進契約。
- 接收不可信後一般插件沒有退化通知，見第 46 條後續另案。
- 未 live 驗證。
