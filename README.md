# Naki (鳴き) - 雀魂麻將 AI 助手

<p align="center">
  <img src="https://img.shields.io/badge/Version-1.1.3-green" alt="Version">
  <img src="https://img.shields.io/badge/Platform-macOS%2013+-blue" alt="Platform">
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

- 🎮 **內嵌遊戲視窗** - WKWebView 直接載入雀魂網頁，無需瀏覽器
- 🔍 **WebSocket 攔截** - JavaScript 注入攔截遊戲通訊
- 🧠 **Core ML 推理** - 使用 Mortal AI 神經網絡模型
- 📊 **實時推薦** - 顯示每張牌的 Q 值和最佳打牌建議
- 🀄 **手牌追蹤** - 實時顯示當前手牌狀態
- 📝 **詳細日誌** - 完整的協議解析和調試日誌
- 🤖 **全自動打牌** - 自動執行打牌、吃、碰、槓、立直、和牌等所有動作
- 🔧 **Debug HTTP Server** - 提供 `/logs`、`/bot/status`、`/bot/ops` 等調試端點

## 📸 截圖

![Naki AI 推薦介面](image.png)

*遊戲中的 AI 推薦介面 - 右側面板顯示 Bot 狀態、分數追蹤、以及每張牌的推薦機率*

## 🏗️ 項目結構

```
Naki/
├── Naki.xcodeproj/              # Xcode 項目配置
├── Naki/                        # 源代碼目錄
│   ├── App/                     # 應用入口
│   │   └── akagiApp.swift       # @main 入口點
│   │
│   ├── Views/                   # SwiftUI 視圖層
│   │   ├── ContentView.swift    # 主視圖 (工具欄+分割視圖)
│   │   ├── WebViewController.swift  # WKWebView 封裝
│   │   ├── TehaiView.swift      # 手牌顯示組件
│   │   ├── RecommendationView.swift # AI 推薦顯示
│   │   ├── BotStatusView.swift  # Bot 狀態指示器
│   │   └── LogPanel.swift       # 日誌面板
│   │
│   ├── ViewModels/              # 視圖模型層
│   │   └── WebViewModel.swift   # 主視圖模型 (Observation)
│   │
│   ├── Services/                # 服務層
│   │   ├── Bot/                 # AI Bot 服務
│   │   │   └── NativeBotController.swift  # Mortal AI 控制器
│   │   │
│   │   ├── Bridge/              # 協議橋接層
│   │   │   ├── LiqiParser.swift # 雀魂 Protobuf 解析器
│   │   │   ├── MajsoulBridge.swift  # Liqi → MJAI 轉換
│   │   │   └── WebSocketInterceptor.swift  # WS 攔截注入
│   │   │
│   │   └── LogManager.swift     # 統一日誌管理
│   │
│   ├── Resources/               # 資源文件
│   │   ├── Assets.xcassets      # 圖標和資源
│   │   └── index.html           # WebView 首頁
│   │
│   └── Documentation/           # 項目文檔
│       ├── QUICKSTART.md        # 快速開始
│       ├── TROUBLESHOOTING.md   # 故障排除
│       └── ...
│
└── build/                       # 編譯輸出 (git ignored)
```

## 🔧 技術架構

```
┌─────────────────────────────────────────────────────────────────┐
│                         WKWebView                                │
│                    (game.maj-soul.com)                          │
│                            │                                     │
│              ┌─────────────┴─────────────┐                      │
│              │  WebSocketInterceptor.js   │                      │
│              │     (JavaScript 注入)       │                      │
│              └─────────────┬─────────────┘                      │
└────────────────────────────┼────────────────────────────────────┘
                             │ Base64 WebSocket Binary
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Swift Native Layer                            │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    LiqiParser                            │   │
│  │           (Protobuf Binary → Dictionary)                 │   │
│  │                                                          │   │
│  │  • XOR 解碼 ActionPrototype                              │   │
│  │  • Varint / Length-delimited 解析                        │   │
│  │  • 支援 Notify / Request / Response                      │   │
│  └─────────────────────────┬───────────────────────────────┘   │
│                            │                                     │
│  ┌─────────────────────────┴───────────────────────────────┐   │
│  │                   MajsoulBridge                          │   │
│  │              (Liqi Protocol → MJAI JSON)                 │   │
│  │                                                          │   │
│  │  • ActionNewRound → start_kyoku + tsumo                  │   │
│  │  • ActionDealTile → tsumo                                │   │
│  │  • ActionDiscardTile → dahai                             │   │
│  │  • ActionChiPengGang → chi/pon/daiminkan                 │   │
│  └─────────────────────────┬───────────────────────────────┘   │
│                            │ MJAI JSON Events                    │
│  ┌─────────────────────────┴───────────────────────────────┐   │
│  │                NativeBotController                       │   │
│  │                                                          │   │
│  │  ┌─────────────────┐    ┌─────────────────────────┐     │   │
│  │  │   libriichi.a   │ →  │   Core ML Model         │     │   │
│  │  │  (Rust FFI)     │    │   (mortal.mlmodelc)     │     │   │
│  │  │                 │    │                         │     │   │
│  │  │ • 遊戲狀態管理   │    │ • 1012×34 觀測張量      │     │   │
│  │  │ • 觀測編碼生成   │    │ • 46 動作 Q 值輸出      │     │   │
│  │  └─────────────────┘    └─────────────────────────┘     │   │
│  └─────────────────────────┬───────────────────────────────┘   │
│                            │                                     │
│                            ▼                                     │
│                   推薦動作 + Q 值排序                             │
└─────────────────────────────────────────────────────────────────┘
```

## 📋 協議說明

### Liqi Protocol (雀魂私有協議)
- 基於 Protobuf 的二進制協議
- `ActionPrototype` 數據經過 XOR 加密
- 消息類型: Notify (0x01), Request (0x02), Response (0x03)

### MJAI Protocol (標準麻將 AI 協議)
- JSON 格式的標準化麻將事件
- 支援事件: `start_game`, `start_kyoku`, `tsumo`, `dahai`, `chi`, `pon`, `kan`, `reach`, `hora`, `end_kyoku`

### 牌面對照表
| 雀魂格式 | MJAI 格式 | 說明 |
|---------|----------|------|
| `0m/0p/0s` | `5mr/5pr/5sr` | 赤寶牌 |
| `1m-9m` | `1m-9m` | 萬子 |
| `1p-9p` | `1p-9p` | 筒子 |
| `1s-9s` | `1s-9s` | 索子 |
| `1z-4z` | `E/S/W/N` | 風牌 |
| `5z-7z` | `P/F/C` | 三元牌 |

## 🚀 快速開始

### 系統需求
- macOS 13.0+ (Ventura)
- Xcode 15.0+
- Swift 5.9+

### 編譯步驟

1. **克隆專案**
   ```bash
   git clone https://github.com/Sunalamye/Naki.git
   cd Naki
   ```

2. **添加 MortalSwift 依賴**

   在 Xcode 中添加 Swift Package:
   - File → Add Package Dependencies
   - 輸入 MortalSwift 的路徑或 URL

3. **添加 Core ML 模型**

   將 `mortal.mlmodelc` 放入項目資源目錄

4. **編譯運行**
   ```bash
   # 命令行編譯
   xcodebuild -project Naki.xcodeproj -scheme Naki build

   # 或在 Xcode 中按 Cmd + R
   ```

### 使用方式

1. 啟動 Naki 應用
2. 應用會自動載入雀魂網頁
3. 登入您的雀魂帳號
4. 進入對局後，AI 會自動開始分析
5. 右側面板顯示推薦的打牌動作

## 🔍 調試

### 日誌位置
```bash
# WebSocket 和協議日誌
/var/folders/.../T/akagi_websocket.log

# 查看實時日誌
tail -f /var/folders/.../T/akagi_websocket.log | grep -E "(Bridge|Bot|MJAI)"
```

### 常見問題

| 問題 | 解決方案 |
|-----|---------|
| AI 推薦不顯示 | 檢查日誌中是否有 `updateFailed` 錯誤 |
| 座位計算錯誤 | 確認 `authGame` 響應正確解析 seatList |
| 手牌顯示不全 | 檢查 `ActionNewRound` 的 tiles 解析 |

## 📦 依賴項目

| 依賴 | 說明 |
|-----|------|
| [MortalSwift](../MortalSwift) | Rust FFI + Core ML 封裝 |
| [libriichi](../mortal-src/libriichi) | Mortal 遊戲邏輯庫 |
| mortal.mlmodelc | Core ML 格式的 AI 模型 |

## 📋 更新日誌

### v1.1.3 (2025-12-02)
- ✅ 修復自動打牌並發問題：舊動作重試循環現在會正確退出
- ✅ 加入防抖動機制：避免同一動作在短時間內重複觸發
- ✅ 優化 log 輸出：減少重複訊息

### v1.1.2 (2025-12-02)
- ✅ 改進自動打牌穩定性：加入 oplist 輪詢等待機制
- ✅ 修復跳過 (Pass) 執行失敗的問題
- ✅ 改進動作驗證邏輯：針對每種動作類型檢查對應的 oplist 操作
- ✅ 優化延遲設定：跳過動作延遲從 0.5s 縮短至 0.1s

### v1.1.1 (2025-12-02)
- ✅ 修復自動和牌 (Hora) 執行順序問題
- ✅ 調整各動作延遲時間

### v1.1.0 (2025-12-02)
- ✅ 新增自動打牌重試機制
- ✅ 改進動作執行可靠性

### v1.0.0 (2025-12-01)
- 🎉 首次公開發布
- ✅ 完整自動打牌功能（打牌/吃/碰/槓/立直/和牌/跳過）
- ✅ Core ML 原生推理
- ✅ Debug HTTP Server

## 📋 TODO / Roadmap

### 自動打牌功能
- [x] 自動打牌基本功能（摸切/手切）
- [x] Debug Server HTTP API
- [x] 自動吃 (Chi)
- [x] 自動碰 (Pon)
- [x] 自動槓 (Kan)
- [x] 自動和牌 (Hora)
- [x] 自動跳過 (Pass)
- [x] oplist 輪詢等待機制
- [x] 動作執行驗證與重試

### 介面優化
- [ ] 輪到自己時閃爍提示 + 出牌時高亮動畫
- [x] 修復重新加載遊戲時 AI 推薦失效的問題

## 🤝 貢獻

歡迎提交 Issue 和 Pull Request！

### 開發指南

1. Fork 此專案
2. 創建功能分支 (`git checkout -b feature/amazing-feature`)
3. 提交更改 (`git commit -m 'Add amazing feature'`)
4. 推送分支 (`git push origin feature/amazing-feature`)
5. 開啟 Pull Request

## 📄 許可證

本項目採用 **AGPL-3.0 with Commons Clause** 授權 - 詳見 [LICENSE](LICENSE) 文件

> ⚠️ **Commons Clause 限制**：本軟體不得用於商業銷售目的。您可以自由使用、修改和分發，但不能將其作為付費產品或服務出售。

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
