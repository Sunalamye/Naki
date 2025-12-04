/**
 * Naki Game API - 遊戲 API 模組
 * 提供遊戲狀態查詢、打牌、副露等遊戲操作
 */
(function() {
    'use strict';

    // ========================================
    // 遊戲 API 探測
    // ========================================

    /**
     * 探測遊戲引擎和可用 API
     */
    window.__nakiDetectGameAPI = function() {
        const results = {
            engine: 'unknown',
            availableAPIs: [],
            gameObjects: []
        };

        // 檢測常見遊戲引擎
        if (window.cc) {
            results.engine = 'Cocos2d';
            results.availableAPIs.push('cc (Cocos2d)');

            if (cc.director) {
                results.availableAPIs.push('cc.director');
                const scene = cc.director.getScene();
                if (scene) {
                    results.gameObjects.push('scene: ' + scene.name);
                }
            }
        }

        if (window.game) results.gameObjects.push('game');
        if (window.GameMgr) results.gameObjects.push('GameMgr');
        if (window.MJ) results.gameObjects.push('MJ');
        if (window.uiscript) results.gameObjects.push('uiscript');
        if (window.view) results.gameObjects.push('view');
        if (window.mjcore) results.gameObjects.push('mjcore');

        // 搜索 window 上的遊戲相關物件
        for (const key of Object.keys(window)) {
            if (key.toLowerCase().includes('game') ||
                key.toLowerCase().includes('mj') ||
                key.toLowerCase().includes('tile') ||
                key.toLowerCase().includes('hand')) {
                if (!results.gameObjects.includes(key)) {
                    results.gameObjects.push(key);
                }
            }
        }

        console.log('[Naki] Game API Detection:', JSON.stringify(results, null, 2));
        return results;
    };

    /**
     * 深度探測 - 探索 uiscript、view、GameMgr 的結構
     */
    window.__nakiExploreGameObjects = function() {
        const explore = (obj, name, depth = 0) => {
            if (depth > 2 || !obj) return {};
            const result = {};
            try {
                const keys = Object.keys(obj).slice(0, 30);
                for (const key of keys) {
                    try {
                        const val = obj[key];
                        const type = typeof val;
                        if (type === 'function') {
                            result[key] = 'function()';
                        } else if (type === 'object' && val !== null) {
                            result[key] = '{...}';
                        } else {
                            result[key] = String(val).substring(0, 50);
                        }
                    } catch (e) {
                        result[key] = '[error]';
                    }
                }
            } catch (e) {}
            return result;
        };

        const results = {};

        if (window.view) {
            results.view = explore(window.view, 'view');
            if (window.view.DesktopMgr) {
                results['view.DesktopMgr'] = explore(window.view.DesktopMgr, 'DesktopMgr');
            }
        }

        if (window.uiscript) {
            results.uiscript = explore(window.uiscript, 'uiscript');
            for (const key of Object.keys(window.uiscript)) {
                if (key.includes('Desktop') || key.includes('Hand') || key.includes('Tile')) {
                    results['uiscript.' + key] = explore(window.uiscript[key], key);
                }
            }
        }

        if (window.GameMgr) {
            results.GameMgr = explore(window.GameMgr, 'GameMgr');
            if (window.GameMgr.Inst) {
                results['GameMgr.Inst'] = explore(window.GameMgr.Inst, 'GameMgr.Inst');
            }
        }

        if (window.mjcore) {
            results.mjcore = explore(window.mjcore, 'mjcore');
        }

        console.log('[Naki] Game Objects Exploration:', JSON.stringify(results, null, 2));
        return results;
    };

    /**
     * 嘗試找到手牌座標
     */
    window.__nakiFindHandTiles = function() {
        const results = { found: false, info: [] };

        try {
            if (window.view && window.view.DesktopMgr && window.view.DesktopMgr.Inst) {
                const dm = window.view.DesktopMgr.Inst;
                results.info.push('Found DesktopMgr.Inst');

                if (dm.players) {
                    results.info.push('Found players: ' + dm.players.length);
                }
                if (dm.seat) {
                    results.info.push('My seat: ' + dm.seat);
                }
                if (dm.hand) {
                    results.info.push('Found hand object');
                    results.hand = Object.keys(dm.hand).slice(0, 20);
                }
            }

            if (window.uiscript && window.uiscript.UI_DesktopInfo) {
                const info = window.uiscript.UI_DesktopInfo;
                results.info.push('Found UI_DesktopInfo');
                if (info.Inst) {
                    results.info.push('Found UI_DesktopInfo.Inst');
                }
            }
        } catch (e) {
            results.error = e.message;
        }

        console.log('[Naki] Hand Tiles Search:', JSON.stringify(results, null, 2));
        return results;
    };

    // ========================================
    // 遊戲 API 模組
    // ========================================

    window.__nakiGameAPI = {
        /**
         * 檢查遊戲 API 是否可用
         */
        isAvailable: function() {
            return !!(window.view && window.view.DesktopMgr && window.view.DesktopMgr.Inst);
        },

        /**
         * 獲取遊戲狀態
         */
        getGameState: function() {
            if (!this.isAvailable()) return null;
            const dm = window.view.DesktopMgr.Inst;
            return {
                seat: dm.seat,
                gamestate: dm.gamestate,
                oplist: dm.oplist ? dm.oplist.map(o => o.type) : [],
                choosed_pai: !!dm.choosed_pai
            };
        },

        /**
         * 獲取手牌信息
         */
        getHandInfo: function() {
            if (!this.isAvailable()) return null;
            const mr = window.view.DesktopMgr.Inst.mainrole;
            if (!mr || !mr.hand) return null;

            const hand = mr.hand;
            return {
                count: hand.length,
                tiles: hand.map((t, i) => ({
                    index: i,
                    type: t.val.type,
                    value: t.val.index,
                    dora: t.val.dora
                }))
            };
        },

        /**
         * 獲取當前可用操作
         */
        getAvailableOps: function() {
            if (!this.isAvailable()) return [];
            const dm = window.view.DesktopMgr.Inst;
            if (!dm.oplist) return [];

            const opNames = {
                0: 'none', 1: 'dapai', 2: 'chi', 3: 'pon',
                4: 'ankan', 5: 'minkan', 6: 'kakan', 7: 'riichi',
                8: 'tsumo', 9: 'ron', 10: 'kyushu', 11: 'babei'
            };

            return dm.oplist.map(o => ({
                type: o.type,
                name: opNames[o.type] || 'unknown',
                combination: o.combination || []
            }));
        },

        /**
         * 探索操作相關的 API
         */
        exploreOperationAPI: function() {
            try {
                const dm = window.view.DesktopMgr.Inst;
                const mr = dm.mainrole;

                const result = {
                    oplist: dm.oplist ? dm.oplist.map(o => ({
                        type: o.type,
                        combination: o.combination || [],
                        timeoutMs: o.timeoutMs
                    })) : [],
                    choosed_op: dm.choosed_op,
                    choosed_pai: dm.choosed_pai ? {
                        type: dm.choosed_pai.val?.type,
                        index: dm.choosed_pai.val?.index
                    } : null,
                    mainroleMethods: Object.keys(mr).filter(k =>
                        typeof mr[k] === 'function' &&
                        (k.includes('Op') || k.includes('Qi') || k.includes('Do') || k.includes('Chi') || k.includes('Pon'))
                    ),
                    dmMethods: Object.keys(dm).filter(k =>
                        typeof dm[k] === 'function' &&
                        (k.includes('Op') || k.includes('Qi') || k.includes('Do') || k.includes('choose'))
                    )
                };

                console.log('[Naki API] Operation API:', JSON.stringify(result, null, 2));
                return result;
            } catch (e) {
                console.error('[Naki API] exploreOperationAPI error:', e);
                return { error: e.message };
            }
        },

        /**
         * 深度探索副露 API
         */
        deepExploreNaki: function() {
            try {
                const dm = window.view.DesktopMgr.Inst;
                const mr = dm.mainrole;

                const opNames = {
                    0: 'none', 1: 'dapai', 2: 'chi', 3: 'pon',
                    4: 'ankan', 5: 'minkan', 6: 'kakan', 7: 'riichi',
                    8: 'tsumo', 9: 'ron', 10: 'kyushu', 11: 'babei'
                };

                const result = {
                    oplist: dm.oplist ? dm.oplist.map((o, idx) => ({
                        index: idx,
                        type: o.type,
                        typeName: opNames[o.type] || 'unknown',
                        combination: o.combination || [],
                        timeoutMs: o.timeoutMs,
                        allKeys: Object.keys(o)
                    })) : [],
                    dmState: {
                        choosed_op: dm.choosed_op,
                        gamestate: dm.gamestate,
                        seat: dm.seat,
                        opRelatedProps: Object.keys(dm).filter(k =>
                            k.toLowerCase().includes('op') ||
                            k.toLowerCase().includes('choose') ||
                            k.toLowerCase().includes('action')
                        )
                    },
                    mainroleMethods: Object.keys(mr).filter(k => typeof mr[k] === 'function').sort(),
                    mainroleProps: Object.keys(mr).filter(k => typeof mr[k] !== 'function').slice(0, 50),
                    dmMethods: Object.keys(dm).filter(k => typeof dm[k] === 'function').sort(),
                    uiManagers: Object.keys(window.view || {}).filter(k =>
                        k.includes('Button') || k.includes('Action') || k.includes('Operation')
                    )
                };

                console.log('[Naki Deep] Full exploration:', JSON.stringify(result, null, 2));
                return result;
            } catch (e) {
                console.error('[Naki Deep] Error:', e);
                return { error: e.message };
            }
        },

        // ========================================
        // 遊戲操作
        // ========================================

        /**
         * 直接選擇手牌
         */
        selectTile: function(tileIndex) {
            try {
                const mr = window.view.DesktopMgr.Inst.mainrole;
                if (!mr || !mr.hand || tileIndex >= mr.hand.length) {
                    console.error('[Naki API] Invalid tile index:', tileIndex);
                    return false;
                }

                const tile = mr.hand[tileIndex];
                console.log('[Naki API] Selecting tile:', tileIndex, tile.val);
                mr.setChoosePai(tile, true);
                return true;
            } catch (e) {
                console.error('[Naki API] selectTile error:', e);
                return false;
            }
        },

        /**
         * 直接打牌 (不需要座標)
         */
        discardTile: function(tileIndex) {
            try {
                const mr = window.view.DesktopMgr.Inst.mainrole;
                if (!mr || !mr.hand) {
                    console.error('[Naki API] mainrole.hand not available');
                    return false;
                }

                const actualIndex = Math.min(tileIndex, mr.hand.length - 1);
                const tile = mr.hand[actualIndex];

                if (!tile) {
                    console.error('[Naki API] Tile not found at index:', actualIndex);
                    return false;
                }

                console.log('[Naki API] Discarding tile:', actualIndex, 'val:', tile.val);
                mr.setChoosePai(tile, true);
                mr.DoDiscardTile();
                console.log('[Naki API] DoDiscardTile called');

                return true;
            } catch (e) {
                console.error('[Naki API] discardTile error:', e);
                return false;
            }
        },

        /**
         * 執行跳過操作 - 使用 cancel_operation API
         */
        pass: function() {
            try {
                const dm = window.view.DesktopMgr.Inst;
                if (!dm) {
                    console.error('[Naki API] No DesktopMgr');
                    return false;
                }

                console.log('[Naki API] Pass check - oplist:', dm.oplist ? dm.oplist.map(o => o.type) : 'none');

                // 使用 NetAgent cancel_operation
                if (window.app && window.app.NetAgent) {
                    window.app.NetAgent.sendReq2MJ('FastTest', 'inputOperation', {
                        cancel_operation: true,
                        timeuse: 1
                    });
                    console.log('[Naki API] Sent pass via cancel_operation');
                    return 1;
                }

                console.error('[Naki API] NetAgent not available');
                return false;
            } catch (e) {
                console.error('[Naki API] pass error:', e.message);
                return false;
            }
        },

        /**
         * 執行副露操作 (吃/碰/槓/和/立直) - 使用 NetAgent API
         */
        executeOperation: function(opType, combinationIndex = 0) {
            try {
                const dm = window.view.DesktopMgr.Inst;

                if (!dm.oplist || dm.oplist.length === 0) {
                    console.error('[Naki API] No operations available');
                    return false;
                }

                if (!window.app || !window.app.NetAgent) {
                    console.error('[Naki API] NetAgent not available');
                    return false;
                }

                // 自摸/榮和 (type 8/9) 優先處理
                if (opType === 8 || opType === 9) {
                    const horaOp = dm.oplist.find(o => o.type === 8 || o.type === 9);
                    if (!horaOp) {
                        console.error('[Naki API] No hora operation in oplist');
                        console.log('[Naki API] Available ops:', dm.oplist.map(o => o.type));
                        return false;
                    }
                    const actualType = horaOp.type;
                    window.app.NetAgent.sendReq2MJ('FastTest', 'inputOperation', {
                        type: actualType,
                        timeuse: 1
                    });
                    console.log('[Naki API] Sent hora:', { type: actualType, typeName: actualType === 8 ? 'tsumo' : 'ron' });
                    return true;
                }

                // 找到對應的操作
                const opIndex = dm.oplist.findIndex(o => o.type === opType);
                if (opIndex < 0) {
                    console.error('[Naki API] Operation type not available:', opType);
                    console.log('[Naki API] Available ops:', dm.oplist.map(o => ({type: o.type, comb: o.combination})));
                    return false;
                }

                const op = dm.oplist[opIndex];
                console.log('[Naki API] Found operation:', opType, 'at index', opIndex, 'combination:', op.combination);

                // 立直 (type 7) 使用 inputOperation
                if (opType === 7) {
                    const tile = op.combination && op.combination[0] ? op.combination[0] : null;
                    if (!tile) {
                        console.error('[Naki API] Riichi: no tile specified');
                        return false;
                    }
                    const mr = dm.mainrole;
                    const isMoqie = mr.hand && mr.hand.length === 14;

                    window.app.NetAgent.sendReq2MJ('FastTest', 'inputOperation', {
                        type: 7,
                        tile: tile,
                        moqie: isMoqie,
                        timeuse: 1
                    });
                    console.log('[Naki API] Sent riichi:', { tile, moqie: isMoqie });
                    return true;
                }

                // 吃/碰/槓 (type 2/3/4/5/6) 使用 inputChiPengGang
                let combIdx = 0;
                if (op.combination && op.combination.length > 0) {
                    combIdx = Math.min(combinationIndex, op.combination.length - 1);
                    console.log('[Naki API] Combination index:', combIdx, 'of', op.combination.length);
                }

                window.app.NetAgent.sendReq2MJ('FastTest', 'inputChiPengGang', {
                    type: opType,
                    index: combIdx,
                    timeuse: 1
                });
                console.log('[Naki API] Sent inputChiPengGang:', { type: opType, index: combIdx });
                return true;
            } catch (e) {
                console.error('[Naki API] executeOperation error:', e);
                return false;
            }
        },

        /**
         * 直接執行操作 (舊方法，保留相容性)
         */
        executeOp: function(opType) {
            return this.executeOperation(opType);
        },

        /**
         * 使用遊戲內部資訊計算牌的螢幕座標
         */
        getTileScreenPosition: function(tileIndex) {
            try {
                const mr = window.view.DesktopMgr.Inst.mainrole;
                if (!mr || !mr.hand) return null;

                const actualIndex = Math.min(tileIndex, mr.hand.length - 1);
                const tile = mr.hand[actualIndex];
                if (!tile || !tile.mySelf || !tile.mySelf.transform) return null;

                const pos3d = tile.mySelf.transform.position;
                if (!pos3d) return null;

                const canvas = document.querySelector('canvas');
                if (!canvas) return null;

                const rect = canvas.getBoundingClientRect();
                const scaleX = rect.width / 1920;
                const scaleY = rect.height / 1080;

                const screenCenterX = 960;
                const scale3dToScreen = 80;
                const screenX = screenCenterX - (pos3d.x - 2) * scale3dToScreen;
                const screenY = 980;

                console.log('[Naki API] Tile', tileIndex, '3D pos:', pos3d.x.toFixed(2), '→ screen:', Math.round(screenX));

                return {
                    x: screenX * scaleX,
                    y: screenY * scaleY,
                    raw3d: { x: pos3d.x, y: pos3d.y, z: pos3d.z }
                };
            } catch (e) {
                console.error('[Naki API] getTileScreenPosition error:', e);
                return null;
            }
        },

        /**
         * 使用計算座標點擊牌（備用方案）
         */
        clickTileByPosition: function(tileIndex) {
            const pos = this.getTileScreenPosition(tileIndex);
            if (!pos) {
                console.error('[Naki API] Cannot get tile position for index:', tileIndex);
                return false;
            }

            console.log('[Naki API] Clicking tile by position:', tileIndex, 'at', pos.x.toFixed(0), pos.y.toFixed(0));

            window.__nakiAutoPlay.click(pos.x, pos.y, '牌 #' + (tileIndex + 1));
            setTimeout(() => {
                window.__nakiAutoPlay.click(pos.x, pos.y, '確認');
            }, 300);

            return true;
        },

        /**
         * 智能執行動作 (先嘗試直接 API，失敗則使用座標點擊)
         */
        smartExecute: function(actionType, params) {
            console.log('[Naki API] Smart execute:', actionType, JSON.stringify(params));

            const opTypeMap = {
                'chi': 2,
                'pon': 3,
                'ankan': 4,
                'minkan': 5,
                'kan': 5,
                'kakan': 6,
                'riichi': 7,
                'tsumo': 8,
                'ron': 9,
                'hora': -1,
                'kyushu': 10
            };

            const gameState = this.getGameState();
            console.log('[Naki API] Game state:', JSON.stringify(gameState));

            let success = false;

            try {
                if (this.isAvailable()) {
                    switch (actionType) {
                        case 'discard':
                            success = this.discardTile(params.tileIndex);
                            if (success) {
                                console.log('[Naki API] Discard via direct API');
                                return true;
                            }
                            break;

                        case 'pass':
                            console.log('[Naki API] Attempting pass...');
                            success = this.pass();
                            console.log('[Naki API] Pass result:', success);
                            if (success) {
                                console.log('[Naki API] Pass via direct API');
                                return true;
                            }
                            break;

                        case 'chi':
                            const chiOpType = opTypeMap['chi'];
                            const chiIndex = params.chiIndex || 0;
                            console.log('[Naki API] Attempting chi, opType:', chiOpType, 'chiIndex:', chiIndex);
                            if (chiOpType !== undefined) {
                                success = this.executeOperation(chiOpType, chiIndex);
                                console.log('[Naki API] chi result:', success);
                                if (success) {
                                    console.log('[Naki API] chi via direct API');
                                    return true;
                                }
                            }
                            break;

                        case 'hora':
                            const dm2 = window.view.DesktopMgr.Inst;
                            console.log('[Naki API] hora: dm2=', !!dm2, 'oplist=', dm2?.oplist?.map(o => o.type));
                            if (dm2 && dm2.oplist && dm2.oplist.length > 0) {
                                const horaOp = dm2.oplist.find(o => o.type === 8 || o.type === 9);
                                console.log('[Naki API] hora: found horaOp=', horaOp?.type);
                                if (horaOp) {
                                    const horaType = horaOp.type;
                                    console.log('[Naki API] Detected hora type:', horaType, horaType === 8 ? 'tsumo' : 'ron');
                                    success = this.executeOperation(horaType);
                                    console.log('[Naki API] hora executeOperation result:', success);
                                    if (success) return {executed: true, type: horaType};
                                } else {
                                    console.log('[Naki API] No hora operation in oplist, types:', dm2.oplist.map(o => o.type));
                                    return {executed: false, fallback: 'clicking', types: dm2.oplist.map(o => o.type)};
                                }
                            } else {
                                console.log('[Naki API] hora: no oplist available');
                                return {executed: false, error: 'no oplist'};
                            }
                            break;

                        case 'pon':
                        case 'kan':
                        case 'ankan':
                        case 'minkan':
                        case 'kakan':
                        case 'tsumo':
                        case 'ron':
                        case 'kyushu':
                            const opType = opTypeMap[actionType];
                            console.log('[Naki API] Attempting', actionType, 'opType:', opType);
                            if (opType !== undefined) {
                                success = this.executeOperation(opType);
                                console.log('[Naki API]', actionType, 'result:', success);
                                if (success) {
                                    console.log('[Naki API]', actionType, 'via direct API');
                                    return true;
                                }
                            }
                            break;

                        case 'riichi':
                            // 立直需要選擇打哪張牌，先不處理
                            break;
                    }
                } else {
                    console.log('[Naki API] Game API not available');
                }
            } catch (e) {
                console.log('[Naki API] Direct API failed:', e.message);
            }

            // 備用方案 1：使用遊戲內部座標計算點擊位置
            if (actionType === 'discard' && params.tileIndex !== undefined) {
                console.log('[Naki API] Trying position-based click for discard');
                success = this.clickTileByPosition(params.tileIndex);
                if (success) {
                    console.log('[Naki API] Discard via position-based click');
                    return true;
                }
            }

            // 備用方案 2：使用校準座標點擊
            console.log('[Naki API] Fallback to UI automation for:', actionType);
            try {
                const result = window.__nakiAutoPlay.executeAction(actionType, params);
                console.log('[Naki API] UI automation result:', result);
                return result;
            } catch (e) {
                console.error('[Naki API] UI automation failed:', e.message);
                return false;
            }
        },

        // ========================================
        // 測試函數
        // ========================================

        /**
         * 嘗試執行吃操作（測試用）
         */
        testChi: function(combIndex = 0) {
            try {
                const dm = window.view.DesktopMgr.Inst;
                const mr = dm.mainrole;

                console.log('[Naki Test] Testing Chi...');
                console.log('[Naki Test] oplist:', JSON.stringify(dm.oplist));

                const chiOp = dm.oplist?.find(o => o.type === 2);
                if (!chiOp) {
                    return { success: false, error: 'No chi operation available' };
                }

                const chiIndex = dm.oplist.findIndex(o => o.type === 2);
                console.log('[Naki Test] Chi found at index:', chiIndex, 'combinations:', chiOp.combination);

                dm.choosed_op = chiIndex;

                if (chiOp.combination && chiOp.combination.length > 1) {
                    console.log('[Naki Test] Multiple combinations, selecting:', combIndex);
                    if (dm.choosed_op_combine !== undefined) {
                        dm.choosed_op_combine = combIndex;
                    }
                }

                const results = [];

                if (typeof mr.DoOperation === 'function') {
                    try {
                        mr.DoOperation(chiIndex);
                        results.push({ method: 'DoOperation', called: true });
                    } catch (e) {
                        results.push({ method: 'DoOperation', error: e.message });
                    }
                }

                if (typeof mr.QiPaiNoPass === 'function' && results.length === 0) {
                    try {
                        mr.QiPaiNoPass();
                        results.push({ method: 'QiPaiNoPass', called: true });
                    } catch (e) {
                        results.push({ method: 'QiPaiNoPass', error: e.message });
                    }
                }

                const chiMethods = Object.keys(mr).filter(k =>
                    typeof mr[k] === 'function' &&
                    (k.toLowerCase().includes('chi') || k.toLowerCase().includes('eat'))
                );
                results.push({ availableChiMethods: chiMethods });

                return { success: results.length > 0, results };
            } catch (e) {
                return { success: false, error: e.message };
            }
        },

        /**
         * 嘗試執行碰操作（測試用）
         */
        testPon: function() {
            try {
                const dm = window.view.DesktopMgr.Inst;
                const mr = dm.mainrole;

                console.log('[Naki Test] Testing Pon...');

                const ponOp = dm.oplist?.find(o => o.type === 3);
                if (!ponOp) {
                    return { success: false, error: 'No pon operation available' };
                }

                const ponIndex = dm.oplist.findIndex(o => o.type === 3);
                console.log('[Naki Test] Pon found at index:', ponIndex);

                dm.choosed_op = ponIndex;

                const results = [];

                if (typeof mr.DoOperation === 'function') {
                    try {
                        mr.DoOperation(ponIndex);
                        results.push({ method: 'DoOperation', called: true });
                    } catch (e) {
                        results.push({ method: 'DoOperation', error: e.message });
                    }
                }

                if (typeof mr.QiPaiNoPass === 'function' && results.length === 0) {
                    try {
                        mr.QiPaiNoPass();
                        results.push({ method: 'QiPaiNoPass', called: true });
                    } catch (e) {
                        results.push({ method: 'QiPaiNoPass', error: e.message });
                    }
                }

                const ponMethods = Object.keys(mr).filter(k =>
                    typeof mr[k] === 'function' &&
                    (k.toLowerCase().includes('pon') || k.toLowerCase().includes('peng'))
                );
                results.push({ availablePonMethods: ponMethods });

                return { success: results.length > 0, results };
            } catch (e) {
                return { success: false, error: e.message };
            }
        }
    };

    // ========================================
    // 🎯 Dora Shimmer Effect 追踪 Hook
    // ========================================
    /**
     * 拦截 effect_dora3D.visible 的修改
     * 用于追踪游戏何时调用原生闪光效果
     */
    window.__nakiDoraHook = {
        hooked: false,
        callHistory: [],
        maxHistory: 100,

        /**
         * 启动 Hook - 拦截 effect_dora3D.visible 的 set/get
         */
        hook: function() {
            try {
                const inst = window.view?.DesktopMgr?.Inst;
                if (!inst || !inst.effect_dora3D) {
                    console.log('[Naki Dora Hook] DesktopMgr or effect_dora3D not available yet');
                    return false;
                }

                const effect = inst.effect_dora3D;
                let _visible = effect.visible;

                Object.defineProperty(effect, 'visible', {
                    get() {
                        return _visible;
                    },
                    set(val) {
                        const timestamp = new Date().toISOString();
                        const stack = new Error().stack;
                        const caller = stack?.split('\n')[2]?.trim() || 'unknown';

                        const entry = {
                            timestamp,
                            value: val,
                            caller,
                            alpha: effect.alpha
                        };

                        this.callHistory.push(entry);
                        if (this.callHistory.length > this.maxHistory) {
                            this.callHistory.shift();
                        }

                        console.log(`[Naki Dora Hook] effect_dora3D.visible set to: ${val}`, {
                            timestamp,
                            alpha: effect.alpha,
                            caller
                        });

                        _visible = val;
                    }
                });

                this.hooked = true;
                console.log('[Naki Dora Hook] Successfully hooked effect_dora3D.visible');
                return true;

            } catch (e) {
                console.error('[Naki Dora Hook] Failed to hook:', e.message);
                return false;
            }
        },

        /**
         * 获取调用历史
         */
        getHistory: function() {
            return {
                hooked: this.hooked,
                count: this.callHistory.length,
                history: this.callHistory
            };
        },

        /**
         * 清空历史
         */
        clearHistory: function() {
            this.callHistory = [];
            console.log('[Naki Dora Hook] History cleared');
        }
    };

    // ========================================
    // 高亮效果初始化 Hook
    // ========================================
    window.__nakiHighlightInit = {
        initialized: false,
        effectRef: null,

        /**
         * 初始化 effect_recommend 並儲存參考
         */
        init: function() {
            try {
                const inst = window.view?.DesktopMgr?.Inst;
                if (!inst || !inst.effect_recommend) {
                    console.log('[Naki Highlight Init] effect_recommend not available yet');
                    return false;
                }

                // 儲存參考
                this.effectRef = inst.effect_recommend;

                // 確保基本設置
                this.effectRef.active = true;

                this.initialized = true;
                console.log('[Naki Highlight Init] effect_recommend initialized successfully');
                return true;

            } catch (e) {
                console.error('[Naki Highlight Init] Failed to initialize:', e.message);
                return false;
            }
        },

        /**
         * 獲取高亮效果物件參考
         */
        getEffect: function() {
            return this.effectRef || window.view?.DesktopMgr?.Inst?.effect_recommend;
        }
    };

    // 尝试立即启动 Hook（如果游戏已经初始化）
    setTimeout(() => {
        if (window.__nakiDoraHook.hook()) {
            console.log('[Naki] Dora Hook initialized on game load');
        }
        if (window.__nakiHighlightInit.init()) {
            console.log('[Naki] Highlight Init hook completed');
        }
    }, 500);

    console.log('[Naki] Game API module loaded');
})();
