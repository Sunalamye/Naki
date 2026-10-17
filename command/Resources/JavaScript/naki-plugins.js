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
//  observe 唯讀；rewriteReceive → ctx.replace（等長就地改寫；另宣告 reshapeReceive 才可長度不等整包換掉，Phase 4 草案；isNaki 流量不給）、
//  dropReceive → ctx.drop（只限 NOTIFY，受 L3 總開關把關；Phase 4 草案，docs/archive/plan/plugin-v2-phase4.md）、
//  rewriteSend → send 方向的 ctx.replace（可改長度與 method，受 L3 總開關把關；v2 草案，docs/archive/plan/plugin-v2.md §B）、
//  injectSend → ctx.sendRequest（受 L3 總開關把關）。
//  送出守衛（manifest sendGuard，docs/archive/plan/plugin-v2-b2.md）：守衛方法 fail-closed，插件污染後持續到頁面重載。
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

    // 宿主快照用的原生入口，載入時保存。set 的來源是 typed array 時只讀內部槽；length 用 %TypedArray% 原型上的 getter
    // 以 .call 讀，實例上的自有屬性遮蔽不到。slice 會讀 constructor（species），只用在插件碰不到的陣列上
    var U8 = Uint8Array, u8set = Uint8Array.prototype.set, u8slice = Uint8Array.prototype.slice;
    var taLength = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), 'length').get;
    function hostCopy(b) {
        var c = new U8(taLength.call(b));
        u8set.call(c, b);
        return c;
    }

    var TYPE_NOTIFY = 1;
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
    // sendRequest 呼叫 sendRaw 期間的注入標記：sendRaw 同步經包裝的 ws.send 回到 dispatch。
    // 同 msgId 且 bytes 與注入的 envelope 完全相同才算這次注入（第三輪第 2 條）：注入前後其他派發的同號請求，
    // 內容不同就不算，也不消耗標記（第二輪第 2 條）
    var injecting = null;

    // 連線角色由協定握手鎖定，URL 不參與（審查第四輪第 1 條）：每條連線第一個請求是 .lq.Route.requestConnection，
    // 第二個才揭露角色（大廳 oauth2Login／prepareLogin，對局 authGame；live 2026-10-17）。
    // 第一個 .lq.Lobby.* 請求 ⇒ lobby，第一個 .lq.FastTest.* ⇒ game，.lq.Route.* 不改；鎖定後不變，關閉才清。
    // 只有 lobby 進守衛。守衛方法都是 .lq.Lobby.*，而它本身就會先鎖定 lobby，所以未定角色的空窗漏不出守衛方法。
    // 角色只存在本閉包，插件改不到；守衛查找壞掉（grant 可被插件改）不影響角色判定。
    var roles = new Map();
    function lockRole(socketId, env) {
        if (!env || env.type !== TYPE_REQUEST || typeof env.method !== 'string' || roles.has(socketId)) return;
        if (env.method.indexOf('.lq.Lobby.') === 0) roles.set(socketId, 'lobby');
        else if (isFastTest(env)) roles.set(socketId, 'game');
    }
    function isLobby(socketId) { return roles.get(socketId) === 'lobby'; }
    function isFastTest(env) { return !!env && typeof env.method === 'string' && env.method.indexOf('.lq.FastTest.') === 0; }
    function isGuardable(bytes) {
        var env = parseEnvelope(bytes);
        return !!env && GUARDABLE_METHODS.indexOf(env.method) !== -1;
    }

    // ---- 送出守衛（N1／N2，docs/archive/plan/plugin-v2-b2.md §3–§4）----
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
            return sendToSwift('plugin_event', { id: id, kind: 'log', msg: String(msg) }) === true;
        } catch (e) { return false; /* log 不該反過來弄壞 dispatch */ }
    }

    // 只在需要時報一次某插件的內部錯誤，避免對局時間軸被洗版
    function noteFailure(id, hook, err) {
        // 錯誤訊息只讀一次，讀取本身拋錯也不中斷記帳（getter 是插件程式碼）
        var message;
        try {
            var m = err && err.message;   // getter 只觸發一次
            message = String(m ? m : err);
        } catch (x) { message = '（錯誤訊息無法讀取）'; }
        diagnostics.lastError = { id: id, message: message };
        var f = failures.get(id) || {};
        var n = (f[hook] || 0) + 1;
        f[hook] = n;
        failures.set(id, f);
        pluginLog(id, hook + ' 拋錯（第 ' + n + ' 次）：' + message);
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

    // 接管 hook 回傳的 thenable。then 會同步跑插件程式碼（可能改 bytes），所以先接管、再由呼叫端驗證（第三輪第 1 條）。
    // 驗證結束前的結果先暫存；這次已判違規就不再記帳，rejection 仍被接住、不重複計失敗（第三輪第 3 條）
    function settle(thenable, id, hook, state) {
        function done(ok, e) {
            if (!state.judged) { state.early = { ok: ok, e: e }; return; }
            if (state.failed) return;
            if (ok) noteSuccess(id, hook); else noteFailure(id, hook, e);
        }
        try { thenable.then(function () { done(true); }, function (e) { done(false, e); }); }
        catch (e) { done(false, e); }
    }
    function judge(state, id, hook, failed) {
        state.judged = true;
        state.failed = failed;
        if (!failed && state.early) {
            if (state.early.ok) noteSuccess(id, hook); else noteFailure(id, hook, state.early.e);
        }
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

    // Naki 與插件都經 sendRaw 送出、以 (連線, msgId) 登記；插件號段本身不算（D22：遊戲 msgId 會跑進號段）。
    // REQUEST 只認還沒收到 RESPONSE 的登記
    function isNakiMsgId(msgId, socketId, request) {
        var ws = window.__nakiWebSocket;
        return msgId != null && !!(ws && ws.isNakiSent && ws.isNakiSent(msgId, socketId, request));
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

    // 只收已鎖定為大廳、非 FastTest 的送出（dispatch 先分流）。守衛方法只有三種結局：原樣送出、本地成功（respondLocally，PV2-B2）、本地錯誤。
    // 跑鏈與鏈後判定在 try 內（第二輪第 1 條）；無法解析的在 try 前就依有無守衛者決定。出錯時只擋守衛方法與
    // 原方法在 GUARDABLE_METHODS 者；其他還原原 bytes 照送（第四輪第 3 條）。實際送出的是原 bytes，所以只看原方法；
    // 這個判斷只用本閉包的常數與 parser，不碰出錯的 grant。
    function guardedSend(raw, env) {
        var origObj = raw.bytes, original = u8slice.call(origObj), guard = null;
        if (!env) return guardActive() ? blockSend(raw, origObj, original, null, null, null, 'guard_error', []) : undefined;
        try {
            guard = env.type === TYPE_REQUEST && env.method ? guardFor(env.method) : null;
            if (guard && isNakiMsgId(env.msgId, raw.wsId, true)) {
                return blockSend(raw, origObj, original, env.msgId, env.method, env.method, 'naki_traffic', guard.ids);
            }
            var out = runChain(raw, env, guard, true);
            if (!guard) return out;
            var reason = guardFailure(guard) || (!sameBytes(original, raw.bytes) ? 'rewritten' : null);
            if (reason) return blockSend(raw, origObj, original, env.msgId, env.method, env.method, reason, guard.ids);
            recordGuard(env.msgId, env.method, 'sent', null, guard.ids, raw.wsId);
            return out;
        } catch (e) {
            if (!guard && !isGuardable(original)) {
                restore(raw, origObj, original);
                return undefined;
            }
            return blockSend(raw, origObj, original, env.msgId, env.method, env.method,
                guard ? 'dispatch_error' : 'guard_error', guard ? guard.ids : []);
        }
    }

    // 插件注入落到非大廳連線（sendRaw 沒有大廳候選時退回全部連線，D28）：比照大廳的 naki_traffic，
    // 有守衛者就擋下。只在注入期間判定，遊戲與 Naki 自送不經這裡。先以常數排除，不可能有守衛的方法不讀 sendGuard（第二輪第 3 條）；
    // 查找出錯時只擋 GUARDABLE_METHODS
    function injectedFallback(raw, env) {
        var ids;
        if (env.type !== TYPE_REQUEST || GUARDABLE_METHODS.indexOf(env.method) === -1) return undefined;
        try {
            var guard = guardFor(env.method);
            if (!guard) return undefined;
            ids = guard.ids;
        } catch (e) { ids = []; }
        return blockSend(raw, raw.bytes, u8slice.call(raw.bytes), env.msgId, env.method, env.method, 'tainted_fallback', ids);
    }

    function restore(raw, origObj, original) {
        raw.bytes = origObj;
        if (origObj.length === original.length) u8set.call(origObj, original);
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
            log: function (msg) { pluginLog(grant.__id, msg); },
            // 主動污染自己：只對宣告 sendGuard 的插件有效，走與大廳改寫相同的 taint；不可解除，頁面重載才清
            taint: function () {
                if (!(grant.sendGuard || []).length) return false;
                taint(grant.__id, grant);
                return true;
            },
            isTainted: function () { return tainted.has(grant.__id); }
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
                if (!newBytes || typeof newBytes.length !== 'number') return false;
                // 長度不等：宣告 reshapeReceive 才走 Phase 4 整包替換（攔原事件、重派合成事件），否則照 v1 回 false。等長仍就地改
                if (newBytes.length !== raw.bytes.length) {
                    return caps.indexOf('reshapeReceive') !== -1 && reshapeReceive(raw, env, method, grant, newBytes);
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

        // dropReceive → ctx.drop：遊戲與 Swift 都收不到這則。只限 NOTIFY（RESPONSE 被丟遊戲會一直等），受 L3 總開關把關
        if (raw.direction === 'receive' && !isNaki && raw.reshape && env.type === TYPE_NOTIFY
            && caps.indexOf('dropReceive') !== -1 && !isReshapeForbidden(method)) {
            ctx.drop = function () {
                if (!window.__nakiPluginsMayModifyOutbound) return false;
                raw.drop = true;
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
                // 先物化成宿主自有副本再驗證，驗的與採用的是同一份；之後插件改它傳進來的物件（含共用的 ArrayBuffer）無效。
                // 只收 TypedArray，ArrayBuffer／SAB／DataView／array-like／Proxy 回 false，不讀自有 length（第六輪第 1 條）
                var next;
                try { next = hostCopy(newBytes); } catch (e) { return false; }
                var after = sendViolation(next, env.msgId) ? null : parseEnvelope(next);
                if (!after) {
                    noteFailure(grant.__id, 'replace', new Error('rewriteSend 不合規（type／msgId 變了、envelope 不完整或觸及送出禁改名單），已放棄'));
                    return false;
                }
                // 不得改寫成另一個守衛方法：遊戲等的是原方法的回應型別，擋下時合不出正確的錯誤（第二輪第 4 條）
                if (after.method !== env.method && isLobby(raw.wsId) && guardFor(after.method)) {
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

                var ws = window.__nakiWebSocket, r, prev = injecting;
                injecting = { msgId: msgId, bytes: envBytes };
                try { r = (ws && ws.sendRaw) ? ws.sendRaw(b64) : { success: false, reason: 'no_sendRaw' }; }
                finally { injecting = prev; }
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

    // Phase 4 變長 replace／drop 的禁改名單（docs/archive/plan/plugin-v2-phase4.md §4），rewriteAllow 解不開，canonical 全名比對。
    // 來源是 Swift 消費端清單：Swift 據以改牌局、帳號或匹配狀態的 NOTIFY／RESPONSE（MajsoulBridge、LiqiParser、
    // LiqiResponseStore 表情廣播）；JSContractTests 從 Swift 原始碼反查，缺一即紅。另加對局與連線層兩個前綴。
    var RESHAPE_FORBIDDEN_METHODS = [
        '.lq.ActionPrototype', '.lq.NotifyGameEndResult', '.lq.NotifyGameTerminate', '.lq.NotifyGameBroadcast',
        '.lq.Lobby.login', '.lq.Lobby.oauth2Login', '.lq.Lobby.emailLogin', '.lq.Lobby.oauth2Auth', '.lq.Lobby.startUnifiedMatch'
    ];
    function isReshapeForbidden(method) {
        return typeof method !== 'string' || !method || RESHAPE_FORBIDDEN_METHODS.indexOf(method) !== -1
            || method.indexOf('.lq.FastTest.') === 0 || method.indexOf('.lq.Route.') === 0;
    }

    // 整包替換 receive：type、msgId 不變；NOTIFY 的 method 不變，RESPONSE 不得帶 method（field 1 可省，Naki 按欄位號取 payload）
    function reshapeReceive(raw, env, method, grant, newBytes) {
        if (!raw.reshape || isReshapeForbidden(method)) return false;
        var next;
        try { next = hostCopy(newBytes); } catch (e) { return false; }   // 與送出 replace 同：先物化再驗證（第六輪）
        var after = parseEnvelope(next);
        if (!after || !isWellFormed(next) || after.type !== env.type || after.msgId !== env.msgId
            || (env.type === TYPE_RESPONSE ? !!after.method : after.method !== method)) {
            noteFailure(grant.__id, 'replace', new Error('變長 replace 不合規（type／msgId／method 變了或 envelope 不完整），已放棄'));
            return false;
        }
        raw.bytes = next;
        noteSuccess(grant.__id, 'replace');
        return true;
    }

    // 送出改寫的結構與名單驗證，對宿主自有快照判定：replace 入口與每個 hook 結束各跑一次
    function sendViolation(next, msgId) {
        var after = parseEnvelope(next);
        return !after || !isWellFormed(next) || after.type !== TYPE_REQUEST || after.msgId !== msgId || isSendForbidden(after.method);
    }

    // envelope 逐欄位走到結尾、沒有越界、field 1（method）非空（RESPONSE 可省）。parseEnvelope 對截斷的 fixed32／fixed64
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
        return method || b[0] === TYPE_RESPONSE;
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

    // lobby：由 guardedSend 呼叫（大廳上的非 FastTest 送出）才為 true；現行鏈不讀任何守衛狀態
    function runChain(raw, env, guard, lobby) {
        diagnostics.parsed++;
        rememberIfRequest(env, raw.direction, raw.wsId);
        var method = resolveMethod(env, raw.direction, raw.wsId);
        diagnostics.lastMethod = method;
        var injectedKey = raw.direction === 'receive' && env.msgId != null ? msgKey(raw.wsId, env.msgId) : null;
        var injected = injectedKey != null && injectedMsgIds.has(injectedKey);
        // 注入登記還在就是插件自送，即使 sendRaw 登記已被淘汰（D22 第二輪第 1 條）
        var isNaki = injected || isNakiMsgId(env.msgId, raw.wsId, raw.direction === 'send');

        // §7.7b 回應路由：插件注入的 request（msgId 64000–65500）的 RESPONSE 回來時，
        // **只**回派給發起它的那一個插件（其餘看不到，§7.7 不變），走 onInjectResponse。
        if (injected) {
            var originId = injectedMsgIds.get(injectedKey);
            injectedMsgIds.delete(injectedKey);
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

        // 送出（可改寫）時插件只拿副本：每個 hook 拿從宿主快照 cur 複製的新陣列，hook 結束後宿主只讀內部槽把它物化成新快照，
        // 驗證的是這份快照。遊戲的原 buffer 與 cur 從不交給插件，驗證之後才執行的插件程式碼（記帳、getter、onDisable）
        // 只碰得到過期的副本（第五輪）。receive 維持與遊戲共用 buffer 的就地改寫（契約 §4）
        var copy = raw.direction === 'send' && raw.mutable !== false;
        var original = raw.bytes, cur = copy ? hostCopy(original) : null, by = [], type = env.type, msgId = env.msgId;
        for (var k = 0; k < chain.length; k++) {
            var entry = chain[k];
            var hook = raw.direction === 'receive' ? 'onReceive' : 'onSend';
            if (copy) raw.bytes = cur;
            var fn = entry.spec[hook];
            if (typeof fn !== 'function') continue;
            var before = copy ? hostCopy(cur) : raw.bytes;
            if (copy) raw.bytes = before;
            var ctx = makeCtx(raw, env, method, isNaki, entry.grant);
            var snapshot = copy || raw.mutable === false ? null : u8slice.call(before);
            var isGuard = !!guard && guard.ids.indexOf(entry.spec.id) !== -1;
            var state = { judged: false, failed: false, early: null };
            var thenable = false, failure = null, staged = null, replaced = false;
            try {
                diagnostics.hooks++;
                var ret = fn(ctx);   // 改寫只能經 ctx.replace（見 makeCtx）；回傳 Promise／thenable 不算放行（審查第 2 條）
                thenable = !!ret && typeof ret.then === 'function';
                if (thenable) {
                    if (isGuard) guard.async.push(entry.spec.id);
                    settle(ret, entry.spec.id, hook, state);
                }
                if (copy) {
                    replaced = raw.bytes !== before;
                    try { staged = hostCopy(raw.bytes); } catch (x) { staged = null; }   // 副本的 buffer 被分離時原生 set 會拋錯
                    if (!staged) throw new Error('送出內容無法讀取（buffer 已分離），已撤回');
                    // 物化後的快照一律完整重驗，replace 入口驗過也重驗（第六輪第 1 條）：經 replace 的照 rewriteSend 規則，
                    // 就地改的 type／msgId 不得變。不合規或改寫成守衛方法：當成這個 hook 失敗，撤回它這次的改動，原請求照常送。
                    // 大廳（guardedSend 的鏈）：改成另一個守衛方法（第三輪第 5 條），改動有守衛者的方法本身由鏈後判定。
                    // 其他連線：改後是 GUARDABLE_METHODS 就撤回，只看閉包常數、不讀 sendGuard（第四輪第 2 條，guard-gaps b、第二輪第 1 條）
                    if (!sameBytes(staged, cur)) {
                        var now = parseEnvelope(staged);
                        if (replaced ? sendViolation(staged, msgId) : !now || now.type !== type || now.msgId !== msgId) {
                            throw new Error('送出改寫不合規（type／msgId 變了、envelope 不完整或觸及送出禁改名單），已撤回');
                        }
                        if (now.method && (lobby ? now.method !== method && guardFor(now.method) : GUARDABLE_METHODS.indexOf(now.method) !== -1)) {
                            throw new Error('改寫成守衛方法 ' + now.method + '，已撤回');
                        }
                    }
                }
                // 守衛插件改了或丟了大廳的回應／通知 ⇒ 已污染，直到頁面重載
                if (raw.direction === 'receive' && snapshot && (entry.grant.sendGuard || []).length
                    && isLobby(raw.wsId) && (raw.drop || !sameBytes(snapshot, raw.bytes))) {
                    taint(entry.spec.id, entry.grant);
                }
            } catch (e) {
                // fail-open：hook 拋錯就撤回它這次的全部改動（整包替換與就地改寫）。守衛方法另由 guardedSend 改為不送出。
                // 送出鏈的改動只在副本上，不採用 staged 就是撤回
                if (!copy) {
                    raw.bytes = before;
                    raw.drop = false;
                    if (snapshot) u8set.call(before, snapshot);
                }
                failure = { error: e };
            }
            var changed = false;
            if (copy) {
                changed = !failure && !sameBytes(staged, cur);
                replaced = changed && replaced;
                if (changed) cur = staged;
                raw.bytes = cur;
            }
            // receive：驗證（或撤回）完成即定案，記帳後還原（第四輪第 1 條）。送出鏈已定案在 cur，插件碰不到
            var committed = raw.bytes, committedDrop = raw.drop, frozen = !copy && snapshot ? u8slice.call(committed) : null;
            try {
                if (failure) {
                    if (isGuard) guard.threw.push(entry.spec.id);
                    judge(state, entry.spec.id, hook, true);
                    noteFailure(entry.spec.id, hook, failure.error);
                } else {
                    // 驗證都過了才記成功：先記會把違規前的連續失敗歸零（第二輪第 4 條）；thenable 的結果出來才記（第二輪第 6 條）
                    judge(state, entry.spec.id, hook, false);
                    if (!thenable) {
                        noteSuccess(entry.spec.id, hook);
                        if (isGuard) guard.approved.push(entry.spec.id);
                    }
                }
            } finally {
                raw.bytes = committed;
                raw.drop = committedDrop;
                if (frozen && !sameBytes(frozen, committed)) u8set.call(committed, frozen);
            }
            if (copy) {
                if (changed) by.push(entry.spec.id);
                if (replaced) {
                    // 換 buffer：send 換了 method 就停——後面的插件是照舊 method 的白名單選進鏈的
                    env = parseEnvelope(cur);
                    if (env.method !== method) break;
                }
                continue;
            }
            if (raw.drop || raw.bytes !== before || (snapshot && !sameBytes(snapshot, raw.bytes))) by.push(entry.spec.id);
            if (raw.drop) break;   // drop 短路：後續插件不再收到
            if (raw.bytes !== before) env = parseEnvelope(raw.bytes);   // 換 buffer：後續插件看新 bytes
        }
        if (raw.direction === 'receive') {
            if (!raw.drop && raw.bytes === original) return undefined;
            return { reshape: true, drop: !!raw.drop, bytes: raw.drop ? null : raw.bytes, method: method, msgId: env.msgId, by: by };
        }
        // 送出：內容沒變就送原物件（插件從未拿到它）；變了就送宿主快照 cur
        if (copy) raw.bytes = cur;
        if (raw.bytes === original || (copy && sameBytes(cur, original))) { raw.bytes = original; return undefined; }
        // RESPONSE 對回「實際送出」的 method，與 Swift 的 pendingRequests 一致
        if (env && env.method) pendingMethods.set(msgKey(raw.wsId, env.msgId), env.method);
        return raw.bytes;
    }

    // 載入來源：宿主注入 script 開頭呼叫 beginBootstrap、結尾呼叫 endBootstrap；兩者每頁只能成功一輪，
    // 之後（含熱啟用）一律 'hot'，插件無法重新進入 document-start 狀態。
    var bootstrapState = 'idle';   // idle → loading → done
    var DEV_LOG_LIMIT = 500;
    var devLogCounts = new Map();
    var devLogSealed = new Set();
    var SEAL_META_MAX_BYTES = 512;

    var api = {
        get loadSource() { return bootstrapState === 'loading' ? 'document-start' : 'hot'; },

        beginBootstrap: function () {
            if (bootstrapState !== 'idle') return false;
            bootstrapState = 'loading';
            devLogCounts.clear();
            devLogSealed.clear();
            return true;
        },
        endBootstrap: function () {
            if (bootstrapState === 'loading') bootstrapState = 'done';
            return bootstrapState === 'done';
        },

        // 拿到 ctx.log 之前就能寫宿主 log（同一管道、同一前綴）。只收已註冊或持有宿主 grant 的 id，每插件每頁 500 行。
        // 回 true＝sendToSwift 確認已交給宿主；bridge 缺席／拋錯／line.toString 拋錯＝false 且不佔配額。
        devLog: function (pluginId, line) {
            if (typeof pluginId !== 'string' || devLogSealed.has(pluginId) || !(registry.has(pluginId) || grantFor(pluginId))) return false;
            var n = devLogCounts.get(pluginId) || 0;
            if (n >= DEV_LOG_LIMIT) return false;
            if (!pluginLog(pluginId, line)) return false;
            devLogCounts.set(pluginId, n + 1);
            return true;
        },

        // 封存：宿主以真實交付數組 seal 行（插件無法偽造 count），成功後該插件本頁 devLog／devLogSeal 一律 false。不佔 500 行配額。
        devLogSeal: function (pluginId, meta) {
            if (typeof pluginId !== 'string' || devLogSealed.has(pluginId) || !(registry.has(pluginId) || grantFor(pluginId))) return false;
            if (meta === null || typeof meta !== 'object') return false;
            var proto = Object.getPrototypeOf(meta);
            if (proto !== null && Object.getPrototypeOf(proto) !== null) return false;   // 純物件（含跨 realm），排除 class 實例
            var metaJson;
            try { metaJson = JSON.stringify(meta); } catch (e) { return false; }
            if (typeof metaJson !== 'string' || unescape(encodeURIComponent(metaJson)).length > SEAL_META_MAX_BYTES) return false;
            var line = '{"kind":"seal","plugin":' + JSON.stringify(pluginId) + ',"count":' + (devLogCounts.get(pluginId) || 0) + ',"meta":' + metaJson + '}';
            if (devLogSealed.has(pluginId)) return false;   // stringify 期間 getter／toJSON 可能重入並已封存
            if (!pluginLog(pluginId, line)) return false;
            devLogSealed.add(pluginId);
            return true;
        },

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
            if (!raw || !raw.bytes) return;
            var send = raw.direction === 'send';
            // 沒有插件也鎖定角色（每條連線只解析到鎖定為止），之後才啟用的守衛一開始就認得大廳
            var env = send && !roles.has(raw.wsId) ? parseEnvelope(raw.bytes) : undefined;
            if (send) lockRole(raw.wsId, env);
            if (registry.size === 0 && tainted.size === 0) return;
            if (env === undefined) env = parseEnvelope(raw.bytes);
            if (send && env && injecting && env.msgId === injecting.msgId && sameBytes(raw.bytes, injecting.bytes)) {
                var fallback = isLobby(raw.wsId) ? undefined : injectedFallback(raw, env);
                if (fallback) return fallback;
            }
            // 對局、未定角色、大廳上的 FastTest：現行鏈原樣，例外與鏈後檢查都不經守衛（第四輪第 2 條）。
            // Blob 的非同步副本已送出，守衛無從判定，只觀察
            if (send && raw.mutable !== false && isLobby(raw.wsId) && !isFastTest(env)) return guardedSend(raw, env);
            return env ? runChain(raw, env, null, false) : undefined;
        },

        // 有守衛者（已污染或已註冊 sendGuard）時拒送無法同步辨識的送出（Blob 等，審查第 4 條）。
        // 角色未定的連線比照大廳（guard-gaps c）：Blob 無法同步解析，守衛方法本可在這裡先於鎖定外送；只有已鎖 game 的放行。
        // 呼叫端不得送出，也沒有 msgId 可回應。
        refuseOpaqueSend: function (socketId) {
            if (roles.get(socketId) === 'game') return false;
            var ids = Array.from(tainted.keys());
            registry.forEach(function (entry, id) {
                if ((entry.grant.sendGuard || []).length && ids.indexOf(id) === -1) ids.push(id);
            });
            if (ids.length === 0) return false;
            recordGuard(null, null, 'refused_opaque', isLobby(socketId) ? 'opaque' : 'opaque_unknown_role', ids, socketId);
            pluginLog(ids.join(','), '已污染：拒送一筆無法同步辨識的送出');
            return true;
        },

        // naki-websocket 的送出路徑出錯時問這裡。只管已鎖定為大廳的連線，其他連線與 FastTest 一律照舊送出。
        // 大廳上：守衛方法擋下；已知非守衛方法照送；查找出錯時只擋 GUARDABLE_METHODS；無法解析時有守衛者才擋下。
        // 回 undefined ＝照舊送出。自己不得拋錯。
        failSafe: function (data, socketId) {
            var b = null, original = null, env = null, ids = [];
            try {
                b = data instanceof ArrayBuffer ? new Uint8Array(data)
                    : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
                original = u8slice.call(b);
                env = parseEnvelope(original);
                lockRole(socketId, env);
                if (!isLobby(socketId) || isFastTest(env) || (!env && !guardActive())) return;
                if (env) {
                    var guard = env.type === TYPE_REQUEST && env.method ? guardFor(env.method) : null;
                    if (!guard) return;
                    ids = guard.ids;
                }
            } catch (e) {
                if (!isLobby(socketId) || isFastTest(env) || (env && !isGuardable(original)) || (!env && !guardActive())) return;
            }
            var empty = new Uint8Array(0);
            return blockSend({ bytes: b || empty, wsId: socketId }, b || empty, original || empty,
                env ? env.msgId : null, env && env.method, env && env.method, 'bridge_error', ids);
        },

        // naki-websocket 在連線關閉時呼叫：角色跟著連線走，重連是新的 socketId、重新握手
        closed: function (socketId) { roles.delete(socketId); },

        // naki-websocket 在變長交付出故障、鎖死變長改寫時呼叫（只記 log；改寫者只是候選，可能是多個插件共同的結果）
        reshapeLocked: function (kind, meta) {
            pluginLog('naki', '變長交付故障（' + kind + '，' + (meta.method || '?') + ' msgId=' + meta.msgId
                + '，候選改寫者 ' + (meta.by || []).join(',') + '），本頁面停用變長 replace／drop');
        },

        // 唯讀：變長 replace／drop 是否禁改這個 method（契約測試從 Swift 消費端反查用）
        isReshapeForbidden: function (method) { return isReshapeForbidden(method); },

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

        // 送出守衛現況（唯讀複本）：已污染插件與其守衛方法、最近 256 筆守衛方法的結局、連線角色
        guardState: function () {
            var t = {};
            var r = {};
            tainted.forEach(function (set, id) { t[id] = Array.from(set); });
            roles.forEach(function (role, id) { r[id] = role; });
            return JSON.parse(JSON.stringify({ tainted: t, log: guardLog, roles: r }));
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
