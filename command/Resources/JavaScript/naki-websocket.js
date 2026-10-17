/**
 * Naki WebSocket - WebSocket 攔截模組
 * 攔截 WebSocket 連接，將訊息轉發到 Swift
 *
 * ⚠️ 協定知識的 canonical 在 Swift，不在這裡（p4-2）：
 *   - envelope 格式（[type][msgId LE][protobuf{1=method,2=payload}]）
 *     → command/Services/Bridge/LiqiEnvelope.swift
 *   - msgId → method 對照表 → LiqiParser.pendingRequests
 *
 * 本檔的 envelope 解析（naki-core 的 `parseEnvelope`／`readVarint`）、`attributeSend`、
 * `sendRaw`、`nakiNicknameMask.pendingMethods` 是**刻意的**重複：它們必須在遊戲解析封包之前、
 * 在頁面裡同步跑完（改暱稱 bytes、選連線），繞去 Swift 再回來就來不及了。跨語言邊界的
 * 同步成本高於重複成本，所以保留——但格式一改，改的是 Swift 那份，這裡跟著對齊。
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
    // core 跑完但沒匯出這兩個函式時 fail-open：遮名停擺、插件不派發（naki-plugins 共用同一份 parseEnvelope），
    // 封包照常轉給 Swift。core 整個缺席時 sendToSwift 也退成空函式（既有行為），Swift 就收不到封包。
    const readVarint = window.__nakiCore?.readVarint || function() { return null; };
    const parseEnvelope = window.__nakiCore?.parseEnvelope || function() { return null; };

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

    // socketId 要跨 frame 唯一。
    //
    // 注入是 `forMainFrameOnly: false`，每個 frame 都跑一次這份 IIFE，而
    // `wsIdCounter` 是各自的區域變數、`__nakiWebSocketLoaded` 的去重也是 per-frame。
    // 兩個 frame 各開一條就都叫 socket 1，但 Swift 側的 `connectedSockets` 是**共用**
    // 的一個 Set——iframe 那條關閉時會把主 frame 的同號連線一起移除。
    //
    // 給每個 frame 一個隨機的號段起點就避開了。不用 crypto：這只是要避免碰撞，
    // 不是安全用途；乘 1e6 讓每個 frame 有一百萬個號可用，實務上不可能撞。
    let wsIdCounter = Math.floor(Math.random() * 1e6) * 1e6;

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

        // 監聽訊息。capture：WebKit 在 target 上先跑 capture listener（live probe (d)），建構當下註冊又排在所有 capture 之首，
        // 遊戲日後不論怎麼註冊都在 Naki 之後（Phase 4 攔原事件的前提）。合成事件（本地回應、變長改寫）的 Swift 那份已顯式送過
        ws.addEventListener('message', function(event) {
            if (syntheticEvents.has(event)) return;
            handleMessage(ws, wsId, event.data, 'receive', isMajsoul, event);
        }, true);
        // 哨兵：排在所有非 capture 之首。看到已攔下的原事件 ⇒ stopImmediatePropagation 沒生效，遊戲收到兩份
        ws.addEventListener('message', function(event) {
            const meta = stoppedEvents.get(event);
            if (meta) reshapeFault('stop_ineffective', meta, '原事件在攔下後仍被派發');
        });

        // 監聽打開
        ws.addEventListener('open', function() {
            console.log('[Naki WS] 已開啟:', wsId);
            // 同一個 open 事件以前送兩份（`websocket_open` + `websocket_connected`），
            // 名義上是「兩種格式確保兼容」，實際上 Swift 兩個 case 都在、其中一個只是
            // 多印一行 log。留一份就好。
            //
            // `isMajsoul` 必須跟著送：Swift 端拿它決定要不要把這條算進「已連上雀魂」。
            // 頁面上任何 WebSocket 都會走到這裡，混進來會讓那個狀態失去意義。
            sendToSwift('websocket_connected', { socketId: wsId, url: url, isMajsoul: isMajsoul });
        });

        // 連線紀錄只清一次。握手失敗只觸發 error 且當下 readyState 仍是 CONNECTING（live 實測，下個 tick 才 CLOSED），
        // 所以不能靠 readyState 判斷；error 一律釋放，隨後的 close 靠 released 冪等
        let released = false;
        const release = function() {
            if (released) return;
            released = true;
            wsConnections.delete(ws);
            if (window.__nakiPlugins && window.__nakiPlugins.closed) window.__nakiPlugins.closed(wsId);
        };

        // 監聽關閉
        ws.addEventListener('close', function(event) {
            console.log('[Naki WS] 已關閉:', wsId, event.code, event.reason);
            sendToSwift('websocket_close', {
                socketId: wsId,
                code: event.code,
                reason: event.reason,
                isMajsoul: isMajsoul
            });
            release();
        });

        // 監聽錯誤
        ws.addEventListener('error', function(event) {
            console.error('[Naki WS] 錯誤:', wsId, event);
            sendToSwift('websocket_error', {
                socketId: wsId,
                error: 'WebSocket error'
            });
            release();
        });

        // 攔截 send 方法
        const originalSend = ws.send.bind(ws);
        ws.send = function(data) {
            // rewriteSend（L3）換掉時改送新 bytes；沒換就是原物件，Naki 自送（isNaki）永遠沒換
            // 守衛擋下（block）時一律不送出：交付失敗也不退回 originalSend
            const out = handleMessage(ws, wsId, data, 'send', isMajsoul);
            if (out && out.block) return respondLocal(ws, wsId, out);
            return originalSend(out || data);
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
                const env = parseEnvelope(bytes);
                if (env && env.complete && env.method) {
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

            const env = parseEnvelope(bytes);
            if (!env || !env.complete || !env.payload) return;
            maskAuthGame(bytes, env.payload.from, env.payload.to);
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


    // Naki 自送登記（bridge D9、D22）：遊戲自己的 msgId 跑久了也會進 60000+，號段猜不準；
    // 遊戲的計數器跨連線遞增，所以以 (連線, msgId) 為鍵。只記最近 256 筆（所有連線共用），被淘汰的一律當成遊戲自己的。
    // RESPONSE 到了就標記已答：之後同線同號的 REQUEST 是遊戲自己的；同號 RESPONSE 仍算 Naki（分不出是哪一筆的回應）。
    // seq：登記序號。RESPONSE 只能回答它抵達前就存在的登記（Blob 異步展開期間的重送不算）
    const nakiSent = new Map();
    // sendRaw 送進 ws.send 的 buffer → 送出者（插件注入的交易代號，或 NAKI_SENDER）。來源判定只看這裡，不比 msgId、不比內容（pair-source）
    const rawSenders = new WeakMap(), NAKI_SENDER = 'naki';
    let nakiSentSeq = 0;
    function rememberNakiSent(socketId, bytes) {
        if (bytes[0] !== 2 || bytes.length < 3) return;
        const msgId = bytes[1] | (bytes[2] << 8), key = socketId + ':' + msgId;
        nakiSent.delete(key);
        nakiSent.set(key, { msgId: msgId, answered: false, seq: ++nakiSentSeq });
        if (nakiSent.size > 256) nakiSent.delete(nakiSent.keys().next().value);
    }
    function markNakiAnswered(socketId, data, arrivedAtSeq) {
        const b = data instanceof ArrayBuffer ? new Uint8Array(data)
                : (ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : null);
        if (!b || b.length < 3 || b[0] !== 3) return;
        const entry = nakiSent.get(socketId + ':' + (b[1] | (b[2] << 8)));
        if (entry && entry.seq <= arrivedAtSeq) entry.answered = true;
    }
    // 不給連線時回答「任一條連線上有沒有」（頁面 API 相容）；pendingOnly 只認還沒收到 RESPONSE 的（判斷 REQUEST 用）
    function isNakiSent(msgId, socketId, pendingOnly) {
        const hit = e => !!e && e.msgId === msgId && !(pendingOnly && e.answered);
        if (socketId != null) return hit(nakiSent.get(socketId + ':' + msgId));
        for (const e of nakiSent.values()) if (hit(e)) return true;
        return false;
    }

    /// 從送出的 REQUEST 認出方法名，記錄這條線是 lobby 線還是對局線
    function attributeSend(info, data) {
        try {
            const b = data instanceof ArrayBuffer ? new Uint8Array(data)
                    : (ArrayBuffer.isView(data)
                       ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : null);
            if (!b || b.length < 6 || b[0] !== 2 || b[3] !== 0x0a) return;
            const msgId = b[1] | (b[2] << 8);
            if (isNakiSent(msgId, info.id, true)) return;   // Naki 自己送的，不能當證據
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
    // 把訊息交給插件 hook（naki-plugins.js，若已載入）。
    //
    // 位置：在 nakiNicknameMask.observe 之後、arrayBufferToBase64／sendToSwift 之前
    // ——這樣 Phase 2 的等長 rewriteReceive 就地改 bytes 後，Swift 收到的是改後的。
    // 插件層自己做解析、白名單、鏈式與錯誤隔離；這裡再包一層 try/catch，
    // 保證「插件出錯絕不影響封包本身」（fail-open）。
    //
    // 回傳：send 方向被 rewriteSend 換掉時的新 Uint8Array，其餘 undefined。
    // receive 變長 replace／drop 回 { reshape:true, bytes, drop, method, msgId, by }（reshape：只有 ArrayBuffer 原事件且未鎖死才給）。
    // sender：sendRaw 送出的 buffer 才有（插件注入是宿主配的代號、Naki 自送是 NAKI_SENDER），遊戲送出是 undefined
    // tx：送出時 handleMessage 為這一筆建立的交易物件，dispatch 與 failSafe 共用，撤回只認它
    function dispatchToPlugins(direction, wsId, info, bytes, mutable, reshape, sender, tx) {
        if (!window.__nakiPlugins || typeof window.__nakiPlugins.dispatch !== 'function') return;
        try {
            const out = window.__nakiPlugins.dispatch({
                direction: direction,
                wsId: wsId,
                url: info ? info.url : '',
                bytes: bytes,
                mutable: mutable !== false,
                reshape: !!reshape && !reshapeLocked,
                sender: sender,
                tx: tx
            });
            if (direction === 'receive') return out && out.reshape ? out : undefined;
            return out instanceof Uint8Array || (out && out.block) ? out : undefined;
        } catch (e) {
            console.error('[Naki WS] 插件 dispatch 錯誤:', e);
            // 派發本身出錯：守衛方法（或有守衛者時認不出的封包）仍要擋下
            if (direction === 'send' && window.__nakiPlugins.failSafe) return window.__nakiPlugins.failSafe(bytes, wsId, sender, tx);
        }
    }

    // 本地回應（守衛擋下；日後 respondLocally 共用）。
    // Swift 成對交付：原 REQUEST 與 RESPONSE 放在同一則 bridge 訊息（localResponse 欄位），兩份都編碼成功才送；
    // postMessage 失敗時兩份一起不見，不會只到一半（審查第三輪第 3 條）。遊戲在 ws.send 回傳後才收到另一份複本，
    // Naki listener 略過它；交付後以擋下當時的連線、msgId、原方法與自己的快照結案。
    const syntheticEvents = new WeakSet();
    function respondLocal(ws, wsId, verdict) {
        let response = null;
        try {
            response = verdict.response ? verdict.response.slice() : null;
            if (verdict.request && response) {
                const reqB64 = arrayBufferToBase64(verdict.request.slice().buffer);
                const resB64 = arrayBufferToBase64(response.slice().buffer);
                if (reqB64 && resB64) {
                    sendToSwift('websocket_message', { socketId: wsId, direction: 'send', data: reqB64, type: 'binary',
                        size: verdict.request.byteLength, localResponse: resB64, reason: verdict.reason });
                }
            }
        } catch (e) { console.error('[Naki WS] 本地交易送 Swift 失敗（兩份都沒送）:', e); }
        if (!response) return;
        try {
            const forGame = response.slice();
            setTimeout(function () {
                try {
                    const ev = new MessageEvent('message', { data: forGame.buffer });
                    syntheticEvents.add(ev);
                    ws.dispatchEvent(ev);
                } catch (e) { console.error('[Naki WS] 本地回應交付失敗:', e); }
                try { window.__nakiPlugins.localResponse(verdict.socketId, verdict.msgId, verdict.method, response, verdict.injected); }
                catch (e) { console.error('[Naki WS] 本地回應結案失敗:', e); }
            }, 0);
        } catch (e) { console.error('[Naki WS] 本地回應排程失敗:', e); }
    }

    // receive 變長 replace／drop（Phase 4，docs/archive/plan/plugin-v2-phase4.md §1–§2、§5）。
    // 建構期（編碼、建合成事件、攔下原事件）任一步失敗 ⇒ 原事件照常交付、Swift 收原 bytes（fail-open）。
    // 攔下之後 bridge 拒收或 dispatch 拋錯 ⇒ 故障：頁面鎖死＋診斷，不重送原事件（遊戲可能已收到一部分）。
    // bridge 拒收時仍把合成事件交給遊戲：Swift 已經缺這一則，遊戲至少不卡在等它。
    // 合成派發期間有 listener 拋錯、或原事件攔不住（哨兵看到它）也記故障並鎖死，頁面重載才解。
    let reshapeLocked = false, dispatching = null;
    const reshapeStats = { attempted: 0, delivered: 0, dropped: 0, fallback: 0, faults: 0 };
    const reshapeFaults = [];
    const stoppedEvents = new WeakMap();
    function reshapeFault(kind, meta, err) {
        reshapeStats.faults++;
        reshapeFaults.push({ kind: kind, socketId: meta.socketId, method: meta.method, msgId: meta.msgId, candidates: meta.by,
            error: String((err && (err.message || err.error && err.error.message)) || err || ''), at: Date.now() });
        if (reshapeFaults.length > 32) reshapeFaults.shift();
        if (reshapeLocked) return;
        reshapeLocked = true;
        if (window.__nakiPlugins && window.__nakiPlugins.reshapeLocked) window.__nakiPlugins.reshapeLocked(kind, meta);
    }
    if (typeof window.addEventListener === 'function') {
        window.addEventListener('error', function (e) { if (dispatching) reshapeFault('synthetic_dispatch_error', dispatching, e); });
    }
    function deliverReshaped(ws, wsId, event, out) {
        const meta = { socketId: wsId, method: out.method, msgId: out.msgId, by: out.by };
        let ev = null, b64 = null;
        reshapeStats.attempted++;
        try {
            if (!out.drop) {
                b64 = arrayBufferToBase64(out.bytes);
                ev = new MessageEvent('message', { data: out.bytes.slice().buffer, origin: event.origin, lastEventId: event.lastEventId });
                syntheticEvents.add(ev);
            }
            event.stopImmediatePropagation();
        } catch (e) {
            console.error('[Naki WS] 變長改寫建構失敗，原事件照常交付:', e);
            reshapeStats.fallback++;
            sendToSwift('websocket_message', { socketId: wsId, direction: 'receive', data: arrayBufferToBase64(event.data),
                type: 'binary', size: event.data.byteLength });
            return;
        }
        stoppedEvents.set(event, meta);
        if (out.drop) { reshapeStats.dropped++; return; }
        let sent = false, bridgeError = 'sendToSwift 未送達';
        try { sent = sendToSwift('websocket_message', { socketId: wsId, direction: 'receive', data: b64, type: 'binary', size: out.bytes.byteLength }) !== false; }
        catch (e) { bridgeError = e; }
        if (!sent) reshapeFault('bridge_rejected', meta, bridgeError);
        dispatching = meta;
        try {
            ws.dispatchEvent(ev);
            if (sent) reshapeStats.delivered++;
        } catch (e) { reshapeFault('dispatch_threw', meta, e); }
        finally { dispatching = null; }
    }

    const messageTypes = {
        receive: { ArrayBuffer: 0, TypedArray: 0, Blob: 0, String: 0, Other: 0 },
        send: { ArrayBuffer: 0, TypedArray: 0, Blob: 0, String: 0, Other: 0 }
    };
    function handleMessage(ws, wsId, data, direction, isMajsoul, event) {
        // 只處理雀魂連接的訊息
        if (!isMajsoul) return;
        const dataType = data instanceof ArrayBuffer ? 'ArrayBuffer'
            : ArrayBuffer.isView(data) ? 'TypedArray'
            : data instanceof Blob ? 'Blob' : typeof data === 'string' ? 'String' : 'Other';
        messageTypes[direction][dataType]++;
        const sender = direction === 'send' && data && typeof data === 'object' ? rawSenders.get(data) : undefined;
        const tx = direction === 'send' ? {} : undefined;
        // 大廳連線上有守衛者時，無法同步辨識的送出一律拒送（Blob 等）
        if (direction === 'send' && (dataType === 'Blob' || dataType === 'Other')
            && window.__nakiPlugins && window.__nakiPlugins.refuseOpaqueSend && window.__nakiPlugins.refuseOpaqueSend(wsId)) {
            return { block: true, reason: 'opaque' };
        }

        // 記錄選線要用的資訊。
        //
        // 「最近收到過訊息」不夠用：雀魂同時開兩條 /gateway，兩條都會收心跳，
        // 時間戳常常完全相同，平手就退回順序——等於沒判。
        //
        // 真正有鑑別力的是「**遊戲自己**在哪條線上送 lobby 請求」：那條必然是
        // 完成 oauth2Login 的那條。Naki 自己送的不算（sendRaw 登記過的 msgId），
        // 否則會把自己送錯的那次記成正確答案，錯誤自我強化。
        const info = wsConnections.get(ws);
        if (info) {
            if (direction === 'receive') { info.lastRecvAt = Date.now(); markNakiAnswered(info.id, data, nakiSentSeq); }
            else if (direction === 'send') attributeSend(info, data);
        }

        try {
            if (data instanceof ArrayBuffer) {
                const pluginBytes = new Uint8Array(data);
                nakiNicknameMask.observe(pluginBytes, direction);
                const rewritten = dispatchToPlugins(direction, wsId, info, pluginBytes, true, !!event, sender, tx);
                if (rewritten && rewritten.block) return rewritten;
                if (direction === 'receive' && rewritten) return deliverReshaped(ws, wsId, event, rewritten);
                // ArrayBuffer：轉成 Base64（pluginBytes 是 data 的 view，插件若就地改過這裡編碼的是改後的；
                // rewriteSend 整包換掉時編碼新 bytes，Swift 與伺服器看到同一份）
                const sent = rewritten || data;
                sendToSwift('websocket_message', {
                    socketId: wsId,
                    direction: direction,
                    data: arrayBufferToBase64(sent),
                    type: 'binary',
                    size: sent.byteLength
                });
                return rewritten;
            } else if (ArrayBuffer.isView(data)) {
                // TypedArray / DataView：Unity WebGL 送出的封包走這條
                // （Laya 時代送 ArrayBuffer，只判 instanceof ArrayBuffer 會整批漏掉送出面，
                //  連帶讓 LiqiParser 收不到 REQUEST、無法配對 RESPONSE）
                const view = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
                nakiNicknameMask.observe(view, direction);
                const rewritten = dispatchToPlugins(direction, wsId, info, view, true, false, sender, tx);
                if (rewritten && rewritten.block) return rewritten;
                const sent = rewritten || view;
                sendToSwift('websocket_message', {
                    socketId: wsId,
                    direction: direction,
                    data: arrayBufferToBase64(sent),
                    type: 'binary',
                    size: sent.byteLength
                });
                return rewritten;
            } else if (data instanceof Blob) {
                // WebKit 的 WebSocket.binaryType 預設可能是 Blob。Swift 原本能收到這條，
                // 但插件只吃 ArrayBuffer / TypedArray，於是 iOS 會出現「插件已啟用卻沒事件」。
                //
                // Blob 只能異步展開；拿到的是副本，已經來不及改遊戲真正收到的 event.data，
                // 所以這條只允許 observe，不提供 rewriteReceive。
                const arrivedAtSeq = nakiSentSeq;
                data.arrayBuffer().then(function(buffer) {
                    const view = new Uint8Array(buffer);
                    if (direction === 'receive') markNakiAnswered(wsId, view, arrivedAtSeq);   // 記帳處讀不到 Blob，展開後補標記
                    dispatchToPlugins(direction, wsId, info, view, false, false, sender, tx);
                }).catch(function(e) {
                    console.error('[Naki WS] Blob 插件 dispatch 轉換失敗:', e);
                });

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
            // 派發前出錯：守衛方法（或已污染時認不出的封包）仍要擋下
            if (direction === 'send' && window.__nakiPlugins && window.__nakiPlugins.failSafe) {
                return window.__nakiPlugins.failSafe(data, wsId, sender, tx);
            }
        }
    }

    // ========================================
    // 導出到全域
    // ========================================

    window.__nakiWebSocket = {
        diagnostics: function () {
            return JSON.parse(JSON.stringify(Object.assign({ reshape: reshapeStats, reshapeLocked: reshapeLocked, reshapeFaults: reshapeFaults }, messageTypes)));
        },
        isNakiSent: isNakiSent,
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
        // sender：插件層 sendRequest 傳入的交易代號；Swift 呼叫時省略，記成 Naki 自送
        sendRaw: function(base64, sender) {
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
            const candidates = pick.length > 0 ? pick : conns;
            const proven = candidatesProvenFor(candidates, isGameMethod);

            // 沒有 proven 時選「最近收到過伺服器訊息」的那條，而不是最後建立的那條。
            //
            // 雀魂可能同時開著兩條 /gateway，但登入握手只在其中一條上做過；
            // 送到另一條伺服器會回 error 1004（連唯讀的 fetchAccountInfo 也一樣）。
            // 原本的 `pick[pick.length - 1]` 是照建立順序取最後一條，在這種情況下
            // 剛好選中沒登入的那條，於是匹配一直卡住而且沒有任何 log 說為什麼。
            //
            // 「最近收到過東西」是有事實根據的訊號：伺服器只會在活著的 session 上
            // 推訊息。平手時才退回原本的順序。
            const conn = proven || candidates.slice().sort(function (a, b) {
                return (b.lastRecvAt || 0) - (a.lastRecvAt || 0);
            })[0];

            // 選定連線後、送出前登記：包過的 send 會同步跑 attributeSend 與插件 dispatch
            rememberNakiSent(conn.id, bytes);
            rawSenders.set(bytes.buffer, sender || NAKI_SENDER);
            try {
                conn.ws.send(bytes.buffer);
            } catch (e) {
                console.error('[Naki WS] sendRaw 失敗:', conn.id, e);
                return { success: false, reason: 'send_failed: ' + e.message };
            }
            if (proven) return { success: true, bytes: bytes.length, socketId: conn.id, pickedBy: 'proven' };

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
