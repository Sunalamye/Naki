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
        return ctx;
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
        }
    };

    window.__nakiPlugins = api;
    console.log('[Naki Plugins] naki-plugins.js 已載入（apiVersion 1，Phase 1 observe）');
})();
