# WP-0p 測試不寫真實偏好 implementation notes

## 目標
NakiTests 前後，`~/Library/Preferences/org.39c154f25912233a.akagi.plist` 的 sha256 不變。

## 寫入者盤點（test host 啟動到 setUp 之前、以及測試期間）
- `NakiRuntime.init` → `adoptStoredAutoPlayMode` → `AutoPlayAvailability.commit` → `AutoPlayModeStore.save`：同值寫入；乾淨機器上新建 key。
- ContentView `.task` 等 5 秒 → `checkForUpdate(manual: false)` → `settings.lastUpdateCheck` → `SettingsStore.standard`。不經過 `NakiRuntime.init`，距上次檢查超過 24 小時就寫。全套測試實測：`naki.tests.host` 在開始後約 8 秒出現 `lastUpdateCheck`。
- 測試自建的 `NakiRuntime()`／`SettingsStore()`：寫入走 `SettingsStore.standard` 與 `AutoPlayModeStore.defaults`。
- 範圍外仍落 `.standard`：`L10n.defaults`（只讀）、`ObservedMatchSids.shared`（測試以 `redirect` 隔離）、ContentView `@AppStorage`（只讀）、AppKit 視窗 frame autosave。

## 做法
- `SettingsStore.isTestHost` 是唯一判斷；`SettingsStore.standard` 在 test host 改為 `naki.tests.host` suite。
- `AutoPlayModeStore.defaults` 初值取 `SettingsStore.standard`。
- `NakiRuntime.init` 改用 `SettingsStore.isTestHost`。
- `SettingsStoreTests` 的外漏快照改看 `SettingsStore.standard`（外漏只會落到預設落點）。
- `TestHostDefaultsTests`：身分比對（修正停用時失敗）＋寫入落點（未隔離時 skip，不寫真實檔）。

## 驗證
- 修正暫時停用、只跑 `TestHostDefaultsTests`：1 個測試失敗（2 個 assertion），1 個 skip；真實 plist 不變（`.swfd/logs/wp-0p/test-fixoff.log`）。
- 全套 996 個、0 failures（`.swfd/logs/wp-0p/verify-test-full.log`）；基底 15cea92 為 994，本包加 2。

## 已知限制
- `~/Library/Preferences/naki.tests.host.plist` 會長期保留（目前 107 bytes，含 `naki.autoPlayMode`、`naki.lastUpdateCheck`）。它是 test host 24 小時更新節流的依據，不應自動刪；缺點是跨次執行帶狀態。
- test host 啟動 5 秒後仍會連 GitHub 查更新；真實設定關掉 `autoCheckUpdate` 擋不住，因為 test host 改讀 host suite。
- test host 內兩處雙來源：`pinMajsoulServer`（`@AppStorage` 讀 `.standard`，`SettingsStore` 讀寫 host suite）；`naki.appLanguage`（`L10n.defaults` 讀 `.standard`，`SettingsStore.appLanguage` 寫 host suite）。
- `mutation-report.md` 的 M5（`NakiRuntime.init` 的 `isTestHost` 恆 `false`）未驗證：`NakiRuntime.init` 的 test host 分支沒有測試保護。
- `ObservedMatchSidsTests.swift` 不改：`.shared` 預設仍是 `.standard`（`command/Services/**` 不在範圍），測試已用 `redirect` 換成獨立 suite 並還原。

## Deviations
- 未採建議的「把 `isTestHost` 提到 `adoptStoredAutoPlayMode` 之前」：更新檢查的寫入不經過 `init`，單改 `init` 擋不住；改預設落點後 adopt 只寫 host suite，再加一個分支只是多一個 seam。
- `LogManager` 的 test host 判斷仍是第二份（`command/Services/**` 不在可改範圍）。
- 本檔不在派工可改清單，依專案 CLAUDE.md 慣例新增。
- 新增 `SettingsStore.isTestHost`（派工只列 `standard` 定義）：把 test host 判斷收斂到一處，`standard` 與 `NakiRuntime.init` 共用。
- 執行中曾誤在主 repo 建 `.swfd-tmp-SettingsStore.swift.bak`（備份路徑寫錯），隨即刪除；記錄於 `.swfd/logs/wp-0p/main-repo-untracked.txt`。
