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
4. **拿掉兩個冗餘判斷**。注入登記不納入避號：輪一圈 1501 號，注入登記上限 256，被淘汰前不會輪回。`blockSend` 不特判注入：同號遊戲配對已被避開，撤銷只會撤到空鍵。實作中曾加過「注入本身不算遊戲號碼」的位元比對，變異 PS8（舊編號）存活，原因是注入經 `sendRaw` 已登記為 Naki、被 `isNakiSent` 排除，於是刪掉。
5. **`msgid_busy`**：避號上限 512 個（配對 256＋窗口 256），小於號段 1501 個，找不到的分支不可達，沒有測試、沒有變異。

## 已知風險

- 窗口 256 是啟發式。遊戲在一次注入往返內送超過 256 筆，或注入一直沒回應，遊戲仍可能走到注入未答的號碼。這時配對各自正確：第一則 RESPONSE 歸注入，下一則對回遊戲方法（PS-4）。遊戲那筆依 D22 算 Naki，若是守衛方法會被 `naki_traffic` 擋下。遊戲層也可能把注入的回應當成自己的，這是協定層同號，未處理。
- 回應順序假設：同號的兩則 RESPONSE 依送出順序抵達。伺服器若亂序，注入與遊戲會互換，未驗證。
- Naki 自送（60000–63999）與遊戲之間沒有隔離（D22 範圍）。
- 遊戲計數器的繞回點未知。若繞回點低於 64000，遊戲永遠不進插件號段，窗口無作用也無害。
- 未 live 驗證。
