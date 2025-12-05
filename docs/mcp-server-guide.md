# MCP Server 指南

**日期**: 2025-12-05
**版本**: 1.0.0
**協議版本**: MCP 2025-03-26

---

## 概述

Naki 的 Debug Server 支援 [Model Context Protocol (MCP)](https://modelcontextprotocol.io/)，讓 AI 助手（如 Claude Code）可以直接調用 Naki 的功能，實現遊戲狀態監控、Bot 控制、JavaScript 執行等操作。

### 特點

- **無需 Node.js** - 純 Swift 實現，HTTP transport
- **22 個工具** - 涵蓋 Bot 控制、遊戲操作、調試功能
- **向後相容** - 現有 HTTP 端點繼續可用
- **JSON-RPC 2.0** - 標準 MCP 協議

---

## 快速開始

### 1. 啟動 Naki

確保 Naki app 已啟動，Debug Server 會自動在 port 8765 運行。

### 2. 配置 Claude Code

```bash
claude mcp add --transport http naki http://localhost:8765/mcp
```

### 3. 驗證連接

```bash
# 測試 MCP 端點
curl -X POST http://localhost:8765/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}'
```

成功響應：
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-03-26",
    "serverInfo": {
      "name": "naki",
      "version": "1.2.0"
    },
    "capabilities": {
      "tools": {}
    }
  }
}
```

---

## MCP 端點

### 端點資訊

| 項目 | 值 |
|-----|---|
| URL | `http://localhost:8765/mcp` |
| Method | POST |
| Content-Type | application/json |
| Protocol | JSON-RPC 2.0 |

### 支援的方法

| 方法 | 說明 |
|-----|------|
| `initialize` | 初始化連接，返回服務器能力 |
| `initialized` | 客戶端確認初始化完成 |
| `tools/list` | 列出所有可用工具 |
| `tools/call` | 調用指定工具 |

---

## 工具列表 (22 個)

### 系統類

| 工具名稱 | 說明 | 參數 |
|---------|------|------|
| `get_status` | 獲取 Debug Server 狀態和埠號 | 無 |
| `get_help` | 獲取完整的 API 文檔 | 無 |
| `get_logs` | 獲取 Debug 日誌（最多 10,000 條） | 無 |
| `clear_logs` | 清空所有日誌 | 無 |

### Bot 控制類

| 工具名稱 | 說明 | 參數 |
|---------|------|------|
| `bot_status` | 獲取 Bot 狀態、手牌、AI 推薦動作 | 無 |
| `bot_trigger` | 手動觸發自動打牌 | 無 |
| `bot_ops` | 探索可用的副露操作（吃/碰/槓） | 無 |
| `bot_deep` | 深度探索 naki API（所有方法） | 無 |
| `bot_chi` | 測試吃操作 | 無 |
| `bot_pon` | 測試碰操作 | 無 |

### 遊戲狀態類

| 工具名稱 | 說明 | 參數 |
|---------|------|------|
| `game_state` | 獲取當前遊戲狀態 | 無 |
| `game_hand` | 獲取手牌資訊 | 無 |
| `game_ops` | 獲取當前可用操作 | 無 |
| `game_discard` | 打出指定索引的牌 | `tileIndex`: integer (0-13) |
| `game_action` | 執行遊戲動作 | `action`: string, `params`: object (可選) |

### JavaScript 執行

| 工具名稱 | 說明 | 參數 |
|---------|------|------|
| `execute_js` | 在遊戲 WebView 中執行 JavaScript | `code`: string |

### 探索類

| 工具名稱 | 說明 | 參數 |
|---------|------|------|
| `detect` | 檢測遊戲 API 是否可用 | 無 |
| `explore` | 探索遊戲物件結構 | 無 |

### UI 操作類

| 工具名稱 | 說明 | 參數 |
|---------|------|------|
| `test_indicators` | 顯示測試指示器 | 無 |
| `click` | 在指定座標點擊 | `x`: number, `y`: number, `label`: string (可選) |
| `calibrate` | 設定校準參數 | `tileSpacing`, `offsetX`, `offsetY`: number |

---

## 使用範例

### 獲取工具列表

```bash
curl -X POST http://localhost:8765/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

### 獲取 Bot 狀態

```bash
curl -X POST http://localhost:8765/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":2,
    "method":"tools/call",
    "params":{
      "name":"bot_status",
      "arguments":{}
    }
  }'
```

### 執行 JavaScript

```bash
curl -X POST http://localhost:8765/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":3,
    "method":"tools/call",
    "params":{
      "name":"execute_js",
      "arguments":{
        "code":"window.view.DesktopMgr.Inst.mainrole.hand.length"
      }
    }
  }'
```

### 打出指定牌

```bash
curl -X POST http://localhost:8765/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":4,
    "method":"tools/call",
    "params":{
      "name":"game_discard",
      "arguments":{
        "tileIndex":3
      }
    }
  }'
```

### 執行遊戲動作

```bash
curl -X POST http://localhost:8765/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":5,
    "method":"tools/call",
    "params":{
      "name":"game_action",
      "arguments":{
        "action":"pass"
      }
    }
  }'
```

---

## Claude Code 使用

配置完成後，Claude Code 可以直接使用這些工具：

```
# 在 Claude Code 中使用
mcp__naki__bot_status
mcp__naki__execute_js --code "window.location.href"
mcp__naki__game_discard --tileIndex 5
mcp__naki__bot_trigger
```

### 常見工作流程

#### 1. 監控遊戲狀態

```
1. mcp__naki__bot_status     # 查看 Bot 狀態和推薦
2. mcp__naki__game_hand      # 查看手牌詳情
3. mcp__naki__get_logs       # 查看操作日誌
```

#### 2. 手動控制打牌

```
1. mcp__naki__bot_status     # 查看 AI 推薦
2. mcp__naki__bot_trigger    # 執行推薦動作
3. mcp__naki__get_logs       # 確認執行結果
```

#### 3. JavaScript 調試

```
1. mcp__naki__detect         # 檢測 API 可用性
2. mcp__naki__explore        # 探索遊戲物件
3. mcp__naki__execute_js     # 執行自定義腳本
```

---

## 響應格式

### 成功響應

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"status\":\"running\",\"port\":8765}"
      }
    ],
    "isError": false
  }
}
```

### 錯誤響應

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Error message here"
      }
    ],
    "isError": true
  }
}
```

### JSON-RPC 錯誤

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32601,
    "message": "Method not found"
  }
}
```

---

## 錯誤代碼

| 代碼 | 說明 |
|-----|------|
| -32700 | Parse error - JSON 解析失敗 |
| -32600 | Invalid Request - 無效請求 |
| -32601 | Method not found - 方法不存在 |
| -32602 | Invalid params - 參數錯誤 |
| -32603 | Internal error - 內部錯誤 |

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

## 與 HTTP API 的對應

MCP 工具與現有 HTTP 端點的對應關係：

| MCP 工具 | HTTP 端點 |
|---------|----------|
| `get_status` | GET /status |
| `get_help` | GET /help |
| `get_logs` | GET /logs |
| `clear_logs` | DELETE /logs |
| `bot_status` | GET /bot/status |
| `bot_trigger` | POST /bot/trigger |
| `game_state` | GET /game/state |
| `game_hand` | GET /game/hand |
| `game_ops` | GET /game/ops |
| `game_discard` | POST /game/discard |
| `game_action` | POST /game/action |
| `execute_js` | POST /js |
| `detect` | GET /detect |
| `explore` | GET /explore |
| `click` | POST /click |
| `calibrate` | POST /calibrate |

---

## 故障排除

### MCP 連接失敗

1. 確認 Naki app 已啟動
2. 確認 port 8765 未被佔用：`lsof -i :8765`
3. 測試 HTTP 端點：`curl http://localhost:8765/status`

### 工具調用失敗

1. 檢查參數格式是否正確
2. 查看日誌：`mcp__naki__get_logs`
3. 確認遊戲已加載：`mcp__naki__detect`

### Claude Code 找不到工具

1. 重新添加 MCP server：
   ```bash
   claude mcp remove naki
   claude mcp add --transport http naki http://localhost:8765/mcp
   ```
2. 重啟 Claude Code

---

## 相關文檔

- [Debug API 完整列表](debug-api-help-endpoint.md)
- [架構深度詳解](architecture-deep-dive.md)
- [Majsoul WebUI 物件參考](majsoul-webui-objects-reference.md)

---

**文檔版本**: 1.0.0
**更新日期**: 2025-12-05
**驗證狀態**: 已通過構建測試
