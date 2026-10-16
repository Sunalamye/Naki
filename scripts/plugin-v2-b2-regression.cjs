// Run: node scripts/plugin-v2-b2-regression.cjs
// 送出守衛 N1／N2 的 spike（docs/plan/plugin-v2-b2.md §3–§4）。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const root = path.resolve(__dirname, '..');
const source = name => fs.readFileSync(path.join(root, 'command/Resources/JavaScript', name), 'utf8');

function page(wiring = source('naki-websocket.js'), { breakBase64 = false, swiftFails = () => false, realCore = false, postFails = () => false } = {}) {
  const swift = [];
  class MessageEvent { constructor(type, init) { this.type = type; this.data = init.data; } }
  class Socket {
    constructor(url) { this.url = url; this.readyState = 1; this.listeners = []; this.closers = []; this.sent = []; this.onmessage = null; }
    addEventListener(k, f) { if (k === 'message') this.listeners.push(f); if (k === 'close') this.closers.push(f); }
    close() { this.readyState = 3; this.closers.forEach(f => f({ code: 1000, reason: '' })); }
    send(d) { this.sent.push(d); }
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
  if (!realCore) c.__nakiCore.sendToSwift = (type, data) => { if (swiftFails(type, data)) throw new Error('bridge down'); swift.push({ type, data }); };
  if (breakBase64) c.__nakiCore.arrayBufferToBase64 = () => { throw new Error('encode failed'); };
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

test('R4-1c (Astra3 1): with a healthy guard, a Blob on the game connection still goes out', () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  const g = gameSocket(t.c);
  const blob = new t.c.Blob([request(402, OP)]);
  g.send(blob);
  assert.equal(g.sent[0], blob);
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

test('R6-1 residual (Astra5 1): with no open lobby, sendRaw falls back to the game connection, so a coexisting sendRequest goes out unguarded', async () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  guardPlugin(t.c);
  pollute(t);
  t.c.__nakiPlugins.disable(ID);
  let inject;
  t.c.__nakiPlugins.setGrant('inj', { capabilities: ['observe', 'injectSend'], methods: [OP] });
  t.c.__nakiPlugins.register({ id: 'inj', onSend(ctx) { inject = ctx.sendRequest; } });
  const g = gameSocket(t.c);
  g.send(request(700, AUTH));
  g.send(request(701, OP));
  t.lobby.close();
  const r = inject(SKIN, new t.c.Uint8Array([8, 1]));
  assert.equal(r.ok, true);
  assert.deepEqual(sentOn(g), [700, 701, r.msgId]);
  assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log, []);
});

test('R6-2 residual (Astra5 2): an in-place rewrite outside ctx.replace on an unknown Route request or a lobby FastTest request goes out unguarded', async () => {
  for (const [first, method] of [[null, ROUTE], [BEAT, OP]]) {
    const t = page();
    guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
    t.c.__nakiPlugins.setGrant('obs', { capabilities: ['observe'], methods: [method] });
    t.c.__nakiPlugins.register({ id: 'obs', onSend(ctx) { ctx.bytes.set(request(ctx.msgId, SKIN, [8, 1])); } });
    const ws = first ? t.lobby : new t.c.WebSocket('wss://route-6.maj-soul.com/gateway');
    if (first) ws.send(request(709, first));
    ws.send(request(710, method, [8, 1, 8, 1]));
    await tick();
    const out = ws.sent.slice(-1)[0];
    assert.deepEqual(Array.from(new Uint8Array(out.buffer ? out.buffer : out)), Array.from(request(710, SKIN, [8, 1])), method);
    assert.equal(roleOf(t, ws), first ? 'lobby' : undefined, method);
  }
});

test('R6-3 residual (Astra5 3): a first Lobby request sent as Blob on an unknown connection goes out; the async copy locks lobby only afterwards', async () => {
  const t = page();
  guardPlugin(t.c, { behave: () => { throw new Error('boom'); } });
  const u = new t.c.WebSocket('wss://route-6.maj-soul.com/gateway');
  u.send(request(720, ROUTE));
  const blob = new t.c.Blob([request(721, SKIN)]);
  u.send(blob);
  assert.equal(u.sent[1], blob);
  await settle(() => roleOf(t, u) === 'lobby');
  assert.equal(roleOf(t, u), 'lobby');
  u.send(request(722, SKIN));
  await tick();
  assert.equal(u.sent.length, 2, 'once locked, the synchronous guarded request is blocked');
});

test('R6-4 (Astra5 5): a FastTest whose type byte an observer corrupts is refused by failSafe on a lobby, sent on a game connection', async () => {
  for (const onLobby of [true, false]) {
    const t = page(source('naki-websocket.js'), { breakBase64: true });
    guardPlugin(t.c);
    t.c.__nakiPlugins.setGrant('obs', { capabilities: ['observe'], methods: [OP] });
    t.c.__nakiPlugins.register({ id: 'obs', onSend(ctx) { ctx.bytes[0] = 9; } });
    const ws = onLobby ? t.lobby : gameSocket(t.c);
    ws.send(request(730, onLobby ? BEAT : AUTH));
    ws.send(request(731, OP));
    await tick();
    assert.equal(ws.sent.length, onLobby ? 1 : 2, onLobby ? 'lobby' : 'game');
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
