# MCPKit

Swift 實現的 Model Context Protocol (MCP) 框架，提供工具定義、註冊、執行和 HTTP 傳輸層。

## 特點

- 🔧 **Protocol-First 設計** - 使用 Swift Protocol 定義工具介面
- 📦 **模組化架構** - Core、Transport 層分離
- 🚀 **Async/Await 支援** - 完整的 Swift Concurrency 支援
- 🔌 **可擴展** - 易於添加自定義工具和傳輸層
- 🧪 **可測試** - 完整的單元測試支援

## 安裝

### Swift Package Manager

```swift
dependencies: [
    .package(path: "../Packages/MCPKit")
]
```

## 快速開始

### 1. 定義工具

```swift
import MCPKit

struct MyTool: MCPTool {
    static let name = "my_tool"
    static let description = "我的自定義工具"
    static let inputSchema = MCPInputSchema(
        properties: [
            "message": .string("輸入訊息")
        ],
        required: ["message"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let message = arguments["message"] as? String else {
            throw MCPToolError.missingParameter("message")
        }
        return ["result": "處理完成: \(message)"]
    }
}
```

### 2. 實現 Context

```swift
@MainActor
class MyAppContext: MCPContext {
    var serverPort: UInt16 = 8765

    func executeJavaScript(_ script: String) async throws -> Any? {
        // 如果你的應用有 WebView，在這裡實現
        throw MCPToolError.notAvailable("JavaScript execution")
    }

    func getLogs() -> [String] {
        return myLogBuffer
    }

    func clearLogs() {
        myLogBuffer.removeAll()
    }

    func log(_ message: String) {
        print("[MyApp] \(message)")
    }
}
```

### 3. 啟動伺服器

```swift
import MCPKit

@MainActor
func startServer() {
    let context = MyAppContext()
    let registry = MCPToolRegistry()

    // 註冊內建工具
    registry.registerBuiltInTools()

    // 註冊自定義工具
    registry.register(MyTool.self)

    // 啟動 HTTP 伺服器
    let server = MCPHTTPServer(context: context, registry: registry, port: 8765)
    server.start()
}
```

### 4. 添加自定義路由

```swift
// 添加 GET 路由
server.get("/my-endpoint") { body, respond in
    respond(200, "{\"hello\": \"world\"}", "application/json")
}

// 添加 POST 路由
server.post("/my-action") { body, respond in
    // 處理 body...
    respond(200, "{\"success\": true}", "application/json")
}
```

## 架構

```
MCPKit/
├── Core/
│   ├── MCPTool.swift          # 工具協議和類型定義
│   ├── MCPContext.swift       # 執行上下文協議
│   ├── MCPToolRegistry.swift  # 工具註冊表
│   └── MCPHandler.swift       # JSON-RPC 處理器
├── Transport/
│   └── MCPHTTPServer.swift    # HTTP 傳輸層
└── Tools/
    └── BuiltInTools.swift     # 內建工具
```

## 內建工具

| 工具名稱 | 描述 |
|---------|------|
| `get_status` | 獲取伺服器狀態 |
| `get_logs` | 獲取日誌 |
| `clear_logs` | 清空日誌 |
| `execute_js` | 執行 JavaScript（需要 WebView 支援）|

## 與 Claude Code 整合

MCPKit 完全相容 Claude Code 的 MCP 協議，可以直接配置為 MCP Server：

```json
{
  "mcpServers": {
    "my-app": {
      "url": "http://localhost:8765/mcp"
    }
  }
}
```

## License

MIT License
