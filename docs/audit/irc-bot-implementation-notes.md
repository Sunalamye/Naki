# IRC Bot 層實作筆記

- 分支 irc-bot，基準 main 7c2fe26（未 commit）。審查來源：`.swfd/logs/irc/audit-bot.md`（BT-01 起）。
- log 在主 repo `.swfd/logs/irc-bot/`：`baseline-build.log`、`baseline-test.log`、`fail-before.log`、`after-bugfix-test.log`、`after-refactor-test.log`、`final-build-clean.log`、`final-ios-build.log`。
- 所有 live 行為皆**未驗證**（無測試帳號、未啟動 App、未送封包）。

## 狀態一覽

| 編號 | 狀態 | 行為是否改變 | 測試 |
|---|---|---|---|
| BT-01 | 已修 | 是 | `testFailedPassIsNotMistakenForASentAction`、`testSuccessfulPassClearsStall` |
| BT-02 | 已修 | 是 | `testFailedPassBacksOffAcrossCyclesAndFlagsOffline` |
| BT-03 | 已修（查證成立） | 是 | `RyukyokuActionIndexTests`（2 條） |
| BT-04 | 已修 | 是 | `testSkippedTicksDuringRecoveryDoNotConsumeBudget` |
| BT-05／06／07 | 未做，列給用戶決策 | — | — |
| BT-08 | 已重構（只命名／註記） | 否 | 既有測試全綠 |
| BT-09 | 已重構（註解） | 否 | — |
| BT-10 | 部分：只補註解，未改結構（見 Deviations） | 否 | 既有 `testHoraBacksOffOnlyWhenOffline` 鎖住 |
| BT-11 | 已重構 | 否 | `AutoPlayGateTests`、`GameFlowRequestTests`、`ToolbarControlsRealTests`（改斷言型別） |
| BT-12 | 部分：只修註解（見 Deviations） | 否 | — |
| BT-13 | 部分：改註解，未刪 `state = .idle`（見 Deviations） | 否 | — |
| BT-14／15／16／21／22 | 已重構（註解） | 否 | — |
| BT-17 | 已重構 | 否 | 既有去抖測試 |
| BT-18 | 已重構 | 否（正式路徑兩個時鐘同為系統時間） | `testCallPassGraceFollowsInjectedClockWhenNowIsOmitted` |
| BT-19 | 已重構 | 否 | 既有 runManualCycle／AkagiSanmaBot 測試 |
| BT-20 | 未做，改歸需要決策（見 Deviations） | — | — |
| BT-23 | 已重構 | 否 | — |
| BT-24 | 已重構 | 否（除極窄競態） | `AutoRematchEngineTests` |
| BT-25 | 未做，改歸需要決策（見 Deviations） | — | — |
| BT-26～33 | 不做（可改可不改） | — | — |

## Bug 修正

fail-before：新增 6 條測試先在未修改的程式碼上跑，`fail-before.log` 顯示 6 條全紅（22 個斷言失敗）；修正後 `after-bugfix-test.log` 為 1034 tests、0 failures（基線 1028 + 6）。

### BT-01 `finish` 把「過」失敗當成送出成功
- 之前：`.passed(_, handled: false)` 走 `reason = nil`，每拍清掉停滯。
- 之後：`.passed(let n, false)` 的 reason 為 `passFailed:n`，只有 `.sent` 與 `.passed(_, true)` 回 nil。停滯 reason 顯示 `passFailed:2` 這類碼。
- fail-before 證據：停滯回呼從未收到非 nil（`reported` 為空）。

### BT-02 「過」失敗不退避
- 之前：`sendPass` 的 `.failed` 不呼叫 `deferRetry`。
- 之後：引擎在傳給 `AutoPassDispatcher.send` 的 `send` closure 裡記下最後一次 `LiqiSendResult.isOffline`，失敗時 `deferRetry(sequence, offline:)`。退避形狀沿用既有 `failureBackoff`／`failureBackoffCap`／`isOffline`，沒有新造機制，也沒有改 `AutoPassDispatcher` 的簽名。
- 測試涵蓋斷線與非斷線兩種失敗：第二拍 `.notSent("backoff")`，到期才再試一輪；斷線時停滯第一拍就帶 `no_open_majsoul_connection`。
- 已知限制：斷線時本輪仍會跑完 dispatcher 的 5 次重試（間隔 0.2 秒），之後才退避。deliver 路徑則是斷線立刻停手。要做到「立刻停手」得改 dispatcher，審查建議沒有要求，保守不做。**行為是否符合 CLAUDE.md「非和牌動作立刻停手」的字面：本輪不符，跨輪符合**，列給用戶決定要不要補。

### BT-03 mask 44（九種九牌）
- 查證（MortalSwift da7238c，`Package.resolved` 釘住；checkout 在 DerivedData `Naki-bihsnstwskegdfampwvohopuzeyp/SourcePackages/checkouts/MortalSwift`，`git rev-parse` 為 da7238c）：
  - `State/PlayerState.swift:451`：`ryukyoku = 44`。
  - `State/ObsEncoder.swift:370-372`：`canRyukyoku` 時 `mask[44] = 1`（非加槓選擇階段）。
  - `State/ActionDecoder.swift:147`：44 解成 `.ryukyoku`。
  - `State/StateUpdate.swift:613,890`：`canDeclareRyukyoku()` 為第一巡且九種以上幺九牌。
  - 結論：審查成立。
- 修正：`MortalActionMapper.actionIndexToRecommendation` 加 `case AI.ryukyoku`，回 `tile: "ryukyoku"`、`actionType: .ryukyoku`。resolver（`snapshot.contains(.kyushu)`）與 executor（`.ryukyoku` → `kyushu()`）本來就支援，未動。未動 Bridge 檔。
- fail-before 證據：mapper 回 nil；resolver 在 `[44, 0]` 的推薦下裁決為 `send(discard, "1m")`，即模型選九種九牌卻送出打牌。
- 未驗證：`BundledCoreMLBot.rankedRecommendations` 為 private，沒有端到端 mask 測試；live 需四麻九種九牌局面。
- 順帶：`legalCount`（forced 判斷）本來就數 mask 內所有 1，包含 44，此修正不影響它。

### BT-04 recovery 預算在閘門之前被消耗
- 之前：預算遞增與「recovery 重送」event 在 `allowsConfirm` 之前。
- 之後：先過閘門，skip 直接回 `.skipped`；通過後才遞增預算與寫 event。`confirmAckedAt = nil`、`confirmInRecovery = true` 的狀態轉換仍在閘門之前（它們是狀態，不是預算）。
- 測試切到 `.recommend` 跑 5 拍：全 `.skipped(.notAutoMode)`、`confirmPending` 保持、無「recovery 重送」event，切回 `.auto` 後預算完整並送出。

## 建議改的處置

- **BT-08**：新增 `Timing.callPassWindowMargin`（1.0）與 `Timing.debounceSlack`（0.5）取代內嵌的 `- 1` 與 `+ 0.5`；`ActionDelayModel.tankBase`（2.0）取代內嵌的 `2.0`。值不變。理由未知者在宣告處註「理由未知」：failureBackoff 與 cap、retry、passRetry、passAttempts、horaRetry、callPassWindowMargin、debounceSlack、confirmMaxWatchdogResends、AutoPassDispatcher 5×0.2、AutoConfirmDispatcher 6×0.4、AutoRematch 45 秒／3 秒×20／10 秒×3、`ActionDelayModel.maximum` 12 秒、`tankBase`。沒有編造理由。
- **BT-09**：`horaRetry` 與 `maxAttempts` 兩處過期註解已改。「15 次＝1.5 秒」改寫為「每次嘗試還要等 RESPONSE 與回音，最長佔用時間遠大於次數乘 retry」，未給精確秒數（避免推測當事實）。
- **BT-11**：`AutoPlayGate.allowsConfirm` 回 `Reason?`；引擎的 switch 與兩個不可能的 case 刪除。順手讓 BT-04 的重排更直接。
- **BT-12**：只改 `AutoPlayStall.reason` 註解。
- **BT-13**：`stop()` 保留 `state = .idle`，註解改為「`occupy(...)` 與 `stop()` 能改」。
- **BT-14／15／16／21／22**：依審查建議改寫過期註解；BT-16 的 ActionDelayModel 註解寫明九種九牌借用 claim 分布是「沒有實測資料時的近似」。
- **BT-17**：`Debounce` 註解寫出仍擋的情境（`wake()` 在同一批推薦內提早叫醒）。「仍擋」是從原始碼推得，**推測，未以實驗證明**。
- **BT-18**：`runCycle(now: Date? = nil)`，`nil` 時取 `timing.clock()`。
- **BT-19**：`runManualCycle` 與 `AkagiSanmaBot.react` 各讀一次 pending 後只用區域值。
- **BT-23**：`NativeBotController.placeholderScores` 常數化，三處共用。
- **BT-24**：`AutoRematchEngine.run` 在 settle 之後取一次 `context()`，模式檢查與目標決策共用；重試迴圈內的模式檢查仍每次重取。

## 需要決策／未做

- BT-05、BT-06、BT-07：照主線裁決，不改，維持審查原文。
- BT-25（改歸需要決策）：審查自己標「行為會變」——帶換行的 key／URL 會被存成不同的值。依「建議改若會改變行為就停手」規則不做。補丁：五處 `.whitespaces` 改 `.whitespacesAndNewlines`，加 `CloudInferenceConfig(apiKey: "abc\n")` 與 `AkagiApiClient.normalize` 單測。
- BT-20（改歸需要決策，推測）：審查稱「無可觀察差異」，但我找到一條理論路徑：三麻、`bot.react` 回 nil 時 `eventOplistSeq != lastRecommendationsOplistSequence` 會把 `lastDecisionSource` 重設成 `.local`。若結束類事件（hora／ryukyoku／end_kyoku／end_game）帶的 oplist 序號恰好等於上一次推薦的 provenance，現行不重設、清掉 provenance 後會重設。結束類事件是否帶序號、值是多少**未查證**，所以無法證明無差異，不做。

## Deviations

1. **BT-10 只補註解**：審查建議把退避判斷移到 switch 之前，但 `AutoPlayGate.Decision` 的 switch 必須窮舉 `.skip`，搬出去後要留一個不可能到達的 `.skip` case（或 `preconditionFailure`），反而更難讀。保守選擇：保留 case 順序，加註解寫明「退避擋和牌，不擋 skip」。「退避期間和牌也被擋」已由既有 `testHoraBacksOffOnlyWhenOffline`（斷線情形）鎖住。
2. **BT-12 只修註解**：offline 字面值要抽成 `LiqiSendResult` 的 static 常數，會動 `LiqiActionSender.swift`（Bridge）與 `DecisionSidebar.swift`（Views），都不在本包可改範圍。字面值仍是兩份（`LiqiActionSender.swift:52` 與 `AutoPlayEngine.updateStall`）。
3. **BT-13 保留 `state = .idle`**：`testLoopDrivesACycleWithoutAnyTimer` 在 `engine.stop()` 後立刻斷言 `state == .idle`，而取消不是同步完成；刪掉會引入競態。審查給的備案（改註解）已採用。
4. **replay-check.sh 未執行**：它要求執行中的 Naki App 提供 loopback MCP（8765），而本包禁止啟動 App。替代證據：`ReplayFingerprintTests`（NakiTests 內，用同一段指紋 python 對版控內的一局錄影重放，與 baseline 比對）在基線與最終都通過。這只涵蓋 1 局、四麻、且該局不含九種九牌局面，所以**不能證明** BT-03 在含九種九牌的局面下的決策差異；`~/Library/Logs/Naki` 另有 7 局錄影未重放。
5. **iOS 警告無基線**：`Naki-M` Simulator build 綠，13 個警告，其中 0 個來自 `Services/Bot`；未在基線樹上跑 iOS build，所以無法比較總數。
6. **主線接受 BT-10、BT-12、BT-13 為部分完成**：復驗裁決認定三項的保守偏離理由可查證，不要求補完。

## 驗證摘要

| 項目 | 基線 | 最終 | 證據 |
|---|---|---|---|
| macOS build 警告（clean build，去重） | 6 | 6 | `.swfd/logs/irc-bot/verify/build-macos-clean.log` |
| NakiTests | 1028 tests，0 failures | 1036 tests，0 failures | `.swfd/logs/irc-bot/verify/test-full.log` |
| iOS `Naki-M` Simulator build | — | BUILD SUCCEEDED | `final-ios-build.log` |

## 清理

範圍：本包已改動的檔案，不改行為。

**做了**
- `confirmMaxWatchdogResends`：行尾註解「3 的理由未知」改成上方 doc 註解，與 `Timing` 其他常數的標註位置一致。純註解，無程式碼變動。

**檢查後不動**
- BT-02 的 `lastSendOffline`：與既有 `deferRetry` 路徑不重複。主送出路徑直接持有 `result`，用 `result?.isOffline`；「過」路徑經 `AutoPassDispatcher.send`，dispatcher 只回 `AutoPassOutcome`，看不到 `LiqiSendResult`，所以必須在 send closure 記下。要消掉這個 var，得讓 `AutoPassOutcome.failed` 帶 offline 旗標，會改 enum 與其測試，超出清理範圍。
- 複雜度：`runPassCycle` 的 `occupy` closure 內為 closure → switch → case，巢狀 3 層，未超限。`runConfirmCycle` 的閘門前移後，原本的 `switch` 少一層（`.proceed/.forceHora/.sendPass` 不可能分支已刪），巢狀降低。沒有新增函數需要拆分。
- BT-08 常數：`callPassWindowMargin`（秒，視窗長度減此值＝寬限期上限）、`debounceSlack`（秒，加在擬人延遲之後）、`tankBase`（秒，長考固定加項）名稱與單位皆明確，三者「理由未知」標註齊全。同值不同義未被合併：`tankBase` 2.0 與 `deadlineMargin` 2.0、`debounceSlack` 0.5 與 `passRetry` 0.5 各自獨立。
- 依賴規則：本包未新增 import 或跨層引用；`PlatformDivergenceTests` 與其他 lint 測試在 1035 個測試內全綠。

**驗收**（`.swfd/logs/irc-bot/`）

| 項目 | 結果 | 證據 |
|---|---|---|
| macOS clean build | BUILD SUCCEEDED，警告去重 6，基線去重 6 | `cleanup-build.log` |
| NakiTests | 1035 tests，0 failures | `cleanup-test.log` |
| `git grep -n "/Users/" NakiTests` | 0 命中 | 指令輸出 |

## 強化（變異測試）

工具：手工 harness `mutate.py`（由介面層版本複製，加 SIGTERM／SIGINT 還原；未用 muter）。只對 `git diff -U0 -- command` 新增行產生關係運算子、邏輯連接詞、三元互換變異。log 與 jsonl 在主 repo `.swfd/logs/irc-bot/mutation/`。

| 檔案 | 總數 | 殺死 | 存活 | 等價 |
|---|---|---|---|---|
| AutoPlayEngine.swift | 5 | 5（含補測後 1） | 0 | 0 |
| AutoPlayGate.swift | 1 | 1 | 0 | 0 |
| AutoRematchEngine.swift | 1 | 1 | 0 | 0 |
| 合計 | 7 | 7 | 0（初跑 1） | 0 |

- 初跑存活：`AutoPlayEngine.swift:663` 的 `!self.confirmPending || Task.isCancelled` 改成 `&&`。補測 `AutoConfirmEngineTests.testRoundBeginningDuringSendIsSupersededWithoutCancellation`（送出途中 `roundDidBegin`、未取消，須回 `.superseded`），重跑後被殺（`rerun.log`）。
- 限制：harness 的模式只匹配「兩側有空白的運算子」與 ` ? : `，本包 143 條新增行僅產生 7 個變異；其餘新增行（字串、常數、函式呼叫、`guard`／`return` 結構變更）未被變異，屬未驗證範圍。
- 全量 NakiTests：1036 tests、0 failures（`full-test.log`）。
- 復驗補強：harness 未變異到 `lastSendOffline` 與 BT-18 的時鐘來源。復驗手工補的兩個變體皆被殺（`.swfd/logs/irc-bot/verify/revert-bt02-offline.log`、`revert-bt18.log`）。

## 已知未驗證

- BT-03 第 3 層回音（九種九牌送出後等權威動作廣播）依賴 `end_kyoku` 事件，屬推測，未驗證。
- 四麻九種九牌缺 live 驗證。
