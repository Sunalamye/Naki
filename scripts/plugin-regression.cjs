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
    __nakiCore: { sendToSwift: (type, data) => events.push({type,data}) },
    __nakiRecommendations: [], __nakiRecommendationContext: {}, __nakiPluginGrants: {},
    __nakiHighlight: { set: (marks,popup) => renders.push(plain({marks,popup})), clear: () => renders.push(null), state: () => ({}) }
  };
  c.window = c; vm.createContext(c); vm.runInContext(source('naki-plugins.js'),c);
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
  class Socket { constructor(){this.listeners={};} addEventListener(k,f){this.listeners[k]=f;} send(){} }
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
test('Naki traffic (msgId >= 60000) never gets ctx.replace', () => {
  const { c, ctxs } = rewriteSetup(['.lq.Foo']);
  const m = Buffer.from('.lq.Foo');
  const mk = type => new Uint8Array([type, 0x61, 0xEA, 10, m.length, ...m, 18, 1, 0]);
  dispatch(c, 'send', mk(2)); dispatch(c, 'receive', mk(3));
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
