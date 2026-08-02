/**
 * Naki WebSocket - WebSocket 攔截模組
 * 攔截 WebSocket 連接，將訊息轉發到 Swift
 *
 * ⚠️ 協定知識的 canonical 在 Swift，不在這裡（p4-2）：
 *   - envelope 格式（[type][msgId LE][protobuf{1=method,2=payload}]）
 *     → command/Services/Bridge/LiqiEnvelope.swift
 *   - msgId → method 對照表 → LiqiParser.pendingRequests
 *
 * 本檔的 `parseEnvelopeBody` / `attributeSend` / `sendRaw` / `nakiNicknameMask.pendingMethods`
 * 各自留著一份**刻意的**重複：它們必須在遊戲解析封包之前、在頁面裡同步跑完
 * （改暱稱 bytes、選連線），繞去 Swift 再回來就來不及了。跨語言邊界的同步成本
 * 高於重複成本，所以保留——但格式一改，改的是 Swift 那份，這裡跟著對齊。
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

        // 通知 Swift 新連接（此刻還沒 open；沒有後續 websocket_connected 就是握手失敗）
        sendToSwift('websocket_connect', {
            socketId: wsId,
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
            // 同一個 open 事件以前送兩份（`websocket_open` + `websocket_connected`），
            // 名義上是「兩種格式確保兼容」，實際上 Swift 兩個 case 都在、其中一個只是
            // 多印一行 log。留一份就好。
            sendToSwift('websocket_connected', { socketId: wsId, url: url });
        });

        // 監聽關閉
        ws.addEventListener('close', function(event) {
            console.log('[Naki WS] 已關閉:', wsId, event.code, event.reason);
            sendToSwift('websocket_close', {
                socketId: wsId,
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


    // ============================================================
    // 隱藏玩家名稱：協定層等長改寫
    // ============================================================
    //
    // 舊實作靠 `uiscript.UI_DesktopInfo`，在 Unity WebGL 客戶端根本不存在，
    // 所以那條路沒救。名字要消失，只能在**遊戲自己解析封包之前**動手。
    //
    // 做法：本檔的 'message' listener 在 WebSocket 建構當下就註冊，一定排在遊戲
    // 自己的 handler 前面，而 event.data 的 ArrayBuffer 是同一份記憶體——就地改
    // bytes，遊戲後面讀到的就是改過的內容。
    //
    // 關鍵約束是**長度必須完全一樣**。protobuf 的 string 前面有一個 varint 長度，
    // 改長度就得改前綴、改前綴又會連動外層所有 nested message 的長度，一路錯到底。
    // 等長覆寫則完全不碰結構，最壞情況只是名字變成怪字串，不會讓遊戲解析爆掉。
    //
    // 範圍刻意收窄：只處理 `.lq.FastTest.authGame` 的 RESPONSE（ResAuthGame 的
    // players / robots）。那是名牌的來源。斷線重連走 syncGame、終局結算走
    // NotifyGameEndResult，兩者目前不處理——寧可漏掉幾個畫面，也不要為了覆蓋率
    // 去改一堆沒實測過的訊息。
    //
    // 任何解析中途遇到看不懂的東西一律 return，維持 bytes 原狀（fail-open 成
    // 「名字照常顯示」，而不是 fail 成壞封包）。
    /// 依「遊戲自己在哪條線上做過同類事情」挑連線。
    ///
    /// 證據強度：**一般 lobby RPC > 登入**。這個順序是實測定的，跟直覺相反：
    /// 客戶端會在多條線上嘗試登入，但只有真正活著的那條會持續跑
    /// fetchCurrentMatchInfo 之類的 RPC。照「登入時間較晚」挑會選到
    /// 已經被放棄的那條（2026-08-01 實測：socket 2 登入較晚但 lobby RPC 是 0，
    /// 送過去一律 error 1004）。
    /// 心跳完全不算證據（見 attributeSend）。
    function candidatesProvenFor(list, isGameMethod) {
        const tiers = isGameMethod
            ? [function (c) { return c.lastGameSendAt || 0; }]
            : [function (c) { return c.lastLobbySendAt || 0; },
               function (c) { return c.lastLoginAt || 0; }];
        for (const score of tiers) {
            let best = null;
            (list || []).forEach(function (c) {
                const t = score(c);
                if (t > 0 && (!best || t > best.t)) best = { t: t, c: c };
            });
            if (best) return best.c;
        }
        return null;
    }

    const nakiNicknameMask = (function() {
        let enabled = false;
        let maskedCount = 0;
        const pendingMethods = new Map();   // msgId -> method name

        const TYPE_REQUEST = 2;
        const TYPE_RESPONSE = 3;
        const AUTH_GAME = '.lq.FastTest.authGame';

        // 回傳 [value, nextOffset]，讀不完整回 null。
        // 用乘法而非 <<：JS 位移是 32-bit，長 varint 會靜默算錯。
        function readVarint(b, i, end) {
            let result = 0;
            let shift = 1;
            while (i < end) {
                const byte = b[i++];
                result += (byte & 0x7f) * shift;
                if ((byte & 0x80) === 0) return [result, i];
                shift *= 128;
                if (shift > 1e15) return null;
            }
            return null;
        }

        // 找出 wrapper `{1: method, 2: payload}` 的兩個欄位。
        function parseEnvelopeBody(b, start) {
            let i = start;
            let method = null;
            let payload = null;
            while (i < b.length) {
                const tag = readVarint(b, i, b.length);
                if (!tag) return null;
                const field = Math.floor(tag[0] / 8);
                const wire = tag[0] & 7;
                i = tag[1];
                if (wire === 2) {
                    const len = readVarint(b, i, b.length);
                    if (!len) return null;
                    const from = len[1];
                    const to = from + len[0];
                    if (to > b.length) return null;
                    if (field === 1) method = decodeAscii(b, from, to);
                    else if (field === 2) payload = [from, to];
                    i = to;
                } else if (wire === 0) {
                    const v = readVarint(b, i, b.length);
                    if (!v) return null;
                    i = v[1];
                } else if (wire === 5) i += 4;
                else if (wire === 1) i += 8;
                else return null;
            }
            return { method: method, payload: payload };
        }

        function decodeAscii(b, from, to) {
            let out = '';
            for (let k = from; k < to; k++) {
                if (b[k] > 127) return null;   // method name 一定是 ASCII
                out += String.fromCharCode(b[k]);
            }
            return out;
        }

        // 把 [from,to) 當成 PlayerGameView，改寫 field 4 (nickname)。
        function maskPlayerGameView(b, from, to, seat) {
            let i = from;
            while (i < to) {
                const tag = readVarint(b, i, to);
                if (!tag) return;
                const field = Math.floor(tag[0] / 8);
                const wire = tag[0] & 7;
                i = tag[1];
                if (wire === 2) {
                    const len = readVarint(b, i, to);
                    if (!len) return;
                    const s = len[1];
                    const e = s + len[0];
                    if (e > to) return;
                    if (field === 4 && len[0] > 0) {
                        writeLabel(b, s, e, seat);
                        maskedCount++;
                    }
                    i = e;
                } else if (wire === 0) {
                    const v = readVarint(b, i, to);
                    if (!v) return;
                    i = v[1];
                } else if (wire === 5) i += 4;
                else if (wire === 1) i += 8;
                else return;
            }
        }

        // 等長覆寫，長度不足就換更短的標籤——截斷 'Player 1' 會得到 "Pl" 這種
        // 看起來像壞掉的字串，不如直接降級成 "P1"。全 ASCII，所以一定是合法
        // UTF-8，不會讓遊戲的字串解碼失敗。
        function writeLabel(b, from, to, seat) {
            const size = to - from;
            let label = 'Player ' + seat;
            if (size < label.length) label = 'P' + seat;
            if (size < label.length) label = String(seat);
            for (let k = from; k < to; k++) {
                b[k] = (k - from < label.length) ? label.charCodeAt(k - from) : 0x20;
            }
        }

        function maskAuthGame(b, from, to) {
            let i = from;
            let seat = 1;
            while (i < to) {
                const tag = readVarint(b, i, to);
                if (!tag) return;
                const field = Math.floor(tag[0] / 8);
                const wire = tag[0] & 7;
                i = tag[1];
                if (wire === 2) {
                    const len = readVarint(b, i, to);
                    if (!len) return;
                    const s = len[1];
                    const e = s + len[0];
                    if (e > to) return;
                    // field 2 = players[], field 7 = robots[]
                    if (field === 2 || field === 7) maskPlayerGameView(b, s, e, seat++);
                    i = e;
                } else if (wire === 0) {
                    const v = readVarint(b, i, to);
                    if (!v) return;
                    i = v[1];
                } else if (wire === 5) i += 4;
                else if (wire === 1) i += 8;
                else return;
            }
        }

        function observe(bytes, direction) {
            // send 面即使關閉也要記 msgId→method：開關可能在對局中途才打開，
            // 沒有這份對照表就認不出後面的 RESPONSE 是哪一個方法。
            if (!bytes || bytes.length < 4) return;
            const type = bytes[0];
            const msgId = bytes[1] | (bytes[2] << 8);

            if (direction === 'send' && type === TYPE_REQUEST) {
                const env = parseEnvelopeBody(bytes, 3);
                if (env && env.method) {
                    pendingMethods.set(msgId, env.method);
                    if (pendingMethods.size > 256) {
                        pendingMethods.delete(pendingMethods.keys().next().value);
                    }
                }
                return;
            }

            if (direction !== 'receive' || type !== TYPE_RESPONSE) return;
            const method = pendingMethods.get(msgId);
            if (method) pendingMethods.delete(msgId);
            if (!enabled || method !== AUTH_GAME) return;

            const env = parseEnvelopeBody(bytes, 3);
            if (!env || !env.payload) return;
            maskAuthGame(bytes, env.payload[0], env.payload[1]);
        }

        return {
            observe: observe,
            setEnabled: function(v) {
                enabled = !!v;
                console.log('[Naki WS] 隱藏玩家名稱:', enabled);
                return enabled;
            },
            getStatus: function() {
                return {
                    available: true,
                    enabled: enabled,
                    maskedFields: maskedCount,
                    scope: 'authGame-response-only',
                    note: '只在下一局 authGame 生效；重連 syncGame 與終局結算不在範圍內'
                };
            }
        };
    })();

    window.__nakiHideNames = nakiNicknameMask;


    /// 從送出的 REQUEST 認出方法名，記錄這條線是 lobby 線還是對局線
    function attributeSend(info, data) {
        try {
            const b = data instanceof ArrayBuffer ? new Uint8Array(data)
                    : (ArrayBuffer.isView(data)
                       ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : null);
            if (!b || b.length < 6 || b[0] !== 2 || b[3] !== 0x0a) return;
            const msgId = b[1] | (b[2] << 8);
            if (msgId >= 60000) return;   // Naki 自己送的，不能當證據
            const len = b[4];
            let m = '';
            for (let i = 0; i < len; i++) m += String.fromCharCode(b[5 + i]);
            if (m.indexOf('.lq.FastTest.') === 0) { info.lastGameSendAt = Date.now(); return; }
            if (m.indexOf('.lq.Lobby.') !== 0) return;

            // 心跳要排除：`.lq.Lobby.heatbeat` / `loginBeat` 兩條線都會送，
            // 拿它當證據等於沒判（實測兩條 socket 的時間戳幾乎同時，選錯照樣 1004）。
            if (m.indexOf('eatbeat') !== -1 || m.indexOf('loginBeat') !== -1) return;

            // 登入類是最強證據：session 就是在那條線上建立的。
            if (m.indexOf('ogin') !== -1 || m.indexOf('uth') !== -1) info.lastLoginAt = Date.now();
            else info.lastLobbySendAt = Date.now();
        } catch (e) { /* 認不出就不記，維持原本的選線邏輯 */ }
    }

    /**
     * 處理 WebSocket 訊息
     */
    function handleMessage(ws, wsId, data, direction, isMajsoul) {
        // 只處理雀魂連接的訊息
        if (!isMajsoul) return;

        // 記錄選線要用的資訊。
        //
        // 「最近收到過訊息」不夠用：雀魂同時開兩條 /gateway，兩條都會收心跳，
        // 時間戳常常完全相同，平手就退回順序——等於沒判。
        //
        // 真正有鑑別力的是「**遊戲自己**在哪條線上送 lobby 請求」：那條必然是
        // 完成 oauth2Login 的那條。Naki 自己送的不算（msgId 從 60000 起跳），
        // 否則會把自己送錯的那次記成正確答案，錯誤自我強化。
        const info = wsConnections.get(ws);
        if (info) {
            if (direction === 'receive') info.lastRecvAt = Date.now();
            else if (direction === 'send') attributeSend(info, data);
        }

        try {
            if (data instanceof ArrayBuffer) {
                nakiNicknameMask.observe(new Uint8Array(data), direction);
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
                nakiNicknameMask.observe(view, direction);
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
                        lastRecvAt: info.lastRecvAt || 0,
                        lastLobbySendAt: info.lastLobbySendAt || 0,
                        lastLoginAt: info.lastLoginAt || 0,
                        lastGameSendAt: info.lastGameSendAt || 0,
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

            // 優先選「遊戲自己在上面送過同類請求」的那條——那是登入完成的證據。
            // 退而求其次才看「最近收到過訊息」，最後才是建立順序。
            const proven = candidatesProvenFor(pick.length > 0 ? pick : conns, isGameMethod);
            if (proven) {
                try { proven.ws.send(bytes.buffer); } catch (e) {
                    return { success: false, reason: 'send_failed: ' + e.message };
                }
                return { success: true, bytes: bytes.length, socketId: proven.id, pickedBy: 'proven' };
            }

            // 選「最近收到過伺服器訊息」的那條，而不是最後建立的那條。
            //
            // 雀魂可能同時開著兩條 /gateway，但登入握手只在其中一條上做過；
            // 送到另一條伺服器會回 error 1004（連唯讀的 fetchAccountInfo 也一樣）。
            // 原本的 `pick[pick.length - 1]` 是照建立順序取最後一條，在這種情況下
            // 剛好選中沒登入的那條，於是匹配一直卡住而且沒有任何 log 說為什麼。
            //
            // 「最近收到過東西」是有事實根據的訊號：伺服器只會在活著的 session 上
            // 推訊息。平手時才退回原本的順序。
            const candidates = pick.length > 0 ? pick : conns;
            const conn = candidates.slice().sort(function (a, b) {
                return (b.lastRecvAt || 0) - (a.lastRecvAt || 0);
            })[0];
            try {
                conn.ws.send(bytes.buffer);
            } catch (e) {
                console.error('[Naki WS] sendRaw 失敗:', conn.id, e);
                return { success: false, reason: 'send_failed: ' + e.message };
            }

            console.log('[Naki WS] sendRaw:', conn.id, bytes.length, 'bytes');
            return { success: true, bytes: bytes.length, socketId: conn.id, pickedBy: 'recency',
                     candidates: candidates.map(function (c) { return c.id; }) };
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
