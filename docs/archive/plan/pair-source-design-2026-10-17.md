# pair-source：跨來源 msgId 配對隔離（設計，2026-10-17）

基準 main `13abe49`。只改 `command/Resources/JavaScript/naki-plugins.js`；`naki-websocket.js` 不需要改。

## 問題

配對表 `pendingMethods` 以 (連線, msgId) 為鍵，遊戲、Naki 與插件注入共用（D22）。插件注入的號碼由 `nextPluginMsgId()` 在 64000–65500 依序輪用，不看遊戲。遊戲 msgId 計數器全域遞增，會進這個號段（`d22-naki-identity.md` live 事實）。碰撞有兩種：

- **甲：遊戲先送、注入後撞號**。遊戲 INFO#64000 未答時注入拿到 64000：
  - 注入被擋時，`blockSend` 依鍵撤銷，遊戲那筆配對消失，它的 RESPONSE method 變 null（`GG11-4` 舊版固定此行為）。
  - 本地錯誤回應以 64000 派給遊戲，遊戲可能把它當成自己 INFO 的回應。
  - 注入沒被擋時，注入覆寫配對，遊戲的 RESPONSE 先到就被 `injectedMsgIds` 認成注入回應，交給 `onInjectResponse`。
- **乙：注入先送、遊戲後撞號**。遊戲計數器走到注入未答的號碼時，遊戲的 `remember` 覆寫注入配對：注入回應被派成遊戲的方法，遊戲回應對不回 method（`PS-4` 修前實測：`[[64000, fetchCharacterInfo]]`）。

前提修正：派工單寫「遊戲永不看到注入的 RESPONSE，因為 D22 已把 Naki 自送回應攔下」。`naki-websocket.js` 的接收路徑沒有攔下 Naki 回應的程式，網路回應與本地錯誤回應都會派給遊戲（`respondLocal` 以 `ws.dispatchEvent` 交付）。所以「改寫號碼、回來再還原」的方案擋不住遊戲層的碰撞，號碼本身必須避開。

## 方案

1. **配發避號**（解甲，降低乙的機率）。`nextPluginMsgId()` 從輪用指標往後找第一個可用號碼。下列號碼不可用：
   - 任一連線上有未答配對（注入彼此不撞：輪一圈 1501 號，注入登記上限 256）。
   - 落在遊戲計數器下一段 `GAME_AHEAD = 256` 內，即 `0 < (id − 遊戲最後 REQUEST msgId) mod 65536 ≤ 256`。

   遊戲最後號碼在 `dispatch` 記錄，只記不在 `sendRaw` 未答登記內的 REQUEST（Naki 自送與插件注入都先經 `sendRaw` 登記）。不可用號碼最多 256＋256＝512 個，號段有 1501 個，一定找得到。仍保留有界迴圈，找不到時回 `{ok:false, reason:'msgid_busy'}`，這條路不可達。
2. **注入配對與遊戲分開**（解乙的派錯）。注入請求不寫 `pendingMethods`；注入被擋時 `blockSend` 照舊依鍵撤銷，但同號遊戲配對已被避開，撤到的只會是空鍵。注入的方法存進注入登記，值改成 `{ id, method }`。RESPONSE 先比對注入登記，命中就以注入自己的方法交給發起插件，只消耗注入登記，不碰遊戲配對。注入登記的鍵是 (連線, msgId)，同鍵的第一則 RESPONSE 歸注入，依送出順序：注入在前才會走到這裡，因為甲已被避號排除。
3. **關閉連線清注入登記**。`closed(socketId)` 比照配對清掉該連線的注入登記。新增唯讀 `diagnostics().pendingInjections`。

## 取捨

- 不採「宿主改寫 msgId、回來還原」：遊戲看得到所有回應（見前提修正），沒有遊戲保證不用的號段，改寫只是多一層對照表。
- 不採「每鍵排隊」：同一來源依序重用 msgId 時舊配對要清掉（契約、`GG11-1b`），排隊會改變它。分來源只需要兩個槽：遊戲＋Naki 一個，注入一個。
- 窗口 256 是啟發式。遊戲在一次注入往返內送超過 256 筆，或注入永遠沒回應，乙仍可能發生。發生時配對仍各自正確，只剩 D22 的身分誤認（下節）。

## 不做什麼

- 不改 D22 身分語意：遊戲在注入未答的同號送請求時，仍依 `isNakiSent` 算 Naki（契約「REQUEST 在途碰撞」）。不改守衛判定，不改遊戲請求的 bytes（I2），不新增外送內容。
- 不處理 Naki 自送（60000–63999）與遊戲的碰撞，那是 D22 範圍。
- 不實作注入回應逾時。
- 不改 Swift。避號讓 Swift `LiqiParser.pendingRequests` 與 `nakiNicknameMask.pendingMethods`（只以 msgId 為鍵）的同號覆寫也一併不發生，這是附帶效果，不另驗。

## 測試矩陣（`scripts/plugin-v2-b2-regression.cjs`）

| 測試 | 情境 | 修前 |
|---|---|---|
| GG11-4／PS-1 | 遊戲 INFO#64000 未答，注入 SKIN 被擋：注入號碼不是 64000，本地錯誤帶注入號碼，INFO 回應仍對回 INFO | 紅：注入拿到 64000 |
| PS-2 | 遊戲與注入同時各一筆未答，回應反序抵達，各自派對 | 紅：注入拿到 64000 |
| PS-3 | 遊戲在 63999，連續注入兩筆避開遊戲下一段，遊戲接著送 64000、64001 各自派對 | 紅：注入拿到 64000 |
| PS-4 | 強制乙：遊戲重用注入未答號碼。第一則回應以注入方法交給注入插件，第二則對回遊戲方法（D22 下只有 Naki observer 看得到） | 紅：注入回應被派成 INFO |
| PS-5 | 關閉連線清注入登記；重連後舊號碼的回應不交給任何人，新注入正常往返 | 紅：沒有 `pendingInjections` |

另有 PS-6：Naki 自送 63999 與注入本身不移動遊戲窗口（修前即綠，固定變異用）。

變異（加進 `scripts/guard-gaps-mutate.cjs`，`PS1`～`PS8`）：拿掉避未答、拿掉遊戲窗口、窗口少算邊界、注入仍寫 `pendingMethods`、注入回應改用 `resolveMethod`、關閉不清注入登記、Naki 自送也算遊戲號碼、遊戲號碼不追蹤。
