# Debug API Help 端點新增記錄

> 日期：2025-12-03
> 修改文件：`Naki/Services/Debug/DebugServer.swift`

---

## 需求描述

在 Debug API 中新增一個 `/help` 端點，提供 **AI 友好** 的 JSON 格式 API 文檔，方便 AI 助手（如 Claude、GPT）理解和使用 Debug API。

### 為什麼需要 AI 友好的格式？

| 格式 | 適用對象 | 特點 |
|------|---------|------|
| HTML (`/`) | 人類 | 可視化、有樣式、易於瀏覽 |
| JSON (`/help`) | AI | 結構化、易於解析、可程式化處理 |

AI 助手在使用 API 時，需要：
1. 知道有哪些端點可用
2. 了解每個端點的參數和返回值
3. 理解常見的使用流程
4. 知道牌的表示法（MJAI 格式）

---

## 問題定位過程

### 1. 查找 Debug Server 實現

```bash
# 找到 Debug Server 文件
ls Naki/Services/Debug/
# 結果：DebugServer.swift
```

### 2. 分析現有路由結構

閱讀 `DebugServer.swift`，找到路由處理邏輯（行 137-207）：

```swift
// 路由處理
switch (method, path) {
case ("GET", "/"):
    handleRoot(connection: connection)  // HTML 首頁

case ("GET", "/status"):
    handleStatus(connection: connection)

// ... 其他端點
}
```

### 3. 分析現有 HTML 首頁

`handleRoot` 方法（行 211-260）返回 HTML 格式的端點列表，但這對 AI 不友好：

```swift
private func handleRoot(connection: NWConnection) {
    let html = """
    <!DOCTYPE html>
    <html>
    <head><title>Naki Debug Server</title></head>
    <body>
    <h1>🀄 Naki Debug Server</h1>
    <h2>Available Endpoints:</h2>
    <ul>
        <li><code>GET /status</code> - Get server status</li>
        ...
    </ul>
    </body>
    </html>
    """
    sendResponse(connection: connection, status: 200, body: html, contentType: "text/html")
}
```

**問題**：
- HTML 格式難以程式化解析
- 缺少參數和返回值的詳細說明
- 沒有使用範例和工作流程

---

## 修改方案

### 設計原則

1. **結構化**：使用 JSON 格式，便於解析
2. **完整性**：包含所有端點的詳細資訊
3. **實用性**：提供使用範例和常見工作流程
4. **領域知識**：包含麻將牌的表示法說明

### JSON 結構設計

```json
{
  "name": "API 名稱",
  "version": "版本號",
  "description": "API 描述",
  "base_url": "基礎 URL",
  "endpoints": [
    {
      "method": "HTTP 方法",
      "path": "路徑",
      "description": "功能描述",
      "body": "請求體格式（POST 時）",
      "returns": "返回值格式",
      "example": "curl 範例"
    }
  ],
  "common_workflows": [
    {
      "name": "工作流程名稱",
      "steps": ["步驟1", "步驟2"]
    }
  ],
  "tile_notation": {
    "數牌": "表示法說明",
    "紅寶牌": "表示法說明",
    "字牌": "表示法說明"
  },
  "tips": ["使用提示"]
}
```

---

## 實現代碼

### 1. 新增路由

在路由 switch 中添加 `/help` 端點（行 142-143）：

```swift
// 路由處理
switch (method, path) {
case ("GET", "/"):
    handleRoot(connection: connection)

case ("GET", "/help"):           // ← 新增
    handleHelp(connection: connection)

case ("GET", "/status"):
    handleStatus(connection: connection)
// ...
}
```

### 2. 實現 handleHelp 方法

在 `handleStatus` 方法後新增（行 274-493）：

```swift
/// AI 友好的 Help 端點
private func handleHelp(connection: NWConnection) {
    let help: [String: Any] = [
        "name": "Naki Debug API",
        "version": "1.0",
        "description": "Naki 麻將 AI 助手的 Debug API，用於監控遊戲狀態、控制 Bot、執行遊戲操作",
        "base_url": "http://localhost:\(port)",
        "endpoints": [
            // 系統類
            [
                "method": "GET",
                "path": "/",
                "description": "首頁，HTML 格式的端點列表（人類可讀）",
                "returns": "HTML"
            ],
            [
                "method": "GET",
                "path": "/help",
                "description": "本端點，JSON 格式的 API 文檔（AI 友好）",
                "returns": "JSON"
            ],
            // ... 更多端點
        ],
        "common_workflows": [
            [
                "name": "監控遊戲狀態",
                "steps": [
                    "GET /bot/status - 檢查 Bot 狀態和手牌",
                    "GET /logs - 查看最近的操作日誌"
                ]
            ],
            // ... 更多工作流程
        ],
        "tile_notation": [
            "數牌": "1-9 + m(萬)/p(筒)/s(索)，如 1m, 5p, 9s",
            "紅寶牌": "5mr, 5pr, 5sr",
            "字牌": "E(東), S(南), W(西), N(北), P(白), F(發), C(中)"
        ],
        "tips": [
            "使用 /help 獲取此文檔",
            "使用 /logs 查看操作歷史",
            "使用 /bot/status 一次性獲取所有狀態",
            "Bot 的推薦按機率排序，第一個通常是最佳選擇"
        ]
    ]
    sendJSON(connection: connection, data: help)
}
```

---

## 完整端點列表

`/help` 返回的端點分為以下幾類：

### 系統類

| 端點 | 方法 | 說明 |
|------|------|------|
| `/` | GET | HTML 首頁（人類可讀） |
| `/help` | GET | JSON API 文檔（AI 友好） |
| `/status` | GET | 伺服器狀態 |
| `/logs` | GET | 獲取 Debug 日誌 |
| `/logs` | DELETE | 清空日誌 |

### Bot 類

| 端點 | 方法 | 說明 |
|------|------|------|
| `/bot/status` | GET | Bot 狀態、手牌、推薦、可用動作 |
| `/bot/trigger` | POST | 手動觸發自動打牌 |
| `/bot/ops` | GET | 探索可用的副露操作 |
| `/bot/deep` | GET | 深度探索 naki API |
| `/bot/chi` | POST | 測試吃操作 |
| `/bot/pon` | POST | 測試碰操作 |

### 遊戲狀態類

| 端點 | 方法 | 說明 |
|------|------|------|
| `/game/state` | GET | 當前遊戲狀態 |
| `/game/hand` | GET | 手牌資訊 |
| `/game/ops` | GET | 當前可用操作 |
| `/game/discard` | POST | 打出指定牌 |
| `/game/action` | POST | 執行遊戲動作 |

### JavaScript 執行

| 端點 | 方法 | 說明 |
|------|------|------|
| `/js` | POST | 執行任意 JavaScript |

### 探索類

| 端點 | 方法 | 說明 |
|------|------|------|
| `/detect` | GET | 檢測遊戲 API |
| `/explore` | GET | 探索遊戲物件 |

### UI 操作類

| 端點 | 方法 | 說明 |
|------|------|------|
| `/test-indicators` | GET | 顯示測試指示器 |
| `/click` | POST | 在指定座標點擊 |
| `/calibrate` | POST | 設定校準參數 |

---

## 驗證結果

### 編譯測試

```bash
xcodebuild -project Naki.xcodeproj -scheme Naki -configuration Debug build
```

**結果**: ✅ Build succeeded

### 功能測試

```bash
# 測試 /help 端點
curl http://localhost:8765/help | jq .
```

預期返回結構化的 JSON 文檔。

### AI 使用範例

#### MCP 工具方式（推薦）

AI 助手可以直接使用 MCP 工具：

```
# 獲取 API 文檔
mcp__naki__get_help

# 獲取 Bot 狀態、手牌、AI 推薦
mcp__naki__bot_status

# 獲取遊戲狀態
mcp__naki__game_state

# 手動觸發自動打牌
mcp__naki__bot_trigger

# 執行 JavaScript
mcp__naki__execute_js({ code: "window.view.DesktopMgr.Inst" })
```

#### HTTP 方式（傳統）

```
1. 首先調用 GET /help 了解 API 結構
2. 根據 endpoints 列表選擇合適的端點
3. 參考 common_workflows 執行常見操作
4. 使用 tile_notation 理解牌的表示法
```

---

## 完整 Diff

```diff
--- a/Naki/Services/Debug/DebugServer.swift
+++ b/Naki/Services/Debug/DebugServer.swift
@@ -137,6 +137,9 @@ class DebugServer {
         switch (method, path) {
         case ("GET", "/"):
             handleRoot(connection: connection)
+
+        case ("GET", "/help"):
+            handleHelp(connection: connection)

         case ("GET", "/status"):
             handleStatus(connection: connection)
@@ -269,6 +272,221 @@ class DebugServer {
         sendJSON(connection: connection, data: status)
     }

+    /// AI 友好的 Help 端點
+    private func handleHelp(connection: NWConnection) {
+        let help: [String: Any] = [
+            "name": "Naki Debug API",
+            "version": "1.0",
+            "description": "Naki 麻將 AI 助手的 Debug API，用於監控遊戲狀態、控制 Bot、執行遊戲操作",
+            "base_url": "http://localhost:\(port)",
+            "endpoints": [
+                // ... 所有端點定義
+            ],
+            "common_workflows": [
+                // ... 工作流程
+            ],
+            "tile_notation": [
+                // ... 牌的表示法
+            ],
+            "tips": [
+                // ... 使用提示
+            ]
+        ]
+        sendJSON(connection: connection, data: help)
+    }
+
     private func handleJavaScript(body: String, connection: NWConnection) {
```

---

## 總結

### 修改前

- 只有 HTML 格式的端點列表（`/`）
- AI 難以解析和理解
- 缺少參數、返回值、使用範例

### 修改後

- 新增 JSON 格式的 API 文檔（`/help`）
- 結構化、易於 AI 解析
- 包含完整的端點資訊、工作流程、牌的表示法

### 使用方式

```bash
# 人類使用（瀏覽器）
open http://localhost:8765/

# AI 使用（MCP 工具 - 推薦）
mcp__naki__get_help

# AI 使用（HTTP 傳統方式）
curl http://localhost:8765/help
```

### 相關文件

| 文件 | 作用 |
|------|-----|
| `Services/Debug/DebugServer.swift` | Debug API 實現（本次修改） |
| `ViewModels/WebViewModel.swift` | WebView 與 Debug Server 的橋接 |
