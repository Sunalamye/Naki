# Naki MCP live usage patterns

Every pattern starts with a real connection to the running Naki process. Static docs, cached tool output, repo code and old logs may help explain a result, but they never satisfy a current query.

## Universal preflight

```text
1. Connect to live Naki MCP.
2. Call tools/list for this user request.
3. Confirm the selected tool and use the returned inputSchema.
4. Call the live tool that answers the question.
5. Report observed fields; label missing runtime evidence as unverified.
```

If the connection or `tools/list` fails, stop with `live Naki unavailable`. Do not fall back to the 42-tool snapshot as though it were live data.

## Pattern 1: Current AI / hand query

Use this for「目前 AI 在想什麼」「現在手牌／推薦是什麼」:

```text
live tools/list
  → get_status
  → bot_status
  → game_state
  → game_hand
  → game_ops
```

Only call the tools needed for the question, but always include the live registry step. State clearly when there is no active game or when the snapshot has not been populated.

`bot_status` and `game_*` read live state from the running Naki process. That state was accumulated from intercepted WebSocket/Liqi events; it is not a fresh complete server snapshot.

## Pattern 2: Investigate a missed tsumo / wrong decision

For「可以自摸卻沒自摸」or another legality discrepancy, capture evidence before triggering anything:

```text
live tools/list
  → get_status
  → game_state
  → game_hand
  → game_ops
  → bot_status
  → bot_deep
  → get_logs
```

Compare four facts:

1. Did the live `game_ops` snapshot actually offer a tsumo/hora operation?
2. What sequence and operation combinations did Naki parse?
3. What action did `bot_status` recommend?
4. What RESPONSE or authoritative action appears in `bot_deep`/logs?

Do not repair the situation by clicking the canvas or reading a nonexistent UI object. If the user explicitly asks to execute the currently legal self-draw, refresh `game_ops` immediately before the action, then call live `game_action_verify` with the action exposed by the current schema and inspect the verification result.

## Pattern 3: Authorized game action

Use only when the user asked to affect the current game:

```text
live tools/list
  → game_state
  → game_ops
  → validate current seat + sequence + offered operation/combination
  → game_action_verify
  → game_state / game_ops again
  → get_logs if verification is incomplete
```

Prefer `game_action_verify` over a bare send. A result such as `sent.success=true` means bytes entered an open WebSocket, not that Majsoul accepted the action. Preserve the RESPONSE, `verified`, previous/new sequence and authoritative follow-up fields in the report.

Never derive a discard from a visual tile position. Supply the tile string accepted by the live schema.

## Pattern 4: Read-only Unity WebUI diagnosis

Game data does not come from JavaScript. Use `execute_js` only after live discovery and only for page/Unity/Naki-injection probes:

```javascript
return JSON.stringify({
  url: location.href,
  canvas: !!document.getElementById('unity-canvas'),
  sockets: window.__nakiWebSocket?.getConnections?.() ?? null,
  highlight: window.__nakiHighlight?.state?.() ?? null
})
```

This is read-only. Do not mutate WebGL state, dispatch mouse/pointer events, call `sendRaw`, or probe `DesktopMgr`/`GameMgr`/`uiscript`/`cfg`.

For actual game state, follow with live `game_state`, `game_hand`, or `game_ops` instead of trying to decode Unity objects from wasm.

## Pattern 5: Lobby query

```text
live tools/list
  → lobby_status
  → lobby_account_info (only when account data is needed)
  → lobby_match_modes (only when mode choices are needed)
```

`lobby_status` and `lobby_account_info` send live lobby requests. Do not replace them with a remembered status or old match-mode table.

Starting or cancelling a match is not a query. Require an explicit user request, refresh live `lobby_match_modes`, then call `lobby_start_match` or `lobby_cancel_match` with its current schema.

## Pattern 6: Friend-room workflow

Read-only room question:

```text
live tools/list → room_info
```

Mutation workflow, only with explicit authorization:

```text
live tools/list
  → room_create
  → check RESPONSE
  → room_add_robot as requested
  → room_info
  → room_start only when requested and preconditions are met
```

`room_quick_test` combines several external mutations. Never use it as a status probe.

## Pattern 7: Connection / bot recovery

First diagnose without mutation:

```text
live tools/list
  → get_status
  → bot_status
  → game_state
  → bot_deep
  → get_logs
```

`bot_sync` closes/reconnects WebSocket connections and rebuilds bot state. Use it only when the user requests recovery or has authorized that runtime side effect. Afterward, repeat live state queries; do not report recovery merely because the tool call returned.

## Pattern 8: Logs

For current-process evidence use live `get_logs`. A log file from a previous launch may be useful historical evidence, but it is not a live Naki query and must be labeled as such.

`clear_logs` is destructive to in-memory diagnostic evidence. Never call it during a query unless the user explicitly asks.

## Failure interpretation

| Observation | Meaning | Correct report |
|---|---|---|
| MCP connection or `tools/list` fails | Running Naki could not be queried | `live Naki unavailable; current result unverified` |
| Tool absent from live list | Running build does not expose it | Report absent; do not call a legacy name |
| `game_state` is empty | Naki has no current protocol snapshot | Report no populated live game state |
| `sent.success=true`, no RESPONSE | WebSocket accepted bytes only | Server acceptance unverified |
| `game_action_verify.verified=false` | Verification condition was not observed | Action result unverified/failed as returned |
| Highlight MCP tool returns unavailable | Compatibility stub behaved as designed | Do not claim highlight changed |

## Explicitly forbidden legacy patterns

- `view.DesktopMgr.Inst`, `GameMgr`, `uiscript`, `cfg`, `app.NetAgent`, `window.naki`/`NakiCoordinator` game-object access.
- `detect`, `explore`, `test_indicators`, `click`, `calibrate`, `ui_names_*`.
- Canvas/DOM coordinate clicks or calibration tables.
- Using Swift hand-array index as a visual tile position.
- Calling `window.__nakiWebSocket.sendRaw` from a query or action workflow.
- Treating this file, the tool catalog, or a prior session result as current Naki data.
