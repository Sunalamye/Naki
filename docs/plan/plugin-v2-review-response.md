# 插件 v2 設計包：審查回應（Astra，13 條，總評 REWORK）

**日期**：2026-10-14
**審查原文**：主 repo `.swfd/logs/plugin-v2-review/astra-review.md`
**回應範圍**：第 1–11、13 條。第 12 條是主線的程序偏離，**由主線處理**。
**log**：主 repo `.swfd/logs/plugin-v2-design/round2-*.log`

## 統計

| 類別 | 條數 | 條目 |
|---|---|---|
| 採納 | 12 | 1、2、3、4、5、6、7、8、9、10、11、13 |
| 反駁（over-guard） | 0 | — |
| 反駁（over-build） | 0 | — |
| 由主線處理 | 1 | 12 |

其中 spike 已修並補反例測試的有 1、2、4、5、6、8、10（純量部分）、13；只改設計的有 3（probe 腳本）、7、9、10（`json` 部分）、11。

---

## 逐條

### 1. 完整性檢查放行截斷封包 — 採納（spike 已修）

- **修法**：`naki-plugins.js` 新增 `isWellFormed`，逐欄位走完 envelope，fixed32／fixed64／length-delimited 都檢查不越界，且 field 1（method）必須非空。`rewriteSend` 改用它，不再依賴 `parseEnvelope(...).complete`。
- `naki-core.js` 的 `parseEnvelope` 本身沒有改：它不在本包可改清單，且其他呼叫端只讀不寫。修 core 列入 PV2-B1，屆時要同步更新 `plugin-regression.cjs` 的 envelope corpus 測試（設計文件 §8-4、§10）。
- 設計文件 §4.4、§4.5-5 改寫：JS 端嚴格檢查的是 **envelope 層**；payload 內層由插件負責，PV2-C 的編碼器是建議的產生方式。
- **反例測試**：`truncated fixed32 / fixed64 tails are refused even though parseEnvelope reports complete`（測試裡先斷言 core 的 `complete === true`，重現審查的情境）、`empty method field is refused`。
- **變異**：把 `isWellFormed` 換回 `after.complete`，第 16 條失敗（`round2-mutation-js.log` R1）。

### 2. 缺設定頁的更新會覆蓋可用插件 — 採納（spike 已修）

- **修法**：`PluginImportSource` 的 HTTPS 與 GitHub 來源都抓 `settingsUI` 檔（HTTPS 要求同源）；`finalize` 在宣告了 `settingsUI` 卻缺檔時回 `invalidManifest`。所有來源（含「檢查更新」走的 `fetchAny`）都經過 `finalize`，`install` 只接受 `finalize` 的產物，所以缺檔的包**不會**進到 `install` 的 `replaceItemAt`，可用舊版不被替換。
- 這屬於可改清單外的檔案，記為 Deviation 9（改動 15 行，在主線「≤30 行可直接修」的範圍內）。
- 設計文件 §3.1、§8-1。
- **反例測試**：`PluginSettingsUITests.testImportFinalizeRequiresSettingsPageBeforeInstall`。
- **變異**：拿掉 `finalize` 的檢查，該測試失敗（`round2-mutation-swift.log` R2）。
- 未驗證：沒有對真的 HTTPS／GitHub 來源執行匯入。

### 3. Phase 4 probe 計數不足以支持開工 — 採納（腳本重寫）

審查指出的兩個缺陷都已消除：

- **攔截器的註冊順序**：攔截器改在「遊戲第一次對該連線註冊 message handler」時才以 capture 註冊，因此一定晚於 Naki 的非 capture listener。(d) 量到的就是「後註冊的 capture 是否超前」。
- **逐 handler 紀錄**：每個事件第一次被任何 handler 看到時給序號；合成事件在 dispatch 前登記它代替的原事件序號。Naki、攔截器、遊戲、probe 自己的每個 handler 都各自記錄看到的目標事件序號與原／合成，所以排在攔截器之前執行、收到原事件的 handler 也會被記到。
- **listener 語意**：同一個 fn 只包一次；`removeEventListener(fn)` 換成移除包裝；`onmessage` getter 回傳原 fn。
- **(c) 不再有「部分」**：攔截器之後緊接著註冊 probe 自己的 `addEventListener` 與 `onmessage` handler，兩條路徑都在真連線上取得資料；`verdict.c_addEventListener` 與 `verdict.c_onmessage` 必須都為 true，任一沒有資料或為 false 都是紅。
- `verdict` 由腳本直接算出，(b) 另保留 60 秒後的人工條件。
- **腳本自我驗證**：三種假 dispatcher（capture 先跑、照註冊順序、`stopImmediatePropagation` 無效）× 兩種遊戲註冊寫法。結果：capture 先跑 ⇒ (a)(b)(c) 綠、(d) 真、Naki 只收到合成事件；照註冊順序 ⇒ (a)(b)(c) 綠、(d) 假、Naki 收到原事件**有被計入**；stop 無效 ⇒ (a)(c) 紅。harness 另斷言 `removeEventListener` 與 `onmessage` getter 語意（`round2-probe-dry-run.log`）。設計文件 §9 內的腳本是經過這次驗證的同一份（`round2-probe-doc-extract.log`）。
- 除錯紀錄：第一次 dry run 的 `onmessage` 情境結果錯誤，原因是 harness 讓兩次執行共用同一個假 class、probe 補丁疊了兩層；改成每次執行建新 class 後正確。這是 harness 的問題，不是 probe 的問題。
- **仍然不是 Phase 4 通行證**：通行證只能是 live 對局上的 (a)(b)(c) 全綠。本包沒有測試帳號，**未執行**。

### 4. 換 method 後 RESPONSE 理解分叉 — 採納（spike 已修）

- **修法**：`rewriteSend` 替換成功後，`naki-plugins.js` 以實際送出的 method 更新自己的 msgId→method 表。插件收到的 RESPONSE `ctx.method` 與 Swift `LiqiParser.pendingRequests` 一致，都是實際送出的 method。
- **語意定案**（設計文件 §4.4）：契約只提供「實際送出的 method」。插件若需要原本的 method，要自己在 `onSend` 記下；不提供第二個欄位，避免插件拿錯型別解碼。
- **反例測試**：`after a method swap the RESPONSE is attributed to the method actually sent (same as Swift)`。
- **變異**：拿掉更新那一行，該測試失敗（R4）。

### 5. hook 撤回只還原參照 — 採納（spike 已修）

- **修法**：`dispatch` 在每個 hook 執行前快照 bytes；hook 拋錯就把參照與內容都還原。整包替換、等長 `replace`、直接改 `ctx.bytes` 的就地改寫都涵蓋，send 與 receive 兩個方向都適用。Blob 路徑（`mutable:false`）不快照。成本是每個 hook 一次 bytes 複製，記在設計文件 §4.4。
- **反例測試**：`receive: equal-length replace followed by a throw is fully reverted`、`in-place edits by a hook that throws are reverted (receive and send)`（就是審查重現的兩個情境）。
- **變異**：拿掉內容還原，兩條都失敗（R5）。

### 6. 送出禁改名單未涵蓋登入／session — 採納（名單補齊＋承諾收窄）

- **盤點**：依 `docs/protocol/liqi.json` 的 Lobby 419 個方法篩出登入、session、憑證、帳號安全、付費驗證類，共 33 個，加上 `startUnifiedMatch`、`matchGame`。改前、改後兩側都查。
- **承諾收窄**（設計文件 §4.4）：名單只保障兩件事——Swift 從遊戲送出學東西的來源，以及帳號登入／session／憑證／付費操作。其餘大廳寫入不在保障內，只靠 L3 總開關與測試帳號；`liqi.json` 過期時名單要跟著補。
- **反例測試**：`login / session / account-security methods are forbidden on both sides`（含審查舉的 `logout`、`loginSuccess`、`fastLogin`、`prepareLogin`）。
- **變異**：名單退回第一版，該測試失敗（R6）。

### 7. `respondLocally` 缺 Swift 配對來源 — 採納（設計）

- **定義**（設計文件 §4.3）：被丟棄的 REQUEST 仍送 Swift，讓 `LiqiParser.parseRequest` 登記 `pendingRequests`。不呼叫 `originalSend`。等 `ws.send` 回傳後才排程：先送 Swift 合成 RESPONSE（對回並清除登記），再 dispatch 合成事件給遊戲。
- **學習副作用**：查 `LiqiParser.parseRequest`，送出方向的副作用有三種：登記 `pendingRequests`、`startUnifiedMatch` 學 sid、`cancelUnifiedMatch`／`cancelMatch` 取消等待。後兩者被本地回應觸發就是錯的。因此 `respondLocally` 的禁用名單是送出禁改名單再加 `cancelUnifiedMatch`、`cancelMatch`。`LiqiResponseStore` 只收 Naki 登記的 msgId，不受影響。
- **結論**：在這個名單下「不改 Swift parser」成立。PV2-B2 要加契約測試：`LiqiParser` 中送出方向有副作用的 method 常數，必須全部出現在 JS 的禁用名單裡。
- 未驗證：遊戲是否接受「`send` 回傳後下一個 tick 才到」的合成 RESPONSE，列為 PV2-B2 live 驗收項。

### 8. 插件更新後舊設定頁搭配新 schema — 採納（spike 已修）

- **修法**：新增 `PluginDescriptor.settingsPageIdentity`，由 id、版本、設定頁檔的修改時間與大小、schema 的 key 與型別組成。View 改用它當 `.id`，任一變了就拆掉舊 WebView 再載入新頁。拆除時會移除 message handler。
- **舊頁未完成的寫入**：bridge 的 `set` 是同步處理完才回覆，拆除前送出的不會留下半套寫入；拆除後才送出的沒有 handler 可收。
- 設計文件 §3.2。
- **反例測試**：`testSettingsPageIdentityChangesWithVersionPageOrSchema`。
- **變異**：身分不含 schema 時，該測試失敗（R8）。
- 未驗證：SwiftUI 實際重建 WebView 的時機（WebKit 情境）。

### 9. protobuf API 資料保真契約不足 — 採納（設計）

- 設計文件 §12.3 新增六條保真契約，每條都要有往返 fixture：
  1. 每一層巢狀都保留未知欄位，存在內部 `WeakMap`、不掛物件屬性。
  2. 建議用 `modify(type, bytes, fn)` 就地改。子物件被替換或複製而丟了未知欄位時，`encode` 拋錯，不靜默輸出；要刻意丟棄得呼叫 `dropUnknown`。
  3. 已知欄位但 wire type 不符時不解碼，整筆當未知欄位保留。
  4. 64 位元整數一律用 `BigInt`。
  5. 非法 UTF-8 的 string 當未知欄位保留。
  6. 保留 packed／unpacked 形式與未知 enum 值。
- 明寫「26 個訊息的 Swift 對照不能取代保真 fixture」。

### 10. JSON 設定解析與遷移規則 — 採納（純量部分 spike 已修；`json` 部分設計）

- **spike 已修**：審查指出的不一致是真的（第一版 `grantDict` 只擋非有限 Double，錯型別會原樣交給插件）。現在 `PluginSettingField.accept` 是唯一規則，`PluginRegistry.grantDict` 與 `PluginSettingsBridge.reply` 都用它；錯型別或非有限值兩端都退回 default。
- **反例測試**：`testGrantAndBridgeAgreeOnStaleOverrides`（兩端逐 key 比對）。
- **變異**：`grantDict` 退回舊規則，該測試失敗（R10）。
- **設計**：設計文件 §12.4 加規則表，涵蓋存法、損壞值、型別遷移（不自動轉換、儲存值不刪）、寫入驗證，以及容量上限。容量上限同時套用於 manifest default（超量 ⇒ 插件不載入）、寫入（`too_large`）與讀回（超量 ⇒ 回 default）。

### 11. 熱更新的失敗與並發語意 — 採納（設計＋§10 修正）

- 設計文件 §12.5 新增六條語意：
  1. `SettingsStore` 是唯一權威；`set` resolve 只代表「已存」。
  2. 每次下發完整快照。
  3. Swift 為每個插件維護遞增 `seq`，頁面丟棄過期的下發。這是因為 `WebSession.fireJavaScript` 每次開新 `Task`，不保證順序。
  4. hook 拋錯時 grant 保持新值，並退回「停用再重跑」，不會出現存值與 grant 分叉。
  5. 頁面不在時由下次載入的注入重建。
  6. 驗收項目。
- **§10 修正**：第一版「三包檔案不重疊」不正確。熱更新的主體在 `naki-plugins.js`，所以整項移到 PV2-B1；§10 新增檔案歸屬表；PV2-C 與 A、B1 有共用檔案，改為排在兩者之後。

### 12. 「修改前確認」被改寫成「合併前確認」 — 由主線處理

- 本包只在設計文件 §8-5 與 §10 的 PV2-B1 前置欄，把措辭改回「修改 bridge **前**取得主線確認」，並註明 spike 是先改後報、程序偏離由主線處理。

### 13. 設定頁來源範圍 — 採納（spike 已修；網路封鎖降為可選）

- **修法**：
  - 主框架只能停在 manifest 指定的設定頁，iframe 只能載入插件目錄內的檔案。
  - message handler 只回應「主框架且文件 URL 就是 manifest 指定頁」，其他文件回 `not_settings_page`。
  - URL 比對時會先解掉 symlink（`/var` 與 `/private/var` 的差異）。
- 設計文件 §3.3 明寫來源範圍：只有 manifest 指定的那一份 HTML 拿得到 bridge。
- **網路封鎖**：同意審查意見。`WKContentRuleList` 從 PV2-A 必做項移除，改列為可選的產品政策（§3.3、§8-2）。
- **反例測試**：`testSettingsPageBridgeEndToEndInIsolatedWebView` 新增兩個情境：主框架導覽到同目錄 `other.html`，以及導覽到外站，兩者都被取消。
- **變異**：主框架改回「目錄內皆可」時，該測試失敗（R13）。
- 未驗證：iframe 拿不到 bridge 這一點沒有測試，目前只有原始碼判讀。
