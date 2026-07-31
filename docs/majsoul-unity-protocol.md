# Majsoul Unity 客戶端 × Liqi 協議參考

**日期**: 2026-07-31
**來源**: runtime 實測（WebSocket 封包擷取 + 全域物件列舉 + 自組請求送出）
**狀態**: 這是 Unity 時代**唯一有效**的雀魂互動參考。舊的 Laya JS 物件文件已作廢，見
[majsoul-webui-objects-reference.md](majsoul-webui-objects-reference.md) /
[majsoul-webui-api-architecture.md](majsoul-webui-api-architecture.md)。

> **驗收語彙**
> **已驗證** = 本輪 runtime 實測有事實佐證（封包 hex / 全域物件列舉 / 伺服器回應）
> **由 source 推導** = 讀 Naki 自己的 code 得到，未跑 runtime 確認
> **未驗證** = 尚無實測，不可當事實引用

---

## 目錄

1. [一句話結論](#一句話結論)
2. [Unity 客戶端事實](#unity-客戶端事實)
3. [Liqi Envelope 格式](#liqi-envelope-格式)
4. [實測封包逐位元組解說](#實測封包逐位元組解說)
5. [接收訊息](#接收訊息)
6. [送出請求](#送出請求)
7. [msgId 管理](#msgid-管理)
8. [已驗證的 PoC](#已驗證的-poc)
9. [尚未驗證的部分](#尚未驗證的部分)

---

## 一句話結論

**JS/DOM 層已死，protobuf 層完好。**

雀魂客戶端從 Laya JS 換成 Unity WebGL 後，遊戲邏輯與 UI 全部搬進 wasm，
JavaScript 端再也拿不到手牌、操作按鈕、配置表等物件。
但 **Liqi wire protocol 一個位元組都沒變**，WebSocket 仍是 JS 可攔可送的通道，
所以 Naki 的正確路線是：**所有讀取與動作都改走 Liqi protobuf**。

---

## Unity 客戶端事實

**已驗證**（2026-07-31 runtime 列舉）：

| 項目 | 值 |
|------|-----|
| 引擎 | Unity WebGL（原為 Laya 3D） |
| 版本字串 | `chs_t-WebGL-release-4.0.45(45)` |
| 載入器 | `loader.js`、`framework.js.gz` |
| 全域物件 | `createUnityInstance`、`unityFramework`、`getUnityElements`、`onUnityReady` |
| 容器 | `<div id="unity-container">` |
| 畫布 | `<canvas id="unity-canvas" width="2560" height="1440">` |

### 已確認**不存在**的全域（舊 Laya 時代物件）

```
window.Laya            window.GameMgr         window.uiscript
window.view.DesktopMgr window.cfg             window.app.NetAgent
```

因此下列舊做法**全數失效**（不是「可能失效」，是實測不存在）：

- `mainrole.hand` 讀手牌、`setChoosePai()` / `DoDiscardTile()` 打牌
- `effect_doraPlane.clone()` 做寶牌／推薦高亮
- `uimgr._ui_lobby` 切頁、`_uis[105].addMatch()` 匹配
- `cfg.xxx.rows_` 讀寫客戶端本地設定表
- `GameMgr.Inst.clientHeatBeat()` 防閒置
- `app.NetAgent.sendReq2Lobby(...)` 發請求

> Unity 內部（wasm 記憶體佈局、Il2Cpp 符號、`unityFramework` 可呼叫面）**本輪未探測**。
> 不要在文件或 code 中對 Unity 內部做任何推測性宣稱。

---

## Liqi Envelope 格式

**已驗證**：外層封包結構與 Laya 時代完全相同。

```
┌────────┬──────────────┬──────────────────────────────────────┐
│ type   │ msgId        │ protobuf body                        │
│ 1 byte │ 2 bytes LE   │ { field1: method(string),            │
│        │              │   field2: payload(bytes) }           │
└────────┴──────────────┴──────────────────────────────────────┘
```

| type | 含義 | msgId | body |
|------|------|-------|------|
| `1` | NOTIFY（伺服器主動推播） | — | field1 = 方法名，field2 = payload |
| `2` | REQUEST（客戶端請求） | 客戶端配發 | field1 = 方法名，field2 = payload |
| `3` | RESPONSE（伺服器回應） | 對應 REQUEST 的 msgId | field1 空、field2 = payload |

### 加密

- **REQUEST / RESPONSE：無 XOR**，方法名是**明文 ASCII**（`.lq.Route.heartbeat` 直接可見）。
- **XOR 只用於 NOTIFY 的 `.lq.ActionPrototype.data`**（對局動作內容）。
  演算法與金鑰見 `FLOW_COMPARISON.md` 與 `command/Services/Bridge/MajsoulBridge.swift`。
- `syncGame` / `enterGame` 回應內的 `gameRestore.actions[]` **不需要 XOR**（既有結論，未因 Unity 遷移改變）。

---

## 實測封包逐位元組解說

### REQUEST（34 bytes，遊戲自己送出的真實心跳）

```
028d000a132e6c712e526f7574652e686561727462656174120808001000180b200f
```

| offset | bytes | 解讀 |
|--------|-------|------|
| 0 | `02` | type = 2 → **REQUEST** |
| 1–2 | `8d 00` | msgId = 0x008d = **141**（little-endian） |
| 3 | `0a` | protobuf tag：field **1**, wire type 2 (length-delimited) |
| 4 | `13` | 長度 = 19 |
| 5–23 | `2e 6c 71 2e 52 6f 75 74 65 2e 68 65 61 72 74 62 65 61 74` | ASCII `.lq.Route.heartbeat` |
| 24 | `12` | protobuf tag：field **2**, wire type 2 |
| 25 | `08` | 長度 = 8 |
| 26–33 | `08 00 10 00 18 0b 20 0f` | payload（見下） |

payload 的 protobuf 拆解（**機械拆解已驗證，欄位語意未驗證**）：

| bytes | tag | 值 |
|-------|-----|-----|
| `08 00` | field 1, varint | 0 |
| `10 00` | field 2, varint | 0 |
| `18 0b` | field 3, varint | 11 |
| `20 0f` | field 4, varint | 15 |

### RESPONSE（7 bytes，伺服器對上面那筆的回應）

```
038d000a001200
```

| offset | bytes | 解讀 |
|--------|-------|------|
| 0 | `03` | type = 3 → **RESPONSE** |
| 1–2 | `8d 00` | msgId = **141**，與 REQUEST 配對 |
| 3–4 | `0a 00` | field 1, length 0 → 方法名空字串 |
| 5–6 | `12 00` | field 2, length 0 → payload 空 |

> RESPONSE 不重覆方法名，**只能靠 msgId 配對**。這是 msgId 管理必須小心的原因。

---

## 接收訊息

**已驗證**：既有 `naki-websocket.js` hook 在 Unity 客戶端下仍正常運作。

- 實測有 2 條 live 連線：`wss://route-N.maj-soul.com/gateway`
- Swift 端 `LiqiParser` 解碼仍正常（協議沒變，parser 不需改）

機制（`command/Resources/JavaScript/naki-websocket.js`）：

```
包裝 window.WebSocket 建構子
  ├─ addEventListener('message')  → handleMessage(..., 'receive')
  ├─ 覆寫 ws.send                 → handleMessage(..., 'send') 後呼叫原生 send
  └─ 以 URL 關鍵字判定是否為雀魂連線（majsoul / mj- / game. / gateway / match）
        └─ 非雀魂連線直接略過，不轉發
```

frame 以 base64 經 `websocketBridge` message handler 送到 Swift。

查詢連線：

```js
return JSON.stringify(window.__nakiWebSocket.getConnections());
// [{ id, url, isMajsoul, readyState, age }, ...]
```

---

## 送出請求

**已驗證**：`getMajsoulConnections()` 回傳物件含**原始 `ws` 參考**，可直接 `.send()`。

```js
// naki-websocket.js → window.__nakiWebSocket.getMajsoulConnections()
const conns = window.__nakiWebSocket.getMajsoulConnections();
// [{ id, url, ws }, ...]  ← 只回傳 isMajsoul && readyState === OPEN 的連線
conns[0].ws.send(bytes);   // bytes: Uint8Array / ArrayBuffer
```

### 並行開發中的封裝：`sendRaw(base64)`

**由 source 推導，未 runtime 驗證**（2026-07-31 讀 code 時工作區已存在，非本輪文件作業產物）：
`naki-websocket.js` 已新增 `window.__nakiWebSocket.sendRaw(base64)`，
搭配新檔 `command/Services/Bridge/LiqiEncoder.swift`（Swift 端組 envelope → base64 → JS 送出）。

```js
window.__nakiWebSocket.sendRaw(base64)
// → { success: true, bytes, socketId }
// → { success: false, reason: 'invalid_base64' | 'decode_failed: …' | 'empty_payload'
//                            | 'no_open_majsoul_connection' | 'send_failed: …' }
```

行為（讀 code 得知）：驗 base64 格式 → 解碼 → 取 `getMajsoulConnections()[0]` → `ws.send(buffer)`。
只送第一條連線、不做任何協定加工。**這條路徑的 runtime 行為未在本文驗證。**

### 注意：送出會被自己的 hook 攔到

**由 source 推導**（`naki-websocket.js` 中 `ws.send` 的包裝）：`ws.send` 已被 Naki 包裝，
所以 Naki 自己送出的請求也會走一次 `handleMessage(..., 'send')` 並轉發給 Swift。
若 Swift 端要區分「遊戲送的」與「Naki 送的」，需要靠 msgId 區間判斷。
**此行為對 Swift 端解析的實際影響未實測。**

繞過方式（若確定不想讓自己的封包進 bridge）：使用 `window.__nakiWebSocket.OriginalWebSocket`
之外的路徑目前**沒有**現成 API——原始 `ws` 實例的 `send` 已在建構時被覆寫。**未驗證是否有其他繞法。**

---

## msgId 管理

**已驗證的事實**：遊戲自己用**低位遞增**的 msgId（實測心跳為 141）。

**規則（Naki 自送時必守）**：

- Naki 自組的 REQUEST 一律用**高位號段，建議 60000+**，避免與遊戲的低位序列撞號。
- 撞號的後果：RESPONSE 只帶 msgId 不帶方法名，撞號會讓遊戲客戶端把「我們的回應」
  當成「它自己那筆請求的回應」餵給 Unity，或反之——**未驗證實際崩潰行為，但避免即可。**
- 每筆自送請求自己記錄 `msgId → method` 的對照表，收到同 msgId 的 type=3 才知道那是什麼。

---

## 已驗證的 PoC

**結論：自組 Liqi 請求送出可行，已驗證。**

實測步驟：

1. 從 live 連線擷取遊戲真實送出的 heartbeat REQUEST（上面那 34 bytes）。
2. 機械改寫其 msgId 為 `60000`（0xEA60 → little-endian `60 EA`），其餘位元組不動。
3. 透過 `getMajsoulConnections()[0].ws.send(...)` 送出。
4. **伺服器正確回應 msgId=60000 的 RESPONSE** → 封包被接受、msgId 配對正確。

對應的封包（依實測封包機械改寫 msgId 而得）：

```
0260ea0a132e6c712e526f7574652e686561727462656174120808001000180b200f
  ^^^^^ msgId = 60000
```

參考重建程式碼（供除錯用；**此片段本身未逐行 runtime 驗證**，
已驗證的是「同構封包 + msgId=60000 會得到對應 RESPONSE」這件事）：

```js
// 在遊戲頁面 context 執行（Debug Server /js 需要 return）
(function () {
  const method = '.lq.Route.heartbeat';
  const payload = [0x08, 0x00, 0x10, 0x00, 0x18, 0x0b, 0x20, 0x0f];
  const msgId = 60000;

  const nameBytes = Array.from(method, c => c.charCodeAt(0));
  const bytes = [
    0x02,                                   // type = REQUEST
    msgId & 0xff, (msgId >> 8) & 0xff,      // msgId, little-endian
    0x0a, nameBytes.length, ...nameBytes,   // field1 = method
    0x12, payload.length, ...payload        // field2 = payload
  ];

  const conns = window.__nakiWebSocket.getMajsoulConnections();
  if (!conns.length) return { ok: false, error: 'no live majsoul ws' };
  conns[0].ws.send(new Uint8Array(bytes));
  return { ok: true, msgId: msgId, len: bytes.length };
})()
```

驗證方法：看 Naki log / bridge 是否出現 `03 60 ea ...` 開頭的 RESPONSE frame。

---

## 尚未驗證的部分

以下**全部未驗證**，任何 code 或文件都不得把它們當事實引用。
要驗證的唯一方法是**抓真實對局／大廳封包比對**。

### 對局動作（送出面）

| 需求 | 推測方法名 | 狀態 |
|------|-----------|------|
| 打牌 / 吃碰槓 / 立直 / 和了 | `.lq.FastTest.inputOperation`（或 `inputChiPengGang`） | ❌ payload schema **未實測** |
| 確認進入對局 | `.lq.FastTest.authGame` | ❌ 未實測 |
| 同步 | `.lq.FastTest.syncGame` | ❌ 未實測（接收面 Naki 既有 parser 有處理，送出面未測） |

### 大廳（送出面）

| 需求 | 推測方法名 | 狀態 |
|------|-----------|------|
| 匹配 | `.lq.Lobby.matchGame` / `startUnifiedMatch` | ❌ payload schema **未實測** |
| 建房 / 加入 / 準備 | `.lq.Lobby.createRoom` / `joinRoom` / `readyPlay` | ❌ 未實測 |
| 帳號資訊（段位） | `.lq.Lobby.fetchAccountInfo` | ❌ 未實測 |

> 這些方法名來自 **Laya 時代**的 `app.NetAgent` 呼叫清單（見舊文件的歷史存檔段落）。
> Liqi 服務名前綴（`.lq.Lobby.` / `.lq.FastTest.`）與各方法的 request message 欄位定義
> **本輪都沒有實測**，只有 `.lq.Route.heartbeat` 是實測確認的完整範例。

### 其他未探測項

- 防閒置：Unity 下如何觸發／是否需要 Naki 自己補送 `.lq.Route.heartbeat`

---

## Unity 執行期可控面（2026-07-31 實測補充）

**已驗證**：Unity instance **拿得到**，先前「完全未探測」的判定作廢。

### 怎麼取到 instance（關鍵）

`window.unityFramework` 是 **`null`**（`typeof` 回 `"object"` 會誤導），
`window.unityInstance` 也**不存在**。真正的 instance 存在頁面 inline script 的
**script scope**（`let`/`const` 宣告不掛上 `window`），所以只能用**裸識別字**取：

```js
// ❌ 取不到
window.unityInstance            // undefined
window.unityFramework           // null

// ✅ 取得到（Debug Server /js 在 page world 執行）
return typeof unityInstance === 'undefined' ? null : Object.keys(unityInstance);
// → ["Module", "SetFullscreen", "SendMessage", "Quit", "GetMemoryInfo"]
```

線索來自 `String(window.onUnityReady)`——它的函式本體是
`function onUnityReady(instance) { unityInstance = instance; … }`。

### 實測可觸及的面

| 面 | 狀態 | 備註 |
|----|------|------|
| `unityInstance.SendMessage(obj, method, value)` | ✅ 存在（`function`） | Unity 標準 JS→C# 橋；**需要知道 GameObject 名稱與 public 方法名**，雀魂並未公開，未驗證有無可用目標 |
| `unityInstance.Module`（Emscripten） | ✅ 565 個 key | |
| `Module.HEAP8/16/32/U8/U16/U32/F32/F64` | ✅ 全部在 | 可讀寫整塊線性記憶體 |
| `Module.ccall` / `cwrap` | ✅ `function` | 但可呼叫的匯出只有下面 17 個 |
| `Module._malloc` / `_free` | ✅ | |
| `Module.addFunction` / `getValue` / `setValue` | ❌ `undefined` | 未編入 |
| Il2Cpp / Mono 符號 | ❌ **零個** | `Object.keys(Module)` 過濾 `il2cpp|mono` = 空 |

**全部匯出函式（`_` 開頭，共 17 個）**——沒有任何遊戲邏輯函式：

```
_GetFakemodTimeInSeconds  _ReleaseKeys  _getMemInfo
_SendMessageFloat  _SendMessageString  _SendMessage  _SetFullscreen
_main  _htonl  _htons  _ntohs  _strlen
_malloc  _free  _emscripten_builtin_memalign  _setThrew  _saveSetjmp
```

WebGL 相關只有 `webglContextAttributes`、`matchWebGLToCanvasSize`（設定值，非繪圖介面）。

### 對「控制牌的顏色 / 高亮」的結論

| 做法 | 可行性 |
|------|--------|
| Unity 內直接改牌面材質色 | ❌ **做不到**。無 Il2Cpp 符號、無遊戲邏輯匯出，只有 `SendMessage` 一條窄門且目標名未知 |
| 掃 / 改 `HEAPU8` 找牌色狀態 | ⚠️ 理論可行但需逆向 wasm 佈局，且每次改版失效；**不建議** |
| Hook WebGL context 攔繪圖呼叫染色 | ⚠️ 需辨識哪個 draw call 是哪張牌，極脆弱 |
| **DOM 疊層**（在 canvas 上蓋半透明標記） | ✅ 最務實。`<canvas id="unity-canvas">` 是 `#unity-container` 的**唯一子元素**，`position: static`、無 z-index，疊一層絕對定位元素不會被覆蓋。**注意**：attribute 尺寸 2560×1440 但 CSS 實際 1007×566，座標需自行換算；牌的螢幕位置仍要靠校準，會隨版面漂移 |
| 協定層裝扮（`.lq.Lobby.useCommonView` / `saveCommonViews`） | ✅ 真實存在，但只能換**整套**牌背／牌桌皮膚（`ViewSlot{slot, item_id, type}`，需帳號已擁有該 item），**不能單張高亮** |

> 現況：`HighlightTools.swift` 的 6 個高亮工具在 Unity 下全數回報 unavailable，
> 推薦改由 Naki 原生 SwiftUI 面板呈現。上表的 DOM 疊層是**唯一**能回到遊戲畫面內的路徑，
> 但**尚未實作、尚未驗證**。

### 建議的驗證順序

1. 開一局，錄下完整 WebSocket frame（含方向、type、msgId、方法名）。
2. 從紀錄中抓出真實的 `inputOperation` REQUEST，逐位元組拆 payload。
3. 用 60000+ 的 msgId 重放**無害**的查詢類請求（如 fetch 類）先確認可行。
4. 才嘗試動作類請求，且**只在測試帳號上**（CLAUDE.md：NEVER 使用主帳號）。

---

**文檔版本**: 1.0
**建立日期**: 2026-07-31
**驗證狀態**: envelope 格式、訊息橋接、送出通道、msgId 配對 = 已驗證；遊戲／大廳 payload schema = 未驗證
