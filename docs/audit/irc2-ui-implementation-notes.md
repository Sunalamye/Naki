# IRC 第二輪 介面加服務 實作筆記（分支 irc2-ui，基準 main 910c51c，未 commit）

log 目錄：`/Users/suoie/Documents/tools/coremltools/Naki/.swfd/logs/irc2-ui/`

## 逐條

### UI-05 側欄雲端退化統一
- 改法：`BotStatus.isCloudFallback`（`cloudHost != nil && (cloudDegraded || cloudFallbackStreak > 0)`）；異常列、`shown`、展開層 `cloudState` 都讀它，刪掉 `DecisionAlerts` 內的區域屬性。
- 測試：`CloudFallbackStatusTests`（3 條）。
- 修前紅：`ui05-red.log`。先讓屬性只回 `cloudDegraded`（等同舊展開層判準），`testSingleFallbackWithHealthyBreakerCountsAsFallback` 失敗。修後綠：`red-ui05green-sv09-ui07.log`（3 條 0 failures）。
- 使用者可見：雲端失敗一手、斷路器仍健康時，展開層「雲端狀態」由「已連線」改為「改用本機」，與異常列一致。

### UI-07 偏好 port 與實際 port
- 改法：`GameStore` 新增 `debugServerPreferredPort`（預設 `DefaultNakiMCPContext.defaultServerPort`＝8765，取代 8765 字面值）；`debugServerPort` 只表示實際綁定值。
- 讀寫點歸類：
  - 偏好：`NakiRuntime.startDebugServer` 建 `DebugServer` 的 port（原讀實際值，已改）。
  - 實際（不變）：`DebugServer` `.ready` 寫回、`ContentView` 工具列顯示與無障礙值、`AdvancedSettingsSheet` 的 URL 與 curl 範例、`DebugServerFramingTests`、`BotToolsTests`。
  - `DebugServer.preferredPort`／`MCPContext` 的 `serverPort` 是 server 內部值，不經 `GameStore`，未動。
- 測試：`DebugServerPreferredPortTests`。測試把偏好設為隨機高位 port、實際值設為另一個（模擬上次綁到別處），啟動後斷言綁到偏好 port；不綁 8765。
- 修前紅：`red-ui05green-sv09-ui07.log`（新屬性已加、尚未接線：綁到 55211 而非 54211）。修後綠：`green-full-test.log`。
- 使用者可見：8765 曾被占用而綁到 8766，之後從工具列停止再啟動，會重新先試 8765（原本沿用 8766）。

### SV-09 kan 無效輸入
- 改法：`NakiGameAction.kanType` 改為 throws；給了 `kanType` 卻無法辨識（含非字串）丟 `invalidParameter("kanType")`；給了 `tile` 卻無法辨識（含空字串）走 `requiredTile()` 丟 `invalidParameter("tile")`。沒給才推導。`spec` 在 `sendLiqi` 之前執行，所以不送出。
- 測試：`GameToolKanValidationTests`（無效輸入 sender 呼叫 0 次且拋錯；未給參數與大小寫 `KAKAN` 仍可用）。
- 修前紅：`red-ui05green-sv09-ui07.log`（`kakan2`、`zz`、空字串三例各送出 1 次、未報錯）。修後綠：`green-full-test.log`。
- 使用者可見：`game_action`／`game_action_verify` 的 kan 帶錯拼字或壞牌時回錯誤，不再靜默改用推導值送出真實動作。

### SV-23 錯誤碼描述
- 維持現狀，無程式改動。錯誤碼 `game_snapshot_callback_not_configured` 保留（`BotTools.swift`、`ToolAndModelGapTests` 比對它）。`MCPToolOutputSchema` 的 `snapshot` 描述已是「取不到時為 null」，沒有舊的「回調未設定」字樣。

### SV-08 刪除 GameHighlightScript.make()
- 先 grep：正式碼對 `GameHighlightScript.` 只有 `WebSession` 用 `.clear`；`make` 只有測試呼叫。
- 改法：刪 `make()`，`GameHighlightScript` 只剩 `clear`。`WebSession.syncHighlight` 的腳本組裝抽成 `static recommendationScript(...)`（純輸入，內容與原本逐行相同），`syncHighlight` 呼叫它。
- 測試：刪 `GameHighlightScriptTests`（只測 `make`）；新增 `WebSessionHighlightPublishTests`（6 條，斷言實際發布的推薦 JSON、`hand`、`callTiles`、`isCallOpportunity`、`.off` 尾端 clear、舊 oplist 不發布組合）。`ToolbarControlsRealTests` 的矩陣第 2 格改讀發布腳本。
- 此條是重構與刪死碼，不是行為修正，無修前紅；證據為 `green-full-test.log`、`grep GameHighlightScript.make command NakiTests` 只剩 `Bridge/LiqiTile.swift` 註解。
- 使用者可見：無。
- 順帶：`CLAUDE.md` 與 `docs/architecture-deep-dive.md` 中「make 保留為參考實作」兩句改成已刪除。

## 驗收
| 項目 | 結果 | 證據 |
|---|---|---|
| NakiTests | 1098 tests 0 failures（基線 1091；復驗後修正再增 1 條，前一版 1097） | `fixup-full.log`；基線 `baseline-test.log` |
| warning 口徑 | 乾淨 DerivedData 全量編譯的 log 中，路徑含 `/command/` 的 `warning:` 行去重數：基線 3，最終 3 | `baseline-test.log`、`final-clean-test.log` |
| Release build | 成功 | `release-build.log` |
| iOS Naki-M（generic iOS Simulator） | 成功 | `ios-build.log` |
| ui-token-gate | 7 PASS 0 FAIL | `ui-token-gate.log` |
| xcstrings-gate | 401 keys, 0 failures | `xcstrings-gate.log` |
| `/Users/` in NakiTests | 0 | grep |
| MCP 工具數 40 | 既有斷言在 1098 條中通過 | `fixup-full.log` |

## Deviations
- UI-05：計畫寫「`fallbackStreak > 0` 即改用本機」。為不讓斷路器已開、尚無決策的情況（原異常列會顯示）退回「已連線」，保留 `cloudDegraded` 為充分條件之一，streak > 0 為新增。屬較保守選項。
- `LiqiTile.swift:34`、`NakiWebSocketScript.swift:7` 的註解仍提 `GameHighlightScript.make`：兩檔在 `Services/Bridge`，不在本包範圍，未動。
- `docs/` 下其他歷史文件（設計決策、plugin-live-test-notes 等）提到 `make` 的段落是歷史記錄，未改。
- `WebSessionHighlightPublishTests` 刪除了舊的 `testMarksTileOnBoardMatchesActualScriptOutput`（鎖 `ActionType.marksTileOnBoard` 與 `make` 輸出一致）。發布路徑不自己標牌，沒有對應物；`marksTileOnBoard` 保留，註解改為不再引用已刪的腳本。
- 觀察，未改：`.off` 時發布的 `isCallOpportunity` 仍可能為 true（原行為，插件自行決定是否使用）。

## 未驗證
- 側欄實際畫面（沒有啟動 App、沒有截圖）；UI-05 只驗 `BotStatus` 判準，兩處 View 讀它由 grep 與編譯確認。
- UI-07 在「8765 真被占用」的真實情境；測試用隨機高位 port 模擬。
- 重啟 Debug server 的 live 行為（不得呼叫 8765）。

## 清理
- 巢狀：`recommendationScript` 最深 3 層（`if current` → `if let type` → `if type == .chi`），為原邏輯原樣搬出，未再拆；`kanType` 與 `isCloudFallback` 為單層。
- 重複：`cloudDegraded`／`cloudFallbackStreak` 在 View 層只剩 `DecisionAlerts` 異常列文字讀 `cloudFallbackStreak` 當手數，沒有第三處自己算退化；其餘讀點為 Bot 狀態寫入與 MCP 輸出。
- UI-07 讀寫點逐一核對：偏好值只被 `NakiRuntime.startDebugServer` 讀；實際值由 `DebugServer` 寫，`ContentView`、`AdvancedSettingsSheet` 讀。命名不需註解即可分辨。
- 修正兩處文字，行為不變：`debugServerPort` 的 doc comment 原寫「Origin 檢查讀這個」，實際 Origin 驗證用 `DebugServer` 內部值，改為「工具列與設定頁顯示讀這個」；`recommendationScript` 參數縮排對齊。
- `marksTileOnBoard`：正式呼叫端為 `GameStore.updateHighlight`（由 `NakiRuntime` 呼叫），保留。
- `CLAUDE.md`、`docs/architecture-deep-dive.md` 的兩句與程式一致：`GameHighlightScript` 只剩 `clear`、`WebSession.recommendationScript` 存在。
- 依賴規則：以既有 lint（NakiTests 內架構測試）驗收，結果見下方清理驗收。

### 清理驗收
NakiTests 1095 tests 0 failures（`cleanup-test.log`，乾淨 DerivedData 全量編譯）；`/command/` 路徑 warning 去重數 3（同前一步算法，持平）；`ui-token-gate` 7 PASS 0 FAIL（`cleanup-ui-token-gate.log`）；`grep -rn "/Users/" NakiTests` 0；DerivedData 已刪。

## 強化（變異測試）
log 與 harness：`/Users/suoie/Documents/tools/coremltools/Naki/.swfd/logs/irc2-ui/mutation/`（`mutate.py` 自動、`manual.py` 手工、`results.jsonl`、`manual.jsonl`、`logs/`）。產品程式碼未動，`before.diff` 與 `after.diff` 逐位元組相同。

- 自動 harness：對本包 `command/` 新增行產生 12 個變體，12 殺 0 活（`results.jsonl`）。
- 手工變體 9 個，最後有效結果 8 殺 1 活（`manual.jsonl`，同 idx 以最後一筆為準）：
  - UI-05：拿掉 `streak > 0`、拿掉 `cloudHost != nil`、展開層讀舊欄位、異常列讀舊欄位 → 殺；`shown` 改讀舊欄位 → 活。
  - UI-07 `startDebugServer` 改讀 `debugServerPort` → 殺。
  - SV-09 無效 kanType 改回推導、無效 tile 改回靜默 → 殺。
  - SV-08 拿掉 `.off` 尾端 clear → 殺。
- 未覆蓋（畫面層）：實際渲染結果不驗；原始碼鎖只保證引用點，不保證畫面。
- 存活 `shown` 變體現由原始碼鎖殺掉；原為等價：`isCloudFallback` 蘊含 `cloudHost != nil`，陣列第 2 項同為真，`shown.contains(true)`（底部間距）不變。差別只在動畫觸發值，單元測試測不到動畫，不補測。
- 補測試：
  - 新增 `CloudFallbackViewTests`（2 條，原始碼鎖）：異常列、展開層、`shown` 必須引用 `isCloudFallback`，側欄不得再出現 `botStatus.cloudDegraded`。依主線指示不用像素比對。
  - `DebugServerPreferredPortTests`：偏好 port 改為 20000–29999 並實際 bind 驗證空閒。原本 50000–54999 落在暫時 port 範圍，變異批次中出現過一次與無關變體同時失敗（綁到偏好 port +1）的假紅。
- 曾試像素比對，全量中不穩定（同尺寸差數 byte），已放棄改為原始碼鎖。
- 驗收：NakiTests 1097 tests 0 failures（`harden-final1.log`、`harden-final2.log` 連跑兩次）；`ui-token-gate` 7 PASS（`harden-ui-token-gate.log`）；`grep -rn "/Users/" NakiTests` 0。
- 前後比對：`before.*` 與 `after.*`；追蹤檔 diff／stat 相同；未追蹤檔差異僅為新增 `CloudFallbackViewTests.swift`、改動的 `DebugServerPreferredPortTests.swift` 與本 notes（本段新增）。

### Deviations（強化）
- 測試執行曾遇 testmanagerd 卡死（log 停在「attach the result bundle」，連單一類別都無法啟動）。依既有經驗 kill -9 testmanagerd 後恢復；該行程為使用者共用，其他會話的測試可能被重啟波及。

## 復驗後修正
log：`/Users/suoie/Documents/tools/coremltools/Naki/.swfd/logs/irc2-ui/fixup-*.log`；依據 `verify/` 復驗報告。

- `BotToolsTests.testStartDebugServerIsNoOpWhileFlagSet`：補 `debugServerPreferredPort = port`，guard 失效時也不會去綁 8765。
- SV-09 JSON `null`：`kan` 的 `kanType`、`tile` 為 `NSNull` 時視為沒給，走既有推導；非字串的非 null 值仍報錯。新增 `testJSONNullKanArgumentsAreTreatedAsOmitted`。修前紅（`fixup-red.log`：`invalidParameter("kanType")`），修後綠（`fixup-green.log`，7 tests 0 failures）。
- `GameToolKanValidationTests` 的 KAKAN 例子補斷言：結果等於小寫 `kakan`，且不同於預設推導的暗槓。
- `AUDIT.md`、`docs/majsoul-unity-protocol.md` 的過期敘述（`make()` 只剩測試呼叫、`GameHighlightScriptTests` 7 條）改為現況：`GameHighlightScript` 只剩 `clear`，發布腳本由 `WebSession.recommendationScript` 組，測試為 `WebSessionHighlightPublishTests`。
- 驗收：NakiTests 1098 tests 0 failures（`fixup-full.log`）；`ui-token-gate` 7 PASS 0 FAIL（`fixup-ui-token-gate.log`）；`grep -rn "/Users/" NakiTests` 0。

### 未做的建議（本包不處理）
- 停止時工具列顯示上次實際 port。
- `（已 0 手）` 文字在 0 手時的呈現。
- 原始碼鎖對縮排敏感。
- `ToolbarControlsRealTests` 第 2 格。
- `syncHighlight` 接線沒有測試。
