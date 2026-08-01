---
name: mcp-tool-writer
description: Create or modify Naki MCP tools against the current 42-tool Swift registry, Unity WebGL client, and Liqi protocol state/action boundaries.
allowed-tools: Read, Glob, Grep, Write, Edit, Bash
---

# Naki MCP Tool Writer

Base directory: {baseDir}

<IMPORTANT>
Runtime 查詢與驗收一律透過 `/naki-mcp-proxy` 真實連到正在執行的 Naki。每個 request 先呼叫 live `tools/list`，再依該次回傳的名稱與 `inputSchema` 呼叫實際工具。若 Naki 無法連線，只能標記「runtime 未驗證」；不可用本 skill、repo source、靜態 catalog、build 成功或之前的輸出冒充 live 結果。

目前雀魂頁面是 Unity WebGL。遊戲狀態來自 Naki 的 Swift Liqi protocol state，遊戲／大廳／房間動作由 Swift 組 Liqi REQUEST。`executeJavaScript` 只適合唯讀 page／Unity canvas／Naki injection probe；不得拿來讀遊戲物件、送遊戲動作或模擬座標點擊。
</IMPORTANT>

## Invariant

新增或修改工具時必須維持三個邊界：

1. `tools/list` 由 `MCPToolRegistry` 自動生成，是名稱、描述與 schema 的 runtime truth。
2. 查詢結果必須揭露資料來源；local Swift snapshot 不可描述成 fresh server snapshot。
3. 會改 log、連線、帳號、排隊、房間或對局的工具，description 與結果都要清楚揭露 side effect，且 runtime 驗收需要明確授權。

## Current architecture

```text
command/Services/MCP/
├── MCPTool.swift          MCPKit re-export、NakiMCPTool、NakiUnsupported
├── MCPContext.swift       NakiMCPContext + DefaultNakiMCPContext
├── MCPToolRegistry.swift  registration order、tools/list definitions、execution
├── MCPHandler.swift       MCP JSON-RPC handler
└── Tools/
    ├── SystemTools.swift     status/help/logs
    ├── BotTools.swift        bot snapshot/control + Liqi chi/pon
    ├── GameTools.swift       protocol state + Liqi game actions
    ├── UITools.swift         one read-only-capable JavaScript surface: execute_js
    ├── LobbyTools.swift      lobby requests + Swift anti-idle scheduler
    ├── RoomTools.swift       friend-room protocol flow
    ├── EmojiTools.swift      Liqi broadcast send/capture
    └── HighlightTools.swift  six explicit compatibility failure stubs

command/Services/Bridge/
├── LiqiActionSender.swift   LiqiRequestSpec/Builder, send outcome/result
├── LiqiOperationStore.swift current server-offered operation snapshots
└── LiqiResponseStore.swift  responses and captured broadcasts
```

State and action flow:

```text
WebSocket frames
  → Liqi parser / Majsoul bridge
  → Swift snapshot + operation/response stores
  → read tools

authorized MCP action
  → LiqiRequestBuilder / NakiGameAction
  → NakiMCPContext.sendLiqi
  → LiqiActionSender
  → correct gateway
  → RESPONSE and/or authoritative state transition
```

## Current registered tools: 42

This is the 2026-08-01 source snapshot. Before runtime work, call live `tools/list`; do not assume this count remains current after code changes.

| Category | Count | Current names |
|---|---:|---|
| System | 4 | `get_status`, `get_help`, `get_logs`, `clear_logs` |
| Bot | 7 | `bot_status`, `bot_trigger`, `bot_ops`, `bot_deep`, `bot_chi`, `bot_pon`, `bot_sync` |
| Game | 6 | `game_state`, `game_hand`, `game_ops`, `game_discard`, `game_action`, `game_action_verify` |
| JavaScript | 1 | `execute_js` |
| Lobby | 8 | `lobby_status`, `lobby_match_modes`, `lobby_start_match`, `lobby_cancel_match`, `lobby_account_info`, `lobby_server_time`, `lobby_heartbeat`, `lobby_login_beat` |
| Anti-idle | 1 | `lobby_anti_idle` |
| Friend room | 7 | `room_create`, `room_add_robot`, `room_start`, `room_info`, `room_join`, `room_leave`, `room_quick_test` |
| Emoji | 2 | `game_emoji`, `game_emoji_listen` |
| Highlight compatibility stubs | 6 | `highlight_tile`, `reset_tile_color`, `highlight_status`, `highlight_settings`, `show_recommendations`, `hide_highlight` |

The six highlight tools are registered contracts that currently return explicit unavailable results. Naki's built-in WebGL recommendation highlighter is a separate Swift-to-JavaScript path; do not implement or document the MCP stubs as successful UI controls without wiring and testing a new contract.

## Before writing a tool

Define these facts first:

| Question | Required decision |
|---|---|
| What is the source? | Server RESPONSE, Swift protocol snapshot, operation store, response store, bot state, local logs, or read-only page probe |
| Is it a query or mutation? | Identify every account/game/file/log/connection side effect |
| Does a current tool already cover it? | Prefer extending a coherent tool over adding an alias |
| Which gateway/method applies? | Derive from current Liqi schema and existing builders; never guess from UI behavior |
| How is success proven? | Return/throw, server RESPONSE, operation sequence movement, or another explicit authoritative signal |
| What happens without runtime context? | Fail clearly; never fabricate an empty success |

Check `git status` before editing and preserve concurrent/user changes.

## Implementing an MCP tool

### 1. Choose the owning file

Add the tool to the category that owns its source and side effects. A tool that sends a lobby request belongs with lobby protocol tools; it does not become a UI tool merely because the result is visible on screen.

### 2. Implement `MCPTool`

```swift
struct MyQueryTool: MCPTool {
    static let name = "my_query"
    static let description = "Read a clearly identified live Naki state source; no external mutation"

    static let inputSchema = MCPInputSchema(
        properties: [
            "limit": .integer("Maximum number of records")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }
        guard let snapshot = nakiContext.getGameSnapshot() else {
            throw MCPToolError.notAvailable("game protocol snapshot")
        }

        return [
            "success": true,
            "source": "swift-protocol-layer",
            "snapshot": snapshot
        ]
    }
}
```

Use a unique snake_case name. Descriptions must say whether the tool is read-only, what it reads, and whether it sends or mutates anything.

### 3. Define an exact schema

```swift
static let inputSchema = MCPInputSchema.empty

static let inputSchema = MCPInputSchema(
    properties: [
        "text": .string("Meaning and accepted format"),
        "count": .integer("Bounds and default"),
        "ratio": .number("Bounds and default"),
        "enabled": .boolean("Omitted means query-only")
    ],
    required: ["text"]
)
```

- Schema, validation, defaults and description must agree.
- Validate enum/range/format before touching external state.
- Echo action-critical normalized inputs in the result when useful for review.
- Do not keep dead parameters for a surface that no longer exists.

### 4. Use the current context boundary

`NakiMCPContext` currently exposes:

```swift
let bot = nakiContext.getBotStatus()
nakiContext.triggerAutoPlay()
let game = nakiContext.getGameSnapshot()
let outcome = await nakiContext.sendLiqi(spec, awaitResponseMs: 1500)
let antiIdle = nakiContext.setAntiIdle(enabled: nil, intervalSeconds: nil)
```

Base `MCPContext` also provides server port, logs and `executeJavaScript`. Use JavaScript only for read-only page/Unity/injection diagnostics, and include `return` when a value is needed:

```swift
let script = "return JSON.stringify({url:location.href,canvas:!!document.getElementById('unity-canvas')})"
let result = try await context.executeJavaScript(script)
```

Do not create a game-state or action tool around JavaScript.

### 5. Build Liqi actions through the shared sender

For a request tool:

1. Reuse or extend `LiqiRequestBuilder`; game action parsing belongs in `NakiGameAction` when applicable.
2. Read `LiqiOperationStore` before an action whose legality/type/combination depends on the server-provided oplist.
3. Call `nakiContext.sendLiqi(spec, awaitResponseMs:)`.
4. Return `LiqiToolResult.dictionary(outcome, spec:extra:)` so method, payload, msgId, send status and RESPONSE semantics stay consistent.
5. For an action that claims completion, verify RESPONSE and/or an authoritative operation/state transition.

```swift
let spec = LiqiRequestBuilder.fetchServerTime()
let outcome = await nakiContext.sendLiqi(spec, awaitResponseMs: 1500)
return LiqiToolResult.dictionary(outcome, spec: spec)
```

`sent.success == true` proves only that bytes were accepted by an open WebSocket. It is not server acceptance. Preserve `response`, `serverAccepted`, timeout and verification fields rather than flattening them into an unconditional success.

Never manually assemble raw WebSocket JavaScript in an MCP action tool; routing, message IDs, encoding and response correlation belong to the shared Liqi sender.

### 6. Handle errors and unsupported contracts

Use `MCPToolError` for invalid input or missing execution context:

```swift
throw MCPToolError.missingParameter("name")
throw MCPToolError.invalidParameter("name", expected: "documented format")
throw MCPToolError.notAvailable("required runtime source")
```

For a retained compatibility contract with no current implementation, use the shared failure shape:

```swift
return NakiUnsupported.result(
    reason: "specific missing current surface",
    alternative: "current supported route"
)
```

Failure must contain `success: false` as a Bool plus machine-readable `error` and human-readable `reason`. Never place a failure dictionary inside a truthy `success` field.

### 7. Register it

Add the type to the correct ordered section of `MCPToolRegistry.registerBuiltInTools()`:

```swift
register(MyQueryTool.self)
```

`tools/list` definitions are generated from the registry; do not maintain a separate JSON list. If the registered set changes, update all explicit counts/category docs/help/tests in the same change and verify the live registry after launching the new build.

## Verification

### Static and unit verification

At minimum, cover the paths relevant to the tool:

- Schema required/optional parameters and validation failures.
- Missing `NakiMCPContext` or unconfigured callbacks.
- Empty/missing protocol snapshot.
- Pure request builder payload and method.
- WebSocket send failure, missing RESPONSE, server error RESPONSE and accepted RESPONSE.
- Verification timeout and operation-sequence transition for action tools.
- Registry name uniqueness, expected category placement and generated schema.
- Side effects are absent on validation failure.

Project commands:

```bash
xcodebuild build -project Naki.xcodeproj -scheme Naki
xcodebuild test -project Naki.xcodeproj -scheme Naki -only-testing:NakiTests
```

Inspect actual command output, test results and `git diff`; an exit code alone is not enough when the environment is dirty.

### Runtime verification

Runtime verification is a separate gate after the new build is running:

```text
/naki-mcp-proxy
  → live tools/list
  → confirm the new/current schema
  → call the live tool
  → inspect the returned source, send, RESPONSE and verification fields
  → re-query relevant state when the tool mutates anything
```

- A query must return data from the live Naki call, not from source inspection.
- A mutation requires explicit authorization and an appropriate test account/state.
- If Naki is stopped, unreachable, running an older build, or lacks the required game snapshot, mark runtime verification incomplete.
- Never report a tool as runtime-working solely because it compiled or appeared in static registration.

## Completion checklist

- [ ] Current source and side-effect boundaries are documented.
- [ ] Tool name is unique and schema matches validation/defaults.
- [ ] State reads use Swift protocol/bot/store sources.
- [ ] Actions use shared Liqi builders/sender and current oplist where required.
- [ ] JavaScript, if any, is a read-only Unity/page probe with an explicit `return`.
- [ ] Failure results cannot be mistaken for success.
- [ ] Tool is registered in the correct ordered category.
- [ ] Explicit registry counts and current documentation were updated if the set changed.
- [ ] Normal, invalid-input, unavailable-context, send-failure and timeout paths were considered.
- [ ] Build/tests were actually run, or clearly marked not run.
- [ ] Runtime was queried through live `tools/list` and an actual tool call, or clearly marked unverified.
- [ ] Final `git status`/diff contains only authorized changes.

## Current references

- `command/Services/MCP/MCPTool.swift`
- `command/Services/MCP/MCPContext.swift`
- `command/Services/MCP/MCPToolRegistry.swift`
- `command/Services/MCP/Tools/`
- `command/Services/Bridge/LiqiActionSender.swift`
- `command/Services/Bridge/LiqiOperationStore.swift`
- `command/Services/Bridge/LiqiResponseStore.swift`
- `.claude/skills/naki-mcp-proxy/SKILL.md`
- `docs/mcp-server-guide.md`
- `docs/majsoul-unity-protocol.md`
