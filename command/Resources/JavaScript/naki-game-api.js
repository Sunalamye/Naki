/**
 * Naki Game API - 遊戲 API 模組 (精簡版)
 * 核心功能已整合至 naki-coordinator.js
 * 此模組保留向後兼容的接口和輔助功能
 */
(function() {
    'use strict';

    // ========================================
    // 遊戲 API 探測 (保留用於調試)
    // ========================================

    window.__nakiDetectGameAPI = function() {
        const results = {
            engine: 'Laya',
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
            console.log('[Naki GameAPI] smartExecute (legacy) →', actionType, params);
            if (!window.NakiCoordinator) {
                console.error('[Naki GameAPI] NakiCoordinator not available');
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
    // 🎭 玩家名稱隱藏功能
    // ========================================

    window.__nakiPlayerNames = {
        hidden: false,

        hide: function() {
            try {
                const playerInfos = window.uiscript?.UI_DesktopInfo?.Inst?._player_infos;
                if (!playerInfos) return false;

                playerInfos.forEach(info => {
                    if (info?.name) info.name.visible = false;
                });
                this.hidden = true;
                console.log('[Naki PlayerNames] Hidden');
                return true;
            } catch (e) {
                return false;
            }
        },

        show: function() {
            try {
                const playerInfos = window.uiscript?.UI_DesktopInfo?.Inst?._player_infos;
                if (!playerInfos) return false;

                playerInfos.forEach(info => {
                    if (info?.name) info.name.visible = true;
                });
                this.hidden = false;
                console.log('[Naki PlayerNames] Shown');
                return true;
            } catch (e) {
                return false;
            }
        },

        toggle: function() {
            return this.hidden ? this.show() : this.hide();
        },

        getStatus: function() {
            const playerInfos = window.uiscript?.UI_DesktopInfo?.Inst?._player_infos;
            return {
                available: !!playerInfos,
                hidden: this.hidden,
                count: playerInfos?.length || 0
            };
        }
    };

    // ========================================
    // 🎯 Dora Shimmer Effect Hook (保留調試用)
    // ========================================

    window.__nakiDoraHook = {
        hooked: false,
        callHistory: [],

        hook: function() {
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
            return { hooked: this.hooked, history: this.callHistory };
        },

        clearHistory: function() {
            this.callHistory = [];
        }
    };

    // ========================================
    // 高亮效果初始化 (保留)
    // ========================================

    window.__nakiHighlightInit = {
        initialized: false,

        init: function() {
            const effect = window.view?.DesktopMgr?.Inst?.effect_recommend;
            if (effect) {
                this.initialized = true;
                return true;
            }
            return false;
        }
    };

    // 延遲初始化 hooks
    setTimeout(() => {
        window.__nakiDoraHook.hook();
        window.__nakiHighlightInit.init();
    }, 500);

    console.log('[Naki] Game API module loaded (slim version, uses NakiCoordinator)');
})();
