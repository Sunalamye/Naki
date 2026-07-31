/**
 * Naki Game API - 遊戲 API 模組 (精簡版)
 * 核心功能已整合至 naki-coordinator.js
 * 此模組保留向後兼容的接口和輔助功能
 */
(function() {
    'use strict';

    // ========================================
    // ⚠️ Unity WebGL 遷移說明（2026-07 實測）
    // ========================================
    /**
     * 雀魂已從 Laya 3D + JS 改為 Unity WebGL (chs_t-WebGL-release-4.0.45)。
     * window.Laya / window.view.DesktopMgr / window.uiscript / window.GameMgr / window.cfg
     * 全部不存在，因此本檔案中所有「直接操作遊戲物件」的功能（玩家名稱隱藏、
     * 寶牌 hook、推薦高亮初始化）在原理上已不可能運作。
     *
     * 本檔案不整檔刪除（naki-coordinator.js 與 MCP 工具仍引用這些 API），
     * 改為：偵測不到 Laya 物件時回傳明確失敗
     *   { success: false, reason: 'unity-client-no-laya' }
     * 而不是靜默回 false 造成假訊號。
     *
     * 推薦顯示的唯一管道 = 原生 SwiftUI 面板
     *   command/Views/RecommendationView.swift、command/Views/BotStatusView.swift
     */

    /** Laya 客戶端是否可用（Unity WebGL 下永遠為 false） */
    function nakiLayaAvailable() {
        return !!(window.Laya
            && window.view
            && window.view.DesktopMgr
            && window.view.DesktopMgr.Inst);
    }

    /** uiscript（Laya UI 層）是否可用 */
    function nakiUIScriptAvailable() {
        return !!(window.uiscript && window.uiscript.UI_DesktopInfo);
    }

    /** 統一的失效回傳（明確失敗，不拋錯、不靜默） */
    function nakiLayaUnavailable(api) {
        console.warn('[Naki GameAPI] ' + api + ' 無法執行：Unity WebGL 客戶端沒有 Laya/DesktopMgr/uiscript');
        return {
            success: false,
            reason: 'unity-client-no-laya',
            api: api,
            error: 'Majsoul Unity WebGL client: Laya game objects not present'
        };
    }

    // ========================================
    // 遊戲 API 探測 (保留用於調試)
    // ========================================

    window.__nakiDetectGameAPI = function() {
        const layaAvailable = nakiLayaAvailable();
        const results = {
            // 不再硬寫 'Laya'：實際偵測，避免誤導
            engine: layaAvailable ? 'Laya' : 'unity-webgl-or-unknown',
            layaAvailable: layaAvailable,
            uiscriptAvailable: nakiUIScriptAvailable(),
            inGameHighlightSupported: layaAvailable,
            coordinator: !!window.NakiCoordinator,
            availableAPIs: [],
            gameObjects: []
        };

        if (window.view) results.gameObjects.push('view');
        if (window.GameMgr) results.gameObjects.push('GameMgr');
        if (window.uiscript) results.gameObjects.push('uiscript');
        if (window.mjcore) results.gameObjects.push('mjcore');
        if (window.app?.NetAgent) results.availableAPIs.push('NetAgent');

        return results;
    };

    window.__nakiExploreGameObjects = function() {
        // 委託給 NakiCoordinator
        if (window.NakiCoordinator) {
            return window.NakiCoordinator.debug.getDiagnostics();
        }
        return { error: 'NakiCoordinator not loaded' };
    };

    // ========================================
    // 向後兼容的 __nakiGameAPI 接口
    // 所有調用轉發給 NakiCoordinator
    // ========================================

    window.__nakiGameAPI = {
        isAvailable: function() {
            return window.NakiCoordinator ? !!window.NakiCoordinator.dm : false;
        },

        getGameState: function() {
            if (window.NakiCoordinator) {
                return window.NakiCoordinator.state.getFullState();
            }
            return null;
        },

        getHandInfo: function() {
            if (window.NakiCoordinator) {
                return window.NakiCoordinator.state.getHandInfo();
            }
            return null;
        },

        getAvailableOps: function() {
            if (window.NakiCoordinator) {
                return window.NakiCoordinator.state.getAvailableOps();
            }
            return [];
        },

        // 向後兼容的 smartExecute
        smartExecute: function(actionType, params) {
            console.log('[Naki GameAPI] smartExecute (舊版) →', actionType, params);
            if (!window.NakiCoordinator) {
                console.error('[Naki GameAPI] NakiCoordinator 不可用');
                return { success: false, error: 'coordinator not available' };
            }
            return window.NakiCoordinator.action.execute(actionType, params);
        },

        // 舊接口轉發
        discardTile: function(idx) {
            return window.NakiCoordinator?.action.discard(idx);
        },
        pass: function() {
            return window.NakiCoordinator?.action.pass();
        },
        executeOperation: function(opType, combIdx) {
            return window.NakiCoordinator?.action._executeNaki(opType, combIdx || 0);
        }
    };

    // ========================================
    // 🎭 玩家名稱隱藏功能 — ⚠️ Unity 客戶端已失效
    // 依賴 window.uiscript.UI_DesktopInfo（Laya UI 層），Unity WebGL 下不存在。
    // ========================================

    window.__nakiPlayerNames = {
        hidden: false,

        hide: function() {
            if (!nakiUIScriptAvailable()) return nakiLayaUnavailable('playerNames.hide');
            try {
                const playerInfos = window.uiscript?.UI_DesktopInfo?.Inst?._player_infos;
                if (!playerInfos) return false;

                playerInfos.forEach(info => {
                    if (info?.name) {
                        info.name.visible = false;
                        info.name.alpha = 0;
                    }
                });
                this.hidden = true;
                console.log('[Naki 玩家名稱] 已隱藏');
                return true;
            } catch (e) {
                return false;
            }
        },

        show: function() {
            if (!nakiUIScriptAvailable()) return nakiLayaUnavailable('playerNames.show');
            try {
                const playerInfos = window.uiscript?.UI_DesktopInfo?.Inst?._player_infos;
                if (!playerInfos) return false;

                playerInfos.forEach(info => {
                    if (info?.name) {
                        info.name.visible = true;
                        info.name.alpha = 1;
                    }
                });
                this.hidden = false;
                console.log('[Naki 玩家名稱] 已顯示');
                return true;
            } catch (e) {
                return false;
            }
        },

        toggle: function() {
            if (!nakiUIScriptAvailable()) return nakiLayaUnavailable('playerNames.toggle');
            return this.hidden ? this.show() : this.hide();
        },

        getStatus: function() {
            const playerInfos = window.uiscript?.UI_DesktopInfo?.Inst?._player_infos;
            return {
                available: !!playerInfos,
                hidden: this.hidden,
                count: playerInfos?.length || 0,
                // 明確標示不可用的原因，避免「available:false」被誤讀成「還沒進對局」
                reason: playerInfos ? null : 'unity-client-no-laya'
            };
        }
    };

    // ========================================
    // 🎯 Dora Shimmer Effect Hook (保留調試用) — ⚠️ Unity 客戶端已失效
    // 依賴 view.DesktopMgr.Inst.effect_dora3D（Laya Sprite3D），Unity WebGL 下不存在。
    // ========================================

    window.__nakiDoraHook = {
        hooked: false,
        callHistory: [],

        hook: function() {
            if (!nakiLayaAvailable()) return nakiLayaUnavailable('doraHook.hook');
            try {
                const effect = window.view?.DesktopMgr?.Inst?.effect_dora3D;
                if (!effect) return false;

                let _visible = effect.visible;
                const self = this;

                Object.defineProperty(effect, 'visible', {
                    get() { return _visible; },
                    set(val) {
                        self.callHistory.push({
                            timestamp: Date.now(),
                            value: val
                        });
                        if (self.callHistory.length > 50) self.callHistory.shift();
                        _visible = val;
                    }
                });

                this.hooked = true;
                return true;
            } catch (e) {
                return false;
            }
        },

        getHistory: function() {
            return {
                hooked: this.hooked,
                history: this.callHistory,
                reason: nakiLayaAvailable() ? null : 'unity-client-no-laya'
            };
        },

        clearHistory: function() {
            this.callHistory = [];
        }
    };

    // ========================================
    // 高亮效果初始化 (保留) — ⚠️ Unity 客戶端已失效
    // 依賴 view.DesktopMgr.Inst.effect_recommend，Unity WebGL 下不存在。
    // ========================================

    window.__nakiHighlightInit = {
        initialized: false,

        init: function() {
            if (!nakiLayaAvailable()) return nakiLayaUnavailable('highlightInit.init');
            const effect = window.view?.DesktopMgr?.Inst?.effect_recommend;
            if (effect) {
                this.initialized = true;
                return true;
            }
            return false;
        }
    };

    // 延遲初始化 hooks（僅 Laya 客戶端；Unity 下直接略過並留下一行明確紀錄）
    setTimeout(() => {
        if (!nakiLayaAvailable()) {
            console.log('[Naki] 略過 dora/highlight hook 初始化：'
                + 'Unity WebGL 客戶端無 Laya 物件，遊戲內高亮已停用（改用原生推薦面板）');
            return;
        }
        window.__nakiDoraHook.hook();
        window.__nakiHighlightInit.init();
    }, 500);

    console.log('[Naki] 遊戲 API 模組已載入 (精簡版, 使用 NakiCoordinator)');
})();
