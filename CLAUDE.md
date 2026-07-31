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
```

**Key Files**: `command/ViewModels/WebViewModel.swift`, `command/Services/Bridge/MajsoulBridge.swift`, `command/Services/Bot/NativeBotController.swift`

### 雀魂是 Unity WebGL（不是 Laya）

客戶端為 Unity WebGL（`chs_t-WebGL-release-4.0.45(45)`），頁面只有
`<canvas id="unity-canvas">`。舊 Laya 全域（`Laya` / `GameMgr` / `uiscript` /
`view.DesktopMgr` / `cfg` / `app.NetAgent`）**全部不存在**。

**所有動作與狀態一律走 Liqi protobuf**，送出用
`window.__nakiWebSocket.sendRaw(base64)`。協議格式、msgId 規則 → @docs/majsoul-unity-protocol.md

⚠️ **送出必須選對連線**：大廳走 `/gateway`、對局走 `/game-gateway`。
送錯會得到 `error code 6 "method not found"`，而且**沒有任何其他徵兆**。

## Critical Information

<IMPORTANT>
### Protocol Parsing
- **Normal messages**: Base64 → XOR decode → Protobuf
- **Reconnection**: Base64 → NO XOR → Protobuf (already decoded)
- No additional `start_game` on syncGame

### Liqi Envelope
`[type:1][msgId:2 LE][protobuf{ field1=method 字串, field2=payload }]`；
type 1=NOTIFY / 2=REQUEST / 3=RESPONSE。method 名**明文**、request **無 XOR**。
Naki 自送的請求用 **msgId 60000+**（遊戲用低位遞增，避免撞號）。

⚠️ **欄位編號一律查 `docs/protocol/liqi.json`，不要照舊碼或記憶**。
舊碼的欄位編號是 Laya 時代猜的，實際全錯（`operation` 在 ActionDealTile /
ActionDiscardTile 是 4、ActionNewRound 是 7、ActionChiPengGang 是 6），
且 `operation_list` 是 repeated——解錯的後果是 oplist 恆空、自動打牌無法判斷輪到誰。

### Game Lifecycle
Each `start_game` triggers fresh Bot creation (delete + recreate) and `end_game` cleans up — already implemented in `NakiWebCoordinator.handleMJAIEvent` (`command/Views/WebViewController.swift:159-199`). See `FLOW_COMPARISON.md`.

### 牌面位置與染色：用遊戲自己的資料，不要自己算
**每張牌是獨立的 draw call，位置與染色參數都在 shader uniform 裡**（2026-07-31 實測）。
不需要掃描像素、不需要推算螢幕座標、不需要自己畫覆蓋層。

攔 `drawElements` 後用 `gl.getUniform(currentProgram, loc)` 讀，或在 draw 前覆寫：

| 對象 | 辨識特徵 | 位置 uniform | 顏色 uniform |
|------|---------|-------------|-------------|
| 麻將牌 | `count === 606` | `hlslcc_mtx4x4unity_ObjectToWorld[0..3]`（第 4 列＝位置） | `_Tint`（實測全程 `[1,1,1,1]`，遊戲沒在用 → 可安全覆寫） |
| UI（吃/碰/立直等按鈕） | `count` 為 6/12/18/24…（quad 倍數） | 同上，另有 `glstate_matrix_projection` | `_Color` |

實測一幀約 533 個 draw call、13 個 shader program、31 個 texture；
牌那組每幀約 98 次獨立呼叫——**每張牌、每個按鈕都是獨立可定址的**。

取得 Unity instance 的方式（易踩）：`window.unityFramework` 是 **`null`**、
`window.unityInstance` **不存在**；instance 宣告在 inline script 的 script scope，
只能用**裸識別字** `unityInstance` 取（Debug Server `/js` 在 page world 執行，可取得）。

### 客戶端配置表：可下載，不在 wasm 裡
`window.cfg` 全域物件確實沒了，但配置資料仍以資源檔公開：
`res/config/lqc.lqbin`（17.5MB）+ `res/proto/config.proto`（自描述 schema），
41 tables / 263 sheets / 119,289 rows。取法與 liqi.json 相同。
解析工具 `tools/parse_lqc.py`、`tools/dump_sheet.py`。詳見 @docs/majsoul-config-tables.md
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

- @docs/majsoul-unity-protocol.md - ⭐ 雀魂互動的唯一參考（Liqi envelope、Unity 可控面、驗證紀錄）
- @docs/majsoul-config-tables.md - 客戶端配置表 `lqc.lqbin` 的取得與解析
- @docs/protocol/liqi.json - **協定欄位的唯一事實來源**
- @docs/architecture-deep-dive.md - Protocol, services, debugging
- FLOW_COMPARISON.md - Python vs Swift, reconnection logic
- AUDIT.md - 稽核紀錄（§9–§11 Unity 遷移全紀錄）
