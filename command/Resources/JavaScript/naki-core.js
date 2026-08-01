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
    // 手牌高亮（Unity WebGL）— 依牌的身分，不算位置
    // ========================================
    //
    // 遊戲畫每一張牌時，`_MainTex_ST` 就寫著這張牌在圖集裡的格子——
    // 也就是**它正在畫哪一張牌**。所以不需要算螢幕座標、不需要排序、
    // 不需要對照第幾張：直接問「這張是不是 9m」就好。
    //
    // 實測對照（2026-07-31，與 /game/hand 逐張吻合）：
    //   手牌 3m 3m 5mr 7m 8m 9m 3p 5p 6p 8p 2s 3s 4s + 摸 9p
    //   UV  .3/.5 .3/.5 0/.5 .7/.5 .8/.5 .9/.5 .3/.25 … .9/.25
    //   → v 決定花色（0.5=萬 0.25=筒 0.75=索 0=字），u 決定數字，u=0 是紅五
    //   兩張 3m 的 UV 完全相同，證明 UV 編的是牌面而不是位置。
    //
    // 先前用「投影後排序取第幾張」的做法已移除：手牌張數會變（摸/打）、
    // 立直時牌會被抬起、畫面邊緣還有別的牌混進同一列，每一項都會讓索引錯位。
    (function () {
        var SUIT_BY_V = { '0.5': 'm', '0.25': 'p', '0.75': 's' };
        var HONORS = ['E', 'S', 'W', 'N', 'P', 'F', 'C'];

        var targets = {};          // tile 名稱 -> [r,g,b]
        var popupColor = null;
        var installed = false;
        var locCache = new Map();
        var totalFrames = 0;
        var baselineSigs = new Set();   // 沒有副露機會時看過的 draw 簽章
        var baselineFrames = 0;
        var objIds = new WeakMap();
        var nextObjId = 1;
        var tintedCount = 0;

        function objId(o) {
            if (!o) return 0;
            var id = objIds.get(o);
            if (!id) { id = nextObjId++; objIds.set(o, id); }
            return id;
        }

        function locsFor(gl, prog) {
            if (locCache.has(prog)) return locCache.get(prog);
            var st = gl.getUniformLocation(prog, '_MainTex_ST');
            // 顏色 uniform 名稱依 shader 而異：手牌是 _Tint、其他 UI 是 _Color
            var color = gl.getUniformLocation(prog, '_Tint')
                     || gl.getUniformLocation(prog, '_Color');
            var L = color ? { st: st, color: color } : null;
            locCache.set(prog, L);
            return L;
        }

        /// 由圖集 UV 反推這是哪一張牌（MJAI 記法）
        function tileFromST(st) {
            if (!st || st.length < 4) return null;
            var u = Math.round(st[2] * 10) / 10;
            var v = Math.round(st[3] * 100) / 100;
            var suit = SUIT_BY_V[String(v)];
            if (suit) {
                var n = Math.round(u * 10);
                if (n === 0) return '5' + suit + 'r';   // u=0 是該花色的紅五
                if (n >= 1 && n <= 9) return String(n) + suit;
                return null;
            }
            if (v === 0) {
                // 字牌：u × 10 直接就是 HONORS 的索引，不能再減 1。
                //
                // 2026-08-01 live 對局實測（手牌 E W W P C）：
                //   u=0   ×37  → E
                //   u=0.2 ×74  → W（兩張，次數正好兩倍）
                //   u=0.4 ×37  → P
                //   u=0.6 ×37  → C
                // 原本的 -1 會讓 E 變 null、W 變 S、P 變 N、C 變 F——
                // 不是解不出來，是**染錯牌**。
                var idx = Math.round(u * 10);
                return (idx >= 0 && idx < HONORS.length) ? HONORS[idx] : null;
            }
            return null;
        }

        function install(gl) {
            if (installed) return;
            installed = true;

            var origDraw = gl.drawElements.bind(gl);
            gl.drawElements = function (mode, count, type, offset) {
                var prog = gl.getParameter(gl.CURRENT_PROGRAM);
                if (!prog) return origDraw(mode, count, type, offset);

                var L;
                try { L = locsFor(gl, prog); } catch (e) { L = null; }
                if (!L) return origDraw(mode, count, type, offset);

                var color = null;

                // 一、手牌：用 UV 認出是哪張牌
                if (L.st && count === 6 && Object.keys(targets).length) {
                    try {
                        var tile = tileFromST(gl.getUniform(prog, L.st));
                        if (tile && targets[tile]) color = targets[tile];
                    } catch (e) { /* 取不到就當作不是牌 */ }
                }

                // 二、副露彈出面板：位置與 UV 都認不出，改用「與平時畫面比對」。
                //
                // 原本的規則是「出現頻率 < 25% 的 draw 就當成按鈕」，太鬆——
                // 動畫、特效、過場 UI 都是低頻的，結果整個畫面都被染色（實測確認）。
                //
                // 改法：沒有副露機會時持續收集畫面的 draw 簽章當**基準線**；
                // 有機會時只染「基準線裡沒出現過」的簽章。按鈕是機會出現才有的東西，
                // 這個判準比頻率精確得多。
                var sig = count + '/' + objId(prog) + '/'
                        + objId(gl.getParameter(gl.TEXTURE_BINDING_2D));
                if (!popupColor) {
                    // 沒機會時：這一幀畫的東西都算平時就有的
                    baselineSigs.add(sig);
                    baselineFrames++;
                } else if (!color && baselineFrames > 120 && !baselineSigs.has(sig)) {
                    // 基準線要夠厚才敢下判斷，否則剛開局什麼都會被當成按鈕
                    color = popupColor;
                }

                if (!color) return origDraw(mode, count, type, offset);

                // 只在這一次 draw 期間覆寫顏色，畫完立刻還原，不留狀態給遊戲。
                //
                // color 可以是 [r,g,b] 或 [r,g,b,a]。給了第 4 個分量就用它當 alpha，
                // 用來把「不推薦的牌」調淡；沒給就沿用遊戲原本的 alpha。
                var prev = gl.getUniform(prog, L.color);
                var baseAlpha = (prev && prev.length > 3) ? prev[3] : 1;
                var alpha = (color.length > 3) ? color[3] * baseAlpha : baseAlpha;
                gl.uniform4f(L.color, color[0], color[1], color[2], alpha);
                var r = origDraw(mode, count, type, offset);
                if (prev && prev.length > 3) {
                    gl.uniform4f(L.color, prev[0], prev[1], prev[2], prev[3]);
                }
                tintedCount++;
                return r;
            };

            var origRAF = window.requestAnimationFrame.bind(window);
            window.requestAnimationFrame = function (cb) {
                return origRAF(function (t) { totalFrames++; return cb(t); });
            };
        }

        function context() {
            var c = document.getElementById('unity-canvas');
            return c ? c.getContext('webgl2') : null;
        }

        window.__nakiHighlight = {
            /// list: [{tile:"9m", color:[r,g,b]}] 或 color:[r,g,b,a]；popup: [r,g,b] 或 null
            set: function (list, popup) {
                targets = {};
                (list || []).forEach(function (m) { targets[m.tile] = m.color; });
                popupColor = (popup && popup.length === 3) ? popup : null;
                var gl = context();
                if (gl) install(gl);
                return Object.keys(targets).length;
            },
            clear: function () { targets = {}; popupColor = null; return true; },
            state: function () {
                return { targets: targets, popup: popupColor,
                         tinted: tintedCount, totalFrames: totalFrames,
                         baselineSigs: baselineSigs.size, baselineFrames: baselineFrames };
            },
            /// 除錯用：列出當前這一幀在手牌區畫出的牌（依 UV 反推）
            decode: function (st) { return tileFromST(st); }
        };
    })();

    console.log('[Naki] 核心模組已載入');
})();
