// Run: node scripts/plugin-v2-b2-regression.cjs
// 送出守衛 N1／N2 的 spike（docs/archive/plan/plugin-v2-b2.md §3–§4）。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const root = path.resolve(__dirname, '..');
const source = name => fs.readFileSync(path.join(root, 'command/Resources/JavaScript', name), 'utf8');

function page(wiring = source('naki-websocket.js'), { breakBase64 = false, encode = null, swiftFails = () => false, realCore = false, postFails = () => false } = {}) {
  const swift = [];
  class MessageEvent { constructor(type, init) { this.type = type; this.data = init.data; } }
  class Socket {
    constructor(url) { this.url = url; this.readyState = 1; this.listeners = []; this.closers = []; this.sent = []; this.committed = []; this.onmessage = null; }
    addEventListener(k, f) { if (k === 'message') this.listeners.push(f); if (k === 'close') this.closers.push(f); }
    close() { this.readyState = 3; this.closers.forEach(f => f({ code: 1000, reason: '' })); }
    // sent 留參照（物件同一性斷言用）；committed 在入口複製，是原生 send 提交當下的內容（送出快照斷言用）
    send(d) {
      this.sent.push(d);
      const b = d instanceof ArrayBuffer ? new Uint8Array(d) : ArrayBuffer.isView(d) ? new Uint8Array(d.buffer, d.byteOffset, d.byteLength) : null;
      this.committed.push(b ? Array.from(b) : d);
    }
    dispatchEvent(ev) { this.listeners.forEach(f => f(ev)); if (this.onmessage) this.onmessage(ev); return true; }
    receive(u8) { this.dispatchEvent(new MessageEvent('message', { data: u8.buffer.slice(0) })); }
  }
  Socket.OPEN = 1;
  const c = { console: { log() {}, error() {} }, Uint8Array, ArrayBuffer, DataView, Blob, MessageEvent, setTimeout,
    btoa: s => Buffer.from(s, 'binary').toString('base64'), atob: s => Buffer.from(s, 'base64').toString('binary'),
    document: { getElementById: () => null }, __nakiPluginGrants: {} };
  c.window = c; c.WebSocket = Socket; vm.createContext(c);
  // realCore：保留 naki-core 正式的 sendToSwift，只替換底層 postMessage
  c.webkit = { messageHandlers: { websocketBridge: { postMessage(m) { if (postFails(m)) throw new Error('postMessage failed'); swift.push({ type: m.type, data: m.data }); } } } };
  vm.runInContext(source('naki-core.js'), c);
  if (!realCore) c.__nakiCore.sendToSwift = (type, data) => { if (swiftFails(type, data)) throw new Error('bridge down'); swift.push({ type, data }); return true; };
  if (breakBase64) c.__nakiCore.arrayBufferToBase64 = () => { throw new Error('encode failed'); };
  if (encode) c.__nakiCore.arrayBufferToBase64 = encode;
  vm.runInContext(wiring, c);
  vm.runInContext(source('naki-plugins.js'), c);
  const lobby = new c.WebSocket('wss://route-4.maj-soul.com/gateway');
  const game = [];
  lobby.onmessage = ev => game.push(Array.from(new Uint8Array(ev.data)));
  // 本地交易是一則 send 訊息帶 localResponse：receive 方向把它算進來（Swift 端在同一則訊息裡處理這一對）
  const toSwift = dir => swift.filter(e => e.type === 'websocket_message' && (e.data.direction === dir || (dir === 'receive' && e.data.localResponse)))
    .map(e => Array.from(Buffer.from(dir === 'receive' && e.data.localResponse ? e.data.localResponse : e.data.data, 'base64')));
  const events = kind => swift.filter(e => e.type === 'plugin_event' && e.data.kind === kind);
  return { c, lobby, game, toSwift, events, swift };
}
const tick = () => new Promise(r => setTimeout(r, 0));
const sentIds = t => t.lobby.sent.map(d => { const b = new Uint8Array(d.buffer ? d.buffer : d); return b[1] | (b[2] << 8); });
const plain = x => JSON.parse(JSON.stringify(x));   // vm realm 的陣列與物件，deepEqual 前轉成本 realm
function request(msgId, method, payload = []) {
  const m = Buffer.from(method);
  return new Uint8Array([2, msgId & 0xff, msgId >> 8, 10, m.length, ...m, 18, payload.length, ...payload]);
}
const response = (msgId, payload) => new Uint8Array([3, msgId & 0xff, msgId >> 8, 10, 0, 18, payload.length, ...payload]);
const errorResponse = (msgId, code = 6) => Array.from(response(msgId, [10, 2, 8, code]));
const SKIN = '.lq.Lobby.changeCharacterSkin', INFO = '.lq.Lobby.fetchCharacterInfo', BEAT = '.lq.Lobby.loginBeat';
const ID = 'unlock';

// 一個守衛插件：改大廳 fetchCharacterInfo 回應（等長，足以觸發污染），onSend 依 behave 放行或拋錯
function guardPlugin(c, { behave = () => {}, grant = {} } = {}) {
  c.__nakiPlugins.setGrant(ID, { capabilities: ['observe', 'rewriteReceive'], methods: [SKIN, INFO], sendGuard: [SKIN], ...grant });
  return c.__nakiPlugins.register({ id: ID,
    onReceive(ctx) { if (ctx.method === INFO) { const b = ctx.bytes.slice(); b[b.length - 1] ^= 1; ctx.replace(b); } },
    onSend(ctx) { return behave(ctx); } });
}
// 遊戲送 fetchCharacterInfo、收到回應 ⇒ 守衛插件改了它 ⇒ 已污染
function pollute(t) {
  t.lobby.send(request(10, INFO));
  t.lobby.receive(response(10, [8, 1]));
}

test('untainted guard plugin that returns normally lets the guarded request go out as the original object', () => {
  const t = page();
  guardPlugin(t.c);
  const req = request(20, SKIN, [8, 1]);
  t.lobby.send(req);
  assert.equal(t.lobby.sent[0], req);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => [e.msgId, e.outcome]), [[20, 'sent']]);
});

test('N2: guard hook throws ⇒ nothing goes out; Swift sees the REQUEST, then a synthetic error RESPONSE once; the game gets it after send returns', async () => {
  const t = page();
  guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
  const req = request(21, SKIN, [8, 1]);
  t.lobby.send(req);
  assert.deepEqual(t.lobby.sent, []);
  assert.deepEqual(t.game, [], 'local response must not be delivered synchronously inside ws.send');
  await tick();
  assert.deepEqual(t.lobby.sent, []);
  assert.deepEqual(t.toSwift('send'), [Array.from(req)]);
  assert.deepEqual(t.toSwift('receive'), [errorResponse(21)]);
  assert.deepEqual(t.game, [errorResponse(21)]);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => [e.msgId, e.outcome, e.reason]), [[21, 'local_error', 'hook_threw']]);
});

test('N1: after pollution, disabling the plugin keeps the guard — guarded request is not sent and the game gets the error', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  assert.equal(t.events('tainted').length, 1);
  t.c.__nakiPlugins.disable(ID);
  t.lobby.send(request(22, SKIN, [8, 1]));
  t.lobby.send(request(23, BEAT));
  await tick();
  assert.deepEqual(sentIds(t), [10, 23], 'only the unguarded loginBeat goes out after pollution');
  assert.deepEqual(t.game.slice(-1), [errorResponse(22)]);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).tainted, { [ID]: [SKIN] });
});

test('N1: auto-disable after repeated failures, failed hot reload, and L3 off all keep the guard', async () => {
  const t = page();
  guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
  pollute(t);
  for (let i = 0; i < 10; i++) t.lobby.send(request(30 + i, SKIN));
  assert.deepEqual(plain(t.c.__nakiPlugins.list()), [], 'auto-disabled');
  // 熱重載：disable → setGrant → 源碼拋錯（PluginRegistry.enableScript 的順序），插件停在停用
  t.c.__nakiPlugins.disable(ID);
  t.c.__nakiPlugins.setGrant(ID, { capabilities: ['observe'], methods: [SKIN] });
  t.c.__nakiPluginsMayModifyOutbound = false;
  t.lobby.send(request(50, SKIN));
  await tick();
  assert.deepEqual(sentIds(t), [10]);
  assert.equal(t.game.filter(b => JSON.stringify(b.slice(3)) === JSON.stringify(errorResponse(0).slice(3))).length, 11, 'eleven synthetic error responses reached the game');
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.slice(-1).map(e => e.reason), ['not_on_chain']);
  assert.equal(t.swift.filter(e => e.data.localResponse).pop().data.reason, 'not_on_chain', 'Swift gets the block reason for its log');
});

test('N1: a re-registered tainted plugin that still guards the method must approve again', () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  t.c.__nakiPluginsMayModifyOutbound = true;
  t.c.__nakiPlugins.disable(ID);
  guardPlugin(t.c);
  t.lobby.send(request(60, SKIN));
  assert.deepEqual(sentIds(t), [10, 60]);
  t.c.__nakiPlugins.disable(ID);
  guardPlugin(t.c, { grant: { methods: [INFO], sendGuard: undefined } });
  t.lobby.send(request(61, SKIN));
  assert.deepEqual(sentIds(t), [10, 60]);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => e.outcome), ['sent', 'local_error']);
});

test('without pollution, disabling a guard plugin releases its guard', () => {
  const t = page();
  guardPlugin(t.c);
  t.c.__nakiPlugins.disable(ID);
  const req = request(70, SKIN);
  t.lobby.send(req);
  assert.equal(t.lobby.sent[0], req);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()), { tainted: {}, log: [], roles: { [t.c.__nakiWebSocket.getMajsoulConnections()[0].id]: 'lobby' } });
});

test('game-gateway rewrites do not pollute; non-guard plugins never pollute', () => {
  const t = page();
  guardPlugin(t.c);
  const g = new t.c.WebSocket('wss://route-4.maj-soul.com/game-gateway');
  g.send(request(79, '.lq.FastTest.authGame'));
  g.send(request(80, INFO));
  g.receive(response(80, [8, 1]));
  assert.equal(t.events('tainted').length, 0);
  t.c.__nakiPlugins.disable(ID);
  t.c.__nakiPlugins.setGrant('other', { capabilities: ['observe', 'rewriteReceive'], methods: [INFO] });
  t.c.__nakiPlugins.register({ id: 'other', onReceive(ctx) { const b = ctx.bytes.slice(); b[b.length - 1] ^= 1; ctx.replace(b); } });
  pollute(t);
  assert.equal(t.events('tainted').length, 0);
});

test('guarded request rewritten by another plugin is blocked, not sent in either form', async () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  guardPlugin(t.c);
  t.c.__nakiPlugins.setGrant('rw', { capabilities: ['observe', 'rewriteSend'], methods: [SKIN], priority: 200 });
  t.c.__nakiPlugins.register({ id: 'rw', onSend(ctx) { ctx.replace(request(ctx.msgId, SKIN, [8, 9])); } });
  t.lobby.send(request(90, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(t.lobby.sent, []);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => e.reason), ['rewritten']);
});

test('after pollution, Naki-sent (sendRaw) guarded requests are blocked too', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  const r = t.c.__nakiWebSocket.sendRaw(Buffer.from(request(60001, SKIN)).toString('base64'));
  assert.equal(r.success, true);
  await tick();
  assert.deepEqual(sentIds(t), [10]);
  assert.deepEqual(t.game.slice(-1), [errorResponse(60001)]);
});

test('register rejects sendGuard methods outside the confirmed-response allowlist (send-forbidden, cancel, FastTest, fetchServerTime) or missing from methods', () => {
  for (const m of ['.lq.Lobby.oauth2Login', '.lq.Lobby.cancelUnifiedMatch', '.lq.FastTest.inputOperation', '.lq.Lobby.fetchServerTime', BEAT]) {
    const t = page();
    t.c.__nakiPlugins.setGrant(ID, { capabilities: ['observe'], methods: m === BEAT ? [SKIN] : [m], sendGuard: [m] });
    assert.equal(t.c.__nakiPlugins.register({ id: ID, onSend() {} }), false, m);
  }
});

test('zero plugins and no taint: the original object goes out and Swift gets it once (wiring is inert)', () => {
  const t = page();
  const req = request(100, SKIN);
  t.lobby.send(req);
  assert.equal(t.lobby.sent[0], req);
  assert.equal(t.toSwift('send').length, 1);
  t.lobby.receive(response(100, [8, 1]));
  assert.equal(t.toSwift('receive').length, 1);
  assert.equal(t.game.length, 1);
});

test('N2: an internal dispatch error on a guarded request blocks it instead of falling back to sending', async () => {
  const t = page();
  guardPlugin(t.c);
  t.c.__nakiPlugins.setGrant('broken', { capabilities: ['observe'], methods: { indexOf() { throw new Error('bad grant'); } } });
  t.c.__nakiPlugins.register({ id: 'broken', onSend() {} });
  t.lobby.send(request(120, SKIN));
  await tick();
  assert.deepEqual(sentIds(t), []);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => e.reason), ['dispatch_error']);
});


// ---- 審查第二輪（Astra 1–8、9、14）：反例 ----

test('R1a (Astra 1): tainted plugin still on the chain with L3 off cannot approve a guarded request', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  t.c.__nakiPluginsMayModifyOutbound = false;
  t.lobby.send(request(130, SKIN));
  await tick();
  assert.deepEqual(sentIds(t), [10]);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => e.reason), ['outbound_disabled']);
});

test('R1b (Astra 1): re-registered without sendGuard, an ordinary hook cannot approve a historically guarded method', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  t.c.__nakiPluginsMayModifyOutbound = true;
  t.c.__nakiPlugins.disable(ID);
  guardPlugin(t.c, { grant: { sendGuard: undefined } });
  t.lobby.send(request(131, SKIN));
  await tick();
  assert.deepEqual(sentIds(t), [10]);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => e.reason), ['guard_revoked']);
});

test('R2 (Astra 2): a guard hook returning a Promise or thenable never approves, and a rejection is handled', async () => {
  for (const ret of [() => Promise.reject(new Error('async boom')), () => ({ then() {} })]) {
    const t = page();
    guardPlugin(t.c, { behave: ret });
    t.lobby.send(request(140, SKIN));
    await tick(); await tick();
    assert.deepEqual(sentIds(t), []);
    assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => e.reason), ['async_hook']);
    assert.deepEqual(t.game, [errorResponse(140)]);
  }
});

test('R3 (Astra 3): once blocked, an encoding failure on the way to Swift cannot turn it back into a send', async () => {
  const t = page(source('naki-websocket.js'), { breakBase64: true });
  guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
  t.lobby.send(request(150, SKIN));
  await tick();
  assert.deepEqual(sentIds(t), []);
  assert.deepEqual(t.game, [errorResponse(150)], 'the game still gets the local error');
});

test('R4 (Astra 4): while any plugin is tainted, a Blob send is refused synchronously', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  t.lobby.send(new t.c.Blob([request(160, SKIN)]));
  assert.deepEqual(sentIds(t), [10]);
  await tick();
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => e.outcome), ['refused_opaque']);
});

test('R4b: with no guard plugin, Blob sends still go out (no behavior change for normal pages)', () => {
  const t = page();
  t.c.__nakiPlugins.setGrant('obs', { capabilities: ['observe'], methods: [BEAT] });
  t.c.__nakiPlugins.register({ id: 'obs', onSend() {} });
  const blob = new t.c.Blob([request(161, BEAT)]);
  t.lobby.send(blob);
  assert.equal(t.lobby.sent[0], blob);
});

test('R4c: a registered but untainted guard plugin also refuses Blob sends', () => {
  const t = page();
  guardPlugin(t.c);
  t.lobby.send(request(161, BEAT));
  t.lobby.send(new t.c.Blob([request(162, SKIN)]));
  assert.deepEqual(sentIds(t), [161]);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => e.outcome), ['refused_opaque']);
});

test('R5 (Astra 5): rewriting a non-guarded request into a guarded method never sends the guarded method', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  t.c.__nakiPlugins.disable(ID);
  t.c.__nakiPluginsMayModifyOutbound = true;
  t.c.__nakiPlugins.setGrant('rw', { capabilities: ['observe', 'rewriteSend'], methods: [BEAT] });
  const results = [];
  t.c.__nakiPlugins.register({ id: 'rw', onSend(ctx) { results.push(ctx.replace(request(ctx.msgId, SKIN, [8, 9]))); } });
  const req = request(170, BEAT);
  t.lobby.send(req);
  await tick();
  assert.deepEqual(results, [false], 'refused at replace time (round-3 policy, see R4d)');
  assert.deepEqual(sentIds(t), [10, 170]);
  assert.equal(t.lobby.sent[1], req, 'the unguarded original goes out unchanged');
});

test('R6 (Astra 6): a guard plugin with observeNakiTraffic cannot approve Naki-sent guarded requests', async () => {
  const t = page();
  guardPlugin(t.c, { grant: { observeNakiTraffic: true } });
  pollute(t);
  t.c.__nakiPluginsMayModifyOutbound = true;
  t.c.__nakiWebSocket.sendRaw(Buffer.from(request(60002, SKIN)).toString('base64'));
  await tick();
  assert.deepEqual(sentIds(t), [10]);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => e.reason), ['naki_traffic']);
});

test('R7 (Astra 7): a hook that changes msgId in place is blocked, and Swift gets the untouched original REQUEST', async () => {
  const t = page();
  guardPlugin(t.c, { behave: ctx => { ctx.bytes[1] = 222; } });
  const req = request(206, SKIN, [8, 1]);
  const original = Array.from(req);
  t.lobby.send(req);
  await tick();
  assert.deepEqual(sentIds(t), []);
  assert.deepEqual(t.toSwift('send'), [original]);
  assert.deepEqual(t.toSwift('receive'), [errorResponse(206)]);
  assert.deepEqual(Array.from(req), original, "the game's own buffer is restored");
});

test('R8 (Astra 8): a blocked plugin sendRequest gets its local error through onInjectResponse and is cleared', async () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  const got = [];
  t.c.__nakiPlugins.setGrant(ID, { capabilities: ['observe', 'rewriteReceive', 'injectSend'], methods: [SKIN, INFO], sendGuard: [SKIN] });
  let inject;
  t.c.__nakiPlugins.register({ id: ID,
    onReceive(ctx) { if (ctx.method === INFO) { const b = ctx.bytes.slice(); b[b.length - 1] ^= 1; ctx.replace(b); inject = ctx.sendRequest; } },
    onSend() {},
    onInjectResponse(ctx) { got.push({ msgId: ctx.inResponseTo, local: ctx.local, bytes: Array.from(ctx.bytes) }); } });
  pollute(t);
  const r = inject(SKIN, new t.c.Uint8Array([8, 1]));
  assert.equal(r.ok, true);
  await tick();
  assert.deepEqual(sentIds(t), [10]);
  assert.deepEqual(plain(got), [{ msgId: r.msgId, local: true, bytes: errorResponse(r.msgId) }]);
  t.lobby.receive(new Uint8Array(errorResponse(r.msgId)));
  assert.equal(got.length, 1, 'the msgId is no longer routed after local closure');
});

test('R9 (Astra 9): Swift gets the blocked REQUEST and its local RESPONSE back to back, before any later send', async () => {
  const t = page();
  guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
  const other = new t.c.WebSocket('wss://route-5.maj-soul.com/gateway');
  t.lobby.send(request(206, SKIN));
  other.send(request(206, BEAT));
  await tick();
  const order = t.swift.filter(e => e.type === 'websocket_message').map(e => [e.data.direction, !!e.data.localResponse]);
  assert.deepEqual(order, [['send', true], ['send', false]], 'the blocked pair travels as one message, before the later send');
});

test('R14 (Astra 14): a non-guard observer that throws does not veto a request every guard approved', () => {
  const t = page();
  guardPlugin(t.c);
  t.c.__nakiPlugins.setGrant('obs', { capabilities: ['observe'], methods: [SKIN] });
  t.c.__nakiPlugins.register({ id: 'obs', onSend() { throw new Error('observer bug'); } });
  const req = request(180, SKIN);
  t.lobby.send(req);
  assert.equal(t.lobby.sent[0], req);
});

test('R3b (Astra 3): an error inside the bridge before dispatch still blocks a guarded request', async () => {
  const t = page();
  guardPlugin(t.c);
  t.c.__nakiHideNames.observe = () => { throw new Error('observer broke'); };
  t.lobby.send(request(190, SKIN));
  t.lobby.send(request(191, BEAT));
  await tick();
  assert.deepEqual(sentIds(t), [191], 'unguarded requests keep the old fail-open path');
  assert.deepEqual(t.game, [errorResponse(190)]);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => e.reason), ['bridge_error']);
});


// ---- 審查第三輪（Astra 第二輪新發現 1–6）：反例 ----
const TITLE = '.lq.Lobby.useTitle', HEAT = '.lq.Lobby.heatbeat';
// 註冊時讀一次 sendGuard 正常，之後每次讀都拋錯：模擬守衛辨識（guardFor）本身出錯
function brokenGuard(c) {
  let reads = 0;
  c.__nakiPlugins.setGrant('broken', { capabilities: ['observe'], methods: [SKIN],
    get sendGuard() { if (reads++ < 1) return [SKIN]; throw new Error('lookup broke'); } });
  assert.equal(c.__nakiPlugins.register({ id: 'broken', onSend() {} }), true);
}

test('R301 (Astra2 1): tainted page, guard lookup throws ⇒ REQUEST 301 is not sent', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  brokenGuard(t.c);
  t.lobby.send(request(301, SKIN));
  await tick();
  assert.deepEqual(sentIds(t), [10]);
});

test('R302 (Astra2 1): untainted guard, bridge error before dispatch and guard lookup throws ⇒ REQUEST 302 is not sent', async () => {
  const t = page();
  brokenGuard(t.c);
  t.c.__nakiHideNames.observe = () => { throw new Error('observer broke'); };
  t.lobby.send(request(302, SKIN));
  await tick();
  assert.deepEqual(sentIds(t), []);
});

test('R3c (Astra2 3): if the local REQUEST cannot reach Swift, its RESPONSE is not sent to Swift either', async () => {
  const t = page(source('naki-websocket.js'), { swiftFails: (type, d) => type === 'websocket_message' && d.direction === 'send' });
  guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
  t.lobby.send(request(310, SKIN));
  await tick();
  assert.deepEqual(sentIds(t), []);
  assert.deepEqual(t.toSwift('receive'), [], 'no half transaction in Swift');
  assert.deepEqual(t.game, [errorResponse(310)], 'the game still gets its local error');
});

test('R4d (Astra2 4): rewriteSend into a guarded method is refused at replace time; the original goes out unchanged', () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  guardPlugin(t.c);
  const FST = '.lq.Lobby.fetchServerTime';
  const results = [];
  t.c.__nakiPlugins.setGrant('rw', { capabilities: ['observe', 'rewriteSend'], methods: [FST] });
  t.c.__nakiPlugins.register({ id: 'rw', onSend(ctx) { results.push(ctx.replace(request(ctx.msgId, SKIN, [8, 9]))); } });
  const req = request(320, FST);
  t.lobby.send(req);
  assert.deepEqual(results, [false]);
  assert.equal(t.lobby.sent[0], req);
});

test('R5b (Astra2 5): local closure keeps the original method and its own snapshot even if the game mutates the delivered buffer', async () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  const got = [];
  let inject;
  t.c.__nakiPlugins.setGrant(ID, { capabilities: ['observe', 'injectSend'], methods: [SKIN, INFO], sendGuard: [SKIN] });
  t.c.__nakiPlugins.register({ id: ID, onSend(ctx) { if (ctx.method === INFO) inject = ctx.sendRequest; },
    onInjectResponse(ctx) { got.push({ msgId: ctx.inResponseTo, method: ctx.method, local: ctx.local }); } });
  t.lobby.send(request(12, INFO));
  t.lobby.onmessage = ev => { new Uint8Array(ev.data)[1] ^= 0xff; };   // 遊戲改動交付給它的 buffer
  const r = inject(SKIN, new t.c.Uint8Array([8, 1]));
  await tick();
  assert.deepEqual(plain(got), [{ msgId: r.msgId, method: SKIN, local: true }]);
  t.lobby.onmessage = null;
  t.lobby.receive(new Uint8Array(errorResponse(r.msgId)));
  assert.equal(got.length, 1, 'the registration was cleared by the closure msgId, not by game-mutated bytes');
});

test('R6b (Astra2 6): ten consecutive async rejections auto-disable the guard plugin', async () => {
  const t = page();
  guardPlugin(t.c, { behave: () => Promise.reject(new Error('async boom')) });
  for (let i = 0; i < 12; i++) { t.lobby.send(request(330 + i, SKIN)); await tick(); await tick(); }
  assert.deepEqual(plain(t.c.__nakiPlugins.list()), []);
  assert.deepEqual(sentIds(t), [340, 341], 'ten blocked; once the untainted plugin is auto-disabled its guard is released');
});


// ---- 審查第四輪（Astra 第三輪新發現 1–3、5）：反例 ----
const OP = '.lq.FastTest.inputOperation', CPG = '.lq.FastTest.inputChiPengGang';
const gameSocket = c => new c.WebSocket('wss://route-4.maj-soul.com/game-gateway');
const sentOn = ws => ws.sent.map(d => { const b = new Uint8Array(d.buffer ? d.buffer : d); return b[1] | (b[2] << 8); });

test('R4-1a (Astra3 1): guard lookup throwing never blocks game-gateway inputOperation / inputChiPengGang', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  brokenGuard(t.c);
  const g = gameSocket(t.c);
  g.send(request(400, OP));
  g.send(request(401, CPG));
  await tick();
  assert.deepEqual(sentOn(g), [400, 401]);
});

test('R4-1b (Astra3 1): guard lookup throwing never blocks a Naki-sent inputOperation', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  brokenGuard(t.c);
  const g = gameSocket(t.c);
  const r = t.c.__nakiWebSocket.sendRaw(Buffer.from(request(60400, OP)).toString('base64'));
  assert.equal(r.success, true);
  await tick();
  assert.deepEqual(sentOn(g), [60400]);
});

test('R4-1c (Astra3 1): with a healthy guard, a Blob on a connection locked as game still goes out', () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  const g = gameSocket(t.c);
  g.send(request(401, '.lq.FastTest.authGame'));
  const blob = new t.c.Blob([request(402, OP)]);
  g.send(blob);
  assert.equal(g.sent[1], blob);
});

test('R4-1d (Astra3 1, D13 rewrite): on the lobby, a known non-guard method hit by an internal error is restored and sent', async () => {
  const t = page();
  guardPlugin(t.c);
  t.c.__nakiPlugins.setGrant('broken', { capabilities: ['observe'], methods: { indexOf() { throw new Error('bad grant'); } } });
  t.c.__nakiPlugins.register({ id: 'broken', onSend() {} });
  const req = request(403, BEAT);
  const original = Array.from(req);
  t.lobby.send(req);
  await tick();
  assert.deepEqual(sentIds(t), [403]);
  assert.deepEqual(Array.from(new Uint8Array(t.lobby.sent[0])), original);
});

test('R4-2 (Astra3 2): a local closure on socket A does not eat socket B\'s pending loginBeat(303)', async () => {
  const t = page();
  guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
  const seen = [];
  t.c.__nakiPlugins.setGrant('obs', { capabilities: ['observe'], methods: [BEAT] });
  t.c.__nakiPlugins.register({ id: 'obs', onReceive(ctx) { seen.push([ctx.socketId, ctx.msgId, ctx.method]); } });
  const b = new t.c.WebSocket('wss://route-5.maj-soul.com/gateway');
  b.send(request(303, BEAT));
  t.lobby.send(request(303, SKIN));
  await tick();
  b.receive(response(303, []));
  assert.equal(seen.length, 1);
  assert.equal(seen[0][2], BEAT);
});

test('R4-3 (Astra3 3): with the real core sendToSwift, a failed postMessage leaves Swift with nothing, never half a pair', async () => {
  for (const failDir of ['send', 'receive']) {
    const t = page(source('naki-websocket.js'), { realCore: true, postFails: m => m.type === 'websocket_message' && m.data.direction === failDir });
    guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
    t.lobby.send(request(410, SKIN));
    await tick();
    const msgs = t.swift.filter(e => e.type === 'websocket_message');
    const reqs = msgs.filter(e => e.data.direction === 'send').length;
    const ress = msgs.filter(e => e.data.direction === 'receive').length + msgs.filter(e => e.data.localResponse).length;
    assert.ok((reqs === 0 && ress === 0) || (reqs === 1 && ress === 1), failDir + ': ' + reqs + ' REQUEST / ' + ress + ' RESPONSE');
    assert.deepEqual(t.game, [errorResponse(410)]);
  }
});

test('R4-5 (Astra3 5): an in-place rewrite into a guarded method is undone, counted as a plugin failure, and the original goes out', async () => {
  const t = page();
  t.c.__nakiPlugins.setGrant('g', { capabilities: ['observe'], methods: [TITLE], sendGuard: [TITLE] });
  t.c.__nakiPlugins.register({ id: 'g', onSend() {} });
  t.c.__nakiPlugins.setGrant('obs', { capabilities: ['observe'], methods: [HEAT] });
  t.c.__nakiPlugins.register({ id: 'obs', onSend(ctx) { Buffer.from(TITLE).forEach((x, i) => { ctx.bytes[5 + i] = x; }); } });
  const req = request(420, HEAT);
  const original = Array.from(req);
  t.lobby.send(req);
  await tick();
  assert.deepEqual(sentIds(t), [420]);
  assert.deepEqual(Array.from(new Uint8Array(t.lobby.sent[0])), original);
  assert.equal(t.events('log').filter(e => e.data.id === 'obs' && / 拋錯/.test(e.data.msg)).length, 1);
});

test('R4-1e (Astra3 1): a .lq.FastTest.* request on the lobby connection bypasses the guard even when lookup throws', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  brokenGuard(t.c);
  t.lobby.send(request(404, OP));
  await tick();
  assert.deepEqual(sentIds(t), [10, 404]);
});

test('R4-1f (Astra3 1): a bridge error on the game connection falls back to sending, whatever the guard state', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  brokenGuard(t.c);
  t.c.__nakiHideNames.observe = () => { throw new Error('observer broke'); };
  const g = gameSocket(t.c);
  g.send(request(405, OP));
  await tick();
  assert.deepEqual(sentOn(g), [405]);
});

test('R4-1g (Astra3 1): non-FastTest traffic on the game connection (.lq.Route.heartbeat) bypasses the guard even when lookup throws', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  brokenGuard(t.c);
  const g = gameSocket(t.c);
  g.send(request(406, '.lq.Route.heartbeat'));
  await tick();
  assert.deepEqual(sentOn(g), [406]);
});


// ---- 審查第五輪（Astra 第四輪 1–3）：角色由協定握手鎖定，不看 URL ----
const ROUTE = '.lq.Route.requestConnection', HB = '.lq.Route.heartbeat', AUTH = '.lq.FastTest.authGame', PREP = '.lq.Lobby.prepareLogin';
const roleOf = (t, ws) => (plain(t.c.__nakiPlugins.guardState()).roles || {})[t.c.__nakiWebSocket.getMajsoulConnections().find(c => c.ws === ws).id];

test('R5-1a (Astra4 1): a game connection whose URL contains /gateway elsewhere is locked as game by authGame and never guarded', async () => {
  for (const url of ['wss://route-4.maj-soul.com/game-gateway?next=/gateway', 'wss://gateway.maj-soul.com/game-gateway']) {
    const t = page();
    guardPlugin(t.c);
    pollute(t);
    brokenGuard(t.c);
    const g = new t.c.WebSocket(url);
    g.send(request(500, ROUTE));
    g.send(request(501, AUTH));
    g.send(request(502, HB));
    await tick();
    assert.deepEqual(sentOn(g), [500, 501, 502], url);
    assert.equal(roleOf(t, g), 'game', url);
  }
});

test('R5-1b (Astra4 1): with a healthy guard, a Blob on a game connection with /gateway in its URL still goes out', () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  const g = new t.c.WebSocket('wss://gateway.maj-soul.com/game-gateway');
  g.send(request(510, ROUTE));
  g.send(request(511, AUTH));
  const blob = new t.c.Blob([request(512, HB)]);
  g.send(blob);
  assert.equal(g.sent[2], blob);
});

test('R5-1c (Astra4 1): a backup lobby that only sends prepareLogin is locked as lobby whatever its URL, and guarded', async () => {
  for (const url of ['wss://route-4.majsoul.com/Gateway', 'wss://route-4.majsoul.com/%67ateway', 'wss://route-4.maj-soul.com/gateway']) {
    const t = page();
    guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
    const b = new t.c.WebSocket(url);
    b.send(request(520, ROUTE));
    b.send(request(521, PREP));
    b.send(request(522, HB));
    b.send(request(523, SKIN));
    await tick();
    assert.deepEqual(sentOn(b), [520, 521, 522], url);
    assert.equal(roleOf(t, b), 'lobby', url);
  }
});

test('R5-1d: the first .lq.Lobby.* request locks lobby before the guard decision on that same request', async () => {
  const t = page();
  guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
  const u = new t.c.WebSocket('wss://route-4.majsoul.com/ws');
  u.send(request(530, ROUTE));
  assert.equal(roleOf(t, u), undefined, '.lq.Route.* does not lock');
  u.send(request(531, SKIN));
  await tick();
  assert.deepEqual(sentOn(u), [530]);
  assert.equal(roleOf(t, u), 'lobby');
});

test('R5-1e: a locked role never changes — FastTest on a lobby stays lobby, Lobby on a game stays game', () => {
  const t = page();
  guardPlugin(t.c);
  t.lobby.send(request(540, BEAT));
  t.lobby.send(request(541, OP));
  assert.equal(roleOf(t, t.lobby), 'lobby');
  const g = gameSocket(t.c);
  g.send(request(542, AUTH));
  g.send(request(543, BEAT));
  assert.equal(roleOf(t, g), 'game');
});

test('R5-1f: an unparsable send on a connection whose role is still unknown goes out (fail-open); on a lobby it is refused', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  const u = new t.c.WebSocket('wss://route-5.maj-soul.com/gateway');
  u.send(request(550, ROUTE));
  const junk = new Uint8Array([9, 9, 9]);
  u.send(junk);
  assert.equal(u.sent[1], junk);
  t.lobby.send(new Uint8Array([9, 9, 9]));
  await tick();
  assert.deepEqual(sentIds(t), [10]);
});

test('R5-1g: closing a connection clears its role', () => {
  const t = page();
  t.c.__nakiPlugins.setGrant('obs', { capabilities: ['observe'], methods: [BEAT] });
  t.c.__nakiPlugins.register({ id: 'obs', onSend() {} });
  t.lobby.send(request(560, BEAT));
  const id = t.c.__nakiWebSocket.getMajsoulConnections().find(c => c.ws === t.lobby).id;
  assert.equal(plain(t.c.__nakiPlugins.guardState()).roles[id], 'lobby');
  t.lobby.close();
  assert.equal(plain(t.c.__nakiPlugins.guardState()).roles[id], undefined);
});

test('R5-1h: roles are locked even with zero plugins, so a guard enabled later already knows the lobby', async () => {
  const t = page();
  t.lobby.send(request(570, ROUTE));
  t.lobby.send(request(571, BEAT));
  guardPlugin(t.c);
  t.lobby.send(new t.c.Blob([request(572, SKIN)]));
  assert.deepEqual(sentIds(t), [570, 571]);
});

test('R5-2a (Astra4 2): a FastTest request on the lobby whose chain throws goes out, with no guard verdict', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  t.c.__nakiPlugins.setGrant('broken', { capabilities: ['observe'], methods: { indexOf() { throw new Error('bad grant'); } } });
  t.c.__nakiPlugins.register({ id: 'broken', onSend() {} });
  t.lobby.send(request(580, OP));
  await tick();
  assert.deepEqual(sentIds(t), [10, 580]);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log, []);
});

test('R5-2b (Astra4 2): FastTest traffic never reads sendGuard, even when an observer rewrites its method in place', () => {
  for (const onLobby of [true, false]) {
    const t = page();
    let reads = 0;
    t.c.__nakiPlugins.setGrant('g', { capabilities: ['observe'], methods: [SKIN], get sendGuard() { reads++; return [SKIN]; } });
    assert.equal(t.c.__nakiPlugins.register({ id: 'g', onSend() {} }), true);
    t.c.__nakiPlugins.setGrant('obs', { capabilities: ['observe'], methods: [OP] });
    t.c.__nakiPlugins.register({ id: 'obs', onSend(ctx) { ctx.bytes[5 + OP.length - 1] ^= 1; } });
    const ws = onLobby ? t.lobby : gameSocket(t.c);
    ws.send(request(590, onLobby ? BEAT : AUTH));
    const before = reads;
    ws.send(request(591, OP));
    assert.equal(reads, before, onLobby ? 'lobby' : 'game');
    assert.equal(ws.sent.length, 2);
  }
});

test('R5-3 (Astra4 3): when guard lookup keeps throwing on the lobby, only guardable and unparsable requests are refused', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  t.c.__nakiPluginGrants[ID].sendGuard.indexOf = () => { throw new Error('lookup broke'); };
  const FAI = '.lq.Lobby.fetchAccountInfo', SUM = '.lq.Lobby.startUnifiedMatch';
  [[600, HB], [601, BEAT], [602, FAI], [603, SUM], [604, SKIN], [605, TITLE]].forEach(([id, m]) => t.lobby.send(request(id, m)));
  t.lobby.send(new Uint8Array([9, 9, 9]));
  await tick();
  assert.deepEqual(sentIds(t), [10, 600, 601, 602, 603]);
  assert.deepEqual(t.game.slice(-2), [errorResponse(604), errorResponse(605)]);
});

test('R5-3b (Astra4 3): the same narrowing holds on the bridge-error path', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  t.c.__nakiPluginGrants[ID].sendGuard.indexOf = () => { throw new Error('lookup broke'); };
  t.c.__nakiHideNames.observe = () => { throw new Error('observer broke'); };
  t.lobby.send(request(610, BEAT));
  t.lobby.send(request(611, SKIN));
  await tick();
  assert.deepEqual(sentIds(t), [10, 610]);
  assert.deepEqual(t.game.slice(-1), [errorResponse(611)]);
});


// ---- 審查第五輪（Astra 第五輪 1–6）：保證範圍的殘餘反例與獨立變異的鎖 ----
const settle = async (until, n = 20) => { for (let i = 0; i < n && !until(); i++) await tick(); };

// guard-gaps：第五輪三條殘餘（D28–D30）改為修掉，原本鎖現行行為的 R6-1～R6-3 改鎖修後行為
function injector(t, { methods = [OP], got = [] } = {}) {
  let inject;
  t.c.__nakiPlugins.setGrant('inj', { capabilities: ['observe', 'injectSend'], methods });
  t.c.__nakiPlugins.register({ id: 'inj', onSend(ctx) { inject = ctx.sendRequest; },
    onInjectResponse(ctx) { got.push({ msgId: ctx.inResponseTo, local: ctx.local, bytes: Array.from(ctx.bytes) }); } });
  return () => inject;
}
function fallbackPage({ taint = true } = {}) {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  guardPlugin(t.c);
  if (taint) { pollute(t); t.c.__nakiPlugins.disable(ID); }
  const got = [];
  const inject = injector(t, { got });
  const g = gameSocket(t.c);
  g.send(request(700, AUTH));
  g.send(request(701, OP));
  t.lobby.close();
  return { t, g, got, inject: (m, p = [8, 1]) => inject()(m, new t.c.Uint8Array(p)) };
}

test('R6-1 (Astra5 1, guard-gaps a): with no open lobby, a coexisting sendRequest of a guarded method that falls back to the game connection is blocked as tainted_fallback', async () => {
  const { t, g, got, inject } = fallbackPage();
  const r = inject(SKIN);
  assert.equal(r.ok, true, 'same outcome as on the lobby: accepted, then a local error');
  await tick();
  assert.deepEqual(sentOn(g), [700, 701]);
  assert.deepEqual(guardLog(t).map(e => e.slice(1)), [[r.msgId, 'local_error', 'tainted_fallback']]);
  assert.deepEqual(plain(got), [{ msgId: r.msgId, local: true, bytes: errorResponse(r.msgId) }]);
  assert.equal(roleOf(t, g), 'game');
});

test('guard-gaps a: the fallback block follows the lobby rule — an untainted registered guard also blocks; an unguarded method still goes out', async () => {
  const { t, g, inject } = fallbackPage({ taint: false });
  const blocked = inject(SKIN);
  const free = inject(TITLE);
  await tick();
  assert.deepEqual(sentOn(g), [700, 701, free.msgId]);
  assert.deepEqual(guardLog(t).map(e => e.slice(1)), [[blocked.msgId, 'local_error', 'tainted_fallback']]);
});

test('guard-gaps a: Naki self-send and the game\'s own requests on the game connection are not judged as injections', async () => {
  const { t, g, inject } = fallbackPage();
  const r = inject(SKIN);
  t.c.__nakiWebSocket.sendRaw(b64(request(60020, SKIN)));
  g.send(request(r.msgId, SKIN));
  await tick();
  assert.deepEqual(sentOn(g), [700, 701, 60020, r.msgId]);
  assert.deepEqual(guardLog(t).map(e => e[3]), ['tainted_fallback']);
});

test('guard-gaps a: when guard lookup throws during a fallback injection, only GUARDABLE_METHODS are blocked', async () => {
  const { t, g, inject } = fallbackPage();
  t.c.__nakiPlugins.setGrant('broken', { methods: [TITLE], sendGuard: [TITLE] });
  t.c.__nakiPlugins.register({ id: 'broken', onSend() {} });
  t.c.__nakiPluginGrants.broken.sendGuard.indexOf = () => { throw new Error('lookup broke'); };
  const guarded = inject(TITLE);
  const plainLobby = inject('.lq.Lobby.fetchAccountInfo');
  await tick();
  assert.deepEqual(sentOn(g), [700, 701, plainLobby.msgId]);
  assert.deepEqual(guardLog(t).map(e => e.slice(1)), [[guarded.msgId, 'local_error', 'tainted_fallback']]);
});

test('R6-2 (Astra5 2, guard-gaps b): an in-place rewrite outside ctx.replace into a guarded method on an unknown Route request or a lobby FastTest request is reverted and the original goes out', async () => {
  for (const [first, method] of [[null, ROUTE], [BEAT, OP]]) {
    const t = page();
    guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
    t.c.__nakiPlugins.setGrant('obs', { capabilities: ['observe'], methods: [method] });
    t.c.__nakiPlugins.register({ id: 'obs', onSend(ctx) { ctx.bytes.set(request(ctx.msgId, SKIN, [8, 1])); } });
    const ws = first ? t.lobby : new t.c.WebSocket('wss://route-6.maj-soul.com/gateway');
    if (first) ws.send(request(709, first));
    const req = request(710, method, [8, 1, 8, 1]);
    const original = Array.from(req);
    ws.send(req);
    await tick();
    const out = ws.sent.slice(-1)[0];
    assert.deepEqual(Array.from(new Uint8Array(out.buffer ? out.buffer : out)), original, method);
    assert.equal(roleOf(t, ws), first ? 'lobby' : undefined, method);
    assert.equal(t.events('log').some(e => /改寫成守衛方法/.test(e.data.msg)), true, method);
  }
});

test('guard-gaps b: on a game connection an in-place rewrite into any GUARDABLE method is reverted without reading sendGuard; other in-place changes still go out', async () => {
  const t = page();
  let reads = 0;
  t.c.__nakiPlugins.setGrant('g', { capabilities: ['observe'], methods: [SKIN], get sendGuard() { reads++; return [SKIN]; } });
  t.c.__nakiPlugins.register({ id: 'g', onSend() {} });
  t.c.__nakiPlugins.setGrant('obs', { capabilities: ['observe'], methods: [OP, '.lq.Lobby.useTitle'] });
  t.c.__nakiPlugins.register({ id: 'obs', onSend(ctx) {
    if (ctx.msgId === 761) ctx.bytes.set(request(761, TITLE, new Array(ctx.bytes.length - 5 - TITLE.length - 2).fill(8)));
    else ctx.bytes[ctx.bytes.length - 1] ^= 1; } });
  const g = gameSocket(t.c);
  g.send(request(760, AUTH));
  const before = reads;
  const a = request(761, OP, [8, 1, 8, 1, 8, 1, 8, 1, 8, 1, 8, 1, 8, 1]);
  const aOriginal = Array.from(a);
  g.send(a);
  const b = request(762, OP, [8, 1]);
  const bChanged = Array.from(b); bChanged[bChanged.length - 1] ^= 1;
  g.send(b);
  const c = request(763, TITLE, [8, 1]);
  const cOriginal = Array.from(c);
  g.send(c);
  await tick();
  assert.equal(reads, before, 'no sendGuard read on the game connection');
  const bytesOut = g.sent.slice(1).map(d => Array.from(new Uint8Array(d.buffer ? d.buffer : d)));
  assert.deepEqual(bytesOut[0], aOriginal, 'rewrite into useTitle reverted');
  assert.deepEqual(bytesOut[1], bChanged, 'a non-guardable in-place change is not this guard\'s business');
  assert.deepEqual(bytesOut[2], cOriginal, 'a payload change to an existing Lobby request on game (§1.4 item 5) is reverted too');
});

test('R6-3 (Astra5 3, guard-gaps c): a Blob on a connection whose role is not yet known is refused while a guard is present', async () => {
  const t = page();
  guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
  const u = new t.c.WebSocket('wss://route-6.maj-soul.com/gateway');
  u.send(request(720, ROUTE));
  const blob = new t.c.Blob([request(721, SKIN)]);
  u.send(blob);
  assert.equal(u.sent.length, 1, 'the Blob is not sent');
  await tick();
  assert.equal(roleOf(t, u), undefined, 'a refused Blob is not dispatched, so it does not lock a role');
  assert.deepEqual(guardLog(t).map(e => e.slice(2)), [['refused_opaque', 'opaque_unknown_role']]);
  u.send(request(722, SKIN));
  await tick();
  assert.equal(u.sent.length, 1, 'the synchronous guarded request is blocked as before');
});

test('guard-gaps c: with no guard present a Blob on an unknown connection still goes out', async () => {
  const t = page();
  const u = new t.c.WebSocket('wss://route-6.maj-soul.com/gateway');
  const blob = new t.c.Blob([request(723, SKIN)]);
  u.send(blob);
  assert.equal(u.sent[0], blob);
});

// ---- guard-gaps 第二輪（Astra guard-gaps 第 1–6 條）----
const bytesOf = d => Array.from(d instanceof ArrayBuffer ? new Uint8Array(d) : new Uint8Array(d.buffer, d.byteOffset, d.byteLength));
const idOf = (t, ws) => t.c.__nakiWebSocket.getMajsoulConnections().find(c => c.ws === ws).id;
const sameLength = (method, total, msgId) => request(msgId, method, new Array(total - 5 - method.length - 2).fill(8));

test('GG2-1 (Astra 1): on a game connection a ctx.replace into a guarded method is reverted, counted as a hook failure, and the original goes out', async () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  guardPlugin(t.c);
  pollute(t);
  const results = [];
  t.c.__nakiPlugins.setGrant('rw', { capabilities: ['observe', 'rewriteSend'], methods: [INFO] });
  t.c.__nakiPlugins.register({ id: 'rw', onSend(ctx) { results.push(ctx.replace(request(ctx.msgId, SKIN, [8, 1]))); } });
  const g = gameSocket(t.c);
  g.send(request(800, AUTH));
  const req = request(801, INFO);
  const original = Array.from(req);
  g.send(req);
  await tick();
  assert.deepEqual(results, [true]);
  assert.deepEqual(sentOn(g), [800, 801]);
  assert.deepEqual(bytesOf(g.sent[1]), original);
  assert.equal(t.events('log').some(e => e.data.id === 'rw' && /onSend 拋錯（第 1 次）.*改寫成守衛方法/.test(e.data.msg)), true);
});

test('GG2-2 (Astra 2): a hook of the injected dispatch sending the same msgId on another game connection is not judged as the injection', async () => {
  const { t, g, inject } = fallbackPage();
  const g2 = gameSocket(t.c);
  g2.send(request(702, AUTH));
  t.c.__nakiPlugins.setGrant('obsN', { capabilities: ['observe'], methods: [TITLE], observeNakiTraffic: true });
  t.c.__nakiPlugins.register({ id: 'obsN', onSend(ctx) {
    if (ctx.isNaki) (ctx.socketId === idOf(t, g) ? g2 : g).send(request(ctx.msgId, SKIN)); } });
  const r = inject(TITLE);
  await tick();
  const all = [...sentOn(g), ...sentOn(g2)];
  assert.equal(all.filter(id => id === r.msgId).length, 2, 'the injected TITLE and the game\'s own SKIN both go out');
  assert.deepEqual(guardLog(t), []);
});

test('GG2-3 (Astra 3): injecting a method that can never be guarded does not read sendGuard', () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  let reads = 0;
  t.c.__nakiPlugins.setGrant('g', { capabilities: ['observe'], methods: [SKIN], get sendGuard() { reads++; return [SKIN]; } });
  t.c.__nakiPlugins.register({ id: 'g', onSend() {} });
  const inject = injector(t);
  const g = gameSocket(t.c);
  g.send(request(810, AUTH));
  g.send(request(811, OP));
  const before = reads;
  const r = inject()(OP, new t.c.Uint8Array([8, 1]));
  assert.equal(r.ok, true);
  assert.equal(reads, before);
  assert.deepEqual(sentOn(g), [810, 811, r.msgId]);
});

test('GG2-4 (Astra 4): ten consecutive in-place violations auto-disable the plugin', () => {
  const t = page();
  t.c.__nakiPlugins.setGrant('bad', { capabilities: ['observe'], methods: [OP] });
  t.c.__nakiPlugins.register({ id: 'bad', onSend(ctx) { ctx.bytes.set(sameLength(TITLE, ctx.bytes.length, ctx.msgId)); } });
  const g = gameSocket(t.c);
  g.send(request(820, AUTH));
  const originals = [];
  for (let i = 0; i < 11; i++) { const req = request(821 + i, OP, [8, 1, 8, 1, 8, 1, 8, 1, 8, 1]); originals.push(Array.from(req)); g.send(req); }
  assert.deepEqual(g.sent.slice(1).map(bytesOf), originals);
  assert.equal(t.events('log').some(e => e.data.id === 'bad' && /第 10 次/.test(e.data.msg)), true);
  assert.deepEqual(plain(t.c.__nakiPlugins.list()), [], 'auto-disabled after the tenth');
});

test('GG2-5 (Astra 5, documented risk): with only authGame switched to Blob, the lobby keeps working while the game connection is refused on every retry and stays unknown', async () => {
  const t = page();
  guardPlugin(t.c);
  t.lobby.send(request(830, BEAT));
  const g = gameSocket(t.c);
  for (let i = 0; i < 3; i++) g.send(new t.c.Blob([request(831 + i, AUTH)]));
  t.lobby.send(request(834, BEAT));
  await tick();
  assert.deepEqual(sentIds(t), [830, 834]);
  assert.equal(g.sent.length, 0);
  assert.equal(roleOf(t, g), undefined);
  assert.deepEqual(guardLog(t).map(e => e.slice(2)), Array(3).fill(['refused_opaque', 'opaque_unknown_role']));
});

test('GG2-6a (Astra 6): when sendRaw throws, the injection marker is cleared, so a later game request with that msgId goes out', async () => {
  const { t, g, inject } = fallbackPage();
  const real = t.c.__nakiWebSocket.sendRaw;
  t.c.__nakiWebSocket.sendRaw = () => { throw new Error('bridge gone'); };
  assert.throws(() => inject(SKIN), /bridge gone/);
  t.c.__nakiWebSocket.sendRaw = real;
  g.send(request(64000, SKIN, [8, 1]));   // 與那次注入的 bytes 完全相同：殘留標記才會命中
  await tick();
  assert.deepEqual(sentOn(g), [700, 701, 64000]);
  assert.deepEqual(guardLog(t), []);
});

test('GG2-6b (Astra 6): an injection nested before the outer dispatch restores the outer marker, so the outer guarded injection is still blocked', async () => {
  const { t, g, inject } = fallbackPage();
  const real = t.c.__nakiWebSocket.sendRaw;
  let depth = 0, inner;
  t.c.__nakiWebSocket.sendRaw = b => { if (depth++ === 0) inner = inject(TITLE); return real(b); };
  const outer = inject(SKIN);
  await tick();
  assert.equal(inner.ok && outer.ok, true);
  assert.deepEqual(sentOn(g), [700, 701, inner.msgId]);
  assert.deepEqual(guardLog(t).map(e => e.slice(1)), [[outer.msgId, 'local_error', 'tainted_fallback']]);
});

test('GG2-6c (Astra 6): the in-place revert holds for ArrayBuffer, Uint8Array and an offset DataView, and keeps an earlier hook\'s legal change', () => {
  for (const kind of ['ArrayBuffer', 'Uint8Array', 'DataView']) {
    const t = page();
    t.c.__nakiPlugins.setGrant('p1', { capabilities: ['observe'], methods: [OP], priority: 0 });
    t.c.__nakiPlugins.register({ id: 'p1', onSend(ctx) { ctx.bytes[ctx.bytes.length - 1] ^= 1; } });
    t.c.__nakiPlugins.setGrant('p2', { capabilities: ['observe'], methods: [OP], priority: 1 });
    t.c.__nakiPlugins.register({ id: 'p2', onSend(ctx) { ctx.bytes.set(sameLength(TITLE, ctx.bytes.length, ctx.msgId)); } });
    const g = gameSocket(t.c);
    g.send(request(840, AUTH));
    const req = request(841, OP, [8, 1, 8, 1, 8, 1, 8, 1, 8, 1]);
    const expected = Array.from(req); expected[expected.length - 1] ^= 1;
    const big = new Uint8Array(req.length + 4); big.set(req, 2);
    const data = kind === 'ArrayBuffer' ? req.slice().buffer : kind === 'Uint8Array' ? req.slice() : new DataView(big.buffer, 2, req.length);
    g.send(data);
    assert.deepEqual(bytesOf(g.sent[1]), expected, kind);
    if (kind === 'DataView') assert.deepEqual([big[0], big[1], big[big.length - 2], big[big.length - 1]], [0, 0, 0, 0], 'bytes outside the view untouched');
  }
});

// ---- guard-gaps 第三輪（Astra guard-gaps 第二輪 1–4 條）----
const methodOf = d => { const b = bytesOf(d); return Buffer.from(b.slice(5, 5 + b[4])).toString(); };
function rejections() {
  const seen = [];
  const on = r => seen.push(r);
  process.on('unhandledRejection', on);
  return { seen, off: () => process.off('unhandledRejection', on) };
}

test('GG3-1 (Astra2 1): a thenable whose then() rewrites the bytes into a guarded method synchronously is reverted, every time until auto-disable', async () => {
  const t = page();
  t.c.__nakiPlugins.setGrant('th', { capabilities: ['observe'], methods: [OP] });
  t.c.__nakiPlugins.register({ id: 'th', onSend(ctx) {
    return { then(resolve) { ctx.bytes.set(sameLength(SKIN, ctx.bytes.length, ctx.msgId)); resolve(); } }; } });
  const g = gameSocket(t.c);
  g.send(request(900, AUTH));
  const originals = [];
  for (let i = 0; i < 10; i++) { const req = request(901 + i, OP, [8, 1, 8, 1, 8, 1, 8, 1, 8, 1]); originals.push(Array.from(req)); g.send(req); }
  await tick();
  assert.deepEqual(g.sent.slice(1).map(bytesOf), originals);
  assert.equal(t.events('log').some(e => e.data.id === 'th' && /第 10 次.*改寫成守衛方法/.test(e.data.msg)), true);
  assert.deepEqual(plain(t.c.__nakiPlugins.list()), [], 'the early sync resolve does not reset the count');
});

test('GG3-1b: a thenable rejecting synchronously inside then() with no violation is still counted, ten times auto-disable', () => {
  const t = page();
  t.c.__nakiPlugins.setGrant('rj', { capabilities: ['observe'], methods: [OP] });
  t.c.__nakiPlugins.register({ id: 'rj', onSend() { return { then(resolve, reject) { reject(new Error('sync no')); } }; } });
  const g = gameSocket(t.c);
  g.send(request(910, AUTH));
  for (let i = 0; i < 10; i++) g.send(request(911 + i, OP, [8, 1]));
  assert.equal(g.sent.length, 11, 'nothing is rewritten, everything goes out');
  assert.equal(t.events('log').some(e => e.data.id === 'rj' && /第 10 次.*sync no/.test(e.data.msg)), true);
  assert.deepEqual(plain(t.c.__nakiPlugins.list()), []);
});

test('GG3-2 (Astra2 2): another dispatch of the same msgId before the injected one does not use up the injection binding', async () => {
  const { t, g, inject } = fallbackPage();
  const g2 = gameSocket(t.c);
  g2.send(request(703, AUTH));
  let busy = false;
  for (const [ws, other] of [[g, g2], [g2, g]]) {
    const orig = ws.send.bind(ws);
    ws.send = d => { if (!busy && d instanceof ArrayBuffer) { busy = true; other.send(request(bytesOf(d)[1] | (bytesOf(d)[2] << 8), OP)); busy = false; } return orig(d); };
  }
  const r = inject(SKIN);
  await tick();
  const out = [...g.sent, ...g2.sent].filter(d => (bytesOf(d)[1] | (bytesOf(d)[2] << 8)) === r.msgId).map(methodOf);
  assert.deepEqual(out, [OP], 'only the colliding OP goes out');
  assert.deepEqual(guardLog(t).map(e => e.slice(1)), [[r.msgId, 'local_error', 'tainted_fallback']]);
});

test('GG3-3 (Astra2 3): an in-place violation that also returns a rejected Promise is counted once and leaves no unhandled rejection', async () => {
  const rj = rejections();
  try {
    const t = page();
    t.c.__nakiPlugins.setGrant('bad', { capabilities: ['observe'], methods: [OP] });
    t.c.__nakiPlugins.register({ id: 'bad', onSend(ctx) {
      ctx.bytes.set(sameLength(TITLE, ctx.bytes.length, ctx.msgId)); return Promise.reject(new Error('async no')); } });
    const g = gameSocket(t.c);
    g.send(request(920, AUTH));
    const req = request(921, OP, [8, 1, 8, 1, 8, 1, 8, 1, 8, 1]);
    const original = Array.from(req);
    g.send(req);
    for (let i = 0; i < 5; i++) await tick();
    assert.deepEqual(bytesOf(g.sent[1]), original);
    const logs = t.events('log').filter(e => e.data.id === 'bad' && /拋錯/.test(e.data.msg)).map(e => e.data.msg);
    assert.equal(logs.length, 1, logs.join(' | '));
    assert.match(logs[0], /第 1 次.*改寫成守衛方法/);
    assert.deepEqual(rj.seen, []);
  } finally { rj.off(); }
});

test('GG3-4a (Astra2 4): an inner injection that throws before the outer dispatch leaves the outer injection guarded', async () => {
  const { t, g, inject } = fallbackPage();
  const real = t.c.__nakiWebSocket.sendRaw;
  let depth = 0, innerError;
  t.c.__nakiWebSocket.sendRaw = b => {
    const d = depth++;
    if (d === 1) throw new Error('inner bridge gone');
    if (d === 0) { try { inject(TITLE); } catch (e) { innerError = e; } }
    return real(b);
  };
  const outer = inject(SKIN);
  await tick();
  assert.match(String(innerError), /inner bridge gone/);
  assert.equal(outer.ok, true);
  assert.deepEqual(sentOn(g), [700, 701]);
  assert.deepEqual(guardLog(t).map(e => e.slice(1)), [[outer.msgId, 'local_error', 'tainted_fallback']]);
});

test('GG3-4b (Astra2 4): after sendRaw reports failure, the game\'s identical request with that msgId is not judged as the injection', async () => {
  const { t, g, inject } = fallbackPage();
  const real = t.c.__nakiWebSocket.sendRaw;
  t.c.__nakiWebSocket.sendRaw = () => ({ success: false, reason: 'no_open_majsoul_connection' });
  const r = inject(SKIN);
  assert.deepEqual(plain(r), { ok: false, reason: 'no_open_majsoul_connection' });
  t.c.__nakiWebSocket.sendRaw = real;
  g.send(request(64000, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(sentOn(g), [700, 701, 64000]);
  assert.deepEqual(guardLog(t), []);
});

test('GG3-4c (Astra2 4; guard-gaps round 7): a near-miss method from one hook is itself an in-place method change and is reverted, so TITLE never forms in either order', () => {
  const NEAR = '.lq.Lobby.useTitlX';
  for (const nearFirst of [true, false]) {
    const t = page();
    t.c.__nakiPlugins.setGrant('near', { capabilities: ['observe'], methods: [OP], priority: nearFirst ? 0 : 1 });
    t.c.__nakiPlugins.register({ id: 'near', onSend(ctx) { ctx.bytes.set(sameLength(NEAR, ctx.bytes.length, ctx.msgId)); } });
    t.c.__nakiPlugins.setGrant('fix', { capabilities: ['observe'], methods: [OP], priority: nearFirst ? 1 : 0 });
    t.c.__nakiPlugins.register({ id: 'fix', onSend(ctx) { ctx.bytes[5 + TITLE.length - 1] = 'e'.charCodeAt(0); } });
    const g = gameSocket(t.c);
    g.send(request(930, AUTH));
    g.send(request(931, OP, [8, 1, 8, 1, 8, 1, 8, 1, 8, 1]));
    assert.equal(methodOf(g.sent[1]), OP, nearFirst ? 'near first' : 'fix first');
  }
});

// ---- guard-gaps 第四輪（Astra guard-gaps 第三輪 1–3 條）：送出快照 ----
const OPREQ = id => request(id, OP, [8, 1, 8, 1, 8, 1, 8, 1, 8, 1]);
const swiftSends = t => t.toSwift('send');
function gameWith(t, id, grant, spec) {
  t.c.__nakiPlugins.setGrant(id, { capabilities: ['observe'], methods: [OP], ...grant });
  assert.equal(t.c.__nakiPlugins.register({ id, ...spec }), true);
  const g = gameSocket(t.c);
  g.send(request(950, AUTH));
  return g;
}

test('GG4-1 (Astra3 1 A): a rejection whose message getter rewrites the kept bytes into SKIN does not change what is committed or sent to Swift', () => {
  const t = page();
  let kept;
  const g = gameWith(t, 'mg', {}, { onSend(ctx) {
    kept = ctx.bytes;
    const err = { get message() { kept.set(sameLength(SKIN, kept.length, 951)); return 'getter'; } };
    return { then(resolve, reject) { reject(err); } }; } });
  const req = OPREQ(951);
  const original = Array.from(req);
  g.send(req);
  assert.deepEqual(g.committed[1], original);
  assert.deepEqual(swiftSends(t).slice(-1), [original]);
});

test('GG4-1b: a synchronous throw whose message getter rewrites the bytes after the revert is undone as well', () => {
  const t = page();
  const g = gameWith(t, 'mg2', {}, { onSend(ctx) {
    const kept = ctx.bytes;
    throw { get message() { kept.set(sameLength(SKIN, kept.length, 952)); return 'getter'; } }; } });
  const req = OPREQ(952);
  const original = Array.from(req);
  g.send(req);
  assert.deepEqual(g.committed[1], original);
  assert.deepEqual(swiftSends(t).slice(-1), [original]);
});

test('GG4-2 (Astra3 1 B): onDisable on the tenth failure rewriting the kept bytes into SKIN does not change that send', () => {
  const t = page();
  let kept;
  const g = gameWith(t, 'od', {}, {
    onSend(ctx) { kept = ctx.bytes; return { then(resolve, reject) { reject(new Error('no')); } }; },
    onDisable() { kept.set(sameLength(SKIN, kept.length, 970)); } });
  const originals = [];
  for (let i = 0; i < 10; i++) { const req = OPREQ(961 + i); originals.push(Array.from(req)); g.send(req); }
  assert.deepEqual(plain(t.c.__nakiPlugins.list()), [], 'disabled on the tenth');
  assert.deepEqual(g.committed.slice(1), originals);
  assert.deepEqual(swiftSends(t).slice(-10), originals);
});

test('GG4-3: during bookkeeping, ctx.replace by the hook is discarded too', () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  let ctxRef;
  t.c.__nakiPlugins.setGrant('rp', { capabilities: ['observe', 'rewriteSend'], methods: [INFO] });
  t.c.__nakiPlugins.register({ id: 'rp', onSend(ctx) {
    ctxRef = ctx;
    throw { get message() { ctxRef.replace(request(ctxRef.msgId, TITLE, [8, 1])); return 'getter'; } }; } });
  const g = gameSocket(t.c);
  g.send(request(980, AUTH));
  const req = request(981, INFO);
  g.send(req);
  assert.equal(g.sent[1], req, 'the original object goes out');
  assert.deepEqual(g.committed[1], Array.from(request(981, INFO)));
});

test('GG4-4: a throwing message getter does not break failure accounting (ten auto-disable)', () => {
  const t = page();
  const g = gameWith(t, 'tg', {}, { onSend() { throw { get message() { throw new Error('getter boom'); } }; } });
  for (let i = 0; i < 10; i++) g.send(OPREQ(990 + i));
  assert.equal(g.committed.length, 11);
  assert.deepEqual(plain(t.c.__nakiPlugins.list()), []);
});

test('GG4-5: overriding set on ctx.bytes does not stop the revert of an in-place rewrite into TITLE', () => {
  const t = page();
  const g = gameWith(t, 'ov', {}, { onSend(ctx) {
    ctx.bytes.set = () => {};
    sameLength(TITLE, ctx.bytes.length, ctx.msgId).forEach((x, i) => { ctx.bytes[i] = x; }); } });
  const req = OPREQ(1001);
  const original = Array.from(req);
  g.send(req);
  assert.deepEqual(g.committed[1], original);
});

test('GG4-5b: an earlier hook overriding slice on the shared buffer cannot hide a later in-place rewrite into TITLE', () => {
  const t = page();
  t.c.__nakiPlugins.setGrant('sl', { capabilities: ['observe'], methods: [OP], priority: 0 });
  t.c.__nakiPlugins.register({ id: 'sl', onSend(ctx) { const len = ctx.bytes.length, id = ctx.msgId; ctx.bytes.slice = () => sameLength(TITLE, len, id); } });
  t.c.__nakiPlugins.setGrant('rw', { capabilities: ['observe'], methods: [OP], priority: 1 });
  t.c.__nakiPlugins.register({ id: 'rw', onSend(ctx) { sameLength(TITLE, ctx.bytes.length, ctx.msgId).forEach((x, i) => { ctx.bytes[i] = x; }); } });
  const g = gameSocket(t.c);
  g.send(request(1002, AUTH));
  const req = OPREQ(1003);
  const original = Array.from(req);
  g.send(req);
  assert.deepEqual(g.committed[1], original);
});

test('GG4-6 (Astra3 3): identical-bytes collision before the injected dispatch blocks both, per Deviation 11', async () => {
  const { t, g, inject } = fallbackPage();
  const g2 = gameSocket(t.c);
  g2.send(request(704, AUTH));
  let busy = false;
  for (const [ws, other] of [[g, g2], [g2, g]]) {
    const orig = ws.send.bind(ws);
    ws.send = d => { if (!busy && d instanceof ArrayBuffer) { busy = true; other.send(new Uint8Array(bytesOf(d))); busy = false; } return orig(d); };
  }
  const r = inject(SKIN);
  await tick();
  assert.equal([...g.committed, ...g2.committed].filter(b => Array.isArray(b) && (b[1] | (b[2] << 8)) === r.msgId).length, 0);
  assert.deepEqual(guardLog(t).map(e => e.slice(2)), [['local_error', 'tainted_fallback'], ['local_error', 'tainted_fallback']]);
});

test('GG4-7 (Astra3 3): two thenable hooks, one legal and one rewriting into TITLE, in both orders keep the legal change only', () => {
  for (const legalFirst of [true, false]) {
    const t = page();
    t.c.__nakiPlugins.setGrant('legal', { capabilities: ['observe'], methods: [OP], priority: legalFirst ? 0 : 1 });
    t.c.__nakiPlugins.register({ id: 'legal', onSend(ctx) { return { then(res) { ctx.bytes[ctx.bytes.length - 1] ^= 1; res(); } }; } });
    t.c.__nakiPlugins.setGrant('bad', { capabilities: ['observe'], methods: [OP], priority: legalFirst ? 1 : 0 });
    t.c.__nakiPlugins.register({ id: 'bad', onSend(ctx) { return { then(res) { ctx.bytes.set(sameLength(TITLE, ctx.bytes.length, ctx.msgId)); res(); } }; } });
    const g = gameSocket(t.c);
    g.send(request(1010, AUTH));
    const req = OPREQ(1011);
    const expected = Array.from(req); expected[expected.length - 1] ^= 1;
    g.send(req);
    assert.deepEqual(g.committed[1], expected, legalFirst ? 'legal first' : 'bad first');
  }
});

test('GG4-8 (Astra3 3): a later-resolving Promise resets the failure count, so 9 + 9 failures do not disable', async () => {
  const t = page();
  let mode = 'throw';
  const g = gameWith(t, 'lr', {}, { onSend() {
    if (mode === 'throw') throw new Error('no');
    return new Promise(r => setTimeout(r, 0)); } });
  for (let i = 0; i < 9; i++) g.send(OPREQ(1020 + i));
  mode = 'ok';
  g.send(OPREQ(1029));
  await tick(); await tick();
  mode = 'throw';
  for (let i = 0; i < 9; i++) g.send(OPREQ(1030 + i));
  assert.deepEqual(plain(t.c.__nakiPlugins.list()).map(e => e.id), ['lr']);
});

// ---- guard-gaps 第五輪（Astra guard-gaps 第四輪 1–4 條）：插件只拿副本，外送宿主快照 ----
test('GG5-1 (Astra4 1): a constructor getter on ctx.bytes that rewrites into SKIN never runs in the host, on the game chain and on the Naki chain', () => {
  for (const naki of [false, true]) {
    const t = page();
    const spec = { onSend(ctx) {
      const b = ctx.bytes;
      Object.defineProperty(b, 'constructor', { get() { b.set(sameLength(SKIN, b.length, ctx.msgId)); return Uint8Array; } }); } };
    const g = gameWith(t, 'ctor', naki ? { observeNakiTraffic: true } : {}, spec);
    const req = OPREQ(1101);
    const original = Array.from(req);
    if (naki) t.c.__nakiWebSocket.sendRaw(b64(req)); else g.send(req);
    assert.deepEqual(g.committed[1], original, naki ? 'sendRaw' : 'game');
    assert.deepEqual(swiftSends(t).slice(-1), [original], naki ? 'sendRaw' : 'game');
  }
});

test('GG5-2 (Astra4 2 A): a byteLength getter on ctx.bytes is never read on the way out, with or without a legal change', () => {
  for (const legal of [false, true]) {
    const t = page();
    const g = gameWith(t, 'bl', {}, { onSend(ctx) {
      const b = ctx.bytes;
      if (legal) b[b.length - 1] ^= 1;
      Object.defineProperty(b, 'byteLength', { get() { b.set(sameLength(SKIN, b.length, ctx.msgId)); return b.length; } }); } });
    const req = OPREQ(1102);
    const expected = Array.from(req); if (legal) expected[expected.length - 1] ^= 1;
    g.send(req);
    assert.deepEqual(g.committed[1], expected, legal ? 'legal' : 'unchanged');
    assert.deepEqual(swiftSends(t).slice(-1), [expected], legal ? 'legal' : 'unchanged');
  }
});

test('GG5-3 (Astra4 2 B): a later plugin\'s onSend getter rewriting an earlier plugin\'s kept bytes does not change the send', () => {
  const t = page();
  let kept;
  t.c.__nakiPlugins.setGrant('keep', { capabilities: ['observe'], methods: [OP], priority: 0 });
  t.c.__nakiPlugins.register({ id: 'keep', onSend(ctx) { kept = ctx.bytes; } });
  t.c.__nakiPlugins.setGrant('getr', { capabilities: ['observe'], methods: [OP], priority: 1 });
  t.c.__nakiPlugins.register({ id: 'getr', get onSend() { if (kept) kept.set(sameLength(SKIN, kept.length, 1103)); return function () {}; } });
  const g = gameSocket(t.c);
  g.send(request(1100, AUTH));
  const req = OPREQ(1103);
  const original = Array.from(req);
  g.send(req);
  assert.deepEqual(g.committed[1], original);
  assert.deepEqual(swiftSends(t).slice(-1), [original]);
});

test('GG5-4 (Astra4 4): the game\'s buffer is never handed to plugins, so reusing it after a deferred rewrite sends OP again', async () => {
  const t = page();
  let kept;
  const g = gameWith(t, 'later', {}, { onSend(ctx) { kept = ctx.bytes; Promise.resolve().then(() => kept.set(sameLength(SKIN, kept.length, 1104))); } });
  const req = OPREQ(1104);
  const original = Array.from(req);
  g.send(req);
  await tick();
  assert.deepEqual(Array.from(req), original, 'the game buffer is untouched');
  g.send(req);
  assert.deepEqual(g.committed.slice(1), [original, original]);
  assert.deepEqual(swiftSends(t).slice(-2), [original, original]);
});

test('GG5-5 (Astra4 3): the error message getter is read exactly once', () => {
  const t = page();
  let reads = 0;
  const g = gameWith(t, 'msg', {}, { onSend() { throw { get message() { reads++; return reads === 1 ? 'first' : 'second'; } }; } });
  g.send(OPREQ(1105));
  assert.equal(reads, 1);
  assert.equal(plain(t.c.__nakiPlugins.diagnostics()).runtime.lastError.message, 'first');
  assert.equal(t.events('log').some(e => e.data.id === 'msg' && /第 1 次）：first/.test(e.data.msg)), true);
});

test('GG5-6: detaching the copy\'s buffer is a hook failure and the original goes out', () => {
  const t = page();
  const g = gameWith(t, 'det', {}, { onSend(ctx) { ctx.bytes.buffer.transfer(); } });
  const req = OPREQ(1106);
  const original = Array.from(req);
  g.send(req);
  assert.deepEqual(g.committed[1], original);
  assert.equal(t.events('log').some(e => e.data.id === 'det' && /無法讀取/.test(e.data.msg)), true);
});

test('GG5-7: an own length property on the copy cannot truncate or extend what is sent', () => {
  for (const delta of [-1, 1]) {
    const t = page();
    const g = gameWith(t, 'len', {}, { onSend(ctx) {
      const b = ctx.bytes, n = b.length;
      b[n - 1] ^= 1;
      Object.defineProperty(b, 'length', { value: n + delta }); } });
    const req = OPREQ(1107);
    const expected = Array.from(req); expected[expected.length - 1] ^= 1;
    g.send(req);
    assert.deepEqual(g.committed[1], expected, String(delta));
  }
});

test('GG5-8: on the send chain ctx.bytes is a copy; a legal in-place change reaches the wire without touching the game\'s buffer', () => {
  const t = page();
  let seen;
  const g = gameWith(t, 'cp', {}, { onSend(ctx) { seen = ctx.bytes; ctx.bytes[ctx.bytes.length - 1] ^= 1; } });
  const req = OPREQ(1108);
  const original = Array.from(req);
  const expected = original.slice(); expected[expected.length - 1] ^= 1;
  g.send(req);
  assert.notEqual(seen.buffer, req.buffer);
  assert.deepEqual(Array.from(req), original);
  assert.deepEqual(g.committed[1], expected);
  assert.deepEqual(swiftSends(t).slice(-1), [expected]);
});

test('R6-4 (Astra5 5, revised in guard-gaps round 5): an observer corrupting a FastTest only touches its copy, so on a bridge error the pristine original goes out on lobby and game', async () => {
  for (const onLobby of [true, false]) {
    const t = page(source('naki-websocket.js'), { breakBase64: true });
    guardPlugin(t.c);
    t.c.__nakiPlugins.setGrant('obs', { capabilities: ['observe'], methods: [OP] });
    t.c.__nakiPlugins.register({ id: 'obs', onSend(ctx) { ctx.bytes[0] = 9; } });
    const ws = onLobby ? t.lobby : gameSocket(t.c);
    ws.send(request(730, onLobby ? BEAT : AUTH));
    const req = request(731, OP);
    const original = Array.from(req);
    ws.send(req);
    await tick();
    assert.equal(ws.sent.length, 2, onLobby ? 'lobby' : 'game');
    assert.deepEqual(ws.committed[1], original, onLobby ? 'lobby' : 'game');
  }
});

test('R6-5: failSafe never changes a locked role — a Lobby request on a game connection hit by a bridge error still goes out', async () => {
  const t = page();
  guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
  const g = gameSocket(t.c);
  g.send(request(740, AUTH));
  t.c.__nakiHideNames.observe = () => { throw new Error('observer broke'); };
  g.send(request(741, SKIN));
  await tick();
  assert.deepEqual(sentOn(g), [740, 741]);
  assert.equal(roleOf(t, g), 'game');
});

test('R6-6 (Astra5 6, D27): an internal error after an unguarded in-place rewrite restores and sends the original non-guardable request', async () => {
  const t = page();
  guardPlugin(t.c);
  t.c.__nakiPlugins.setGrant('obs', { capabilities: ['observe'], methods: [HEAT] });
  t.c.__nakiPlugins.register({ id: 'obs', onSend(ctx) { Buffer.from(TITLE).forEach((x, i) => { ctx.bytes[5 + i] = x; }); } });
  let reads = 0;
  t.c.__nakiPlugins.setGrant('late', { methods: [HEAT], priority: 10,
    get capabilities() { if (reads++ < 1) return ['observe']; throw new Error('bad grant'); } });
  assert.equal(t.c.__nakiPlugins.register({ id: 'late', onSend() {} }), true);
  const req = request(750, HEAT);
  const original = Array.from(req);
  t.lobby.send(req);
  await tick();
  assert.deepEqual(sentIds(t), [750]);
  assert.deepEqual(Array.from(new Uint8Array(t.lobby.sent[0])), original);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log, []);
});

test('D22: a game request whose msgId runs into the plugin range is guarded normally, not naki_traffic', () => {
  const t = page();
  guardPlugin(t.c);
  for (const id of [64000, 64010, 65500]) t.lobby.send(request(id, SKIN, [8, 1]));
  assert.deepEqual(sentIds(t), [64000, 64010, 65500]);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => [e.msgId, e.outcome]),
    [[64000, 'sent'], [64010, 'sent'], [65500, 'sent']]);
});

test('D22: a Naki msgId sent on the game connection does not mark the same msgId on the lobby', () => {
  const t = page();
  guardPlugin(t.c);
  const gameWs = new t.c.WebSocket('wss://route-4.maj-soul.com/game-gateway');
  const r = t.c.__nakiWebSocket.sendRaw(Buffer.from(request(60003, '.lq.FastTest.inputOperation')).toString('base64'));
  assert.equal(r.success, true); assert.equal(gameWs.sent.length, 1);
  t.lobby.send(request(60003, SKIN, [8, 1]));
  assert.deepEqual(sentIds(t), [60003]);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => [e.msgId, e.outcome]), [[60003, 'sent']]);
});

test('D22-2: a game guarded request on the same line and msgId as a Naki send is blocked only until the Naki RESPONSE arrives', () => {
  const t = page();
  guardPlugin(t.c);
  t.c.__nakiWebSocket.sendRaw(Buffer.from(request(60003, BEAT)).toString('base64'));
  t.lobby.send(request(60003, SKIN, [8, 1]));
  t.lobby.receive(response(60003, []));
  t.lobby.send(request(60003, SKIN, [8, 1]));
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => [e.msgId, e.outcome, e.reason]),
    [[60003, 'local_error', 'naki_traffic'], [60003, 'sent', null]]);
  assert.deepEqual(sentIds(t), [60003, 60003]);
});

const b64 = u8 => Buffer.from(u8).toString('base64');
const guardLog = t => plain(t.c.__nakiPlugins.guardState()).log.map(e => [e.socketId, e.msgId, e.outcome, e.reason]);

test('D22-3: a Blob RESPONSE marks the Naki pair answered once unwrapped, so the game\'s same pair goes out', async () => {
  const t = page();
  guardPlugin(t.c);
  t.c.__nakiWebSocket.sendRaw(b64(request(60003, BEAT)));
  t.lobby.dispatchEvent(new t.c.MessageEvent('message', { data: new t.c.Blob([response(60003, [])]) }));
  for (let i = 0; i < 5; i++) await tick();
  t.lobby.send(request(60003, SKIN, [8, 1]));
  assert.deepEqual(guardLog(t).map(e => e.slice(1)), [[60003, 'sent', null]]);
  assert.deepEqual(sentIds(t), [60003, 60003]);
});

test('D22-3: a Naki guarded request answered locally stays pending (documented exception): the game\'s same pair is still naki_traffic', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  t.c.__nakiWebSocket.sendRaw(b64(request(60001, SKIN)));
  await tick();
  assert.deepEqual(t.game.slice(-1), [errorResponse(60001)]);
  t.lobby.send(request(60001, SKIN, [8, 1]));
  assert.deepEqual(guardLog(t).map(e => e[3]), ['naki_traffic', 'naki_traffic']);
});

test('D22-3: the same Naki msgId on two lobbies with only one answered: only the answered lobby lets the game\'s same pair through', () => {
  const t = page();
  guardPlugin(t.c);
  const lobby2 = new t.c.WebSocket('wss://route-4.maj-soul.com/gateway');
  t.c.__nakiWebSocket.sendRaw(b64(request(60004, BEAT)));
  lobby2.send(request(30, INFO));
  t.c.__nakiWebSocket.sendRaw(b64(request(60004, BEAT)));
  assert.equal(lobby2.sent.length, 2);
  t.lobby.receive(response(60004, []));
  t.lobby.send(request(60004, SKIN, [8, 1]));
  lobby2.send(request(60004, SKIN, [8, 1]));
  const [a, b] = t.c.__nakiWebSocket.getMajsoulConnections().map(x => x.id);
  assert.deepEqual(guardLog(t), [[a, 60004, 'sent', null], [b, 60004, 'local_error', 'naki_traffic']]);
  assert.equal(lobby2.sent.length, 2, 'the game request on the unanswered lobby never went out');
});

test('D22-4: a Blob RESPONSE unwrapped after a re-send of the same pair does not answer the new send: the game\'s same pair stays blocked', async () => {
  const t = page();
  guardPlugin(t.c);
  t.c.__nakiWebSocket.sendRaw(b64(request(60008, BEAT)));
  t.lobby.dispatchEvent(new t.c.MessageEvent('message', { data: new t.c.Blob([response(60008, [])]) }));
  t.c.__nakiWebSocket.sendRaw(b64(request(60008, BEAT)));
  for (let i = 0; i < 5; i++) await tick();
  t.lobby.send(request(60008, SKIN, [8, 1]));
  assert.deepEqual(guardLog(t).map(e => e.slice(1)), [[60008, 'local_error', 'naki_traffic']]);
  assert.deepEqual(sentIds(t), [60008, 60008], 'only the two Naki sends went out');
});

test('D22-4: a locally answered Naki guarded request that is re-sent stays pending: the game\'s same pair goes out 0 times', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  for (let i = 0; i < 2; i++) { t.c.__nakiWebSocket.sendRaw(b64(request(60001, SKIN))); await tick(); }
  const id = t.c.__nakiWebSocket.getMajsoulConnections()[0].id;
  assert.equal(t.c.__nakiWebSocket.isNakiSent(60001, id, true), true);
  t.lobby.send(request(60001, SKIN, [8, 1]));
  assert.deepEqual(guardLog(t).map(e => e[3]), ['naki_traffic', 'naki_traffic', 'naki_traffic']);
  assert.deepEqual(sentIds(t), [10]);
});


// ---- ctx.taint() / ctx.isTainted()：插件主動污染自己 ----
function taintOnReceive(c, { grant = {}, out = [] } = {}) {
  c.__nakiPlugins.setGrant(ID, { capabilities: ['observe'], methods: [SKIN, INFO], sendGuard: [SKIN], ...grant });
  return c.__nakiPlugins.register({ id: ID,
    onReceive(ctx) { if (ctx.method === INFO) { out.push(ctx.isTainted()); out.push(ctx.taint()); out.push(ctx.isTainted()); } },
    onSend() {} });
}

test('ctx.taint(): a guard plugin taints itself without rewriting; same set, same event, L3 off blocks, disable keeps it', async () => {
  const t = page();
  const out = [];
  taintOnReceive(t.c, { out });
  pollute(t);
  assert.deepEqual(out, [false, true, true]);
  assert.equal(t.events('tainted').length, 1);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).tainted, { [ID]: [SKIN] });
  t.c.__nakiPluginsMayModifyOutbound = false;
  t.lobby.send(request(200, SKIN));
  await tick();
  assert.deepEqual(sentIds(t), [10]);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.map(e => e.reason), ['outbound_disabled']);
  t.c.__nakiPlugins.disable(ID);
  t.lobby.send(request(201, SKIN));
  await tick();
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log.slice(-1).map(e => e.reason), ['not_on_chain']);
  taintOnReceive(t.c, { out: [] });
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).tainted, { [ID]: [SKIN] }, 're-enable stays tainted');
  assert.equal(t.events('tainted').length, 1, 'no second event');
});

test('ctx.taint(): repeated calls stay idempotent', () => {
  const t = page();
  const out = [];
  taintOnReceive(t.c, { out });
  pollute(t);
  t.lobby.send(request(11, INFO));
  t.lobby.receive(response(11, [8, 1]));
  assert.equal(t.events('tainted').length, 1);
  assert.deepEqual(out, [false, true, true, true, true, true]);
});

test('ctx.taint(): without sendGuard returns false, taints nothing, sends unaffected', () => {
  const t = page();
  const out = [];
  taintOnReceive(t.c, { grant: { sendGuard: undefined }, out });
  pollute(t);
  assert.deepEqual(out, [false, false, false]);
  assert.equal(t.events('tainted').length, 0);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).tainted, {});
  const req = request(210, SKIN);
  t.lobby.send(req);
  assert.equal(t.lobby.sent[1], req, 'original object still goes out');
});

test('ctx.taint(): a guard plugin tainting from game-gateway onSend is tainted', () => {
  const t = page();
  t.c.__nakiPlugins.setGrant(ID, { capabilities: ['observe'], methods: [SKIN, '.lq.FastTest.authGame'], sendGuard: [SKIN] });
  t.c.__nakiPlugins.register({ id: ID, onSend(ctx) { if (ctx.method === '.lq.FastTest.authGame') ctx.taint(); } });
  new t.c.WebSocket('wss://route-4.maj-soul.com/game-gateway').send(request(79, '.lq.FastTest.authGame'));
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).tainted, { [ID]: [SKIN] });
});

test('ctx.taint(): extra arguments are ignored, a plugin can only taint itself', () => {
  const t = page();
  t.c.__nakiPlugins.setGrant('other', { capabilities: ['observe'], methods: [SKIN, INFO], sendGuard: [SKIN] });
  let otherTainted;
  t.c.__nakiPlugins.register({ id: 'other', onReceive(ctx) { otherTainted = ctx.isTainted(); } });
  t.c.__nakiPlugins.setGrant(ID, { capabilities: ['observe'], methods: [SKIN, INFO], sendGuard: [SKIN] });
  t.c.__nakiPlugins.register({ id: ID, onReceive(ctx) { ctx.taint('other'); } });
  pollute(t);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).tainted, { [ID]: [SKIN] });
  assert.equal(otherTainted, false);
});

test('loadSource: document-start only while the host bootstrap runs, hot otherwise', () => {
  const t = page();
  const p = t.c.__nakiPlugins;
  assert.equal(p.loadSource, 'hot', 'before any bootstrap');
  assert.equal(p.beginBootstrap(), true);
  t.c.__nakiPlugins.setGrant('boot', { capabilities: ['observe'], methods: [] });
  t.c.seen = null;
  vm.runInContext(`window.seen = window.__nakiPlugins.loadSource; window.__nakiPlugins.register({ id: 'boot' });`, t.c);
  assert.equal(t.c.seen, 'document-start');
  assert.equal(p.endBootstrap(), true);
  assert.equal(p.loadSource, 'hot');
  assert.equal(p.beginBootstrap(), false, 'a second bootstrap is refused, hot plugins cannot re-enter document-start');
  assert.equal(p.loadSource, 'hot');
  assert.equal(p.list().some(x => x.id === 'boot'), true, 'registration survives');
});

test('loadSource: re-registering after disable is hot, and the property is read-only', () => {
  const t = page();
  const p = t.c.__nakiPlugins;
  p.beginBootstrap();
  p.endBootstrap();
  p.setGrant('h', { capabilities: ['observe'], methods: [] });
  try { p.loadSource = 'document-start'; } catch (e) { /* strict mode throws, sloppy ignores */ }
  assert.equal(p.loadSource, 'hot');
  p.disable('h');
  p.setGrant('h', { capabilities: ['observe'], methods: [] });
  vm.runInContext(`window.seen = window.__nakiPlugins.loadSource`, t.c);
  assert.equal(t.c.seen, 'hot');
});

test('devLog: unknown id is dropped, known id shares the ctx.log channel and format', () => {
  const t = page();
  const p = t.c.__nakiPlugins;
  assert.equal(p.devLog('ghost', 'x'), false);
  assert.equal(p.devLog(42, 'x'), false);
  assert.equal(t.events('log').length, 0);
  p.setGrant('dev', { capabilities: ['observe'], methods: [] });
  p.register({ id: 'dev' });
  t.events('log').length = 0;
  t.swift.length = 0;
  assert.equal(p.devLog('dev', 'early'), true);
  const [e] = t.events('log');
  assert.deepEqual(plain(e.data), { id: 'dev', kind: 'log', msg: 'early' });
});

test('devLog: works for a granted plugin that has not registered yet (loading)', () => {
  const t = page();
  const p = t.c.__nakiPlugins;
  p.setGrant('pre', { capabilities: ['observe'], methods: [] });
  assert.equal(p.devLog('pre', 'before register'), true);
  assert.equal(t.events('log').length, 1);
  p.disable('pre');
  assert.equal(p.devLog('pre', 'after disable'), false, 'grant removed and not registered');
});

test('devLog: capped at 500 lines per plugin per page, other plugins unaffected', () => {
  const t = page();
  const p = t.c.__nakiPlugins;
  p.setGrant('a', { capabilities: ['observe'], methods: [] });
  p.setGrant('b', { capabilities: ['observe'], methods: [] });
  let ok = 0;
  for (let i = 0; i < 520; i++) if (p.devLog('a', 'l' + i)) ok++;
  assert.equal(ok, 500);
  assert.equal(p.devLog('a', 'more'), false);
  assert.equal(p.devLog('b', 'fine'), true);
  assert.equal(t.events('log').filter(e => e.data.id === 'a').length, 500);
});

test('devLog: true only when delivered; bridge failure or throwing toString returns false and costs no quota', () => {
  let down = false;
  const t = page(undefined, { swiftFails: () => down });
  const p = t.c.__nakiPlugins;
  p.setGrant('d', { capabilities: ['observe'], methods: [] });
  down = true;
  for (let i = 0; i < 600; i++) assert.equal(p.devLog('d', 'x'), false, 'bridge throws');
  down = false;
  assert.equal(p.devLog('d', { toString() { throw new Error('boom'); } }), false, 'toString throws');
  let ok = 0;
  for (let i = 0; i < 520; i++) if (p.devLog('d', 'l' + i)) ok++;
  assert.equal(ok, 500, 'failed attempts did not consume the quota');
});

function sealPage(opts) {
  const t = page(undefined, opts);
  const p = t.c.__nakiPlugins;
  p.setGrant('s', { capabilities: ['observe'], methods: [] });
  t.events('log').length = 0;
  return { t, p, logs: () => t.events('log').map(e => e.data.msg) };
}

test('devLogSeal: host writes the seal line with the delivered count; later devLog/devLogSeal fail closed and send nothing', () => {
  const { p, logs } = sealPage();
  p.devLog('s', 'a'); p.devLog('s', 'b');
  assert.equal(p.devLogSeal('s', { run: 'r1' }), true);
  const last = logs().pop();
  assert.deepEqual(JSON.parse(last), { kind: 'seal', plugin: 's', count: 2, meta: { run: 'r1' } });
  const n = logs().length;
  assert.equal(p.devLog('s', 'late'), false);
  assert.equal(p.devLogSeal('s', {}), false, 'second seal refused');
  assert.equal(logs().length, n, 'nothing sent after seal');
});

test('devLogSeal: unknown id, non-plain or oversized meta return false and send nothing', () => {
  const { p, logs } = sealPage();
  assert.equal(p.devLogSeal('ghost', {}), false);
  assert.equal(p.devLogSeal(7, {}), false);
  for (const bad of [undefined, null, 'x', 1, [], [1], new Date(), new Map(), { a: 'x'.repeat(600) }, { get a() { throw new Error('x'); } }]) {
    assert.equal(p.devLogSeal('s', bad), false);
  }
  assert.equal(logs().length, 0);
  assert.equal(p.devLogSeal('s', { a: 'x'.repeat(480) }), true, 'under 512 bytes still sealed after failed attempts');
});

test('devLogSeal: meta limit counts UTF-8 bytes', () => {
  const { p } = sealPage();
  assert.equal(p.devLogSeal('s', { a: '雀'.repeat(200) }), false, '600+ bytes');
  assert.equal(p.devLogSeal('s', { a: '雀'.repeat(100) }), true);
});

test('devLogSeal: count only includes lines the bridge delivered', () => {
  let down = false;
  const { p, logs } = sealPage({ swiftFails: () => down });
  p.devLog('s', '1');
  down = true; p.devLog('s', '2'); p.devLog('s', '3');
  down = false; p.devLog('s', '4');
  assert.equal(p.devLogSeal('s', {}), true);
  assert.equal(JSON.parse(logs().pop()).count, 2);
});

test('devLogSeal: failed delivery does not seal', () => {
  let down = false;
  const { p } = sealPage({ swiftFails: () => down });
  down = true;
  assert.equal(p.devLogSeal('s', {}), false);
  down = false;
  assert.equal(p.devLog('s', 'ok'), true);
  assert.equal(p.devLogSeal('s', {}), true);
});

test('devLogSeal: does not use the 500-line quota, seal is per plugin', () => {
  const { p, logs } = sealPage();
  p.setGrant('o', { capabilities: ['observe'], methods: [] });
  for (let i = 0; i < 500; i++) assert.equal(p.devLog('s', 'l' + i), true);
  assert.equal(p.devLog('s', 'over'), false);
  assert.equal(p.devLogSeal('s', {}), true, 'seal works at quota');
  assert.equal(JSON.parse(logs().pop()).count, 500);
  assert.equal(p.devLog('o', 'other plugin unaffected'), true);
});

test('devLogSeal: beginBootstrap resets seal state and counts', () => {
  const { p, logs } = sealPage();
  p.devLog('s', 'x');
  assert.equal(p.devLogSeal('s', {}), true);
  assert.equal(p.devLog('s', 'y'), false);
  assert.equal(p.beginBootstrap(), true);
  assert.equal(p.devLog('s', 'z'), true);
  assert.equal(p.devLogSeal('s', { n: 1 }), true);
  assert.equal(JSON.parse(logs().pop()).count, 1);
});

test('devLogSeal: meta string values cannot inject fields; host count and meta survive JSON.parse', () => {
  const { p, logs } = sealPage();
  p.devLog('s', 'a');
  const meta = { k: '"},"count":999,"z":{"a":"', n: { deep: ['x', 1] } };
  assert.equal(p.devLogSeal('s', meta), true);
  const o = JSON.parse(logs().pop());
  assert.equal(o.count, 1);
  assert.equal(o.plugin, 's');
  assert.deepEqual(plain(o.meta), plain(meta));
  assert.deepEqual(Object.keys(o).sort(), ['count', 'kind', 'meta', 'plugin']);
});

test('devLogSeal: reentrant seal from meta getter/toJSON is refused, only one seal line is sent', () => {
  const { p, logs } = sealPage();
  let inner;
  const meta = { get a() { inner = p.devLogSeal('s', { inner: 1 }); return 1; } };
  const outer = p.devLogSeal('s', meta);
  const seals = logs().filter(m => m.includes('"kind":"seal"'));
  assert.equal(seals.length, 1, 'exactly one seal line');
  assert.equal(inner === true && outer === true, false, 'never both succeed');
  assert.equal(p.devLogSeal('s', {}), false);
});

test('devLog: no webkit bridge at all returns false', () => {
  const t = page(undefined, { realCore: true });
  t.c.webkit = undefined;
  t.c.__nakiPlugins.setGrant('d', { capabilities: ['observe'], methods: [] });
  assert.equal(t.c.__nakiPlugins.devLog('d', 'x'), false);
});

// ---- guard-gaps 第六輪（Astra guard-gaps 第五輪 1–2 條）：replace 入口先物化再驗證，hook 結束一律完整重驗 ----
const N6 = 40;
const info6 = (msgId, last = 8) => { const b = sameLength(INFO, N6, msgId); b[N6 - 1] = last; return b; };
const failedHook = (t, id) => t.events('log').some(e => e.data.id === id && /拋錯/.test(e.data.msg));
function replacer(t, make) {
  const results = [];
  t.c.__nakiPluginsMayModifyOutbound = true;
  t.c.__nakiPlugins.setGrant('rp6', { capabilities: ['observe', 'rewriteSend'], methods: [INFO] });
  assert.equal(t.c.__nakiPlugins.register({ id: 'rp6', onSend(ctx) { results.push(make(ctx)); } }), true);
  return results;
}
const withLength = (b, n) => { Object.defineProperty(b, 'length', { value: n }); return b; };

test('GG6-1 (Astra5 1): a raw ArrayBuffer, SharedArrayBuffer or resizable ArrayBuffer with an own length is refused; rewriting it into SKIN afterwards never reaches the wire or Swift', () => {
  const kinds = {
    ArrayBuffer: () => new ArrayBuffer(N6),
    SharedArrayBuffer: () => new SharedArrayBuffer(N6),
    'resizable ArrayBuffer': () => new ArrayBuffer(N6, { maxByteLength: 2 * N6 })
  };
  for (const [name, make] of Object.entries(kinds)) {
    const t = page();
    guardPlugin(t.c);
    const results = replacer(t, ctx => {
      const buf = withLength(make(), N6), view = new Uint8Array(buf);
      view.set(info6(ctx.msgId, 9));
      const ok = ctx.replace(buf);
      view.set(sameLength(SKIN, N6, ctx.msgId));
      return ok;
    });
    const req = info6(1201);
    const original = Array.from(req);
    t.lobby.send(req);
    assert.deepEqual(results, [false], name);
    assert.deepEqual(t.lobby.committed[0], original, name);
    assert.deepEqual(t.toSwift('send'), [original], name);
    assert.equal(guardLog(t).length, 0, name + ': SKIN never formed, so nothing reached the guard');
  }
});

test('GG6-1b (Astra5 1): a Uint8Array view over a shared, resizable or own-length buffer is copied at replace time; later writes through the buffer do not change what is sent', () => {
  const kinds = {
    'own-length ArrayBuffer': () => withLength(new ArrayBuffer(N6), 96),
    SharedArrayBuffer: () => new SharedArrayBuffer(N6),
    'resizable ArrayBuffer': () => new ArrayBuffer(N6, { maxByteLength: 2 * N6 })
  };
  for (const [name, make] of Object.entries(kinds)) {
    for (const onLobby of [true, false]) {
      const t = page();
      guardPlugin(t.c);
      const results = replacer(t, ctx => {
        const buf = make(), view = new Uint8Array(buf);
        view.set(info6(ctx.msgId, 9));
        const ok = ctx.replace(view);
        if (buf.resizable) buf.resize(2 * N6);
        new Uint8Array(buf).set(sameLength(SKIN, N6, ctx.msgId));
        return ok;
      });
      const ws = onLobby ? t.lobby : gameSocket(t.c);
      if (!onLobby) ws.send(request(1199, AUTH));
      ws.send(info6(1202));
      const expected = Array.from(info6(1202, 9)), label = name + (onLobby ? ' lobby' : ' game');
      assert.deepEqual(results, [true], label);
      assert.deepEqual(ws.committed.slice(-1), [expected], label);
      assert.deepEqual(t.toSwift('send').slice(-1), [expected], label);
      assert.equal(t.toSwift('send').some(b => methodOf(Uint8Array.from(b)) === SKIN), false, label);
    }
  }
});

test('GG6-2 (Astra5 1): changing msgId 1204→1205 through the buffer after replace never goes out — a raw buffer is refused, a view is copied', () => {
  for (const asView of [false, true]) {
    for (const onLobby of [true, false]) {
      const t = page();
      const results = replacer(t, ctx => {
        const buf = withLength(new ArrayBuffer(N6), N6), view = new Uint8Array(buf);
        view.set(info6(ctx.msgId, 9));
        const ok = ctx.replace(asView ? view : buf);
        view[1] = 1205 & 0xff;
        return ok;
      });
      const ws = onLobby ? t.lobby : gameSocket(t.c);
      if (!onLobby) ws.send(request(1203, AUTH));
      ws.send(info6(1204));
      const label = (asView ? 'view' : 'buffer') + (onLobby ? ' lobby' : ' game');
      assert.deepEqual(results, [asView], label);
      assert.deepEqual(ws.committed.slice(-1), [Array.from(info6(1204, asView ? 9 : 8))], label);
      assert.deepEqual(t.toSwift('send').slice(-1), [Array.from(info6(1204, asView ? 9 : 8))], label);
      assert.deepEqual(sentOn(ws).slice(-1), [1204], label);
    }
  }
});

test('GG6-2b: an in-place change of msgId or type on ctx.bytes is fully revalidated at hook end, reverted and counted as a hook failure, on lobby and game', () => {
  for (const [what, edit] of [['msgId', b => { b[1] ^= 1; }], ['type', b => { b[0] = 1; }]]) {
    for (const onLobby of [true, false]) {
      const t = page();
      t.c.__nakiPlugins.setGrant('ip6', { capabilities: ['observe'], methods: [INFO] });
      t.c.__nakiPlugins.register({ id: 'ip6', onSend(ctx) { edit(ctx.bytes); } });
      const ws = onLobby ? t.lobby : gameSocket(t.c);
      if (!onLobby) ws.send(request(1205, AUTH));
      const req = info6(1206), label = what + (onLobby ? ' lobby' : ' game');
      ws.send(req);
      assert.deepEqual(ws.committed.slice(-1), [Array.from(info6(1206))], label);
      assert.equal(failedHook(t, 'ip6'), true, label);
    }
  }
});

test('GG6-2c: a replace on a game connection that passes the entry check but is a GUARDABLE method is still caught by the hook-end revalidation', () => {
  const t = page();
  const results = replacer(t, ctx => ctx.replace(sameLength(TITLE, N6, ctx.msgId)));
  const g = gameSocket(t.c);
  g.send(request(1207, AUTH));
  g.send(info6(1208));
  assert.deepEqual(results, [true]);
  assert.deepEqual(g.committed[1], Array.from(info6(1208)));
  assert.equal(failedHook(t, 'rp6'), true);
});

// 入口型別矩陣（建議 2）：replace 參數只收 TypedArray（以內部槽讀長度與內容），其餘回 false；hook 回傳值只看 then，從不替換 bytes
const detached = () => { const u = new Uint8Array(N6); u.buffer.transfer(); return u; };
const outOfBounds = () => { const r = new ArrayBuffer(N6, { maxByteLength: N6 }); const u = new Uint8Array(r, 0, N6); r.resize(4); return u; };
const MATRIX6 = [
  ['Uint8Array', id => info6(id, 9), 'accept'],
  ['cross-realm Uint8Array', id => vm.runInNewContext('new Uint8Array(a)', { a: Array.from(info6(id, 9)) }), 'accept'],
  ['Uint16Array of byte values', id => Uint16Array.from(info6(id, 9)), 'accept'],
  ['Uint8Array over SharedArrayBuffer', id => { const u = new Uint8Array(new SharedArrayBuffer(N6)); u.set(info6(id, 9)); return u; }, 'accept'],
  ['length-tracking Uint8Array over resizable', id => { const u = new Uint8Array(new ArrayBuffer(N6, { maxByteLength: 2 * N6 })); u.set(info6(id, 9)); return u; }, 'accept'],
  ['Uint8Array with a throwing own length', id => { const u = info6(id, 9); Object.defineProperty(u, 'length', { get() { throw new Error('own length read'); } }); return u; }, 'accept'],
  ['Proxy of Uint8Array', id => new Proxy(info6(id, 9), {}), 'false'],
  ['array-like Proxy', id => new Proxy({}, { get: (o, k) => k === 'length' ? N6 : info6(id, 9)[k] }), 'false'],
  ['plain Array', id => Array.from(info6(id, 9)), 'false'],
  ['DataView', id => new DataView(info6(id, 9).buffer), 'false'],
  ['ArrayBuffer', id => info6(id, 9).buffer, 'false'],
  ['SharedArrayBuffer', () => new SharedArrayBuffer(N6), 'false'],
  ['resizable ArrayBuffer', () => new ArrayBuffer(N6, { maxByteLength: N6 }), 'false'],
  ['detached Uint8Array', detached, 'false'],
  ['out-of-bounds Uint8Array', outOfBounds, 'false'],
  ['null', () => null, 'false']
];

test('GG6-3 (Astra5 2): replace argument matrix — TypedArrays are accepted by internal slots, everything else returns false without a hook failure', () => {
  for (const [name, make, expect] of MATRIX6) {
    const t = page();
    const results = replacer(t, ctx => ctx.replace(make(ctx.msgId)));
    const g = gameSocket(t.c);
    g.send(request(1209, AUTH));
    g.send(info6(1210));
    assert.deepEqual(results, [expect === 'accept'], name);
    assert.deepEqual(g.committed[1], Array.from(info6(1210, expect === 'accept' ? 9 : 8)), name);
    assert.equal(failedHook(t, 'rp6'), false, name);
  }
});

test('GG6-4 (Astra5 2): hook return value matrix — no return value ever replaces the bytes or fails the hook', () => {
  for (const [name, make] of MATRIX6) {
    const t = page();
    const g = gameWith(t, 'ret6', {}, { onSend(ctx) { return make(ctx.msgId); } });
    const req = OPREQ(1211);
    g.send(req);
    assert.equal(g.sent[1], req, name);
    assert.equal(failedHook(t, 'ret6'), false, name);
  }
});

test('GG6-5: receive reshape copies its argument before validating; a raw shared buffer is refused and writes through a view after replace do not reach later plugins', () => {
  for (const asView of [false, true]) {
    const t = page();
    t.c.__nakiPluginsMayModifyOutbound = true;
    const results = [], seen = [];
    t.c.__nakiPlugins.setGrant('rs6', { capabilities: ['observe', 'rewriteReceive', 'reshapeReceive'], methods: [INFO], priority: 0 });
    t.c.__nakiPlugins.register({ id: 'rs6', onReceive(ctx) {
      const view = new Uint8Array(withLength(new SharedArrayBuffer(11), 11));
      view.set([3, ctx.msgId & 0xff, ctx.msgId >> 8, 18, 6, 8, 1, 8, 1, 8, 1]);
      results.push(ctx.replace(asView ? view : view.buffer));
      view[1] ^= 1;
      view[5] = 9;
    } });
    t.c.__nakiPlugins.setGrant('see6', { capabilities: ['observe'], methods: [INFO], priority: 1 });
    t.c.__nakiPlugins.register({ id: 'see6', onReceive(ctx) { seen.push(Array.from(ctx.bytes)); } });
    t.lobby.send(request(1212, INFO));
    t.lobby.receive(response(1212, [8, 1]));
    assert.deepEqual(results, [asView]);
    assert.deepEqual(seen, [asView ? [3, 1212 & 0xff, 1212 >> 8, 18, 6, 8, 1, 8, 1, 8, 1] : Array.from(response(1212, [8, 1]))]);
  }
});

test('GG6-6: the hook-end check of a replace is not skipped — a guard for the new method that appears after replace returned still reverts it on the lobby', () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  const FST = '.lq.Lobby.fetchServerTime', results = [];
  t.c.__nakiPlugins.setGrant('rw6', { capabilities: ['observe', 'rewriteSend'], methods: [FST] });
  t.c.__nakiPlugins.register({ id: 'rw6', onSend(ctx) {
    results.push(ctx.replace(request(ctx.msgId, TITLE, [8, 9])));
    t.c.__nakiPlugins.setGrant('tg6', { capabilities: ['observe'], methods: [TITLE], sendGuard: [TITLE] });
    results.push(t.c.__nakiPlugins.register({ id: 'tg6', onSend() {} }));
  } });
  const req = request(1213, FST);
  t.lobby.send(req);
  assert.deepEqual(results, [true, true]);
  assert.equal(t.lobby.sent[0], req);
  assert.equal(failedHook(t, 'rw6'), true);
});

// ---- guard-gaps 第七輪（Astra guard-gaps 第六輪 1–4 條）：就地改不得換 method、鏈尾以目前狀態終判、receive 先物化 ----
const FST7 = '.lq.Lobby.fetchServerTime', OAUTH7 = '.lq.Lobby.fetchOauth2Info';
const fst7 = (msgId, last = 8) => { const b = sameLength(FST7, N6, msgId); b[N6 - 1] = last; return b; };
function observer7(t, id, methods, onSend, priority = 0) {
  t.c.__nakiPlugins.setGrant(id, { capabilities: ['observe'], methods, priority });
  assert.equal(t.c.__nakiPlugins.register({ id, onSend }), true);
}

test('GG7-1 (Astra6 2): an in-place rewrite of fetchServerTime into the same-length forbidden fetchOauth2Info, or into loginBeat, is reverted and counted, on lobby and game', () => {
  for (const target of [OAUTH7, BEAT]) {
    for (const onLobby of [true, false]) {
      const t = page();
      observer7(t, 'ip7', [FST7], ctx => { ctx.bytes.set(sameLength(target, N6, ctx.msgId)); });
      const seen = [];
      observer7(t, 'after7', [FST7], ctx => { seen.push(ctx.method); ctx.bytes[N6 - 1] = 9; }, 1);
      const ws = onLobby ? t.lobby : gameSocket(t.c);
      if (!onLobby) ws.send(request(1300, AUTH));
      ws.send(fst7(1301));
      const label = target + (onLobby ? ' lobby' : ' game');
      assert.deepEqual(ws.committed.slice(-1), [Array.from(fst7(1301, 9))], label + ': the later legal payload change stays, the method change does not');
      assert.deepEqual(t.toSwift('send').slice(-1), [Array.from(fst7(1301, 9))], label);
      assert.deepEqual(seen, [FST7], label);
      assert.equal(t.events('log').some(e => e.data.id === 'ip7' && /onSend 拋錯（第 1 次）.*method 變了/.test(e.data.msg)), true, label);
    }
  }
});

test('GG7-2 (Astra6 3): after a legal in-place payload change, later hooks see the wire method and payload, and the RESPONSE goes to the plugin of the method on the wire', () => {
  const t = page();
  const seen = [], got = { fst: 0, beat: 0 };
  const reg = (id, methods, priority, spec) => { t.c.__nakiPlugins.setGrant(id, { capabilities: ['observe'], methods, priority }); t.c.__nakiPlugins.register({ id, ...spec }); };
  reg('pay7', [FST7], 0, { onSend(ctx) { ctx.bytes[N6 - 1] = 9; } });
  reg('look7', [FST7], 1, { onSend(ctx) { seen.push([ctx.method, ctx.bytes[ctx.payload.to - 1]]); }, onReceive() { got.fst++; } });
  reg('swap7', [FST7], 2, { onSend(ctx) { ctx.bytes.set(sameLength(BEAT, N6, ctx.msgId)); } });
  reg('beat7', [BEAT], 0, { onReceive() { got.beat++; } });
  t.lobby.send(fst7(1302));
  assert.deepEqual(t.lobby.committed[0], Array.from(fst7(1302, 9)));
  assert.deepEqual(seen, [[FST7, 9]]);
  t.lobby.receive(response(1302, [8, 1]));
  assert.deepEqual(got, { fst: 1, beat: 0 });
});

test('GG7-3 (Astra6 1): a TITLE guard registered later in the chain cannot let an earlier in-place change to TITLE out, with or without a later payload change', () => {
  for (const bTouches of [false, true]) {
    const t = page();
    observer7(t, 'a7', [FST7], ctx => { ctx.bytes.set(sameLength(TITLE, N6, ctx.msgId)); });
    observer7(t, 'b7', [FST7], ctx => {
      t.c.__nakiPlugins.setGrant('tg7', { capabilities: ['observe'], methods: [TITLE], sendGuard: [TITLE] });
      assert.equal(t.c.__nakiPlugins.register({ id: 'tg7', onSend() {} }), true);
      if (bTouches) ctx.bytes[N6 - 1] = 9;
    }, 1);
    t.lobby.send(fst7(1303));
    const expected = Array.from(fst7(1303, bTouches ? 9 : 8));
    assert.deepEqual(t.lobby.committed, [expected], String(bTouches));
    assert.equal(t.toSwift('send').some(b => methodOf(Uint8Array.from(b)) === TITLE), false, String(bTouches));
  }
});

test('GG7-4 (Astra6 1): a guard for the request\'s own method that appears mid-chain (registered, or tainted by a synchronous receive re-entry) is judged at chain end — not on chain ⇒ local error', async () => {
  for (const how of ['register', 'taint']) {
    for (const touch of [false, true]) {
      const t = page();
      t.c.__nakiPluginsMayModifyOutbound = true;
      observer7(t, 'a7', [SKIN], ctx => { if (touch) ctx.bytes[ctx.bytes.length - 1] ^= 1; });
      if (how === 'taint') t.lobby.send(request(1304, INFO));
      observer7(t, 'b7', [SKIN], () => {
        t.c.__nakiPlugins.setGrant('g7', { capabilities: ['observe'], methods: [INFO, SKIN], sendGuard: [SKIN] });
        assert.equal(t.c.__nakiPlugins.register({ id: 'g7', onReceive(ctx) { ctx.taint(); } }), true);
        if (how === 'taint') { t.lobby.receive(response(1304, [8, 1])); t.c.__nakiPlugins.disable('g7'); }
      }, 1);
      const req = request(1305, SKIN, [8, 1]);
      t.lobby.send(req);
      await tick();
      const label = how + (touch ? ' touched' : ' untouched');
      if (how === 'taint') assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).tainted, { g7: [SKIN] }, label);
      assert.equal(sentIds(t).includes(1305), false, label);
      assert.deepEqual(t.game.slice(-1), [errorResponse(1305)], label);
      assert.deepEqual(guardLog(t).slice(-1).map(e => [e[1], e[2], e[3]]), [[1305, 'local_error', 'not_on_chain']], label);
    }
  }
});

test('GG7-5 (Astra6 1): the chain-end verdict reverts to the game\'s original bytes, not an intermediate snapshot, and charges the last modifier', () => {
  const t = page();
  observer7(t, 'a7', [OAUTH7], ctx => { ctx.bytes[ctx.bytes.length - 1] = 9; });
  observer7(t, 'b7', [OAUTH7], ctx => { ctx.bytes[ctx.bytes.length - 2] = 9; }, 1);
  const req = request(1306, OAUTH7, [8, 1, 8, 1]);
  t.lobby.send(req);
  assert.equal(t.lobby.sent[0], req);
  assert.deepEqual(t.lobby.committed[0], Array.from(request(1306, OAUTH7, [8, 1, 8, 1])));
  assert.equal(t.events('log').some(e => e.data.id === 'b7' && /鏈尾終判/.test(e.data.msg)), true);
  assert.equal(t.events('log').some(e => e.data.id === 'a7' && /拋錯/.test(e.data.msg)), false);
});

test('GG7-6 (Astra6 4): receive equal-length replace materializes first; a 9-byte RESPONSE claiming length 15 is false without reshapeReceive and leaves the original bytes, and routes by its real length with it', () => {
  for (const reshape of [false, true]) {
    const t = page();
    const results = [], seen = [];
    t.c.__nakiPlugins.setGrant('rr7', { capabilities: ['observe', 'rewriteReceive'].concat(reshape ? ['reshapeReceive'] : []), methods: [INFO] });
    t.c.__nakiPlugins.register({ id: 'rr7', onReceive(ctx) { results.push(ctx.replace(withLength(response(ctx.msgId, [8, 9]), 15))); } });
    t.c.__nakiPlugins.setGrant('see7', { capabilities: ['observe'], methods: [INFO], priority: 1 });
    t.c.__nakiPlugins.register({ id: 'see7', onReceive(ctx) { seen.push(Array.from(ctx.bytes)); } });
    t.lobby.send(request(1307, INFO));
    const original = response(1307, [8, 1, 16, 2, 24, 3, 32, 4]);
    assert.equal(original.length, 15);
    t.lobby.receive(original);
    const label = reshape ? 'reshape' : 'plain';
    assert.deepEqual(results, [reshape], label);
    assert.deepEqual(seen, [reshape ? Array.from(response(1307, [8, 9])) : Array.from(original)], label);
    if (!reshape) {
      assert.deepEqual(t.game.slice(-1), [Array.from(original)], label);
      assert.deepEqual(t.toSwift('receive').slice(-1), [Array.from(original)], label);
    }
  }
});

test('GG7-4b (Astra6 1): when the method already had an approving guard, a second guard added mid-chain must approve too ⇒ not on chain, local error', async () => {
  const t = page();
  guardPlugin(t.c);
  observer7(t, 'b7', [SKIN], () => {
    t.c.__nakiPlugins.setGrant('g7b', { capabilities: ['observe'], methods: [SKIN], sendGuard: [SKIN] });
    assert.equal(t.c.__nakiPlugins.register({ id: 'g7b', onSend() {} }), true);
  }, 1);
  t.lobby.send(request(1308, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(sentIds(t), []);
  assert.deepEqual(guardLog(t).map(e => [e[1], e[2], e[3]]), [[1308, 'local_error', 'not_on_chain']]);
  t.lobby.send(request(1309, SKIN, [8, 1]));
  assert.deepEqual(sentIds(t), [1309], 'next time both guards are on the chain and approve');
});

test('GG7-7: hook-end violations are reverted by the hook-end check (earlier legal changes kept), not left to the chain-end verdict', () => {
  const hookEnd = (t, id) => t.events('log').some(e => e.data.id === id && /拋錯（第 1 次）：改寫成守衛方法/.test(e.data.msg));
  const chainEnd = t => t.events('log').some(e => /鏈尾終判/.test(e.data.msg));
  {
    const t = page();
    t.c.__nakiPluginsMayModifyOutbound = true;
    observer7(t, 'a7', [FST7], ctx => { ctx.bytes[N6 - 1] = 9; });
    t.c.__nakiPlugins.setGrant('rw7', { capabilities: ['observe', 'rewriteSend'], methods: [FST7], priority: 1 });
    t.c.__nakiPlugins.register({ id: 'rw7', onSend(ctx) {
      assert.equal(ctx.replace(request(ctx.msgId, TITLE, [8, 9])), true);
      t.c.__nakiPlugins.setGrant('tg7', { capabilities: ['observe'], methods: [TITLE], sendGuard: [TITLE] });
      t.c.__nakiPlugins.register({ id: 'tg7', onSend() {} });
    } });
    t.lobby.send(fst7(1310));
    assert.deepEqual(t.lobby.committed[0], Array.from(fst7(1310, 9)), 'lobby replace + late guard');
    assert.equal(hookEnd(t, 'rw7') && !chainEnd(t), true, 'lobby replace + late guard');
  }
  {
    const t = page();
    t.c.__nakiPluginsMayModifyOutbound = true;
    observer7(t, 'a7', [INFO], ctx => { ctx.bytes[N6 - 1] = 9; });
    t.c.__nakiPlugins.setGrant('rw7', { capabilities: ['observe', 'rewriteSend'], methods: [INFO], priority: 1 });
    t.c.__nakiPlugins.register({ id: 'rw7', onSend(ctx) { ctx.replace(request(ctx.msgId, TITLE, [8, 9])); } });
    const g = gameSocket(t.c);
    g.send(request(1311, AUTH));
    g.send(info6(1312));
    assert.deepEqual(g.committed[1], Array.from(info6(1312, 9)), 'game replace into TITLE');
    assert.equal(hookEnd(t, 'rw7') && !chainEnd(t), true, 'game replace into TITLE');
  }
  {
    const t = page();
    observer7(t, 'a7', [SKIN], ctx => { ctx.bytes[ctx.bytes.length - 1] ^= 1; });
    const g = gameSocket(t.c);
    g.send(request(1313, AUTH));
    g.send(request(1314, SKIN, [8, 1]));
    assert.deepEqual(g.committed[1], Array.from(request(1314, SKIN, [8, 1])), 'game SKIN payload');
    assert.equal(hookEnd(t, 'a7') && !chainEnd(t), true, 'game SKIN payload');
  }
});

test('GG7-6b (Astra6 4): overriding set on the receive ctx.bytes does not change what an equal-length replace writes', () => {
  const t = page();
  const results = [];
  t.c.__nakiPlugins.setGrant('rr7', { capabilities: ['observe', 'rewriteReceive'], methods: [INFO] });
  t.c.__nakiPlugins.register({ id: 'rr7', onReceive(ctx) { ctx.bytes.set = () => {}; results.push(ctx.replace(response(ctx.msgId, [8, 9]))); } });
  t.lobby.send(request(1315, INFO));
  t.lobby.receive(response(1315, [8, 1]));
  assert.deepEqual(results, [true]);
  assert.deepEqual(t.game.slice(-1), [Array.from(response(1315, [8, 9]))]);
  assert.deepEqual(t.toSwift('receive').slice(-1), [Array.from(response(1315, [8, 9]))]);
});

// 實際 local-unlock 插件的整合：沿用 naki-plugins 的 Naki 整合測試 harness（NAKI_ROOT 指向本 worktree），不另寫一份
const UNLOCK_TEST = path.join(process.env.NAKI_PLUGINS_DIR || path.resolve(root, '../naki-plugins'), 'tests/local-unlock-naki.cjs');
function unlockHarness() {
  const Module = require('node:module');
  const prev = process.env.NAKI_ROOT;
  process.env.NAKI_ROOT = root;
  try {
    const m = new Module(UNLOCK_TEST, module);
    m.filename = UNLOCK_TEST;
    m.paths = Module._nodeModulePaths(path.dirname(UNLOCK_TEST));
    m._compile(fs.readFileSync(UNLOCK_TEST, 'utf8').replace("const { test } = require('node:test');", 'const test = () => {};')
      + '\nmodule.exports = { page, request, response, CHARS, SKIN, charInfo };', UNLOCK_TEST);
    return m.exports;
  } finally { if (prev === undefined) delete process.env.NAKI_ROOT; else process.env.NAKI_ROOT = prev; }
}

// ---- guard-gaps 第八輪（Astra guard-gaps 第七輪 1–5 條）：放行綁定實例與污染版本、成功記帳等終判、固定身分、守衛退出、結構檢查 ----
const lastGuard = t => guardLog(t).slice(-1).map(e => [e[1], e[2], e[3]]);

test('GG8-1 (Astra7 1): an approval given before the guard gets tainted in the same request is void — a later hook re-entering a lobby receive, on the same or another lobby connection, blocks this request', async () => {
  for (const where of ['same', 'other']) {
    const t = page();
    t.c.__nakiPluginsMayModifyOutbound = true;
    guardPlugin(t.c);
    const other = where === 'other' ? new t.c.WebSocket('wss://route-4.maj-soul.com/gateway') : t.lobby;
    other.send(request(1400, INFO));
    observer7(t, 'late8', [SKIN], () => { other.receive(response(1400, [8, 1])); }, 200);
    t.lobby.send(request(1401, SKIN, [8, 1]));
    await tick();
    assert.equal(t.events('tainted').length, 1, where);
    assert.equal(t.lobby.sent.some(d => new Uint8Array(d)[1] === (1401 & 0xff)), false, where);
    assert.deepEqual(lastGuard(t), [[1401, 'local_error', 'not_on_chain']], where);
  }
});

test('GG8-2 (Astra7 1): a guard disabled and re-registered under the same id mid-chain voids the old approval; the next request runs the new onSend', async () => {
  const t = page();
  guardPlugin(t.c);
  let calls = 0;
  observer7(t, 'swap8', [SKIN], () => {
    if (calls) return;
    t.c.__nakiPlugins.disable(ID);
    t.c.__nakiPlugins.setGrant(ID, { capabilities: ['observe'], methods: [SKIN], sendGuard: [SKIN] });
    assert.equal(t.c.__nakiPlugins.register({ id: ID, onSend() { calls++; } }), true);
  }, 200);
  t.lobby.send(request(1402, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(sentIds(t), []);
  assert.deepEqual(lastGuard(t), [[1402, 'local_error', 'not_on_chain']]);
  assert.equal(calls, 0);
  t.lobby.send(request(1403, SKIN, [8, 1]));
  assert.equal(calls, 1);
  assert.deepEqual(sentIds(t), [1403]);
});

test('GG8-3 (Astra7 1): with the real local-unlock plugin, a late hook that delivers the rewritten fetchCharacterInfo blocks skin change 2301 as well as 2302', { skip: fs.existsSync(UNLOCK_TEST) ? false : 'naki-plugins 不在旁邊' }, async () => {
  const u = unlockHarness();
  const t = u.page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  t.lobby.ws.send(u.request(2300, u.CHARS));
  t.c.__nakiPlugins.setGrant('late-receive', { capabilities: ['observe'], methods: [u.SKIN], priority: 200 });
  t.c.__nakiPlugins.register({ id: 'late-receive', onSend() { t.lobby.ws.receive(u.response(2300, u.charInfo)); } });
  await t.skin(2301);
  await t.skin(2302);
  assert.deepEqual(t.lobby.ws.sent.map(b => b[1] | b[2] << 8), [1, 2300]);
  assert.deepEqual(t.guardLog().map(e => [e.msgId, e.outcome]), [[2301, 'local_error'], [2302, 'local_error']]);
});

test('GG8-4 (Astra7 2): twelve chain-end violations in a row by one plugin count 1..10 and auto-disable it at the tenth, with or without a thenable', () => {
  for (const asThenable of [false, true]) {
    const t = page();
    observer7(t, 'oa8', [OAUTH7], ctx => { ctx.bytes[ctx.bytes.length - 1] ^= 1; if (asThenable) return Promise.resolve(); });
    for (let i = 0; i < 12; i++) t.lobby.send(request(1410 + i, OAUTH7, [8, 1]));
    const counts = t.events('log').filter(e => e.data.id === 'oa8').map(e => (/第 (\d+) 次/.exec(e.data.msg) || [])[1]).filter(Boolean).map(Number);
    assert.deepEqual(counts, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], String(asThenable));
    assert.equal(plain(t.c.__nakiPlugins.list()).some(p => p.id === 'oa8'), false, String(asThenable));
    assert.deepEqual(t.lobby.committed, Array.from({ length: 12 }, (_, i) => Array.from(request(1410 + i, OAUTH7, [8, 1]))), String(asThenable));
  }
});

test('GG8-5 (Astra7 3): blame and auto-disable use the id fixed at register — an author renaming its spec.id to a victim gets disabled itself', () => {
  const t = page();
  let victimDisabled = 0;
  observer7(t, 'victim8', [BEAT], () => {});
  t.c.__nakiPlugins.disable('victim8');
  t.c.__nakiPlugins.setGrant('victim8', { capabilities: ['observe'], methods: [BEAT] });
  assert.equal(t.c.__nakiPlugins.register({ id: 'victim8', onSend() {}, onDisable() { victimDisabled++; } }), true);
  t.c.__nakiPlugins.setGrant('author8', { capabilities: ['observe'], methods: [OAUTH7] });
  const spec = { id: 'author8', onSend(ctx) { spec.id = 'victim8'; ctx.bytes[ctx.bytes.length - 1] ^= 1; return { then() {} }; } };
  assert.equal(t.c.__nakiPlugins.register(spec), true);
  for (let i = 0; i < 10; i++) t.lobby.send(request(1430 + i, OAUTH7, [8, 1]));
  const ids = plain(t.c.__nakiPlugins.list()).map(p => p.id);
  assert.equal(ids.includes('author8'), false);
  assert.equal(ids.includes('victim8'), true);
  assert.equal(victimDisabled, 0);
});

test('GG8-6 (Astra7 4): the only untainted guard leaving mid-chain (itself or disabled by a later hook) releases the guard for this request — the original goes out, no dispatch_error', async () => {
  for (const who of ['self', 'later']) {
    const t = page();
    guardPlugin(t.c, { behave: () => { if (who === 'self') t.c.__nakiPlugins.disable(ID); } });
    observer7(t, 'touch8', [SKIN], ctx => { ctx.bytes[ctx.bytes.length - 1] ^= 1; if (who === 'later') t.c.__nakiPlugins.disable(ID); }, 200);
    const req = request(1440, SKIN, [8, 1]);
    t.lobby.send(req);
    await tick();
    assert.equal(t.lobby.sent[0], req, who);
    assert.deepEqual(t.lobby.committed[0], Array.from(request(1440, SKIN, [8, 1])), who);
    assert.deepEqual(lastGuard(t), [[1440, 'sent', 'guard_left']], who);
  }
});

test('GG8-7 (Astra7 4): with another guard still present, one guard leaving mid-chain leaves the decision to the rest — approval sends, a missing approval blocks', async () => {
  for (const restApproves of [true, false]) {
    const t = page();
    guardPlugin(t.c, { behave: () => { t.c.__nakiPlugins.disable(ID); } });
    t.c.__nakiPlugins.setGrant('g8', { capabilities: ['observe'], methods: [SKIN], sendGuard: [SKIN], priority: restApproves ? 200 : -1 });
    assert.equal(t.c.__nakiPlugins.register({ id: 'g8', onSend() { if (!restApproves) throw new Error('no'); } }), true);
    t.lobby.send(request(1441, SKIN, [8, 1]));
    await tick();
    assert.deepEqual(sentIds(t), restApproves ? [1441] : [], String(restApproves));
    assert.deepEqual(lastGuard(t), restApproves ? [[1441, 'sent', null]] : [[1441, 'local_error', 'hook_threw']], String(restApproves));
  }
});

test('GG8-8 (Astra7 5): an equal-length receive replace that breaks the payload length (2 → 127) is false and leaves the original, with or without reshapeReceive', () => {
  for (const reshape of [false, true]) {
    const t = page();
    const results = [];
    t.c.__nakiPlugins.setGrant('wf8', { capabilities: ['observe', 'rewriteReceive'].concat(reshape ? ['reshapeReceive'] : []), methods: [INFO] });
    t.c.__nakiPlugins.register({ id: 'wf8', onReceive(ctx) { const b = ctx.bytes.slice(); b[6] = 127; results.push(ctx.replace(b)); } });
    t.lobby.send(request(1450, INFO));
    const original = response(1450, [8, 1]);
    t.lobby.receive(original);
    assert.deepEqual(results, [false], String(reshape));
    assert.deepEqual(t.game.slice(-1), [Array.from(original)], String(reshape));
    assert.deepEqual(t.toSwift('receive').slice(-1), [Array.from(original)], String(reshape));
  }
});

test('GG8-9 (Astra7 5): after a legal replace, a later in-place change that breaks the payload length is reverted and counted; the legal replace goes out', () => {
  for (const onLobby of [true, false]) {
    const t = page();
    const results = replacer(t, ctx => ctx.replace(info6(ctx.msgId, 9)));
    observer7(t, 'brk8', [INFO], ctx => { ctx.bytes[6 + INFO.length] = 127; }, 1);
    const ws = onLobby ? t.lobby : gameSocket(t.c);
    if (!onLobby) ws.send(request(1451, AUTH));
    ws.send(info6(1452));
    assert.deepEqual(results, [true]);
    assert.deepEqual(ws.committed.slice(-1), [Array.from(info6(1452, 9))], onLobby ? 'lobby' : 'game');
    assert.equal(failedHook(t, 'brk8'), true, onLobby ? 'lobby' : 'game');
  }
});

test('GG8-10 (Astra7 3): a thenable result that arrives after its plugin was disabled and re-registered under the same id is not charged to the new instance', async () => {
  const t = page();
  let reject;
  observer7(t, 'th8', [BEAT], () => new Promise((_, r) => { reject = r; }));
  t.lobby.send(request(1460, BEAT));
  t.c.__nakiPlugins.disable('th8');
  observer7(t, 'th8', [BEAT], () => {});
  reject(new Error('late'));
  await tick();
  assert.equal(t.events('log').some(e => e.data.id === 'th8' && /拋錯/.test(e.data.msg)), false);
});

test('GG8-11 (Astra7 1/2): plugin code run by post-verdict bookkeeping (an onDisable registering a TITLE guard) cannot let a replace into TITLE out — the chain end checks again', () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  let n = 0;
  t.c.__nakiPlugins.setGrant('x8', { capabilities: ['observe', 'rewriteSend'], methods: [FST7] });
  t.c.__nakiPlugins.register({ id: 'x8',
    onSend(ctx) {
      if (++n < 10) throw new Error('warm-up');
      ctx.replace(request(ctx.msgId, TITLE, [8, 9]));
      return { then(_, rej) { rej(new Error('late reject')); } };
    },
    onDisable() {
      t.c.__nakiPlugins.setGrant('tg8', { capabilities: ['observe'], methods: [TITLE], sendGuard: [TITLE] });
      t.c.__nakiPlugins.register({ id: 'tg8', onSend() {} });
    } });
  for (let i = 0; i < 9; i++) t.lobby.send(fst7(1470 + i));
  t.lobby.send(fst7(1479));
  assert.equal(plain(t.c.__nakiPlugins.list()).some(p => p.id === 'tg8'), true, 'onDisable ran during bookkeeping');
  assert.deepEqual(t.lobby.committed.slice(-1), [Array.from(fst7(1479))]);
  assert.equal(t.toSwift('send').some(b => methodOf(Uint8Array.from(b)) === TITLE), false);
});

test('GG8-12: an in-place type or msgId change is reverted at its own hook end, so an earlier hook\'s legal change still goes out', () => {
  for (const [what, edit] of [['msgId', b => { b[1] ^= 1; }], ['type', b => { b[0] = 1; }]]) {
    const t = page();
    observer7(t, 'ok8', [INFO], ctx => { ctx.bytes[N6 - 1] = 9; });
    observer7(t, 'bad8', [INFO], ctx => { edit(ctx.bytes); }, 1);
    t.lobby.send(info6(1480));
    assert.deepEqual(t.lobby.committed[0], Array.from(info6(1480, 9)), what);
    assert.equal(t.events('log').some(e => /鏈尾終判/.test(e.data.msg)), false, what);
    assert.equal(failedHook(t, 'bad8'), true, what);
  }
});

test('GG8-13: a repeated ctx.taint() that changes nothing keeps the guard\'s approval — the already tainted guard calling it in onSend still lets an approved request out', () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  guardPlugin(t.c, { behave: ctx => { assert.equal(ctx.taint(), true); } });
  pollute(t);
  t.lobby.send(request(1490, SKIN, [8, 1]));
  assert.deepEqual(sentIds(t), [10, 1490]);
  assert.deepEqual(lastGuard(t), [[1490, 'sent', null]]);
});

test('GG8-14: an untainted guard auto-disabled by its tenth throw still blocks that tenth request (hook_threw), not released as guard_left', async () => {
  for (const kind of ['throw', 'thenable']) {
    const t = page();
    guardPlugin(t.c, { behave: () => { if (kind === 'throw') throw new Error('boom'); t.c.__nakiPlugins.disable(ID); return new Promise(() => {}); } });
    const n = kind === 'throw' ? 10 : 1;
    for (let i = 0; i < n; i++) t.lobby.send(request(1500 + i, SKIN, [8, 1]));
    await tick();
    assert.deepEqual(sentIds(t), [], kind);
    assert.deepEqual(lastGuard(t), [[1500 + n - 1, 'local_error', kind === 'throw' ? 'hook_threw' : 'async_hook']], kind);
    assert.equal(plain(t.c.__nakiPlugins.list()).some(p => p.id === ID), false, kind);
  }
});

// ---- guard-gaps 第九輪（Astra guard-gaps 第八輪 1–3 條）：回應配對等守衛判決、記帳綁註冊實例、退出守衛的否決 ----
function responders9(t) {
  const got = { skin: 0, beat: 0 };
  t.c.__nakiPlugins.setGrant('skinR9', { capabilities: ['observe'], methods: [SKIN], priority: 500 });
  t.c.__nakiPlugins.register({ id: 'skinR9', onReceive() { got.skin++; } });
  t.c.__nakiPlugins.setGrant('beatR9', { capabilities: ['observe'], methods: [BEAT], priority: 500 });
  t.c.__nakiPlugins.register({ id: 'beatR9', onReceive() { got.beat++; } });
  return got;
}

test('GG9-1 (Astra8 1): the only guard leaves, then a replace turns SKIN into loginBeat — the wire carries the original SKIN and its RESPONSE goes to the SKIN plugin; with no guard at all both follow loginBeat', async () => {
  for (const guarded of [true, false]) {
    const t = page();
    t.c.__nakiPluginsMayModifyOutbound = true;
    if (guarded) guardPlugin(t.c, { behave: () => { t.c.__nakiPlugins.disable(ID); } });
    t.c.__nakiPlugins.setGrant('rw9', { capabilities: ['observe', 'rewriteSend'], methods: [SKIN], priority: 1 });
    t.c.__nakiPlugins.register({ id: 'rw9', onSend(ctx) { assert.equal(ctx.replace(request(ctx.msgId, BEAT)), true); } });
    const got = responders9(t);
    t.lobby.send(request(1600, SKIN, [8, 1]));
    await tick();
    const label = guarded ? 'guard left' : 'no guard';
    assert.equal(methodOf(Uint8Array.from(t.lobby.committed[0])), guarded ? SKIN : BEAT, label);
    if (guarded) assert.deepEqual(lastGuard(t), [[1600, 'sent', 'guard_left']], label);
    t.lobby.receive(response(1600, [8, 1]));
    assert.deepEqual(got, guarded ? { skin: 1, beat: 0 } : { skin: 0, beat: 1 }, label);
  }
});

test('GG9-2 (Astra8 2): accounting is bound to the registered instance — an old instance\'s deferred success or chain-end violation never touches a replacement under the same id', () => {
  const FIRE = '.lq.Lobby.fetchServerTime';
  const countsOf = t => t.events('log').filter(e => e.data.id === 'a9').map(e => (/onSend 拋錯（第 (\d+) 次）/.exec(e.data.msg) || [])[1]).filter(Boolean).map(Number);
  const swap = (t, after) => {
    t.c.__nakiPlugins.disable('a9');
    t.c.__nakiPlugins.setGrant('a9', { capabilities: ['observe'], methods: [FIRE] });
    assert.equal(t.c.__nakiPlugins.register({ id: 'a9', onSend() { throw new Error('new A'); } }), true);
    if (after) after();
  };
  {
    // 舊 A 成功（延後到鏈尾），鏈中被換掉、新 A 連錯 9 次：鏈尾不清新 A 的計數，第 10 次停用
    const t = page();
    observer7(t, 'a9', [OAUTH7], () => {});
    observer7(t, 'b9', [OAUTH7], () => swap(t, () => { for (let i = 0; i < 9; i++) t.lobby.send(request(1610 + i, FIRE)); }), 1);
    t.lobby.send(request(1609, OAUTH7, [8, 1]));
    t.lobby.send(request(1619, FIRE));
    assert.deepEqual(countsOf(t), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 'deferred success');
    assert.equal(plain(t.c.__nakiPlugins.list()).some(p => p.id === 'a9'), false, 'deferred success');
  }
  {
    // 舊 A 鏈尾違規，鏈中被換掉：違規不算給新 A
    const t = page();
    observer7(t, 'a9', [OAUTH7], ctx => { ctx.bytes[ctx.bytes.length - 1] ^= 1; });
    observer7(t, 'b9', [OAUTH7], () => swap(t), 1);
    t.lobby.send(request(1620, OAUTH7, [8, 1]));
    assert.deepEqual(countsOf(t), [], 'chain-end violation');
    t.lobby.send(request(1621, FIRE));
    assert.deepEqual(countsOf(t), [1], 'chain-end violation');
  }
});

test('GG9-2b (Astra8 2): a late rejection whose message getter swaps the instance is not charged to the new one', async () => {
  const t = page();
  let reject;
  observer7(t, 'a9', [BEAT], () => new Promise((_, r) => { reject = r; }));
  t.lobby.send(request(1630, BEAT));
  const err = { get message() {
    t.c.__nakiPlugins.disable('a9');
    t.c.__nakiPlugins.setGrant('a9', { capabilities: ['observe'], methods: [BEAT] });
    t.c.__nakiPlugins.register({ id: 'a9', onSend() { throw new Error('new A'); } });
    return 'old A';
  } };
  reject(err);
  await tick();
  assert.equal(t.events('log').some(e => e.data.id === 'a9' && /old A/.test(e.data.msg)), false);
  t.lobby.send(request(1631, BEAT));
  assert.equal(t.events('log').some(e => e.data.id === 'a9' && /onSend 拋錯（第 1 次）：new A/.test(e.data.msg)), true);
});

test('GG9-3 (Astra8 3): a guard that throws or returns a thenable and then leaves still vetoes this request even if the remaining guard approves', async () => {
  for (const kind of ['throw', 'thenable']) {
    const t = page();
    guardPlugin(t.c, { behave: () => { t.c.__nakiPlugins.disable(ID); if (kind === 'throw') throw new Error('veto'); return new Promise(() => {}); } });
    t.c.__nakiPlugins.setGrant('g9', { capabilities: ['observe'], methods: [SKIN], sendGuard: [SKIN], priority: 200 });
    assert.equal(t.c.__nakiPlugins.register({ id: 'g9', onSend() {} }), true);
    t.lobby.send(request(1640, SKIN, [8, 1]));
    await tick();
    assert.deepEqual(sentIds(t), [], kind);
    assert.deepEqual(lastGuard(t), [[1640, 'local_error', kind === 'throw' ? 'hook_threw' : 'async_hook']], kind);
  }
});

// ---- guard-gaps 第十輪（Astra guard-gaps 第九輪 1–2 條）：本地結案不刪回呼內新配對、disable 尾端清理只管被停用的實例 ----
test('GG10-1 (Astra9 1): the game resends loginBeat with the same msgId inside the synthetic error callback — the new pairing survives and the real RESPONSE routes as loginBeat (hook_threw / guard_error / dispatch_error)', async () => {
  for (const reason of ['hook_threw', 'guard_error', 'dispatch_error']) {
    const t = page();
    guardPlugin(t.c, { behave: () => { if (reason === 'hook_threw') throw new Error('boom'); } });
    let once = true;
    const breakOnce = list => ({ indexOf(m) { if (once) { once = false; throw new Error('bad grant'); } return list.indexOf(m); } });
    if (reason === 'guard_error') t.c.__nakiPluginGrants[ID].sendGuard = breakOnce([SKIN]);
    if (reason === 'dispatch_error') {
      t.c.__nakiPlugins.setGrant('broken10', { capabilities: ['observe'], methods: breakOnce([SKIN]) });
      t.c.__nakiPlugins.register({ id: 'broken10', onSend() {} });
    }
    const got = responders9(t);
    t.lobby.onmessage = ev => {
      const b = Array.from(new Uint8Array(ev.data));
      t.game.push(b);
      if (JSON.stringify(b) === JSON.stringify(errorResponse(1700))) t.lobby.send(request(1700, BEAT));
    };
    t.lobby.send(request(1700, SKIN, [8, 1]));
    await tick();
    assert.deepEqual(lastGuard(t), [[1700, 'local_error', reason]], reason);
    assert.deepEqual(t.lobby.committed.map(d => methodOf(Uint8Array.from(d))), [BEAT], reason);
    t.lobby.receive(response(1700, [8, 1]));
    assert.deepEqual(got, { skin: 0, beat: 1 }, reason);
  }
});

test('GG10-2 (Astra9 2): an old instance\'s onDisable registers a new A under the same id and it fails nine times — disable keeps the new A\'s count and grant, the tenth failure disables it', () => {
  const t = page();
  const FIRE = '.lq.Lobby.fetchServerTime';
  const countsOf = () => t.events('log').filter(e => e.data.id === 'a10').map(e => (/onSend 拋錯（第 (\d+) 次）/.exec(e.data.msg) || [])[1]).filter(Boolean).map(Number);
  t.c.__nakiPlugins.setGrant('a10', { capabilities: ['observe'], methods: [FIRE] });
  assert.equal(t.c.__nakiPlugins.register({ id: 'a10', onDisable() {
    assert.equal(t.c.__nakiPlugins.register({ id: 'a10', onSend() { throw new Error('new A'); } }), true);
    for (let i = 0; i < 9; i++) t.lobby.send(request(1710 + i, FIRE));
  } }), true);
  assert.deepEqual(plain(t.c.__nakiPlugins.disable('a10')), { ok: true, wasRegistered: true });
  assert.equal(plain(t.c.__nakiPlugins.list()).some(p => p.id === 'a10'), true);
  assert.ok(t.c.__nakiPluginGrants.a10, 'the new instance keeps its grant');
  t.lobby.send(request(1719, FIRE));
  assert.deepEqual(countsOf(), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  assert.equal(plain(t.c.__nakiPlugins.list()).some(p => p.id === 'a10'), false);
});

test('GG10-1b (Astra9 1): a blocked request leaves no pairing behind — a stray RESPONSE with its msgId is not routed to the SKIN plugin', async () => {
  const t = page();
  guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
  const got = responders9(t);
  t.lobby.send(request(1720, SKIN, [8, 1]));
  t.lobby.receive(response(1720, [8, 1]));
  await tick();
  t.lobby.receive(response(1720, [8, 1]));
  assert.deepEqual(lastGuard(t), [[1720, 'local_error', 'hook_threw']]);
  assert.deepEqual(got, { skin: 0, beat: 0 });
});

// ---- guard-gaps 第十一輪（Astra guard-gaps 第十輪 1–2 條）：bridge 故障退回原請求時配對跟著退回、邊界固定回歸 ----
function seen11(t, methods, { naki = false } = {}) {
  const got = [];
  methods.forEach((m, i) => {
    const id = 'seen11-' + i;
    t.c.__nakiPlugins.setGrant(id, { capabilities: ['observe'], methods: [m], priority: 500, observeNakiTraffic: naki });
    t.c.__nakiPlugins.register({ id, onReceive(ctx) { got.push(ctx.method); } });
  });
  return got;
}
function guard11(t) {
  t.c.__nakiPlugins.setGrant('g11', { capabilities: ['observe'], methods: [SKIN], sendGuard: [SKIN] });
  assert.equal(t.c.__nakiPlugins.register({ id: 'g11', onSend() {} }), true);
}

test('GG11-1 (Astra10 1): a bridge failure after a replace INFO→loginBeat sends the original INFO and its RESPONSE goes to the INFO plugin (with and without a page guard); without the failure both follow loginBeat', async () => {
  for (const [broken, guarded] of [[true, false], [true, true], [false, false]]) {
    const label = (broken ? 'bridge error' : 'healthy') + (guarded ? ', page guard' : '');
    const t = page(source('naki-websocket.js'), { breakBase64: broken });
    t.c.__nakiPluginsMayModifyOutbound = true;
    if (guarded) guard11(t);
    t.c.__nakiPlugins.setGrant('rw11', { capabilities: ['observe', 'rewriteSend'], methods: [INFO], priority: 1 });
    t.c.__nakiPlugins.register({ id: 'rw11', onSend(ctx) { assert.equal(ctx.replace(request(ctx.msgId, BEAT)), true); } });
    const got = seen11(t, [INFO, BEAT]);
    t.lobby.send(request(1800, INFO, [8, 1]));
    await tick();
    assert.deepEqual(t.lobby.committed.map(d => methodOf(Uint8Array.from(d))), [broken ? INFO : BEAT], label);
    t.lobby.receive(response(1800, [8, 1]));
    assert.deepEqual(plain(got), [broken ? INFO : BEAT], label);
  }
});

test('GG11-1b (Astra10 1/2): a guarded method that hits a bridge failure is blocked as bridge_error, keeps no pairing, and a loginBeat resent with its msgId inside the error callback keeps its own', async () => {
  for (const resend of [false, true]) {
    const t = page(source('naki-websocket.js'), { breakBase64: true });
    guard11(t);
    const got = seen11(t, [SKIN, BEAT]);
    t.lobby.onmessage = ev => {
      const b = Array.from(new Uint8Array(ev.data));
      t.game.push(b);
      if (resend && JSON.stringify(b) === JSON.stringify(errorResponse(1810))) t.lobby.send(request(1810, BEAT));
    };
    t.lobby.send(request(1810, SKIN, [8, 1]));
    await tick();
    assert.deepEqual(lastGuard(t), [[1810, 'local_error', 'bridge_error']]);
    assert.deepEqual(t.lobby.committed.map(d => methodOf(Uint8Array.from(d))), resend ? [BEAT] : []);
    t.lobby.receive(response(1810, [8, 1]));
    assert.deepEqual(plain(got), resend ? [BEAT] : [], resend ? 'resend' : 'no resend');
  }
});

test('GG11-2 (Astra10 2): the game resends on the game connection inside the tainted_fallback error callback — its pairing survives (the RESPONSE is Naki-attributed per the contract, so only a Naki-traffic observer sees it)', async () => {
  const { t, g, inject } = fallbackPage();
  const got = seen11(t, [OP], { naki: true });
  let msgId = null;
  g.onmessage = ev => {
    const b = new Uint8Array(ev.data);
    if (msgId != null && (b[1] | (b[2] << 8)) === msgId && b[0] === 3) g.send(request(msgId, OP));
  };
  msgId = inject(SKIN).msgId;
  await tick();
  assert.deepEqual(guardLog(t).map(e => e.slice(1)), [[msgId, 'local_error', 'tainted_fallback']]);
  assert.deepEqual(sentOn(g), [700, 701, msgId]);
  g.receive(response(msgId, [8, 1]));
  assert.deepEqual(plain(got), [OP]);
});

test('GG11-3 (Astra10 2): onDisable that only swaps the grant without registering again leaves no grant behind; an auto-disabled plugin registered again counts from 1 to 10 afresh', () => {
  const t = page();
  const FIRE = '.lq.Lobby.fetchServerTime';
  t.c.__nakiPlugins.setGrant('a11', { capabilities: ['observe'], methods: [FIRE] });
  t.c.__nakiPlugins.register({ id: 'a11', onDisable() { t.c.__nakiPlugins.setGrant('a11', { capabilities: ['observe'], methods: [FIRE] }); } });
  t.c.__nakiPlugins.disable('a11');
  assert.equal(Object.prototype.hasOwnProperty.call(t.c.__nakiPluginGrants, 'a11'), false, 'grant swap only');
  const counts = () => t.events('log').filter(e => e.data.id === 'b11').map(e => (/onSend 拋錯（第 (\d+) 次）/.exec(e.data.msg) || [])[1]).filter(Boolean).map(Number);
  const reg = () => {
    t.c.__nakiPlugins.setGrant('b11', { capabilities: ['observe'], methods: [FIRE] });
    assert.equal(t.c.__nakiPlugins.register({ id: 'b11', onSend() { throw new Error('b'); } }), true);
  };
  reg();
  for (let i = 0; i < 10; i++) t.lobby.send(request(1820 + i, FIRE));
  assert.equal(plain(t.c.__nakiPlugins.list()).some(p => p.id === 'b11'), false);
  reg();
  for (let i = 0; i < 10; i++) t.lobby.send(request(1830 + i, FIRE));
  assert.deepEqual(counts(), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  assert.equal(plain(t.c.__nakiPlugins.list()).some(p => p.id === 'b11'), false);
});

test('GG11-4 (Astra10 2, documented residual risk): a game INFO awaiting msgId 64000 loses its pairing when a plugin injection with the same msgId is blocked — no cross-source pairing isolation', async () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  guard11(t);
  let inject;
  t.c.__nakiPlugins.setGrant('inj11', { capabilities: ['observe', 'injectSend'], methods: [BEAT] });
  t.c.__nakiPlugins.register({ id: 'inj11', onSend(ctx) { inject = ctx.sendRequest; } });
  const got = seen11(t, [INFO], { naki: true });
  t.lobby.send(request(1840, BEAT));
  t.lobby.send(request(64000, INFO));
  const r = inject(SKIN, new t.c.Uint8Array([8, 1]));
  assert.equal(r.msgId, 64000);
  await tick();
  assert.deepEqual(lastGuard(t), [[64000, 'local_error', 'naki_traffic']]);
  t.lobby.receive(response(64000, [8, 1]));
  assert.deepEqual(plain(got), [], 'the INFO RESPONSE resolves to no method');
});

test('GG11-1c (Astra10 1): the bridge failure path keeps the original pairing when the guard lookup itself throws inside failSafe, and on a game connection', async () => {
  {
    let armed = false;
    const t = page(source('naki-websocket.js'), { encode: () => { armed = true; throw new Error('encode failed'); } });
    t.c.__nakiPluginsMayModifyOutbound = true;
    guard11(t);
    t.c.__nakiPluginGrants.g11.sendGuard = { indexOf(m) { if (armed) throw new Error('lookup failed'); return [SKIN].indexOf(m); } };
    t.c.__nakiPlugins.setGrant('rw11', { capabilities: ['observe', 'rewriteSend'], methods: [INFO], priority: 1 });
    t.c.__nakiPlugins.register({ id: 'rw11', onSend(ctx) { assert.equal(ctx.replace(request(ctx.msgId, BEAT)), true); } });
    const got = seen11(t, [INFO, BEAT]);
    t.lobby.send(request(1850, INFO, [8, 1]));
    armed = false;
    await tick();
    assert.deepEqual(t.lobby.committed.map(d => methodOf(Uint8Array.from(d))), [INFO], 'lookup throws in failSafe');
    t.lobby.receive(response(1850, [8, 1]));
    assert.deepEqual(plain(got), [INFO], 'lookup throws in failSafe');
  }
  {
    const t = page(source('naki-websocket.js'), { breakBase64: true });
    t.c.__nakiPluginsMayModifyOutbound = true;
    const g = gameSocket(t.c);
    g.send(request(1859, AUTH));
    t.c.__nakiPlugins.setGrant('rw11', { capabilities: ['observe', 'rewriteSend'], methods: [INFO], priority: 1 });
    t.c.__nakiPlugins.register({ id: 'rw11', onSend(ctx) { assert.equal(ctx.replace(request(ctx.msgId, BEAT)), true); } });
    const got = seen11(t, [INFO, BEAT]);
    g.send(request(1860, INFO, [8, 1]));
    await tick();
    assert.deepEqual(g.committed.map(d => methodOf(Uint8Array.from(d))), [AUTH, INFO], 'game connection');
    g.receive(response(1860, [8, 1]));
    assert.deepEqual(plain(got), [INFO], 'game connection');
  }
});
