// Run: node scripts/guard-gaps-mutate.cjs [--from N] [--to M] [--log <path>]
// guard-gaps 送出守衛的變異測試：逐一把 MUTANTS 的字串替換套到 naki-plugins.js（第三欄指定時改套該檔，如 naki-websocket.js），跑 b2／v2／p4 三套 node 回歸，
// 至少一條 not ok 才算殺掉。先跑未變異基線，基線必須 0 fail；存活只准 EQUIVALENT 內的等價變異，否則 exit 1。
// b2 需要 naki-plugins repo（NAKI_PLUGINS_DIR，預設 ../naki-plugins）。--from／--to 分段（索引以 MUTANTS 為準，含頭不含尾）。
// 用法與歷史見 docs/archive/notes/guard-gaps-implementation-notes.md「變異 harness」。
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const jsDir = path.join(root, 'command/Resources/JavaScript');
const arg = (k, d) => { const i = process.argv.indexOf(k); return i === -1 ? d : process.argv[i + 1]; };
const from = Number(arg('--from', 0)), to = Number(arg('--to', Infinity));
const logPath = arg('--log', null);
const pluginsDir = process.env.NAKI_PLUGINS_DIR || path.resolve(root, '../naki-plugins');
const EQUIVALENT = ['T7', 'U10'];

const MUTANTS = [
  ["BB1 零消耗者 RESPONSE 不消耗配對", [["else if (k && e.type === (send ? TYPE_REQUEST : TYPE_RESPONSE)) {", "else if (k && send && e.type === TYPE_REQUEST) {"]]],
  ["BB2 零消耗者同鍵送出不撤銷舊配對", [["else if (k && e.type === (send ? TYPE_REQUEST : TYPE_RESPONSE)) {", "else if (k && !send && e.type === TYPE_RESPONSE) {"]]],
  ["BB3 零消耗者完全不碰配對", [["            if (pendingMethods.size || injectedMsgIds.size || ambiguousPairs.size) {\n", "            if (false) {\n"]]],
  ["BB4 零消耗者方向對調", [["else if (k && e.type === (send ? TYPE_REQUEST : TYPE_RESPONSE)) {", "else if (k && e.type === (send ? TYPE_RESPONSE : TYPE_REQUEST)) {"]]],
  ["AA1 沒人消耗時先早退、不撤銷舊配對", [["        pendingMethods.delete(key);\n        if (noConsumers()) return;\n", "        if (noConsumers()) return;\n        pendingMethods.delete(key);\n"]]],
  ["AA2 remember 只看 registry", [["        if (noConsumers()) return;\n        pendingMethods.set(key, {", "        if (registry.size === 0) return;\n        pendingMethods.set(key, {"]]],
  ["AA3 remember 只看 tainted", [["        if (noConsumers()) return;\n        pendingMethods.set(key, {", "        if (tainted.size === 0) return;\n        pendingMethods.set(key, {"]]],
  ["AA4 dispatch 只看 registry", [["        if (noConsumers()) {\n", "        if (registry.size === 0) {\n"]]],
  ["AA5 dispatch 只看 tainted", [["        if (noConsumers()) {\n", "        if (tainted.size === 0) {\n"]]],
  ["Z1 零插件仍登記配對", [["        if (noConsumers()) return;\n        pendingMethods.set(key, {", "        pendingMethods.set(key, {"]]],
  ["Z2 配對不設容量上限", [["        if (pendingMethods.size > PENDING_LIMIT) pendingMethods.delete(pendingMethods.keys().next().value);\n", ""]]],
  ["Z3 關閉不清配對", [["            Array.from(pendingMethods.keys()).forEach(function (k) { if (k.indexOf(prefix) === 0) pendingMethods.delete(k); });\n", ""]]],
  ["Z4 關閉清掉所有連線的配對", [["if (k.indexOf(prefix) === 0) pendingMethods.delete(k);", "pendingMethods.delete(k);"]]],
  ["Z5 pairWith 繞過唯一寫入口", [["e.method) remember(socketId, e.msgId, e.method);", "e.method) pendingMethods.set(msgKey(socketId, e.msgId), e.method);"]]],
  ["Y1 failSafe 照送不恢復配對", [["try { if (env && !injected) pairWith(socketId, original); } catch (x)", "try { } catch (x)"]]],
  ["Y2 大廳非守衛方法照送不恢復配對", [["                    if (!guard) return sendOriginal();\n", "                    if (!guard) return;\n"]]],
  ["Y3 failSafe 查找出錯照送不恢復配對", [["(!env && !guardActive())) return sendOriginal();\n            }\n", "(!env && !guardActive())) return;\n            }\n"]]],
  ["Y4 非大廳照送不恢復配對", [["if (!isLobby(socketId) || isFastTest(env) || (!env && !guardActive())) return sendOriginal();", "if (!isLobby(socketId) || isFastTest(env) || (!env && !guardActive())) return;"]]],
  ["X1 擋下不撤銷配對", [["if (msgId != null && !raw.injected) pendingMethods.delete(msgKey(raw.wsId, msgId));", "if (false) pendingMethods.delete(msgKey(raw.wsId, msgId));"]]],
  ["X2 擋下仍提交配對", [["if (!(result && result.block) && !raw.injected) pairWith(raw.wsId, raw.bytes);", "if (!raw.injected) pairWith(raw.wsId, raw.bytes);"]]],
  ["X3 本地結案仍刪配對", [["            var key = msgKey(socketId, msgId);\n", "            var key = msgKey(socketId, msgId);\n            pendingMethods.delete(key);\n"]]],
  ["X4 disable 無條件清失敗計數", [["            if (!registry.has(id)) {\n                failures.delete(id);", "            failures.delete(id);\n            if (!registry.has(id)) {"]]],
  ["X5 disable 無條件刪 grant", [["            if (!registry.has(id)) {\n                failures.delete(id);\n                if (window.__nakiPluginGrants) delete window.__nakiPluginGrants[id];\n            }", "            if (!registry.has(id)) failures.delete(id);\n            if (window.__nakiPluginGrants) delete window.__nakiPluginGrants[id];"]]],
  ["W1 回應配對不在守衛判決後提交", [["        if (!(result && result.block) && !raw.injected) pairWith(raw.wsId, raw.bytes);\n        return result;", "        return result;"]]],
  ["W3 失敗記帳不核對實例", [["        if (!current(entry)) return;\n        var f = failures.get(id) || {};", "        var f = failures.get(id) || {};"]]],
  ["W4 成功記帳不核對實例", [["var f = current(entry) && failures.get(entry.id);", "var f = failures.get(entry.id);"]]],
  ["W5 先核對實例再讀錯誤訊息", [["        var message, id = entry.id;\n", "        var message, id = entry.id;\n        if (!current(entry)) return;\n"], ["        if (!current(entry)) return;\n        var f = failures.get(id) || {};", "        var f = failures.get(id) || {};"]]],
  ["V1 放行不核對註冊實例", [["return a.id === ids[i] && !!entry && a.token === entry.token && a.version === versionOf(a.id);", "return a.id === ids[i] && !!entry && a.version === versionOf(a.id);"]]],
  ["V2 放行不核對污染版本", [["return a.id === ids[i] && !!entry && a.token === entry.token && a.version === versionOf(a.id);", "return a.id === ids[i] && !!entry && a.token === entry.token;"]]],
  ["V3 放行版本在記帳時才取", [["if (p.isGuard) guard.approved.push(p.approval);", "if (p.isGuard) guard.approved.push({ id: p.entry.id, token: p.entry.token, version: versionOf(p.entry.id) });"]]],
  ["V4 污染不遞增版本", [["        if (first || set.size !== size) taintVersions.set(id, versionOf(id) + 1);\n", ""]]],
  ["V15 重複污染也遞增版本", [["if (first || set.size !== size) taintVersions.set(", "if (true) taintVersions.set("]]],
  ["V16 守衛拋錯或 thenable 後退出也解除", [["if (!now && guard && !guard.threw.length && !guard.async.length && !respondFailure(guard, raw.tx)) {", "if (!now && guard && !respondFailure(guard, raw.tx)) {"]]],
  ["V5 送出鏈成功立即記帳", [["                } else if (copy) {\n", "                } else if (false) {\n"]]],
  ["V6 鏈尾違規者仍記成功", [["var charged = bad && p.entry === last;", "var charged = false;"]]],
  ["V7 鏈尾歸責讀 spec.id", [["noteFailure(last, 'onSend'", "noteFailure(registry.get(last.spec.id) || last, 'onSend'"]]],
  ["V8 registry 身分跟著 spec.id 走", [["var entry = { id: id, token:", "var entry = { get id() { return spec.id; }, token:"]]],
  ["V9 守衛全部退出時不解除", [["if (!now && guard && !guard.threw.length && !guard.async.length && !respondFailure(guard, raw.tx)) {", "if (false) {"]]],
  ["V10 receive 等長不驗結構", [["if (!after || !isWellFormed(raw.bytes) || after.type", "if (!after || after.type"]]],
  ["V11 送出就地改不驗結構", [[": !now || !isWellFormed(staged) || now.type", ": !now || now.type"]]],
  ["V13 記帳後不再判", [["} else if (last && !sameBytes(cur, original) && finalViolation(cur, type, msgId, method, lobby)) {", "} else if (false) {"]]],
  ["U1 就地改可換 method", [[" || now.msgId !== msgId || now.method !== method) {", " || now.msgId !== msgId) {"]]],
  ["U2 已有守衛時不併入鏈中新增的守衛者", [["if (now) guard = { method: env.method, ids: now.ids,", "if (now && !guard) guard = { method: env.method, ids: now.ids,"]]],
  ["U3 開頭沒有守衛者就不重算", [["var now = env.method ? guardFor(env.method) : null;", "var now = guard && env.method ? guardFor(env.method) : null;"]]],
  ["U4 鏈尾不終判", [["var bad = last && !sameBytes(cur, original) ? finalViolation(cur, type, msgId, method, lobby) : null;", "var bad = null;"]]],
  ["U5 鏈尾不合規但不退回", [["if (bad) { cur = original; env = parseEnvelope(original); }", "if (bad) { env = parseEnvelope(original); }"]]],
  ["U6 鏈尾禁改名單只看換 method", [["if (SEND_FORBIDDEN_METHODS.indexOf(fin.method) !== -1 || (fin.method !== method && isSendForbidden(fin.method))) {", "if (fin.method !== method && isSendForbidden(fin.method)) {"]]],
  ["U7 鏈尾失敗記在第一個改動者", [["                    last = entry;\n", "                    last = last || entry;\n"]]],
  ["U8 receive replace 以自有 length 選路", [["if (taLength.call(next) !== taLength.call(raw.bytes)) {", "if (newBytes.length !== raw.bytes.length) {"]]],
  ["U10 receive 變長入口不物化（等價：new Uint8Array(TypedArray) 也只讀內部槽並複製）", [["return caps.indexOf('reshapeReceive') !== -1 && reshapeReceive(raw, env, method, entry, next);", "return caps.indexOf('reshapeReceive') !== -1 && reshapeReceive(raw, env, method, entry, new Uint8Array(newBytes));"]]],
  ["U9 receive replace 寫入未物化的原參數", [["                u8set.call(raw.bytes, next);\n", "                try { raw.bytes.set(newBytes); } catch (e) { return false; }\n"]]],
  ["T1 送出 replace 入口不物化（共用來源記憶體）", [["try { next = hostCopy(newBytes); } catch (e) { return false; }\n                var after", "next = new Uint8Array(newBytes);\n                var after"]]],
  ["T2 送出 replace 入口讀自有 length", [["try { next = hostCopy(newBytes); } catch (e) { return false; }\n                var after", "try { next = new U8(newBytes.length); u8set.call(next, newBytes); } catch (e) { return false; }\n                var after"]]],
  ["T3 hook 結束不驗就地改的 type／msgId", [["now.type !== type || now.msgId !== msgId || now.method !== method) {", "now.method !== method) {"]]],
  ["T4 送出 replace 入口不驗證", [["var after = sendViolation(next, env.msgId) ? null : parseEnvelope(next);", "var after = parseEnvelope(next);"]]],
  ["T6 物化失敗退回共用 view", [["try { next = hostCopy(newBytes); } catch (e) { return false; }\n                var after", "try { next = hostCopy(newBytes); } catch (e) { next = new Uint8Array(newBytes); }\n                var after"]]],
  ["T7 hook 結束對 replace 跳過完整重驗（等價，入口已驗同一份）", [["if (replaced ? sendViolation(staged, msgId)\n", "if (replaced ? false\n"]]],
  ["T8 hook 結束對 replace 跳過大廳守衛", [["(lobby ? now.method !== method && guardFor(now.method)", "(lobby ? !replaced && now.method !== method && guardFor(now.method)"]]],
  ["T9 hook 結束只驗 type 不驗 msgId", [[" || now.msgId !== msgId || now.method !== method) {", " || now.method !== method) {"]]],
  ["S1 插件直接拿宿主快照 cur（不複製）", [["var before = copy ? hostCopy(cur) : raw.bytes;", "var before = copy ? cur : raw.bytes;"]]],
  ["S2 送出鏈不複製（插件拿原件）", [["var copy = raw.direction === 'send' && raw.mutable !== false;", "var copy = false;"]]],
  ["S3 物化讀實例 length", [["var c = new U8(taLength.call(b));", "var c = new U8(b.length);"]]],
  ["S4 外送插件持有的最後副本", [["        if (copy) raw.bytes = cur;\n        if (raw.bytes === original", "        if (copy) raw.bytes = before;\n        if (raw.bytes === original"]]],
  ["S5 內容變了仍送原物件", [["if (raw.bytes === original || (copy && sameBytes(cur, original)))", "if (raw.bytes === original || copy)"]]],
  ["S6 錯誤訊息讀兩次", [["            var m = err && err.message;   // getter 只觸發一次\n            message = String(m ? m : err);", "            message = String(err && err.message ? err.message : err);"]]],
  ["S7 物化失敗不視為違規", [["if (!staged) throw new Error('送出內容無法讀取（buffer 已分離），已撤回');", "if (!staged) staged = cur;"]]],
  ["S8 物化前就記帳（驗證用插件陣列本身）", [["try { staged = hostCopy(raw.bytes); } catch (x) { staged = null; }", "staged = raw.bytes;"]]],
  ["P1 先驗證再接管 thenable", [["                    settle(ret, entry, hook, state);\n", ""], ["                // 守衛插件改了或丟了大廳的回應", "                if (thenable) settle(ret, entry, hook, state);\n                // 守衛插件改了或丟了大廳的回應"]]],
  ["P2 注入退回只認代號（相同 bytes 的重入不判）", [["(raw.injected || (injecting && sameBytes(raw.bytes, injecting.bytes)))", "(raw.injected)"]]],
  ["P3 相同 bytes 也當注入來源", [["raw.injected = send && liveTokens.has(raw.sender);", "raw.injected = send && (liveTokens.has(raw.sender) || (!!injecting && sameBytes(raw.bytes, injecting.bytes)));"]]],
  ["P4 違規後仍記 thenable 結果", [["                    judge(state, entry, hook, true);\n", "                    judge(state, entry, hook, false);\n"]]],
  ["P5 不接 rejection", [["thenable.then(function () { done(true); }, function (e) { done(false, e); });", "thenable.then(function () { done(true); });"]]],
  ["P6 提早 resolve 立刻記成功", [["if (!state.judged) { state.early = { ok: ok, e: e }; return; }", "if (!state.judged) { if (ok) noteSuccess(entry, hook); else state.early = { ok: ok, e: e }; return; }"]]],
  ["P7 判定通過時丟掉提早結果", [["if (!failed && state.early) {", "if (false) {"]]],
  ["N2 finally 還原 null", [["finally { injecting = prev; liveTokens.delete(token); }", "finally { injecting = null; liveTokens.delete(token); }"]]],
  ["N3 只在正常返回時還原", [["try { r = (ws && ws.sendRaw) ? ws.sendRaw(b64, token) : { success: false, reason: 'no_sendRaw' }; }\n                finally { injecting = prev; liveTokens.delete(token); }", "r = (ws && ws.sendRaw) ? ws.sendRaw(b64, token) : { success: false, reason: 'no_sendRaw' };\n                injecting = prev; liveTokens.delete(token);"]]],
  ["N4 注入退回不先以常數排除", [["if (env.type !== TYPE_REQUEST || GUARDABLE_METHODS.indexOf(env.method) === -1) return undefined;\n        try {", "try {"]]],
  ["N5 先記成功再驗證", [["var ret = callHook(fn, ctx);   //", "var ret = callHook(fn, ctx); noteSuccess(entry, hook);   //"]]],
  ["N6 非大廳只查就地（漏 replace）", [[": GUARDABLE_METHODS.indexOf(now.method) !== -1)) {", ": !replaced && GUARDABLE_METHODS.indexOf(now.method) !== -1)) {"]]],
  ["Q4 錯誤訊息讀取不設防", [["        } catch (x) { message = '（錯誤訊息無法讀取）'; }", "        } finally {}"]]],
  ["M1 不檢查注入退回", [["if (send && env && (raw.injected || (injecting && sameBytes(raw.bytes, injecting.bytes)))) {", "if (false) {"]]],
  ["M2 不設注入標記", [["injecting = { bytes: envBytes };", ";"]]],
  ["M4 注入查找出錯放行", [["} catch (e) { ids = []; }", "} catch (e) { return undefined; }"]]],
  ["M5 注入退回改 lobby 才判", [["var fallback = isLobby(raw.wsId) ? undefined : injectedFallback(raw, env);", "var fallback = isLobby(raw.wsId) ? injectedFallback(raw, env) : undefined;"]]],
  ["M6 非大廳改寫不檢查", [[": GUARDABLE_METHODS.indexOf(now.method) !== -1)) {", ": false)) {"]]],
  ["M7 非大廳改讀 guardFor", [[": GUARDABLE_METHODS.indexOf(now.method) !== -1)) {", ": guardFor(now.method))) {"]]],
  ["M9 refuseOpaqueSend 只看 lobby", [["if (roles.get(socketId) === 'game') return false;", "if (!isLobby(socketId)) return false;"]]],
  ["M10 refuseOpaqueSend 連 game 也拒", [["if (roles.get(socketId) === 'game') return false;", ";"]]],
  ["M11 非大廳要求 method 改變", [[": GUARDABLE_METHODS.indexOf(now.method) !== -1)) {", ": now.method !== method && GUARDABLE_METHODS.indexOf(now.method) !== -1)) {"]]],
  ["PS1 配發不避未答注入", [["        injectedMsgIds.forEach(function (v, k) { busy.add(Number(k.slice(k.lastIndexOf(':') + 1))); });\n", ""]]],
  ["PS2 配發不避遊戲未答", [["g.inflight.forEach(function (c, id) { busy.add(id); }); });", " });"]]],
  ["PS3 配發不避遊戲窗口", [["return a > 0 && a <= GAME_AHEAD; })) return v;", "return false; })) return v;"]]],
  ["PS4 遊戲窗口少算邊界", [["a > 0 && a <= GAME_AHEAD", "a > 0 && a < GAME_AHEAD"]]],
  ["PS5 注入仍寫 pendingMethods", [["        if (!raw.injected) rememberIfRequest(env, raw.direction, raw.wsId);", "        rememberIfRequest(env, raw.direction, raw.wsId);"]]],
  ["PS6 注入回應改用 resolveMethod", [["var method = injected ? injection.method : resolveMethod(env, raw.direction, raw.wsId, wm);", "var method = resolveMethod(env, raw.direction, raw.wsId, wm);"]]],
  ["PS7 關閉不清注入登記", [["            Array.from(injectedMsgIds.keys()).forEach(function (k) { if (k.indexOf(prefix) === 0) injectedMsgIds.delete(k); });\n", ""]]],
  ["PS8 Naki 自送也算遊戲號碼", [["raw.direction === 'send' && raw.sender === undefined && !!raw.bytes", "raw.direction === 'send' && typeof raw.sender !== 'object' && !!raw.bytes"]]],
  ["PS9 失準不拒發", [["if (lost || untrustedSockets.size) return null;", "if (untrustedSockets.size) return null;"]]],
  ["PS10 RESPONSE 不消耗遊戲未答", [["        if (!send && b.length >= 3 && b[0] === TYPE_RESPONSE && !injectionFor(msgKey(raw.wsId, b[1] | (b[2] << 8)), raw.watermark)) gameDone(raw.wsId, b[1] | (b[2] << 8), raw.watermark);\n", ""]]],
  ["PS12 關閉不清遊戲紀錄", [["            gameSends.delete(socketId);\n", ""]]],
  ["PS13 零消耗者不消耗注入登記", [["if (k && !send && e.type === TYPE_RESPONSE && injectionFor(k, raw.watermark))", "if (false)"]]],
  ["PS14 本地結案不看來源", [["            if (!injected) return;\n", ""]]],
  ["PS15 歧義回應仍可改寫", [["var isNaki = !!raw.synthetic || injected || ambiguous || (raw.direction", "var isNaki = !!raw.synthetic || injected || (raw.direction"]]],
  ["PS16 歧義不標記", [["        if (injected && ambiguous) markAmbiguous(raw.wsId, injectedKey);\n", ""]]],
  ["PS17 failSafe 不辨識注入", [["var injected = liveTokens.has(sender);", "var injected = false;"]]],
  ["PS18 注入回應也消耗遊戲未答", [[" && !injectionFor(msgKey(raw.wsId, b[1] | (b[2] << 8)), raw.watermark)) gameDone", ") gameDone"]]],
  ["PS19 注入被擋撤銷同鍵配對", [["if (msgId != null && !raw.injected) pendingMethods.delete(", "if (msgId != null) pendingMethods.delete("]]],
  ["PS20 非大廳鏈尾不辨識注入", [["if (!lobby && !raw.injected) pairWith", "if (!lobby) pairWith"]]],
  ["PS21 歧義滿時淘汰最舊", [["        ambiguousPairs.forEach(function (s, k) { ambiguousSockets.add(k.slice(0, k.lastIndexOf(':'))); });\n        ambiguousPairs.clear();\n", "        ambiguousPairs.delete(ambiguousPairs.keys().next().value);\n"]]],
  ["PS22 不查整條連線歧義", [["        return ambiguousSockets.has(String(socketId));\n", "        return false;\n"]]],
  ["PS23 送出判決前就記未答", [["if (game && !(result && result.block)) commitGameSend", "if (game) commitGameSend"]]],
  ["PS24 零消耗者不看歧義標記", [["pendingMethods.size || injectedMsgIds.size || ambiguousPairs.size", "pendingMethods.size || injectedMsgIds.size"]]],
  ["PS25 sendRaw 不帶代號", [["ws.sendRaw(b64, token)", "ws.sendRaw(b64)"]]],
  ["PS26 派發中不保留號碼", [["            if (mark) gameDispatching.push(mark);\n", ""]]],
  ["PS27 保留號碼不進避號集合", [["gameDispatching.forEach(function (d) { busy.add(d.msgId); lasts.push(d.msgId); });", "gameDispatching.forEach(function (d) { lasts.push(d.msgId); });"]]],
  ["PS28 保留號碼不推前方窗", [["gameDispatching.forEach(function (d) { busy.add(d.msgId); lasts.push(d.msgId); });", "gameDispatching.forEach(function (d) { busy.add(d.msgId); });"]]],
  ["PS32 代號不是一次性", [["finally { injecting = prev; liveTokens.delete(token); }", "finally { injecting = prev; }"]]],
  ["PS33 派發結束不釋放保留", [["                if (mark) gameDispatching.splice(gameDispatching.indexOf(mark), 1);\n", ""]]],
  ["PS29 failSafe 擋下不撤回", [["if (sender === undefined && tx) revertGameSend(tx.commit);", "if (false) revertGameSend(tx.commit);"]]],
  ["PS30 撤回不回復失準", [["        if (clean && c.lostSet) g.lost = false;\n", ""]]],
  ["PS31 撤回不放回被淘汰的號碼", [["        if (clean && c.evicted) g.inflight = new Map([c.evicted].concat(Array.from(g.inflight)));\n", ""]]],
  ["PS34 dispatch 不把提交記進交易", [["        tx.commit = c;\n", ""]]],
  ["PS36 撤回不查擁有者", [["if (g.inflight.get(c.msgId) === c.seq) {", "if (true) {"]]],
  ["PS37 撤回不放回先前提交", [["g.inflight.delete(c.msgId); if (c.prev !== undefined) g.inflight.set(c.msgId, c.prev); }", "g.inflight.delete(c.msgId); }"]]],
  ["PS38 撤回不比版本", [["clean = g.version === c.version;", "clean = true;"]]],
  ["PS39 消耗不推版本", [["            g.inflight.delete(msgId);\n            g.version++;\n", "            g.inflight.delete(msgId);\n"]]],
  ["PS40 撤回用整表快照", [["        if (g.inflight.get(c.msgId) === c.seq) {", "        if (true) { g.inflight = new Map(Array.from(g.inflight).filter(function (e) { return e[1] < c.seq; })); }\n        if (false) {"]]],
  ["PS43 暫時淘汰項被回答不作廢", [["        openCommits.forEach(function (c) { if (c.g === g && c.evicted && c.evicted[0] === msgId && !newerThan(watermark, c.evicted[1])) c.evicted = null; });\n", ""]]],
  ["PS44 交易結束不釋放撤回資料", [["            else openCommits.delete(c);\n", ""]]],
  ["PS45 底層 send 失敗不撤回", [["if (failed) revertGameSend(c);\n            else openCommits.delete(c);", "openCommits.delete(c);"]]],
  ["PS48 failSafe 照送重複提交", [["if (sender === undefined && original && !(tx && tx.commit)) commitGameSend", "if (sender === undefined && original) commitGameSend"]]],
  ["PS49 標不可信無效", [["markUntrusted: function (socketId) { untrustedSockets.add(socketId); degrade(socketId, 'send_blob'); }", "markUntrusted: function (socketId) { degrade(socketId, 'send_blob'); }"]]],
  ["PS50 不可信連線不拒發", [["if (lost || untrustedSockets.size) return null;", "if (lost) return null;"]]],
  ["PS51 關閉不清不可信", [["            untrustedSockets.delete(socketId);\n", ""]]],
  ["PS52 延後派發也記帳", [["&& !!raw.bytes && !raw.deferred;", "&& !!raw.bytes;"]]],
  ["PS53 連線釋放後仍派發 Blob", [["                    if (!wsConnections.has(ws)) return;\n", ""]], "naki-websocket.js"],
  ["PS54 入口不標不可信", [["            window.__nakiPlugins.markUntrusted(wsId);\n", ""]], "naki-websocket.js"],
  ["PS55 標記延到展開後", [["            window.__nakiPlugins.markUntrusted(wsId);\n", ""], ["                    if (!wsConnections.has(ws)) return;\n", "                    if (!wsConnections.has(ws)) return;\n                    if (direction === 'send' && sender === undefined) window.__nakiPlugins.markUntrusted(wsId);\n"]], "naki-websocket.js"],
  ["PS56 延後回應消耗較新的未答", [["            if (newerThan(watermark, g.inflight.get(msgId))) return;\n", ""]]],
  ["PS57 延後回應消耗較新的配對", [["if (p && !newerThan(watermark, p.seq)) {", "if (p) {"]]],
  ["PS58 配對不帶序號", [["pendingMethods.set(key, { method: method, seq: nextSeq() });", "pendingMethods.set(key, { method: method, seq: 0 });"]]],
  ["PS60 排隊接收不取水位", [["{ watermark: entry.watermark, synthetic: entry.synthetic }", "{ watermark: undefined, synthetic: entry.synthetic }"]], "naki-websocket.js"],
  ["PS61 入口不排除已釋放連線", [["            if (!wsConnections.has(ws)) return originalSend(data);\n", ""]], "naki-websocket.js"],
  ["PS62 延後派發拋錯仍走 failSafe", [["if (direction === 'send' && !deferred && window.__nakiPlugins.failSafe)", "if (direction === 'send' && window.__nakiPlugins.failSafe)"]], "naki-websocket.js"],
  ["PS63 延後回應認領較新的注入", [["return token !== undefined && !newerThan(watermark, token.seq) ? token : undefined;", "return token;"]]],
  ["PS65 零消耗者認領不看水位", [["injectionFor(k, raw.watermark)) { injectedMsgIds.delete(k);", "injectedMsgIds.has(k)) { injectedMsgIds.delete(k);"]]],
  ["PS66 延後注入回應遇較新配對仍建歧義", [["var ambiguous = injected ? pairWaiting(injectedKey, wm) :", "var ambiguous = injected ? pendingMethods.has(injectedKey) :"]]],
  ["PS67 零消耗者延後回應刪較新配對", [["if (send || pairWaiting(k, raw.watermark)) pendingMethods.delete(k);", "pendingMethods.delete(k);"]]],
  ["PS68 Blob 待展開時同步封包不排隊", [["(dataType === 'Blob' || ((info.recvQueue.length || info.flushing) && (dataType === 'ArrayBuffer' || dataType === 'TypedArray')))", "(dataType === 'Blob')"]], "naki-websocket.js"],
  ["PS69 依展開順序派發", [["while (q.length && q[0].ready) {", "while (q.some(e => e.ready)) {\n                q.sort((a, b) => b.ready - a.ready);"]], "naki-websocket.js"],
  ["PS70 歧義標記用建立當下的新序號", [["ambiguousPairs.set(key, pendingMethods.get(key).seq);", "ambiguousPairs.set(key, nextSeq());"]]],
  ["PS71 展開失敗卡住佇列", [["const failed = function(e) { console.error('[Naki WS] Blob 插件 dispatch 轉換失敗:', e); settle(null); };", "const failed = function(e) { console.error('[Naki WS] Blob 插件 dispatch 轉換失敗:', e); };"]], "naki-websocket.js"],
  ["PS72 同步拋錯卡住佇列", [["try { Promise.resolve(data.arrayBuffer()).then(settle, failed); } catch (e) { failed(e); }", "try { Promise.resolve(data.arrayBuffer()).then(settle, failed); } catch (e) { }"]], "naki-websocket.js"],
  ["PS73 釋放不丟棄佇列", [["if (info) { info.recvQueue.length = 0; info.injected.length = 0; }", "if (info) { info.injected.length = 0; }"]], "naki-websocket.js"],
  ["PS74 排隊同步封包送 Swift 之後才就緒", [["            entry.ready = true;\n            sendToSwift(", "            sendToSwift("], ["type: 'binary', size: view.byteLength });\n        } finally {", "type: 'binary', size: view.byteLength });\n            entry.ready = true;\n        } finally {"]], "naki-websocket.js"],
  ["PS75 讀取失敗不宣告接收不可信", [["if (!entry.view) { if (entry.failed) receiveLost(wsId, info, 'receive_blob_failed'); continue; }", "if (!entry.view) continue;"]], "naki-websocket.js"],
  ["PS76 接收不可信的回應仍進一般鏈", [["injected || ambiguous || (raw.direction === 'receive' && recvLostSockets.has(String(raw.wsId))) || isNakiMsgId(", "injected || ambiguous || isNakiMsgId("]]],
  ["PS77 接收不可信不結案既有注入", [["if (k.indexOf(prefix) !== 0) return;\n                var injection = injectedMsgIds.get(k);", "return;\n                var injection = injectedMsgIds.get(k);"]]],
  ["PS78 接收不可信不拒發新注入", [["            untrustedSockets.add(socketId);\n            recvLostSockets.add(String(socketId));", "            recvLostSockets.add(String(socketId));"]]],
  ["PS79 flush 中佇列空時同步封包不排隊", [["(info.recvQueue.length || info.flushing)", "info.recvQueue.length"]], "naki-websocket.js"],
  ["PS80 排隊快照取在遮罩之前", [["try { nakiNicknameMask.observe(view, 'receive'); entry.view = view.slice(); }", "entry.view = view.slice(); try { nakiNicknameMask.observe(view, 'receive'); }"]], "naki-websocket.js"],
  ["PS81 遮罩拋錯不留快照", [["entry.view = original; }", "}"]], "naki-websocket.js"],
  ["PS82 溢出不宣告接收不可信", [["        receiveLost(wsId, info, 'receive_queue_overflow');\n        info.recvQueue.forEach", "        info.recvQueue.forEach"]], "naki-websocket.js"],
  ["PS83 溢出不放棄待展開項", [["        info.recvQueue.forEach(function(e) { if (!e.ready) { e.ready = true; e.view = null; } });\n", ""]], "naki-websocket.js"],
  ["PS84 關閉不清接收不可信", [["            recvLostSockets.delete(String(socketId));\n", ""]]],
  ["PS85 在途注入遇接收不可信仍登記", [["if (recvLostSockets.has(sid)) {", "if (false) {"]]],
  ["PS86 在途注入遇接收不可信不結案", [["Promise.resolve().then(function () { injectionLost(socketId, msgId, token, 'receive_untrusted'); });", ""]]],
  ["PS87 遮罩拋錯不還原共享內容", [["view.set(original); entry.view = original;", "entry.view = original;"]], "naki-websocket.js"],
  ["PS88 接收不可信只管 RESPONSE", [["(raw.direction === 'receive' && recvLostSockets", "(injectedKey != null && recvLostSockets"]]],
  ["PS90 檢查後才取序號", [["                token.seq = nextSeq();\n", ""], ["                injectedMsgIds.set(msgKey(sid, msgId), token);\n", "                token.seq = nextSeq();\n                injectedMsgIds.set(msgKey(sid, msgId), token);\n"]]],
  ["PS91 淘汰注入靜默遺失", [["Promise.resolve().then(function () { injectionLost(evicted.socketId, evicted.msgId, evicted, 'evicted'); });", ""]]],
  ["PS92 淘汰結案不帶原因", [["rctx.reason = reason;", ""]]],
  ["PS93 登記鍵再讀回傳值", [["injectedMsgIds.set(msgKey(sid, msgId), token);", "injectedMsgIds.set(msgKey(r.socketId, msgId), token);"]]],
  ["PS94 代號欄位在檢查之後才賦值", [["                token.socketId = socketId;\n                token.msgId = msgId;\n", ""], ["                injectedMsgIds.set(msgKey(sid, msgId), token);\n", "                token.socketId = socketId;\n                token.msgId = msgId;\n                injectedMsgIds.set(msgKey(sid, msgId), token);\n"]]],
  ["PS35 擋下仍消耗遊戲未答", [["            if (msgId != null && !raw.injected) pendingMethods.delete(msgKey(raw.wsId, msgId));\n", "            if (msgId != null && !raw.injected) { pendingMethods.delete(msgKey(raw.wsId, msgId)); gameDone(raw.wsId, msgId); }\n"]]],
  ["VB2 同鍵覆寫不移到最新（只在零消耗者時刪舊鍵）", [["        var key = msgKey(socketId, msgId);\n        pendingMethods.delete(key);\n        if (noConsumers()) return;\n", "        var key = msgKey(socketId, msgId);\n        if (noConsumers()) { pendingMethods.delete(key); return; }\n"]]],
  ["IR1 合成同步交付", [["setTimeout(function() { deliverInjected(ws, info, item); }, 0);", "deliverInjected(ws, info, item);"]], "naki-websocket.js"],
  ["IR2 合成 microtask 交付", [["setTimeout(function() { deliverInjected(ws, info, item); }, 0);", "Promise.resolve().then(function() { deliverInjected(ws, info, item); });"]], "naki-websocket.js"],
  ["IR3 觀察項不入隊", [["        info.recvQueue.push({ view: item.bytes.slice(), ready: true, failed: false, blob: false, watermark: undefined, synthetic: item.pluginId, at: Date.now() });\n        checkOverflow(info.id, info);\n        flushReceive(info.id, info);\n", ""]], "naki-websocket.js"],
  ["IR4 觀察項繞過佇列", [["        info.recvQueue.push({ view: item.bytes.slice(), ready: true, failed: false, blob: false, watermark: undefined, synthetic: item.pluginId, at: Date.now() });\n        checkOverflow(info.id, info);\n        flushReceive(info.id, info);\n", "        dispatchToPlugins('receive', info.id, info, item.bytes.slice(), false, false, undefined, undefined, { watermark: undefined, synthetic: item.pluginId });\n"]], "naki-websocket.js"],
  ["IR5 合成進一般鏈", [["var isNaki = !!raw.synthetic || injected", "var isNaki = injected"]]],
  ["IR6 合成 ctx 帶 sendRequest", [["if (caps.indexOf('injectSend') !== -1 && !raw.synthetic) {", "if (caps.indexOf('injectSend') !== -1) {"]]],
  ["IR7 送 Swift 失敗仍交付遊戲", [["        if (!sent) return drop('送 Swift 失敗');\n", ""]], "naki-websocket.js"],
  ["IR8 不查禁改名單", [["                if (isReshapeForbidden(e.method) || FORBIDDEN_METHODS.indexOf(e.method) !== -1) return { ok: false, reason: 'forbidden_method' };\n", ""]]],
  ["IR9 不查 NOTIFY 型別與 method", [["if (!e || e.type !== TYPE_NOTIFY || !e.method || !isWellFormed(next))", "if (!e || !isWellFormed(next))"]]],
  ["IR10 交付時不查接收不可信", [["        if (info.recvLost) return drop('連線接收不可信');\n", ""]], "naki-websocket.js"],
  ["IR11 釋放不清待交付", [["if (info) { info.recvQueue.length = 0; info.injected.length = 0; }", "if (info) { info.recvQueue.length = 0; }"]], "naki-websocket.js"],
  ["IR12 不設待交付上限", [["        if (info.injected.length >= maxPending) return { ok: false, reason: 'inject_busy' };\n", ""]], "naki-websocket.js"],
  ["IR13 關閉中的連線也接受", [["if (!info || ws.readyState !== OriginalWebSocket.OPEN) return { ok: false, reason: 'no_connection' };", "if (!info) return { ok: false, reason: 'no_connection' };"]], "naki-websocket.js"],
  ["IR14 交付插件自己的 buffer（入口不複製）", [["ws.injectReceive(raw.wsId, next, grant.__id", "ws.injectReceive(raw.wsId, notifyBytes, grant.__id"]]],
  ["IR15 呼叫時不查接收不可信", [["        if (info.recvLost) return { ok: false, reason: 'receive_untrusted' };\n", ""]], "naki-websocket.js"],
  ["IR16 injectReceive 不查 L3", [["                if (!window.__nakiPluginsMayModifyOutbound) return { ok: false, reason: 'outbound_disabled' };\n                var next;\n", "                var next;\n"]]],
  ["IR17 長度上限邊界差一", [["if (taLength.call(next) > SYNTHETIC_MAX_BYTES) return { ok: false, reason: 'bad_bytes' };", "if (taLength.call(next) >= SYNTHETIC_MAX_BYTES) return { ok: false, reason: 'bad_bytes' };"]]],
  ["RL1 dispatch 不把提案改為本地成功", [["                if (raw && raw.tx && raw.tx.local && !(result && result.block)) result = localOk(raw, origObj, null);\n", ""]]],
  ["RL2 failSafe 照送不看提案", [["                if (tx && tx.local) {\n                    var ok = localOk(", "                if (false) {\n                    var ok = localOk("]]],
  ["RL3 本地結局不推進遊戲最後號碼", [["            else if (mark) gameLast(raw.wsId, mark.msgId, mark.order);\n", ""]]],
  ["RL4 failSafe 擋下不推進遊戲最後號碼", [["            if (sender === undefined && verdict.msgId != null) gameLast(socketId, verdict.msgId, orderOf(tx));\n", ""]]],
  ["RL5 禁用名單少 cancelMatch", [["var RESPOND_FORBIDDEN_METHODS = ['.lq.Lobby.cancelUnifiedMatch', '.lq.Lobby.cancelMatch'];", "var RESPOND_FORBIDDEN_METHODS = ['.lq.Lobby.cancelUnifiedMatch'];"]]],
  ["RL6 不查 too_late", [["                else if (!openCtx.has(ctx)) reason = 'too_late';\n", ""]]],
  ["RL7 不查 rewritten", [["                    else if (!sameBytes(raw.bytes, raw.sendOriginal)) reason = 'rewritten';\n", ""]]],
  ["RL8 後到者覆蓋提案", [["                    else if (tx.local) reason = 'already_responded';\n", ""]]],
  ["RL9 提案後仍可 replace", [["if (!window.__nakiPluginsMayModifyOutbound || (raw.tx && raw.tx.local)) return false;", "if (!window.__nakiPluginsMayModifyOutbound) return false;"]]],
  ["RL10 守衛者被拒不算第 3 步", [["        var refused = respondFailure(guard, tx);\n        if (refused) return refused;\n", ""]]],
  ["RL11 3b 不在第 4–7 步之前", [["        if (tx && tx.local) return tx.local.guardian ? null : 'not_guardian';\n        var ids = guard.ids", "        var ids = guard.ids"]]],
  ["RL12 不查回應 msgId", [["after.type !== TYPE_RESPONSE || after.msgId !== env.msgId ||", "after.type !== TYPE_RESPONSE ||"]]],
  ["RL13 守衛者全部退出時忽略提案", [["                if (raw.tx && raw.tx.local) return localOk(raw, origObj, guard.ids);\n                restore(raw, origObj, original);", "                restore(raw, origObj, original);"]]],
  ["RL14 failSafe 先於守衛判定交付提案", [["            var injected = liveTokens.has(sender);   // 這次注入：配對在注入登記，不寫 pendingMethods\n", "            var injected = liveTokens.has(sender);   // 這次注入：配對在注入登記，不寫 pendingMethods\n            if (tx && tx.local) return localOk({ bytes: data, wsId: socketId, tx: tx }, data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength), null);\n"]]],
  ["RL15 failSafe 本地成功不推進遊戲最後號碼", [["                    if (sender === undefined && ok.msgId != null) gameLast(socketId, ok.msgId, orderOf(tx));\n", ""]]],
  ["DG1 退化事件在 hook 中途同步交付（終判後外送前、onRecommendations 中途）", [["        degradeScheduled = true;\n        setTimeout(deliverDegraded, 0);\n", "        deliverDegraded();\n"]]],
  ["DG2 退化事件重複發", [["        if (degradedSeen.has(key)) return;\n", ""]]],
  ["DG3 撤回的未答溢出也發（不看結算後是否仍失準）", [["if (c && c.lostSet && c.g.lost && gameSends", "if (c && c.lostSet && gameSends"]]],
  ["DG4 漏發 send_blob", [["untrustedSockets.add(socketId); degrade(socketId, 'send_blob'); },", "untrustedSockets.add(socketId); },"]]],
  ["DG5 佇列溢出記成讀取失敗", [["degrade(socketId, reason === 'receive_queue_overflow' ? reason : 'receive_blob_failed');", "degrade(socketId, 'receive_blob_failed');"]]],
  ["DG6 退化事件從不交付", [["        setTimeout(deliverDegraded, 0);\n", ""]]],
  ["DG7 漏發 ambiguity_overflow", [["        ambiguousSockets.forEach(function (id) { degrade(Number(id), 'ambiguity_overflow'); });\n", ""]]],
  ["DG8 漏發 reshape_locked", [["            degrade(meta.socketId, 'reshape_locked');\n", ""]]],
  ["DG9 交付後不重設排程（之後的退化事件不再交付）", [["        degradeScheduled = false;\n", ""]]],
  ["DG10 退化 ctx 不凍結", [["fn.call(entry.spec, Object.freeze({ socketId: d.socketId", "fn.call(entry.spec, ({ socketId: d.socketId"]]],
  ["R2-1a injectReceive 接受不污染守衛插件", [["                if ((grant.sendGuard || []).length) taint(grant.__id, grant);\n                pluginLog(grant.__id, 'injectReceive '", "                pluginLog(grant.__id, 'injectReceive '"]]],
  ["R2-1b respondLocally 接受不污染守衛插件", [["                if ((grant.sendGuard || []).length) taint(grant.__id, grant);   // 同 injectReceive", "                // 同 injectReceive"]]],
  ["R2-2a 守衛者的拒絕只以目前守衛者過濾（退出即失效）", [["return r.guardian || guard.ids.indexOf(r.id) !== -1;", "return guard.ids.indexOf(r.id) !== -1;"]]],
  ["R2-2b 拒絕紀錄不帶呼叫當時的守衛身分", [["{ id: grant.__id, guardian: guardian, invalid:", "{ id: grant.__id, guardian: false, invalid:"]]],
  ["R2-4a 守衛本地錯誤不保留號碼", [["{ response = guardErrorResponse(msgId); holdLocal(raw.wsId, msgId); }", "{ response = guardErrorResponse(msgId); }"]]],
  ["R2-4b 本地成功不保留號碼", [["            holdLocal(raw.wsId, env.msgId);\n", ""]]],
  ["R2-4c 配號不避開保留號碼", [["        localPending.forEach(function (n, k) { busy.add(Number(k.slice(k.lastIndexOf(':') + 1))); });\n", ""]]],
  ["R2-4d 交付後不釋放保留號碼", [["            releaseLocal(socketId, msgId);   // 已交付給遊戲", "            // 已交付給遊戲"]]],
  ["R2-5a 最後號碼不看進入順序（後結案者覆蓋）", [["if (order >= g.lastOrder) { g.last = msgId; g.lastOrder = order; }", "{ g.last = msgId; g.lastOrder = order; }"]]],
  ["R2-5b 順序在結案時才取（不是進入時）", [["            else if (mark) gameLast(raw.wsId, mark.msgId, mark.order);\n", "            else if (mark) gameLast(raw.wsId, mark.msgId, ++gameOrder);\n"]]],
  ["R2-6 合成觀察項不檢查佇列上限", [["        checkOverflow(info.id, info);\n        flushReceive(info.id, info);\n    }", "        flushReceive(info.id, info);\n    }"]], "naki-websocket.js"],
  ["R2-7 交付前不重查 OPEN（CLOSING 仍交付）", [["if (wsConnections.get(ws) !== info || ws.readyState !== OriginalWebSocket.OPEN) return drop('連線已關閉');", "if (wsConnections.get(ws) !== info) return drop('連線已關閉');"]], "naki-websocket.js"],
  ["R2-10a 非守衛者在守衛方法上也收提案", [["                else if (guard && !guardian) reason = 'not_guardian';\n", ""]]],
  ["R2-10b 非守衛者的提案在終判時也走 3b", [["return tx.local.guardian ? null : 'not_guardian';", "return null;"]]],
  ["R2-10c 非大廳連線也查守衛身分", [["guard = raw.lobbyChain ? guardFor(method) : null;", "guard = guardFor(method);"]]],
  ["R3-2 排空吃掉回呼內新觸發的退化（非批次快照）", [["        pendingDegraded.splice(0).forEach(function (d) {", "        for (var d0; (d0 = pendingDegraded.shift());) [d0].forEach(function (d) {"]]],
  ["R3-3a hook 取得在隔離之外（getter 拋錯中斷整批）", [["                try {\n                    var fn = entry.spec.onConnectionDegraded;", "                var fn = entry.spec.onConnectionDegraded;\n                try {"]]],
  ["R3-3b 退化 hook 失敗不記帳", [["                } catch (e) { noteFailure(entry, 'onConnectionDegraded', e); }", "                } catch (e) { }"]]],
  ["R3-4a respondLocally 不設待交付上限", [["                else if (localCount(raw.wsId) >= LOCAL_PENDING_LIMIT) reason = 'local_busy';\n", ""]]],
  ["R3-4b 上限差一（第 257 筆仍接受）", [["localCount(raw.wsId) >= LOCAL_PENDING_LIMIT", "localCount(raw.wsId) > LOCAL_PENDING_LIMIT"]]],
  ["R3-4c localDropped 不釋放", [["localDropped: function (socketId, msgId) { if (msgId != null) releaseLocal(socketId, msgId); },", "localDropped: function () {},"]]],
  ["R3-4d 排程失敗不通知插件層", [["        if (scheduled || !verdict.response) return;\n", "        return;\n"]], "naki-websocket.js"],
  ["R3-4e 連線關閉不清保留號碼", [["            Array.from(localPending.keys()).forEach(function (k) { if (k.indexOf(prefix) === 0) localPending.delete(k); });\n", ""]]],
  ["R3-5 丟棄合成通知不記 log", [["injectDropped: function (pluginId, why) { pluginLog(pluginId, 'injectReceive 未交付：' + why); },", "injectDropped: function () {},"]]],
];

const read = file => fs.readFileSync(path.join(jsDir, file), 'utf8');
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'guard-gaps-mutate-'));
const log = line => { console.log(line); if (logPath) fs.appendFileSync(logPath, line + '\n'); };

function run(code, file = 'naki-plugins.js') {
  const dir = path.join(work, 'tree');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(path.join(dir, 'scripts'), { recursive: true });
  fs.cpSync(jsDir, path.join(dir, 'command/Resources/JavaScript'), { recursive: true });
  for (const s of ['plugin-v2-b2-regression.cjs', 'plugin-v2-regression.cjs']) fs.copyFileSync(path.join(root, 'scripts', s), path.join(dir, 'scripts', s));
  fs.writeFileSync(path.join(dir, 'command/Resources/JavaScript', file), code);
  const env = { ...process.env, NAKI_PLUGINS_DIR: pluginsDir };
  const suites = [
    ['b2', path.join(dir, 'scripts/plugin-v2-b2-regression.cjs'), env],
    ['v2', path.join(dir, 'scripts/plugin-v2-regression.cjs'), env],
    // p4 從自己的 git 取 main 做差異比較，所以跑 repo 內的腳本、只把 JS 指向變異目錄
    ['p4', path.join(root, 'scripts/plugin-v2-p4-regression.cjs'), { ...env, NAKI_JS_DIR: path.join(dir, 'command/Resources/JavaScript') }],
  ];
  const fails = [];
  for (const [name, file, e] of suites) {
    const r = spawnSync(process.execPath, [file], { cwd: root, env: e, encoding: 'utf8', timeout: 300000 });
    const out = r.stdout || '';
    out.split('\n').filter(l => l.startsWith('not ok')).forEach(l => fails.push(name + ': ' + l));
    if (!/^# tests \d+/m.test(out)) fails.push(name + ': 沒有 TAP 摘要（崩潰或逾時）' + String(r.stderr || '').slice(-200));
  }
  return fails;
}

const base = run(read('naki-plugins.js'));
log('BASE（未變異）: ' + base.length + ' fail' + base.map(f => '\n   ' + f).join(''));
if (base.length) { log('基線不是 0 fail，停止'); process.exit(1); }
let killed = 0, survivors = [];
MUTANTS.forEach(([name, pairs, file = 'naki-plugins.js'], i) => {
  if (i < from || i >= to) return;
  let code = read(file);
  for (const [a, b] of pairs) {
    if (code.split(a).length !== 2) { log(`[${i}] ${name}: 替換字串不唯一或不存在，變異定義過期`); process.exitCode = 1; return; }
    code = code.replace(a, () => b);
  }
  const fails = run(code, file);
  if (fails.length) killed++; else survivors.push(name);
  log(`[${i}] ${name}: ${fails.length ? 'KILLED' : 'SURVIVED'} (${fails.length} fail)` + fails.slice(0, 4).map(f => '\n   ' + f).join(''));
});
const ran = MUTANTS.filter((_, i) => i >= from && i < to).length;
log(`TOTAL ${killed}/${ran} killed（${from}–${Math.min(to, MUTANTS.length)}，共 ${MUTANTS.length} 個定義）`);
const unexpected = survivors.filter(n => !EQUIVALENT.includes(n.split(' ')[0]));
if (unexpected.length) { log('非等價存活：' + unexpected.join('、')); process.exitCode = 1; }
fs.rmSync(work, { recursive: true, force: true });
