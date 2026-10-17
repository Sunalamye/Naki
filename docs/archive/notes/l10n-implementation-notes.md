# 多國語系 — implementation notes

日期：2026-10-01。基準：`477f102`（v2.12.0）。

## 目標

源語言繁中（zh-Hant），加 zh-Hans、en、ja、ko。範圍：使用者看得到的全部（設定頁、側欄、橫幅、狀態列、插件頁、確認對話、停滯／Bot 錯誤／續局訊息）。log、MCP 工具描述、解析錯誤的診斷文字維持繁中。

## 設計

- **String Catalog**：`command/Resources/Localizable.xcstrings`，key 直接用現有繁中字串，SwiftUI `Text("…")` 不必改；帶插值的字串 key 為格式字串（`%lld`／`%@`）。
- **切換方式**：macOS App 內選單（`SettingsStore.appLanguage`，根部 `.environment(\.locale)` 即時切換）；iOS 不做選單，跟隨系統（使用者在 iOS 設定 → Naki → 語言切換）。
- **Services 訊息**：不經 `Text` 的字串（statusMessage、橫幅、停滯提示）走 `L10n` helper（`String(localized:locale:)` 讀目前語言）。
- **持久化的 rawValue 不動**：`AutoPlayMode` 的 `關閉／推薦／自動／全自動` 存在 UserDefaults，另加 `displayName`。
- **翻譯產出**：三個抽取包各產出 JSON 中介檔（key → 四語），主線合併進 xcstrings，避免多人同時改一個檔。
- **翻譯品質**：由模型翻譯，標「未經母語校對」。

## 工作包

| 包 | 範圍 | 等級 |
|---|---|---|
| L0 基礎建設 | 專案設定、xcstrings、SettingsStore、根部 locale、L10n helper、macOS 選單、AutoPlayMode.displayName | Sonnet medium |
| L1 | `ContentView.swift` | Sonnet low |
| L2 | `DecisionSidebar.swift`、`LogPanel.swift`、其他 Views、App 層 | Sonnet low |
| L3 | Services 進 UI 的訊息（coordinator、WebSession、AutoPlayEngine 停滯、AutoRematch、Plugin 匯入／更新、NakiRuntime） | Sonnet low |
| 合併＋閘 | 合併 JSON → xcstrings、build、tests、`-AppleLanguages` 截圖 | 主線 |
| 復驗 | 逐語言截圖核對、未翻譯 key 掃描、rawValue 未變、iOS 設定可見語言 | Opus medium |

## 風險

- `.environment(\.locale)` 是否在 runtime 切換 `Text` 本地化（而非只影響格式）：L0 要驗，不行就改 Bundle 覆寫。
- 格式字串 key 與程式碼插值型別不一致 → 顯示原 key。復驗要掃「顯示出 key」的情況。
- 原始碼 lint 測試（`PlatformDivergenceTests` 等）grep 原始碼，改寫可能誤觸。
- 新增 Swift 檔必須加進 `project.pbxproj` 的 membershipExceptions（包含清單制）。

## codex 審查裁決（2026-10-01，統帥代決）

採納：`String` 型別顯示值一律改 `LocalizedStringKey`／`Text` 插值（`pickerLabel`、`regionName`、`autoUnavailableReason`、`String(format:)` 秒數）；同字不同語境用語意 key（catalog 寫明 zh-Hant 值）；Picker 以繁中字數算寬度的寫法移除；中介 JSON 帶 `source`／`context`，同 key 不同譯文視為合併錯誤；驗收矩陣＝五語 × 四畫面截圖、無裸 key、`rawValue` 未變、iOS 設定出現語言清單、開著 sheet 切語言、切回跟隨系統。
已知限制（不處理）：已存入 `statusMessage` 的歷史訊息不隨切換重算。
後續（本次不做）：Dynamic Type、CJK 字體、Accessibility、`error.localizedDescription`、母語校對、`.commands` 選單的 locale。

## Deviations

- **L0**：`String(localized:locale:)` 的 locale 實測只影響格式、不挑語言 → helper 改用 `LocalizedStringResource(key, locale:)`；全專案禁用裸 `String(localized:)`。
- **L0**：Scene 的 `body` 不隨設定重算 → `.environment(\.locale)` 掛在 View 層（`.appLocale()`），不在 `WindowGroup`。
- **L0**：`AutoPlayMode.displayName` 回 `LocalizedStringKey` 而非 `String`，理由同上（String 版只吃系統語言）。
- **切換方式（使用者決定）**：macOS App 內選單；iOS 不做選單、跟隨系統設定。
- **pbxproj 踩雷**：`membershipExceptions` 列了尚不存在的檔會被並行的 xcodebuild 剔除，要先建檔再改 pbxproj。
- **L1**：狀態列圖示改成只看四個故障來源（botFailure／pageLoadFailure／JS 注入失敗／解析阻斷），不再比對訊息文字；原本的綠色「成功」勾勾因此取消（訊息不帶類型，沒有可靠來源）。`Text("a" + "b")` 會變 verbatim，多行文案改成多行字面值。
- **L3**：顯示名採「保留 String（MCP／測試）＋新增 `…Key`（UI）」，不改既有簽名；`AutoRematchEngine.fail` 的 log 固定繁中、`onFailure` 走使用者語言；`AutoPlayEngine` 走 `.log` sink 又進狀態列的診斷行（觸發／略過…）維持繁中（統帥代決：屬診斷文字）；插件巢狀細節在建立時本地化，切語言後既有 descriptor 不重算。
- **復驗 5 修正**：macOS 的 sheet 是獨立 NSWindow，`\.locale` 會被改回行程語言 → 每個 `.sheet` 內容根（設定、插件、全自動確認表、iOS Log）各自掛 `.appLocale()`；`.confirmationDialog` 在這些 sheet 內，一併跟著。
- **autosave key 事件**：`.appLocale()` 一度掛在 Scene 根 View 上，且 `AppLocale` 是 `private struct`，型別名（含記憶體位址）成為視窗 autosave key → 視窗 frame 每次啟動重置、plist 每次多一條 `NSWindow Frame …` 垃圾 key（復驗時累積 43 條）。改為 `ContentView.body` 內部掛載，root 型別名回到原本的 `ContentView, _EnvironmentKeyWritingModifier<NakiEnvironment>`；已存在的垃圾 key 不自動清除，交使用者決定。
- **維持繁中的狀態列訊息**：`NakiRuntime.logAutoPlayEvent`（自動打牌事件）與 `NakiMCPDependencies.log`（MCP 診斷）直接寫 `statusMessage`，屬診斷文字，維持繁中；已存入 `statusMessage` 的訊息不隨語言切換重算。
- **合併裁決**：跨包同 key 譯文衝突 9 條，統一採用：區服名 "CN Server／JP Server／International Server"、「吃」"Chi"、「關」韓文 끔、「可用／不可用」日文 利用可能／利用不可、「MCP Server 已停止」日文 を停止しました。日文「發」保留舊字形（麻雀牌名慣例）。

## 驗證

| 閘 | 結果 |
|---|---|
| catalog | 375 條 key，四語齊全，格式符一致；異體字機械檢查（ICU 簡繁互轉＋日文新舊字體表）唯一例外為 ja 品牌名「雀魂麻將」保留原字 |
| NakiTests | 726 tests，0 failures（2026-10-01 快照，當時的數字；現況見 `CLAUDE.md`） |
| macOS Debug／iOS Simulator build | 成功；bundle 內 en／ja／ko／zh-Hans 四個 `.lproj` |
| Live（`-AppleLanguages` 啟動） | 五語主畫面截圖；ja 側欄與狀態列確認已翻 |
| 獨立復驗（Opus，兩輪） | verify.sh 全閘通過；五語 × 7 畫面截圖無裸 key、無爆版；App 內切換：工具列／側欄／狀態列／各 sheet／確認框即時更新，切回跟隨系統即時；視窗記憶修正後重啟兩次 key 數不變；iOS 模擬器「設定 → Naki-M → 語言」列出五種、系統切 ja 跟著變；用詞與異體字抽查修正後通過 |

未驗證：iOS 實機（只有模擬器）、pageLoadFailure／botFailure 橫幅各語（觸發不了）、翻譯未經母語校對。
已知殘留：`WebSession.swift:199` 載入訊息插的是區服原始 displayName（簡中下顯示「將」）；AppLocale 曾為 private 期間在使用者偏好設定留下約 37 條帶位址的 `NSWindow Frame` key，是否清除由使用者決定。
