# test-defaults-leak implementation notes

## 根因
測試的隔離 suite 結束時已呼叫 `removePersistentDomain`，但它只清內容、不刪 `~/Library/Preferences/<suite>.plist`。對照探針：寫入、移除後檔案仍在（42 bytes 空殼）。所以不是「忘了清」，是清法不刪檔，11,700 個空殼由此累積。

## 做法
- `NakiTests/IsolatedDefaults.swift`：`removeIsolatedSuite(name)` 先拒絕非 `naki.tests.`／`naki.test.` 前綴（`XCTFail`，不碰 `.standard`），再 `removePersistentDomain`＋`synchronize`，最後刪該 suite 自己的 plist。
- 既有各處 `removePersistentDomain` 全改呼叫它；原本沒清的三處補清：`SettingsStoreInlinePathTests`（改用輔助）、`AutoRematchEngineTests.testDefaults`（固定名 `naki.tests.fullauto`，補 defer）、`UITestIsolationTests` 的固定名 `naki.tests.ui`。固定名 `naki.test.sids.{cancel,backfill,latest}` 走既有 `makeIsolatedStore`，現已刪檔。
- 整包結束（`testBundleDidFinish`）再對本次追蹤過的 suite 加 `naki.tests.host` 掃一次並多刪幾輪，因為 cfprefsd 的延遲寫入會在刪檔後把空殼補回。

## 驗證（xcodebuild test -only-testing:NakiTests，worktree 2d02a03 + 本變更）
- 測試數 1178（基準 1177，加 0 個測試；差 1 為 main 之後的既有差異，未驗證來源），0 failures。
- 修前：一次全量留下約 140 個。
- 修後（無其他 worktree 的 xcodebuild／Naki host 並行，由取樣檔確認）：同一版本三次全量，2 次殘留 0，1 次殘留 6（含 `naki.tests.host`、`naki.tests.ui`，疑似 host 在掃描輪次中途被終止）。
- 另一版掃描（先刪一次再兩輪）四次中 1 次 0，3 次殘留 2（`web.keepalive`、`wp8`）。結論：殘留量與掃描時機有關，**未達成每次 0**。

## Deviations
- 計畫要求「以 `addTeardownBlock` 建 suite 的共用輔助」。既有各處已是 `setUp/tearDown` 或 `defer` 配對，只缺刪檔，所以只換掉清理呼叫，沒有改建立方式（較保守、diff 小）。
- 計畫要求跑完 `ls ~/Library/Preferences | grep -c '^naki\.tests\?\.'` 為 0。實測不穩定達成，原因推測為最後幾個測試的 plist 被 cfprefsd 在 host 結束前後補寫，**未驗證**。殘留上限從每次約 140 降到 0–6，累積速度降兩個數量級。
- 掃描會多刪 `naki.tests.host`（host 啟動時重建）。若另一個 worktree 同時在跑測試，會刪到對方的 host 空殼，無害但存在。
