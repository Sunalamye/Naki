# Naki 畫面設計參考（ui-design）

日期：2026-10-13。基底：`15cea92`（分支 `wp-ui-design`）。

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

新文案與既有 key 的撞名檢查見 `.swfd/logs/ui-design/copy-collision-check.log`：「已連線」「還原預設」已存在且語意相同，可直接共用；「關閉」語意不同，已排除。其餘新文案都是新 key。
多對一合併（「顯示/隱藏日誌」與「顯示或隱藏日誌」合成「紀錄」）要逐語系人工確認翻譯，不能只看 `state`。

實作注意：`Localizable.xcstrings` 的 key 就是繁中原文。改文案等於改 key，必須同時搬移 en／ja／ko／zh-Hans 四份翻譯；`accessibilityIdentifier` 不受影響，但以字串查元素的 UI 測試會受影響。

### 4.1 名稱（按鈕、開關、標籤、分頁）

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
| 進階設定 | 伺服器預設（清空） | 還原預設 | — |
| 進階設定 | 啟用雲端推論 | 不改 | Toggle 標籤，按「描述 ≤20 字」判定，符合 |
| 進階設定 GroupBox | 雲端推論 | 不改 | 與上一列 Toggle 保持同一用詞 |
| 進階設定 | 基準延遲 | 出手延遲 | 「基準」是實作語 |
| 進階設定 | 視窗在背景時保持遊戲運作 | 不改 | **統帥代決**：背景保活的 live 效果未驗證，「背景連線」是更強的承諾 |
| 進階設定 | 顯示狀態訊息列 | 不改 | Toggle 標籤，按「描述 ≤20 字」判定，符合 |
| 進階設定 | 啟動時不再詢問 | 不再詢問 | — |
| 區服選擇 | 以後都用這個伺服器，不要再問 | 記住伺服器 | — |
| 進階設定 | 自動送出：不可用 | 不能自動 | GroupBox 內標題；外層 GroupBox 是「自動打牌」，語意由它補足 |
| 進階設定 | 重建 Bot／刪除 Bot／Bot 管理 | 不改 | **已裁決**：保留。「Bot」貫穿全 App 與 MCP 工具名 |
| 工具列 | MCP Server 運行中／MCP Server 已停止 | 不改 | **已裁決**：保留 |
| 更新橫幅 | 關閉提示 | 不改 | 既有 key「關閉」是模式 Off（en `Off`），「關閉提示」是 `Dismiss`，合併會翻錯一邊；`AppLanguageTests` 鎖定「關閉」 |
| 插件頁 | 抓取中… | 預覽中… | 與「預覽」同一個按鈕的進行中狀態，兩者一起改 |
| 不變 | 即時決策、最佳選擇、其他選項、運行中、待機、未在對局、重新載入、插件、進階設定、前往下載、略過此版本、自動檢查更新、金鑰狀態、移除插件？、進入遊戲、選擇雀魂伺服器、寶牌指示牌、推薦顯示已關閉、雲端狀態、已設定・未使用 | — | 已符合原則 |

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
| 進階設定伺服器說明 | 換伺服器會**整頁重新載入**，等於登出重來——各服的帳號不互通。對局中不要換。 | 換服要重新登入，對局中別換 |
| 進階設定 Bot 說明 | Bot 會在遊戲開始時自動創建，通常不需要手動管理。 | 開局時自動建立，通常不必管 |

橫幅的 summary 第二行（等寬字的技術摘要）不改：那是回報 bug 時要貼的內容。
`JSInjectionFailureBanner` 的新標題**已裁決**為「App 元件載入失敗」；「JavaScript」只留在第二行摘要。

---

## 5. 工作包拆分建議

### 共通規則

- 執行順序（已裁決）：WP-0p → WP-0 → WP-A → WP-B → WP-C → WP-D → WP-E。

- 驗收前提：`rendered/*.png` 是 HTML 原型的渲染，不是 App 截圖，不套 App 的 1.5% 門檻。本機沒有 ImageMagick（`which compare magick` 皆 not found）。
- Build 閘：每個改 Swift 的包都要跑四個 build，全部 `BUILD SUCCEEDED`。新增用到 `#if DEBUG` stub 的 `#Preview` 必須自己包 `#if DEBUG`。

```bash
xcodebuild build -project Naki.xcodeproj -scheme Naki -configuration Debug
xcodebuild build -project Naki.xcodeproj -scheme Naki -configuration Release
xcodebuild build -project Naki.xcodeproj -scheme Naki-M -configuration Debug -destination 'generic/platform=iOS Simulator'
xcodebuild build -project Naki.xcodeproj -scheme Naki-M -configuration Release -destination 'generic/platform=iOS Simulator'
```

- 新增或改動的使用者可見字串，由該包自己補 en／ja／ko／zh-Hans 翻譯，不等 WP-D。

### WP-0p：測試不寫真實偏好設定（WP-0 的前置，**已裁決：開**）

- 問題：test host 一啟動，`NakiApp` 的 `NakiRuntime.init` 就呼叫 `adoptStoredAutoPlayMode`，在任何 `setUp` 之前對 `.standard` 寫入（`CLAUDE.md`「專案結構的坑」）。隔離 suite 與確認 `pending` 為 null 都擋不住它。
- 範圍：需要改 `command/App/`，超出 UI 包的可改邊界；用戶已同意另立此包，已派出（worktree `Naki-wt-wp0p`，派工檔 `.swfd/logs/wp-0p/dispatch.md`）。
- 原始碼：`command/App/NakiRuntime.swift` 的 `init`（test host 分支）。只有證明單改 `init` 不夠時，才動 `command/App/SettingsStore.swift` 的 `standard` 與 `command/Services/Bot/AutoPlayMode.swift` 的 `AutoPlayModeStore.defaults`；後者屬 Services 層，UI 包不得改，只有 WP-0p 依其派工檔的條件可改。
- 測試：`SettingsStoreTests.swift`、`ObservedMatchSidsTests.swift`（直接提到 `UserDefaults.standard` 的兩檔）；新增一個 characterization test，改動前失敗、改動後通過。
- 文件：`CLAUDE.md`「專案結構的坑」中「基底即有，尚未處理」那句改成現況。
- 驗收：先確認 `/game/state` 的 `pending` 為 null；測試前後量真實偏好檔 `~/Library/Preferences/org.39c154f25912233a.akagi.plist` 的 sha256，必須相同；測試結束後 `pgrep` 只剩用戶原本的 Naki；全套 0 failures（基準 1003）；macOS Debug／Release 與 iOS Debug build 通過。
- 清理與強化：不可略過強化（characterization test 必須先紅後綠）。不得自動刪除已累積的 `naki.tests.*` 空殼 plist。
- 在 WP-0p 完成前，WP-0 不得執行。

### WP-0：元件快照 baseline 與比對工具

- 範圍：在 `NakiTests` 用 `ImageRenderer` 渲染固定 fixture 的 `DecisionSidebar`、`DecisionCard`、`OptionList`、五種橫幅，輸出 PNG 到 `docs/ui-reference/app-baseline/`。
- 固定條件：尺寸、scale、OS 版本、語系 zh-Hant、淺色與深色各一份、fixture 內容都寫進測試，baseline 檔名帶這些條件。
- 渲染完整性先驗：Apple 文件說明 `ImageRenderer` 不渲染部分原生控制項與容器，而橫幅含 `.bordered` 按鈕。第一步逐張人工確認畫面完整，畫不出來的元件不納入 pixel diff。
- 比對契約，分開測：
  1. 差異計數：改 1 個像素，計數必須等於 1。
  2. 門檻：差異占比剛好 1.5% 通過，超過 1.5% 失敗。
  3. 尺寸不同失敗。
  4. baseline 不存在或讀圖失敗時失敗，不得當成通過。
- 不覆蓋的區域：插件頁、`LogPanel`、工具列、設定頁、iOS 版面。這些區域不因 WP-0 通過而視為通過，各包改到時用人工截圖對照，並在報告列為「未經 pixel diff」。
- 風險：fixture 要建構 `NakiEnvironment` 裡的物件。單測釋放 MainActor 隔離的 class 會 SIGABRT；目前只有 `GameStore`、`NativeBotController` 補了 `nonisolated deinit`。設定物件走隔離 suite（`SettingsStore(defaults:)`、`L10n.defaults`、`AutoPlayModeStore.defaults`）。
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
- 測試：新增 UI 測試檔放 `NakiUITests`。它在 pbxproj 是 `PBXFileSystemSynchronizedRootGroup`，不必登記 target 成員。翻譯：無新字串。「取消」「移除「%@」」「會刪掉 %@ 的整個插件目錄。可重新匯入或放檔案救回。」都是既有 key，四語系齊備（`.swfd/logs/ui-design/copy-collision-check.log`）。文件：無。
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

- 範圍：§4 全表（裁決已併入表內）。
- 原始碼：`Localizable.xcstrings`、`DecisionSidebar.swift`、`StatusBanners.swift`、`ContentView.swift`（工具列、`ConnectionIndicator`、`ServerPickerView`）、`AdvancedSettingsSheet.swift`、`PluginsPageView.swift`、`LogPanel.swift`。測試：`AppLanguageTests` 與以字串查元素的 UI 測試。
- 驗收：
  - 不用 `plutil -lint`：它對 `.xcstrings` 回報 `Unexpected character { at line 1` 並 exit 1，但檔案是合法 JSON。
  - 改用 JSON 解析，檢查 `sourceLanguage` 為 zh-Hant、每個 key 有 en／ja／ko／zh-Hans 四語系、各語系的插值占位符數量與種類和 key 一致。
  - 舊 key 不得殘留（grep 為空）；多對一合併逐語系人工確認；最後以共通規則的四個 build 驗證。
- 清理與強化：不可略過清理（舊 key 殘留會變成永遠不顯示的翻譯）。

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

## 7. 審查修訂（2026-10-13）

Astra 審查 13 條全部採納。逐條回應見 `.swfd/logs/ui-design/astra-response.md`。

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

主線獨立復驗的 8 項必修與 3 項建議全部處理（證據 `.swfd/logs/ui-design/verify-*.log`）：

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
