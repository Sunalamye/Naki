# 可選 AI：Naki 的實作計畫

**資料日期**：2026-08-01
**參考**：[Akagi mjai_bot 協定](https://github.com/shinkuan/Akagi/blob/v3/mjai_bot/README.md)

Akagi 用「Python 子行程 + JSONL over stdin/stdout」。**那套不能直接搬**，因為 Naki 同時出 macOS 與 iOS，而 iOS 不允許 app 啟動任意子行程。這份文件是針對 Naki 實際限制的設計。

---

## 現況

| 事實 | 來源 | 影響 |
|------|------|------|
| App Sandbox **未啟用** | `Naki/akagi.entitlements` 沒有 `com.apple.security.app-sandbox` | macOS 可以起子行程 |
| iOS deployment target 17.0 | project.pbxproj | iOS **不可能**起子行程 |
| `NativeBotController.bot` 是具體型別 `MortalBot?` | `NativeBotController.swift:27` | 沒有抽象層 |
| `react(event:)` 一次一個事件 | 同上 | 與 mjai 慣例的批次不同 |
| `is3P` 不換模型 | CLAUDE.md | 三麻其實是四麻模型在跑 |

---

## 核心設計：把「協定」與「誰啟動行程」分開

Akagi 把兩件事綁在一起（子行程 + stdin/stdout）。Naki 拆開：

```
                    ┌─────────────────────────┐
                    │  MJAIEventStream        │
                    └───────────┬─────────────┘
                                ▼
                    ┌─────────────────────────┐
                    │  NativeBotController    │
                    │  持有 any MahjongBot    │  ← 唯一要改的既有型別
                    └───────────┬─────────────┘
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
      BundledCoreMLBot     StreamBot         （未來）
      （現有 MortalBot）   JSONL codec
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
             SubprocessTransport      NetworkTransport
             macOS only               macOS + iOS
             Pipe(stdin/stdout)       TCP / WebSocket
```

**關鍵取捨**：JSONL 編解碼只實作一次，子行程與網路只是不同的 `Transport`。

Akagi 的做法是「子行程」與「雲端 API」兩套完全不同的實作。對 Naki 而言那會變成三套（因為 iOS 只能走網路），而三套的行為差異就是三倍的 bug 面。**統一 codec、只變 transport**，讓 macOS 的子行程 bot 與 iOS 的遠端 bot 走完全相同的協定路徑——差別只在誰負責啟動那個行程。

---

## 分層實作

### 第 1 層：`MahjongBot` 抽象（無論之後做不做外部 bot 都該做）

```swift
/// 一個能對 MJAI 事件做出反應的引擎
protocol MahjongBot: Actor {
    /// 對一批事件做出反應
    ///
    /// 批次而不是單一事件：mjai 慣例是「自上次反應以來累積的所有事件，
    /// 最後一個是觸發點」。單事件介面在子行程／網路下每個事件都要一次
    /// round-trip，一局 700 個事件就是 700 次——批次讓它降到決策點的次數。
    func react(events: [MJAIEvent]) async throws -> BotReaction?

    /// 引擎自述（UI 顯示、log 標記用）
    var identity: BotIdentity { get }

    func shutdown() async
}

struct BotReaction {
    let action: [String: Any]
    /// 引擎自己的 HUD 資料，Naki 不解讀只轉發
    let meta: [String: Any]?
}

struct BotIdentity {
    let name: String          // "mortal-bundled" / "my-bot"
    let displayName: String
    let supports3P: Bool
    let isLocal: Bool         // 影響 UI 上的隱私提示
}
```

現有 `MortalBot` 包成 `BundledCoreMLBot`。這一步**不改變任何行為**，可以用 `replay-check.sh` 的決策指紋驗證（改完指紋必須完全相同）。

### 第 2 層：`StreamBot` + `Transport`

```swift
protocol BotTransport: Actor {
    func start() async throws
    func send(line: Data) async throws
    /// 一行一個 JSON 值
    func lines() -> AsyncThrowingStream<Data, Error>
    func stop() async
}
```

`StreamBot` 負責協定，`Transport` 負責位元組怎麼進出。

**協定與 Akagi 相容**（刻意的——這樣現有的 mjai bot 不用改就能跑）：

- stdin ← 一行 JSON array，是自上次反應以來的所有事件
- stdout → 剛好一行 JSON reaction；不是自己的回合回 `{"type":"none"}`
- stderr 只做診斷，前綴 `@@AKAGI_NOTIFY@@ ` 的行轉成 App 內通知
- 收到 `end_game` 回一次然後退出

**唯一刻意不相容的地方**：Naki 額外在 `start_game` 前送一個握手行，讓 bot 自報 `identity`。Akagi 靠資料夾裡的 `manifest.toml`，那是檔案系統慣例；Naki 走網路時沒有檔案系統可讀。握手是可選的——bot 不回應就用預設值，所以未修改的 mjai bot 仍然能跑。

### 第 3 層：路由與 fallback

```swift
struct BotRouting {
    var active4P: String   // "mortal-bundled"
    var active3P: String
    /// 外部引擎失敗時是否退回內建
    var fallbackToBundled: Bool = true
    /// 一次反應的預算
    var reactTimeout: TimeInterval = 5.0
}
```

**fallback 的規則沿用本專案已確立的原則**：可以更弱，但必須是同一種東西。外部引擎逾時／崩潰／回傳非法動作時，退回內建模型的決策，**並在 event log 留下明確一行**。

> 本專案 2026-08-01 修掉的 bug 正是違反這條：副露後退回均勻分布，側欄顯示得與真推薦一模一樣。「看起來一樣但其實不是決策」比「明顯更弱的決策」危險得多。

---

## 平台差異（不得假裝一致）

| 能力 | macOS | iOS |
|------|:-----:|:---:|
| 內建 Core ML bot | ✅ | ✅ |
| 遠端 bot（TCP/WS） | ✅ | ✅ |
| 本機子行程 bot | ✅ | ❌ |
| 從 ZIP／GitHub 安裝 bot | ✅ | ❌ |

iOS 上「可選 AI」只能是遠端。UI 必須直說這件事，不能給一個在 iOS 上永遠灰掉的按鈕——這正是本專案 §13 移除四組假設定的教訓。

---

## 刻意不做的事

**不 bundle Python runtime。** Akagi 打包了 python-build-standalone + uv（每平台一份）。對 Naki 的代價：

- App 體積 +50 MB 以上
- 公證（notarization）要處理一整棵未簽名的二進位樹
- iOS 完全用不到

**改成**：Naki 只負責啟動一個**已存在的可執行檔**（使用者自己準備環境），或連到一個已在跑的 endpoint。門檻轉嫁給使用者，但那些想換 AI 的人本來就有能力自己裝 Python。

**不做 bot 市集／自動安裝。** Akagi 支援從 GitHub release 或 ZIP 安裝。Naki **沒有開 App Sandbox**，自動下載並執行任意程式碼的風險太高。要加外部 bot 必須使用者手動指定路徑，且首次執行要明確確認。

**不宣稱三麻支援。** `StreamBot` 讓三麻變成「可能」——跑一個別人訓好的三麻 mjai bot 就行。但 Naki 自己仍然沒有三麻模型，`BotIdentity.supports3P` 要如實反映，`is3P` 路由到不支援三麻的引擎時必須擋下並說明。

---

## 安全考量

執行外部程式碼是這個功能的本質風險，而 Naki 沒有沙盒。

1. **明確授權**：新增一個外部 bot 時要有一次性的確認對話，內容說清楚「這個程式將以你的權限執行」。
2. **不記憶路徑外的東西**：只存使用者選的路徑，不掃描目錄自動發現。
3. **遠端 endpoint 預設只允許 loopback**；要連外部主機必須另外確認，並在 UI 常駐顯示「對局資料正在送往 <host>」。
4. **bot 的 `meta` 原樣轉發但不執行**：只當資料渲染，不解讀成指令。

---

## 建議順序

| 階段 | 內容 | 驗證方式 |
|------|------|---------|
| 1 | `MahjongBot` 協定 + `BundledCoreMLBot` 包裝 | `replay-check.sh` 指紋必須**完全相同** |
| 2 | `react` 改成批次 | 同上；指紋相同代表批次化沒改變決策 |
| 3 | `StreamBot` + JSONL codec + `NetworkTransport` | 用一個 echo bot 做整合測試 |
| 4 | 逾時／fallback／log | 單測：逾時、崩潰、非法動作三種失敗 |
| 5 | UI：引擎選擇 + 平台差異說明 | — |
| 6 | `SubprocessTransport`（macOS） | — |

**第 1、2 階段是無論如何都該做的**——它們讓核心不再綁死單一引擎，而且有決策指紋當安全網，風險極低。第 3 階段之後才是真正的「可選 AI」。


---

## 補充：Akagi 的「換 AI」其實是三層（2026-08-01 讀 `src/bot/README.md`）

先前只看 `mjai_bot/README.md`，以為換 AI 就是換子行程。實際上分三層，**難度與價值完全不同**：

| 層 | 機制 | 生效時機 | 需要子行程 |
|----|------|---------|-----------|
| 換引擎 | `bot.active_4p` / `active_3p` 字串 | 下一局 `start_game` | 是（保留名稱除外）|
| 換模型 | 同一引擎內代理給遠端 API | **對局中即時** | 否 |
| 換設定 | bot 自己的 `manifest.toml` 旋鈕 | 依 bot | 否 |

`BotManager` 的生成點是 `start_game`，依 `num_players` 挑 `active_4p` 或 `active_3p`；
兩個保留名稱（`akagi-native` / `akagi-native3p`）走 in-process，其餘才 spawn 子行程。
**換引擎不是熱插拔。**

### 對 Naki 的順序修正

原本的階段表把「換引擎」排在「換模型」前面。**應該反過來**：

「換模型」（第二層）不需要子行程，**iOS 也吃得到**，而 Naki 目前這層是零——
`MortalBot(version: 4, useBundledModel: true)` 兩個參數都寫死。先做這層，
兩個平台同時受益；「換引擎」只有 macOS 能用，價值更窄。

### 從 Akagi 直接借的三個做法

**1. 每個決策點重讀設定，不是啟動時讀一次。**

> Re-reading per decision is what lets the user enable cloud inference, fix a mistyped key,
> or switch models mid-game — a change resets the Breaker so the new settings are tried
> on the very next move.

**2. 本地模型永遠留著，同時當「合法動作閘門」與 fallback。**

不只是遠端失敗時的備援——不能動作時直接跳過遠端呼叫，省一次 round-trip。
這與本專案已確立的 fallback 原則一致：可以更弱，但必須是同一種東西。

**3. 指數退避斷路器（5s → 120s）。**

> a dead server costs one slow turn per window instead of a request timeout on every decision

沒有這個，遠端掛掉會讓**每一個決策**都等到逾時。以 Naki 的 5 秒預算算，
一局 100 手就是 500 秒的空等。

### 一個 UI 正確性的教訓（Akagi issue #190）

`meta.show` 卡片的規則是「**bot 做了選擇時才更新，其餘絕不更新**」，兩半都要對：

- 「其餘絕不更新」：多數事件不是決策（別家打了張我們不能碰的牌）。若那些也帶卡片，
  整局都在閃爍。
- 「做了選擇時一定更新」：**放棄副露也是一種選擇**。他們曾經在「最佳選項是 pass」時
  抑制卡片，於是放棄副露後畫面留著上一巡的打牌建議，讀起來像是對一個已結束的決策的
  即時建議。

> getting either wrong is invisible in tests but obvious in a game

修法是讓 pass 本身成為一列（「Pass 87% / Pon 13%」）——那個比較正是當下最有用的資訊。

這與本專案 2026-08-01 修的「副露被搶先送過」是同一類問題：**畫面上顯示的東西
必須對應真實發生的決策**。Naki 目前副露時側欄顯示什麼、放棄後是否清掉，尚未檢查。
