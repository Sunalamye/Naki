---
name: webui-tester
description: Diagnose the current Majsoul Unity WebGL page inside Naki. Use live Naki MCP for read-only page probes and Liqi protocol state/action routes; never use legacy Laya objects or coordinate clicking.
allowed-tools: Read, Glob, Grep, Task
---

# Unity WebUI tester

<IMPORTANT>
所有 Naki 查詢與動作都必須透過 `/naki-mcp-proxy` 連到 live Naki。每一個使用者 request 先做 live `tools/list`，再呼叫當次 registry 中的實際工具。不得只讀本 skill、repo 文件、舊 log 或先前 session 結果後宣稱查到目前狀態。

`execute_js` 僅允許唯讀 Unity/page/WebSocket/WebGL probe。禁止 Laya／DesktopMgr／NakiCoordinator 遊戲物件路徑、DOM/canvas 座標點擊、合成 pointer event、raw Liqi send 或任何 JS 狀態修改。
</IMPORTANT>

## Identify the surface

When「畫面／UI」不明確時，先分清楚：

| Surface | Current technology | Correct route |
|---|---|---|
| Majsoul game page | Unity WebGL in Naki's WKWebView | Read-only `execute_js` probes; state/actions use Liqi MCP tools |
| Naki application UI | SwiftUI | Inspect/edit Swift source under the task's code-change scope |

The Majsoul page is not a JavaScript game-object UI. Unity owns a single `unity-canvas`; individual hand tiles and buttons are not DOM elements.

## Current architecture

```text
Majsoul WebSocket frames
  → Naki WebSocket interceptor
  → Liqi protobuf parser
  → Swift game/operation state
  → game_state / game_hand / game_ops / bot_*

Authorized action
  → game_action_verify
  → Naki builds Liqi REQUEST
  → correct lobby/game gateway
  → RESPONSE + authoritative state/action verification
```

JavaScript remains useful only for the web page shell, Unity canvas, Naki's injected WebSocket bridge, and the WebGL highlight hook. It is not the game-state source.

## Mandatory live workflow

### Read-only diagnosis

```text
live Naki tools/list
  → get_status
  → execute_js (only if page/Unity rendering facts are needed)
  → game_state / game_hand / game_ops for game facts
  → bot_status / bot_deep for AI and protocol diagnostics
  → get_logs when event evidence is needed
```

Use only the calls needed for the question. If the live connection fails, say that current state is unverified; do not substitute a static explanation.

### Authorized action

```text
live Naki tools/list
  → game_state
  → game_ops
  → confirm current sequence and server-offered operation
  → game_action_verify using the live schema
  → game_state / game_ops again
```

Actions require an explicit user request. Never execute an action merely to test whether the UI works.

## Approved `execute_js` probes

`execute_js` receives a function body. To return a value, include `return`; serialize objects with `JSON.stringify`.

### Page and Unity presence

```javascript
return JSON.stringify({
  url: location.href,
  title: document.title,
  readyState: document.readyState,
  canvas: !!document.getElementById('unity-canvas'),
  canvasSize: (() => {
    const c = document.getElementById('unity-canvas');
    return c ? {width: c.width, height: c.height} : null;
  })()
})
```

### Naki injection presence

```javascript
return JSON.stringify({
  webSocketBridge: typeof window.__nakiWebSocket,
  connections: window.__nakiWebSocket?.getConnections?.() ?? null,
  highlighter: typeof window.__nakiHighlight,
  highlightState: window.__nakiHighlight?.state?.() ?? null
})
```

These probes read state only. `window.__nakiWebSocket.sendRaw`, `forceReconnect`, highlighter setters, DOM writes, WebGL uniform changes and event dispatch are not approved tester probes.

## Game-state route

| Question | Live tool |
|---|---|
| Current parsed round/hand/seat | `game_state` |
| Current hand and recommendation | `game_hand` |
| Currently legal server-offered operations | `game_ops` |
| Bot mode/recommendation | `bot_status` |
| Protocol snapshots, responses, diagnostics | `bot_deep` |
| Current runtime logs | `get_logs` |

`game_state`/`game_hand`/`game_ops` expose the running Naki process's Swift state accumulated from WebSocket/Liqi events. They are current Naki data, but they are not fresh complete RPC snapshots from the Majsoul server. Preserve that distinction in the report.

## Action route

1. Refresh live `game_ops` immediately before acting.
2. Confirm the action is present in the server-provided operation list and use its current `sequence`/combination.
3. Call `game_action_verify` using the live `tools/list` schema.
4. Inspect RESPONSE, `verified`, sequence/oplist movement and the next authoritative action.
5. Re-query live state before claiming success.

`sent.success=true` proves only that bytes entered an open WebSocket. It does not prove server acceptance. For terminal actions such as tsumo/ron, confirm the authoritative hand-ending action instead of relying only on send status.

## Forbidden legacy routes

The following objects/routes are absent or invalid in the current Unity client and must not appear in a proposed probe:

```text
window.Laya
window.view.DesktopMgr / view.DesktopMgr.Inst
GameMgr
uiscript
cfg
app.NetAgent
window.naki / window.NakiCoordinator game-state APIs
window.__nakiGameAPI
```

The following MCP tools were removed and must not be called:

```text
detect, explore, test_indicators, click, calibrate
ui_names_status, ui_names_hide, ui_names_show, ui_names_toggle
```

Also forbidden:

- Inferring a tile from screen coordinates or a Swift array index.
- Clicking the Unity canvas, dispatching mouse/pointer/touch events, or maintaining calibration offsets.
- Trying to find per-tile DOM nodes; there are none.
- Mutating WebGL materials/uniforms from an ad-hoc tester query.
- Sending Liqi bytes from JavaScript instead of the protocol action tools.

## Diagnostic checklists

### Current screen/render issue

- [ ] Live `tools/list` succeeded for this request.
- [ ] `get_status` proves the running Naki endpoint was reached.
- [ ] Read-only probe confirms current URL, `unity-canvas`, canvas dimensions and injection presence.
- [ ] `game_state`/`bot_status` distinguish a rendering issue from missing protocol state.
- [ ] `get_logs` was queried when the conclusion depends on recent events.
- [ ] No canvas mutation or click was performed.

### Wrong/missing action

- [ ] Live `game_ops` captured the exact offered operation and sequence.
- [ ] Live `bot_status` captured the recommendation.
- [ ] `bot_deep`/logs captured response or authoritative action evidence.
- [ ] No action was sent unless explicitly authorized.
- [ ] A send was not mistaken for server acceptance.

## Error handling

| Failure | Meaning | Response |
|---|---|---|
| MCP/`tools/list` unavailable | Naki was not queried live | Mark all current-state claims unverified |
| `execute_js` returns null | Missing `return`, unloaded page, or absent value | Re-check with a smaller read-only probe |
| `unity-canvas` absent | Current page is not at the loaded Unity surface | Report the observed URL/state; do not click around |
| Game snapshot empty | Naki has not accumulated active game state | Report no current protocol snapshot |
| Action verification times out | Acceptance/state transition was not observed | Report unverified/failed exactly as returned |

## Current references

- `../../../docs/majsoul-unity-protocol.md` — current Unity/Liqi architecture and runtime evidence.
- `../../../docs/mcp-server-guide.md` — current 42-tool list, safety classes and verification semantics.
- `../naki-mcp-proxy/SKILL.md` — mandatory live routing policy.

No Laya object reference is retained because it is not a valid query surface for the current client.
