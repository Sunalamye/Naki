# IRC 第二輪 Bot 實作筆記

- 分支 irc2-bot，基準 main 910c51c（未 commit）。計畫：`.swfd/logs/irc2/plan.md`；原審查：`.swfd/logs/irc/audit-bot.md`（BT-02／06／07／25）。
- log 在主 repo `.swfd/logs/irc2-bot/`：`baseline-test.log`、`baseline-rerun-liqiparser.log`、`fail-before.log`、`fail-before-bt25.log`、`after-fix-targeted.log`、`final-test.log`、`final-build-clean.log`、`final-ios-build.log`。
- 所有 live 行為皆**未驗證**（無測試帳號、未啟動 App、未送封包）。

| 編號 | 狀態 | 測試 |
|---|---|---|
| BT-02 | 已修 | `testOfflineStopsRetryingImmediately`、`testFailedPassBacksOffAcrossCyclesAndFlagsOffline`（改斷言） |
| BT-06 | 已修 | `testPassRejectedByServerIsNotHandled`、`testPassAcceptedByServerIsHandled` |
| BT-07 | 已修 | `testConfirmPendingWithoutProgressReportsStall` |
| BT-25 | 已修 | `test_newlinesAreTrimmedFromKeyAndURL` |

## BT-02 斷線時「過」立刻停手

- 改法：`AutoPassDispatcher.send` 在一次失敗後若 `result.isOffline` 就跳出迴圈，回 `.failed(attempts: 1)`；`AutoPlayEngine.sendPass` 既有的 `deferRetry(offline:)` 接手。
- 修前紅：`fail-before.log`，`testOfflineStopsRetryingImmediately` 得到 `failed(attempts: 3)`、送出 3 次。修後綠：`after-fix-targeted.log`。
- 行為改變：被擠下線時，「過」每輪只送 1 次（原 5 次），第二輪起進跨輪退避，停滯立即顯示 `no_open_majsoul_connection`。其他失敗原因的重試次數不變。
- 既有測試調整：`AutoPassDispatcherTests` 兩條原用 `no_open_majsoul_connection` 當一般失敗，改用 `no_gateway`；`testFailedPassBacksOffAcrossCyclesAndFlagsOffline` 的斷線案例改斷言每輪 1 次。

## BT-06 「過」兩條路徑統一成功判準

- 改法：`sendPass` 的送出改呼叫 executor 既有的 `AutoPlayActionExecutor.sendAndVerify`（`action: .none`、`echoTimeoutMs: 0`，與 executor 的「過」同樣跳過第 3 層），成功＝同 msgId RESPONSE 且無 error。`sendAndVerify` 由 private 改 internal，未新造機制。
- 重試參數統一為 executor 那邊的 `Timing.passAttempts`（5，再與 `maxAttempts` 取小）與 `passRetry`（0.5 秒）；刪除 `Timing.passPolicy`（dispatcher 的 5 次／0.2 秒預設只剩單測直接使用）。
- 修前紅：`fail-before.log`，`testPassRejectedByServerIsNotHandled` 得到 `passed(attempts: 1, handled: true)`。修後綠：`after-fix-targeted.log`。
- 行為改變：伺服器對「過」回 error 時，oplist 不再被當成已處理，會重送；每次送出多等最長 `actionAwaitResponseMs`（800 毫秒，實測 RESPONSE 約 100 毫秒到）；失敗重試間隔 0.2 → 0.5 秒。皆只影響送出失敗或被拒的路徑，成功路徑只多等一個 RESPONSE。

## BT-07 等確認期間無進展報停滯

- 改法：進入 `confirmPending` 時記 `confirmPendingSince`；`runConfirmCycle` 開頭若已超過 `confirmAckWatchdog`（6 秒，沿用既有常數，沒有新常數）且模式會送出，就 `updateStall(reason: "confirmStalled")`。
- 修前紅：`fail-before.log`，`testConfirmPendingWithoutProgressReportsStall` 收不到停滯（nil）。修後綠：`after-fix-targeted.log`。測試用注入時鐘。
- 行為改變：漏收 `ActionNewRound`、卻已有新 oplist（`store.pending != nil`，`updateStall` 既有前提）時，約 6 秒上限加既有 4 拍門檻後，側欄顯示「自動打牌卡住 … （confirmStalled）」。沒有 pending 時不報，正常結算流程不受影響。
- 「進展」的解讀（推測）：只有 `ActionNewRound`（清 pending）算進展；confirm 受理（ack）與 watchdog 重送不重置起算點，否則 watchdog 每 6 秒重送一次會永遠不到上限。

## BT-25 key／URL 去換行

- 改法：`.whitespaces` 改 `.whitespacesAndNewlines`，在 `CloudKeyStore`（新增 `sanitized`，`save` 使用）、`CloudInferenceConfig`（`isActive`、`missingItems`、`model`、`keyLast4`）、`AkagiApiClient`（`normalize`、init 的 key、`redactingKey`）、`CloudBot`（`supports3P` 判斷，與 `model(is3P:)` 一致）。
- 修前紅：`fail-before-bt25.log`，`test_newlinesAreTrimmedFromKeyAndURL` 6 項斷言紅。修後綠：`after-fix-targeted.log`。
- 行為改變：只影響帶換行的輸入——貼上帶尾端換行的 key 現在存成不含換行的值，不再得到 401；只含換行的欄位視為空。
- 測試未呼叫真實 Keychain（service 是固定常數，會覆蓋使用者真實的 key），改測 `sanitized` 純函式。

## Deviations

- BT-25 只改 `command/Services/Bot/` 內的 `.whitespaces`。`SettingsStore.cloudServerURL` 與設定頁 `NakiActions.swift:1435`、`AdvancedSettingsSheet.swift:295` 不在本包範圍，未改；URL 的實際使用點（`normalize`）已去換行，所以不影響連線。
- `CloudBot` 與 `CloudInferenceConfig.missingItems`／`model` 不在審查列的五處，但同一欄位判斷不一致會讓 `isActive` 與其他判斷分歧，一併改。
- worktree `CLAUDE.md` 對「過」的描述（若有）未更新：不在範圍。
- 基線 `LiqiParserLearningTests.testTraceRedactsCredentialPayloadButKeepsOrdinaryStrings` 在整包基線跑時紅 1 次，單獨重跑綠（`baseline-rerun-liqiparser.log`），最終整包跑綠；推測是兩棵 worktree 同時跑測試造成的共用狀態干擾（未驗證）。

## 清理

- 範圍：僅前一步改動的檔案。未改變行為。
- BT-25 收斂：`AkagiApiClient`（init 的 key、`redactingKey`）與 `CloudInferenceConfig`（`isActive`、`missingItems`、`keyLast4`）的 key 修剪改呼叫 `CloudKeyStore.sanitized`，與 `save` 同一個 helper。URL 與 model 欄位各只有 1 到 2 處獨立判斷，不另造 helper。
- 函數結構：`sendPass` 最深 3 層（函數、`occupy` 閉包、`send` 閉包），`AutoPassDispatcher.send` 與 `runConfirmCycle` 新增段落未增加巢狀，不拆函數。
- lint：`testNoSecondDecisionPathOutsideTheEngine` 只禁 `AutoPlayActionExecutor.execute`、`AutoPassDispatcher.send` 等字串；引擎呼叫的 `sendAndVerify` 只做送出與驗收、不含閘門或 resolver，且呼叫點仍在 `AutoPlayEngine.swift`，無第二條決策路徑。
- `passPolicy` 殘留：全專案 grep 僅剩 `docs/archive/plan/design-review-2026-10-12-decisions.md:280` 的歷史紀錄（當時狀態的描述），及本檔上文；程式與測試無引用，不改歷史文件。
- 驗收：clean build 綠，去重 warning 3（算法 `grep "warning:" | sed 's/^.*warning:/warning:/' | sort -u | wc -l`，前一步 log 同算法亦為 3），證據 `cleanup-build.log`；NakiTests 1096 tests 0 failures、`ReplayFingerprintTests` 2 條綠，證據 `cleanup-test.log`；`grep -rn "/Users/" NakiTests` 0。

## 驗收

| 項目 | 結果 | 證據 |
|---|---|---|
| NakiTests | 1096 全綠（基線 1091 + 新增 5） | `final-test.log` |
| macOS clean build | 綠，3 個去重 warning，皆在未改動檔案 | `final-build-clean.log` |
| iOS Naki-M Simulator build | 綠 | `final-ios-build.log` |
| ReplayFingerprintTests | 2 條綠 | `final-test.log` |
| `grep -rn "/Users/" NakiTests` | 0 | 指令輸出 |

## 強化

- 工具：手工 harness `mutate.py`（沿用 irc-bot 版，只加 `-derivedDataPath`；未用 muter）與 `manual.py`（harness 覆蓋不到的修正點），皆在主 repo `.swfd/logs/irc2-bot/mutation/`。逐筆結果：`results.jsonl`、`manual-results.jsonl`，log 在 `logs/`。
- harness：`git diff -U0` 新增行產生 7 個變異體。首輪 6 殺、1 存活；補測試後 7 殺 0 存活。
- 存活變異體：`CloudInferenceConfig.model(is3P:)` 三元互換。原因是 `test_newlinesAreTrimmedFromKeyAndURL` 的 model4P 為 `"\n"`、model3P 為空，互換後結果相同。真缺口，非等價。
- 手工變異（9 種，最終全殺）：BT-02 拿掉斷線 break；BT-06 改回只看 sendRaw；BT-07 起算點不設定、停滯判斷拿掉、ack 時重置起算點；BT-25 四個檔案各把 `.whitespacesAndNewlines` 改回 `.whitespaces`。
- 手工首輪存活 2 項：
  - `BT25-CloudBot`：真缺口，原測試無換行-only 的 model3P。
  - `BT07-since-reset-on-ack`：我寫的變異體插入位置在 `resetConfirm` 內、與原行重複，等價，無效；改插在受理（ack）處的 `ack2` 才有效。`ack2` 首次「殺」是假的（新測試本身步數不足，未變異也紅），修測試後重跑才算數，以最後一筆為準。
- 補的測試：
  - `CloudInferenceTests.test_newlinesAreTrimmedFromKeyAndURL` 加入 4P／3P 不同值且帶換行的 `model(is3P:)` 斷言。
  - `CloudBotTests.test_identity_supports3P_followsLocalOrCloud3pModel` 加一組 model3P 為 `"\n"` 預期 false。
  - 新增 `AutoConfirmEngineTests.testConfirmAckDoesNotResetStallClock`（ack 不重置停滯起算點）。
- 未覆蓋：harness 只對 `command` 下新增行的比較／邏輯／三元運算子變異，不含常數、刪行、`.none`／`echoTimeoutMs: 0` 等參數變異（手工只做上列 9 種）；`passRetry` 0.5 秒、`retryLimit(for: .none)` 實際值未以變異驗證；`SettingsStore.cloudServerURL` 等範圍外處未驗。
- 前後比對：product 程式碼 diff 與強化前逐位元相同（`after.command.diff` 對 `before.diff` 的 command 段 `diff` 無輸出）；HEAD 仍 910c51c；未 commit、未 stash。測試檔多動 `CloudInferenceTests.swift`（擴充）、`CloudBotTests.swift`（新進入 diff）、`AutoConfirmEngineTests.swift`（加 1 條）。
- 驗收：NakiTests 1097 tests 0 failures（`harden-final-test.log`）；`ReplayFingerprintTests` 2 條綠；`grep -rn "/Users/" NakiTests` 0；DerivedData 已刪。

## 復驗後小修

只補測試，未動產品碼。依據復驗報告 `verify/report.md` 4-2、4-3、4-4、4-5。

- `testConfirmPendingDoesNotReportStallWhenModeNeverSends`（`AutoConfirmEngineTests`）：推薦模式下 confirm 等待超過上限也不得報 `confirmStalled`。套用 `verify/mut-M1.diff`（拿掉 `sendsActions` 條件）後此測試轉紅，證據 `fixup-mut-M1.log`。
- `testPassAttemptsPerCycleUseOwnLimit`（`AutoPlayEngineTests`）：`passAttempts = 3`、`maxAttempts = 15`，主動送「過」一輪內恰送 3 次。套用 `verify/mut-M2.diff`（上限改成 `timing.maxAttempts`）後送出 15 次、測試轉紅，證據 `fixup-mut-M2.log`。
- 第一版「過」測試走 `perform` 路徑而非 `sendPass`，M2 存活（`retryLimit` 兩處呼叫，只有 `sendPass` 那處被變異）；改為空推薦並越過寬限期後才殺掉。
- 變異皆已還原，`AutoPlayEngine.swift` 內容與變異前一致。
- 驗收表 warning 數筆誤已改為 3。

已知風險：BT-06 的測試寫 `LiqiResponseStore.shared` 單例，前後各 reset 一次；目前測試串列執行無礙，若開平行測試可能互相干擾。
