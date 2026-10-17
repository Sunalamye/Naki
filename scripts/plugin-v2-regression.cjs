// Run: node scripts/plugin-v2-regression.cjs
// 插件 v2 草案的 rewriteSend（docs/plan/plugin-v2.md §B）：只用 bundled 模組，不需外部插件 repo。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const root = path.resolve(__dirname, '..');
const source = name => fs.readFileSync(path.join(root, 'command/Resources/JavaScript', name), 'utf8');

function page() {
  const swift = [];
  const c = { console: { log() {}, error() {} }, Uint8Array, ArrayBuffer, DataView, Blob,
    btoa: s => Buffer.from(s, 'binary').toString('base64'), atob: s => Buffer.from(s, 'base64').toString('binary'),
    document: { getElementById: () => null }, __nakiPluginGrants: {} };
  class Socket { constructor(url) { this.url = url; this.readyState = 1; this.listeners = {}; this.sent = []; }
    addEventListener(k, f) { this.listeners[k] = f; } send(d) { this.sent.push(d); } }
  Socket.OPEN = 1;
  c.window = c; c.WebSocket = Socket; vm.createContext(c);
  vm.runInContext(source('naki-core.js'), c);
  c.__nakiCore.sendToSwift = (type, data) => swift.push({ type, data });
  vm.runInContext(source('naki-websocket.js'), c);
  vm.runInContext(source('naki-plugins.js'), c);
  const ws = new c.WebSocket('wss://game.example/gateway');
  const sentToSwift = () => swift.filter(e => e.type === 'websocket_message' && e.data.direction === 'send').map(e => e.data.data);
  const failures = () => swift.filter(e => e.type === 'plugin_event' && / 拋錯/.test(e.data.msg)).length;
  return { c, ws, sentToSwift, failures };
}
function request(msgId, method, payload = []) {
  const m = Buffer.from(method);
  return new Uint8Array([2, msgId & 0xff, msgId >> 8, 10, m.length, ...m, 18, payload.length, ...payload]);
}
const notify = (method, payload = []) => { const m = Buffer.from(method); return new Uint8Array([1, 10, m.length, ...m, 18, payload.length, ...payload]); };
const b64 = u8 => Buffer.from(u8).toString('base64');
const bytes = x => Array.from(new Uint8Array(x.buffer ? x.buffer.slice(x.byteOffset, x.byteOffset + x.byteLength) : x));
const SKIN = '.lq.Lobby.changeCharacterSkin', BEAT = '.lq.Lobby.loginBeat';

// 一個 rewriteSend 插件：對白名單 method 呼叫 replace(make(ctx))，結果記在 results
function rewriter(c, { id = 'rw', methods = [SKIN], caps = ['observe', 'rewriteSend'], priority, make, extra = {} }) {
  const results = [], seen = [];
  c.__nakiPlugins.setGrant(id, { capabilities: caps, methods, priority, ...extra });
  c.__nakiPlugins.register({ id, onSend(ctx) {
    seen.push({ method: ctx.method, bytes: Array.from(ctx.bytes), payload: ctx.payload, hasReplace: typeof ctx.replace === 'function' });
    if (ctx.replace && make) results.push(ctx.replace(make(ctx)));
  } });
  return { results, seen };
}

test('outbound switch off: replace refuses and the original bytes object goes out unchanged', () => {
  const { c, ws, sentToSwift } = page();
  const { results } = rewriter(c, { make: ctx => request(ctx.msgId, BEAT) });
  const original = request(150, SKIN, [8, 1]);
  ws.send(original);
  assert.deepEqual(results, [false]);
  assert.equal(ws.sent[0], original);
  assert.deepEqual(sentToSwift(), [b64(original)]);
});

test('outbound switch on: request swapped for a different method and length; socket and Swift see the same new bytes', () => {
  const { c, ws, sentToSwift } = page(); c.__nakiPluginsMayModifyOutbound = true;
  const { results } = rewriter(c, { make: ctx => request(ctx.msgId, BEAT) });
  ws.send(request(151, SKIN, [8, 1, 16, 2]));
  assert.deepEqual(results, [true]);
  assert.deepEqual(bytes(ws.sent[0]), Array.from(request(151, BEAT)));
  assert.deepEqual(sentToSwift(), [b64(request(151, BEAT))]);
});

test('ArrayBuffer sends are rewritten the same way', () => {
  const { c, ws, sentToSwift } = page(); c.__nakiPluginsMayModifyOutbound = true;
  rewriter(c, { make: ctx => request(ctx.msgId, BEAT) });
  ws.send(request(162, SKIN, [8, 1]).buffer);
  assert.deepEqual(bytes(ws.sent[0]), Array.from(request(162, BEAT)));
  assert.deepEqual(sentToSwift(), [b64(request(162, BEAT))]);
});

test('TypedArray sends (Unity path) are rewritten the same way', () => {
  const { c, ws, sentToSwift } = page(); c.__nakiPluginsMayModifyOutbound = true;
  rewriter(c, { make: ctx => request(ctx.msgId, SKIN, [8, 9, 9, 9]) });
  const backing = new Uint8Array(64); const src = request(152, SKIN, [8, 1]); backing.set(src, 5);
  ws.send(new Uint8Array(backing.buffer, 5, src.length));
  assert.deepEqual(bytes(ws.sent[0]), Array.from(request(152, SKIN, [8, 9, 9, 9])));
  assert.deepEqual(sentToSwift(), [b64(request(152, SKIN, [8, 9, 9, 9]))]);
});

test('msgId change, type change, incomplete envelope and non-bytes are refused and counted', () => {
  const makers = [ctx => request(ctx.msgId + 1, BEAT), () => notify(BEAT), ctx => request(ctx.msgId, BEAT).slice(0, 8), () => 7, () => null];
  for (const make of makers) {
    const { c, ws, failures } = page(); c.__nakiPluginsMayModifyOutbound = true;
    const { results } = rewriter(c, { make });
    const original = request(153, SKIN);
    ws.send(original);
    assert.deepEqual(results, [false], String(make));
    assert.equal(ws.sent[0], original);
    assert.ok(failures() <= 1);
  }
});

test('send forbidden list: no replace on FastTest, login/auth or match entry; rewriteAllow does not unlock', () => {
  for (const m of ['.lq.FastTest.inputOperation', '.lq.FastTest.authGame', '.lq.Lobby.oauth2Login', '.lq.Lobby.startUnifiedMatch', '.lq.Lobby.matchGame', '.lq.Route.heartbeat']) {
    const { c, ws } = page(); c.__nakiPluginsMayModifyOutbound = true;
    const { seen } = rewriter(c, { methods: [m], make: ctx => request(ctx.msgId, BEAT), extra: { rewriteAllow: [m] } });
    const original = request(154, m);
    ws.send(original);
    assert.equal(seen[0].hasReplace, false, m); assert.equal(ws.sent[0], original);
  }
});

test('rewriting into a forbidden method is refused', () => {
  for (const target of ['.lq.Lobby.oauth2Login', '.lq.FastTest.inputOperation', '.lq.Lobby.startUnifiedMatch']) {
    const { c, ws } = page(); c.__nakiPluginsMayModifyOutbound = true;
    const { results } = rewriter(c, { make: ctx => request(ctx.msgId, target) });
    const original = request(155, SKIN);
    ws.send(original);
    assert.deepEqual(results, [false], target); assert.equal(ws.sent[0], original);
  }
});

test('rewriteReceive alone does not grant send-side replace; receive replace stays equal-length only', () => {
  const { c, ws } = page(); c.__nakiPluginsMayModifyOutbound = true;
  const { seen } = rewriter(c, { caps: ['observe', 'rewriteReceive'], make: ctx => request(ctx.msgId, BEAT) });
  ws.send(request(156, SKIN));
  assert.equal(seen[0].hasReplace, false);
  const got = [];
  c.__nakiPlugins.setGrant('both', { capabilities: ['observe', 'rewriteReceive', 'rewriteSend'], methods: ['.lq.NotifyFoo'] });
  c.__nakiPlugins.register({ id: 'both', onReceive(ctx) { got.push(ctx.replace(notify('.lq.NotifyFoo', [1, 2, 3]))); } });
  ws.listeners.message({ data: notify('.lq.NotifyFoo', [1]).buffer });
  assert.deepEqual(got, [false]);
});

test('Naki\'s own sendRaw is never offered rewriteSend; the socket gets exactly the decoded bytes', () => {
  const { c, ws } = page(); c.__nakiPluginsMayModifyOutbound = true;
  const seen = [];
  c.__nakiPlugins.setGrant('rw', { capabilities: ['observe', 'rewriteSend'], methods: [SKIN], observeNakiTraffic: true });
  c.__nakiPlugins.register({ id: 'rw', onSend(ctx) { seen.push([ctx.isNaki, typeof ctx.replace]); } });
  assert.equal(c.__nakiWebSocket.sendRaw(b64(request(60010, SKIN, [8, 1]))).success, true);
  assert.deepEqual(seen, [[true, 'undefined']]);
  assert.deepEqual(bytes(ws.sent[0]), Array.from(request(60010, SKIN, [8, 1])));
});

test('D22: injected sends (via sendRaw) are Naki traffic and never rewritten; the plugin range alone is not', () => {
  const { c, ws } = page(); c.__nakiPluginsMayModifyOutbound = true;
  const rw = rewriter(c, { make: ctx => request(ctx.msgId, SKIN, [8, 1]), extra: { observeNakiTraffic: true } }), { seen } = rw;
  const original = request(64002, SKIN);
  assert.equal(c.__nakiWebSocket.sendRaw(b64(original)).success, true);
  assert.equal(seen[0].hasReplace, false); assert.deepEqual(Array.from(new Uint8Array(ws.sent[0])), Array.from(original));
  rw.results.length = 0;
  ws.send(request(64003, SKIN));
  assert.deepEqual(rw.results, [true], 'the game\'s own msgId in the plugin range is rewritable');
  assert.deepEqual(bytes(ws.sent[1]), Array.from(request(64003, SKIN, [8, 1])));
});

test('no plugins: send passes the very same object through (zero-plugin regression)', () => {
  const { ws, sentToSwift } = page();
  const original = request(157, SKIN, [8, 1]);
  ws.send(original);
  assert.equal(ws.sent[0], original);
  assert.deepEqual(sentToSwift(), [b64(original)]);
});

test('chain: later plugin sees the replaced buffer and its new payload range', () => {
  const { c, ws } = page(); c.__nakiPluginsMayModifyOutbound = true;
  rewriter(c, { id: 'a', priority: 1, make: ctx => request(ctx.msgId, SKIN, [8, 1, 16, 2, 24, 3]) });
  const b = rewriter(c, { id: 'b', priority: 2 });
  ws.send(request(158, SKIN, [8, 1]));
  assert.deepEqual(b.seen[0].bytes, Array.from(request(158, SKIN, [8, 1, 16, 2, 24, 3])));
  assert.equal(b.seen[0].payload.to - b.seen[0].payload.from, 6);
});

test('chain: a method swap stops the chain for plugins selected by the old method', () => {
  const { c, ws } = page(); c.__nakiPluginsMayModifyOutbound = true;
  rewriter(c, { id: 'a', priority: 1, make: ctx => request(ctx.msgId, BEAT) });
  const b = rewriter(c, { id: 'b', priority: 2 });
  ws.send(request(159, SKIN));
  assert.equal(b.seen.length, 0);
  assert.deepEqual(bytes(ws.sent[0]), Array.from(request(159, BEAT)));
});

test('a hook that throws after a successful replace has its replacement withdrawn (fail-open)', () => {
  const { c, ws, failures } = page(); c.__nakiPluginsMayModifyOutbound = true;
  c.__nakiPlugins.setGrant('bad', { capabilities: ['observe', 'rewriteSend'], methods: [SKIN] });
  c.__nakiPlugins.register({ id: 'bad', onSend(ctx) { ctx.replace(request(ctx.msgId, BEAT)); throw Error('boom'); } });
  const original = request(160, SKIN);
  ws.send(original);
  assert.equal(ws.sent[0], original); assert.equal(failures(), 1);
});

test('replace returns false when the switch is turned off between registration and the call', () => {
  const { c, ws } = page(); c.__nakiPluginsMayModifyOutbound = true;
  const { results } = rewriter(c, { make: ctx => { c.__nakiPluginsMayModifyOutbound = false; return request(ctx.msgId, BEAT); } });
  const original = request(161, SKIN);
  ws.send(original);
  assert.deepEqual(results, [false]); assert.equal(ws.sent[0], original);
});

// ---- 審查第二輪（Astra 1／4／5／6）反例 ----
const response = (msgId, payload = []) => new Uint8Array([3, msgId & 0xff, msgId >> 8, 10, 0, 18, payload.length, ...payload]);

test('truncated fixed32 / fixed64 tails are refused even though parseEnvelope reports complete', () => {
  for (const tail of [[0x1d, 1], [0x19, 1, 2, 3]]) {
    const { c, ws } = page(); c.__nakiPluginsMayModifyOutbound = true;
    const bad = new Uint8Array([...request(170, BEAT), ...tail]);
    assert.equal(c.__nakiCore.parseEnvelope(bad).complete, true, 'precondition: core parser is lenient');
    const { results } = rewriter(c, { make: () => bad });
    const original = request(170, SKIN);
    ws.send(original);
    assert.deepEqual(results, [false], String(tail)); assert.equal(ws.sent[0], original);
  }
});

test('empty method field is refused', () => {
  const { c, ws } = page(); c.__nakiPluginsMayModifyOutbound = true;
  const { results } = rewriter(c, { make: ctx => new Uint8Array([2, ctx.msgId & 0xff, ctx.msgId >> 8, 10, 0, 18, 0]) });
  ws.send(request(171, SKIN));
  assert.deepEqual(results, [false]);
});

test('after a method swap the RESPONSE is attributed to the method actually sent (same as Swift)', () => {
  const { c, ws } = page(); c.__nakiPluginsMayModifyOutbound = true;
  rewriter(c, { make: ctx => request(ctx.msgId, BEAT) });
  const seen = [];
  c.__nakiPlugins.setGrant('obs', { capabilities: ['observe'], methods: [SKIN, BEAT] });
  c.__nakiPlugins.register({ id: 'obs', onReceive(ctx) { seen.push(ctx.method); } });
  ws.send(request(172, SKIN));
  ws.listeners.message({ data: response(172).buffer });
  assert.deepEqual(seen, [BEAT]);
});

test('receive: equal-length replace followed by a throw is fully reverted', () => {
  const { c, ws } = page();
  c.__nakiPlugins.setGrant('bad', { capabilities: ['observe', 'rewriteReceive'], methods: ['.lq.NotifyFoo'] });
  c.__nakiPlugins.register({ id: 'bad', onReceive(ctx) { assert.equal(ctx.replace(notify('.lq.NotifyFoo', [9])), true); throw Error('boom'); } });
  const buf = notify('.lq.NotifyFoo', [1]);
  ws.listeners.message({ data: buf.buffer });
  assert.deepEqual(Array.from(buf), Array.from(notify('.lq.NotifyFoo', [1])));
});

test('in-place edits by a hook that throws are reverted (receive and send)', () => {
  const { c, ws } = page(); c.__nakiPluginsMayModifyOutbound = true;
  c.__nakiPlugins.setGrant('bad', { capabilities: ['observe', 'rewriteSend'], methods: ['.lq.NotifyFoo', SKIN] });
  c.__nakiPlugins.register({ id: 'bad',
    onReceive(ctx) { ctx.bytes[ctx.bytes.length - 1] = 9; throw Error('boom'); },
    onSend(ctx) { ctx.bytes[ctx.bytes.length - 1] = 9; ctx.replace(request(ctx.msgId, BEAT)); throw Error('boom'); } });
  const rbuf = notify('.lq.NotifyFoo', [1]);
  ws.listeners.message({ data: rbuf.buffer });
  assert.equal(rbuf.at(-1), 1);
  const sbuf = request(173, SKIN, [8, 1]);
  ws.send(sbuf);
  assert.equal(ws.sent[0], sbuf); assert.equal(sbuf.at(-1), 1);
});

test('login / session / account-security methods are forbidden on both sides', () => {
  const methods = ['logout', 'loginSuccess', 'fastLogin', 'prepareLogin', 'dmmPreLogin', 'oauth2Signup', 'modifyPassword', 'deleteAccount', 'bindEmail', 'fetchOBToken', 'verifySteamOrder'].map(m => '.lq.Lobby.' + m);
  for (const m of methods) {
    const before = page(); before.c.__nakiPluginsMayModifyOutbound = true;
    const b = rewriter(before.c, { methods: [m], make: ctx => request(ctx.msgId, BEAT) });
    before.ws.send(request(174, m));
    assert.equal(b.seen[0].hasReplace, false, 'source ' + m);
    const after = page(); after.c.__nakiPluginsMayModifyOutbound = true;
    const a = rewriter(after.c, { make: ctx => request(ctx.msgId, m) });
    after.ws.send(request(175, SKIN));
    assert.deepEqual(a.results, [false], 'target ' + m);
  }
});
