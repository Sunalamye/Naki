# Architecture Deep Dive

For a complete understanding of Naki's architecture, see `CLAUDE.md` first. This document provides deeper technical details.

> ⚠️ **2026-07-31：雀魂已改用 Unity WebGL**（`chs_t-WebGL-release-4.0.45(45)`）。
> 本文描述的**程式碼結構仍然正確**（它描述 Naki 自己的 code），但凡是依賴
> `window.view.DesktopMgr` / `GameMgr` / `uiscript` / `cfg` 的**執行路徑已全部失效**
> ——`naki-game-api.js`、`naki-autoplay.js`、AutoPlay 重試迴圈、`/game/*` 端點。
> WebSocket 訊息橋接與 Liqi→MJAI 轉換**不受影響**（協議沒變）。
> 新的正確互動面 → [majsoul-unity-protocol.md](majsoul-unity-protocol.md)。

## Observable State Pattern

`GameStateManager` is an `ObservableObject` (it publishes state via `@Published` properties, not the `@Observable` macro). SwiftUI views redraw when its published properties change. `WebViewModel` owns a `GameStateManager` instance (`private(set) var gameStateManager = GameStateManager()`) and calls `gameStateManager.syncFrom(controller:)` to push bot state into the UI.

See `command/ViewModels/GameStateManager.swift` for state definition.

## Protocol Conversion Pipeline

### Normal Game Flow
1. **WebSocketInterceptor** (command/Services/Bridge/WebSocketInterceptor.swift)
   - Captures raw `.lq.ActionPrototype` Liqi Protobuf messages
   - Passes to MajsoulBridge

2. **MajsoulBridge** (command/Services/Bridge/MajsoulBridge.swift)
   - Decodes base64 data with XOR decryption (crucial step)
   - Parses Liqi Protobuf via LiqiParser
   - Converts to MJAI event format
   - Publishes to GameStateManager

3. **GameStateManager** (command/ViewModels/GameStateManager.swift)
   - Centralizes game state (@Observable)
   - Triggers reactive UI updates

### Reconnection Flow (syncGame/enterGame)

When disconnected and reconnected:
- `MajsoulBridge.parseSyncGameRestore()` processes `gameRestore.actions[]`
- **Critical**: NO XOR decoding needed (already decoded in response)
- **Critical**: Do NOT send additional `start_game` (authGame already did)

See `FLOW_COMPARISON.md` for complete lifecycle including multiround handling.

## Service Initialization Order

`WebViewModel` initializes services in this order (property inits + `init()` body):

1. **GameStateManager** - `private(set) var gameStateManager = GameStateManager()` (stored-property init, so ready before the body runs)
2. **NakiWebCoordinator / NakiNavigationDecider / NakiDialogPresenter** - created at the top of `init()`
3. **WebPage** - built with a `WKUserContentController` that registers the `websocketBridge` message handler and injects `WebSocketInterceptor.createUserScript()` (see JavaScript Injection Details)
4. **NativeBotController** - `nativeBotController = NativeBotController()` (Bot management and inference)
5. **AutoPlayController + AutoPlayService** - `autoPlayController = AutoPlayController()`; `autoPlayService.delegate = self`
6. **DebugServer** - `startDebugServer()` creates `DebugServer(port: 8765)`, which also embeds the MCP handler (same server, see Debug Server Endpoints)
7. **Auto-play mode + check timer** - `autoPlayController?.setMode(.auto)` then `startAutoPlayCheckTimer()` (**1.0-second** interval polling via `checkAndRetriggerAutoPlay()`)

## JavaScript Injection Details

JS is injected during **`WebViewModel.init()`** (not `WebViewController.init()`):

- The `WKUserContentController` registers a `WKScriptMessageHandler` under the name **`websocketBridge`** (`userContentController.add(coordinator.websocketHandler, name: "websocketBridge")`). JS posts to Swift via `window.webkit.messageHandlers.websocketBridge.postMessage(...)`.
- `WebSocketInterceptor.createUserScript()` concatenates the **5** bundled modules (`WebSocketInterceptor.jsModules`) and adds them as a single `WKUserScript`.

Injection order (from `WebSocketInterceptor.jsModules`) — this order matters:

```
1. naki-core.js
   ├─ Posts to Swift via window.webkit.messageHandlers.websocketBridge
   ├─ Base64 helpers (__nakiArrayBufferToBase64 / __nakiBase64ToArrayBuffer / ...)
   └─ Exposes window.__nakiCore, window.__nakiAntiIdle, window.__nakiEmojiAutoReply

2. naki-autoplay.js                          ❌ 失效（Laya/DOM 已不存在）
   ├─ Tile element finding
   ├─ Click / discard simulation
   └─ Handles DOM / Laya layout variations

3. naki-game-api.js                          ❌ 失效（DesktopMgr 已不存在）
   ├─ Extracts game state from window.view.DesktopMgr.Inst
   └─ Exposes window.__nakiGameAPI, window.__nakiDoraHook, window.__nakiRecommendHighlight

4. naki-websocket.js                         ✅ 仍正常
   ├─ Intercepts WebSocket.send() before the game sends
   └─ Forwards frames to Swift via postMessage

5. naki-coordinator.js
   ├─ Unified coordinator integrating the other modules' APIs
   └─ Sets the global entry point: window.naki = window.NakiCoordinator
```

> Note: there is no `naki-recommendation-shimmer.js` / `naki-webgl-shimmer.js` and no `window.nakaMessenger`; those were removed. The Swift-facing handler is `websocketBridge` and the global JS entry point is `window.naki`.

All modules live in `command/Resources/JavaScript/` and are loaded from the bundle at runtime (`Bundle.main.url(forResource:withExtension:"js", subdirectory:"Resources/JavaScript")`).

## AutoPlay Retry Mechanism

> ❌ **本節描述的執行路徑已失效**（2026-07-31）：它讀 `window.view.DesktopMgr.Inst.oplist`
> 並靠 Laya 版面點擊，Unity 客戶端下這些都不存在。程式碼本身尚未更新。
> 替代方向：動作改組 Liqi REQUEST 送出（見 majsoul-unity-protocol.md），
> 屆時 oplist 等待/重試邏輯應由 protobuf 回應取代。

The **live** retry path is `WebViewModel.executeAutoPlayActionWithRetry(...)` (`command/ViewModels/WebViewModel.swift`, ~line 816), driven by the periodic `checkAndRetriggerAutoPlay()` timer (**1.0-second** interval). `AutoPlayService.swift` still exists but is largely inert — the active logic lives in `WebViewModel`.

```
Recommendation generated
    ↓
checkAndRetriggerAutoPlay() timer (every 1.0s) → triggerAutoPlayNow()
    ↓
executeAutoPlayActionWithRetry(attempt:executionId:)   // recursive
  - Guards on currentExecutionId (cancels if superseded by a newer trigger)
  - Reads window.view.DesktopMgr.Inst.oplist to check available ops
  - discard: executes immediately (no oplist wait)
  - other actions: wait for oplist, retry up to maxRetryAttempts (50) × 0.1s (~5s)
    ↓
Success or timeout
    ↓
Log to debug server, clear currentExecutionId
```

Handles timing issues when Majsoul reflows/updates its Laya layout.

## MortalSwift Integration (pure Swift + Core ML)

As of **MortalSwift v0.3.0** this is **pure Swift + Core ML — no FFI**. (Old FFI sources may still be present in the tree but are excluded from the build.) `command/Services/Bot/NativeBotController.swift` (`import MortalSwift`) manages:

1. **Bot Creation** - `createBot(playerId: UInt8, is3P: Bool = false) throws` (synchronous, `throws` — not `async`)
   - Builds `MortalBot(playerId: Int(playerId), version: 4, useBundledModel: true)`
   - `MortalBot` is an `actor`, so inference runs off the main thread
   - `is3P` selects the 3-player model variant

2. **Inference** - `react(event:) async throws -> MJAIAction?` (also overloads for `[String: Any]` events and arrays)
   - Sends an MJAI event to the bot
   - Returns an action recommendation with Q-values
   - Async because `MortalBot` is an actor

3. **State Tracking**
   - Hand tiles and revealed tiles
   - Dora indicators
   - Player wind positions
   - Scores and round state

4. **Cleanup** - `deleteBot()` on `end_game` (invoked from `NakiWebCoordinator.handleMJAIEvent`)

The Core ML model is bundled with the MortalSwift package (`useBundledModel: true`).

## Game Lifecycle State Machine

```
┌─ authGame Request
│  └─ Reset Bridge state
├─ authGame Response
│  └─ start_game (create new Bot)
├─ ActionNewRound
│  └─ start_kyoku
├─ ActionDealTile
│  └─ tsumo (recommendations begin)
├─ ... game play ...
├─ ActionHule/ActionNoTile
│  └─ end_kyoku
└─ NotifyGameEndResult
   └─ end_game (cleanup Bot)
```

**Critical**: Each `start_game` must destroy old Bot and create fresh instance. This matches Python Akagi behavior.

## Protocol Encoding/Decoding

### XOR Decryption (for normal messages)

From `FLOW_COMPARISON.md`:

```swift
let keys = [0x84, 0x5e, 0x4e, 0x42, 0x39, 0xa2, 0x1f, 0x60, 0x1c]

func decode(data: [UInt8]) -> [UInt8] {
    var result = data
    for i in 0..<result.count {
        let u = (23 ^ result.count) + 5 * i + keys[i % keys.count] & 255
        result[i] ^= UInt8(u)
    }
    return result
}
```

**When to use XOR decode**:
- `.lq.ActionPrototype` from WebSocket (Notify): YES
- `gameRestore.actions[]` from syncGame/enterGame Response: NO

### Protobuf Parsing

`LiqiParser.swift` handles all Liqi protocol definitions:
- Message field parsing (field 1, 2, 3, etc.)
- Nested structure extraction (e.g., `gameRestore.snapshot.tiles`)
- Type conversions (enums, packed arrays)

If Majsoul updates protocol, update protobuf definitions here.

## Debug Server Endpoints

Located in `command/Services/Debug/DebugServer.swift`, port **8765**. The MCP server is **not** a separate process: `DebugServer` embeds an MCP handler (`private let mcpHandler = MCPHandler()`, imports `MCPKit` / `MCPWebKit`) and exposes it as the `POST /mcp` route. So the plain HTTP debug API and the MCP protocol share the same server/port.

Selected routes (see the `switch (method, path)` in `DebugServer.handleRequest` for the full list):

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/help`, `/status` | GET | API docs / server status |
| `/js` | POST | Execute JavaScript in game context (needs `return`) |
| `/logs` | GET / DELETE | View / clear log entries |
| `/game/state`, `/game/hand`, `/game/ops` | GET | Game state, hand tiles, operations |
| `/game/discard`, `/game/action` | POST | Discard / execute an action |
| `/bot/status`, `/bot/ops`, `/bot/deep` | GET | Bot state, ops, deep inference detail |
| `/bot/trigger`, `/bot/chi`, `/bot/pon` | POST | Manually trigger auto-play / chi / pon |
| `/ui/names`, `/ui/names/{hide,show,toggle}` | GET / POST | Player-name hiding controls |
| **`/mcp`** | POST | **MCP protocol endpoint (delegated to the embedded `MCPHandler`)** |

Useful for remote testing and debugging without UI access.

## Xcode Project Structure

Dual-platform project (`Naki.xcodeproj`, `objectVersion = 77`, built with **Xcode 26**):

- **Targets**:
  - `Naki` — primary **macOS** app (deployment target **macOS 26.0**; `@main` in `Naki/App/NakiApp.swift`)
  - `Naki-M` — secondary **iOS** app (deployment target **iOS 26.0**; `@main` in `Naki-M/Naki_MApp.swift`)
  - `Naki-MTests` — unit tests (attached to the `Naki-M` iOS target)
  - `Naki-MUITests` — UI tests (attached to the `Naki-M` iOS target)
  - Note: there is no test bundle on the macOS `Naki` target, so `xcodebuild test -scheme Naki` runs no tests.
- **Shared code**: the `command/` folder is a **file-system-synchronized folder** (`PBXFileSystemSynchronizedRootGroup`) shared by the app targets, so all `command/**` `.swift` and resources are picked up automatically (no manual "add file" step).
- **Build Phases** (per target):
  - Compile Sources (all `command/**` .swift + the per-target `*App.swift`)
  - Link with the MortalSwift package (pure Swift + Core ML)
  - Copy Bundle Resources (`command/Resources/JavaScript/naki-*.js`, `index.html`, `Assets.xcassets`)
- **Entitlements** (`Naki/akagi.entitlements`):
  - App sandbox enabled
  - Network client/server (for WebSocket and the debug/MCP server)
  - File access (for user-selected files)

## Testing Approach

Since this is a production tool with account risk:
- Manual UI testing on test accounts only
- Debug server endpoints for API testing
- Log inspection via UI and debug endpoint
- Incremental testing of new features

No automated test suite (due to game UI interaction complexity).

## Performance Considerations

1. **Bot Model Loading** - Takes ~500ms on first inference, cache on subsequent calls
2. **WebSocket Processing** - Sequential message parsing may impact responsiveness with very frequent updates
3. **UI Updates** - All @Observable mutations trigger SwiftUI refresh, batch when possible
4. **AutoPlay Retry** - 50 attempts × 0.1s = max 5 seconds per action
5. **Debug Server** - Minimal overhead, logging is buffered to max 10,000 entries

## Common Debugging Patterns

### WebSocket Interception Not Working
1. Verify JS injection: `mcp__naki__execute_js({ code: "return !!window.naki" })` should return `true` (global entry point from naki-coordinator.js; the Swift handler name is `websocketBridge`)
2. Check browser console via remote debugging
3. Verify `naki-websocket.js` modifications if protocol changed

### Bot Not Creating Recommendations
1. Check `mcp__naki__bot_status` for bot state
2. Verify `start_game` was received (should have playerId)
3. Check MortalSwift framework is linked in Xcode build phases
4. Review logs: `mcp__naki__get_logs` or UI sidebar

### AutoPlay Failing to Click ❌（整段已失效）
> Unity WebGL 只渲染單一 `<canvas id="unity-canvas">`，**沒有任何 per-tile DOM 元素**，
> 下列 DOM 定位手法一律無效。改用 protobuf 送動作後這類除錯應改為「比對送出/回應封包」。
1. ~~Verify tile positions: `document.querySelector('[class*=tile]').getBoundingClientRect()`~~
2. ~~Check game layout hasn't changed~~
3. Review retry logs in sidebar or via `mcp__naki__get_logs`（仍可看到失敗紀錄）
4. ~~Consider if game UI is in unexpected state~~

### Protocol Parsing Errors
1. Add debug logs to `MajsoulBridge.swift` and `LiqiParser.swift`
2. Check raw Liqi messages via `mcp__naki__get_logs`
3. Compare with Python Akagi implementation in reference docs
4. Update protobuf definitions if Majsoul changed message format
