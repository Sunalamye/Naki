# 雲端推論實作決策紀錄（2026-08-04 起）

實作期間使用者授權「全部交給你完成；要問的一律做保守決定，事後寫文件說明為什麼」。
本文件就是那份說明：每一條都是**當下可以二選一、而我選了保守那邊**的決策，附理由。
實作結果見 [`cloud-inference-plan.md`](cloud-inference-plan.md)（已更新為 as-implemented）。

**D1 已於 2026-08-05 被使用者決策推翻並重做，見 D11**；D2–D10 仍然有效
（D9 的指紋比對已由 D11 的測試完成一半，詳見該條）。

## D1. ~~不做 `MahjongBot` protocol 大重構，改用 controller 內 overlay~~（已被 D11 取代）

**原計畫**（pluggable-bots-plan 第 1 層 + cloud-inference-plan 初稿）：抽
`MahjongBot` protocol、`BundledCoreMLBot` 包裝、`HybridBot` 裝飾器，
`NativeBotController` 只認得 `any MahjongBot`。

**實際**：protocol 不抽。雲端以 overlay 形式住在 `NativeBotController` 內：
決策點呼叫 `applyCloudOverrideIfNeeded`，成功覆蓋 `lastRecommendations`。

**為什麼**：
1. 讀完 851 行 `NativeBotController` 後確認它與 MortalBot 的 mask/probs API
   深耦合（`getLastMask`/`getLastProbs`/`inferCurrentState`、紅五索引 34–36、
   副露後以 `tehai` 合成 mask）。把這些搬進包裝層是對 App 心臟的大手術，
   回歸風險遠高於雲端功能本身的需要。
2. 雲端根本不需要那層抽象——它每個決策上傳**整局視窗**，不是逐事件轉發；
   批次化 `react`（原階段 2）對雲端也一樣用不到。
3. Akagi v3 本尊就是這個結構：雲端是 native bot 內的一種模式（`native.rs`
   的 `remote_decision`），不是平行引擎。照抄經過生產驗證的結構，比照抄
   自己文件裡未經驗證的抽象安全。
4. 關閉時零行為變化由構造保證：`cloudConfigProvider == nil`（Replay／單測）
   或 `isActive == false` 時 overlay 第一個 guard 就 return。

protocol 層仍是未來「換引擎」（macOS 子行程 bot）的正確做法，屆時再抽；
本次刻意不動。

## D2. 雲端決策的生效通道是 `lastRecommendations`，不是 react 的回傳值

讀碼發現自動打牌**不消費** `react()` 的回傳 dict（consumer 只拿它寫 log）；
真正的決策消費面是 `store.recommendations`＋伺服器 oplist（gate → resolver →
executor）。所以 overlay 只覆蓋 `lastRecommendations`——一條通道，
且所有既有 log 行零改動（AUDIT §17.3：log 格式一變，依賴它的工具全滅）。

## D3. 立直兩段式失敗＝整個決策退回本地（比 Akagi 更保守）

Akagi 第二段失敗時用「API 立直＋本地捨牌」拼裝。Naki 選擇：第二段拿不到
捨牌就**放棄整個雲端反應**，本地決策（可能不立直）原樣生效。理由：fallback
原則是「可以更弱，但必須是同一種東西」——完整的本地決策是同一種東西，
半雲半本地的拼裝不是。executor 的宣言牌取「清單順序第一個 discard」，
雲端捨牌插在第二列即無縫接上，不需要動 executor。

## D4. 不做 proxy 支援

Akagi 為 proxy 寫了 scheme 驗證＋「錯誤訊息絕不回顯 proxy 字串」的專門測試，
因為 proxy URL 常帶 `user:pass@host` 而錯誤訊息會進使用者附在 bug report 的
log。Naki v1 直接不做 proxy：少一整類洩漏面。要連內網自架伺服器不需要 proxy。

## D5. react 逾時固定 2.0s，不做 UI 旋鈕

計畫原文說「要從雀魂回合計時器扣掉自己的延遲模型再算」。實測預算沒有量測
資料（標未驗證），而 Akagi 的 2s 是生產環境驗過的值（立直兩段 2s×2 要擠進
~5s 回合）。保守選擇：沿用 2s 常數（`AkagiApiClient.reactTimeout`），不加
使用者旋鈕——本專案 §13 才剛移除過三組假控制，沒有量測依據的旋鈕不加。

## D6. `/v3/key` 額度查詢與 redeem／購買流程都不做

redeem／購買是使用者 2026-08-04 明確定案不做。`/v3/key`（方案/額度/到期）
是純顯示功能，v1 略過；額度撞牆時的行為已由斷路器＋eventLog 覆蓋
（429 會帶出 Retry-After）。之後要加是純增量。

## D7. API key 存 Keychain；log 只出現後四碼

`CloudKeyStore`（generic password，service `org.naki.cloud-inference`）。
所有 eventLog 只印 `key •••<後四碼>`；錯誤訊息來自伺服器 body 或
`URLError.localizedDescription`，皆不含 key。`/bot/status` 新增欄位只有
`decisionSource` 與 `cloudHost`，不含 key。

## D8. 局中途啟動不上傳殘缺流

視窗缺 `start_game` 或 `start_kyoku`（App 在對局中途才開）時
`hasUploadableWindow == false`，寧可整局本地也不上傳偽裝完整的殘缺事件流
——伺服器對不完整流的行為未知，null reaction 已有「事件流不同步」的警告
語意，不要主動製造。

## D9. 驗證的保守決定：不殺使用者正在跑的 Naki、不跑 live 對局

- 8765 上有一個使用者的 Naki instance（`build/Build/Products/Release`，
  改動前的舊 code，閒置中）。**沒有殺它**：改用它產出 replay 決策指紋
  baseline（`note/replay-baseline-pre-cloud-*.txt`，58＋32 個決策，
  指紋 `8089648fb9af18bb`／`6d31018603457caf`）。
- 新 binary 的指紋比對因此**未執行**（需要重啟 App，屬副作用）。下次以新
  build 啟動 Naki 後，一條指令完成驗證：

  ```bash
  scripts/replay-check.sh --session 20260803-013133 \
      --baseline note/replay-baseline-pre-cloud-20260803-013133.txt
  scripts/replay-check.sh --session 20260803-020246 \
      --baseline note/replay-baseline-pre-cloud-20260803-020246.txt
  ```

  預期：指紋完全相同（Replay 的 controller 沒有 `cloudConfigProvider`，
  雲端 code 一行不跑）。
- `soak-test.sh`（會送出遊戲動作）未跑——live 對局測試需要測試帳號上線，
  屬使用者授權範圍，保守不代跑。
- 未 commit（使用者指示保守）：全部改動留在 working tree。

## D10. iOS target（Naki-M）編譯未驗證

本機沒有 iOS 26 platform SDK（`xcodebuild -scheme Naki-M` 直接
destination 錯誤），Naki-M 編不了是**環境限制、先於本次改動**。共用的
`command/` 已在 macOS target 過編譯與測試；新增 code 只用跨平台 API
（SwiftUI GroupBox/SecureField、URLSession、Security）。仍標未驗證。

## D11. （2026-08-05，使用者決策）先抽 protocol、雲端重建在抽象上——推翻 D1

使用者看過 D1 的理由後明確指示：「改成先做到 protocol 抽象，然後再實作好我
需要的內容」。當日完成：

- **`MahjongBot` protocol**（`react(events:) -> BotReaction?` 批次介面、
  `identity`、`cloudHost`、`reset`）＋ `BotReaction{action?, recommendations,
  source}`。
- **`BundledCoreMLBot`**：MortalBot 專屬 API（mask/probs 掃描、
  `inferCurrentState`、副露 mask 合成）全部搬入；紅五 34–36 與索引解碼抽成
  **`MortalActionMapper`**（`AkaDiscardActionIndexTests` 跟著指向 mapper）。
- **`CloudBot`**：裝飾器持有 `local: any MahjongBot`——D1 擔心的「protocol 抽
  象漏 mask/probs」用**手牌 closure**解掉：手牌是遊戲狀態，權威留在
  `NativeBotController.updateInternalState`（UI/MCP 匯出讀同一份），引擎經
  `hand()` 只讀。controller 瘦身 ~250 行，只剩生命週期、遊戲狀態、世代守衛
  與 `BotReaction` 套用。
- **重構期間順手修掉一個 D1 版就存在的缺陷**：`resyncBot` 重放歷史事件時
  會對每個歷史決策重打雲端 API（N 決策 × 2s 預算＋額度純浪費）。現在
  `prepareForResyncReplay(eventCount:)` → `CloudBot.suppressCloud` 在重放
  期間只走本地。
- **驗證**：`ReplayFingerprintTests` 用改動前舊 Release binary 產的 baseline
  重放實錄，決策指紋 `6d31018603457caf`（230 事件、32 決策）**完全一致**——
  指紋計算不用 Swift 重寫，`Process` 跑 `replay-check.sh` 同一段 python，
  同源保證同格式。`CloudBotTests` 10 條整合測試（stub 引擎＋mock HTTP）蓋掉
  D1 版測不到的整條 overlay 流程。470 tests 全過、Debug/Release build 通過。

**D1 當時的風險評估如何被解決**：耦合最深的手牌依賴改成唯讀 closure 注入，
不搬狀態、不漏抽象；「protocol 對雲端沒必要」仍然是事實，但使用者要的是
架構位置正確（未來子行程引擎直接 conform），成本由指紋測試兜底。

## D12. 教訓：test host 啟動會吃掉 log 輪替額度，錄影 fixture 必須先備份

log 目錄保留 8 次啟動，而**跑一次 NakiTests 就是一次啟動**。2026-08-05 的
測試迭代把 `20260803-013133` 的實錄輪替掉了——那局的 baseline
（`8089648fb9af18bb`，58 決策）從此無法重放，指紋回歸只剩一局
（`020246`，32 決策）。倖存錄影已備份到 `note/replay-fixture-*.mjai.jsonl`
（note/ 不受輪替、gitignored 不進 repo——錄影含其他玩家暱稱），
`ReplayFingerprintTests` 優先讀備份。**之後每錄到值得當 fixture 的對局，
先 cp 進 note/ 再說。**

## D13. （2026-08-05 晚）三麻自動打：逐決策放行＋kita 全鏈

使用者定案「有開啟雲端推論就要可以自動打（三麻）」。實作取的條件比字面
更嚴：**逐決策**放行——`AutoPlayGate`／resolver／手動觸發只在「這批推薦
由雲端算出」（`decisionSource` 有 `cloud:` 前綴）時放行三麻；雲端失敗
fallback 到本地四麻模型的那一手**自動關回 fail-closed**。理由：三麻擋自動
打的根因是「本地四麻模型推三麻結構上無效」，這個根因在 fallback 的瞬間
仍然成立，設定層開關擋不住那幾手。唯一例外是局間自動確認
（`allowsConfirm`）跟著設定層走——按「下一局」不是模型決策。

同輪補齊拔北（kita）全鏈，否則三麻自動打會在拔北手停擺：
- **關鍵發現**：Naki bridge 的拔北事件名是 `nukidora`（ActionBaBei→mjai），
  伺服器 schema 是 `kita`——`KyokuStreamAccumulator.apiEvent` 加轉譯，
  不然三麻上傳流會 desync。bridge 本身不動（本地 MortalSwift 路徑與既有
  錄影都用 `nukidora`）。
- `ActionType.kita` ＋ mapper（reaction `kita`／candidate `nukidora`）＋
  resolver（oplist type 11 babei）＋ executor（`LiqiRequestBuilder.babei`，
  Liqi 層本來就齊）。
- UI：三麻警告只在「本批決策非雲端」時顯示（fallback 手警告如實回來）。

另補（同輪使用者需求）：雲端 HTTP **原始回應**落 botLog（debug 通道，
上限 2000 字）——摘要行只有前 6 列，伺服器給的 top-k 原始數值只有這裡
查得到。top-k 只有 3（伺服器方案 topk），prob 視覺校正未做（使用者未拍板）。

驗證：481 tests 全過（新增 gate×5、resolver×4、mapper/accumulator×3）；
**三麻 live 對局未驗**（AUDIT §20.2），要一局真三麻含拔北手才能蓋章。

## D14. （2026-08-05 深夜）顯示驗證管道：`POST /debug/ui`＋截圖迴圈

使用者要求「所有動作的顯示都看過一遍、你要能直接送指令、直接看」且**不開
真實對局**。做法：DEBUG-only 的 `POST /debug/ui`（直接寫 `GameStore`——純顯
示層注入，不碰決策管線；Release 查不到此路由，endpoint 表測試斷言這一點）
＋既有 `GET /screenshot`，agent 注入狀態→截圖→目視，一輪十幾秒。

這一輪掃出並修掉三個顯示問題、補一個增強：
1. **立直列顯示 raw「reach」**——riichi 推薦從不帶牌，卻走牌面分支 fallback
   成原始標籤；改走 `displayLabel`（顯示「立直」）。live 對局同樣會發生，
   是既有 bug 不是注入假象。
2. **雲端 3p 決策時模型行仍掛「⚠️ 三麻無專用模型」**——與下一行的
   `cloud:3p` 指示矛盾；後綴改為只在 `decisionSource` 非 cloud 時顯示
   （fallback 手警告如實回來）。
3. **可用動作徽章列沒有拔北**——補 `canKita`（oplist type 11），徽章只在
   三麻對局出現（四麻永遠不可能亮，常駐是噪音）。
4. **吃列增強**：`Recommendation.detail`（純顯示欄位，executor 不讀）——
   雲端 reaction 帶 consumed 時顯示「用 4m·5m 吃 3m」；本地 mask 只有粗變體
   ⇒ 維持 ①②③。「吃完丟哪張」不顯示：那是副露執行後的**下一個決策點**，
   模型屆時才會算（雲端/本地皆然），預先顯示等於偽造未來的決策。

## D15. （2026-08-05 深夜）三麻改雲端-only：本地模型連啟動都不啟動

live 三麻首戰揭露的病理（events.log 20260805-230638）：本地 4p 模型推三麻
會**幻覺出吃窗口**（三麻沒有吃、伺服器也沒授權），CloudBot 把幻覺當決策點
問伺服器 → null reaction ×3；一次真決策（拔北）在脫節時序下被伺服器
靜默丟單，22 秒後逾時代打、watchdog 重連自救。拔北鏈本身多次成功
（23:12:17×2、23:14:07、23:20:59、23:21:42——live 首驗通過）。

使用者定案：「三麻不應該送本地的」「本地就沒有三麻，就不應該啟動本地的」。
實作：

- `CloudBot.local` 改為 optional；三麻時 `NativeBotController.createBot`
  **不建 `BundledCoreMLBot`**（MortalBot/Core ML 完全不載），bot =
  `CloudBot(local: nil)`。
- 雲端-only 的決策點改由**伺服器授權驅動**：事件上的
  `MJAIEventKey.oplistSequence` 每批恰觸發一次雲端呼叫（同授權 pending
  期間不重複），`serverAuthorization`（pending 非 nil）擋 autopass 競態。
  幻覺窗口從根拔除——沒有本地就沒有幻覺。
- 雲端失敗／null＝**本手誠實沒有推薦**（不會有結構無效的本地輸出頂上）；
  三麻閘門本來就不送非雲端決策，行為一致。
- UI 同步：三麻 modelName=`cloud-3p`（「雲端推論 (3P)」），未生效時後綴
  「⚠️ 未生效，無推論」；SanmaUnsupportedNotice 文案改「三麻僅雲端推論」。
- null reaction 的警告行現在附**上傳尾巴**（最後 6 個事件），真脫節可直接定位。

**自動發現**（在使用者發現前）：`scripts/cloud-watch.sh` 監看 events.log，
命中「null reaction／雲端失敗／強制重連／送出後 15 秒停滯」即發 macOS 通知；
agent session 側另掛 Monitor 同步喚醒查因。

驗證狀態：code 完成、**尚未 build**（使用者對局中，明令不 build）；
待對局結束跑全測試（新增雲端-only ×3）＋rebuild＋重啟。

## D16. （2026-08-05 深夜）422 事故：重連 reset 歸零 seat——雲端當了偵錯器

Monitor 上線 36 分鐘就抓到第一起真事故：四麻局全程 HTTP 422
（"could not process event stream"），斷路器 5s→80s 一路退避。

**病理**：`MajsoulBridge.reset()`（局中重連路徑）把 `seat` 歸零但只保留
accountId；syncGame 重連不會再送 seatList，seat 永遠恢復不了。之後每個
新 kyoku 的 `parseNewRound` 把自家手牌放到 `tehais[0]`（實際座位 2）——
伺服器看到「seat 2 憑空打未知牌、seat 0 抱 13 張不動」如實 422 拒收整局；
**本地模型吃同一份壞手牌，退化成摸切（1 item @100%）**。

**這是先於雲端接入的既有 bug**：純本地時代重連後的 kyoku 推薦一直是壞的，
只是本地不會「拒收」、壞得無聲。雲端的 422 第一次把它變成可見、可定位
（Monitor 通知 → events/bridge log 對時 → parseNewRound 的 seat=0 一行）。

**修法**：reset() 保留 seat／is3P（重連回同一局，座位不可能變）；換帳號
／換對局的歸零由 fullReset()＋authGame 負責。當下救援：重載頁面
（fullReset → authGame 重發 seatList）。

**取捨**：不做「resync 時從 eventStream.getPlayerId() 再導 seat」的第二層
防護——單一來源原則，保留就夠；再加一條推導路徑反而製造兩個權威。

## D17. （2026-08-06）fallback 可視化：紅色退化警示＋連續手數

使用者需求：「如果失敗了，我需要知道現在是用 rollback 的本地模型」。
原本的揭露只有雲端行小字從 `(cloud:模型)` 變 `(local)`——對局中根本不會注意到。

設計＝把「退化」變成一級狀態：

- `CloudBot` 新增 `cloudDegraded`（斷路器不健康或退避中）與
  `cloudFallbackStreak`（雲端啟用下**連續**非雲端決策數；成功歸零、
  改設定歸零、未設定恆 0——「沒開雲端」不是 fallback，不該掛警示）。
  經 `MahjongBot` protocol 曝露（extension 預設 false/0，本地引擎零負擔）。
- UI：雲端行三態——正常橙色「送往 host（cloud:模型）」；退化時整行轉
  **紅色 `icloud.slash` 警示框**「雲端失敗——正在用本地模型（連續 N 手，
  自動重試中）」；三麻文案改「本手無推薦（三麻不用本地）」。
- `/bot/status` 增 `cloudDegraded`／`cloudFallbackStreak`（cloud-watch 與
  agent 監看可機讀）；`/debug/ui` 可注入這兩欄供顯示驗證。

取捨：不做 toast／彈窗——桌面通知已由 cloud-watch 負責（app 內再彈是雙重
打擾）；常駐紅框比一次性通知更符合「這個狀態會持續一段時間」的性質。

狀態：code＋測試就緒，**未 build**（使用者對局中）；待對局結束驗證
＋ /debug/ui 截圖確認紅框視覺。

## D18. （2026-08-06）送出驗證加第 3 層：伺服器受理 ≠ 伺服器執行

live 事故：東家開局第一打，`sendRaw` 成功、RESPONSE 無 error（**現有兩層驗證
全綠**），伺服器卻 16 秒沒動作，最後是使用者自己點才打出去。同一局其他 59 次
送出的權威回音都在 1 秒內——只有這次掉。

**設計上的真正問題**：成功的定義錯了。原本「送出成功」＝socket 收下＋RESPONSE
無 error，這兩件事都只證明**請求送達**，不證明**動作發生**。改成以伺服器廣播
我方動作（`ActionDiscardTile`／`ActionChiPengGang`／`ActionBaBei`／…中
`actor == 自家座位` 的那則）為準：**沒有權威回音就不算成功、不消化 oplist**，
交由既有重試框架重送。

- `SelfActionEchoTracker`（單調計數）＋ `SelfActionEchoObserving`（單測可 stub）。
  寫入點在 `MajsoulBridge.parse`——唯一同時知道事件內容與自家座位的地方。
- baseline 在送出**前**取，否則會把別批回音算成自己的。
- 不會雙送：重試框架每次重送前重驗 `isStillValid`，動作若其實已生效，
  oplist 早已換批而停手。
- 「過」跳過這層：伺服器不為 cancel 廣播我方 action，等它必然逾時。
- 700ms 門檻來自實測（正常 < 100ms、丟單 16 秒），差距大到不需要精算。

**取捨**：不做「開局第一手多等 2.5 秒」那種延遲式繞法——它只賭時序、治不了
其他時點的丟單，而且每局都付延遲。這層是通用的，也同時涵蓋 2026-08-05 那次
拔北丟單。

偵測面：`⚠️ … 沒有權威回音（疑似丟單）` 進 events.log，cloud-watch 命中即發
macOS 通知——同一類事故下次會自己現形。

## D19. （2026-08-06）雲端 prob 是「攤在幾個選項上」，不是信心度

側欄常常整排只有 12–13%，看起來像 AI 沒把握。**不是**——那是分母。

伺服器只回 top-3，但機率攤在**所有合法動作**上。實測 143 次回應（4p-akg-v8）：

| reaction | n | 最高 prob 中位 | 為什麼 |
|---|---|---|---|
| dahai | 113 | 0.133 | 攤在 13–14 張可打的牌上；均勻是 0.077 |
| none／pon／chi | 28 | 0.56 | 只有 2 個選項，兩者相加剛好 1.0 |
| hora | 1 | 0.958 | 該和就和 |

dahai 的最高 prob 也出現過 1.000。所以低數字＝那一手真的沒有明顯好壞，
不是模型無能。**不要拿數字大小比較雲端與本地誰強**：本地 Mortal 顯示 12 列、
常見 30%+，那是 softmax 溫度不同造成的顯示差異，能比的只有「它選了哪張」。

## D20. （2026-08-06）不做「近似平手就隨機」

提案：top-3 的 prob 互相在 2 個百分點內時，隨機挑一個送出。**使用者當場撤回，
不實作**。這裡記的是**如果將來要撿回來，該知道什麼**：

- **接線點只有一處**：`NativeBotController` 存 `lastRecommendations` 的那一行。
  它同時決定側欄顯示與自動送出（`recommendations.first`），動這一處兩邊才會一致；
  動 resolver 會讓「畫面顯示的」與「實際打的」不同，那是更糟的設計。
- **必須照 `cloudConfigProvider` 的注入模式**：Replay／單測不注入 ⇒ 不隨機，
  `replay-check.sh` 與 `ReplayFingerprintTests` 的決策指紋才不會被打壞。
  直接在推薦產生處塞 `Bool.random()` 會讓回歸測試變成擲骰子。
- **本質限制**：伺服器只回 top-3，所以只看得見這三個是否平手；第 4 名以後
  是否也在 2pp 內**無從得知**。門檻再怎麼調都繞不過這一點。
- **代價無法量化**：prob 差 0.9pp 對應多少 EV 差取決於伺服器的 softmax 溫度，
  而溫度沒有公開。宣稱「反正差不多，隨機不虧」是沒有依據的。
