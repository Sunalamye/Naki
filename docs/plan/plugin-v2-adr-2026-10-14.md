# ADR：插件系統 v2 設計定案（2026-10-14）

**狀態**：已定案（設計），實作未開始。
**設計文件**：`docs/plan/plugin-v2.md`；審查回應：`docs/plan/plugin-v2-review-response.md`；決策流水：`docs/plan/plugin-v2-implementation-notes.md`。
**設計者**：Opus 5.5 high。**審查**：Astra（codex `gpt-6-astra`，唯讀 sandbox）。**裁決**：主線。

## 背景

用戶提問「MajsoulMax 能不能當 Naki 插件做」。對照 MajsoulMax `plugin/mod.py` 後，現行插件 API 缺四種封包原語（變長 receive 改寫、drop、rewriteSend、向客戶端注入）。用戶接著要求兩件事：插件頁要能顯示插件自帶的設定畫面；整體方向「讓插件更自由」。

## 決定

1. **插件自帶設定頁（PV2-A）**：manifest 宣告 `settingsUI`（插件目錄內的單一 `.html`），插件頁以獨立 `WKWebView` 載入，只有該頁拿得到 `get`／`set` bridge；值仍只存在 `SettingsStore` 的 `plugin.<id>.<key>`。另加 `json` 設定型別（存 JSON 字串，每插件合計上限 64KB）。
   why：用戶要「插件自己顯示能設定的內容」；schema 自動渲染畫不出巢狀結構，`json` 型別與自帶設定頁互為前提，所以同包。
2. **rewriteSend、onSocketClose、設定熱更新（PV2-B1）**：L3，受 `pluginsMayModifyOutbound` 把關；送出禁改名單涵蓋非 `.lq.Lobby.*`、登入／session／憑證／付費 33 個方法與配對相關方法。
   why：不依賴 Phase 4 機制，單獨就能涵蓋「把 REQUEST 改成無害心跳」這類用法；熱更新放 B1 是因為主體在 `naki-plugins.js`，放 A 會搶檔案。
3. **protobuf 編解碼 JS API（PV2-C）**：bundled `liqi.json` 驅動的 `window.__nakiProto`，manifest `"protobuf": true` 才注入；六條資料保真契約（巢狀未知欄位保留、64 位元用 BigInt 等）。
   why：沒有編碼器，變長改寫與注入幾乎不可用；讓每個插件自帶 protobufjs 是重複且更容易丟欄位。
4. **變長 receive replace、drop、injectReceive、respondLocally（PV2-B2）**：只定設計，**實作卡 Phase 4 live probe (a)(b)(c) 全綠**（`plugin-system-design.md` §11 #6，本 ADR 不推翻）。
5. **不做**：內置 MajsoulMax 任何規則或 id 表（授權線 §9）；資源替換 hook、lqc.lqbin 暴露、methods 萬用字元、isNaki 流量改寫（理由與日後路徑見設計 §12.2）。

## 用戶裁決（2026-10-14，AskUserQuestion）

- **`ws.send` 接線改動**：spike 在派工時已修改 `naki-websocket.js` 的 `ws.send` 包裝，違反 CLAUDE.md「修改 WebSocket bridge 前先確認」的時點（Astra 第 12 條）。用戶裁決**事後追認，保留並進 PV2-B1**。程序偏離記錄於此；之後動 bridge 的工作包仍須在修改前確認。
- **`liqi.json` 打包進 App**：用戶裁決**允許**。理由：它是協定 schema，不是 MajsoulMax 程式碼，不觸授權線。

## 統帥代決

- **工作包改名**：UI 設計計畫已占用 WP-A 到 WP-F，插件 v2 原本也用 WP-A／B1／B2／C，同名不同物。插件 v2 一律改為 PV2-A／PV2-B1／PV2-B2／PV2-C（三份 plugin-v2 文件已全文替換）。
- **合併順序** A → B1 → C → B2，依設計 §10。PV2-B2 另需 probe 綠且 PV2-C 已合併。

## 審查裁決

| 項目 | 數字 |
|---|---|
| Astra 條目 | 13（擋 3、應修 9、建議 1） |
| 採納 | 12 |
| 反駁（over-guard／over-build） | 0／0 |
| 主線推翻的反駁 | 0（無反駁可裁） |
| 由主線處理 | 1（第 12 條，見上方用戶裁決） |

反駁率 0，不觸發「反駁過半重讀」。主線檢查是否過度採納：第 1、2、3、5、7、8、10、11 條屬資料遺失／安全／並發正確性類，依規則只能採納；第 4、6、9 條影響插件拿到的資料是否正確，採納合理；第 13 條 Astra 本身建議把網路封鎖降為可選，採納反而縮小範圍。判定無過度採納。

## 定案前把關（重大計畫）

- 目標：A、B1、C 可交付；B2 有明確 gate。成立。
- 邊界：每包的可改檔案見設計 §10 檔案歸屬表。成立。
- 驗證：spike 整合閘 NakiTests 1027／0、plugin-v2-regression 21／21、plugin-regression 29／29、macOS 與 iOS Simulator build 綠（主 repo `.swfd/logs/plugin-v2-design/round2-*.log`）。
- **已知風險**：
  1. 插件分支基於 `0ef66df`，main 已到 `b8e0d95`；`PluginsPageView.swift` 兩邊都改（main 87+/27-），PV2-A 開工前必須 rebase 並解衝突。UI 的 WP-F2（`Naki-wt-wpf2`，設定分頁）仍在進行，可能再動同一檔。
  2. 未驗證：App 內實際顯示設定頁、iOS 17–25 執行、真實 HTTPS／GitHub 匯入、rewriteSend 在伺服器上的效果、Phase 4 probe。
  3. 帳號外觀變更類插件有封號風險，只在測試帳號使用（CLAUDE.md）。

## 附錄：Astra 審查原文

（複製自主 repo `.swfd/logs/plugin-v2-review/astra-review.md`。本次無反駁原文。）

1. 【擋】完整性檢查會放行截斷封包 — `command/Resources/JavaScript/naki-plugins.js:217`、`naki-core.js:250`  
   已用 Node 重現：合法 REQUEST 尾端加上缺少資料的 fixed32 tag，`replace()` 仍回 true 並送出。  
   §4.5「改後可由 Swift 重讀」因此不成立；§8 雖已揭露，仍須在啟用 rewriteSend 前補齊 fixed32／fixed64 邊界檢查。

2. 【擋】缺設定頁的更新會覆蓋原本可用的插件 — `command/Services/Plugins/PluginImportSource.swift:248`、`:318`；`PluginRegistry.swift:268`  
   HTTPS／GitHub 更新加入 `settingsUI` 時，下載包缺 HTML，`finalize` 卻接受，`install` 接著替換既有目錄；Registry 最後才拒載。  
   這不只是文件所寫的「fail-closed」：可用舊版已被替換。應在替換前驗完整資源，缺檔時保留舊版；本次僅源碼追查，未執行安裝。

3. 【擋】Phase 4 probe 的計數不足以支持開工判定 — `docs/plan/plugin-v2.md:355`、`:365`、`:384`、`:410`  
   已用假 socket 重現：`wrap()` 先呼叫 `state()`，攔截器實際比 Naki handler 早註冊，無法測出文件宣稱的「後註冊 capture 超前」。  
   而 `original` 到攔截器執行時才設定，先執行的 handler 即使收到原事件，也不會被計入 `original`。  
   應改成可識別原／合成事件的逐 handler 紀錄，保持 listener 移除語意；(c)「部分」仍不得算全綠。現腳本不能作為 Phase 4 通行證。

4. 【應修】換 method 後，Swift 與插件對 RESPONSE 的理解分叉 — `command/Resources/JavaScript/naki-plugins.js:347`、`:411`  
   已重現：`changeCharacterSkin → loginBeat` 後，送出的 method 是 `loginBeat`，插件收到 RESPONSE 的 `ctx.method` 卻仍是 `changeCharacterSkin`。  
   `pendingMethods` 在改寫前登記，成功後未更新。應明定原始 method 與實際送出 method 的用途；需要保留兩者時須明確區分，不能讓插件按錯誤型別解碼。

5. 【應修】hook 撤回只還原參照，沒有完整還原 bytes — `command/Resources/JavaScript/naki-plugins.js:400`、`:406`  
   已重現：receive hook 經合法等長 `replace()` 改值後 throw，改值仍留在 buffer；send hook 先就地修改再替換、throw，也留下先前修改。  
   純 send 整包替換的撤回測試有通過，但不足以支持 v1 §7 的全面 fail-open 敘述。應補每個 hook 的還原語意與反例；這是錯誤隔離問題，不是要求推翻 U4。

6. 【應修】送出禁改名單未涵蓋宣稱的登入／session 範圍 — `command/Resources/JavaScript/naki-plugins.js:284`  
   已重現：改寫成 `logout`、`loginSuccess` 都被接受；repo schema 另有 `fastLogin`、`prepareLogin` 等入口未列入。  
   「只放行非關鍵大廳請求」比實際保障更廣。應盤點登入／session 方法並測改前、改後兩側，或收窄文件承諾；不必因此禁止所有大廳寫入。

7. 【應修】`respondLocally` 缺少 Swift 回應配對來源 — `docs/plan/plugin-v2.md:154`、`:192`；`command/Services/Bridge/LiqiParser.swift:240`  
   設計要求被丟棄的 REQUEST 不送 Swift，卻要把合成 RESPONSE 交給 Swift；此時沒有對應 `pendingRequests`，parser 會走 unmatched 路徑。  
   必須先定義本地請求如何登記、清除及避免觸發真送出的學習副作用，再檢查「不改 Swift parser」是否仍可成立。

8. 【應修】插件更新後，舊設定頁可能搭配新 schema 繼續寫入 — `command/Views/PluginsPageView.swift:311`；`command/Services/Web/PluginSettingsHost.swift:121`、`:132`  
   同 id 更新時，View 身分不變；update 方法只換 handler，沒有載入新的 `pageURL` 或 HTML。  
   推測結果是舊控制項寫入新版 schema：可能被拒絕，也可能覆蓋同名欄位的新語意。應以頁面版本／內容身分重建，並處理舊頁未完成的寫入；WebKit 情境本次未驗證。

9. 【應修】protobuf API 的資料保真契約仍不足 — `docs/plan/plugin-v2.md:484`、`:493`  
   提供共用編解碼器的方向合理，但只寫「保留未知欄位」尚未涵蓋巢狀 message、同欄位 wire type 不符，以及 int64／uint64 的精確表示。  
   若採一般 JS Number 或在複製物件時遺失不可列舉的 `__unknown`，仍可能靜默改資料。應先固定這些語意與往返 fixture；26 個 Swift 訊息對照不能替代它們。

10. 【應修】JSON 設定需要一致的解析與遷移規則 — `docs/plan/plugin-v2.md:509`；`command/Services/Web/PluginSettingsHost.swift:37`；`command/Services/Plugins/PluginRegistry.swift:343`  
    JSON 字串持久化與不做 JSON Schema 的取捨合理，但尚未定義舊型別轉換、損壞儲存值及超量 default 的處理。  
    現在設定頁會對錯型別覆寫值退回 default，grant 卻仍可能把錯型別交給插件。應共用解析規則，並讓容量限制涵蓋 default、讀回與寫入，避免兩端各看一份設定。

11. 【應修】設定熱更新低估了失敗與並發語意 — `docs/plan/plugin-v2.md:521`、`:527`；`command/Services/Web/WebSession.swift:182`  
    保留插件執行期狀態值得做，但目前存值後另開 Task 套用；bridge 成功不代表遊戲頁已套用。  
    新 hook 若拋錯，儲存值、grant 與插件內部狀態如何收斂仍未定義；連續更新也缺順序／過期處理驗收。  
    此外 WP-A 的熱更新與 WP-B1 都會改 `naki-plugins.js`，§10「檔案不重疊、可並行」須修正。

12. 【應修】「修改前確認」不能改寫成「合併前確認」 — `docs/plan/plugin-v2-implementation-notes.md:46`；`CLAUDE.md`「不可違反的邊界」  
    Deviations 明載 spike 已修改 `ws.send` 接線，卻把確認延至合併前；這與既有邊界的時點不同。  
    本次材料未提供修改前授權證據，應補上既有授權依據或明列程序偏離；單測通過不能替代授權。

13. 【建議】釐清設定頁來源範圍，避免把網路封鎖升為必要防護 — `command/Services/Web/PluginSettingsHost.swift:100`、`:109`；`docs/plan/plugin-v2.md:268`  
    handler 只驗 main frame，導覽卻允許目錄內其他文件；它們成為主頁後也可寫設定，並非只授權 manifest 指定的 HTML。此點是源碼判讀，未做 WebKit 驗證。  
    可明訂「同插件目錄主文件皆受信任」，或限定設定頁 URL；不要宣稱更窄的來源保障。  
    U4 下，全面封鎖網路應屬可選產品政策；它會限制遠端選項資料等正常用途，不宜成為 WP-A 的必做安全工程。

總評：**REWORK**。A、rewriteSend 與三項自由度擴充方向可保留，但目前不能視為可合併的完整功能；Phase 4 也尚無可靠通行證。已重跑 Node 15／15，並以額外反例確認上述封包問題；正常路徑中，零插件原物件、Naki 自送及替換後 Swift／socket bytes 一致的測試通過。文件對多數未驗證項目有誠實標示，但已知 parser 缺陷與更新破壞不能只列風險。本次未重跑 Swift／WebKit、build 或 live 對局；未修改任何檔案，結束時 git 狀態與開始一致，`git diff --check` 通過。
## 用戶裁決：spike 提前合進 main（2026-10-14）

用戶決定為了併入 v2.18.0，把 spike 在 PV2-A 手測與 PV2-B1 live 驗證之前合進 main。

仍未驗證的項目照列：

- App 內設定頁的實際顯示
- iOS 17–25 上的執行
- 真實 HTTPS／GitHub 匯入
- `rewriteSend` 在伺服器上的效果

風險界線：

- `rewriteSend` 受 L3 總開關 `pluginsMayModifyOutbound` 把關，預設關。
- 零插件與 Naki 自送路徑有單測鎖住「原物件直送」。

PV2-A／PV2-B1 的剩餘工作（見設計 §10）不變。
