# Naki（鳴き）

**雀魂的 AI 雀友 — 原生 macOS / iOS 應用，開箱即用。**

<p align="center">
  <img src="image.png" width="640" alt="Naki macOS 介面">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Version-2.3.0-green" alt="Version">
  <img src="https://img.shields.io/badge/macOS-14.0+-blue" alt="macOS">
  <img src="https://img.shields.io/badge/iOS-17.0+-blue" alt="iOS">
  <img src="https://img.shields.io/badge/Apple%20Silicon-Required-red" alt="Architecture">
  <img src="https://img.shields.io/badge/License-AGPL--3.0-blue" alt="License">
</p>

<p align="center">
  <a href="https://github.com/Sunalamye/Naki/releases/latest"><strong>下載</strong></a> ·
  <a href="#快速開始"><strong>快速開始</strong></a> ·
  <a href="#功能"><strong>功能</strong></a> ·
  <a href="#給開發者"><strong>給開發者</strong></a>
</p>

---

> ### ⚠️ 使用前必讀
>
> 本專案**僅供學習與研究**。使用本工具可能違反雀魂服務條款，導致帳號被封禁。
>
> **請勿使用主帳號。** 作者不對任何損失負責。繼續使用即表示您接受以上風險。

---

## 這是什麼

「鳴き」是日麻術語，指吃、碰、槓這類副露動作。這款 AI 會在關鍵時刻告訴你：該鳴。

Naki 把雀魂和麻將 AI 包進同一個 App。不需要 Python、不需要 Docker、不需要瀏覽器外掛——
打開就能用，AI 推薦直接顯示在遊戲畫面上。

推論引擎是 [Mortal](https://github.com/Equim-chan/Mortal)，透過 Core ML 跑在 Apple Neural Engine 上。

---

## ⚠️ 舊版突然沒反應？請更新

雀魂在 **2026 年 7 月把客戶端換成了 Unity 引擎**。

這次改版讓舊版 Naki 的**自動打牌與畫面高亮完全失效**——
過去的做法是操作網頁上的遊戲物件，而那些物件在新引擎裡已經不存在了。

最新版已全面改走遊戲的通訊協定，兩項功能都已恢復，並在真實對局中驗證過。
**如果你的 Naki 只剩側邊欄有推薦、遊戲畫面卻沒反應，更新就會好。**

---

## 功能

<table>
<tr>
<td width="50%">

### 即時 AI 推薦

每張牌都有 AI 評分，最佳選擇直接在遊戲畫面中變色。

- 顏色越亮 = 越推薦
- 側邊欄顯示完整分析與 Q 值
- 涵蓋打牌 / 吃 / 碰 / 槓 / 立直 / 和牌

</td>
<td width="50%">

<img src="image-1.png" width="100%" alt="推薦高亮">

</td>
</tr>
<tr>
<td width="50%">

<img src="iphone.png" width="100%" alt="iPhone 介面">

</td>
<td width="50%">

### macOS 與 iOS 都能用

- **macOS** — 完整功能，含自動打牌
- **iPhone / iPad** — 查看 AI 推薦
- 響應式 UI、支援深色模式

</td>
</tr>
</table>

### 三種模式

| 模式 | 說明 |
|:---:|-----|
| **關閉** | AI 在背景運算但不顯示，完全手動 |
| **推薦** | 顯示 AI 推薦，你來決定怎麼打 |
| **自動** | AI 全權代理，躺平看戲 |

> 模式選擇會記住，重開 App 不會被重設。

### 還有這些

- **手牌顏色高亮** — 建議打的牌直接在遊戲畫面中變色
- **動作按鈕高亮** — 該吃該碰的時候，遊戲的動作按鈕會一起亮起來
- **自動回應表情** — 被立直、被和牌時自動發表情
- **MCP Server** — 讓 Claude Code 等 AI 助手直接操作遊戲

---

## 快速開始

### 系統需求

| 平台 | 版本 | 架構 |
|-----|------|-----|
| **macOS** | 14.0+（Sonoma） | Apple Silicon |
| **iOS** | 17.0+ | A12 以上 |

> **為什麼不支援 Intel Mac？**
> AI 模型跑在 Apple Neural Engine 上，那是 Apple Silicon 獨有的硬體。

> **macOS 26 / iOS 26 以上**用新的 `WebPage` API；**14–25** 走相容路徑（`WKWebView`）。
> 兩條路的 AI 推薦與自動打牌都走同一套遊戲協定層，功能一致。
> 相容路徑目前只驗證過編譯與單元測試，尚未在 macOS 14/15 實機跑過對局。

### 安裝

1. 到 [Releases](https://github.com/Sunalamye/Naki/releases/latest) 下載 `Naki.dmg`
2. 拖進「應用程式」
3. 首次開啟：右鍵 →「打開」（繞過 Gatekeeper）

### 使用

1. 打開 Naki，雀魂會自動載入
2. 登入帳號（**請用小號**）
3. 開始對局，AI 推薦即時顯示
4. 在側邊欄選擇你要的模式

---

## 給開發者

<details>
<summary><b>Debug API（HTTP，port 8765）</b></summary>

App 啟動後會在本機開一個 HTTP server，只綁 loopback，同網段其他裝置連不到。

```bash
# Bot 狀態、手牌、推薦
curl http://localhost:8765/bot/status

# 協定層目前的可用操作（吃/碰/槓/立直…）
curl http://localhost:8765/bot/ops

# 手動觸發一次自動打牌
curl -X POST http://localhost:8765/bot/trigger

# 在遊戲頁面執行 JS（注意：必須用 return 才有回傳值）
curl -X POST http://localhost:8765/js -d 'return window.location.href'
```

`/status` 會回傳檔案日誌的路徑；歷史日誌保留最近 5 次啟動。

</details>

<details>
<summary><b>MCP Server（Claude Code 整合）</b></summary>

Naki 內建 [Model Context Protocol](https://modelcontextprotocol.io/) server，
提供 42 個工具讓 AI 助手直接操作遊戲。與 Debug API 共用同一個 port。

```bash
claude mcp add --transport http naki http://localhost:8765/mcp
```

| 類別 | 工具範例 |
|-----|---------|
| Bot 控制 | `bot_status` · `bot_ops` · `bot_trigger` |
| 遊戲動作 | `game_state` · `game_discard` · `game_action` |
| 友人房 | `room_create` · `room_add_robot` · `room_start` · `room_quick_test` |
| 大廳 | `lobby_start_match` · `lobby_account_info` |
| 表情 | `game_emoji` · `game_emoji_listen` |

`room_quick_test` 會一次跑完「建房 → 補人機 → 開局」，用來快速驗證自動打牌。

</details>

<details>
<summary><b>架構</b></summary>

```
┌─────────────────────────────────────────────────────────┐
│              WebPage（雀魂 · Unity WebGL）               │
│                          │                              │
│      JavaScript：只做 WebSocket 收送與畫面標色           │
│               naki-core / naki-websocket                │
└──────────────────────────┼──────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────┐
│                     Swift 服務層                         │
│                                                         │
│  MajsoulBridge  →  NativeBotController  →  LiqiActionSender
│   (Liqi→MJAI)      (純 Swift + Core ML)     (組包送出動作)
│                           │                             │
│          GameStateManager  ←→  SwiftUI Views            │
└─────────────────────────────────────────────────────────┘
```

**為什麼不去操作遊戲畫面？**

雀魂改用 Unity 後，遊戲邏輯與畫面都在 wasm 裡，JavaScript 拿不到任何遊戲物件。
所以 Naki 一律走**協定層**：狀態從 WebSocket 封包解析，動作自行組包送出。
協定欄位定義取自遊戲自身公開的資源檔 `res/proto/liqi.json`，不是反組譯客戶端得來的。

畫面高亮則是攔截繪圖呼叫、改遊戲畫那張牌時用的顏色參數——
位置由遊戲自己給，不需要猜螢幕座標。

技術細節見 [`docs/majsoul-unity-protocol.md`](docs/majsoul-unity-protocol.md)。

</details>

---

## 開發計畫

- [x] AI 推薦高亮
- [x] 全自動打牌
- [x] 動作按鈕高亮
- [x] MCP Server
- [x] 自動回應表情
- [x] Unity 客戶端遷移
- [ ] 三麻模式
- [ ] 牌譜回放分析

---

## 致謝

- [Mortal](https://github.com/Equim-chan/Mortal) — 麻將 AI 引擎
- [Akagi](https://github.com/shinkuan/Akagi) — Python 版參考實現
- 雀魂（Majsoul） — 很好的麻將遊戲

## 許可證

[AGPL-3.0 with Commons Clause](LICENSE) — 開源，但禁止商業銷售。

---

## ⚖️ 免責聲明

### 教育與學習目的

本專案的開發目的是為了：

- 學習 Swift / SwiftUI 原生 macOS / iOS 應用開發
- 研究 Core ML 機器學習模型整合
- 理解 WebSocket 通訊協議與攔截技術
- 探索 Protobuf 協議解析

### 使用風險

1. **帳號風險**：使用本工具可能違反雀魂（Majsoul）的服務條款，可能導致您的遊戲帳號被暫停或永久封禁。**強烈建議使用小號或測試帳號**。

2. **法律風險**：在某些地區，使用此類工具可能涉及法律問題。請確保您了解並遵守當地法律法規。

3. **無擔保**：本軟體按「現狀」提供，不提供任何明示或暗示的擔保，包括但不限於對適銷性、特定用途適用性和非侵權性的擔保。

### 責任限制

在任何情況下，作者或版權持有人均不對任何索賠、損害或其他責任負責，無論是在合約訴訟、侵權行為或其他方面，由軟體或軟體的使用或其他交易引起或與之相關。

### 第三方內容

- 本專案使用 [Mortal](https://github.com/Equim-chan/Mortal) AI 模型
- 雀魂（Majsoul）是貓糧工作室的註冊商標
- 本專案與貓糧工作室或悠星網絡無任何關聯

**使用本軟體即表示您已閱讀、理解並同意以上所有條款。**

---

## ⭐ Star History

[![Star History Chart](https://api.star-history.com/svg?repos=Sunalamye/Naki&type=Date)](https://star-history.com/#Sunalamye/Naki&Date)

<p align="center">
  <sub>Made with ❤️ by a Mahjong lover who got tired of losing</sub>
</p>
