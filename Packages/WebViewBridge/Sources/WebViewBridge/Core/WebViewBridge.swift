//
//  WebViewBridge.swift
//  WebViewBridge
//
//  WKWebView 與 Swift 的雙向通訊橋接層
//  提供 JavaScript 注入、訊息處理、模組管理等功能
//

import Foundation
import WebKit

// MARK: - Bridge Delegate

/// WebView 橋接代理協議
public protocol WebViewBridgeDelegate: AnyObject {
    /// 收到 JavaScript 訊息
    func bridge(_ bridge: WebViewBridge, didReceiveMessage type: String, data: [String: Any])

    /// WebSocket 狀態變更（可選）
    func bridge(_ bridge: WebViewBridge, webSocketStatusChanged connected: Bool)

    /// 錯誤發生（可選）
    func bridge(_ bridge: WebViewBridge, didEncounterError error: Error)
}

// 提供可選方法的預設實現
public extension WebViewBridgeDelegate {
    func bridge(_ bridge: WebViewBridge, webSocketStatusChanged connected: Bool) {}
    func bridge(_ bridge: WebViewBridge, didEncounterError error: Error) {}
}

// MARK: - JavaScript Module

/// JavaScript 模組定義
public struct JavaScriptModule: Sendable {
    /// 模組名稱
    public let name: String

    /// 模組代碼
    public let source: String

    /// 是否在文檔開始時注入
    public let injectAtStart: Bool

    /// 是否僅在主框架注入
    public let mainFrameOnly: Bool

    public init(name: String, source: String, injectAtStart: Bool = true, mainFrameOnly: Bool = false) {
        self.name = name
        self.source = source
        self.injectAtStart = injectAtStart
        self.mainFrameOnly = mainFrameOnly
    }

    /// 從 Bundle 載入模組
    public static func fromBundle(named filename: String, bundle: Bundle = .main, subdirectory: String? = nil) -> JavaScriptModule? {
        var url: URL?

        if let subdirectory = subdirectory {
            url = bundle.url(forResource: filename, withExtension: "js", subdirectory: subdirectory)
        }

        if url == nil {
            url = bundle.url(forResource: filename, withExtension: "js")
        }

        guard let fileURL = url,
              let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        return JavaScriptModule(name: filename, source: source)
    }
}

// MARK: - WebView Bridge

/// WKWebView 雙向通訊橋接器
@MainActor
public final class WebViewBridge: NSObject {

    // MARK: - Properties

    /// 訊息處理器名稱（JavaScript 中使用 webkit.messageHandlers[name]）
    public let handlerName: String

    /// 已註冊的 JavaScript 模組
    private var modules: [JavaScriptModule] = []

    /// 代理
    public weak var delegate: WebViewBridgeDelegate?

    /// 訊息處理回調（替代 delegate 的輕量方案）
    public var onMessage: ((_ type: String, _ data: [String: Any]) -> Void)?

    /// 日誌回調
    public var onLog: ((String) -> Void)?

    /// 連接的 WebSocket 數量
    private var connectedSockets: Set<Int> = []

    // MARK: - Initialization

    public init(handlerName: String = "websocketBridge") {
        self.handlerName = handlerName
        super.init()
    }

    // MARK: - Module Management

    /// 註冊 JavaScript 模組
    public func registerModule(_ module: JavaScriptModule) {
        modules.append(module)
        log("Registered module: \(module.name)")
    }

    /// 批量註冊模組
    public func registerModules(_ modules: [JavaScriptModule]) {
        for module in modules {
            registerModule(module)
        }
    }

    /// 註冊內建的核心模組
    public func registerCoreModules() {
        // 載入內建的 bridge-core.js
        if let coreModule = loadBundledModule(named: "bridge-core") {
            registerModule(coreModule)
        }
    }

    /// 從 Package Bundle 載入模組
    private func loadBundledModule(named name: String) -> JavaScriptModule? {
        // 嘗試從 Package 的 resource bundle 載入
        let bundle = Bundle.module

        // 嘗試 JavaScript 子目錄
        if let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "JavaScript") {
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                return JavaScriptModule(name: name, source: source)
            }
        }

        // 嘗試根目錄
        if let url = bundle.url(forResource: name, withExtension: "js") {
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                return JavaScriptModule(name: name, source: source)
            }
        }

        log("Warning: Could not load bundled module: \(name)")
        return nil
    }

    // MARK: - WebView Configuration

    /// 配置 WKWebView 的 UserContentController
    public func configure(contentController: WKUserContentController) {
        // 添加訊息處理器
        contentController.add(self, name: handlerName)

        // 注入所有已註冊的模組
        for module in modules {
            let script = WKUserScript(
                source: wrapModule(module),
                injectionTime: module.injectAtStart ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: module.mainFrameOnly
            )
            contentController.addUserScript(script)
            log("Injected module: \(module.name)")
        }
    }

    /// 生成完整的注入腳本
    public func generateInjectionScript() -> String {
        var scripts: [String] = []

        for module in modules {
            scripts.append("// === \(module.name) ===")
            scripts.append(wrapModule(module))
        }

        return scripts.joined(separator: "\n\n")
    }

    /// 包裝模組代碼（添加錯誤處理）
    private func wrapModule(_ module: JavaScriptModule) -> String {
        return """
        try {
            \(module.source)
        } catch (e) {
            console.error('[WebViewBridge] Error in module \(module.name):', e);
        }
        """
    }

    // MARK: - JavaScript Execution

    /// 在 WebView 中執行 JavaScript
    public func executeJavaScript(_ script: String, in webView: WKWebView) async throws -> Any? {
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    // MARK: - State

    /// WebSocket 是否已連接
    public var isWebSocketConnected: Bool {
        !connectedSockets.isEmpty
    }

    /// 重置狀態
    public func reset() {
        connectedSockets.removeAll()
    }

    // MARK: - Logging

    private func log(_ message: String) {
        print("[WebViewBridge] \(message)")
        onLog?(message)
    }
}

// MARK: - WKScriptMessageHandler

extension WebViewBridge: WKScriptMessageHandler {
    nonisolated public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }

            let data = body["data"] as? [String: Any] ?? [:]

            // 處理內建訊息類型
            switch type {
            case "websocket_connected":
                if let socketId = data["socketId"] as? Int {
                    connectedSockets.insert(socketId)
                    delegate?.bridge(self, webSocketStatusChanged: true)
                }

            case "websocket_closed", "websocket_close":
                if let socketId = data["socketId"] as? Int {
                    connectedSockets.remove(socketId)
                    if connectedSockets.isEmpty {
                        delegate?.bridge(self, webSocketStatusChanged: false)
                    }
                }

            case "console_log":
                if let message = data["message"] as? String {
                    log("[JS] \(message)")
                }

            default:
                break
            }

            // 通知代理或回調
            delegate?.bridge(self, didReceiveMessage: type, data: data)
            onMessage?(type, data)
        }
    }
}
