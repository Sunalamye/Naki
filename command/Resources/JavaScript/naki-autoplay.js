/**
 * Naki AutoPlay - UI 自動化模組
 * 提供點擊指示器、模擬滑鼠事件、手牌/按鈕點擊等功能
 */
(function() {
    'use strict';

    // 依賴 naki-core.js
    const sendToSwift = window.__nakiCore?.sendToSwift || window.__nakiSendToSwift || function() {};

    // ========================================
    // AutoPlay 模組
    // ========================================

    window.__nakiAutoPlay = {
        // 調試模式：顯示點擊位置
        debugMode: true,

        // 校準參數 (可透過 Swift 調整)
        calibration: {
            tileSpacing: 96,    // 手牌間距
            offsetX: -200,      // 水平偏移
            offsetY: 0          // 垂直偏移
        },

        // 基準座標 (1920x1080 參考)
        baseCoords: {
            tileBaseX: 460,     // 手牌起始 X
            tileBaseY: 980,     // 手牌 Y
            tsumoGap: 20        // 摸牌間隙
        },

        // 獲取遊戲 Canvas
        getCanvas: function() {
            return document.querySelector('canvas') || document.getElementById('canvas');
        },

        // ========================================
        // 點擊指示器
        // ========================================

        /**
         * 顯示點擊指示器
         */
        showClickIndicator: function(x, y, label) {
            console.log('[Naki] showClickIndicator called:', x, y, label);

            if (!this.debugMode) {
                console.log('[Naki] debugMode is off, skipping indicator');
                return;
            }

            const canvas = this.getCanvas();
            if (!canvas) {
                console.log('[Naki] No canvas found for indicator');
                return;
            }

            const rect = canvas.getBoundingClientRect();
            console.log('[Naki] Canvas rect:', rect.left, rect.top, rect.width, rect.height);

            const absoluteX = rect.left + x;
            const absoluteY = rect.top + y;
            console.log('[Naki] Creating indicator at absolute position:', absoluteX, absoluteY);

            // 創建點擊指示器容器
            const indicator = document.createElement('div');
            indicator.style.cssText = `
                position: fixed;
                left: ${absoluteX}px;
                top: ${absoluteY}px;
                transform: translate(-50%, -50%);
                pointer-events: none;
                z-index: 999999;
            `;

            // 創建十字準心
            const crosshair = document.createElement('div');
            crosshair.style.cssText = `
                position: absolute;
                left: 50%;
                top: 50%;
                transform: translate(-50%, -50%);
                width: 40px;
                height: 40px;
                border: 3px solid #ff0000;
                border-radius: 50%;
                background: rgba(255, 0, 0, 0.2);
                box-shadow: 0 0 10px rgba(255, 0, 0, 0.5);
            `;

            // 創建十字線 (水平)
            const lineH = document.createElement('div');
            lineH.style.cssText = `
                position: absolute;
                left: 50%;
                top: 50%;
                transform: translate(-50%, -50%);
                width: 60px;
                height: 2px;
                background: #ff0000;
            `;

            // 創建十字線 (垂直)
            const lineV = document.createElement('div');
            lineV.style.cssText = `
                position: absolute;
                left: 50%;
                top: 50%;
                transform: translate(-50%, -50%);
                width: 2px;
                height: 60px;
                background: #ff0000;
            `;

            // 創建標籤
            const labelDiv = document.createElement('div');
            labelDiv.style.cssText = `
                position: absolute;
                left: 50%;
                top: 45px;
                transform: translateX(-50%);
                background: rgba(255, 0, 0, 0.9);
                color: white;
                padding: 4px 10px;
                border-radius: 4px;
                font-size: 14px;
                font-weight: bold;
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                white-space: nowrap;
                box-shadow: 0 2px 8px rgba(0,0,0,0.3);
            `;
            labelDiv.textContent = label || `(${Math.round(x)}, ${Math.round(y)})`;

            // 組裝指示器
            indicator.appendChild(crosshair);
            indicator.appendChild(lineH);
            indicator.appendChild(lineV);
            indicator.appendChild(labelDiv);
            document.body.appendChild(indicator);
            console.log('[Naki] Indicator added to DOM:', indicator, 'at', absoluteX, absoluteY);

            // 動畫效果：放大後縮小消失
            indicator.animate([
                { opacity: 1, transform: 'translate(-50%, -50%) scale(1.2)' },
                { opacity: 1, transform: 'translate(-50%, -50%) scale(1)' },
                { opacity: 0.8, transform: 'translate(-50%, -50%) scale(1)' },
                { opacity: 0, transform: 'translate(-50%, -50%) scale(0.8)' }
            ], {
                duration: 1500,
                easing: 'ease-out'
            });

            // 1.5 秒後移除
            setTimeout(() => {
                indicator.remove();
            }, 1500);
        },

        // ========================================
        // 滑鼠事件模擬
        // ========================================

        /**
         * 模擬滑鼠事件
         */
        simulateMouseEvent: function(canvas, type, x, y) {
            const rect = canvas.getBoundingClientRect();
            const event = new MouseEvent(type, {
                bubbles: true,
                cancelable: true,
                view: window,
                clientX: rect.left + x,
                clientY: rect.top + y,
                button: 0
            });
            canvas.dispatchEvent(event);
        },

        /**
         * 模擬點擊
         */
        click: function(x, y, label) {
            const canvas = this.getCanvas();
            if (!canvas) {
                console.error('[Naki] Canvas not found');
                sendToSwift('autoplay_error', { error: 'Canvas not found' });
                return false;
            }

            // 顯示點擊指示器
            this.showClickIndicator(x, y, label);

            console.log('[Naki] Clicking at:', x, y);
            this.simulateMouseEvent(canvas, 'mousedown', x, y);
            setTimeout(() => {
                this.simulateMouseEvent(canvas, 'mouseup', x, y);
                this.simulateMouseEvent(canvas, 'click', x, y);
            }, 50);

            sendToSwift('autoplay_click', { x: x, y: y });
            return true;
        },

        // ========================================
        // 手牌點擊
        // ========================================

        /**
         * 點擊手牌 (根據索引)
         * @param {number} tileIndex - 手牌索引 (0-based)
         * @param {number} handCount - 實際手牌數 (副露後會減少，預設 13)
         */
        clickTile: function(tileIndex, handCount) {
            const canvas = this.getCanvas();
            if (!canvas) {
                sendToSwift('autoplay_error', { error: 'Canvas not found' });
                return false;
            }

            // 使用實際渲染大小，不是內部解析度
            const rect = canvas.getBoundingClientRect();
            const scaleX = rect.width / 1920;
            const scaleY = rect.height / 1080;

            // 使用校準參數 + 基準座標
            const cal = this.calibration;
            const base = this.baseCoords;
            const baseX = base.tileBaseX + cal.offsetX;
            const baseY = base.tileBaseY + cal.offsetY;
            const tileWidth = cal.tileSpacing;
            const tsumoGap = base.tsumoGap;

            // 實際手牌數 (未副露時為 13)
            const actualHandCount = handCount || 13;
            const isTsumo = tileIndex >= actualHandCount;

            let x, y, label;
            if (!isTsumo) {
                // 手牌
                x = (baseX + tileIndex * tileWidth) * scaleX;
                label = `手牌 #${tileIndex + 1}`;
            } else {
                // 摸牌 (在最後一張手牌後面)
                x = (baseX + actualHandCount * tileWidth + tsumoGap) * scaleX;
                label = '摸牌';
            }
            y = baseY * scaleY;

            console.log('[Naki] Clicking tile index:', tileIndex, 'handCount:', actualHandCount, 'isTsumo:', isTsumo, 'at', x, y);
            sendToSwift('autoplay_tile_click', { index: tileIndex, handCount: actualHandCount, isTsumo: isTsumo, x: x, y: y });
            return this.click(x, y, label);
        },

        // ========================================
        // 按鈕點擊
        // ========================================

        /**
         * 點擊操作按鈕 (吃/碰/槓/和/跳過等)
         */
        clickButton: function(action) {
            const canvas = this.getCanvas();
            if (!canvas) {
                sendToSwift('autoplay_error', { error: 'Canvas not found' });
                return false;
            }

            const rect = canvas.getBoundingClientRect();
            const scaleX = rect.width / 1920;
            const scaleY = rect.height / 1080;

            const cal = this.calibration;
            const base = this.baseCoords;
            const baseX = base.tileBaseX + cal.offsetX;
            const buttonY = 827;  // 按鈕 Y 座標

            // 按鈕位置：相對於手牌索引
            const buttonPositions = {
                'pass':     { tileIndex: 11, label: '跳過' },
                'chi':      { tileIndex: 8, label: '吃' },
                'pon':      { tileIndex: 8, label: '碰' },
                'kan':      { tileIndex: 8, label: '槓' },
                'riichi':   { tileIndex: 8, label: '立直' },
                'tsumo':    { tileIndex: 5, label: '自摸' },
                'ron':      { tileIndex: 5, label: '榮和' },
                'hora':     { tileIndex: 5, label: '和牌' },
                'ryukyoku': { tileIndex: 8, label: '流局' },
                'kyushu':   { tileIndex: 8, label: '九種九牌' },
            };

            const pos = buttonPositions[action];
            if (!pos) {
                console.error('[Naki] Unknown action:', action);
                sendToSwift('autoplay_error', { error: 'Unknown action: ' + action });
                return false;
            }

            const x = (baseX + pos.tileIndex * cal.tileSpacing) * scaleX;
            const y = buttonY * scaleY;

            console.log('[Naki] Clicking button:', action, 'at', x, y, '(above tile #' + (pos.tileIndex + 1) + ')');
            sendToSwift('autoplay_button_click', { action: action, x: x, y: y });
            return this.click(x, y, pos.label);
        },

        // ========================================
        // 複合動作
        // ========================================

        /**
         * 執行複合動作 (例如：立直 + 打牌)
         */
        executeAction: function(actionType, params) {
            console.log('[Naki] Executing action:', actionType, params);

            switch (actionType) {
                case 'discard':
                    // 打牌：需要點兩次（選中 + 確認）
                    const tileIdx = params.tileIndex;
                    const handCnt = params.handCount;
                    this.clickTile(tileIdx, handCnt);
                    setTimeout(() => {
                        this.clickTile(tileIdx, handCnt);
                    }, 300);
                    return true;

                case 'riichi':
                    // 立直：先點立直按鈕，再打牌
                    this.clickButton('riichi');
                    const handCount = params.handCount;
                    setTimeout(() => {
                        this.clickTile(params.tileIndex, handCount);
                    }, 500);
                    return true;

                case 'chi':
                case 'pon':
                case 'kan':
                    return this.clickButton(actionType);

                case 'hora':
                case 'tsumo':
                case 'ron':
                    return this.clickButton('hora');

                case 'pass':
                    return this.clickButton('pass');

                case 'ryukyoku':
                case 'kyushu':
                    return this.clickButton(actionType);

                default:
                    console.error('[Naki] Unknown action type:', actionType);
                    return false;
            }
        }
    };

    // ========================================
    // 向後兼容的簡化接口
    // ========================================

    window.__nakiClickTile = function(tileIndex) {
        return window.__nakiAutoPlay.clickTile(tileIndex);
    };

    window.__nakiClickButton = function(action) {
        return window.__nakiAutoPlay.clickButton(action);
    };

    window.__nakiExecuteAction = function(actionType, params) {
        return window.__nakiAutoPlay.executeAction(actionType, params);
    };

    // ========================================
    // 測試函數
    // ========================================

    /**
     * 測試函數：顯示所有手牌位置
     */
    window.__nakiTestIndicators = function() {
        const autoPlay = window.__nakiAutoPlay;
        const canvas = autoPlay.getCanvas();
        if (!canvas) {
            console.error('[Naki] Canvas not found!');
            alert('Canvas not found!');
            return;
        }

        const rect = canvas.getBoundingClientRect();
        console.log('[Naki] Canvas internal size:', canvas.width, 'x', canvas.height);
        console.log('[Naki] Canvas rendered size:', rect.width, 'x', rect.height);
        console.log('[Naki] Calibration:', JSON.stringify(autoPlay.calibration));

        const cal = autoPlay.calibration;
        const base = autoPlay.baseCoords;

        // 顯示所有 13 張手牌 + 摸牌的位置
        for (let i = 0; i <= 13; i++) {
            setTimeout(() => {
                const rect = canvas.getBoundingClientRect();
                const scaleX = rect.width / 1920;
                const scaleY = rect.height / 1080;

                const baseX = base.tileBaseX + cal.offsetX;
                const baseY = base.tileBaseY + cal.offsetY;
                const tileWidth = cal.tileSpacing;
                const tsumoGap = base.tsumoGap;

                let x, y, label;
                if (i < 13) {
                    x = (baseX + i * tileWidth) * scaleX;
                    label = `#${i + 1}`;
                } else {
                    x = (baseX + 13 * tileWidth + tsumoGap) * scaleX;
                    label = '摸';
                }
                y = baseY * scaleY;

                autoPlay.showClickIndicator(x, y, label);
            }, i * 200);
        }

        // 顯示按鈕位置
        setTimeout(() => {
            const rect = canvas.getBoundingClientRect();
            const scaleX = rect.width / 1920;
            const scaleY = rect.height / 1080;

            const baseX = base.tileBaseX + cal.offsetX;
            const buttonY = 827;

            const buttons = [
                { tileIndex: 5, label: '和' },
                { tileIndex: 8, label: '碰' },
                { tileIndex: 11, label: '過' },
            ];

            buttons.forEach((btn, idx) => {
                setTimeout(() => {
                    const x = (baseX + btn.tileIndex * cal.tileSpacing) * scaleX;
                    const y = buttonY * scaleY;
                    autoPlay.showClickIndicator(x, y, btn.label);
                }, idx * 200);
            });
        }, 14 * 200);
    };

    /**
     * 測試函數：顯示單一點擊位置
     */
    window.__nakiTestClick = function(x, y, label) {
        window.__nakiAutoPlay.showClickIndicator(x, y, label || 'TEST');
    };

    // ========================================
    // 🌟 推薦高亮管理模組 (RunUV 效果版)
    // ========================================
    /**
     * 管理推薦牌的視覺高亮效果
     * 使用 effect_doraPlane + anim.RunUV 實現
     * 支援多個推薦同時顯示，根據機率顯示不同顏色
     */
    window.__nakiRecommendHighlight = {
        activeEffects: [],  // 存儲所有活躍的效果 { effect, runUV, tileIndex }
        nativeEffectActive: false,  // 追蹤原生 effect_recommend 狀態

        // 🔧 設定選項
        settings: {
            showRotatingEffect: false,  // 是否顯示旋轉 Bling 效果（預設關閉）
            showNativeEffect: true      // 是否顯示原生 effect_recommend（預設開啟）
        },

        // 顏色配置
        colors: {
            green: { r: 0, g: 2, b: 0, a: 2 },   // probability > 0.5
            red: { r: 2, g: 0, b: 0, a: 2 }      // 0.2 < probability <= 0.5
        },

        /**
         * 將原生 effect_recommend 移動到指定牌的位置
         * @param {number} tileIndex - 牌在手中的位置
         * @returns {boolean} 成功或失敗
         */
        moveNativeEffect: function(tileIndex) {
            try {
                const mgr = window.view?.DesktopMgr?.Inst;
                if (!mgr?.effect_recommend?._childs?.[0]) {
                    console.log('[Naki Highlight] Native effect_recommend not available');
                    return false;
                }

                const hand = mgr.mainrole?.hand;
                if (!hand || !hand[tileIndex]) {
                    console.log('[Naki Highlight] Tile not found at index:', tileIndex);
                    return false;
                }

                // 獲取目標牌的 pos_x
                const targetX = hand[tileIndex].pos_x;
                const effect = mgr.effect_recommend;
                const child = effect._childs[0];

                // 移動子對象到目標位置 (Y 和 Z 保持固定)
                child.transform.localPosition = new Laya.Vector3(targetX, 1.66, -0.52);

                // 激活效果
                effect.active = true;
                this.nativeEffectActive = true;

                console.log('[Naki Highlight] Native effect moved to tile', tileIndex, 'x:', targetX);
                return true;
            } catch (e) {
                console.error('[Naki Highlight] moveNativeEffect failed:', e);
                return false;
            }
        },

        /**
         * 隱藏原生 effect_recommend
         */
        hideNativeEffect: function() {
            try {
                const effect = window.view?.DesktopMgr?.Inst?.effect_recommend;
                if (effect) {
                    effect.active = false;
                    this.nativeEffectActive = false;
                    console.log('[Naki Highlight] Native effect hidden');
                }
            } catch (e) {
                console.error('[Naki Highlight] hideNativeEffect failed:', e);
            }
        },

        /**
         * 根據機率獲取顏色
         * @param {number} probability - 機率值 (0.0 ~ 1.0)
         * @returns {object|null} 顏色對象或 null（不顯示）
         */
        getColorForProbability: function(probability) {
            if (probability > 0.5) {
                return this.colors.green;
            } else if (probability > 0.2) {
                return this.colors.red;
            }
            return null;  // probability <= 0.2 不顯示
        },

        // 旋轉動畫 interval ID
        rotateIntervalId: null,

        /**
         * 為單張牌創建雙層旋轉 Bling 效果
         * @param {object} tile - 牌物件
         * @param {object} color - 顏色 { r, g, b, a }
         * @param {boolean} reverse - 未使用（保留參數兼容性）
         * @returns {object|null} { effects: [effect1, effect2], blings: [bling1, bling2] } 或 null
         */
        createEffect: function(tile, color, reverse) {
            try {
                const mgr = window.view?.DesktopMgr?.Inst;
                if (!mgr || !tile || !tile.mySelf) return null;

                const effects = [];
                const blings = [];

                // 創建兩層效果 (90° 和 180°)
                [90, 180].forEach(rotation => {
                    const effect = mgr.effect_doraPlane.clone();
                    tile.mySelf.addChild(effect);

                    effect.transform.localPosition = new Laya.Vector3(0, 0, 0);
                    effect.transform.localRotationEuler = new Laya.Vector3(0, 0, rotation);
                    effect.transform.localScale = new Laya.Vector3(1, 1, 1);
                    effect.active = true;

                    const child = effect.getChildAt(0);
                    const bling = child.addComponent(anim.Bling);
                    bling.tick = 300;

                    if (color && bling.mat) {
                        const c = bling.mat.albedoColor;
                        c.x = color.r;
                        c.y = color.g;
                        c.z = color.b;
                        c.w = color.a;
                        bling.mat.albedoColor = c;
                    }

                    effects.push(effect);
                    blings.push(bling);
                });

                return { effects, blings };
            } catch (e) {
                console.error('[Naki Highlight] createEffect failed:', e);
                return null;
            }
        },

        /**
         * 啟動旋轉動畫
         */
        startRotation: function() {
            if (this.rotateIntervalId) return;

            const self = this;
            this.rotateIntervalId = setInterval(function() {
                self.activeEffects.forEach(item => {
                    if (item.effects) {
                        item.effects.forEach(effect => {
                            if (effect && effect.transform) {
                                const z = effect.transform.localRotationEuler.z + 3;
                                effect.transform.localRotationEuler = new Laya.Vector3(0, 0, z);
                            }
                        });
                    }
                });
            }, 30);
        },

        /**
         * 停止旋轉動畫
         */
        stopRotation: function() {
            if (this.rotateIntervalId) {
                clearInterval(this.rotateIntervalId);
                this.rotateIntervalId = null;
            }
        },

        /**
         * 顯示多個推薦的高亮
         * @param {Array} recommendations - [{ tileIndex, probability }, ...]
         * @returns {number} 成功創建的效果數量
         */
        showMultiple: function(recommendations) {
            // 先清除現有效果
            this.hide();

            const mgr = window.view?.DesktopMgr?.Inst;
            if (!mgr) {
                console.log('[Naki Highlight] Game manager not available');
                return 0;
            }

            const hand = mgr.mainrole?.hand;
            if (!hand) {
                console.log('[Naki Highlight] Hand not available');
                return 0;
            }

            // 🌟 找出最高概率的推薦，移動原生 effect_recommend
            if (this.settings.showNativeEffect && recommendations.length > 0) {
                const sorted = [...recommendations].sort((a, b) => b.probability - a.probability);
                const best = sorted[0];
                if (best.probability > 0.2) {
                    this.moveNativeEffect(best.tileIndex);
                }
            }

            // 如果旋轉效果被禁用，直接返回
            if (!this.settings.showRotatingEffect) {
                console.log('[Naki Highlight] Rotating effect disabled, using native only');
                return 0;
            }

            let created = 0;
            for (const rec of recommendations) {
                const { tileIndex, probability } = rec;

                // 根據機率獲取顏色
                const color = this.getColorForProbability(probability);
                if (!color) {
                    console.log('[Naki Highlight] Skipping tile', tileIndex, 'probability too low:', probability);
                    continue;
                }

                // 獲取牌物件
                const tile = hand[tileIndex];
                if (!tile) {
                    console.log('[Naki Highlight] Tile not found at index:', tileIndex);
                    continue;
                }

                // 創建雙層效果
                const result = this.createEffect(tile, color, false);
                if (result) {
                    this.activeEffects.push({
                        effects: result.effects,
                        blings: result.blings,
                        tileIndex: tileIndex,
                        probability: probability
                    });
                    created++;
                    console.log('[Naki Highlight] Created effect for tile', tileIndex,
                        'probability:', probability.toFixed(3),
                        'color:', probability > 0.5 ? 'green' : 'red');
                }
            }

            // 啟動旋轉動畫
            if (created > 0) {
                this.startRotation();
            }

            console.log('[Naki Highlight] Created', created, 'effects');
            return created;
        },

        /**
         * 顯示單個推薦的高亮（向後兼容）
         * @param {number} tileIndex - 牌在手中的位置
         * @param {number} probability - 機率值（預設 1.0）
         * @returns {boolean} 成功或失敗
         */
        show: function(tileIndex, probability) {
            const prob = typeof probability === 'number' ? probability : 1.0;
            return this.showMultiple([{ tileIndex, probability: prob }]) > 0;
        },

        /**
         * 隱藏所有推薦高亮
         * @returns {boolean} 成功或失敗
         */
        hide: function() {
            try {
                // 停止旋轉動畫
                this.stopRotation();

                // 🌟 隱藏原生 effect_recommend
                this.hideNativeEffect();

                // 銷毀所有效果
                for (const item of this.activeEffects) {
                    if (item.effects) {
                        item.effects.forEach(effect => {
                            if (effect) effect.destroy();
                        });
                    }
                    // 向後兼容舊格式
                    if (item.effect) {
                        item.effect.destroy();
                    }
                }
                this.activeEffects = [];
                console.log('[Naki Highlight] All effects hidden');
                return true;
            } catch (e) {
                console.error('[Naki Highlight] hide failed:', e);
                return false;
            }
        },

        /**
         * 獲取當前狀態
         */
        getStatus: function() {
            return {
                isActive: this.activeEffects.length > 0 || this.nativeEffectActive,
                effectCount: this.activeEffects.length,
                nativeEffectActive: this.nativeEffectActive,
                settings: this.settings,
                effects: this.activeEffects.map(e => ({
                    tileIndex: e.tileIndex,
                    probability: e.probability
                }))
            };
        },

        /**
         * 更新設定
         * @param {object} newSettings - { showRotatingEffect, showNativeEffect }
         */
        setSettings: function(newSettings) {
            if (typeof newSettings.showRotatingEffect === 'boolean') {
                this.settings.showRotatingEffect = newSettings.showRotatingEffect;
            }
            if (typeof newSettings.showNativeEffect === 'boolean') {
                this.settings.showNativeEffect = newSettings.showNativeEffect;
            }
            console.log('[Naki Highlight] Settings updated:', this.settings);
        }
    };

    console.log('[Naki] AutoPlay module loaded');
})();
