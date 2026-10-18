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
  // FileReader 模型：naki-core 的 blobToBase64 用它轉碼給 Swift；讀原型的 arrayBuffer，不受測試替換的展開影響
  class FileReader {
    readAsDataURL(blob) {
      Blob.prototype.arrayBuffer.call(blob).then(ab => { this.result = 'data:application/octet-stream;base64,' + Buffer.from(ab).toString('base64'); if (this.onloadend) this.onloadend(); });
    }
  }
  const c = { console: { log() {}, error() {} }, Uint8Array, ArrayBuffer, DataView, Blob, MessageEvent, FileReader, setTimeout,
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
  const got = seen11(t, [OP]);
  const r = inject(SKIN);
  await tick();
  const out = [...g.sent, ...g2.sent].filter(d => (bytesOf(d)[1] | (bytesOf(d)[2] << 8)) === r.msgId).map(methodOf);
  assert.deepEqual(out, [OP], 'only the colliding OP goes out');
  assert.deepEqual(guardLog(t).map(e => e.slice(1)), [[r.msgId, 'local_error', 'tainted_fallback']]);
  // pair-source 第二輪第 3 條：同號不同內容的遊戲請求照常登記配對，它的 RESPONSE 對回 OP
  const carrier = [g, g2].find(ws => ws.sent.some(d => (bytesOf(d)[1] | (bytesOf(d)[2] << 8)) === r.msgId));
  carrier.receive(response(r.msgId, [8, 1]));
  assert.deepEqual(plain(got), [OP]);
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
let seen11Seq = 0;
function seen11(t, methods, { naki = false } = {}) {
  const got = [];
  methods.forEach(m => {
    const id = 'seen11-' + (++seen11Seq);
    t.c.__nakiPlugins.setGrant(id, { capabilities: ['observe'], methods: [m], priority: 500, observeNakiTraffic: naki });
    assert.equal(t.c.__nakiPlugins.register({ id, onReceive(ctx) { got.push(ctx.method); } }), true);
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

// ---- pair-source：插件注入的 msgId 避開使用中與遊戲即將用到的號碼，注入的回應配對與遊戲分開（docs/archive/plan/pair-source-design-2026-10-17.md）----
const FST = '.lq.Lobby.fetchServerTime';
function injector11(t) {
  t.c.__nakiPluginsMayModifyOutbound = true;
  const answers = [], answerPayloads = [], answerErrors = [], answerReasons = [];
  let send;
  t.c.__nakiPlugins.setGrant('inj11', { capabilities: ['observe', 'injectSend'], methods: [BEAT] });
  t.c.__nakiPlugins.register({ id: 'inj11', onSend(ctx) { send = ctx.sendRequest; },
    onInjectResponse(ctx) { answers.push([ctx.inResponseTo, ctx.method]); answerPayloads.push(ctx.bytes[ctx.bytes.length - 1]); answerErrors.push(ctx.error || null); answerReasons.push(ctx.reason || null); } });
  t.lobby.send(request(1840, BEAT));
  t.lobby.receive(response(1840, [8, 1]));
  return { answers, answerPayloads, answerErrors, answerReasons, inject: (m, p = [8, 1]) => send(m, new t.c.Uint8Array(p)) };
}
const pendingPairs = t => t.c.__nakiPlugins.diagnostics().pendingPairs;
const pendingInjections = t => t.c.__nakiPlugins.diagnostics().pendingInjections;

test('GG11-4 / PS-1: a game INFO awaiting msgId 64000 keeps its pairing — a blocked plugin injection never takes 64000, and its local error carries its own msgId', async () => {
  const t = page();
  guard11(t);
  const { answers, inject } = injector11(t);
  const got = seen11(t, [INFO], { naki: true });
  t.lobby.send(request(64000, INFO));
  const r = inject(SKIN);
  assert.equal(r.ok, true);
  assert.notEqual(r.msgId, 64000);
  await tick();
  assert.deepEqual(lastGuard(t), [[r.msgId, 'local_error', 'naki_traffic']]);
  assert.deepEqual(t.game.slice(-1), [errorResponse(r.msgId)], 'the game gets the local error under the injection msgId only');
  assert.deepEqual(answers, [[r.msgId, SKIN]]);
  t.lobby.receive(response(64000, [8, 1]));
  assert.deepEqual(plain(got), [INFO]);
});

test('PS-2: a game request and an injection pending at the same time each get their own RESPONSE and method, in either arrival order', () => {
  const t = page();
  const { answers, inject } = injector11(t);
  const got = seen11(t, [INFO]);
  t.lobby.send(request(64000, INFO));
  const r = inject(FST);
  assert.equal(r.ok, true);
  assert.notEqual(r.msgId, 64000);
  t.lobby.receive(response(r.msgId, [8, 1]));
  t.lobby.receive(response(64000, [8, 1]));
  assert.deepEqual(answers, [[r.msgId, FST]]);
  assert.deepEqual(plain(got), [INFO]);
  assert.equal(pendingPairs(t), 0);
  assert.equal(pendingInjections(t), 0);
});

test('PS-3: two injections in a row skip the numbers the game counter reaches next, so the game\'s following requests keep their own pairings', () => {
  const t = page();
  const { answers, inject } = injector11(t);
  const got = seen11(t, [INFO]);
  t.lobby.send(request(63999, BEAT));
  t.lobby.receive(response(63999, [8, 1]));
  const a = inject(FST).msgId, b = inject(FST).msgId;
  assert.notEqual(a, b);
  for (const id of [a, b]) assert.ok(id >= 64000 && id <= 65500 && id - 63999 > 256, 'outside the game window: ' + id);
  t.lobby.send(request(64000, INFO));
  t.lobby.send(request(64001, INFO));
  for (const id of [a, b, 64000, 64001]) t.lobby.receive(response(id, [8, 1]));
  assert.deepEqual(answers, [[a, FST], [b, FST]]);
  assert.deepEqual(plain(got), [INFO, INFO]);
});

test('PS-4: the game reusing a pending injection msgId on the same connection does not overwrite either pairing — the first RESPONSE answers the injection with its own method, the second resolves to the game method', () => {
  const t = page();
  const { answers, inject } = injector11(t);
  const got = seen11(t, [INFO], { naki: true });
  const plainGot = seen11(t, [INFO]);
  const a = inject(FST).msgId;
  t.lobby.send(request(a, INFO));
  t.lobby.receive(response(a, [8, 1]));
  assert.deepEqual(answers, [[a, FST]]);
  t.lobby.receive(response(a, [8, 2]));
  assert.deepEqual(plain(got), [INFO], 'D22: the game request on a pending Naki pair stays Naki-attributed');
  assert.deepEqual(plain(plainGot), []);
  assert.equal(pendingPairs(t), 0);
});

test('PS-5: closing a connection drops its injection registrations with its pairings; after reconnecting, a stale number answers nobody and a new injection routes normally', () => {
  const t = page();
  const { answers, inject } = injector11(t);
  t.lobby.send(request(64000, INFO));
  const a = inject(FST).msgId;
  assert.equal(pendingInjections(t), 1);
  t.lobby.close();
  assert.equal(pendingPairs(t), 0);
  assert.equal(pendingInjections(t), 0);
  const lobby2 = new t.c.WebSocket('wss://route-4.maj-soul.com/gateway');
  lobby2.send(request(64001, BEAT));
  const c = inject(FST).msgId;
  assert.notEqual(c, a);
  assert.equal(lobby2.sent.length, 2, 'the injection goes out on the new lobby');
  lobby2.receive(response(a, [8, 1]));
  lobby2.receive(response(c, [8, 1]));
  assert.deepEqual(answers, [[c, FST]]);
  assert.equal(pendingInjections(t), 0);
});

test('PS-6: Naki\'s own sendRaw and the injection itself do not move the game counter window — after Naki sends 63999 and one injection, the next injection still starts right at the plugin range', () => {
  const t = page();
  const { inject } = injector11(t);
  t.c.__nakiWebSocket.sendRaw(b64(request(63999, BEAT)));
  const a = inject(FST).msgId, b = inject(FST).msgId;
  assert.deepEqual([a, b], [64000, 64001]);
});

// ---- pair-source 第二輪（Astra 第一輪 1～6 條）----
test('PS-7 (r2 1): seven injections stay pending while the game on another connection walks along with each of them — no injection msgId repeats', () => {
  const t = page();
  const { inject } = injector11(t);
  const g = gameSocket(t.c);
  g.send(request(700, AUTH));
  g.receive(response(700, [8, 1]));
  const ids = [];
  for (let i = 0; i < 7; i++) {
    const id = inject(FST).msgId;
    ids.push(id);
    g.send(request(id, OP));
    g.receive(response(id, [8, 1]));
  }
  assert.equal(new Set(ids).size, 7, ids.join(','));
  assert.equal(pendingInjections(t), 7);
});

test('PS-8 (r2 2): a game INFO#64000 sent while no plugin is on the page stays in flight — a guarded injection enabled afterwards never takes 64000, and its local error carries its own msgId', async () => {
  const t = page();
  t.lobby.send(request(64000, INFO));
  guard11(t);
  const { inject } = injector11(t);
  const r = inject(SKIN);
  assert.equal(r.ok, true);
  assert.notEqual(r.msgId, 64000);
  await tick();
  assert.deepEqual(lastGuard(t), [[r.msgId, 'local_error', 'naki_traffic']]);
  assert.deepEqual(t.game.slice(-1), [errorResponse(r.msgId)]);
});

test('PS-9 (r2 2): 256 unanswered game requests on one connection are all avoided; the 257th overflows that record and injections are refused with msgid_busy until the connection closes', () => {
  const t = page();
  const { inject } = injector11(t);
  for (let i = 0; i < 256; i++) t.lobby.send(request(64000 + i, BEAT));
  assert.equal(inject(FST).msgId, 64512, 'past the 256 in flight and the window after 64255');
  t.lobby.send(request(64256, BEAT));
  assert.deepEqual(plain(inject(FST)), { ok: false, reason: 'msgid_busy' });
  t.lobby.close();
  const lobby2 = new t.c.WebSocket('wss://route-4.maj-soul.com/gateway');
  lobby2.send(request(64257, BEAT));
  assert.equal(inject(FST).msgId, 64514, 'the closed record is gone; only the new connection window 64258–64513 is avoided');
});

test('PS-10 (r2 2): a game request leaves the in-flight record when its RESPONSE arrives and when it is blocked locally, so its number is free for injections again', async () => {
  const t = page();
  const { inject } = injector11(t);
  guardPlugin(t.c, { behave: () => { throw new Error('no'); } });
  t.lobby.send(request(64000, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[64000, 'local_error', 'hook_threw']]);
  t.lobby.send(request(64001, BEAT));
  t.lobby.receive(response(64001, [8, 1]));
  t.lobby.send(request(63000, BEAT));
  t.lobby.receive(response(63000, [8, 1]));
  assert.deepEqual([inject(FST).msgId, inject(FST).msgId], [64000, 64001]);
});

test('PS-11 (r2 4): with no consumer left, the injection RESPONSE still uses up its registration — a plugin registered again later never gets the game same-number RESPONSE as an injection answer', () => {
  const t = page();
  const first = injector11(t);
  const a = first.inject(FST).msgId;
  t.c.__nakiPlugins.disable('inj11');
  assert.equal(pendingInjections(t), 1);
  t.lobby.receive(response(a, [8, 1]));
  assert.equal(pendingInjections(t), 0);
  const second = injector11(t);
  const got = seen11(t, [INFO], { naki: true });
  t.lobby.send(request(a, INFO));
  t.lobby.receive(response(a, [8, 2]));
  assert.deepEqual([first.answers, second.answers], [[], []]);
  assert.deepEqual(plain(got), [INFO]);
});

test('PS-12 (r2 5): a game SKIN blocked on a pending injection number answers the game locally and leaves the injection registration alone — the real injection RESPONSE still reaches the injector', async () => {
  const t = page();
  guard11(t);
  const { answers, inject } = injector11(t);
  const a = inject(FST).msgId;
  t.lobby.send(request(a, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[a, 'local_error', 'naki_traffic']]);
  assert.deepEqual(t.game.slice(-1), [errorResponse(a)]);
  assert.deepEqual(answers, []);
  t.lobby.receive(response(a, [8, 1]));
  assert.deepEqual(answers, [[a, FST]]);
});

test('PS-13 (r2 6): with the injection sendRaw registration evicted, a game request on the pending injection number makes the pair ambiguous — the RESPONSE after the injection one is observe-only for Naki observers, never rewritable', () => {
  const t = page();
  const { answers, inject } = injector11(t);
  const nakiSeen = seen11(t, [INFO], { naki: true });
  const rewrites = [];
  t.c.__nakiPlugins.setGrant('rw13', { capabilities: ['observe', 'rewriteReceive'], methods: [INFO] });
  t.c.__nakiPlugins.register({ id: 'rw13', onReceive(ctx) { rewrites.push(typeof ctx.replace); } });
  const a = inject(FST).msgId;
  for (let id = 60100; id < 60356; id++) t.c.__nakiWebSocket.sendRaw(b64(request(id, BEAT)));
  assert.equal(t.c.__nakiWebSocket.isNakiSent(a), false);
  t.lobby.send(request(a, INFO));
  t.lobby.receive(response(a, [8, 1]));
  t.lobby.receive(response(a, [8, 2]));
  assert.deepEqual(answers, [[a, FST]]);
  assert.deepEqual(plain(nakiSeen), [INFO]);
  assert.deepEqual(rewrites, []);
});

test('PS-14 (r2 3): a bridge failure while sending an injection still keeps its pairing out of the shared table — the RESPONSE answers the injector and leaves nothing behind', () => {
  let armed = 0;   // 2：sendRequest 自己編碼成功，送出路徑送 Swift 的那次編碼失敗 ⇒ failSafe
  const t = page(source('naki-websocket.js'), { encode: d => { if (armed && --armed === 0) throw new Error('encode failed'); return Buffer.from(d).toString('base64'); } });
  const { answers, inject } = injector11(t);
  armed = 2;
  const a = inject(FST).msgId;
  assert.equal(armed, 0, 'the bridge failure happened on the injection send');
  assert.equal(pendingPairs(t), 0);
  t.lobby.receive(response(a, [8, 1]));
  assert.deepEqual(answers, [[a, FST]]);
  assert.equal(pendingPairs(t), 0);
});

// ---- pair-source 第三輪（Astra 第二輪 8～14 條）：注入身分＝宿主交易代號 ----
test('PS-15 (r3 8): a game INFO sent on a pending injection number stays in flight after the injection RESPONSE — seven later injections with the game walking along never reuse it', () => {
  const t = page();
  const { inject } = injector11(t);
  const g = gameSocket(t.c);
  g.send(request(700, AUTH));
  g.receive(response(700, [8, 1]));
  const a = inject(FST).msgId;
  t.lobby.send(request(a, INFO));
  t.lobby.receive(response(a, [8, 1]));
  const ids = [];
  for (let i = 0; i < 7; i++) {
    const id = inject(FST).msgId;
    ids.push(id);
    g.send(request(id, OP));
    g.receive(response(id, [8, 1]));
  }
  assert.equal(ids.includes(a), false, ids.join(','));
});

test('PS-16 (r3 9): a blocked injection does not revoke the pairing of a game INFO re-entered on the same socket with the same msgId — its real RESPONSE still resolves to INFO', async () => {
  const t = page();
  guard11(t);
  const { inject } = injector11(t);
  const got = seen11(t, [INFO], { naki: true });
  const orig = t.lobby.send.bind(t.lobby);
  let busy = false;
  t.lobby.send = d => { if (!busy && d instanceof ArrayBuffer) { busy = true; orig(request(bytesOf(d)[1] | (bytesOf(d)[2] << 8), INFO)); busy = false; } return orig(d); };
  const r = inject(SKIN);
  await tick();
  assert.deepEqual(lastGuard(t), [[r.msgId, 'local_error', 'naki_traffic']]);
  assert.equal(pendingPairs(t), 1);
  t.lobby.receive(response(r.msgId, [8, 1]));
  assert.deepEqual(plain(got), [INFO]);
});

test('PS-17 (r3 10): an injection falling back to the game connection keeps its pairing out of the shared table even after a Naki observer edits its payload', () => {
  const { t, g, got, inject } = fallbackPage({ taint: false });
  t.c.__nakiPlugins.setGrant('mut17', { capabilities: ['observe'], methods: [FST], observeNakiTraffic: true });
  t.c.__nakiPlugins.register({ id: 'mut17', onSend(ctx) { ctx.bytes[ctx.bytes.length - 1] ^= 1; } });
  const before = pendingPairs(t);
  const r = inject(FST);
  assert.equal(r.ok, true);
  assert.equal(sentOn(g).at(-1), r.msgId);
  assert.equal(bytesOf(g.sent.at(-1)).at(-1), 0, 'the observer edit went out');
  assert.equal(pendingPairs(t), before);
  g.receive(response(r.msgId, [8, 1]));
  assert.deepEqual(got.map(x => x.msgId), [r.msgId]);
  assert.equal(pendingPairs(t), before);
});

test('PS-18 (r3 11): 257 ambiguous pairs across two connections overflow the record — both connections turn observe-only until closed, so the oldest late RESPONSE never gets a rewrite chain', () => {
  const t = page();
  const { answers, inject } = injector11(t);
  const g = gameSocket(t.c);
  g.send(request(700, AUTH));
  g.receive(response(700, [8, 1]));
  const nakiSeen = seen11(t, [INFO], { naki: true });
  const rewrites = [];
  t.c.__nakiPlugins.setGrant('rw18', { capabilities: ['observe', 'rewriteReceive'], methods: [INFO] });
  t.c.__nakiPlugins.register({ id: 'rw18', onReceive(ctx) { rewrites.push(ctx.msgId); } });
  const first = inject(FST).msgId;
  t.lobby.send(request(first, INFO));
  t.lobby.receive(response(first, [8, 1]));
  for (let i = 1; i < 257; i++) {
    const [ws, m, gm] = i % 2 ? [g, '.lq.FastTest.fetchGamePlayerState', OP] : [t.lobby, FST, INFO];
    const id = inject(m).msgId;
    assert.equal(typeof id, 'number', 'injection ' + i);
    ws.send(request(id, gm));
    ws.receive(response(id, [8, 1]));
  }
  assert.equal(answers.length, 257);
  t.lobby.send(request(first, INFO));
  t.lobby.receive(response(first, [8, 2]));
  t.lobby.send(request(1990, INFO));
  t.lobby.receive(response(1990, [8, 1]));
  assert.deepEqual(rewrites, [], 'no rewrite chain on either connection after the overflow');
  assert.deepEqual(plain(nakiSeen), [INFO, INFO]);
  t.lobby.close();
  const lobby2 = new t.c.WebSocket('wss://route-4.maj-soul.com/gateway');
  lobby2.send(request(1991, INFO));
  lobby2.receive(response(1991, [8, 1]));
  assert.deepEqual(rewrites, [1991], 'a new connection starts unambiguous');
});

test('PS-19 (r3 12, inject-receive r2 4): a guarded request blocked locally on top of 256 unanswered game requests is not counted — no overflow, injections still go out; its number stays reserved until the local error is delivered', async () => {
  for (const early of [true, false]) {
    const label = early ? 'injection before the local error is delivered' : 'injection after delivery';
    const t = page();
    const { inject } = injector11(t);
    guardPlugin(t.c, { behave: () => { throw new Error('no'); } });
    for (let i = 0; i < 256; i++) t.lobby.send(request(64000 + i, BEAT));
    t.lobby.send(request(64256, SKIN, [8, 1]));
    if (!early) await tick();
    const r = inject(FST);
    assert.equal(r.ok, true, label + ': ' + JSON.stringify(plain(r)));
    // 裁決 a：本地結局讓遊戲最後號碼前進到 64256，避號視窗 64257–64512。交付前 64256 另保留（不算未答），交付後才可用
    assert.equal(r.msgId, early ? 64513 : 64256, label);
    await tick();
    assert.deepEqual(lastGuard(t), [[64256, 'local_error', 'hook_threw']], label);
    assert.equal(t.c.__nakiPlugins.diagnostics().gameInflight, 256, label + ': the blocked request is not counted unanswered');
  }
});

test('PS-20 (r3 13): during an injection, a game request with identical bytes on another lobby connection keeps its own pairing — its RESPONSE reaches the FST observer', async () => {
  const t = page();
  const { answers, inject } = injector11(t);
  const lobby2 = new t.c.WebSocket('wss://route-4.maj-soul.com/gateway');
  lobby2.send(request(1850, BEAT));
  lobby2.receive(response(1850, [8, 1]));
  const got = seen11(t, [FST]);
  let busy = false;
  for (const [ws, other] of [[t.lobby, lobby2], [lobby2, t.lobby]]) {
    const orig = ws.send.bind(ws);
    ws.send = d => { if (!busy && d instanceof ArrayBuffer) { busy = true; other.send(new Uint8Array(bytesOf(d))); busy = false; } return orig(d); };
  }
  const r = inject(FST);
  const injectedOn = ws => ws.sent.some(d => d instanceof ArrayBuffer && (bytesOf(d)[1] | (bytesOf(d)[2] << 8)) === r.msgId);   // 注入是 sendRaw 的 ArrayBuffer，遊戲複本是 Uint8Array
  const [carrier, other] = injectedOn(t.lobby) ? [t.lobby, lobby2] : [lobby2, t.lobby];
  assert.equal(injectedOn(other), false);
  assert.equal(sentOn(carrier).filter(id => id === r.msgId).length, 1);
  assert.equal(sentOn(other).filter(id => id === r.msgId).length, 1, 'the identical game request went out');
  other.receive(response(r.msgId, [8, 1]));
  carrier.receive(response(r.msgId, [8, 2]));
  assert.deepEqual(plain(got), [FST]);
  assert.deepEqual(answers, [[r.msgId, FST]]);
});

test('PS-21 (r3 14): with no consumer left and the other tables empty, the late RESPONSE still clears its ambiguity mark — a later game RESPONSE on that number reaches the general chain again', () => {
  const t = page();
  const { inject } = injector11(t);
  const a = inject(FST).msgId;
  t.lobby.send(request(a, INFO));
  t.lobby.receive(response(a, [8, 1]));
  for (let id = 60100; id < 60356; id++) t.c.__nakiWebSocket.sendRaw(b64(request(id, BEAT)));
  for (let id = 60100; id < 60356; id++) t.lobby.receive(response(id, [8, 1]));
  assert.equal(pendingPairs(t), 0);
  assert.equal(pendingInjections(t), 0);
  t.c.__nakiPlugins.disable('inj11');
  t.lobby.receive(response(a, [8, 2]));
  const got = seen11(t, [INFO]);
  t.lobby.send(request(a, INFO));
  t.lobby.receive(response(a, [8, 3]));
  assert.deepEqual(plain(got), [INFO]);
});

test('PS-22 (r3 12): a game request already counted by the dispatch but then blocked by failSafe (bridge error) leaves the in-flight record — its number is free for injections', async () => {
  let armed = 0;
  const t = page(source('naki-websocket.js'), { encode: d => { if (armed && --armed === 0) throw new Error('encode failed'); return Buffer.from(d).toString('base64'); } });
  guard11(t);
  const { inject } = injector11(t);
  armed = 1;
  t.lobby.send(request(64000, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[64000, 'local_error', 'bridge_error']]);
  assert.equal(inject(FST).msgId, 64000);
});

test('PS-23 (r4 15): an injection fired inside the onSend hook of game INFO#64000 never takes 64000 — guarded and unguarded', async () => {
  for (const guarded of [false, true]) {
    const label = guarded ? 'guarded' : 'unguarded';
    const t = page();
    if (guarded) guard11(t);
    const { inject } = injector11(t);
    let r = null;
    t.c.__nakiPlugins.setGrant('hook15', { capabilities: ['observe'], methods: [INFO] });
    t.c.__nakiPlugins.register({ id: 'hook15', onSend() { if (!r) r = inject(SKIN); } });
    t.lobby.send(request(64000, INFO));
    await tick();
    assert.equal(r.ok, true, label);
    assert.equal(r.msgId > 64256, true, label + ': the number in dispatch and the next ' + 256 + ' after it are skipped: ' + r.msgId);
    assert.equal(sentOn(t.lobby).filter(id => id === 64000).length, 1, label + ': only the game INFO used 64000');
    if (guarded) {
      assert.deepEqual(lastGuard(t), [[r.msgId, 'local_error', 'naki_traffic']]);
      assert.deepEqual(t.game.slice(-1), [errorResponse(r.msgId)], 'the local error carries the injection number only');
    }
  }
});

test('PS-24 (r4 16): on top of 256 unanswered game requests, a request counted by the dispatch but then blocked by failSafe rolls the overflow back — injections never turn msgid_busy and the oldest unanswered number stays avoided', async () => {
  let armed = 0;
  const t = page(source('naki-websocket.js'), { encode: d => { if (armed && --armed === 0) throw new Error('encode failed'); return Buffer.from(d).toString('base64'); } });
  guard11(t);
  const { inject } = injector11(t);
  for (let i = 0; i < 256; i++) t.lobby.send(request(64000 + i, BEAT));
  armed = 1;
  t.lobby.send(request(64256, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[64256, 'local_error', 'bridge_error']]);
  const r = inject(FST);
  assert.equal(r.ok, true, JSON.stringify(plain(r)));
  assert.equal(r.msgId >= 64256, true, 'all 256 unanswered numbers, the oldest included, stay avoided: ' + r.msgId);
  for (let i = 0; i < 256; i++) t.lobby.receive(response(64000 + i, [8, 1]));
  assert.equal(inject(FST).ok, true);
});

test('PS-27 (r4 16): a dispatch that throws leaves no rollback record behind — failSafe blocking the resend cannot undo the earlier request that really went out', () => {
  const t = page();
  guard11(t);
  const { inject } = injector11(t);
  const id = idOf(t, t.lobby);
  for (let i = 0; i <= 256; i++) t.lobby.send(request(64000 + i, BEAT));
  assert.equal(inject(FST).reason, 'msgid_busy', '257 unanswered overflow the record');
  const bytes = request(64256, SKIN, [8, 1]);
  const raw = { direction: 'send', url: '', mutable: true, bytes, get wsId() { throw new Error('dispatch broke'); } };
  assert.throws(() => t.c.__nakiPlugins.dispatch(raw));
  assert.equal(t.c.__nakiPlugins.failSafe(bytes, id).block, true);
  assert.equal(inject(FST).reason, 'msgid_busy', 'the overflow from the request that went out stays');
});

test('PS-28 (r4 16): a game request blocked locally on a number its earlier request still awaits leaves that earlier request in flight — injections keep avoiding it', async () => {
  const t = page();
  const { inject } = injector11(t);
  guardPlugin(t.c, { behave: () => { throw new Error('no'); } });
  t.lobby.send(request(64000, BEAT));
  t.lobby.send(request(64000, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[64000, 'local_error', 'hook_threw']]);
  assert.notEqual(inject(FST).msgId, 64000);
});

// 第五輪：failSafe 查守衛時同步重入（encode 失敗後第一次查 sendGuard 才觸發 during）
function reenterInFailSafe(during) {
  let armed = 0, reenter = false;
  const t = page(source('naki-websocket.js'), { encode: d => { if (armed && --armed === 0) { reenter = true; throw new Error('encode failed'); } return Buffer.from(d).toString('base64'); } });
  guard11(t);
  t.c.__nakiPluginGrants.g11.sendGuard = { indexOf(m) { if (reenter) { reenter = false; during(t); } return [SKIN].indexOf(m); } };
  return { t, arm: () => { armed = 1; } };
}

test('PS-29 (r5 19): BEAT#64000 really goes out, then a SKIN on the same number fails before its dispatch — failSafe has no commit of its own to undo, so 64000 stays unanswered', async () => {
  const t = page();
  guard11(t);
  const { inject } = injector11(t);
  t.lobby.send(request(64000, BEAT));
  const mask = t.c.__nakiHideNames, observe = mask.observe;
  mask.observe = () => { mask.observe = observe; throw new Error('mask broke'); };
  t.lobby.send(request(64000, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[64000, 'local_error', 'bridge_error']]);
  assert.notEqual(inject(FST).msgId, 64000);
});

test('PS-30 (r5 19): with 256 unanswered, the 257th request is committed, a send on another connection re-enters during its encoding and fails too — the 257th still rolls back its own overflow, so injections recover once everything is answered', async () => {
  let step = 0, g = null;
  const t = page(source('naki-websocket.js'), { encode: d => {
    if (step === 1) { step = 2; g.send(request(900, OP)); throw new Error('lobby encode failed'); }
    if (step === 2) { step = 3; throw new Error('game encode failed'); }
    return Buffer.from(d).toString('base64');
  } });
  guard11(t);
  const { inject } = injector11(t);
  g = gameSocket(t.c);
  g.send(request(700, AUTH));
  g.receive(response(700, [8, 1]));
  for (let i = 0; i < 256; i++) t.lobby.send(request(64000 + i, BEAT));
  step = 1;
  t.lobby.send(request(64256, SKIN, [8, 1]));
  await tick();
  assert.equal(step, 3);
  assert.deepEqual(lastGuard(t), [[64256, 'local_error', 'bridge_error']]);
  g.receive(response(900, [8, 1]));
  for (let i = 0; i < 256; i++) t.lobby.receive(response(64000 + i, [8, 1]));
  const r = inject(FST);
  assert.equal(r.ok, true, JSON.stringify(plain(r)));
});

test('PS-31 (r5 20, same-line add): SKIN#65000 is committed, its encoding fails and failSafe re-enters with a real BEAT#64000 — the rollback removes only 65000, 64000 stays unanswered', async () => {
  const { t, arm } = reenterInFailSafe(t => t.lobby.send(request(64000, BEAT)));
  const { inject } = injector11(t);
  arm();
  t.lobby.send(request(65000, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[65000, 'local_error', 'bridge_error']]);
  assert.equal(sentOn(t.lobby).includes(64000), true);
  assert.notEqual(inject(FST).msgId, 64000);
});

test('PS-32 (r5 20, same-line consume): BEAT#64000 is unanswered, SKIN#65000 is committed and fails, and the 64000 RESPONSE arrives inside failSafe — the rollback does not bring 64000 back', async () => {
  const { t, arm } = reenterInFailSafe(t => t.lobby.receive(response(64000, [8, 1])));
  const { inject } = injector11(t);
  t.lobby.send(request(64000, BEAT));
  arm();
  t.lobby.send(request(65000, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[65000, 'local_error', 'bridge_error']]);
  assert.equal(inject(FST).msgId, 64000, 'the answered number is free again');
});

test('PS-33 (r5 20, same-line capacity): 256 unanswered, the 257th overflows and fails, and failSafe re-enters with another real request on the same line — the conflict keeps the record lost (conservative), injections stay msgid_busy', async () => {
  const { t, arm } = reenterInFailSafe(t => t.lobby.send(request(64300, BEAT)));
  const { inject } = injector11(t);
  for (let i = 0; i < 256; i++) t.lobby.send(request(64000 + i, BEAT));
  arm();
  t.lobby.send(request(64256, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[64256, 'local_error', 'bridge_error']]);
  assert.equal(inject(FST).reason, 'msgid_busy');
});

test('PS-34 (r5 20, same number re-entered): SKIN#64000 is committed and fails, and failSafe re-enters with a real BEAT#64000 — the rollback leaves the BEAT commit, 64000 stays unanswered', async () => {
  const { t, arm } = reenterInFailSafe(t => t.lobby.send(request(64000, BEAT)));
  const { inject } = injector11(t);
  arm();
  t.lobby.send(request(64000, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[64000, 'local_error', 'bridge_error']]);
  assert.notEqual(inject(FST).msgId, 64000);
});

test('PS-35 (r5 20): BEAT#64000 really goes out, then a SKIN on the same number is committed and fails after its dispatch — the rollback puts the BEAT commit back', async () => {
  let armed = 0;
  const t = page(source('naki-websocket.js'), { encode: d => { if (armed && --armed === 0) throw new Error('encode failed'); return Buffer.from(d).toString('base64'); } });
  guard11(t);
  const { inject } = injector11(t);
  t.lobby.send(request(64000, BEAT));
  armed = 1;
  t.lobby.send(request(64000, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[64000, 'local_error', 'bridge_error']]);
  assert.notEqual(inject(FST).msgId, 64000);
});

test('PS-36 (r5 20, consume at capacity): 256 unanswered, the 257th overflows and fails, and a RESPONSE arrives inside failSafe — the conflict keeps the record lost (conservative), injections stay msgid_busy', async () => {
  const { t, arm } = reenterInFailSafe(t => t.lobby.receive(response(64001, [8, 1])));
  const { inject } = injector11(t);
  for (let i = 0; i < 256; i++) t.lobby.send(request(64000 + i, BEAT));
  arm();
  t.lobby.send(request(64256, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[64256, 'local_error', 'bridge_error']]);
  assert.equal(inject(FST).reason, 'msgid_busy');
});

const gameDiag = t => { const d = t.c.__nakiPlugins.diagnostics(); return [d.gameInflight, d.openCommits]; };

const untrusted = t => t.c.__nakiPlugins.diagnostics().untrustedSockets;

test('PS-37 (r7 26-30): a game Blob send marks its connection untrusted until close — injections stay msgid_busy even after expansion, the expanded Blob is observed and paired as usual but never counted, and a new connection after close works (unguarded lobby, guarded game connection)', async () => {
  for (const guarded of [false, true]) {
    const label = guarded ? 'guarded' : 'unguarded';
    const t = page();
    if (guarded) guard11(t);
    const { inject } = injector11(t);
    let ws = t.lobby, method = BEAT;
    if (guarded) {
      ws = gameSocket(t.c); method = OP;
      ws.send(request(700, AUTH)); ws.receive(response(700, [8, 1]));
      const refused = t.lobby.sent.length;
      t.lobby.send(new t.c.Blob([request(1900, SKIN)]));
      assert.equal(t.lobby.sent.length, refused, label + ': the guard still refuses a lobby Blob');
      assert.equal(untrusted(t), 0, label + ': a refused Blob never went out, nothing to distrust');
    }
    const got = seen11(t, [method]);
    const before = ws.sent.length, inflight = gameDiag(t)[0];
    ws.send(new t.c.Blob([request(64000, method)]));
    assert.equal(ws.sent.length, before + 1, label + ': the Blob went out');
    assert.equal(untrusted(t), 1, label);
    assert.equal(inject(FST).reason, 'msgid_busy', label + ': before expansion');
    await tick();
    assert.equal(inject(FST).reason, 'msgid_busy', label + ': after expansion');
    assert.deepEqual(gameDiag(t), [inflight, 0], label + ': the Blob is not counted');
    ws.receive(response(64000, [8, 1]));
    assert.deepEqual(plain(got), [method], label + ': the Blob request is paired as usual');
    ws.close();
    assert.equal(untrusted(t), 0, label);
    const fresh = new t.c.WebSocket('wss://route-4.maj-soul.com/gateway');
    fresh.send(request(1950, BEAT));
    fresh.receive(response(1950, [8, 1]));
    const r = inject(FST);
    assert.equal(r.ok, true, label + ' ' + JSON.stringify(plain(r)));
  }
});

test('PS-44 (r7 26, 30): a Blob whose expansion rejects, or throws synchronously, keeps only the untrusted mark — nothing counted, no pairing, injections refused until close', async () => {
  for (const kind of ['reject', 'throw']) {
    const t = page();
    const { inject } = injector11(t);
    const blob = new t.c.Blob([request(64000, BEAT)]);
    blob.arrayBuffer = kind === 'reject' ? () => Promise.reject(new Error('read failed')) : () => { throw new Error('read failed'); };
    const before = t.lobby.sent.length;
    t.lobby.send(blob);
    await tick();
    assert.equal(t.lobby.sent.length, before + 1, kind + ': the Blob still went out');
    assert.deepEqual(gameDiag(t), [0, 0], kind);
    assert.equal(pendingPairs(t), 0, kind);
    assert.equal(untrusted(t), 1, kind);
    assert.equal(inject(FST).reason, 'msgid_busy', kind);
  }
});

test('PS-45 (r7 28): 257 Blobs pending expansion, then close, then a new connection, then all old Blobs expand — the released connection gets no role, pairing or count back, and the new connection injects', async () => {
  const t = page();
  const { inject } = injector11(t);
  const old = t.lobby, oldId = idOf(t, old), opens = [];
  for (let i = 0; i < 257; i++) {
    const blob = new t.c.Blob([request(64000 + i, BEAT)]);
    const real = blob.arrayBuffer.bind(blob);
    blob.arrayBuffer = () => new Promise(resolve => opens.push(() => resolve(real())));
    old.send(blob);
  }
  old.close();
  const fresh = new t.c.WebSocket('wss://route-4.maj-soul.com/gateway');
  fresh.send(request(1950, BEAT));
  fresh.receive(response(1950, [8, 1]));
  opens.forEach(f => f());
  await tick(); await tick();
  assert.equal((plain(t.c.__nakiPlugins.guardState()).roles || {})[oldId], undefined, 'no role rebuilt');
  assert.equal(pendingPairs(t), 0, 'no pairing rebuilt');
  assert.deepEqual(gameDiag(t), [0, 0]);
  assert.equal(untrusted(t), 0);
  const r = inject(FST);
  assert.equal(r.ok, true, JSON.stringify(plain(r)));
});

test('PS-38 (r6 22): 256 unanswered, the 257th is committed and fails, and the RESPONSE of the evicted #64000 arrives inside failSafe — the rollback does not revive 64000, so the next real send does not overflow', async () => {
  const { t, arm } = reenterInFailSafe(t => t.lobby.receive(response(64000, [8, 1])));
  const { inject } = injector11(t);
  for (let i = 0; i < 256; i++) t.lobby.send(request(64000 + i, BEAT));
  arm();
  t.lobby.send(request(64256, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[64256, 'local_error', 'bridge_error']]);
  assert.deepEqual(gameDiag(t), [255, 0]);
  t.lobby.send(request(64300, BEAT));
  const r = inject(FST);
  assert.equal(r.ok, true, JSON.stringify(plain(r)));
});

test('PS-39 (r6 23): rollback data lives only while a send is open — 4096 distinct sends keep 256 unanswered and no commit records, and 4096 re-sends of one number keep one', () => {
  const t = page();
  for (let i = 0; i < 4096; i++) t.lobby.send(request(1000 + i, BEAT));
  assert.deepEqual(gameDiag(t), [256, 0]);
  const u = page();
  for (let i = 0; i < 4096; i++) u.lobby.send(request(5000, BEAT));
  assert.deepEqual(gameDiag(u), [1, 0]);
});

test('PS-40 (r6 24): a socket still CONNECTING throws InvalidStateError on 257 sends — each failed send rolls its commit back and the error is rethrown, so injections work once it opens (fake socket model, not real WebKit)', () => {
  const t = page();
  const { inject } = injector11(t);
  const proto = Object.getPrototypeOf(t.lobby), send = proto.send;
  proto.send = function (d) { if (this.readyState === 0) { const e = new Error('still connecting'); e.name = 'InvalidStateError'; throw e; } return send.call(this, d); };
  const ws = new t.c.WebSocket('wss://route-4.maj-soul.com/gateway');
  ws.readyState = 0;
  for (let i = 0; i < 257; i++) assert.throws(() => ws.send(request(64000 + i, BEAT)), { name: 'InvalidStateError' });
  assert.equal(ws.sent.length, 0);
  assert.deepEqual(gameDiag(t), [0, 0]);
  ws.readyState = 1;
  const r = inject(FST);
  assert.equal(r.ok, true, JSON.stringify(plain(r)));
  assert.equal(r.msgId, 64000);
});

test('PS-41 (r6 25): at full capacity, re-sending the oldest number and failing after dispatch puts the earlier commit back (as the newest, not at its old FIFO spot) — still 256, no records left', async () => {
  let armed = 0;
  const t = page(source('naki-websocket.js'), { encode: d => { if (armed && --armed === 0) throw new Error('encode failed'); return Buffer.from(d).toString('base64'); } });
  guard11(t);
  const { inject } = injector11(t);
  for (let i = 0; i < 256; i++) t.lobby.send(request(64000 + i, BEAT));
  armed = 1;
  t.lobby.send(request(64000, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[64000, 'local_error', 'bridge_error']]);
  assert.deepEqual(gameDiag(t), [256, 0]);
  const r = inject(FST);
  assert.equal(r.ok, true, JSON.stringify(plain(r)));
  assert.equal(r.msgId >= 64256, true, String(r.msgId));
});

test('PS-43 (r6 23): a request committed by the dispatch and then sent as-is by failSafe (bridge error, no guard) is counted once and leaves no rollback record', () => {
  let armed = 0;
  const t = page(source('naki-websocket.js'), { encode: d => { if (armed && --armed === 0) throw new Error('encode failed'); return Buffer.from(d).toString('base64'); } });
  injector11(t);
  armed = 1;
  t.lobby.send(request(64000, BEAT));
  assert.equal(sentOn(t.lobby).includes(64000), true);
  assert.deepEqual(gameDiag(t), [1, 0]);
});

function heldBlob(t, bytes) {
  const blob = new t.c.Blob([bytes]);
  let open = null;
  blob.arrayBuffer = () => new Promise(resolve => { open = () => resolve(Blob.prototype.arrayBuffer.call(blob)); });
  return { blob, open: () => open() };
}

test('PS-46 (r8 31): BEAT#64000 goes out as TypedArray, its RESPONSE arrives as a Blob still unexpanded, the game then sends INFO#64000, and only then the Blob expands — the late RESPONSE consumes neither INFO\'s unanswered record nor its pairing', async () => {
  const t = page();
  const { inject } = injector11(t);
  const got = seen11(t, [INFO, BEAT]), payloads = [];
  t.c.__nakiPlugins.setGrant('pay46', { capabilities: ['observe'], methods: [INFO], priority: 400 });
  t.c.__nakiPlugins.register({ id: 'pay46', onReceive(ctx) { payloads.push(ctx.bytes[ctx.bytes.length - 1]); } });
  t.lobby.send(request(64000, BEAT));
  const held = heldBlob(t, response(64000, [8, 1]));
  t.lobby.dispatchEvent(new t.c.MessageEvent('message', { data: held.blob }));
  t.lobby.send(request(64000, INFO));
  held.open();
  await tick(); await tick();
  assert.deepEqual(gameDiag(t), [1, 0], 'INFO is still unanswered');
  assert.equal(untrusted(t), 0, 'a received Blob does not distrust the connection');
  assert.notEqual(inject(FST).msgId, 64000);
  t.lobby.receive(response(64000, [8, 2]));
  assert.deepEqual(plain(got), [INFO], 'the real INFO RESPONSE still resolves to INFO');
  assert.deepEqual(plain(payloads), [2], 'only the real INFO RESPONSE (payload 2), not the late Blob (payload 1)');
  assert.deepEqual(gameDiag(t), [0, 0]);
});

test('PS-49 (r8 31, no consumers): the same late Blob RESPONSE expanding while no plugin is active does not clear INFO\'s newer pairing — an observer registered afterwards still resolves the real RESPONSE to INFO', async () => {
  const t = page();
  injector11(t);
  t.lobby.send(request(64000, BEAT));
  const held = heldBlob(t, response(64000, [8, 1]));
  t.lobby.dispatchEvent(new t.c.MessageEvent('message', { data: held.blob }));
  t.lobby.send(request(64000, INFO));
  assert.equal(pendingPairs(t), 1);
  t.c.__nakiPlugins.disable('inj11');
  held.open();
  await tick(); await tick();
  assert.equal(pendingPairs(t), 1, 'the newer INFO pairing survives the late RESPONSE');
  assert.deepEqual(gameDiag(t), [1, 0]);
  const got = seen11(t, [INFO]);
  t.lobby.receive(response(64000, [8, 2]));
  assert.deepEqual(plain(got), [INFO]);
});

test('PS-47 (r8 32): a Blob sent on a released socket goes to the underlying send without marking anything — no lasting untrusted mark, injections on a new connection work', () => {
  const t = page();
  const { inject } = injector11(t);
  const old = t.lobby;
  old.close();
  old.send(new t.c.Blob([request(64000, BEAT)]));
  assert.equal(untrusted(t), 0);
  assert.deepEqual(gameDiag(t), [0, 0]);
  const fresh = new t.c.WebSocket('wss://route-4.maj-soul.com/gateway');
  fresh.send(request(1950, BEAT));
  fresh.receive(response(1950, [8, 1]));
  const r = inject(FST);
  assert.equal(r.ok, true, JSON.stringify(plain(r)));
});

test('PS-48 (r8 33): the deferred dispatch of a Blob send throws (an observer whose onSend getter throws) — no failSafe, nothing counted, the connection only stays untrusted', async () => {
  const t = page();
  injector11(t);
  let armed = false;
  t.c.__nakiPlugins.setGrant('bad33', { capabilities: ['observe'], methods: [BEAT] });
  t.c.__nakiPlugins.register({ id: 'bad33', get onSend() { if (armed) throw new Error('getter broke'); return () => {}; } });
  const before = t.lobby.sent.length;
  armed = true;
  t.lobby.send(new t.c.Blob([request(64000, BEAT)]));
  await tick(); await tick();
  assert.equal(t.lobby.sent.length, before + 1);
  assert.deepEqual(gameDiag(t), [0, 0]);
  assert.equal(untrusted(t), 1);
});

test('PS-50 (r9 34, r10 36): an old BEAT RESPONSE Blob still unexpanded holds back the INFO RESPONSE that arrives after it — INFO stays unanswered so an injection avoids 64000; once the Blob expands it claims nothing and INFO resolves with its own payload', async () => {
  const t = page();
  const { answers, inject } = injector11(t);
  const payloads = [];
  t.c.__nakiPlugins.setGrant('pay50', { capabilities: ['observe'], methods: [INFO, BEAT], priority: 400 });
  t.c.__nakiPlugins.register({ id: 'pay50', onReceive(ctx) { payloads.push([ctx.method, ctx.bytes[ctx.bytes.length - 1]]); } });
  t.lobby.send(request(64000, BEAT));
  const held = heldBlob(t, response(64000, [8, 1]));
  t.lobby.dispatchEvent(new t.c.MessageEvent('message', { data: held.blob }));
  t.lobby.send(request(64000, INFO));
  t.lobby.receive(response(64000, [8, 2]));
  assert.deepEqual(plain(payloads), [], 'the INFO RESPONSE waits behind the Blob');
  assert.deepEqual(gameDiag(t), [1, 0], 'INFO is unanswered until its RESPONSE is processed');
  const r = inject(FST);
  assert.notEqual(r.msgId, 64000);
  held.open();
  await tick(); await tick();
  assert.deepEqual(plain(payloads), [[INFO, 2]], 'the late Blob claims nothing; the INFO RESPONSE gets INFO');
  assert.deepEqual(gameDiag(t), [0, 0]);
  assert.equal(pendingPairs(t), 0);
  t.lobby.receive(response(r.msgId, [8, 1]));
  assert.deepEqual(plain(answers), [[r.msgId, FST]]);
  assert.equal(pendingInjections(t), 0);
});

test('PS-51 (r9 35, r10 36): with an old BEAT RESPONSE Blob still unexpanded, a later injection RESPONSE and the ambiguous INFO RESPONSE wait behind it — after the Blob expands the injection is answered first and the real INFO RESPONSE stays Naki traffic without replace', async () => {
  const t = page();
  const { answers, inject } = injector11(t);
  const seen = [];
  t.c.__nakiPlugins.setGrant('obs35', { capabilities: ['observe', 'rewriteReceive'], methods: [INFO], priority: 300, observeNakiTraffic: true });
  t.c.__nakiPlugins.register({ id: 'obs35', onReceive(ctx) { seen.push([ctx.bytes[ctx.bytes.length - 1], ctx.isNaki, typeof ctx.replace === 'function']); } });
  const r = inject(FST);
  assert.equal(r.msgId, 64000);
  for (let id = 60100; id < 60356; id++) t.c.__nakiWebSocket.sendRaw(b64(request(id, BEAT)));
  assert.equal(t.c.__nakiWebSocket.isNakiSent(64000, idOf(t, t.lobby)), false, 'the injection D22 entry was evicted');
  t.lobby.send(request(1960, BEAT));
  const held = heldBlob(t, response(1960, [8, 1]));
  t.lobby.dispatchEvent(new t.c.MessageEvent('message', { data: held.blob }));
  t.lobby.send(request(64000, INFO));
  t.lobby.receive(response(64000, [8, 3]));
  t.lobby.receive(response(64000, [8, 4]));
  assert.deepEqual(plain(answers), [], 'both RESPONSEs wait behind the Blob');
  held.open();
  await tick(); await tick();
  assert.deepEqual(plain(answers), [[64000, FST]]);
  assert.deepEqual(plain(seen), [[4, true, false]], 'the real INFO RESPONSE is observe-only Naki traffic');
});

test('PS-52 (r9 34, ambiguity): an injection RESPONSE arriving as a Blob and expanding after the game sent INFO on the same number claims the injection but marks no ambiguity — the real INFO RESPONSE goes to the general chain with replace', async () => {
  const t = page();
  const { answers, inject } = injector11(t);
  const seen = [];
  t.c.__nakiPlugins.setGrant('obs52', { capabilities: ['observe', 'rewriteReceive'], methods: [INFO], priority: 300, observeNakiTraffic: true });
  t.c.__nakiPlugins.register({ id: 'obs52', onReceive(ctx) { seen.push([ctx.bytes[ctx.bytes.length - 1], ctx.isNaki, typeof ctx.replace === 'function']); } });
  const r = inject(FST);
  assert.equal(r.msgId, 64000);
  for (let id = 60100; id < 60356; id++) t.c.__nakiWebSocket.sendRaw(b64(request(id, BEAT)));
  const held = heldBlob(t, response(64000, [8, 1]));
  t.lobby.dispatchEvent(new t.c.MessageEvent('message', { data: held.blob }));
  t.lobby.send(request(64000, INFO));
  held.open();
  await tick(); await tick();
  assert.deepEqual(plain(answers), [[64000, FST]]);
  t.lobby.receive(response(64000, [8, 2]));
  assert.deepEqual(plain(seen), [[2, false, true]], 'the game INFO RESPONSE is the game\'s own');
});

// ---- pair-source 第十輪：接收依抵達順序認領、歧義標記綁配對世代 ----
function rejectingBlob(t, bytes, sync = false) {
  const blob = new t.c.Blob([bytes]);
  let fail = null;
  blob.arrayBuffer = sync ? () => { throw new Error('expand broke'); } : () => new Promise((_, reject) => { fail = () => reject(new Error('expand broke')); });
  return { blob, fail: () => fail() };
}
function nakiObserver(t, id) {
  const seen = [];
  t.c.__nakiPlugins.setGrant(id, { capabilities: ['observe', 'rewriteReceive'], methods: [INFO], priority: 300, observeNakiTraffic: true });
  t.c.__nakiPlugins.register({ id, onReceive(ctx) { seen.push([ctx.bytes[ctx.bytes.length - 1], ctx.isNaki, typeof ctx.replace === 'function']); } });
  return seen;
}
const arrive = (t, data) => t.lobby.dispatchEvent(new t.c.MessageEvent('message', { data }));

test('PS-53 (r10 36): injected FST#64000, then the game sends INFO#64000; the FST RESPONSE arrives first as a Blob still unexpanded, the INFO RESPONSE second (TypedArray, or a Blob expanding first) — the FST RESPONSE (11) goes to onInjectResponse and the INFO RESPONSE (22) to INFO', async () => {
  for (const mode of ['blob then typed array', 'two blobs expanding in reverse']) {
    const t = page();
    const { answers, answerPayloads, inject } = injector11(t);
    const seen = nakiObserver(t, 'obs53');
    const r = inject(FST);
    assert.equal(r.msgId, 64000, mode);
    t.lobby.send(request(64000, INFO));
    const fst = heldBlob(t, response(64000, [8, 11]));
    arrive(t, fst.blob);
    if (mode === 'blob then typed array') {
      t.lobby.receive(response(64000, [8, 22]));
    } else {
      const info = heldBlob(t, response(64000, [8, 22]));
      arrive(t, info.blob);
      info.open();
      await tick(); await tick();
    }
    assert.deepEqual(plain(answerPayloads), [], mode + ': nothing is claimed before the first RESPONSE expands');
    fst.open();
    await tick(); await tick();
    assert.deepEqual(plain(answers), [[64000, FST]], mode);
    assert.deepEqual(plain(answerPayloads), [11], mode);
    assert.deepEqual(plain(seen), [[22, true, false]], mode + ': the INFO RESPONSE is INFO\'s, observe-only after the ambiguity');
    assert.equal(pendingPairs(t), 0, mode);
    assert.equal(pendingInjections(t), 0, mode);
  }
});

test('PS-54 (r10 37): injection FST#64000 with its D22 entry evicted, the game sends INFO#64000, both RESPONSEs arrive as Blobs and expand in order — the second is Naki traffic kept out of the general hook, and the next round of INFO#64000 is the game\'s own again', async () => {
  const t = page();
  const { answerPayloads, inject } = injector11(t);
  const seen = nakiObserver(t, 'obs54');
  const general = [];
  t.c.__nakiPlugins.setGrant('gen54', { capabilities: ['observe', 'rewriteReceive'], methods: [INFO], priority: 200 });
  t.c.__nakiPlugins.register({ id: 'gen54', onReceive(ctx) { general.push([ctx.bytes[ctx.bytes.length - 1], ctx.isNaki, typeof ctx.replace === 'function']); } });
  const r = inject(FST);
  assert.equal(r.msgId, 64000);
  for (let id = 60100; id < 60356; id++) t.c.__nakiWebSocket.sendRaw(b64(request(id, BEAT)));
  assert.equal(t.c.__nakiWebSocket.isNakiSent(64000, idOf(t, t.lobby)), false, 'the injection D22 entry was evicted');
  t.lobby.send(request(64000, INFO));
  const first = heldBlob(t, response(64000, [8, 11])), second = heldBlob(t, response(64000, [8, 22]));
  arrive(t, first.blob);
  arrive(t, second.blob);
  first.open();
  await tick(); await tick();
  second.open();
  await tick(); await tick();
  assert.deepEqual(plain(answerPayloads), [11]);
  assert.deepEqual(plain(seen), [[22, true, false]]);
  assert.deepEqual(plain(general), [], 'the second RESPONSE never reaches the general hook');
  t.lobby.send(request(64000, INFO));
  t.lobby.receive(response(64000, [8, 33]));
  assert.deepEqual(plain(general), [[33, false, true]], 'the mark was consumed; the next INFO RESPONSE is the game\'s own');
  assert.deepEqual(plain(seen), [[22, true, false], [33, false, true]]);
});

test('PS-55 (r10 36, r11 39): a received Blob whose expansion rejects (or throws synchronously) makes the connection receive-untrusted — the TypedArray queued behind it is still dispatched in order but observe-only, later RESPONSEs too, and nothing waits forever', async () => {
  for (const sync of [false, true]) {
    const label = sync ? 'sync throw' : 'rejected';
    const t = page();
    const { inject } = injector11(t);
    const seen = nakiObserver(t, 'obs55');
    t.lobby.send(request(1970, INFO));
    const bad = rejectingBlob(t, response(1970, [8, 1]), sync);
    t.lobby.send(request(1971, INFO));
    arrive(t, bad.blob);
    t.lobby.receive(response(1971, [8, 2]));
    if (!sync) { assert.deepEqual(plain(seen), [], label + ': queued'); bad.fail(); }
    await tick(); await tick();
    assert.deepEqual(plain(seen), [[2, true, false]], label + ': the TypedArray behind the failed Blob is observe-only');
    assert.equal(t.c.__nakiPlugins.diagnostics().receiveLost, 1, label);
    assert.equal(inject(FST).ok, false, label + ': no new injection while receive-untrusted');
    t.lobby.send(request(1973, INFO));
    t.lobby.receive(response(1973, [8, 4]));
    assert.deepEqual(plain(seen), [[2, true, false], [4, true, false]], label + ': later RESPONSEs are synchronous but still observe-only');
    assert.equal(pendingPairs(t), 1, label + ': only the pairing of the lost RESPONSE remains');
    assert.deepEqual(plain(t.c.__nakiWebSocket.diagnostics().recvQueue), [], label + ': the queue drained');
  }
});

test('PS-56 (r10 36, close): the connection closes while a Blob is unexpanded with a TypedArray queued behind it — the queue is dropped, nothing is dispatched after the close', async () => {
  const t = page();
  const NOTE = '.lq.NotifyAccountUpdate', m = Buffer.from(NOTE);
  const got = seen11(t, [INFO, NOTE]);
  t.lobby.send(request(1980, INFO));
  const held = heldBlob(t, response(1980, [8, 1]));
  arrive(t, held.blob);
  t.lobby.receive(new Uint8Array([1, 10, m.length, ...m, 18, 0]));
  t.lobby.close();
  held.open();
  await tick(); await tick();
  assert.deepEqual(plain(got), [], 'neither the Blob nor the NOTIFY queued behind it is dispatched');
  assert.equal(pendingPairs(t), 0);
});

test('PS-57 (r10 36, bridge): a TypedArray queued behind an unexpanded Blob whose Swift delivery throws still takes its place in the queue — it is dispatched after the Blob and the queue drains', async () => {
  let armed = false;
  const t = page(source('naki-websocket.js'), { swiftFails: (type, d) => armed && type === 'websocket_message' && d.type === 'binary' && d.direction === 'receive' });
  const got = seen11(t, [INFO]);
  t.lobby.send(request(1990, INFO));
  t.lobby.send(request(1991, INFO));
  const held = heldBlob(t, response(1990, [8, 1]));
  arrive(t, held.blob);
  armed = true;
  t.lobby.receive(response(1991, [8, 2]));
  armed = false;
  held.open();
  await tick(); await tick();
  assert.deepEqual(plain(got), [INFO, INFO]);
  t.lobby.send(request(1992, INFO));
  t.lobby.receive(response(1992, [8, 3]));
  assert.deepEqual(plain(got), [INFO, INFO, INFO], 'later traffic is synchronous again');
});

test('PS-58 (r10 36, watermark kept): BEAT#64000 is answered, then a stray duplicate RESPONSE for 64000 arrives as a Blob still unexpanded and an injection takes the now free 64000 — the stray claims nothing (with and without consumers) and the real FST RESPONSE reaches onInjectResponse', async () => {
  for (const consumers of [true, false]) {
    const label = consumers ? 'with consumers' : 'zero-consumer branch';
    const t = page();
    const { answers, answerPayloads, inject } = injector11(t);
    t.lobby.send(request(64000, BEAT));
    t.lobby.receive(response(64000, [8, 1]));
    const stray = heldBlob(t, response(64000, [8, 2]));
    arrive(t, stray.blob);
    const r = inject(FST);
    assert.equal(r.msgId, 64000, label);
    if (!consumers) t.c.__nakiPlugins.disable('inj11');
    stray.open();
    await tick(); await tick();
    assert.equal(pendingInjections(t), 1, label + ': the injection is still registered');
    assert.deepEqual(plain(answers), [], label);
    if (!consumers) continue;
    t.lobby.receive(response(64000, [8, 3]));
    assert.deepEqual(plain(answers), [[64000, FST]], label);
    assert.deepEqual(plain(answerPayloads), [3], label);
  }
});

// ---- pair-source 第十一輪：接收讀取失敗＝接收不可信、flush 重入排隊、遮罩後快照、佇列容量 ----
test('PS-59 (r11 39): injected FST#64000, the game sends INFO#64000, the FST RESPONSE Blob fails to read (reject or sync throw), the INFO RESPONSE (22) arrives as a TypedArray — FST gets response_lost, INFO\'s RESPONSE never reaches FST and is observe-only', async () => {
  for (const sync of [false, true]) {
    const label = sync ? 'sync throw' : 'rejected';
    const t = page();
    const { answers, answerErrors, inject } = injector11(t);
    const seen = nakiObserver(t, 'obs59'), general = [];
    t.c.__nakiPlugins.setGrant('gen59', { capabilities: ['observe'], methods: [INFO], priority: 200 });
    t.c.__nakiPlugins.register({ id: 'gen59', onReceive(ctx) { general.push(ctx.bytes[ctx.bytes.length - 1]); } });
    const r = inject(FST);
    assert.equal(r.msgId, 64000, label);
    t.lobby.send(request(64000, INFO));
    const bad = rejectingBlob(t, response(64000, [8, 11]), sync);
    arrive(t, bad.blob);
    t.lobby.receive(response(64000, [8, 22]));
    if (!sync) bad.fail();
    await tick(); await tick();
    assert.deepEqual(plain(answers), [[64000, FST]], label);
    assert.deepEqual(plain(answerErrors), ['response_lost'], label);
    assert.equal(pendingInjections(t), 0, label);
    assert.deepEqual(plain(seen), [[22, true, false]], label + ': INFO\'s RESPONSE is observe-only');
    assert.deepEqual(plain(general), [], label);
    assert.deepEqual(gameDiag(t), [0, 0], label + ': INFO\'s unanswered record is still consumed');
    assert.equal(pendingPairs(t), 0, label);
    assert.equal(untrusted(t), 1, label);
  }
});

test('PS-60 (r11 40): while the last queued item is being dispatched, observer A synchronously delivers RESPONSE #3 — it is queued behind the current item, so the hook order is A1, B1, A3, B3', async () => {
  const t = page();
  const order = [];
  let reentered = false;
  t.c.__nakiPlugins.setGrant('a60', { capabilities: ['observe'], methods: [INFO], priority: 500 });
  t.c.__nakiPlugins.register({ id: 'a60', onReceive(ctx) {
    order.push('A' + ctx.msgId % 10);
    if (!reentered) { reentered = true; t.lobby.receive(response(2003, [8, 3])); }
  } });
  t.c.__nakiPlugins.setGrant('b60', { capabilities: ['observe'], methods: [INFO], priority: 600 });
  t.c.__nakiPlugins.register({ id: 'b60', onReceive(ctx) { order.push('B' + ctx.msgId % 10); } });
  t.lobby.send(request(2001, INFO));
  t.lobby.send(request(2003, INFO));
  const held = heldBlob(t, response(2001, [8, 1]));
  arrive(t, held.blob);
  held.open();
  await tick(); await tick();
  assert.deepEqual(plain(order), ['A1', 'B1', 'A3', 'B3']);
  assert.deepEqual(plain(t.c.__nakiWebSocket.diagnostics().recvQueue), []);
});

test('PS-61 (r11 41, r12 44): with the nickname mask on and a Blob unexpanded, an authGame RESPONSE arriving as a TypedArray is the same masked content for plugins, the game and Swift; if the mask throws (before or after changing the bytes) all three get the original bytes and the queue still drains', async () => {
  for (const mode of ['mask works', 'mask throws before changing', 'mask throws after changing']) {
    const label = mode, broken = mode !== 'mask works';
    const t = page();
    t.c.__nakiHideNames.setEnabled(true);
    const seen = [];
    t.c.__nakiPlugins.setGrant('auth61', { capabilities: ['observe'], methods: [AUTH] });
    t.c.__nakiPlugins.register({ id: 'auth61', onReceive(ctx) { seen.push(Array.from(ctx.bytes)); } });
    t.lobby.send(request(2010, INFO));
    t.lobby.send(request(2011, AUTH));
    const held = heldBlob(t, response(2010, [8, 1]));
    arrive(t, held.blob);
    const name = [...Buffer.from('Alice')], view = [0x22, name.length, ...name];
    const real = t.c.__nakiHideNames.observe;
    if (mode === 'mask throws before changing') t.c.__nakiHideNames.observe = () => { throw new Error('mask broke'); };
    if (mode === 'mask throws after changing') t.c.__nakiHideNames.observe = (v, d) => { real(v, d); throw new Error('mask broke late'); };
    t.lobby.receive(response(2011, [18, view.length, ...view]));
    held.open();
    await tick(); await tick();
    const game = t.game.slice(-1)[0], swift = t.toSwift('receive').find(b => b[0] === 3 && (b[1] | (b[2] << 8)) === 2011);
    assert.equal(Buffer.from(game.slice(-5)).toString(), broken ? 'Alice' : 'P1   ', label);
    assert.deepEqual(plain(seen), [game], label + ': the plugin sees what the game got');
    assert.deepEqual(swift, game, label + ': Swift too');
  }
});

test('PS-62 (r11 42): a Blob that never settles holds 256 queued items (diagnostics show the length and the head wait); the 257th makes the connection receive-untrusted, abandons the Blob, drains the queue observe-only and closes the pending injection with response_lost', async () => {
  const t = page();
  const { answerErrors, inject } = injector11(t);
  const seen = nakiObserver(t, 'obs62');
  assert.equal(inject(FST).msgId, 64000);
  t.lobby.send(request(2020, INFO));
  const held = heldBlob(t, response(2020, [8, 1]));
  arrive(t, held.blob);
  for (let i = 0; i < 255; i++) t.lobby.receive(response(30000 + i, [8, 2]));
  const d = plain(t.c.__nakiWebSocket.diagnostics().recvQueue);
  assert.equal(d.length, 1);
  assert.equal(d[0].length, 256);
  assert.equal(typeof d[0].headWaitMs, 'number');
  assert.deepEqual(plain(answerErrors), []);
  t.lobby.send(request(2021, INFO));
  t.lobby.receive(response(2021, [8, 3]));
  assert.deepEqual(plain(answerErrors), ['response_lost']);
  assert.deepEqual(plain(t.c.__nakiWebSocket.diagnostics().recvQueue), []);
  assert.equal(t.c.__nakiPlugins.diagnostics().receiveLost, 1);
  assert.deepEqual(plain(seen), [[3, true, false]], 'the 257th is dispatched observe-only');
  held.open();
  await tick(); await tick();
  assert.deepEqual(plain(seen), [[3, true, false]], 'the abandoned Blob is never dispatched');
  t.lobby.close();
  assert.equal(t.c.__nakiPlugins.diagnostics().receiveLost, 0, 'closing clears receive-untrusted');
  assert.equal(untrusted(t), 0);
});

// ---- pair-source 第十二輪：在途注入遇接收不可信、遮罩改後拋錯還原、NOTIFY 也只觀察 ----
test('PS-63 (r12 43): an observer of the injected FST synchronously makes the connection receive-untrusted inside sendRaw (a Blob that throws on read, or the 257th queued item) — the injection is not registered, FST gets response_lost on the next tick, and the later RESPONSE (22) on the same number never reaches FST', async () => {
  for (const how of ['read throws', 'queue overflow']) {
    const t = page();
    const { answers, answerErrors, answerPayloads, inject } = injector11(t);
    let armed = false;
    t.c.__nakiPlugins.setGrant('sab63', { capabilities: ['observe'], methods: [FST], priority: 700, observeNakiTraffic: true });
    t.c.__nakiPlugins.register({ id: 'sab63', onSend() {
      if (!armed) return;
      armed = false;
      if (how === 'read throws') { arrive(t, rejectingBlob(t, response(2030, [8, 1]), true).blob); return; }
      arrive(t, heldBlob(t, response(2030, [8, 1])).blob);
      for (let i = 0; i < 256; i++) t.lobby.receive(response(31000 + i, [8, 2]));
    } });
    armed = true;
    const r = inject(FST);
    assert.equal(r.ok, true, how);
    assert.equal(r.msgId, 64000, how);
    assert.equal(t.c.__nakiPlugins.diagnostics().receiveLost, 1, how);
    assert.equal(pendingInjections(t), 0, how + ': not registered');
    assert.deepEqual(plain(answerErrors), [], how + ': not yet, the plugin first gets its msgId');
    await tick();
    assert.deepEqual(plain(answers), [[64000, FST]], how);
    assert.deepEqual(plain(answerErrors), ['response_lost'], how);
    t.lobby.receive(response(64000, [8, 22]));
    assert.deepEqual(plain(answers), [[64000, FST]], how + ': the later RESPONSE never reaches FST');
    assert.equal(answerPayloads.includes(22), false, how);
  }
});

test('PS-64 (r12 45): after a NOTIFY Blob fails to read, the next NOTIFY on that connection is observe-only too — no general hook, no replace, no drop', async () => {
  const t = page();
  const NOTE = '.lq.NotifyAccountUpdate', m = Buffer.from(NOTE);
  const note = p => new Uint8Array([1, 10, m.length, ...m, 18, 1, p]);
  const general = [], seen = [];
  t.c.__nakiPlugins.setGrant('gen64', { capabilities: ['observe', 'rewriteReceive'], methods: [NOTE], priority: 200 });
  t.c.__nakiPlugins.register({ id: 'gen64', onReceive(ctx) { general.push(ctx.bytes[ctx.bytes.length - 1]); } });
  t.c.__nakiPlugins.setGrant('naki64', { capabilities: ['observe', 'rewriteReceive'], methods: [NOTE], priority: 300, observeNakiTraffic: true });
  t.c.__nakiPlugins.register({ id: 'naki64', onReceive(ctx) { seen.push([ctx.bytes[ctx.bytes.length - 1], ctx.isNaki, typeof ctx.replace === 'function', typeof ctx.drop === 'function']); } });
  t.lobby.receive(note(1));
  assert.deepEqual(plain(general), [1], 'before the failure NOTIFY goes to the general chain');
  const bad = rejectingBlob(t, note(2));
  arrive(t, bad.blob);
  bad.fail();
  await tick(); await tick();
  t.lobby.receive(note(3));
  assert.deepEqual(plain(general), [1], 'after the failure no general hook sees NOTIFY');
  assert.deepEqual(plain(seen).slice(-1), [[3, true, false, false]]);
});

// ---- pair-source 第十三輪（復驗回饋）：nextSeq 重入、注入登記淘汰結案 ----
test('PS-65 (r13 verify cx1): same-realm code wraps sendRaw and nextSeq and, inside the first nextSeq after sendRaw, delivers a Blob that throws on read — the injection is not registered, FST gets response_lost on the next tick, and the later RESPONSE (22) never reaches FST', async () => {
  const t = page();
  const { answers, answerErrors, answerReasons, answerPayloads, inject } = injector11(t);
  const ws = t.c.__nakiWebSocket, origRaw = ws.sendRaw, origSeq = ws.nextSeq;
  let armed = false;
  ws.sendRaw = function (b, s) { const r = origRaw.call(this, b, s); armed = true; return r; };
  ws.nextSeq = function () {
    if (armed) { armed = false; arrive(t, rejectingBlob(t, response(2040, [8, 1]), true).blob); }
    return origSeq.call(this);
  };
  const r = inject(FST);
  ws.sendRaw = origRaw; ws.nextSeq = origSeq;
  assert.equal(r.ok, true);
  assert.equal(t.c.__nakiPlugins.diagnostics().receiveLost, 1);
  assert.equal(pendingInjections(t), 0, 'not registered');
  await tick();
  assert.deepEqual(plain(answers), [[r.msgId, FST]]);
  assert.deepEqual(plain(answerErrors), ['response_lost']);
  assert.deepEqual(plain(answerReasons), ['receive_untrusted']);
  t.lobby.receive(response(r.msgId, [8, 22]));
  assert.deepEqual(plain(answers), [[r.msgId, FST]]);
  assert.equal(answerPayloads.includes(22), false);
});

test('PS-66 (r13): the 257th pending injection evicts the oldest — the evicted one is closed with response_lost (reason evicted) on the next tick instead of disappearing, and its late RESPONSE is not an injection answer', async () => {
  const t = page();
  const { answers, answerErrors, answerReasons, inject } = injector11(t);
  const ids = [];
  for (let i = 0; i < 257; i++) { const r = inject(FST); assert.equal(r.ok, true, 'injection ' + i); ids.push(r.msgId); }
  assert.equal(pendingInjections(t), 256);
  assert.deepEqual(plain(answers), [], 'not synchronously inside sendRequest');
  await tick();
  assert.deepEqual(plain(answers), [[ids[0], FST]]);
  assert.deepEqual(plain(answerErrors), ['response_lost']);
  assert.deepEqual(plain(answerReasons), ['evicted']);
  t.lobby.receive(response(ids[0], [8, 1]));
  assert.equal(plain(answers).length, 1, 'the evicted injection\'s late RESPONSE is not delivered again');
  t.lobby.receive(response(ids[1], [8, 1]));
  assert.deepEqual(plain(answers).slice(-1), [[ids[1], FST]]);
  assert.deepEqual(plain(answerErrors).slice(-1), [null]);
});

test('PS-67 (r14 verify cx4): a wrapped sendRaw returns socketId as a getter (or a prototype setter catches token.socketId) that delivers a Blob throwing on read — the host reads socketId once; whenever the connection turns receive-untrusted before the check, the injection is not registered and FST gets response_lost; a reentry the host never triggers leaves a normal injection, never an orphan', async () => {
  for (const mode of ['getter reentry on read 1', 'getter reentry on read 2', 'prototype setter reentry']) {
    const t = page();
    const { answers, answerErrors, answerReasons, answerPayloads, inject } = injector11(t);
    const ws = t.c.__nakiWebSocket, origRaw = ws.sendRaw;
    const breakReceive = () => arrive(t, rejectingBlob(t, response(2050, [8, 1]), true).blob);
    let reads = 0;
    const O = vm.runInContext('Object', t.c);
    ws.sendRaw = function (b, s) {
      const r = origRaw.call(this, b, s);
      if (mode === 'prototype setter reentry') return r;
      return { success: r.success, get socketId() {
        reads++;
        if (reads === (mode === 'getter reentry on read 1' ? 1 : 2)) breakReceive();
        return r.socketId;
      } };
    };
    if (mode === 'prototype setter reentry') {
      O.defineProperty(O.prototype, 'socketId', { configurable: true, set(v) {
        O.defineProperty(this, 'socketId', { value: v, writable: true, enumerable: true, configurable: true });
        breakReceive();
      } });
    }
    let r;
    try { r = inject(FST); } finally { ws.sendRaw = origRaw; delete O.prototype.socketId; }
    assert.equal(r.ok, true, mode);
    if (mode !== 'prototype setter reentry') assert.equal(reads, 1, mode + ': socketId is read exactly once');
    await tick();
    if (mode === 'getter reentry on read 2') {
      assert.equal(t.c.__nakiPlugins.diagnostics().receiveLost, 0, mode + ': never triggered');
      assert.equal(pendingInjections(t), 1, mode);
      t.lobby.receive(response(r.msgId, [8, 22]));
      assert.deepEqual(plain(answerPayloads), [22], mode + ': a normal injection answered normally');
      continue;
    }
    assert.equal(t.c.__nakiPlugins.diagnostics().receiveLost, 1, mode);
    assert.equal(pendingInjections(t), 0, mode + ': not registered');
    assert.deepEqual(plain(answers), [[r.msgId, FST]], mode);
    assert.deepEqual(plain(answerErrors), ['response_lost'], mode);
    assert.deepEqual(plain(answerReasons), ['receive_untrusted'], mode);
    t.lobby.receive(response(r.msgId, [8, 22]));
    assert.equal(answerPayloads.includes(22), false, mode);
  }
});

// 第十四輪：sendRequest 期間每個頁面程式可介入的點逐一讓連線接收不可信，斷言沒有孤兒登記（PS89 存活的可實跑證明）
const REENTRY_POINTS = ['inside sendRaw', 'success getter', 'nextSeq', 'socketId getter', 'socketId toString', 'seq setter', 'socketId setter', 'msgId setter', 'log bridge after registration'];
test('PS-68 (r14): at every point where page code can run during sendRequest, making the connection receive-untrusted never leaves an orphan injection — not registered, response_lost exactly once, the later RESPONSE never reaches FST', async () => {
  for (const point of REENTRY_POINTS) {
    let fire = null;
    const t = page(source('naki-websocket.js'), { swiftFails: (type, d) => {
      if (point === 'log bridge after registration' && fire && type === 'plugin_event' && /sendRequest .*fetchServerTime/.test(d.msg)) fire();
      return false;
    } });
    const { answers, answerErrors, answerPayloads, inject } = injector11(t);
    const O = vm.runInContext('Object', t.c);
    const ws = t.c.__nakiWebSocket, origRaw = ws.sendRaw, origSeq = ws.nextSeq;
    let fired = false;
    fire = () => { if (fired) return; fired = true; arrive(t, rejectingBlob(t, response(2060, [8, 1]), true).blob); };
    ws.sendRaw = function (b, s) {
      const r = origRaw.call(this, b, s);
      if (point === 'inside sendRaw') fire();
      return { get success() { if (point === 'success getter') fire(); return r.success; },
        get socketId() {
          if (point === 'socketId getter') fire();
          if (point === 'socketId toString') return { toString() { fire(); return String(r.socketId); } };
          return r.socketId;
        } };
    };
    ws.nextSeq = function () { if (point === 'nextSeq') fire(); return origSeq.call(this); };
    const prop = { 'seq setter': 'seq', 'socketId setter': 'socketId', 'msgId setter': 'msgId' }[point];
    if (prop) O.defineProperty(O.prototype, prop, { configurable: true, set(v) {
      O.defineProperty(this, prop, { value: v, writable: true, enumerable: true, configurable: true });
      fire();
    } });
    let r;
    try { r = inject(FST); } finally { ws.sendRaw = origRaw; ws.nextSeq = origSeq; if (prop) delete O.prototype[prop]; }
    assert.equal(fired, true, point + ': the reentry point was reached');
    assert.equal(r.ok, true, point);
    assert.equal(pendingInjections(t), 0, point + ': no orphan registration');
    await tick();
    assert.deepEqual(plain(answerErrors), ['response_lost'], point + ': closed exactly once');
    assert.equal(plain(answers)[0][0], r.msgId, point);
    t.lobby.receive(response(r.msgId, [8, 22]));
    assert.equal(answerPayloads.includes(22), false, point);
  }
});

test('PS-25 (r4 17): a token captured by wrapping sendRaw is dead once the call returns — replaying it goes out as plain Naki traffic in the shared table, not as an injection', () => {
  const t = page();
  const { answers, inject } = injector11(t);
  const ws = t.c.__nakiWebSocket, orig = ws.sendRaw;
  let captured;
  ws.sendRaw = function (b, s) { captured = s; return orig.call(this, b, s); };
  const r = inject(FST);
  ws.sendRaw = orig;
  t.lobby.receive(response(r.msgId, [8, 1]));
  assert.deepEqual(answers, [[r.msgId, FST]]);
  assert.equal(pendingPairs(t), 0);
  assert.equal(ws.sendRaw(b64(request(64400, FST)), captured).success, true);
  assert.equal(pendingInjections(t), 0);
  assert.equal(pendingPairs(t), 1, 'the replay pairs like any sendRaw');
  t.lobby.receive(response(64400, [8, 1]));
  assert.deepEqual(answers, [[r.msgId, FST]], 'no injection answer for the replay');
  assert.equal(pendingPairs(t), 0);
});

test('PS-26 (r4 18): an outer wrapper that loses the token (new Uint8Array view, slice copy, sendRaw without the token) turns the injection into plain traffic — its pairing stays after the RESPONSE, while the D22 identity and the injection answer stay intact', () => {
  const wraps = {
    view: t => { const o = t.lobby.send.bind(t.lobby); t.lobby.send = d => o(d instanceof ArrayBuffer ? new Uint8Array(d) : d); },
    slice: t => { const o = t.lobby.send.bind(t.lobby); t.lobby.send = d => o(d instanceof ArrayBuffer ? d.slice(0) : d); },
    dropToken: t => { const ws = t.c.__nakiWebSocket, o = ws.sendRaw; ws.sendRaw = b => o.call(ws, b); },
  };
  for (const [label, wrap] of Object.entries(wraps)) {
    const t = page();
    const { answers, inject } = injector11(t);
    wrap(t);
    assert.equal(pendingPairs(t), 0, label);
    const r = inject(FST);
    assert.equal(r.ok, true, label);
    assert.equal(pendingPairs(t), 1, label + ': the injection landed in the shared table');
    assert.equal(t.c.__nakiWebSocket.isNakiSent(r.msgId, idOf(t, t.lobby)), true, label + ': D22 identity is independent of the token');
    t.lobby.receive(response(r.msgId, [8, 1]));
    assert.deepEqual(answers, [[r.msgId, FST]], label);
    assert.equal(pendingPairs(t), 1, label + ': the pairing stays after the RESPONSE');
  }
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

// ---- guard-gaps 第十二輪（Astra guard-gaps 第十一輪 1 條）：所有配對寫入共用容量上限、零插件不登記、關閉清該連線 ----

test('GG12-1 (Astra11 1): pairings never accumulate — zero plugins with a broken bridge leave none after 300 round trips, also after close and reconnect; with plugins the table stays at PENDING_LIMIT and close clears that connection', async () => {
  {
    const t = page(source('naki-websocket.js'), { breakBase64: true });
    const round = async ws => {
      for (let i = 0; i < 300; i++) ws.send(request(1900 + i, BEAT));
      await tick();
      for (let i = 0; i < 300; i++) ws.receive(response(1900 + i, [8, 1]));
      assert.equal(ws.sent.length, 300);
      assert.equal(pendingPairs(t), 0);
    };
    await round(t.lobby);
    t.lobby.close();
    const again = new t.c.WebSocket('wss://route-4.maj-soul.com/gateway');
    await round(again);
    again.close();
    assert.equal(pendingPairs(t), 0);
  }
  for (const broken of [false, true]) {
    const label = broken ? 'bridge error' : 'healthy';
    const t = page(source('naki-websocket.js'), { breakBase64: broken });
    seen11(t, [INFO]);
    for (let i = 0; i < 300; i++) t.lobby.send(request(2300 + i, BEAT));
    await tick();
    assert.equal(pendingPairs(t), 256, label);
    const other = new t.c.WebSocket('wss://route-4.maj-soul.com/gateway');
    for (let i = 0; i < 10; i++) other.send(request(2700 + i, BEAT));
    await tick();
    assert.equal(pendingPairs(t), 256, label);
    t.lobby.close();
    assert.equal(pendingPairs(t), 10, label + ': close clears only that connection');
    other.close();
    assert.equal(pendingPairs(t), 0, label);
  }
});

// ---- guard-gaps 第十三輪（Astra guard-gaps 第十二輪 1–2 條）：沒人消耗時只撤銷舊配對、不留鏈首的舊值 ----
test('GG13-1 (Astra12 1): the only plugin replaces INFO→loginBeat and disables itself in the same onSend — the wire carries loginBeat and the stale INFO pairing is revoked; with another plugin still present it is corrected to loginBeat', async () => {
  for (const alone of [true, false]) {
    const label = alone ? 'only plugin' : 'another plugin stays';
    const t = page();
    t.c.__nakiPluginsMayModifyOutbound = true;
    if (!alone) seen11(t, [TITLE]);
    t.c.__nakiPlugins.setGrant('rw13', { capabilities: ['observe', 'rewriteSend'], methods: [INFO], priority: 1 });
    t.c.__nakiPlugins.register({ id: 'rw13', onSend(ctx) {
      assert.equal(ctx.replace(request(ctx.msgId, BEAT)), true);
      t.c.__nakiPlugins.disable('rw13');
    } });
    t.lobby.send(request(2000, INFO, [8, 1]));
    await tick();
    assert.deepEqual(t.lobby.committed.map(d => methodOf(Uint8Array.from(d))), [BEAT], label);
    assert.equal(pendingPairs(t), alone ? 0 : 1, label);
    const got = seen11(t, [INFO, BEAT]);
    t.lobby.receive(response(2000, [8, 1]));
    assert.deepEqual(plain(got), alone ? [] : [BEAT], label);
  }
});

test('GG13-2 (Astra12 2): a page with taint but no registered plugin still has consumers — pairings are kept until the RESPONSE consumes them', async () => {
  const t = page();
  guardPlugin(t.c);
  pollute(t);
  t.c.__nakiPlugins.disable(ID);
  assert.deepEqual(plain(t.c.__nakiPlugins.list()), []);
  t.lobby.send(request(2010, BEAT));
  assert.equal(pendingPairs(t), 1);
  t.lobby.receive(response(2010, [8, 1]));
  assert.equal(pendingPairs(t), 0);
});

// ---- guard-gaps 第十四輪（Astra guard-gaps 第十三輪 1 條）：沒人消耗時，配對的消耗照常 ----
test('GG14-1 (Astra13 1): INFO sent, the only plugin disabled, INFO answered to the game, the msgId reused for loginBeat — a later observer never sees INFO (answered or not, observer before or after the reuse)', async () => {
  for (const [answered, early] of [[true, false], [true, true], [false, false]]) {
    const label = (answered ? 'INFO answered' : 'INFO unanswered') + (early ? ', observer before reuse' : ', observer after reuse');
    const t = page();
    seen11(t, [INFO]);
    t.lobby.send(request(2100, INFO));
    assert.equal(pendingPairs(t), 1, label);
    plain(t.c.__nakiPlugins.list()).forEach(p => t.c.__nakiPlugins.disable(p.id));
    if (answered) {
      t.lobby.receive(response(2100, [8, 1]));
      assert.equal(t.game.length, 1, label);
      assert.equal(pendingPairs(t), 0, label + ': the RESPONSE consumes the pairing even with no consumers');
    }
    let got = early ? seen11(t, [INFO, BEAT]) : null;
    t.lobby.send(request(2100, BEAT));
    if (!early) {
      assert.equal(pendingPairs(t), 0, label + ': the reused msgId revokes the old pairing');
      got = seen11(t, [INFO, BEAT]);
    }
    t.lobby.receive(response(2100, [8, 1]));
    assert.deepEqual(plain(got), early ? [BEAT] : [], label);
  }
});

test('GG14-2 (verifier VB2): overwriting a key moves it to the newest position — with the table full, rewrite A then add 255 new keys: A survives and the oldest other key is evicted', async () => {
  const t = page();
  const got = seen11(t, [INFO, BEAT]);
  for (let i = 0; i < 256; i++) t.lobby.send(request(3000 + i, INFO));
  assert.equal(pendingPairs(t), 256);
  t.lobby.send(request(3000, BEAT));
  for (let i = 0; i < 255; i++) t.lobby.send(request(3300 + i, INFO));
  await tick();
  assert.equal(pendingPairs(t), 256);
  t.lobby.receive(response(3001, [8, 1]));
  t.lobby.receive(response(3000, [8, 1]));
  assert.deepEqual(plain(got), [BEAT], 'A (rewritten as loginBeat) is still paired; 3001 was evicted');
});

// ---- inject-receive：injectReceive、respondLocally、連線退化事件（docs/archive/plan/inject-receive-design-2026-10-18.md）----
const NOTE = '.lq.NotifyRoomPlayerUpdate';
function notifyMsg(method, payload = []) {
  const m = Buffer.from(method);
  return new Uint8Array([1, 10, m.length, ...m, 18, payload.length, ...payload]);
}
// 剛好 total bytes 的合法 NOTIFY（payload 長度用 3 byte varint）
function bigNotify(total) {
  const m = Buffer.from(NOTE), plen = total - 7 - m.length, b = new Uint8Array(total);
  b.set([1, 10, m.length, ...m, 18, (plen & 0x7f) | 0x80, ((plen >> 7) & 0x7f) | 0x80, plen >> 14]);
  return b;
}
const WRITE_FNS = ['replace', 'drop', 'sendRequest', 'injectReceive', 'respondLocally'];
const writeFns = ctx => WRITE_FNS.filter(k => typeof ctx[k] === 'function');
function irPlugin(t, id, grant, spec) {
  t.c.__nakiPluginsMayModifyOutbound = true;
  t.c.__nakiPlugins.setGrant(id, grant);
  assert.equal(t.c.__nakiPlugins.register({ id, ...spec }), true);
}
function nakiNoteObserver(t, id, methods = [NOTE]) {
  const seen = [];
  irPlugin(t, id, { capabilities: ['observe', 'rewriteReceive', 'dropReceive', 'injectSend', 'injectReceive'], methods, observeNakiTraffic: true },
    { onReceive(ctx) { seen.push([ctx.method, ctx.isNaki, ctx.synthetic || null, ctx.syntheticBy || null, writeFns(ctx)]); } });
  return seen;
}
// 一個在 onSend 存下 ctx 的插件（之後在 hook 外呼叫，或檢查函式有無）
function ctxKeeper(t, id, caps, methods = [INFO], grant = {}) {
  const ctxs = [];
  irPlugin(t, id, { capabilities: ['observe', ...caps], methods, ...grant }, { onSend(ctx) { ctxs.push(ctx); }, onReceive(ctx) { ctxs.push(ctx); } });
  return ctxs;
}

test('IR-1: injectReceive inside onReceive — the game gets the current RESPONSE first and the synthetic NOTIFY on a later task (not a microtask); Swift sees each once, the synthetic marked; only Naki observers see it, marked and without write functions; no record is touched', async () => {
  const t = page();
  const { inject } = injector11(t);
  assert.equal(inject(FST).ok, true);
  t.lobby.send(request(1500, INFO));
  const results = [];
  irPlugin(t, 'ir1', { capabilities: ['observe', 'injectReceive'], methods: [INFO] },
    { onReceive(ctx) { results.push(plain(ctx.injectReceive(notifyMsg(NOTE, [7])))); } });
  const naki = nakiNoteObserver(t, 'obsN'), general = [];
  irPlugin(t, 'obsG', { capabilities: ['observe'], methods: [NOTE] }, { onReceive(ctx) { general.push(ctx.method); } });
  const sw0 = t.toSwift('receive').length, g0 = t.game.length;
  t.lobby.receive(response(1500, [8, 1]));
  const records = [pendingPairs(t), pendingInjections(t), gameDiag(t)];
  assert.deepEqual(results, [{ ok: true }]);
  assert.equal(t.game.length, g0 + 1, 'only the current RESPONSE reaches the game synchronously');
  await Promise.resolve();
  assert.equal(t.game.length, g0 + 1, 'not delivered on a microtask');
  await tick();
  assert.deepEqual(t.game.slice(g0), [Array.from(response(1500, [8, 1])), Array.from(notifyMsg(NOTE, [7]))]);
  assert.deepEqual(t.toSwift('receive').slice(sw0), [Array.from(response(1500, [8, 1])), Array.from(notifyMsg(NOTE, [7]))]);
  assert.equal(t.swift.filter(e => e.data && e.data.synthetic === true).length, 1, 'Swift gets the synthetic once, marked');
  assert.deepEqual(plain(naki), [[NOTE, true, 'injectReceive', 'ir1', []]]);
  assert.deepEqual(general, [], 'never in the general chain');
  assert.deepEqual([pendingPairs(t), pendingInjections(t), gameDiag(t)], records, 'no pairing, injection or game record touched');
});

test('IR-2: a synthetic NOTIFY injected while a received Blob is still unexpanded reaches the game on the next task, but Naki observers see it only after the Blob — the order the game received them', async () => {
  const t = page();
  const ctxs = ctxKeeper(t, 'ir2', ['injectReceive']);
  const seen = nakiNoteObserver(t, 'obs2', [INFO, NOTE]);
  t.lobby.send(request(1510, INFO));
  const held = heldBlob(t, response(1510, [8, 1]));
  arrive(t, held.blob);
  assert.deepEqual(plain(ctxs[0].injectReceive(notifyMsg(NOTE, [7]))), { ok: true }, 'callable after the hook returned');
  await tick();
  assert.deepEqual(t.game.slice(-1), [Array.from(notifyMsg(NOTE, [7]))]);
  assert.deepEqual(plain(seen), [], 'the observation waits behind the Blob');
  held.open();
  await tick(); await tick();
  assert.deepEqual(plain(seen).map(s => s[0]), [INFO, NOTE]);
});

test('IR-3: injectReceive refusals — L3 off, not a TypedArray or over 1 MiB, not a well-formed NOTIFY with a method, a forbidden method (rewriteAllow cannot unlock), 32 pending, receive-untrusted, closing or closed; no function without the capability or on Naki traffic', async () => {
  const t = page();
  const ctxs = ctxKeeper(t, 'ir3', ['injectReceive'], [INFO], { observeNakiTraffic: true, rewriteAllow: ['.lq.ActionPrototype', '.lq.FastTest.syncGame', '.lq.NotifyGameEndResult'] });
  const bare = ctxKeeper(t, 'ir3bare', [], [INFO]);
  t.lobby.send(request(1520, INFO));
  assert.equal(ctxs[0].isNaki, false);
  const inj = b => plain(ctxs[0].injectReceive(b));
  t.c.__nakiPluginsMayModifyOutbound = false;
  assert.deepEqual(inj(notifyMsg(NOTE)), { ok: false, reason: 'outbound_disabled' });
  t.c.__nakiPluginsMayModifyOutbound = true;
  for (const bad of [Array.from(notifyMsg(NOTE)), notifyMsg(NOTE).buffer, null, 'x', bigNotify(1048577)]) {
    assert.deepEqual(inj(bad), { ok: false, reason: 'bad_bytes' });
  }
  for (const bad of [request(1, NOTE), response(1, [8, 1]), new Uint8Array([1, 10, 0, 18, 0]), new Uint8Array([1, 10, 50, 1]), new Uint8Array([1]), new Uint8Array([1, 10, 3, 65, 66, 67, 18, 9, 1])]) {
    assert.deepEqual(inj(bad), { ok: false, reason: 'bad_envelope' }, Array.from(bad).join());
  }
  for (const m of ['.lq.ActionPrototype', '.lq.NotifyGameEndResult', '.lq.NotifyGameTerminate', '.lq.NotifyGameBroadcast', '.lq.FastTest.syncGame', '.lq.FastTest.anything', '.lq.Route.heartbeat', '.lq.Lobby.login']) {
    assert.deepEqual(inj(notifyMsg(m)), { ok: false, reason: 'forbidden_method' }, m);
  }
  assert.deepEqual(inj(bigNotify(1048576)), { ok: true }, 'exactly 1 MiB is allowed');
  for (let i = 1; i < 32; i++) assert.deepEqual(inj(notifyMsg(NOTE, [i])), { ok: true }, 'pending ' + i);
  assert.deepEqual(inj(notifyMsg(NOTE)), { ok: false, reason: 'inject_busy' });
  const g0 = t.game.length;
  await tick();
  assert.equal(t.game.length, g0 + 32, 'the 32 queued are delivered; the refused one never');
  assert.deepEqual(inj(notifyMsg(NOTE)), { ok: true }, 'room again after delivery');
  await tick();
  assert.equal(typeof bare[0].injectReceive, 'undefined', 'no capability, no function');
  t.c.__nakiWebSocket.sendRaw(Buffer.from(request(60001, INFO)).toString('base64'));
  assert.equal(ctxs[ctxs.length - 1].isNaki, true);
  assert.equal(typeof ctxs[ctxs.length - 1].injectReceive, 'undefined', 'Naki traffic ctx has no injectReceive');
  t.lobby.readyState = 2;
  assert.deepEqual(inj(notifyMsg(NOTE)), { ok: false, reason: 'no_connection' }, 'closing');
  t.lobby.readyState = 1;
  arrive(t, rejectingBlob(t, response(9, [8, 1]), true).blob);
  assert.deepEqual(inj(notifyMsg(NOTE)), { ok: false, reason: 'receive_untrusted' });
  t.lobby.close();
  assert.deepEqual(inj(notifyMsg(NOTE)), { ok: false, reason: 'no_connection' }, 'closed');
});

test('IR-4: a pending synthetic NOTIFY is dropped when the connection closes or turns receive-untrusted before its task; a Swift failure keeps it from the game; the caller changing its buffer afterwards changes nothing; a game listener that throws neither locks the page nor skips the observation', async () => {
  for (const mode of ['close', 'untrusted', 'swift fails', 'buffer changed', 'listener throws']) {
    const t = page(source('naki-websocket.js'), { swiftFails: (type, data) => mode === 'swift fails' && type === 'websocket_message' && data.synthetic === true });
    const ctxs = ctxKeeper(t, 'ir4', ['injectReceive']);
    const seen = nakiNoteObserver(t, 'obs4');
    t.lobby.send(request(1530, INFO));
    if (mode === 'listener throws') { const deliver = t.lobby.onmessage; t.lobby.onmessage = ev => { deliver(ev); if (new Uint8Array(ev.data)[0] === 1) throw new Error('game handler broke'); }; }
    const mine = notifyMsg(NOTE, [7]);
    assert.deepEqual(plain(ctxs[0].injectReceive(mine)), { ok: true }, mode);
    mine[mine.length - 1] = 9;
    const g0 = t.game.length, sw0 = t.toSwift('receive').length;
    if (mode === 'close') t.lobby.close();
    if (mode === 'untrusted') arrive(t, rejectingBlob(t, response(9, [8, 1]), true).blob);
    await tick(); await tick();
    const delivered = !['close', 'untrusted', 'swift fails'].includes(mode);
    const gameGot = t.game.slice(g0).filter(b => b[0] === 1);
    assert.deepEqual(gameGot, delivered ? [Array.from(notifyMsg(NOTE, [7]))] : [], mode + ': game');
    assert.deepEqual(t.toSwift('receive').slice(sw0).filter(b => b[0] === 1), delivered ? [Array.from(notifyMsg(NOTE, [7]))] : [], mode + ': Swift');
    assert.deepEqual(plain(seen).map(s => s[0]), delivered ? [NOTE] : [], mode + ': observation');
    assert.equal(t.c.__nakiWebSocket.diagnostics().reshapeLocked, false, mode);
    if (!delivered && mode !== 'swift fails') assert.equal(t.events('log').some(e => /injectReceive 未交付/.test(e.data.msg)), mode === 'untrusted', mode + ': log');
  }
});

// respondLocally：在 onSend 呼叫，回 ctx.msgId 的 RESPONSE
function responder(t, id, { methods = [INFO], payload = [8, 7], priority = 0, grant = {}, caps = [], respond } = {}) {
  const results = [];
  irPlugin(t, id, { capabilities: ['observe', 'respondLocally', ...caps], methods, priority, ...grant },
    { onSend(ctx) { results.push(plain(respond ? respond(ctx) : ctx.respondLocally(response(ctx.msgId, payload)))); } });
  return results;
}

test('IR-5: respondLocally on a lobby method (lobby or game connection) — nothing goes out, Swift gets the REQUEST and the RESPONSE paired in one message, the game gets the RESPONSE after send returns, no pairing is left; a plugin that does not call it leaves the original object going out', async () => {
  for (const where of ['lobby', 'game connection']) {
    const t = page();
    const ws = where === 'lobby' ? t.lobby : gameSocket(t.c);
    const game = [];
    if (ws !== t.lobby) { ws.onmessage = ev => game.push(Array.from(new Uint8Array(ev.data))); ws.send(request(700, AUTH)); ws.receive(response(700, [8, 1])); }
    const results = responder(t, 'ir5');
    const seen = seen11(t, [INFO]);
    const req = request(1540, INFO);
    const sent0 = ws.sent.length;
    ws.send(req);
    assert.deepEqual(results, [{ ok: true }], where);
    assert.equal(ws.sent.length, sent0, where + ': nothing on the wire');
    const out = ws === t.lobby ? t.game : game, g0 = out.length;
    await tick();
    assert.deepEqual(out.slice(g0), [Array.from(response(1540, [8, 7]))], where + ': the game gets the proposal');
    const local = t.swift.filter(e => e.data && e.data.localResponse);
    assert.equal(local.length, 1, where);
    assert.deepEqual(Array.from(Buffer.from(local[0].data.data, 'base64')), Array.from(req), where);
    assert.deepEqual(Array.from(Buffer.from(local[0].data.localResponse, 'base64')), Array.from(response(1540, [8, 7])), where);
    assert.equal(local[0].data.reason, 'respond_locally', where);
    assert.equal(pendingPairs(t), 0, where + ': no pairing left');
    ws.receive(response(1540, [8, 1]));
    assert.deepEqual(plain(seen), [], where + ': a stray RESPONSE on that number resolves to nothing');
  }
  const t = page();
  responder(t, 'quiet', { respond: () => undefined });
  const req = request(1541, INFO);
  t.lobby.send(req);
  assert.equal(t.lobby.sent[0], req, 'no proposal: the original object goes out');
});

test('IR-6: respondLocally does not exist for the send-forbidden list, the two cancel methods, FastTest or Route — rewriteAllow cannot unlock it; isRespondForbidden answers the same', () => {
  const forbidden = ['.lq.Lobby.login', '.lq.Lobby.oauth2Login', '.lq.Lobby.emailLogin', '.lq.Lobby.startUnifiedMatch', '.lq.Lobby.matchGame',
    '.lq.Lobby.cancelUnifiedMatch', '.lq.Lobby.cancelMatch', OP, HB];
  const t = page();
  const got = responder(t, 'ir6', { methods: [...forbidden, INFO], grant: { rewriteAllow: forbidden }, respond: ctx => typeof ctx.respondLocally });
  forbidden.forEach((m, i) => t.lobby.send(request(1550 + i, m)));
  t.lobby.send(request(1599, INFO));
  assert.deepEqual(got, [...forbidden.map(() => 'undefined'), 'function']);
  assert.equal(t.lobby.sent.length, forbidden.length + 1, 'every request went out untouched');
  assert.deepEqual(forbidden.map(m => t.c.__nakiPlugins.isRespondForbidden(m)), forbidden.map(() => true));
  assert.equal(t.c.__nakiPlugins.isRespondForbidden(INFO), false);
});

test('IR-7: respondLocally refusals on an unguarded method — L3 off, called after the hook returned (too_late), not a TypedArray or over 1 MiB, not a RESPONSE for this msgId, the request already rewritten, a proposal already there; the refused request goes out; replace after a proposal returns false', async () => {
  const cases = [
    ['L3 off', { respond: ctx => { t3(false); const r = ctx.respondLocally(response(ctx.msgId, [8, 7])); t3(true); return r; } }, 'outbound_disabled'],
    ['array', { respond: ctx => ctx.respondLocally(Array.from(response(ctx.msgId, [8, 7]))) }, 'bad_bytes'],
    ['over 1 MiB', { respond: ctx => { const b = new Uint8Array(1048577); b.set(response(ctx.msgId, [])); return ctx.respondLocally(b); } }, 'bad_bytes'],
    ['REQUEST', { respond: ctx => ctx.respondLocally(request(ctx.msgId, INFO)) }, 'bad_envelope'],
    ['other msgId', { respond: ctx => ctx.respondLocally(response(ctx.msgId + 1, [8, 7])) }, 'bad_envelope'],
    ['truncated', { respond: ctx => ctx.respondLocally(new Uint8Array([3, ctx.msgId & 0xff, ctx.msgId >> 8, 18, 9, 1])) }, 'bad_envelope'],
    ['own in-place edit', { respond: ctx => { ctx.bytes[ctx.bytes.length - 1] ^= 1; return ctx.respondLocally(response(ctx.msgId, [8, 7])); } }, 'rewritten'],
  ];
  let t3;
  for (const [label, opts, reason] of cases) {
    const t = page();
    t3 = on => { t.c.__nakiPluginsMayModifyOutbound = on; };
    const got = responder(t, 'ir7', opts);
    t.lobby.send(request(1560, INFO, [8, 1]));
    assert.deepEqual(got, [{ ok: false, reason }], label);
    assert.equal(t.lobby.sent.length, 1, label + ': the request goes out');
    await tick();
    assert.equal(t.game.filter(b => b[0] === 3).length, 0, label + ': no local response');
  }
  { // too_late
    const t = page();
    const ctxs = ctxKeeper(t, 'late', ['respondLocally']);
    t.lobby.send(request(1561, INFO));
    assert.deepEqual(plain(ctxs[0].respondLocally(response(1561, [8, 7]))), { ok: false, reason: 'too_late' });
    assert.equal(t.lobby.sent.length, 1);
  }
  { // an earlier plugin rewrote the request
    const t = page();
    irPlugin(t, 'rw7', { capabilities: ['observe', 'rewriteSend'], methods: [INFO], priority: 0 }, { onSend(ctx) { ctx.replace(request(ctx.msgId, INFO, [8, 9])); } });
    const got = responder(t, 'ir7', { priority: 10 });
    t.lobby.send(request(1562, INFO, [8, 1]));
    assert.deepEqual(got, [{ ok: false, reason: 'rewritten' }]);
    assert.deepEqual(t.lobby.committed, [Array.from(request(1562, INFO, [8, 9]))], 'the rewritten request goes out');
  }
  { // first come, first served; replace after a proposal is refused
    const t = page();
    const replaced = [];
    const first = responder(t, 'p1', { priority: 0, caps: ['rewriteSend'], respond: ctx => { const r = ctx.respondLocally(response(ctx.msgId, [8, 1])); replaced.push(ctx.replace(request(ctx.msgId, INFO, [8, 5]))); return r; } });
    const second = responder(t, 'p2', { priority: 10, payload: [8, 2] });
    t.lobby.send(request(1563, INFO));
    assert.deepEqual([first, second, replaced], [[{ ok: true }], [{ ok: false, reason: 'already_responded' }], [false]]);
    await tick();
    assert.deepEqual(t.lobby.sent, []);
    assert.deepEqual(t.game.slice(-1), [Array.from(response(1563, [8, 1]))], 'the first proposal is delivered');
  }
});

test('IR-8: respondLocally on a guarded method follows b2 §4.2 — a guard\'s accepted proposal is local_ok even with another guard not on the chain (3b before 4); a guard\'s refused call is respond_rejected or response_invalid; a non-guard gets not_guardian and the table decides without it; a throwing guard still wins (step 3)', async () => {
  const guardGrant = { capabilities: ['observe', 'respondLocally'], methods: [SKIN], sendGuard: [SKIN] };
  const cases = [
    ['guard proposes', [['gA', guardGrant, ctx => ctx.respondLocally(response(ctx.msgId, [8, 7]))]], 'local_ok', null, [8, 7]],
    ['other guard not on chain', [['gA', guardGrant, ctx => ctx.respondLocally(response(ctx.msgId, [8, 7]))], ['gB', guardGrant, null]], 'local_ok', null, [8, 7]],
    ['guard sends a bad envelope', [['gA', guardGrant, ctx => ctx.respondLocally(request(ctx.msgId, SKIN))]], 'local_error', 'response_invalid', null],
    ['non-guard first, guard second', [['p1', { capabilities: ['observe', 'respondLocally'], methods: [SKIN] }, ctx => { notGuardian.push(plain(ctx.respondLocally(response(ctx.msgId, [8, 1])))); }],
      ['gA', { ...guardGrant, priority: 10 }, ctx => ctx.respondLocally(response(ctx.msgId, [8, 7]))]], 'local_ok', null, [8, 7]],
    ['non-guard proposes, guard approves', [['p1', { capabilities: ['observe', 'respondLocally'], methods: [SKIN] }, ctx => { notGuardian.push(plain(ctx.respondLocally(response(ctx.msgId, [8, 1])))); }],
      ['gA', { ...guardGrant, priority: 10 }, () => {}]], 'sent', null, null],
    ['two guards propose', [['gA', guardGrant, ctx => ctx.respondLocally(response(ctx.msgId, [8, 7]))],
      ['gB', { ...guardGrant, priority: 10 }, ctx => ctx.respondLocally(response(ctx.msgId, [8, 1]))]], 'local_error', 'respond_rejected', null],
    ['guard proposes, other guard throws', [['gA', guardGrant, ctx => ctx.respondLocally(response(ctx.msgId, [8, 7]))],
      ['gB', { ...guardGrant, priority: 10 }, () => { throw new Error('no'); }]], 'local_error', 'hook_threw', null],
    ['guard proposes and leaves', [['gA', guardGrant, ctx => { const r = ctx.respondLocally(response(ctx.msgId, [8, 7])); cur.c.__nakiPlugins.disable('gA'); return r; }]], 'local_ok', null, [8, 7]],
    // 守衛者先退出（未污染），之後的插件呼叫時已無守衛者，提案被接受：守衛全部退出也本地成功，不照送原請求
    ['guard leaves, then a plugin proposes', [['gA', guardGrant, () => { cur.c.__nakiPlugins.disable('gA'); }],
      ['p1', { capabilities: ['observe', 'respondLocally'], methods: [SKIN], priority: 10 }, ctx => ctx.respondLocally(response(ctx.msgId, [8, 1]))]], 'local_ok', null, [8, 1]],
  ];
  let cur, notGuardian;
  for (const [label, plugins, outcome, reason, payload] of cases) {
    const t = cur = page();
    notGuardian = [];
    for (const [id, grant, fn] of plugins) irPlugin(t, id, grant, fn ? { onSend: fn } : {});
    t.lobby.send(request(1570, SKIN, [8, 1]));
    await tick();
    if (label.startsWith('non-guard')) assert.deepEqual(notGuardian, [{ ok: false, reason: 'not_guardian' }], label);
    const log = plain(t.c.__nakiPlugins.guardState()).log.slice(-1)[0];
    assert.deepEqual([log.outcome, log.reason], [outcome, reason], label);
    if (outcome === 'sent') {
      assert.deepEqual(sentIds(t), [1570], label + ': the original goes out');
      assert.deepEqual(t.game, [], label + ': no local response');
      continue;
    }
    assert.deepEqual(t.lobby.sent, [], label + ': nothing goes out');
    assert.deepEqual(t.game.slice(-1), [payload ? Array.from(response(1570, payload)) : errorResponse(1570)], label + ': game');
  }
});

test('IR-9: the bridge fails after a proposal (the dispatch throws) — failSafe never sends the original: an unguarded method is answered with the proposal, a guarded one gets the bridge_error local error (step 2 first)', async () => {
  for (const [method, guarded] of [[INFO, false], [SKIN, true]]) {
    const t = page();
    if (guarded) irPlugin(t, 'gA', { capabilities: ['observe', 'respondLocally'], methods: [SKIN], sendGuard: [SKIN] }, { onSend(ctx) { ctx.respondLocally(response(ctx.msgId, [8, 7])); } });
    else responder(t, 'ir9', { methods: [INFO] });
    const orig = t.c.__nakiPlugins.dispatch;
    t.c.__nakiPlugins.dispatch = raw => { const r = orig(raw); if (raw.direction === 'send') throw new Error('bridge broke'); return r; };
    t.lobby.send(request(1580, method, [8, 1]));
    await tick();
    assert.deepEqual(t.lobby.sent, [], method);
    assert.deepEqual(t.game.slice(-1), [guarded ? errorResponse(1580) : Array.from(response(1580, [8, 7]))], method);
    if (guarded) assert.deepEqual(lastGuard(t), [[1580, 'local_error', 'bridge_error']]);
  }
});

test('IR-10 (ruling a): 300 local outcomes in a row (respondLocally, guard local errors, bridge errors before the dispatch, a proposal whose dispatch then throws) move the game\'s last number without counting anything unanswered — an injection then avoids the game\'s next 256 numbers', async () => {
  for (const mode of ['respondLocally', 'guard local error', 'bridge error before dispatch', 'proposal, then the dispatch throws (game connection)']) {
    const t = page();
    const { inject } = injector11(t);
    let method = INFO, armed = false, ws = t.lobby;
    if (mode === 'respondLocally') responder(t, 'ir10');
    if (mode.startsWith('proposal')) {
      ws = gameSocket(t.c);
      ws.send(request(700, AUTH));
      ws.receive(response(700, [8, 1]));
      let boom = false;
      responder(t, 'ir10', { respond: ctx => { const r = ctx.respondLocally(response(ctx.msgId, [8, 7])); ctx.bytes[ctx.bytes.length - 1] ^= 1; boom = armed; return r; } });
      const ns = t.c.__nakiWebSocket.nextSeq;
      t.c.__nakiWebSocket.nextSeq = () => { if (boom) { boom = false; throw new Error('nextSeq broke'); } return ns(); };
    }
    if (mode === 'guard local error') { guardPlugin(t.c); pollute(t); method = SKIN; }
    if (mode === 'bridge error before dispatch') {
      guard11(t); method = SKIN;
      const orig = t.c.__nakiPlugins.dispatch;
      t.c.__nakiPlugins.dispatch = raw => { if (armed && raw.direction === 'send') throw new Error('bridge broke'); return orig(raw); };
    }
    t.lobby.send(request(63600, BEAT));
    t.lobby.receive(response(63600, [8, 1]));
    if (mode === 'guard local error') t.c.__nakiPluginsMayModifyOutbound = false;
    armed = true;
    // 每 100 筆讓出一個 task：待交付的本地回應每連線上限 256（第三輪第 4 條）
    for (let i = 1; i <= 300; i++) { ws.send(request(63600 + i, method, [8, 1])); if (i % 100 === 0) await tick(); }
    armed = false;
    t.c.__nakiPluginsMayModifyOutbound = true;
    await tick();
    assert.equal(ws.sent.filter(d => { const b = new Uint8Array(d.buffer ? d.buffer : d); return (b[1] | (b[2] << 8)) > 63600; }).length, 0, mode + ': all 300 stayed local');
    assert.deepEqual(gameDiag(t), [0, 0], mode + ': nothing counted unanswered');
    const r = inject(FST);
    assert.equal(r.ok, true, mode);
    assert.equal(r.msgId, 64157, mode + ': the game\'s last number is 63900, so 63901–64156 are avoided');
  }
});

// 退化事件：記錄 onConnectionDegraded 與 Naki observer 的 onReceive，同一個陣列看先後
function degradeWatcher(t, id = 'deg', methods = [INFO]) {
  const log = [];
  irPlugin(t, id, { capabilities: ['observe'], methods, observeNakiTraffic: true }, {
    onConnectionDegraded(ctx) {
      log.push(['degraded', ctx.reason, ctx.socketId, ctx.scope, Array.from(ctx.effects), ctx.recovery, Object.isFrozen(ctx) && Object.isFrozen(ctx.effects),
        Object.keys(ctx).filter(k => typeof ctx[k] === 'function'), typeof ctx.url, typeof ctx.at]);
    },
    onReceive(ctx) { log.push(['recv', ctx.bytes[ctx.bytes.length - 1]]); } });
  return log;
}
const lobbyId = t => t.c.__nakiWebSocket.getMajsoulConnections()[0].id;
const RECV_EFFECTS = ['responses_observe_only', 'notify_observe_only', 'injections_refused'];

test('IR-11: a received Blob that fails to read raises receive_blob_failed once, read-only, on a task after the drain (the observe-only item queued behind it is already observed); a second failure on the connection raises nothing', async () => {
  const t = page();
  const log = degradeWatcher(t);
  t.lobby.send(request(1600, INFO));
  t.lobby.send(request(1601, INFO));
  const bad = rejectingBlob(t, response(1600, [8, 1]));
  arrive(t, bad.blob);
  t.lobby.receive(response(1601, [8, 2]));
  bad.fail();
  await tick(); await tick();
  assert.deepEqual(plain(log), [['recv', 2], ['degraded', 'receive_blob_failed', lobbyId(t), 'connection', RECV_EFFECTS, 'reconnect', true, ['log'], 'string', 'number']]);
  arrive(t, rejectingBlob(t, response(1602, [8, 1]), true).blob);
  await tick(); await tick();
  assert.equal(log.filter(e => e[0] === 'degraded').length, 1, 'once per connection and reason');
});

test('IR-12: the 257th queued item raises receive_queue_overflow on a task after the drain; the abandoned Blob raises nothing more', async () => {
  const t = page();
  const log = degradeWatcher(t);
  t.lobby.send(request(2020, INFO));
  const held = heldBlob(t, response(2020, [8, 1]));
  arrive(t, held.blob);
  for (let i = 0; i < 255; i++) t.lobby.receive(response(30000 + i, [8, 2]));
  t.lobby.send(request(2021, INFO));
  t.lobby.receive(response(2021, [8, 3]));
  held.open();
  await tick(); await tick();
  assert.deepEqual(plain(log).map(e => e.slice(0, 2)), [['recv', 3], ['degraded', 'receive_queue_overflow']]);
});

test('IR-13: a game Blob send raises send_blob (page scope) once, on a task after the send; the plugin needs no injection to get it', async () => {
  const t = page();
  const log = degradeWatcher(t);
  t.lobby.send(new t.c.Blob([request(1700, INFO)]));
  assert.deepEqual(log, [], 'not inside the send');
  await tick();
  assert.deepEqual(plain(log), [['degraded', 'send_blob', lobbyId(t), 'page', ['injections_refused'], 'reconnect', true, ['log'], 'string', 'number']]);
  t.lobby.send(new t.c.Blob([request(1701, INFO)]));
  await tick();
  assert.equal(log.length, 1);
});

test('IR-14: the 257th unanswered game request raises send_inflight_overflow once when its send settles; an overflow rolled back cleanly by failSafe raises nothing, one that stays lost after an unclean rollback raises it', async () => {
  {
    const t = page();
    const log = degradeWatcher(t, 'deg', [BEAT]);
    for (let i = 0; i < 256; i++) t.lobby.send(request(64000 + i, BEAT));
    await tick();
    assert.deepEqual(log, []);
    t.lobby.send(request(64256, BEAT));
    t.lobby.send(request(64257, BEAT));
    await tick();
    assert.deepEqual(plain(log).map(e => e.slice(0, 4)), [['degraded', 'send_inflight_overflow', lobbyId(t), 'page']]);
  }
  {
    let armed = 0;
    const t = page(source('naki-websocket.js'), { encode: d => { if (armed && --armed === 0) throw new Error('encode failed'); return Buffer.from(d).toString('base64'); } });
    guard11(t);
    const log = degradeWatcher(t, 'deg', [BEAT]);
    for (let i = 0; i < 256; i++) t.lobby.send(request(64000 + i, BEAT));
    armed = 1;
    t.lobby.send(request(64256, SKIN, [8, 1]));
    await tick();
    assert.deepEqual(lastGuard(t), [[64256, 'local_error', 'bridge_error']]);
    assert.deepEqual(log, [], 'the rolled-back overflow raises nothing');
  }
  { // 撤回時表已變動（failSafe 期間同線重入）：保守維持失準，照實發一次
    const { t, arm } = reenterInFailSafe(t => t.lobby.send(request(64300, BEAT)));
    const log = degradeWatcher(t, 'deg', [BEAT]);
    for (let i = 0; i < 256; i++) t.lobby.send(request(64000 + i, BEAT));
    arm();
    t.lobby.send(request(64256, SKIN, [8, 1]));
    await tick();
    assert.deepEqual(plain(log).map(e => e[1]), ['send_inflight_overflow'], 'still lost after an unclean rollback');
  }
});

test('IR-15: 257 ambiguous pairs across two connections raise ambiguity_overflow once for each connection', async () => {
  const t = page();
  const { inject } = injector11(t);
  const g = gameSocket(t.c);
  g.send(request(700, AUTH));
  g.receive(response(700, [8, 1]));
  const log = degradeWatcher(t, 'deg', []);
  const first = inject(FST).msgId;
  t.lobby.send(request(first, INFO));
  t.lobby.receive(response(first, [8, 1]));
  for (let i = 1; i < 257; i++) {
    const [ws, m, gm] = i % 2 ? [g, '.lq.FastTest.fetchGamePlayerState', OP] : [t.lobby, FST, INFO];
    const id = inject(m).msgId;
    ws.send(request(id, gm));
    ws.receive(response(id, [8, 1]));
  }
  await tick();
  assert.equal(log.length, 2, 'delivered on the next task, without waiting for a send');
  const ids = plain(t.c.__nakiWebSocket.getMajsoulConnections().map(c => c.id)).sort((a, b) => a - b);
  assert.deepEqual(plain(log).map(e => [e[1], e[2], e[3], e[4]]).sort((a, b) => a[1] - b[1]),
    ids.map(id => ['ambiguity_overflow', id, 'connection', ['responses_observe_only']]));
});

test('IR-16: a variable-length delivery the bridge refuses locks reshaping and raises reshape_locked (page scope, recovery reload)', async () => {
  const longer = notifyMsg(NOTE, [1, 2, 3]);
  const t = page(source('naki-websocket.js'), { swiftFails: (type, data) => type === 'websocket_message' && data.size === longer.length });
  t.c.MessageEvent.prototype.stopImmediatePropagation = function () {};   // 替身事件沒有這個方法；有了才走到攔下之後的 bridge 交付
  const log = degradeWatcher(t, 'deg', []);
  irPlugin(t, 'rs', { capabilities: ['observe', 'rewriteReceive', 'reshapeReceive'], methods: [NOTE] }, { onReceive(ctx) { ctx.replace(longer); } });
  t.lobby.receive(notifyMsg(NOTE, [1]));
  assert.equal(t.c.__nakiWebSocket.diagnostics().reshapeLocked, true);
  await tick();
  assert.deepEqual(plain(log).map(e => e.slice(1, 6)), [['reshape_locked', lobbyId(t), 'page', ['reshape_disabled'], 'reload']]);
});

test('IR-17: degradation inside another plugin\'s hook (a Blob that throws on read arriving during an injection) is delivered on a later task, never while that hook runs', async () => {
  const t = page();
  const { inject } = injector11(t);
  let inHook = false, armed = false;
  const during = [];
  irPlugin(t, 'sab17', { capabilities: ['observe'], methods: [FST], priority: 700, observeNakiTraffic: true }, { onSend() {
    if (!armed) return;
    armed = false; inHook = true;
    arrive(t, rejectingBlob(t, response(2030, [8, 1]), true).blob);
    inHook = false;
  } });
  irPlugin(t, 'deg17', { capabilities: ['observe'], methods: [] }, { onConnectionDegraded(ctx) { during.push([ctx.reason, inHook]); } });
  armed = true;
  inject(FST);
  assert.deepEqual(during, [], 'not delivered synchronously');
  await tick();
  assert.deepEqual(during, [['receive_blob_failed', false]]);
});

// ---- inject-receive 第二輪（Astra 第一輪第 1–10 條反例）----
const taintedIds = t => Object.keys(plain(t.c.__nakiPlugins.guardState()).tainted);

test('IR-18 (Astra 1): a guard plugin whose injectReceive or respondLocally is accepted is tainted at acceptance — disabled before the synthetic is delivered, its guarded method still never goes out; a plugin without sendGuard is not tainted', async () => {
  for (const kind of ['injectReceive', 'respondLocally']) {
    const t = page();
    const results = [];
    irPlugin(t, 'g18', { capabilities: ['observe', kind], methods: [SKIN, INFO], sendGuard: [SKIN] }, { onSend(ctx) {
      if (ctx.method === INFO) results.push(plain(kind === 'injectReceive' ? ctx.injectReceive(notifyMsg(NOTE, [7])) : ctx.respondLocally(response(ctx.msgId, [8, 7]))));
    } });
    irPlugin(t, 'p18', { capabilities: ['observe', 'injectReceive'], methods: [INFO], priority: 10 }, { onSend(ctx) { results.push(plain(ctx.injectReceive(notifyMsg(NOTE, [8])))); } });
    t.lobby.send(request(1900, INFO));
    assert.deepEqual(results.map(r => r.ok), [true, true], kind);
    assert.deepEqual(taintedIds(t), ['g18'], kind + ': tainted at acceptance; the plugin without sendGuard is not');
    t.c.__nakiPlugins.disable('g18');
    await tick();
    t.lobby.send(request(1901, SKIN, [8, 1]));
    await tick();
    assert.deepEqual(lastGuard(t), [[1901, 'local_error', 'not_on_chain']], kind);
    assert.equal(sentIds(t).includes(1901), false, kind + ': the guarded request never goes out');
  }
});

test('IR-19 (Astra 2): a guard whose respondLocally was refused keeps its veto after it leaves the chain — the other guard approving does not send the request (response_invalid, respond_rejected)', async () => {
  const guardGrant = priority => ({ capabilities: ['observe', 'respondLocally'], methods: [SKIN], sendGuard: [SKIN], priority });
  for (const [label, reason] of [['bad envelope', 'response_invalid'], ['already responded', 'respond_rejected']]) {
    const t = page();
    if (label === 'already responded') irPlugin(t, 'g0', guardGrant(0), { onSend(ctx) { ctx.respondLocally(response(ctx.msgId, [8, 7])); } });
    irPlugin(t, 'gA', guardGrant(5), { onSend(ctx) {
      ctx.respondLocally(label === 'bad envelope' ? request(ctx.msgId, SKIN) : response(ctx.msgId, [8, 9]));
      t.c.__nakiPlugins.disable('gA');
    } });
    irPlugin(t, 'gB', guardGrant(10), { onSend() {} });
    t.lobby.send(request(1910, SKIN, [8, 1]));
    await tick();
    assert.deepEqual(t.lobby.sent, [], label + ': nothing goes out');
    assert.deepEqual(lastGuard(t), [[1910, 'local_error', reason]], label);
    assert.deepEqual(t.game.slice(-1), [errorResponse(1910)], label);
  }
});

test('IR-20 (Astra 3, 8): degradation raised inside onSend or onRecommendations is delivered on a later task — never between the verdict and the wire, never inside the hook; a taint() from the callback with a saved ctx only affects later sends', async () => {
  const t = page();
  const g1 = gameSocket(t.c), g2 = gameSocket(t.c);
  for (const g of [g1, g2]) { g.send(request(700, AUTH)); g.receive(response(700, [8, 1])); }
  const order = [];
  let saved = null, inRecs = false;
  irPlugin(t, 'g20', { capabilities: ['observe'], methods: [SKIN], sendGuard: [SKIN] }, {
    onSend(ctx) { saved = ctx; g1.send(new t.c.Blob([request(701, OP)])); },
    onRecommendations() { if (inRecs) g2.send(new t.c.Blob([request(702, OP)])); } });
  irPlugin(t, 'deg20', { capabilities: ['observe'], methods: [] }, { onConnectionDegraded(ctx) {
    order.push([ctx.reason, ctx.socketId, t.lobby.sent.length, inRecs]);
    saved.taint();
  } });
  t.lobby.send(request(1920, SKIN, [8, 1]));
  assert.deepEqual(order, [], 'not delivered before ws.send returns');
  assert.deepEqual(sentIds(t), [1920]);
  assert.deepEqual(lastGuard(t), [[1920, 'sent', null]]);
  await tick();
  const ids = plain(t.c.__nakiWebSocket.getMajsoulConnections().map(c => c.id));
  assert.deepEqual(plain(order), [['send_blob', ids[1], 1, false]], 'after the request was on the wire');
  assert.deepEqual(taintedIds(t), ['g20'], 'the callback taint() takes effect');
  inRecs = true;
  t.c.__nakiPlugins.recommendationsChanged([], {});
  inRecs = false;
  assert.equal(order.length, 1, 'not inside onRecommendations');
  await tick();
  assert.deepEqual(plain(order).slice(1), [['send_blob', ids[2], 1, false]]);
  t.c.__nakiPlugins.disable('g20');
  t.lobby.send(request(1921, SKIN, [8, 1]));
  await tick();
  assert.deepEqual(lastGuard(t), [[1921, 'local_error', 'not_on_chain']], 'later sends follow the taint');
  assert.deepEqual(sentIds(t), [1920]);
});

test('IR-21 (Astra 4): a local response still waiting for its task keeps its number reserved apart from the unanswered count — an injection before delivery skips it, and the game never gets an injection RESPONSE and the local one on the same number', async () => {
  const t = page();
  const { inject } = injector11(t);
  responder(t, 'ir21');
  t.lobby.send(request(64000, INFO));
  assert.equal(t.c.__nakiPlugins.diagnostics().gameInflight, 0, 'not counted unanswered');
  const r = inject(FST);
  assert.equal(r.ok, true);
  assert.equal(r.msgId, 64257, '64000 is reserved until delivery, 64001–64256 follow the game\'s last number');
  t.lobby.receive(response(r.msgId, [8, 1]));
  await tick();
  const answered = t.game.filter(b => b[0] === 3).map(b => b[1] | (b[2] << 8));
  assert.deepEqual(answered.filter(id => id === 64000), [64000], 'the game gets exactly one RESPONSE for 64000, the local one');
});

test('IR-22 (Astra 5): the game\'s last number follows the order the game entered its sends — an outer request answered locally after a re-entered later send does not move it back, whether the later number is larger (63900 then 63901) or smaller (wrap-around analog)', async () => {
  for (const [outer, inner, expected] of [[63900, 63901, 64158], [63900, 63800, 64057]]) {
    const t = page();
    const { inject } = injector11(t);
    responder(t, 'ir22', { respond: ctx => { t.lobby.send(request(inner, BEAT)); return ctx.respondLocally(response(ctx.msgId, [8, 7])); } });
    t.lobby.send(request(outer, INFO));
    await tick();
    const r = inject(FST);
    assert.equal(r.ok, true);
    assert.equal(r.msgId, expected, `${outer} then ${inner}: the last number is ${inner}`);
  }
});

test('IR-23 (Astra 6): synthetic observations share the receive queue limit — with a Blob unexpanded, injections over several tasks overflow the queue: receive_queue_overflow once, later injections refused, the queue drained', async () => {
  const t = page();
  const ctxs = ctxKeeper(t, 'ir23', ['injectReceive']);
  nakiNoteObserver(t, 'obs23');
  const log = degradeWatcher(t, 'deg23', []);
  t.lobby.send(request(1930, INFO));
  arrive(t, heldBlob(t, response(1930, [8, 1])).blob);
  const refused = [];
  for (let task = 0; task < 10; task++) {
    for (let i = 0; i < 32; i++) { const r = plain(ctxs[0].injectReceive(notifyMsg(NOTE, [i]))); if (!r.ok) refused.push(r.reason); }
    await tick();
  }
  await tick();
  assert.deepEqual(plain(t.c.__nakiWebSocket.diagnostics().recvQueue), [], 'drained after the overflow');
  assert.deepEqual(plain(log).map(e => e[1]), ['receive_queue_overflow']);
  assert.deepEqual([refused.length, [...new Set(refused)]], [64, ['receive_untrusted']]);
});

test('IR-24 (Astra 7): a synthetic NOTIFY is dropped when its connection is CLOSING at delivery time but not yet released — neither the game nor Swift nor the observers get it, and a log line says so', async () => {
  const t = page();
  const ctxs = ctxKeeper(t, 'ir24', ['injectReceive']);
  const seen = nakiNoteObserver(t, 'obs24');
  t.lobby.send(request(1940, INFO));
  assert.deepEqual(plain(ctxs[0].injectReceive(notifyMsg(NOTE, [7]))), { ok: true });
  t.lobby.readyState = 2;
  const g0 = t.game.length, sw0 = t.toSwift('receive').length;
  await tick(); await tick();
  assert.equal(t.game.length, g0);
  assert.equal(t.toSwift('receive').length, sw0);
  assert.deepEqual(plain(seen), []);
  assert.equal(t.events('log').some(e => /injectReceive 未交付：連線已關閉/.test(e.data.msg)), true);
});

test('IR-25 (Astra 10, ruling): on a guarded method only a guard may propose — another plugin gets not_guardian and the table decides as if it never called; a proposal accepted before the method became guarded mid-chain ends in a local error (not_guardian), never on the wire', async () => {
  {
    const t = page();
    const got = responder(t, 'p25', { methods: [SKIN] });
    irPlugin(t, 'g25', { capabilities: ['observe'], methods: [SKIN], sendGuard: [SKIN], priority: 10 }, { onSend() {} });
    t.lobby.send(request(1950, SKIN, [8, 1]));
    assert.deepEqual(got, [{ ok: false, reason: 'not_guardian' }]);
    assert.deepEqual(sentIds(t), [1950]);
    assert.deepEqual(lastGuard(t), [[1950, 'sent', null]]);
  }
  {
    const t = page();
    const got = responder(t, 'p25', { methods: [SKIN] });
    irPlugin(t, 'late', { capabilities: ['observe'], methods: [SKIN], priority: 10 }, { onSend() {
      t.c.__nakiPlugins.setGrant('g25', { capabilities: ['observe'], methods: [SKIN], sendGuard: [SKIN] });
      t.c.__nakiPlugins.register({ id: 'g25', onSend() {} });
    } });
    t.lobby.send(request(1951, SKIN, [8, 1]));
    await tick();
    assert.deepEqual(got, [{ ok: true }], 'no guard when it called');
    assert.deepEqual(t.lobby.sent, []);
    assert.deepEqual(lastGuard(t), [[1951, 'local_error', 'not_guardian']]);
    assert.deepEqual(t.game.slice(-1), [errorResponse(1951)]);
  }
  { // 對局連線不跑守衛（§1.4）：守衛身分不查，非守衛者的提案照收、本地成功，不留守衛紀錄
    const t = page();
    const g = gameSocket(t.c), game = [];
    g.onmessage = ev => game.push(Array.from(new Uint8Array(ev.data)));
    g.send(request(700, AUTH));
    g.receive(response(700, [8, 1]));
    const got = responder(t, 'p25', { methods: [SKIN] });
    irPlugin(t, 'g25', { capabilities: ['observe'], methods: [SKIN], sendGuard: [SKIN], priority: 10 }, { onSend() {} });
    const sent0 = g.sent.length;
    g.send(request(1952, SKIN, [8, 1]));
    await tick();
    assert.deepEqual(got, [{ ok: true }], 'game connection');
    assert.equal(g.sent.length, sent0, 'game connection: answered locally');
    assert.deepEqual(game.slice(-1), [Array.from(response(1952, [8, 7]))]);
    assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).log, [], 'no guard verdict on the game connection');
  }
});

// ---- inject-receive 第三輪（Astra 第二輪第 2–4 條）----
function twoGameSockets(t) {
  const g1 = gameSocket(t.c), g2 = gameSocket(t.c);
  for (const g of [g1, g2]) { g.send(request(700, AUTH)); g.receive(response(700, [8, 1])); }
  const ids = plain(t.c.__nakiWebSocket.getMajsoulConnections().map(c => c.id));
  return { g1, g2, ids };
}

test('IR-26 (Astra2 2): a degradation raised inside an onConnectionDegraded callback waits for the next task — the current batch and the microtasks it queued finish first', async () => {
  const t = page();
  const { g1, g2, ids } = twoGameSockets(t);
  const order = [];
  irPlugin(t, 'deg26', { capabilities: ['observe'], methods: [] }, { onConnectionDegraded(ctx) {
    order.push(ctx.socketId);
    if (order.length > 1) return;
    Promise.resolve().then(() => order.push('micro'));
    g2.send(new t.c.Blob([request(702, OP)]));
  } });
  g1.send(new t.c.Blob([request(701, OP)]));
  await tick();
  assert.deepEqual(order, [ids[1], 'micro'], 'the re-raised event is not in this batch');
  await tick();
  assert.deepEqual(order, [ids[1], 'micro', ids[2]]);
});

test('IR-27 (Astra2 3): a plugin whose onConnectionDegraded getter throws is charged once per event and does not stop the others — a healthy plugin still gets every event of the batch', async () => {
  const t = page();
  const { g1, g2 } = twoGameSockets(t);
  let reads = 0;
  t.c.__nakiPlugins.setGrant('bad27', { capabilities: ['observe'], methods: [] });
  assert.equal(t.c.__nakiPlugins.register({ id: 'bad27', get onConnectionDegraded() { reads++; throw new Error('getter broke'); } }), true);
  const got = [];
  irPlugin(t, 'ok27', { capabilities: ['observe'], methods: [] }, { onConnectionDegraded(ctx) { got.push(ctx.socketId); } });
  g1.send(new t.c.Blob([request(701, OP)]));
  g2.send(new t.c.Blob([request(702, OP)]));
  await tick();
  assert.equal(got.length, 2, 'the healthy plugin gets both events');
  assert.equal(reads, 2, 'the hook is read once per event');
  assert.equal(t.events('log').filter(e => e.data.id === 'bad27' && /onConnectionDegraded 拋錯/.test(e.data.msg)).length, 2, 'charged to the failing plugin');
});

test('IR-28 (Astra2 4): reserved local numbers are bounded and released on every path — a failed schedule releases at once, the 257th pending respondLocally on a connection gets local_busy (that request goes out, nothing reserved is evicted), closing the connection clears them; diagnostics().localPending counts them', async () => {
  const pending = t => t.c.__nakiPlugins.diagnostics().localPending;
  { // 排程失敗：遊戲收不到本地回應，號碼立即釋放
    const t = page();
    const { inject } = injector11(t);
    responder(t, 'ir28');
    const timer = t.c.setTimeout;
    t.c.setTimeout = () => { throw new Error('timer broke'); };
    t.lobby.send(request(64000, INFO));
    t.c.setTimeout = timer;
    assert.equal(pending(t), 0, 'released when scheduling fails');
    assert.equal(inject(FST).msgId, 64000, 'the number is free again');
  }
  { // 容量：每連線 256 筆待交付
    const t = page();
    const got = responder(t, 'ir28');
    for (let i = 0; i < 257; i++) t.lobby.send(request(3000 + i, INFO));
    assert.equal(got.slice(0, 256).every(r => r.ok), true);
    assert.deepEqual(got[256], { ok: false, reason: 'local_busy' });
    assert.deepEqual(sentIds(t), [3256], 'the refused request goes out');
    assert.equal(pending(t), 256);
    await tick();
    assert.equal(pending(t), 0, 'released after delivery');
    assert.equal(t.game.filter(b => b[0] === 3).length, 256, 'every reserved number was answered locally');
    t.lobby.send(request(3300, INFO));
    assert.deepEqual(got[257], { ok: true }, 'room again');
  }
  { // 關閉連線清除
    const t = page();
    responder(t, 'ir28');
    t.lobby.send(request(3400, INFO));
    assert.equal(pending(t), 1);
    t.lobby.close();
    assert.equal(pending(t), 0);
    await tick();
    assert.equal(pending(t), 0);
  }
});
