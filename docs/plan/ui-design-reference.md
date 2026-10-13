# Naki 畫面設計參考（ui-design）

日期：2026-10-13。初稿基底：`15cea92`（分支 `wp-ui-design`）；設定分頁修訂基底：main `07c3079`。

這份文件把用戶提供的 web 設計來源（uiarc.dev、designeer.xyz 子站、後台文案 prompt）翻譯成 Naki 的 SwiftUI 規格。
它建立在 2026-08-09 的 UI 重設計之上，不推倒重來：
`docs/ui-reference/action-states/prototype.html` 與 `rendered/*.png` 仍是視覺 source of truth，但只限版面、側欄順序、牌面、決策卡與動作色。
原型裡已失效的控制與說明不是需求：「隱藏玩家名稱」開關（已移交插件）、「三麻 3P 模型是唯一的真三麻推論路徑」等三麻能力說明（現行有本地 Akagi 三麻）。
`rendered/settings.png` 只參考排版，不參考設定項目；設定項目以 `AdvancedSettingsSheet` 現況為準。
`docs/ui-reference/implementation-decisions.md` 仍是「為什麼這樣選」的依據。
本文件只寫「沿用／調整／新增」。

標記約定：

- **沿用**：現況已符合，不動。
- **調整**：現況有做，但值或寫法要收斂。
- **新增**：現況沒有。
- **SwiftUI 系統 API，worktree 尚未使用**：文件提到、但目前 `command/` 內 grep 不到的 Apple API。它們是建議寫法，不是現況。
- **推測**：沒有實測證據的判斷。
- **已裁決**：用戶 2026-10-13 的裁決結果，依據見 `docs/plan/ui-design-adr-2026-10-13.md`。

---

## 1. 目標、模組邊界、資料流、不變條件、取捨、不做的事

### 目標

1. 把散落在 9 個 View 檔的 spacing、cornerRadius、透明度、動畫時長收斂成一份可查的 token 表。
2. 把來源中對 Naki 有用的互動模式（原地確認、數字計數、清單合攏、減少動態效果）對到具體 View 與 SwiftUI 寫法。
3. 產出使用者可見文案的「原文案 → 新文案」對照表，功能不改。
4. 拆出可獨立驗收的後續工作包。

### 模組邊界

- 設計 token 的唯一定義點是 `PanelLayout`（`command/Views/ContentView.swift`）。
  不另開第二個常數 enum。同一個值有兩個來源時，兩邊遲早漂開。
- 動畫的減少動態效果分支只有一個入口：`PanelLayout.animation(_:reduceMotion:)`。
  它在 reduce motion 開啟時回傳 `nil`，所有動畫都經過它。
- 顏色的定義點：動作色仍在 `Recommendation` 內 `ActionType` 的 `color`（`command/Models/GameModels.swift`），
  背景色仍在 `Color+Extension.swift`（`contentBackground`、`windowBackground`、`textFieldBackground`）。
  狀態色目前沒有定義點，在 View 裡直接寫；WP-A 把它收進 `PanelLayout`（見 §3.4）。
- 本包與後續 UI 包都不得改 `command/Services/**`、`command/App/**`、`command/ViewModels/**`。
  因此動畫無法在資料寫入處用 `withAnimation` 包住，只能在 View 端做（見不變條件 2）。

### 資料流

```text
PanelLayout（token、animation(_:reduceMotion:)）
  ← 各 View 讀取（DecisionSidebar、StatusBanners、PluginsPageView、AdvancedSettingsSheet、ContentView）

GameStore（由 Services 寫入，View 不寫）
  → View 讀值
  → 葉節點 Text 上的 .contentTransition + .animation(PanelLayout.animation(...), value:)
  → 減少動態效果開啟時，PanelLayout.animation 回傳 nil，值直接跳到新值

使用者操作（Button）
  → View 內 withAnimation(PanelLayout.animation(...)) { naki.actions.xxx() }
```

### 不變條件

1. 每個新動畫都經過 `PanelLayout.animation(_:reduceMotion:)`。不得直接寫 `withAnimation(.spring...)` 或 `.animation(.easeInOut...)`。
   減少動態效果開啟時一律**直接切換**：入口回傳 `nil`，`.transition` 也就不會播放，不另做 crossfade。
   既有例外（兩處入口外的分支點，WP-B 移除後例外消失）：
   - `LogPanel` 自動捲到底用自己的 `if reduceMotion` 分支加裸 `withAnimation`。
   - `ContentView` iOS 面板的 `.transition(reduceMotion ? .opacity : .move(edge: .trailing))`。入口回傳 `nil` 時 `.opacity` 永遠不播，這個分支沒有作用；WP-B 改成單純 `.move(edge: .trailing)`。
2. 隱式動畫 `.animation(_:value:)` 只能掛在**葉節點**，或掛在子樹不含 WebView 的容器上。
   原因：iOS 版的註解已禁止在含 WKWebView 的容器上掛它，理由是動畫只該作用在需要的子樹。`implementation-decisions.md`「iOS 間歇性崩潰」記載「動畫是崩潰根因」的推論不成立，所以這條是作用範圍規則，不是崩潰修正。
   既有例外：macOS `macOSLayout` 的 `HSplitView` 經過入口，但子樹含 `AdaptiveNakiWebView`。本包不修；WP-B 改成切換處 `withAnimation` 後，這條例外移除。
3. 回報狀態的動畫不回彈（bounce 0）。來源依據是 uiarc motion 規則「Anything that reports state lands without overshoot」：
   回彈會讓數字或面板短暫顯示一個不成立的狀態。
4. 所有時長 ≤ 0.4 秒。依據是 lawsofux 的 Doherty Threshold（<400ms）。
5. 不以顏色作為唯一線索。沿用 `StatusDot` 的 `accessibilityDifferentiateWithoutColor` 做法與 `AuthorizedActionsRow` 的字重線索。
6. 假功能不得留在 UI（`CLAUDE.md`）。例如 confirm-morph 的「復原」若沒有真的復原能力，就不得出現。
7. UI 文字 draw 與 WebGL 高亮由插件負責，Swift 端不碰。本文件的動效只作用在 SwiftUI 側欄、橫幅、設定頁與插件頁。

### 取捨

- **token 放 `PanelLayout`，不開新檔**：新 Swift 檔要登記 app target 的兩個 `membershipExceptions` 集合（`project.pbxproj` 內 `Views/ContentView.swift` 出現兩次），
  會動 pbxproj。放進既有 enum 不需要。代價是 `PanelLayout` 的名稱比內容窄；改名列為後續包的選項，不在本包做。
- **只在 code 裡加用到的 token**（YAGNI）：完整 token 表只寫在本文件。後續工作包收斂某一類值時，才把那一類加進 `PanelLayout`。
- **計數只用在點數，不用在推薦百分比**：見 §2 的捨棄理由。
- **不做客製 Stepper**：number-field 的「推到上限會回彈」需要客製控制項，換來的只是動畫。系統 Stepper 在上限時已停用那顆箭頭，拒絕本身看得到。

### 明確不做的事

- 不換視覺風格、不換配色主題、不重畫 `prototype.html`。
- 不在 WebView 上方或周圍加任何動畫（含橫幅高度收合，見 §2）。
- 不加 scroll reveal、不加循環動畫（uiarc 規則 8）。
- 不改麻將術語（立直、副露、赤寶、段位場、寶牌指示牌等）。
- 不在本包修 macOS `HSplitView` 上的 `.animation(_:value:)`（見 §5 已知風險），只記錄。

---

## 2. 來源模式對照表

### 2.1 採用

時長與曲線的 token 見 §3.6。來源：uiarc `motion.md`（uiarc 的 token，不是 Naki 識別字：`spring.smooth` 0.4s bounce 0；`spring.snappy` 0.26s bounce 0.12；`duration.fast` 0.16s；`duration.exit` 0.18s）。
SwiftUI 對應：`.smooth(duration:)` 是 bounce 0 的 spring（spike 已使用）。Apple 文件把 `.snappy` 定義為帶少量回彈的 spring，`extraBounce: 0` 只是不再加回彈，所以本文件不用 `.snappy`。
`.smooth(duration:)` 與 `.contentTransition(.numericText(value:))` 都需要 iOS 17／macOS 14，符合 Naki 的最低版本。

| 來源模式 | Naki 畫面／View | SwiftUI 寫法 | 時長／曲線 | 減少動態效果分支 | 狀態 |
|---|---|---|---|---|---|
| uiarc 數字計數（animated-counter：數字往變動方向滾） | 摘要條的自家點數：`GameSummaryDisclosure` 的 `myScore` | 葉節點 `Text`：`.contentTransition(.numericText(value:))` + `.animation(PanelLayout.animation(PanelLayout.valueChange, reduceMotion:), value: myScoreValue)` | `PanelLayout.valueChange` = `.smooth(duration: 0.4)` | `PanelLayout.animation` 回傳 `nil`，數字直接跳到新值 | **新增，spike 已完成** |
| 同上 | 展開層四家點數：`ScoreRow` | 同上，每格一個葉節點 `Text` | 同上 | 同上 | 新增（後續包 WP-B） |
| 同上 | 設定頁與工具列的「基準延遲」數值：`AdvancedSettingsSheet` 的延遲列、`ContentView` 的 `actionDelayStepper` | 數值 `Text` 加 `.contentTransition(.numericText(value: naki.settings.actionDelaySeconds))`，`.animation` 掛在同一個 `Text` | `PanelLayout.valueChange` | 同上 | 新增（WP-B） |
| uiarc number-field（到上限時說出是哪個上限） | 同上兩個延遲 Stepper | 不做回彈動畫。值等於 `SettingsStore.actionDelayRange` 的下界時，在數值旁顯示「最快」；等於上界時顯示「最慢」（延遲越小越快）。同一段文字寫進 `accessibilityValue` | 無動畫 | 不適用 | 新增（WP-B）。回彈部分捨棄，理由見 §1 取捨 |
| uiarc confirm-morph（按鈕原地變成確認列） | 插件移除：`PluginsPageView` 的「移除」按鈕（現行是 `confirmationDialog` + `pendingRemoval`） | 沿用 `pendingRemoval: String?` 當唯一狀態，確認面只在 `pendingRemoval == d.id` 時出現，所以狀態不會套到另一個插件。點「移除」後同一位置換成 `Button("取消")` 與 `Button("移除「\(id)」", role: .destructive)`，下方一行沿用現行 dialog 的說明句「會刪掉 \(id) 的整個插件目錄。可重新匯入或放檔案救回。」，保留插件身分、後果與救回方法。寬度變化由 `.animation(PanelLayout.animation(...), value: pendingRemoval)` 掛在按鈕容器上（子樹不含 WebView）。4 秒逾時用 `.task(id: pendingRemoval)`：目標改變、取消或離開頁面時，SwiftUI 會取消上一輪任務；`Task.sleep` 被取消時直接 return，不清狀態。確認面出現 0.28 秒內的點擊不算數（uiarc：防雙擊誤確認） | 展開 `PanelLayout.valueChange`；退回 `PanelLayout.exit`（exit 比 entrance 快） | 直接切換（不變條件 1） | 新增（WP-C）。**不做「復原」**：`removePlugin` 刪除整個目錄，沒有復原能力，做了就是假功能 |
| uiarc inbox-triage（項目離開後清單合攏） | 插件清單移除後：`PluginsPageView` 的清單列 | 確認動作改成 `withAnimation(PanelLayout.animation(PanelLayout.valueChange, reduceMotion:)) { naki.actions.removePlugin(id) }`，在 View 內呼叫，不碰 Actions 層 | `PanelLayout.valueChange` | 回傳 `nil`，列直接消失 | 新增（WP-C）。刪除失敗時沿用 `NakiRuntime` 的 `removePlugin` 現況：寫 `statusMessage`、重新掃描，那一列留下；View 端把 `pendingRemoval` 清為 nil。移除後焦點移到下一列（uiarc 無障礙行為）列為建議 |
| 同上 | 側欄異常列：`DecisionAlerts`（雲端失敗、自動打牌停滯、三麻提示） | 每個 alert 加 `.transition(.opacity.combined(with: .move(edge: .top)))`；`DecisionAlerts` 的 `VStack` 掛 `.animation(PanelLayout.animation(...), value: autoPlayStall != nil)` 等布林值。這個 `VStack` 的子樹不含 WebView | 出現 `PanelLayout.valueChange` | 直接切換（不變條件 1） | 新增（WP-B） |
| uiarc reduced motion（每個動畫都有分支，保留最終狀態） | 全部 | 一律經過 `PanelLayout.animation(_:reduceMotion:)`，開啟時直接切換 | — | 這就是分支本身 | **調整**：入口已存在；入口外還有兩個分支點（不變條件 1 的既有例外），WP-B 移除 |
| lawsofux Doherty Threshold（<400ms） | 全部動畫 | 時長上限 0.4 秒 | ≤0.4s | — | 調整：時長收進 §3.6 的三個 token，全部 ≤0.4 秒 |
| lawsofux Von Restorff Effect（不同的那一個最容易被記住） | 決策卡 `DecisionCard` 是側欄唯一帶色塊與大字的元素 | 不加第二個同等強調的元素 | — | — | 沿用 |
| lawsofux Hick's Law（選項越多決策越慢） | 次選 `OptionList` 最多 3 個（窄版 2 個），超出顯示「還有 N 個」 | — | — | — | 沿用 |
| lawsofux Fitts's Law（目標越小越難點） | `PanelLayout.minTapTarget` 44pt | — | — | — | 沿用 |
| lawsofux Law of Common Region（同框即同組） | 摘要條與授權動作同一張卡片（`GameSummaryDisclosure`） | — | — | — | 沿用 |

### 2.2 捨棄

| 來源模式 | 捨棄理由 |
|---|---|
| 推薦百分比計數（`DecisionCard` 的 `percentageString`） | 推薦換手時（8p 93% → 3m 41%）數字會從 93 滾到 41，暗示「同一件事的機率在下降」，實際上是另一個問題的答案。uiarc 的計數適用對象是同一個量的連續變化。 |
| number-field 的上限回彈與按鈕抖動 | 需要客製 Stepper；系統 Stepper 在上限時已停用箭頭。只保留「說出是哪個上限」。 |
| in-view title（blur／words／lines／wipe 進場） | Naki 沒有捲動進場的區段標題。uiarc 規則 8 也寫「No scroll reveal on every section」。 |
| morph-select（trigger 長成清單） | Naki 的 Picker 都是系統 segmented／menu，換成客製選單違反 Jakob's Law。 |
| command-palette | Naki 沒有足以需要搜尋的指令數量。工具列 13 個控制的問題要靠收納解決，不是搜尋。 |
| chat-thread（送出後落位） | Naki 沒有訊息輸入。 |
| announcement-bar 的高度收合（套到 `StatusBanners` 五種橫幅） | macOS 的橫幅與 `AdaptiveNakiWebView` 在同一個 `VStack`，高度動畫會讓 WebView 每一幀改尺寸；橫幅的出現由 `GameStore` 驅動，View 端沒有 `withAnimation` 可包，只能把 `.animation` 掛在含 WebView 的容器上，違反不變條件 2。橫幅維持直接出現／消失。 |
| confirm-morph 的 hold／countdown 模式 | Naki 的破壞性操作只有兩個，按一下確認已足夠。 |
| 「刪除 Bot」加原地確認 | 已裁決：不做。Bot 下一局自動重建，不是不可逆操作。 |
| prompt-motion.com | 影片動效，對 app UI 無直接適用（`sources.md` 第 3 則已註明可略過）。 |
| 60fps.design、details.so 等 gallery | 首頁是影片 gallery，沒有可引用的原則文字。本文件只引用 lawsofux.com 的定律名稱。 |

---

## 3. Token 表

現況數字由下列指令取得（2026-10-13，worktree `command/Views/*.swift`）：

```bash
grep -ohE 'spacing: *[0-9.]+' *.swift | sort | uniq -c
grep -ohE 'cornerRadius: *[0-9.]+' *.swift | sort | uniq -c
grep -ohE '\.font\([^)]*\)' *.swift | sort | uniq -c
```

### 3.1 Spacing

現況：`spacing:` 出現 0／1／2／3／4／5／6／8／10／12／14／16／20；`padding` 另有 7／9（`compact ? 7 : 10` 這類成對值）。

收斂方案：**2／4／6／8／10／12／16／20**，加上 0（緊貼）。換算規則只有一條：取最近的集合值，等距時取較大者。

| 現況值 | 收斂為 | 說明 |
|---|---|---|
| 1 | 2 | `ScoreRow`（`DecisionSidebar.swift` 約 338 行）、`ContentView.swift` 約 819 行、`PluginsPageView.swift` 約 251 行的 `VStack(spacing: 1)` |
| 3 | 4 | 等距取大 |
| 5 | 6 | 等距取大 |
| 7 | 8 | — |
| 9 | 10 | 等距取大 |
| 14 | 16 | 等距取大；`DecisionCard` 寬版 padding 與 HStack 間距 |
| 18 | 20 | 等距取大；`ServerPickerView` 確認鈕的 `padding(.top, 18)`（`ContentView.swift` 約 796 行） |
| 0／2／4／6／8／10／12／16／20 | 不變 | — |

10 保留在表內：`padding(10)` 與 `spacing: 10` 用得多，改成 8 或 12 會讓整個側欄位移，pixel diff 會大面積變動。

`compact` 成對值不另訂「往下幾格」規則，兩邊各自套上面的換算。原因：iOS 右側欄只有 220pt，若規定窄版只比寬版小一格，`padding(compact ? 10 : 16)` 會變成 12／16，窄版內容反而變窄。
換算後的成對值（`DecisionSidebar.swift`）：8:12、10:16、10:12、8:10 不變；7:12 → 8:12；5:8 → 6:8；6:9 → 6:10；7:9 → 8:10；7:10 → 8:10；8:14 → 8:16；10:14 → 10:16；3:6 → 4:6；5:7 → 6:8。
例外：摘要條 `HStack(spacing: compact ? 10 : 6)` 窄版比寬版大，是刻意的：窄版只剩局況與自風兩欄，間距加大才分得開。維持 10:6。

### 3.2 cornerRadius

現況：3／4／5／6／7／8／10。prototype.html 另有 9／12／13／16／18／24／99px（99px 是膠囊）。

| 語意 | 值 | 現況使用處 |
|---|---|---|
| badge | 4 | `AuthorizedActionsRow` 的 badge、`OptionRow` 的動作標籤、`StatusBar` 推薦數、`LogPanel`（3 → 4） |
| control | 6 | `DecisionCard` 動作框、`DecisionAlerts`（現況已是 6） |
| row | 8 | `OptionRow`（7 → 8）、`GameSummaryDisclosure` |
| card | 10 | `DecisionCard` |
| capsule | `Capsule()` | `ProbabilityBar`、插件 capability 標籤 |

`cornerRadius: 5` 全專案只有 `ScoreRow` 一處，改為 4（badge 等級）。`TileImage` 牌身的 3 跟著牌面比例走，**沿用**，不納入收斂。

### 3.3 字型階層

現況以 `.caption`（47 處）與 `.caption2`（37 處）為主，另有等寬 `.caption`（14）與 `.caption2`（11）。沿用系統 text style，支援 Dynamic Type。

| 角色 | 寬版 | 窄版（`compact`） | 使用處 |
|---|---|---|---|
| 面板標題 | `.title3` bold | `.subheadline` bold | `SidebarHeader` |
| 決策動作 | `.headline` bold | `.caption` bold | `DecisionCard` |
| 決策數字 | `.largeTitle` 等寬 bold | `.title3` 等寬 bold | `DecisionCard` 百分比 |
| 區段標籤 | `.caption` bold `.secondary` | `.caption2` bold `.secondary` | `SectionLabel` |
| 內文 | `.caption` | `.caption2` | 摘要條、`GameDetailsPanel` |
| 註記 | `.caption2` `.secondary` | 同左 | 空狀態、說明文字 |
| 診斷 | 等寬 `.caption` | 同左 | 橫幅的 summary、`StatusBar` |

**沿用**：現行程式沒有寫死字級。唯一的固定算式是 `TileImage` 的 `.system(size: max(7, width * 0.34))`，它是 fallback 文字，跟牌面尺寸連動。`TileImage.swift` 裡的 `.system(size: 28)` 只出現在描述舊版的註解。

### 3.4 Semantic color

現況：狀態色在 View 裡直接寫 `.red`／`.orange`／`.green`／`.blue`，`command/Views` 共 44 處（`grep -nE '\.(red|orange|green|blue)\b'`，排除註解），沒有定義點。

**WP-A 把下列五個語意名稱收進 `PanelLayout`**，維持單一定義點。清理閘：`command/Views` 內除了 `PanelLayout` 的定義行，不得再出現裸的 `.red`／`.orange`／`.green`／`.blue`。
唯一例外是 `LogPanel` 的 `categoryColor`：它是 log 分類的識別色，不是狀態，清理閘的 grep 要明列排除它。

| 語意 | 色 | 用途 |
|---|---|---|
| danger | `.red` | 會讓 Naki 失效、不會自己好：JS 注入失敗、自動打牌停滯、雲端失敗 |
| warning | `.orange` | 本局受影響或資料外送：頁面載入失敗、封包解析失敗、Bot 推論失敗、雲端外送提示、三麻提示 |
| success | `.green` | 可用、已連線、運行中 |
| info | `.blue` | 更新提示、一般狀態 |
| neutral | `.secondary` | 不可用、待機、註記 |

透明度：現況 10 種（0.08、0.09、0.10、0.12、0.15、0.16、0.18、0.20、0.22、0.25），另有 0.45、0.55、0.7、0.9。全部歸入下表，WP-A 的清理閘才會通過。

| 角色 | 值 | 取代 |
|---|---|---|
| fill.subtle | 0.10 | 0.08、0.09、0.10、0.12 |
| fill.tint | 0.16 | 0.15、0.16、0.18、0.20 |
| neutral | 0.25 | 0.22（`GameSummaryDisclosure` 外框、`ContentView` 約 838 行的關閉狀態外框）、0.25（`ProbabilityBar` 底軌） |
| stroke | 0.45 | 0.45（`DecisionCard` 外框）、0.55（`ContentView` 約 837 行的 accent 外框）、0.7（`DecisionCard` 動作框，`DecisionSidebar.swift` 約 497 行） |
| text.dim | 0.8 | `Color.secondary.opacity(0.7)`（`RecommendationsDisabledView`，`DecisionSidebar.swift` 約 738 行）、`.opacity(0.9)`（`StatusBanners.swift` 約 132、180 行，實心橫幅上的第三行說明） |

0.55、0.7、0.9、0.22 的換算都會改變畫面，須 pixel 對照後由用戶確認。

**動作色與 danger 衝突**：`Recommendation` 內 `ActionType` 的 `color` 把「槓」設為 `.red`，與 danger 同色（`implementation-decisions.md` 已知遺留「紅同時是槓與危險」）。
**已裁決**：槓改為 `.indigo`（SwiftUI 系統色，worktree 尚未使用）。連動 `command/Models/` 與 `rendered/ankan.png`、`kakan.png`、`minkan.png` 三張基準，見 §5 WP-E。

**已知風險（本輪不解）**：
- 動作色與狀態色仍有重疊：打牌 `.blue`＝info、立直 `.orange`＝warning、吃 `.green`＝success；`LogPanel` 的 `.bot` 分類是 `.red`＝danger。
- **推測**：槓改 `.indigo` 後與碰的 `.purple` 在小尺寸下可能不易區分。未驗證，WP-E 重產基準圖時人工確認。

### 3.5 材質（Liquid Glass 與 fallback）

現況：`.ultraThinMaterial` 兩處，都在 iOS 牌桌上方的浮層：

1. 面板收起後的「顯示決策面板」浮動圓鈕（`ContentView` iOS 版面）。
2. `IOSStatusOverlay` 的狀態列背景。

建議只在這兩處用玻璃，側欄與設定頁不用：側欄是不透明面板，底下沒有內容可透。

```swift
if #available(iOS 26, macOS 26, *) {
    button.glassEffect(.regular, in: .circle)
} else {
    button.background(.ultraThinMaterial, in: Circle())
}
```

- `glassEffect` 是 SwiftUI 系統 API，worktree 尚未使用。
- iOS 17–25 走 `.ultraThinMaterial`，就是現況。macOS deployment target 是 26，只走玻璃分支。
- macOS toolbar 在 OS 26 由系統自動套玻璃，不需要寫。
- `NakiWebViewHost.swift` 第 13 行寫「在這裡再寫一次 `#available` 就是第二個真相」。那條規則防的是 backend 與 View 由兩處各自判版本、配錯時靜默失敗。玻璃分歧只決定外觀，兩個分支都能正常運作，沒有「配錯」的失敗模式，所以語意上不屬該規則。
- 但規則有機械化的閘：`PlatformDivergenceTests` 的 `testVersionCheckExistsExactlyOnce` 掃描整個 `command/`，斷言 `#available` 只有一處、而且在 `Services/Web/WebSession.swift`。直接加玻璃分歧會讓這條測試失敗。WP-E 必須同包修改它：允許清單明列 `ContentView.swift` 的玻璃分歧，並保留「web backend 版本分歧只在 `WebSession.init`」的斷言。`CLAUDE.md` 那句同步改寫。
- **推測**：玻璃圓鈕在 iPhone 實機的觸控行為與 `.ultraThinMaterial` 相同。未驗證；iOS 間歇性崩潰尚未解決，這兩處都疊在 WebView 上，必須實機驗。

---

### 3.6 動畫時長

| token | 值 | 用途 | 現況 |
|---|---|---|---|
| `PanelLayout.valueChange` | `.smooth(duration: 0.4)` | 回報狀態的變化：數值計數、確認鈕展開、清單合攏、異常列出現 | 已存在（spike） |
| `PanelLayout.exit` | `.smooth(duration: 0.18)` | 退場：確認鈕退回 | 新增（WP-B） |
| `PanelLayout.standard` | `.easeInOut(duration: 0.2)` | 面板開合、摘要條展開；作為 `PanelLayout.animation` 的預設參數 | 新增名稱（WP-B）；值就是現行預設參數 |

`DecisionSidebar.swift` 約 165 行摘要條展開用 `.easeInOut(duration: 0.18)`，WP-B 改用 `PanelLayout.standard`（0.02 秒差，肉眼不可辨）。WP-B 之後 `command/Views` 內不得再出現 `duration:` 字面值，`PanelLayout` 的定義行除外。

---

## 4. 文案對照表

原則來自 `sources.md` 第 4 則：用戶一眼看懂、用日常說法、不用術語、名稱 2–4 字、描述不超過 20 字、功能不改、不確定的先問。

適用方式：按鈕、分頁、GroupBox 標題、側欄標籤按「名稱 2–4 字」；Toggle 的整句標籤、橫幅標題、異常訊息按「描述 ≤20 字」。
字數以中文字計，「AI」「App」這類英文詞各算一字。
麻將術語（立直、副露、赤寶、段位場、寶牌指示牌、三麻、自風等）是使用者的日常語，不改。

新文案與既有 key 的撞名檢查見主 repo 的 `.swfd/logs/ui-design/copy-collision-check.log`：「已連線」「還原預設」已存在且語意相同，可直接共用；「關閉」語意不同，已排除。其餘新文案都是新 key。
多對一合併（「顯示/隱藏日誌」與「顯示或隱藏日誌」合成「紀錄」）要逐語系人工確認翻譯，不能只看 `state`。

實作注意：`Localizable.xcstrings` 的 key 就是繁中原文。改文案等於改 key，必須同時搬移 en／ja／ko／zh-Hans 四份翻譯；`accessibilityIdentifier` 不受影響，但以字串查元素的 UI 測試會受影響。

### 4.1 名稱（按鈕、開關、標籤、分頁）

各列由誰執行依 §5 WP-D 的歸屬判準：WP-F 負責 `AdvancedSettingsSheet.swift`、`MajsoulConnectionSettingsBox.swift` 內的全部字串，加上工具列設定鈕（`ContentView.swift` 320、322、601）與伺服器選擇畫面那一句（`ContentView.swift` 781）；其餘字串歸 WP-D。標「WP-F 執行」的列即屬前者。

| 位置 | 原文案 | 新文案 | 說明 |
|---|---|---|---|
| 側欄授權動作標題 | 伺服器目前授權動作 | 可用動作 | 「授權」是內部概念 |
| 側欄空狀態 | 等待遊戲數據... | 等待牌局資料… | 「數據」是簡中用語；省略號改單一字元 |
| 摘要條 a11y label | 牌局與模型資訊 | 牌局資訊 | 4 字內 |
| 展開層 | 決策來源 | 建議來源 | — |
| 展開層 | 推論位置 | 計算位置 | 「推論」是 ML 術語 |
| 展開層值 | 本機 Core ML | 本機 | **已裁決**：改 |
| 展開層值 | 退化中 | 改用本機 | 說出實際發生的事 |
| 工具列連線 | 已連接／未連接 | 已連線／未連線 | 與「雲端狀態：已連線」用詞一致 |
| 工具列連線 a11y label | WebSocket 連線狀態 | 遊戲連線 | 術語 |
| 工具列 | 顯示/隱藏日誌、顯示或隱藏日誌 | 紀錄 | 兩個 key 同義，合併成一個 |
| 工具列 | 顯示/隱藏遊戲面板 | 決策面板 | — |
| 插件頁分頁 | Log | 紀錄 | 與工具列一致 |
| 插件頁分頁 | 信任 | 權限 | **已裁決**：改 |
| 插件頁 | 抓取 | 預覽 | 按下後實際做的是抓取並顯示預覽，不會安裝 |
| 進階設定 | 伺服器預設（清空） | 還原預設 | WP-F 執行 |
| 進階設定 | 啟用雲端推論 | 不改 | Toggle 標籤，按「描述 ≤20 字」判定，符合 |
| 進階設定 GroupBox | 雲端推論 | 不改 | 與上一列 Toggle 保持同一用詞 |
| 進階設定 | 基準延遲 | 出手延遲 | 「基準」是實作語（WP-F 執行） |
| 進階設定 | 視窗在背景時保持遊戲運作 | 不改 | **統帥代決**：背景保活的 live 效果未驗證，「背景連線」是更強的承諾 |
| 進階設定 | 顯示狀態訊息列 | 不改 | Toggle 標籤，按「描述 ≤20 字」判定，符合 |
| 進階設定 | 啟動時不再詢問 | 不再詢問 | WP-F 執行 |
| 區服選擇 | 以後都用這個伺服器，不要再問 | 記住伺服器 | — |
| 進階設定 | 自動送出：不可用 | 不能自動 | GroupBox 內標題；外層 GroupBox 是「自動打牌」，語意由它補足（WP-F 執行） |
| 進階設定 | 重建 Bot／刪除 Bot／Bot 管理 | 不改 | **已裁決**：保留。「Bot」貫穿全 App 與 MCP 工具名 |
| 工具列 | MCP Server 運行中／MCP Server 已停止 | 不改 | **已裁決**：保留 |
| 更新橫幅 | 關閉提示 | 不改 | 既有 key「關閉」是模式 Off（en `Off`），「關閉提示」是 `Dismiss`，合併會翻錯一邊；`AppLanguageTests` 鎖定「關閉」 |
| 插件頁 | 抓取中… | 預覽中… | 與「預覽」同一個按鈕的進行中狀態，兩者一起改 |
| 工具列、設定頁標題 | 進階設定 | 設定 | **已裁決**（§8）；WP-F 執行 |
| 伺服器選擇畫面 | 之後可以在進階設定裡改，或取消固定。 | 之後可以在設定裡改，或取消固定。 | 跟隨「進階設定」改名（WP-F 執行；Astra 第 9 條補列） |
| 不變 | 即時決策、最佳選擇、其他選項、運行中、待機、未在對局、重新載入、插件、前往下載、略過此版本、自動檢查更新、金鑰狀態、移除插件？、進入遊戲、選擇雀魂伺服器、寶牌指示牌、推薦顯示已關閉、雲端狀態、已設定・未使用 | — | 已符合原則 |

模式選單「關／推薦／自動／全自動」不改：已是 1–3 字，且與 `AutoPlayMode` 的 `pickerLabel`、MCP 回傳值對應。

### 4.2 描述與異常訊息

| 位置 | 原文案 | 新文案 |
|---|---|---|
| `DecisionAlerts` 雲端失敗（四麻） | 雲端失敗——正在用本地模型（連續 N 手） | 雲端失敗，改用本機（已 N 手） |
| `DecisionAlerts` 雲端失敗（三麻） | 雲端失敗——正在用本地 Akagi 三麻（連續 N 手） | 雲端失敗，改用本機三麻（已 N 手） |
| `DecisionAlerts` 停滯 | 自動打牌停滯 N 秒——伺服器已給機會但沒送出（reason） | 自動打牌卡住 N 秒：該出手卻沒送出（reason） |
| `DecisionAlerts` 三麻 | 三麻尚無推薦：本地 Akagi 三麻引擎在下一個決策點才會產出。 | 三麻建議下一手才會出現 |
| `PageLoadFailureBanner` 標題 | 頁面載入失敗：Naki 讀不到牌局 | 頁面沒載入，讀不到牌局 |
| `JSInjectionFailureBanner` 標題 | JavaScript 注入失敗：Naki 讀不到牌局，也送不出任何動作 | App 元件載入失敗 |
| `LiqiParseFailureBanner` 標題 | 牌局封包解析失敗：這一局 Naki 不會給推薦，也不會自動打牌 | 這局資料讀不懂：本局不給建議、不自動打 |
| 進階設定伺服器說明 | 換伺服器會**整頁重新載入**，等於登出重來——各服的帳號不互通。對局中不要換。 | 換服要重新登入，對局中別換（WP-F 執行，見 §8.4） |
| 進階設定 Bot 說明 | Bot 會在遊戲開始時自動創建，通常不需要手動管理。 | 開局時自動建立，通常不必管（WP-F 執行，見 §8.4） |

橫幅的 summary 第二行（等寬字的技術摘要）不改：那是回報 bug 時要貼的內容。
`JSInjectionFailureBanner` 的新標題**已裁決**為「App 元件載入失敗」；「JavaScript」只留在第二行摘要。

---

## 5. 工作包拆分建議

### 共通規則

- 執行順序：WP-0p → WP-0 → WP-A → WP-B → WP-C → WP-D → WP-F → WP-E。原順序（不含 WP-F）為用戶裁決；WP-F 插在 WP-E 之前的理由見 §8.8。

- 驗收前提：`rendered/*.png` 是 HTML 原型的渲染，不是 App 截圖，不套 App 的 1.5% 門檻。本機沒有 ImageMagick（`which compare magick` 皆 not found）。
- Build 閘：每個改 Swift 的包都要跑四個 build，全部 `BUILD SUCCEEDED`。新增用到 `#if DEBUG` stub 的 `#Preview` 必須自己包 `#if DEBUG`。

```bash
xcodebuild build -project Naki.xcodeproj -scheme Naki -configuration Debug
xcodebuild build -project Naki.xcodeproj -scheme Naki -configuration Release
xcodebuild build -project Naki.xcodeproj -scheme Naki-M -configuration Debug -destination 'generic/platform=iOS Simulator'
xcodebuild build -project Naki.xcodeproj -scheme Naki-M -configuration Release -destination 'generic/platform=iOS Simulator'
```

- 新增或改動的使用者可見字串，由該包自己補 en／ja／ko／zh-Hans 翻譯，不等 WP-D。

### WP-0p：測試不寫真實偏好設定（WP-0 的前置，**已合入 main `1dceb6d`**）

- 問題：test host 一啟動，`NakiApp` 的 `NakiRuntime.init` 就呼叫 `adoptStoredAutoPlayMode`，在任何 `setUp` 之前對 `.standard` 寫入（`CLAUDE.md`「專案結構的坑」）。隔離 suite 與確認 `pending` 為 null 都擋不住它。
- 範圍：需要改 `command/App/`，超出 UI 包的可改邊界；用戶已同意另立此包，已完成並合入 main `1dceb6d`（當時 worktree `Naki-wt-wp0p`，派工檔在主 repo 的 `.swfd/logs/wp-0p/dispatch.md`）。
- 原始碼：`command/App/NakiRuntime.swift` 的 `init`（test host 分支）。只有證明單改 `init` 不夠時，才動 `command/App/SettingsStore.swift` 的 `standard` 與 `command/Services/Bot/AutoPlayMode.swift` 的 `AutoPlayModeStore.defaults`；後者屬 Services 層，UI 包不得改，只有 WP-0p 依其派工檔的條件可改。
- 測試：`SettingsStoreTests.swift`、`ObservedMatchSidsTests.swift`（直接提到 `UserDefaults.standard` 的兩檔）；新增一個 characterization test，改動前失敗、改動後通過。
- 文件：`CLAUDE.md`「專案結構的坑」中「基底即有，尚未處理」那句改成現況。
- 驗收：先確認 `/game/state` 的 `pending` 為 null；測試前後量真實偏好檔 `~/Library/Preferences/org.39c154f25912233a.akagi.plist` 的 sha256，必須相同；測試結束後 `pgrep` 只剩用戶原本的 Naki；全套 0 failures（基準 1003）；macOS Debug／Release 與 iOS Debug build 通過。
- 清理與強化：不可略過強化（characterization test 必須先紅後綠）。不得自動刪除已累積的 `naki.tests.*` 空殼 plist。
- WP-0p 已完成，WP-0 已據此執行（main `8b51848`）。

### WP-0：元件快照 baseline 與比對工具

- 範圍：在 `NakiTests` 用 `ImageRenderer` 渲染固定 fixture 的 `DecisionSidebar`、`DecisionCard`、`OptionList`、五種橫幅，輸出 PNG 到 `docs/ui-reference/app-baseline/`。
- 固定條件：尺寸、scale、OS 版本、語系 zh-Hant、淺色與深色各一份、fixture 內容都寫進測試，baseline 檔名帶這些條件。
- 渲染完整性先驗：Apple 文件說明 `ImageRenderer` 不渲染部分原生控制項與容器，而橫幅含 `.bordered` 按鈕。第一步逐張人工確認畫面完整，畫不出來的元件不納入 pixel diff。
- 比對契約，分開測：
  1. 差異計數：改 1 個像素，計數必須等於 1。
  2. 門檻：差異占比剛好 1.5% 通過，超過 1.5% 失敗。
  3. 尺寸不同失敗。
  4. baseline 不存在或讀圖失敗時失敗，不得當成通過。
- 實際覆蓋（2026-10-13 建立，`NakiTests/UISnapshotTests.swift`，baseline 28 張＝14 種畫面 × 淺／深色，macOS 27.0、scale 2、zh-Hant）：`DecisionSidebar` 寬版（380×600）與窄版（220×560，同一份對局中 fixture）；`DecisionCard` 打牌、吃（含牌組說明）、窄版赤五；`OptionList` 寬版與窄版（含「還有 N 個」）；`DecisionAlerts` 雲端退化、自動打牌停滯、三麻無推薦；`PageLoadFailureBanner`（`.bordered` 按鈕實測畫得完整）、`BotFailureBanner`、`JSInjectionFailureBanner`、`LiqiParseFailureBanner`。
- 不覆蓋的區域：`UpdateAvailableBanner`（icon-only `.borderless` 關閉鈕被 `ImageRenderer` 畫成禁止符號佔位，圖證在主 repo `.swfd/logs/wp-0/excluded/`）、`StatusBar`、插件頁、`LogPanel`、工具列、設定頁、iOS 版面。這些區域不因 WP-0 通過而視為通過，各包改到時用人工截圖對照，並在報告列為「未經 pixel diff」。
- 風險：fixture 要建構 `NakiEnvironment` 裡的物件。單測釋放 MainActor 隔離的 class 會 SIGABRT；`command/` 已有 33 處 `nonisolated deinit`（2026-10-13 grep），WP-0 fixture 用到的 `GameStore`、`SettingsStore`、`PluginStore`、`UIState`、`JSInjectionState`、`LiqiParseFaultState` 都已補。設定物件走隔離 suite（`SettingsStore(defaults:)`、`L10n.defaults`、`AutoPlayModeStore.defaults`）。
- 檔案：新測試檔（`NakiTests` 是 synchronized group，不必改 pbxproj）、`docs/ui-reference/app-baseline/`。
- 清理與強化：不可略過強化。

### WP-A：token 收斂（spacing、cornerRadius、透明度、狀態色）

- 範圍：§3.1、§3.2、§3.4（五個狀態語意名稱與透明度）。把收斂後的值加進 `PanelLayout`，逐檔替換。
- 原始碼：`DecisionSidebar.swift`、`StatusBanners.swift`、`PluginsPageView.swift`、`AdvancedSettingsSheet.swift`、`ContentView.swift`、`LogPanel.swift`、`MajsoulConnectionSettingsBox.swift`。測試、翻譯：無。基準圖：WP-0 baseline。文件：無。
- 驗收：WP-0 覆蓋的元件差異 ≤1.5%；超過的畫面附前後截圖由用戶確認。未覆蓋區域人工對照。
- 清理與強化：可略過強化（純數值替換）；不可略過清理。清理閘：替換後 `command/Views` 不得再出現收斂表外的 spacing、cornerRadius、透明度值，明列排除 `TileImage.swift` 的牌身（第 102、105 行的 `cornerRadius: 3`、第 115 行的 `.padding(1)`，跟著牌面比例走）；除 `PanelLayout` 定義行與 `LogPanel` 的 `categoryColor` 外，不得再出現裸的 `.red`／`.orange`／`.green`／`.blue`。

### WP-B：數值與異常列動效

- 範圍：§2.1 的 `ScoreRow` 計數、延遲數值計數與上下限文字、`DecisionAlerts` transition；移除不變條件 1、2 的既有例外（`LogPanel` 捲動改經入口；iOS 面板 transition 改單純 `.move(edge: .trailing)`；`macOSLayout` 拿掉 `HSplitView` 上的 `.animation`，改在切換處 macOS 工具列的 `naki.ui.showGamePanel.toggle()`（`ContentView.swift` 約 398 行）包 `withAnimation`；iOS `onAppear` 依 `startsVisible` 設定初值（約 544 行）不加動畫）；新增 §3.6 的 `exit`、`standard` token。這兩項修的是動畫作用範圍，不以找到 macOS 崩潰紀錄為前提，也不宣稱修好任何崩潰。
- 原始碼：`DecisionSidebar.swift`、`ContentView.swift`、`AdvancedSettingsSheet.swift`、`LogPanel.swift`。翻譯：「最快」「最慢」四語系。基準圖：上下限兩張新預期圖（寬版與工具列窄版各一）。文件：無。
- 驗收：
  - 純動效（計數、`DecisionAlerts`、捲動）：最終幀與 WP-0 baseline 差異為 0。開啟與關閉「減少動態效果」各錄一次，人工確認開啟時直接切換。
  - 上下限文字：最終畫面會變，另建經用戶核准的預期圖；確認工具列窄版不擠壓、`accessibilityValue` 含「最快」或「最慢」。
- 清理與強化：不可略過強化。

### WP-C：原地確認（confirm-morph）與清單合攏

- 範圍：只有插件移除改原地確認、移除後清單合攏。「刪除 Bot」已裁決不加確認。
- 原始碼：`PluginsPageView.swift`。
  - 兩個「移除」按鈕都要改：有效插件詳情的那顆（已有 `plugin-remove-<id>`），以及無效插件分支的那顆（約 337 行，沒有 identifier，要補同一個 `plugin-remove-<id>`；兩者在不同分支、不會同時出現）。
  - 兩個平台的 `.confirmationDialog(removeDialogTitle, item: $pendingRemoval, …)`（約 73、89 行）都要移除，連同 `removeDialogActions`、`removeDialogMessage`。
  - 確認面的「取消」掛 `.keyboardShortcut(.cancelAction)` 讓 Esc 取消。插件頁本身是 sheet，Esc 會不會先被 sheet 吃掉**未驗證**，WP-C 要實測。
- 測試：新增 UI 測試檔放 `NakiUITests`。它在 pbxproj 是 `PBXFileSystemSynchronizedRootGroup`，不必登記 target 成員。翻譯：無新字串。「取消」「移除「%@」」「會刪掉 %@ 的整個插件目錄。可重新匯入或放檔案救回。」都是既有 key，四語系齊備（主 repo 的 `.swfd/logs/ui-design/copy-collision-check.log`）。文件：無。
- 驗收：既有 `plugin-remove-<id>` identifier 保留；UI 測試涵蓋：
  1. 點一次不刪，點確認才刪。
  2. 確認面出現 0.28 秒內的快速雙擊不刪。
  3. 4 秒後自動退回。
  4. A 的確認面開著時改選 B，A 的確認面消失，B 不會被刪。
  5. 取消後重開，計時重新從 4 秒算。
  6. Esc 取消；離開頁面後再回來，確認面不在。
  7. 刪除失敗時那一列留下、確認面收起。
  - 不得出現「復原」。
- 清理與強化：不可略過強化（破壞性操作）。

### WP-D：文案

- 範圍：§4 全表（裁決已併入表內），但不含標「WP-F 執行」的列。歸屬判準（§4.1、§8.5 用同一句）：WP-F 負責 `AdvancedSettingsSheet.swift`、`MajsoulConnectionSettingsBox.swift` 內的全部字串，加上工具列設定鈕（`ContentView.swift` 320、322、601）與伺服器選擇畫面那一句（`ContentView.swift` 781）；其餘字串歸 WP-D。
- 原始碼：`Localizable.xcstrings`、`DecisionSidebar.swift`、`StatusBanners.swift`、`ContentView.swift`（工具列、`ConnectionIndicator`、`ServerPickerView`，第 781 行那句除外）、`PluginsPageView.swift`、`LogPanel.swift`。`AdvancedSettingsSheet.swift` 歸 WP-F。測試：`AppLanguageTests` 與以字串查元素的 UI 測試。
- 驗收：
  - 不用 `plutil -lint`：它對 `.xcstrings` 回報 `Unexpected character { at line 1` 並 exit 1，但檔案是合法 JSON。
  - 改用 JSON 解析，檢查 `sourceLanguage` 為 zh-Hant、每個 key 有 en／ja／ko／zh-Hans 四語系、各語系的插值占位符數量與種類和 key 一致。
  - 舊 key 不得殘留（grep 為空）；多對一合併逐語系人工確認；最後以共通規則的四個 build 驗證。
- 清理與強化：不可略過清理（舊 key 殘留會變成永遠不顯示的翻譯）。

### WP-F：設定分頁

規格在 §8；範圍、檔案、驗收見 §8.8。

### WP-E：語意色與玻璃

- 範圍：§3.4 槓的顏色（已裁決：`.indigo`）、§3.5 兩處玻璃。
- 原始碼：`command/Models/GameModels.swift`（槓色）、`ContentView.swift`（玻璃）。
- 測試：`NakiTests/PlatformDivergenceTests.swift` 的 `testVersionCheckExistsExactlyOnce`（允許清單加入玻璃分歧，見 §3.5）。
- 基準圖：原型裡槓的 tone 寫死為紅，只改 Swift 重產不出新色。槓色獲准後，同包修改 `prototype.html` 的槓 tone，再重產 `rendered/ankan.png`、`kakan.png`、`minkan.png` 與 WP-0 baseline。§1「不重畫 prototype」指不改設計，不排除這種顏色 token 的同步。
- 文件：`CLAUDE.md`「唯一 `#available` 在 `WebSession.init`」那句要改成區分 web backend 與 UI 分歧；`docs/ui-reference/implementation-decisions.md` 的已知遺留「紅同時是槓與危險」要更新。
- 驗收：玻璃需 iPhone 實機（iOS 26）與 iOS 17–25 模擬器各看一次，舊 OS 必須實際執行確認 `.ultraThinMaterial` fallback；模擬器測試前關閉硬體鍵盤直通（`implementation-decisions.md` 記載的幽靈事件）。
- 清理與強化：不可略過強化（iOS 崩潰未解，疊在 WebView 上的元件要實機驗）。

---

## 6. Deviations

| # | 派工檔的說法或計畫 | 實際 | 選擇的保守方案 |
|---|---|---|---|
| 1 | 「全檔無 Material／`.transition`」 | `.ultraThinMaterial` 2 處（`ContentView` iOS 浮動圓鈕、`IOSStatusOverlay`）；`.transition` 1 處（iOS 面板，已有 reduce motion 分支） | 本文件以 grep 結果為準，§3.5 從現況出發 |
| 2 | 「`withAnimation` 2 處」 | 4 處：`LogPanel` 1、`ContentView` 2、`DecisionSidebar` 1 | 同上 |
| 3 | 「cornerRadius 3/4/5/6/8」 | 另有 7 與 10 | §3.2 納入 |
| 4 | 「spacing 0/1/2/4/5/6/8/10/12/16/20」 | `spacing:` 另有 3 與 14；padding 另有 7、9 | §3.1 納入 |
| 5 | spike 建議「`DesignTokens` enum」（派工檔提議的名稱，本包未建立） | 新檔要動 pbxproj 兩個 exception set（不是一行）；同檔另開 enum 會讓 token 有兩個來源 | token 併入既有 `PanelLayout`，只加 spike 用到的 `valueChange` |
| 6 | 驗收「截圖 pixel diff 對 `rendered/` baseline 1.5%」 | `rendered/` 是 HTML 原型渲染，不宜套 App 門檻（未實測比對，不宣稱「必定不通過」）；本機無比對工具；本包只被允許 GET `/status`、`/game/state`，無法擷取 App 截圖 | §5 改為 WP-0p → WP-0 建立元件 baseline；本包未產生 baseline |
| 7 | 驗收「每個引用的 API 名稱在 worktree 內可 grep 到」 | 系統 API（`glassEffect` 等）在 worktree 沒有使用處 | 在文中標「SwiftUI 系統 API，worktree 尚未使用」；以腳本逐一檢查並把結果存 log |
| 8 | spike 建議的數字計數位置未指定；直覺位置是決策卡百分比 | 百分比換手時計數會誤導（§2.2） | spike 改用摘要條自家點數 |
| 9 | 專案 CLAUDE.md 要求維護 `xxxxx-implementation-notes.md` | 派工檔範圍只允許 `docs/plan/ui-design-reference.md` 一份文件 | 以本節作為 implementation notes，不另開檔 |
| 10 | 主線指示 §3.1 窄版「往下一格」（例：12 → 10、16 → 12） | 套用後 `padding(compact ? 10 : 16)` 變 12／16，iOS 220pt 欄的窄版內容反而變窄 | 改採「最近值、等距取大」，窄版維持現況寬度。**統帥代決** |
| 11 | 初稿把「macOS 標題列顯示分頁名稱」詮釋為 sheet 頂端的自訂標題列 | 用戶裁決採原生 `Settings` scene；設計者再提 sheet 方案，用戶維持原裁決 | 「標題列」指原生設定視窗的標題列，隨選取的分頁名變化（§8.2）；sheet 頂端自訂標題 `HStack` 移除 |
| 12 | 演示頁註明「分頁切換是 0.2 秒淡入」 | macOS `Settings` 視窗的 `TabView` 切換由系統處理；自訂淡入要自做分頁列 | 不加動畫，直接切換（與 reduce motion 開啟時相同） |
| 13 | 主線上一輪指示的截圖對策之一是「有設定視窗時優先截它」，設計者曾採用 | Astra 第 6 條指出這會改變既有 `mainWindow → attachedSheet` 的選擇 | 改為 `/screenshot?window=settings` 明確參數，不帶參數時行為不變（主線本輪傾向同此） |
| 14 | 上一輪設計讀 SwiftUI 自己給的設定視窗 identifier | 系統值不是公開 API，Astra 第 6 條指出不能當穩定契約；自設 identifier 又會改到 SwiftUI 擁有的視窗狀態 | 設定根 View 以 weak 參考登記所在視窗，查詢比對物件；不讀也不改 identifier |
| 15 | 主線指示設定頁「兩處『本地』→『本機』」 | `AdvancedSettingsSheet.swift` 的使用者可見字串有三處四個 key 含「本地」（167、337、338、673）；612 那句已由 §8.4 定稿取代 | 四個 key 全列入 §8.5，避免同頁新舊用詞並存 |
| 16 | 上一輪設計 `POST /debug/ui` 最多等 2 秒並輸出 `settingsOpenRequest` | 主線復驗：等待把觸發與觀測綁在同一請求，序號對呼叫端無用 | `POST` 立即回當下值，呼叫端 `GET` 輪詢；序號只作觸發，不輸出 |
| 17 | 主線指示 WP-F 首步先跑兩條 UI 測試命令取現況基準，若會寫真實設定則改只 build | §5 WP-0p 問題段記載 `NakiRuntime.init` 寫 `.standard`，WP-0p 只隔離 test host；現有 UI 測試啟動的是真 App 且未設 `launchEnvironment` | 基準改為 `build-for-testing` 只 build 不跑（尚未實跑確認會寫） |

## 7. 審查修訂（2026-10-13）

Astra 審查 13 條全部採納。逐條回應見主 repo 的 `.swfd/logs/ui-design/astra-response.md`。

| 節 | 修訂 |
|---|---|
| 開頭 | 原型只作版面與動作色參考，排除失效控制與過時三麻說明（第 8 條） |
| §1 不變條件 | 減少動態效果一律直接切換；兩條既有例外分列並寫出移除條件（第 9、10 條） |
| §2.1 | 延遲數值改用 `PanelLayout.valueChange`，不用 `.snappy`（第 11 條）；原地確認保留 `pendingRemoval` 目標、`.task(id:)` 管逾時、失敗處理（第 2 條）；reduce motion 欄改直接切換（第 10 條） |
| §4 | 「關閉提示」不改；撞名檢查與多對一合併規則（第 6 條） |
| §5 | 新增共通 build 閘與翻譯責任（第 12、13 條）、WP-0p 前置（第 1 條）、WP-0 比對契約與覆蓋邊界（第 3、7 條）、WP-B 驗收分流（第 4 條）、WP-C 驗收清單（第 2 條）、WP-D 改 JSON 驗證（第 5 條）、WP-E 原型同步與文件（第 12 條） |
| §6 | Deviation 6 不再宣稱「必定不通過」（第 7 條） |

用戶裁決見 `docs/plan/ui-design-adr-2026-10-13.md`。

### 復驗修訂（2026-10-13）

主線獨立復驗的 8 項必修與 3 項建議全部處理（證據在主 repo 的 `.swfd/logs/ui-design/verify-*.log`）：

| 節 | 修訂 |
|---|---|
| §1 不變條件 1 | 加入 iOS 面板 transition 這個入口外分支點 |
| §2.1 | 時長改引用 §3.6 token；reduced motion 列改「調整」；修正 confirm-morph 列缺少的欄位分隔 |
| §3.1 | 換算規則改為「最近值、等距取大」，列出全部成對值、18 與 1 的使用處、窄版較大的例外 |
| §3.2 | `DecisionAlerts` 本來就是 6；5 只有 `ScoreRow` |
| §3.4、§5 WP-A | 狀態色收進 `PanelLayout` 併入 WP-A 並加清理閘；透明度全部歸類；色彩重疊列為已知風險 |
| §3.5 | 引用 `NakiWebViewHost.swift` 的規則，並指出 `PlatformDivergenceTests` 會擋，WP-E 須同包修改 |
| §3.6 | 新增動畫時長 token |
| §4.1 | 三個 Toggle 與 GroupBox 列改「不改」，其中背景保活為統帥代決 |
| §5 | WP-0p 補欄位；WP-B 點名切換處；WP-C 補第二顆移除鈕、移除兩處 dialog、Esc 機制、`NakiUITests` 不需登記、確認面文案全部沿用既有 key |

### 設定分頁（2026-10-13）

新增 §8 與 §5 WP-F（之後依用戶補充裁決，§8.2 由 sheet 改為原生 `Settings` scene；設計者再提 sheet 方案後用戶維持原裁決，§8.2 改為定案並逐條列出已知代價與對策）；§4 標出歸 WP-F 的列並把「進階設定」改「設定」；§5 執行順序插入 WP-F、WP-D 範圍排除設定頁 key；§6 新增第 11、12 條。

Astra 審查設定分頁 13 條（總評 REWORK，方向不變），全部採納。逐條回應見主 repo 的 `.swfd/logs/settings-tabs/astra-response.md`。

| 節 | 修訂 |
|---|---|
| §8.2 | 設定根 View 掛 `.appLocale()`（第 1 條）；開啟請求（`settingsOpenRequest`）與視窗可見分開，`/debug/ui` 回應時點、逾時與欄位寫定（第 2 條）；不依賴 `.onDisappear`／`dismiss`，列為假定不可靠（第 3 條）；`DebugUIStateTests` 契約逐條列出（第 4 條）；平台分歧收在 Action（第 5 條）；截圖改明確參數、設定視窗以 weak 參考辨識（第 6 條） |
| §8.1、§8.6 | iOS 重設時機寫定（第 13 條）；新增不變條件 5、6 |
| §8.3 | Header 草稿上移到根 View 並列為例外（第 7 條）；全部 `@State`、重複 identifier 的查詢方式（第 8 條） |
| §8.4 | 兩句定稿補啟用條件（第 13 條）；兩項待裁決改為保留成一句提示（第 10 條，主線指示） |
| §8.5、§4 | 完整改名清單與引用點，補伺服器選擇畫面字串（第 9 條） |
| §8.8 | UI 測試命令、destination、測試內容與隔離前提（第 11 條）；主 repo 路徑與計數命令（第 12 條） |
| §6 | 新增第 13、14 條 |

主線復驗設定分頁：必修 4 條、建議 9 條全部採納，含兩項**統帥代決**。

| 節 | 修訂 |
|---|---|
| §8.2 | 可見判定改為「已登記且 `isVisible`」（必修 1）；`POST` 立即回當下值、刪除等待函式與 `settingsOpenRequest` 輸出（建議 1、3）；互斥只對 `apply` 成立（建議 5）；代價與對策總表（建議 6）；`.appLocale()` 位置說明（建議 7）；視覺驗證分工：HTTP 截圖為主、Accessibility 斷言補 toolbar（建議 4，統帥代決） |
| §8.8 | UI 測試隔離鉤子為前置，沒有鉤子不得跑 UI 測試，移除「套用並重新載入」情境（必修 2，統帥代決）；首步只 build 不跑（建議 8）；smoke 第 1、3 步改寫（建議 4、5）；基底 main |
| §8.5、§5、§4.1 | 「決策來源」「本地」「自動送出不可用」列入改名（必修 3、建議 9）；WP-D／WP-F 歸屬判準三處同一句（必修 4） |
| §5 WP-0p | 改為已合入 `1dceb6d`（建議 9） |
| §6 | 新增第 15、16、17 條 |

---

## 8. 設定分頁

用戶裁決（2026-10-13，ADR 第 8 項）：設定分四組（一般／連線／AI／開發者）；每個 GroupBox 的說明縮成一句；macOS 採原生 `Settings` scene（toolbar 圖示分頁、標題列顯示分頁名稱、⌘, 開啟），選單與 iOS 導覽列寫「設定」；iOS 仍是 sheet。
來源：演示頁在主 repo 的 `.swfd/logs/ui-demo/naki-ui-demo.html` 的「設定分頁提案」段與截圖 `shot-tabs-*.png`。

### 8.1 分頁與歸屬

現況是 `AdvancedSettingsSheet` 一張 sheet，macOS 兩欄（左 `operationalSettings`、右 `cloudSettings`），iOS 單欄捲動。

| 分頁 | GroupBox（由上而下） | 現況位置 |
|---|---|---|
| 一般 | 語言（只有 macOS）、畫面、更新 | `languageBox`、`displayBox`、`updateBox` |
| 連線 | 雀魂伺服器、雀魂連線 | `majsoulServerBox`、`MajsoulConnectionSettingsBox` |
| AI | 自動打牌（只在不支援自動送出時出現）、自動操作、雲端推論（開關、說明、4p／3p 模型、生效狀態、三麻提醒） | `autoPlayAvailabilityBox`、`autoPlaySettingsBox`、`cloudSettings` 上半 |
| 開發者 | 雲端 API（新 GroupBox：伺服器 URL、預設鈕、預設 URL 行、API Key、測試連線與結果、生效狀態、金鑰狀態表）、Bot 管理、MCP Server | `cloudSettings` 下半、`cloudKeyStatusCard`、`botManagementBox`、`mcpServerBox` |

- 「顯示狀態訊息列」只有 iOS，留在一般頁的畫面框內。
- macOS：`Settings` scene 內放 `TabView`，每頁一個 `.tabItem`（圖示加分頁名），呈現為視窗 toolbar 的圖示分頁。
- iOS：同一張 sheet 單頁捲動，四組依序排列，每組以分頁名稱當段落標題。「開發者」整組包在 `DisclosureGroup`，預設折疊。每次 sheet 出現時捲到頂端、「開發者」折疊；重設時機是 sheet 出現，因為折疊狀態是 sheet 內的 `@State`，隨 sheet 重建。
- 分頁歸屬只有一個定義點：`AdvancedSettingsSheet` 內一個 `SettingsTab` enum（`general`、`connection`、`ai`、`developer`，各帶標題）加一個 `page(_:)` 函式回傳該頁的 GroupBox。macOS 的 `TabView` 與 iOS 的四個段落都呼叫它。名稱為**提議**，worktree 尚無。

### 8.2 macOS 實作方式：原生 `Settings` scene（定案）

用戶裁決採 `Settings` scene（ADR 第 8 項）。設計者曾提出改用 sheet 的方案與證據，用戶看過後維持原裁決，接受下列代價。本節寫出狀態模型與每條代價的對策，不留假功能。Astra 審查與主線復驗（2026-10-13）的修法都落在本節。

**代價與對策總表**（細節見下方各段）：

| # | 代價 | 對策 |
|---|---|---|
| 1 | `OpenSettingsAction` 只能從 View 的 environment 取得，`UIState` 不能直接開視窗 | `apply(.settings)` 遞增 `settingsOpenRequest`，macOS `ContentView` 以 `.onChange` 呼叫 `openSettings()` |
| 2 | 設定視窗不是 sheet，關閉（⌘W、紅鈕）不寫任何旗標；`.onDisappear` 假定不可靠 | 可見狀態改由 `SettingsWindowAction` 讀實際視窗；開啟只依賴請求序號變化 |
| 3 | 設定視窗不受 `apply(screen:)` 的互斥管 | body 含 `screen` 且值不是 `settings` 時，`DebugServer` 經 Action 關閉設定視窗 |
| 4 | 開啟發生在下一次 View 更新，`POST` 回應時可能還沒開 | `POST` 立即回當下可見值；呼叫端以 `GET /debug/ui` 輪詢 |
| 5 | 第二個 scene 不繼承主視窗的 environment | scene 內容自己注入 `\.naki` 與 `.appLocale()` |
| 6 | 預設截圖路徑截不到獨立的設定視窗，且截不到 toolbar | 新增 `/screenshot?window=settings`；分頁列與標題列以 `NakiUITests` 的 Accessibility 斷言驗 |
| 7 | 主視窗不在時請求沒有讀者 | 不重播；回應照實回不可見 |
| 8 | 背景時 `openSettings()` 行為未知 | 不加 `NSApp.activate`；通過標準是回報與實際一致 |

**Scene、`\.naki` 與語言注入**（`Naki/App/NakiApp.swift`，`WindowGroup` 之後）：

```swift
Settings {
    AdvancedSettingsSheet()
        .appLocale()
        .environment(\.naki, runtime.environment)
}
```

- `\.naki` 與 `WindowGroup` 內的 `ContentView` 用同一個 `runtime.environment`。漏掉會讀到 Preview 預設值，形成 `NakiApp` 註解警告的雙重真實來源。
- `.appLocale()` 必須掛，且必須寫在 `.environment(\.naki, …)` 之前。SwiftUI 的 environment 由外層往內傳：`.environment` 寫在後面就是外層，先把 `\.naki` 放進 environment，`AppLocale` 在內層才讀得到 `naki.settings.locale`。順序反過來，`AppLocale` 讀到的是 Preview 預設值。`command/Services/L10n.swift` 的 `AppLocale` 註解要求每個獨立內容根自己掛；現行 sheet 是 `AdvancedSettingsSheet().appLocale()`（`ContentView.swift` 兩處）。漏掉的話，一般頁改了語言，設定視窗本身不跟著換。
- 不需要 `#if os(macOS)`：`NakiApp.swift` 只屬於 macOS target，iOS 入口是 `Naki-M/Naki_MApp.swift`（兩者都有 `@main`）。
- 依 Apple `Settings` 文件，宣告這個 scene 後 SwiftUI 會啟用 App 選單的「設定」項目與 ⌘,，並負責顯示與移除視窗。不需要自己加 `CommandGroup`；選單文字由系統在地化。
- 標題列是原生視窗標題列，由 `TabView` 選取的分頁名驅動。**推測**：這是 macOS 設定視窗的標準行為，WP-F 以 UI 測試確認。
- 沿用 `AdvancedSettingsSheet` 型別當設定根 View，不新增檔案，pbxproj 不動。

**開啟路徑**：

| 來源 | 做法 |
|---|---|
| ⌘, 與 App 選單 | 系統內建 |
| 工具列齒輪（macOS） | 改為 `SettingsLink`，保留 identifier `toolbar-settings` 與 `.help("設定")` |
| `POST /debug/ui` 的 `{"screen":"settings"}` | 見下方狀態模型 |
| iOS | 維持 `.sheet(isPresented: $ui.showAdvancedSettings)`，行為不變 |

**狀態模型：開啟請求與視窗可見分開**

| 語意 | macOS | iOS |
|---|---|---|
| 開啟請求 | `UIState.settingsOpenRequest`（**提議**，`Int`）。`apply(screen: .settings)` 每次加 1，其他 screen 不動它 | 同一欄位也加 1，但沒有讀者；iOS 由 `showAdvancedSettings` 開 sheet |
| 視窗可見 | `SettingsWindowAction`：已登記的設定視窗存在，且該視窗 `isVisible` 為 true（見下方「視窗辨識」） | `showAdvancedSettings`（sheet binding；SwiftUI 關 sheet 時寫回 false） |
| `showAdvancedSettings` | `apply(screen:)` 照舊寫入（維持互斥測試），但 macOS 沒有任何 View 綁定或讀取它 | sheet binding，同時代表請求與可見 |

- macOS 開啟：`ContentView` 讀 `@Environment(\.openSettings)`，以 `.onChange(of: naki.ui.settingsOpenRequest)` 呼叫 `openSettings()`。每次請求都是新值，重複送 `settings` 也會觸發；⌘W 或紅鈕關閉後再送也會觸發。開啟不依賴任何會被關閉動作破壞的旗標。
- 不用 `.onAppear`／`.onDisappear`／`dismiss` 同步狀態。**假定不可靠**：已有附最小程式的回報指出 `Settings` 關閉時不呼叫 `.onDisappear`（[Stack Overflow 72313074](https://stackoverflow.com/questions/72313074/swiftui-detecting-when-preferences-settings-window-closes)），Apple 的 `DismissAction` 文件也沒有保證 `Settings` 的關閉行為。這是歷史反例，未在 macOS 26 實測；設計不依賴它成立與否。
- `ContentView` 不在（主視窗已關、App 仍執行）：請求沒有讀者，視窗不會開，回應照實回報不可見（見下）。主視窗之後出現時不補開（`.onChange` 不在首次出現時觸發），舊請求不重播。
- `openSettings` 在 macOS 14 起可用，Naki 最低 macOS 26，不需要 `#available`。

**互斥成立的時點**：

- 互斥只對 `apply(screen:)` 路徑成立。使用者用 ⌘, 或工具列齒輪開設定時不經過 `apply`，所以插件 sheet 開著時再按 ⌘, 會兩者並存，這是預期行為。
- `UIState` 的四個畫面旗標在 `apply(screen:)` 回傳時就互斥，與現在相同。
- body 含 `screen` 且值不是 `settings` 時，`DebugServer` 在同一個處理流程內呼叫 `SettingsWindowAction` 的關閉（macOS 對設定視窗 `performClose`，iOS 不做事），所以回應送出前設定視窗已關。body 沒有 `screen` 欄位（例如只送 `language`）時不動設定視窗。
- `screen` 是 `settings` 時，視窗在下一次 View 更新才開。`settings → plugins`：設定視窗關閉，插件 sheet 開在主視窗。

**`POST /debug/ui` 的回應時點與欄位**：

- `POST` 套用全部欄位後立即回應當下的可見值，不輪詢、不等待。含 `"screen":"settings"` 時，回應的 `showAdvancedSettings` 通常還是 false，因為視窗在下一次 View 更新才開。
- 呼叫端（smoke 腳本、UI 測試）以 `GET /debug/ui` 輪詢可見值，自訂逾時。
- 回應一律 200（請求已被接受）。欄位名與欄位集合不變；`showAdvancedSettings` 的語意改為「設定畫面目前可見」（macOS 讀 `SettingsWindowAction`，iOS 讀旗標）。`settingsOpenRequest` 只是觸發機制，不輸出。
- 開不出來（沒有讀者、背景）：`GET` 一直回 false，呼叫端以逾時判定失敗。同一個 body 的 `language`、`recommendations` 等欄位已經寫入，不回滾（與現行「欄位逐一套用」的語意相同）。

**視窗辨識**：設定根 View 在 macOS 區塊內用一個小型 `NSViewRepresentable`（**提議**，放在 `AdvancedSettingsSheet.swift` 現有的 `#if os(macOS)` 內），在 `viewDidMoveToWindow` 把所在的 `NSWindow` 以 weak 參考登記給 `SettingsWindowAction`。「可見」的判定是：weak 參考仍指向視窗，且該視窗 `isVisible` 為 true。視窗關閉後 SwiftUI 可能保留它（`isVisible` 為 false）或釋放它（weak 參考變 nil），兩種都算不可見；關閉後是否保留**未驗證**，判定不依賴它。查詢時比對這個物件，不比對 identifier。不讀 SwiftUI 給的 identifier（系統值不是公開 API），也不改寫它（SwiftUI 可能用它管理設定視窗，改寫可能讓 ⌘, 開出第二個視窗）。

**`SettingsWindowAction`**（**提議**，`command/Actions/NakiActions.swift`）：

- 「是否可見」回傳 `Bool?`：macOS 回實際視窗狀態，iOS 回 `nil`。「關閉」在 iOS 不做事。「截圖」給 `/screenshot?window=settings` 用（見下）。
- 平台分歧放在這個 Action 的 `#if os(macOS)` 內。`DebugServer` 經 `NakiMCPDependencies` 取得它（與 `captureScreenshot` 同一種注入方式），只處理平台中立的結果：可見值為 `nil` 時改讀 `ui.showAdvancedSettings`。Debug 層不加 `#if os(`。

**截圖**：

- `GET /screenshot` 不帶參數時行為不變：`mainWindow ?? keyWindow ?? 第一個可見視窗`，有 sheet 截 sheet。設定視窗開在背景時也不會被截到。
- `GET /screenshot?window=settings`（新增）：截設定視窗的 `contentView`；設定視窗不可見時回 `{"error":"settings window not visible"}`。iOS 回同一錯誤（設定是 sheet，照不帶參數的路徑截）。
- 現在路由會丟掉 query（`DebugServer.swift` 拆 `?` 的那一行）。WP-F 在 `DebugHTTPRequest` 加 `query` 欄位傳給 handler。
- 這是 HTTP `/screenshot` 的能力；MCP 層沒有截圖工具（`command/Services/MCP` 只有註解提到 `/screenshot`）。
- 截圖只含 `contentView`，不含 toolbar（現行已知限制，見 `windowScreenshot` 註解）。WP-F 在 `windowScreenshot` 註解補「設定視窗同樣截不到分頁列」。
- 視覺驗證分工（**統帥代決**，依 2026-10-09 用戶定案「視覺驗證以 HTTP 截圖為主」）：分頁內容一律以 `GET /screenshot?window=settings` 驗；只有 HTTP 截不到的 toolbar 分頁列與標題列，由 `NakiUITests` 以 Accessibility 斷言驗（分頁按鈕存在且可選、視窗標題等於分頁名）。

**背景時的通過標準**：App 在背景時送 `{"screen":"settings"}`，不要求視窗開得出來或取得焦點；要求 `GET /debug/ui` 的 `showAdvancedSettings` 與實際視窗一致（以 `NakiUITests` 的 `XCUIApplication().windows` 判斷）。不加 `NSApp.activate` 或私有 selector `showSettingsWindow:`。

**`DebugUIStateTests` 的契約改動**（`NakiTests/DebugUIStateTests.swift` 不起 server，只能鎖純函式；真實視窗由 §8.8 的 UI 測試鎖）：

- `testEachScreenOpensExactlyOne`：不變。
- 新增：`apply(screen: .settings)` 連續兩次，`settingsOpenRequest` 加 2；其他 screen 不改它。
- `testStatusPayloadReportsFlagsAndLanguage`：`uiStatusPayload` 多一個可見參數（**提議** `settingsVisible:`），欄位集合不變。補一條：`ui.showAdvancedSettings` 為 true、參數為 false 時，欄位是 false。
- `parseUIRequest` 不改，`testEveryKnownValueParses` 不受影響。
- `docs/release-notes/v2.15.0.md` 的既有描述不改（歷史紀錄）。

**兩條路徑共用與分歧**：

| 部分 | macOS | iOS |
|---|---|---|
| `SettingsTab`、`page(_:)`、全部 GroupBox、全部 `@State`、`.task(id: cloudProbeToken)` | 共用，放在 `AdvancedSettingsSheet.swift` 的條件編譯之外 | 共用 |
| 入口 | `NakiApp` 的 `Settings` scene | `ContentView` 的 `.sheet` |
| 根 View 的 body | `TabView`，每頁 `.tabItem`；單欄；無自訂標題列、無完成鈕；視窗辨識用的 `NSViewRepresentable` | 單頁捲動，四段依序，「開發者」包 `DisclosureGroup`；導覽列標題「設定」與完成鈕 |
| 開啟 | ⌘,、`SettingsLink`、`settingsOpenRequest` → `openSettings()` | `showAdvancedSettings` |
| 可見狀態來源 | `SettingsWindowAction` | `showAdvancedSettings` |

`PlatformDivergenceTests` 的影響：

- `#available` 計數不變（`Settings`、`SettingsLink`、`openSettings` 最晚在 macOS 14 起可用，Naki 最低 macOS 26）。
- 根 View body 的平台分歧沿用 `AdvancedSettingsSheet` 現有 `#if os(macOS)`／`#else` 那一處（現在切 `macOSSettingsContent` 與 `iOSSettingsContent`）。視窗辨識的 `NSViewRepresentable` 放進現有 macOS 區塊。
- `ContentView` 的改動都在現有 macOS 區塊內。
- 視窗查詢、關閉與截圖放在 `NakiActions.swift` 的 `#if os(macOS)`，不放進 `Services/Debug/` 或 `Services/MCP/`，所以 `testDebugAndMCPLayerIsNotPlatformGated` 維持通過。

**名稱不改**：`showAdvancedSettings`、`Screen.settings`、`AdvancedSettingsSheet`。前兩者是 `GET /debug/ui` 的 JSON 欄位與測試契約；改型別名要動檔名與 pbxproj。

**其他**：

- macOS 設定視窗沒有完成鈕，以視窗關閉為準。`settings-done-button` 只留在 iOS。
- 分頁切換由系統處理，不加動畫（§6 第 12 條）。
- 視窗尺寸：單欄，寬 600（**提議**），WP-F 對照演示頁截圖定值。
- `TabView`、`.tabItem`、`SettingsLink`、`OpenSettingsAction`（`openSettings`）、`Settings` scene、`NSViewRepresentable` 是 SwiftUI 系統 API，`NSWindow.identifier`、`performClose` 是 AppKit API，`showSettingsWindow:` 是 AppKit 私有 selector；worktree 都尚未使用（`NSViewRepresentable` 已在 WebView 層使用）。

### 8.3 雲端設定拆兩頁的資料流

```text
SettingsStore（cloudInferenceEnabled、cloudServerURL、cloudAPIKey→CloudKeyStore、模型欄）
  ← AI 頁：開關、模型欄寫入；生效狀態讀
  ← 開發者頁：URL、金鑰寫入；生效狀態、金鑰狀態讀

設定根 View（AdvancedSettingsSheet）的 @State（cloudTest、cloudModels、cloudKeyStatus、cloudProbeFailure、cloudTestRunning、cloudProbing）
  ← 開發者頁「測試連線」與父層 .task(id: cloudProbeToken) 的自動探測寫入
  → AI 頁模型選單讀 cloudModels；開發者頁讀 cloudTest、cloudKeyStatus
```

- 兩頁讀寫同一個 `SettingsStore`，不得在分頁內複製任何設定值。
- 設定根 View 現有的全部 `@State`（上面六個加 `updateCheckRunning`）與 `.task(id: cloudProbeToken) { await autoProbeCloud() }` 必須留在設定根 View（macOS 是 `Settings` scene 的內容，iOS 是 sheet），不得下放到分頁 View。下放的話，自動探測只在那一頁可見時才跑，切頁時探測結果也會丟失。
- `cloudEffectiveStateRow` 在 AI 頁與開發者頁**都顯示**。它是讀 `SettingsStore` 的衍生 View，不是狀態副本。原因：現行兩欄排版的目的是讓開關與其結果同時在畫面上（`settingsForm` 註解、Akagi #221 的形狀）。拆頁後，使用者在開發者頁貼好金鑰時看不到 AI 頁的開關；生效狀態列會直接說出「還缺什麼」。
- `autoProbeCloud` 現況在開關沒開時把 `cloudKeyStatus` 設為 nil，所以開關關著時開發者頁的金鑰狀態表是空的。這個語意不改；同頁的生效狀態列說明了原因。
- `cloudEffectiveStateRow` 兩處都帶 identifier `cloud-effective-state`，iOS 展開「開發者」後會同時存在兩個。UI 測試必須先以頁面容器限定查詢範圍（**提議** identifier `settings-page-general`、`settings-page-connection`、`settings-page-ai`、`settings-page-developer`），不得直接全域查這個 identifier。
- 模型選單的提示「先按「測試連線」取得模型清單」指向另一頁的按鈕，改為「先到「開發者」按「測試連線」」（新 key）。

**Header 草稿（Astra 第 7 條）**：

- 現況 `MajsoulConnectionSettingsBox` 以 `@State rows` 保存未套用的 Header 編輯，按「套用並重新載入」才寫回；它的 `.task` 每次執行都從 `SettingsStore` 覆寫 `rows`。切頁若讓這個 View 重建或 `.task` 重跑，未套用的輸入會消失。`TabView` 切頁是否重建分頁內容**未實測**，設計不依賴它。
- 修法：`rows` 移到設定根 View 的 `@State`，以 `Binding` 傳給 `MajsoulConnectionSettingsBox`。初始化放在根 View 的 `.task`：設定根 View 每次出現時從 `SettingsStore` 載入一次。分頁 View 不再載入或覆寫草稿。`defaultUserAgent` 是唯讀快取，留在原處。
- 草稿是 §8.6 第 1 條「不得持有設定值副本」的明確例外：它是使用者尚未送出的輸入，不是設定值的鏡像；寫回仍只經「套用並重新載入」。
- **推測**：macOS 關閉設定視窗後根 View 可能被保留，再開時不觸發 `.task`，草稿會留著上次未套用的內容。WP-F 實測並記錄；若保留，維持此行為（未套用的輸入不丟），不另加清除。

### 8.4 說明句定稿

規則：每個 GroupBox 一句說明。下列是狀態或提示，不算說明句，維持原文：目前 host、伺服器固定狀態、更新檢查結果、雀魂連線的驗證錯誤、雲端生效狀態、測試連線結果、預設 URL 行、三麻提醒（含「模仿天鳳人類」的強度聲明，對應 `CLAUDE.md` 的強度措辭規則；只依 §8.5 換「本機」「建議來源」兩個詞）、MCP 的 URL 與 curl 範例。

計數方式：中文字與全形標點各算 1；連續英數字（如 Akagi、API）算 1；空白不算。上限 20。計數腳本在主 repo 的 `.swfd/logs/settings-tabs/sentence-length.sh`（不隨 git 進 worktree），命令見 §8.8，輸出存同目錄的 `sentence-length.log`。

| GroupBox | 原文 | 定稿 | 字數 | 來源 |
|---|---|---|---|---|
| 自動操作 | 這是縮放係數，不是固定值：實際送出仍會套用 ActionDelayModel 的隨機分布。 | 延遲是倍率，實際送出仍會隨機浮動 | 16 | 改自演示頁草稿（草稿保留「縮放係數」術語） |
| 自動打牌（不支援時） | 模式選單只提供「關 / 推薦」。 | 模式選單只有「關」與「推薦」 | 14 | 新定稿（演示頁未畫） |
| 雀魂伺服器 | 換伺服器會**整頁重新載入**，等於登出重來——各服的帳號不互通。對局中不要換。 | 換服要重新登入，對局中別換 | 13 | 採演示頁草稿（同 §4.2） |
| 雀魂連線 | 額外 header 只套用在頁面主文件請求；User-Agent 會套用到全部請求，包含 WebSocket 握手。／變更後需重新載入才會生效。對局中不要套用。 | 套用時會重新載入，對局中別套用 | 15 | 改自演示頁草稿（草稿 21 字超標） |
| 語言 | 無 | 無 | — | 不新增 |
| 畫面 | 三段：背景保活說明、插件移交說明、iOS 狀態列說明 | 開啟後，視窗被蓋住仍低頻運作 | 14 | 改自演示頁草稿；補上開關啟用條件（Astra 第 13 條） |
| 更新 | 無 | 無 | — | 不新增 |
| 雲端推論 | 啟用後，每個決策點會把**本局至今的對局事件**（含自家手牌）上傳到下方伺服器換取決策；伺服器失敗時自動退回內建本地模型，對局不會停擺。API key 存在 Keychain，不會出現在 log 或設定檔。 | 啟用後上傳本局牌譜與手牌，失敗改用本機 | 19 | 改自演示頁草稿（草稿 32 字超標）；補上啟用條件（Astra 第 13 條） |
| 雲端 API（新） | 拆自上一列的金鑰句 | 金鑰存在鑰匙圈，不會寫進紀錄 | 14 | 新定稿；已核實金鑰經 `CloudKeyStore` 存 Keychain（`SettingsStore` 的 `cloudAPIKey`） |
| Bot 管理 | Bot 會在遊戲開始時自動創建，通常不需要手動管理。 | 開局時自動建立，通常不必管 | 13 | 採演示頁草稿（同 §4.2） |
| MCP Server | 無 | 無 | — | 不新增 |
| 雀魂連線（提示，放「新增 Header」下方） | 額外 header 只套用在頁面主文件請求；User-Agent 會套用到全部請求，包含 WebSocket 握手。 | 額外 Header 只用於主頁面，User-Agent 用於全部請求 | 19 | 主線指示保留（Astra 第 10 條）；提示，不算 GroupBox 說明句 |
| 畫面（提示，放框內最下方） | 暱稱隱藏與牌面高亮已改由**插件**提供（工具列拼圖圖示 → 插件頁面）…… | 暱稱隱藏與牌面高亮改由插件提供 | 15 | 主線指示保留（Astra 第 10 條）；提示，不算 GroupBox 說明句 |

雲端推論那句是資料外送聲明。定稿保留「啟用後」「上傳」與「手牌」；原文的「每個決策點」省略，「本局牌譜」已表達上傳的是整局至今的紀錄，不會讓人以為只上傳一次。

被移除的說明與去向：

| 原說明 | 去向 |
|---|---|
| 雀魂連線：header 與 User-Agent 的套用範圍 | 縮成一句提示，放在「新增 Header」下方（上表） |
| 畫面：「暱稱隱藏與牌面高亮已改由插件提供…」 | 縮成一句提示，放在畫面框內最下方（上表）；括號內的操作路徑移除 |
| 畫面：iOS 狀態列的長說明 | 移除；開關標籤「顯示狀態訊息列」已說明用途 |
| 自動操作的 `ActionDelayModel` 名稱 | 移除；是實作名稱 |

### 8.5 文案 key 影響

新 key（四語系 en／ja／ko／zh-Hans 由 WP-F 補）：

- 分頁名：一般、連線、AI、開發者。
- GroupBox 標題「雲端 API」。
- §8.4 的 10 句定稿（8 句說明加 2 句提示）。
- 「先到「開發者」按「測試連線」」。
- 下表「新 key」欄中尚不存在的 key。

沿用既有 key：「設定」（已存在，`PluginsPageView` 也在用，en 為 Settings，語意相同），用於工具列 `.help` 與 iOS 導覽列。App 選單的「設定…」由系統在地化，不需要 key。

改名清單（全部由 WP-F 執行；引用點為現況行號）：

| 舊 key | 新 key | 引用點 | 備註 |
|---|---|---|---|
| 進階設定 | 設定 | `ContentView.swift` 320、322、601；`AdvancedSettingsSheet.swift` 41、71 | 「設定」已存在，沿用翻譯。macOS 自訂標題 `HStack`（41）整段移除 |
| 之後可以在進階設定裡改，或取消固定。 | 之後可以在設定裡改，或取消固定。 | `ContentView.swift` 781（伺服器選擇畫面） | Astra 第 9 條補列 |
| 伺服器預設（清空） | 還原預設 | `AdvancedSettingsSheet.swift` 137 | 「還原預設」已存在（`MajsoulConnectionSettingsBox.swift` 40），沿用翻譯 |
| 基準延遲 | 出手延遲 | `AdvancedSettingsSheet.swift` 705、710 | 新 key |
| 啟動時不再詢問 | 不再詢問 | `AdvancedSettingsSheet.swift` 421 | 新 key |
| 自動送出：不可用 | 不能自動 | `AdvancedSettingsSheet.swift` 737 | 新 key |
| 自動送出不可用（a11y label） | 不能自動 | `AdvancedSettingsSheet.swift` 753 | 與上一列同 key，`autoplay-unavailable-note` identifier 不變 |
| 三麻提醒：本地有 Akagi 三麻（default strength，模仿天鳳人類）接手，雲端啟用時雲端優先；側欄的決策來源會如實顯示。 | 三麻提醒：本機有 Akagi 三麻（default strength，模仿天鳳人類）接手，雲端啟用時雲端優先；側欄的建議來源會如實顯示。 | `AdvancedSettingsSheet.swift` 673 | 跟隨側欄「決策來源→建議來源」（§4.1，WP-D）；只換兩個詞，強度聲明不動 |
| 雲端推論尚未生效，仍在用內建本地模型。還缺：%@ | 雲端推論尚未生效，仍在用內建本機模型。還缺：%@ | `AdvancedSettingsSheet.swift` 167 | 「本地」→「本機」，與 §4.2 一致 |
| 伺服器 %@；可用模型：%@（但開關未開，對局仍走本地模型） 與其「——可用模型欄旁的箭頭直接選」變體 | 同句「本地模型」→「本機模型」 | `AdvancedSettingsSheet.swift` 337、338 | 同上；主線指示「兩處」，grep 為三處四個 key，全列（§6 第 15 條） |
| §8.4 原文欄各段、先按「測試連線」取得模型清單 | §8.4 定稿、先到「開發者」按「測試連線」 | `AdvancedSettingsSheet.swift`、`MajsoulConnectionSettingsBox.swift` 59、64 | 新 key |

退場檢查：舊 key 在 `command/Resources/Localizable.xcstrings` 不得殘留，且 `command/` 的 Swift 內 grep 不到完整舊字串。文件與註解中的歷史敘述（例如 `ContentView.swift` 114 的註解、本文件）不在檢查範圍。

與 WP-D 的分界（§5、§4.1 用同一句）：WP-F 負責 `AdvancedSettingsSheet.swift`、`MajsoulConnectionSettingsBox.swift` 內的全部字串，加上工具列設定鈕（`ContentView.swift` 320、322、601）與伺服器選擇畫面那一句（`ContentView.swift` 781）；其餘字串歸 WP-D。上表全部由 WP-F 執行；WP-D 不碰這些 key。

### 8.6 不變條件

1. 所有設定仍只有 `SettingsStore` 一個寫入點。直接綁定或經 Actions（例如 `setAppLanguage`、`setKeepAliveInBackground`）都落在 `SettingsStore`。分頁不得持有設定值的副本。例外：Header 編輯草稿（§8.3），它放在設定根 View，只經「套用並重新載入」寫回。
2. `UIState.apply(screen: .settings)`：iOS 行為不變（開 sheet）。macOS 由 `settingsOpenRequest` 的值變化觸發 `openSettings()`（§8.2 狀態模型）。開啟請求與視窗可見是兩個語意：`/debug/ui` 的 `showAdvancedSettings` 只回報可見，在 macOS 讀實際視窗，開不出來時回 false，不得假裝開了。
   分頁不指定：iOS 每次開啟回到頂端、「開發者」折疊（§8.1）；macOS 設定視窗由系統保留，可能停在上次的分頁。不把分頁加進 `Screen`；日後若需要指定分頁，在 `UIState` 加一個 `settingsTab` 欄位，由 `parseUIRequest` 解析。
3. 沒有任何控制項失去行為：現況每個控制項都出現在 §8.1 的某一頁，accessibility identifier 全部保留（`cloud-inference-toggle`、`cloud-api-key-field`、`delete-bot-button` 等）；例外是 `settings-done-button` 在 macOS 移除（設定視窗沒有完成鈕），iOS 保留。目前沒有 UI 測試使用任何設定頁 identifier（grep `NakiUITests`、`Naki-MUITests`），所以這個移除不會讓既有測試失敗。
4. `cloudEffectiveStateRow` 在 AI 頁與開發者頁都顯示（§8.3）。
5. 切頁不丟未套用的 Header 草稿：草稿 `@State rows` 放在設定根 View，分頁 View 只拿 `Binding`，不得自行載入或覆寫（§8.3）。
6. 設定視窗的語言跟隨 App 語言：設定根 View 掛 `.appLocale()`（§8.2）。

### 8.7 明確不做

- 不改任何設定的語意、預設值或儲存位置。
- 不加新設定。
- 不改 `FullAutoSetupSheet`。
- 不改 `Screen`、`showAdvancedSettings`、`AdvancedSettingsSheet` 的名稱。
- 不自己記住上次選的分頁（YAGNI；macOS 視窗由系統保留時的行為照系統）。
- 不採用私有 selector `showSettingsWindow:`，不加 `NSApp.activate`。
- 不改 `GET /screenshot` 不帶參數時的視窗選擇。
- `POST /debug/ui` 不輪詢、不等待設定視窗出現。
- `/debug/ui` 不輸出 `settingsOpenRequest`。
- 不依賴 `.onDisappear`／`dismiss` 偵測設定視窗關閉。

### 8.8 WP-F

- 基底：從 `main` 開分支（設計定稿時 main 為 `07c3079`）。
- 順序：排在 WP-D 之後、WP-E 之前。WP-D 先把共用文案定稿，WP-F 只處理 §8.5 分界清單內的 key，兩包不碰同一批 key；WP-E 需要 iPhone 實機與舊 OS 驗收，排最後不擋 WP-F。
- 第一步（取現況基準）：在 UI 測試隔離鉤子完成前，只能跑現有測試，且要先確認它們不寫真實設定。現有 `NakiUITests`、`Naki-MUITests` 都是 `XCUIApplication().launch()` 啟動真 App，沒有設 `launchEnvironment`；被啟動的 App 不是 test host，`SettingsStore.isTestHost` 為 false，`NakiRuntime.init` 會照常讀寫 `.standard`。依據 §5 WP-0p 問題段的記載，`NakiRuntime.init` 在啟動時就對 `.standard` 讀寫，而 WP-0p 只隔離了 test host，所以現有 UI 測試會寫真實設定（尚未實跑確認）。基準因此改為「只 build 不跑」（§6 第 17 條）：

```bash
xcodebuild build-for-testing -project Naki.xcodeproj -scheme Naki -configuration Debug -destination 'platform=macOS'
xcodebuild build-for-testing -project Naki.xcodeproj -scheme Naki-M -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17'
```

- UI 測試隔離鉤子（資料安全前置，**沒有這個鉤子之前不得執行任何 UI 測試**）：
  - UI 測試以 `launchEnvironment` 傳兩個值（**提議**名稱）：`NAKI_UI_TEST_DEFAULTS_SUITE=naki.tests.ui`、`NAKI_UI_TEST_KEYCHAIN_SERVICE=org.naki.cloud-inference.uitest`。
  - `SettingsStore.standard` 在 `isTestHost` 之外，也在收到第一個值時改用該 suite。`command/`、`Naki/`、`Naki-M/` 內 grep `UserDefaults.standard`、`@AppStorage`、`UserDefaults(`、`= .standard` 的全部落點與處理：
    - `SettingsStore.swift` 84（`standard` 本身）：鉤子所在。
    - `AutoPlayModeStore.defaults`（`AutoPlayMode.swift` 150）與各 `load…`／`save…` 的預設參數：已經由 `SettingsStore.standard`，跟著切換。
    - `L10n.defaults`（`L10n.swift` 45）：初值是 `.standard`，不經 `SettingsStore.standard`，要一併切換。
    - `ContentView.swift` 240 的 `@AppStorage(SettingsStore.pinMajsoulServerKey)`：沒有指定 store，預設讀寫 `.standard`，要改為指定 `SettingsStore.standard`（或在根 View 掛 `.defaultAppStorage(SettingsStore.standard)`）。
    - `ObservedMatchSids.swift` 74：`init(defaults:)` 預設 `.standard`，要改為 `SettingsStore.standard`。
  - `CloudKeyStore.service` 收到第二個值時改用測試 service，不讀寫真實 API key。
  - 兩個鉤子只在 `#if DEBUG` 內生效，Release 忽略。
  - UI 測試只做唯讀斷言與設定頁內的輸入，不按「套用並重新載入」等會重新載入雀魂頁面的按鈕，不安裝或移除插件。WebView 的網站資料不在隔離範圍：UI 測試啟動的 App 用真實的 WebKit 資料，包含雀魂登入狀態，所以測試不得在遊戲頁面上做任何操作。
- 原始碼：
  - `command/Views/AdvancedSettingsSheet.swift`：分頁、單欄、雲端拆兩框、Header 草稿上移、視窗辨識、macOS 移除自訂標題列與完成鈕、§8.5 的設定頁字串。
  - `command/Views/MajsoulConnectionSettingsBox.swift`：草稿改 `Binding`、說明句與提示。
  - `command/Views/ContentView.swift`：macOS 齒輪改 `SettingsLink`、`.onChange(of: settingsOpenRequest)` 呼叫 `openSettings()`、macOS 移除設定 sheet、第 781 行伺服器選擇畫面字串。
  - `Naki/App/NakiApp.swift`：`Settings` scene、`.appLocale()` 與 `\.naki` 注入。
  - `command/ViewModels/UIState.swift`：`settingsOpenRequest`。
  - `command/Actions/NakiActions.swift`：`SettingsWindowAction`、`windowScreenshot` 註解。
  - `command/Services/MCP/NakiMCPDependencies.swift`、`command/App/NakiRuntime.swift`：注入 `SettingsWindowAction`。測試端另有三處建構 `NakiMCPDependencies`（`NakiTests/NakiActionLayerTests.swift`、`NakiTests/BotToolsTests.swift`、`NakiTests/MCPTestSupport.swift`），新欄位要給預設值或一併修改。
  - `command/Services/Debug/DebugServer.swift`：`DebugHTTPRequest.query`、`/debug/ui` 的可見欄位與關閉、`/screenshot?window=settings`。
  - 隔離鉤子：`command/App/SettingsStore.swift`、`command/Services/Bot/CloudKeyStore.swift`、`command/Services/L10n.swift`、`command/Services/Bridge/ObservedMatchSids.swift`，以及 `ContentView.swift` 240 的 `@AppStorage`。
  - WP-F 派工須允許改 `command/App/NakiRuntime.swift`、`command/App/SettingsStore.swift`、`command/ViewModels/UIState.swift`、`command/Services/Debug`、`command/Services/MCP`、`command/Services/Bot/CloudKeyStore.swift`、`command/Services/L10n.swift`、`command/Services/Bridge/ObservedMatchSids.swift`。
- 翻譯：`command/Resources/Localizable.xcstrings`，§8.5 新 key 的四語系；改名清單的舊 key 刪除。
- 測試：
  - `NakiTests/DebugUIStateTests.swift`：照 §8.2「契約改動」修改與新增。`PlatformDivergenceTests` 不改且須通過。
  - `NakiTests` 補隔離鉤子的單元測試：設了環境值時 `SettingsStore.standard` 與 `CloudKeyStore.service` 改用測試值。
  - `NakiUITests`（macOS，需 Debug build，App 會綁 loopback 8765，每個測試都帶隔離鉤子的 `launchEnvironment`）：
    - ⌘, 與工具列齒輪各能開出設定視窗。
    - 分頁列與標題列的 Accessibility 斷言：四個分頁按鈕存在且可選；選取後視窗標題等於分頁名。這是 HTTP 截圖截不到的部分（§8.2 視覺驗證分工）。
    - HTTP 整合：測試內以 `URLSession` 對 `127.0.0.1:8765` 送 `POST /debug/ui {"screen":"settings"}`，再以 `GET /debug/ui` 輪詢到 `showAdvancedSettings` 為 true，且 `XCUIApplication().windows` 有設定視窗；⌘W 後 `GET` 輪詢到 false；再送一次能重新開出；`settings → plugins`、`settings → none` 後設定視窗關閉；設定視窗開著時只送 `{"language":…}`，視窗仍在。
    - 視窗唯一性：⌘, 與 `POST /debug/ui {"screen":"settings"}` 各連續送兩次，設定視窗始終只有一個。
    - 語言：App 語言設成與系統不同，設定視窗開著時在一般頁切換語言，分頁名與 GroupBox 標題跟著換。
    - Header 草稿：輸入 Header → 切到其他頁 → 切回 → 輸入仍在（唯讀斷言，不按「套用並重新載入」）。
    - 雲端跨頁：開關關閉、缺 key 兩種狀態下，AI 頁與開發者頁的生效狀態列文字相同；查詢先限定在 `settings-page-*` 容器內。
  - `Naki-MUITests`（iOS 模擬器，同樣帶隔離鉤子）：「開發者」預設折疊；展開後關閉 sheet 再開，回到折疊且捲到頂端；展開後兩個 `cloud-effective-state` 以容器區分。
  - 新增 identifier（**提議**）：`settings-tab-general`、`settings-tab-connection`、`settings-tab-ai`、`settings-tab-developer`、`settings-page-general`、`settings-page-connection`、`settings-page-ai`、`settings-page-developer`、`settings-developer-disclosure`。
  - `NakiUITests`、`Naki-MUITests` 是同步目錄，在既有目錄新增測試檔不需登記 pbxproj。
- 文件：本節；`docs/ui-reference/implementation-decisions.md` 補一條「設定分頁：macOS 原生 Settings scene 實測結果」，記下設定視窗關閉後是否被保留、背景時 `openSettings()` 的結果、關閉後再開時 Header 草稿是否保留、smoke 結果。
- 驗收：
  - 共通規則的四個 build。
  - `NakiTests` 全套通過（含 `DebugUIStateTests`），跑前確認 `/game/state` 的 `pending` 為 null。
  - UI 測試前提：隔離鉤子已完成且其單元測試通過；沒有其他 Naki 實例在跑（8765 未被占用）；跑前後各量一次真實偏好檔 `~/Library/Preferences/org.39c154f25912233a.akagi.plist` 的 sha256（沿用 WP-0p 的方法），以及 `security find-generic-password -s org.naki.cloud-inference` 輸出的屬性（不加 `-g`，不讀出金鑰），兩者都必須不變，結果寫進 log；跑完確認沒有殘留的 Naki 程序。
  - UI 測試命令，兩條都要 `** TEST SUCCEEDED **`：

```bash
xcodebuild test -project Naki.xcodeproj -scheme Naki -configuration Debug \
  -destination 'platform=macOS' -only-testing:NakiUITests
xcodebuild test -project Naki.xcodeproj -scheme Naki-M -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:Naki-MUITests
```

  - Debug 端點 smoke（只在 Debug build，log 放主 repo 的 `.swfd/logs/wp-f/`）：
    1. App 在前景，`POST /debug/ui` 帶 `{"screen":"settings"}`，之後 `GET /debug/ui` 輪詢到 `showAdvancedSettings` 為 true。必要證據擇一：`NakiUITests` 的 `XCUIApplication().windows` 斷言，或 `GET /debug/ui` 的可見值。不依賴影像內容判定。
    2. 對設定視窗按 ⌘W；`GET /debug/ui` 輪詢到 false。再送一次 `{"screen":"settings"}` 能重新開出。
    3. 順序：先 `POST /debug/ui {"screen":"plugins"}` 讓主視窗開插件 sheet，再按 ⌘, 開設定（不經 `apply`，兩者並存）。此時 `GET /screenshot` 不帶參數截到插件 sheet，`?window=settings` 截到設定視窗的分頁內容。關閉設定視窗後，`?window=settings` 回錯誤。
    4. App 在背景時送 `{"screen":"settings"}`：通過標準是 `GET /debug/ui` 的值與實際視窗一致，不要求開得出來。
  - 視覺驗收：分頁內容以 `GET /screenshot?window=settings` 截圖為主；分頁列與標題列以 `NakiUITests` 的 Accessibility 斷言為準（§8.2 視覺驗證分工）。
  - MCP 層沒有開設定頁或截圖的工具（`command/Services/MCP` 內 grep 不到 `apply(screen`），所以 smoke 只走 HTTP 端點。
  - 內容歸屬：截圖人工對照演示頁截圖 `shot-tabs-general.png`、`shot-tabs-connection.png`、`shot-tabs-ai.png`、`shot-tabs-developer.png`、`shot-tabs-ios-collapsed.png`、`shot-tabs-ios-expanded.png`。它們在主 repo 的 `.swfd/logs/ui-demo/`，不隨 git 進 worktree；演示頁是 sheet 版，只驗各頁有哪些 GroupBox。
  - 說明句字數：在 worktree 根目錄執行下列命令，輸出不得有 `OVER`。腳本在主 repo，不隨 git 進 worktree。

```bash
bash /Users/suoie/Documents/tools/coremltools/Naki/.swfd/logs/settings-tabs/sentence-length.sh "$PWD"
```

- 清理與強化：都不可略過。新增了分頁選取、iOS 折疊、程式化開關設定視窗、隔離鉤子與草稿上移等分支。
