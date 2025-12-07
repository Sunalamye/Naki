# MCP Server 指南

**版本**: 2.0.0
**工具數量**: 47 個
**協議版本**: MCP 2025-03-26

---

## 概述

Naki 支援 [Model Context Protocol (MCP)](https://modelcontextprotocol.io/)，讓 AI 助手（如 Claude Code）可以直接調用 Naki 的功能，實現遊戲狀態監控、Bot 控制、自動打牌等操作。

### 特點

- **純 Swift 實現** - 無需 Node.js，HTTP transport
- **47 個工具** - 完整的遊戲控制能力
- **向後相容** - 現有 HTTP 端點繼續可用
- **JSON-RPC 2.0** - 標準 MCP 協議

---

## 快速開始

### 1. 啟動 Naki

確保 Naki app 已啟動，MCP Server 會自動在 port 8765 運行。

### 2. 配置 Claude Code

```bash
claude mcp add --transport http naki http://localhost:8765/mcp
```

### 3. 驗證連接

```bash
curl -X POST http://localhost:8765/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}'
```

---

## 工具列表 (47 個)

### 系統類 (4 個)

| 工具名稱 | 說明 |
|---------|------|
| `get_status` | 獲取 Server 狀態和埠號 |
| `get_help` | 獲取完整 API 文檔 (JSON) |
| `get_logs` | 獲取 Debug 日誌（最多 10,000 條） |
| `clear_logs` | 清空所有日誌 |

### Bot 控制類 (7 個)

| 工具名稱 | 說明 |
|---------|------|
| `bot_status` | 獲取 Bot 狀態、手牌、AI 推薦 |
| `bot_trigger` | 手動觸發自動打牌 |
| `bot_ops` | 探索可用的副露操作（吃/碰/槓） |
| `bot_deep` | 深度探索 naki API |
| `bot_chi` | 測試吃操作 |
| `bot_pon` | 測試碰操作 |
| `bot_sync` | 強制斷線重連以重建 Bot 狀態 |

### 遊戲狀態類 (6 個)

| 工具名稱 | 說明 | 參數 |
|---------|------|------|
| `game_state` | 獲取當前遊戲狀態 | - |
| `game_hand` | 獲取手牌資訊 | - |
| `game_ops` | 獲取當前可用操作 | - |
| `game_discard` | 打出指定索引的牌 | `tileIndex`: 0-13 |
| `game_action` | 執行遊戲動作 | `action`: string |
| `game_action_verify` | 執行動作並驗證結果 | `action`: string |

### 高亮控制類 (6 個)

| 工具名稱 | 說明 | 參數 |
|---------|------|------|
| `highlight_tile` | 高亮指定手牌 | `tileIndex`, `color` |
| `reset_tile_color` | 重置手牌顏色 | `tileIndex` (可選) |
| `highlight_status` | 獲取高亮狀態 | - |
| `highlight_settings` | 設置高亮選項 | `showTileColor`, `showNativeEffect` |
| `show_recommendations` | 顯示多個推薦高亮 | `recommendations`: JSON |
| `hide_highlight` | 隱藏所有高亮 | - |

**顏色選項**: `green` (推薦度高), `orange` (中), `red` (低), `white` (重置), 或自訂 RGBA

### 表情類 (4 個)

| 工具名稱 | 說明 | 參數 |
|---------|------|------|
| `game_emoji` | 發送表情 | `emo_id`: 0-8, `count`: 1-5 |
| `game_emoji_list` | 獲取可用表情列表 | - |
| `game_emoji_auto_reply` | 切換自動回應表情 | `enabled` (可選) |
| `game_emoji_listen` | 獲取表情廣播記錄 | `clear` (可選) |

### 大廳類 (9 個)

| 工具名稱 | 說明 | 參數 |
|---------|------|------|
| `lobby_status` | 獲取大廳狀態 | - |
| `lobby_match_modes` | 獲取匹配模式列表 | - |
| `lobby_start_match` | 開始段位場匹配 | `match_mode` |
| `lobby_cancel_match` | 取消匹配 | - |
| `lobby_match_status` | 獲取匹配狀態 | - |
| `lobby_navigate` | 導航到指定頁面 | `page`: 0-3 |
| `lobby_heartbeat` | 發送心跳防閒置 | - |
| `lobby_anti_idle` | 切換自動防閒置 | `enabled` (可選) |
| `lobby_idle_status` | 獲取閒置狀態 | - |
| `lobby_account_level` | 獲取帳號段位 | - |

**匹配模式 ID**:
| ID | 段位場 |
|----|-------|
| 1, 2 | 銅東, 銅半 |
| 4, 5 | 銀東, 銀半 |
| 7, 8 | 金東, 金半 |
| 10, 11 | 玉東, 玉半 |
| 13, 14 | 王座東, 王座半 |

### UI 控制類 (11 個)

| 工具名稱 | 說明 | 參數 |
|---------|------|------|
| `execute_js` | 執行 JavaScript | `code`: string |
| `detect` | 檢測遊戲 API 可用性 | - |
| `explore` | 探索遊戲物件結構 | - |
| `test_indicators` | 顯示測試指示器 | - |
| `click` | 在指定座標點擊 | `x`, `y`, `label` |
| `calibrate` | 設定校準參數 | `tileSpacing`, `offsetX`, `offsetY` |
| `ui_names_status` | 獲取玩家名稱顯示狀態 | - |
| `ui_names_hide` | 隱藏所有玩家名稱 | - |
| `ui_names_show` | 顯示所有玩家名稱 | - |
| `ui_names_toggle` | 切換玩家名稱顯示 | - |

---

## Claude Code 使用範例

配置完成後，直接使用 MCP 工具：

```
# 獲取 Bot 狀態和 AI 推薦
mcp__naki__bot_status

# 手動觸發自動打牌
mcp__naki__bot_trigger

# 開始銀之間半莊匹配
mcp__naki__lobby_start_match --match_mode 5

# 發送表情
mcp__naki__game_emoji --emo_id 3 --count 2

# 高亮第 5 張牌為綠色
mcp__naki__highlight_tile --tileIndex 5 --color green

# 執行 JavaScript
mcp__naki__execute_js --code "return window.location.href"
```

### 常見工作流程

#### 1. 自動段位場

```
1. mcp__naki__lobby_status           # 確認在大廳
2. mcp__naki__lobby_navigate --page 1  # 前往段位場
3. mcp__naki__lobby_start_match --match_mode 5  # 開始銀半
4. mcp__naki__bot_status             # 等待遊戲開始，查看推薦
```

#### 2. 調試遊戲狀態

```
1. mcp__naki__detect                 # 檢測 API 可用性
2. mcp__naki__game_state             # 獲取遊戲狀態
3. mcp__naki__game_hand              # 查看手牌
4. mcp__naki__get_logs               # 查看操作日誌
```

#### 3. 手牌高亮測試

```
1. mcp__naki__highlight_status       # 查看當前高亮狀態
2. mcp__naki__highlight_tile --tileIndex 0 --color green  # 高亮第一張
3. mcp__naki__hide_highlight         # 清除所有高亮
```

---

## 牌記號說明

MCP 工具中使用的牌記號遵循 MJAI 格式：

| 類型 | 格式 | 範例 |
|-----|------|------|
| 萬子 | 1-9m | 1m, 5m, 9m |
| 筒子 | 1-9p | 1p, 5p, 9p |
| 索子 | 1-9s | 1s, 5s, 9s |
| 紅寶牌 | 5Xr | 5mr, 5pr, 5sr |
| 字牌 | E/S/W/N/P/F/C | E(東), S(南), W(西), N(北), P(白), F(發), C(中) |

---

## HTTP API 對照表

MCP 工具與 HTTP 端點對應：

| MCP 工具 | HTTP 端點 |
|---------|----------|
| `get_status` | GET /status |
| `get_logs` | GET /logs |
| `bot_status` | GET /bot/status |
| `bot_trigger` | POST /bot/trigger |
| `game_state` | GET /game/state |
| `game_discard` | POST /game/discard |
| `execute_js` | POST /js |

---

## 故障排除

### MCP 連接失敗

1. 確認 Naki app 已啟動
2. 確認 port 8765 未被佔用：`lsof -i :8765`
3. 測試 HTTP：`curl http://localhost:8765/status`

### 工具找不到

```bash
# 重新添加 MCP server
claude mcp remove naki
claude mcp add --transport http naki http://localhost:8765/mcp
```

### 遊戲 API 不可用

```
mcp__naki__detect  # 檢查遊戲是否已載入
```

---

## 相關文檔

- [Debug API 完整列表](debug-api-help-endpoint.md)
- [架構深度詳解](architecture-deep-dive.md)
- [Majsoul WebUI 物件參考](majsoul-webui-objects-reference.md)

---

**更新日期**: 2025-12-07
