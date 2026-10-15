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
//  observe 唯讀；rewriteReceive → ctx.replace（等長就地改寫，isNaki 流量不給）、
//  rewriteSend → send 方向的 ctx.replace（可改長度與 method，受 L3 總開關把關；v2 草案，docs/plan/plugin-v2.md §B）、
//  injectSend → ctx.sendRequest（受 L3 總開關把關）。沒有 drop。
//  送出守衛（manifest sendGuard，docs/plan/plugin-v2-b2.md）：守衛方法 fail-closed，插件污染後持續到頁面重載。
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
    // envelope 解析與 naki-websocket 共用 naki-core 那一份；缺了就不派發（fail-open）
    var parseEnvelope = (window.__nakiCore && window.__nakiCore.parseEnvelope)
        || function () { return null; };

    var TYPE_REQUEST = 2;
    var TYPE_RESPONSE = 3;

    // manifest 是權威。grants 由 Swift 注入，插件在 JS 裡自稱什麼一律不算數。
    // 但這是「防誤用、不防惡意插件」：grants 與總開關 `__nakiPluginsMayModifyOutbound` 都是同一個 realm 裡
    // 可寫的全域變數，惡意插件能直接改寫（見 docs/plugin-api-v1.md §8）。
    // 形狀：{ id: { capabilities:[String], methods:[String], priority:Number,
    //              observeNakiTraffic:Bool, settings:Object } }
    function grantFor(id) {
        var g = window.__nakiPluginGrants;
        return (g && Object.prototype.hasOwnProperty.call(g, id)) ? g[id] : null;
    }

    // 已註冊插件：id -> { spec, grant }
    var registry = new Map();
    // 連續失敗計數：id -> { hook名: Number }（同一個 hook 連續達上限才自動停用；
    // 別的 hook 成功不能沖掉它，否則永遠拋錯的 onReceive 會被正常的 onRecommendations 蓋掉）
    var failures = new Map();
    var FAILURE_LIMIT = 10;
    var diagnostics = { dispatches: 0, parsed: 0, hooks: 0, lastMethod: null,
        recommendationUpdates: 0, recommendationHooks: 0, lastError: null };
    function cleanup(entry) {
        if (!entry || typeof entry.spec.onDisable !== 'function') return;
        try { entry.spec.onDisable({ log: function (msg) { pluginLog(entry.spec.id, msg); } }); }
        catch (e) { pluginLog(entry.spec.id, 'cleanup failed: ' + e.message); }
    }
    // 自己維護的 (連線, msgId) -> method（只為 RESPONSE 對回；與 nicknameMask 各一份，刻意隔離）。
    // RESPONSE 只回到送出它的那條連線，所以一律以連線＋msgId 為鍵（審查第三輪第 2 條）。
    var pendingMethods = new Map();
    function msgKey(socketId, msgId) { return socketId + ':' + msgId; }
    var PENDING_LIMIT = 256;

    // ---- L3 送出側（injectSend，§7.6/§7.7b）----
    // 插件注入用 msgId 區段 64000–65500（Naki 自送收窄為 60000–63999）。
    var PLUGIN_MSGID_FIRST = 64000, PLUGIN_MSGID_LAST = 65500;
    var pluginMsgId = PLUGIN_MSGID_FIRST;
    function nextPluginMsgId() {
        var v = pluginMsgId;
        pluginMsgId = (v >= PLUGIN_MSGID_LAST) ? PLUGIN_MSGID_FIRST : (v + 1);
        return v;
    }
    // 插件注入的 (連線, msgId) -> 發起插件 id（回應路由，§7.7b）
    var injectedMsgIds = new Map();

    // 守衛只作用在已確認的大廳連線（/gateway，不是 /game-gateway）。對局連線與 .lq.FastTest.* 不進任何守衛路徑。
    function isLobbyUrl(url) { return typeof url === 'string' && url.indexOf('/gateway') !== -1; }

    // ---- 送出守衛（N1／N2，docs/plan/plugin-v2-b2.md §3–§4）----
    // 已污染：插件 id -> 守衛方法 Set。只增不減，活在本閉包裡：disable、setGrant、自動停用、熱重載都碰不到，
    // 頁面重載（本檔重跑）才清空。不受 L3 總開關限制。
    var tainted = new Map();
    var guardLog = [];
    var GUARD_LOG_LIMIT = 256;
    // 守衛擋下時合成的 Error.code。選擇依據見設計 §3.4；遊戲端怎麼顯示未驗證（需 live）。
    var GUARD_ERROR_CODE = 6;
    // 可宣告為守衛的方法：回應型別 field 1 已確認是 Error（docs/protocol/liqi.json），合成的錯誤回應才合型別。
    // PV2-C 把 schema 打包進 App 後改成載入時依 schema 檢查。
    var GUARDABLE_METHODS = [
        'changeCharacterSkin', 'changeMainCharacter', 'changeAvatar', 'useTitle', 'setRandomCharacter',
        'updateCharacterSort', 'setHiddenCharacter', 'changeCharacterView', 'changeCommonView', 'saveCommonViews',
        'useCommonView', 'setLoadingImage', 'sendGiftToCharacter', 'upgradeCharacter', 'addFinishedEnding',
        'receiveEndingReward', 'receiveCharacterRewards', 'mmoActivitySetCharacter', 'mmoActivitySetTeamMember'
    ].map(function (m) { return '.lq.Lobby.' + m; });

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
    function noteFailure(id, hook, err) {
        diagnostics.lastError = { id: id, message: String(err && err.message || err) };
        var f = failures.get(id) || {};
        var n = (f[hook] || 0) + 1;
        f[hook] = n;
        failures.set(id, f);
        pluginLog(id, hook + ' 拋錯（第 ' + n + ' 次）：' + (err && err.message ? err.message : err));
        if (n >= FAILURE_LIMIT) {
            var entry = registry.get(id);
            registry.delete(id);
            cleanup(entry);
            pluginLog(id, '連續失敗達 ' + FAILURE_LIMIT + ' 次，本頁面生命週期內停用');
        }
    }

    function noteSuccess(id, hook) {
        var f = failures.get(id);
        if (f) f[hook] = 0;
    }

    function settle(thenable, id, hook) {
        try { thenable.then(function () { noteSuccess(id, hook); }, function (e) { noteFailure(id, hook, e); }); }
        catch (e) { noteFailure(id, hook, e); }
    }

    function taint(id, grant) {
        var set = tainted.get(id) || new Set();
        var first = !tainted.has(id);
        (grant.sendGuard || []).forEach(function (m) { set.add(m); });
        tainted.set(id, set);
        if (first) {
            try { sendToSwift('plugin_event', { id: id, kind: 'tainted', msg: '已污染：守衛方法到頁面重載前都不會原樣送出' }); }
            catch (e) { /* 通知失敗不影響守衛本身 */ }
        }
    }

    // 守衛這個 method 的插件：目前註冊且 sendGuard 含它的，加上曾污染且當時守衛它的（即使已不在鏈上）
    function guardFor(method) {
        var ids = [];
        registry.forEach(function (entry, id) {
            if ((entry.grant.sendGuard || []).indexOf(method) !== -1) ids.push(id);
        });
        tainted.forEach(function (set, id) {
            if (set.has(method) && ids.indexOf(id) === -1) ids.push(id);
        });
        return ids.length ? { method: method, ids: ids, approved: [], threw: [], async: [] } : null;
    }

    function isNakiMsgId(msgId) {
        var ws = window.__nakiWebSocket;
        return msgId != null && ((msgId >= PLUGIN_MSGID_FIRST && msgId <= PLUGIN_MSGID_LAST)
            || !!(ws && ws.isNakiSent && ws.isNakiSent(msgId)));
    }

    // 守衛者全部有效放行才回 null。已污染者的放行另外要求：仍守衛這個方法、L3 開著（審查第 1 條）
    function guardFailure(guard) {
        if (guard.threw.length) return 'hook_threw';
        if (guard.async.length) return 'async_hook';
        var ids = guard.ids, m = guard.method, i, entry;
        for (i = 0; i < ids.length; i++) if (guard.approved.indexOf(ids[i]) === -1) return 'not_on_chain';
        var taintedHere = ids.filter(function (id) { return tainted.has(id) && tainted.get(id).has(m); });
        for (i = 0; i < taintedHere.length; i++) {
            entry = registry.get(taintedHere[i]);
            if (!entry || (entry.grant.sendGuard || []).indexOf(m) === -1) return 'guard_revoked';
        }
        if (taintedHere.length && !window.__nakiPluginsMayModifyOutbound) return 'outbound_disabled';
        return null;
    }

    function recordGuard(msgId, method, outcome, reason, ids, socketId) {
        guardLog.push({ socketId: socketId == null ? null : socketId, msgId: msgId, method: method, outcome: outcome,
            reason: reason, guards: ids, at: Date.now() });
        if (guardLog.length > GUARD_LOG_LIMIT) guardLog.shift();
    }

    function sameBytes(a, b) {
        if (a.length !== b.length) return false;
        for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
        return true;
    }

    // RESPONSE envelope：field 1 一定寫出空字串，與官方伺服器的形狀相同（見 LiqiEnvelope 註解），
    // payload 只有 field 1 = Error{ code }。守衛方法的 Res 型別 field 1 都是 error（liqi.json）。
    function guardErrorResponse(msgId) {
        var err = [0x08].concat(encodeVarint(GUARD_ERROR_CODE));
        var payload = [0x0a].concat(encodeVarint(err.length), err);
        return new Uint8Array([3, msgId & 0xff, (msgId >> 8) & 0xff, 0x0a, 0x00, 0x12]
            .concat(encodeVarint(payload.length), payload));
    }

    // 頁面上是否有守衛者（已污染，或已註冊且宣告 sendGuard）。查找本身出錯時當成有。
    function guardActive() {
        try {
            if (tainted.size) return true;
            var any = false;
            registry.forEach(function (entry) { if ((entry.grant.sendGuard || []).length) any = true; });
            return any;
        } catch (e) { return true; }
    }

    // 擋下：遊戲的 buffer 還原成原樣，交付用的是完整原始快照（審查第 7 條）。這裡不得拋錯，否則呼叫端會退回送出。
    // 錯誤回應依「原 REQUEST 的方法」建：只有它在 GUARDABLE_METHODS（回應型別 field 1 是 Error）才合成，
    // 否則不回應（審查第二輪第 4 條）。msgId 與原方法另外帶出，本地結案不再讀交付後的 bytes（第二輪第 5 條）。
    function blockSend(raw, origObj, original, msgId, method, origMethod, reason, ids) {
        var response = null;
        try {
            restore(raw, origObj, original);
            recordGuard(msgId, method, 'local_error', reason, ids, raw.wsId);
            pluginLog(ids.join(','), '守衛擋下 ' + method + ' msgId=' + msgId + '（' + reason + '），改回本地錯誤');
            if (msgId != null && GUARDABLE_METHODS.indexOf(origMethod) !== -1) response = guardErrorResponse(msgId);
        } catch (e) { /* 擋下的決定不受記錄或建構失敗影響 */ }
        return { block: true, reason: reason, request: original, response: response,
            socketId: raw.wsId, msgId: msgId, method: origMethod };
    }

    // send 方向的唯一入口。對局連線（以及大廳上的 .lq.FastTest.*）在守衛查找之前就走現行鏈，行為與 main 相同。
    // 大廳上，守衛方法只有三種結局：原樣送出、本地成功（respondLocally，PV2-B2）、本地錯誤。
    // 辨識、跑鏈、鏈後判定都在 try 內（第二輪第 1 條）。出錯時：已知是守衛方法 ⇒ 擋下；已知不是 ⇒ 還原原 bytes 照送；
    // 辨識本身失敗 ⇒ 頁面上有守衛者才擋下（第三輪第 1 條）。
    function guardedSend(raw) {
        if (!isLobbyUrl(raw.url)) return plainChain(raw);
        var origObj = raw.bytes, original = origObj.slice(), env = null, guard = null, identified = false;
        try {
            env = parseEnvelope(origObj);
            if (env && env.method && env.method.indexOf('.lq.FastTest.') === 0) return plainChain(raw, env);
            guard = env && env.type === TYPE_REQUEST && env.method ? guardFor(env.method) : null;
            identified = !!env;
            if (!env) return guardActive() ? blockSend(raw, origObj, original, null, null, null, 'guard_error', []) : undefined;
            if (guard && isNakiMsgId(env.msgId)) {
                return blockSend(raw, origObj, original, env.msgId, env.method, env.method, 'naki_traffic', guard.ids);
            }
            var out = runChain(raw, env, guard);
            if (!guard) return out;
            var reason = guardFailure(guard) || (!sameBytes(original, raw.bytes) ? 'rewritten' : null);
            if (reason) return blockSend(raw, origObj, original, env.msgId, env.method, env.method, reason, guard.ids);
            recordGuard(env.msgId, env.method, 'sent', null, guard.ids, raw.wsId);
            return out;
        } catch (e) {
            if (guard) return blockSend(raw, origObj, original, env.msgId, env.method, env.method, 'dispatch_error', guard.ids);
            if (identified || !guardActive()) {
                restore(raw, origObj, original);
                return undefined;
            }
            return blockSend(raw, origObj, original, env ? env.msgId : null, env && env.method, env && env.method, 'guard_error', []);
        }
    }

    function plainChain(raw, env) {
        env = env || parseEnvelope(raw.bytes);
        return env ? runChain(raw, env, null) : undefined;
    }

    function restore(raw, origObj, original) {
        raw.bytes = origObj;
        if (origObj.length === original.length) origObj.set(original);
    }

    function rememberIfRequest(env, direction, socketId) {
        if (direction === 'send' && env.type === TYPE_REQUEST && env.msgId != null && env.method) {
            pendingMethods.set(msgKey(socketId, env.msgId), env.method);
            if (pendingMethods.size > PENDING_LIMIT) {
                pendingMethods.delete(pendingMethods.keys().next().value);
            }
        }
    }

    // RESPONSE envelope 不帶 method，靠送出時記下的 msgId 對回（可能對不上 → null）
    function resolveMethod(env, direction, socketId) {
        if (env.method) return env.method;
        if (direction === 'receive' && env.type === TYPE_RESPONSE && env.msgId != null) {
            var m = pendingMethods.get(msgKey(socketId, env.msgId));
            if (m != null) { pendingMethods.delete(msgKey(socketId, env.msgId)); return m; }
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

        // rewriteReceive → ctx.replace（等長就地改寫）。
        // 只在「有 rewriteReceive capability + receive 方向 + 非 Naki 流量 + method 不在禁改名單」時掛。
        // raw.bytes 是遊戲那份 buffer 的 view，set 就地改 ⇒ 遊戲與 Naki 都看到改後的。
        var caps = grant.capabilities || [];
        if (raw.direction === 'receive'
            && !isNaki
            && raw.mutable !== false
            && caps.indexOf('rewriteReceive') !== -1
            && !isForbiddenMethod(method, grant)) {
            ctx.replace = function (newBytes) {
                // 等長是 v1 硬約束（protobuf varint 長度前綴，改長度要連動所有外層）。
                if (!newBytes || typeof newBytes.length !== 'number'
                    || newBytes.length !== raw.bytes.length) {
                    return false;   // fail-open：長度不等 ⇒ 不改、原樣通過
                }
                var original = raw.bytes.slice();
                try {
                    raw.bytes.set(newBytes);
                } catch (e) {
                    return false;
                }
                // 等長改寫可以把整個 envelope 換掉：改後重新解析，method 變了或落進禁改名單
                // 就還原並計一次失敗（禁改名單只擋改寫前的 method 等於沒擋）。
                var after = parseEnvelope(raw.bytes);
                var afterMethod = after && (after.method || method);
                if (!after || after.type !== env.type || after.msgId !== env.msgId
                    || afterMethod !== method || isForbiddenMethod(afterMethod, grant)) {
                    raw.bytes.set(original);
                    noteFailure(grant.__id, 'replace', new Error('改寫換掉了 method 或觸及禁改名單，已還原'));
                    return false;
                }
                noteSuccess(grant.__id, 'replace');
                return true;
            };
        }

        // L3：rewriteSend → send 方向的 ctx.replace。整包換掉遊戲要送的 REQUEST（可改長度、可換 method），
        // 換上的 bytes 由 dispatch 交回 ws.send 包裝送出，Swift 也收到換後的（與伺服器看到的一致）。
        // type 與 msgId 不得變（遊戲在等這個 msgId 的回應）；改前改後的 method 都要過 isSendForbidden。
        if (raw.direction === 'send'
            && !isNaki
            && raw.mutable !== false
            && caps.indexOf('rewriteSend') !== -1
            && !isSendForbidden(method)) {
            ctx.replace = function (newBytes) {
                if (!window.__nakiPluginsMayModifyOutbound) return false;
                if (!newBytes || typeof newBytes.length !== 'number') return false;
                var next = new Uint8Array(newBytes);
                var after = parseEnvelope(next);
                if (!after || !isWellFormed(next) || after.type !== TYPE_REQUEST
                    || after.msgId !== env.msgId || isSendForbidden(after.method)) {
                    noteFailure(grant.__id, 'replace', new Error('rewriteSend 不合規（type／msgId 變了、envelope 不完整或觸及送出禁改名單），已放棄'));
                    return false;
                }
                // 不得改寫成另一個守衛方法：遊戲等的是原方法的回應型別，擋下時合不出正確的錯誤（第二輪第 4 條）
                if (after.method !== env.method && isLobbyUrl(raw.url) && guardFor(after.method)) {
                    noteFailure(grant.__id, 'replace', new Error('rewriteSend 不得改寫成守衛方法 ' + after.method + '，已放棄'));
                    return false;
                }
                raw.bytes = next;
                noteSuccess(grant.__id, 'replace');
                pluginLog(grant.__id, 'rewriteSend ' + method + ' → ' + after.method + '（' + next.length + ' bytes）');
                return true;
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
                // 登記 (連線, msgId) → 發起插件（§7.7b 回應路由）；連線是 sendRaw 實際選到的那條
                injectedMsgIds.set(msgKey(r.socketId, msgId), grant.__id);
                if (injectedMsgIds.size > 256) {
                    injectedMsgIds.delete(injectedMsgIds.keys().next().value);
                }
                pluginLog(grant.__id, 'sendRequest ' + method + ' msgId=' + msgId + '（送出，成功要看 RESPONSE）');
                return { ok: true, msgId: msgId };
            };
        }
        return ctx;
    }

    function makeRecommendationCtx(grant, recommendations, context) {
        var ctx = {
            recommendations: JSON.parse(JSON.stringify(Array.isArray(recommendations) ? recommendations : [])),
            context: JSON.parse(JSON.stringify(context || window.__nakiRecommendationContext || {})),
            log: function (msg) { pluginLog(grant.__id, msg); }
        };
        if (grant.settings && typeof grant.settings === 'object') {
            ctx.settings = grant.settings;
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
    // 送出禁改名單只保障兩件事：Swift 從遊戲自己的送出學東西的來源（對局 .lq.FastTest.* 全部、authGame、
    // startUnifiedMatch／matchGame 的 sid），與帳號登入／session／憑證／付費操作（依 docs/protocol/liqi.json 的
    // Lobby 方法盤點）。其餘大廳寫入不在保障內，只靠 L3 總開關與測試帳號。改前改後兩側都查，rewriteAllow 解不開。
    var SEND_FORBIDDEN_METHODS = [
        'login', 'oauth2Login', 'emailLogin', 'fastLogin', 'prepareLogin', 'dmmPreLogin', 'loginSuccess', 'logout',
        'oauth2Auth', 'oauth2Check', 'oauth2Signup', 'signup', 'fetchOauth2Info',
        'bindAccount', 'bindEmail', 'bindOauth2', 'bindPhoneNumber', 'unbindPhoneNumber', 'createPhoneLoginBind',
        'fetchPhoneLoginBind', 'createEmailVerifyCode', 'createPhoneVerifyCode', 'modifyPassword',
        'deleteAccount', 'cancelDeleteAccount', 'yostarDeleteAccount',
        'fetchOBToken', 'generateAnnualReportToken', 'generateContestManagerLoginCode', 'gameMasterCommand',
        'verifyMyCardOrder', 'verifySteamOrder', 'cancelGooglePlayOrder',
        'startUnifiedMatch', 'matchGame'
    ].map(function (m) { return '.lq.Lobby.' + m; });
    function isSendForbidden(method) {
        return typeof method !== 'string' || method.indexOf('.lq.Lobby.') !== 0
            || SEND_FORBIDDEN_METHODS.indexOf(method) !== -1;
    }

    // envelope 逐欄位走到結尾、沒有越界、field 1（method）非空。parseEnvelope 對截斷的 fixed32／fixed64
    // 會回 complete:true（naki-core 的既有行為），整包替換不能只靠它。
    function isWellFormed(b) {
        var i = b[0] === 1 ? 1 : 3, method = false;
        while (i < b.length) {
            var tag = readVarint(b, i);
            if (!tag) return false;
            var wire = tag[0] & 7;
            i = tag[1];
            if (wire === 0) { var v = readVarint(b, i); if (!v) return false; i = v[1]; }
            else if (wire === 2) {
                var len = readVarint(b, i);
                if (!len || len[1] + len[0] > b.length) return false;
                if (tag[0] >>> 3 === 1) method = len[0] > 0;
                i = len[1] + len[0];
            }
            else if (wire === 5) { if (i + 4 > b.length) return false; i += 4; }
            else if (wire === 1) { if (i + 8 > b.length) return false; i += 8; }
            else return false;
        }
        return method;
    }
    function readVarint(b, i) {
        var n = 0, shift = 0;
        for (; i < b.length && shift < 35; shift += 7) {
            var x = b[i++];
            n += (x & 0x7f) * Math.pow(2, shift);
            if (!(x & 0x80)) return [n, i];
        }
        return null;
    }
    function isForbiddenMethod(method, grant) {
        if (method == null) return true;
        if (FORBIDDEN_METHODS.indexOf(method) === -1) return false;
        // manifest 逐一解除：grant.rewriteAllow 含這個 method 才放行
        var allow = grant.rewriteAllow || [];
        return allow.indexOf(method) === -1;
    }

    function runChain(raw, env, guard) {
        diagnostics.parsed++;
        rememberIfRequest(env, raw.direction, raw.wsId);
        var method = resolveMethod(env, raw.direction, raw.wsId);
        diagnostics.lastMethod = method;
        // Naki 自送看 sendRaw 的登記；插件號段另計（websocket 模組缺席時只剩號段）
        var isNaki = isNakiMsgId(env.msgId);

        // §7.7b 回應路由：插件注入的 request（msgId 64000–65500）的 RESPONSE 回來時，
        // **只**回派給發起它的那一個插件（其餘看不到，§7.7 不變），走 onInjectResponse。
        if (raw.direction === 'receive' && env.msgId != null && injectedMsgIds.has(msgKey(raw.wsId, env.msgId))) {
            var originId = injectedMsgIds.get(msgKey(raw.wsId, env.msgId));
            injectedMsgIds.delete(msgKey(raw.wsId, env.msgId));
            var origin = registry.get(originId);
            if (origin && typeof origin.spec.onInjectResponse === 'function') {
                var rctx = makeCtx(raw, env, method, isNaki, origin.grant);
                rctx.inResponseTo = env.msgId;
                rctx.timedOut = false;
                try { origin.spec.onInjectResponse(rctx); noteSuccess(originId, 'onInjectResponse'); }
                catch (e) { noteFailure(originId, 'onInjectResponse', e); }
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

        var original = raw.bytes;
        for (var k = 0; k < chain.length; k++) {
            var entry = chain[k];
            var hook = raw.direction === 'receive' ? 'onReceive' : 'onSend';
            var fn = entry.spec[hook];
            if (typeof fn !== 'function') continue;
            var ctx = makeCtx(raw, env, method, isNaki, entry.grant);
            var before = raw.bytes;
            var snapshot = raw.mutable === false ? null : before.slice();
            var isGuard = !!guard && guard.ids.indexOf(entry.spec.id) !== -1;
            try {
                diagnostics.hooks++;
                var ret = fn(ctx);   // 改寫只能經 ctx.replace（見 makeCtx）；回傳 Promise／thenable 不算放行（審查第 2 條）
                if (ret && typeof ret.then === 'function') {
                    // 結果出來才記成功或失敗：先記成功會把連續失敗歸零（第二輪第 6 條）
                    if (isGuard) guard.async.push(entry.spec.id);
                    settle(ret, entry.spec.id, hook);
                } else {
                    noteSuccess(entry.spec.id, hook);
                    if (isGuard) guard.approved.push(entry.spec.id);
                }
                // 大廳上就地改寫成另一個守衛方法：當成這個 hook 失敗，撤回改動，原請求照常送（第三輪第 5 條）
                if (raw.direction === 'send' && raw.bytes === before && snapshot && isLobbyUrl(raw.url)
                    && !sameBytes(snapshot, raw.bytes)) {
                    var now = parseEnvelope(raw.bytes);
                    if (now && now.method && now.method !== method && guardFor(now.method)) {
                        throw new Error('就地改寫成守衛方法 ' + now.method + '，已撤回');
                    }
                }
                // 守衛插件改了大廳回應（等長或日後的變長）⇒ 已污染，直到頁面重載
                if (raw.direction === 'receive' && snapshot && (entry.grant.sendGuard || []).length
                    && isLobbyUrl(raw.url) && !sameBytes(snapshot, raw.bytes)) {
                    taint(entry.spec.id, entry.grant);
                }
            } catch (e) {
                // fail-open：hook 拋錯就撤回它這次的全部改動（整包替換與就地改寫）。守衛方法另由 guardedSend 改為不送出
                raw.bytes = before;
                if (snapshot) before.set(snapshot);
                if (isGuard) guard.threw.push(entry.spec.id);
                noteFailure(entry.spec.id, hook, e);
            }
            if (raw.bytes !== before) {
                // 換 buffer：後續插件看新 bytes。method 換了就停——後面的插件是照舊 method 的白名單選進鏈的
                env = parseEnvelope(raw.bytes);
                if (env.method !== method) break;
            }
        }
        if (raw.direction !== 'send' || raw.bytes === original) return undefined;
        // RESPONSE 對回「實際送出」的 method，與 Swift 的 pendingRequests 一致
        if (env && env.method) pendingMethods.set(msgKey(raw.wsId, env.msgId), env.method);
        return raw.bytes;
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
            var badGuard = (grant.sendGuard || []).filter(function (m) {
                return GUARDABLE_METHODS.indexOf(m) === -1 || (grant.methods || []).indexOf(m) === -1;
            });
            if (badGuard.length) {
                pluginLog(spec.id, 'register 被拒：sendGuard 含不可守衛（回應型別未確認）或不在 methods 的方法：' + badGuard.join(','));
                return false;
            }
            // 把 id 綁進 grant 供 ctx.log 使用（不動原物件語意）
            grant.__id = spec.id;
            registry.set(spec.id, { spec: spec, grant: grant });
            failures.set(spec.id, {});
            pluginLog(spec.id, 'registered（capabilities=' + (grant.capabilities || []).join(',') + '）');

            // 高亮類插件不應該等下一個 WebSocket 封包才看見已經算好的推薦。
            // 熱啟用時如果頁面上已經有推薦，立刻補一次目前狀態。
            if (typeof spec.onRecommendations === 'function'
                && Array.isArray(window.__nakiRecommendations)) {
                try {
                    spec.onRecommendations(makeRecommendationCtx(grant, window.__nakiRecommendations));
                } catch (e) {
                    noteFailure(spec.id, 'onRecommendations', e);
                }
            }
            return true;
        },

        // naki-websocket.js 的 handleMessage 在中段呼叫。
        // raw = { direction:'send'|'receive', wsId:Number, url:String, bytes:Uint8Array }
        // 回傳：send 方向被 rewriteSend 換掉時回新的 Uint8Array（呼叫端改送它），其餘一律 undefined。
        // 守衛方法的 REQUEST 被擋下時回 { block:true, reason, response }：呼叫端不得送出，改把 response 交給遊戲與 Swift。
        dispatch: function (raw) {
            diagnostics.dispatches++;
            if (!raw || !raw.bytes || (registry.size === 0 && tainted.size === 0)) return;

            // Blob 的非同步副本已送出，守衛無從判定，只觀察
            if (raw.direction === 'send' && raw.mutable !== false) return guardedSend(raw);
            var env = parseEnvelope(raw.bytes);
            if (!env) return;
            return runChain(raw, env, null);
        },

        // 有守衛者（已污染或已註冊 sendGuard）時拒送無法同步辨識的送出（Blob 等，審查第 4 條）。
        // 呼叫端不得送出，也沒有 msgId 可回應。
        refuseOpaqueSend: function (url) {
            if (!isLobbyUrl(url)) return false;
            var ids = Array.from(tainted.keys());
            registry.forEach(function (entry, id) {
                if ((entry.grant.sendGuard || []).length && ids.indexOf(id) === -1) ids.push(id);
            });
            if (ids.length === 0) return false;
            recordGuard(null, null, 'refused_opaque', 'opaque', ids);
            pluginLog(ids.join(','), '已污染：拒送一筆無法同步辨識的送出');
            return true;
        },

        // naki-websocket 的送出路徑出錯時問這裡。只管已確認的大廳連線，其他連線一律照舊送出。
        // 大廳上：守衛方法擋下；已知非守衛方法照送；辨識失敗時有守衛者才擋下。回 undefined ＝照舊送出。自己不得拋錯。
        failSafe: function (data, url, socketId) {
            if (!isLobbyUrl(url)) return;
            var b = null, original = null, env = null, raw = null, identified = false;
            try {
                b = data instanceof ArrayBuffer ? new Uint8Array(data)
                    : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
                original = b.slice();
                raw = { bytes: b, wsId: socketId };
                env = parseEnvelope(original);
                if (env && env.method && env.method.indexOf('.lq.FastTest.') === 0) return;
                var guard = env && env.type === TYPE_REQUEST && env.method ? guardFor(env.method) : null;
                identified = !!env;
                if (guard) return blockSend(raw, b, original, env.msgId, env.method, env.method, 'bridge_error', guard.ids);
                if (identified || !guardActive()) return;
            } catch (e) {
                if (identified || !guardActive()) return;
            }
            var empty = new Uint8Array(0);
            return blockSend(raw || { bytes: empty, wsId: socketId }, b || empty, original || empty,
                null, null, null, 'bridge_error', []);
        },

        // 本地回應交給遊戲之後呼叫：清 msgId 對照，插件注入的請求把本地結果交回發起插件（審查第 8 條）。
        // msgId 與原方法來自擋下當時的判定，bytes 是交付前另存的快照（第二輪第 5 條）。不跑改寫鏈、不送 Swift。
        localResponse: function (socketId, msgId, method, bytes) {
            if (msgId == null) return;
            var key = msgKey(socketId, msgId);
            pendingMethods.delete(key);
            var originId = injectedMsgIds.get(key);
            if (originId == null) return;
            injectedMsgIds.delete(key);
            var origin = registry.get(originId);
            if (!origin || typeof origin.spec.onInjectResponse !== 'function') return;
            var env = parseEnvelope(bytes) || { type: TYPE_RESPONSE, msgId: msgId, method: null, payload: null };
            var rctx = makeCtx({ direction: 'receive', wsId: socketId, url: '', bytes: bytes, mutable: false },
                env, method || null, true, origin.grant);
            rctx.inResponseTo = msgId;
            rctx.timedOut = false;
            rctx.local = true;
            try { origin.spec.onInjectResponse(rctx); noteSuccess(originId, 'onInjectResponse'); }
            catch (e) { noteFailure(originId, 'onInjectResponse', e); }
        },

        // 推薦不是 WebSocket hook 的副產品：它要等 Swift / Mortal 推論完成才存在。
        // 由 WebSession 在 __nakiRecommendations 更新後主動呼叫，讓插件拿到同一拍資料。
        recommendationsChanged: function (recommendations, context) {
            diagnostics.recommendationUpdates++;
            var recs = Array.isArray(recommendations) ? recommendations : [];
            registry.forEach(function (entry, id) {
                if (typeof entry.spec.onRecommendations !== 'function') return;
                try {
                    diagnostics.recommendationHooks++;
                    entry.spec.onRecommendations(makeRecommendationCtx(entry.grant, recs, context));
                    noteSuccess(id, 'onRecommendations');
                } catch (e) {
                    noteFailure(id, 'onRecommendations', e);
                }
            });
        },

        diagnostics: function () {
            return JSON.parse(JSON.stringify({ runtime: diagnostics, registered: api.list(), guard: api.guardState(),
                websocket: window.__nakiWebSocket && window.__nakiWebSocket.diagnostics
                    ? window.__nakiWebSocket.diagnostics() : null,
                recommendations: (window.__nakiRecommendations || []).length,
                topRecommendation: (window.__nakiRecommendations || [])[0] || null,
                highlight: window.__nakiHighlight && window.__nakiHighlight.state ? window.__nakiHighlight.state() : null,
                nameMask: window.__nakiHighlight && window.__nakiHighlight.nameMaskStatus ? window.__nakiHighlight.nameMaskStatus() : null }));
        },

        // 診斷用（唯讀）：目前註冊了哪些插件
        list: function () {
            var out = [];
            registry.forEach(function (entry, id) {
                out.push({ id: id, capabilities: entry.grant.capabilities || [], tainted: tainted.has(id) });
            });
            return out;
        },

        // 送出守衛現況（唯讀複本）：已污染插件與其守衛方法、最近 256 筆守衛方法的結局
        guardState: function () {
            var t = {};
            tainted.forEach(function (set, id) { t[id] = Array.from(set); });
            return JSON.parse(JSON.stringify({ tainted: t, log: guardLog }));
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
            var entry = registry.get(id);
            var wasRegistered = registry.delete(id);
            cleanup(entry);
            failures.delete(id);
            if (window.__nakiPluginGrants) delete window.__nakiPluginGrants[id];
            pluginLog(id, 'disabled（熱停用，免 reload）');
            return { ok: true, wasRegistered: wasRegistered };
        }
    };

    window.__nakiPlugins = api;
    console.log('[Naki Plugins] naki-plugins.js 已載入（apiVersion 1，Phase 1 observe）');
})();
