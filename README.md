# Naki (鳴き) - 雀魂麻將 AI 助手

<p align="center">
  <img src="https://img.shields.io/badge/Version-2.0.0-green" alt="Version">
  <img src="https://img.shields.io/badge/Platform-macOS%2026+-blue" alt="Platform">
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

![Naki AI 推薦介面](image.png)

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
- Apple Silicon 或 Intel Mac

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

啟動後自動開啟 HTTP Server (port 8765)：

```bash
# 查看日誌
curl http://localhost:8765/logs

# Bot 狀態
curl http://localhost:8765/bot/status

# 手動觸發自動打牌
curl -X POST http://localhost:8765/bot/trigger

# 執行 JavaScript
curl -X POST http://localhost:8765/js -d 'window.location.href'
```

## 📋 TODO

- [x] 設定介面優化
- [x] 出牌高亮提示
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
