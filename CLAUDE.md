# CLAUDE.md

**Naki (鳴き)** - Native macOS mahjong AI assistant for Majsoul (雀魂).

| Property | Value |
|----------|-------|
| Type | Native macOS App (Swift/SwiftUI) |
| Platform | macOS 13.0+ |
| Swift | 5.9+ |
| Version | 2.3.0 |

## Quick Commands

```bash
open Naki.xcodeproj                                    # Open project
xcodebuild build -project Naki.xcodeproj -scheme Naki  # Build
xcodebuild test -project Naki.xcodeproj -scheme Naki   # Test
```

<EXTREMELY_IMPORTANT>
**MCP 調用規則**: 所有 Naki MCP 工具必須透過 `/naki-mcp-proxy` skill 調用，禁止直接調用 `mcp__naki__*` 工具。
- 節省 40-70% tokens (工具 schema 僅載入 agent 上下文)
- 參考 @.claude/skills/naki-mcp-proxy/SKILL.md (47 tools)

**Debug Server /js 端點注意事項**:
- ⚠️ **必須使用 `return` 語句**才能獲取返回值（函數體格式）
- 正確：`curl -X POST http://localhost:8765/js -d 'return 1+1'` → 返回 2
- 錯誤：`curl -X POST http://localhost:8765/js -d '1+1'` → 返回 null
- 複雜對象使用 `return JSON.stringify(obj)` 或直接 return（會自動序列化）
</EXTREMELY_IMPORTANT>

## Three-Tier Boundaries

### Always (Must-Do)
- Use absolute paths for all file operations
- Log all account-affecting operations
- Verify destructive operations before executing

### Ask (Require Confirmation)
- Modifying WebSocket interception logic
- Changes to auto-play behavior
- Account-related operations

### Never (Forbidden)
- Never use main Majsoul account (permanent ban risk)
- Never commit game session tokens or credentials
- Never bypass Majsoul ToS detection mechanisms

## Architecture

```
WKWebView → WebSocketInterceptor/MajsoulBridge (Liqi→MJAI)
         → NativeBotController (Core ML via MortalSwift FFI)
         → GameStateManager (@Observable)
         → AutoPlayService → SwiftUI Views
```

**Key Files**: `WebViewModel.swift:1162`, `MajsoulBridge.swift:1176`, `NativeBotController.swift:902`

## Critical Information

<IMPORTANT>
### Protocol Parsing
- **Normal messages**: Base64 → XOR decode → Protobuf
- **Reconnection**: Base64 → NO XOR → Protobuf (already decoded)
- No additional `start_game` on syncGame

### Tile Index Mapping
Swift `tehai` array ≠ Majsoul UI order. Use `executeAutoPlayAction` in `WebViewModel.swift:226-266`.

### Game Lifecycle
Each `authGame` must trigger fresh Bot creation. See `FLOW_COMPARISON.md:290-295`.

### 雀魂配置結構（cfg）
- `cfg` 是**函數/對象**，不是 `window.cfg`（直接用 `cfg.xxx` 存取）
- 配置使用自定義表格結構：`cfg.xxx.rows_`（陣列）、`cfg.xxx.table_`（索引）
- 例：`cfg.snowball.snowball_monster_group.rows_[0].round_time`
- 不要用 `cfg.snowball.snowball_monster_group[0]`（會失敗）
</IMPORTANT>

## Code Structure

```
Naki/
├── App/NakiApp.swift
├── Models/GameModels.swift
├── ViewModels/{WebViewModel,GameStateManager}.swift
├── Views/{ContentView,WebViewController}.swift
├── Services/{Bridge/,Bot/,AutoPlay/,Debug/}
└── Resources/JavaScript/naki-*.js
```

## Documentation

- @docs/architecture-deep-dive.md - Protocol, services, debugging
- @docs/shell-tools-guide.md - Modern shell tools (fd, rg, ast-grep)
- @docs/majsoul-webui-objects-reference.md - Game UI objects
- @docs/majsoul-minigame-snowball-reference.md - 雪球小遊戲框架、配置修改
- FLOW_COMPARISON.md - Python vs Swift, reconnection logic
