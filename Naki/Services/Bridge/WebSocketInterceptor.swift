//
//  WebSocketInterceptor.swift
//  akagi
//
//  Created by Suoie on 2025/11/30.
//  WebSocket 攔截器 - 通過 JavaScript 注入監聽雀魂的 WebSocket 通訊
//  Updated: 2025/12/01 - 添加自動打牌支援
//  Updated: 2025/12/03 - 重構為從外部 JS 文件載入
//

import Foundation
import WebKit
import os.log

// 使用 LogManager 的 wsLog 函數

// MARK: - WebSocket Interceptor

/// WebSocket 攔截器，用於監聽 WKWebView 中的 WebSocket 通訊
class WebSocketInterceptor {

    /// JavaScript 模組文件名稱（按載入順序）
    private static let jsModules = [
        "naki-core",
        "naki-autoplay",
        "naki-game-api",
        "naki-websocket"
    ]

    /// 從 Bundle 載入 JavaScript 文件
    private static func loadJavaScript(named filename: String) -> String? {
        // 嘗試從 Resources/JavaScript 子目錄載入
        if let url = Bundle.main.url(forResource: filename, withExtension: "js", subdirectory: "Resources/JavaScript") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        // 嘗試直接從 bundle 根目錄載入
        if let url = Bundle.main.url(forResource: filename, withExtension: "js") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        wsLog("[JS] Failed to find \(filename).js in bundle")
        return nil
    }

    /// 注入到網頁的 JavaScript 代碼（從外部文件載入，回退到內嵌腳本）
    static var injectionScript: String {
        var scripts: [String] = []

        for module in jsModules {
            if let script = loadJavaScript(named: module) {
                scripts.append("// === \(module).js ===")
                scripts.append(script)
                wsLog("[JS] Loaded module: \(module).js")
            } else {
                wsLog("[JS] Warning: Could not load \(module).js")
            }
        }

        // 如果成功載入任何模組，使用外部文件
        if !scripts.isEmpty {
            wsLog("[JS] Using external JavaScript modules (\(scripts.count / 2) loaded)")
            return scripts.joined(separator: "\n\n")
        }

        // 回退：使用內嵌腳本
        wsLog("[JS] Warning: No JavaScript modules loaded, using fallback inline script")
        return inlineScript
    }

    /// 內嵌腳本（回退用）- 保留原有功能
    private static var inlineScript: String {
        """
        (function() {
            'use strict';

            // 避免重複注入
            if (window.__nakiWebSocketHooked) {
                return;
            }
            window.__nakiWebSocketHooked = true;

            // 保存原始 WebSocket 構造函數
            const OriginalWebSocket = window.WebSocket;
            let socketCounter = 0;

            // 保存雀魂 WebSocket 連接用於發送消息
            window.__nakiMajsoulSockets = {};

            // 輔助函數：將 ArrayBuffer 轉換為 Base64
            function arrayBufferToBase64(buffer) {
                const bytes = new Uint8Array(buffer);
                let binary = '';
                for (let i = 0; i < bytes.byteLength; i++) {
                    binary += String.fromCharCode(bytes[i]);
                }
                return btoa(binary);
            }

            // 輔助函數：將 Base64 轉換為 ArrayBuffer
            function base64ToArrayBuffer(base64) {
                const binary = atob(base64);
                const len = binary.length;
                const bytes = new Uint8Array(len);
                for (let i = 0; i < len; i++) {
                    bytes[i] = binary.charCodeAt(i);
                }
                return bytes.buffer;
            }

            // 輔助函數：將 Blob 轉換為 Base64
            function blobToBase64(blob, callback) {
                const reader = new FileReader();
                reader.onloadend = function() {
                    const base64 = reader.result.split(',')[1];
                    callback(base64);
                };
                reader.readAsDataURL(blob);
            }

            // 發送消息到 Swift（安全版本）
            function sendToSwift(type, data) {
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.websocketBridge) {
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

            // ⭐ UI 自動化模組
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

                // 顯示點擊指示器
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

                // 模擬滑鼠事件
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

                // 模擬點擊
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

                // 點擊手牌 (根據索引，支援動態手牌數)
                // tileIndex: 手牌索引 (0-based)
                // handCount: 實際手牌數 (副露後會減少，預設 13)
                clickTile: function(tileIndex, handCount) {
                    const canvas = this.getCanvas();
                    if (!canvas) {
                        sendToSwift('autoplay_error', { error: 'Canvas not found' });
                        return false;
                    }

                    // ⚠️ 使用實際渲染大小，不是內部解析度
                    const rect = canvas.getBoundingClientRect();
                    const scaleX = rect.width / 1920;
                    const scaleY = rect.height / 1080;

                    // 使用校準參數 + 基準座標
                    const cal = this.calibration;
                    const base = this.baseCoords;
                    const baseX = base.tileBaseX + cal.offsetX;  // 加上水平偏移
                    const baseY = base.tileBaseY + cal.offsetY;  // 加上垂直偏移
                    const tileWidth = cal.tileSpacing;           // 使用校準的間距
                    const tsumoGap = base.tsumoGap;

                    // 實際手牌數 (未副露時為 13，碰一次為 10，碰兩次為 7...)
                    const actualHandCount = handCount || 13;
                    const isTsumo = tileIndex >= actualHandCount;

                    let x, y;
                    let label;
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

                // 點擊操作按鈕 (吃/碰/槓/和/跳過等)
                clickButton: function(action) {
                    const canvas = this.getCanvas();
                    if (!canvas) {
                        sendToSwift('autoplay_error', { error: 'Canvas not found' });
                        return false;
                    }

                    // ⚠️ 使用實際渲染大小，不是內部解析度
                    const rect = canvas.getBoundingClientRect();
                    const scaleX = rect.width / 1920;
                    const scaleY = rect.height / 1080;

                    // 使用校準參數計算按鈕位置
                    const cal = this.calibration;
                    const base = this.baseCoords;
                    const baseX = base.tileBaseX + cal.offsetX;

                    // 按鈕 Y 座標 (在手牌上方，往下調整 1/3)
                    // 原本 750，手牌 980，差距 230，往下移 1/3 ≈ 77
                    const buttonY = 827;

                    // 按鈕位置：相對於手牌索引
                    // 根據實測：碰在 #9 上方，過在 #12 上方
                    const buttonPositions = {
                        'pass':     { tileIndex: 11, label: '跳過' },      // #12 上方 (0-indexed: 11)
                        'chi':      { tileIndex: 8, label: '吃' },         // #9 上方
                        'pon':      { tileIndex: 8, label: '碰' },         // #9 上方
                        'kan':      { tileIndex: 8, label: '槓' },         // #9 上方
                        'riichi':   { tileIndex: 8, label: '立直' },       // #9 上方
                        'tsumo':    { tileIndex: 5, label: '自摸' },       // 左側一點
                        'ron':      { tileIndex: 5, label: '榮和' },       // 左側一點
                        'hora':     { tileIndex: 5, label: '和牌' },       // 左側一點
                        'ryukyoku': { tileIndex: 8, label: '流局' },
                        'kyushu':   { tileIndex: 8, label: '九種九牌' },
                    };

                    const pos = buttonPositions[action];
                    if (!pos) {
                        console.error('[Naki] Unknown action:', action);
                        sendToSwift('autoplay_error', { error: 'Unknown action: ' + action });
                        return false;
                    }

                    // 計算 X 座標：與手牌相同的計算方式
                    const x = (baseX + pos.tileIndex * cal.tileSpacing) * scaleX;
                    const y = buttonY * scaleY;

                    console.log('[Naki] Clicking button:', action, 'at', x, y, '(above tile #' + (pos.tileIndex + 1) + ')');
                    sendToSwift('autoplay_button_click', { action: action, x: x, y: y });
                    return this.click(x, y, pos.label);
                },

                // 執行複合動作 (例如：立直 + 打牌)
                executeAction: function(actionType, params) {
                    console.log('[Naki] Executing action:', actionType, params);

                    switch (actionType) {
                        case 'discard':
                            // 打牌：需要點兩次（選中 + 確認）
                            const tileIdx = params.tileIndex;
                            const handCnt = params.handCount;
                            this.clickTile(tileIdx, handCnt);
                            // 延遲後再點一次確認
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
                            // 吃/碰/槓：點擊對應按鈕
                            return this.clickButton(actionType);

                        case 'hora':
                        case 'tsumo':
                        case 'ron':
                            // 和牌
                            return this.clickButton('hora');

                        case 'pass':
                            // 跳過
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

            // 向後兼容的簡化接口
            window.__nakiClickTile = function(tileIndex) {
                return window.__nakiAutoPlay.clickTile(tileIndex);
            };

            window.__nakiClickButton = function(action) {
                return window.__nakiAutoPlay.clickButton(action);
            };

            window.__nakiExecuteAction = function(actionType, params) {
                return window.__nakiAutoPlay.executeAction(actionType, params);
            };

            // 🧪 測試函數：顯示所有手牌位置
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

                // 使用校準參數
                const cal = autoPlay.calibration;
                const base = autoPlay.baseCoords;

                // 顯示所有 13 張手牌 + 摸牌的位置
                for (let i = 0; i <= 13; i++) {
                    setTimeout(() => {
                        const rect = canvas.getBoundingClientRect();
                        // ⚠️ 使用實際渲染大小，不是內部解析度
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

                // 顯示按鈕位置 (使用相同校準參數)
                setTimeout(() => {
                    const rect = canvas.getBoundingClientRect();
                    const scaleX = rect.width / 1920;
                    const scaleY = rect.height / 1080;

                    const baseX = base.tileBaseX + cal.offsetX;
                    const buttonY = 827;  // 按鈕 Y 座標

                    // 按鈕位置：相對於手牌索引
                    const buttons = [
                        { tileIndex: 5, label: '和' },      // #6 上方
                        { tileIndex: 8, label: '碰' },      // #9 上方
                        { tileIndex: 11, label: '過' },     // #12 上方
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

            // 🧪 測試函數：顯示單一點擊位置
            window.__nakiTestClick = function(x, y, label) {
                window.__nakiAutoPlay.showClickIndicator(x, y, label || 'TEST');
            };

            // 🔍 探測遊戲引擎和可用 API
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

                    // 嘗試找到遊戲場景
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

            // 🔍 深度探測 - 探索 uiscript、view、GameMgr 的結構
            window.__nakiExploreGameObjects = function() {
                const explore = (obj, name, depth = 0) => {
                    if (depth > 2 || !obj) return {};
                    const result = {};
                    try {
                        const keys = Object.keys(obj).slice(0, 30);  // 限制數量
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

                // 探索 view
                if (window.view) {
                    results.view = explore(window.view, 'view');
                    // 特別尋找手牌相關
                    if (window.view.DesktopMgr) {
                        results['view.DesktopMgr'] = explore(window.view.DesktopMgr, 'DesktopMgr');
                    }
                }

                // 探索 uiscript
                if (window.uiscript) {
                    results.uiscript = explore(window.uiscript, 'uiscript');
                    // 尋找 UI_DesktopInfo 或類似物件
                    for (const key of Object.keys(window.uiscript)) {
                        if (key.includes('Desktop') || key.includes('Hand') || key.includes('Tile')) {
                            results['uiscript.' + key] = explore(window.uiscript[key], key);
                        }
                    }
                }

                // 探索 GameMgr
                if (window.GameMgr) {
                    results.GameMgr = explore(window.GameMgr, 'GameMgr');
                    if (window.GameMgr.Inst) {
                        results['GameMgr.Inst'] = explore(window.GameMgr.Inst, 'GameMgr.Inst');
                    }
                }

                // 探索 mjcore
                if (window.mjcore) {
                    results.mjcore = explore(window.mjcore, 'mjcore');
                }

                console.log('[Naki] Game Objects Exploration:', JSON.stringify(results, null, 2));
                return results;
            };

            // 🔍 嘗試找到手牌座標
            window.__nakiFindHandTiles = function() {
                const results = { found: false, info: [] };

                try {
                    // 嘗試從 view.DesktopMgr 找
                    if (window.view && window.view.DesktopMgr && window.view.DesktopMgr.Inst) {
                        const dm = window.view.DesktopMgr.Inst;
                        results.info.push('Found DesktopMgr.Inst');

                        // 尋找手牌容器
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

                    // 嘗試從 uiscript 找
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

            // ⭐ 直接遊戲 API 模組
            window.__nakiGameAPI = {
                // 檢查遊戲 API 是否可用
                isAvailable: function() {
                    return !!(window.view && window.view.DesktopMgr && window.view.DesktopMgr.Inst);
                },

                // 獲取遊戲狀態
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

                // 獲取手牌信息
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

                // 獲取當前可用操作
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

                // ⭐ 探索操作相關的 API
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

                // ⭐ 深度探索副露 API（當有吃/碰/槓機會時調用）
                deepExploreNaki: function() {
                    try {
                        const dm = window.view.DesktopMgr.Inst;
                        const mr = dm.mainrole;

                        // 操作類型名稱
                        const opNames = {
                            0: 'none', 1: 'dapai', 2: 'chi', 3: 'pon',
                            4: 'ankan', 5: 'minkan', 6: 'kakan', 7: 'riichi',
                            8: 'tsumo', 9: 'ron', 10: 'kyushu', 11: 'babei'
                        };

                        const result = {
                            // 當前操作列表詳情
                            oplist: dm.oplist ? dm.oplist.map((o, idx) => ({
                                index: idx,
                                type: o.type,
                                typeName: opNames[o.type] || 'unknown',
                                combination: o.combination || [],
                                timeoutMs: o.timeoutMs,
                                // 嘗試獲取更多屬性
                                allKeys: Object.keys(o)
                            })) : [],

                            // DesktopMgr 狀態
                            dmState: {
                                choosed_op: dm.choosed_op,
                                gamestate: dm.gamestate,
                                seat: dm.seat,
                                // 查找所有 op 相關屬性
                                opRelatedProps: Object.keys(dm).filter(k =>
                                    k.toLowerCase().includes('op') ||
                                    k.toLowerCase().includes('choose') ||
                                    k.toLowerCase().includes('action')
                                )
                            },

                            // mainrole 所有方法（完整列表）
                            mainroleMethods: Object.keys(mr).filter(k => typeof mr[k] === 'function').sort(),

                            // mainrole 所有屬性
                            mainroleProps: Object.keys(mr).filter(k => typeof mr[k] !== 'function').slice(0, 50),

                            // DesktopMgr 所有方法
                            dmMethods: Object.keys(dm).filter(k => typeof dm[k] === 'function').sort(),

                            // 嘗試找到 ActionButtonManager 或類似的 UI 管理器
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

                // ⭐ 嘗試執行吃操作（測試用）
                testChi: function(combIndex = 0) {
                    try {
                        const dm = window.view.DesktopMgr.Inst;
                        const mr = dm.mainrole;

                        console.log('[Naki Test] Testing Chi...');
                        console.log('[Naki Test] oplist:', JSON.stringify(dm.oplist));

                        // 找到吃操作
                        const chiOp = dm.oplist?.find(o => o.type === 2);
                        if (!chiOp) {
                            return { success: false, error: 'No chi operation available' };
                        }

                        const chiIndex = dm.oplist.findIndex(o => o.type === 2);
                        console.log('[Naki Test] Chi found at index:', chiIndex, 'combinations:', chiOp.combination);

                        // 嘗試方法 1: 設置 choosed_op 然後調用 DoOperation
                        dm.choosed_op = chiIndex;

                        // 如果有多個組合，需要選擇
                        if (chiOp.combination && chiOp.combination.length > 1) {
                            console.log('[Naki Test] Multiple combinations, selecting:', combIndex);
                            // 可能需要設置 choosed_op_combine 或類似屬性
                            if (dm.choosed_op_combine !== undefined) {
                                dm.choosed_op_combine = combIndex;
                            }
                        }

                        // 嘗試各種方法
                        const results = [];

                        // 方法 1: DoOperation
                        if (typeof mr.DoOperation === 'function') {
                            try {
                                mr.DoOperation(chiIndex);
                                results.push({ method: 'DoOperation', called: true });
                            } catch (e) {
                                results.push({ method: 'DoOperation', error: e.message });
                            }
                        }

                        // 方法 2: QiPaiNoPass
                        if (typeof mr.QiPaiNoPass === 'function' && results.length === 0) {
                            try {
                                mr.QiPaiNoPass();
                                results.push({ method: 'QiPaiNoPass', called: true });
                            } catch (e) {
                                results.push({ method: 'QiPaiNoPass', error: e.message });
                            }
                        }

                        // 方法 3: 找其他可能的方法
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

                // ⭐ 嘗試執行碰操作（測試用）
                testPon: function() {
                    try {
                        const dm = window.view.DesktopMgr.Inst;
                        const mr = dm.mainrole;

                        console.log('[Naki Test] Testing Pon...');

                        // 找到碰操作
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
                },

                // 直接選擇手牌 (使用遊戲內部方法)
                selectTile: function(tileIndex) {
                    try {
                        const mr = window.view.DesktopMgr.Inst.mainrole;
                        if (!mr || !mr.hand || tileIndex >= mr.hand.length) {
                            console.error('[Naki API] Invalid tile index:', tileIndex);
                            return false;
                        }

                        const tile = mr.hand[tileIndex];
                        console.log('[Naki API] Selecting tile:', tileIndex, tile.val);

                        // 調用遊戲內部的選擇方法
                        mr.setChoosePai(tile, true);
                        return true;
                    } catch (e) {
                        console.error('[Naki API] selectTile error:', e);
                        return false;
                    }
                },

                // 直接打牌 (使用遊戲內部方法) - 不需要座標！
                discardTile: function(tileIndex) {
                    try {
                        const mr = window.view.DesktopMgr.Inst.mainrole;
                        if (!mr || !mr.hand) {
                            console.error('[Naki API] mainrole.hand not available');
                            return false;
                        }

                        // 支援超出範圍的索引（摸牌）
                        const actualIndex = Math.min(tileIndex, mr.hand.length - 1);
                        const tile = mr.hand[actualIndex];

                        if (!tile) {
                            console.error('[Naki API] Tile not found at index:', actualIndex);
                            return false;
                        }

                        console.log('[Naki API] Discarding tile:', actualIndex, 'val:', tile.val);

                        // 使用遊戲內部 API：選擇牌 → 立即執行打牌
                        mr.setChoosePai(tile, true);
                        mr.DoDiscardTile();
                        console.log('[Naki API] DoDiscardTile called');

                        return true;
                    } catch (e) {
                        console.error('[Naki API] discardTile error:', e);
                        return false;
                    }
                },

                // ⭐ 執行跳過操作 - 使用 cancel_operation API
                pass: function() {
                    try {
                        const dm = window.view.DesktopMgr.Inst;
                        if (!dm) {
                            console.error('[Naki API] No DesktopMgr');
                            return false;
                        }

                        // 先檢查是否有操作可以跳過
                        console.log('[Naki API] Pass check - oplist:', dm.oplist ? dm.oplist.map(o => o.type) : 'none');

                        // ⭐ 使用 NetAgent cancel_operation (對吃/碰/槓機會有效)
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

                // ⭐ 執行副露操作 (吃/碰/槓/和/立直) - 使用 NetAgent API
                executeOperation: function(opType, combinationIndex = 0) {
                    try {
                        const dm = window.view.DesktopMgr.Inst;

                        // 檢查操作是否可用
                        if (!dm.oplist || dm.oplist.length === 0) {
                            console.error('[Naki API] No operations available');
                            return false;
                        }

                        if (!window.app || !window.app.NetAgent) {
                            console.error('[Naki API] NetAgent not available');
                            return false;
                        }

                        // ⭐ 自摸/榮和 (type 8/9) 優先處理 - 使用 inputOperation
                        // 因為 hora 需要從 oplist 中動態偵測是 tsumo(8) 還是 ron(9)
                        if (opType === 8 || opType === 9) {
                            // 找 oplist 中的 hora 操作 (可能是 8 或 9)
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

                        // ⭐ 立直 (type 7) 使用 inputOperation
                        if (opType === 7) {
                            const tile = op.combination && op.combination[0] ? op.combination[0] : null;
                            if (!tile) {
                                console.error('[Naki API] Riichi: no tile specified');
                                return false;
                            }
                            // 判斷是否摸切 (如果打的牌是摸牌)
                            const mr = dm.mainrole;
                            const isMoqie = mr.hand && mr.hand.length === 14; // 14張牌表示剛摸牌

                            window.app.NetAgent.sendReq2MJ('FastTest', 'inputOperation', {
                                type: 7,
                                tile: tile,
                                moqie: isMoqie,
                                timeuse: 1
                            });
                            console.log('[Naki API] Sent riichi:', { tile, moqie: isMoqie });
                            return true;
                        }

                        // ⭐ 吃/碰/槓 (type 2/3/4/5/6) 使用 inputChiPengGang
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

                // 直接執行操作 (舊方法，保留相容性)
                executeOp: function(opType) {
                    return this.executeOperation(opType);
                },

                // ⭐ 使用遊戲內部資訊計算牌的螢幕座標
                getTileScreenPosition: function(tileIndex) {
                    try {
                        const mr = window.view.DesktopMgr.Inst.mainrole;
                        if (!mr || !mr.hand) return null;

                        const actualIndex = Math.min(tileIndex, mr.hand.length - 1);
                        const tile = mr.hand[actualIndex];
                        if (!tile || !tile.mySelf || !tile.mySelf.transform) return null;

                        const pos3d = tile.mySelf.transform.position;
                        if (!pos3d) return null;

                        // 從 3D 座標轉換到螢幕座標
                        // 基於實測數據：
                        // - 3D x 範圍約 -7.5 到 11.5 對應螢幕 x
                        // - 3D y 約 -7.6 對應螢幕底部手牌位置
                        // - 螢幕尺寸 1920x1080
                        const canvas = document.querySelector('canvas');
                        if (!canvas) return null;

                        const rect = canvas.getBoundingClientRect();
                        const scaleX = rect.width / 1920;
                        const scaleY = rect.height / 1080;

                        // 3D 到 2D 投影（基於觀察的線性映射）
                        // x: 3D 11.5 → 螢幕左側, 3D -7.5 → 螢幕右側
                        // 中心點約在 3D x=2 處
                        const screenCenterX = 960;
                        const scale3dToScreen = 80;  // 每個 3D 單位約 80 螢幕像素
                        const screenX = screenCenterX - (pos3d.x - 2) * scale3dToScreen;

                        // y: 手牌固定在底部
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

                // ⭐ 使用計算座標點擊牌（備用方案）
                clickTileByPosition: function(tileIndex) {
                    const pos = this.getTileScreenPosition(tileIndex);
                    if (!pos) {
                        console.error('[Naki API] Cannot get tile position for index:', tileIndex);
                        return false;
                    }

                    console.log('[Naki API] Clicking tile by position:', tileIndex, 'at', pos.x.toFixed(0), pos.y.toFixed(0));

                    // 點擊兩次（選擇 + 確認）
                    window.__nakiAutoPlay.click(pos.x, pos.y, '牌 #' + (tileIndex + 1));
                    setTimeout(() => {
                        window.__nakiAutoPlay.click(pos.x, pos.y, '確認');
                    }, 300);

                    return true;
                },

                // 智能執行動作 (先嘗試直接 API，失敗則使用座標點擊)
                smartExecute: function(actionType, params) {
                    console.log('[Naki API] Smart execute:', actionType, JSON.stringify(params));

                    // 操作類型映射
                    const opTypeMap = {
                        'chi': 2,
                        'pon': 3,
                        'ankan': 4,
                        'minkan': 5,
                        'kan': 5,      // 預設為明槓
                        'kakan': 6,
                        'riichi': 7,
                        'tsumo': 8,
                        'ron': 9,
                        'hora': -1,    // 特殊處理：需要從 oplist 偵測是 tsumo(8) 還是 ron(9)
                        'kyushu': 10
                    };

                    // ⭐ 先檢查遊戲狀態
                    const gameState = this.getGameState();
                    console.log('[Naki API] Game state:', JSON.stringify(gameState));

                    // 先嘗試直接 API
                    let success = false;

                    try {
                        if (this.isAvailable()) {
                            switch (actionType) {
                                case 'discard':
                                    // 打牌：使用直接 API
                                    success = this.discardTile(params.tileIndex);
                                    if (success) {
                                        console.log('[Naki API] Discard via direct API');
                                        return true;
                                    }
                                    break;

                                case 'pass':
                                    // 跳過：使用直接 API
                                    console.log('[Naki API] Attempting pass...');
                                    success = this.pass();
                                    console.log('[Naki API] Pass result:', success);
                                    if (success) {
                                        console.log('[Naki API] Pass via direct API');
                                        return true;
                                    }
                                    break;

                                case 'chi':
                                    // ⭐ 吃操作：需要传递 chiIndex 来选择正确的组合
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
                                    // ⭐ 和牌：自動偵測是 tsumo(8) 還是 ron(9)
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
                                            // 嘗試備用方案：直接點擊和牌按鈕
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
                                    // 副露/和牌操作：使用直接 API
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
                                    // 立直：先使用 UI 點擊（需要選擇打哪張牌）
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
                }
            };

            // 包裝 WebSocket
            window.WebSocket = function(url, protocols) {
                // 創建原始 WebSocket
                const ws = protocols !== undefined
                    ? new OriginalWebSocket(url, protocols)
                    : new OriginalWebSocket(url);

                const socketId = socketCounter++;

                // 記錄所有 WebSocket 連接用於調試
                console.log('[Naki] WebSocket created:', url);
                sendToSwift('websocket_debug', { socketId: socketId, url: url, message: 'WebSocket created' });

                // 檢測是否為雀魂 WebSocket（包括所有已知的服務器域名）
                const isMajsoul = url.includes('majsoul') ||
                                  url.includes('maj-soul') ||
                                  url.includes('mahjongsoul') ||
                                  url.includes('mjs') ||
                                  url.includes('gateway');

                if (isMajsoul) {
                    console.log('[Naki] Detected Majsoul WebSocket:', url);
                    sendToSwift('websocket_open', { socketId: socketId, url: url });

                    // ⭐ 保存 WebSocket 連接供自動打牌使用
                    window.__nakiMajsoulSockets[socketId] = ws;

                    // 監聽 open 事件
                    ws.addEventListener('open', function() {
                        sendToSwift('websocket_connected', { socketId: socketId });
                    });

                    // 監聽 message 事件
                    ws.addEventListener('message', function(event) {
                        try {
                            if (event.data instanceof ArrayBuffer) {
                                const base64 = arrayBufferToBase64(event.data);
                                sendToSwift('websocket_message', {
                                    socketId: socketId,
                                    direction: 'receive',
                                    data: base64,
                                    dataType: 'arraybuffer'
                                });
                            } else if (event.data instanceof Blob) {
                                blobToBase64(event.data, function(base64) {
                                    sendToSwift('websocket_message', {
                                        socketId: socketId,
                                        direction: 'receive',
                                        data: base64,
                                        dataType: 'blob'
                                    });
                                });
                            }
                        } catch (e) {
                            // 忽略錯誤
                        }
                    });

                    // 監聽 close 事件
                    ws.addEventListener('close', function(event) {
                        // ⭐ 移除已關閉的 WebSocket
                        delete window.__nakiMajsoulSockets[socketId];
                        sendToSwift('websocket_closed', {
                            socketId: socketId,
                            code: event.code,
                            reason: event.reason
                        });
                    });

                    // 監聽 error 事件
                    ws.addEventListener('error', function() {
                        sendToSwift('websocket_error', { socketId: socketId });
                    });

                    // ⭐ 保存原始 send 方法供自動打牌使用
                    const originalSend = ws.send.bind(ws);
                    ws.__originalSend = originalSend;

                    // 攔截 send 方法來監聽發送的數據
                    ws.send = function(data) {
                        try {
                            if (data instanceof ArrayBuffer) {
                                const base64 = arrayBufferToBase64(data);
                                sendToSwift('websocket_message', {
                                    socketId: socketId,
                                    direction: 'send',
                                    data: base64,
                                    dataType: 'arraybuffer'
                                });
                            } else if (data instanceof Blob) {
                                blobToBase64(data, function(base64) {
                                    sendToSwift('websocket_message', {
                                        socketId: socketId,
                                        direction: 'send',
                                        data: base64,
                                        dataType: 'blob'
                                    });
                                });
                            }
                        } catch (e) {
                            // 忽略錯誤
                        }
                        // 始終調用原始 send
                        return originalSend(data);
                    };
                }

                return ws;
            };

            // 複製靜態屬性
            window.WebSocket.CONNECTING = OriginalWebSocket.CONNECTING;
            window.WebSocket.OPEN = OriginalWebSocket.OPEN;
            window.WebSocket.CLOSING = OriginalWebSocket.CLOSING;
            window.WebSocket.CLOSED = OriginalWebSocket.CLOSED;

            // 保持原型鏈
            window.WebSocket.prototype = OriginalWebSocket.prototype;

            // 攔截 console.log 發送到 Swift
            const originalLog = console.log;
            console.log = function(...args) {
                originalLog.apply(console, args);
                try {
                    sendToSwift('console_log', { message: args.map(a => String(a)).join(' ') });
                } catch (e) {}
            };

            console.log('[Naki] WebSocket interceptor installed (with auto-play support)');
            sendToSwift('interceptor_ready', { version: '3.0', autoplay: true });
        })();
        """
    }

    /// 創建用於注入的 WKUserScript
    static func createUserScript() -> WKUserScript {
        return WKUserScript(
            source: injectionScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }
}

// MARK: - WebSocket Message Handler

/// 處理從 JavaScript 傳來的 WebSocket 消息
class WebSocketMessageHandler: NSObject, WKScriptMessageHandler {

    // MARK: - Properties

    /// 雀魂協議橋接器
    private let majsoulBridge = MajsoulBridge()

    /// MJAI 事件回調
    var onMJAIEvent: (([String: Any]) -> Void)?

    /// WebSocket 狀態回調
    var onWebSocketStatusChanged: ((Bool) -> Void)?

    /// 自動打牌發送結果回調
    var onAutoPlayResult: ((Bool, String?) -> Void)?

    /// 連接的 WebSocket 數量
    private var connectedSockets: Set<Int> = []

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {

        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }

        let data = body["data"] as? [String: Any] ?? [:]

        switch type {
        case "interceptor_ready":
            let version = data["version"] as? String ?? "unknown"
            let autoplay = data["autoplay"] as? Bool ?? false
            wsLog("[JS] WebSocket interceptor is ready (v\(version), autoplay=\(autoplay))")

        case "console_log":
            if let message = data["message"] as? String {
                wsLog("[JS] \(message)")
            }

        case "websocket_debug":
            if let url = data["url"] as? String,
               let msg = data["message"] as? String {
                wsLog("[WS] DEBUG: \(msg) - \(url)")
            }

        case "websocket_open":
            handleWebSocketOpen(data)

        case "websocket_connected":
            handleWebSocketConnected(data)

        case "websocket_message":
            handleWebSocketMessage(data)

        case "websocket_close", "websocket_closed":
            handleWebSocketClose(data)

        case "websocket_error":
            handleWebSocketError(data)

        // ⭐ 自動打牌 UI 自動化相關消息
        case "autoplay_click":
            if let x = data["x"] as? Double, let y = data["y"] as? Double {
                wsLog("[AutoPlay] Click at: (\(Int(x)), \(Int(y)))")
            }

        case "autoplay_tile_click":
            if let index = data["index"] as? Int {
                wsLog("[AutoPlay] Tile click: index=\(index)")
            }

        case "autoplay_button_click":
            if let action = data["action"] as? String {
                wsLog("[AutoPlay] Button click: \(action)")
            }

        case "autoplay_error":
            if let error = data["error"] as? String {
                wsLog("[AutoPlay] Error: \(error)")
                onAutoPlayResult?(false, error)
            }

        default:
            break
        }
    }

    // MARK: - Message Handlers

    private func handleWebSocketOpen(_ data: [String: Any]) {
        guard let socketId = data["socketId"] as? Int,
              let url = data["url"] as? String else { return }

        wsLog("[WS] WebSocket opening: \(socketId) - \(url)")
    }

    private func handleWebSocketConnected(_ data: [String: Any]) {
        guard let socketId = data["socketId"] as? Int else { return }

        connectedSockets.insert(socketId)
        wsLog("[WS] WebSocket connected: \(socketId)")
        onWebSocketStatusChanged?(true)
    }

    private func handleWebSocketMessage(_ data: [String: Any]) {
        guard let base64Data = data["data"] as? String,
              let direction = data["direction"] as? String else { return }

        // 解碼 Base64 數據
        guard let binaryData = Data(base64Encoded: base64Data) else {
            wsLog("[WS] Failed to decode base64 data")
            return
        }

        // 打印數據大小用於調試
        let dirSymbol = direction == "receive" ? "←" : "→"
        wsLog("[WS] \(dirSymbol) \(binaryData.count) bytes")

        // 處理發送的消息（用於跟蹤請求）
        if direction == "send" {
            // 發送的消息是請求，需要解析以跟蹤 msgId
            if let parsed = majsoulBridge.parseRaw(binaryData),
               let method = parsed["method"] as? String {
                wsLog("[WS] Sent request: \(method)")
            }
            return
        }

        // 處理接收的消息
        guard direction == "receive" else { return }

        // 使用 MajsoulBridge 解析消息
        if let mjaiEvents = majsoulBridge.parse(binaryData) {
            for event in mjaiEvents {
                if let eventType = event["type"] as? String {
                    wsLog("[MJAI] \(eventType): \(formatEvent(event))")
                }
                onMJAIEvent?(event)
            }
        } else {
            // 調試：顯示解析結果
            let parser = LiqiParser()
            if let parsed = parser.parse(binaryData),
               let method = parsed["method"] as? String {
                wsLog("[Liqi] \(method)")

                // 調試 ActionPrototype
                if method == ".lq.ActionPrototype",
                   let data = parsed["data"] as? [String: Any] {
                    if let actionName = data["name"] as? String {
                        wsLog("[Action] \(actionName): \(data)")
                    } else {
                        wsLog("[Action] No name found in data: \(data)")
                    }
                }
            }
        }
    }

    /// 格式化事件用於日誌
    private func formatEvent(_ event: [String: Any]) -> String {
        var parts: [String] = []

        if let actor = event["actor"] as? Int {
            parts.append("actor=\(actor)")
        }
        if let pai = event["pai"] as? String {
            parts.append("pai=\(pai)")
        }
        if let target = event["target"] as? Int {
            parts.append("target=\(target)")
        }
        if let consumed = event["consumed"] as? [String] {
            parts.append("consumed=\(consumed.joined(separator: ","))")
        }
        if let bakaze = event["bakaze"] as? String {
            parts.append("bakaze=\(bakaze)")
        }
        if let kyoku = event["kyoku"] as? Int {
            parts.append("kyoku=\(kyoku)")
        }

        return parts.isEmpty ? "" : "[\(parts.joined(separator: ", "))]"
    }

    private func handleWebSocketClose(_ data: [String: Any]) {
        guard let socketId = data["socketId"] as? Int else { return }

        connectedSockets.remove(socketId)
        wsLog("[WS] WebSocket closed: \(socketId)")

        if connectedSockets.isEmpty {
            onWebSocketStatusChanged?(false)
        }
    }

    private func handleWebSocketError(_ data: [String: Any]) {
        if let socketId = data["socketId"] as? Int {
            wsLog("[WS] WebSocket error: \(socketId)")
        }
    }

    // MARK: - Public Methods

    /// 重置橋接器狀態（開始新遊戲時調用）
    func reset() {
        majsoulBridge.reset()
    }

    /// 完整重置橋接器狀態（頁面重新載入時調用）
    func fullReset() {
        majsoulBridge.fullReset()
        connectedSockets.removeAll()
    }
}
