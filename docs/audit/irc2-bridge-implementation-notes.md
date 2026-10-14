# IRC 第二輪 Bridge 實作筆記

基準：main `910c51c`，分支 `irc2-bridge`（未 commit）。依據：`.swfd/logs/irc2/plan.md`、`.swfd/logs/irc/audit-bridge.md`。
log：主 repo `.swfd/logs/irc2-bridge/`（`baseline.log`、`red.log`、`green-new.log`、`build-macos.log`、`final-tests.log`、`build-ios.log`）。
新測試：`NakiTests/Irc2BridgeTests.swift`（14 個）。修前 14 個測試中 9 紅（13 個斷言失敗，`red.log`），修後全綠（`green-new.log`）。

## 逐條

| 編號 | 狀態 | 改法 | 測試 | 行為改變 |
|---|---|---|---|---|
| BR-03 | 已修 | parser 把 ActionNewRound field 5 存成單數 `dora`，不再併進 `doras`；bridge 以 `doras` 為準，只有它缺席才用 `dora`；每局無條件 `doras = doraList ?? []` | `testNewRoundWithBothDoraAndDorasKeepsNextKanDora`、`testInvalidFirstDoraResetsPreviousRoundKanDoraCount` 修前紅；`testNewRoundWithOnlySingularDoraStillSeedsDoraList` 鎖舊式單張 | 是：dora 事件不再被吞 |
| BR-04 | 已修 | 刪 `parseAuthGameRequest` 的 account_id、token；保留 game_uuid（本輪範圍外） | `testAuthGameRequestParsedDataHasNoCredentials` 修前紅 | 是：`lastParsed` 不再含 token |
| BR-05 | 已修 | `syncing` 期間 `continue`，不 `record()`；log 改為「不計回音」 | `testSyncGameReplayOfOwnActionsDoesNotCountAsEcho` 修前紅 | 是：重放的自家動作與 end_kyoku 不滿足 `waitForEcho` |
| BR-06 | **改列需要決策，未做** | 見下 | — | — |
| BR-07 | 已修 | `ponMelds` 記本局每次碰的 pai＋consumed；加槓時以同 actor、同底牌查出原碰三張當 consumed 並移除；每局與 `reset()` 清空 | `testKakanConsumedComesFromRecordedPonWithoutRedFive`、`testKakanUsesThePonOfTheSameActorAndTile` 修前紅；赤五案例與無紀錄 fallback 為鎖定測試 | 是：原碰無赤五時 consumed 不再含 `5mr` |
| BR-08 | 已修 | `LiqiMsgIdAllocator.revoke(_:)`（新增，最小）；`send` 在 `no_send_handler` 與 `raw.success == false` 時撤銷 | `testFailedSendRevokesMsgIdRegistration`、`testMissingSendHandlerRevokesMsgIdRegistration` 修前紅；`testSuccessfulSendKeepsMsgIdRegistration` 鎖成功路徑 | 是：失敗的號不再被誤認 Naki 自送 |
| BR-09 | 已修 | `GameRecorder.record` 對 `start_game` 呼叫 `KyokuStreamAccumulator.apiEvent` 取其 `names`（單一來源，未改 Bot）；`id`、`is3P` 照舊 | `testRecordedStartGameUsesCloudPlaceholderNames` 修前紅 | 是：新錄影的 names 為 `Player0…`；記憶體內事件與 Bot 輸入不變 |

## BR-06 為何改列需要決策

用戶指示：欄位語意在 liqi.json 與現有錄影中無法確定就停手，不得猜。查證結果：

- liqi.json 的 `GameSnapshot.index_player`（4）、`PlayerSnapshot.tilenum`（3）、`mings`（5，`Fulu{type, tile[], from[]}`）只有欄位名與型別，沒有語意說明；`Fulu.type` 的數值對照不在 liqi.json。
- 現有 `*.mjai.jsonl` 錄的是 MJAI 事件，不含原始快照；`~/Library/Logs/Naki/*/` 的 bridge／liqi log 只印快照欄位名（keys），不印值，且含副露的重連沒有留存。repo 內無含副露的真實快照。
- 純算術可得的事實：手牌張數 `% 3 == 2` 代表「該打牌」，但剛摸牌與剛鳴牌（chi／pon 後）都落在這個值，快照無法只靠張數分辨；分辨需要 `index_player` 與 `mings` 的語意。

需要用戶決策：(a) 取得含副露的 live 重連快照，確認 `index_player`、`tilenum`、`Fulu.type`／`from` 的語意後再實作還原（含補副露事件）；或 (b) 有副露的快照視為不可還原，記 blocking、不發 start_kyoku（保守，不需要語意）。程式未動，行為同 main。

## 清理

- `parseAnGangAddGang` 的加槓分支原本內嵌「查原碰＋退回推定」（閉包套閉包），抽成 `kakanConsumed(actor:baseTile:mjaiTile:)`，邏輯逐字保留，行為不變。
- `ponMelds` 記錄（`pon` 分支一行）、`revoke`、BR-03 的 `dora`／`doras` 處理已是單一職責、巢狀 ≤3 層，未動。
- 重複模式：`replacingOccurrences(of: "r", with: "")` 與 `baseTile` 的算法同源，但只在該函數內出現兩次，抽出反而增加間接層，未動。
- 分層（BR-09）：`GameRecorder` 呼叫 `KyokuStreamAccumulator.apiEvent` 是 Bridge 檔案認得 Bot 目錄的型別。既有先例：`NakiWebCoordinator`（Bridge 目錄）直接持有 `NativeBotController`。專案是單一 module，沒有編譯循環；NakiTests 內沒有禁止 Bridge 引用 Bot 的 lint（只有 `AutoPlayEngineTests` 掃 `Services/Bot` 的呼叫點）。結論：不違反既有規則，不需搬檔。若之後想讓 Bridge 完全不認 Bot，最小修法是把 `apiEvent` 的 `start_game` 佔位名邏輯抽到中立位置；本輪不做（跨範圍）。
- 驗收（`cleanup-build.log`、`cleanup-tests.log`）：clean build `BUILD SUCCEEDED`；NakiTests 1105 通過、0 失敗；`BridgeCharacterizationTests`、`Irc2BridgeTests`、`ReplayFingerprintTests` 通過；warning 去重數 build 3、test 4（算法同上，不多於前一步的 4）；`grep -rn "/Users/" NakiTests` 0 筆。

## 驗收

| 項目 | 結果 | 證據 |
|---|---|---|
| macOS clean build | 綠 | `build-macos.log`（`BUILD SUCCEEDED`） |
| NakiTests | 1105 通過、0 失敗（基線 1091＋14） | `final-tests.log`、`baseline.log` |
| warning 去重數 | 基線 6，之後 4（`sed 's/^.*warning:/warning:/' \| sort -u`；後者含增量編譯，未更多） | 兩份 test log |
| iOS Naki-M Simulator build | 綠 | `build-ios.log` |
| `BridgeCharacterizationTests`、`ReplayFingerprintTests` | 綠 | `final-tests.log` |
| `grep -rn "/Users/" NakiTests` | 0 筆 | 指令輸出 |

特性化 fixture `bridge-characterization.json` **未變動**（`git status` 無此檔）：該檔情境的事件輸出不受上述修正影響（`newRound.dora5AndDoras14` 的內部清單變了，但事件相同；`gang.kakan` 沒有碰紀錄，走保留的推定 fallback）。新測試 fixture 只用「NickA」類佔位暱稱與假 account id。

## Deviations

1. **BR-07 無碰紀錄時維持舊推定**：重連從局中開始、歷史碰不在重放內時，沒有可查的原碰。選保守：沿用舊推定並只寫 bridgeLog，沒有新增 degraded fault（新增會改 fault 計數與橫幅，見第一輪 BR-23）。這條路徑仍可能錯，屬已知風險。
2. **BR-09 只改錄影**：單一來源靠直接呼叫 `KyokuStreamAccumulator.apiEvent`（不改 Bot 目錄）。記憶體內的 `start_game` 事件仍帶真實暱稱，Bot 與 UI 讀到的不變；以 `is3P: false` 呼叫，所以三麻錄影 names 為 3 筆，不補第四個空名。
3. **BR-04 範圍**：只刪 account_id、token。`NakiActions.swift:471` 的註解仍寫「登入／authGame 回應」，該檔不在本包範圍，未改。`WebSocketInterceptor` 的同類註解已改。
4. **BR-08 撤銷條件**：只在送出前即確定失敗時撤銷：`no_send_handler`，以及 JS 回報的 `no_open_majsoul_connection`、`no_game_gateway_connection`、`invalid_base64`、`decode_failed`、`empty_payload`、`send_failed`（`decode_failed: …`、`send_failed: …` 以前綴比對）。`js_error`、`unparsable_js_result`、`runtime_deallocated` 與成功但沒收到回應的號不撤銷。

## 未驗證

- 以上皆無 live 驗證（無測試帳號、未啟動 App、未送封包、未呼叫 8765）。
- BR-05 對 `AutoPlayActionExecutor` 的下游影響：重連期間若真有和牌，回音不再成立，executor 走逾時路徑；未逐行讀 executor，未驗證。
- BR-07 的 Majsoul 實際 `froms`／tiles 排列只用測試構造的封包。

## 強化（變異測試）

不用 muter。harness 為 `mutate.py`（只對 `git diff -U0` 新增行做關係、邏輯、三元互換），手工變異為 `manual.py`；兩者與全部 log 在主 repo `.swfd/logs/irc2-bridge/mutation/`（`results.jsonl`、`manual-results.round1.jsonl`、`manual-results.jsonl`、`logs/`）。測試類別為 `Irc2BridgeTests`、`BridgeCharacterizationTests`、`ReplayFingerprintTests` 加 12 個相關 Bridge／Liqi／WebSocket 類別。

| 類型 | 變異數 | 殺掉 | 存活 |
|---|---|---|---|
| harness（7 筆，GameRecorder 1、LiqiEncoder 1、MajsoulBridge 5） | 7 | 7 | 0 |
| 手工，第一輪 | 14 | 8 | 6 |
| 手工，補測試後重跑存活者 | 6 | 6 | 0 |

手工 14 筆涵蓋：BR-07 總是推定、不記碰、不移除原碰、三處清空各拿掉一次（newRound、`reset()`、snapshot）；BR-08 兩處 `revoke` 各拿掉；BR-05 拿掉 `continue`；BR-09 改回原始暱稱；BR-04 恢復 token；BR-03 不每局重設、拿掉單張 fallback、單張優先於 doras。

第一輪存活的 6 筆及補的測試（補完後皆被殺）：

- 不移除原碰：`testKakanConsumesTheRecordedPonOnlyOnce`
- 三處清空 `ponMelds`：`testNewRoundClearsRecordedPons`、`testResetClearsRecordedPons`、`testSnapshotRestartClearsRecordedPons`
- BR-03 新局無任何寶牌時不重設：`testNewRoundWithoutAnyDoraResetsPreviousRoundKanDoraCount`
- BR-03 單張優先於 doras：`testNewRoundWithConflictingDoraAndDorasUsesDoras`

「只消費一次」測試用同 actor 連兩次加槓，是構造情境，真實牌局不會發生；它鎖的是實作行為而非遊戲規則。

驗收：NakiTests 全量 1111 通過、0 失敗（`full-test.log`），`grep -rn "/Users/" NakiTests` 0 筆。

未覆蓋：harness 只產生關係、邏輯、三元互換，不會刪語句或換常數，所以 `LiqiParser` 刪除的程式、`WebSocketInterceptor` 註解、`LiqiEncoder.revoke` 內部（僅關係變異 1 筆）沒有語句刪除變異；`revoke` 的 `removeAll` 若改成只移除第一筆等價變體未試。

## 復驗後修正

依據：`.swfd/logs/irc2-bridge/verify/report.md` 與主線裁決。log 在 `.swfd/logs/irc2-bridge/fixup-*.log`。

| 項目 | 改法 | 測試 | 證據 |
|---|---|---|---|
| BR-08 收窄 | `LiqiActionSender.failedBeforeSending(detail)`：detail 以六個送出前失敗碼之一開頭才撤銷。實際字串來自 `naki-websocket.js` 557–631、`NakiRuntime.swift:137,143`、`NakiWebSocketScript.swift:72`，與裁決名稱一致 | `testAmbiguousFailuresKeepMsgIdRegistration`（修前紅）、`testDefiniteFailuresRevokeMsgIdRegistration`（鎖定） | `fixup-red.log` 三筆斷言失敗；`fixup-green-new.log` 24 測試 0 失敗 |
| BR-07 降級 | `kakanConsumed` 查到的原碰含 2 張以上赤五（實體不可能）就退回推定；該筆碰紀錄仍移除 | `testKakanAfterPonWithoutFromsFallsBackToInference`（修前紅，`[5mr,5mr,5mr]`；修後 `[5mr,5m,5m]`，同修前推定） | 同上 |
| parseGameState 寶牌 | `doras = doraList ?? []`，比照 BR-03 | `testSnapshotWithoutDorasResetsPreviousKanDoraCount`（鎖定，**修前不紅**） | `fixup-red.log` 該測試通過 |

parseGameState 無法做出修前紅：`LiqiParser.parseGameStateProto` 恆寫入 `doras`（空陣列也寫），所以從線路進來 `doraList` 不會是 nil，修前的「nil 時保留舊清單」分支不可達。此修正只是讓程式與 BR-03 一致、防未來 parser 改動；測試鎖的是線路行為。

BR-08 補充：`no_websocket_module`（`sendRaw` 腳本在模組缺席時回的短碼）也是送出前失敗，但不在裁決清單內，維持不撤銷（與修前相同，保守）。

復驗後驗收：clean build `BUILD SUCCEEDED`、warning 去重 3（`fixup-build-macos.log`）；`-only-testing:NakiTests` 1115 通過、0 失敗（`fixup-tests.log`，1111＋新增 4）；`BridgeCharacterizationTests`、`Irc2BridgeTests`（24）、`ReplayFingerprintTests` 綠；iOS Naki-M Simulator build 綠（`fixup-build-ios.log`）；`grep -rn "/Users/" NakiTests` 0。第一次全量曾有 `LiqiParserLearningTests.testTraceRedactsCredentialPayloadButKeepsOrdinaryStrings` 2 個斷言失敗（`fixup-tests-run1-flake.log`，log 落盤時序，該測試 8.6 秒），單獨重跑與全量重跑皆綠（`fixup-learning.log`），判為負載下的時序不穩，推測，未追根因。
