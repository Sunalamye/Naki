# App 更新提醒 — implementation notes

日期：2026-10-01。基準：`0f9a86e`（v2.13.0 之後）。

## 目標

Naki 在 GitHub Releases 發行（macOS dmg／zip 未簽、iOS ipa 側載），App 內沒有任何「有新版」的提示，使用者要自己去 release 頁看。加一層**只檢查、不安裝**的提醒。

## 參考（2026-10-01 檢索）

| 層級 | 代表 | 做法 |
|---|---|---|
| ① 只檢查＋導向下載 | RISCfuture/GitHubUpdateChecker、MacNewFileApp PR #4 | 打 Releases API 比 tag；每日／每週節流；提示＋開 release 頁 |
| ② 檢查＋下載＋原地替換 | mxcl/AppUpdater、Im-Fran/openupdater、shinkuan/Akagi v3 | 下載後驗簽（attestation／Ed25519／minisign）再換掉 app、重啟 |
| ③ 完整框架 | Sparkle | appcast XML＋EdDSA 簽更新包；24h 背景查；第二次啟動才問 |

Akagi v3（同血脈、同樣 GitHub 發行、同樣未簽）走 ②：啟動時查＋Settings → Updates 手動查，一鍵下載套用重啟，唯讀安裝退回開 release 頁。
iOS 側載圈（Feather）靠 AltStore source JSON＋`releases/latest/download/X.ipa`，App 本身只能提示。

**裁決：走 ①。** macOS 包未簽，原地替換在沒有簽章驗證下等於引入供應鏈風險；iOS 又只能提示。有 Developer ID 後再升級到 ②。不引第三方套件（GitHubUpdateChecker 只支援 macOS），自己寫。

## 設計

- **來源**：`GET https://api.github.com/repos/Sunalamye/Naki/releases/latest`，匿名、不帶識別、`timeoutInterval` 10s、只收 `tag_name`／`html_url`／`draft`／`prerelease`。失敗只 log，不上 UI（手動檢查例外）。
- **比對**：`tag_name` 去掉前綴 `v` 後與 `NakiAppVersion.short` 用 `.numeric` 比較；draft／prerelease 忽略。
- **自動檢查**：主視窗出現後延遲 5 秒；`autoCheckUpdate`（預設開）關則不查；距 `lastUpdateCheck` 不足 24h 不查。**成功取得回應才寫** `lastUpdateCheck`（離線啟動不消耗 24h 視窗）。
- **手動檢查**：設定頁「立即檢查」＋ macOS App 選單「檢查更新…」；略過節流與 `skippedUpdateVersion`；結果顯示在按鈕旁（已是最新／有新版本 X／檢查失敗），不彈窗。
- **提示**：非 modal 的一列（與 `PageLoadFailureBanner` 同位置、同風格）：「有新版本 X」＋「前往下載」（開 `html_url`）＋「略過此版本」（寫 `skippedUpdateVersion`）＋「×」（只隱藏本次）。
- **持久化**（`UserDefaults`，key 住 `SettingsStore`）：`naki.autoCheckUpdate: Bool`、`naki.lastUpdateCheck: Date`、`naki.skippedUpdateVersion: String`。
- **不做**：自動下載／替換／重啟、強制更新、changelog 內嵌、對局中彈窗。

## 工作包

| 包 | 範圍 | 等級 |
|---|---|---|
| U1 | `UpdateChecker`（Services）、`GameStore.availableUpdate`、`SettingsStore` 三個 key、`NakiActions.checkForUpdate`、`NakiRuntime` 啟動排程、Banner、設定頁、macOS 選單、五語字串、單元測試 | Sonnet medium |
| 閘 | macOS Debug＋iOS Simulator build、`NakiTests`、live 啟動一次真的打 API | 主線 |
| 復驗 | 離線測試重跑、節流／略過／比對邊界、五語截圖、選單項存在 | Opus medium |

## 統帥代決

- 不送 codex 審查：約 150 行、流程圖已由使用者逐段確認。
- macOS 選單項文字跟隨系統語言（`.commands` 不吃 `\.locale`，l10n notes 已列為後續）。

## Deviations

- 不另做 `skipUpdate()`／`dismissUpdateBanner()` 的 runtime 方法與 Action：純狀態寫入、無副作用（比照 `showStatusBar` 直接寫 settings），橫幅直接寫 `settings.skippedUpdateVersion`／`store.availableUpdate = nil`。
- 啟動排程放在 `ContentView` 的 `.task(id: showsServerPicker)`（區服選擇器消失後才計 5 秒），不用 runtime flag；重進視圖由 24h 節流擋。
- 手動檢查除了 `updateCheckResult`，也寫 `store.statusMessage`（已是最新／檢查失敗），讓 App 選單入口（沒有設定頁）有回饋；有新版走橫幅。
- 手動檢查拿到 draft／prerelease（nil）視為「已是最新」。
- 抽出純函式 `shouldAutoCheck`／`shouldSurface` 供測試；測試用自寫最小 `URLProtocol` mock（private），不複用 `CloudMockURLProtocol`，避免共用 static 與平行測試互相干擾。
- 成功與節流略過各 log 一行 `[Update] …`：live 驗證只能靠 `/logs` 證明有跑，沒有這兩行無法區分「沒跑」與「被節流」。
- **閘踩雷**：`defaults` CLI 對這個 bundle id 解析到 stale container，`defaults delete` 看似成功但 app 讀的是 `~/Library/Preferences/org.39c154f25912233a.akagi.plist`；第一輪 live 其實已成功並寫了 `lastUpdateCheck`，之後每次啟動都被 24h 節流擋住而誤判「沒跑」。閘改用完整 plist 路徑。另：live 前必須 `pkill` 舊實例並等 8765 釋放，`osascript quit` 對 Debug build 不生效；舊實例佔 port 時 `/logs` 讀到的是它的，且同帳號兩實例互踢。

## 驗證

| 閘 | 結果 |
|---|---|
| macOS Debug／iOS Simulator build | 成功 |
| NakiTests | 734 tests，0 failures（新增 9 條 `UpdateCheckerTests`） |
| catalog | 新增 10 條 key，四語齊全；pbxproj 兩處 membership |
| live 正常版（2.13.0） | `/logs`：`[Update] 最新 2.13.0，目前 2.13.0`；`lastUpdateCheck` 已寫；無橫幅 |
| live `MARKETING_VERSION=2.0.0` | `/logs`：`[Update] 最新 2.13.0，目前 2.0.0`；橫幅出現（藍底「有新版本 2.13.0」＋前往下載／略過此版本／×） |
| live 略過 2.13.0／自動檢查關 | 略過：有查、無橫幅；關閉：`[Update] 略過自動檢查` |
| 獨立復驗（Opus） | 閘 ALL PASS；用 `/js` 導到無效 host 觸發既有 `PageLoadFailureBanner`，證實「橫幅浮在側欄標頭上」是四個橫幅共有的既存問題（`HSplitView` 不吃 `safeAreaInset`）；App 選單「檢查更新…」存在、手動檢查不受 24h 節流、狀態列顯示「已是最新版本」；譯文四語齊全無異體字；`.numeric` 實跑 `2.9.0<2.13.0`、`3.0>2.13.0` |

復驗後修正（統帥代決）：macOS 橫幅改排在左欄 `VStack` 內、牌桌上方（連帶修好既有四個橫幅的疊字）；× 鈕無障礙名稱改用新 key「關閉提示」（原「關閉」是開關語意，VoiceOver 會念 Off）；`Task.sleep` 被取消時不再立刻查；「自動檢查更新」ja／ko／zh-Hans 去掉源文沒有的「啟動時」。
未修：`isNewer("2.13.0", than: "2.13")` 判新版（tag 一向三段式）；runtime 的「失敗不寫 lastUpdateCheck」只有程式碼可證、無單元測試。
未驗證：iOS 畫面（只有 build）、非繁中語系下的實際 UI 字串、設定頁「立即檢查」鈕的點擊（與選單同一條路徑）。
