# Naki MCP Server

**最後核對**：2026-08-02，source（`MCPToolRegistry.registerBuiltInTools()`）  
**Endpoint**：`http://127.0.0.1:8765/mcp`  
**工具數**：不寫死——查 live `tools/list` 或 `get_status.toolsCount`

MCP 與 Debug HTTP API 由同一個 Naki process／loopback port 提供。所有工具名稱與 schema 以 live `tools/list` 為準；本文件不保存已移除的 Laya 工具。

Debug HTTP endpoint（`/status`、`/logs`、`/screenshot`、`/game/*`、`/bot/*`…）的清單不在本文件裡：
`GET /` 的首頁由 `DebugServer.endpoints` 這張路由表直接產生，是唯一不會漂移的來源。

`initialize` 回的 `serverInfo.version` 讀 `Info.plist`（`NakiAppVersion`），與 App 版本同一個數字。

## 協定版本（雙版本並存）

程式端唯一來源是 `command/Services/MCP/MCPProtocolSpec.swift`。

| 支援版本 | 進入方式 |
|---|---|
| `2026-07-28`（current） | 請求 `params._meta` 帶 `io.modelcontextprotocol/protocolVersion` |
| `2025-11-25` / `2025-06-18` / `2025-03-26` | `initialize` handshake（client 宣告的版本我們支援就原樣回報） |

era 由請求自己決定，不靠連線狀態——這正是 2026-07-28 的 stateless 模型。

**2026-07-28 路徑的差異**

- `server/discover`（規格 MUST）：回 `supportedVersions`、`capabilities`、`instructions`、`_meta['io.modelcontextprotocol/serverInfo']`，並帶 `ttlMs` + `cacheScope`。
- 每個 result 帶 `resultType: "complete"` 與 `_meta` 裡的 serverInfo。
- `tools/list` 另外帶 `ttlMs` + `cacheScope: "public"`（CacheableResult），順序＝registry 註冊順序（deterministic）。
- 版本不支援回 `-32022`，`data.supported` 列出全部支援版本，HTTP 400。
- `MCP-Protocol-Version` header 與 body `_meta` 不一致、或 `Mcp-Name` 與 `params.name` 不一致 → `-32020`，HTTP 400。
- 未知方法 HTTP 404（body 仍是 `-32601`）。`initialize`、`ping`、`logging/setLevel` 在這條路徑上就是未知方法。

**兩條路徑都有的**

- 工具結果帶 `structuredContent`（真 JSON 物件）＋ `content[0].text`（同一份 JSON 字串化）；所有工具都有 `outputSchema`（`MCPToolOutputSchema.swift`）。
- 參數錯誤回 Tool Execution Error（`isError: true`），不是 protocol error——模型可以自己改參數重試。
- JSON-RPC batch（陣列 body）明確拒絕（`-32600`）。
- 非 loopback `Origin` 一律 403（**所有** Debug endpoint，不只 `/mcp`）；沒帶 Origin 的 curl／MCP client 不受影響。

未實作且不打算實作：Authorization／OAuth、Roots／Sampling／Logging（已 Deprecated）、Tasks extension、MRTR、`subscriptions/listen`、session 與 SSE resumability。

```bash
# 2026-07-28 路徑
curl -s http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: server/discover' \
  -d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
```

## 設定

```bash
claude mcp add --transport http naki http://127.0.0.1:8765/mcp
```

Repo agent 應先讀 `.claude/skills/naki-mcp-proxy/SKILL.md`，讓 proxy 先做 `tools/list` 再選工具，不可依舊 catalog 猜名稱。

## 現行工具

工具數以 live `tools/list`、`get_status.toolsCount` 或 `get_help.tools_count` 為準；
`MCPToolRegistry.registerBuiltInTools()` 是程式端唯一真實來源，三個回報欄位都直接數 registry，
所以文件與註解不再寫死數字（下表分組標題只是給人讀的索引，數字對不上時以 registry 為準）。
2026-08-01 的 live snapshot 是 42，其中含 6 個已於 2026-08-02 移除的 highlight 失敗樁。

### 系統（6）

| Tool | 作用 |
|------|------|
| `get_status` | server／port／App 版本／`toolsCount`／時間／log 路徑／JS 注入結果 |
| `get_help` | current JSON help（含 `app_version`） |
| `get_logs` | 近期記憶體 log（來源 LogManager，時間排序） |
| `clear_logs` | 清除記憶體 log（檔案 log 不動） |
| `replay_list` | 列出已錄的對局 |
| `replay_game` | 重跑錄影的決策 |

### Bot（7）

| Tool | 作用 |
|------|------|
| `bot_status` | Bot、手牌、mode、推薦 |
| `bot_trigger` | 手動觸發自動打牌 |
| `bot_ops` | pending／latest oplist |
| `bot_deep` | game snapshot、response、diagnostics |
| `bot_chi` | 送出 chi |
| `bot_pon` | 送出 pon |
| `bot_sync` | 強制 WebSocket reconnect／重建 Bot |

### 遊戲狀態／動作（6）

| Tool | 作用 |
|------|------|
| `game_state` | Swift protocol-layer game snapshot |
| `game_hand` | 手牌與推薦 |
| `game_ops` | 可用操作 |
| `game_discard` | 以牌字串 discard |
| `game_action` | 送一般 action |
| `game_action_verify` | 送 action 並等 RESPONSE／snapshot 前進 |

### JavaScript（1）

| Tool | 作用 |
|------|------|
| `execute_js` | 在 WebView 執行 function body；取值必須 `return` |

### 大廳（8）

| Tool | 作用 |
|------|------|
| `lobby_status` | Naki lobby／connection 狀態 |
| `lobby_match_modes` | 從 current config 提供可用 match modes |
| `lobby_start_match` | 開始匹配 |
| `lobby_cancel_match` | 取消匹配 |
| `lobby_account_info` | 查帳號資訊 |
| `lobby_server_time` | 唯讀 server-time request／連線自檢 |
| `lobby_heartbeat` | 送 lobby heartbeat |
| `lobby_login_beat` | 送 login beat |

### 防閒置（1）

| Tool | 作用 |
|------|------|
| `lobby_anti_idle` | 查詢或切換 Naki 自動 heartbeat |

### 友人房（7）

| Tool | 作用 |
|------|------|
| `room_create` | 建立友人房 |
| `room_add_robot` | 加入機器人 |
| `room_start` | 開局 |
| `room_info` | 查房間資訊 |
| `room_join` | 加入房間 |
| `room_leave` | 離開房間 |
| `room_quick_test` | 建房 → 補機器人 → 開局 |

### 表情（2）

| Tool | 作用 |
|------|------|
| `game_emoji` | 送表情 |
| `game_emoji_listen` | 讀取／清除已捕獲的表情廣播 |

### 高亮：沒有 MCP 工具（2026-08-02 移除 6 個失敗樁）

`highlight_tile`／`reset_tile_color`／`highlight_status`／`highlight_settings`／
`show_recommendations`／`hide_highlight` 已移除，呼叫會得到 `Unknown tool: <name>`。

它們的參數契約源自 Laya 牌物件，從來沒接到現行的 `window.__nakiHighlight` WebGL hook，
也不打算接：App 內建的自動推薦高亮由 Swift 的 `WebViewModel.syncGameHighlight()` 直接驅動
（模式 = 關閉時送 `clear()`），MCP 不需要第二個入口。要程式化取得推薦請用
`bot_status` / `game_hand`。

## 已移除，不可再呼叫

```text
detect
explore
test_indicators
click
calibrate
ui_names_status / ui_names_hide / ui_names_show / ui_names_toggle
lobby_match_status
lobby_navigate
lobby_idle_status
lobby_account_level
game_emoji_list
game_emoji_auto_reply
```

它們依賴 Laya／DesktopMgr／UI 座標或不存在的 server semantics。不要用 `execute_js` 重造同一條舊路徑。

## 安全分級

### 唯讀優先

```text
get_status, get_help, get_logs
bot_status, bot_ops, bot_deep
game_state, game_hand, game_ops
lobby_status, lobby_match_modes, lobby_account_info, lobby_server_time
room_info, game_emoji_listen(clear=false)
```

`execute_js` 只有在 code 本身唯讀時才算唯讀。

### 會改 local runtime

```text
clear_logs
bot_sync
lobby_anti_idle(enabled=...)
game_emoji_listen(clear=true)
```

### 會影響帳號／對局

```text
bot_trigger
bot_chi, bot_pon
game_discard, game_action, game_action_verify
lobby_start_match, lobby_cancel_match, lobby_heartbeat, lobby_login_beat
room_create, room_add_robot, room_start, room_join, room_leave, room_quick_test
game_emoji
```

這些只在測試帳號、明確授權與正確 oplist／gateway 下使用。

## 建議流程

### 唯讀診斷

```text
get_status
  → bot_status
  → game_state
  → game_ops
  → bot_deep（需要 request／response 細節時）
  → get_logs
```

### 對局動作

```text
game_ops
  → 確認 seat、sequence、type、combination
  → game_action_verify
  → 檢查 sent、response、verified／新 snapshot
```

不要只因 `sent.success=true` 就宣稱 server 已接受。

### 連線自檢

`lobby_server_time` 是較低風險的 request。需要確認對局 sender 時，必須在測試帳號與實際 game-gateway 下用合法動作驗證，不能把 lobby 成功外推成 game action 成功。

### Unity 唯讀 probe

```javascript
return JSON.stringify({
  canvas: !!document.getElementById('unity-canvas'),
  laya: typeof window.Laya,
  sockets: window.__nakiWebSocket?.getConnections?.(),
  highlight: window.__nakiHighlight?.state?.()
})
```

`execute_js` 是 function body，沒有 `return` 只會得到 null／undefined。

## 資料語意與限制

- 工具結果讀 `structuredContent`；`content[0].text` 只是同一份 JSON 的字串化 fallback。腳本不要再對回應做 `tr -d '\\'`。
- `outputSchema` 只宣告程式碼保證的欄位，其餘 `additionalProperties: true`——它是契約，不是完整欄位清單。
- `game_state`／`game_hand`／`game_ops` 讀 Naki 的 Swift protocol state，不是 server 完整查詢。
- `game_action_verify` 比單純 send 更好，但仍應針對終局動作確認 `ActionHule`。
- Legacy iOS 17–25 的自動路徑沒有主路徑 resolver；MCP sender 與自動模式不可混為一談。
- 三麻沒有專用 AI model。
- 完整 current facts 見 [majsoul-unity-protocol.md](majsoul-unity-protocol.md)。
