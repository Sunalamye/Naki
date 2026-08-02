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
    // 導出到全域
    // ========================================

    window.__nakiCore = {
        arrayBufferToBase64: arrayBufferToBase64,
        base64ToArrayBuffer: base64ToArrayBuffer,
        blobToBase64: blobToBase64,
        sendToSwift: sendToSwift
    };

    // 向後兼容：直接導出到 window
    window.__nakiArrayBufferToBase64 = arrayBufferToBase64;
    window.__nakiBase64ToArrayBuffer = base64ToArrayBuffer;
    window.__nakiBlobToBase64 = blobToBase64;
    window.__nakiSendToSwift = sendToSwift;

    // ========================================
    // 手牌高亮（Unity WebGL）— 依牌的身分，不算位置
    // ========================================
    //
    // 遊戲畫每一張牌時，`_MainTex_ST` 就寫著這張牌在圖集裡的格子——
    // 也就是**它正在畫哪一張牌**。所以不需要算螢幕座標、不需要排序、
    // 不需要對照第幾張：直接問「這張是不是 9m」就好。
    //
    // 實測對照（2026-07-31，與 /game/hand 逐張吻合）：
    //   手牌 3m 3m 5mr 7m 8m 9m 3p 5p 6p 8p 2s 3s 4s + 摸 9p
    //   UV  .3/.5 .3/.5 0/.5 .7/.5 .8/.5 .9/.5 .3/.25 … .9/.25
    //   → v 決定花色（0.5=萬 0.25=筒 0.75=索 0=字），u 決定數字，u=0 是紅五
    //   兩張 3m 的 UV 完全相同，證明 UV 編的是牌面而不是位置。
    //
    // 先前用「投影後排序取第幾張」的做法已移除：手牌張數會變（摸/打）、
    // 立直時牌會被抬起、畫面邊緣還有別的牌混進同一列，每一項都會讓索引錯位。
    (function () {
        var SUIT_BY_V = { '0.5': 'm', '0.25': 'p', '0.75': 's' };
        var HONORS = ['E', 'S', 'W', 'N', 'P', 'F', 'C'];

        var targets = {};          // tile 名稱 -> [r,g,b]
        var popupColor = null;
        var installed = false;
        var locCache = new Map();
        var totalFrames = 0;
        var baselineSigs = new Set();   // 沒有副露機會時看過的 draw 簽章
        var baselineFrames = 0;
        var objIds = new WeakMap();
        var nextObjId = 1;
        var tintedCount = 0;

        function objId(o) {
            if (!o) return 0;
            var id = objIds.get(o);
            if (!id) { id = nextObjId++; objIds.set(o, id); }
            return id;
        }

        function locsFor(gl, prog) {
            if (locCache.has(prog)) return locCache.get(prog);
            var st = gl.getUniformLocation(prog, '_MainTex_ST');
            // 顏色 uniform 名稱依 shader 而異：手牌是 _Tint、其他 UI 是 _Color
            var color = gl.getUniformLocation(prog, '_Tint')
                     || gl.getUniformLocation(prog, '_Color');
            var L = color ? { st: st, color: color } : null;
            locCache.set(prog, L);
            return L;
        }

        /// 由圖集 UV 反推這是哪一張牌（MJAI 記法）
        function tileFromST(st) {
            if (!st || st.length < 4) return null;
            var u = Math.round(st[2] * 10) / 10;
            var v = Math.round(st[3] * 100) / 100;
            var suit = SUIT_BY_V[String(v)];
            if (suit) {
                var n = Math.round(u * 10);
                if (n === 0) return '5' + suit + 'r';   // u=0 是該花色的紅五
                if (n >= 1 && n <= 9) return String(n) + suit;
                return null;
            }
            if (v === 0) {
                // 字牌：u × 10 直接就是 HONORS 的索引，不能再減 1。
                //
                // 2026-08-01 live 對局實測（手牌 E W W P C）：
                //   u=0   ×37  → E
                //   u=0.2 ×74  → W（兩張，次數正好兩倍）
                //   u=0.4 ×37  → P
                //   u=0.6 ×37  → C
                // 原本的 -1 會讓 E 變 null、W 變 S、P 變 N、C 變 F——
                // 不是解不出來，是**染錯牌**。
                var idx = Math.round(u * 10);
                return (idx >= 0 && idx < HONORS.length) ? HONORS[idx] : null;
            }
            return null;
        }

        function install(gl) {
            if (installed) return;
            installed = true;

            var origDraw = gl.drawElements.bind(gl);
            gl.drawElements = function (mode, count, type, offset) {
                var prog = gl.getParameter(gl.CURRENT_PROGRAM);
                if (!prog) return origDraw(mode, count, type, offset);

                var L;
                try { L = locsFor(gl, prog); } catch (e) { L = null; }
                if (!L) return origDraw(mode, count, type, offset);

                var color = null;

                // 一、手牌：用 UV 認出是哪張牌
                if (L.st && count === 6 && Object.keys(targets).length) {
                    try {
                        var tile = tileFromST(gl.getUniform(prog, L.st));
                        if (tile && targets[tile]) color = targets[tile];
                    } catch (e) { /* 取不到就當作不是牌 */ }
                }

                // 二、副露彈出面板：位置與 UV 都認不出，改用「與平時畫面比對」。
                //
                // 原本的規則是「出現頻率 < 25% 的 draw 就當成按鈕」，太鬆——
                // 動畫、特效、過場 UI 都是低頻的，結果整個畫面都被染色（實測確認）。
                //
                // 改法：沒有副露機會時持續收集畫面的 draw 簽章當**基準線**；
                // 有機會時只染「基準線裡沒出現過」的簽章。按鈕是機會出現才有的東西，
                // 這個判準比頻率精確得多。
                var sig = count + '/' + objId(prog) + '/'
                        + objId(gl.getParameter(gl.TEXTURE_BINDING_2D));
                if (!popupColor) {
                    // 沒機會時：這一幀畫的東西都算平時就有的
                    baselineSigs.add(sig);
                    baselineFrames++;
                } else if (!color && baselineFrames > 120 && !baselineSigs.has(sig)) {
                    // 基準線要夠厚才敢下判斷，否則剛開局什麼都會被當成按鈕
                    color = popupColor;
                }

                if (!color) return origDraw(mode, count, type, offset);

                // 只在這一次 draw 期間覆寫顏色，畫完立刻還原，不留狀態給遊戲。
                //
                // color 可以是 [r,g,b] 或 [r,g,b,a]。給了第 4 個分量就用它當 alpha，
                // 用來把「不推薦的牌」調淡；沒給就沿用遊戲原本的 alpha。
                var prev = gl.getUniform(prog, L.color);
                var baseAlpha = (prev && prev.length > 3) ? prev[3] : 1;
                var alpha = (color.length > 3) ? color[3] * baseAlpha : baseAlpha;
                gl.uniform4f(L.color, color[0], color[1], color[2], alpha);
                var r = origDraw(mode, count, type, offset);
                if (prev && prev.length > 3) {
                    gl.uniform4f(L.color, prev[0], prev[1], prev[2], prev[3]);
                }
                tintedCount++;
                return r;
            };

            var origRAF = window.requestAnimationFrame.bind(window);
            window.requestAnimationFrame = function (cb) {
                return origRAF(function (t) { totalFrames++; return cb(t); });
            };
        }

        function context() {
            var c = document.getElementById('unity-canvas');
            return c ? c.getContext('webgl2') : null;
        }

        window.__nakiHighlight = {
            /// list: [{tile:"9m", color:[r,g,b]}] 或 color:[r,g,b,a]；popup: [r,g,b] 或 null
            set: function (list, popup) {
                targets = {};
                (list || []).forEach(function (m) { targets[m.tile] = m.color; });
                popupColor = (popup && popup.length === 3) ? popup : null;
                var gl = context();
                if (gl) install(gl);
                return Object.keys(targets).length;
            },
            clear: function () { targets = {}; popupColor = null; return true; },
            state: function () {
                return { targets: targets, popup: popupColor,
                         tinted: tintedCount, totalFrames: totalFrames,
                         baselineSigs: baselineSigs.size, baselineFrames: baselineFrames };
            },
            /// 除錯用：列出當前這一幀在手牌區畫出的牌（依 UV 反推）
            decode: function (st) { return tileFromST(st); }
        };
    })();

    console.log('[Naki] 核心模組已載入');
})();
