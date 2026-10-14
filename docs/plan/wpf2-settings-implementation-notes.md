# WP-F2 設定分頁本體 implementation notes

基底 main `b8e0d95`，分支 `wp-f2-settings`，未 commit。log 在主 repo `.swfd/logs/wp-f2/`（下稱 L）。

**狀態：依硬性安全規則 4 停止。** 手動 smoke 後真實偏好檔 xml diff 出現 `NSWindow Frame` 以外的變化（見「已知風險」第 1、2 條），已停止一切會啟動 App 的執行，未自行改動真實偏好檔。macOS UI 測試另因 Automation Mode 需要用戶驗證而無法執行。

## 已修改
- `AdvancedSettingsSheet`：`SettingsTab`（general／connection／ai／developer）加 `page(_:)` 是分頁歸屬唯一定義點。macOS 是 `TabView` 分頁、單欄、寬 600 高 560，無自訂標題列與完成鈕。iOS 單頁捲動四段，「開發者」包 `DisclosureGroup` 預設折疊。雲端拆成 AI 頁「雲端推論」與開發者頁「雲端 API」，生效狀態列兩頁都有。全部 `@State`、`.task(id: cloudProbeToken)` 與 Header 草稿都留在根 View。視窗辨識用 `SettingsWindowRegistrar`。GroupBox 以 `FullWidthGroupBoxStyle` 撐滿寬度。
- `MajsoulConnectionSettingsBox`：草稿改 `@Binding`，`HeaderRow` 改 internal，加 `rows(from:)`。說明句與提示照 §8.4。
- `ContentView`：macOS 齒輪改 `SettingsLink`，移除 macOS 設定 sheet。`.onChange(of: settingsOpenRequest)` 呼叫 `openSettings()`。iOS 齒輪與伺服器選擇畫面字串改名。
- `NakiApp`：`Settings` scene，`.appLocale()` 寫在 `.environment(\.naki, …)` 之前。
- `UIState.settingsOpenRequest`：`apply(screen: .settings)` 每次加 1。
- `SettingsWindowAction`（`NakiActions.swift`）：可見、關閉、截圖，macOS 讀 weak 登記的視窗，iOS 可見回 nil。`CaptureScreenshotAction.png(of:)` 抽出共用。`windowScreenshot` 註解補設定視窗截不到分頁列。
- `NakiMCPDependencies.settingsWindow`：預設 `.unavailable`，三處測試建構點不必改。`NakiRuntime` 注入真實值。
- `DebugServer`：`DebugHTTPRequest.query`。`/debug/ui` 的 `showAdvancedSettings` 改回報實際可見，`screen` 不是 `settings` 時在回應前關設定視窗。`/screenshot?window=settings` 新增，不可見回 `{"error":"settings window not visible"}`。
- `Localizable.xcstrings`：新增 23 個 key、刪 21 個舊 key，四語系齊。沿用「設定」「還原預設」並更新註解。
- 測試：`DebugUIStateTests` 照 §8.2 改。新增 `NakiUITests/NakiUITestCase.swift`、`SettingsWindowUITests.swift`，以及 `Naki-MUITests/NakiMUITestCase.swift`、`SettingsSheetUITests.swift`。既有 UI 測試全部改繼承基底。
- 文件：`docs/ui-reference/implementation-decisions.md` 新增一節。設計文件 §8 有四處標「WP-F2 實測」。

## 已驗證
- 四個 build 都 `BUILD SUCCEEDED`（最後一次改碼之後），證據在 L 的 `build-macos-debug.log`、`build-macos-release.log`、`build-ios-debug.log`、`build-ios-release.log`。iOS 用 `generic/platform=iOS Simulator`。
- 兩條 build-for-testing 都 `TEST BUILD SUCCEEDED`：L 的 `bft-macos.log`、`bft-ios.log`。
- NakiTests 全套 1031 個，2 failures，都是 `UISnapshotTests.testActionDelayBounds` 的 light／dark（L 的 `test-full.log`）。成因是「出手延遲」改名，已撤回，見 Deviations。撤回後未重跑，見「未驗證」。
- iOS UI 測試（iPhone 17 模擬器）：
  - 全 target 跑一次是 15 個，3 skipped，1 failure。失敗的是 disclosure identifier 蓋掉 `settings-page-developer`（L 的 `uitest-ios.log`）。
  - 修正後 `SettingsSheetUITests` 單獨跑 `** TEST SUCCEEDED **`（L 的 `uitest-ios-settings.log`）。這次執行早於 `FullWidthGroupBoxStyle`，而那個樣式改的是兩平台共用的 `page(_:)`。
  - 修正後**沒有重跑全 target**，所以驗收要求的那一條全 target 指令仍未達成。
  - 每次啟動都經 `/bot/status` 確認模式為「關閉」。
- 手動 smoke：Debug App 以兩個隔離環境值與 argument domain 啟動，用 `open --env` 加 `--args`，模式確認是「關閉」（L 的 `smoke-launch.log`）。
  1. 前景 `POST settings`：回應 false，`GET` 第一次輪詢就是 true。螢幕上視窗從 1 個變 2 個（L 的 `smoke-1.log`）。
  2. 關閉後 `GET` 輪詢到 false，再送一次能重開（L 的 `smoke-2.log`）。關窗用的是 AX 紅鈕，⌘W 沒有驗到，見 Deviations。
  3. 插件 sheet 與設定視窗可以並存。不帶參數的 `/screenshot` 截到設定視窗，推翻設計預期。關閉設定後 `?window=settings` 回錯誤（L 的 `smoke-3.log`）。
  4. 背景時送 settings：視窗照樣開出，App 不取得前景，`GET` 與 AX 和 CGWindowList 一致（L 的 `smoke-4.log`）。
- AX 實測：
  - 標題列跟著分頁變（L 的 `ax-tabs.log`）。
  - 選單「設定⋯ ⌘,」由系統提供（L 的 `ax-open-menu.log`）。
  - 選單連按兩次、`POST settings` 連送兩次，設定視窗都只有一個。`settings→plugins` 與 `settings→none` 在回應前就關了。只送 `language` 時視窗不動。以上見 L 的 `ax-http-integration.log`。
  - 語言 ja→English 時，分頁名、標題列與 GroupBox 內文都跟著換（L 的 `ax-language.log`）。
  - 雲端生效狀態列在開關關閉、缺 key 兩種狀態下，AI 與開發者兩頁文字相同。開關寫進的是 `naki.tests.ui`（L 的 `ax-cloud-cross-page.log`）。
- 四頁的 GroupBox 歸屬與演示頁一致，截圖是 L 的 `shots/settings-{general,connection,ai,developer}.png`，用 `screencapture -l` 截，是深色。
- §8.6 不變條件：
  1. 設定只有一個寫入點：分頁內沒有設定值副本，只有綁定與 Action。開關寫入落在 `naki.tests.ui`（L 的 `ax-cloud-cross-page.log`）。草稿在套用前不寫入設定（L 的 `smoke-draft.log`）。
  2. 開啟請求與可見分開：單測 `testOnlySettingsIncrementsOpenRequest`、`testSettingsFieldReportsVisibilityNotRequest`、`testUnavailableSettingsWindowHasNoVisibility`、`testStatusPayloadReportsFlagsAndLanguage` 在 L 的 `test-full.log` 都通過。另有 smoke 1、2、4。
  3. identifier 保留：比對基底與工作樹 `command/` 的 `accessibilityIdentifier` 字面值，基底有而工作樹沒有的是 0 個；`settings-done-button` 只剩 iOS 一處（L 的 `ids-compare.log`）。
  4. 生效狀態列兩頁都有：L 的 `ax-cloud-cross-page.log` 與 iOS `uitest-ios-settings.log`。
  5. 切頁不丟草稿：L 的 `smoke-draft.log` 用鍵入事件驗，第一段用 AX 直接設值的結果作廢。
  6. 設定視窗跟隨 App 語言：L 的 `ax-language.log`。
- 閘：`ui-token-gate.sh` exit 0；`xcstrings-gate.py` 401 keys、0 failures；`sentence-length.sh` 0 個 OVER。分別見 L 的 `ui-token-gate.log`、`xcstrings-gate.log`、`sentence-length.log`。
- 舊字串退場：§8.5 改名清單的舊字串，在 `command`、`Naki`、`Naki-M` 的程式碼中 0 hit。例外是「基準延遲」，見 Deviations。
- Keychain：`security find-generic-password -s org.naki.cloud-inference` 的屬性前後相同，含 mdat。`.uitest` service 前後都不存在。證據是 L 的 `keychain-before.txt`、`keychain-after.txt`、`keychain-uitest-*.txt`。

## 未驗證
- macOS UI 測試全部沒有執行。runner 初始化時 `Timed out while enabling automation mode`。`automationmodetool` 回「This device requires user authentication to enable Automation Mode」（L 的 `uitest-macos-single.log`、`automationmode-status.txt`）。啟用要用戶本人執行 `sudo automationmodetool enable-automationmode-without-authentication`，本包不改系統安全設定。`SettingsWindowUITests` 只確認編得過，查詢方式依 AX 實測調整過。
- NakiTests 全套在撤回改名、GroupBox 樣式、disclosure identifier 與 tabItem identifier 移除之後沒有重跑。停止規則生效後不再啟動 App（test host 也是 App）。
- iOS UI 測試全 target 在修正後沒有重跑；`SettingsSheetUITests` 在加 `FullWidthGroupBoxStyle` 之後也沒有重跑。
- ⌘W 關閉：以 `CGEvent.postToPid` 送出沒有生效，當時 Naki 在前景，原因未查明。smoke 2 改用紅鈕。
- 淺色截圖：`-AppleInterfaceStyle Light` 只影響 `cacheDisplay` 的 HTTP 截圖（白底），真實視窗仍是系統的深色。
- `UISnapshotTests` 撤回改名後沒有單獨重跑。

## 已知風險
1. **真實偏好檔被改**（規則 4，停止原因）。L 的 `plist-diff.txt` 有三處變化，檔案 mtime 是 01:58:24，正是本包收掉手動啟動 App 的時間：
   - 新增 `NSWindow Frame com_apple_SwiftUI_Settings_window`：規則允許。
   - 新增 `com_apple_SwiftUI_Settings_selectedTabIndex`（值 2）：SwiftUI `Settings` 的 `TabView` 自己記住上次的分頁，寫進 `.standard`，隔離鉤子管不到。之後任何 UI 測試只要開過設定都會寫它。要避免就得給 `TabView` 一個 selection 綁定，但那會改變「停在上次分頁」的系統行為（§8.6 第 2 條、§8.7），需要主線裁決。
   - 刪除 `naki.observedMatchSids`：舊值是 F1 notes 記的測試殘留 `sync-sid`／`v1`。Naki 程式在 App 執行期間不會刪它，只有測試呼叫的 `reset()` 會刪。推測是 F1 當初直接覆寫 plist 檔還原，cfprefsd 快取仍是刪除後的狀態；本包寫入視窗 frame 時，cfprefsd 把快取落盤。這是推測，未驗證。備份在 L 的 `plist-backup/akagi-before.plist`，未自行還原。
2. **真實 log 被輪替**：兩次手動啟動讓 `LogManager` 刪掉 170 個 session 目錄，另有 2 個只剩 `games/`（L 的 `naki-logs-diff.txt`、`naki-logs-trimmed.txt`）。啟動前整份備份在 L 的 `logs-backup/Naki/`，共 62M，可以還原。這是 F1 已記的風險。
3. 開發者頁的生效狀態列寫「還缺：上方的「啟用雲端推論」開關」，但開關在 AI 頁。字串在 `CloudInferenceConfig`，不在本包可改清單。
4. 不帶參數的 `/screenshot` 在設定視窗開在前景時會截到設定視窗。依派工不改。
5. `?window=settings` 的 PNG 經 `cacheDisplay`：內容完整，背景透明、深色模式文字為白色，疊深色底可見（`.swfd/logs/wp-f2-takeover/verify/http-settings-on-dark.png`）。原記載「只畫得出勾選框」有誤，已由復驗更正。

## Deviations
- 「基準延遲 → 出手延遲」沒有改：
  - 引用點實際在 `ContentView` 的 `ActionDelayStepper` 寬版。設計文件寫的是 `AdvancedSettingsSheet` 705、710。
  - 這個元件有快照 `ActionDelayStepper_settings-fastest`。改名後 light／dark 差異 866、888 像素，超過千分之 15 的門檻（L 的 `test-full.log`）。
  - 派工寫「UISnapshotTests 不含設定頁、不重錄」。保守選項是撤回這個改名、保留舊 key，交主線決定要改名加重錄兩張，或維持現狀。
- iOS UI 測試的 setUp 不寫 suite。模擬器上 runner 與 App 是不同 container，寫不到。模式、固定伺服器與語言改走 argument domain。實測 `UserDefaults(suiteName:)` 也讀 argument domain，未產生 suite 檔（L 的 `argdomain-probe.log`）。macOS 兩者都做。
- 啟動前加固定伺服器（`PinMajsoulServer`）：新 suite 沒釘服時會先出伺服器選擇畫面，主版面、工具列與 `settingsOpenRequest` 的讀者都不會出現。
- `DecisionHUDTouchTests` 改成 opt-in，要設 `NAKI_UI_TEST_ALLOW_WEBVIEW_TOUCH=1` 才跑。原因是它在雀魂頁面上點擊、拖曳、輸入，違反「不得在遊戲頁面操作」。
- `settings-tab-*` identifier 沒有採用：`.tabItem` 內掛的 identifier 實測傳不到 toolbar 按鈕，UI 測試改以標籤查。
- `settings-developer-disclosure` 掛在 label 上：掛在 `DisclosureGroup` 會蓋掉內容的 `settings-page-developer`（L 的 `uitest-ios-diag.log`）。
- 為了 UI 測試另加兩個 identifier：`add-majsoul-header-button`、`majsoul-header-name-field`。
- `/screenshot?window=` 收到未知值時回 400 並列出可用值，不默默退回不帶參數的截圖。
- smoke 沒有寫成 UI 測試，改以手動啟動加 curl 與 AX 工具完成：macOS UI 測試無法執行。AX 工具只對 Naki 的 pid 操作，並拒絕「套用並重新載入」「刪除 Bot」「重建 Bot」「MCP 停止」。工具原始碼在 L 的 `tools/`（`ax.swift`、`winlist.swift`、`axcheck.swift`，以 `swiftc` 編譯）。原本寫好的 `SettingsSmokeUITests` 已刪，沒有留下未執行過的程式。
- GroupBox 加了 `FullWidthGroupBoxStyle`：單欄頁面的系統 GroupBox 只貼著內容寬，與演示頁不符。
- 設計文件超出派工字面的兩處：派工只允許在「推測」被推翻時改 §8。不帶參數截圖選窗（§8.2「截圖」與 §8.8 smoke 3）與 `settings-tab-*` identifier（§8.8）推翻的是沒有標「推測」的敘述，仍標「WP-F2 實測」，避免下一包照錯的敘述驗收。「推測成立」與「未驗證補上實測值」兩處已還原，內容只記在 `implementation-decisions.md`。
