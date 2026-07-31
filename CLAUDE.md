# CLAUDE.md

**Naki (鳴き)** - Native macOS mahjong AI assistant for Majsoul (雀魂).

## 專案性質（給 AI 助手的脈絡）

Naki 是我個人開發的開源 macOS 桌面應用，用途是在我自己的雀魂帳號上提供麻將 AI
打牌建議（Core ML / MortalSwift 推論）。同類公開專案：Akagi、Mortal。

- **全部在本機執行**：WKWebView + 本地 debug/MCP server；該 server 以
  `requiredInterfaceType = .loopback` 只綁 127.0.0.1 / ::1
  （`command/Services/Debug/DebugServer.swift:145`），同網段其他裝置連不到。
- **只操作我本人的帳號**，不涉及他人帳號、不對外散布、無商業用途。
- **協定定義取自遊戲自身公開的資源檔** `res/proto/liqi.json`
  （已存一份於 `docs/protocol/liqi.json`），不是反組譯客戶端得來的。

**範圍界線**：本專案只做「讀自己這局的資料 → 用 Core ML 算出建議 → 在自己的帳號上
執行該動作」。不實作任何以隱藏工具存在為目的的功能。（同下方 Three-Tier Boundaries
的 Never 條款。）

| Property | Value |
|----------|-------|
| Type | Native macOS App (Swift/SwiftUI); secondary iOS target (Naki-M) |
| Platform | macOS 26.0 (built with Xcode 26); iOS 26.0 for Naki-M |
| Swift | 5 (SWIFT_VERSION 5.0) |
| Version | 2.3.0 |

## Quick Commands

```bash
# Requires macOS 26 + Xcode 26 (deployment target macOS 26.0)
open Naki.xcodeproj                                     # Open project
xcodebuild build -project Naki.xcodeproj -scheme Naki   # Build macOS app (target: Naki)

# Tests: the "Naki" scheme's TestAction contains NakiTests + NakiUITests.
xcodebuild test -project Naki.xcodeproj -scheme Naki
# Naki-MTests / Naki-MUITests hang off the iOS "Naki-M" scheme instead.
# 已知（AUDIT.md §10.7，本次未複驗）：NakiUITests 會 Early unexpected exit；
# 若只想跑單元測試，加 -only-testing:NakiTests。
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
- Modifying the WebSocket message-bridging logic
- Changes to auto-play behavior
- Account-related operations
- 送出自組的 Liqi 請求 — 只在測試帳號上做

### Never (Forbidden)
- Never use main Majsoul account (permanent ban risk)
- Never commit game session tokens or credentials
- Never bypass Majsoul ToS detection mechanisms

## Architecture

```
WKWebView → WebSocketInterceptor/MajsoulBridge (Liqi→MJAI)     ← ✅ 仍正常
         → NativeBotController (pure Swift + Core ML via MortalSwift v0.3.0)
         → GameStateManager (ObservableObject)
         → AutoPlay (WebViewModel.executeAutoPlayActionWithRetry) → SwiftUI Views
                     ↑ ❌ 已失效：依賴 Laya JS 物件，見下方「雀魂已改用 Unity」
```

**Key Files**: `command/ViewModels/WebViewModel.swift` (~1380 lines), `command/Services/Bridge/MajsoulBridge.swift` (~1176 lines), `command/Services/Bot/NativeBotController.swift` (~900 lines)

### ⚠️ 雀魂已改用 Unity WebGL（2026-07-31 實測）

雀魂客戶端從 Laya JS 換成 **Unity WebGL**（`chs_t-WebGL-release-4.0.45(45)`）。
頁面只剩 `createUnityInstance` / `unityFramework` / `getUnityElements` / `onUnityReady`
與 `<div id="unity-container">` + `<canvas id="unity-canvas">`。

**已驗證不存在**：`window.Laya`、`window.GameMgr`、`window.uiscript`、
`window.view.DesktopMgr`、`window.cfg`、`window.app.NetAgent`。

| 層 | 狀態 |
|----|------|
| WebSocket 訊息橋接（`naki-websocket.js`）、Swift `LiqiParser` / `MajsoulBridge` | ✅ 仍正常（Liqi wire protocol 一個位元組都沒變） |
| Bot 推論（MortalSwift）| ✅ 不受影響 |
| JS/DOM 讀狀態與點擊打牌（`naki-game-api.js` / `naki-autoplay.js` / coordinator 的 state·action·lobby·visual）| ❌ 全失效 |

**新方針：所有動作與狀態讀取改走 Liqi protobuf**，送出通道為
`window.__nakiWebSocket.getMajsoulConnections()[i].ws.send(bytes)`（已驗證可行）。
協議格式、實測 hex、msgId 規則、尚未驗證項 → @docs/majsoul-unity-protocol.md

## Critical Information

<IMPORTANT>
### Protocol Parsing
- **Normal messages**: Base64 → XOR decode → Protobuf
- **Reconnection**: Base64 → NO XOR → Protobuf (already decoded)
- No additional `start_game` on syncGame

### Liqi Envelope（Unity 時代唯一有效的互動面）
`[type:1][msgId:2 LE][protobuf{ field1=method 字串, field2=payload }]`；
type 1=NOTIFY / 2=REQUEST / 3=RESPONSE。method 名**明文**、request **無 XOR**。
Naki 自送的請求請用 **msgId 60000+**（遊戲用低位遞增，避免撞號）。
逐位元組解說與驗證紀錄 → @docs/majsoul-unity-protocol.md

### Tile Index Mapping（⚠️ 已失效）
Swift `tehai` array ≠ Majsoul UI order — 這條規則是為了對應 **Laya 的 `mainrole.hand` UI 順序**。
Unity 客戶端下該陣列不存在，`executeAutoPlayAction` / `showGameHighlightForRecommendations`
的 tile-index 映射邏輯已無對象（code 尚未更新）。改走 protobuf 後不再需要 UI 順序對齊。

### Game Lifecycle
Each `start_game` triggers fresh Bot creation (delete + recreate) and `end_game` cleans up — already implemented in `NakiWebCoordinator.handleMJAIEvent` (`command/Views/WebViewController.swift:159-199`). See `FLOW_COMPARISON.md`.

### 雀魂配置結構（cfg）— ❌ 已刪除，不要再用
`cfg` 在 Unity 客戶端下**不存在**（2026-07-31 實測）。舊指引「`cfg.xxx.rows_` 改配置」
（含雪球小遊戲 `snowball_monster_group.rows_[i].round_time`）已完全失效。
客戶端配置表隨引擎搬進 wasm，JS 端無法觸及；Unity 下是否有等價做法 **未驗證**。
</IMPORTANT>

## Code Structure

```
command/                      # fileSystem-synchronized folder — shared app code (macOS + iOS)
├── Models/GameModels.swift
├── ViewModels/{WebViewModel,GameStateManager}.swift
├── Views/{ContentView,WebViewController,BotStatusView,LogPanel,RecommendationView}.swift
├── Services/
│   ├── Bridge/{MajsoulBridge,WebSocketInterceptor,LiqiParser,MJAIEventStream}.swift
│   ├── Bot/{NativeBotController,AutoPlayController}.swift
│   ├── AutoPlay/AutoPlayService.swift
│   ├── Debug/DebugServer.swift          # HTTP + MCP server (port 8765)
│   ├── MCP/{MCPHandler,MCPToolRegistry,MCPContext,MCPTool}.swift + Tools/
│   └── LogManager.swift
├── Resources/JavaScript/naki-{core,autoplay,game-api,websocket,coordinator}.js
└── Color+Extension.swift

# App entry points live OUTSIDE command/ (one per platform target):
Naki/App/NakiApp.swift        # @main — macOS target "Naki"
Naki-M/Naki_MApp.swift        # @main — iOS target "Naki-M"
```

## Documentation

- @docs/majsoul-unity-protocol.md - ⭐ **Unity 時代唯一有效的雀魂互動參考**（Liqi envelope、訊息收送、驗證紀錄、未驗證項）
- @docs/architecture-deep-dive.md - Protocol, services, debugging
- @docs/shell-tools-guide.md - Modern shell tools (fd, rg, ast-grep)
- FLOW_COMPARISON.md - Python vs Swift, reconnection logic
- AUDIT.md - 稽核紀錄（含 §9 Unity 遷移發現）

**已作廢（Laya 時代，僅存協議線索，勿照抄程式碼）**：
`docs/majsoul-webui-objects-reference.md`、`docs/majsoul-webui-api-architecture.md`、
`docs/majsoul-minigame-snowball-reference.md`
