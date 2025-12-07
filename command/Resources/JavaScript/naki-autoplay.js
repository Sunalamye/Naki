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
            console.log('[Naki] 顯示點擊指示器:', x, y, label);

            if (!this.debugMode) {
                console.log('[Naki] 除錯模式已關閉，跳過指示器');
                return;
            }

            const canvas = this.getCanvas();
            if (!canvas) {
                console.log('[Naki] 找不到畫布，無法顯示指示器');
                return;
            }

            const rect = canvas.getBoundingClientRect();
            console.log('[Naki] 畫布範圍:', rect.left, rect.top, rect.width, rect.height);

            const absoluteX = rect.left + x;
            const absoluteY = rect.top + y;
            console.log('[Naki] 建立指示器於絕對位置:', absoluteX, absoluteY);

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
            console.log('[Naki] 指示器已加入 DOM:', indicator, '位於', absoluteX, absoluteY);

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
                console.error('[Naki] 找不到畫布');
                sendToSwift('autoplay_error', { error: 'Canvas not found' });
                return false;
            }

            // 顯示點擊指示器
            this.showClickIndicator(x, y, label);

            console.log('[Naki] 點擊位置:', x, y);
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

            console.log('[Naki] 點擊手牌索引:', tileIndex, '手牌數:', actualHandCount, '是否摸牌:', isTsumo, '位置', x, y);
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
                console.error('[Naki] 未知動作:', action);
                sendToSwift('autoplay_error', { error: 'Unknown action: ' + action });
                return false;
            }

            const x = (baseX + pos.tileIndex * cal.tileSpacing) * scaleX;
            const y = buttonY * scaleY;

            console.log('[Naki] 點擊按鈕:', action, '位置', x, y, '(手牌 #' + (pos.tileIndex + 1) + ' 上方)');
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
            console.log('[Naki] 執行動作:', actionType, params);

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
                    console.error('[Naki] 未知動作類型:', actionType);
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
            console.error('[Naki] 找不到畫布!');
            alert('找不到畫布!');
            return;
        }

        const rect = canvas.getBoundingClientRect();
        console.log('[Naki] 畫布內部大小:', canvas.width, 'x', canvas.height);
        console.log('[Naki] 畫布渲染大小:', rect.width, 'x', rect.height);
        console.log('[Naki] 校準參數:', JSON.stringify(autoPlay.calibration));

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
    // 🌟 推薦高亮管理模組 (手牌顏色版)
    // ========================================
    /**
     * 管理推薦牌的視覺高亮效果
     * 使用 tile._SetColor() 直接改變手牌顏色
     * 支援多個推薦同時顯示，根據機率顯示不同顏色：
     * - 綠色：probability > 0.5
     * - 橘色：0.3 < probability <= 0.5
     * - 紅色：0.2 < probability <= 0.3
     */
    window.__nakiRecommendHighlight = {
        activeEffects: [],  // 存儲所有已著色的牌 { tileIndex, originalColor }
        nativeEffectActive: false,  // 追蹤原生 effect_recommend 狀態

        // 🔧 設定選項
        settings: {
            showRotatingEffect: false,  // 是否顯示旋轉 Bling 效果（預設關閉）
            showNativeEffect: true,     // 是否顯示原生 effect_recommend（預設開啟）
            showTileColor: true         // 是否使用牌顏色高亮（預設開啟）
        },

        // 顏色配置 (Laya.Vector4 格式: r, g, b, a)
        colors: {
            green:  { r: 0.4, g: 0.9, b: 0.4, a: 1 },   // probability > 0.5 綠色
            orange: { r: 1.0, g: 0.6, b: 0.2, a: 1 },   // 0.3 < probability <= 0.5 橘色
            red:    { r: 1.0, g: 0.4, b: 0.4, a: 1 },   // 0.2 < probability <= 0.3 紅色
            white:  { r: 1.0, g: 1.0, b: 1.0, a: 1 }    // 原始顏色（白色）
        },

        // 舊版顏色配置（用於旋轉效果，保留向後兼容）
        legacyColors: {
            green: { r: 0, g: 2, b: 0, a: 2 },
            red: { r: 2, g: 0, b: 0, a: 2 }
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
                    console.log('[Naki 高亮] 原生 effect_recommend 不可用');
                    return false;
                }

                const hand = mgr.mainrole?.hand;
                if (!hand || !hand[tileIndex]) {
                    console.log('[Naki 高亮] 找不到索引處的牌:', tileIndex);
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

                console.log('[Naki 高亮] 原生效果已移至牌', tileIndex, 'x:', targetX);
                return true;
            } catch (e) {
                console.error('[Naki 高亮] 移動原生效果失敗:', e);
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
                    console.log('[Naki 高亮] 原生效果已隱藏');
                }
            } catch (e) {
                console.error('[Naki 高亮] 隱藏原生效果失敗:', e);
            }
        },

        /**
         * 將原生 effect_recommend 移動到指定按鈕的位置
         * @param {string} actionType - 動作類型: 'chi', 'pon', 'kan', 'hu', 'zimo', 'pass' 等
         * @returns {boolean} 成功或失敗
         */
        moveNativeEffectToButton: function(actionType) {
            try {
                const mgr = window.view?.DesktopMgr?.Inst;
                if (!mgr?.effect_recommend?._childs?.[0]) {
                    console.log('[Naki 高亮] 原生 effect_recommend 不可用');
                    return false;
                }

                const ui = window.uiscript?.UI_ChiPengHu?.Inst;
                if (!ui?.container_btns) {
                    console.log('[Naki 高亮] UI_ChiPengHu 不可用');
                    return false;
                }

                // 按鈕名稱映射
                const btnNameMap = {
                    'chi': 'btn_chi',
                    'pon': 'btn_peng',
                    'kan': 'btn_gang',
                    'hu': 'btn_hu',
                    'zimo': 'btn_zimo',
                    'ron': 'btn_hu',
                    'hora': 'btn_hu',
                    'pass': 'btn_cancel',
                    'cancel': 'btn_cancel',
                    'riichi': 'btn_lizhi',
                    'ryukyoku': 'btn_jiuzhongjiupai',
                    'kyushu': 'btn_jiuzhongjiupai'
                };

                const targetBtnName = btnNameMap[actionType];
                if (!targetBtnName) {
                    console.log('[Naki 高亮] 未知動作類型:', actionType);
                    return false;
                }

                // 獲取所有可見按鈕（從右到左排序）
                const container = ui.container_btns;
                const visibleBtns = [];
                for (let i = 0; i < container.numChildren; i++) {
                    const btn = container.getChildAt(i);
                    if (btn.visible) {
                        visibleBtns.push({
                            name: btn.name,
                            x: btn.x,
                            center_x: container.x + btn.x + btn.width / 2
                        });
                    }
                }

                // 按 center_x 從大到小排序（最右邊的在前）
                visibleBtns.sort((a, b) => b.center_x - a.center_x);

                // 找到目標按鈕的索引
                let btnIndex = -1;
                for (let i = 0; i < visibleBtns.length; i++) {
                    if (visibleBtns[i].name === targetBtnName) {
                        btnIndex = i;
                        break;
                    }
                }

                if (btnIndex === -1) {
                    console.log('[Naki 高亮] 目標按鈕不可見:', targetBtnName);
                    return false;
                }

                // 計算 3D 位置：x = 27.5 - (索引 × 7), y = 4.5
                const effect = mgr.effect_recommend;
                const child = effect._childs[0];
                const posX = 27.5 - (btnIndex * 7);
                const posY = 4.5;
                const posZ = -0.52;

                child.transform.localPosition = new Laya.Vector3(posX, posY, posZ);
                effect.active = true;
                this.nativeEffectActive = true;

                console.log('[Naki 高亮] 已移至按鈕:', actionType,
                    'btnName:', targetBtnName, 'index:', btnIndex,
                    'pos:', posX, posY, posZ);
                return true;
            } catch (e) {
                console.error('[Naki 高亮] 移動原生效果至按鈕失敗:', e);
                return false;
            }
        },

        /**
         * 根據機率獲取顏色（用於牌顏色高亮）
         * 閾值設計考慮：麻將推薦通常分散，最高推薦往往只有 15-30%
         * @param {number} probability - 機率值 (0.0 ~ 1.0)
         * @returns {object|null} 顏色對象或 null（不顯示）
         */
        getColorForProbability: function(probability) {
            if (probability > 0.3) {
                return this.colors.green;   // 綠色：> 30%（強烈推薦）
            } else if (probability > 0.15) {
                return this.colors.orange;  // 橘色：15% - 30%（中等推薦）
            } else if (probability > 0.08) {
                return this.colors.red;     // 紅色：8% - 15%（弱推薦）
            }
            return null;  // probability <= 8% 不顯示
        },

        /**
         * 根據機率獲取顏色（用於舊版旋轉效果）
         * @param {number} probability - 機率值 (0.0 ~ 1.0)
         * @returns {object|null} 顏色對象或 null（不顯示）
         */
        getLegacyColorForProbability: function(probability) {
            if (probability > 0.5) {
                return this.legacyColors.green;
            } else if (probability > 0.2) {
                return this.legacyColors.red;
            }
            return null;
        },

        /**
         * 設置單張牌的顏色
         * @param {number} tileIndex - 牌在手中的位置
         * @param {object} color - 顏色 { r, g, b, a }
         * @returns {boolean} 成功或失敗
         */
        setTileColor: function(tileIndex, color) {
            try {
                const mgr = window.view?.DesktopMgr?.Inst;
                const hand = mgr?.mainrole?.hand;
                if (!hand || !hand[tileIndex]) {
                    console.log('[Naki 高亮] 找不到索引處的牌:', tileIndex);
                    return false;
                }

                const tile = hand[tileIndex];
                if (!tile._SetColor) {
                    console.log('[Naki 高亮] 牌沒有 _SetColor 方法:', tileIndex);
                    return false;
                }

                const layaColor = new Laya.Vector4(color.r, color.g, color.b, color.a);
                tile._SetColor(layaColor);

                // 驗證設置成功（某些情況下 _SetColor 會被遊戲重置）
                // 使用 requestAnimationFrame 延遲驗證
                const self = this;
                requestAnimationFrame(function() {
                    if (tile.getColor) {
                        const actual = tile.getColor();
                        if (actual && Math.abs(actual.x - color.r) > 0.1) {
                            // 顏色被重置，嘗試再次設置
                            console.log('[Naki 高亮] 重試設置牌', tileIndex, '顏色');
                            tile._SetColor(layaColor);
                        }
                    }
                });

                return true;
            } catch (e) {
                console.error('[Naki 高亮] 設置牌顏色失敗:', e);
                return false;
            }
        },

        /**
         * 重置單張牌的顏色為白色
         * @param {number} tileIndex - 牌在手中的位置
         * @returns {boolean} 成功或失敗
         */
        resetTileColor: function(tileIndex) {
            return this.setTileColor(tileIndex, this.colors.white);
        },

        /**
         * 重置所有手牌的顏色
         */
        resetAllTileColors: function() {
            try {
                const mgr = window.view?.DesktopMgr?.Inst;
                const hand = mgr?.mainrole?.hand;
                if (!hand) return;

                const white = new Laya.Vector4(1, 1, 1, 1);
                for (let i = 0; i < hand.length; i++) {
                    const tile = hand[i];
                    if (tile && tile._SetColor) {
                        tile._SetColor(white);
                    }
                }
                console.log('[Naki 高亮] 已重置所有手牌顏色');
            } catch (e) {
                console.error('[Naki 高亮] 重置手牌顏色失敗:', e);
            }
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
                console.log('[Naki 高亮] 遊戲管理器不可用');
                return 0;
            }

            const hand = mgr.mainrole?.hand;
            if (!hand) {
                console.log('[Naki 高亮] 手牌不可用');
                return 0;
            }

            let created = 0;

            // 🌟 使用牌顏色高亮（預設開啟）
            const useTileColor = this.settings.showTileColor !== false;
            if (useTileColor) {
                for (const rec of recommendations) {
                    const { tileIndex, probability } = rec;

                    // 根據機率獲取顏色
                    const color = this.getColorForProbability(probability);
                    if (!color) {
                        continue;
                    }

                    // 設置牌顏色
                    if (this.setTileColor(tileIndex, color)) {
                        // 記錄顏色類型（與 getColorForProbability 閾值一致）
                        const colorType = probability > 0.3 ? 'green' : (probability > 0.15 ? 'orange' : 'red');
                        this.activeEffects.push({
                            tileIndex: tileIndex,
                            probability: probability,
                            colorType: colorType
                        });
                        created++;
                        console.log('[Naki 高亮] 設置牌顏色:', tileIndex,
                            '機率:', probability.toFixed(3),
                            '顏色:', colorType === 'green' ? '綠色' : (colorType === 'orange' ? '橘色' : '紅色'));

                        // 驗證顏色是否真的設置成功
                        const tile = hand[tileIndex];
                        if (tile && tile.getColor) {
                            const actualColor = tile.getColor();
                            if (actualColor && Math.abs(actualColor.x - color.r) > 0.1) {
                                console.warn('[Naki 高亮] 驗證失敗: 牌', tileIndex, '顏色未正確設置');
                            }
                        }
                    }
                }
            }

            // 🌟 找出最高概率的推薦，移動原生 effect_recommend
            if (this.settings.showNativeEffect && recommendations.length > 0) {
                const sorted = [...recommendations].sort((a, b) => b.probability - a.probability);
                const best = sorted[0];
                if (best.probability > 0.2) {
                    this.moveNativeEffect(best.tileIndex);
                }
            }

            // 如果旋轉效果被啟用（預設關閉）
            if (this.settings.showRotatingEffect) {
                for (const rec of recommendations) {
                    const { tileIndex, probability } = rec;

                    // 使用舊版顏色
                    const color = this.getLegacyColorForProbability(probability);
                    if (!color) continue;

                    const tile = hand[tileIndex];
                    if (!tile) continue;

                    const result = this.createEffect(tile, color, false);
                    if (result) {
                        this.activeEffects.push({
                            effects: result.effects,
                            blings: result.blings,
                            tileIndex: tileIndex,
                            probability: probability
                        });
                    }
                }

                // 啟動旋轉動畫
                if (this.activeEffects.some(e => e.effects)) {
                    this.startRotation();
                }
            }

            console.log('[Naki 高亮] 已創建', created, '個顏色效果');
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

                // 🌟 重置所有手牌顏色
                this.resetAllTileColors();

                // 銷毀所有旋轉效果
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
                console.log('[Naki 高亮] 所有效果已隱藏');
                return true;
            } catch (e) {
                console.error('[Naki 高亮] 隱藏效果失敗:', e);
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
                    probability: e.probability,
                    colorType: e.colorType || 'unknown'
                }))
            };
        },

        /**
         * 更新設定
         * @param {object} newSettings - { showRotatingEffect, showNativeEffect, showTileColor }
         */
        setSettings: function(newSettings) {
            if (typeof newSettings.showRotatingEffect === 'boolean') {
                this.settings.showRotatingEffect = newSettings.showRotatingEffect;
            }
            if (typeof newSettings.showNativeEffect === 'boolean') {
                this.settings.showNativeEffect = newSettings.showNativeEffect;
            }
            if (typeof newSettings.showTileColor === 'boolean') {
                this.settings.showTileColor = newSettings.showTileColor;
            }
            console.log('[Naki 高亮] 設定已更新:', this.settings);
        },

        /**
         * 設置自定義顏色
         * @param {string} colorName - 顏色名稱 (green, orange, red)
         * @param {object} color - 顏色值 { r, g, b, a }
         */
        setColor: function(colorName, color) {
            if (this.colors[colorName]) {
                this.colors[colorName] = color;
                console.log('[Naki 高亮] 顏色已更新:', colorName, color);
            }
        }
    };

    console.log('[Naki] 自動打牌模組已載入');
})();
