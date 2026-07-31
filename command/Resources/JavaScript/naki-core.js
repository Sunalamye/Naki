/**
 * Naki Core - 基礎工具模組
 * 提供 Base64 編碼/解碼、Swift 通訊等核心功能
 */
(function() {
    'use strict';

    // 避免重複注入
    if (window.__nakiCoreLoaded) {
        return;
    }
    window.__nakiCoreLoaded = true;

    // ========================================
    // Base64 編碼/解碼
    // ========================================

    /**
     * ArrayBuffer 轉 Base64
     */
    function arrayBufferToBase64(buffer) {
        const bytes = new Uint8Array(buffer);
        let binary = '';
        for (let i = 0; i < bytes.byteLength; i++) {
            binary += String.fromCharCode(bytes[i]);
        }
        return btoa(binary);
    }

    /**
     * Base64 轉 ArrayBuffer
     */
    function base64ToArrayBuffer(base64) {
        const binary = atob(base64);
        const len = binary.length;
        const bytes = new Uint8Array(len);
        for (let i = 0; i < len; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        return bytes.buffer;
    }

    /**
     * Blob 轉 Base64 (異步)
     */
    function blobToBase64(blob, callback) {
        const reader = new FileReader();
        reader.onloadend = function() {
            const base64 = reader.result.split(',')[1];
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
                window.webkit.messageHandlers.websocketBridge) {
                window.webkit.messageHandlers.websocketBridge.postMessage({
                    type: type,
                    data: data,
                    timestamp: Date.now()
                });
            }
        } catch (e) {
            // 忽略錯誤，不影響正常運作
        }
    }

    // ========================================
    // 自動防閒置 (Anti-Idle)
    // 監聽伺服器心跳通知，自動刷新本地心跳時間
    // ========================================

    var antiIdleConfig = {
        enabled: true,           // 預設開啟
        lastHeartbeat: 0,
        heartbeatCount: 0,
        minInterval: 5 * 60 * 1000  // 最小刷新間隔：5 分鐘
    };

    /**
     * 刷新心跳（被動響應伺服器訊息時調用）
     * 有最小間隔限制，避免過於頻繁刷新
     */
    function refreshHeartbeat() {
        if (!antiIdleConfig.enabled) return false;

        var now = Date.now();
        // 檢查是否超過最小間隔
        if (antiIdleConfig.lastHeartbeat > 0 &&
            (now - antiIdleConfig.lastHeartbeat) < antiIdleConfig.minInterval) {
            return false; // 間隔太短，跳過
        }

        try {
            var gm = window.GameMgr;
            if (gm && gm.Inst && typeof gm.Inst.clientHeatBeat === 'function') {
                gm.Inst.clientHeatBeat();
                antiIdleConfig.lastHeartbeat = now;
                antiIdleConfig.heartbeatCount++;
                console.log('[Naki] 防閒置: 心跳已刷新 (#' + antiIdleConfig.heartbeatCount + ')');
                return true;
            }
        } catch (e) {
            console.error('[Naki] 防閒置心跳失敗:', e);
        }
        return false;
    }

    /**
     * 啟用自動防閒置
     */
    function enableAntiIdle() {
        antiIdleConfig.enabled = true;
        console.log('[Naki] 防閒置已啟用');
        return true;
    }

    /**
     * 停用自動防閒置
     */
    function disableAntiIdle() {
        antiIdleConfig.enabled = false;
        console.log('[Naki] 防閒置已停用');
        return true;
    }

    /**
     * 獲取防閒置狀態
     */
    function getAntiIdleStatus() {
        var now = Date.now();
        var gm = window.GameMgr;
        var serverLastHeartbeat = (gm && gm.Inst) ? gm.Inst._last_heatbeat_time : 0;
        var timeSinceLastRefresh = antiIdleConfig.lastHeartbeat > 0
            ? Math.floor((now - antiIdleConfig.lastHeartbeat) / 1000)
            : -1;
        var nextRefreshIn = antiIdleConfig.lastHeartbeat > 0
            ? Math.max(0, Math.floor((antiIdleConfig.minInterval - (now - antiIdleConfig.lastHeartbeat)) / 1000))
            : 0;

        return {
            enabled: antiIdleConfig.enabled,
            heartbeatCount: antiIdleConfig.heartbeatCount,
            minIntervalSeconds: antiIdleConfig.minInterval / 1000,
            lastRefresh: antiIdleConfig.lastHeartbeat,
            lastRefreshAgo: timeSinceLastRefresh >= 0
                ? timeSinceLastRefresh + ' 秒前'
                : '尚未刷新',
            nextRefreshIn: nextRefreshIn + ' 秒後',
            serverLastHeartbeat: serverLastHeartbeat,
            serverIdleSeconds: serverLastHeartbeat > 0
                ? Math.floor((now - serverLastHeartbeat) / 1000)
                : -1
        };
    }

    // 導出防閒置 API 到全域（供 WebSocket 模組調用）
    window.__nakiAntiIdle = {
        refresh: refreshHeartbeat,
        enable: enableAntiIdle,
        disable: disableAntiIdle,
        status: getAntiIdleStatus,
        isEnabled: function() { return antiIdleConfig.enabled; }
    };

    console.log('[Naki] 防閒置模組已載入 (被動模式, 預設啟用)');

    // ========================================
    // 自動回應表情 (Emoji Auto-Reply)
    // 當其他玩家發送表情時，5 秒後以 50% 機率回應相同表情
    // ========================================

    var emojiAutoReplyConfig = {
        enabled: true,           // 預設開啟
        lastReplyTime: 0,
        cooldownMs: 60000,       // 60 秒冷卻
        delayMs: 5000,           // 5 秒延遲
        probability: 0.5,        // 50% 機率
        pendingTimeout: null,
        pendingEmoId: null,
        stats: { received: 0, replied: 0, skipped: 0, merged: 0 }
    };

    /**
     * 處理收到的表情廣播
     */
    function handleEmojiBroadcast(data) {
        if (!emojiAutoReplyConfig.enabled) return;

        try {
            var content = JSON.parse(data.content);
            var emoId = content.emo;

            // 確認是表情
            if (typeof emoId !== 'number') return;

            // 確認不是自己發的
            var dm = window.view && window.view.DesktopMgr && window.view.DesktopMgr.Inst;
            var mySeat = dm ? dm.seat : -1;
            if (data.seat === mySeat) return;

            emojiAutoReplyConfig.stats.received++;

            var now = Date.now();
            var timeSinceLastReply = now - emojiAutoReplyConfig.lastReplyTime;

            // 檢查冷卻
            if (timeSinceLastReply < emojiAutoReplyConfig.cooldownMs) {
                emojiAutoReplyConfig.stats.skipped++;
                console.log('[Naki] 自動回應表情: 冷卻中 (剩餘 ' +
                    Math.ceil((emojiAutoReplyConfig.cooldownMs - timeSinceLastReply) / 1000) + ' 秒)');
                return;
            }

            // 如果已有待處理的回應，合併（忽略後續表情，只用第一個）
            if (emojiAutoReplyConfig.pendingTimeout) {
                emojiAutoReplyConfig.stats.merged++;
                console.log('[Naki] 自動回應表情: 已合併 (座位 ' + data.seat + ')');
                return;
            }

            // 記錄待發送的表情 ID
            emojiAutoReplyConfig.pendingEmoId = emoId;

            // 5 秒後以 50% 機率回應
            emojiAutoReplyConfig.pendingTimeout = setTimeout(function() {
                if (!emojiAutoReplyConfig.enabled) {
                    emojiAutoReplyConfig.pendingTimeout = null;
                    emojiAutoReplyConfig.pendingEmoId = null;
                    return;
                }

                var emoToSend = emojiAutoReplyConfig.pendingEmoId;

                if (Math.random() < emojiAutoReplyConfig.probability) {
                    // 發送表情
                    if (window.app && window.app.NetAgent) {
                        window.app.NetAgent.sendReq2MJ('FastTest', 'broadcastInGame', {
                            content: JSON.stringify({ emo: emoToSend }),
                            except_self: false
                        }, function(err, res) {
                            if (!err) {
                                emojiAutoReplyConfig.lastReplyTime = Date.now();
                                emojiAutoReplyConfig.stats.replied++;
                                console.log('[Naki] 自動回應表情: 已發送表情 #' + emoToSend);
                            }
                        });
                    }
                } else {
                    emojiAutoReplyConfig.stats.skipped++;
                    console.log('[Naki] 自動回應表情: 跳過 (機率未中)');
                }
                emojiAutoReplyConfig.pendingTimeout = null;
                emojiAutoReplyConfig.pendingEmoId = null;
            }, emojiAutoReplyConfig.delayMs);

            console.log('[Naki] 自動回應表情: 已排程 5 秒後回應 (表情 #' + emoId + ')');
        } catch (e) {
            // 忽略非 JSON 內容
        }
    }

    /**
     * 安裝表情廣播監聽器
     */
    function installEmojiListener() {
        if (window.__nakiEmojiListenerInstalled) return true;

        try {
            var netAgent = window.app && window.app.NetAgent;
            var routeGroup = netAgent && netAgent.netRouteGroup_mj;
            var handlers = routeGroup && routeGroup.notifyHander && routeGroup.notifyHander.handlers;
            var originalHandler = handlers && handlers['.lq.NotifyGameBroadcast'];

            if (originalHandler && originalHandler[0]) {
                var origMethod = originalHandler[0].__nakiOrigMethod || originalHandler[0].method;

                // 保存原始方法
                if (!originalHandler[0].__nakiOrigMethod) {
                    originalHandler[0].__nakiOrigMethod = origMethod;
                }

                originalHandler[0].method = function(data) {
                    // 調用原始方法
                    if (origMethod) {
                        origMethod.call(this, data);
                    }

                    // 調用自動回應邏輯
                    handleEmojiBroadcast(data);
                };

                window.__nakiEmojiListenerInstalled = true;
                console.log('[Naki] 表情監聽器已安裝');
                return true;
            }
        } catch (e) {
            console.error('[Naki] 安裝表情監聽器失敗:', e);
        }
        return false;
    }

    /**
     * 啟用自動回應表情
     */
    function enableEmojiAutoReply() {
        emojiAutoReplyConfig.enabled = true;
        installEmojiListener();
        console.log('[Naki] 自動回應表情已啟用');
        return true;
    }

    /**
     * 停用自動回應表情
     */
    function disableEmojiAutoReply() {
        emojiAutoReplyConfig.enabled = false;
        // 清除待處理的回應
        if (emojiAutoReplyConfig.pendingTimeout) {
            clearTimeout(emojiAutoReplyConfig.pendingTimeout);
            emojiAutoReplyConfig.pendingTimeout = null;
            emojiAutoReplyConfig.pendingEmoId = null;
        }
        console.log('[Naki] 自動回應表情已停用');
        return true;
    }

    /**
     * 獲取自動回應表情狀態
     */
    function getEmojiAutoReplyStatus() {
        var now = Date.now();
        var cooldownRemaining = 0;
        if (emojiAutoReplyConfig.lastReplyTime > 0) {
            var elapsed = now - emojiAutoReplyConfig.lastReplyTime;
            if (elapsed < emojiAutoReplyConfig.cooldownMs) {
                cooldownRemaining = Math.ceil((emojiAutoReplyConfig.cooldownMs - elapsed) / 1000);
            }
        }

        return {
            enabled: emojiAutoReplyConfig.enabled,
            listenerInstalled: !!window.__nakiEmojiListenerInstalled,
            cooldownRemainingSeconds: cooldownRemaining,
            pendingReply: emojiAutoReplyConfig.pendingTimeout !== null,
            settings: {
                delaySeconds: emojiAutoReplyConfig.delayMs / 1000,
                probability: emojiAutoReplyConfig.probability,
                cooldownSeconds: emojiAutoReplyConfig.cooldownMs / 1000
            },
            stats: emojiAutoReplyConfig.stats
        };
    }

    // 導出自動回應表情 API 到全域
    window.__nakiEmojiAutoReply = {
        enable: enableEmojiAutoReply,
        disable: disableEmojiAutoReply,
        status: getEmojiAutoReplyStatus,
        isEnabled: function() { return emojiAutoReplyConfig.enabled; },
        installListener: installEmojiListener
    };

    console.log('[Naki] 自動回應表情模組已載入 (預設啟用)');

    // ========================================
    // 導出到全域
    // ========================================

    window.__nakiCore = {
        arrayBufferToBase64: arrayBufferToBase64,
        base64ToArrayBuffer: base64ToArrayBuffer,
        blobToBase64: blobToBase64,
        sendToSwift: sendToSwift,
        // 防閒置 API（也可通過 window.__nakiAntiIdle 訪問）
        antiIdle: window.__nakiAntiIdle,
        // 自動回應表情 API（也可通過 window.__nakiEmojiAutoReply 訪問）
        emojiAutoReply: window.__nakiEmojiAutoReply
    };

    // 向後兼容：直接導出到 window
    window.__nakiArrayBufferToBase64 = arrayBufferToBase64;
    window.__nakiBase64ToArrayBuffer = base64ToArrayBuffer;
    window.__nakiBlobToBase64 = blobToBase64;
    window.__nakiSendToSwift = sendToSwift;

    // ========================================
    // 手牌高亮（Unity WebGL）— 改遊戲自己畫牌時用的顏色
    // ========================================
    //
    // 不自繪、不疊圖層、不推算座標：牌的位置與顏色本來就在 shader uniform 裡，
    // 攔 `drawElements` 直接改就好（實測 2026-07-31）：
    //
    //   自家手牌 = UI quad（`count === 6`），uniform 有
    //     hlslcc_mtx4x4unity_ObjectToWorld[3]  → 世界座標（第 4 列即位置）
    //     hlslcc_mtx4x4unity_MatrixVP[0..3]    → 遊戲自己的 view-projection
    //     _Color                                → 顏色，改它就等於把牌染色
    //   （桌上的 3D 牌是另一組 `count === 606`，uniform 用 `_Tint`；
    //     自家手牌雀魂是當 sprite 畫的，所以走 UI 這條。）
    //
    // 投影約定（踩過）：clip[j] = dot(worldPos, VP 第 j 個分量組成的向量)，
    // 也就是 `clip[j] = w0*VP[0][j] + w1*VP[1][j] + w2*VP[2][j] + w3*VP[3][j]`。
    // 反過來寫（dot(VP[j], worldPos)）會得到數量級完全錯誤的結果。
    //
    // 手牌辨識：投影後 y 落在同一條線上、x 等距的那一排就是自家手牌，
    // 依 x 排序即為畫面上由左至右的顯示序。整排位置由遊戲決定，
    // 換解析度／有副露導致手牌變短都會自動跟上。
    (function () {
        var HAND_Y_MAX = -0.55;    // NDC y 低於此值才可能是自家手牌那一排
        var Y_TOLERANCE = 0.02;    // 同一排的 y 容差
        var X_TOLERANCE = 0.03;    // 對應到同一張牌的 x 容差
        // 滑鼠指到／選取時雀魂會把那張牌抬起來，y 會離開靜止那一排。
        // 抬起只改 y、不改 x，所以索引一律以 x 認人，y 只用來界定「屬於手牌區」。
        var LIFT_TOLERANCE = 0.16;

        var marks = {};            // index -> [r,g,b]
        var handXs = [];           // 上一幀量到的手牌 x（已排序），供本幀查索引
        var handY = null;
        var scan = [];             // 本幀候選點 [{x,y}]
        var installed = false;
        var progCache = new Map();

        // 副露按鈕（吃／碰／跳過）的辨識：它們的位置不在 uniform 裡
        // （Unity UI 把座標烘進 vertex buffer），所以改用「只在有副露機會時才出現」
        // 這個事實——維護一份平時的 draw call 基線，機會出現時不在基線裡的就是彈出面板。
        // 實測差異只有 4 筆（兩個按鈕 quad + 文字/光效），且會隨版本自動跟上，
        // 不需要寫死貼圖 ID 或螢幕座標。
        var popupColor = null;     // 有值時代表「現在有副露機會」，要染彈出面板
        var sigFrames = new Map(); // draw call 特徵 -> 出現過的幀數
        var totalFrames = 0;
        var frameSigs = new Set();
        var POPUP_RATIO = 0.25;    // 出現率低於此值才算「彈出元件」
        var POPUP_MIN_FRAMES = 300;
        var objIds = new WeakMap();
        var nextObjId = 1;

        var popupTinted = 0;
        var colorCache = new Map();

        function objId(o) {
            if (!o) return 0;
            var id = objIds.get(o);
            if (!id) { id = nextObjId++; objIds.set(o, id); }
            return id;
        }

        /// 只找顏色 uniform（不要求位置），給彈出面板用
        function colorLocFor(gl, prog) {
            if (colorCache.has(prog)) return colorCache.get(prog);
            var c = gl.getUniformLocation(prog, '_Tint')
                 || gl.getUniformLocation(prog, '_Color');
            colorCache.set(prog, c);
            return c;
        }

        function locsFor(gl, prog) {
            if (progCache.has(prog)) return progCache.get(prog);
            var o3 = gl.getUniformLocation(prog, 'hlslcc_mtx4x4unity_ObjectToWorld[3]');
            var vp = [0, 1, 2, 3].map(function (i) {
                return gl.getUniformLocation(prog, 'hlslcc_mtx4x4unity_MatrixVP[' + i + ']');
            });
            // 顏色 uniform 名稱依 shader 而異：自家手牌那組是 `_Tint`，
            // 其他 UI 是 `_Color`。兩者語意相同（乘在貼圖上），取到哪個就用哪個。
            var color = gl.getUniformLocation(prog, '_Tint')
                     || gl.getUniformLocation(prog, '_Color');
            var L = (o3 && vp[0] && color) ? { o3: o3, vp: vp, color: color } : null;
            progCache.set(prog, L);
            return L;
        }

        function project(gl, prog, L) {
            var w = gl.getUniform(prog, L.o3);
            if (!w) return null;
            var vp = [
                gl.getUniform(prog, L.vp[0]), gl.getUniform(prog, L.vp[1]),
                gl.getUniform(prog, L.vp[2]), gl.getUniform(prog, L.vp[3])
            ];
            if (!vp[0]) return null;
            var cw = w[0] * vp[0][3] + w[1] * vp[1][3] + w[2] * vp[2][3] + w[3] * vp[3][3];
            if (!cw) return null;
            var cx = w[0] * vp[0][0] + w[1] * vp[1][0] + w[2] * vp[2][0] + w[3] * vp[3][0];
            var cy = w[0] * vp[0][1] + w[1] * vp[1][1] + w[2] * vp[2][1] + w[3] * vp[3][1];
            return { x: cx / cw, y: cy / cw };
        }

        /// 從本幀候選點裡挑出手牌那一排。
        ///
        /// 不能用「最低的一排」——畫面底部還有其他 UI（實測 y = -1 的角落元件會搶走），
        /// 手牌的特徵是**同一條 y 上有最多相異 x**（一整排等距的牌），用這個判定才穩。
        /// 同一張牌會被畫好幾個 quad（底、面、框），所以 x 要去重。
        function resolveHandRow() {
            var groups = [];   // [{y, xs:[]}]
            for (var i = 0; i < scan.length; i++) {
                var p = scan[i];
                var g = null;
                for (var j = 0; j < groups.length; j++) {
                    if (Math.abs(groups[j].y - p.y) < Y_TOLERANCE) { g = groups[j]; break; }
                }
                if (!g) { g = { y: p.y, xs: [] }; groups.push(g); }
                var dup = false;
                for (var k = 0; k < g.xs.length; k++) {
                    if (Math.abs(g.xs[k] - p.x) < X_TOLERANCE) { dup = true; break; }
                }
                if (!dup) g.xs.push(p.x);
            }
            var best = null;
            for (var m = 0; m < groups.length; m++) {
                if (groups[m].xs.length >= 5 && (!best || groups[m].xs.length > best.xs.length)) {
                    best = groups[m];
                }
            }
            if (!best) return;

            handY = best.y;
            var xs = best.xs.slice();
            // 被抬起的那張牌不在靜止列上，但它仍是手牌的一員——
            // 不補回來的話 x 清單會少一格，後面所有索引就整個位移（選牌時高亮跑掉）。
            for (var q = 0; q < scan.length; q++) {
                var s = scan[q];
                if (s.y <= handY + Y_TOLERANCE || s.y > handY + LIFT_TOLERANCE) continue;
                var known = false;
                for (var r = 0; r < xs.length; r++) {
                    if (Math.abs(xs[r] - s.x) < X_TOLERANCE) { known = true; break; }
                }
                if (!known) xs.push(s.x);
            }
            handXs = xs.sort(function (a, b) { return a - b; });
        }

        function indexOfTile(p) {
            // y 只用來界定「還在手牌區」（含被抬起的牌），實際認人一律看 x
            if (handY === null) return -1;
            if (p.y < handY - Y_TOLERANCE || p.y > handY + LIFT_TOLERANCE) return -1;
            for (var i = 0; i < handXs.length; i++) {
                if (Math.abs(handXs[i] - p.x) < X_TOLERANCE) return i;
            }
            return -1;
        }

        function install(gl) {
            if (installed) return;
            installed = true;

            var origDraw = gl.drawElements.bind(gl);
            gl.drawElements = function (mode, count, type, offset) {
                var prog = gl.getParameter(gl.CURRENT_PROGRAM);

                // 副露彈出面板：不在基線裡的 draw call 就染色
                if (prog) {
                    var sig = count + '/' + objId(prog) + '/' +
                              objId(gl.getParameter(gl.TEXTURE_BINDING_2D));
                    frameSigs.add(sig);
                    // 常駐 UI 幾乎每幀都畫，副露按鈕只在少數幀出現——用出現率區分。
                    // 不能用「累積基線」：按鈕在更早的機會裡就會被吸收進去，之後永不判為彈出。
                    var seenFrames = sigFrames.get(sig) || 0;
                    if (popupColor && totalFrames > POPUP_MIN_FRAMES
                        && seenFrames < totalFrames * POPUP_RATIO) {
                        // 彈出面板只需要顏色 uniform——按鈕的 shader 沒有 ObjectToWorld /
                        // MatrixVP（Unity UI 把座標烘進 vertex buffer），所以不能沿用
                        // 手牌那條需要位置的查詢，否則整批會被判定「缺 uniform」而跳過。
                        var pc = colorLocFor(gl, prog);
                        if (pc) {
                            var pPrev = gl.getUniform(prog, pc);
                            gl.uniform4f(pc, popupColor[0], popupColor[1], popupColor[2],
                                         pPrev && pPrev.length > 3 ? pPrev[3] : 1);
                            var pr = origDraw(mode, count, type, offset);
                            if (pPrev && pPrev.length > 3) {
                                gl.uniform4f(pc, pPrev[0], pPrev[1], pPrev[2], pPrev[3]);
                            }
                            popupTinted++;
                            return pr;
                        }
                    }
                }

                if (count !== 6) return origDraw(mode, count, type, offset);
                if (!prog) return origDraw(mode, count, type, offset);

                var L;
                try { L = locsFor(gl, prog); } catch (e) { L = null; }
                if (!L) return origDraw(mode, count, type, offset);

                var p;
                try { p = project(gl, prog, L); } catch (e) { p = null; }
                if (!p || p.y > HAND_Y_MAX) return origDraw(mode, count, type, offset);

                if (scan.length < 2000) scan.push(p);

                var idx = indexOfTile(p);
                var color = (idx >= 0) ? marks[idx] : null;
                if (!color) return origDraw(mode, count, type, offset);

                // 只在這一次 draw 期間覆寫顏色，畫完立刻還原，不留任何狀態給遊戲
                var prev = gl.getUniform(prog, L.color);
                gl.uniform4f(L.color, color[0], color[1], color[2],
                             prev && prev.length > 3 ? prev[3] : 1);
                var r = origDraw(mode, count, type, offset);
                if (prev && prev.length > 3) {
                    gl.uniform4f(L.color, prev[0], prev[1], prev[2], prev[3]);
                }
                return r;
            };

            // 一幀結束才把量到的 x 定案，供下一幀查索引（畫的當下還不知道總共幾張）
            var origRAF = window.requestAnimationFrame.bind(window);
            window.requestAnimationFrame = function (cb) {
                return origRAF(function (t) {
                    var r = cb(t);
                    resolveHandRow();
                    scan = [];
                    totalFrames++;
                    frameSigs.forEach(function (s) {
                        sigFrames.set(s, (sigFrames.get(s) || 0) + 1);
                    });
                    frameSigs = new Set();
                    return r;
                });
            };
        }

        function context() {
            var c = document.getElementById('unity-canvas');
            return c ? c.getContext('webgl2') : null;
        }

        window.__nakiHighlight = {
            /// marks: [{index, color:[r,g,b]}]，index = 手牌由左至右的顯示序（含摸到的牌）
            /// popup: [r,g,b] 或 null——有值時把副露彈出面板（吃／碰／跳過）一併染色
            set: function (list, popup) {
                marks = {};
                (list || []).forEach(function (m) { marks[m.index] = m.color; });
                popupColor = (popup && popup.length === 3) ? popup : null;
                var gl = context();
                if (gl) install(gl);
                return Object.keys(marks).length;
            },
            clear: function () { marks = {}; popupColor = null; return true; },
            state: function () {
                return {
                    marks: marks, handTileCount: handXs.length, handY: handY, handXs: handXs,
                    popup: popupColor, totalFrames: totalFrames,
                    sigCount: sigFrames.size, popupTinted: popupTinted
                };
            }
        };
    })();

    console.log('[Naki] 核心模組已載入');
})();
