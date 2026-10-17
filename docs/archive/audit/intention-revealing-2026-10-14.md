# Intention-Revealing Code 審查報告（2026-10-14）

**狀態**：審查完成，實作進行中。本文件隨工作包結案更新；條目編號固定，修正後改狀態不刪原文。
**基準**：main `b8e0d95`（審查）／`7c2fe26`（實作，Swift 與審查基準相同）。
**準則**：用戶原文八項準則與額外面向 A／B，摘錄於主 repo `.swfd/logs/irc/criteria.md`。專案內不存在 `intention-revealing-code`、`swift-decide-then-act` skill，依原文執行。
**報告位置**：根目錄 `AUDIT.md` 已有其他用途（驗證差距與完成判準），macOS 檔名不分大小寫，`audit.md` 會撞名，所以放這裡。

## 範圍

| 組 | 目錄 | 審查檔 | 條數 |
|---|---|---|---|
| Bridge | `command/Services/Bridge/` | `.swfd/logs/irc/audit-bridge.md`（BR-01～34，附 liqi.json 欄位流對照） | 34 |
| Bot | `command/Services/Bot/` | `.swfd/logs/irc/audit-bot.md`（BT-01～33） | 33 |
| 介面 | `Views`、`ViewModels`、`Models`、`App`、`Actions`、`Naki/App` | `.swfd/logs/irc/audit-ui.md`（UI-01～37） | 37 |
| 服務 | `Services/MCP`、`Web`、`Debug`、`Plugins`、`Services/` 根 | `.swfd/logs/irc/audit-services.md`（SV-01～40） | 40 |

**排除**：第三方依賴（MortalSwift、MCPKit）、測試以外的 UI 測試 target、JS 檔（只審跨語言介面）。**未查**：iOS `Naki-M` 目錄、Akagi 原始碼（本機無）、MCP 規格與 RFC 條文（未上網查證）、所有 live 行為。各組未查清單見審查檔檔首。

## in-flight 延後（Deviations：保守選擇）

另一會話的 WP-F2（`Naki-wt-wpf2`，未提交）與插件 v2 分支（`plugin-v2-design`）正在改下列檔案。這些檔案的發現照記、不改，避免三方衝突：
`NakiActions.swift`、`NakiRuntime.swift`、`UIState.swift`、`AdvancedSettingsSheet.swift`、`ContentView.swift`、`MajsoulConnectionSettingsBox.swift`、`NakiApp.swift`、`DebugServer.swift`、`NakiMCPDependencies.swift`、`PluginsPageView.swift`、`PluginRegistry.swift`、`PluginImportSource.swift`。
受影響條目：UI 22 條、SV 13 條。

## 主線分類裁決

| 組 | 修（Bug） | 列給用戶決策 | 做（建議改） | 不做 |
|---|---|---|---|---|
| Bot | BT-01～04 | BT-05、06、07 | BT-08（只命名不改值，改歸建議改）＋全部建議改 | 可改可不改 8 條 |
| Bridge | BR-01 | BR-02～09 | 全部建議改 | 可改可不改 9 條 |
| 介面 | UI-01 | UI-05、07 | UI-10～16、UI-25 | in-flight 22 條、可改可不改 |
| 服務 | SV-01、SV-04；SV-05（統帥代決，見下） | SV-07、08、09 | SV-12～24、26、27、34、36（不碰 in-flight 與其他包的檔） | in-flight 13 條、可改可不改 4 條 |

- **用戶授權（2026-10-14）**：Bridge 與 Bot 全權授權，含改變送出行為的 Bug 修正。
- **SV-05 統帥代決**：Origin 只檢查 host 不檢查 port，同機其他 port 的網頁可用 `text/plain` POST 繞過 preflight 呼叫 `/js`。這是安全條目，不能以業務決策擱置。採保守修法：帶 Origin 且 port 不等於實際綁定 port 的請求一律拒絕。curl 與 MCP client 不送 Origin，不受影響。
- 實作中發現「建議改」其實改行為者，停手改歸需要決策。

## 工作包

| 包 | worktree | 狀態 |
|---|---|---|
| irc-bot | `Naki-wt-irc-bot` | 實作中 |
| irc-ui | `Naki-wt-irc-ui` | 實作中 |
| irc-bridge | 待建 | 排隊（等 irc-bot，兩者可能都動送出檔） |
| irc-services | 待建 | 排隊（編譯名額） |

每包流程：實作 → 清理 → 變異強化 → 獨立復驗 → 主線裁決。未取得 commit 授權前不 commit，最後集中提供 `refactor:`／`fix:` 分組。

## 進度與追加裁決（2026-10-14 19:50）

| 包 | 狀態 |
|---|---|
| irc-ui | 實作、清理、強化（11 變異全殺）完成；獨立復驗中 |
| irc-bot | 實作完成（BT-01～04 修前紅修後綠）；清理中 |
| irc-bridge | 實作完成（BR-01 修前紅修後綠；BR-10～12 以重構前錄製的特性化 fixture 鎖住）；排清理 |
| irc-services | 排隊 |

- **Bridge 重構的兩處可觀察差異要還原（主線裁決）**：實作 Deviation 1（快照路徑 `fault.reason` 連接符多一個空白）與 Deviation 2（`parseNewRound` 的「場=…」log 移到守衛前，守衛失敗時多印一行）。理由：歸類為「建議改」的條目必須行為不變，log 與 fault reason 屬可觀察輸出；保留它們等於把行為改變包裝成重構。清理步驟還原後由特性化 fixture 驗證。
- **實作中改歸「需要決策」的條目**：BT-20、BT-25、BR-23；另 BT-02 的限制（斷線時本輪仍跑完 dispatcher 5 次重試才退避，與 CLAUDE.md「非和牌動作立刻停手」字面不符，跨輪符合）。
- **新發現**：`LiqiParserLearningTests.testTraceRedactsCredentialPayloadButKeepsOrdinaryStrings` 只跑子集時失敗、整套通過，修改前即如此。推測依賴整套先建立 trace log，未深查。歸「建議改」候選，本輪不處理。
- **未驗證**：`scripts/replay-check.sh` 需要執行中的 App，三個包都未跑；BT-03（九種九牌）沒有端到端重放證據。

## 介面層完成裁決（2026-10-14 20:00）

irc-ui 五步完成（實作、清理、強化 11 變異全殺、獨立復驗「可 commit」、復驗後修正），閘全綠：NakiTests 1039／0、Debug／Release／iOS build 綠、token 閘 7 項 0 hit、`grep -rn "/Users/" NakiTests` 0 命中。復驗報告：`.swfd/logs/irc-ui/verify/report.md`。

- **UI-13 刪 `mortal3p` 分支：收下**。屬函式層行為改變，但復驗列舉全部 modelName 寫入點（NativeBotController、CloudBot、/debug/ui），正式路徑不可達。取捨：保留死分支會繼續誤導讀者以為存在 `mortal3p` 模型。
- **UI-12 部分完成：接受**。剩餘部分要改 `NativeBotController` 與 in-flight 的 `DebugServer`／`NakiMCPDependencies`，延到 WP-F2 合併後。取捨：為完整性越界改 in-flight 檔會與另一會話衝突。
- **建議 4 不改**：`bundledModelName`（"mortal"）與 `BundledCoreMLBot.identity.name`（"mortal-bundled"）易混淆，但改名牽動面大、收益不足，記錄保留。
- **證據指令更正**：`git grep` 不搜 untracked 檔，新測試檔多為 untracked，絕對路徑檢查一律改用 `grep -rn`；後續各包派工已照此要求。

## SV-05 接線策略（2026-10-14）

Origin port 檢查放在 `NakiMCPRequestGuard`（不在 in-flight）。實際綁定 port 若只能從 in-flight 的 `DebugServer.swift` 取得，本輪只讓 guard 以參數接收，呼叫端接線留給 WP-F2 合併後；未接線時預設行為必須與 main 相同。取捨：安全條目不能擱置，但也不能為它改另一會話正在改的檔；先把判斷邏輯與測試做好，接線是一行小改。

## Bot 完成裁決與服務層還原（2026-10-14 20:25）

irc-bot 五步完成：實作（BT-01～04 修前紅修後綠）、清理、強化（7 變異全殺）、獨立復驗「可 commit」（BT-01～04 在臨時樹逐條重現修前紅；BT-03 的 MortalSwift 槽位獨立查證成立）、復驗後小修。NakiTests 1036／0。復驗報告：`.swfd/logs/irc-bot/verify/report.md`。

- **BT-10、12、13 部分完成：接受**。理由各自可查證（switch 窮舉、需動 Bridge 與 Views、既有測試斷言 state==.idle）。取捨：為完整性越界或製造競態，代價高於保留註解層級的改善。
- **`GameModels.ActionType.ryukyoku` 註解在 irc-ui 修**：它寫「四麻沒有這個槽位」，正是 BT-03 長期未被發現的錯誤前提。檔案歸介面層包，所以在 irc-ui 修；irc-ui 未 commit、只改註解，以 build＋全量測試確認，不重跑整套復驗。
- **變異 harness 覆蓋有限：接受並記錄**。只變異比較、邏輯、三元運算子，Bot 新增 143 行只覆蓋 7 個位置；修正點已由修前紅測試直接鎖住，復驗另補兩個手工變體皆被殺。
- **服務層 SV-18、SV-20 必須還原**：SV-18 改了 `bot_trigger` 的對外錯誤碼，SV-20 讓 quick test 多接受欄位、改變送出的 Liqi request。兩者被標為「建議改」卻改了可觀察行為；若有價值，只能列為需要決策候選，不得留在程式碼。
- **共用 `.git/info/exclude` 被加了 `.dd/`、`.dd-ios/`**（服務層實作）：無害，irc-services worktree 移除時一併刪除，恢復環境。

## Bridge 復驗裁決（2026-10-14 20:35）

Bridge 復驗結論「要修正（小幅）」。fixture 等價性已獨立證明（MajsoulBridge 整檔退回 main 仍全綠，故意破壞會紅；71 情境，三麻 7 個）。報告：`.swfd/logs/irc-bridge/verify/report.md`。

- **BR-24 還原**：`Int(exactly:)` 讓 ±2^53 以上輸入由 0 變實值。原本的 0 是「不可信」語意，不是 bug，呼叫端（JS 關閉計數）實務不可達；無證據的行為改變一律還原，2^53 改具名常數保留可讀性。
- **BR-14 還原**：審查認為 `hasReceivedAuthGame`「只寫不讀」，但 syncGame 的 log 讀它，前提不成立。依「log 屬可觀察輸出」的一致標準還原，只留註解修正。取捨：診斷欄位少一個的損失不大，但標準不一致會讓之後每次都要重新爭論。
- **BR-01 error 判定改用既有共用邏輯**：原修正只看 field 1 存在；若成功回應帶空 error，會清掉 awaitingGameKind，讓三麻判定永遠學不到，等於修 bug 又引入回歸。改用全專案同一套 error 判斷（單一資料來源），找不到可共用者則停手列需要決策。
- **測試品質**：兩條測試數全域 `LogManager.entries`（上限 5000，滿額從頭刪）會因執行順序變紅，改數 fence 之後；寫死 `/tmp` 路徑改 temporaryDirectory。
- **已知缺口**：特性化 fixture 未涵蓋快照含副露、seat 未知、跨局 dora。
- **原則累積**：本輪三包都出現「建議改卻改行為」（Bridge Deviation 1／2、SV-18／20、BR-14／24）。之後派工的「建議改」一律要求逐條自證行為不變，復驗必做「行為改變逐條判定」。

## 服務層復驗裁決與整合策略（2026-10-14 21:10）

服務層復驗結論「要修正（小幅）」；報告 `.swfd/logs/irc-services/verify/report.md`。四包五步至此全部完成。

- **還原（無證據的行為改變）**：SV-27(1) 輪替判斷（改成 DateFormatter 解析後雙向改變，含 DST 缺口讓真實 session 永遠不刪）、SV-21 `reconnect_hint`（舊提示可用）、SV-24 Legacy domain 檢查（只影響不可達輸入，比照 BR-24）。
- **改歸 Bug 並補修前紅測試**：SV-19（來源標記與實際採用值矛盾）、SV-16（`logFileNote` 與保留規則不符）。
- **SV-23 收下為文件修正**：舊描述指的「回調未設定」狀態已不存在；與錯誤碼名詞不一致併入需要決策。
- **SV-05 接線列 WP-F2 合併後待辦**：`DebugServer.handleRequest` 傳 `boundPort: actualPort`，同時改 `testDebugServerCallsRequestGuardBeforeRouting` 的原始碼字串搜尋。**狀態：已於 WP-F2 合併時接線**，live 證據 `.swfd/logs/wp-f2-takeover/live-origin-9999.txt`。
- **整合策略**：四包各自在 7c2fe26 上驗證，經檢查沒有重疊檔案，但有語意交互（SV-17 的 `LiqiToolResult` 被 Bot／Bridge 呼叫）。取捨：不逐包 commit 後再 rebase，而是先在獨立整合樹以 `git apply` 套用四包並跑完整閘；通過後再依 `refactor:`／`fix:` 分組 commit。理由是逐包分別驗證抓不到交互，整合閘才是 commit 前的最後依據。
- **WP-F2 再度活動**：未提交檔由 17 增為 21，延後條目的判斷維持。

## 最終狀態（2026-10-14 21:20）

**整合樹**：`Naki-wt-irc-integrate`（分支 irc-integrate，基準 7c2fe26，未 commit）。報告：`.swfd/logs/irc-integrate/report.md`。

### 驗證層次

| 層次 | 結果 |
|---|---|
| 已修改 | 四包 72 檔（含新測試與 notes） |
| 已編譯 | macOS Debug、Release；iOS Naki-M Simulator |
| 已通過單元測試 | NakiTests 1074／0（基線 1028，新增 46）；warning 去重 6＝基線，新增 0；token 閘 7/7；xcstrings 399 keys 0 failures；MCP 工具數 40 |
| 修前紅 | 全部 Bug 修正皆有：BT-01～04、BR-01（含整合時補的 error 判定紅燈）、UI-01、SV-01、04、05、16、19 |
| 變異強化 | ui 11/11、bot 7/7＋復驗 2、bridge 25/26（1 等價，推測）、services 15/15＋SV-05 手工 3 |
| 已在模擬器驗證 | 無（只 ImageRenderer 離屏截圖，UI-01） |
| live 驗證 | 無（未啟動 App；replay-check.sh 需執行中 App，未跑） |

### 處理結果統計

| 組 | Bug 已修 | 建議改已做 | 已還原（無證據行為改變） | 列給用戶決策 | in-flight 延後 | 不做 |
|---|---|---|---|---|---|---|
| Bot | BT-01～04 | BT-08、09、11、14～19、21～24；BT-10／12／13 部分 | — | BT-05、06、07、20、25；BT-02 本輪送滿 5 次 | 0 | BT-26～33 |
| Bridge | BR-01 | BR-10～13、15～22、25；BR-12／21 部分 | BR-14、BR-24、實作 Deviation 1／2 | BR-02～09、BR-23 | 0 | BR-26～34 |
| 介面 | UI-01 | UI-10、11、13～16、25；UI-12 部分 | — | UI-05、07 | 22 條 | 可改可不改 |
| 服務 | SV-01、04、05、16、19 | SV-12～15、17、22、23、26、27(2)、34、36；SV-14／18／20 部分 | SV-18、20、21、24、27(1) | SV-07、08、09；SV-23 錯誤碼改名與 getGameSnapshot 非 optional；SV-20 quick test 開放規則欄位（候選） | 13 條 | SV-37～40 |

### 需要用戶決策（彙總）

- **Bot**：BT-05（forceHora 0 延遲與「固定時序是指紋」矛盾）、BT-06（兩條「過」送出路徑成功判準不同）、BT-07（confirmPending 期間漏收 ActionNewRound 的停滯風險）、BT-20（三麻 react 回 nil 時 provenance 重設）、BT-25（帶換行的 key／URL 修剪）、BT-02（斷線時本輪仍送滿 5 次才退避，與 CLAUDE.md「立刻停手」字面不符）。
- **Bridge**：BR-02（過的通道兩套推導）、BR-03（dora／doras 累加）、BR-04（ReqAuthGame 解析無讀取端）、BR-05（syncGame 重放累加回音）、BR-06（重連快照副露時 start_kyoku）、BR-07（加槓赤五推定）、BR-08（msgId 送出前登記不撤銷）、BR-09（錄影保留真實暱稱）、BR-23（default 記 degraded fault）。
- **介面**：UI-05（兩套雲端退化定義）、UI-07（debugServerPort 偏好與實際 port 合一）。
- **服務**：SV-07（Unknown tool 的錯誤形式）、SV-08（GameHighlightScript.make 刪除或共用）、SV-09（kan 無效輸入靜默忽略）、SV-23 剩餘（錯誤碼改名、getGameSnapshot 非 optional）、SV-20 候選（quick test 開放規則欄位，需改 inputSchema）。

### 延後與後續待辦

- **WP-F2 合併後**：SV-05 接線（`DebugServer.handleRequest` 傳 `boundPort: actualPort`，同改 `testDebugServerCallsRequestGuardBeforeRouting`；**狀態：已於 WP-F2 合併時接線**，live 證據 `.swfd/logs/wp-f2-takeover/live-origin-9999.txt`）；UI-12 剩餘；介面 22 條與服務 13 條 in-flight 條目。
- **下一輪**：`NativeBotController` 的模型名稱字面值改用 UI 包新增的常數；SV-17 遷移後移除 `AutoConfirmDispatcher` 已不可達的 `?? "unknown"`；BT-12 offline 字面值單一來源（跨 Bridge 與 Views）。
- **已知缺口**：Bridge 特性化 fixture 未涵蓋快照含副露、seat 未知、跨局 dora；變異 harness 只覆蓋比較／邏輯／三元運算子；`LiqiParserLearningTests` 子集紅不穩定（推測）。
- **未驗證**：所有 live 行為；BT-03 九種九牌端到端；BR-01 live 回應形狀；replay-check.sh。

### 耗用與異常

- 子代理約 30 個（審查 4、實作 4、清理 4、強化 4、復驗 4、復驗後修正 5、整合 1、巡檢若干）；模型 Opus 5.5（審查、復驗、整合）、Sonnet 5.5（實作、清理、強化、修正）、Haiku 5.5（巡檢）。
- 異常：Bridge 強化有一批超過 10 分鐘被自動轉背景；復驗報告寫檔三次被 harness 擋下（由主線存檔）；Bridge 復驗寫入共用 scratchpad 根目錄（查無覆寫）；服務層實作改了共用 `.git/info/exclude`；整合時 `git stash create` 留下一個無 ref 的物件 383d7c6（無害）；三包出現「建議改卻改行為」，已逐條還原或改歸 Bug。
