# MCP Tool Writer Reference

## Complete Protocol Definition

See `MCPTool.swift:15-32`:

```swift
protocol MCPTool {
    static var name: String { get }
    static var description: String { get }
    static var inputSchema: MCPInputSchema { get }

    init(context: MCPContext)
    func execute(arguments: [String: Any]) async throws -> Any
}
```

## Full Examples from Current Codebase

### Example 1: Simple Tool (No Parameters) - SystemTools.swift

```swift
/// 獲取 MCP Server 狀態
struct GetStatusTool: MCPTool {
    static let name = "get_status"
    static let description = "獲取 MCP Server 狀態和埠號"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        return [
            "status": "running",
            "port": context.serverPort,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
    }
}
```

### Example 2: Tool with Required Parameter - GameTools.swift

```swift
/// 打出指定索引的牌
struct GameDiscardTool: MCPTool {
    static let name = "game_discard"
    static let description = "打出指定索引的牌"
    static let inputSchema = MCPInputSchema(
        properties: [
            "tileIndex": .integer("要打出的牌在手牌中的索引 (0-13)")
        ],
        required: ["tileIndex"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let tileIndex = arguments["tileIndex"] as? Int else {
            throw MCPToolError.missingParameter("tileIndex")
        }

        let script = "window.__nakiGameAPI ? __nakiGameAPI.discardTile(\(tileIndex)) : false"
        let result = try await context.executeJavaScript(script)
        let success = result as? Bool ?? false

        return [
            "success": success,
            "tileIndex": tileIndex
        ]
    }
}
```

### Example 3: Tool with Multiple Parameters - UITools.swift

```swift
/// 在指定座標點擊
struct ClickTool: MCPTool {
    static let name = "click"
    static let description = "在指定座標點擊"
    static let inputSchema = MCPInputSchema(
        properties: [
            "x": .number("X 座標"),
            "y": .number("Y 座標"),
            "label": .string("點擊標籤（可選）")
        ],
        required: ["x", "y"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let x = arguments["x"] as? Double else {
            throw MCPToolError.missingParameter("x")
        }
        guard let y = arguments["y"] as? Double else {
            throw MCPToolError.missingParameter("y")
        }

        let label = arguments["label"] as? String ?? "MCP Click"
        let script = "window.__nakiAutoPlay.click(\(x), \(y), '\(label)')"
        _ = try await context.executeJavaScript(script)

        return [
            "result": "clicked",
            "x": x,
            "y": y
        ]
    }
}
```

### Example 4: Tool with JavaScript Execution - BotTools.swift

```swift
/// 強制重連以重建 Bot 狀態
struct BotSyncTool: MCPTool {
    static let name = "bot_sync"
    static let description = "強制斷線重連以重建 Bot 狀態。當 Bot 沒有推薦提示時使用"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        context.log("MCP: Force reconnecting to rebuild Bot state")

        let script = "return window.__nakiWebSocket?.forceReconnect() || 0"
        let result = try await context.executeJavaScript(script)

        let closedCount = (result as? Int) ?? 0
        let success = closedCount > 0

        return [
            "success": success,
            "closedConnections": closedCount,
            "message": success ? "已關閉 \(closedCount) 個連線，遊戲將自動重連" : "沒有找到可關閉的連線"
        ]
    }
}
```

### Example 5: Tool with Optional Parameters & Defaults - UITools.swift

```swift
/// 設定校準參數
struct CalibrateTool: MCPTool {
    static let name = "calibrate"
    static let description = "設定校準參數"
    static let inputSchema = MCPInputSchema(
        properties: [
            "tileSpacing": .number("牌間距（默認 96）"),
            "offsetX": .number("X 偏移（默認 -200）"),
            "offsetY": .number("Y 偏移（默認 0）")
        ],
        required: []  // 全部可選
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        // 使用默認值處理可選參數
        let tileSpacing = arguments["tileSpacing"] as? Double ?? 96
        let offsetX = arguments["offsetX"] as? Double ?? -200
        let offsetY = arguments["offsetY"] as? Double ?? 0

        let script = """
        if (window.__nakiAutoPlay) {
            window.__nakiAutoPlay.calibration = {
                tileSpacing: \(tileSpacing),
                offsetX: \(offsetX),
                offsetY: \(offsetY)
            };
            JSON.stringify(window.__nakiAutoPlay.calibration);
        } else {
            'Not loaded';
        }
        """
        _ = try await context.executeJavaScript(script)

        return [
            "result": "calibrated",
            "tileSpacing": tileSpacing,
            "offsetX": offsetX,
            "offsetY": offsetY
        ]
    }
}
```

## MCPContext API Reference

定義在 `MCPContext.swift:15-38`：

```swift
protocol MCPContext: AnyObject {
    /// 伺服器埠號
    var serverPort: UInt16 { get }

    /// 執行 JavaScript（async/await）
    func executeJavaScript(_ script: String) async throws -> Any?

    /// 獲取 Bot 狀態
    func getBotStatus() -> [String: Any]?

    /// 觸發自動打牌
    func triggerAutoPlay()

    /// 獲取日誌
    func getLogs() -> [String]

    /// 清空日誌
    func clearLogs()

    /// 記錄日誌
    func log(_ message: String)
}
```

### executeJavaScript Usage

**⚠️ 重要**：必須使用 `return` 語句才能正確返回值！

```swift
// ✅ 正確：使用 return 語句
let title = try await context.executeJavaScript("return document.title")
let sum = try await context.executeJavaScript("return 1 + 1")
let json = try await context.executeJavaScript("return JSON.stringify({a:1})")

// ✅ 正確：調用遊戲 API 並返回結果
let result = try await context.executeJavaScript("return window.__nakiGameAPI.getGameState()")

// ❌ 錯誤：沒有 return，結果為 nil
let title = try await context.executeJavaScript("document.title")  // 返回 nil！
```

### getBotStatus 返回結構

```swift
{
    "botStatus": { "playerId": 0, "isActive": false },
    "recommendations": [...],
    "tehaiCount": 13,
    "tsumoTile": "5m",
    "gameState": { "bakaze": "東", "kyoku": 1 },
    "autoPlay": { "mode": "自動", "isMyTurn": true }
}
```

## MCPInputSchema Reference

定義在 `MCPTool.swift:37-56`：

### Property Types

```swift
MCPPropertySchema.string("描述")     // "type": "string"
MCPPropertySchema.integer("描述")    // "type": "integer"
MCPPropertySchema.number("描述")     // "type": "number"
MCPPropertySchema.boolean("描述")    // "type": "boolean"
MCPPropertySchema.object("描述")     // "type": "object"
```

### Schema Examples

```swift
// 空 Schema（無參數）
MCPInputSchema.empty

// 單一必填參數
MCPInputSchema(
    properties: ["code": .string("JavaScript 代碼")],
    required: ["code"]
)

// 多參數混合（部分必填）
MCPInputSchema(
    properties: [
        "x": .number("X 座標"),
        "y": .number("Y 座標"),
        "label": .string("點擊標籤（可選）")
    ],
    required: ["x", "y"]
)

// 全部可選參數
MCPInputSchema(
    properties: [
        "limit": .integer("最大數量"),
        "offset": .integer("起始位置")
    ],
    required: []
)
```

## MCPToolError Reference

定義在 `MCPTool.swift:129-147`：

```swift
enum MCPToolError: LocalizedError {
    case missingParameter(String)           // 缺少必填參數
    case invalidParameter(String, expected: String)  // 參數類型錯誤
    case executionFailed(String)            // 執行失敗
    case notAvailable(String)               // 資源不可用
}

// 使用範例
throw MCPToolError.missingParameter("code")
throw MCPToolError.invalidParameter("x", expected: "number")
throw MCPToolError.executionFailed("Game API not loaded")
throw MCPToolError.notAvailable("Bot status")
```

## MCPToolResult Reference

定義在 `MCPTool.swift:106-124`：

```swift
enum MCPToolResult {
    case success(Any)
    case error(String)

    var isSuccess: Bool
    var value: Any?
    var errorMessage: String?
}
```

## Registration in MCPToolRegistry

位置：`MCPToolRegistry.swift:142-182`

```swift
extension MCPToolRegistry {
    func registerBuiltInTools() {
        // 系統類
        register(GetStatusTool.self)
        register(GetHelpTool.self)
        register(GetLogsTool.self)
        register(ClearLogsTool.self)

        // Bot 控制類
        register(BotStatusTool.self)
        register(BotTriggerTool.self)
        register(BotOpsTool.self)
        register(BotDeepTool.self)
        register(BotChiTool.self)
        register(BotPonTool.self)
        register(BotSyncTool.self)

        // 遊戲狀態類
        register(GameStateTool.self)
        register(GameHandTool.self)
        register(GameOpsTool.self)
        register(GameDiscardTool.self)
        register(GameActionTool.self)

        // JavaScript 執行
        register(ExecuteJSTool.self)

        // 探索類
        register(DetectTool.self)
        register(ExploreTool.self)

        // UI 操作類
        register(TestIndicatorsTool.self)
        register(ClickTool.self)
        register(CalibrateTool.self)

        // UI 控制類
        register(UINameStatusTool.self)
        register(UINameHideTool.self)
        register(UINameShowTool.self)
        register(UINameToggleTool.self)
    }
}
```

## File Locations

| 類型 | 路徑 | 行數範圍 |
|------|------|---------|
| Protocol | `command/Services/MCP/MCPTool.swift` | 15-32 |
| InputSchema | `command/Services/MCP/MCPTool.swift` | 37-56 |
| PropertySchema | `command/Services/MCP/MCPTool.swift` | 59-101 |
| ToolResult | `command/Services/MCP/MCPTool.swift` | 106-124 |
| ToolError | `command/Services/MCP/MCPTool.swift` | 129-147 |
| Context Protocol | `command/Services/MCP/MCPContext.swift` | 15-38 |
| DefaultContext | `command/Services/MCP/MCPContext.swift` | 44-102 |
| Registry | `command/Services/MCP/MCPToolRegistry.swift` | 15-136 |
| Registration | `command/Services/MCP/MCPToolRegistry.swift` | 142-182 |
| Handler | `command/Services/MCP/MCPHandler.swift` | 16-314 |
| SystemTools | `command/Services/MCP/Tools/SystemTools.swift` | 全部 |
| BotTools | `command/Services/MCP/Tools/BotTools.swift` | 全部 |
| GameTools | `command/Services/MCP/Tools/GameTools.swift` | 全部 |
| UITools | `command/Services/MCP/Tools/UITools.swift` | 全部 |

## Testing Checklist

1. ✅ `xcodebuild build -project Naki.xcodeproj -scheme Naki` 成功
2. ✅ 啟動應用
3. ✅ 使用 `mcp__naki__<tool_name>` 測試
4. ✅ 檢查返回結果格式正確
5. ✅ 測試錯誤處理（缺少參數、無效參數）
6. ✅ 檢查日誌輸出（`mcp__naki__get_logs`）

## Common Patterns

### Pattern 1: 調用遊戲 API 並解析 JSON

```swift
func execute(arguments: [String: Any]) async throws -> Any {
    let script = """
    window.__nakiGameAPI ? JSON.stringify(__nakiGameAPI.getGameState()) : '{"error": "API not loaded"}'
    """
    let result = try await context.executeJavaScript(script)

    if let jsonString = result as? String,
       let data = jsonString.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) {
        return json
    }
    return ["result": result ?? NSNull()]
}
```

### Pattern 2: 執行操作並記錄日誌

```swift
func execute(arguments: [String: Any]) async throws -> Any {
    context.log("MCP: Starting operation...")

    // 執行操作
    let result = try await context.executeJavaScript("...")

    context.log("MCP: Operation completed")
    return ["success": true, "result": result ?? NSNull()]
}
```

### Pattern 3: 獲取 Bot 狀態並檢查可用性

```swift
func execute(arguments: [String: Any]) async throws -> Any {
    guard let status = context.getBotStatus() else {
        throw MCPToolError.notAvailable("Bot status")
    }
    return status
}
```
