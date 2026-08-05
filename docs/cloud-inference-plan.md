# 雲端推論接入設計（Akagi `/v3/react`）

**定案日期**：2026-08-04；**同日實作完成**（見下方「實作狀態」與
[`cloud-inference-decisions.md`](cloud-inference-decisions.md) 的偏差說明）
**協定參考**：[`reference/akagi-inference-api.md`](reference/akagi-inference-api.md)（含 2026-08-04 補充節）
**上位計畫**：[`pluggable-bots-plan.md`](pluggable-bots-plan.md) — 本文件是其「換模型」層（第二層）的具體設計，依該計畫的順序修正，排在「換引擎」（子行程）之前實作。

## 實作狀態（2026-08-05 protocol 版）

2026-08-04 先以 controller 內 overlay 落地（decisions D1）；2026-08-05 使用者
決策推翻 D1，改為 **`MahjongBot` protocol 抽象＋`CloudBot` 裝飾器**（decisions
**D11**，含與初稿 HybridBot 的差異：手牌經唯讀 closure 注入而不搬狀態）。
現行架構：

```
NakiWebCoordinator → NativeBotController（遊戲狀態＋世代守衛，持有 any MahjongBot）
                        └─ CloudBot（裝飾器：視窗/斷路器/立直兩段/重放抑制）
                             └─ BundledCoreMLBot（MortalSwift + Core ML；
                                  mask 解碼在 MortalActionMapper）
```

落地檔案（`command/`）：

| 檔案 | 職責 |
|------|------|
| `Services/Bot/MahjongBot.swift` | protocol（`react(events:)` 批次）＋`BotReaction`＋`BotIdentity` |
| `Services/Bot/BundledCoreMLBot.swift` | 內建引擎：MortalBot 專屬 API 全在此（mask/probs、副露特例）|
| `Services/Bot/MortalActionMapper.swift` | action space 46 格解碼（含紅五 34–36），`AkaDiscardActionIndexTests` 的對象 |
| `Services/Bot/CloudBot.swift` | 雲端裝飾器：本地閘門、覆蓋、fallback、立直兩段、重連重放抑制 |
| `Services/Bot/KyokuStreamAccumulator.swift` | per-kyoku 視窗＋API 塑形（剝內部欄位、裸 reach、三麻補位）|
| `Services/Bot/CloudBreaker.swift` | 5s→120s 指數退避斷路器 |
| `Services/Bot/AkagiApiClient.swift` | `/v3/react`（2s）＋`/healthz`、`/v3/models`（8s）；key 只進 header |
| `Services/Bot/CloudDecisionMapper.swift` | reaction＋candidates → `[Recommendation]`（含 chi 變體、立直捨牌插列、pass 列）|
| `Services/Bot/CloudInferenceConfig.swift` | 設定值快照（Equatable，變更偵測）|
| `Services/Bot/CloudKeyStore.swift` | API key 的 Keychain 存取 |
| `NativeBotController.swift`（改）| 持有 `any MahjongBot`；遊戲狀態、世代守衛、`BotReaction` 套用、`decisionSource` |
| `SettingsStore.swift`（改）| `naki.cloud.*` 欄位＋`cloudConfig` 快照 |
| `ContentView.swift`（改）| 「雲端推論」GroupBox＋測試連線（healthz＋models）|
| `BotStatusView.swift`（改）| 常駐「對局資料送往 \<host\>」指示 |
| `NakiRuntime.swift`（改）| `cloudConfigProvider` 接線（唯一注入點）|
| `NakiMCPDependencies.swift`（改）| `/bot/status` 增 `decisionSource`/`cloudHost` |
| `NakiTests/CloudInferenceTests.swift`（新）| 28 個元件測試（Akagi 測試清單移植）|
| `NakiTests/CloudBotTests.swift`（新）| 10 個裝飾器整合測試（stub 引擎＋mock HTTP）|
| `NakiTests/ReplayFingerprintTests.swift`（新）| 決策指紋回歸：重放實錄 vs 舊 binary baseline |

驗證狀態：

| 項目 | 狀態 |
|------|------|
| macOS Debug／Release build | ✅ 通過（2026-08-05）|
| NakiTests 全迴歸（470 tests，含新增 40）| ✅ 全數通過 |
| replay 決策指紋 vs 改動前舊 binary | ✅ **一致**（`6d31018603457caf`，230 事件/32 決策；另一局 fixture 遺失，見 decisions D12）|
| CloudBot overlay 全路徑（閘門/覆蓋/fallback/兩段/抑制）| ✅ 整合測試通過（mock HTTP）|
| 雲端 live 對局（真 server＋真 key）| ✅ 2026-08-05 晚間驗證通過（4p-akg-v8 連續決策、重放抑制實際觸發；詳見 AUDIT §20.1）|
| 立直兩段式 live 時序 | ❌ 未驗證 |
| iOS target（Naki-M）編譯 | ❌ 本機無 iOS 26 SDK，環境性未驗證（decisions D10）|

## 範圍（已定案）

- **做**：`POST /v3/react` 決策代理、`GET /healthz` 對局前健康檢查、`GET /v3/models` 模型清單。`GET /v3/key`（額度顯示）可選、後補。
- **不做**：`/v3/redeem` 兌換與整套購買流程（PayPal handshake）。**key 由使用者自行取得後貼上**。（2026-08-04 使用者定案）
- server 不限定：官方（`https://mjapi.shinkuan.me`）或自架皆可，client 只認 URL + key。自架最小集合是 `/react` 一個端點。

## 現況缺口（2026-08-04 盤點）

| 缺口 | 位置 |
|------|------|
| 無推論抽象層，直接持有具體型別 `MortalBot?` | `command/Services/Bot/NativeBotController.swift:27`，建構點 `:145` |
| `react(event:)` 一次一個事件；`react(events:)` 只是 for-loop | 同上 `:168` / `:289` |
| **沒有任何 outbound HTTP client**（既有 `import Network` 全是 inbound loopback server） | `command/` 全域 |
| 沒有雲端相關設定欄位（grep `cloud|remote|apiKey` 零命中） | `SettingsStore.swift` |

## 架構：HybridBot 裝飾器，不是平行引擎

pluggable-bots-plan 原圖把引擎畫成平行兄弟。Akagi v3 的實戰做法證明**雲端不該是平行引擎，而是本地引擎的一種模式**——本地模型必須全程在場，同時扮演三個角色：

1. **合法動作閘門**：不是決策點就不打 API——省 round-trip，也省額度（basic 方案 rpm ≈ 10，額度會真的碰到；立直一手要吃兩次呼叫）。
2. **失敗 fallback**：逾時／HTTP 錯誤／`reaction: null`（事件流不同步）／立直捨牌解析失敗，全部退回本地決策，對局永不停擺。
3. **立直捨牌後備**：兩段式第二呼叫失敗時提供立直捨牌。

```swift
/// 持有本地 bot 當閘門與 fallback；雲端啟用且斷路器允許時代理決策
actor HybridBot: MahjongBot {
    private let local: BundledCoreMLBot     // 永遠在場，餵每一個事件
    private var api: AkagiApiClient?        // 每個決策點重讀設定決定生死
    private var breaker: Breaker            // 5s → 120s 指數退避
    private var kyokuStream: KyokuStreamBuilder
}
```

`NativeBotController` 只認得 `any MahjongBot`，雲端開關對它透明；之後的子行程 `StreamBot`（macOS only）是另一個 conform，互不干擾。

### `BotReaction` 對計畫草案的微調

計畫草案把 `meta` 當 opaque JSON——那是 Akagi 前後端分 process 的產物。Naki 的 UI 在同 process，改成型別化：

```swift
struct BotReaction {
    let action: MJAIEvent                  // 要打的動作
    let candidates: [BotCandidate]?        // top-k，映射到現有 Recommendation
    let servedBy: String                   // "cloud:<model>" / "local"，UI 與 log 標示用
}
```

`servedBy` 是 fallback 原則的落實：**可以更弱，但必須讓人看得出來**（2026-08-01「均勻分布偽裝成推薦」的教訓）。側欄每一手都要能標示這是雲端還是本地算的。

## 新增元件

| # | 元件 | 位置 | 要點 |
|---|------|------|------|
| 1 | `MahjongBot` protocol + `BundledCoreMLBot` | `command/Services/Bot/` | 計畫第 1 層原樣；唯一必改既有點是 `NativeBotController.swift:27` / `:145` |
| 2 | 批次 `react(events:)` | `NativeBotController.swift` | mjai 慣例：自上次反應以來的所有事件，最後一個是觸發點 |
| 3 | `AkagiApiClient` | 新檔 | `URLSession` 包 `/v3/react`（短逾時）＋ `/healthz`、`/v3/models`（8s）。**hold 一份重用**，只在 URL/key 變更時重建（連線池）。錯誤格式：`{"error": "..."}` + `Retry-After` |
| 4 | `KyokuStreamBuilder` | 新檔 | per-kyoku 視窗（保留 `start_game` 當 `events[0]`）＋ censor ＋ 三麻補位到長度 4。純函數，重點單測對象 |
| 5 | `Breaker` | 新檔 | 5s→120s 指數退避；`healthy` 旗標只在狀態轉變時通知；使用者改設定即 reset |
| 6 | 設定欄位 + UI | `SettingsStore.swift` ＋ `ContentView.swift` `settingsForm` | `cloudInferenceEnabled` / `cloudServerURL` / `cloudModel4P` / `cloudModel3P`，照 `actionDelaySeconds` pattern；**key 進 Keychain 不進 UserDefaults** |
| 7 | 隱私常駐指示 | UI | 連外部主機需一次性確認 + 對局中常駐「對局資料正在送往 \<host\>」（沿用計畫安全節） |
| 8 | 對局前健康檢查 | Settings UI | `/healthz` 附每模型 queue_depth，開局前就知道 server 可用與否 |

## 必守語意（每條都有 Akagi 實戰出處）

1. **每個決策點重讀設定**——修 key、換模型局中即生效，並 reset 斷路器。
2. **立直兩段式**：server 回裸 reach → 附上 reach 再打第二次拿捨牌 → 失敗用本地立直捨牌 → 再失敗整個退回本地決策。沒有捨牌的 reach 會卡死自動打牌。
3. **`reaction: null` 但本地有合法動作 ＝ 事件流不同步**：打本地決策 + warn，絕不默默 pass。null reaction 不觸發斷路器（server 可達）。
4. **推薦卡片規則**（Akagi #190）：bot 做了選擇才更新、其餘絕不更新；**放棄副露也是選擇**，pass 以一列呈現（「Pass 87% / Pon 13%」）。
5. **react 逾時不照抄 2 秒**：從雀魂回合計時器扣掉 Naki 自己的 `ActionDelayModel`（0.5–3.0s）再算預算。
6. **錯誤訊息不回顯 key／proxy 字串**——訊息會進 `~/Library/Logs/Naki/` 並被 bug report 附上；同時確認 `LogManager`、`/status`、MCP `get_status` 不外洩 key。
7. 收到 reaction 後**防禦性覆寫 `actor`** 為自己座位；同一組壞設定只警告一次（tombstone）。

## 三麻

雲端 server 有真三麻模型（`/v3/models` 的 `game: "3p"`；設定分 `model_4p` / `model_3p`）。這是 Naki 第一次有真三麻推論路徑——但**本地 fallback 仍是四麻模型**：三麻局 fallback 時 UI 必須標示降級，不得無聲切換；`BotIdentity.supports3P` 只在「雲端啟用＋選了 3p 模型」時如實為 true。

## 實作順序與驗證

| 階段 | 內容 | 驗證 |
|------|------|------|
| 1 | `MahjongBot` + `BundledCoreMLBot` 包裝 | `replay-check.sh` 決策指紋**完全相同** |
| 2 | 批次化 `react` | 同上，指紋相同＝批次化沒改變決策 |
| 3 | `KyokuStreamBuilder` + `AkagiApiClient` + `HybridBot` + `Breaker` | mock HTTP server 單測；**Akagi `api.rs`/`native.rs` 的測試清單就是現成規格書**（bearer 不進 URL、null reaction fallback、立直兩段、斷路器退避、mid-game 改設定生效、unreachable fallback…逐條移植成 Swift 測試） |
| 4 | 設定 UI + Keychain + healthz/models | — |
| 5 | live 驗證 | `soak-test.sh` 人機局：fallback 切換時 event log 有明確一行、側欄 `servedBy` 標示正確 |

## 專案坑位提醒

- 新增 Swift 檔要手動加進 `Naki.xcodeproj` 的 `membershipExceptions`（**包含清單**），否則 `cannot find 'X' in scope`。
- 新的 `@MainActor` class 補 `nonisolated deinit { }`，否則 NakiTests host SIGABRT。
- `#Preview` 內容 Release 也編譯，用到 `#if DEBUG` 才有的東西要自己包。

## 未驗證項（實作前要先查）

- **Naki `LiqiParser` 產出的 MJAI 事件形狀是否與 server 期待一致**（欄位名、字牌 `E/S/W/N/P/F/C`、`tehais` 是否已是 13 張 `?`）——未驗證，階段 3 前先拿一局實錄事件比對 mjai spec。
- 官方 server 的實際 plan 額度（rpm/rpd/topk）——文件數字來自 Akagi 測試 fixture，未以真 key 驗證。
- 雀魂回合計時器實際可用預算（決定 react 逾時值）——未量測。
