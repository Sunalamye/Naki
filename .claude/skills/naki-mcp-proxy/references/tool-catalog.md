# Naki MCP Tool Catalog

Complete reference for all 47 MCP tools available in Naki.

**Server**: `http://localhost:8765/mcp`
**Protocol**: MCP 2025-03-26 (JSON-RPC 2.0)

---

## 系統類 (4 tools)

| Tool | Description | Parameters |
|------|-------------|------------|
| `get_status` | 獲取 Server 狀態和埠號 | - |
| `get_help` | 獲取完整 API 文檔 (JSON) | - |
| `get_logs` | 獲取 Debug 日誌（最多 10,000 條） | - |
| `clear_logs` | 清空所有日誌 | - |

---

## Bot 控制類 (7 tools)

| Tool | Description | Parameters |
|------|-------------|------------|
| `bot_status` | 獲取 Bot 狀態、手牌、AI 推薦 | - |
| `bot_trigger` | 手動觸發自動打牌（執行 AI 推薦） | - |
| `bot_ops` | 探索可用的副露操作（吃/碰/槓） | - |
| `bot_deep` | 深度探索 naki API | - |
| `bot_chi` | 測試吃操作 | - |
| `bot_pon` | 測試碰操作 | - |
| `bot_sync` | 強制斷線重連以重建 Bot 狀態 | - |

---

## 遊戲狀態類 (6 tools)

| Tool | Description | Parameters |
|------|-------------|------------|
| `game_state` | 獲取當前遊戲狀態 | - |
| `game_hand` | 獲取手牌資訊 | - |
| `game_ops` | 獲取當前可用操作 | - |
| `game_discard` | 打出指定索引的牌 | `tileIndex`: 0-13 |
| `game_action` | 執行遊戲動作 | `action`: string |
| `game_action_verify` | 執行動作並驗證結果 | `action`: string |

---

## 高亮控制類 (6 tools)

| Tool | Description | Parameters |
|------|-------------|------------|
| `highlight_tile` | 高亮指定手牌 | `tileIndex`: int, `color`: string |
| `reset_tile_color` | 重置手牌顏色 | `tileIndex`: int (可選) |
| `highlight_status` | 獲取高亮狀態 | - |
| `highlight_settings` | 設置高亮選項 | `showTileColor`, `showNativeEffect`: bool |
| `show_recommendations` | 顯示多個推薦高亮 | `recommendations`: JSON array |
| `hide_highlight` | 隱藏所有高亮 | - |

**Color Options**:
- `green` - 推薦度高
- `orange` - 中等推薦
- `red` - 低推薦
- `white` - 重置
- Custom RGBA: `[r, g, b, a]`

---

## 表情類 (4 tools)

| Tool | Description | Parameters |
|------|-------------|------------|
| `game_emoji` | 發送表情 | `emo_id`: 0-8, `count`: 1-5 |
| `game_emoji_list` | 獲取可用表情列表 | - |
| `game_emoji_auto_reply` | 切換自動回應表情 | `enabled`: bool (可選) |
| `game_emoji_listen` | 獲取表情廣播記錄 | `clear`: bool (可選) |

---

## 大廳類 (9 tools)

| Tool | Description | Parameters |
|------|-------------|------------|
| `lobby_status` | 獲取大廳狀態 | - |
| `lobby_match_modes` | 獲取匹配模式列表 | - |
| `lobby_start_match` | 開始段位場匹配 | `match_mode`: int |
| `lobby_cancel_match` | 取消匹配 | - |
| `lobby_match_status` | 獲取匹配狀態 | - |
| `lobby_navigate` | 導航到指定頁面 | `page`: 0-3 |
| `lobby_heartbeat` | 發送心跳防閒置 | - |
| `lobby_anti_idle` | 切換自動防閒置 | `enabled`: bool (可選) |
| `lobby_idle_status` | 獲取閒置狀態 | - |
| `lobby_account_level` | 獲取帳號段位 | - |

**Match Mode IDs**:

| ID | 段位場 | ID | 段位場 |
|----|-------|----|----|
| 1 | 銅東 | 2 | 銅半 |
| 4 | 銀東 | 5 | 銀半 |
| 7 | 金東 | 8 | 金半 |
| 10 | 玉東 | 11 | 玉半 |
| 13 | 王座東 | 14 | 王座半 |

**Lobby Pages**:

| Page | 位置 |
|------|------|
| 0 | 主頁 |
| 1 | 段位場 |
| 2 | 友人場 |
| 3 | 大會 |

---

## UI 控制類 (11 tools)

| Tool | Description | Parameters |
|------|-------------|------------|
| `execute_js` | 執行 JavaScript | `code`: string |
| `detect` | 檢測遊戲 API 可用性 | - |
| `explore` | 探索遊戲物件結構 | - |
| `test_indicators` | 顯示測試指示器 | - |
| `click` | 在指定座標點擊 | `x`, `y`: int, `label`: string |
| `calibrate` | 設定校準參數 | `tileSpacing`, `offsetX`, `offsetY`: int |
| `ui_names_status` | 獲取玩家名稱顯示狀態 | - |
| `ui_names_hide` | 隱藏所有玩家名稱 | - |
| `ui_names_show` | 顯示所有玩家名稱 | - |
| `ui_names_toggle` | 切換玩家名稱顯示 | - |

---

## 牌記號說明 (MJAI Format)

| 類型 | 格式 | 範例 |
|-----|------|------|
| 萬子 | 1-9m | 1m, 5m, 9m |
| 筒子 | 1-9p | 1p, 5p, 9p |
| 索子 | 1-9s | 1s, 5s, 9s |
| 紅寶牌 | 5Xr | 5mr, 5pr, 5sr |
| 字牌 | E/S/W/N/P/F/C | E(東), S(南), W(西), N(北), P(白), F(發), C(中) |

---

## Tool Invocation Examples

### Claude Code Format

```
mcp__naki__bot_status
mcp__naki__bot_trigger
mcp__naki__game_action --action "dahai 5m"
mcp__naki__highlight_tile --tileIndex 5 --color green
mcp__naki__lobby_start_match --match_mode 5
mcp__naki__execute_js --code "return window.location.href"
```

### HTTP API Mapping

| MCP Tool | HTTP Endpoint |
|---------|--------------|
| `get_status` | GET /status |
| `get_logs` | GET /logs |
| `bot_status` | GET /bot/status |
| `bot_trigger` | POST /bot/trigger |
| `game_state` | GET /game/state |
| `execute_js` | POST /js |

---

**Last Updated**: 2026-01-01
