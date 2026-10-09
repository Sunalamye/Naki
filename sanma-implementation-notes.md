# 三麻本地推論（Akagi native_bot 移植）＋ Akagi 同步調整 — implementation notes

日期：2026-10-09。Naki 基準：`4e92764`（v2.14.0）。Akagi 基準：`cd68865`（v3.7.1，2026-09-29）。

## 目標

1. **三麻本地推論**：把 Akagi `native_bot/`（Rust、Apache 2.0、自帶 `weights/akagi3p.safetensors`）編成 xcframework，包成 Swift package，接進 Naki 的 `MahjongBot` protocol，讓三麻在雲端不可用時仍有推薦與自動送出。
2. **Akagi 同步調整**（2026-10-09 比對結論，見專案記憶 `akagi-sync-baseline`）：
   - `docs/protocol/liqi.json` 的 `ReqSelfOperation` 補 `auto_operation`（bool, id 11）。
   - `AkagiApiClient.reactTimeout` 2 秒 → 3 秒（Akagi #265 預設值）。
3. 不做：點擊式送出（使用者 2026-10-09 決定不做）、iOS 專屬功能（package 仍要能編 iOS，否則 Naki iOS target 會壞）。

## 設計決策

- **路線（使用者定案 2026-10-09）：純 Swift，產品零 Rust 依賴。** 原提案的 Rust→xcframework 路線已放棄（S0 spike 在 vendor 階段停止，殘留搬到 scratchpad）。
- **要移植的 Rust 模組**（Akagi `native_bot/src/`）：`tiles.rs`（27 格索引、赤五、寶牌下一張含三麻 1m→9m 環）、`obs.rs`＋`adapt.rs`（37×27 觀測）、`action_codec.rs`（60 動作空間、legal mask、logit→動作含赤五不丟寶牌規則）、`model.rs`（Conv1d 37→64 k3、3 個殘差塊、FC 1728→256、head →60，BN 已折疊）、`engine.rs` 的決策流程（含立直二段 `predict_reach_discard_3p`）。`riichienv-core` 的三麻狀態機**不整個移植**：
  - **合法動作來源改用伺服器 oplist**（Naki 本來就以 `LiqiOperationStore` 為權威），映射到 60 格 mask；不重做役判定。
  - 觀測需要的狀態（手牌、各家捨牌／副露／立直／立直宣言牌／分數／拔北數、最後捨牌、場風自風、本場、供託、巡目、聽牌與待牌、寶牌）由一個精簡的 `SanmaState` 從 MJAI 事件追蹤；聽牌與待牌用 MortalSwift 既有的 `Shanten`（34 格表對三麻子集仍正確）。
- **推論**：純 Swift＋Accelerate（vDSP）直接做 Conv1d／Linear，權重從 `akagi3p.safetensors`（2.1 MB，自寫極小 safetensors 讀取）載入。不走 Core ML：模型只有約 270 萬 MAC，單次推論在 1 ms 等級，而且 Akagi 附的 `parity_3p.json`（obs→logits 數值 fixtures）可以直接驗 Swift 推論與 candle 一致。
- **奇偶性驗證**：Rust 只在開發機離線用一次——寫一支不進 repo 的 Rust 工具，把三麻 MJAI 事件流餵 `native_bot::Engine`，逐決策點 dump 觀測張量、mask、logits、動作成 JSON fixtures 提交；Swift 測試只對 fixtures，不帶任何 Rust 產物（與 MortalSwift 掛 xcframework 當 oracle 的做法不同，更乾淨）。三麻事件流來源：S0 查 `riichienv-core` 能否自走隨機合法對局產 mjai log，否則用 Akagi train 流程的天鳳三麻 log 轉換。
- **放哪裡（使用者定案 2026-10-09）**：MortalSwift 新 target `AkagiSanma`（worktree `MortalSwift-wt/akagi-sanma`，branch `feat/akagi-sanma`）。MortalSwift 版本升 0.6.0，Naki 的 `Package.resolved` 跟著 commit。
- **A1**：已驗證（liqi.json 只多 `auto_operation`、`reactTimeout` 3 秒、NakiTests 734 全過），使用者決定**先不 commit**，留在 worktree `Naki-wt/a1-akagi-sync`。
- **接線**：三麻改為 `CloudBot(local: AkagiSanmaBot, …)`，與四麻 `CloudBot(local: BundledCoreMLBot)` 同形。雲端可用時仍以雲端為準，本地只在雲端退化時接手。這**推翻 D15**「三麻不啟動本地模型」——D15 的理由是四麻模型推三麻會幻覺，現在本地是真三麻模型，理由不再成立。
- **強度標示**：Akagi 自述「default strength」（模仿天鳳人類）。`BotIdentity.displayName` 與設定頁必須寫明，不得寫成 Mortal 等級。
- **MJAI 事件**：Naki bridge 送的是 `nukidora`，引擎吃 `kita`；`feed_line` 內建 `normalize_line` 會轉。4 座位陣列由 `sanitize_3p` 截 3。Naki 端不另做轉換。
- **立直兩段**：引擎的 `Decision.action` 若是 `Reach` 已帶 `pai`；`CloudBot` 既有的立直二段邏輯沿用。

## S0 結果與 codex 審查（2026-10-09）

S0（純 Swift）：`SanmaTiles`／`SanmaModel`／`SanmaActionCodec`／`SanmaObs` 完成，18 個 XCTest 全過；模型對 `parity_3p.json` 最大 |Δ| 1.5e-5、argmax 54；obs encoder 對 3 組 Rust `EncInput::encode` 黃金樣本逐值相等；release forward 0.12 ms。證據 `.swfd/logs/s0-sanma-spike/`。riichienv-core 0.4.8 可自走三麻對局並輸出 mjai log（smoke：seed 42、705 事件）。

codex 審查（`.swfd/logs/s0-sanma-spike/codex-review.md`）判定 **BLOCK S1**：核心運算可保留，但 (1) MJAI→`SanmaState`→`EncInput` 的 adapter 未做；(2) 「oplist 直接當合法集合」在立直後摸切、立直二段、pass 合成、搶槓 context tile、forced 判定上會與 riichienv 不等價；(3) 現有 fixtures 不是逐事件 dump；(4) `turn_count`、被叫走的捨牌是否保留、riichi tile 時機、reach 前後分數時機要用 Rust fixture 固定答案。

**採納後的設計修正（統帥代決）**：
- 合法動作改為「**Swift 自算實體動作、伺服器 oplist 做授權閘**」：`SanmaState` 移植 riichienv `GameState3P` mjai 重播路徑的狀態與**實體**合法動作列舉（捨牌含立直後摸切限制、碰／槓組合、拔北、立直候選），和牌／立直／副露／拔北／九種九牌是否允許以 oplist 為準，pass 只在回應窗口合成。`forced` 以實體動作數判定。
- 立直二段：clone `SanmaState`、套用 reach、重編碼、第二次 forward（對應 `predict_reach_discard_3p`）。
- 奇偶性：Rust 產生器（scratchpad，不進 repo）用**偏好策略**自走多個 seed，逐決策點 dump 原始 MJAI、obs、實體合法動作、60 mask、logits、排名、forced、最終動作，附 provenance（Akagi commit、riichienv 版本、權重 sha256、規則）。Swift 測試逐欄比對。真實 oplist 與 MJAI 同步的 fixtures 只能來自 live 三麻對局，接線前標「未 live 驗證」。
- 計畫中的 Rust FFI／C API 段落作廢（下方保留標記為作廢）。

## C API（作廢：Rust 路線已放棄，僅留紀錄）

```
nb_engine_t* nb_engine_new(uint8_t num_players, uint8_t seat);   // 內嵌權重
void nb_engine_free(nb_engine_t*);
void nb_engine_reset(nb_engine_t*);
void nb_engine_set_seat(nb_engine_t*, uint8_t seat);
bool nb_engine_feed_line(nb_engine_t*, const char* json_line);
char* nb_engine_decide(nb_engine_t*);   // JSON 或 NULL；呼叫端用 nb_string_free 釋放
char* nb_engine_reach_discard(nb_engine_t*);
void nb_string_free(char*);
```

`decide` 回傳 JSON：`{"action":<mjai dict>,"candidates":[{"action":…,"prob":…}],"forced":bool}`。

## 工作包

| 包 | 範圍 | 路由 | 狀態 |
|---|---|---|---|
| S0（Rust FFI） | 作廢：使用者定案零 Rust 依賴，vendor 階段停止 | — | 作廢 |
| S0 spike（純 Swift） | MortalSwift target `AkagiSanma`：tiles／model／action codec／obs 佈局 | Opus medium | 完成，18 tests |
| codex 審查 | 審計畫與 S0 | codex | 完成，BLOCK S1 → 設計修正已採納 |
| S1a | Rust 產生器（scratchpad）：13 seed × 2 座位、1985 筆決策、`state-semantics.md` 十條事實 | Sonnet medium | 完成 |
| S1b | `SanmaState`、`SanmaLegal`、`SanmaAdapt`、`SanmaEngine`（立直二段、授權閘）；60 tests；fixture 1985 筆逐欄一致（logits |Δ| ≤1.5e-5）；手工變異 88 殺 85、3 等價 | Opus medium | 完成、復驗通過（修 2 處）、**使用者決定先不 commit** |
| S1b 復驗 | 宣稱全部屬實；找出空 `consumed` 槓越界 trap、他家摸 `?` 留下假 1m，已修 | Opus medium | 完成 |
| S2 | Naki：`AkagiSanmaBot: MahjongBot`、三麻 `CloudBot(local:)`、`cloudDecision`→`sanmaCapableDecision`、D23 文件、20 條新測試；macOS／iOS build 成功、NakiTests 754、手工變異 44 殺 43 餘 1 等價 | Sonnet medium | 實作完成，復驗中（Opus） |
| M1 | `48add0a..d0072fa` 的 Bot／Bridge 改動（25 檔）in-diff 手工變異，存活補測試；產出 `scripts/mutate.py` | Sonnet medium | 進行中（worktree `Naki-wt/m1-mutation`） |

S1 關鍵事實（S1a 證實、S1b 依此實作）：Akagi 引擎重播路徑上 `turn_count` 恆 0、`riichi_sutehais` 恆 None，對應 4 個觀測面恆 0；`last_discard` 只有 dahai 設定、搶槓開窗時改為被搶牌；被叫走的捨牌保留在河；`reach_accepted` 才扣分；waits 純形狀且只在 13 張時計算。muter 16 對含中文註解的 Swift 檔不可信（位移錯、變異體未真正套用），改用手工 harness `mutate.py`。

S1c 待辦（codex 第 2、3 條）：oplist 與實體動作的**逐組合**對應（碰／槓 consumed、立直可宣言牌），在 S2 接線時處理或列為後續。

**S2 的開發期偏離（統帥代決）**：MortalSwift 的 `AkagiSanma` 未 commit、未發版，S2 在 Naki worktree 把 MortalSwift 套件引用暫改為**本地路徑** `../../MortalSwift-wt/akagi-sanma`，以便編譯與測試。最終 commit 前必須：MortalSwift commit → 升 0.6.0 → push → tag（需使用者授權）→ Naki 恢復遠端引用並更新 `Package.resolved`。
| A1 | Naki：`liqi.json` 補欄、`reactTimeout` 3 秒、CLAUDE.md 連動一句 | Sonnet low | 完成；commit `d0072fa` 已 ff 合進 main（統帥代決，使用者授權「後面都自動判斷」）；worktree 已移除 |

S1 的 MortalSwift commit：`04bcdf6`（branch `feat/akagi-sanma`，worktree `MortalSwift-wt/akagi-sanma`），未 push、未 tag。

## S2 之後的排程（使用者 2026-10-09 補充指示：未驗證項測完整、M0 全程式碼變異復驗跑完）

1. S3 live 三麻 smoke：測試帳號開三人友人房＋人機一局，驗本地推薦、拔北、和牌送出鏈路；雲端關閉時本地接手。
2. M 系列：`48add0a..HEAD` 邏輯檔用手工變異 harness（`.swfd/logs/s1b-sanma-state/mutation/mutate.py` 改成 xcodebuild 版）逐檔跑，改動內存活補測試；範圍外列清單。
3. S1c：oplist 逐組合對應（若 S2 未涵蓋）。

## U 系列（UI 修正包）

### 可見行為變化

- 到期時間改隨 locale 格式。
- 測試連線結果改每次重繪產生，隨開關與語言更新。
- 限額欄改整句 key。
- 插件頁 log 格式改「HH:mm:ss.SSS 訊息」，不含日期與分類。
- 插件狀態點改 SF Symbol。
- 日誌搜尋改 `localizedStandardContains`。
- macOS 重新載入鈕改 `primaryAction`。
- 延遲顯示「1.0 秒」最小寬 40。
- 決策面板寬 300–480，可拖。
- 警示字級改 caption。
- iOS 面板：regular 300pt；compact 寬＋regular 高啟動即收起；控制列 44pt；Reduce Motion 時淡入淡出。
- 全自動表與 ServerPicker 可捲動，按鈕列固定在底部。
- iOS 完成鈕改 `confirmationAction`。
- 不以顏色區分時，MCP 狀態點畫符號。

### 復驗殘留（未處理）

- 8 處 `clipShape(RoundedRectangle)` 寫法不一致。
- LogPanel 的 Picker 標題為空。
- 五個新 Action 未標 `@MainActor`（app target 預設隔離，功能不受影響）。
- iPad 執行中改分割不會重新判斷面板。

## Deviations

- **S2 復驗（2026-10-09）**：裁決「要修正」。存活變異體 `NativeBotController.swift:159`（`serverAuthorization` 閉包）不是等價而是測試缺口——雲端啟用後三麻每手都不會問雲端且無提示；本家槓後嶺上摸牌前仍回捨牌（stale guard 不擋 nil provenance）；局間確認與續局仍寫死「三麻只有雲端」；強度標示未上 UI；新文案未進 xcstrings；多處註解仍寫雲端-only。全部交回 S2 修正。
- **局間確認／續局的三麻條件（統帥代決）**：由 `cloudInferenceActive` 改為「bot identity 支援三麻」（雲端 3p 或本地 Akagi），與 D23 一致。理由：原條件的依據「本地排進去也不會出手」已不成立。
- **合併時序（統帥代決）**：S2 可在 branch `wp/s2-sanma` commit，但**不得合進 main**，直到 MortalSwift `feat/akagi-sanma` 升 0.6.0、push、tag（需使用者授權）並把 Naki 套件引用改回遠端、重產 `Package.resolved`。原因：目前 pbxproj 是本地路徑引用，clean clone 會編不過。

S2（2026-10-09）：
- 套件引用暫改本地路徑（統帥代決，見上）；`Package.resolved` 因此少了 mortalswift 的遠端 pin，恢復遠端引用時要重新解析並一起 commit。
- `sanma-implementation-notes.md` 在主 repo 是未追蹤檔，worktree 內沒有，S2 複製一份到 worktree 後修改。
- 授權類別沒有 `.hora`：引擎的 `Kind` 分 `tsumo`／`ron`，所以 oplist tsumo→`.tsumo`、ron→`.ron`；minkan→`.daiminkan`。
- `cloudDecision` 更名 `sanmaCapableDecision`（gate／resolver／engine／NakiRuntime／測試全改）；`BotStatus` 新增 `isSanmaCapableDecision`，`isCloudDecision` 保留。
- 範圍外但必要的小改：`GameModels.swift`（新屬性、`modelDisplayKey` 三麻引擎不標警告）、`DecisionSidebar.swift`（警告條件改用新屬性、文案改為「三麻尚無推薦…」）。`Localizable.xcstrings` 沒改，舊文案「三麻僅雲端推論…」與「雲端推論 (3P)」變成無用 key，新文案沒有翻譯。
- 授權由 `AkagiSanmaBot` 注入 `snapshot` 閉包（非 `authorization` 閉包），映射函式 `authorizedKinds` 為 static 以便單測。
- 無雲端設定來源（Replay／單測）時三麻 bot 就是 `AkagiSanmaBot` 本身，與四麻同形。
- `CloudBot` identity：`supports3P` 改為本地引擎或雲端 `model3P` 任一成立。
- `scripts/replay-check.sh` 需要連到執行中的 Naki App（port 8765 是他人的 App，且不是 worktree 的 build），按規定未執行；改以 `ReplayFingerprintTests`（進程內、對照 baseline）驗四麻決策指紋不變。
- 原判為等價的 `serverAuthorization` 閉包變異（`==`→`!=`）經復驗證明不等價（雲端啟用時授權為真才會問雲端）；已補 `testSanmaCloudConsultedForCurrentAuthorization` 與四麻同形的 `testYonmaCloudConsultedForCurrentAuthorization`，兩處變異皆被殺。
- 復驗後修正（同一 worktree、未 commit）：
  - 自家 ankan／kakan／daiminkan 事件回 nil：槓事件沒有 oplist seq，stale guard 擋不住，嶺上牌到達前的捨牌建議沒看過新牌（偏離原計畫「只有 isMyPon 特例」）。
  - 局間確認（`AutoPlayGate.allowsConfirm`）與續局（`AutoRematchEngine`）的三麻條件由「雲端推論啟用」改為「目前引擎支援三麻」（`NativeBotController.supports3P`：雲端 3p 或本地 Akagi 三麻）。參數 `cloudInferenceActive` 更名 `sanmaEngineAvailable`，outcome `sanmaWithoutCloud` 更名 `sanmaEngineMissing`（統帥代決）。
  - `AkagiSanmaBot` 建構失敗時 `createBot` 退回 `CloudBot(local: nil)` 並寫 log，不讓三麻整個起不來；以 `NativeBotController.makeSanmaLocal` 作測試縫。此時 `supports3P` 只看雲端 `model3P`。
  - 側欄模型名：三麻本地顯示「Akagi 三麻・default strength」，雲端算的那一手顯示「雲端推論 (3P)」，雲端-only 退路未生效時加警示。新增三個文案四語（en／ja／ko／zh-Hans）為模型翻譯，**未經母語校對**；刪除兩個無用 key（舊側欄警告、舊續局訊息）。「雲端推論 (3P)」與其「未生效」變體仍在用，保留。
  - 第 7 項（已改）：原列為範圍外的陳舊句子：`SettingsStore.swift:361`、`ContentView.swift:1894`（及其字串 key「雲端推論未啟用，三麻不會排隊…」與「三麻提醒：…」「雲端失敗——本手無推薦（三麻不用本地…）」）、`MajsoulBridge.swift:821`、`docs/majsoul-unity-protocol.md:27/:327`。

## 驗證

- 初版：macOS／iOS build 成功；`NakiTests` 754 passed；變異 44 殺 43、存活 1（後證明不等價，已補測試）。
- 復驗修正後：`NakiTests` 760 passed、macOS Release／iOS Simulator build 成功（第 7 項後 Debug build 與 760 tests 再過一次，`test-full-fix3.log`）；新改分支變異 29 殺 29，結果 `.swfd/logs/s2-sanma/mutation/fix/results.jsonl`）。
- 未驗證：live 三麻對局（本地推薦、拔北、和牌送出、雲端關閉時接手）；碰／槓 consumed 與赤五 copy 逐組合對應；立直宣言牌與 oplist 比對；pending 在決策事件到達時一定已寫入的時序（只從程式碼閱讀得出：`MajsoulBridge.parseAction` 先 `recordOperationSnapshot` 再產生事件）。
