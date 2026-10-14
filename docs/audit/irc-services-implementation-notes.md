# 服務層 Intention-Revealing Code 實作筆記

- worktree：`Naki-wt-irc-services`，分支 irc-services，基準 main `7c2fe26`；未 commit。
- 依據：`.swfd/logs/irc/audit-services.md`（SV-01～40）與主線分類裁決。
- log：`.swfd/logs/irc-services/`（`baseline-*.log`、`red-bugs.log`、`test-iter1.log`、`final-*.log`、`cleanup-*.log`）。
- 測試集中在 `NakiTests/ServicesIRCTests.swift`（19 條，含清理與復驗後修正；以 `grep -c "func test"` 為準）。

## 驗收數字

| 項目 | 基線 | 最終 |
|---|---|---|
| NakiTests | 1028、0 failures | 1047、0 failures（復驗後修正，`fixup-test-full.log`） |
| macOS build warning 去重數 | 6 | 6（內容相同，僅 appintents 時間戳不同） |
| iOS `Naki-M` Simulator build | — | 成功（warning 去重 6） |
| MCP 工具數 | 40（既有斷言） | 40（同一斷言通過） |

## 逐條

| 編號 | 狀態 | 修改前後 | 行為改變 | 測試 |
|---|---|---|---|---|
| SV-01 | 已修 | `BotSyncTool` 補 `message`（取 `statusMessage`），`ForceReconnectOutcome`（NakiActions.swift，in-flight）未動 | 是：失敗時多一個欄位 | `testBotSyncFailureOutputSatisfiesOutputSchemaRequired` |
| SV-04 | 已修 | 另計 `totalDecisions`，`truncated = totalDecisions > decisions.count` | 是：邊界值與 limit 0 | `testReplayTruncatedOnlyWhenLimitDroppedDecisions` |
| SV-05 | guard 已就緒、接線未做 | `NakiMCPOriginPolicy.isAllowed(_:boundPort:)`、`NakiMCPRequestGuard.rejection(lines:boundPort:)`；`boundPort` 預設 nil，行為與 main 相同 | 未接線時否 | `testOriginPortMustMatchBoundPort`、`testOriginWithoutHeaderAndNonLoopbackBehaviorUnchangedWhenBound`、`testOriginUnboundKeepsLegacyBehavior`、`testRequestGuardPassesBoundPortToOriginCheck` |
| SV-12 | 完成 | 兩處註解改為與 `plan` 及測試一致 | 否 | 無（註解） |
| SV-13 | 完成 | `MCPArguments.inGameAwaitMs/lobbyAwaitMs/roomAwaitMs`；描述字串插值；`room_quick_test` 的 4000／3000／4000 命名為私有常數。值不變，理由未知 | 否 | `testAwaitDefaultsKeepValuesAndDescriptionsQuoteThem` |
| SV-14 | 部分 | 只做 `DefaultNakiMCPContext.defaultServerPort`。`DebugServer.swift`、`GameStore.swift` 兩處不在範圍，仍是字面值 8765 | 否 | 編譯 |
| SV-15 | 完成 | `NakiMCPProtocol` 加 5 個 JSON-RPC 標準碼常數並引用；`MCPHandler` 的 fallback 字串插值 | 否 | `testJSONRPCStandardCodesKeepWireValues` |
| SV-16 | Bug（部分） | `LogManager.sessionKeepCount` 改 static internal，`logFileNote` 改插值並更正為「保留最近 N 次完整目錄，更舊且有錄影的只留 games/」；registry 分組註解拿掉工具數。**未做**：廣播 50 與心跳 30／86400 的擁有者在 `command/Services/Bridge/`（範圍外），描述仍是字面值 | 是：`logFileNote` 原文「保留 8 次」與 `pruneOldSessions` 實際行為不符，文字改正 | `testLogFileNoteDescribesRetentionRule`（修前紅 `fixup-red.log`、修後綠 `fixup-green.log`）、`testLogFileNoteUsesRetentionConstant` |
| SV-17 | 完成（相容式） | `LiqiToolSendOutcome` 改 `enum { unavailable(String), attempted(LiqiSendResult, response:) }`；保留 `init(sent:response:)` 與 `sent`／`response`／`unavailableReason` 計算屬性，Bot／Bridge 呼叫端與既有測試不需改。本檔 `?? "unknown"` 已移除；`AutoConfirmDispatcher.swift:111` 的 `?? "unknown"` 在範圍外，保留 | 否 | `testSendOutcomeStatesAreExclusive` ＋既有 AutoConfirm 測試 |
| SV-18 | 部分（行為改變已還原） | `bot_trigger` 判斷順序與 main 相同（先 `no_recommendation`、再 `no_oplist`）。**未做**：推薦數與 account id 改由 context 提供型別化屬性（要改 `NakiMCPContext` 協定與 `NakiActions.swift`） | 否（已還原） | 既有 `testBotTriggerPrecheckAllowsHoraWithoutRecommendation`；`testBotTriggerWithoutOplistAndRecommendationKeepsMainErrorCode` |
| SV-19 | Bug | `lobby_account_info` 的 `accountIdSource` 與 `lobby_start_unified_match` 的 `sidSource` 依實際採用的值決定 | 是：參數型別不符（如 `match_sid: 123`）時標記與實際採用的值矛盾，改正 | `testAccountInfoSourceMarkerFollowsResolvedValue`、`testStartUnifiedMatchSidSourceFollowsResolvedValue`（含 `match_sid: 123`；修前紅 `fixup-red.log`、修後綠 `fixup-green.log`） |
| SV-20 | 完成（行為改變已還原） | 抽 `RoomConfigParser.parse`，`room_create` 與 `room_quick_test` 共用；`acceptsRuleOverrides` 決定是否讀 dora_count 等規則欄位，quick test 傳 false（只吃 mode、time_fixed、time_add、ai_level）；`time_fixed` 預設 300／60 刻意不同 | 否（已還原） | `testRoomConfigParserSharesRulesAndOnlyTimeFixedDefaultDiffers`、`testRoomQuickTestRequestIgnoresRuleOverrides` |
| SV-21 | 已還原（無證據的行為改變） | `reconnect_hint` 文字與 main 逐字相同；移除只讀原始碼字串的 `testQuickTestReconnectHintPointsToBotSync` | 否（已還原） | `git diff` 中 `RoomTools.swift` 無 `reconnect_hint` 變動 |
| SV-22 | 完成 | `OperationsSnapshotPayload.current()`，`bot_ops`／`game_ops` 共用 | 否 | `testBotOpsAndGameOpsShareOneOutput` |
| SV-23 | 部分（主線收下為文件修正） | 只改 `bot_deep` 的 schema 描述（去掉「回調未設定時」）。**未做**：錯誤碼 `game_snapshot_callback_not_configured` 改名（`ToolAndModelGapTests` 釘住，屬對外字串）、`getGameSnapshot()` 改非 optional（改協定）。與錯誤碼名詞不一致併入「需要決策」 | 否 | 既有 `ToolAndModelGapTests` |
| SV-24 | 已還原（無證據的行為改變） | `WebSessionBackends.swift` 整檔回到 main：Legacy 只看 code；WebPage 的 domain＋code 判斷與 main 相同，原改動只是抽共用，無獨立價值，一併還原 | 否（已還原） | `git diff --stat` 該檔無變動；既有 `navigationFailureMessage` 測試 |
| SV-26 | 部分 | 刪恆真的 `guard`；`maxEntries` 改 `let`；`/// 系統日誌` 註解歸位。**未做**：`fileLoggingEnabled` 改 `let`——審查說無寫入，但 `LogAndVersionSingleSourceTests` 會寫它，保留 `var` | 否 | 既有 LogManager 測試 |
| SV-27 | 部分（(1) 已還原） | (1) 輪替判斷回到 main 語意 `count == sessionStampLength（"yyyyMMdd-HHmmss".count）&& contains("-")`，只具名長度；(2) `LogManager.logsRoot` 單一來源，`ReplaySupport.logsRoot` 移除（`isInsideLogsRoot` 預設引用 `LogManager.logsRoot`）。**未做**：建目錄失敗退回 temp 時以 `logDirectory` 為準 | (1) 否（已還原；`pkg-stamp.json` 列出的輸入與 main 一致）；(2) 否 | `testPruneIgnoresDirectoriesThatAreNotSessionStamps`（驗舊語意：`abcdefg-hijklmn`、`20261301-000000` 會被刪、14 字元不刪；修前紅 `fixup-red.log`、修後綠 `fixup-green.log`）、既有 `testPruneKeepsOnlyGamesOfOldSessionsWithRecordings` |
| SV-34 | 完成 | 刪 `MCPHandler.initializeResult` 轉發，測試改呼叫 `NakiMCPProtocol.initializeResult` | 否 | `testMCPServerInfoVersionMatchesAppBundle` |
| SV-36 | 完成 | 刪過時註解 | 否 | 無 |

## 不改，列給用戶

SV-07、SV-08、SV-09：未動。

## 不做（in-flight 或可改可不改）

SV-02、03、06、10、11、25、28～33、35；SV-37～40。

## Deviations

1. SV-01：`ForceReconnectOutcome` 在 in-flight 的 `NakiActions.swift`，改在 `BotSyncTool` 組裝輸出時補 `message`，而不是動 enum。
2. SV-17：選相容式 enum（保留舊 init 與計算屬性），避免動 Bot／Bridge 範圍外檔案。
3. SV-23：錯誤碼改名與 optional 改非 optional 未做，理由見上；建議改歸需要決策。
4. SV-26：審查的「無寫入者」不成立，`fileLoggingEnabled` 保留 `var`。
5. SV-16／18／14：擁有者在範圍外的部分未做，見表。
6. 本機 worktree 的 `.dd/`、`.dd-ios/` 是 DerivedData，已寫進 `.git/info/exclude`，不進版控。

## 清理

### 還原的行為改變（主線裁決）

| 項 | 還原內容 | 修前紅 | 修後綠 |
|---|---|---|---|
| SV-18 | `bot_trigger` 兩者皆缺時回 `no_recommendation`，判斷順序與 main 相同；不再提前讀 `pending` | `testBotTriggerWithoutOplistAndRecommendationKeepsMainErrorCode`：得 `no_oplist`，期望 `no_recommendation`（`cleanup-red.log`） | 同測試通過（`cleanup-green.log`） |
| SV-20 | quick test 不讀 dora_count、shiduan、init_point、fandian、public_live、enable_ai、client_version_string；送出的 createRoom payload 與 main 逐 byte 相同 | `testRoomQuickTestRequestIgnoresRuleOverrides`：payload 含額外欄位而不等於 main 組法（`cleanup-red.log`） | 同測試通過 |

- `testRoomConfigParserSharesRulesAndOnlyTimeFixedDefaultDiffers` 因參數簽章改變，無法在還原前的程式碼上編譯，紅燈 log 時暫時移出；還原後加回並通過。
- 兩項「行為改變」在程式碼裡都不保留。SV-20 的「quick test 開放規則欄位」若有價值，列為**需要決策（候選）**：要同時增列 inputSchema 欄位，屬對外介面變更。SV-18 的錯誤碼順序無候選。

### 其他清理

- `RoomConfigParser`：單一函數、巢狀最深 2 層，不再拆分。
- `room_quick_test` 的 `record()` 還原為讀 `dict["serverAccepted"]`（與 main 相同）。前一步改讀 `outcome.response` 的等價性只在「送出失敗但有 response」不存在時成立，無法證明，保守還原。
- SV-17 相容式 enum 的舊 init 與 `sent`／`response`／`unavailableReason` **保留**。全專案 grep 仍有範圍外呼叫端：`LiqiActionSender.swift`、`AutoConfirmDispatcher.swift`、`AutoPlayActionExecutor.swift`、`NakiRuntime.swift`，以及 `AutoConfirmDispatcherTests`、`AutoConfirmEngineTests`、`NakiActionLayerTests`。刪了就要動範圍外檔案。
- 沒有依賴規則違規：既有 lint 測試在 NakiTests 全綠。其餘範圍內函數未超過複雜度上限，不清理。

### 清理後驗收

| 項目 | 結果 | 證據 |
|---|---|---|
| macOS clean build | 成功，warning 去重後 6（內容同基線，僅 appintents 時間戳不同） | `cleanup-build.log` |
| NakiTests | 1045 executed、0 failures | `cleanup-green.log` |
| MCP 工具數 | 40 | `testToolDefinitionsCarryOutputSchemaAndKeepOrder` 通過 |
| `grep -rn "/Users/" NakiTests` | 0 命中 | 指令輸出 |

### Deviations（清理步驟）

1. `record()` 還原為 main 寫法，不是主線指定項；理由見上，採較保守選項。
2. 其他前一步標「行為改變」的項目（SV-01、04、19、21、27）當時主線只點名 SV-18、SV-20，故未動；復驗後裁決 SV-21、24、27(1) 已於「復驗後修正」還原，SV-16、19 改列 Bug。

## 強化（變異測試）

- 工具：`.swfd/logs/irc-bot/mutation/mutate.py` 複製為 `.swfd/logs/irc-services/mutation/mutate.py`，只改 `CLASSES`（ServicesIRCTests、MCPToolHardeningTests、LogAndVersionSingleSourceTests、MCPProtocolSpecTests、ToolAndModelGapTests、BotToolsTests、PlatformDivergenceTests、ReplayFingerprintTests、WebLayerGapTests、NakiWebCoordinatorTests、RoomModeTests）。不用 muter。
- 範圍：`git diff -U0 -- command` 的新增行；產品程式碼未動（前後 `git diff` 位元組相同）。
- log：`.swfd/logs/irc-services/mutation/`（`results.jsonl`、`rerun/results.jsonl`、`sv05.jsonl`、`run1.log`、`run2.log`、`rerun.log`、`final-full.log`）。

| 項目 | 數量 |
|---|---|
| 變異總數 | 15 |
| 首輪殺死 | 11 |
| 首輪存活 | 4 |
| 補測試後重跑殺死 | 4 |
| 最終存活 | 0 |
| 等價變異 | 0 |

### 首輪存活與補的測試

| 變異 | 原因 | 補的測試 |
|---|---|---|
| `MCPProtocolSpec.swift:364` `scheme == "https"` 改 `!=`；三元互換 443／80（2 個） | 既有測試的 Origin 都明寫 port，只有 `http://localhost` 對 8765，沒覆蓋 scheme 預設 port | `testOriginWithoutPortUsesSchemeDefault` |
| `LobbyTools.swift:137` `argumentSid == nil` 改 `!=`；三元互換（2 個） | 上一步標「未驗證」：依賴全域 `ObservedMatchSids.shared` | `testStartUnifiedMatchSidSourceFollowsResolvedValue`（用既有 `isolateSharedObservedMatchSids` 導向獨立 suite） |

### SV-05 手工變體（安全條目）

harness 對 `guard let boundPort else { return true }` 不產生變異（無運算子），手工做三個變體（`manual_sv05.py`，含 SIGTERM／SIGINT 還原；log `sv05_*.log`、`sv05.jsonl`）：

| 變體 | 結果 | 殺死它的測試 |
|---|---|---|
| A：port 比較改恆真（`== Int(boundPort) \|\| true`） | 殺死 | `testOriginPortMustMatchBoundPort`、`testOriginWithoutPortUsesSchemeDefault`、`testRequestGuardPassesBoundPortToOriginCheck` |
| B：boundPort 為 nil 的分支 `return true` 改 `return false` | 殺死 | `MCPProtocolSpecTests.testLoopbackOriginsAreAllowed`、`testOriginUnboundKeepsLegacyBehavior`、`testRequestGuardPassesBoundPortToOriginCheck` |
| C：`NakiMCPRequestGuard` 傳給 Origin 檢查的 boundPort 改 nil | 殺死 | `testRequestGuardPassesBoundPortToOriginCheck` |

### 未覆蓋（harness 不產生變異，未手工驗）

新增行中沒有關係／邏輯運算子或三元的部分：`RoomConfigParser` 的欄位預設值與 `min`／`max` 夾取、`LiqiToolSendOutcome` enum 轉接、`MCPArguments` 常數值、`LogManager.sessionKeepCount` 與 `logFileNote` 文字、`reconnect_hint` 字串、`OperationsSnapshotPayload.current()` 欄位集合、`BotSyncTool` 補 `message`。這些由字面值斷言測試守住，但未經變異驗證。

### 範圍外存活

無（harness 只變異本包 diff）。

### 驗收

| 項目 | 結果 | 證據 |
|---|---|---|
| NakiTests | 1047 executed、0 failures（新增 2 條） | `final-full.log` |
| MCP 工具數斷言 | 仍為 40 | `MCPProtocolSpecTests.testToolDefinitionsCarryOutputSchemaAndKeepOrder` 通過 |
| `grep -rn "/Users/" NakiTests` | 0 命中 | 指令輸出 |
| 前後比對 | tracked diff／stat 與強化前位元組相同；untracked 僅 `ServicesIRCTests.swift` 雜湊不同（新增 2 條測試）；`docs/audit/` 為本節新增 | `before.*`、`after.*` |

### Deviations（強化步驟）

1. 全量測試以 `-only-testing:NakiTests` 執行，數量 1047（基準 1045 加 2）。
2. 每批變異跑 8 個與 7 個，各自在 10 分鐘內前景完成；重跑存活者逐一執行。

## 復驗後修正

依復驗報告與主線裁決（`.swfd/logs/irc-services/verify/report.md`）。

| 項 | 處理 | 證據 |
|---|---|---|
| SV-27(1) | 還原為 main 語意；測試改驗舊語意 | `fixup-red.log`（目前程式碼上紅）、`fixup-green.log` |
| SV-21 | 文字還原，移除原始碼字串測試 | `git diff` |
| SV-24 | 整檔還原；內容見 `fixup-sv24-reverted.diff` | `git status` 該檔無變動 |
| SV-19 | 改列 Bug，補 `match_sid: 123` 斷言 | `fixup-red.log`（暫改回 main 寫法時紅）、`fixup-green.log` |
| SV-16 | 改列 Bug，補 `logFileNote` 文字斷言 | 同上 |
| SV-23 | 列「部分（主線收下為文件修正）」 | 本表 |

紅燈做法：SV-19 暫把 `sidSource` 改回 main 的 `arguments["match_sid"] == nil`，SV-16 暫把 `logFileNote` 改成「（保留 8 次）」近似 main 文字（非逐字，僅用來證明斷言會紅），跑完立即還原。

notes 更正三處（復驗報告未逐條列出，下列為依實況推定，推測）：新增測試數 17 改 19；驗收數字 1045 改 1047；SV-24「Legacy 多一道 domain 檢查，實務相同」改為整檔還原。

復驗指出的三處不符為：SV-27 描述不完整、SV-19 強化測試只殺變異不釘行為、清理後驗收未跑 iOS；前兩處已由復驗後修正的實質修改處理，第三處由復驗補跑。

### WP-F2 合併後待辦

- `DebugServer.swift` 的 handleRequest 內改為 `NakiMCPRequestGuard.rejection(lines: lines, boundPort: actualPort)`，並同時改 `MCPToolHardeningTests.testDebugServerCallsRequestGuardBeforeRouting` 的原始碼字串搜尋。

### 復驗後驗收

| 項目 | 結果 | 證據 |
|---|---|---|
| macOS clean build | 成功，warning 去重 5 | `fixup-build-macos.log` |
| iOS Naki-M Simulator build | 成功 | `fixup-build-ios.log` |
| NakiTests | 1047 executed、0 failures | `fixup-test-full.log` |
| MCP 工具數 | 40（同一斷言通過） | `fixup-test-full.log` |
| `grep -rn "/Users/" NakiTests` | 0 命中 | 指令輸出 |
