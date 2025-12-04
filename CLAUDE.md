# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

**Naki (鳴き)** is a native macOS mahjong AI assistant for Majsoul (雀魂) that embeds the game in a WKWebView, intercepts WebSocket messages via JavaScript, converts Liqi Protobuf protocol to MJAI format, and runs real-time AI inference using Core ML and Rust FFI.

- **Type**: Native macOS Application (Swift/SwiftUI)
- **Platform**: macOS 13.0+
- **Swift**: 5.9+
- **License**: AGPL-3.0 with Commons Clause
- **Version**: 1.2.0

## Architecture

The app follows a service-oriented architecture with clear separation of concerns:

```
WKWebView (game embedding)
    ↓ (WebKit message handlers)
Swift Services Layer:
  • WebSocketInterceptor/MajsoulBridge: Liqi → MJAI protocol conversion
  • NativeBotController: Core ML inference via MortalSwift FFI
  • GameStateManager: @Observable centralized state
  • AutoPlayService: Tile click execution with retry mechanism
    ↓
SwiftUI Views (reactive to state changes)
```

**Key Files**:
- `Naki/ViewModels/WebViewModel.swift:1162` - Main orchestrator
- `Naki/Services/Bridge/MajsoulBridge.swift:1176` - Protocol parsing
- `Naki/Services/Bot/NativeBotController.swift:902` - AI inference
- `Naki/ViewModels/GameStateManager.swift` - Reactive state management
- `Naki/Resources/JavaScript/naki-*.js` - WebSocket interception & automation

## Development Workflow

### Build & Run

```bash
open Naki.xcodeproj          # Open in Xcode
# Build via Xcode (Cmd + B) or run (Cmd + R)
```

### Debug

The app runs an HTTP debug server on port 8765. **Get full API docs via**:

```bash
curl http://localhost:8765/help | jq .       # Complete API documentation (JSON)
curl http://localhost:8765/                  # HTML endpoints list (browser)
curl http://localhost:8765/bot/status        # Bot state and recommendations
curl http://localhost:8765/logs              # View debug logs
```

The `/help` endpoint provides AI-friendly structured documentation with all available endpoints, common workflows, tile notation, and usage tips. See `DebugServer.swift:306-506` for implementation.

### Test

```bash
xcodebuild test -project Naki.xcodeproj -scheme Naki
```

## Critical Information

### Game Lifecycle

Each new game (after `authGame` response) **must** trigger a fresh Bot creation. See `FLOW_COMPARISON.md:290-295` for the complete lifecycle and reconnection handling.

### Protocol Parsing

- **Normal messages** (.lq.ActionPrototype via WebSocket): Base64 → **XOR decode** → Protobuf
- **Reconnection** (syncGame/enterGame response): Base64 → **NO XOR decode** → Protobuf (already decoded in response)
- **Critical**: Do NOT send additional `start_game` on syncGame—authGame already did

See `FLOW_COMPARISON.md` for detailed XOR decode logic and handling of disconnect scenarios.

### State Management

The app uses Swift's `@Observable` macro for reactive UI updates:
- `GameStateManager:14-30` defines the centralized state
- All SwiftUI views automatically redraw when state properties change
- Services update state through GameStateManager methods

### JavaScript Injection

Four JS modules are injected into WKWebView (must be in "Copy Bundle Resources" build phase):
- `naki-core.js` - Base64 encoding, message handlers
- `naki-websocket.js` - WebSocket interception
- `naki-game-api.js` - Game state extraction
- `naki-autoplay.js` - Tile clicking automation

Verify injection is working via the debug server's `/js` endpoint.

### Majsoul WebUI Objects (Laya Engine)

**IMPORTANT**: The following objects exist in **Majsoul's WebUI** (JavaScript/Laya), not in Naki:

Key objects:
- Game manager: `window.view.DesktopMgr.Inst`
- Hand tiles: `mainrole.hand[]` (14 tile objects with `val`, `isDora`, `_doraeffect`, `_recommendeffect`, etc.)
- Dora effects: `effect_dora3D`, `effect_dora3D_touying`, `effect_doraPlane`
- Recommendation highlight: `effect_recommend.active` (AI recommendation control)

See `@docs/majsoul-webui-objects-reference.md` for complete reference including:
- How to find and query objects (Debug Server methods)
- Complete tile object properties
- Game manager structure
- Effect control mechanisms
- Laya Sprite3D properties
- Type mapping and encoding

### ⚠️ Tile Index Mapping - Critical Pitfall

**IMPORTANT**: When finding tiles in the game UI, you CANNOT use Swift's `tehai` array indices directly!

**The Problem**:
- Swift's `tehai` array is sorted by tile index: `tehai.sort { $0.index < $1.index }`
- Majsoul's UI displays tiles in a different visual order (not sorted by index)
- Using `tehai` index to click/highlight will target the WRONG tile

**The Solution**:
Always use the **same logic as `executeAutoPlayAction` in `WebViewModel.swift`**:

1. Parse tile MJAI name (e.g., "7m", "5mr", "W")
2. Convert to Majsoul type mapping:
   - `typeMap = {'m': 1, 'p': 0, 's': 2}`
   - `honorMap = {'E': [3,1], 'S': [3,2], 'W': [3,3], 'N': [3,4], 'P': [3,5], 'F': [3,6], 'C': [3,7]}`
3. Iterate through `mr.hand[i]` in JavaScript
4. Match by `tile.val.type` and `tile.val.index` (note: index is 0-based, tile value is 1-based)
5. For red dora (e.g., "5mr"), also check `tile.val.dora` flag

**References**:
- See `WebViewModel.swift:226-266` for correct implementation
- See `WebViewModel.swift:590-650` for executeAutoPlayAction reference
- Never assume Swift array order matches UI display order

## Common Tasks

### Add a Game Property

1. Define in `GameModels.swift`
2. Add to `GameState` in `GameStateManager.swift:20`
3. Update `MajsoulBridge.swift` parsing to populate it
4. Create SwiftUI component and add to view

### Fix WebSocket Issues

1. Check JS console errors: `curl -X POST http://localhost:8765/js -d 'YOUR_SCRIPT'`
2. Verify `naki-websocket.js` injection in `WebViewController.swift`
3. Check Protobuf parsing in `LiqiParser.swift` if protocol changed
4. Use debug logs in UI (right sidebar, powered by `LogManager`)

### Handle Majsoul Protocol Changes

1. New message fields? Update `LiqiParser.swift` protobuf parsing
2. New action types? Add to `ActionType` enum in `GameModels.swift`
3. Format changes? Update `MajsoulBridge.swift:200-207`
4. Test via debug endpoints to verify parsing

## Important Patterns

- **Service Initialization**: Created in `WebViewModel.init()` (line 30+)
  - See @docs/architecture-deep-dive.md for service initialization order
- **Async Operations**: Use Swift concurrency with `MortalBot` actors
  - See @docs/architecture-deep-dive.md for MortalSwift FFI integration details
- **WebView Bridge**: Two-way communication via message handlers in `WebViewController.swift`
  - See @docs/architecture-deep-dive.md for JavaScript injection details
- **Delegate Callbacks**: `AutoPlayService` uses delegate protocol for action feedback
- **MARK Sections**: Extensive use throughout for code organization

## Code Structure

```
Naki/
├── App/NakiApp.swift              # @main entry point
├── Models/GameModels.swift        # Type-safe game state
├── ViewModels/
│   ├── WebViewModel.swift         # Orchestrator & service coordination
│   └── GameStateManager.swift     # @Observable centralized state
├── Views/                         # SwiftUI components
│   ├── ContentView.swift          # Main layout
│   └── WebViewController.swift    # WKWebView embedding
├── Services/
│   ├── Bridge/                    # Protocol conversion
│   │   ├── MajsoulBridge.swift    # Liqi → MJAI
│   │   └── LiqiParser.swift       # Protobuf parsing
│   ├── Bot/
│   │   └── NativeBotController.swift  # Core ML inference
│   ├── AutoPlay/AutoPlayService.swift # Action execution
│   ├── Debug/DebugServer.swift        # HTTP server (port 8765)
│   └── LogManager.swift
└── Resources/
    ├── JavaScript/naki-*.js
    └── Assets.xcassets
```

## Dependencies

**MortalSwift** (Rust FFI + Core ML):
- Contains `libriichi.a` (compiled Rust)
- Includes `mortal.mlmodelc` (Core ML model)
- Provides async `MortalBot` actor for inference

## Configuration

- **Xcode**: Build configuration in `Naki.xcodeproj`
- **Entitlements**: `akagi.entitlements` - app sandbox, network, file access
- **Minimum macOS**: 13.0 (Ventura)

## Important Warnings

⚠️ **Account Risk**: This tool intercepts game messages and violates Majsoul ToS. Using a main account risks permanent ban. **Use test accounts only.**

See `README.md` for full legal disclaimer and educational use warnings.

## Documentation

For detailed guidance, refer to:
- **FLOW_COMPARISON.md** - Python vs Swift architecture, protocol handling, reconnection logic
- **RELEASE.md** - Version control, tagging, release process
- **docs/debug-api-help-endpoint.md** - Debug server endpoints
- **docs/dev-notes/** - Development notes on specific fixes
- **docs/architecture-deep-dive.md** - Protocol conversion, service initialization, debugging patterns
- **docs/shell-tools-guide.md** - Modern shell tools usage guide

## Shell Tools

All modern shell tools are installed for efficient development. See @docs/shell-tools-guide.md for detailed usage patterns and examples.

| Tool | Purpose | Version |
|------|---------|---------|
| `fd` | File finding | 10.3.0 |
| `rg` (ripgrep) | Text search | 14.1.1 |
| `ast-grep` | AST-based code search | 0.40.0 |
| `fzf` | Interactive fuzzy find | 0.66.1 |
| `jq` | JSON processing | 1.7.1 |
| `yq` | YAML/XML processing | 4.48.1 |

## Verifying Changes

**After any adjustments to this CLAUDE.md file, always verify with Xcode build**:

```bash
# Check file line count (must be < 300 lines)
wc -l CLAUDE.md

# Verify build succeeds
xcodebuild build -project Naki.xcodeproj -scheme Naki

# Or using Claude Code MCP:
mcp__XcodeBuildMCP__build_macos({
  projectPath: "/path/to/Naki.xcodeproj",
  scheme: "Naki"
})
```

**Build validation checklist**:
- ✅ Build succeeds (0 errors)
- ✅ File line count < 300
- ✅ All @import links are valid
- ✅ All file:line references still exist

See @docs/claude-md-refactoring-journal.md for detailed refactoring history and maintenance guidelines.
