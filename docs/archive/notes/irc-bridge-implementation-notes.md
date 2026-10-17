# IRC Bridge 層實作筆記

基準：main `7c2fe26`，分支 `irc-bridge`（未 commit）。審查來源：`.swfd/logs/irc/audit-bridge.md`（BR-01～34）。
log：主 repo `.swfd/logs/irc-bridge/`。

## 逐條狀態

| 編號 | 狀態 | 修改前後 | 行為改變 | 測試 |
|---|---|---|---|---|
| BR-01 | 已修 | `webNavigationDidStart` 清掉 `awaitingGameKind`；遊戲自己送的 `startUnifiedMatch` 回應的 `LiqiResponseRecord.errorCode`（與 `LiqiResponseStore` 同一來源）非 0 時也清掉；空 error 或 code=0 不清 | 是（awaiting 生命週期變短） | `NakiWebCoordinatorTests.testNavigationStartClearsAwaitingGameKind`、`LiqiParserLearningTests.testGameSentStartUnifiedMatchErrorResponseClearsAwaitingGameKind`（修正前失敗 `br01-before.log`，修正後通過 `br01-after.log`）；反向鎖 `testGameSentStartUnifiedMatchSuccessResponseKeepsAwaitingGameKind`、`testGameSentStartUnifiedMatchEmptyOrZeroErrorKeepsAwaitingGameKind` |
| BR-02～09 | 不改，列給用戶決策 | — | — | — |
| BR-10 | 已做 | start_kyoku 的守衛與組裝抽成 `makeStartKyoku(fromSnapshot:…)`；`parseNewRound` 與 `parseGameState` 只取值 | 否（事件流、fault site、fieldId、reason、log 逐字相同） | `BridgeCharacterizationTests`（重構前錄製） |
| BR-11 | 已做 | `recordOperationSnapshot` 三處 `operations.clear()` 合成一處；空清單與有內容兩種 log 條件不變 | 否 | `BridgeCharacterizationTests`（oplist.* 與 newRound.op*）、`LiqiParserFailureTests` oplist 系列 |
| BR-12 | 已做第一步 | 841-845 改為 `mjaiTile != pai && consumed.count < 2`（布林等價）；三段 consumed 推導不合併 | 否 | `BridgeCharacterizationTests`（meld.*）、`LiqiParserFailureTests` chi／pon 系列 |
| BR-13 | 已做 | `LiqiParser.loginResponseMethods` 一份，parser 與 bridge 共讀 | 否 | 既有登入回應測試 |
| BR-14 | 還原 | 審查前提不成立：`hasReceivedAuthGame` 並非只寫不讀，syncGame 那行 log 讀取它（log 屬可觀察輸出）。已還原狀態、設值、重置與 log 欄位，與 7c2fe26 逐字相同；只保留 `syncing` 的註解修正 | 否 | `fixup-br14-diff.log`（`hasReceivedAuthGame` 各行與 main 相同、`git diff 7c2fe26` 無涉及行） |
| BR-15 | 已做 | `WebSocketInterceptor.reset()` 註解改為局中重連 | 否 | 無需測試 |
| BR-16 | 已做 | 三處 msgId 區段註解改為 60000–63999 自送、64000–65500 插件、判定看登記 | 否 | 無需測試 |
| BR-17 | 已做 | 三麻細則改記 live 已驗（`s3-live-4/live-all.log`）；拔北移出未驗清單；CDN byte-identical 改為「基準過期」 | 否 | 無需測試 |
| BR-18 | 已做 | 「只剩兩個模組」改「只剩三個模組」 | 否 | 無需測試 |
| BR-19 | 已做 | 註解改為與 liqi.json `Account.level`／`level3`（21／22）一致 | 否 | 無需測試 |
| BR-20 | 已做 | `LiqiEnvelope`、`LiqiEncoder` 檔頭改為「WebSocket 上的 ActionPrototype.data 需 XOR；GameRestore.actions 內不需要」。`LiqiParser` 該處原本就與 CLAUDE.md 一致，未動 | 否 | 無需測試 |
| BR-21 | 已做（僅註解） | guard 維持一個，註解寫明兩種退回情況與安全失敗理由；沒拆成兩個 guard，因為退回動作相同，拆開只會多一份重複 | 否 | 無需測試 |
| BR-22 | 已做 | `private var playerCount` 計算屬性，四處改讀（`parseAuthGame` 內以 `seatList.count` 命名的區域變數是另一個意思，未動） | 否 | `BridgeCharacterizationTests`（sanma）、`LiqiParserFailureTests` 三麻系列 |
| BR-23 | 改歸需要決策，未做 | `parseAnGangAddGang` default 記 degraded fault 會讓 fault 計數與可能的橫幅多一筆 | 會 | — |
| BR-24 | 還原 | 行為不變：保留 main 的守衛語意（有限且絕對值 < 2^53，否則 0；其後 `Int(value)` 截斷），2^53 改為具名常數 `exactIntegerLimit`。回 0 是「超出 Double 精確整數範圍、視為不可信」，非 bug | 否 | `NakiWebSocketScriptTests.testClosedCountFromDouble`（補 ±2^53、2^53+2、±9e18、±(2^53−1)）；`Int(exactly:)` 版紅 `fixup-br24-red.log`，還原後綠 `fixup-green-subset.log` |
| BR-25 | 已做 | `ObservedMatchSids.observationLimit` | 否 | 無需測試 |
| BR-26 以後 | 不做 | 「可改可不改」 | — | — |

## 復驗後修正

- 應修 2：`testRoundLogPrintsAfterRangeGuardOnly`、`testEmptyOperationWarnsOnlyForActionNewRound` 改為只數兩個 fence 之間的 log，並先灌 5100 筆含被數文字的 log。修前寫法在灌滿後紅（`fixup-logcap-red.log`），修後綠（`fixup-green-subset.log`）。
- 建議 5：特性化測試失敗時的輸出檔改寫 `FileManager.default.temporaryDirectory` 下的唯一檔名，teardown 刪除。

## 驗證方式

- 重構前先錄製 `NakiTests/Fixtures/bridge-characterization.json`（約 70 個情境：ActionNewRound 各種守衛、重連快照、chi／pon／daiminkan／槓、oplist 三條清除路徑；輸出含事件、fault、blocking、oplist 快照），重構後逐字比對。
- 為什麼不用既有錄影 fixture：`ReplayFingerprintTests` 重放的是 MJAI 事件流，不經 `LiqiParser`／`MajsoulBridge`（該測試檔頭已寫明），所以鎖不住這幾條路徑。

## Deviations

1. （已還原，見「清理」）fault.reason 文字。
2. （已還原，見「清理」）log 順序。
3. **BR-11 手法**：審查建議用 `.record`／`.clear`／`.clear(warning:)` 判斷再 switch；實作改為「record 成功就回，否則統一 clear 再依內容印 log」，不新增型別，分支條件不變。
4. **BR-12**：只做第一步，沒合併三段 consumed 推導。三段的前提不同（froms 路徑、備用路徑、補救路徑），合併風險高於收益。
5. **BR-23**：改歸需要決策（見上表）。
6. **日誌子集失敗**：先前記錄「只跑 `LiqiParserLearningTests` 子集時 `testTraceRedactsCredentialPayloadButKeepsOrdinaryStrings` 必紅」，復驗後未重現；改記為「不穩定（推測）」，原因未查，與本工作包無關。

## 未驗證

- `scripts/replay-check.sh` 需要執行中的 App，未跑。
- BR-01 的兩條修正路徑只有單測；排隊中重載頁面與伺服器拒絕段位場請求都沒有 live 觀察。
- 錯誤回應判斷改用 `LiqiResponseRecord.errorCode`（`startUnifiedMatch` 不在例外表，error 取 field 1）；未見過 live 的 `startUnifiedMatch` error 封包。`errorCode` 對解不出 varint 的畸形 error 回 nil，此時不清除（保守）。

## 已知缺口

特性化 fixture（`bridge-characterization.json`）未涵蓋：重連快照含副露、seat 未知、跨局 dora。

## 清理

主線裁決：Deviation 1、2 屬「建議改」，必須行為不變，已還原。

- **還原 1，fault.reason**：快照路徑 chang/ju 的連接符改回「）→」（無空白），與 7c2fe26 逐字相同。其餘 reason 本來就相同。
- **還原 2，log 順序**：「parseNewRound: 場=…」改回範圍守衛之後才印，守衛失敗時不多印。做法是把 chang/ju 守衛從 `makeStartKyoku` 抽成 `acceptKyokuRange`，兩個呼叫端先過它再印 log、再進 `makeStartKyoku`；`makeStartKyoku` 因此只剩點數與手牌守衛及組裝。
- **證據**：新增 `testBlockingFaultReasonsMatchPreRefactorText`（六種 blocking reason 全文比對）與 `testRoundLogPrintsAfterRangeGuardOnly`（守衛失敗 log 數不變、守衛後失敗與成功各 +1）。還原前紅（`cleanup-red.log`：快照 reason 多空白、log 多一行），還原後綠（`cleanup-green.log`）。特性化 fixture 只記 site／fieldId，不含 reason，未重錄，`testBridgeOutputMatchesRecordedCharacterization` 兩次都綠。
- **複雜度**：`makeStartKyoku` 巢狀最深 2 層，單一職責（點數、手牌守衛與組裝）；`parseNewRound`、`parseGameState` 只取值與補發事件。測試輔助 `startedBridge` 取代 `run` 內重複的登入／authGame 前置。
- **沒清理**：BR-12 剩餘部分、BR-21 guard 拆分（主線指示不做）；`makeStartKyoku` 內仍有 `fromSnapshot` 三元運算，兩路徑只差字串與欄位號，再拆成兩個函數只會把守衛複製兩份。
- 依賴規則：未新增 import，既有 lint 測試見整套測試結果。

## 強化

手工 harness（`mutate.py`，不用 muter），只變異 `git diff -U0` 新增行；每個變異跑 22 個 Bridge 相關測試類別（基準 282 測試全綠，`LiqiParserLearningTests` 整類執行，順序依賴測試未紅）。log 與 `results.jsonl` 在主 repo `.swfd/logs/irc-bridge/mutation/`。

| 變異總數 | 殺死 | 存活 | 補測後殺死 | 等價 |
|---|---|---|---|---|
| 26 | 24 | 2 | 1 | 1 |

- **補的測試**：`testEmptyOperationWarnsOnlyForActionNewRound`（`BridgeCharacterizationTests`）。殺死 `MajsoulBridge.swift:547` 的 `==`→`!=`：該變異只改 log，回傳值同為 nil，所以特性化 fixture 看不到；新測試檢查別家附空 operation 不警告、`ActionNewRound` 空 operation 要警告。補後重跑被殺（`rerun/results.jsonl`）。
- **等價變異**：`MajsoulBridge.swift:261` 的 `&&`→`||`。此守衛與 `LiqiParser.swift:340` 的 `loginResponseMethods && isResponse` 重複；頂層 `accountId`／`account` 鍵只有 `parseLoginResponse`（僅登入回應）與 `parseAuthGameRequest`（方法非登入、type 為 request）會產生，其他 response 走 `blocksToDict` 只有 `fieldN` 鍵。因此無輸入能讓兩種寫法產生不同結果。這是推測性的程式分析，未用測試證明。
- **未覆蓋（harness 只變異兩側有空白的運算子與三元）**：`makeStartKyoku`、`acceptKyokuRange` 的 `Int(exactly:)` 與範圍比較（`0..<4` 區間式）、`guard` 結構、字串組裝，以及其他無運算子的新增行。
- **範圍外存活**：無（變異只取自本包新增行）。
- 補完後全量 `NakiTests` 1035 測試 0 failures；`grep -rn "/Users/" NakiTests` 0 命中。
