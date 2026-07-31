/**
 * Naki WebSocket - WebSocket 攔截模組
 * 攔截 WebSocket 連接，將訊息轉發到 Swift
 */
(function() {
    'use strict';

    // 避免重複注入
    if (window.__nakiWebSocketLoaded) {
        console.log('[Naki] WebSocket 模組已載入，跳過重複載入');
        return;
    }
    window.__nakiWebSocketLoaded = true;

    // 依賴 naki-core.js
    const sendToSwift = window.__nakiCore?.sendToSwift || window.__nakiSendToSwift || function() {};
    const arrayBufferToBase64 = window.__nakiCore?.arrayBufferToBase64 || window.__nakiArrayBufferToBase64 || function(b) { return ''; };
    const blobToBase64 = window.__nakiCore?.blobToBase64 || window.__nakiBlobToBase64 || function(b, cb) { cb(''); };

    /**
     * Base64 → Uint8Array（不依賴 naki-core，避免載入順序造成的空實作 fallback）
     */
    function base64ToUint8Array(base64) {
        const binary = atob(base64);
        const len = binary.length;
        const bytes = new Uint8Array(len);
        for (let i = 0; i < len; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        return bytes;
    }

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

        console.log('[Naki WS] 新連線:', wsId, url, isMajsoul ? '(雀魂)' : '');

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
            console.log('[Naki WS] 已開啟:', wsId);
            // 發送兩種格式確保兼容
            sendToSwift('websocket_open', { id: wsId, socketId: wsId, url: url });
            sendToSwift('websocket_connected', { socketId: wsId, url: url });
        });

        // 監聽關閉
        ws.addEventListener('close', function(event) {
            console.log('[Naki WS] 已關閉:', wsId, event.code, event.reason);
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
            console.error('[Naki WS] 錯誤:', wsId, event);
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

        // 嘗試安裝表情自動回應監聽器（需要等 NetAgent 準備好）
        if (direction === 'receive' && window.__nakiEmojiAutoReply && !window.__nakiEmojiListenerInstalled) {
            window.__nakiEmojiAutoReply.installListener();
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
            } else if (ArrayBuffer.isView(data)) {
                // TypedArray / DataView：Unity WebGL 送出的封包走這條
                // （Laya 時代送 ArrayBuffer，只判 instanceof ArrayBuffer 會整批漏掉送出面，
                //  連帶讓 LiqiParser 收不到 REQUEST、無法配對 RESPONSE）
                const view = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
                sendToSwift('websocket_message', {
                    socketId: wsId,
                    direction: direction,
                    data: arrayBufferToBase64(view),
                    type: 'binary',
                    size: view.byteLength
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
            console.error('[Naki WS] 處理訊息錯誤:', e);
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

        console.log('[Naki] 主控台攔截已啟用');
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

        console.log('[Naki] 主控台攔截已停用');
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
         * 送出原始二進位封包到適當的雀魂連線
         *
         * 由 Swift 端 LiqiEncoder 產生 Liqi envelope（[type][msgId LE][protobuf]），
         * 以 base64 傳進來後解碼送出。本函式只負責挑連線與送出，不做任何協定加工。
         *
         * ⚠️ 雀魂同時開著大廳 `/gateway` 與對局 `/game-gateway` 兩種連線。
         * 對局方法（`.lq.FastTest.*`）只有 game-gateway 認得，送到大廳會被回
         * `method not found`（error code 6）。舊版寫死取 conns[0]，一旦大廳連線
         * 排在前面，所有打牌都會靜默失敗。
         *
         * @param {string} base64 - 完整 envelope 的 base64
         * @returns {{success: boolean, bytes?: number, socketId?: number, reason?: string}}
         */
        sendRaw: function(base64) {
            if (typeof base64 !== 'string' || base64.length === 0) {
                return { success: false, reason: 'invalid_base64' };
            }
            // 明確驗格式：不同引擎的 atob 寬鬆度不一，先擋掉才不會送出半解碼的垃圾
            if (base64.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(base64)) {
                return { success: false, reason: 'invalid_base64' };
            }

            let bytes;
            try {
                bytes = base64ToUint8Array(base64);
            } catch (e) {
                return { success: false, reason: 'decode_failed: ' + e.message };
            }

            if (bytes.length === 0) {
                return { success: false, reason: 'empty_payload' };
            }

            const conns = window.__nakiWebSocket.getMajsoulConnections();
            if (conns.length === 0) {
                return { success: false, reason: 'no_open_majsoul_connection' };
            }

            // 從 envelope 取出明文方法名（REQUEST 無 XOR：[type][msgId:2][0a][len][method]）
            let method = '';
            try {
                if (bytes[3] === 0x0a) {
                    const nameLen = bytes[4];
                    let s = '';
                    for (let i = 0; i < nameLen; i++) s += String.fromCharCode(bytes[5 + i]);
                    method = s;
                }
            } catch (e) { /* 取不到方法名就退回預設選線 */ }

            const isGameMethod = method.indexOf('.lq.FastTest.') === 0;
            const pick = conns.filter(function (c) {
                const isGameGateway = c.url.indexOf('game-gateway') !== -1;
                return isGameMethod ? isGameGateway : !isGameGateway;
            });

            if (isGameMethod && pick.length === 0) {
                return { success: false, reason: 'no_game_gateway_connection' };
            }

            const conn = pick.length > 0 ? pick[pick.length - 1] : conns[0];
            try {
                conn.ws.send(bytes.buffer);
            } catch (e) {
                console.error('[Naki WS] sendRaw 失敗:', conn.id, e);
                return { success: false, reason: 'send_failed: ' + e.message };
            }

            console.log('[Naki WS] sendRaw:', conn.id, bytes.length, 'bytes');
            return { success: true, bytes: bytes.length, socketId: conn.id };
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
                console.log('[Naki WS] 強制關閉:', info.id, info.url);
                try {
                    ws.close(1000, 'Naki force reconnect');
                    closedCount++;
                } catch (e) {
                    console.error('[Naki WS] 關閉錯誤:', info.id, e);
                }
            }

            console.log('[Naki WS] 強制重連: 已關閉', closedCount, '個連線');
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

    console.log('[Naki] WebSocket 模組已載入');
})();
