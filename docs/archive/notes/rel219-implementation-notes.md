# 2.19.0 發版準備 實作筆記

日期：2026-10-15。基底 4761f6e，worktree 分支 release-2.19.0。未 commit、未 tag、未 push、未建 release。

## 做了什麼
- `MARKETING_VERSION` 2.18.0 改 2.19.0，project.pbxproj 共 12 處，舊值剩 0 處。`NakiAppVersion` 只讀 bundle，沒有寫死版本。
- 新增 `docs/release-notes/v2.19.0.md`。
- `CLAUDE.md` 基準表 App version 與測試數更新。

## 驗證
- macOS Debug build 成功：`.swfd/logs/rel219/build-macos.log`。
- iOS（Naki-M，generic/platform=iOS，Debug，不簽名）build 成功：`.swfd/logs/rel219/build-ios.log`。
- NakiTests 全量 1138 個、0 failures：`.swfd/logs/rel219/test-full.log`；三條架構 lint 測試與 `testTraceRedacts...` 皆未紅。
- Release 產物：macOS 與 iOS 的 `CFBundleShortVersionString` 皆為 2.19.0；SHA256 見 `.swfd/logs/rel219/artifacts/SHA256SUMS.txt`。

## Deviations
- 沒有執行 `release.sh`，只手動照其 build 與 package 段產出 dmg、zip、ipa；Release 的 DerivedData 與 archive 放 scratchpad，不放 worktree。
- `release.sh` 會改 README 三份的版本 badge（仍是 2.18.0）。任務範圍不含 README，保守起見未改；發布前需由主線決定是否同步。
- 沒跑 `release.sh` 的 Test gate 與 preflight，改用 Debug scheme 全量 NakiTests；未跑 UI 測試與 plugin regression、ui-token-gate、xcstrings-gate（未驗證）。
- 產物為 ad-hoc／未簽名，未做 live 啟動驗證（不得啟動連線雀魂的實例）。

## 主線裁決（2026-10-15）
- README badge：release.sh 本來就同步 README.md，2.18.0 時三語 README 也都已同步，故三份一併改為 2.19.0。
- 獨立復驗（2026-10-15，`.swfd/logs/rel219/verify-*.log`）已補跑 ui-token-gate 7/7、xcstrings-gate 401 keys 0 failures、plugin-regression 29/29、plugin-v2-regression 21/21、NakiTests 1138/0；產物三件 shasum 與版本、JS 資源逐 byte 一致。
- release notes 的 kan 條目原照抄 878ccbe commit message，寫成 null 會回錯誤；實際 null 視同沒給（`GameToolKanValidationTests.testJSONNullKanArgumentsAreTreatedAsOmitted`），已更正。
- lint-notes.py 在 v2.19.0 tag 建立前必因 compare 連結失敗，其餘模板檢查以替換連結的探針通過。
