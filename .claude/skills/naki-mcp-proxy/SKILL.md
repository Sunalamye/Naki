---
name: naki-mcp-proxy
description: Live-only router for Naki's current 42 MCP tools. Use for every Naki status, game, bot, lobby, room, Unity probe, or action request; discover the running registry first and never answer from a stale catalog.
allowed-tools:
  - Task
  - Read
  - Bash
---

# Naki MCP Proxy

Base directory: {baseDir}

<IMPORTANT>
每一次 Naki 查詢都必須真的連到正在執行的 Naki MCP server。先做 live `tools/list`，再依該次回傳的 schema 呼叫實際工具。除了「目前有哪些工具」本身可由 `tools/list` 回答外，只讀 repo、skill、catalog、舊 log 或先前結果都不算完成查詢。

若 Naki 無法連線，回報「live Naki 不可用／本次未驗證」並停止；不可拿靜態文件或記憶內容冒充即時結果。
</IMPORTANT>

## Current contract

- Default endpoint: `http://127.0.0.1:8765/mcp`.
- 2026-08-01 的 live registry 基準為 42 tools；2026-08-02 移除 6 個 highlight 失敗樁後靜態計數 38。數字、名稱與參數一律以每次 live `tools/list` 為準。
- 雀魂頁面是 Unity WebGL，不是 Laya。`window.Laya`、`GameMgr`、`uiscript`、`view.DesktopMgr`、`cfg`、`app.NetAgent` 都不是可用查詢面。
- 遊戲狀態由 Naki 攔截 WebSocket、解析 Liqi protobuf 後累積在 Swift state；動作由 Naki 組 Liqi REQUEST 並送到正確 gateway。
- `execute_js` 只用於 Unity/page/WebSocket/WebGL 的唯讀 probe。遊戲狀態走 `game_*`，動作走 `game_action_verify`；禁止用 JS 重造遊戲物件、raw request 或座標點擊。

## Required execution protocol

### 1. Connect and discover

對每一個使用者 request：

1. 連到 live Naki MCP endpoint。
2. 呼叫 `tools/list`。
3. 在這次回傳中確認工具存在，並採用 live `inputSchema`；不可依 catalog 猜參數。
4. 若問題不是 registry 本身，再呼叫至少一個能回答該問題的 live Naki tool。

### 2. Choose the current route

| Intent | Read/query route | Mutation route |
|---|---|---|
| Server／工具 | `get_status`, `get_help` | `clear_logs` 僅在明確要求時 |
| Bot／AI | `bot_status`, `bot_ops`, `bot_deep` | `bot_trigger`, `bot_chi`, `bot_pon`, `bot_sync` |
| 對局狀態 | `game_state`, `game_hand`, `game_ops` | `game_action_verify`；必要時 `game_discard`／`game_action` |
| 大廳 | `lobby_status`, `lobby_match_modes`, `lobby_account_info`, `lobby_server_time` | `lobby_start_match`, `lobby_cancel_match`, heartbeat tools |
| 友人房 | `room_info` | `room_create`, `room_add_robot`, `room_start`, `room_join`, `room_leave`, `room_quick_test` |
| 表情 | `game_emoji_listen`（`clear=false`） | `game_emoji` 或 `clear=true` |
| Unity 頁面 | `execute_js` 的唯讀 probe | 不用 JS 改遊戲狀態或模擬點擊 |

純查詢一律使用 read/query route。會影響帳號、排隊、房間、對局、連線或 log 的工具，只有在使用者明確要求該副作用時才能呼叫。

### 3. Execute against live Naki

若需要 agent isolation，派出的 agent 也必須遵守同一條 live 規則：

```text
Connect to the configured Naki MCP server.
1. Call live tools/list for this request.
2. Select only a tool present in that response and use its returned schema.
3. Call the live tool; do not answer from repo documentation or earlier output.
4. Return the raw verification fields plus a concise interpretation.
5. If connection fails, report live Naki unavailable and do not infer a result.
```

### 4. Verify the meaning of the result

- `game_state`／`game_hand`／`game_ops` 是 live Naki process 內的 protocol-layer snapshot，不是每次向雀魂 server 重新抓一份完整 snapshot；回報時要保留這個資料語意。
- 動作前先讀 `game_ops`，確認 server 提供的 `sequence`、`type`、`combination`。
- 優先用 `game_action_verify`。`sent.success=true` 只表示 bytes 已交給 WebSocket，不等於 server 接受；要看同 msgId RESPONSE、`verified`、oplist/snapshot 推進，以及終局時的權威 action。
- 只有工具實際回傳的資料可標「已查到」。連線失敗、無對局或 snapshot 缺失都要標「未驗證」。

## Current 42-tool shape

| Category | Count | Notes |
|---|---:|---|
| System | 4 | status/help/logs |
| Bot | 7 | Swift state + Liqi actions |
| Game | 6 | state/hand/ops/action |
| JavaScript | 1 | read-only Unity probe |
| Lobby | 8 | `.lq.Lobby.*` |
| Anti-idle | 1 | Swift heartbeat scheduler |
| Room | 7 | protocol room flow |
| Emoji | 2 | Liqi broadcast send/capture |
| Highlight compatibility stubs | 6 | fixed unavailable; not a working UI route |

The six highlight tools remain in the registry only as explicit failure stubs. Naki's built-in `window.__nakiHighlight` WebGL renderer is a separate path; do not claim an MCP highlight call succeeded.

## Removed routes

Never call or recreate these old Laya/UI routes:

```text
detect, explore, test_indicators, click, calibrate
ui_names_status, ui_names_hide, ui_names_show, ui_names_toggle
lobby_match_status, lobby_navigate, lobby_idle_status, lobby_account_level
game_emoji_list, game_emoji_auto_reply
```

Do not replace them with `execute_js` that reads `DesktopMgr`, mutates the canvas, or clicks coordinates.

## Resource index

| Resource | Purpose |
|---|---|
| `{baseDir}/references/tool-catalog.md` | 2026-08-01 42-tool snapshot and safety classification; routing hint only |
| `{baseDir}/references/usage-patterns.md` | Live-only workflows and verification rules |

Static resources help choose what to query; they never replace a live Naki call.
