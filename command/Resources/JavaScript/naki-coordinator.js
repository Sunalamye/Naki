/**
 * Naki Coordinator - 統一遊戲管理協調器
 * 整合所有遊戲 API，提供統一的控制介面
 *
 * 依賴: naki-core.js, naki-game-api.js, naki-autoplay.js, naki-websocket.js
 */
(function() {
    'use strict';

    // 避免重複注入
    if (window.__nakiCoordinatorLoaded) {
        console.log('[Naki Coordinator] Already loaded');
        return;
    }
    window.__nakiCoordinatorLoaded = true;

    // ========================================
    // 統一協調器
    // ========================================

    window.NakiCoordinator = {
        version: '1.1.0',

        // ========================================
        // 核心管理器參考 (快取)
        // ========================================
        _cache: {
            dm: null,           // DesktopMgr.Inst
            mr: null,           // mainrole
            gm: null,           // GameMgr.Inst
            netAgent: null,     // app.NetAgent
            lastUpdate: 0
        },

        // ========================================
        // 動作追蹤 (用於檢測動作是否執行成功)
        // ========================================
        _actionTracker: {
            lastAction: null,           // 上次執行的動作
            lastActionTime: 0,          // 上次動作時間
            lastHandCount: -1,          // 上次手牌數量
            lastOplistLength: -1,       // 上次 oplist 長度
            pendingVerification: null,  // 待驗證的動作
            verificationTimeout: null   // 驗證超時定時器
        },

        /**
         * 刷新快取的管理器參考
         */
        _refreshCache: function() {
            const now = Date.now();
            // 100ms 內不重複刷新
            if (now - this._cache.lastUpdate < 100) return;

            this._cache.dm = window.view?.DesktopMgr?.Inst || null;
            this._cache.mr = this._cache.dm?.mainrole || null;
            this._cache.gm = window.GameMgr?.Inst || null;
            this._cache.netAgent = window.app?.NetAgent || null;
            this._cache.lastUpdate = now;
        },

        /**
         * 獲取 DesktopMgr 實例
         */
        get dm() {
            this._refreshCache();
            return this._cache.dm;
        },

        /**
         * 獲取 mainrole
         */
        get mr() {
            this._refreshCache();
            return this._cache.mr;
        },

        /**
         * 獲取 GameMgr 實例
         */
        get gm() {
            this._refreshCache();
            return this._cache.gm;
        },

        /**
         * 獲取 NetAgent
         */
        get net() {
            this._refreshCache();
            return this._cache.netAgent;
        },

        // ========================================
        // 動作驗證方法
        // ========================================

        /**
         * 記錄動作執行前的狀態快照
         */
        _snapshotBeforeAction: function(actionType) {
            const mr = this.mr;
            const dm = this.dm;

            this._actionTracker.lastAction = actionType;
            this._actionTracker.lastActionTime = Date.now();
            this._actionTracker.lastHandCount = mr ? mr.hand?.length : -1;
            this._actionTracker.lastOplistLength = dm?.oplist?.length || 0;

            console.log('[Naki Tracker] Snapshot before:', actionType,
                'hand:', this._actionTracker.lastHandCount,
                'oplist:', this._actionTracker.lastOplistLength);
        },

        /**
         * 驗證動作是否執行成功
         * @param {string} actionType - 動作類型
         * @param {number} timeout - 超時時間 (ms)，預設 2000ms
         * @returns {Promise<{success: boolean, verified: boolean, reason: string}>}
         */
        verifyAction: function(actionType, timeout = 2000) {
            const self = this;
            const startSnapshot = {
                handCount: this._actionTracker.lastHandCount,
                oplistLength: this._actionTracker.lastOplistLength,
                actionRunning: this.state.isActionRunning(),
                operationShowing: this.state.isOperationShowing()
            };

            return new Promise((resolve) => {
                const startTime = Date.now();
                const checkInterval = 100; // 每 100ms 檢查一次

                const checker = setInterval(() => {
                    const elapsed = Date.now() - startTime;
                    const mr = self.mr;
                    const dm = self.dm;

                    const currentHandCount = mr ? mr.hand?.length : -1;
                    const currentOplistLength = dm?.oplist?.length || 0;
                    const currentActionRunning = self.state.isActionRunning();
                    const currentOpShowing = self.state.isOperationShowing();

                    let verified = false;
                    let reason = '';

                    // 根據動作類型判斷是否成功
                    switch (actionType) {
                        case 'discard':
                            // 打牌後手牌應該減少 1 張
                            if (currentHandCount === startSnapshot.handCount - 1) {
                                verified = true;
                                reason = 'hand count decreased';
                            }
                            break;

                        case 'pass':
                        case 'chi':
                        case 'pon':
                        case 'kan':
                            // 副露/pass 後 oplist 應該清空
                            if (startSnapshot.oplistLength > 0 && currentOplistLength === 0) {
                                verified = true;
                                reason = 'oplist cleared';
                            }
                            // 或者 operation_showing 從 true 變 false
                            if (startSnapshot.operationShowing && !currentOpShowing) {
                                verified = true;
                                reason = 'operation_showing cleared';
                            }
                            break;

                        case 'hora':
                        case 'tsumo':
                        case 'ron':
                            // 和牌後遊戲應該結束或 action_running 變化
                            if (!self.state.isInGame() || currentActionRunning !== startSnapshot.actionRunning) {
                                verified = true;
                                reason = 'game state changed';
                            }
                            break;

                        case 'riichi':
                            // 立直後 oplist 應該變化
                            if (currentOplistLength !== startSnapshot.oplistLength) {
                                verified = true;
                                reason = 'oplist changed after riichi';
                            }
                            break;
                    }

                    if (verified) {
                        clearInterval(checker);
                        console.log('[Naki Tracker] Action verified:', actionType, reason, 'in', elapsed, 'ms');
                        resolve({ success: true, verified: true, reason: reason, elapsed: elapsed });
                    } else if (elapsed >= timeout) {
                        clearInterval(checker);
                        console.warn('[Naki Tracker] Action verification timeout:', actionType);
                        resolve({ success: false, verified: false, reason: 'timeout', elapsed: elapsed });
                    }
                }, checkInterval);
            });
        },

        /**
         * 獲取上次動作資訊
         */
        getLastAction: function() {
            return {
                action: this._actionTracker.lastAction,
                time: this._actionTracker.lastActionTime,
                elapsed: Date.now() - this._actionTracker.lastActionTime
            };
        },

        // ========================================
        // 遊戲狀態查詢
        // ========================================
        state: {
            /**
             * 檢查遊戲是否進行中
             */
            isInGame: function() {
                const dm = NakiCoordinator.dm;
                return dm ? dm.gameing === true : false;
            },

            /**
             * 檢查是否正在執行動作
             */
            isActionRunning: function() {
                const dm = NakiCoordinator.dm;
                return dm ? dm.action_running === true : false;
            },

            /**
             * 檢查是否有操作選項顯示中
             */
            isOperationShowing: function() {
                const dm = NakiCoordinator.dm;
                return dm ? dm.operation_showing === true : false;
            },

            /**
             * 檢查是否在重連中
             */
            isReconnecting: function() {
                const dm = NakiCoordinator.dm;
                return dm ? dm.duringReconnect === true : false;
            },

            /**
             * 檢查是否可以執行操作
             */
            canExecuteAction: function() {
                return this.isInGame() &&
                       !this.isActionRunning() &&
                       !this.isReconnecting();
            },

            /**
             * 獲取完整遊戲狀態
             */
            getFullState: function() {
                const dm = NakiCoordinator.dm;
                const gm = NakiCoordinator.gm;

                if (!dm) return { available: false };

                return {
                    available: true,
                    // 基本狀態
                    gameing: dm.gameing,
                    gamestate: dm.gamestate,
                    seat: dm.seat,
                    // 動作狀態
                    action_running: dm.action_running,
                    operation_showing: dm.operation_showing,
                    duringReconnect: dm.duringReconnect,
                    // 操作列表
                    oplist: dm.oplist ? dm.oplist.map(o => ({
                        type: o.type,
                        combination: o.combination || []
                    })) : [],
                    choosed_op: dm.choosed_op,
                    // 自動設定
                    auto_hule: dm.auto_hule,
                    auto_nofulu: dm.auto_nofulu,
                    auto_moqie: dm.auto_moqie,
                    auto_liqi: dm.auto_liqi,
                    // 回合資訊
                    index_turn: dm.index_turn,
                    index_player: dm.index_player,
                    // GameMgr 狀態
                    account_id: gm?.account_id,
                    room_id: gm?.room_id
                };
            },

            /**
             * 獲取手牌資訊
             */
            getHandInfo: function() {
                const mr = NakiCoordinator.mr;
                if (!mr || !mr.hand) return null;

                return {
                    count: mr.hand.length,
                    tiles: mr.hand.map((t, i) => ({
                        index: i,
                        type: t.val?.type,
                        value: t.val?.index,
                        dora: t.val?.dora || false,
                        pos_x: t.pos_x
                    }))
                };
            },

            /**
             * 獲取可用操作
             */
            getAvailableOps: function() {
                const dm = NakiCoordinator.dm;
                if (!dm || !dm.oplist) return [];

                const opNames = {
                    0: 'none', 1: 'dapai', 2: 'chi', 3: 'pon',
                    4: 'ankan', 5: 'minkan', 6: 'kakan', 7: 'riichi',
                    8: 'tsumo', 9: 'ron', 10: 'kyushu', 11: 'babei'
                };

                return dm.oplist.map((o, i) => ({
                    index: i,
                    type: o.type,
                    name: opNames[o.type] || 'unknown',
                    combination: o.combination || []
                }));
            }
        },

        // ========================================
        // 自動設定控制
        // ========================================
        auto: {
            /**
             * 獲取所有自動設定狀態
             */
            getSettings: function() {
                const dm = NakiCoordinator.dm;
                if (!dm) return null;

                return {
                    hule: dm.auto_hule || false,      // 自動和牌
                    nofulu: dm.auto_nofulu || false,  // 不吃碰槓
                    moqie: dm.auto_moqie || false,    // 自動摸切
                    liqi: dm.auto_liqi || false,      // 自動立直
                    babei: dm.auto_babei || false     // 自動拔北
                };
            },

            /**
             * 設定自動和牌
             */
            setHule: function(enabled) {
                const dm = NakiCoordinator.dm;
                if (dm && typeof dm.setAutoHule === 'function') {
                    dm.setAutoHule(enabled);
                    console.log('[Naki Coordinator] Auto hule:', enabled);
                    return true;
                }
                return false;
            },

            /**
             * 設定不吃碰槓 (自動 pass)
             */
            setNoFulu: function(enabled) {
                const dm = NakiCoordinator.dm;
                if (dm && typeof dm.setAutoNoFulu === 'function') {
                    dm.setAutoNoFulu(enabled);
                    console.log('[Naki Coordinator] Auto no-fulu:', enabled);
                    return true;
                }
                return false;
            },

            /**
             * 設定自動摸切
             */
            setMoqie: function(enabled) {
                const dm = NakiCoordinator.dm;
                if (dm && typeof dm.setAutoMoQie === 'function') {
                    dm.setAutoMoQie(enabled);
                    console.log('[Naki Coordinator] Auto moqie:', enabled);
                    return true;
                }
                return false;
            },

            /**
             * 設定自動立直
             */
            setLiqi: function(enabled) {
                const dm = NakiCoordinator.dm;
                if (dm && typeof dm.setAutoLiPai === 'function') {
                    dm.setAutoLiPai(enabled);
                    console.log('[Naki Coordinator] Auto liqi:', enabled);
                    return true;
                }
                return false;
            },

            /**
             * 啟用所有自動設定
             */
            enableAll: function() {
                this.setHule(true);
                this.setNoFulu(true);
                this.setMoqie(true);
                this.setLiqi(true);
                console.log('[Naki Coordinator] All auto settings enabled');
            },

            /**
             * 停用所有自動設定
             */
            disableAll: function() {
                this.setHule(false);
                this.setNoFulu(false);
                this.setMoqie(false);
                this.setLiqi(false);
                console.log('[Naki Coordinator] All auto settings disabled');
            }
        },

        // ========================================
        // 遊戲操作執行
        // ========================================
        action: {
            /**
             * 操作類型映射
             */
            OP_TYPES: {
                none: 0, dapai: 1, chi: 2, pon: 3,
                ankan: 4, minkan: 5, kakan: 6, riichi: 7,
                tsumo: 8, ron: 9, kyushu: 10, babei: 11
            },

            /**
             * 執行打牌
             * @param {number} tileIndex - 手牌索引
             * @param {Object} options - 選項 {verify: boolean, verifyTimeout: number}
             */
            discard: function(tileIndex, options = {}) {
                const mr = NakiCoordinator.mr;
                if (!mr || !mr.hand) {
                    console.error('[Naki Action] mainrole not available');
                    return { success: false, error: 'mainrole not available' };
                }

                if (!NakiCoordinator.state.canExecuteAction()) {
                    console.error('[Naki Action] Cannot execute action now');
                    return { success: false, error: 'cannot execute action' };
                }

                const actualIndex = Math.min(tileIndex, mr.hand.length - 1);
                const tile = mr.hand[actualIndex];

                if (!tile) {
                    console.error('[Naki Action] Tile not found:', actualIndex);
                    return { success: false, error: 'tile not found' };
                }

                // 記錄動作前快照
                NakiCoordinator._snapshotBeforeAction('discard');

                try {
                    mr.setChoosePai(tile, true);
                    mr.DoDiscardTile();
                    console.log('[Naki Action] Discard tile:', actualIndex);

                    const result = { success: true, tileIndex: actualIndex };

                    // 如果需要驗證
                    if (options.verify) {
                        result.verifyPromise = NakiCoordinator.verifyAction('discard', options.verifyTimeout || 2000);
                    }

                    return result;
                } catch (e) {
                    console.error('[Naki Action] Discard error:', e);
                    return { success: false, error: e.message };
                }
            },

            /**
             * 執行跳過
             * @param {Object} options - 選項 {useBuiltin: boolean, verify: boolean}
             */
            pass: function(options = {}) {
                // 如果啟用內建方式，使用 setAutoNoFulu 臨時開啟
                if (options.useBuiltin) {
                    const dm = NakiCoordinator.dm;
                    if (dm && typeof dm.setAutoNoFulu === 'function') {
                        // 臨時開啟自動 pass
                        dm.setAutoNoFulu(true);
                        // 200ms 後關閉
                        setTimeout(() => {
                            dm.setAutoNoFulu(false);
                            console.log('[Naki Action] Auto no-fulu disabled');
                        }, 200);
                        console.log('[Naki Action] Pass via builtin auto-nofulu');
                        return { success: true, method: 'builtin' };
                    }
                }

                const net = NakiCoordinator.net;
                if (!net) {
                    console.error('[Naki Action] NetAgent not available');
                    return { success: false, error: 'NetAgent not available' };
                }

                // 記錄動作前快照
                NakiCoordinator._snapshotBeforeAction('pass');

                try {
                    net.sendReq2MJ('FastTest', 'inputOperation', {
                        cancel_operation: true,
                        timeuse: 1
                    });
                    console.log('[Naki Action] Pass sent');

                    const result = { success: true, method: 'network' };

                    if (options.verify) {
                        result.verifyPromise = NakiCoordinator.verifyAction('pass', options.verifyTimeout || 2000);
                    }

                    return result;
                } catch (e) {
                    console.error('[Naki Action] Pass error:', e);
                    return { success: false, error: e.message };
                }
            },

            /**
             * 執行吃
             * @param {number} combinationIndex - 組合索引
             * @param {Object} options - 選項 {verify: boolean}
             */
            chi: function(combinationIndex = 0, options = {}) {
                return this._executeNaki(2, combinationIndex, 'chi', options);
            },

            /**
             * 執行碰
             * @param {Object} options - 選項 {verify: boolean}
             */
            pon: function(options = {}) {
                return this._executeNaki(3, 0, 'pon', options);
            },

            /**
             * 執行槓 (明槓/暗槓/加槓)
             * @param {Object} options - 選項 {verify: boolean}
             */
            kan: function(options = {}) {
                // 嘗試明槓(5)、暗槓(4)、加槓(6)
                const dm = NakiCoordinator.dm;
                if (!dm || !dm.oplist) {
                    return { success: false, error: 'oplist not available' };
                }

                const kanOp = dm.oplist.find(o => o.type === 5 || o.type === 4 || o.type === 6);
                if (!kanOp) {
                    return { success: false, error: 'no kan operation available' };
                }

                return this._executeNaki(kanOp.type, 0, 'kan', options);
            },

            /**
             * 執行和牌 (自摸或榮和)
             * @param {Object} options - 選項 {useBuiltin: boolean, verify: boolean}
             */
            hora: function(options = {}) {
                const dm = NakiCoordinator.dm;

                // 方法 1: 使用內建自動和功能 (最可靠)
                if (options.useBuiltin !== false) {  // 預設啟用
                    if (dm && typeof dm.setAutoHule === 'function') {
                        dm.setAutoHule(true);
                        console.log('[Naki Action] Auto-hule enabled (will auto win)');

                        // 2 秒後關閉自動和，避免影響後續遊戲
                        setTimeout(() => {
                            if (dm && typeof dm.setAutoHule === 'function') {
                                dm.setAutoHule(false);
                                console.log('[Naki Action] Auto-hule disabled');
                            }
                        }, 2000);

                        return { success: true, method: 'builtin', type: 'auto_hule' };
                    }
                }

                // 方法 2: 直接發送請求
                if (!dm || !dm.oplist) {
                    return { success: false, error: 'oplist not available' };
                }

                const horaOp = dm.oplist.find(o => o.type === 8 || o.type === 9);
                if (!horaOp) {
                    return { success: false, error: 'no hora operation available' };
                }

                const net = NakiCoordinator.net;
                if (!net) {
                    return { success: false, error: 'NetAgent not available' };
                }

                // 記錄動作前快照
                NakiCoordinator._snapshotBeforeAction('hora');

                try {
                    net.sendReq2MJ('FastTest', 'inputOperation', {
                        type: horaOp.type,
                        timeuse: 1
                    });
                    console.log('[Naki Action] Hora sent:', horaOp.type === 8 ? 'tsumo' : 'ron');

                    const result = { success: true, method: 'network', type: horaOp.type };

                    if (options.verify) {
                        result.verifyPromise = NakiCoordinator.verifyAction('hora', options.verifyTimeout || 3000);
                    }

                    return result;
                } catch (e) {
                    return { success: false, error: e.message };
                }
            },

            /**
             * 執行立直
             * @param {number} tileIndex - 要打的牌索引
             * @param {Object} options - 選項 {verify: boolean}
             */
            riichi: function(tileIndex, options = {}) {
                const dm = NakiCoordinator.dm;
                const mr = NakiCoordinator.mr;
                const net = NakiCoordinator.net;

                if (!dm || !dm.oplist || !net) {
                    return { success: false, error: 'not available' };
                }

                // 增強狀態檢查
                if (!NakiCoordinator.state.isInGame()) {
                    return { success: false, error: 'not in game' };
                }

                const riichiOp = dm.oplist.find(o => o.type === 7);
                if (!riichiOp) {
                    return { success: false, error: 'riichi not available' };
                }

                // 如果沒指定牌，使用 combination 中的第一張
                let tile = tileIndex;
                if (tile === undefined && riichiOp.combination && riichiOp.combination[0]) {
                    tile = riichiOp.combination[0];
                }

                const isMoqie = mr && mr.hand && mr.hand.length === 14;

                // 記錄動作前快照
                NakiCoordinator._snapshotBeforeAction('riichi');

                try {
                    net.sendReq2MJ('FastTest', 'inputOperation', {
                        type: 7,
                        tile: tile,
                        moqie: isMoqie,
                        timeuse: 1
                    });
                    console.log('[Naki Action] Riichi sent:', tile);

                    const result = { success: true, tile: tile };

                    if (options.verify) {
                        result.verifyPromise = NakiCoordinator.verifyAction('riichi', options.verifyTimeout || 2000);
                    }

                    return result;
                } catch (e) {
                    return { success: false, error: e.message };
                }
            },

            /**
             * 內部方法：執行副露操作
             * @param {number} opType - 操作類型
             * @param {number} combinationIndex - 組合索引
             * @param {string} actionName - 動作名稱 (用於驗證)
             * @param {Object} options - 選項
             */
            _executeNaki: function(opType, combinationIndex, actionName = 'naki', options = {}) {
                const dm = NakiCoordinator.dm;
                const net = NakiCoordinator.net;

                if (!dm || !dm.oplist || !net) {
                    return { success: false, error: 'not available' };
                }

                // 增強狀態檢查
                if (!NakiCoordinator.state.isInGame()) {
                    return { success: false, error: 'not in game' };
                }

                if (NakiCoordinator.state.isActionRunning()) {
                    return { success: false, error: 'action already running' };
                }

                const op = dm.oplist.find(o => o.type === opType);
                if (!op) {
                    return { success: false, error: 'operation not available', opType: opType };
                }

                const combIdx = Math.min(combinationIndex, (op.combination?.length || 1) - 1);

                // 記錄動作前快照
                NakiCoordinator._snapshotBeforeAction(actionName);

                try {
                    net.sendReq2MJ('FastTest', 'inputChiPengGang', {
                        type: opType,
                        index: combIdx,
                        timeuse: 1
                    });
                    console.log('[Naki Action] Naki sent:', opType, 'combIdx:', combIdx);

                    const result = { success: true, opType: opType, combIdx: combIdx };

                    if (options.verify) {
                        result.verifyPromise = NakiCoordinator.verifyAction(actionName, options.verifyTimeout || 2000);
                    }

                    return result;
                } catch (e) {
                    return { success: false, error: e.message };
                }
            },

            /**
             * 智能執行：根據動作名稱自動選擇方法
             * @param {string} actionName - 動作名稱
             * @param {Object} params - 參數，可包含 verify, verifyTimeout, useBuiltin 等選項
             */
            execute: function(actionName, params = {}) {
                console.log('[Naki Action] Execute:', actionName, params);

                const options = {
                    verify: params.verify || false,
                    verifyTimeout: params.verifyTimeout,
                    useBuiltin: params.useBuiltin
                };

                switch (actionName.toLowerCase()) {
                    case 'discard':
                        return this.discard(params.tileIndex, options);
                    case 'pass':
                        return this.pass(options);
                    case 'chi':
                        return this.chi(params.combinationIndex || params.chiIndex || 0, options);
                    case 'pon':
                        return this.pon(options);
                    case 'kan':
                    case 'ankan':
                    case 'minkan':
                    case 'kakan':
                        return this.kan(options);
                    case 'hora':
                    case 'tsumo':
                    case 'ron':
                        return this.hora(options);
                    case 'riichi':
                        return this.riichi(params.tileIndex, options);
                    default:
                        return { success: false, error: 'unknown action: ' + actionName };
                }
            }
        },

        // ========================================
        // 大廳操作
        // ========================================
        lobby: {
            /**
             * 匹配模式定義
             */
            MATCH_MODES: {
                BRONZE_EAST: 1,    // 銅之間 東風
                BRONZE_SOUTH: 2,   // 銅之間 半莊
                SILVER_EAST: 4,    // 銀之間 東風
                SILVER_SOUTH: 5,   // 銀之間 半莊
                GOLD_EAST: 7,      // 金之間 東風
                GOLD_SOUTH: 8,     // 金之間 半莊
                JADE_EAST: 10,     // 玉之間 東風
                JADE_SOUTH: 11,    // 玉之間 半莊
                THRONE_EAST: 13,   // 王座之間 東風
                THRONE_SOUTH: 14   // 王座之間 半莊
            },

            /**
             * 獲取大廳狀態
             */
            getStatus: function() {
                const gm = NakiCoordinator.gm;
                if (!gm) return { available: false };

                return {
                    available: true,
                    account_id: gm.account_id,
                    nickname: gm.account_data?.nickname,
                    room_id: gm.room_id,
                    inMatch: gm.inMatch || false,
                    inGame: NakiCoordinator.state.isInGame()
                };
            },

            /**
             * 開始匹配
             */
            startMatch: function(matchMode) {
                const net = NakiCoordinator.net;
                if (!net) {
                    return { success: false, error: 'NetAgent not available' };
                }

                try {
                    net.sendReq2Lobby('Lobby', 'matchGame', {
                        match_mode: matchMode
                    }, function(err, res) {
                        if (err) {
                            console.error('[Naki Lobby] Match error:', err);
                        } else {
                            console.log('[Naki Lobby] Match started:', res);
                        }
                    });
                    console.log('[Naki Lobby] Match request sent, mode:', matchMode);
                    return { success: true, matchMode: matchMode };
                } catch (e) {
                    return { success: false, error: e.message };
                }
            },

            /**
             * 取消匹配
             */
            cancelMatch: function() {
                const net = NakiCoordinator.net;
                if (!net) {
                    return { success: false, error: 'NetAgent not available' };
                }

                try {
                    net.sendReq2Lobby('Lobby', 'cancelMatch', {}, function(err, res) {
                        if (err) {
                            console.error('[Naki Lobby] Cancel error:', err);
                        } else {
                            console.log('[Naki Lobby] Match cancelled:', res);
                        }
                    });
                    return { success: true };
                } catch (e) {
                    return { success: false, error: e.message };
                }
            },

            /**
             * 導航到指定頁面
             */
            navigate: function(pageIndex) {
                // 0=主頁, 1=段位場, 2=友人場, 3=比賽場
                const LobbyNetMgr = window.LobbyNetMgr;
                if (LobbyNetMgr && LobbyNetMgr.Inst) {
                    try {
                        // 使用 UI 導航
                        const uiLobby = window.uiscript?.UI_Lobby?.Inst;
                        if (uiLobby && typeof uiLobby.onClickFold === 'function') {
                            uiLobby.onClickFold(pageIndex);
                            return { success: true, page: pageIndex };
                        }
                    } catch (e) {
                        return { success: false, error: e.message };
                    }
                }
                return { success: false, error: 'LobbyNetMgr not available' };
            }
        },

        // ========================================
        // 心跳與防閒置
        // ========================================
        heartbeat: {
            /**
             * 發送心跳
             */
            send: function() {
                const gm = NakiCoordinator.gm;
                if (gm && typeof gm.clientHeatBeat === 'function') {
                    gm.clientHeatBeat();
                    console.log('[Naki Heartbeat] Sent');
                    return { success: true };
                }
                return { success: false, error: 'GameMgr not available' };
            },

            /**
             * 獲取閒置狀態
             */
            getIdleStatus: function() {
                const gm = NakiCoordinator.gm;
                if (!gm) return { available: false };

                const now = Date.now();
                const lastHeartbeat = gm._last_heatbeat_time || 0;
                const idleSeconds = lastHeartbeat > 0
                    ? Math.floor((now - lastHeartbeat) / 1000)
                    : -1;

                return {
                    available: true,
                    lastHeartbeat: lastHeartbeat,
                    idleSeconds: idleSeconds,
                    warningThreshold: 50 * 60  // 50 分鐘
                };
            },

            /**
             * 使用內建的 Anti-Idle 模組
             */
            getAntiIdleStatus: function() {
                if (window.__nakiAntiIdle) {
                    return window.__nakiAntiIdle.status();
                }
                return { available: false };
            },

            enableAntiIdle: function() {
                if (window.__nakiAntiIdle) {
                    return window.__nakiAntiIdle.enable();
                }
                return false;
            },

            disableAntiIdle: function() {
                if (window.__nakiAntiIdle) {
                    return window.__nakiAntiIdle.disable();
                }
                return false;
            }
        },

        // ========================================
        // 視覺效果控制
        // ========================================
        visual: {
            /**
             * 顯示推薦高亮
             */
            showRecommendation: function(tileIndex, probability) {
                if (window.__nakiRecommendHighlight) {
                    return window.__nakiRecommendHighlight.show(tileIndex, probability);
                }
                return false;
            },

            /**
             * 顯示多個推薦高亮
             */
            showMultipleRecommendations: function(recommendations) {
                if (window.__nakiRecommendHighlight) {
                    return window.__nakiRecommendHighlight.showMultiple(recommendations);
                }
                return 0;
            },

            /**
             * 隱藏所有推薦高亮
             */
            hideRecommendations: function() {
                if (window.__nakiRecommendHighlight) {
                    return window.__nakiRecommendHighlight.hide();
                }
                return false;
            },

            /**
             * 移動高亮到按鈕
             */
            highlightButton: function(actionType) {
                if (window.__nakiRecommendHighlight) {
                    return window.__nakiRecommendHighlight.moveNativeEffectToButton(actionType);
                }
                return false;
            },

            /**
             * 玩家名稱控制
             */
            playerNames: {
                hide: function() {
                    if (window.__nakiPlayerNames) {
                        return window.__nakiPlayerNames.hide();
                    }
                    return false;
                },
                show: function() {
                    if (window.__nakiPlayerNames) {
                        return window.__nakiPlayerNames.show();
                    }
                    return false;
                },
                toggle: function() {
                    if (window.__nakiPlayerNames) {
                        return window.__nakiPlayerNames.toggle();
                    }
                    return false;
                },
                getStatus: function() {
                    if (window.__nakiPlayerNames) {
                        return window.__nakiPlayerNames.getStatus();
                    }
                    return { available: false };
                }
            }
        },

        // ========================================
        // 網路操作
        // ========================================
        network: {
            /**
             * 發送遊戲請求
             */
            sendToGame: function(service, method, data, callback) {
                const net = NakiCoordinator.net;
                if (!net) {
                    if (callback) callback('NetAgent not available', null);
                    return false;
                }

                try {
                    net.sendReq2MJ(service, method, data, callback);
                    return true;
                } catch (e) {
                    if (callback) callback(e.message, null);
                    return false;
                }
            },

            /**
             * 發送大廳請求
             */
            sendToLobby: function(service, method, data, callback) {
                const net = NakiCoordinator.net;
                if (!net) {
                    if (callback) callback('NetAgent not available', null);
                    return false;
                }

                try {
                    net.sendReq2Lobby(service, method, data, callback);
                    return true;
                } catch (e) {
                    if (callback) callback(e.message, null);
                    return false;
                }
            },

            /**
             * 強制重連
             */
            forceReconnect: function() {
                if (window.__nakiWebSocket) {
                    return window.__nakiWebSocket.forceReconnect();
                }
                return 0;
            },

            /**
             * 獲取 WebSocket 連接狀態
             */
            getConnections: function() {
                if (window.__nakiWebSocket) {
                    return window.__nakiWebSocket.getConnections();
                }
                return [];
            }
        },

        // ========================================
        // 遊戲同步
        // ========================================
        sync: {
            /**
             * 嘗試同步遊戲狀態
             */
            trySync: function() {
                const dm = NakiCoordinator.dm;
                if (dm && typeof dm.trySyncGame === 'function') {
                    dm.trySyncGame();
                    console.log('[Naki Sync] trySyncGame called');
                    return { success: true };
                }
                return { success: false, error: 'trySyncGame not available' };
            },

            /**
             * 重置遊戲狀態
             */
            reset: function() {
                const dm = NakiCoordinator.dm;
                if (dm && typeof dm.Reset === 'function') {
                    dm.Reset();
                    console.log('[Naki Sync] Reset called');
                    return { success: true };
                }
                return { success: false, error: 'Reset not available' };
            }
        },

        // ========================================
        // 表情系統
        // ========================================
        emoji: {
            /**
             * 發送表情
             */
            send: function(emoId, count) {
                const net = NakiCoordinator.net;
                if (!net) {
                    return { success: false, error: 'NetAgent not available' };
                }

                const sendCount = Math.min(Math.max(count || 1, 1), 5);

                for (let i = 0; i < sendCount; i++) {
                    setTimeout(() => {
                        net.sendReq2MJ('FastTest', 'inputGameGMCommand', {
                            content: JSON.stringify({ emo: emoId })
                        });
                    }, i * 100);
                }

                console.log('[Naki Emoji] Sent:', emoId, 'x', sendCount);
                return { success: true, emoId: emoId, count: sendCount };
            },

            /**
             * 獲取可用表情列表
             */
            getList: function() {
                const gm = NakiCoordinator.gm;
                if (!gm || !gm.account_data) {
                    return { available: false };
                }

                const characterId = gm.account_data.character_id || 200001;
                const emojiCount = 9;

                return {
                    available: true,
                    characterId: characterId,
                    count: emojiCount,
                    emojis: Array.from({ length: emojiCount }, (_, i) => ({
                        id: i,
                        description: `表情 ${i + 1}`
                    }))
                };
            }
        },

        // ========================================
        // 工具方法
        // ========================================
        utils: {
            /**
             * MJAI 牌名轉 Majsoul 格式
             */
            mjaiToMajsoul: function(mjaiTile) {
                // 處理數牌 (1m-9m, 1p-9p, 1s-9s)
                const match = mjaiTile.match(/^(\d)([mps])(r)?$/);
                if (match) {
                    const num = parseInt(match[1]);
                    const suit = match[2];
                    const isRed = match[3] === 'r';

                    const typeMap = { m: 1, p: 0, s: 2 };
                    return {
                        type: typeMap[suit],
                        index: num,
                        dora: isRed && num === 5
                    };
                }

                // 處理字牌 (E, S, W, N, P, F, C)
                const honorMap = {
                    'E': { type: 3, index: 1 },  // 東
                    'S': { type: 3, index: 2 },  // 南
                    'W': { type: 3, index: 3 },  // 西
                    'N': { type: 3, index: 4 },  // 北
                    'P': { type: 3, index: 5 },  // 白
                    'F': { type: 3, index: 6 },  // 發
                    'C': { type: 3, index: 7 }   // 中
                };

                if (honorMap[mjaiTile]) {
                    return { ...honorMap[mjaiTile], dora: false };
                }

                return null;
            },

            /**
             * Majsoul 格式轉 MJAI 牌名
             */
            majsoulToMjai: function(type, index, dora) {
                if (type === 3) {
                    // 字牌
                    const honors = ['?', 'E', 'S', 'W', 'N', 'P', 'F', 'C'];
                    return honors[index] || '?';
                }

                // 數牌
                const suits = ['p', 'm', 's'];
                const suit = suits[type] || '?';
                const red = (dora && index === 5) ? 'r' : '';
                return `${index}${suit}${red}`;
            },

            /**
             * 在手牌中查找指定牌
             */
            findTileInHand: function(mjaiTile) {
                const mr = NakiCoordinator.mr;
                if (!mr || !mr.hand) return -1;

                const target = this.mjaiToMajsoul(mjaiTile);
                if (!target) return -1;

                for (let i = 0; i < mr.hand.length; i++) {
                    const tile = mr.hand[i];
                    if (!tile || !tile.val) continue;

                    const typeMatch = tile.val.type === target.type;
                    const indexMatch = tile.val.index === target.index;
                    const doraMatch = !target.dora || tile.val.dora === target.dora;

                    if (typeMatch && indexMatch && doraMatch) {
                        return i;
                    }
                }

                return -1;
            }
        },

        // ========================================
        // 診斷與調試
        // ========================================
        debug: {
            /**
             * 獲取完整診斷資訊
             */
            getDiagnostics: function() {
                return {
                    coordinator: {
                        version: NakiCoordinator.version,
                        loaded: true
                    },
                    managers: {
                        dm: !!NakiCoordinator.dm,
                        mr: !!NakiCoordinator.mr,
                        gm: !!NakiCoordinator.gm,
                        net: !!NakiCoordinator.net
                    },
                    modules: {
                        core: !!window.__nakiCoreLoaded,
                        websocket: !!window.__nakiWebSocketLoaded,
                        gameApi: !!window.__nakiGameAPI,
                        autoPlay: !!window.__nakiAutoPlay,
                        antiIdle: !!window.__nakiAntiIdle,
                        highlight: !!window.__nakiRecommendHighlight,
                        playerNames: !!window.__nakiPlayerNames
                    },
                    state: NakiCoordinator.state.getFullState(),
                    auto: NakiCoordinator.auto.getSettings(),
                    heartbeat: NakiCoordinator.heartbeat.getIdleStatus(),
                    lastAction: NakiCoordinator.getLastAction()
                };
            },

            /**
             * 獲取上次動作資訊
             */
            getLastAction: function() {
                return NakiCoordinator.getLastAction();
            },

            /**
             * 執行動作並驗證結果 (高階 API)
             * @param {string} actionType - 動作類型
             * @param {Object} params - 動作參數
             * @returns {Promise<{success: boolean, verified: boolean}>}
             */
            executeAndVerify: async function(actionType, params = {}) {
                const result = NakiCoordinator.action.execute(actionType, { ...params, verify: true });

                if (!result.success) {
                    return { success: false, verified: false, error: result.error };
                }

                if (result.verifyPromise) {
                    const verification = await result.verifyPromise;
                    return {
                        success: true,
                        verified: verification.verified,
                        reason: verification.reason,
                        elapsed: verification.elapsed
                    };
                }

                return { success: true, verified: false, reason: 'no verification' };
            },

            /**
             * 列出所有可用方法
             */
            listMethods: function() {
                const methods = [];

                const explore = (obj, prefix) => {
                    for (const key of Object.keys(obj)) {
                        const val = obj[key];
                        const path = prefix ? `${prefix}.${key}` : key;

                        if (typeof val === 'function') {
                            methods.push(path + '()');
                        } else if (typeof val === 'object' && val !== null && !Array.isArray(val)) {
                            explore(val, path);
                        }
                    }
                };

                explore(NakiCoordinator, 'NakiCoordinator');
                return methods.sort();
            }
        }
    };

    // ========================================
    // 快捷別名
    // ========================================
    window.naki = window.NakiCoordinator;

    console.log('[Naki Coordinator] v' + window.NakiCoordinator.version + ' loaded');
    console.log('[Naki Coordinator] Use NakiCoordinator.debug.getDiagnostics() for status');
    console.log('[Naki Coordinator] Use NakiCoordinator.debug.listMethods() for available methods');

})();
