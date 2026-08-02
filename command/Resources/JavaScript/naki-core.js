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
     *
     * ⚠️ `type` 不是自由字串：Swift 端只認得
     * `WebSocketInterceptor.swift` 的 `BridgeMessageType`（那張表是契約的唯一真相來源）。
     * 送不在表上的 type 不會靜默消失，但也不會被處理——Swift 會丟一行
     * 「未知的 bridge 訊息 type」warning 然後丟掉。要加新訊息就兩端一起加，
     * `BridgeMessageContractTests` 會做雙向比對，單邊改一定紅。
     *
     * envelope 固定是 `{ type, data, timestamp }`；`data` 的欄位 schema 見上述契約表。
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

        // 基準線收集要「夠久」才敢判斷什麼是副露面板。
        //
        // 這個門檻以前掛在 `baselineFrames`，而那個計數器**加在 drawElements 裡**
        // ——它數的是 draw call 不是幀。live 實測一幀約 356 個 draw call，
        // 所以「>120」在開頁後不到一幀就滿足，等於沒有保護。現在改成在 rAF 回呼
        // 裡加，數的是真的幀；60fps 下 120 幀約 2 秒。
        var BASELINE_FRAME_MIN = 120;

        // 基準線簽章的上限。簽章含 objId，而 Unity 會重建 program／texture，
        // 每次重建都產生新的 id → 舊版的 Set 只增不減，一局下來單向長大。
        var BASELINE_SIG_LIMIT = 4096;

        var targets = {};          // tile 名稱 -> [r,g,b]
        var targetCount = 0;       // Object.keys(targets).length 的快取（每個 draw 都要看）
        var popupColor = null;
        var installed = false;
        // program 物件當 key：Unity 刪掉的 program 不該被這裡留住
        var locCache = new WeakMap();
        var totalFrames = 0;
        // 沒有副露機會時看過的 draw 簽章。用 Map 而不是 Set 是為了拿它的插入順序當 LRU。
        var baselineSigs = new Map();
        var baselineFrames = 0;    // 真的幀數（rAF 回呼次數）
        var objIds = new WeakMap();
        var nextObjId = 1;
        var tintedCount = 0;

        // ── 由 hook 追蹤的 GL 狀態 ───────────────────────────────────────
        //
        // 舊版每個 draw call 都問 `gl.getParameter(CURRENT_PROGRAM)` 與
        // `gl.getParameter(TEXTURE_BINDING_2D)`：一幀 356 個 draw call × 2 次跨 JS↔引擎
        // 的狀態查詢。這兩個值只會由 `useProgram` / `bindTexture` 改變，攔下來自己記
        // 就完全不必查——draw 熱路徑上的同步查詢歸零。
        var currentProgram = null;
        var activeUnit = 0;
        var texture2D = [];        // activeUnit -> 綁在 TEXTURE_2D 的 texture

        // install() 攔下來的方法；uninstall() 要原封不動放回去
        var hooks = [];

        function objId(o) {
            if (!o) return 0;
            var id = objIds.get(o);
            if (!id) { id = nextObjId++; objIds.set(o, id); }
            return id;
        }

        function locsFor(gl, prog) {
            var cached = locCache.get(prog);
            if (cached !== undefined) return cached;
            var st = gl.getUniformLocation(prog, '_MainTex_ST');
            // 顏色 uniform 名稱依 shader 而異：手牌是 _Tint、其他 UI 是 _Color
            var color = gl.getUniformLocation(prog, '_Tint')
                     || gl.getUniformLocation(prog, '_Color');
            var L = color ? { st: st, color: color } : null;
            locCache.set(prog, L);
            return L;
        }

        /// 把一個簽章記進基準線，並維持上限。
        ///
        /// 命中時**不動**（draw 熱路徑上每幀幾百次，不做無謂的 Map 搬移）；
        /// 只有在已經滿載、真的會發生淘汰時才把命中的簽章移到尾端，
        /// 讓淘汰順序是 LRU 而不是「先進先出砍掉還在用的」。
        function noteBaseline(sig) {
            if (baselineSigs.has(sig)) {
                if (baselineSigs.size >= BASELINE_SIG_LIMIT) {
                    baselineSigs.delete(sig);
                    baselineSigs.set(sig, 1);
                }
                return;
            }
            baselineSigs.set(sig, 1);
            while (baselineSigs.size > BASELINE_SIG_LIMIT) {
                baselineSigs.delete(baselineSigs.keys().next().value);
            }
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

        /// 攔一個方法，並記下**還原它需要的一切**。
        ///
        /// 只存「bind 過的原函式」是不夠的：bound function 與原本掛在物件上的那一個
        /// 不是同一個物件，還原之後 `gl.drawElements === 原本那個` 會是 false，
        /// 也就無法機械證明「真的拆乾淨了」。這裡連「原本是不是自有屬性」都記下來，
        /// 還原時繼承來的方法用 `delete` 回到 prototype，自有的才寫回去。
        ///
        /// - Parameter makeWrapper: 收到「可直接呼叫的原函式」，回傳 wrapper
        function hookMethod(target, name, makeWrapper) {
            var hadOwn = Object.prototype.hasOwnProperty.call(target, name);
            var previous = target[name];
            var wrapper = makeWrapper(previous.bind(target));
            target[name] = wrapper;
            hooks.push({ target: target, name: name, hadOwn: hadOwn,
                         previous: previous, wrapper: wrapper });
            return wrapper;
        }

        function install(gl) {
            if (installed) return;
            installed = true;
            hooks = [];

            // 攔 useProgram / activeTexture / bindTexture，把 draw 熱路徑要用的 GL 狀態
            // 記在 JS 這一側。install 當下先問一次，把「現在是什麼」接上；
            // 之後全部由 hook 維護，drawElements 裡不再有任何 getParameter。
            currentProgram = gl.getParameter(gl.CURRENT_PROGRAM);
            activeUnit = (gl.getParameter(gl.ACTIVE_TEXTURE) || gl.TEXTURE0) - gl.TEXTURE0;
            texture2D = [];
            texture2D[activeUnit] = gl.getParameter(gl.TEXTURE_BINDING_2D);

            var TEXTURE0 = gl.TEXTURE0;
            var TEXTURE_2D = gl.TEXTURE_2D;

            hookMethod(gl, 'useProgram', function (orig) {
                return function (program) {
                    currentProgram = program;
                    return orig(program);
                };
            });

            hookMethod(gl, 'activeTexture', function (orig) {
                return function (unit) {
                    activeUnit = unit - TEXTURE0;
                    return orig(unit);
                };
            });

            hookMethod(gl, 'bindTexture', function (orig) {
                return function (target, texture) {
                    if (target === TEXTURE_2D) texture2D[activeUnit] = texture;
                    return orig(target, texture);
                };
            });

            hookMethod(gl, 'drawElements', function (origDraw) {
                return function (mode, count, type, offset) {
                    var prog = currentProgram;
                    if (!prog) return origDraw(mode, count, type, offset);

                    var L;
                    try { L = locsFor(gl, prog); } catch (e) { L = null; }
                    if (!L) return origDraw(mode, count, type, offset);

                    var color = null;

                    // 一、手牌：用 UV 認出是哪張牌
                    if (L.st && count === 6 && targetCount) {
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
                    //
                    // 簽章只在真的要用時才組（字串串接也在每幀幾百次的路徑上）。
                    if (!popupColor) {
                        // 沒機會時：這一幀畫的東西都算平時就有的
                        noteBaseline(count + '/' + objId(prog) + '/'
                                     + objId(texture2D[activeUnit]));
                    } else if (!color && baselineFrames > BASELINE_FRAME_MIN) {
                        // 基準線要夠厚才敢下判斷，否則剛開局什麼都會被當成按鈕
                        var sig = count + '/' + objId(prog) + '/'
                                + objId(texture2D[activeUnit]);
                        if (!baselineSigs.has(sig)) color = popupColor;
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
            });

            // 幀計數在這裡，不在 drawElements 裡：一幀有數百個 draw call，
            // 加在 draw 上得到的是 draw call 數，拿來當「基準線收了幾幀」是錯的。
            hookMethod(window, 'requestAnimationFrame', function (origRAF) {
                return function (cb) {
                    return origRAF(function (t) {
                        totalFrames++;
                        if (!popupColor) baselineFrames++;
                        return cb(t);
                    });
                };
            });
        }

        /// 完全解除：把攔下來的函式原封不動放回去，狀態歸零。
        ///
        /// `install()` 以前是單向的——裝上去就再也拿不掉，連確認「關掉之後遊戲跑得
        /// 一樣快嗎」都做不到。只有在 wrapper **還是我們裝的那一個**時才還原：
        /// 別人又包了一層時貿然還原會把對方的 wrapper 一起拆掉。
        ///
        /// - Returns: 是否已經完全還原（有任何一個 wrapper 被別人蓋掉就回 false）
        function uninstall() {
            if (!installed) return false;

            var complete = true;
            // 反序拆，跟裝上去的順序對稱
            for (var i = hooks.length - 1; i >= 0; i--) {
                var h = hooks[i];
                if (h.target[h.name] !== h.wrapper) {
                    complete = false;       // 上面還疊著別人的 wrapper，不動它
                    continue;
                }
                if (h.hadOwn) {
                    h.target[h.name] = h.previous;
                } else {
                    // 原本是繼承來的：刪掉自有屬性就回到 prototype 的那一個
                    delete h.target[h.name];
                }
            }

            hooks = [];
            installed = false;
            locCache = new WeakMap();
            baselineSigs = new Map();
            baselineFrames = 0;
            currentProgram = null;
            texture2D = [];
            activeUnit = 0;
            return complete;
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
                targetCount = Object.keys(targets).length;
                popupColor = (popup && popup.length === 3) ? popup : null;
                var gl = context();
                if (gl) install(gl);
                return targetCount;
            },
            /// 停止染色。`clear(true)` 連 hook 一起拆掉（wrapper 還原、基準線歸零）；
            /// 不帶參數維持原行為——只是不再染，hook 留著，基準線也留著。
            /// 每次切 `.off` 都整組拆掉會讓下一次開啟必須重新收 120 幀基準線。
            clear: function (full) {
                targets = {};
                targetCount = 0;
                popupColor = null;
                if (full) return uninstall();
                return true;
            },
            /// 明確解除安裝（回 true 代表所有 wrapper 都還原了）
            uninstall: function () { return uninstall(); },
            state: function () {
                return { targets: targets, popup: popupColor,
                         installed: installed,
                         tinted: tintedCount, totalFrames: totalFrames,
                         baselineSigs: baselineSigs.size,
                         baselineSigLimit: BASELINE_SIG_LIMIT,
                         baselineFrames: baselineFrames,
                         baselineFrameMin: BASELINE_FRAME_MIN };
            },
            /// 除錯用：列出當前這一幀在手牌區畫出的牌（依 UV 反推）
            decode: function (st) { return tileFromST(st); }
        };
    })();

    console.log('[Naki] 核心模組已載入');
})();
