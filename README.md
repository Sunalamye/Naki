# Naki (鳴き) - 雀魂麻將 AI 助手

<p align="center">
  <img src="https://img.shields.io/badge/Version-2.1.2-green" alt="Version">
  <img src="https://img.shields.io/badge/Platform-macOS%2026+-blue" alt="Platform">
  <img src="https://img.shields.io/badge/Arch-Apple%20Silicon-red" alt="Architecture">
  <img src="https://img.shields.io/badge/Swift-5.9+-orange" alt="Swift">
  <img src="https://img.shields.io/badge/License-AGPL--3.0%20with%20Commons%20Clause-blue" alt="License">
</p>

<p align="center">
  <a href="https://github.com/Sunalamye/Naki/releases/latest"><strong>📥 下載最新版本</strong></a>
</p>

純 Swift + Core ML 實現的雀魂 (Majsoul) 麻將 AI 助手。無需 Python 後端，原生 macOS 應用，實時分析牌局並提供最優打牌建議。

> **鳴き (Naki)** - 日本麻將術語，指「吃」「碰」「槓」等副露動作

---

## ⚠️ 重要警告

> **本專案僅供學習與研究用途！**
>
> - 🎓 本專案旨在學習 Swift/SwiftUI、Core ML、WebSocket 攔截等技術
> - 🚫 **請勿使用主帳號** - 強烈建議使用小號或測試帳號
> - ⚖️ 使用本工具可能違反雀魂的服務條款，可能導致帳號被封禁
> - 🙅 作者不對任何因使用本工具造成的損失負責

---

## ✨ 功能特點

| 功能 | 說明 |
|-----|------|
| 🎮 **內嵌遊戲** | WebPage API (macOS 26.0+) 直接載入雀魂，無需外部瀏覽器 |
| 🧠 **AI 推理** | Core ML + Mortal 神經網絡，本地即時運算 |
| 🤖 **全自動打牌** | 打牌、吃、碰、槓、立直、和牌一鍵全自動 |
| 📊 **即時推薦** | 顯示每張牌的 Q 值與最優選擇 |
| 🔧 **Debug API** | HTTP Server 提供狀態查詢與手動觸發 |

## 📸 截圖

### macOS
![Naki macOS 介面](image.png)
過碰推薦
![Recommend](image-1.png)

### iOS / iPhone
![Naki iPhone 介面](iphone.png)

## 🏗️ 架構設計

```
┌─────────────────────────────────────────────────────────────┐
│                   WebPage (macOS 26.0+)                      │
│                   (game.maj-soul.com)                        │
│                           │                                  │
│           ┌───────────────┴───────────────┐                 │
│           │     JavaScript Modules        │                 │
│           │  naki-core / naki-websocket   │                 │
│           │  naki-autoplay / naki-game-api│                 │
│           └───────────────┬───────────────┘                 │
└───────────────────────────┼─────────────────────────────────┘
                            │ WebKit Bridge
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                     Swift Services                           │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ LiqiParser  │  │MajsoulBridge│  │WebSocketInterceptor │ │
│  │  Protobuf   │→ │ Liqi→MJAI   │→ │   JS Module Loader  │ │
│  └─────────────┘  └─────────────┘  └─────────────────────┘ │
│                           │                                  │
│  ┌────────────────────────┴────────────────────────────┐   │
│  │              NativeBotController                     │   │
│  │    libriichi.a (Rust FFI) + Core ML (Mortal)        │   │
│  └────────────────────────┬────────────────────────────┘   │
│                           │                                  │
│  ┌────────────────────────┴────────────────────────────┐   │
│  │  AutoPlayService  │  GameStateManager  │ DebugServer │   │
│  │   重試機制協調     │   響應式狀態管理   │  HTTP API   │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                  │
│                    WebViewModel (協調器)                      │
└─────────────────────────────────────────────────────────────┘
```

### 模組說明

| 模組 | 職責 |
|-----|------|
| **JavaScript Modules** | 從 Bundle 載入，處理 WebSocket 攔截與 UI 自動化 |
| **AutoPlayService** | 自動打牌重試機制、動作協調、成功/失敗回調 |
| **GameStateManager** | 集中管理遊戲狀態，提供 SwiftUI 響應式更新 |
| **WebViewModel** | 協調器角色，串接各服務與 UI 層 |

## 🚀 快速開始

### 系統需求
- macOS 26.0+ (需要 WebPage API)
- Xcode 26.0+
- **Apple Silicon (M1/M2/M3/M4)** - 不支援 Intel Mac

> **注意**：由於 libriichi (Rust FFI) 僅編譯為 arm64 架構，本應用僅支援 Apple Silicon Mac。

### 編譯

```bash
git clone https://github.com/Sunalamye/Naki.git
cd Naki
open Naki.xcodeproj
# Cmd + R 執行
```

### 依賴項目

| 依賴 | 說明 |
|-----|------|
| [MortalSwift](../MortalSwift) | Rust FFI + Core ML 封裝 |
| mortal.mlmodelc | Mortal AI 模型 (Core ML 格式) |

## 🔧 Debug API

啟動後自動開啟 HTTP Server (port 8765)，支援 MCP 工具或傳統 HTTP 呼叫：

### MCP 工具 (推薦用於 AI 助手)

| 工具 | 說明 |
|-----|------|
| `mcp__naki__get_logs` | 查看日誌 |
| `mcp__naki__bot_status` | Bot 狀態、手牌、AI 推薦 |
| `mcp__naki__bot_trigger` | 手動觸發自動打牌 |
| `mcp__naki__execute_js` | 執行 JavaScript |
| `mcp__naki__game_state` | 遊戲狀態 |

### HTTP 端點 (傳統方式)

```bash
curl http://localhost:8765/logs              # 查看日誌
curl http://localhost:8765/bot/status        # Bot 狀態
curl -X POST http://localhost:8765/bot/trigger  # 手動觸發
curl -X POST http://localhost:8765/js -d 'code' # 執行 JS
```

## 🤖 MCP Server (Claude Code 整合)

Naki 支援 [Model Context Protocol (MCP)](https://modelcontextprotocol.io/)，讓 AI 助手可以直接操作遊戲。

### 配置 Claude Code

```bash
claude mcp add --transport http naki http://localhost:8765/mcp
```

### 可用工具 (22 個)

| 類別 | 工具 | 說明 |
|-----|------|------|
| **Bot 控制** | `bot_status` | 獲取 Bot 狀態、手牌、AI 推薦 |
| | `bot_trigger` | 手動觸發自動打牌 |
| **遊戲操作** | `game_state` | 獲取遊戲狀態 |
| | `game_discard` | 打出指定牌 |
| | `game_action` | 執行動作 (pass/chi/pon/kan) |
| **調試** | `execute_js` | 執行 JavaScript |
| | `get_logs` | 獲取日誌 |

### 使用範例

在 Claude Code 中直接使用 MCP 工具：

```
# 獲取 Bot 狀態和 AI 推薦
mcp__naki__bot_status

# 手動觸發自動打牌
mcp__naki__bot_trigger

# 執行 JavaScript 查詢遊戲狀態
mcp__naki__execute_js({ code: "window.location.href" })

# 獲取完整 API 文檔
mcp__naki__get_help
```

詳見 [MCP Server 指南](docs/mcp-server-guide.md)

## 📋 TODO

- [x] 設定介面優化
- [x] 出牌高亮提示
- [x] 動作按鈕推薦高亮（吃/碰/槓/立直）
- [x] MCP Server 模組化重構
- [x] iOS 跨平台 UI 支援
- [ ] MortalSwift 閃退問題待解決
- [ ] 三麻模式支援

## 🤝 貢獻

歡迎提交 Issue 和 Pull Request！

## 📄 許可證

**AGPL-3.0 with Commons Clause** - 詳見 [LICENSE](LICENSE)

> ⚠️ 本軟體不得用於商業銷售目的。

## ⚖️ 免責聲明

### 教育與學習目的

本專案的開發目的是為了：
- 學習 Swift/SwiftUI 原生 macOS 應用開發
- 研究 Core ML 機器學習模型整合
- 理解 WebSocket 通訊協議與攔截技術
- 探索 Protobuf 協議解析

### 使用風險

1. **帳號風險**：使用本工具可能違反雀魂 (Majsoul) 的服務條款，可能導致您的遊戲帳號被暫停或永久封禁。**強烈建議使用小號或測試帳號**。

2. **法律風險**：在某些地區，使用此類工具可能涉及法律問題。請確保您了解並遵守當地法律法規。

3. **無擔保**：本軟體按「現狀」提供，不提供任何明示或暗示的擔保，包括但不限於對適銷性、特定用途適用性和非侵權性的擔保。

### 責任限制

在任何情況下，作者或版權持有人均不對任何索賠、損害或其他責任負責，無論是在合約訴訟、侵權行為或其他方面，由軟體或軟體的使用或其他交易引起或與之相關。

### 第三方內容

- 本專案使用 [Mortal](https://github.com/Equim-chan/Mortal) AI 模型
- 雀魂 (Majsoul) 是貓糧工作室的註冊商標
- 本專案與貓糧工作室或悠星網絡無任何關聯

**使用本軟體即表示您已閱讀、理解並同意以上所有條款。**

## 🙏 致謝

- [Mortal](https://github.com/Equim-chan/Mortal) - 麻將 AI 模型
- [Akagi](https://github.com/shinkuan/Akagi) - Python 版參考實現
- 雀魂 (Majsoul) - 遊戲平台

---

<p align="center">
  Made with ❤️ for Mahjong enthusiasts
</p>
