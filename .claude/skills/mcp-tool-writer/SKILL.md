---
name: mcp-tool-writer
description: Create, modify, and manage MCP tools for the Naki mahjong AI assistant. Use when adding new MCP tools, modifying existing tools, or fixing tool-related issues. This skill understands the Protocol-based MCPTool architecture.
allowed-tools: Read, Glob, Grep, Write, Edit, Bash
---

# Naki MCP Tool Writer

This skill helps create and modify MCP (Model Context Protocol) tools for the Naki project using the Protocol-based architecture.

## Architecture Overview

Naki uses a Protocol-based MCP architecture:

```
Services/MCP/
├── MCPTool.swift          - Protocol 定義 + Schema 類型
├── MCPContext.swift       - 執行上下文 (async/await 支持)
├── MCPToolRegistry.swift  - 工具註冊表 (單例)
├── MCPHandler.swift       - MCP 協議處理器
└── Tools/
    ├── SystemTools.swift  - 系統類工具
    ├── BotTools.swift     - Bot 控制工具
    ├── GameTools.swift    - 遊戲狀態工具
    └── UITools.swift      - UI 操作工具
```

## How to Create a New MCP Tool

### Step 1: Define the Tool Struct

Create a new struct implementing `MCPTool` protocol:

```swift
struct MyNewTool: MCPTool {
    // 1. 工具名稱 (唯一標識符)
    static let name = "my_new_tool"

    // 2. 工具描述 (給 AI 看的說明)
    static let description = "描述這個工具做什麼，何時使用"

    // 3. 輸入參數 Schema
    static let inputSchema = MCPInputSchema(
        properties: [
            "param1": .string("參數1的描述"),
            "param2": .integer("參數2的描述")
        ],
        required: ["param1"]  // 必填參數
    )

    // 4. 上下文 (用於訪問 JS、Bot 等)
    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    // 5. 執行邏輯
    func execute(arguments: [String: Any]) async throws -> Any {
        // 獲取參數
        guard let param1 = arguments["param1"] as? String else {
            throw MCPToolError.missingParameter("param1")
        }

        // 執行邏輯...

        return ["success": true, "result": "..."]
    }
}
```

### Step 2: Register the Tool

在 `MCPToolRegistry.swift` 的 `registerBuiltInTools()` 方法中添加：

```swift
register(MyNewTool.self)
```

**注意**: Tools 列表會自動從 Registry 生成，無需手動維護 JSON 檔案。

### Step 3: Add to Xcode Project

如果創建了新文件，需要在 `Naki.xcodeproj/project.pbxproj` 的 membershipExceptions 中添加路徑。

## Input Schema Types

```swift
// 無參數
static let inputSchema = MCPInputSchema.empty

// 有參數
static let inputSchema = MCPInputSchema(
    properties: [
        "stringParam": .string("字串參數描述"),
        "intParam": .integer("整數參數描述"),
        "numberParam": .number("數字參數描述"),
        "boolParam": .boolean("布林參數描述"),
        "objectParam": .object("物件參數描述")
    ],
    required: ["stringParam"]  // 必填參數列表
)
```

## Context API

工具可以通過 `context` 訪問以下功能：

```swift
// 執行 JavaScript
let result = try await context.executeJavaScript("return document.title")

// 獲取 Bot 狀態
let status = context.getBotStatus()

// 觸發自動打牌
context.triggerAutoPlay()

// 日誌操作
let logs = context.getLogs()
context.clearLogs()
context.log("記錄訊息")

// 服務器埠號
let port = context.serverPort
```

## Error Handling

使用 `MCPToolError` 處理錯誤：

```swift
throw MCPToolError.missingParameter("paramName")
throw MCPToolError.invalidParameter("paramName", expected: "string")
throw MCPToolError.executionFailed("原因描述")
throw MCPToolError.notAvailable("資源名稱")
```

## Tool Categories

按功能分類放置工具：

| 類別 | 文件 | 工具範例 |
|------|------|---------|
| 系統 | SystemTools.swift | get_status, get_help, get_logs |
| Bot | BotTools.swift | bot_status, bot_trigger |
| 遊戲 | GameTools.swift | game_state, game_hand |
| UI | UITools.swift | execute_js, click, calibrate |

## Checklist for New Tools

- [ ] 定義唯一的 `name`
- [ ] 寫清楚的 `description`（給 AI 理解）
- [ ] 定義正確的 `inputSchema`
- [ ] 實現 `execute()` 方法
- [ ] 處理所有錯誤情況
- [ ] 在 Registry 中註冊
- [ ] 添加到 Xcode 項目（如果是新文件）
- [ ] 構建測試通過
- [ ] 使用 MCP 工具測試功能

## Testing

構建並測試：

```bash
# 構建
xcodebuild build -project Naki.xcodeproj -scheme Naki

# 啟動應用後，使用 MCP 工具測試
mcp__naki__<tool_name>
```

See REFERENCE.md for complete protocol specifications and more examples.
