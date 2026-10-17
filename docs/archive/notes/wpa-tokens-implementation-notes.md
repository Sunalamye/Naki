# WP-A token 收斂 implementation notes

基底 main cc5eed2，分支 `wp-a-tokens`，未 commit。log 與圖在主 repo `Naki/.swfd/logs/wp-a/`（下稱 `LOG/`）。

用戶 2026-10-13 接受全部 28 張視覺變化，baseline 由主線重錄。

## 已修改

`command/Views/ContentView.swift` 的 `PanelLayout` 新增單一定義點：

- `Spacing.s2 s4 s6 s8 s10 s12 s16 s20`；字面 0 保留不換（緊貼，不是檔位）。
- `Radius.badge 4／control 6／row 8／card 10`。
- `Opacity.subtle 0.10／tint 0.16／neutral 0.25／stroke 0.45／textDim 0.8`。
- 狀態色 `danger／warning／success／info／neutral`（`.neutral = .secondary`）。

逐檔替換（變動行數＝git diff 刪除行）：

| 檔 | 變動行 |
|---|---|
| DecisionSidebar | 79 |
| PluginsPageView | 39 |
| ContentView（不含新增 token） | 37 |
| StatusBanners | 32 |
| AdvancedSettingsSheet | 28 |
| LogPanel | 13 |
| MajsoulConnectionSettingsBox | 3 |

換算只用設計文件 §3.1／§3.2／§3.4 的規則，值有變的項目：

- spacing／padding：1→2、3→4、5→6、7→8、9→10、14→16、18→20；成對值照 §3.1 列表，摘要條維持 10:6。
- cornerRadius：3→4（LogPanel）、5→4（ScoreRow）、7→8（OptionRow）；其餘 4／6／8／10 不變。
- opacity：0.08／0.09／0.1／0.12→0.10；0.15／0.18／0.2→0.16；0.22→0.25；0.55／0.7→0.45；0.9 與 `Color.secondary.opacity(0.7)`→0.8。
- 顏色：`.red/.orange/.green/.blue` 對應 danger／warning／success／info；`.gray` 5 處（DecisionSidebar 狀態點、available 底色、ProbabilityBar 底軌；ContentView、AdvancedSettingsSheet 的 debug server 點）→ neutral（`.secondary`，色值變）。全專案沒有 `.yellow`。
- 與狀態成對的 `.secondary`（DecisionSidebar available、AdvancedSettingsSheet supportsAutoPlay、ContentView cloud 色、PluginsPageView outbound）改 `PanelLayout.neutral`，色值不變。其餘 `.secondary` 不動。
- 按鈕 `.tint` 沿用 danger／success，表示破壞性／建設性動作（MCP 停止、刪除 Bot），不是狀態語意。
- WebSocket 膠囊 `ConnectionIndicator` 的 `.padding(.top, 3)` 不換成 4，保留 3 並以註解標為實測對齊值（補償 toolbar 擺放偏高），清理閘明列排除。
- `Spacer(minLength:)` 的 4／8／12 也換成 token。

清理：`Spacing` 註解刪掉換算歷史，只留規則；其餘 diff 逐處核對，狀態色皆與原色同色對應，語意未變。

沒改：`command/Models/`、測試、翻譯、`TileImage.swift` 整檔、`LogPanel.categoryColor`、`.ultraThinMaterial`。

## 已驗證

| 項目 | 結果 | 證據 |
|---|---|---|
| 清理閘 4 項（spacing／padding、cornerRadius、opacity、裸狀態色） | 0 hit；四種反例（縮排的 `.padding(7)`、`.foregroundStyle(.red)`、`cornerRadius: 5`、`.opacity(0.5)`）各自 FAIL，還原後 shasum 一致 | `LOG/gate.sh`、`LOG/gate-fix.log` |
| macOS Debug／Release | BUILD SUCCEEDED | `LOG/build-macos-debug.log`、`build-macos-release.log` |
| iOS Debug／Release（`Naki-M`） | BUILD SUCCEEDED | `LOG/build-ios-debug.log`、`build-ios-release.log` |
| 全套 NakiTests | 1010 tests、28 failures，28 個全是 UISnapshotTests，其餘 0 | `LOG/test-full.log` |
| 真實偏好檔 | 只有 `NSWindow Frame` 那個 key 不同 | `LOG/plist-diff.log`、`plist-before.xml`、`plist-after.xml` |
| 測試前 `/game/state` | `inGame:false`、`pending:null` | `LOG/state-before.txt` |
| 測試後程序 | 只剩用戶的 `/Applications/Naki.app`（pid 61826，跑前同） | `LOG/pgrep-before.txt`、`pgrep-after.txt` |
| baseline 28 張 | 重錄後以 `git checkout` 還原，shasum 與跑前一致 | `LOG/baseline-sha-before.txt`、`baseline-sha-after.txt` |

### UISnapshotTests 28 張（整個 class，`LOG/test-snapshot.log`、`LOG/snapshot-diffs.txt`）

比對是「任一通道不同即算差異」，所以 28 張全部超過 1.5%。最後一欄是前後圖逐像素最大通道差：差 >16 的像素才算肉眼可見（`LOG/pixel-delta.txt`，工具 pxd 在 scratchpad）。

| 圖 | 模式 | diff 像素 | 占比 | ≤1.5% | 通道差 >16 占比 |
|---|---|---|---|---|---|
| PageLoadFailureBanner_760x70 | light | 150956／212800 | 70.94% | no | 0.00% |
| PageLoadFailureBanner_760x70 | dark | 149430／212800 | 70.22% | no | 0.00% |
| BotFailureBanner_760x70 | light | 116290／212800 | 54.65% | no | 0.00% |
| BotFailureBanner_760x70 | dark | 115773／212800 | 54.40% | no | 0.00% |
| JSInjectionFailureBanner_760x70 | light | 7585／212800 | 3.56% | no | 1.68% |
| JSInjectionFailureBanner_760x70 | dark | 7563／212800 | 3.55% | no | 1.60% |
| LiqiParseFailureBanner_760x70 | light | 7446／212800 | 3.50% | no | 1.80% |
| LiqiParseFailureBanner_760x70 | dark | 7362／212800 | 3.46% | no | 1.71% |
| DecisionAlerts_cloud-degraded_348x56 | light | 33767／77952 | 43.32% | no | 4.18% |
| DecisionAlerts_cloud-degraded_348x56 | dark | 33795／77952 | 43.35% | no | 4.22% |
| DecisionAlerts_stall_348x56 | light | 51538／77952 | 66.12% | no | 9.04% |
| DecisionAlerts_stall_348x56 | dark | 51538／77952 | 66.12% | no | 9.19% |
| DecisionAlerts_sanma_348x56 | light | 33442／77952 | 42.90% | no | 6.56% |
| DecisionAlerts_sanma_348x56 | dark | 33439／77952 | 42.90% | no | 6.60% |
| DecisionCard_discard_348x120 | light | 147737／167040 | 88.44% | no | 14.75% |
| DecisionCard_discard_348x120 | dark | 148599／167040 | 88.96% | no | 14.80% |
| DecisionCard_chi-detail_348x120 | light | 138352／167040 | 82.83% | no | 10.97% |
| DecisionCard_chi-detail_348x120 | dark | 138321／167040 | 82.81% | no | 11.05% |
| DecisionCard_compact_200x80 | light | 54074／64000 | 84.49% | no | 6.19% |
| DecisionCard_compact_200x80 | dark | 54589／64000 | 85.30% | no | 6.19% |
| DecisionSidebar_regular_380x600 | light | 219827／912000 | 24.10% | no | 11.30% |
| DecisionSidebar_regular_380x600 | dark | 221294／912000 | 24.26% | no | 11.45% |
| DecisionSidebar_compact_220x560 | light | 102867／492800 | 20.87% | no | 11.14% |
| DecisionSidebar_compact_220x560 | dark | 103582／492800 | 21.02% | no | 11.31% |
| OptionList_regular_348x160 | light | 17434／222720 | 7.83% | no | 7.02% |
| OptionList_regular_348x160 | dark | 17905／222720 | 8.04% | no | 7.24% |
| OptionList_compact_200x90 | light | 7059／72000 | 9.80% | no | 8.93% |
| OptionList_compact_200x90 | dark | 7383／72000 | 10.25% | no | 9.27% |

完整原始數字見 `LOG/snapshot-diffs.txt`、`LOG/pixel-delta.txt`。

判讀：
- PageLoadFailureBanner、BotFailureBanner：通道差 >4 的像素是 0，只有 orange／red 底色 0.15→0.16 的 1 色階位移，肉眼不可見。
- JSInjectionFailureBanner、LiqiParseFailureBanner：全部差異都來自第三行說明 0.9→0.8（見下表），可見度低。
- DecisionCard、DecisionAlerts、DecisionSidebar、OptionList 有版面位移（padding 14→16、9→10、7→8 等）與 0.45／0.7 外框變化，屬設計文件預期的畫面改動。
- 前後圖：`LOG/before/`（原 baseline）、`LOG/after/`（本包渲染），供用戶確認。baseline 目錄未改。

### 須用戶確認的四個換算（逐處 pixel 數，用「只把該處還原原值」重錄後與 after 比對；`LOG/site/`、`site-022-DS237.txt`、`site-rest.txt`）

| 值 | 處 | 影響 |
|---|---|---|
| 0.22→0.25 | DecisionSidebar 摘要條外框 | Sidebar 4 張各 0.39–0.46%，通道差都 ≤4（肉眼不可見） |
| 0.22→0.25、0.55→0.45 | ContentView 設定選項卡外框 | 快照未覆蓋，pixel 未量（未驗證） |
| 0.7→0.45 | DecisionCard 動作框（DecisionSidebar 外框） | DecisionCard 6 張（含 dark）0.31–0.62%、Sidebar 4 張 0.06–0.08%，通道差 >16 的占 0.05–0.54% |
| 0.7→0.8 | RecommendationsDisabledView 文字 | 沒有快照渲染此 View，所以還原也是 0 差；未驗證 |
| 0.9→0.8 | StatusBanners 兩條第三行說明 | JSInjection 3.55%、LiqiParse 3.46%，其中通道差 >16 約 1.6–1.8%；這兩張的全部差異都來自此處 |

另量到：ProbabilityBar 底軌 `.gray`→`.secondary`（neutral）讓 DecisionCard 與 OptionList 等共 12 張多出 0.3–4.7% 差異，通道差多在 ≤4，淺色模式有 >4 的像素。

## 未驗證

- ContentView 的 ServerPicker 選項卡、PluginsPageView、AdvancedSettingsSheet、LogPanel、MajsoulConnectionSettingsBox 沒有快照，畫面差異只靠換算規則推定，未人工對照。
- compact 成對值只有 macOS 渲染的 DecisionSidebar compact 快照，iOS 實機未看。
- UpdateAvailableBanner（0.15→0.16）、StatusBar（0.2→0.16、0.1）、RecommendationsDisabledView 與 EmptyRecommendationView（0.7→0.8）沒有快照渲染，畫面差異未驗證。
- WebSocket 膠囊對齊（`.padding(.top, 3)`）live 未看。
- Release 與 Debug 渲染是否一致未驗。

## 已知風險

- baseline 28 張在本分支一定會紅，直到用戶確認後由主線重錄。重錄要整個 class 跑（單條有 ±1 色階雜訊）。
- `.gray`→`.secondary` 讓狀態點與底軌色值改變，設計文件把 neutral 定為 `.secondary`，派工又要求 `.gray`→neutral，兩者以派工為準。
- 動作色與狀態色重疊、槓／危險同為紅，屬設計文件「本輪不解」。

- WebSocket 膠囊 `.padding(.top, 3)` 是實測對齊值，未收斂到 4；WP-E 實機驗收後決定是否換成 token。

## Deviations

1. 清理閘允許字面 0（`spacing: 0`、`Spacer(minLength: 0)`、`: 0` 三元分支）。原因：0 是「緊貼」不是檔位，換成 token 只會增加噪音。
2. 閘排除 `TileImage.swift` 整檔，而非只排除三行。原因：本包不得改該檔，其 Preview 與 `Color.secondary.opacity(0.45)` 描邊同屬牌面，沒有字面數字可以放行的細粒度。
3. `Spacer(minLength:)` 與 `spacing: compact ? a : b` 的三元式納入收斂與閘，派工清單沒列，但屬同類 spacing，留著字面值會讓閘失去意義。
4. iOS build 用 `generic/platform=iOS` 加 `CODE_SIGNING_ALLOWED=NO`，不是 WP-0p 的 Simulator destination。兩者都通過編譯，沒有各跑一遍。理由（推測，未確認）：本包只驗編譯，不需要啟動模擬器，generic 不依賴已安裝的 Simulator runtime 與簽署身分。
5. 圖改以「錄製到 baseline 目錄再搬走並 `git checkout` 還原」處理，測試不支援改輸出路徑。baseline 在錄製期間短暫被覆寫，已用 shasum 核對還原。
6. 額外量了 `.gray`→`.secondary` 的 pixel 影響，派工只要求四個須確認值。理由：這是本包唯一一組色值改變的換算，用戶確認視覺變化時需要知道它的影響範圍。
7. 清理閘明列排除標有「實測對齊值」的一行（WebSocket 膠囊 `.padding(.top, 3)`），做法同 TileImage。原因：3 是實測補償 toolbar 擺放偏高的值，換成 4 會移動對齊；由統帥裁決保留，WP-E 實機驗收後決定。
