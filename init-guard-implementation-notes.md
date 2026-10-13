# init-guard 實作筆記

目標：讓「test host 下 `NakiRuntime.init` 不啟動 debug server、不啟動 AutoPlayEngine」有測試保護（WP-0p 強化 M5 指出的缺口）。

## 已修改
- `command/App/NakiRuntime.swift`：新增唯讀 `isAutoPlayEngineRunning`（`autoPlayEngine != nil`）與 `isDebugServerStarted`（`debugServer != nil`，主線授權追加），不加 setter、不加注入參數、不改 private 屬性可見度。
- `NakiTests/NakiRuntimeTestHostTests.swift`：斷言 `SettingsStore.isTestHost`、`store.isDebugServerRunning == false`、`isDebugServerStarted == false`、`isAutoPlayEngineRunning == false`。
- `CLAUDE.md`：`naki.tests.*` 空殼 plist 的描述改成現況（2026-10-13 已清除 235 個，備份在 `.swfd/logs/prefs-cleanup/`，host plist 保留）。

## 已驗證（log 在主 repo `.swfd/logs/init-guard/`）
- 追加 `isDebugServerStarted` 後重跑四類與 macOS Debug build 皆通過（`test.log`、`build-macos-debug.log`）；Release 與 iOS 未重跑（改動只是唯讀屬性，未驗證）。
- 四類（新測試、`NakiRuntimeWiringTests`、`TestHostDefaultsTests`、`BotToolsTests`）Debug 共 10 tests、0 failures：`test.log`。
- macOS Debug、macOS Release、iOS Debug（Naki-M）build 皆 BUILD SUCCEEDED：`build-macos-debug.log`、`build-macos-release.log`、`build-ios-debug.log`。
- 真實 plist 內容前後相同：第一輪 sha256 相同（`b375488a…308d`，`sha-before.txt`、`sha-after.txt`）；追加後 sha 變動，改以內容比對（見已知風險）。
- 測試前 `/game/state` 的 `pending` 為 null：`pending.txt`。測試後 `pgrep` 只剩用戶原本的 Naki（PID 61826）。

## 未驗證
- 追加 `isDebugServerStarted` 後未重跑 Release 與 iOS build。
- plist sha 第二輪未落盤於本包原有紀錄；歸因由主線完成。
- 變異未執行。

## 強化（只做靜態分析，未執行變異）
- 條件反轉 `if !isTestHost { startAutoPlayEngine() }` → `if isTestHost`：`startAutoPlayEngine()` 同步設定 `autoPlayEngine`，故 `isAutoPlayEngineRunning` 為 true，`isAutoPlayEngineRunning` 那條斷言紅。可靠。
- 條件反轉 `if !isTestHost { startDebugServer() }` → `if isTestHost`：`startDebugServer()` 同步設定 `debugServer = server`，故 `isDebugServerStarted` 為 true，`isDebugServerStarted` 那條斷言紅，可靠。`isDebugServerRunning` 要等 `.ready` 回呼（`DebugServer.swift:161`），不是紅的依據。
- 刪除 `isTestHost` 判斷（兩處都無條件啟動）：兩條同步斷言（引擎、debug server started）皆紅。

## 已知風險
- 新測試證明的是「建構當下沒有啟動」，不證明之後不會啟動。
- 追加 `isDebugServerStarted` 後 plist sha256 變成 `d607339a…3ce2`（mtime 21:49:04）。主線歸因：以 `plutil -convert xml1` 正規化後與 `.swfd/logs/wp-0p/plist-backup-20261013-174526.plist` diff 為空，內容無鍵變動；無測試執行時 mtime 仍持續更新（21:49:24），是 cfprefsd 因 live Naki 寫入同值而重新序列化，sha 變動屬序列化差異。此歸因由主線完成，本包未重跑驗證。

## Deviations
- 強化改為只做靜態分析、不執行變異：變異會在 test host 綁 8765，與 live Naki（PID 61826）衝突。派工文件明示。
- 原本不為 debug server 另加縫；主線裁決後追加唯讀 `isDebugServerStarted`，補上同步可見的保護。
