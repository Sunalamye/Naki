# Naki（鳴き）

**雀魂的 AI 雀友。原生 macOS / iOS 應用，打開就能用。**

<p align="center">
  <img src="image.png" width="680" alt="Naki macOS 介面">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-2.3.0-green" alt="Version">
  <img src="https://img.shields.io/badge/macOS-26.0+-blue" alt="macOS">
  <img src="https://img.shields.io/badge/iOS-17.0+-blue" alt="iOS">
  <img src="https://img.shields.io/badge/Apple%20Silicon-required-red" alt="Architecture">
  <img src="https://img.shields.io/badge/license-AGPL--3.0-lightgrey" alt="License">
</p>

<p align="center">
  <a href="https://github.com/Sunalamye/Naki/releases/latest"><b>下載</b></a> ·
  <a href="#快速開始"><b>快速開始</b></a> ·
  <a href="#能做什麼"><b>能做什麼</b></a> ·
  <a href="#給開發者"><b>給開發者</b></a>
</p>

---

> ## ⚠️ 先讀這段
>
> 本專案**僅供學習與研究**。使用它可能違反雀魂服務條款，導致帳號被封禁。
>
> **請勿使用主帳號。** 作者不對任何損失負責。繼續使用即代表你接受這個風險。

---

## 這是什麼

「鳴き」是日麻術語，指吃、碰、槓那類副露動作。這個 App 會在該鳴的時候告訴你：該鳴。

Naki 把雀魂和麻將 AI 裝進同一個視窗。**不需要 Python、Docker、瀏覽器外掛或代理伺服器**——
下載、打開、登入，AI 推薦就直接疊在遊戲畫面上。

推論引擎是 [Mortal](https://github.com/Equim-chan/Mortal)，透過 Core ML 跑在 Apple Neural Engine 上。
沒有網路請求，模型和運算全都在你的機器裡。

---

## 能做什麼

<table>
<tr>
<td width="52%">

### 推薦直接標在牌上

不用低頭看側邊欄再回頭找牌。AI 建議打哪張，**那張牌就在遊戲畫面裡變色**。

- 該吃該碰時，遊戲的動作按鈕會一起亮起來
- 側邊欄有完整分析與 Q 值
- 涵蓋打牌 / 吃 / 碰 / 槓 / 立直 / 和牌

</td>
<td width="48%">
<img src="image-1.png" width="100%" alt="推薦高亮">
</td>
</tr>
<tr>
<td width="52%">
<img src="iphone.png" width="100%" alt="iPhone 介面">
</td>
<td width="48%">

### Mac 和 iPhone 都能用

- **macOS** — 完整功能，含全自動打牌
- **iPhone / iPad** — 查看 AI 推薦
- 深色模式、響應式排版

</td>
</tr>
</table>

### 三種模式，隨時切換

| 模式 | 行為 |
|:---:|-----|
| **關閉** | 完全手動。AI 不算也不顯示 |
| **推薦** | 顯示建議，你自己決定 |
| **自動** | AI 全權代打 |

模式會記住，重開 App 不會被重設。

### 其他

- **自動回應表情** — 被立直、被和牌時自動回敬
- **MCP Server** — 讓 Claude Code 之類的 AI 助手直接操作遊戲
- **本機 Debug API** — 只綁 loopback，同網段的其他裝置連不到

---

## 快速開始

### 系統需求

| 平台 | 版本 | 架構 |
|-----|------|-----|
| **macOS** | **26.0+** | Apple Silicon |
| **iOS / iPadOS** | 17.0+ | A12 以上 |

> **為什麼要 Apple Silicon？**
> AI 模型跑在 Apple Neural Engine 上，那是 Apple Silicon 獨有的硬體，Intel Mac 沒有。

> **iOS 17–25** 走 `WKWebView` 相容路徑，**iOS 26+** 用新的 `WebPage` API。
> 兩條路的推薦與動作都走同一套遊戲協定層，功能一致。
> 相容路徑目前只驗證過編譯與單元測試，**尚未在實機跑過完整對局**。

### 安裝

1. 到 [Releases](https://github.com/Sunalamye/Naki/releases/latest) 下載 `Naki.dmg`
2. 拖進「應用程式」
3. 首次開啟：右鍵 →「打開」（繞過 Gatekeeper）

### 使用

1. 打開 Naki，雀魂會自動載入
2. 登入帳號（**用小號**）
3. 開始對局，推薦即時顯示
4. 在側邊欄選你要的模式

---

## AI 的輸入是經過驗證的

這件事值得單獨講，因為它決定推薦到底可不可信。

Mortal 的模型是**固定成品**——它訓練時看到的輸入是一個 `1012 × 34` 的張量，
每一格代表什麼（第 23 格是本場、第 860 格是聽牌…）都寫死在權重裡，改不了。
Naki 這邊如果某一格填錯東西，模型不會報錯，它會**照樣算出一個看起來很正常的推薦**，
只是那個推薦建立在完全錯誤的理解上。

所以 Naki 用 [MortalSwift](https://github.com/Sunalamye/MortalSwift) 把 Mortal 的
Rust 核心（libriichi）逐格對拍：同一串對局事件同時餵給兩邊，比對輸出的每一格。

**目前 1012 格全部一致，動作遮罩也一致。** 這代表模型收到的每一格語意，
都與它訓練時看到的相同——包含「每張打牌在往後每一巡的聽牌率、和牌率、期望點數」
這組最直接關於「打哪張比較好」的資訊。

> 誠實補充：對拍證明的是**輸入正確**，不是**打得比較好**。
> 後者需要跑幾千局的評測環境才說得準，那個還沒做。

---

## 給開發者

<details>
<summary><b>架構：為什麼不去操作遊戲畫面</b></summary>

```
┌──────────────────────────────────────────────────────────┐
│              WebPage（雀魂 · Unity WebGL）                │
│                          │                               │
│    JavaScript 只做兩件事：收送 WebSocket、替牌上色         │
│              naki-core / naki-websocket                  │
└──────────────────────────┼───────────────────────────────┘
                           ▼
┌──────────────────────────────────────────────────────────┐
│                      Swift 服務層                         │
│                                                          │
│  MajsoulBridge  →  NativeBotController  →  LiqiActionSender
│   (Liqi→MJAI)      (純 Swift + Core ML)      (組包送出)
│                           │                              │
│      AutoPlayDecisionResolver（合法性與模式閘門）          │
│                           │                              │
│          GameStateManager  ←→  SwiftUI Views             │
└──────────────────────────────────────────────────────────┘
```

雀魂在 2026 年 7 月把客戶端換成 Unity WebGL，遊戲邏輯與畫面全都進了 wasm，
JavaScript 再也拿不到任何遊戲物件。所以 Naki 一律走**協定層**：
狀態從 WebSocket 封包解析，動作自己組 protobuf 送出。

協定欄位定義取自**遊戲自己公開的資源檔** `res/proto/liqi.json`，不是反組譯客戶端得來的。

畫面高亮則是攔截 WebGL 繪圖呼叫、改遊戲畫那張牌時用的顏色參數——
**位置由遊戲自己給**，不需要猜螢幕座標，也不會因為版面調整就失效。

**合法性由伺服器決定，不由模型決定。** 每個動作送出前都會比對雀魂給的
可用操作清單；清單裡沒有的動作一律不送，缺清單時直接放棄。
模型只負責「這幾個合法動作裡哪個好」。

技術細節：[`docs/majsoul-unity-protocol.md`](docs/majsoul-unity-protocol.md) ·
[`AUDIT.md`](AUDIT.md)

</details>

<details>
<summary><b>Debug API（HTTP，port 8765）</b></summary>

App 啟動後會在本機開一個 HTTP server，`requiredInterfaceType = .loopback`，
只綁 127.0.0.1 / ::1。

```bash
# Bot 狀態、手牌、推薦
curl http://localhost:8765/bot/status

# 協定層目前的可用操作（吃/碰/槓/立直…）
curl http://localhost:8765/bot/ops

# 手動觸發一次自動打牌
curl -X POST http://localhost:8765/bot/trigger

# 在遊戲頁面執行 JS（⚠️ 必須用 return 才有回傳值）
curl -X POST http://localhost:8765/js -d 'return window.location.href'
```

`/status` 會回傳日誌檔路徑；歷史日誌保留最近 5 次啟動。

</details>

<details>
<summary><b>MCP Server（Claude Code 整合）</b></summary>

內建 [Model Context Protocol](https://modelcontextprotocol.io/) server，
**42 個工具**，與 Debug API 共用同一個 port。

```bash
claude mcp add --transport http naki http://localhost:8765/mcp
```

| 類別 | 數量 | 範例 |
|-----|:---:|------|
| 系統 | 4 | `get_status` · `get_logs` |
| Bot 控制 | 7 | `bot_status` · `bot_ops` · `bot_trigger` |
| 遊戲狀態與動作 | 6 | `game_state` · `game_discard` · `game_action` |
| 大廳 | 8 | `lobby_start_match` · `lobby_account_info` |
| 友人房 | 7 | `room_create` · `room_add_robot` · `room_quick_test` |
| 表情 | 2 | `game_emoji` · `game_emoji_listen` |
| 其他 | 8 | JS 執行、防閒置、高亮 |

`room_quick_test` 一次跑完「建房 → 補人機 → 開局」，用來快速驗證自動打牌。

> 高亮那 6 個工具在 Unity 客戶端下**一律回明確失敗**並導向原生推薦面板——
> 它們是 Laya 時代的遺留，留著是為了讓呼叫端拿到清楚的錯誤而不是靜默失效。

</details>

<details>
<summary><b>自己建置</b></summary>

需要 Xcode 26 以上。

```bash
git clone https://github.com/Sunalamye/Naki.git
cd Naki
xcodebuild build -project Naki.xcodeproj -scheme Naki
xcodebuild test  -project Naki.xcodeproj -scheme Naki -only-testing:NakiTests
```

**想要順的話請用 Release 建置。** 期望值推演在 Debug（無最佳化）下，
開局散牌手的一次運算要 1.2 秒；Release 是 **37 毫秒**，差 33 倍。
Xcode 裡改 `Product → Scheme → Edit Scheme → Run → Build Configuration`。

</details>

---

## 現況

| | 狀態 |
|---|---|
| AI 推薦與畫面高亮 | ✅ 真實對局驗證過 |
| 全自動打牌 | ✅ 真實對局驗證過 |
| 動作按鈕高亮 | ✅ |
| 模型輸入正確性 | ✅ 1012 格與 libriichi 逐格一致 |
| MCP Server / 自動表情 | ✅ |
| iOS 17–25 相容路徑 | ⚠️ 只驗過編譯與單元測試，未實機跑過對局 |
| 三麻 | ❌ 見下 |
| 牌譜回放分析 | ❌ 尚未開始 |

### 關於三麻

**做不了，卡在模型檔。**

三麻的引擎有開源版本（[mortal-sanma](https://github.com/Mateces/mortal-sanma)），
規格也清楚：observation 是 `775 × 34`、動作空間 44、沒有 2–8 萬、北是拔北寶牌。
但**訓練好的三麻權重沒有公開發布**，找遍 HuggingFace 與各個 repo 都沒有。

所以三麻對局時，Naki 用的仍是四麻模型——輸入結構根本不同，
輸出不是「稍微偏差」而是**結構上無效**。因此 UI 會明確標示
`Mortal (4P) ⚠️ 三麻無專用模型`，不會假裝有支援。

---

## 致謝

- [Mortal](https://github.com/Equim-chan/Mortal) — 麻將 AI 引擎與 libriichi
- [Akagi](https://github.com/shinkuan/Akagi) — Python 版參考實現
- [mortal-sanma](https://github.com/Mateces/mortal-sanma) — 三麻引擎規格
- 雀魂（Majsoul） — 很好的麻將遊戲

---

## 許可證

[AGPL-3.0 with Commons Clause](LICENSE) — 開源，但**禁止商業銷售**。

---

## ⚖️ 免責聲明

**開發目的**：學習 Swift / SwiftUI 原生開發、Core ML 模型整合、
WebSocket 與 Protobuf 協定解析。

**帳號風險**：使用本工具可能違反雀魂服務條款，可能導致帳號被暫停或永久封禁。
**強烈建議使用小號。**

**法律風險**：某些地區使用此類工具可能涉及法律問題，請自行確認當地法規。

**無擔保**：本軟體按「現狀」提供，不提供任何明示或暗示的擔保。
作者不對任何索賠、損害或其他責任負責。

**第三方**：雀魂是貓糧工作室的註冊商標；本專案與貓糧工作室、悠星網絡無任何關聯。

使用本軟體即表示你已閱讀、理解並同意以上條款。

---

<p align="center">
  <a href="https://star-history.com/#Sunalamye/Naki&Date">
    <img src="https://api.star-history.com/svg?repos=Sunalamye/Naki&type=Date" width="500" alt="Star History">
  </a>
</p>
