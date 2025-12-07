/**
 * Bridge Core - 通用 WebView 橋接核心模組
 * 提供 Base64 編碼/解碼、Swift 通訊等核心功能
 * 這是一個通用模組，可用於任何需要 WKWebView 橋接的應用
 */
(function() {
    'use strict';

    // 避免重複注入
    if (window.__bridgeCoreLoaded) {
        return;
    }
    window.__bridgeCoreLoaded = true;

    // ========================================
    // Configuration
    // ========================================

    var config = {
        handlerName: 'websocketBridge',  // 可配置的訊息處理器名稱
        debug: false
    };

    /**
     * 設定配置
     */
    function configure(options) {
        if (options.handlerName) config.handlerName = options.handlerName;
        if (options.debug !== undefined) config.debug = options.debug;
    }

    // ========================================
    // Base64 編碼/解碼
    // ========================================

    /**
     * ArrayBuffer 轉 Base64
     */
    function arrayBufferToBase64(buffer) {
        var bytes = new Uint8Array(buffer);
        var binary = '';
        for (var i = 0; i < bytes.byteLength; i++) {
            binary += String.fromCharCode(bytes[i]);
        }
        return btoa(binary);
    }

    /**
     * Base64 轉 ArrayBuffer
     */
    function base64ToArrayBuffer(base64) {
        var binary = atob(base64);
        var len = binary.length;
        var bytes = new Uint8Array(len);
        for (var i = 0; i < len; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        return bytes.buffer;
    }

    /**
     * Blob 轉 Base64 (異步)
     */
    function blobToBase64(blob, callback) {
        var reader = new FileReader();
        reader.onloadend = function() {
            var base64 = reader.result.split(',')[1];
            callback(base64);
        };
        reader.readAsDataURL(blob);
    }

    // ========================================
    // Swift 通訊
    // ========================================

    /**
     * 發送消息到 Swift (安全版本)
     */
    function sendToSwift(type, data) {
        try {
            if (window.webkit &&
                window.webkit.messageHandlers &&
                window.webkit.messageHandlers[config.handlerName]) {
                window.webkit.messageHandlers[config.handlerName].postMessage({
                    type: type,
                    data: data,
                    timestamp: Date.now()
                });
                return true;
            }
        } catch (e) {
            if (config.debug) {
                console.error('[BridgeCore] sendToSwift error:', e);
            }
        }
        return false;
    }

    /**
     * 發送日誌到 Swift
     */
    function log(message) {
        if (config.debug) {
            console.log('[BridgeCore] ' + message);
        }
        sendToSwift('console_log', { message: message });
    }

    // ========================================
    // WebSocket 攔截 (通用版本)
    // ========================================

    /**
     * 安裝 WebSocket 攔截器
     * @param {Object} options - 配置選項
     * @param {Function} options.shouldIntercept - 判斷是否攔截特定 URL
     * @param {Function} options.onMessage - 訊息回調
     */
    function installWebSocketInterceptor(options) {
        options = options || {};

        if (window.__bridgeWebSocketHooked) {
            return false;
        }
        window.__bridgeWebSocketHooked = true;

        var OriginalWebSocket = window.WebSocket;
        var socketCounter = 0;
        window.__bridgeSockets = {};

        var shouldIntercept = options.shouldIntercept || function() { return true; };

        window.WebSocket = function(url, protocols) {
            var ws = protocols !== undefined
                ? new OriginalWebSocket(url, protocols)
                : new OriginalWebSocket(url);

            var socketId = socketCounter++;

            if (shouldIntercept(url)) {
                log('WebSocket intercepted: ' + url);
                sendToSwift('websocket_open', { socketId: socketId, url: url });
                window.__bridgeSockets[socketId] = ws;

                ws.addEventListener('open', function() {
                    sendToSwift('websocket_connected', { socketId: socketId });
                });

                ws.addEventListener('close', function(e) {
                    delete window.__bridgeSockets[socketId];
                    sendToSwift('websocket_closed', {
                        socketId: socketId,
                        code: e.code,
                        reason: e.reason
                    });
                });

                ws.addEventListener('error', function() {
                    sendToSwift('websocket_error', { socketId: socketId });
                });

                ws.addEventListener('message', function(event) {
                    try {
                        if (event.data instanceof ArrayBuffer) {
                            sendToSwift('websocket_message', {
                                socketId: socketId,
                                direction: 'receive',
                                data: arrayBufferToBase64(event.data),
                                dataType: 'arraybuffer'
                            });
                        } else if (event.data instanceof Blob) {
                            blobToBase64(event.data, function(b64) {
                                sendToSwift('websocket_message', {
                                    socketId: socketId,
                                    direction: 'receive',
                                    data: b64,
                                    dataType: 'blob'
                                });
                            });
                        } else if (typeof event.data === 'string') {
                            sendToSwift('websocket_message', {
                                socketId: socketId,
                                direction: 'receive',
                                data: event.data,
                                dataType: 'text'
                            });
                        }
                    } catch (e) {
                        if (config.debug) {
                            console.error('[BridgeCore] WebSocket message error:', e);
                        }
                    }
                });

                // 攔截 send
                var originalSend = ws.send.bind(ws);
                ws.__originalSend = originalSend;
                ws.send = function(data) {
                    try {
                        if (data instanceof ArrayBuffer) {
                            sendToSwift('websocket_message', {
                                socketId: socketId,
                                direction: 'send',
                                data: arrayBufferToBase64(data),
                                dataType: 'arraybuffer'
                            });
                        } else if (typeof data === 'string') {
                            sendToSwift('websocket_message', {
                                socketId: socketId,
                                direction: 'send',
                                data: data,
                                dataType: 'text'
                            });
                        }
                    } catch (e) {
                        if (config.debug) {
                            console.error('[BridgeCore] WebSocket send error:', e);
                        }
                    }
                    return originalSend(data);
                };
            }

            return ws;
        };

        // 保留原始 WebSocket 的靜態屬性
        window.WebSocket.CONNECTING = OriginalWebSocket.CONNECTING;
        window.WebSocket.OPEN = OriginalWebSocket.OPEN;
        window.WebSocket.CLOSING = OriginalWebSocket.CLOSING;
        window.WebSocket.CLOSED = OriginalWebSocket.CLOSED;
        window.WebSocket.prototype = OriginalWebSocket.prototype;

        log('WebSocket interceptor installed');
        sendToSwift('interceptor_ready', { version: '1.0' });
        return true;
    }

    // ========================================
    // 導出到全域
    // ========================================

    window.__bridgeCore = {
        // 配置
        configure: configure,

        // Base64
        arrayBufferToBase64: arrayBufferToBase64,
        base64ToArrayBuffer: base64ToArrayBuffer,
        blobToBase64: blobToBase64,

        // 通訊
        sendToSwift: sendToSwift,
        log: log,

        // WebSocket
        installWebSocketInterceptor: installWebSocketInterceptor
    };

    console.log('[BridgeCore] Core module loaded');
})();
