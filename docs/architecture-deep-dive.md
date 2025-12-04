# Architecture Deep Dive

For a complete understanding of Naki's architecture, see `CLAUDE.md` first. This document provides deeper technical details.

## Observable State Pattern

The app uses Swift's `@Observable` macro (macOS 14.0+) for reactive updates. All SwiftUI views automatically redraw when `GameStateManager` properties change.

See `Naki/ViewModels/GameStateManager.swift:14-30` for state definition.

## Protocol Conversion Pipeline

### Normal Game Flow
1. **WebSocketInterceptor** (Naki/Services/Bridge/WebSocketInterceptor.swift)
   - Captures raw `.lq.ActionPrototype` Liqi Protobuf messages
   - Passes to MajsoulBridge

2. **MajsoulBridge** (Naki/Services/Bridge/MajsoulBridge.swift:200-207)
   - Decodes base64 data with XOR decryption (crucial step)
   - Parses Liqi Protobuf via LiqiParser
   - Converts to MJAI event format
   - Publishes to GameStateManager

3. **GameStateManager** (Naki/ViewModels/GameStateManager.swift)
   - Centralizes game state (@Observable)
   - Triggers reactive UI updates

### Reconnection Flow (syncGame/enterGame)

When disconnected and reconnected:
- `MajsoulBridge.parseSyncGameRestore()` processes `gameRestore.actions[]`
- **Critical**: NO XOR decoding needed (already decoded in response)
- **Critical**: Do NOT send additional `start_game` (authGame already did)

See `FLOW_COMPARISON.md` for complete lifecycle including multiround handling.

## Service Initialization Order

From `WebViewModel.init()`:

1. **GameStateManager** - Created first (other services depend on it)
2. **NativeBotController** - Bot management and inference
3. **AutoPlayService** - Tile execution with retry mechanism
4. **DebugServer** - HTTP server on port 8765
5. **Auto-play check timer** - 2-second interval polling

Order matters for dependency resolution.

## JavaScript Injection Details

All JS modules are bundled and injected during `WebViewController.init()`:

```
naki-core.js
  ├─ Defines window.nakaMessenger for Swift bridge
  ├─ Base64 encoding utilities
  └─ Message handler setup

naki-websocket.js
  ├─ Intercepts WebSocket.send() before game sends
  ├─ Forwards to Swift via postMessage
  └─ Allows bidirectional communication

naki-game-api.js
  ├─ Extracts game state from DOM
  ├─ Provides window.gameState API
  └─ Polling mechanism for state changes

naki-autoplay.js
  ├─ Tile element finding via AI-generated selectors
  ├─ Click simulation
  └─ Handles DOM layout variations
```

All modules must be in Xcode's "Copy Bundle Resources" build phase.

## AutoPlay Retry Mechanism

Located in `AutoPlayService.swift` and coordinated by `WebViewModel.checkAndRetriggerAutoPlay()`:

```
Recommendation generated
    ↓
AutoPlayService.executeAction()
    ↓
Retry loop (50 × 0.1s = max 5 seconds):
  1. Get tile position from game UI
  2. Simulate click at coordinates
  3. Check if action succeeded
  4. Retry if failed
    ↓
Success or timeout
    ↓
Log to debug server, publish to UI
```

Handles timing issues when Majsoul reflows/updates its layout.

## MortalSwift FFI Integration

`NativeBotController.swift:902` manages:

1. **Bot Creation** - `createBot(playerId:)` async
   - Initializes MortalBot actor
   - Passes playerID for seating context

2. **Inference** - `react(event:)` throws
   - Sends MJAI event to bot
   - Returns action recommendation with Q-values
   - Async/await via MortalBot actor interface

3. **State Tracking**
   - Hand tiles and revealed tiles
   - Dora indicators
   - Player wind positions
   - Scores and round state

4. **Cleanup** - Bot disposal on `end_game`

Core ML model (`mortal.mlmodelc`) is embedded in MortalSwift framework.

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

Located in `Debug/DebugServer.swift`, port 8765:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/logs` | GET | View last 10,000 log entries |
| `/bot/status` | GET | Current bot state, recommendations, tiles |
| `/bot/trigger` | POST | Manually trigger auto-play action |
| `/js` | POST | Execute JavaScript in game context |

Useful for remote testing and debugging without UI access.

## Xcode Project Structure

- **Target**: Naki (macOS app)
- **Build Phases**:
  - Compile Sources (all .swift files)
  - Link Binary With Libraries (MortalSwift)
  - Copy Bundle Resources (naki-*.js, Assets.xcassets)
- **Entitlements** (akagi.entitlements):
  - App sandbox enabled
  - Network client/server (for WebSocket and debug server)
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
1. Verify JS injection: `curl -X POST http://localhost:8765/js -d "window.nakaMessenger"` should return truthy
2. Check browser console via remote debugging
3. Verify `naki-websocket.js` modifications if protocol changed

### Bot Not Creating Recommendations
1. Check `curl http://localhost:8765/bot/status` for bot state
2. Verify `start_game` was received (should have playerId)
3. Check MortalSwift framework is linked in Xcode build phases
4. Review logs in UI sidebar for inference errors

### AutoPlay Failing to Click
1. Verify tile positions are correct: `curl -X POST http://localhost:8765/js -d "document.querySelector('[class*=tile]').getBoundingClientRect()"`
2. Check game layout hasn't changed
3. Review retry logs in sidebar
4. Consider if game UI is in unexpected state

### Protocol Parsing Errors
1. Add debug logs to `MajsoulBridge.swift` and `LiqiParser.swift`
2. Check raw Liqi messages via WebSocket interception logs
3. Compare with Python Akagi implementation in reference docs
4. Update protobuf definitions if Majsoul changed message format
