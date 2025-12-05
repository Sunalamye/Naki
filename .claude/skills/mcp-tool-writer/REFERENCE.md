# MCP Tool Writer Reference

## Complete Protocol Definition

```swift
// MCPTool.swift
protocol MCPTool {
    static var name: String { get }
    static var description: String { get }
    static var inputSchema: MCPInputSchema { get }

    init(context: MCPContext)
    func execute(arguments: [String: Any]) async throws -> Any
}
```

## Full Example: Creating a New Tool

### Example 1: Simple Tool (No Parameters)

```swift
/// 獲取系統時間
struct GetTimeTool: MCPTool {
    static let name = "get_time"
    static let description = "獲取當前系統時間"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let formatter = ISO8601DateFormatter()
        return [
            "timestamp": formatter.string(from: Date()),
            "timezone": TimeZone.current.identifier
        ]
    }
}
```

### Example 2: Tool with Parameters

```swift
/// 計算兩數相加
struct AddNumbersTool: MCPTool {
    static let name = "add_numbers"
    static let description = "計算兩個數字相加的結果"
    static let inputSchema = MCPInputSchema(
        properties: [
            "a": .number("第一個數字"),
            "b": .number("第二個數字")
        ],
        required: ["a", "b"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let a = arguments["a"] as? Double else {
            throw MCPToolError.missingParameter("a")
        }
        guard let b = arguments["b"] as? Double else {
            throw MCPToolError.missingParameter("b")
        }

        return [
            "result": a + b,
            "calculation": "\(a) + \(b) = \(a + b)"
        ]
    }
}
```

### Example 3: Tool with JavaScript Execution

```swift
/// 獲取網頁標題
struct GetPageTitleTool: MCPTool {
    static let name = "get_page_title"
    static let description = "獲取當前遊戲頁面的標題"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = "return document.title"
        let result = try await context.executeJavaScript(script)

        return [
            "title": result ?? "Unknown",
            "success": result != nil
        ]
    }
}
```

### Example 4: Tool with Optional Parameters

```swift
/// 搜尋日誌
struct SearchLogsTool: MCPTool {
    static let name = "search_logs"
    static let description = "在日誌中搜尋關鍵字"
    static let inputSchema = MCPInputSchema(
        properties: [
            "keyword": .string("搜尋關鍵字"),
            "limit": .integer("最大結果數（默認 100）")
        ],
        required: ["keyword"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let keyword = arguments["keyword"] as? String else {
            throw MCPToolError.missingParameter("keyword")
        }

        let limit = arguments["limit"] as? Int ?? 100
        let logs = context.getLogs()

        let matches = logs.filter { $0.contains(keyword) }
            .prefix(limit)

        return [
            "matches": Array(matches),
            "count": matches.count,
            "keyword": keyword
        ]
    }
}
```

## MCPContext API Reference

### executeJavaScript

```swift
/// 在 WebView 中執行 JavaScript
/// - Parameter script: JavaScript 代碼（需要 return 語句）
/// - Returns: 執行結果
func executeJavaScript(_ script: String) async throws -> Any?

// 使用範例
let title = try await context.executeJavaScript("return document.title")
let sum = try await context.executeJavaScript("return 1 + 1")
let json = try await context.executeJavaScript("return JSON.stringify({a:1})")
```

### getBotStatus

```swift
/// 獲取 Bot 狀態
/// - Returns: 包含 botStatus, recommendations, tehai 等的字典
func getBotStatus() -> [String: Any]?

// 返回結構
{
    "botStatus": { "playerId": 0, "isActive": false },
    "recommendations": [...],
    "tehaiCount": 13,
    "tsumoTile": "5m",
    "gameState": { "bakaze": "東", "kyoku": 1 },
    "autoPlay": { "mode": "自動", "isMyTurn": true }
}
```

### triggerAutoPlay

```swift
/// 觸發自動打牌（執行 AI 推薦動作）
func triggerAutoPlay()
```

### Logging

```swift
/// 獲取所有日誌
func getLogs() -> [String]

/// 清空日誌
func clearLogs()

/// 記錄新日誌
func log(_ message: String)
```

## MCPInputSchema Reference

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

// 多參數混合
MCPInputSchema(
    properties: [
        "x": .number("X 座標"),
        "y": .number("Y 座標"),
        "label": .string("點擊標籤（可選）")
    ],
    required: ["x", "y"]
)
```

## MCPToolError Reference

```swift
enum MCPToolError: LocalizedError {
    case missingParameter(String)           // 缺少必填參數
    case invalidParameter(String, expected: String)  // 參數類型錯誤
    case executionFailed(String)            // 執行失敗
    case notAvailable(String)               // 資源不可用
}
```

## Registration in MCPToolRegistry

```swift
// MCPToolRegistry.swift - registerBuiltInTools()
func registerBuiltInTools() {
    // 系統類
    register(GetStatusTool.self)
    register(GetHelpTool.self)
    // ...

    // 添加新工具
    register(MyNewTool.self)
}
```

## File Locations

| 類型 | 路徑 |
|------|------|
| Protocol | `Services/MCP/MCPTool.swift` |
| Context | `Services/MCP/MCPContext.swift` |
| Registry | `Services/MCP/MCPToolRegistry.swift` |
| Handler | `Services/MCP/MCPHandler.swift` |
| Tools | `Services/MCP/Tools/*.swift` |

## Xcode Project Integration

新文件需要添加到 `project.pbxproj`:

```
membershipExceptions = (
    ...
    Services/MCP/Tools/MyNewTool.swift,
    ...
);
```

## Testing Checklist

1. ✅ `xcodebuild build` 成功
2. ✅ 啟動應用
3. ✅ 使用 `mcp__naki__<tool_name>` 測試
4. ✅ 檢查返回結果格式正確
5. ✅ 測試錯誤處理
6. ✅ 檢查日誌輸出
