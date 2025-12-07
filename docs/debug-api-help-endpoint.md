# Debug API 完整指南

**版本**: 2.0
**更新日期**: 2025-12-07
**HTTP Port**: 8765

---

## 概述

Naki 提供 HTTP Debug Server，用於監控遊戲狀態、控制 Bot、執行遊戲操作。

### 兩種使用方式

| 方式 | 說明 | 推薦 |
|------|------|------|
| **MCP 工具** | Claude Code 直接調用 | ⭐ 推薦 |
| **HTTP 端點** | curl 或瀏覽器訪問 | 傳統方式 |

> **提示**: MCP 工具功能更完整（47 個工具），詳見 [mcp-server-guide.md](mcp-server-guide.md)

---

## HTTP 端點列表

### 系統類

| 端點 | 方法 | 說明 |
|------|------|------|
| `/` | GET | HTML 首頁 |
| `/help` | GET | JSON API 文檔 |
| `/status` | GET | 伺服器狀態 |
| `/logs` | GET | 獲取 Debug 日誌 |
| `/logs` | DELETE | 清空日誌 |

### Bot 控制類

| 端點 | 方法 | 說明 |
|------|------|------|
| `/bot/status` | GET | Bot 狀態、手牌、AI 推薦 |
| `/bot/trigger` | POST | 手動觸發自動打牌 |
| `/bot/ops` | GET | 探索可用的副露操作 |
| `/bot/deep` | GET | 深度探索 naki API |
| `/bot/chi` | POST | 測試吃操作 |
| `/bot/pon` | POST | 測試碰操作 |
| `/bot/sync` | POST | 強制斷線重連重建狀態 |

### 遊戲狀態類

| 端點 | 方法 | 說明 | Body |
|------|------|------|------|
| `/game/state` | GET | 當前遊戲狀態 | - |
| `/game/hand` | GET | 手牌資訊 | - |
| `/game/ops` | GET | 當前可用操作 | - |
| `/game/discard` | POST | 打出指定牌 | `{"tileIndex": 0-13}` |
| `/game/action` | POST | 執行遊戲動作 | `{"action": "pass"}` |

### JavaScript 執行

| 端點 | 方法 | 說明 | Body |
|------|------|------|------|
| `/js` | POST | 執行 JavaScript | JS 代碼（需 return） |

### 探索類

| 端點 | 方法 | 說明 |
|------|------|------|
| `/detect` | GET | 檢測遊戲 API 可用性 |
| `/explore` | GET | 探索遊戲物件結構 |

### UI 操作類

| 端點 | 方法 | 說明 | Body |
|------|------|------|------|
| `/test-indicators` | GET | 顯示測試指示器 | - |
| `/click` | POST | 在指定座標點擊 | `{"x": 100, "y": 200}` |
| `/calibrate` | POST | 設定校準參數 | `{"offsetX": -200}` |

---

## 使用範例

### 查看 Bot 狀態

```bash
curl http://localhost:8765/bot/status | jq .
```

### 手動觸發打牌

```bash
curl -X POST http://localhost:8765/bot/trigger
```

### 執行 JavaScript

```bash
curl -X POST http://localhost:8765/js -d 'return window.location.href'
```

### 打出第 3 張牌

```bash
curl -X POST http://localhost:8765/game/discard \
  -H "Content-Type: application/json" \
  -d '{"tileIndex": 2}'
```

---

## 常見工作流程

### 1. 監控遊戲狀態

```bash
curl http://localhost:8765/bot/status   # Bot 狀態和推薦
curl http://localhost:8765/game/hand    # 手牌詳情
curl http://localhost:8765/logs         # 操作日誌
```

### 2. 手動控制打牌

```bash
curl http://localhost:8765/bot/status          # 查看 AI 推薦
curl -X POST http://localhost:8765/bot/trigger # 執行推薦動作
```

### 3. JavaScript 調試

```bash
curl http://localhost:8765/detect   # 檢測 API 可用性
curl http://localhost:8765/explore  # 探索遊戲物件
curl -X POST http://localhost:8765/js -d 'return JSON.stringify(window.view.DesktopMgr.Inst.mainrole.hand.length)'
```

---

## 牌記號說明 (MJAI 格式)

| 類型 | 格式 | 範例 |
|-----|------|------|
| 萬子 | 1-9m | 1m, 5m, 9m |
| 筒子 | 1-9p | 1p, 5p, 9p |
| 索子 | 1-9s | 1s, 5s, 9s |
| 紅寶牌 | 5Xr | 5mr, 5pr, 5sr |
| 字牌 | E/S/W/N/P/F/C | E(東), S(南), W(西), N(北), P(白), F(發), C(中) |

---

## 故障排除

### 連接失敗

```bash
# 確認 Naki 已啟動
curl http://localhost:8765/status

# 檢查端口是否被佔用
lsof -i :8765
```

### 遊戲 API 不可用

```bash
# 檢測遊戲是否已載入
curl http://localhost:8765/detect
```

---

## 相關文檔

- [mcp-server-guide.md](mcp-server-guide.md) - MCP 工具完整指南（47 個工具）
- [architecture-deep-dive.md](architecture-deep-dive.md) - 架構深度詳解

---

**文件位置**: `Naki/Services/Debug/DebugServer.swift`
