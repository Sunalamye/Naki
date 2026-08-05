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
