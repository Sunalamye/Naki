/**
 * Naki WebSocket - WebSocket 攔截模組
 * 攔截 WebSocket 連接，將訊息轉發到 Swift
 */
(function() {
    'use strict';

    // 避免重複注入
    if (window.__nakiWebSocketLoaded) {
        console.log('[Naki] WebSocket module already loaded');
        return;
    }
    window.__nakiWebSocketLoaded = true;

    // 依賴 naki-core.js
    const sendToSwift = window.__nakiCore?.sendToSwift || window.__nakiSendToSwift || function() {};
    const arrayBufferToBase64 = window.__nakiCore?.arrayBufferToBase64 || window.__nakiArrayBufferToBase64 || function(b) { return ''; };
    const blobToBase64 = window.__nakiCore?.blobToBase64 || window.__nakiBlobToBase64 || function(b, cb) { cb(''); };

    // ========================================
    // WebSocket 攔截
    // ========================================

    // 保存原始 WebSocket 構造函數
    const OriginalWebSocket = window.WebSocket;

    // 追蹤所有 WebSocket 連接
    const wsConnections = new Map();
    let wsIdCounter = 0;

    /**
     * 檢測是否為雀魂 WebSocket
     */
    function isMajsoulWebSocket(url) {
        return url && (
            url.includes('majsoul') ||
            url.includes('mj-') ||
            url.includes('game.') ||
            url.includes('gateway') ||
            url.includes('match')
        );
    }

    /**
     * 包裝 WebSocket 構造函數
     */
    window.WebSocket = function(url, protocols) {
        const ws = protocols
            ? new OriginalWebSocket(url, protocols)
            : new OriginalWebSocket(url);

        const wsId = ++wsIdCounter;
        const isMajsoul = isMajsoulWebSocket(url);

        console.log('[Naki WS] New connection:', wsId, url, isMajsoul ? '(Majsoul)' : '');

        // 記錄連接信息
        wsConnections.set(ws, {
            id: wsId,
            url: url,
            isMajsoul: isMajsoul,
            created: Date.now()
        });

        // 通知 Swift 新連接
        sendToSwift('websocket_connect', {
            id: wsId,
            url: url,
            isMajsoul: isMajsoul
        });

        // 監聽訊息
        ws.addEventListener('message', function(event) {
            handleMessage(ws, wsId, event.data, 'receive', isMajsoul);
        });

        // 監聽打開
        ws.addEventListener('open', function() {
            console.log('[Naki WS] Opened:', wsId);
            // 發送兩種格式確保兼容
            sendToSwift('websocket_open', { id: wsId, socketId: wsId, url: url });
            sendToSwift('websocket_connected', { socketId: wsId, url: url });
        });

        // 監聽關閉
        ws.addEventListener('close', function(event) {
            console.log('[Naki WS] Closed:', wsId, event.code, event.reason);
            sendToSwift('websocket_close', {
                socketId: wsId,
                id: wsId,
                code: event.code,
                reason: event.reason
            });
            wsConnections.delete(ws);
        });

        // 監聽錯誤
        ws.addEventListener('error', function(event) {
            console.error('[Naki WS] Error:', wsId, event);
            sendToSwift('websocket_error', {
                socketId: wsId,
                id: wsId,
                error: 'WebSocket error'
            });
        });

        // 攔截 send 方法
        const originalSend = ws.send.bind(ws);
        ws.send = function(data) {
            handleMessage(ws, wsId, data, 'send', isMajsoul);
            return originalSend(data);
        };

        return ws;
    };

    // 繼承靜態屬性
    window.WebSocket.prototype = OriginalWebSocket.prototype;
    window.WebSocket.CONNECTING = OriginalWebSocket.CONNECTING;
    window.WebSocket.OPEN = OriginalWebSocket.OPEN;
    window.WebSocket.CLOSING = OriginalWebSocket.CLOSING;
    window.WebSocket.CLOSED = OriginalWebSocket.CLOSED;

    /**
     * 處理 WebSocket 訊息
     */
    function handleMessage(ws, wsId, data, direction, isMajsoul) {
        // 只處理雀魂連接的訊息
        if (!isMajsoul) return;

        // 收到伺服器訊息時，刷新心跳防止閒置登出
        if (direction === 'receive' && window.__nakiAntiIdle && window.__nakiAntiIdle.isEnabled()) {
            window.__nakiAntiIdle.refresh();
        }

        try {
            if (data instanceof ArrayBuffer) {
                // ArrayBuffer：轉成 Base64
                const base64 = arrayBufferToBase64(data);
                sendToSwift('websocket_message', {
                    socketId: wsId,
                    direction: direction,
                    data: base64,
                    type: 'binary',
                    size: data.byteLength
                });
            } else if (data instanceof Blob) {
                // Blob：異步轉成 Base64
                blobToBase64(data, function(base64) {
                    sendToSwift('websocket_message', {
                        socketId: wsId,
                        direction: direction,
                        data: base64,
                        type: 'blob',
                        size: data.size
                    });
                });
            } else if (typeof data === 'string') {
                // 字串：直接發送（限制長度避免過大）
                const truncated = data.length > 10000 ? data.substring(0, 10000) + '...' : data;
                sendToSwift('websocket_message', {
                    socketId: wsId,
                    direction: direction,
                    data: truncated,
                    type: 'text',
                    size: data.length
                });
            }
        } catch (e) {
            console.error('[Naki WS] handleMessage error:', e);
        }
    }

    // ========================================
    // Console 攔截（調試用）
    // ========================================

    // 保存原始 console
    const originalConsole = {
        log: console.log.bind(console),
        warn: console.warn.bind(console),
        error: console.error.bind(console)
    };

    // 是否啟用 console 攔截
    let consoleInterceptEnabled = false;

    /**
     * 攔截 console 輸出
     */
    function interceptConsole() {
        if (consoleInterceptEnabled) return;
        consoleInterceptEnabled = true;

        console.log = function(...args) {
            originalConsole.log.apply(console, args);
            sendToSwift('console_log', { level: 'log', args: formatArgs(args) });
        };

        console.warn = function(...args) {
            originalConsole.warn.apply(console, args);
            sendToSwift('console_log', { level: 'warn', args: formatArgs(args) });
        };

        console.error = function(...args) {
            originalConsole.error.apply(console, args);
            sendToSwift('console_log', { level: 'error', args: formatArgs(args) });
        };

        console.log('[Naki] Console interception enabled');
    }

    /**
     * 格式化 console 參數
     */
    function formatArgs(args) {
        return args.map(arg => {
            if (arg === null) return 'null';
            if (arg === undefined) return 'undefined';
            if (typeof arg === 'object') {
                try {
                    return JSON.stringify(arg).substring(0, 1000);
                } catch (e) {
                    return '[Object]';
                }
            }
            return String(arg).substring(0, 1000);
        }).join(' ');
    }

    /**
     * 恢復原始 console
     */
    function restoreConsole() {
        if (!consoleInterceptEnabled) return;
        consoleInterceptEnabled = false;

        console.log = originalConsole.log;
        console.warn = originalConsole.warn;
        console.error = originalConsole.error;

        console.log('[Naki] Console interception disabled');
    }

    // ========================================
    // 導出到全域
    // ========================================

    window.__nakiWebSocket = {
        // 獲取連接信息
        getConnections: function() {
            const result = [];
            wsConnections.forEach((info, ws) => {
                result.push({
                    id: info.id,
                    url: info.url,
                    isMajsoul: info.isMajsoul,
                    readyState: ws.readyState,
                    age: Date.now() - info.created
                });
            });
            return result;
        },

        // 獲取雀魂連接
        getMajsoulConnections: function() {
            const result = [];
            wsConnections.forEach((info, ws) => {
                if (info.isMajsoul && ws.readyState === WebSocket.OPEN) {
                    result.push({
                        id: info.id,
                        url: info.url,
                        ws: ws
                    });
                }
            });
            return result;
        },

        /**
         * 強制關閉所有雀魂 WebSocket 連接
         * 這會觸發遊戲重連，伺服器會發送 syncGame 恢復遊戲狀態
         * @returns {number} 關閉的連接數
         */
        forceReconnect: function() {
            let closedCount = 0;
            const toClose = [];

            // 先收集要關閉的連接，避免在遍歷時修改 Map
            wsConnections.forEach((info, ws) => {
                if (info.isMajsoul && ws.readyState === WebSocket.OPEN) {
                    toClose.push({ ws, info });
                }
            });

            // 關閉連接
            for (const { ws, info } of toClose) {
                console.log('[Naki WS] Force closing:', info.id, info.url);
                try {
                    ws.close(1000, 'Naki force reconnect');
                    closedCount++;
                } catch (e) {
                    console.error('[Naki WS] Error closing:', info.id, e);
                }
            }

            console.log('[Naki WS] Force reconnect: closed', closedCount, 'connections');
            sendToSwift('force_reconnect', { closedCount: closedCount });
            return closedCount;
        },

        // Console 控制
        interceptConsole: interceptConsole,
        restoreConsole: restoreConsole,
        isConsoleIntercepted: function() {
            return consoleInterceptEnabled;
        },

        // 原始 WebSocket（供需要時使用）
        OriginalWebSocket: OriginalWebSocket
    };

    // 向後兼容
    window.__nakiOriginalWebSocket = OriginalWebSocket;
    window.__nakiGetWsConnections = function() {
        return window.__nakiWebSocket.getConnections();
    };

    console.log('[Naki] WebSocket module loaded');
})();
