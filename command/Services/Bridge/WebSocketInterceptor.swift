//
//  WebSocketInterceptor.swift
//  Naki
//
//  Created by Suoie on 2025/11/30.
//  WebSocket 攔截器 - 透過 JavaScript 注入監聽雀魂的 WebSocket 通訊
//  Updated: 2025/12/01 - 新增自動打牌支援
//  Updated: 2025/12/03 - 重構為從外部 JS 檔案載入
//  Updated: 2025/12/04 - 支援 WebPage API (macOS 26.0+)
//

import Foundation
import WebKit
import os.log

// 使用 LogManager 的 wsLog 函式

// MARK: - WebSocket Interceptor

/// WebSocket 攔截器，用於監聽 WebPage 中的 WebSocket 通訊
/// 透過 WKUserScript 注入 JavaScript 程式碼
class WebSocketInterceptor {

    /// JavaScript 模組文件名稱（按載入順序）
    /// 注意：順序很重要，coordinator 必須在其他模組之後載入
    private static let jsModules = [
        "naki-core",
        "naki-autoplay",
        "naki-game-api",
        "naki-websocket",
        "naki-coordinator"  // 統一協調器，整合所有 API
    ]

    /// 從 Bundle 載入 JavaScript 文件
    private static func loadJavaScript(named filename: String) -> String? {
        // 嘗試從 Resources/JavaScript 子目錄載入
        if let url = Bundle.main.url(forResource: filename, withExtension: "js", subdirectory: "Resources/JavaScript") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        // 嘗試直接從 bundle 根目錄載入
        if let url = Bundle.main.url(forResource: filename, withExtension: "js") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        wsLog("[JS] Failed to find \(filename).js in bundle")
        return nil
    }

    /// 注入到網頁的 JavaScript 代碼（從外部文件載入，回退到內嵌腳本）
    static var injectionScript: String {
        var scripts: [String] = []

        for module in jsModules {
            if let script = loadJavaScript(named: module) {
                scripts.append("// === \(module).js ===")
                scripts.append(script)
                wsLog("[JS] Loaded module: \(module).js")
            } else {
                wsLog("[JS] Warning: Could not load \(module).js")
            }
        }

        // 如果成功載入任何模組，使用外部文件
        if !scripts.isEmpty {
            wsLog("[JS] Using external JavaScript modules (\(scripts.count / 2) loaded)")
            return scripts.joined(separator: "\n\n")
        }

        // 回退：使用內嵌腳本
        wsLog("[JS] Warning: No JavaScript modules loaded, using fallback inline script")
        return inlineScript
    }

    /// 內嵌腳本（回退用）- 精簡版，僅包含核心 WebSocket 攔截
    /// 完整功能由外部 JS 模組提供
    private static var inlineScript: String {
        """
        (function() {
            'use strict';

            // 避免重複注入
            if (window.__nakiWebSocketHooked) return;
            window.__nakiWebSocketHooked = true;

            const OriginalWebSocket = window.WebSocket;
            let socketCounter = 0;
            window.__nakiMajsoulSockets = {};

            // Base64 編碼
            function arrayBufferToBase64(buffer) {
                const bytes = new Uint8Array(buffer);
                let binary = '';
                for (let i = 0; i < bytes.byteLength; i++) {
                    binary += String.fromCharCode(bytes[i]);
                }
                return btoa(binary);
            }

            function blobToBase64(blob, callback) {
                const reader = new FileReader();
                reader.onloadend = function() {
                    callback(reader.result.split(',')[1]);
                };
                reader.readAsDataURL(blob);
            }

            // 發送到 Swift
            function sendToSwift(type, data) {
                try {
                    if (window.webkit?.messageHandlers?.websocketBridge) {
                        window.webkit.messageHandlers.websocketBridge.postMessage({
                            type: type, data: data, timestamp: Date.now()
                        });
                    }
                } catch (e) {}
            }

            // WebSocket 攔截
            window.WebSocket = function(url, protocols) {
                const ws = protocols !== undefined
                    ? new OriginalWebSocket(url, protocols)
                    : new OriginalWebSocket(url);

                const socketId = socketCounter++;
                const isMajsoul = url.includes('majsoul') || url.includes('maj-soul') ||
                                  url.includes('mahjongsoul') || url.includes('mjs') ||
                                  url.includes('gateway');

                if (isMajsoul) {
                    console.log('[Naki] Majsoul WebSocket:', url);
                    sendToSwift('websocket_open', { socketId: socketId, url: url });
                    window.__nakiMajsoulSockets[socketId] = ws;

                    ws.addEventListener('open', () => sendToSwift('websocket_connected', { socketId }));
                    ws.addEventListener('close', (e) => {
                        delete window.__nakiMajsoulSockets[socketId];
                        sendToSwift('websocket_closed', { socketId, code: e.code, reason: e.reason });
                    });
                    ws.addEventListener('error', () => sendToSwift('websocket_error', { socketId }));

                    ws.addEventListener('message', function(event) {
                        try {
                            if (event.data instanceof ArrayBuffer) {
                                sendToSwift('websocket_message', {
                                    socketId, direction: 'receive',
                                    data: arrayBufferToBase64(event.data), dataType: 'arraybuffer'
                                });
                            } else if (event.data instanceof Blob) {
                                blobToBase64(event.data, (b64) => {
                                    sendToSwift('websocket_message', {
                                        socketId, direction: 'receive', data: b64, dataType: 'blob'
                                    });
                                });
                            }
                        } catch (e) {}
                    });

                    const originalSend = ws.send.bind(ws);
                    ws.__originalSend = originalSend;
                    ws.send = function(data) {
                        try {
                            if (data instanceof ArrayBuffer) {
                                sendToSwift('websocket_message', {
                                    socketId, direction: 'send',
                                    data: arrayBufferToBase64(data), dataType: 'arraybuffer'
                                });
                            }
                        } catch (e) {}
                        return originalSend(data);
                    };
                }
                return ws;
            };

            window.WebSocket.CONNECTING = OriginalWebSocket.CONNECTING;
            window.WebSocket.OPEN = OriginalWebSocket.OPEN;
            window.WebSocket.CLOSING = OriginalWebSocket.CLOSING;
            window.WebSocket.CLOSED = OriginalWebSocket.CLOSED;
            window.WebSocket.prototype = OriginalWebSocket.prototype;

            console.log('[Naki] WebSocket interceptor installed (fallback mode)');
            sendToSwift('interceptor_ready', { version: '4.0', fallback: true });
        })();
        """
    }

    /// 創建用於注入的 WKUserScript
    static func createUserScript() -> WKUserScript {
        return WKUserScript(
            source: injectionScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }
}

// MARK: - WebSocket Message Handler

/// 處理從 JavaScript 傳來的 WebSocket 消息
class WebSocketMessageHandler: NSObject, WKScriptMessageHandler {

    // MARK: - Properties

    /// 雀魂協議橋接器
    private let majsoulBridge = MajsoulBridge()

    /// MJAI 事件回調
    var onMJAIEvent: (([String: Any]) -> Void)?

    /// WebSocket 狀態回調
    var onWebSocketStatusChanged: ((Bool) -> Void)?

    /// 自動打牌發送結果回調
    var onAutoPlayResult: ((Bool, String?) -> Void)?

    /// 摸牌事件回調 (handCount: 摸牌後手牌數量)
    var onAddHandPai: ((Int) -> Void)?

    /// 連接的 WebSocket 數量
    private var connectedSockets: Set<Int> = []

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {

        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }

        let data = body["data"] as? [String: Any] ?? [:]

        switch type {
        case "interceptor_ready":
            let version = data["version"] as? String ?? "unknown"
            let autoplay = data["autoplay"] as? Bool ?? false
            wsLog("[JS] WebSocket interceptor is ready (v\(version), autoplay=\(autoplay))")

        case "console_log":
            if let message = data["message"] as? String {
                wsLog("[JS] \(message)")
            }

        case "websocket_debug":
            if let url = data["url"] as? String,
               let msg = data["message"] as? String {
                wsLog("[WS] DEBUG: \(msg) - \(url)")
            }

        case "websocket_open":
            handleWebSocketOpen(data)

        case "websocket_connected":
            handleWebSocketConnected(data)

        case "websocket_message":
            handleWebSocketMessage(data)

        case "websocket_close", "websocket_closed":
            handleWebSocketClose(data)

        case "websocket_error":
            handleWebSocketError(data)

        // ⭐ 自動打牌 UI 自動化相關消息
        case "autoplay_click":
            if let x = data["x"] as? Double, let y = data["y"] as? Double {
                wsLog("[AutoPlay] Click at: (\(Int(x)), \(Int(y)))")
            }

        case "autoplay_tile_click":
            if let index = data["index"] as? Int {
                wsLog("[AutoPlay] Tile click: index=\(index)")
            }

        case "autoplay_button_click":
            if let action = data["action"] as? String {
                wsLog("[AutoPlay] Button click: \(action)")
            }

        case "autoplay_error":
            if let error = data["error"] as? String {
                wsLog("[AutoPlay] Error: \(error)")
                onAutoPlayResult?(false, error)
            }

        // 🎯 遊戲事件 Hook
        case "addHandPai":
            // 玩家摸牌事件
            let handCount = data["handCount"] as? Int ?? 0
            wsLog("[Hook] 摸牌事件: handCount=\(handCount)")
            onAddHandPai?(handCount)

        default:
            break
        }
    }

    // MARK: - Message Handlers

    private func handleWebSocketOpen(_ data: [String: Any]) {
        guard let socketId = data["socketId"] as? Int,
              let url = data["url"] as? String else { return }

        wsLog("[WS] WebSocket opening: \(socketId) - \(url)")
    }

    private func handleWebSocketConnected(_ data: [String: Any]) {
        guard let socketId = data["socketId"] as? Int else { return }

        connectedSockets.insert(socketId)
        wsLog("[WS] WebSocket connected: \(socketId)")
        onWebSocketStatusChanged?(true)
    }

    private func handleWebSocketMessage(_ data: [String: Any]) {
        guard let base64Data = data["data"] as? String,
              let direction = data["direction"] as? String else { return }

        // 解碼 Base64 數據
        guard let binaryData = Data(base64Encoded: base64Data) else {
            wsLog("[WS] Failed to decode base64 data")
            return
        }

        // 打印數據大小用於調試
        let dirSymbol = direction == "receive" ? "←" : "→"
        wsLog("[WS] \(dirSymbol) \(binaryData.count) bytes")

        // 處理發送的消息（用於跟蹤請求）
        if direction == "send" {
            // 發送的消息是請求，需要解析以跟蹤 msgId
            if let parsed = majsoulBridge.parseRaw(binaryData),
               let method = parsed["method"] as? String {
                wsLog("[WS] Sent request: \(method)")
            }
            return
        }

        // 處理接收的消息
        guard direction == "receive" else { return }

        // 使用 MajsoulBridge 解析消息
        if let mjaiEvents = majsoulBridge.parse(binaryData) {
            for event in mjaiEvents {
                if let eventType = event["type"] as? String {
                    wsLog("[MJAI] \(eventType): \(formatEvent(event))")
                }
                onMJAIEvent?(event)
            }
        } else {
            // 調試：顯示解析結果
            let parser = LiqiParser()
            if let parsed = parser.parse(binaryData),
               let method = parsed["method"] as? String {
                wsLog("[Liqi] \(method)")

                // 調試 ActionPrototype
                if method == ".lq.ActionPrototype",
                   let data = parsed["data"] as? [String: Any] {
                    if let actionName = data["name"] as? String {
                        wsLog("[Action] \(actionName): \(data)")
                    } else {
                        wsLog("[Action] No name found in data: \(data)")
                    }
                }
            }
        }
    }

    /// 格式化事件用於日誌
    private func formatEvent(_ event: [String: Any]) -> String {
        var parts: [String] = []

        if let actor = event["actor"] as? Int {
            parts.append("actor=\(actor)")
        }
        if let pai = event["pai"] as? String {
            parts.append("pai=\(pai)")
        }
        if let target = event["target"] as? Int {
            parts.append("target=\(target)")
        }
        if let consumed = event["consumed"] as? [String] {
            parts.append("consumed=\(consumed.joined(separator: ","))")
        }
        if let bakaze = event["bakaze"] as? String {
            parts.append("bakaze=\(bakaze)")
        }
        if let kyoku = event["kyoku"] as? Int {
            parts.append("kyoku=\(kyoku)")
        }

        return parts.isEmpty ? "" : "[\(parts.joined(separator: ", "))]"
    }

    private func handleWebSocketClose(_ data: [String: Any]) {
        guard let socketId = data["socketId"] as? Int else { return }

        connectedSockets.remove(socketId)
        wsLog("[WS] WebSocket closed: \(socketId)")

        if connectedSockets.isEmpty {
            onWebSocketStatusChanged?(false)
        }
    }

    private func handleWebSocketError(_ data: [String: Any]) {
        if let socketId = data["socketId"] as? Int {
            wsLog("[WS] WebSocket error: \(socketId)")
        }
    }

    // MARK: - Public Methods

    /// 重置橋接器狀態（開始新遊戲時調用）
    func reset() {
        majsoulBridge.reset()
    }

    /// 完整重置橋接器狀態（頁面重新載入時調用）
    func fullReset() {
        majsoulBridge.fullReset()
        connectedSockets.removeAll()
    }
}
