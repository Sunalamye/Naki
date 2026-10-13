# ADR：Naki 畫面設計參考的審查裁決（2026-10-13）

設計文件：`docs/plan/ui-design-reference.md`（設計者 Opus 5.5 high，基底 15cea92）。
審查者：Astra（codex `gpt-6-astra`，唯讀 sandbox）。原文 `.swfd/logs/ui-design/astra-review.md`，回應 `.swfd/logs/ui-design/astra-response.md`。

## 數字

| 項目 | 數 |
|---|---|
| 審查條目 | 13（擋 5、應修 7、建議 1） |
| 採納 | 13 |
| 反駁 | 0 |
| 主線推翻的反駁 | 0 |

反駁率 0%，未觸發「反駁過半需重讀」規則。

## 主線裁決

全部採納成立。要點與 why：

- **第 1 條（擋，資料完整性）**：test host 啟動即寫真實 UserDefaults，依規則不得以 over-guard 反駁。設計者改為前置包 WP-0p，但 WP-0p 要改 `command/App/`，超出 UI 包邊界，由用戶裁決是否開包。在它完成前 WP-0 不得執行。
- **第 2 條（擋）**：原地確認從 `Bool` 改回綁定插件 ID 的 `pendingRemoval`，逾時用 `.task(id:)`。why：單一 Bool 在切換插件時會把確認套到另一個目標，這是正確性問題，不是防護過度。
- **第 5、6 條**：審查者實際執行過 `plutil -lint` 與翻譯撞名比對，證據確鑿。「關閉提示」不改，避免與模式 Off 的翻譯合併。
- **第 11 條**：`.snappy(extraBounce: 0)` 仍有 Apple 定義的少量回彈，與不變條件 3「回報狀態不回彈」衝突；全文改 `.smooth`。
- **第 9、10 條**：reduce motion 分支統一為直接切換；`LogPanel` 與 `HSplitView` 兩條既有例外分列，WP-B 修正不以找到崩潰紀錄為前提，也不宣稱修崩潰。

## 用戶裁決（2026-10-13，計畫定案）

| # | 事項 | 裁決 |
|---|---|---|
| 1 | 開 WP-0p（改 `command/App/` 讓測試不寫真實偏好設定） | **開**。接受整份計畫，順序 WP-0p → 0 → A → B → C → D → E |
| 2 | 「本機 Core ML」→「本機」 | 改 |
| 3 | 插件頁「信任」→「權限」 | 改 |
| 4 | 「刪除 Bot」加原地確認 | 不加。why：Bot 下一局自動重建，不是不可逆 |
| 5 | 「Bot」「MCP Server」系列名稱 | 保留。why：貫穿 MCP 工具名，改一處要改全部 |
| 6 | JavaScript 注入失敗橫幅標題 | 改「App 元件載入失敗」，「JavaScript」留在第二行技術摘要 |
| 7 | 槓的動作色 | 改 `.indigo`。why：紅同時代表槓與危險是已知遺留；WP-E 連動原型與三張 `rendered/` 基準 |

## 流程紀錄

設計者結案四次（初稿、審查修訂、復驗修訂、最後小修），未重派。spike 兩檔未因審查改動；四個 build（macOS／iOS × Debug／Release）通過，log 在 `.swfd/logs/ui-design/`。

## 獨立復驗裁決（2026-10-13，Opus 5.5 medium 復驗）

復驗報告列 8 項必修、5 項建議。主線裁決：8 項必修全部成立並已修正；建議採納 3 項（引用檢查腳本改 bash 並排除自身、WP-B 點名切換處、§3.5 補引用 `NakiWebViewHost.swift` 原則），其餘記錄。證據 `.swfd/logs/ui-design/verify-*.log`。

要點與 why：
- **semantic color 併入 WP-A**：狀態色在 View 裸寫 44 處、無定義點，違反引導詞 semantic color；收進 `PanelLayout` 維持單一定義點。動作色與狀態色重疊、indigo／purple 區分度列已知風險，本輪不解。
- **新增 §3.6 動畫時長 token**：`.smooth(duration: 0.4)` 在 §2.1 與 `PanelLayout.valueChange` 形成第二個定義點，違反 deep modules。
- **reduce motion 第二分支點**：`ContentView` iOS 面板的 `.transition(reduceMotion ? .opacity : …)` 在入口回 nil 時 `.opacity` 永不播放，是死分支；列既有例外，WP-B 移除。
- **統帥代決：「視窗在背景時保持遊戲運作」不改**。why：背景保活 live 效果未驗證（`CLAUDE.md`），「背景連線」是更強的承諾。
- **統帥代決：§3.1 窄版換算採「最近值、等距取大」**，與主線原指示「往下一格」不同。why：設計者指出「往下一格」會把 `padding(compact ? 10 : 16)` 的窄版推到 12，iOS 220pt 欄更窄；最近值規則保住窄版現況。
- **新發現**：`PlatformDivergenceTests.testVersionCheckExistsExactlyOnce` 掃描整個 `command/`，斷言 `#available` 只有 `WebSession.swift` 一處。WP-E 的玻璃分歧必須同包放寬這條測試（允許清單明列），並改 `CLAUDE.md` 的「唯一 `#available`」一句。這是放寬既有守門測試，WP-E 報告必須標明。

## 流程（設計包）

實作（設計者 Opus 5.5 high）完成；清理、強化略過（2 個 Swift 檔、無新邏輯分支、其餘為文件）；獨立復驗（Opus 5.5 medium）完成一次，必修修正後重點復核一次。設計者結案四次（初稿、審查修訂、復驗修訂、最後小修），未重派。
