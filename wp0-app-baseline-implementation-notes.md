# WP-0 元件快照 baseline 實作紀錄

分支 `wp-0-app-baseline`（基底 `1dceb6d`）。log 在主 repo `.swfd/logs/wp-0/`。

## 做了什麼

- `NakiTests/UISnapshotTests.swift`：固定 fixture 以 `ImageRenderer`（scale 2、固定 frame、`zh-Hant`、`.windowBackground` 不透明底）渲染元件，與 `docs/ui-reference/app-baseline/` 逐像素比對，差異 ≤1.5% 通過。淺／深色各一份，兩者都同時設 `\.colorScheme` 與 `NSAppearance.performAsCurrentDrawingAppearance`（`contentBackground` 是 `NSColor` 動態色）。
- 比對器 `PixelDiff`：兩邊都畫進 sRGB RGBA8 premultiplied context 再逐像素比，任一通道不同算一個差異像素；門檻用整數比較 `differing * 1000 <= total * 15`。
- 檔名：`<元件>_<狀態>_<寬>x<高>@2x_macOS<主>.<次>_zh-Hant_<light|dark>.png`。OS 版本進檔名，換 OS 後 baseline 視為不存在而失敗，需重錄。
- record 模式：`TEST_RUNNER_NAKI_SNAPSHOT_RECORD=1 xcodebuild test ... -only-testing:NakiTests/UISnapshotTests`。test host 讀到的是去掉前綴的 `NAKI_SNAPSHOT_RECORD`；錄製的那次每張都 `XCTFail`，不會被當成綠燈。
- 兩條渲染性質測試：同一 fixture 連續渲染兩次差異為 0；淺色與深色角落像素不同。

## 覆蓋清單（28 張＝14 種 × 淺／深）

| 測試 | 畫面 | 尺寸（pt） |
|---|---|---|
| `testDecisionSidebar` | `DecisionSidebar` 寬版、窄版（東 2 局 1 本場、可打可立直、5 個推薦） | 380×600、220×560 |
| `testDecisionCard` | 打牌 8p、吃（含牌組說明）、窄版赤五 | 348×120 ×2、200×80 |
| `testOptionList` | 寬版（顯示 3、還有 1 個）、窄版（顯示 2、還有 2 個） | 348×160、200×90 |
| `testDecisionAlerts` | 雲端退化、自動打牌停滯、三麻無推薦 | 348×56 |
| `testBanners` | `PageLoadFailureBanner`、`BotFailureBanner`、`JSInjectionFailureBanner`、`LiqiParseFailureBanner` | 760×70 |

28 張都用 Read 人工看過，內容完整。`PageLoadFailureBanner` 的 `.bordered` 按鈕實測畫得完整。

不覆蓋：`UpdateAvailableBanner`（icon-only `.borderless` 關閉鈕畫成禁止符號佔位；`.borderedProminent`、`.bordered` 兩顆正常；圖證 `.swfd/logs/wp-0/excluded/`）、`StatusBar`、插件頁、`LogPanel`、工具列、設定頁、iOS 版面。

## 驗證

| 項目 | 結果 | log |
|---|---|---|
| 四條契約單元測試（合成 200×100 圖） | 通過 | `test-compare-1.log` |
| 重錄後比對 28 張 | 全部 diff=0 | `test-compare-1.log` |
| 改真實 baseline 0／1／960／961 像素（400×160，1.5%＝960） | diff 0 過、1 過、960 過、961 紅 | `tamper-control0.log`、`tamper-1px.log`、`tamper-960px.log`、`tamper-961px.log` |
| baseline 改成 400×162 | 紅（sizeMismatch） | `tamper-resize.log` |
| baseline 刪除／換成非 PNG | 紅（unreadable） | `tamper-missing.log`、`tamper-garbage.log` |
| 改檔前後 baseline sha256 | 一致 | `baseline-sha-before-tamper.txt`、`baseline-sha-after-tamper.txt` |
| 全套 NakiTests（強化前） | 1007 tests、0 failures（基底 996＋本包 11）；強化後本包 13 條，全套現況由主線合併閘重跑 | `test-full.log` |
| macOS Debug／Release build | 皆 SUCCEEDED | `build-macos-debug.log`、`build-macos-release.log` |

## Deviations

1. **契約證據改用整個 class 執行。** 只跑 `testDecisionCard` 時，渲染結果與整個 class 執行時錄的 baseline 有 ±1 色階差（反鋸齒邊緣，每張 44–124 像素；400×160 那張量到 44 像素＝0.07%，其餘占比未逐張驗證，`diag-isolated-record.log` 沒有逐張計數）。整個 class 與全套執行時 28 張皆為 0。比對仍維持「任一通道不同就算差異」，不加容差：加容差會讓契約 1（改 1 像素計數＝1）失真。保守做法是記錄雜訊，不改比對語意。
2. **竄改工具第一版作廢。** 第一版在單一測試模式下得到 control=44，起初懷疑是重新編碼失真；以 pxdiff 確認重新編碼無損（raw bytes 相同），差異來自上一條的渲染雜訊。作廢的 log 保留在 `tamper-v1-lossy/`、`tamper-v2-isolated/`。
3. **fixture 寫在測試檔內，沒有另開 `NakiTests/Fixtures/` 檔案。** fixture 是 Swift 值，放同一檔最簡單。
4. **`UpdateAvailableBanner` 整條不納入**，而不是只遮掉關閉鈕：遮罩要另寫比對區域，超出「畫不出來就列不覆蓋」的指示。
5. **契約證據與派工字面不同。** 派工寫「四條契約用故意改 baseline 像素實證各自會紅」。四條契約單元測試用合成圖，改 baseline 不影響它們；改 baseline 驗的是 snapshot 路徑。契約 1 改 1 像素本來就低於門檻，所以證據是計數＝1 且通過，不是紅。對應：契約 1 `tamper-1px.log`（diff=1/64000 過）；契約 2 `tamper-960px.log` 過、`tamper-961px.log` 紅；契約 3 `tamper-resize.log` 紅；契約 4 `tamper-missing.log`、`tamper-garbage.log` 紅。

## 強化

變異測試（`mutation-report.md`，12 個變異）找出 3 個原測試殺不掉的非等價存活（門檻常數、只比 R 通道、`assertSnapshot` 吞錯），分別新增 `testThresholdIsFifteenPermille`、`testDiffCountsEveryChannel`、`testSnapshotFailsWhenBaselineMissing` 後全部被殺。`altered` 改為減 1，避免 alpha 255 繞回 0。與 `testThresholdIsFifteenPermille` 重複的 `testThresholdBoundary` 已刪（本包 11 → 13 條）；刪除後未重跑變異，M5、M7 仍被殺為依測試內容推斷，未驗證。

## 已知風險

- 渲染雜訊（Deviation 1）：WP-B（動效工作包）「最終幀差異為 0」只在整個 class 或全套執行時成立，單跑一條測試會看到每張 44–124 像素（400×160 那張為 0.07%）的雜訊。成因未驗證，目前只觀察到與執行範圍有關。**重錄與比對都必須跑整個 class**；只用單條測試重錄，會把雜訊版本存成 baseline。
- baseline 綁本機 macOS 27.0 與字型；換機器或升級 OS 必然重錄。
- `CLAUDE.md`「專案結構的坑」仍寫「`GameStore`、`NativeBotController` 已補」，與 33 處現況不符；不在本包可改範圍，未動。
- **真實偏好檔 sha256 前後不同（驗收未通過）。** 執行前 `b375488…`，結束時 `d607339…`。
- **已確認：** 兩個狀態只差一個 key `NSWindow Frame SwiftUI.WindowGroup<…ContentView…>-1-AppWindow-1`（AppKit 視窗 frame autosave，值在外接與內建螢幕兩組之間來回），設定類 key 沒有變（`attrib-plist-diff-run2.txt`、`attrib-plist-diff-original-vs-now.txt`）。`UISnapshotTests` 只用隔離 suite。主線先前判為 cfprefsd 同值重寫，此歸因修正為 test host 視窗 frame autosave；init-guard notes 的歸因段以此為準。
- **推測（只有時間相關）：** 寫入者是 test host，寫入時間 21:54:36、21:59:44、21:59:54 落在本包 test host 執行中或剛結束（`attrib-sha.txt`）。同一期間 `Naki-wt-init-guard` 與主 repo 的 DerivedData 在 21:44–21:52 也各跑過 test host，前後差異不能只算本包。WP-0p 當時量到相同，可能只是剛好翻回原值。
- **範圍外：** 修正要動 `command/`，不在本包範圍，真實偏好檔未還原。只要 test host 會開視窗，sha 比對就可能失敗。
