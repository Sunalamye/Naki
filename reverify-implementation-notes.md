# 全程式碼復驗與變異測試 — implementation notes

日期：2026-10-08。基準：`4e92764`（v2.14.0，工作樹乾淨）。前一輪：`code-audit-implementation-notes.md`（基準 `48add0a`）。

## 目標

1. **補做變異測試**：2026-09-30 審查修正、l10n、更新提醒三個系列（`48add0a..4e92764`）新增或修改的邏輯分支，當時只做了 10 個手工 mutation；本輪依使用者的變異測試規則逐檔補做，存活變異體在改動內的補測試。
2. **全程式碼重新審查與設計確認**：`command/` 78 個 Swift 檔（26,439 行）與內建 JS 三檔。審查重點：設計是否成立（責任邊界、單一來源、fail-closed）、是否符合專案 CLAUDE.md 的 clear code 原則（不過度拆分、無多餘註解、精簡）、重複模式。審出的必修項各成工作包，走五步流程（實作／清理／強化＝變異測試／獨立復驗／裁決）。

## 工具決策（統帥代決）

- 專案是 Swift／Xcode，使用者規則寫的 `cargo-mutants` 不適用。對應工具選 **muter 16**（`brew tap muter-mutation-testing/formulae`，已 trust、已裝）。
- muter 只有 4 個運算子（關係運算子替換、移除副作用、邏輯連接詞替換、三元交換），比 cargo-mutants 弱；沒有「布林反轉」「回傳值替換」。**規則對應**：
  - `--in-diff` → 只對 `git diff 48add0a..HEAD` 碰到的檔案跑，且只計入改動行所在函數內的變異體；其餘變異體列清單不處理。
  - `--file` 分批 → `--files-to-mutate <檔案>`，每批前景 ≤10 分鐘。
  - `mutants.out/outcomes.json` → muter `--format json --output .swfd/logs/mutation/<檔>.json`。
  - 「逾時／未編譯」 → muter 的 build error／timeout 分類；若 muter 不分這兩類，報告寫「muter 不區分，未驗證」。
- muter 會整個目錄複製到 `muter_tmp`，主 repo 有未追蹤的 `build*/`、`dist/`、mp4，所以 **只在乾淨 worktree 跑**。worktree 放 `/Users/suoie/Documents/tools/coremltools/Naki-wt/<包名>`（不放 `/tmp`：三條架構 lint 測試在 symlink 路徑假紅）。

## 基準

| 項目 | 值 | 證據 |
|---|---|---|
| NakiTests | 734 tests，0 failures，約 60 秒（含增量建置；測試本體 28 秒） | `.swfd/logs/baseline/nakitests-baseline.log` |
| 工作樹 | `Localizable.xcstrings` 原本有一份 Xcode 自動抽取的未提交改動（新增 15 個 key、7 個標 stale），已存成 diff 並還原 | `.swfd/logs/baseline/xcstrings-autoextract.diff` |
| 磁碟 | 99 GiB 可用；預算：同時編譯 worktree ≤2、可用 ≥30 GiB | 專案記憶 `naki-resource-budget` |
| live App | `/Applications/Naki.app` 在跑（pid 1619），`inGame=false` | `curl 127.0.0.1:8765/game/state` |

`xcstrings-autoextract.diff` 本身是一個發現：`Log`、`MCP Server`、`WebSocket`、`正在初始化...`、`revision：%@`、`%@ · v%@` 等 key 有 `Text()` 用到但 catalog 沒有（未翻譯）。列入審查工作包 R-UI。

## 工作包

| 包 | 內容 | 路由 | 狀態 |
|---|---|---|---|
| M0 spike | muter 設定、對 `UpdateChecker.swift`＋`AutoPlayGate.swift` 跑一次、量每個變異體耗時、寫 `scripts/mutation-run.sh` 包裝（輸入檔案清單、輸出使用者要的報告欄位） | Sonnet medium | 進行中 |
| codex 審查 | 審本計畫與 M0 結果（唯讀） | codex | 待 M0 |
| M1–Mn | 依 48add0a..HEAD 的邏輯檔分批變異測試（約 48 個非 View 檔，依模組分包） | Sonnet medium | 待 codex |
| R1–R5 | 五條流程設計審查（分包見下） | Opus medium | 待 codex |

審查分包（唯讀，各約 5–7 千行）：

| 包 | 檔案 |
|---|---|
| R1 入站協定 | `Bridge/Liqi*`（Parser 1434、Envelope、Encoder、RequestBuilder、OperationStore、ResponseStore、Tile、ParseFault）、`MajsoulBridge`（1100）、`WebSocketInterceptor`、`ObservedMatch*`、`MatchModeTable`、`SelfActionEchoTracker`、`SerialEventIntake`、`MJAIEventStream`、`GameRecorder`、`naki-websocket.js` |
| R2 Bot 與雲端 | `Bot/`（AutoPlay* 以外）：`NativeBotController`（643）、`BundledCoreMLBot`、`CloudBot`、`CloudBreaker`、`CloudDecisionMapper`、`CloudInferenceConfig`、`CloudKeyStore`、`AkagiApiClient`、`KyokuStreamAccumulator`、`MahjongBot`、`MortalActionMapper`、`NakiWebCoordinator`、`GameModels`、`GameStore` |
| R3 自動打牌 | `AutoPlayEngine`（1059）、`AutoPlayGate`、`AutoPlayDecisionResolver`、`AutoPlayActionExecutor`、`AutoPlayMode`、`AutoPassDispatcher`、`AutoConfirmDispatcher`、`AutoRematchEngine`、`ActionDelayModel`、`LiqiActionSender`、`NakiWebSocketScript` |
| R4 WebView／插件／App／UI | `Web/`、`Plugins/`、`App/`（Runtime、Environment、SettingsStore）、`Actions/NakiActions`（1343）、`Views/`（ContentView 2665、DecisionSidebar 781、LogPanel、TileImage）、`L10n`、`UpdateChecker`、`naki-core.js`、`naki-plugins.js` |
| R5 Debug／MCP／log | `Debug/DebugServer`（813）、`MCP/`（全部）、`LogManager`、`JSONSanitizer`、`AppVersion`、`NakiTests/` 的測試設計（是否只驗 happy path、架構 lint 是否還鎖得住） |
| 修正包 | 由審查結論裁決後成立 | 依路由 | — |

## Deviations

- （尚無）

## 驗證

（M0 完成後填）
