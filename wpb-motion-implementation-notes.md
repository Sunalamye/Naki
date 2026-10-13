# WP-B 數值與異常列動效 implementation notes

依據：`docs/plan/ui-design-reference.md` §1 不變條件、§2.1、§3.6、§5 WP-B。基底 main `b913a08`，分支 `wp-b-motion`，未 commit。
`LOG` = 主 repo `.swfd/logs/wp-b/`。

## 已修改

- `ContentView.swift`
  - `PanelLayout` 新增 `exit`（`.smooth(duration: 0.18)`）、`standard`（`.easeInOut(duration: 0.2)`）；`animation(_:reduceMotion:)` 預設參數改為 `standard`。
  - `ActionDelayStepper.delayBoundLabel(_:)`（static）：與 `SettingsStore.actionDelayRange` 端點相差不到半步（`actionDelayStep / 2`）時回「最快」或「最慢」。
  - 工具列的 `actionDelayStepper` 屬性改成 `ActionDelayStepper` struct，設定頁共用（`compact` 為工具列版）。數值 Text 加 `.contentTransition(.numericText(value:))` 與 `PanelLayout.valueChange` 動畫；端點說明文字不加動畫；兩版的 `accessibilityValue` 都是「秒數 端點說明」（沿用既有 key `%@ %@`）。
  - macOS：拿掉 `HSplitView` 上的 `.animation(_:value: showGamePanel)`，改在工具列切換鈕用 `withAnimation(PanelLayout.animation(reduceMotion:))` 包 `toggle()`。
  - iOS：面板 transition 改單純 `.move(edge: .trailing)`。`onAppear` 原本就是不加動畫的直接賦值，維持「只在不該顯示時設 false」的條件寫法（無條件賦值會在畫面重新出現時蓋掉用戶自己的開關）。
- `DecisionSidebar.swift`
  - 摘要條展開改用 `PanelLayout.standard`。
  - `ScoreRow` 每格點數 Text 加 numericText 與 `valueChange` 動畫（與 `myScore` 同模式）。
  - `DecisionAlerts`：四個條件列（雲端失敗、雲端送出提示、停滯、三麻提示）加 `.transition(.opacity.combined(with: .move(edge: .top)))`；VStack 掛一個 `.animation(..., value: shown)`，`shown` 是 `[Bool]`，只看各列有無。停滯秒數每秒變動，不放進 value。三個條件抽成 `cloudDegraded`、`sanmaNotice`，`hasAny` 共用。
- `AdvancedSettingsSheet.swift`：延遲列改用 `ActionDelayStepper()`；移除不再使用的 `@Bindable`。
- `LogPanel.swift`：捲到底改成 `withAnimation(PanelLayout.animation(reduceMotion:))`，刪掉 `if reduceMotion` 分支。
- `Localizable.xcstrings`：新增「最快」「最慢」，en／ja／ko／zh-Hans 四語系，附 comment。用文字插入在檔尾，其餘內容不動。
- `scripts/ui-token-gate.sh`：加三項動效檢查（見 Deviations 第 1 條）。
- 測試
  - `PanelLayoutTests.testDelayBoundLabel`（新增，呼叫 `ActionDelayStepper.delayBoundLabel`）。
  - `PanelLayoutTests.testAnimationTokenDurations`（強化時補上，見「強化」段）。
  - `testReduceMotionDisablesAnimation` 加一條預設參數等於 `standard` 的斷言。
  - `UISnapshotTests.testActionDelayBounds`（新增）：設定頁寬版在下界、工具列窄版在上界。
- 基準圖：新增 4 張 `ActionDelayStepper_*`，既有 28 張未動。副本在 `LOG/new-baseline/`，待用戶核准。

## 已驗證

| 項目 | 結果 | 證據 |
|---|---|---|
| 最終碼：全套 NakiTests | 1013 tests、0 failures（強化多 1 個測試） | 由獨立復驗於最終碼重跑 |
| 最終碼：macOS Release、iOS Debug、iOS Release build | 全部 BUILD SUCCEEDED | 由獨立復驗於最終碼重跑 |
| 清理前：四個 build（macOS Debug／Release、`Naki-M` iOS Simulator Debug／Release） | 全部 BUILD SUCCEEDED，改動檔無 warning | `LOG/build-macos-debug.log`、`build-macos-release.log`、`build-ios-debug.log`、`build-ios-release.log` |
| 清理前：全套 NakiTests（兩次；第二次是改完單測、做完變異還原之後） | 兩次都是 1012 tests、0 failures（基底 1010，新增 2） | `LOG/test-full.log`、`test-full-final.log` |
| UISnapshotTests 整個 class | 14 tests、0 failures；既有 28 張差異見下方 | `LOG/test-snapshot.log`、`test-snapshot-2.log`、`snapshot-diffs.txt` |
| 既有 28 張排除新測試 | 28 張全部 diff=0 | `LOG/test-snapshot-skipnew.log` |
| 新 4 張只新增 | `git status` 只有 4 個 `??` | `LOG/test-record.log` |
| 新圖內容（4 張逐張 Read） | `ActionDelayStepper_settings-fastest_420x32@2x_macOS27.0_zh-Hant_light.png`、`…_dark.png`：「基準延遲」與「最快 0.5 秒」；`ActionDelayStepper_toolbar-slowest_200x32@2x_macOS27.0_zh-Hant_light.png`、`…_dark.png`：「最慢 3.0 秒」。淺深都看得清楚次要色，文字未截斷 | `LOG/new-baseline/` |
| 動效 gate | 7 項 PASS；對基底 `b913a08` 的 Views 跑會抓到 5 處違規（`duration:` 2 處、`reduceMotion` 分支 2 處、`HSplitView` 隱式動畫 1 處） | `LOG/gate.log`、`gate-against-base.log` |
| 減少動態效果 | 既有 `PanelLayoutTests.testReduceMotionDisablesAnimation`：`true` 回 nil，`false` 回非 nil | `LOG/test-full.log` |
| 端點說明 | `testDelayBoundLabel` 驗下界「最快」、上界「最慢」、步進累加誤差、相鄰一步回 nil；把容差改成 `==` 的變異會讓它失敗（2 failures），已還原 | `LOG/mutation-equality.log` |
| xcstrings | JSON 解析通過；兩個 key 都有 4 個語系 | `LOG/xcstrings-check.txt` |
| 真實偏好檔 | 測試前後 sha256 相同，`plutil -convert xml1` diff 為空；最終全套前後 sha256 也相同 | `LOG/sha-before.txt`、`sha-after.txt`、`prefs-diff.txt`、`sha-before-final.txt`、`sha-after-final.txt` |
| 測試前 live 狀態 | `pending` 為 null；測試後只剩用戶原本的 Naki（pid 61826） | `LOG/pending-before.txt`、`pgrep-before.txt`、`pgrep-after.txt` |

**既有 28 張的差異（發現，不重錄）**：整個 class 跑時，`BotFailureBanner` 淺／深 8／1 像素、`PageLoadFailureBanner` 淺／深 611／261 像素（門檻千分之 15 內，測試通過）。

- `BotFailureBanner` 的 8／1 是 WP-B 造成的，觸發點是新增的 `testActionDelayBounds`，不是動效的產品程式碼。基底整合閘是 0，排除新測試的那次也是 0，只有加了新測試才出現。新測試依字母序排在 `testBanners` 之前，banner 不再是程序裡第一個渲染的畫面。banner 程式碼沒有改。機制未證。
- `PageLoadFailureBanner` 的 611／261 在基底就有：基底 `b913a08` 的整合閘（`.swfd/logs/merge-main/test-b913a08.log`）是同樣數字。排除新測試、`testBanners` 成為第一個渲染時，它反而是 0。
- 推論：差異取決於同一個 test host 程序裡，之前是否已渲染過其他畫面。這是推論，未追到渲染層的原因。沒有改測試名稱去讓 diff 歸零。
- 新圖 `ActionDelayStepper_settings-fastest` 也有同樣現象：第一次全套 diff=0，第二次全套淺／深 79／49 像素，仍在門檻內。所以這個差異在不同次執行之間也會變，不只取決於順序。
- `DecisionAlerts` 加了 transition，三張圖的最終幀在每一次執行都是 diff=0。

## 未驗證

- 減少動態效果的實機錄影：統帥決定不補做，列為 release 已知限制。
- 實機開關「減少動態效果」的觀感，沒有錄影。開啟時直接切換只由單測保證，單測只證明入口回 nil。
- 計數動畫、`DecisionAlerts` 進退場、LogPanel 捲動、macOS 面板開合的過程幀。快照只比最終幀。
- `ImageRenderer` 不畫 AppKit 的 Stepper，新圖裡 Stepper 位置是禁止符號佔位圖。窄版「不擠壓」只確認了文字部分。工具列實際寬度（macOS `.fixedSize()`、iOS 側欄）未在 live App 檢視。
- VoiceOver 實際朗讀「0.5 秒 最快」，沒有用輔助技術驗證。
- en／ja／ko／zh-Hans 的新字串沒有在畫面上檢視。

## 強化

對最終碼做變異測試，結果見 `.swfd/logs/wp-b/mutation-report.md`。

- 8 個變異被殺。
- M6 為等價變異，行為不變。
- M7 存活：無障礙值（`accessibilityValue`）沒有自動化保護。保守起見不改正式碼，列為已知缺口。

## 已知風險

- LogPanel 捲動原本用 `withAnimation` 的預設曲線，現在是 `PanelLayout.standard`（easeInOut 0.2 秒）。log 很密時，捲動動畫可能更常互相打斷。
- macOS 面板開合現在只由工具列按鈕驅動動畫。MCP 或其他地方改 `showGamePanel` 時不會有動畫，會直接切換。目前 Swift 端只有工具列按鈕會寫它。
- 工具列窄版到端點時多出兩個字，寬度會變。macOS 是 `.fixedSize()`，toolbar 項目會跟著變寬。
- 新快照包含 Stepper 佔位圖。日後 `ImageRenderer` 若改成能畫 Stepper，這 4 張要重錄。

## Deviations

1. **gate 併入 `scripts/ui-token-gate.sh`**，不另寫 `.swfd/logs/wp-b/gate.sh`。理由是讓之後的工作包也持續受檢。
   - `PanelLayout.animation` 的定義行本身就是 `reduceMotion ? nil : base`，所以 gate 排除這一行，與 `duration:` 排除 `static let …: Animation =` 定義行的做法相同。
   - 分支檢查除了 `reduceMotion ?`，也抓 `if reduceMotion`，因為 LogPanel 原本的寫法是後者。
   - 「`.animation(` 不得在含 WebView 的子樹」的檢查範圍是 ContentView 從 `MARK: - macOS Layout` 到 `MARK: - Game Panel` 的區段，涵蓋兩個平台的版面。
2. **延遲控制抽成一個 `ActionDelayStepper` struct**，放在 `ContentView.swift`，工具列與設定頁共用。派工只要求兩處各加計數與說明，但原本的兩處都是 private，快照測試無法單獨渲染。抽成一份也讓端點判斷、格式與 a11y 只有一個來源。放既有檔是為了不動 pbxproj。設定頁的 Stepper 標籤與 identifier（`settings-delay-stepper`）照舊。
3. **純函式放在 `ActionDelayStepper.delayBoundLabel`（static）**，回傳 `String?`。`PanelLayout` 是版面 enum，端點說明屬於延遲控制，所以跟著 struct 走（清理時從 `PanelLayout` 搬來，不動 pbxproj）。畫面用 `LocalizedStringKey` 包起來，與 `ScoreRow` 對 `SeatWind.name` 的做法相同。`SettingsStore` 不在可改範圍，所以不放那裡。
4. **`DecisionAlerts` 的 transition 也加到「對局資料送往 host」那一列**。它與雲端失敗列是同一組 if／else，只加其中一個會讓切換時一列有動畫、一列沒有。
5. **單測加在 `PanelLayoutTests.swift`**。派工的檔案清單沒有列這個檔，但驗收 8 要求單測，而 `PanelLayout` 的既有單測都在這裡。
6. **derivedData 放在 `/tmp/naki-dd-wpb`**，不放 scratchpad。它是 build 產物，不影響驗收。
