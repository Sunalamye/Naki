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
    // 🌟 推薦高亮管理模組
    // ========================================
    /**
     * 管理推薦牌的視覺高亮效果
     * 基於 Majsoul 的 effect_recommend 機制
     */
    window.__nakiRecommendHighlight = {
        isActive: false,
        highlightTileIndex: -1,

        /**
         * 顯示推薦牌的高亮
         * @param {number} tileIndex - 牌在手中的位置 (0-13)
         * @returns {boolean} 成功或失敗
         */
        show: function(tileIndex) {
            try {
                const inst = window.view?.DesktopMgr?.Inst;
                if (!inst) {
                    console.log('[Naki Highlight] Game manager not available');
                    return false;
                }

                // ⭐ 使用初始化 hook 的高亮效果參考，或直接獲取
                const effect = window.__nakiHighlightInit?.getEffect?.() || inst.effect_recommend;
                if (!effect) {
                    console.log('[Naki Highlight] effect_recommend not available');
                    return false;
                }

                // 啟用推薦效果
                effect.active = true;
                this.isActive = true;
                this.highlightTileIndex = tileIndex;

                console.log('[Naki Highlight] 顯示推薦高亮於牌位置:', tileIndex);
                return true;

            } catch (e) {
                console.error('[Naki Highlight] 顯示高亮失敗:', e);
                return false;
            }
        },

        /**
         * 隱藏推薦牌的高亮
         * @returns {boolean} 成功或失敗
         */
        hide: function() {
            try {
                const inst = window.view?.DesktopMgr?.Inst;
                if (!inst || !inst.effect_recommend) {
                    return false;
                }

                // 停用推薦效果
                inst.effect_recommend.active = false;
                this.isActive = false;
                this.highlightTileIndex = -1;

                console.log('[Naki Highlight] 隱藏推薦高亮');
                return true;

            } catch (e) {
                console.error('[Naki Highlight] 隱藏高亮失敗:', e);
                return false;
            }
        },

        /**
         * 切換推薦高亮
         */
        toggle: function(tileIndex) {
            if (this.isActive) {
                return this.hide();
            } else {
                return this.show(tileIndex || 0);
            }
        },

        /**
         * 獲取當前狀態
         */
        getStatus: function() {
            return {
                isActive: this.isActive,
                highlightTileIndex: this.highlightTileIndex,
                hasEffect: !!window.view?.DesktopMgr?.Inst?.effect_recommend
            };
        }
    };

    console.log('[Naki] AutoPlay module loaded');
})();
