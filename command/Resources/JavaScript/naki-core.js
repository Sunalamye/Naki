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
    // 手牌高亮（Unity WebGL）
    // ========================================
    //
    // Unity 下沒有任何 per-tile DOM 或 Laya 物件可以改材質色（實測：頁面只暴露
    // GameLoader.OnLuaGC 一個橋接方法、Emscripten 匯出裡沒有 Il2Cpp 符號），
    // 所以改成「在 Unity 畫完的同一幀，直接往它的 framebuffer 疊色塊」：
    //   requestAnimationFrame 包裝 → Unity 的 callback 跑完 → scissor + clear 畫矩形。
    // 用 scissor+clear 而不是自繪 quad，是為了完全不碰 Unity 的 shader program /
    // buffer 綁定狀態，只動 scissor box 與 clear color 並在畫完還原。
    //
    // 牌的螢幕座標沒有任何官方資料可查（協定層只給牌的內容，不給版面），
    // 因此改為**每次需要時從畫面自動量測**：readPixels 掃描底部橫列，
    // 牌面是亮色、桌面是深色，連續亮區段即為一張牌。這樣換解析度／有副露
    // 導致手牌變短時都會自動跟上，不需要維護寫死的常數。
    (function () {
        var TILE_MIN_WIDTH = 40;      // 小於此寬度的亮區段視為雜訊（花紋、UI 邊框）
        var BRIGHT_THRESHOLD = 150;   // 牌面 vs 桌面的亮度分界
        var BAR_HEIGHT = 22;          // 標記條高度
        var BAR_GAP = 8;              // 標記條與牌頂的間距

        var marks = [];               // [{index, color:[r,g,b]}]
        var boxes = null;             // [{x, w}]，含 top（牌頂 y，畫布座標）
        var needCalib = false;
        var installed = false;

        function canvas() { return document.getElementById('unity-canvas'); }

        function gl2() {
            var c = canvas();
            return c ? c.getContext('webgl2') : null;
        }

        // 讀一整列像素（WebGL 原點在左下，這裡的 y 是畫布座標（左上原點））
        function readRow(gl, width, height, y) {
            var buf = new Uint8Array(width * 4);
            gl.readPixels(0, height - 1 - y, width, 1, gl.RGBA, gl.UNSIGNED_BYTE, buf);
            return buf;
        }

        function segmentsOf(buf, width) {
            var out = [], start = -1;
            for (var x = 0; x < width; x++) {
                var v = (buf[x * 4] + buf[x * 4 + 1] + buf[x * 4 + 2]) / 3;
                if (v > BRIGHT_THRESHOLD) { if (start < 0) start = x; }
                else if (start >= 0) {
                    if (x - start >= TILE_MIN_WIDTH) out.push({ x: start, w: x - start });
                    start = -1;
                }
            }
            if (start >= 0 && width - start >= TILE_MIN_WIDTH) out.push({ x: start, w: width - start });
            return out;
        }

        // 從當前 framebuffer 量測手牌位置。必須在 Unity 畫完的同一幀內呼叫。
        function calibrate() {
            var c = canvas(), gl = gl2();
            if (!c || !gl) return null;
            var W = c.width, H = c.height;

            // 由下往上掃，取亮區段最多的那一列（= 落在手牌帶上）
            var best = null;
            for (var y = H - 25; y > H - 300; y -= 6) {
                var segs = segmentsOf(readRow(gl, W, H, y), W);
                if (segs.length >= 3 && (!best || segs.length > best.segs.length)) {
                    best = { y: y, segs: segs };
                }
            }
            if (!best) return null;

            // 再往上找牌頂：以第一張牌的中心 x 逐列往上掃到不再是亮色為止
            var cx = best.segs[0].x + Math.floor(best.segs[0].w / 2);
            var top = best.y;
            for (var yy = best.y; yy > H - 320; yy--) {
                var px = new Uint8Array(4);
                gl.readPixels(cx, H - 1 - yy, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
                if ((px[0] + px[1] + px[2]) / 3 > BRIGHT_THRESHOLD) top = yy;
                else break;
            }

            best.segs.top = top;
            return best.segs;
        }

        function draw() {
            if (!marks.length) return;
            var c = canvas(), gl = gl2();
            if (!c || !gl) return;

            if (needCalib || !boxes) {
                boxes = calibrate();
                needCalib = false;
                if (!boxes) return;
            }

            var prevScissorOn = gl.getParameter(gl.SCISSOR_TEST);
            var prevBox = gl.getParameter(gl.SCISSOR_BOX);
            var prevClear = gl.getParameter(gl.COLOR_CLEAR_VALUE);

            gl.bindFramebuffer(gl.FRAMEBUFFER, null);
            gl.enable(gl.SCISSOR_TEST);

            var barY = Math.max(0, boxes.top - BAR_GAP - BAR_HEIGHT);
            for (var i = 0; i < marks.length; i++) {
                var m = marks[i];
                var b = boxes[m.index];
                if (!b) continue;
                gl.scissor(b.x, c.height - barY - BAR_HEIGHT, b.w, BAR_HEIGHT);
                gl.clearColor(m.color[0], m.color[1], m.color[2], 1);
                gl.clear(gl.COLOR_BUFFER_BIT);
            }

            if (!prevScissorOn) gl.disable(gl.SCISSOR_TEST);
            gl.scissor(prevBox[0], prevBox[1], prevBox[2], prevBox[3]);
            gl.clearColor(prevClear[0], prevClear[1], prevClear[2], prevClear[3]);
        }

        function install() {
            if (installed) return;
            installed = true;
            var origRAF = window.requestAnimationFrame.bind(window);
            window.requestAnimationFrame = function (cb) {
                return origRAF(function (t) {
                    var r = cb(t);          // Unity 在這裡畫完整幀
                    try { draw(); } catch (e) { /* 疊畫失敗不能影響遊戲本身 */ }
                    return r;
                });
            };
        }

        window.__nakiHighlight = {
            /// marks: [{index, color:[r,g,b]}]，index 為手牌由左至右的顯示序（含摸到的牌）
            set: function (newMarks) {
                marks = Array.isArray(newMarks) ? newMarks : [];
                needCalib = true;       // 手牌可能已變動，重新量測
                install();
                return marks.length;
            },
            clear: function () { marks = []; boxes = null; return true; },
            state: function () {
                return { marks: marks, boxes: boxes, tileCount: boxes ? boxes.length : 0 };
            }
        };
    })();

    console.log('[Naki] 核心模組已載入');
})();
