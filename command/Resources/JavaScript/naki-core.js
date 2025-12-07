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
                console.log('[Naki] Anti-idle: heartbeat refreshed (#' + antiIdleConfig.heartbeatCount + ')');
                return true;
            }
        } catch (e) {
            console.error('[Naki] Anti-idle heartbeat failed:', e);
        }
        return false;
    }

    /**
     * 啟用自動防閒置
     */
    function enableAntiIdle() {
        antiIdleConfig.enabled = true;
        console.log('[Naki] Anti-idle enabled');
        return true;
    }

    /**
     * 停用自動防閒置
     */
    function disableAntiIdle() {
        antiIdleConfig.enabled = false;
        console.log('[Naki] Anti-idle disabled');
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

    console.log('[Naki] Anti-idle module ready (passive mode, enabled by default)');

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
                console.log('[Naki] Emoji auto-reply: cooling down (' +
                    Math.ceil((emojiAutoReplyConfig.cooldownMs - timeSinceLastReply) / 1000) + 's left)');
                return;
            }

            // 如果已有待處理的回應，合併（忽略後續表情，只用第一個）
            if (emojiAutoReplyConfig.pendingTimeout) {
                emojiAutoReplyConfig.stats.merged++;
                console.log('[Naki] Emoji auto-reply: merged with pending (seat ' + data.seat + ')');
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
                                console.log('[Naki] Emoji auto-reply: sent emoji #' + emoToSend);
                            }
                        });
                    }
                } else {
                    emojiAutoReplyConfig.stats.skipped++;
                    console.log('[Naki] Emoji auto-reply: skipped (probability)');
                }
                emojiAutoReplyConfig.pendingTimeout = null;
                emojiAutoReplyConfig.pendingEmoId = null;
            }, emojiAutoReplyConfig.delayMs);

            console.log('[Naki] Emoji auto-reply: scheduled for 5s later (emoji #' + emoId + ')');
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
                console.log('[Naki] Emoji listener installed');
                return true;
            }
        } catch (e) {
            console.error('[Naki] Failed to install emoji listener:', e);
        }
        return false;
    }

    /**
     * 啟用自動回應表情
     */
    function enableEmojiAutoReply() {
        emojiAutoReplyConfig.enabled = true;
        installEmojiListener();
        console.log('[Naki] Emoji auto-reply enabled');
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
        console.log('[Naki] Emoji auto-reply disabled');
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

    console.log('[Naki] Emoji auto-reply module ready (enabled by default)');

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

    console.log('[Naki] Core module loaded');
})();
