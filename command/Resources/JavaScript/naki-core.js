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

        // ── 名字圖層遮蔽（`nameMask`）──
        // 暱稱文字有自己的字型 atlas。鎖定那張貼圖後，把它的 draw alpha 設 0 就
        // 只有名字消失（實測「暫無稱號」、分數、局數、手牌、按鈕都不受影響）。
        // 協定層的 `__nakiHideNames` 只能在 authGame 那刻改 bytes、中途開沒用；
        // 這一層即時生效。認不到圖層就什麼都不遮——寧可不遮，不要遮錯。
        // 名字圖層的判準（實測 live 得到）：
        //
        //   1. **那一幀只有一個 draw 用這張貼圖** —— 四家名字批次成單一 draw；
        //      共用字型 atlas 的貼圖同幀會有好幾個（實測 78/84/132/216 四個）。
        //   2. **字數接近協定算出的總字數** —— `naki-websocket.js` 解 authGame 時
        //      量四家暱稱共幾個字。用接近而非相等：協定與畫面會差一兩個字
        //      （實測 24 vs 22），要求相等永遠對不上。
        //
        // **刻意不「鎖定」某個 texture 物件**：動態字型 atlas 會被重建，鎖住物件
        // 就會在重建後失效（實測鎖定後只遮到 2 次）。改成每幀重新判定，
        // 用上一幀的結論遮這一幀——UI 幀間是穩定的，而且對重建免疫。
        var nameMaskOn = false;
        var nameTargets = new Map();    // 上一幀判定要遮的貼圖
        var nameMasked = 0;
        var NAME_MIN_COUNT = 42;        // 批次文字下界（一般 UI 圖片 6～36）
        // 校準用：把每幀的大文字 draw 依繪製順序編號，一次只遮一個，
        // 從外面截圖比對就能指認哪一個是名字（判準猜不出來就用量的）。
        var nameProbe = -1;             // 校準中：只遮這個序號（-1＝不遮）
        var nameOrder = 0;              // 本幀已見的大文字 draw 序號
        var nameProbeLog = [];          // 累積中的本幀
        var nameProbeLast = [];         // 上一幀（讀的是這份，才不會讀到半幀）
        var nameProbeTex = [];          // 上一幀 序號 → texture

        // 自我校準：逐一遮掉候選、讀回畫面比對，看哪一個讓「四個分散的小區塊」消失。
        //
        // 判準只有畫面本身。shader、貼圖、index 數都試過而且都不可靠——字數指紋在
        // 人機場直接失效（「電腦（簡單）」由客戶端產生，封包裡沒有），貼圖用量與
        // index 數又分不出同為 132 的另一個 draw。名字唯一固定的特徵是**幾何**：
        // 四家座位分散在畫面四周，遮掉它會讓變動像素「散佈很廣、總量很少」，
        // 其他 UI 文字都集中在一處。這與版面縮放、人數、名字長度都無關。
        // 目標會失效：換局／重載後貼圖被重建，鎖定的那張就再也不會被畫。
        // 沒人看著就會靜默不遮，所以用「連續幾幀一個都沒遮到」當觸發重新校準。
        var nameIdle = 0;
        var nameHitThisFrame = false;
        var NAME_IDLE_FRAMES = 120;     // 約 2 秒

        var calib = null;               // { step, base, results, total }
        var calibResult = null;         // 選中的候選（校準完才有）
        var calibLog = null;            // 每個候選的量測值（驗收看得到才敢信）
        var CAL_STRIDE = 4;             // 讀回畫面的取樣間隔（省 CPU）
        var CAL_RETRY_FRAMES = 600;     // 校準不出來時的重試間隔（約 10 秒）
        var calibCooldown = 0;
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
            // UI／文字 shader 的識別特徵：字型 atlas 是 alpha-only，Unity 用
            // `_TextureSampleAdd` 把 RGB 補成 1。3D 牌的 shader 沒有這個 uniform——
            // 少了這一格，名字判定會把整桌的牌一起算進候選（實測 606-index 的牌
            // draw 全部混進來）。
            var ui = !!gl.getUniformLocation(prog, '_TextureSampleAdd');
            var L = color ? { st: st, color: color, ui: ui } : null;
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

        /// 讀回這一幀的畫面（稀疏取樣）。回傳 Uint8Array 或 null。
        function grabFrame(gl) {
            var w = gl.drawingBufferWidth, h = gl.drawingBufferHeight;
            if (!w || !h) return null;
            var buf = new Uint8Array(w * h * 4);
            try { gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, buf); }
            catch (e) { return null; }
            return { buf: buf, w: w, h: h };
        }

        /// 比較兩幀，回傳變動像素數與外接框（取樣座標）。
        function frameDelta(a, b) {
            var w = a.w, h = a.h, n = 0;
            var x0 = w, x1 = -1, y0 = h, y1 = -1;
            var quad = [0, 0, 0, 0];    // 四象限各有幾個變動像素
            for (var y = 0; y < h; y += CAL_STRIDE) {
                var row = y * w * 4;
                for (var x = 0; x < w; x += CAL_STRIDE) {
                    var i = row + x * 4;
                    var d = Math.abs(a.buf[i] - b.buf[i])
                          + Math.abs(a.buf[i + 1] - b.buf[i + 1])
                          + Math.abs(a.buf[i + 2] - b.buf[i + 2]);
                    if (d > 40) {
                        n++;
                        if (x < x0) x0 = x; if (x > x1) x1 = x;
                        if (y < y0) y0 = y; if (y > y1) y1 = y;
                        quad[(y < h / 2 ? 0 : 2) + (x < w / 2 ? 0 : 1)]++;
                    }
                }
            }
            var quads = 0;
            quad.forEach(function (c) { if (c > 2) quads++; });
            return { n: n, spanX: x1 - x0, spanY: y1 - y0, quads: quads, w: w, h: h };
        }

        /// 校準的一步：讀回剛畫完的這一幀，記錄差異，然後排下一個候選。
        function calibStep(gl) {
                var f = grabFrame(gl);
                if (!f) { calib = null; nameProbe = -1; return; }
                if (calib.step === 0) {
                    calib.base = f;
                    calib.total = nameProbeLast.length;
                    if (!calib.total) { calib = null; return; }
                    nameProbe = 0;
                    calib.step = 1;
                    return;
                }
                var ord = calib.step - 1;
                var d = frameDelta(calib.base, f);
                // 名字的幾何特徵：四家分坐四方 ⇒ 變動像素**散在至少 3 個象限**，
                // 而且總量很少（每個名牌只有十幾個字）。少了象限這一條，大廳畫面
                // 也會選出候選——那裡只有自己的名字，集中在單一角落。
                var spread = d.spanX / f.w;
                var ok = d.n > 8 && spread > 0.4 && d.quads >= 3;
                calib.results.push({ ord: ord, n: d.n, spread: spread, quads: d.quads,
                                     score: ok ? spread / d.n : 0 });
                if (calib.step > calib.total) {
                    var best = null;
                    calib.results.forEach(function (r) {
                        if (r.score > 0 && (!best || r.score > best.score)) best = r;
                    });
                    nameProbe = -1;
                    nameTargets.clear();
                    if (best) {
                        var tex = nameProbeTex[best.ord];
                        if (tex) nameTargets.set(tex, best.ord);
                        calibResult = best;
                    } else {
                        calibCooldown = CAL_RETRY_FRAMES;   // 沒有合格候選（例如在大廳）
                    }
                    calibLog = calib.results;
                    calib = null;
                    return;
                }
                nameProbe = calib.step;
                calib.step++;
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

                    // 〇、名字圖層：用上一幀的判定遮這一幀（見上方註解）
                    if (L.ui && count >= NAME_MIN_COUNT) {
                        var ord = nameOrder++;
                        var tx = texture2D[activeUnit];
                        if (nameProbeLog.length < 40) {
                            nameProbeLog.push({ ord: ord, count: count });
                            nameProbeTex[ord] = tx;
                        }
                        if (tx) {
                            if (nameProbe >= 0 && ord === nameProbe) {
                                var cv = gl.getUniform(prog, L.color);
                                gl.uniform4f(L.color, cv[0], cv[1], cv[2], 0);
                                var cr = origDraw(mode, count, type, offset);
                                gl.uniform4f(L.color, cv[0], cv[1], cv[2], cv[3]);
                                nameMasked++;
                                return cr;
                            }
                            if (nameMaskOn && nameTargets.has(tx)) {
                                nameHitThisFrame = true;
                                var pv = gl.getUniform(prog, L.color);
                                gl.uniform4f(L.color, pv[0], pv[1], pv[2], 0);
                                var rr = origDraw(mode, count, type, offset);
                                gl.uniform4f(L.color, pv[0], pv[1], pv[2], pv[3]);
                                nameMasked++;
                                return rr;
                            }
                        }
                    }

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
                        nameOrder = 0;
                        if (nameProbeLog.length) { nameProbeLast = nameProbeLog; nameProbeLog = []; }
                        if (nameMaskOn && !calib) {
                            if (calibCooldown > 0) {
                                calibCooldown--;
                            } else if (!nameTargets.size) {
                                calib = { step: 0, base: null, results: [], total: 0 };
                            } else {
                                nameIdle = nameHitThisFrame ? 0 : nameIdle + 1;
                                if (nameIdle > NAME_IDLE_FRAMES) {
                                    nameTargets.clear(); nameIdle = 0;
                                }
                            }
                        }
                        nameHitThisFrame = false;
                        var r = cb(t);
                        // 讀回畫面必須在遊戲畫完之後，所以校準跑在 cb 後面
                        if (calib) calibStep(gl);
                        return r;
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
            decode: function (st) { return tileFromST(st); },

            /// 名字圖層遮蔽開關。回傳 `locked=false` 代表還沒認出名字圖層——
            /// 此時什麼都不會遮，呼叫端應顯示「未生效」而不是假裝成功。
            setNameMask: function (on) {
                nameMaskOn = !!on;
                if (nameMaskOn) {
                    var g = context(); if (g) install(g);
                    calibCooldown = 0;
                }
                return { enabled: nameMaskOn, installed: installed,
                         calibrating: !!calib, targets: nameTargets.size };
            },
            nameMaskStatus: function () {
                return { enabled: nameMaskOn, installed: installed,
                         masked: nameMasked, targets: nameTargets.size,
                         calibrating: !!calib, picked: calibResult, idle: nameIdle,
                         trials: calibLog, frames: totalFrames };
            },

            /// 驗收用：只遮第 `ord` 個 UI 文字 draw（-1 關閉）。校準跑的就是這件事，
            /// 開放出來才能從外面用截圖獨立確認「遮的是不是名字」。
            maskProbe: function (ord) {
                nameProbe = (ord === undefined || ord === null) ? -1 : ord | 0;
                if (nameProbe >= 0) { var gp = context(); if (gp) install(gp); }
                return { probe: nameProbe, draws: nameProbeLast.slice(0, 16) };
            },


        };
    })();

    /// wasm 記憶體捕獲。
    ///
    /// 遊戲的 Unity instance 存在 script scope（`onUnityReady` 內的區域變數），事後撈不到；
    /// 而攔 `onUnityReady`／`createUnityInstance` 也沒用——頁面用**函式宣告**定義它們，
    /// 會直接覆蓋我們掛的 accessor。`WebAssembly.instantiate*` 是頁面覆蓋不掉的入口，
    /// 而且 wasm 線性記憶體就從那裡出來。純唯讀捕獲，不改參數也不改回傳。
    (function () {
        function keep(memory) {
            if (!memory || window.__nakiWasmMemory) return;
            window.__nakiWasmMemory = memory;
            window.__nakiHeap = function () { return new Uint8Array(memory.buffer); };
            console.log('[Naki] 已捕獲 wasm memory:', memory.buffer.byteLength);
        }
        function scan(result, imports) {
            try {
                if (imports && imports.env && imports.env.memory) keep(imports.env.memory);
                var inst = result && (result.instance || result);
                if (inst && inst.exports && inst.exports.memory) keep(inst.exports.memory);
            } catch (e) {}
            return result;
        }
        ['instantiate', 'instantiateStreaming'].forEach(function (name) {
            var orig = WebAssembly[name];
            if (typeof orig !== 'function') return;
            WebAssembly[name] = function (src, imports) {
                var p = orig.apply(this, arguments);
                return (p && p.then) ? p.then(function (r) { return scan(r, imports); }) : scan(p, imports);
            };
        });
    })();

    console.log('[Naki] 核心模組已載入');
})();
