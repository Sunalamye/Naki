//
//  naki-plugins.js
//  Naki
//
//  第三方插件的 hook 執行環境（bundled 模組，apiVersion: 1）。
//  契約見 docs/plugin-api-v1.md 與 docs/plugin-system-design.md §7。
//
//  載入順序：naki-core → naki-websocket → naki-plugins（本檔）。
//  本檔提供 window.__nakiPlugins.register / dispatch。
//  第三方插件的原始碼與授權（grants）由 Swift 端經「第二個 WKUserScript」注入：
//    window.__nakiPluginGrants = { id: {...} };   // 先設
//    window.__nakiPlugins.register({ id, onReceive, ... });   // 插件自己呼叫
//
//  Phase 1 只支援 observe（唯讀）。rewriteReceive / injectSend 屬 Phase 2/3，
//  ctx 目前不提供 replace / drop / sendRequest。
//
(function () {
    'use strict';

    if (window.__nakiPluginsLoaded) {
        return;
    }
    window.__nakiPluginsLoaded = true;

    var sendToSwift = (window.__nakiCore && window.__nakiCore.sendToSwift)
        || window.__nakiSendToSwift
        || function () {};

    var TYPE_NOTIFY = 1;
    var TYPE_REQUEST = 2;
    var TYPE_RESPONSE = 3;

    // manifest 是權威。grants 由 Swift 注入，插件在 JS 裡自稱什麼一律不算數。
    // 形狀：{ id: { capabilities:[String], methods:[String], priority:Number,
    //              observeNakiTraffic:Bool, settings:Object } }
    function grantFor(id) {
        var g = window.__nakiPluginGrants;
        return (g && Object.prototype.hasOwnProperty.call(g, id)) ? g[id] : null;
    }

    // 已註冊插件：id -> { spec, grant }
    var registry = new Map();
    // 連續失敗計數：id -> Number（達上限自動停用本頁面生命週期）
    var failures = new Map();
    var FAILURE_LIMIT = 10;
    // 自己維護的 msgId -> method（只為 RESPONSE 對回；與 nicknameMask 各一份，刻意隔離）
    var pendingMethods = new Map();
    var PENDING_LIMIT = 256;

    // ---- L3 送出側（injectSend，§7.6/§7.7b）----
    // 插件注入用 msgId 區段 64000–65500（Naki 自送收窄為 60000–63999）。
    var pluginMsgId = 64000;
    function nextPluginMsgId() {
        var v = pluginMsgId;
        pluginMsgId = (v >= 65500) ? 64000 : (v + 1);
        return v;
    }
    // 插件注入的 msgId -> 發起插件 id（回應路由，§7.7b）
    var injectedMsgIds = new Map();

    function encodeVarint(n) {
        var out = [];
        n = n >>> 0;
        while (n > 0x7f) { out.push((n & 0x7f) | 0x80); n = n >>> 7; }
        out.push(n & 0x7f);
        return out;
    }

    // 組 REQUEST envelope：[2][msgId LE 2B][0a][methodLen][method][12][payloadLen][payload]
    // field1=method、field2=payload；REQUEST 無 XOR（§7.4 送出側協定事實）。
    function buildRequestEnvelope(msgId, method, payload) {
        var mb = [];
        for (var i = 0; i < method.length; i++) mb.push(method.charCodeAt(i) & 0xff);
        var out = [2, msgId & 0xff, (msgId >> 8) & 0xff];
        out.push(0x0a); out = out.concat(encodeVarint(mb.length)).concat(mb);
        out.push(0x12); out = out.concat(encodeVarint(payload.length));
        for (var j = 0; j < payload.length; j++) out.push(payload[j] & 0xff);
        return new Uint8Array(out);
    }

    function uint8ToBase64(u8) {
        if (window.__nakiCore && window.__nakiCore.arrayBufferToBase64) {
            return window.__nakiCore.arrayBufferToBase64(u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength));
        }
        var bin = '';
        for (var i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
        return btoa(bin);
    }

    function pluginLog(id, msg) {
        try {
            sendToSwift('plugin_event', { id: id, kind: 'log', msg: String(msg) });
        } catch (e) { /* log 不該反過來弄壞 dispatch */ }
    }

    // 只在需要時報一次某插件的內部錯誤，避免對局時間軸被洗版
    function noteFailure(id, err) {
        var n = (failures.get(id) || 0) + 1;
        failures.set(id, n);
        pluginLog(id, 'hook 拋錯（第 ' + n + ' 次）：' + (err && err.message ? err.message : err));
        if (n >= FAILURE_LIMIT) {
            registry.delete(id);
            pluginLog(id, '連續失敗達 ' + FAILURE_LIMIT + ' 次，本頁面生命週期內停用');
        }
    }

    // ---- 輕量 envelope 解析（自包含，不依賴 naki-websocket 的私有符號）----

    function readVarint(b, i, end) {
        var shift = 0, result = 0;
        while (i < end) {
            var byte = b[i];
            result |= (byte & 0x7f) << shift;
            i++;
            if ((byte & 0x80) === 0) return [result >>> 0, i];
            shift += 7;
            if (shift > 35) return null;
        }
        return null;
    }

    function decodeAscii(b, from, to) {
        var s = '';
        for (var i = from; i < to; i++) s += String.fromCharCode(b[i]);
        return s;
    }

    // 掃 envelope body 的 field 1(method) 與 field 2(payload byte range)
    function parseBody(b, start) {
        var i = start, method = null, payload = null;
        while (i < b.length) {
            var tag = readVarint(b, i, b.length);
            if (!tag) break;
            var field = Math.floor(tag[0] / 8);
            var wire = tag[0] & 7;
            i = tag[1];
            if (wire === 2) {
                var len = readVarint(b, i, b.length);
                if (!len) break;
                var from = len[1];
                var to = from + len[0];
                if (to > b.length) break;
                if (field === 1) method = decodeAscii(b, from, to);
                else if (field === 2) payload = { from: from, to: to };
                i = to;
            } else if (wire === 0) {
                var v = readVarint(b, i, b.length);
                if (!v) break;
                i = v[1];
            } else if (wire === 5) { i += 4; }
            else if (wire === 1) { i += 8; }
            else break;
        }
        return { method: method, payload: payload };
    }

    // bytes(Uint8Array) -> { type, msgId, method, payload }
    // NOTIFY 無 msgId，body 從 index 1；REQUEST/RESPONSE 跳過 2 bytes msgId，body 從 index 3。
    function parseEnvelope(bytes) {
        if (!bytes || bytes.length < 1) return null;
        var type = bytes[0];
        var msgId = null;
        var bodyStart;
        if (type === TYPE_NOTIFY) {
            bodyStart = 1;
        } else if (type === TYPE_REQUEST || type === TYPE_RESPONSE) {
            if (bytes.length < 3) return null;
            msgId = bytes[1] | (bytes[2] << 8);
            bodyStart = 3;
        } else {
            return null; // 非 liqi envelope，不派發
        }
        var body = parseBody(bytes, bodyStart);
        return { type: type, msgId: msgId, method: body.method, payload: body.payload };
    }

    function rememberIfRequest(env, direction) {
        if (direction === 'send' && env.type === TYPE_REQUEST && env.msgId != null && env.method) {
            pendingMethods.set(env.msgId, env.method);
            if (pendingMethods.size > PENDING_LIMIT) {
                pendingMethods.delete(pendingMethods.keys().next().value);
            }
        }
    }

    // RESPONSE envelope 不帶 method，靠送出時記下的 msgId 對回（可能對不上 → null）
    function resolveMethod(env, direction) {
        if (env.method) return env.method;
        if (direction === 'receive' && env.type === TYPE_RESPONSE && env.msgId != null) {
            var m = pendingMethods.get(env.msgId);
            if (m != null) { pendingMethods.delete(env.msgId); return m; }
        }
        return null;
    }

    function makeCtx(raw, env, method, isNaki, grant) {
        var ctx = {
            direction: raw.direction,
            socketId: raw.wsId,
            url: raw.url || '',
            type: env.type,
            msgId: env.msgId,
            method: method,
            bytes: raw.bytes,
            payload: env.payload,
            isNaki: isNaki,
            log: function (msg) { pluginLog(grant.__id, msg); }
        };
        // Phase 2 起才有 settings；沒宣告就不掛這個屬性（與契約 §6 一致）
        if (grant.settings && typeof grant.settings === 'object') {
            ctx.settings = grant.settings;
        }

        // Phase 2：rewriteReceive → ctx.replace（等長就地改寫）。
        // 只在「有 rewriteReceive capability + receive 方向 + method 不在禁改名單」時掛。
        // raw.bytes 是遊戲那份 buffer 的 view，set 就地改 ⇒ 遊戲與 Naki 都看到改後的。
        var caps = grant.capabilities || [];
        if (raw.direction === 'receive'
            && caps.indexOf('rewriteReceive') !== -1
            && !isForbiddenMethod(method, grant)) {
            ctx.replace = function (newBytes) {
                // 等長是 v1 硬約束（protobuf varint 長度前綴，改長度要連動所有外層）。
                if (!newBytes || typeof newBytes.length !== 'number'
                    || newBytes.length !== raw.bytes.length) {
                    return false;   // fail-open：長度不等 ⇒ 不改、原樣通過
                }
                try {
                    raw.bytes.set(newBytes);
                    return true;
                } catch (e) {
                    return false;
                }
            };
        }

        // L3：injectSend → ctx.sendRequest（送一筆 REQUEST）。受總開關把關。
        if (caps.indexOf('injectSend') !== -1) {
            ctx.sendRequest = function (method, payloadBytes) {
                // 總開關（§8.1）：預設 false，關著一律拒——對應「送 Liqi request 前先確認」。
                if (!window.__nakiPluginsMayModifyOutbound) {
                    return { ok: false, reason: 'outbound_disabled' };
                }
                if (typeof method !== 'string' || !method) {
                    return { ok: false, reason: 'bad_method' };
                }
                var payload = payloadBytes || new Uint8Array(0);
                var msgId = nextPluginMsgId();
                var envBytes = buildRequestEnvelope(msgId, method, payload);
                var b64;
                try { b64 = uint8ToBase64(envBytes); }
                catch (e) { return { ok: false, reason: 'encode_failed' }; }

                var ws = window.__nakiWebSocket;
                var r = (ws && ws.sendRaw) ? ws.sendRaw(b64) : { success: false, reason: 'no_sendRaw' };
                if (!r || !r.success) {
                    return { ok: false, reason: (r && r.reason) || 'send_failed' };
                }
                // 登記 msgId → 發起插件（§7.7b 回應路由）
                injectedMsgIds.set(msgId, grant.__id);
                if (injectedMsgIds.size > 256) {
                    injectedMsgIds.delete(injectedMsgIds.keys().next().value);
                }
                pluginLog(grant.__id, 'sendRequest ' + method + ' msgId=' + msgId + '（送出，成功要看 RESPONSE）');
                return { ok: true, msgId: msgId };
            };
        }
        return ctx;
    }

    // §8.2 預設禁改名單：這些 method 是 Naki 判斷牌局的真相來源，改了畫面看不出來、
    // 但會污染推薦與自動打牌。除非 manifest 明確在 rewriteAllow 逐一解除（§11 #5）。
    var FORBIDDEN_METHODS = [
        '.lq.ActionPrototype',
        '.lq.FastTest.syncGame',
        '.lq.NotifyGameEndResult'
    ];
    function isForbiddenMethod(method, grant) {
        if (method == null) return true;
        if (FORBIDDEN_METHODS.indexOf(method) === -1) return false;
        // manifest 逐一解除：grant.rewriteAllow 含這個 method 才放行
        var allow = grant.rewriteAllow || [];
        return allow.indexOf(method) === -1;
    }

    var api = {
        // 插件進入點自己呼叫。manifest（grant）是權威。
        register: function (spec) {
            if (!spec || typeof spec.id !== 'string') {
                return false;
            }
            var grant = grantFor(spec.id);
            if (!grant) {
                // 未啟用或未知 id。不 log 封包內容，只記 id。
                pluginLog(spec.id, 'register 被拒：未啟用或未知 id');
                return false;
            }
            if (registry.has(spec.id)) {
                pluginLog(spec.id, 'register 被拒：重複註冊');
                return false;
            }
            // 把 id 綁進 grant 供 ctx.log 使用（不動原物件語意）
            grant.__id = spec.id;
            registry.set(spec.id, { spec: spec, grant: grant });
            failures.set(spec.id, 0);
            pluginLog(spec.id, 'registered（capabilities=' + (grant.capabilities || []).join(',') + '）');
            return true;
        },

        // naki-websocket.js 的 handleMessage 在中段呼叫。
        // raw = { direction:'send'|'receive', wsId:Number, url:String, bytes:Uint8Array }
        dispatch: function (raw) {
            if (registry.size === 0) return;
            if (!raw || !raw.bytes) return;

            var env = parseEnvelope(raw.bytes);
            if (!env) return;

            rememberIfRequest(env, raw.direction);
            var method = resolveMethod(env, raw.direction);
            var isNaki = (env.msgId != null && env.msgId >= 60000);

            // §7.7b 回應路由：插件注入的 request（msgId 64000–65500）的 RESPONSE 回來時，
            // **只**回派給發起它的那一個插件（其餘看不到，§7.7 不變），走 onInjectResponse。
            if (raw.direction === 'receive' && env.msgId != null && injectedMsgIds.has(env.msgId)) {
                var originId = injectedMsgIds.get(env.msgId);
                injectedMsgIds.delete(env.msgId);
                var origin = registry.get(originId);
                if (origin && typeof origin.spec.onInjectResponse === 'function') {
                    var rctx = makeCtx(raw, env, method, isNaki, origin.grant);
                    rctx.inResponseTo = env.msgId;
                    rctx.timedOut = false;
                    try { origin.spec.onInjectResponse(rctx); }
                    catch (e) { noteFailure(originId, e); }
                }
                return;   // 注入回應不進一般鏈
            }

            // 建鏈：isNaki 走「只含宣告 observeNakiTraffic 的 observer」另一條，
            // 與一般鏈分開，同一則訊息永遠只屬於其中一條（契約 §7.7）。
            var chain = [];
            registry.forEach(function (entry) {
                var g = entry.grant;
                if (isNaki && !g.observeNakiTraffic) return;
                // 白名單在 Naki 這側過濾；method 為 null（RESPONSE 對不回）視為不命中
                if (method == null) return;
                var methods = g.methods || [];
                if (methods.indexOf(method) === -1) return;
                chain.push(entry);
            });
            if (chain.length === 0) return;

            // priority 升冪，同值 id 字典序
            chain.sort(function (a, b) {
                var pa = a.grant.priority || 0, pb = b.grant.priority || 0;
                if (pa !== pb) return pa - pb;
                return a.spec.id < b.spec.id ? -1 : (a.spec.id > b.spec.id ? 1 : 0);
            });

            for (var k = 0; k < chain.length; k++) {
                var entry = chain[k];
                var fn = raw.direction === 'receive' ? entry.spec.onReceive : entry.spec.onSend;
                if (typeof fn !== 'function') continue;
                var ctx = makeCtx(raw, env, method, isNaki, entry.grant);
                try {
                    fn(ctx);   // Phase 1 observe：回傳值忽略，ctx 無 replace/drop（改不到封包）
                    failures.set(entry.spec.id, 0);
                } catch (e) {
                    noteFailure(entry.spec.id, e);
                }
            }
        },

        // 診斷用（唯讀）：目前註冊了哪些插件
        list: function () {
            var out = [];
            registry.forEach(function (entry, id) {
                out.push({ id: id, capabilities: entry.grant.capabilities || [] });
            });
            return out;
        },

        // ---- 熱插拔（runtime enable/disable，免 reload）----
        //
        // Swift 端 toggle 時呼叫：先 setGrant 下發權威 grant，再由呼叫端 evaluateJavaScript
        // 插件源碼（源碼會呼叫 register，register 讀 grant 生效）。disable 反向移除。
        // 這條路不經 WKUserScript，所以不必重新載入頁面。

        // 設定/更新某 id 的 grant（register 前必須先有 grant，否則 register 會被拒）
        setGrant: function (id, grant) {
            if (typeof id !== 'string' || !grant) return false;
            window.__nakiPluginGrants = window.__nakiPluginGrants || {};
            window.__nakiPluginGrants[id] = grant;
            return true;
        },

        // 熱停用：從 registry 移除、清 grant、歸零失敗計數。回可觀測結果。
        disable: function (id) {
            var wasRegistered = registry.delete(id);
            failures.delete(id);
            if (window.__nakiPluginGrants) delete window.__nakiPluginGrants[id];
            pluginLog(id, 'disabled（熱停用，免 reload）');
            return { ok: true, wasRegistered: wasRegistered };
        }
    };

    window.__nakiPlugins = api;
    console.log('[Naki Plugins] naki-plugins.js 已載入（apiVersion 1，Phase 1 observe）');
})();
