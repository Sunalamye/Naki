// Run: node scripts/plugin-regression.cjs <path-to-naki-plugins>
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const root = path.resolve(__dirname, '..');
if (!process.argv[2]) throw new Error('Usage: node scripts/plugin-regression.cjs <path-to-naki-plugins>');
const pluginRoot = path.resolve(process.argv[2]);
const source = name => fs.readFileSync(path.join(root, 'command/Resources/JavaScript', name), 'utf8');
const plugin = id => fs.readFileSync(path.join(pluginRoot, 'plugins', id, 'plugin.js'), 'utf8');
const id = 'naki-plugin-ex-tile-highlighter';
const plain = x => JSON.parse(JSON.stringify(x));
function setup() {
  const events = [], renders = [];
  const c = { console: { log(){}, error(){} }, Uint8Array, ArrayBuffer, DataView, Blob,
    btoa: s => Buffer.from(s, 'binary').toString('base64'), atob: s => Buffer.from(s, 'base64').toString('binary'),
    document: { getElementById: () => null },
    __nakiRecommendations: [], __nakiRecommendationContext: {}, __nakiPluginGrants: {}
  };
  // 照正式注入順序先載 naki-core（envelope 解析在那裡），再換掉 bridge 與 WebGL 高亮
  c.window = c; vm.createContext(c); vm.runInContext(source('naki-core.js'),c);
  c.__nakiCore.sendToSwift = (type, data) => events.push({type,data});
  c.__nakiHighlight = { set: (marks,popup) => renders.push(plain({marks,popup})), clear: () => renders.push(null), state: () => ({}) };
  vm.runInContext(source('naki-plugins.js'),c);
  function register(settings={}) {
    c.__nakiPlugins.setGrant(id,{capabilities:['observe'],methods:['.lq.ActionPrototype'],settings});
    vm.runInContext(plugin(id),c);
  }
  return { c, events, renders, register };
}
function rec(actionType='discard',tile='7p') { return {actionType,tile,probability:0.82}; }
test('recommendation update draws immediately without a WebSocket packet', () => {
  const {c,renders,register}=setup(); register();
  c.__nakiPlugins.recommendationsChanged([rec()],{hand:['7p','1m','1m','5pr']});
  assert.deepEqual(renders.at(-1),{marks:[{tile:'7p',color:[0.45,1,0.5]},{tile:'1m',color:[0.62,0.62,0.68,0.55]},{tile:'5pr',color:[0.62,0.62,0.68,0.55]}],popup:null});
});
test('hot enable replays the current hand and recommendation',()=>{
  const {c,renders,register}=setup(); c.__nakiRecommendations=[rec()]; c.__nakiRecommendationContext={hand:['7p','E']}; register();
  assert.equal(renders.at(-1).marks.length,2);
});
test('riichi uses its accompanying discard; preserves red five',()=>{
  const {c,renders,register}=setup(); register();
  c.__nakiPlugins.recommendationsChanged([rec('riichi',null),rec('discard','5pr')],{hand:['5p','5pr']});
  assert.equal(renders.at(-1).marks[0].tile,'5pr'); assert.equal(renders.at(-1).marks[1].tile,'5p');
});
for(const action of ['none','hora','kita','ryukyoku']) test(action+' never falls back to a lower-ranked discard',()=>{
  const {c,renders,register}=setup();register();c.__nakiPlugins.recommendationsChanged([rec()]);
  c.__nakiPlugins.recommendationsChanged([rec(action,null),rec()]);assert.equal(renders.at(-1),null);
});
test('empty recommendation and disable clear existing marks',()=>{
  const {c,renders,register}=setup();register();c.__nakiPlugins.recommendationsChanged([rec()]);
  c.__nakiPlugins.recommendationsChanged([]);assert.equal(renders.at(-1),null);
  c.__nakiPlugins.recommendationsChanged([rec()]); c.__nakiPlugins.disable(id);assert.equal(renders.at(-1),null);
  const n=renders.length;c.__nakiPlugins.recommendationsChanged([rec()]);assert.equal(renders.length,n);
});
test('settings reload replaces the registered hook and applies new color',()=>{
  const {c,renders,register}=setup();c.__nakiRecommendations=[rec()];register();
  c.__nakiPlugins.disable(id);register({color:'blue',dimOthers:false});
  assert.deepEqual(renders.at(-1).marks,[{tile:'7p',color:[0.45,0.65,1]}]); assert.equal(c.__nakiPlugins.list().length,1);
});
test('call marks use authoritative context; popup remains off by default',()=>{
  const {c,renders,register}=setup();register();c.__nakiPlugins.recommendationsChanged([rec('chi',null)],{callTiles:['5pr','6p'],isCallOpportunity:true});
  assert.deepEqual(renders.at(-1),{marks:[{tile:'5pr',color:[1,0.75,0.4]},{tile:'6p',color:[1,0.75,0.4]}],popup:null});
});
test('failing plugin is cleaned up and does not block other plugins',()=>{
  const {c,renders,register}=setup();register();let cleaned=0;
  c.__nakiPlugins.setGrant('broken',{});c.__nakiPlugins.register({id:'broken',onRecommendations(){throw Error('failure');},onDisable(){cleaned++;}});
  for(let i=0;i<10;i++) c.__nakiPlugins.recommendationsChanged([rec()]);
  assert.equal(cleaned,1);assert.equal(c.__nakiPlugins.list().length,1);assert.equal(renders.at(-1).marks[0].tile,'7p');
});
test('each recommendation hook gets an isolated snapshot',()=>{
  const {c}=setup();let seen;
  c.__nakiPlugins.setGrant('a',{});c.__nakiPlugins.setGrant('b',{});
  c.__nakiPlugins.register({id:'a',onRecommendations(ctx){ctx.recommendations.length=0;ctx.context.hand=[];}});
  c.__nakiPlugins.register({id:'b',onRecommendations(ctx){seen=ctx;}});
  c.__nakiPlugins.recommendationsChanged([rec()],{hand:['7p']});assert.equal(seen.recommendations.length,1);assert.equal(seen.context.hand[0],'7p');
});
test('Swift injection template evaluates JSON, then notifies plugins',()=>{
  const s=fs.readFileSync(path.join(root,'command/Services/Bridge/NakiWebSocketScript.swift'),'utf8');
  const body=s.match(/func publishRecommendations[\s\S]*?"""([\s\S]*?)"""/)[1];
  assert.ok(body.includes('\\(json)'));assert.ok(body.includes('\\(contextJSON)'));
  const {c,renders,register}=setup();register();
  vm.runInContext(body.replace('\\(json)',JSON.stringify([rec()])).replace('\\(contextJSON)',JSON.stringify({hand:['7p','E']})),c);
  assert.equal(renders.at(-1).marks.length,2);
});
test('Swift hot-enable script disables old registration before installing grant',()=>{
  const s=fs.readFileSync(path.join(root,'command/Services/Plugins/PluginRegistry.swift'),'utf8').split('static func enableScript')[1];
  assert.ok(s.indexOf('__nakiPlugins.disable(')<s.indexOf('__nakiPlugins.setGrant('));
});
test('Blob dispatch is observable but never grants rewriteReceive; counters report actual types',async()=>{
  const {c}=setup(); const observed=[];
  class Socket { constructor(){this.listeners={};} addEventListener(k,f){this.listeners[k]=this.listeners[k]||f;} send(){} }
  c.WebSocket=Socket;
  c.__nakiPlugins.setGrant('observer',{capabilities:['observe','rewriteReceive'],methods:['.lq.ActionPrototype'],rewriteAllow:['.lq.ActionPrototype']});
  c.__nakiPlugins.register({id:'observer',onReceive(ctx){observed.push(ctx);}});
  vm.runInContext(source('naki-websocket.js'),c);
  const socket=new c.WebSocket('wss://game.example/gateway');
  const m=Buffer.from('.lq.ActionPrototype');const bytes=new Uint8Array([1,10,m.length,...m,18,0]);
  socket.listeners.message({data:new Blob([bytes])});
  await new Promise(resolve=>setImmediate(resolve));
  socket.listeners.message({data:bytes.buffer});socket.listeners.message({data:new DataView(bytes.buffer)});socket.listeners.message({data:'text'});
  assert.equal(observed.length,3);assert.equal(observed[0].msgId,null);assert.equal(observed[0].replace,undefined);assert.equal(typeof observed[1].replace,'function');
  assert.deepEqual(plain(c.__nakiWebSocket.diagnostics().receive),{ArrayBuffer:1,TypedArray:1,Blob:1,String:1,Other:0});
  assert.equal(c.__nakiPlugins.diagnostics().runtime.lastMethod,'.lq.ActionPrototype');
});
function renderer() {
  const c={console:{log(){},error(){}},document:{getElementById:()=>({getContext:type=>type==='webgl'?gl:null})},requestAnimationFrame:()=>0};
  const gl={CURRENT_PROGRAM:1,ACTIVE_TEXTURE:2,TEXTURE0:100,TEXTURE_BINDING_2D:3,TEXTURE_2D:4,
    st:[0.1,0.25,0.7,0.25],color:[1,1,1,1],draws:[],ui:false,fail:false,
    getParameter(k){return k===1?program:k===2?100:null;},
    getUniformLocation(p,k){return k==='_MainTex_ST'?'st':k==='_Tint'?'color':k==='_TextureSampleAdd'&&this.ui?'ui':null;},
    getUniform(p,k){return this[k].slice();},uniform4f(k,...v){this[k]=v;},useProgram(){},activeTexture(){},bindTexture(){},
    drawElements(){this.draws.push(this.color.slice());if(this.fail)throw Error('draw failure');}
  };const program={};c.window=c;vm.createContext(c);vm.runInContext(source('naki-core.js'),c);return {c,gl};
}
test('atlas decoder rejects full-screen, invalid scale and invalid offsets',()=>{
  const {c}=renderer();const H=c.__nakiHighlight;
  assert.equal(H.decode([1,1,0,0]),null);assert.equal(H.decode([0.1,0.25,0,0]),'E');
  assert.equal(H.decode([0.1,0.25,0,0.25]),'5pr');assert.equal(H.decode([0.1,0.25,0.15,0.25]),null);
  assert.equal(H.decode([0.1,0.25,NaN,0.25]),null);
});
test('WebGL1 fallback tints tile only and restores uniform even on exception',()=>{
  const {c,gl}=renderer();c.__nakiHighlight.set([{tile:'7p',color:[0.45,1,0.5]}],null);
  gl.drawElements(4,6,0,0);assert.deepEqual(gl.draws[0],[0.45,1,0.5,1]);assert.deepEqual(gl.color,[1,1,1,1]);
  gl.st=[1,1,0,0];gl.drawElements(4,6,0,0);assert.deepEqual(gl.draws[1],[1,1,1,1]);
  gl.st=[0.1,0.25,0.7,0.25];gl.fail=true;assert.throws(()=>gl.drawElements(4,6,0,0));assert.deepEqual(gl.color,[1,1,1,1]);
});
test('UI shader is excluded from tile tint',()=>{
  const {c,gl}=renderer();gl.ui=true;c.__nakiHighlight.set([{tile:'7p',color:[0,1,0]}],null);gl.drawElements(4,6,0,0);assert.deepEqual(gl.draws[0],[1,1,1,1]);
});
test('disabling name mask cancels calibration probe immediately',()=>{
  const {c,gl}=renderer();gl.ui=true;c.__nakiHighlight.setNameMask(true);c.__nakiHighlight.maskProbe(0);c.__nakiHighlight.setNameMask(false);
  gl.drawElements(4,60,0,0);assert.deepEqual(gl.draws[0],[1,1,1,1]);assert.equal(c.__nakiHighlight.nameMaskStatus().calibrating,false);
});
function notifyEnvelope(method, payload = [0]) {
  const m = Buffer.from(method);
  return new Uint8Array([1, 10, m.length, ...m, 18, payload.length, ...payload]);
}
function rewriteSetup(methods) {
  const s = setup(); let ctxs = [];
  s.c.__nakiPlugins.setGrant('rw', { capabilities: ['observe', 'rewriteReceive'], methods, observeNakiTraffic: true });
  s.c.__nakiPlugins.register({ id: 'rw', onReceive(ctx) { ctxs.push(ctx); } });
  return { ...s, ctxs };
}
function dispatch(c, direction, bytes) { c.__nakiPlugins.dispatch({ direction, wsId: 1, url: '', bytes }); }
test('Naki traffic (msgId registered by sendRaw) never gets ctx.replace', () => {
  const { c, socket } = page(); const ctxs = [];
  c.__nakiPlugins.setGrant('rw', { capabilities: ['observe', 'rewriteReceive'], methods: ['.lq.Foo'], observeNakiTraffic: true });
  c.__nakiPlugins.register({ id: 'rw', onReceive(ctx) { ctxs.push(ctx); } });
  const ws = socket('wss://game.example/gateway');
  c.__nakiWebSocket.sendRaw(b64(request(60001, '.lq.Foo', [0])));
  ws.listeners.message({ data: response(60001, [0]).buffer });
  assert.equal(ctxs.length, 1); assert.equal(ctxs[0].isNaki, true); assert.equal(ctxs[0].replace, undefined);
});
test('replace that swaps the method is reverted and counted as a failure', () => {
  const { c, ctxs } = rewriteSetup(['.lq.FastTest.syncGamX']);
  const bytes = notifyEnvelope('.lq.FastTest.syncGamX'); const orig = Array.from(bytes);
  dispatch(c, 'receive', bytes);
  assert.equal(typeof ctxs[0].replace, 'function');
  assert.equal(ctxs[0].replace(notifyEnvelope('.lq.FastTest.syncGame')), false);
  assert.deepEqual(Array.from(bytes), orig);
  assert.equal(c.__nakiPlugins.diagnostics().runtime.lastError.id, 'rw');
});
test('replace keeping the same method still works', () => {
  const { c, ctxs } = rewriteSetup(['.lq.Foo']);
  const bytes = notifyEnvelope('.lq.Foo', [1]); dispatch(c, 'receive', bytes);
  assert.equal(ctxs[0].replace(notifyEnvelope('.lq.Foo', [2])), true);
  assert.equal(bytes.at(-1), 2);
});
test('failures are counted per hook: a healthy hook does not reset a failing one', () => {
  const { c } = setup();
  c.__nakiPlugins.setGrant('half', { capabilities: ['observe'], methods: ['.lq.Foo'] });
  c.__nakiPlugins.register({ id: 'half', onReceive() { throw Error('boom'); }, onRecommendations() {} });
  for (let i = 0; i < 10; i++) {
    dispatch(c, 'receive', notifyEnvelope('.lq.Foo'));
    c.__nakiPlugins.recommendationsChanged([rec()]);
  }
  assert.equal(c.__nakiPlugins.list().length, 0);
});
// ---- envelope 解析（naki-core 共用一份，websocket 遮名與插件派發都走它）----
function page(random) {
  const s = setup();
  if (random != null) vm.runInContext('Math.random = () => ' + random, s.c);
  class Socket { constructor(url) { this.url = url; this.readyState = 1; this.listeners = {}; this.sent = []; }
    addEventListener(k, f) { this.listeners[k] = this.listeners[k] || f; } send(d) { this.sent.push(new Uint8Array(d)); } }
  Socket.OPEN = 1; Socket.CLOSED = 3; s.c.WebSocket = Socket;
  vm.runInContext(source('naki-websocket.js'), s.c);
  return { ...s, socket: url => new s.c.WebSocket(url) };
}
function request(msgId, method, payload = []) {
  const m = Buffer.from(method);
  return new Uint8Array([2, msgId & 0xff, msgId >> 8, 10, m.length, ...m, 18, payload.length, ...payload]);
}
const b64 = u8 => Buffer.from(u8).toString('base64');
function response(msgId, payload = []) { return new Uint8Array([3, msgId & 0xff, msgId >> 8, 10, 0, 18, payload.length, ...payload]); }
test('core parseEnvelope: corpus locks shared semantics', () => {
  const { c } = setup(); const P = b => plain(c.__nakiCore.parseEnvelope(new Uint8Array(b)));
  const m = [...Buffer.from('.lq.Foo')], A = [10, 1, 0x41];
  const env = (type, msgId, method, payload, complete) => ({ type, msgId, method, payload, complete });
  assert.deepEqual(P([1, 10, 7, ...m, 18, 1, 9]), env(1, null, '.lq.Foo', { from: 12, to: 13 }, true));
  assert.deepEqual(P([2, 0x61, 0xEA, 10, 7, ...m, 18, 0]), env(2, 60001, '.lq.Foo', { from: 14, to: 14 }, true));
  assert.deepEqual(P([2, 1, 0, 10, 9, ...m]), env(2, 1, null, null, false), 'length past end');
  assert.deepEqual(P([1, ...A, 18, 5, 1]), env(1, null, 'A', null, false), 'partial fields survive');
  assert.deepEqual(P([1, 10, 2, 0xC3, 0xA9]), env(1, null, 'Ã©', null, true), 'non-ASCII method is latin1');
  assert.deepEqual(P([1, 8, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 1, ...A]), env(1, null, 'A', null, true), '7-byte varint');
  assert.deepEqual(P([1, 8, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 1]), env(1, null, null, null, false), 'varint too long');
  assert.deepEqual(P([1, 11, ...A]), env(1, null, null, null, false), 'wire 3');
  assert.deepEqual(P([1, 0xC2, 0x3E, 1, 0, ...A]), env(1, null, 'A', null, true), 'field 1000');
  assert.deepEqual(P([1, 13, 1]), env(1, null, null, null, true), 'fixed32 past end');
  for (const b of [[], [4, 10, 0], [2, 1]]) assert.equal(c.__nakiCore.parseEnvelope(new Uint8Array(b)), null);
  assert.deepEqual(plain(c.__nakiCore.readVarint(new Uint8Array([0x80, 0x80, 0x80, 0x80, 0x10]), 0, 5)), [2 ** 32, 5]);
});
test('authGame nickname is masked in place; malformed response is left alone', () => {
  const { c, socket } = page(); const ws = socket('wss://game.example/game-gateway');
  c.__nakiHideNames.setEnabled(true);
  const name = [...Buffer.from('Alice12')], view = [0x22, name.length, ...name];
  ws.send(request(7, '.lq.FastTest.authGame'));
  const bytes = response(7, [18, view.length, ...view]);
  ws.listeners.message({ data: bytes.buffer });
  assert.equal(Buffer.from(bytes.slice(-7)).toString(), 'P1     ');
  ws.send(request(8, '.lq.FastTest.authGame'));
  const bad = new Uint8Array([...response(8, [18, view.length, ...view]), 11]);
  ws.listeners.message({ data: bad.buffer });
  assert.equal(Buffer.from(bad.slice(-8, -1)).toString(), 'Alice12');
  assert.equal(c.__nakiHideNames.getStatus().maskedFields, 1);
});
// ---- D9：Naki 自送登記（sendRaw 送出前登記最近 256 筆 msgId）----
const LOBBY = '.lq.Lobby.fetchInfo';
function traffic() {
  const p = page(); const general = [], watcher = [];
  p.c.__nakiPlugins.setGrant('general', { capabilities: ['observe'], methods: [LOBBY] });
  p.c.__nakiPlugins.register({ id: 'general', onSend(ctx) { general.push(ctx.msgId); }, onReceive(ctx) { general.push(ctx.msgId); } });
  p.c.__nakiPlugins.setGrant('watcher', { capabilities: ['observe'], methods: [LOBBY], observeNakiTraffic: true });
  p.c.__nakiPlugins.register({ id: 'watcher', onSend(ctx) { watcher.push([ctx.msgId, ctx.isNaki]); }, onReceive(ctx) { watcher.push([ctx.msgId, ctx.isNaki]); } });
  const ws = p.socket('wss://game.example/gateway');
  const lobbySendAt = () => p.c.__nakiWebSocket.getMajsoulConnections()[0].lastLobbySendAt;
  return { ...p, ws, general, watcher, lobbySendAt };
}
test('D9 Naki send: registered before ws.send, never lobby evidence, isNaki both ways', () => {
  const { c, ws, general, watcher, lobbySendAt } = traffic();
  assert.equal(c.__nakiWebSocket.sendRaw(b64(request(60005, LOBBY))).success, true);
  ws.listeners.message({ data: response(60005).buffer });
  assert.equal(ws.sent.length, 1); assert.equal(lobbySendAt(), 0);
  assert.deepEqual(watcher, [[60005, true], [60005, true]]); assert.deepEqual(general, []);
});
test('D9 page send is the game\'s own at any msgId: lobby evidence, visible to plugins', () => {
  for (const msgId of [100, 60001, 65535]) {
    const { ws, general, watcher, lobbySendAt } = traffic();
    ws.send(request(msgId, LOBBY)); ws.listeners.message({ data: response(msgId).buffer });
    assert.ok(lobbySendAt() > 0, String(msgId));
    assert.deepEqual(watcher, [[msgId, false], [msgId, false]]); assert.deepEqual(general, [msgId, msgId]);
  }
});
test('D9/D22 plugin send: registered via sendRaw; the plugin range alone is not Naki', () => {
  const { c, ws, general, watcher, lobbySendAt } = traffic(); let notify;
  c.__nakiPluginsMayModifyOutbound = true;
  c.__nakiPlugins.setGrant('injector', { capabilities: ['observe', 'injectSend'], methods: ['.lq.NotifyFoo'] });
  c.__nakiPlugins.register({ id: 'injector', onReceive(ctx) { notify = ctx; } });
  ws.listeners.message({ data: notifyEnvelope('.lq.NotifyFoo').buffer });
  assert.deepEqual(plain(notify.sendRequest(LOBBY, new Uint8Array(0))), { ok: true, msgId: 64000 });
  assert.equal(c.__nakiWebSocket.isNakiSent(64000), true); assert.equal(lobbySendAt(), 0);
  ws.send(request(64001, LOBBY));
  assert.ok(lobbySendAt() > 0, 'unregistered id is the game\'s own for line selection');
  assert.deepEqual(watcher, [[64000, true], [64001, false]]); assert.deepEqual(general, [64001]);
});
test('D9 registry keeps the latest 256 sends; re-sending refreshes; evicted ids count as the game\'s', () => {
  const { c, ws, watcher } = traffic(); const sent = id => c.__nakiWebSocket.sendRaw(b64(request(id, LOBBY)));
  sent(60005); sent(60006); ws.listeners.message({ data: response(60005).buffer });
  assert.deepEqual(watcher.at(-1), [60005, true]);
  for (let id = 60100; id < 60355; id++) sent(id);
  sent(60006); sent(60355);
  assert.equal(c.__nakiWebSocket.isNakiSent(60005), false, 'oldest evicted after 256 newer sends');
  assert.equal(c.__nakiWebSocket.isNakiSent(60006), true, 're-send moved it to the newest slot');
  assert.equal(c.__nakiWebSocket.isNakiSent(60100), false); assert.equal(c.__nakiWebSocket.isNakiSent(60101), true);
});
test('D22 registry is per connection: the same msgId on another socket is the game\'s own', () => {
  const { c, ws, general, watcher, socket } = traffic();
  assert.equal(c.__nakiWebSocket.sendRaw(b64(request(60005, LOBBY))).success, true);
  const other = socket('wss://game.example/gateway');
  const [a, b] = c.__nakiWebSocket.getMajsoulConnections().map(x => x.id);
  assert.equal(c.__nakiWebSocket.isNakiSent(60005, a), true);
  assert.equal(c.__nakiWebSocket.isNakiSent(60005, b), false);
  assert.equal(c.__nakiWebSocket.isNakiSent(60005), true, 'no socket given: any connection');
  other.send(request(60005, LOBBY)); other.listeners.message({ data: response(60005).buffer });
  assert.ok(c.__nakiWebSocket.getMajsoulConnections()[1].lastLobbySendAt > 0, 'lobby evidence on the other socket');
  assert.deepEqual(watcher, [[60005, true], [60005, false], [60005, false]]); assert.deepEqual(general, [60005, 60005]);
  ws.listeners.message({ data: response(60005).buffer });
  assert.deepEqual(watcher.at(-1), [60005, true]);
});
const GATEWAY = 'wss://game.example/gateway';
test('D22-2 an injected RESPONSE stays Naki after its sendRaw registration is evicted by the other /gateway', () => {
  const { c, ws, socket } = traffic(); let notify; const got = [];
  c.__nakiPluginsMayModifyOutbound = true;
  c.__nakiPlugins.setGrant('injector', { capabilities: ['observe', 'injectSend', 'rewriteReceive'], methods: ['.lq.NotifyFoo', LOBBY] });
  c.__nakiPlugins.register({ id: 'injector', onReceive(ctx) { notify = ctx; },
    onInjectResponse(ctx) { got.push([ctx.isNaki, typeof ctx.replace]); } });
  ws.listeners.message({ data: notifyEnvelope('.lq.NotifyFoo').buffer });
  assert.equal(notify.sendRequest(LOBBY, new Uint8Array(0)).msgId, 64000);
  const other = socket(GATEWAY); other.send(request(100, LOBBY));
  for (let id = 60100; id < 60356; id++) c.__nakiWebSocket.sendRaw(b64(request(id, LOBBY)));
  const [a, b] = c.__nakiWebSocket.getMajsoulConnections().map(x => x.id);
  assert.equal(other.sent.length, 257);
  assert.equal(c.__nakiWebSocket.isNakiSent(64000, a), false, '256 slots are shared by both sockets');
  assert.equal(c.__nakiWebSocket.isNakiSent(60100, b), true);
  ws.listeners.message({ data: response(64000).buffer });
  assert.deepEqual(got, [[true, 'undefined']]);
});
test('D22-2 same socket, same msgId: Naki until its RESPONSE arrives, the game\'s own after; the RESPONSE stays Naki', () => {
  const { c, ws, watcher, lobbySendAt } = traffic();
  c.__nakiWebSocket.sendRaw(b64(request(60007, LOBBY)));
  ws.send(request(60007, LOBBY));
  assert.deepEqual(watcher.at(-1), [60007, true], 'residual: collision while the Naki request is in flight');
  assert.equal(lobbySendAt(), 0);
  ws.listeners.message({ data: response(60007).buffer });
  assert.deepEqual(watcher.at(-1), [60007, true]);
  ws.send(request(60007, LOBBY));
  assert.deepEqual(watcher.at(-1), [60007, false]); assert.ok(lobbySendAt() > 0);
  ws.listeners.message({ data: response(60007).buffer });
  assert.deepEqual(watcher.at(-1), [60007, true], 'a RESPONSE on a registered pair is never handed out as the game\'s');
  assert.equal(c.__nakiWebSocket.isNakiSent(60007), true); assert.equal(c.__nakiWebSocket.isNakiSent(60007, null, true), false);
});
test('D22-2 socket ids: a random start per page, so a reload with the same random value repeats ids; a reconnect never does', () => {
  const first = page(0.25), again = page(0.25), other = page(0.5);
  const ws = first.socket(GATEWAY); again.socket(GATEWAY); other.socket(GATEWAY);
  const id = p => p.c.__nakiWebSocket.getMajsoulConnections()[0].id;
  assert.equal(id(first), id(again)); assert.notEqual(id(first), id(other));
  first.c.__nakiWebSocket.sendRaw(b64(request(60009, LOBBY)));
  assert.equal(again.c.__nakiWebSocket.isNakiSent(60009), false, 'the registry does not survive a reload');
  const before = id(first); ws.readyState = 3; first.socket(GATEWAY);
  assert.notEqual(id(first), before);
  assert.equal(first.c.__nakiWebSocket.isNakiSent(60009, id(first)), false);
  assert.equal(first.c.__nakiWebSocket.isNakiSent(60009, before), true);
});
test('D22-3 a re-send of an answered pair is pending again: the game\'s same pair is Naki and not lobby evidence', () => {
  const { c, ws, watcher, lobbySendAt } = traffic(); const id = () => c.__nakiWebSocket.getMajsoulConnections()[0].id;
  c.__nakiWebSocket.sendRaw(b64(request(60011, LOBBY)));
  ws.listeners.message({ data: response(60011).buffer });
  assert.equal(c.__nakiWebSocket.isNakiSent(60011, id(), true), false);
  c.__nakiWebSocket.sendRaw(b64(request(60011, LOBBY)));
  assert.equal(c.__nakiWebSocket.isNakiSent(60011, id(), true), true);
  ws.send(request(60011, LOBBY));
  assert.deepEqual(watcher.at(-1), [60011, true]); assert.equal(lobbySendAt(), 0);
});
test('D22-3 the same Naki msgId on two /gateway sockets, only one answered: isNaki and lobby evidence follow each socket', () => {
  const { c, ws, watcher, socket } = traffic();
  c.__nakiWebSocket.sendRaw(b64(request(60012, LOBBY)));
  const other = socket(GATEWAY); other.send(request(100, LOBBY));
  c.__nakiWebSocket.sendRaw(b64(request(60012, LOBBY)));
  assert.equal(other.sent.length, 2);
  ws.listeners.message({ data: response(60012).buffer });
  const conns = () => c.__nakiWebSocket.getMajsoulConnections(), [a, b] = conns().map(x => x.id);
  assert.equal(c.__nakiWebSocket.isNakiSent(60012, a, true), false);
  assert.equal(c.__nakiWebSocket.isNakiSent(60012, b, true), true);
  assert.equal(conns()[0].lastLobbySendAt || 0, 0);
  ws.send(request(60012, LOBBY));
  assert.deepEqual(watcher.at(-1), [60012, false]); assert.ok(conns()[0].lastLobbySendAt > 0);
  other.send(request(60012, LOBBY));
  assert.deepEqual(watcher.at(-1), [60012, true]);
});
test('D22-3 residual + pair-source: with its sendRaw registration evicted and a game fetchInfo on the injected pair, the game RESPONSE arriving first is claimed by the injection; the real injection RESPONSE after it is ambiguous — Naki observers only, no rewrite', () => {
  const { c, ws, general, watcher, socket } = traffic(); let notify; const got = [], rewriters = [];
  const FST = '.lq.Lobby.fetchServerTime';
  c.__nakiPluginsMayModifyOutbound = true;
  c.__nakiPlugins.setGrant('injector', { capabilities: ['observe', 'injectSend'], methods: ['.lq.NotifyFoo'] });
  c.__nakiPlugins.register({ id: 'injector', onReceive(ctx) { notify = ctx; }, onInjectResponse(ctx) { got.push([ctx.isNaki, ctx.method, Array.from(ctx.bytes.slice(-1))]); } });
  c.__nakiPlugins.setGrant('rw', { capabilities: ['observe', 'rewriteReceive'], methods: [LOBBY] });
  c.__nakiPlugins.register({ id: 'rw', onReceive(ctx) { rewriters.push([ctx.msgId, typeof ctx.replace]); } });
  ws.listeners.message({ data: notifyEnvelope('.lq.NotifyFoo').buffer });
  assert.equal(notify.sendRequest(FST, new Uint8Array(0)).msgId, 64000);
  const other = socket(GATEWAY); other.send(request(100, LOBBY));
  for (let id = 60100; id < 60356; id++) c.__nakiWebSocket.sendRaw(b64(request(id, LOBBY)));
  ws.send(request(64000, LOBBY));
  ws.listeners.message({ data: response(64000, [8, 1]).buffer });
  ws.listeners.message({ data: response(64000, [8, 2]).buffer });
  assert.deepEqual(got, [[true, FST, [1]]], 'the first RESPONSE on the pair goes to the injection by send order');
  assert.deepEqual(general.filter(x => x === 64000), [64000], 'only the game REQUEST reaches the general chain');
  assert.deepEqual(rewriters.filter(x => x[0] === 64000), [], 'the ambiguous RESPONSE never reaches a rewriteReceive plugin');
  assert.deepEqual(watcher.filter(x => x[0] === 64000), [[64000, false], [64000, true]], 'the ambiguous RESPONSE is Naki-attributed');
});

// WebKit 握手失敗兩種情境（live 2026-10-17）：error 當下 readyState 仍是 0；(a) 之後完全沒有 close（live 紀錄）、(b) 下個 tick 變 3 並補 close
function failHandshake(ws) { ws.readyState = 0; ws.listeners.error({}); }
test('handshake failure (a): error with no close afterwards releases the connection and notifies plugins once', () => {
  const { c, events, socket } = page(); let closed = 0, ids = []; const orig = c.__nakiPlugins.closed;
  c.__nakiPlugins.closed = id => { closed++; ids.push(id); return orig.call(c.__nakiPlugins, id); };
  const ws = socket(GATEWAY); const id = c.__nakiWebSocket.getConnections()[0].id;
  failHandshake(ws);
  assert.equal(c.__nakiWebSocket.getConnections().some(x => x.id === id), false);
  assert.deepEqual([closed, ids[0]], [1, id]);
  assert.equal(events.filter(e => e.type === 'websocket_error').length, 1);
});
test('handshake failure (b): the close that follows the error neither releases nor notifies plugins twice, Swift still hears it', () => {
  const { c, events, socket } = page(); let closed = 0; const orig = c.__nakiPlugins.closed;
  c.__nakiPlugins.closed = id => { closed++; return orig.call(c.__nakiPlugins, id); };
  const ws = socket(GATEWAY);
  failHandshake(ws); ws.readyState = 3; ws.listeners.close({ code: 1006, reason: '' });
  assert.equal(closed, 1); assert.equal(c.__nakiWebSocket.getConnections().length, 0);
  assert.equal(events.filter(e => e.type === 'websocket_close').length, 1);
});
test('close then error releases only once', () => {
  const { c, socket } = page(); let closed = 0; const orig = c.__nakiPlugins.closed;
  c.__nakiPlugins.closed = id => { closed++; return orig.call(c.__nakiPlugins, id); };
  const ws = socket(GATEWAY); ws.readyState = 3;
  ws.listeners.close({ code: 1006, reason: '' }); ws.listeners.error({});
  assert.equal(closed, 1); assert.equal(c.__nakiWebSocket.getConnections().length, 0);
});
