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
    // 導出到全域
    // ========================================

    window.__nakiCore = {
        arrayBufferToBase64: arrayBufferToBase64,
        base64ToArrayBuffer: base64ToArrayBuffer,
        blobToBase64: blobToBase64,
        sendToSwift: sendToSwift,
        // 防閒置 API（也可通過 window.__nakiAntiIdle 訪問）
        antiIdle: window.__nakiAntiIdle
    };

    // 向後兼容：直接導出到 window
    window.__nakiArrayBufferToBase64 = arrayBufferToBase64;
    window.__nakiBase64ToArrayBuffer = base64ToArrayBuffer;
    window.__nakiBlobToBase64 = blobToBase64;
    window.__nakiSendToSwift = sendToSwift;

    console.log('[Naki] Core module loaded');
})();
