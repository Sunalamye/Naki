# 插件系統 v2 設計包：implementation notes

**日期**：2026-10-14
**分支**：`plugin-v2-design`（worktree `Naki-wt-plugin-v2`，基於 main `0ef66df`），未 commit。
**設計文件**：`docs/plan/plugin-v2.md`
**log**：主 repo `.swfd/logs/plugin-v2-design/`

---

## 決策

1. **設定頁用 `WKWebView`，兩平台一條路徑**。iOS target 17，`WebPage` 只在 26+；`WKScriptMessageHandlerWithReply` 兩平台都有。
2. **bridge 驗證放 Swift 純函式**（`PluginSettingsBridge.reply`），JS shim 只負責轉送。頁面可以改寫 shim，驗證放 JS 等於沒驗。
3. **宣告 `settingsUI` 必須同時宣告非空 `settings`**。沒有 schema 就沒有型別可驗。
4. **settingsUI 檔不存在或外逃 ⇒ 整個插件不載入**，沿用 v1「沒有部分載入」。
5. **bridge 的寫入走既有 `setPluginSetting` action**：與 schema 自動渲染的控制項同一條路（存值，已啟用才熱重載），不新增 Runtime API。
6. **`rewriteSend` 允許換 method 與改長度**，但改前改後都要過送出禁改名單；type 與 msgId 不得變。MajsoulMax 的「改成 `loginBeat`」需要換 method。
7. **送出禁改名單採白名單式前綴**：只放行 `.lq.Lobby.*`，再排除登入／認證與 `startUnifiedMatch`／`matchGame`。`rewriteAllow` 不擴及送出側。
8. **鏈上換了 method 就停止派發**：後續插件是照舊 method 的白名單選進來的。
9. **send 側不提供裸 `drop()`**，改為設計 `respondLocally`（丟棄＋合成 RESPONSE），它依賴 Phase 4 機制，一起卡 gate。
10. **`injectReceive` 先送 Swift 再 dispatch，Naki listener 一律略過合成 event**：保證 LiqiParser 看到且只看到一次。
11. **probe 只攔「第一筆」無害目標 method，合成 event 內容與原封包相同**：(b) 失敗時遊戲最多少收一筆表情廣播或延遲檢查。

12. **（2026-10-14 追加）方向定為「讓插件更自由」，新增設計文件 §12 盤點 18 條限制**。本次納入：`rewriteSend`（已 spike）、`json` 設定型別、設定熱更新 `onSettingsChanged`、`onSocketClose`、Naki 提供的 protobuf 編解碼 `__nakiProto`（新工作包 PV2-C）；變長 replace、drop、injectReceive 納入設計但卡 Phase 4 gate。其餘不納入，各附日後路徑。
13. **`json` 設定一律存 JSON 字串**：plist 沒有 null，直接存 object 會在 null 處失敗；只驗合法 JSON、有限數字與合計 64KB 上限，不驗內部結構。
14. **`__nakiProto` 解碼必須保留未知欄位並在編碼時寫回**：`liqi.json` 已知過期，丟未知欄位會靜默刪資料。
15. **熱更新退路**：插件沒有 `onSettingsChanged` 就沿用現行「停用再重跑源碼」，不破壞現有插件。
16. **新節編號用 §12 而非 §11**：本文件既有的「§11 #N」都指 `plugin-system-design.md` 的拍板表，用 §11 會撞名。

17. **（審查第二輪）rewriteSend 的 envelope 檢查改用 `naki-plugins.js` 自己的 `isWellFormed`**，不修 `naki-core.js` 的 `parseEnvelope`：core 不在可改清單，且其他呼叫端只讀不寫。修 core 列入 PV2-B1。
18. **RESPONSE 的 `ctx.method` 是實際送出的 method**，與 Swift 一致；不另提供原 method 欄位。
19. **hook 拋錯撤回全部改動**：每個 hook 前快照 bytes，拋錯時還原參照與內容（Blob 路徑不快照）。
20. **送出禁改名單只保障兩件事**：Swift 從送出學習的來源，以及 33 個登入／session／憑證／付費方法（依 `liqi.json` Lobby 419 個方法盤點）。其餘大廳寫入不在保障內，文件承諾同步收窄。
21. **`respondLocally` 的 Swift 配對**：被丟棄的 REQUEST 仍送 Swift 登記 `pendingRequests`；合成 RESPONSE 在 `ws.send` 回傳後才送。禁用名單＝送出禁改名單＋`cancelUnifiedMatch`／`cancelMatch`（Swift 不論誰送都會取消等待）。
22. **設定頁以 `settingsPageIdentity` 重建**：id、版本、頁面檔修改時間與大小、schema 的 key 與型別。
23. **純量設定的讀值規則只有一份**（`PluginSettingField.accept`），grant 與 bridge 共用；`json` 型別日後擴充同一個函式。
24. **只有 manifest 指定的頁面拿得到 bridge**；主框架不能導覽到別的文件。網路封鎖降為可選產品政策。
25. **熱更新整項移到 PV2-B1**，並定 `seq` 防逆序、完整快照、hook 拋錯退回重跑；§10 新增檔案歸屬表，修正「三包不重疊」的錯誤敘述。
26. **protobuf API 以 `modify` 為建議用法**，未知欄位存在內部 `WeakMap`；子物件被替換而丟了未知欄位時 `encode` 拋錯；64 位元整數用 `BigInt`。
27. **Phase 4 probe 改為延遲註冊攔截器＋逐 handler 逐事件紀錄**，`verdict` 由腳本算出；(c) 兩條路徑都要有真連線資料，沒有「部分」。

## 追加查證（2026-10-14）

- 契約漂移：`plugin-api-v1.md` §6 寫「改設定要重載頁面才生效」，實作是熱重載（停用再重跑源碼）。讀原始碼確認，未在 App 內實測。
- `liqi.json` 不在 App bundle，只在 `docs/protocol/`（約 280KB）。
- Naki 沒有執行期解析 `lqc.lqbin`；`MatchModeTable` 是離線解出的靜態表。
- 插件注入腳本是 `atDocumentStart`、main frame only（`WebSession.setPluginInjection`）。

## 驗證紀錄

| 項目 | 結果 | 證據 |
|---|---|---|
| 改動前基準 NakiTests | 1013 tests、0 failures | `baseline-test.log` |
| 改動前基準 plugin-regression | 29／29 | `baseline-plugin-regression.log`（插件 repo `naki-plugins` `c35e61d`） |
| macOS build | 綠 | `build-2.log`（`build-1.log` 是修正前的編譯錯誤） |
| iOS（`Naki-M`，iOS Simulator）build | 綠 | `build-ios-1.log` |
| `PluginSettingsUITests` | 11／11 | `test-settingsui-2.log` |
| Swift 變異 S1（`isRegularFile` 恆真）、S2（number 不分 CFBoolean／不驗有限值） | 都讓測試失敗 | `mutation-swift.log`、`mut-S1-regular-file.log`、`mut-S2-cfboolean.log` |
| `plugin-v2-regression.cjs` | 15／15 | `plugin-v2-regression-2.log` |
| JS 變異 M1–M10 | 全部至少一條失敗 | `mutation-js.log`（第一次跑的 M9 沒抓到 ArrayBuffer 分支，補了 ArrayBuffer 測試後重跑抓到；同檔第一個 M9 行是腳本自己的錯誤替換，未生效） |
| 改動後 plugin-regression | 29／29 | `plugin-regression-after.log` |
| probe 腳本 | 語法可執行；在 node 假 socket 上邏輯如預期 | `probe-dry-run.log`（**dummy，不是 live 證據**） |
| UI token 閘 | 全 PASS | `ui-token-gate.log` |
| 最終整合閘（搬檔後） | macOS build 綠、iOS build 綠、NakiTests 1024 tests 0 failures（基準 1013＋本包 11）、plugin-v2-regression 15／15、plugin-regression 29／29 | `final-build.log`、`final-build-ios.log`、`final-test.log`、`final-plugin-v2-regression.log`、`final-plugin-regression.log` |
| 第二輪：node 回歸 | 21／21 | `round2-plugin-v2-regression.log` |
| 第二輪：JS 變異 R1／R4／R5／R6 | 各自讓對應反例失敗 | `round2-mutation-js.log` |
| 第二輪：Swift 變異 R2／R8／R10／R13 | 各自讓對應反例失敗 | `round2-mutation-swift.log`、`round2-mut-*.log` |
| 第二輪：probe 自我驗證 | 三種 dispatcher × 兩種寫法判讀正確；設計文件內嵌腳本與受測腳本逐字相同 | `round2-probe-dry-run.log`、`round2-probe-doc-extract.log`、harness `round2-probe-dry-harness.cjs` |
| 第二輪：整合閘 | macOS／iOS build 綠、NakiTests 1027 tests 0 failures（上輪 1024＋3）、plugin-v2-regression 21／21、plugin-regression 29／29、ui-token-gate 全 PASS、`git diff --check` 通過 | `round2-build.log`、`round2-build-ios.log`、`round2-test.log`、`round2-plugin-v2-regression.log`、`round2-plugin-regression.log`、`round2-ui-token-gate.log` |

## Deviations

1. **settingsUI 的檔名規則不是 `isSafeEntry`**。指示寫「限 `isSafeEntry`」，但 `isSafeEntry` 要求 `.js` 結尾，設定頁是 HTML。採用較保守的同等規則：`isSafeName`（同字元集、不得以 `.` 開頭、不得含 `..`、不含 `/`）＋ `.html` 結尾，另加「解掉 symlink 後仍是插件目錄直接子項、且是一般檔案」。
2. **node 測試放在新檔 `scripts/plugin-v2-regression.cjs`，沒有改 `scripts/plugin-regression.cjs`**。可改清單沒有列 `scripts/`；新增檔案比改既有檔案保守，而且新檔不依賴外部插件 repo 路徑，可直接 `node scripts/plugin-v2-regression.cjs`。
3. **`naki-websocket.js` 的 send 包裝有接線改動**（`originalSend(handleMessage(...) || data)` 與兩個分支回傳 `rewritten`）。指示說 B 只做「JS 端鏈式派發與 capability 閘」；不接線的話 `rewriteSend` 無法端到端測。這屬 CLAUDE.md「修改 WebSocket bridge 前先確認」，已在設計文件 §8-5 標為合併前需主線確認；Naki 自送與零插件路徑有單測鎖住（`Naki's own sendRaw is never offered rewriteSend…`、`no plugins: send passes the very same object through…`）。
4. **為了端到端單測，`PluginSettingsWebView.makeWebView` 是 `static` 而非 `private`**，Coordinator 補 `nonisolated deinit {}`（CLAUDE.md：單測釋放 MainActor class 會 SIGABRT）。
5. **沒有改 `SettingsStore.swift`、`NakiRuntime.swift`**：既有 `pluginSettingValue`／`setPluginSettingValue`／`setPluginSetting` 已足夠，改它們沒有必要。
6. **範例插件 fixture 放在 `NakiTests/Fixtures/plugins/com.naki.example.settings-page/`**。`NakiTests` 是 synchronized group，這些檔案會成為測試 bundle 的資源，但**不會**進 app bundle。內容原創，CC0。
7. **新檔放在 `command/Services/Web/PluginSettingsHost.swift`，不是指示寫的 `command/Services/Plugins/`**。第一次全套測試 `PlatformDivergenceTests.testWebViewImplementationsLiveOnlyInWebSessionLayer` 失敗：既有架構規則規定 `WKWebView(` 只准在 `Services/Web/` 內建立。保守選項是遵守規則、搬檔，而不是放寬 lint 測試。檔案內容不變，`project.pbxproj` 兩個 exception set 都改登記在 `Services/Web/`。證據：`test-before-move.log`（搬檔前，1024 tests、1 failure）。
8. **（第二輪已由第 9 條取代）URL 匯入沒有補抓 `settingsUI`**（`PluginImportSource.swift` 不在可改清單）。結果：經 HTTPS 或 GitHub 來源匯入、宣告 `settingsUI` 的插件會整個不載入（fail-closed）。列入 PV2-A。
9. **（審查第二輪）改了可改清單外的 `PluginImportSource.swift`**（15 行：HTTPS／GitHub 來源抓 `settingsUI`、`finalize` 缺檔即拒）。原因：這個缺陷是 spike 引入的回歸（main 上 `settingsUI` 會被忽略，spike 之後缺檔會讓更新覆蓋可用插件），主線第二輪指示允許「≤30 行的 spike 修正」。保守做法是在替換前擋下，而不是放寬 Registry 的「缺檔不載入」。
10. **（審查第二輪）沒有修 `naki-core.js` 的 `parseEnvelope`**，改在 `naki-plugins.js` 加嚴格檢查。core 不在可改清單，修它會改變 `plugin-regression.cjs` 鎖住的 envelope corpus 語意，較保守的做法是只在寫入路徑加嚴，core 的修正排進 PV2-B1。
