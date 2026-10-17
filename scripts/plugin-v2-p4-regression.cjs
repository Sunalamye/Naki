// Run: node scripts/plugin-v2-p4-regression.cjs
// Phase 4 receive 變長 replace／drop（docs/plan/plugin-v2-phase4.md）。假 dispatcher 照 live probe 的三種：
// capture（target 上 capture 先跑，WebKit 實測）、order（照註冊順序）、nostop（stopImmediatePropagation 無效）。
// NAKI_JS_DIR 可指向變異後的 JS 目錄；main 差異比較從 git 取 main（2d02a03）的 JS。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const jsDir = process.env.NAKI_JS_DIR || path.resolve(__dirname, '../command/Resources/JavaScript');
const source = name => fs.readFileSync(path.join(jsDir, name), 'utf8');
const mainSource = name => require('node:child_process').execFileSync('git',
  ['-C', path.resolve(__dirname, '..'), 'show', `2d02a03:command/Resources/JavaScript/${name}`], { encoding: 'utf8' });

function page(mode = 'capture', { url = 'wss://route-2.maj-soul.com/gateway', noMessageEvent = false, src = source,
  encodeFails = () => false, swiftFails = () => false } = {}) {
  const swift = [], errorListeners = [];
  class MessageEvent {
    constructor(type, init = {}) {
      if (noMessageEvent) throw new Error('MessageEvent unavailable');
      Object.assign(this, { type, data: init.data, origin: init.origin || '', lastEventId: init.lastEventId || '', stopped: false });
    }
    stopImmediatePropagation() { this.stopped = true; }
  }
  class Socket {
    constructor(u) { this.url = u; this.readyState = 1; this.binaryType = 'arraybuffer'; this.listeners = []; this.sent = []; }
    addEventListener(k, f, capture) {
      if (k !== 'message' || this.listeners.some(l => l.fn === f && l.capture === !!capture)) return;
      this.listeners.push({ fn: f, capture: !!capture });
    }
    set onmessage(f) { const slot = this.listeners.find(l => l.attr); if (slot) slot.fn = f; else this.listeners.push({ fn: f, capture: false, attr: true }); }
    get onmessage() { const slot = this.listeners.find(l => l.attr); return slot ? slot.fn : null; }
    send(d) { this.sent.push(d); }
    dispatchEvent(ev) {
      const list = mode === 'order' ? this.listeners.slice()
        : this.listeners.filter(l => l.capture).concat(this.listeners.filter(l => !l.capture));
      for (const l of list) {
        if (ev.stopped && mode !== 'nostop') break;
        try { l.fn.call(this, ev); } catch (e) { errorListeners.forEach(f => f({ error: e })); }
      }
      return true;
    }
  }
  Socket.OPEN = 1; Socket.CLOSED = 3;
  class FileReader {
    readAsDataURL(blob) { blob.arrayBuffer().then(b => { this.result = 'data:;base64,' + Buffer.from(b).toString('base64'); this.onloadend(); }); }
  }
  const c = { console: { log() {}, error() {} }, Uint8Array, ArrayBuffer, DataView, Blob, MessageEvent, FileReader, setTimeout,
    btoa: s => Buffer.from(s, 'binary').toString('base64'), atob: s => Buffer.from(s, 'base64').toString('binary'),
    document: { getElementById: () => null }, __nakiPluginGrants: {},
    addEventListener: (k, f) => { if (k === 'error') errorListeners.push(f); } };
  c.window = c; c.WebSocket = Socket; vm.createContext(c);
  vm.runInContext(src('naki-core.js'), c);
  c.__nakiCore.sendToSwift = (type, data) => swiftFails(type, data) ? false : swift.push({ type, data });
  const encode = c.__nakiCore.arrayBufferToBase64;
  c.__nakiCore.arrayBufferToBase64 = b => { if (encodeFails(Array.from(new Uint8Array(b)))) throw new Error('encode failed'); return encode(b); };
  vm.runInContext(src('naki-websocket.js'), c);
  vm.runInContext(src('naki-plugins.js'), c);
  const ws = new c.WebSocket(url);
  const game = [];
  ws.onmessage = ev => game.push(ev);
  const recv = (u8, extra = {}) => {
    const ev = new MessageEvent('message', { data: u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength), origin: 'wss://route-2.maj-soul.com', ...extra });
    ws.dispatchEvent(ev);
    return ev;
  };
  const toSwift = () => swift.filter(e => e.type === 'websocket_message').map(e => [e.data.direction, Array.from(Buffer.from(e.data.data, 'base64'))]);
  const logs = () => swift.filter(e => e.type === 'plugin_event').map(e => e.data.msg);
  return { c, ws, game, recv, swift, toSwift, logs, stats: () => plain(c.__nakiWebSocket.diagnostics()) };
}
const plain = x => JSON.parse(JSON.stringify(x));
const arr = ev => Array.from(new Uint8Array(ev.data));
const field = (n, bytes) => [(n << 3) | 2, bytes.length, ...bytes];
const notify = (method, payload = []) => new Uint8Array([1, ...field(1, [...Buffer.from(method)]), ...field(2, payload)]);
const request = (msgId, method, payload = []) => new Uint8Array([2, msgId & 0xff, msgId >> 8, ...field(1, [...Buffer.from(method)]), ...field(2, payload)]);
const response = (msgId, payload = [], method = '') => new Uint8Array([3, msgId & 0xff, msgId >> 8, ...field(1, [...Buffer.from(method)]), ...field(2, payload)]);
const canonicalResponse = (msgId, payload) => new Uint8Array([3, msgId & 0xff, msgId >> 8, ...field(2, payload)]);
const NOTE = '.lq.NotifyAccountUpdate', INFO = '.lq.Lobby.fetchCharacterInfo', SKIN = '.lq.Lobby.changeCharacterSkin';

function plugin(c, id, { caps = ['observe', 'rewriteReceive', 'reshapeReceive'], methods = [NOTE], priority, extra = {}, onReceive }) {
  const calls = [];
  c.__nakiPlugins.setGrant(id, { capabilities: caps, methods, priority, ...extra });
  assert.equal(c.__nakiPlugins.register({ id, onReceive(ctx) {
    calls.push({ bytes: Array.from(ctx.bytes), payload: plain(ctx.payload), hasDrop: typeof ctx.drop === 'function' });
    if (onReceive) return onReceive(ctx);
  } }), true);
  return calls;
}

test('Naki listener is capture: with zero plugins every dispatcher delivers the original event once, after Swift got it', () => {
  for (const mode of ['capture', 'order', 'nostop']) {
    const t = page(mode);
    const seenByLateCapture = [];
    t.ws.addEventListener('message', () => seenByLateCapture.push(t.toSwift().length), true);
    const ev = t.recv(notify(NOTE, [1]));
    assert.equal(t.game.length, 1, mode);
    assert.equal(t.game[0], ev, mode);
    assert.deepEqual(seenByLateCapture, [1], `${mode}: a game capture listener registered later runs after Naki`);
    assert.deepEqual(t.toSwift(), [['receive', Array.from(notify(NOTE, [1]))]], mode);
  }
});

test('variable-length NOTIFY replace: the game gets one synthetic ArrayBuffer event, Swift gets the new bytes once', () => {
  for (const mode of ['capture', 'order']) {
    const t = page(mode);
    const longer = notify(NOTE, [8, 1, 16, 2, 24, 3]);
    const results = [];
    const calls = plugin(t.c, 'p', { onReceive: ctx => { results.push(ctx.replace(longer)); } });
    const lateCapture = [];
    t.ws.addEventListener('message', e => lateCapture.push(e), true);
    const ev = t.recv(notify(NOTE, [1]));
    assert.deepEqual(results, [true], mode);
    assert.equal(calls.length, 1, `${mode}: the synthetic event is not dispatched to plugins again`);
    assert.equal(t.game.length, 1, mode);
    assert.notEqual(t.game[0], ev, mode);
    assert.ok(t.game[0].data instanceof ArrayBuffer, mode);
    assert.deepEqual(arr(t.game[0]), Array.from(longer), mode);
    assert.equal(t.game[0].origin, ev.origin, mode);
    assert.deepEqual(lateCapture, [t.game[0]], `${mode}: later game capture listeners only see the synthetic event`);
    assert.deepEqual(t.toSwift(), [['receive', Array.from(longer)]], mode);
    assert.deepEqual(t.stats().reshape, { attempted: 1, delivered: 1, dropped: 0, fallback: 0, faults: 0 }, mode);
  }
});

test('RESPONSE replace accepts a canonical re-encode without field 1, refuses one that carries a method', () => {
  const t = page();
  const results = [];
  plugin(t.c, 'p', { methods: [INFO], onReceive: ctx => {
    results.push(ctx.replace(response(ctx.msgId, [8, 1, 8, 2], INFO)));
    results.push(ctx.replace(canonicalResponse(ctx.msgId, [8, 1, 8, 2, 8, 3])));
  } });
  t.ws.send(request(30, INFO));
  t.recv(response(30, [8, 1]));
  assert.deepEqual(results, [false, true]);
  assert.deepEqual(arr(t.game[0]), Array.from(canonicalResponse(30, [8, 1, 8, 2, 8, 3])));
  assert.deepEqual(t.toSwift().filter(e => e[0] === 'receive'), [['receive', Array.from(canonicalResponse(30, [8, 1, 8, 2, 8, 3]))]]);
});

test('Swift sees the replaced receive before a request the game sends while handling it', () => {
  const t = page();
  plugin(t.c, 'p', { onReceive: ctx => { ctx.replace(notify(NOTE, [1, 2, 3])); } });
  t.ws.onmessage = () => t.ws.send(request(40, INFO));
  t.recv(notify(NOTE, [1]));
  assert.deepEqual(t.toSwift().map(e => e[0]), ['receive', 'send']);
});

test('drop: NOTIFY only, dropReceive capability, L3 switch on; nothing reaches the game or Swift and the chain stops', () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  const results = [];
  plugin(t.c, 'a', { caps: ['observe', 'dropReceive'], methods: [NOTE, INFO], priority: 1,
    onReceive: ctx => { results.push(ctx.drop ? ctx.drop() : 'none'); } });
  const later = plugin(t.c, 'b', { methods: [NOTE], priority: 2 });
  t.recv(notify(NOTE, [1]));
  assert.deepEqual(results, [true]);
  assert.equal(later.length, 0);
  assert.equal(t.game.length, 0);
  assert.deepEqual(t.toSwift(), []);
  assert.equal(t.stats().reshape.dropped, 1);
  t.ws.send(request(31, INFO));
  t.recv(response(31, [8, 1]));
  assert.deepEqual(results, [true, 'none'], 'RESPONSE never gets ctx.drop');
  assert.equal(t.game.length, 1);
});

test('drop is refused with L3 off and absent without dropReceive; the original event is delivered', () => {
  const t = page();
  const results = [];
  plugin(t.c, 'a', { caps: ['observe', 'dropReceive'], onReceive: ctx => { results.push(ctx.drop()); } });
  const noCap = plugin(t.c, 'b', { caps: ['observe', 'rewriteReceive'] });
  const ev = t.recv(notify(NOTE, [1]));
  assert.deepEqual(results, [false]);
  assert.equal(noCap[0].hasDrop, false);
  assert.deepEqual(t.game, [ev]);
});

test('chain: a later plugin sees the replaced bytes and payload; drop after replace wins', () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  const longer = notify(NOTE, [9, 9, 9, 9]);
  plugin(t.c, 'a', { priority: 1, onReceive: ctx => { ctx.replace(longer); } });
  const b = plugin(t.c, 'b', { caps: ['observe', 'dropReceive'], priority: 2, onReceive: ctx => { ctx.drop(); } });
  t.recv(notify(NOTE, [1]));
  assert.deepEqual(b[0].bytes, Array.from(longer));
  assert.deepEqual(b[0].payload, { from: longer.length - 4, to: longer.length });
  assert.equal(t.game.length, 0);
  assert.deepEqual(t.toSwift(), []);
});

test('fail-open: a hook that throws after replace or drop has both undone; the original event goes through', () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  plugin(t.c, 'a', { caps: ['observe', 'rewriteReceive', 'reshapeReceive', 'dropReceive'], onReceive: ctx => {
    ctx.replace(notify(NOTE, [1, 2, 3, 4]));
    ctx.drop();
    throw new Error('boom');
  } });
  const ev = t.recv(notify(NOTE, [1]));
  assert.deepEqual(t.game, [ev]);
  assert.deepEqual(arr(ev), Array.from(notify(NOTE, [1])));
  assert.deepEqual(t.toSwift(), [['receive', Array.from(notify(NOTE, [1]))]]);
  assert.deepEqual(t.stats().reshape, { attempted: 0, delivered: 0, dropped: 0, fallback: 0, faults: 0 });
});

test('forbidden methods: no variable-length replace or drop even with rewriteAllow; equal-length authGame still works', () => {
  const t = page('capture', { url: 'wss://x.maj-soul.com/game-gateway' });
  t.c.__nakiPluginsMayModifyOutbound = true;
  const RES = ['.lq.FastTest.authGame', '.lq.FastTest.syncGame', '.lq.FastTest.enterGame', '.lq.Route.heartbeat',
    '.lq.Lobby.login', '.lq.Lobby.oauth2Login', '.lq.Lobby.emailLogin', '.lq.Lobby.oauth2Auth', '.lq.Lobby.startUnifiedMatch'];
  const NOTES = ['.lq.ActionPrototype', '.lq.NotifyGameEndResult', '.lq.NotifyGameTerminate', '.lq.NotifyGameBroadcast'];
  const results = [];
  plugin(t.c, 'p', { caps: ['observe', 'rewriteReceive', 'reshapeReceive', 'dropReceive'], methods: RES.concat(NOTES),
    extra: { rewriteAllow: NOTES.concat('.lq.FastTest.syncGame') }, onReceive: ctx => {
      const bigger = ctx.type === 1 ? notify(ctx.method, [1, 2, 3, 4]) : canonicalResponse(ctx.msgId, [1, 2, 3, 4, 5, 6]);
      const same = ctx.bytes.slice(); same[same.length - 1] ^= 1;
      results.push([ctx.method, ctx.replace(bigger), typeof ctx.drop, ctx.replace(same)]);
    } });
  RES.forEach((m, i) => { t.ws.send(request(50 + i, m)); t.recv(response(50 + i, [8, 1])); });
  NOTES.forEach(m => t.recv(notify(m, [8, 1])));
  assert.deepEqual(results, RES.concat(NOTES).map(m => [m, false, 'undefined', true]));
  assert.equal(t.game.length, RES.length + NOTES.length);
  assert.equal(t.stats().reshape.attempted, 0);
});

test('Naki\'s own RESPONSE (sendRaw registration) never offers replace or drop, not even to a Naki-traffic observer', () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  const seen = [];
  t.c.__nakiPlugins.setGrant('o', { capabilities: ['observe', 'rewriteReceive', 'dropReceive'], methods: [INFO], observeNakiTraffic: true });
  t.c.__nakiPlugins.register({ id: 'o', onReceive(ctx) { seen.push([ctx.isNaki, typeof ctx.replace, typeof ctx.drop]); } });
  assert.equal(t.c.__nakiWebSocket.sendRaw(Buffer.from(request(60001, INFO)).toString('base64')).success, true);
  const ev = t.recv(response(60001, [8, 1]));
  assert.deepEqual(seen, [[true, 'undefined', 'undefined']]);
  assert.deepEqual(t.game, [ev]);
});

test('invalid replacements are refused and counted; the original event goes through', () => {
  const t = page();
  const results = [];
  plugin(t.c, 'p', { methods: [NOTE, INFO], onReceive: ctx => {
    if (ctx.type === 1) {
      results.push(ctx.replace(notify('.lq.NotifyOther', [1, 2, 3])));
      results.push(ctx.replace(new Uint8Array([1, ...field(2, [1, 2, 3])])));
      results.push(ctx.replace(new Uint8Array([...notify(NOTE, [1, 2, 3]), 0x0d, 1])));
      results.push(ctx.replace(request(1, NOTE, [1, 2])));
    } else {
      results.push(ctx.replace(canonicalResponse(ctx.msgId + 1, [1, 2, 3])));
    }
  } });
  const ev = t.recv(notify(NOTE, [1]));
  t.ws.send(request(70, INFO));
  t.recv(response(70, [8, 1]));
  assert.deepEqual(results, [false, false, false, false, false]);
  assert.equal(t.game[0], ev);
  assert.equal(t.game.length, 2);
  assert.equal(t.logs().filter(m => /變長 replace 不合規/.test(m)).length, 5);
});

test('fail-open: if the synthetic event cannot be built, the original is delivered and Swift gets the original bytes', () => {
  const t = page('capture', { noMessageEvent: true });
  const results = [];
  plugin(t.c, 'p', { onReceive: ctx => { results.push(ctx.replace(notify(NOTE, [1, 2, 3]))); } });
  const original = notify(NOTE, [1]);
  const ev = { type: 'message', data: original.buffer.slice(0), stopped: false, stopImmediatePropagation() { this.stopped = true; } };
  t.ws.dispatchEvent(ev);
  assert.deepEqual(results, [true]);
  assert.deepEqual(t.game, [ev]);
  assert.deepEqual(t.toSwift(), [['receive', Array.from(original)]]);
  assert.equal(t.stats().reshape.fallback, 1);
});

test('kill-switch: an error during synthetic dispatch is recorded with metadata and candidates, and locks reshaping for the page', () => {
  const t = page();
  const results = [];
  plugin(t.c, 'p', { onReceive: ctx => { results.push(ctx.replace(notify(NOTE, [1, 2, 3]))); } });
  t.ws.onmessage = ev => { t.game.push(ev); if (t.game.length === 1) throw new Error('game decode failed'); };
  t.recv(notify(NOTE, [1]));
  const ev = t.recv(notify(NOTE, [2]));
  assert.deepEqual(results, [true, false]);
  assert.equal(t.game[1], ev);
  assert.equal(t.stats().reshapeLocked, true);
  assert.equal(t.stats().reshape.faults, 1);
  assert.deepEqual(t.stats().reshapeFaults.map(f => [f.kind, f.method, f.candidates, f.error]),
    [['synthetic_dispatch_error', NOTE, ['p'], 'game decode failed']]);
  assert.equal(t.logs().filter(m => /變長交付故障（synthetic_dispatch_error.*候選改寫者 p）.*停用變長/.test(m)).length, 1);
});

test('Blob events stay observe-only: no replace, the game gets the original Blob event, Swift gets its full bytes', async () => {
  const t = page();
  const seen = [];
  t.c.__nakiPlugins.setGrant('p', { capabilities: ['observe', 'rewriteReceive', 'reshapeReceive', 'dropReceive'], methods: [NOTE] });
  t.c.__nakiPlugins.register({ id: 'p', onReceive(ctx) { seen.push([typeof ctx.replace, typeof ctx.drop, Array.from(ctx.bytes)]); } });
  const bytes = notify(NOTE, [1, 2, 3]);
  const ev = new t.c.MessageEvent('message', { data: new Blob([bytes]) });
  t.ws.dispatchEvent(ev);
  assert.deepEqual(t.game, [ev], 'the game receives the Blob event first, synchronously');
  await new Promise(r => setTimeout(r, 20));
  assert.deepEqual(seen, [['undefined', 'undefined', Array.from(bytes)]]);
  assert.ok(t.game[0].data instanceof Blob);
  assert.deepEqual(t.toSwift(), [['receive', Array.from(bytes)]]);
  assert.equal(t.swift.find(e => e.type === 'websocket_message').data.type, 'blob');
});

test('nostop dispatcher: the duplicate cannot be prevented, but the sentinel records stop_ineffective and locks reshaping', () => {
  const t = page('nostop');
  const results = [];
  plugin(t.c, 'p', { onReceive: ctx => { results.push(ctx.replace(notify(NOTE, [1, 2, 3]))); } });
  const ev = t.recv(notify(NOTE, [1]));
  assert.deepEqual(t.game.map(e => e === ev), [false, true]);
  assert.deepEqual(t.stats().reshapeFaults.map(f => f.kind), ['stop_ineffective']);
  const next = t.recv(notify(NOTE, [2]));
  assert.deepEqual(results, [true, false]);
  assert.equal(t.game[2], next);
});

test('taint: a guard plugin that replaces (variable length) or drops lobby traffic is tainted until reload', () => {
  for (const act of ['replace', 'drop']) {
    const t = page();
    t.c.__nakiPluginsMayModifyOutbound = true;
    plugin(t.c, 'g', { caps: ['observe', 'rewriteReceive', 'reshapeReceive', 'dropReceive'], methods: [SKIN, NOTE], extra: { sendGuard: [SKIN] },
      onReceive: ctx => { act === 'replace' ? ctx.replace(notify(NOTE, [1, 2, 3])) : ctx.drop(); } });
    t.ws.send(request(80, INFO));
    t.recv(notify(NOTE, [1]));
    assert.deepEqual(plain(t.c.__nakiPlugins.guardState()).tainted, { g: [SKIN] }, act);
  }
});

test('guard local response still reaches the game once through the capture listener and is not re-dispatched', async () => {
  const t = page();
  t.c.__nakiPlugins.setGrant('g', { capabilities: ['observe'], methods: [SKIN], sendGuard: [SKIN] });
  t.c.__nakiPlugins.register({ id: 'g', onSend() { throw new Error('boom'); } });
  t.ws.send(request(90, INFO));
  t.ws.send(request(91, SKIN));
  await new Promise(r => setTimeout(r, 0));
  assert.equal(t.game.length, 1);
  assert.equal(t.toSwift().filter(e => e[0] === 'receive').length, 0, 'the local pair travels as one send message; the listener skips the copy');
});

test('without reshapeReceive a different-length replace still returns false (v1 semantics); equal length still works', () => {
  const t = page();
  const results = [];
  plugin(t.c, 'old', { caps: ['observe', 'rewriteReceive'], onReceive: ctx => {
    results.push(ctx.replace(notify(NOTE, [1, 2, 3])));
    const same = ctx.bytes.slice(); same[same.length - 1] = 9;
    results.push(ctx.replace(same));
  } });
  const ev = t.recv(notify(NOTE, [1]));
  assert.deepEqual(results, [false, true]);
  assert.deepEqual(t.game, [ev]);
  assert.deepEqual(arr(ev), Array.from(notify(NOTE, [9])));
  assert.equal(t.stats().reshape.attempted, 0);
});

test('a throwing hook returns the chain to its state before that hook: A\'s replacement is still delivered', () => {
  const t = page();
  t.c.__nakiPluginsMayModifyOutbound = true;
  const longer = notify(NOTE, [7, 7, 7, 7]);
  plugin(t.c, 'a', { priority: 1, onReceive: ctx => { ctx.replace(longer); } });
  plugin(t.c, 'b', { caps: ['observe', 'rewriteReceive', 'reshapeReceive', 'dropReceive'], priority: 2, onReceive: ctx => {
    ctx.bytes[ctx.bytes.length - 1] = 0;
    ctx.replace(notify(NOTE, [5, 5, 5, 5, 5, 5]));
    ctx.drop();
    throw new Error('boom');
  } });
  t.recv(notify(NOTE, [1]));
  assert.equal(t.game.length, 1);
  assert.deepEqual(arr(t.game[0]), Array.from(longer));
  assert.deepEqual(t.toSwift(), [['receive', Array.from(longer)]]);
  assert.deepEqual(t.stats().reshape, { attempted: 1, delivered: 1, dropped: 0, fallback: 0, faults: 0 });
});

test('fault injection: encoding failure before the stop is fail-open — original delivered, not counted as delivered, not locked', () => {
  const longer = Array.from(notify(NOTE, [1, 2, 3]));
  const t = page('capture', { encodeFails: b => JSON.stringify(b) === JSON.stringify(longer) });
  plugin(t.c, 'p', { onReceive: ctx => { ctx.replace(new Uint8Array(longer)); } });
  const ev = t.recv(notify(NOTE, [1]));
  assert.deepEqual(t.game, [ev]);
  assert.deepEqual(t.toSwift(), [['receive', Array.from(notify(NOTE, [1]))]]);
  assert.deepEqual(t.stats().reshape, { attempted: 1, delivered: 0, dropped: 0, fallback: 1, faults: 0 });
  assert.equal(t.stats().reshapeLocked, false);
});

test('fault injection: bridge refuses after the stop — fault recorded and locked, the game still gets the synthetic once, no original resend', () => {
  const longer = notify(NOTE, [1, 2, 3]);
  const t = page('capture', { swiftFails: (type, data) => type === 'websocket_message' && data.size === longer.length });
  plugin(t.c, 'p', { onReceive: ctx => { ctx.replace(longer); } });
  const ev = t.recv(notify(NOTE, [1]));
  assert.equal(t.game.length, 1);
  assert.notEqual(t.game[0], ev);
  assert.deepEqual(arr(t.game[0]), Array.from(longer));
  assert.deepEqual(t.toSwift(), []);
  assert.deepEqual(t.stats().reshape, { attempted: 1, delivered: 0, dropped: 0, fallback: 0, faults: 1 });
  assert.deepEqual(t.stats().reshapeFaults.map(f => [f.kind, f.method, f.candidates]), [['bridge_rejected', NOTE, ['p']]]);
  assert.equal(t.stats().reshapeLocked, true);
});

test('fault injection: dispatch throws after the stop — fault recorded and locked, Swift has the new bytes once, no original resend', () => {
  const longer = notify(NOTE, [1, 2, 3]);
  const t = page();
  plugin(t.c, 'p', { onReceive: ctx => { ctx.replace(longer); } });
  const real = t.ws.dispatchEvent.bind(t.ws);
  let first = null;
  t.ws.dispatchEvent = ev => { if (first && ev !== first) throw new Error('dispatch failed'); first = first || ev; return real(ev); };
  t.recv(notify(NOTE, [1]));
  assert.deepEqual(t.game, []);
  assert.deepEqual(t.toSwift(), [['receive', Array.from(longer)]]);
  assert.deepEqual(t.stats().reshape, { attempted: 1, delivered: 0, dropped: 0, fallback: 0, faults: 1 });
  assert.deepEqual(t.stats().reshapeFaults.map(f => [f.kind, f.error]), [['dispatch_threw', 'dispatch failed']]);
  assert.equal(t.stats().reshapeLocked, true);
});

test('main parity: zero plugins and equal-length rewriting deliver the same bytes in the same order as main (game onmessage, ArrayBuffer and offset TypedArray)', () => {
  const run = (src, equalLength) => {
    const t = page('capture', { src });
    if (equalLength) {
      t.c.__nakiPlugins.setGrant('eq', { capabilities: ['observe', 'rewriteReceive'], methods: [NOTE, INFO] });
      t.c.__nakiPlugins.register({ id: 'eq', onReceive(ctx) { const b = ctx.bytes.slice(); b[b.length - 1] ^= 0x40; ctx.replace(b); } });
    }
    const big = new Uint8Array(64);
    const req = request(33, INFO, [8, 1]);
    big.set(req, 5);
    const view = new Uint8Array(big.buffer, 5, req.length);
    t.recv(notify(NOTE, [1, 2]));
    t.ws.send(view);
    t.recv(response(33, [8, 7]));
    t.recv(notify(NOTE, [3]));
    return { game: t.game.map(arr), swift: t.toSwift(), sent: t.ws.sent.map(d => d === view) };
  };
  for (const equalLength of [false, true]) {
    const head = run(source, equalLength), main = run(mainSource, equalLength);
    assert.deepEqual(head, main, `equalLength=${equalLength}`);
    assert.deepEqual(head.sent, [true], 'the offset TypedArray goes out as the same object');
    assert.deepEqual(head.swift[1], ['send', Array.from(request(33, INFO, [8, 1]))], 'Swift gets exactly the view, not the whole buffer');
  }
});
