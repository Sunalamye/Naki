# WebViewBridge

Swift 實現的通用 WKWebView 雙向通訊框架，提供 JavaScript 注入、訊息處理和 WebSocket 攔截功能。

## 特點

- 🌉 **雙向通訊** - Swift 與 JavaScript 無縫通訊
- 📦 **模組化 JS** - 支援多個 JavaScript 模組註冊和注入
- 🔌 **WebSocket 攔截** - 可選的 WebSocket 訊息攔截
- 🎯 **型別安全** - 完整的 Swift 型別支援
- 🧪 **可測試** - 易於單元測試的設計

## 安裝

### Swift Package Manager

```swift
dependencies: [
    .package(path: "../Packages/WebViewBridge")
]
```

## 快速開始

### 1. 創建 Bridge

```swift
import WebViewBridge
import WebKit

@MainActor
class MyViewController: NSViewController {
    let bridge = WebViewBridge(handlerName: "myBridge")
    var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()

        // 註冊核心模組
        bridge.registerCoreModules()

        // 註冊自定義模組
        let myModule = JavaScriptModule(
            name: "my-module",
            source: """
                window.myApp = {
                    sendMessage: function(msg) {
                        window.__bridgeCore.sendToSwift('custom_message', { message: msg });
                    }
                };
            """
        )
        bridge.registerModule(myModule)

        // 設置訊息回調
        bridge.onMessage = { type, data in
            print("Received: \(type) - \(data)")
        }

        // 配置 WebView
        let config = WKWebViewConfiguration()
        bridge.configure(contentController: config.userContentController)

        webView = WKWebView(frame: .zero, configuration: config)
    }
}
```

### 2. 從 JavaScript 發送訊息

```javascript
// 使用 bridge-core.js 提供的 API
window.__bridgeCore.sendToSwift('my_event', { key: 'value' });

// 或使用自定義 API
window.myApp.sendMessage('Hello from JavaScript!');
```

### 3. 從 Swift 執行 JavaScript

```swift
Task {
    let result = try await bridge.executeJavaScript(
        "document.title",
        in: webView
    )
    print("Page title: \(result ?? "unknown")")
}
```

### 4. 攔截 WebSocket

```javascript
// 在你的 JavaScript 模組中
window.__bridgeCore.installWebSocketInterceptor({
    shouldIntercept: function(url) {
        return url.includes('your-api.com');
    }
});
```

## 架構

```
WebViewBridge/
├── Core/
│   └── WebViewBridge.swift     # 主要橋接類
├── JavaScript/
│   └── bridge-core.js          # 核心 JS 模組
└── WebViewBridge.swift         # 版本資訊
```

## JavaScript API

### bridge-core.js

| 方法 | 說明 |
|------|------|
| `configure(options)` | 設定配置 |
| `arrayBufferToBase64(buffer)` | ArrayBuffer 轉 Base64 |
| `base64ToArrayBuffer(base64)` | Base64 轉 ArrayBuffer |
| `blobToBase64(blob, callback)` | Blob 轉 Base64 |
| `sendToSwift(type, data)` | 發送訊息到 Swift |
| `log(message)` | 發送日誌 |
| `installWebSocketInterceptor(options)` | 安裝 WebSocket 攔截器 |

## Swift API

### WebViewBridge

| 屬性/方法 | 說明 |
|----------|------|
| `handlerName` | 訊息處理器名稱 |
| `delegate` | 代理 |
| `onMessage` | 訊息回調 |
| `registerModule(_:)` | 註冊 JS 模組 |
| `registerCoreModules()` | 註冊內建模組 |
| `configure(contentController:)` | 配置 WKUserContentController |
| `executeJavaScript(_:in:)` | 執行 JavaScript |
| `isWebSocketConnected` | WebSocket 連接狀態 |

### JavaScriptModule

| 屬性 | 說明 |
|-----|------|
| `name` | 模組名稱 |
| `source` | JavaScript 代碼 |
| `injectAtStart` | 是否在文檔開始時注入 |
| `mainFrameOnly` | 是否僅主框架注入 |

## 訊息類型

內建支援的訊息類型：

| 類型 | 方向 | 說明 |
|------|------|------|
| `websocket_open` | JS → Swift | WebSocket 開始連接 |
| `websocket_connected` | JS → Swift | WebSocket 已連接 |
| `websocket_message` | JS → Swift | WebSocket 訊息 |
| `websocket_closed` | JS → Swift | WebSocket 已關閉 |
| `websocket_error` | JS → Swift | WebSocket 錯誤 |
| `console_log` | JS → Swift | 日誌訊息 |
| `interceptor_ready` | JS → Swift | 攔截器已就緒 |

## License

MIT License
