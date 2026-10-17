# WP-C 插件移除原地確認 implementation notes

分支 `wp-c-confirm`，基底 main 0ef66df（v2.18.0），未 commit。log 在主 repo `.swfd/logs/wp-c/`。

## 已修改

- `command/Views/PluginsPageView.swift`
  - `pendingRemoval: String?` 換成 `RemovalConfirm`（同檔、`nonisolated struct`、internal）。狀態 `pending`／`armedAt`；操作 `arm`、`confirm`（0.28 秒內或目標不符回 false，成功即清狀態）、`cancel`、`expire`（只清同 id）、`switchTarget`。時間一律由呼叫端注入。
  - 兩平台的 `.confirmationDialog(removeDialogTitle, item: $pendingRemoval, …)` 與 `removeDialogTitle`／`removeDialogActions`／`removeDialogMessage` 移除。
  - 有效與無效插件兩顆「移除」共用 `removeControl(id)`：未確認時是原本的「移除」鈕（`plugin-remove-<id>`，無效分支因此補上）；確認時同位置換成「取消」（`.keyboardShortcut(.cancelAction)`）與「移除「id」」，下方一行既有說明句。容器掛 `.animation`，展開 `PanelLayout.valueChange`、退回 `PanelLayout.exit`，經 `PanelLayout.animation(_:reduceMotion:)`。
  - 確認：`confirm` 回 true 才在 `withAnimation(valueChange)` 內呼叫 `removePlugin`，保留 `selectedPluginId` 清除。
  - 生命週期掛在兩平台共用的 `tabBody`：`.task(id: removal)` 睡 4 秒後 `expire`，被取消直接 return；`selectedPluginId` 變更呼叫 `switchTarget`；換分頁 `cancel`。
- `NakiTests/PluginRemovalConfirmTests.swift`（新，清理後 5 tests，各標 §5 WP-C 編號；原 9 條中重複與常數同義反覆者已併入）。
- 未改：Actions、Runtime、Registry、`Localizable.xcstrings`、`project.pbxproj`。

## 已驗證

| 項目 | 結果 | log |
|---|---|---|
| 插件相關單測（含新測試） | 清理後由獨立復驗實測：插件兩個 class 20 tests 0 failures | `cleanup-*.log` |
| 全套 NakiTests | 清理後由獨立復驗實測 1018 tests、0 failures | `cleanup-*.log` |
| macOS Debug／Release、iOS Simulator Debug／Release | 4 個 BUILD SUCCEEDED | `build-*.log` |
| `scripts/ui-token-gate.sh` | 7 項 0 hit | `gate.log` |
| `confirmationDialog` 只剩「允許插件送出遊戲動作？」；「復原」0 hit；兩分支都經 `removeControl` 帶 `plugin-remove-<id>` | 符合 | `grep-acceptance.txt` |
| 真實插件目錄前後 `ls -la` | 相同 | `plugins-dir-before.txt`／`plugins-dir-after.txt` |
| 真實偏好檔 xml | 無差異 | `prefs-before.xml`／`prefs-after.xml`／`prefs-diff.txt` |
| 測試結束後無殘留 test host／xctest 程序 | `pgrep-after.txt` 為空 | `pgrep-after.txt` |

## 未驗證

- 原地確認列實機外觀、寬度變化動畫、清單合攏動畫。
- Esc 取消：插件頁是 sheet，Esc 是否先被 sheet 吃掉未實測。
- 離開頁面後再回來確認面不在：依 sheet 關閉時 `@State` 釋放推論，未實測。
- `.task(id:)` 4 秒逾時與取消的實際時序：只驗了 `expire` 的邏輯層。
- 刪除失敗時那一列留下：狀態機層已鎖「確認成功即收起」，列是否留下由 `rescanPlugins` 決定，未在 UI 驗。
- 以上待 WP-F 隔離鉤子後補 UI 測試。
- 清理與強化已執行：清理見 `.swfd/logs/wp-c/cleanup-*.log`，變異測試見 `.swfd/logs/wp-c/mutation-report.md`（9 變異全殺、M9 靜態）。

## 已知風險

- **主線裁決：非回歸，基底同為執行間雜訊。** 驗收 4 字面未達：驗收要求 `UISnapshotTests` 32 張 diff=0；本包與基底都未達，32 張都在 `PixelDiff.thresholdPermille` 內通過。三次執行（基底 `snapshot-diffs-base.txt`、本包 `snapshot-diffs.txt`、本包重跑 `snapshot-diffs-change2.txt`）的非 0 項：

  | 快照 | 基底 | 本包 | 本包重跑 |
  |---|---|---|---|
  | ActionDelayStepper_toolbar-slowest dark | 0 | 19 | 0 |
  | ActionDelayStepper_toolbar-slowest light | 0 | 18 | 0 |
  | BotFailureBanner dark | 1 | 1 | 1 |
  | BotFailureBanner light | 8 | 8 | 8 |
  | PageLoadFailureBanner dark | 261 | 261 | 261 |
  | PageLoadFailureBanner light | 611 | 0 | 611 |

  `BotFailureBanner` 兩張與 `PageLoadFailureBanner` dark 三次同值，是 baseline 既有偏差；`ActionDelayStepper` 兩張與 `PageLoadFailureBanner` light 在 0 與非 0 間跳動，是執行間雜訊。這些 view 都不含插件頁，判定非本包回歸。
- 「移除插件？」key 成孤兒，留在 `Localizable.xcstrings`，由 WP-D 處理 key 進退場。
- 用戶 Naki（派工記載 pid 61826）在本包執行期間不存在（`ps-61826.txt` 回 rc=1；`pgrep-before.txt` 無 Naki；loopback 無回應），測試未與 live App 並存。

## Deviations

1. 設計文件要求 7 條 UI 測試，改為純邏輯狀態機單測（統帥代決）。理由：UI 測試會啟真 App、綁 8765、寫真實設定，且用戶 Naki 可能在跑。單測覆蓋設計文件第 1、2、4、5、7 條；第 3 條驗 `expire` 不清新目標與逾時常數；第 6 條（Esc、離頁）只在 View 層掛 `.keyboardShortcut(.cancelAction)` 與 `.task(id:)`，列未驗證。ADR 由主線補。
2. `.task(id:)` 用整個 `RemovalConfirm`（含 `armedAt`）而不是只用 `pending`。理由：每次 arm 都保證重新起算 4 秒，不依賴 `pending` 先經過 nil。用 `pending` 在現行流程也會重啟，這是較保守的寫法，不是修已知問題。
3. 新增 `switchTarget` 呼叫於 `selectedPluginId` 變更，並在換分頁時 `cancel`。理由：不收起的話，改選 B 再於 4 秒內選回 A，A 的確認面會重現（第 4 條的破口）；換分頁視同離開確認脈絡。
4. 確認列兩顆鈕加 `plugin-remove-cancel-<id>`／`plugin-remove-confirm-<id>`，給 WP-F 的 UI 測試用；不是翻譯字串。
5. 派工寫 `.animation(..., value: pending)`，實作用 `value: armed`（`pending == id` 的每列 Bool）。同一列內兩者等價，且避免別列的 pending 變化觸發本列動畫。
