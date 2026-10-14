# IRC 介面層實作筆記

- 依據：`.swfd/logs/irc/audit-ui.md`（行號基準 b8e0d95，Swift 與 7c2fe26 相同）。
- worktree：`Naki-wt-irc-ui`，分支 `irc-ui`，基準 main 7c2fe26。未 commit。
- 證據 log 與截圖：主 repo `.swfd/logs/irc-ui/`。

## 條目

| 編號 | 狀態 | 修改前後 | 行為改變 | 測試 |
|---|---|---|---|---|
| UI-01 | 已修 | 徽章條件抽成 `GameStore.showsRecommendationBadge`，由 `recommendationCount > 0` 改為 `autoPlayMode.showRecommendation && recommendationCount > 0`；`StatusBar` 讀它 | 是：`.off` 時徽章消失 | `StatusBarBadgeTests`（修前失敗 log `ui01-before-fix.log`，修後通過 `ui01-after-fix.log`）；截圖 `statusbar-off.png`、`statusbar-recommend.png`、修前 `statusbar-off-before-fix.png` |
| UI-10 | 已做 | `GameStore.apply` 註解列出實際寫入點（`apply`、`clearAfterBotDeleted`、`NakiWebCoordinator.createBot`、DEBUG `/debug/ui`）；`MARK` 去掉「唯一入口」 | 否 | 無（註解） |
| UI-11 | 已做 | 四處「六個」改「七個」 | 否 | 無（註解） |
| UI-12 | 部分完成，主線接受；剩餘部分涉 NativeBotController 與 in-flight 的 DebugServer／NakiMCPDependencies，延到 WP-F2 合併後 | 只刪 `BotStatus.hasAvailableAction`（全專案只有測試呼叫，重複 `BotAvailableActions.hasAny`）。七個平行欄位與 `applyAvailableActions` 保留 | 否 | `BotAvailableActionsTests.testApplyAvailableActionsWritesAllSevenFields`（改為直接斷言旗標） |
| UI-13 | 部分 | 新增 `BotStatus.bundledModelName`／`akagiSanmaModelName`／`cloudOnlyModelName` 供 `modelDisplayKey` 引用；刪死分支 `"mortal3p"`；改寫舊時代註解 | 函式層改變（刪 `mortal3p` 分支），正式路徑不可達：全部 modelName 寫入點只產生 mortal、identity.name、akagi-sanma-bc、cloud-only、cloud+… | `ModelNameProducerTests`（三個名稱與產生端一致）；`ToolAndModelGapTests` 刪除 `mortal3p` 斷言 |
| UI-14 | 已做 | `hasAny` 刪除，改 `shown.contains(true)`；區域 `cloudDegraded` 改名 `showsCloudFallback`。未動 UI-05 的判定邏輯 | 否（兩者原本等價） | `UISnapshotTests.testDecisionAlerts`（四種組合）、`testDecisionSidebar` |
| UI-15 | 已做 | 刪 `GameState.riichiBou`，側欄改讀 `kyotaku` | 否 | `UISnapshotTests.testDecisionSidebar`（供託列，fixture kyotaku=1） |
| UI-16 | 已做 | 刪 `Recommendation.isRed`；`accessibleName` 與 `TileImage.back` 註解改成現況 | 否 | Debug／Release build |
| UI-25 | 已做 | 12 個缺 loader 的設定補上 `nonisolated static func load…(from:)`；19 個屬性的 inline 初值與 `init(defaults:)` 都呼叫同一個 loader。預設值與 key 各只剩一處 | 否 | `SettingsStoreInlinePathTests`（inline 與注入版逐項相等、空 suite 預設值）；`SettingsStoreInjectionTests` 既有 3 項；重構前已先跑過（`ui25-before-refactor.log`） |
| UI-05 | 不改，待用戶決策 | — | — | — |
| UI-07 | 不改，待用戶決策 | — | — | — |

## Deviations

1. **UI-12 只做一小部分。** 完整建議要改 `BotStatus` 持有 `BotAvailableActions`，使用處在範圍外：`Services/Bot/NativeBotController.swift`（`botState` 的 `applyAvailableActions`）、`Services/Debug/DebugServer.swift`（`/debug/ui` 逐欄寫旗標）、`Services/MCP/NakiMCPDependencies.swift`（`bot_status` 逐欄讀）。選了保守做法：不動欄位，只刪確定無人使用的 `hasAvailableAction`。完整版留給 Services 工作包合併後再做。
2. **UI-13 的「產生端定義常數」做不到。** 產生端（`AkagiSanmaBot`、`CloudBot`、`NativeBotController`）在 `Services/**`。保守做法：常數放在 `BotStatus`，由 `ModelNameProducerTests` 對產生端的實際輸出做一致性斷言，產生端改名時測試會紅，但產生端本身仍是字面值。
3. **UI-13 刪 `"mortal3p"` 分支**屬函式層行為變更（輸入 `mortal3p` 原回 "Mortal (3P)"，現回原字串），但全專案無產生者、DEBUG fixture 不寫 `modelName`，判定不可達；測試中對應斷言已刪。
4. **UI-01 截圖用 `ImageRenderer`** 在測試內渲染 `StatusBar`。原版寫死主 repo 絕對路徑，已於清理步驟改掉（見「清理」）。
5. **UI-25 的 inline 路徑測試**只能比對 `SettingsStore()` 與 `SettingsStore(defaults: .standard)`（test host 的 `standard` 是共用 suite，測試不寫它），所以非預設值只由注入版既有測試涵蓋，inline 版靠「兩邊呼叫同一個 loader」保證。`cloudAPIKey` 走 Keychain，不在本條範圍。
6. **UI-16 的舊註解是刪除，不是改寫。** `Recommendation.isRed` 與其相關舊註解整段移除，`accessibleName`、`TileImage.back` 的註解改為現況描述。
7. **UI-14 單獨做，未與 UI-05 一起。** UI-05 定案後 `showsCloudFallback` 的判定可能再改。
8. **復驗建議 4 保留不改：** `bundledModelName` 與 `identity.name` 易混淆，但改名牽動面大、收益不足。
9. **復驗後修正（本輪）：** `BotStatus.modelName` 預設值改引用 `bundledModelName`（值相同）；「六個」殘留註解改為「最多七個」或去掉數字；`testApplyAvailableActionsWritesAllSevenFields` 補斷言其餘五欄；`StatusBarBadgeTests` 以 `addTeardownBlock` 刪除自建暫存資料夾（`NAKI_SNAPSHOT_DIR` 不刪）。

## 未驗證

- 所有畫面證據只有 `ImageRenderer` 離屏渲染，沒有 live App 截圖。
- iOS Simulator 只驗 build，沒跑 iOS 測試（`Naki-MTests` 是孤兒 target）。

## 清理

| 項目 | 結果 | 理由與證據 |
|---|---|---|
| `StatusBarBadgeTests` 絕對路徑 | 已改 | 預設寫 `temporaryDirectory` 子目錄並以 `XCTAttachment`（`keepAlways`）附加；只有環境變數 `NAKI_SNAPSHOT_DIR` 存在才另寫一份。測試內不再有家目錄路徑。證據：`grep -rn "/Users/" NakiTests` 無命中（復驗後重跑，0 命中，`fixup-grep.log`）；`cleanup-statusbar.log`（`TEST_RUNNER_NAKI_SNAPSHOT_DIR` 傳入，4 項 0 failures），截圖 `.swfd/logs/irc-ui/cleanup/statusbar-{off,recommend}.png` |
| UI-25 的 12 個 loader | 保留，不合併泛型 | 各 loader 的型別（Bool／String／Date?／Set／enum）與預設值都不同，泛型版需額外傳 key 與預設值，呼叫端反而比一行 `defaults.bool(forKey:)` 更長；現況每個屬性的 inline 初值與 `init(defaults:)` 已呼叫同一個 loader，重複已消除 |
| 函數複雜度 | 無需清理 | 本包新增函數皆為單行 loader 或 `showsRecommendationBadge`，無巢狀；`modelDisplayKey` 為既有函數，僅換常數 |
| 依賴規則 | 無違規 | 新增 loader 只在 `SettingsStore`（App 層）讀 UserDefaults；View 檔改動只換屬性來源；Models 未引入 Views。由全量測試中的既有 lint 測試確認 |

## 強化（變異測試）

工具：手工 harness（`.swfd/logs/irc-ui/mutation/mutate.py`，複製自 s1b-sanma-state，改成只對 `git diff -U0` 新增行產生變異；運算子為關係、邏輯連接詞、三元互換）。每個變異跑 `ToolAndModelGapTests`、`StatusBarBadgeTests`、`UISnapshotTests`、`ModelNameProducerTests`、`BotAvailableActionsTests`。結果 `results.jsonl`，重跑 `rerun/results.jsonl`。

| 檔案 | 總數 | 殺死 | 存活 | 等價 |
|---|---|---|---|---|
| `GameModels.swift` | 5 | 5 | 0 | 0 |
| `GameStore.swift` | 2 | 2 | 0 | 0 |
| `DecisionSidebar.swift` | 4 | 3（首輪）＋1（補測後） | 0 | 0 |
| `SettingsStore.swift`、`StatusBanners.swift`、`TileImage.swift` | 0 | — | — | — |
| 合計 | 11 | 11 | 0 | 0 |

首輪 10 殺 1 存：`DecisionSidebar.swift:684` 內層三元（`compact ? s8 : s10`）互換存活，因快照比對有容差，2pt 差異不會紅。補 `DecisionAlertsPaddingTests`（`testCompactPaddingIsSmallerThanRegularWhenAlertShown`、`testNoPaddingWhenNoAlertShown`）量渲染高度；重跑該變異與外層三元，皆被殺（`rerun.log`）。

後三個檔案沒有變異：新增行只有單行 loader（`?? ""`、`as? Date` 等）、屬性來源替換與註解，不含 harness 的運算子。loader 預設值由 `SettingsStoreInlinePathTests`（空 suite 預設值）涵蓋，**未對 `??` 做變異（harness 不支援）**。

驗收：全量 NakiTests 1039 tests、0 failures（`full-test.log`）。

## 復驗後小修

- 依 irc-bot 復驗應修 2，修正 `ActionType.ryukyoku` 註解（範圍內，僅註解）。
