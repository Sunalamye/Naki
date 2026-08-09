# Naki 插件 API 契約（`apiVersion: 1`）

**資料日期**：2026-08-09
**狀態**：**契約規格，對應實作尚未存在。** 本文件描述 `apiVersion: 1` 的介面約定，供插件作者參照。Naki 這側的載入器、`naki-plugins.js`、`PluginRegistry` 都還沒寫（見 `plugin-system-design.md` §10 落地計畫）。標「未驗證」的行為在對應 Phase 動工前不得當保證使用。
**權威來源**：本文件從 `plugin-system-design.md` §6–§8 抽出，面向插件作者。兩份衝突時以設計文件為準；涉及實際行為時以**執行中的 Naki 與原始碼**為準（Naki 的文件漂移過，見 `CLAUDE.md`）。

---

## 0. 一分鐘上手

一個插件 ＝ 一個目錄，裡面至少兩個檔案：

```
com.example.myplugin/
  plugin.json      # manifest（必要）
  plugin.js        # 進入點（必要）
  LICENSE          # 你的授權（強烈建議；Naki 只顯示不解讀）
  README.md        # 選用
```

`plugin.js` 整個檔案就是一次 `register` 呼叫：

```js
window.__nakiPlugins.register({
  id: 'com.example.myplugin',      // 必須與 manifest 的 id 完全相同
  onReceive(ctx) {
    ctx.log(`收到 ${ctx.method} ${ctx.bytes.length} bytes`);
  },
});
```

放進 Naki 的插件目錄（macOS：`~/Library/Application Support/Naki/Plugins/<id>/`，非 sandbox），在**插件頁面**（工具列拼圖圖示）打開開關即可——**熱插拔，開關當下即時生效、免重新載入頁面**（2026-08-10 起）。頁面 reload 後也會照開關狀態自動還原。

---

## 1. Manifest（`plugin.json`）

```json
{
  "schemaVersion": 1,
  "apiVersion": 1,
  "id": "com.example.myplugin",
  "name": "我的插件",
  "version": "1.0.0",
  "entry": "plugin.js",
  "capabilities": ["observe"],
  "methods": [".lq.Lobby.fetchAccountInfo", ".lq.ActionPrototype"],
  "priority": 100,
  "settings": {
    "displayName": { "type": "string", "default": "Player", "description": "顯示名稱" }
  },
  "license": "MIT",
  "homepage": "https://example.com/…",
  "description": "只改本機顯示，不影響其他玩家看到的內容。"
}
```

| 欄位 | 必要 | 說明 |
|---|---|---|
| `schemaVersion` | ✅ | manifest 格式版本，目前固定 `1` |
| `apiVersion` | ✅ | Hook API 版本。**exact match：不是 `1` 就整個不載入**（原因 `apiVersionUnsupported`）。Naki 不做 semver range |
| `id` | ✅ | 反向網域命名。**必須與目錄名完全相同**，否則不載入 |
| `name` / `version` | ✅ | 顯示用；`version` 建議 semver |
| `entry` | ✅ | 進入點 JS 的相對路徑 |
| `capabilities` | ✅ | 見 §5。空陣列＝什麼都不能做 |
| `methods` | ✅ | **白名單**。只有列在這裡的 liqi method 會派發給你。空陣列＝這個插件不處理任何訊息（等於停用） |
| `priority` | 選用 | 多插件時的鏈上順序，升冪；預設值由 Naki 定，同值按 id 字典序 |
| `settings` | 選用 | 使用者可配置項的 schema，見 §6 |
| `license` | 選用（強烈建議） | Naki 只**顯示**，不代為授權、不驗證、不背書 |
| `homepage` / `description` | 選用 | 當**資料**渲染，永不當指令執行 |

**任何必填欄位缺漏或格式錯 ⇒ 整個插件不載入**，Naki UI 掛出可查原因（`notFound` / `unreadable` / `empty` / `manifestInvalid` / `apiVersionUnsupported`）。沒有部分載入。

> **無簽章、無雜湊驗證。** 這是刻意的：假的完整性檢查比沒有更糟。安裝插件＝信任作者（見 §8）。

---

## 2. `register`

```js
window.__nakiPlugins.register({
  id: 'com.example.myplugin',   // 必須與 manifest id 相同，否則拒絕註冊
  onReceive(ctx) { /* 選用 */ },
  onSend(ctx)    { /* 選用 */ },
  onSocketClose(info) { /* 選用：{ socketId, url } */ },
});
```

- **manifest 是權威**：你在 JS 裡宣稱什麼 capability／method 一律不算數，Naki 只認 manifest。
- id 對不上、未在啟用清單、或重複註冊 ⇒ 拒絕並記一行 log。
- 三個 hook 全部選用；沒有的就不會被呼叫。
- **回傳值一律被忽略**——所有作用都必須經 `ctx` 的方法，這樣「插件做了什麼」在 Naki 這側才可觀測。

---

## 3. `ctx`：你在 hook 裡拿到什麼

```
ctx = {
  direction : 'receive' | 'send',
  socketId  : number,              // 這條 WebSocket 連線的 id
  url       : string,              // 連線 URL（判斷 gateway / game-gateway）
  type      : 1 | 2 | 3,           // notify / request / response（envelope 第 0 byte）
  msgId     : number | null,       // notify 沒有 msgId
  method    : string | null,       // REQUEST 直接解出；RESPONSE 由 pending 對回（可能 null）
  bytes     : Uint8Array,          // 完整 envelope。可就地改（等長，見 §4）
  payload   : { from, to } | null, // envelope 內 field 2 的 byte range，不必自己再剝 wrapper
  isNaki    : boolean,             // msgId 落在 Naki／插件號段
  settings  : object,              // manifest 有宣告 settings 才存在，唯讀快照（見 §6）
  log(msg)  : void,                // 進 Naki 的 log，自動帶你的 id 前綴

  // 以下需要對應 capability，否則不存在或一律回 false：
  replace(newBytes) : boolean,     // 需要 rewriteReceive / rewriteSend
  drop()            : boolean,     // 需要 dropReceive / dropSend
  sendRequest(method, payloadBytes) : {ok, msgId} | {ok:false, reason}   // 需要 injectSend
}
```

### 你**看不到**什麼（如實）

- 非雀魂連線的訊息（`handleMessage` 開頭就 `if (!isMajsoul) return`）。
- Blob 分支與字串訊息不在範圍內。實務上雀魂送的是 ArrayBuffer／TypedArray，但這是限制不是保證。
- Naki 的 Swift 狀態（推薦、手牌、oplist）。v1 不開回程通道。
- `method` 對 RESPONSE **可能是 null**（pending 對不回來時）。白名單比對時 null 視為**不命中**——宣告了某 method 不保證每一筆該 method 的 RESPONSE 都到得了你手上。

---

## 4. 改寫封包：長度是硬約束

| 方向 | 等長改寫 | 改長度 | drop |
|---|---|---|---|
| **send** | 就地改 `bytes` | ✅ 可以（wrapper 換掉傳給底層的參數） | 需 `dropSend`，且預設禁止（遊戲會卡在「以為送出去了」） |
| **receive** | 就地改 `bytes`（唯一已驗證機制） | ⚠️ 需 Phase 4 機制，**未驗證** | 需 `dropReceive`，同上風險 |

**v1 的 receive 改寫是嚴格等長。** 理由：protobuf 的 string／bytes 前面是 varint 長度，改長度就要連動所有外層 nested message 的長度前綴，一路錯到底。等長覆寫不碰結構，最壞情況只是顯示怪字串，不會讓遊戲解析爆掉。

```js
onReceive(ctx) {
  if (ctx.method !== '.lq.Lobby.fetchAccountInfo') return;
  // 就地等長改寫：ctx.bytes 與遊戲共用同一份記憶體，改完遊戲與 Naki 都看到改後的
  const idx = findBytes(ctx.bytes, oldNameBytes, ctx.payload.from, ctx.payload.to);
  if (idx < 0) return;
  ctx.bytes.set(padToLength(newNameBytes, oldNameBytes.length), idx);  // 注意是「byte 數」等長，不是字數
}
```

整包替換走 `ctx.replace()`，receive 方向長度不等 ⇒ 回 `false` 且**不改任何 bytes**（fail-open，原樣通過）：

```js
const ok = ctx.replace(newBytes);
if (!ok) ctx.log('長度不等，放棄');
```

### ⚠️ 若你整包重新序列化：canonical proto3 的三種合法變形

**契約硬性條件**：你改寫後的 bytes 必須能被 Naki 既有 parser 正確重讀。要容忍 canonical proto3 re-encode 的三種變形：**欄位順序重排**、**預設值欄位省略**、**repeated 轉 packed**。不必 byte-identical，但必須語意可讀。

具體的坑（Naki 已踩過，issue #2 根因）：Liqi wrapper 是 `{1: method, 2: payload}`，RESPONSE 的 field 1 是**空字串**，官方伺服器照寫（`0a 00`），但 canonical encoder 會省略預設值欄位，於是重編過的 RESPONSE 只剩 field 2。因此：

1. `injectSend` / `rewriteSend` 產生的 REQUEST **必須自己寫出 field 1**（method 非空）。
2. 重編 NOTIFY 時別省欄位——Naki 對 NOTIFY 是位置取法，省了會**顯式失敗**（`notEnoughBlocks`）。
3. 「等長就地改」不會踩到這個；只有整包重編才會。

### 送 REQUEST 的四個協定事實（injectSend / rewriteSend）

1. **REQUEST envelope 無 XOR**：`[type=2][msgId 2B little-endian][protobuf: field1=method, field2=payload]`。你送 request **不需要** XOR，別去 XOR payload。
2. **XOR 只作用在 receive 側 notify 的 `.lq.ActionPrototype`**（而 `syncGame`／`enterGame` restore 不 XOR）——與你送 request 無關。只有將來 `rewriteReceive` 改 ActionPrototype 才需知道它是 XOR 過的，但那個 method 在禁改名單裡（§7）。
3. **gateway 分流是自動的**：`.lq.FastTest.*` 走對局連線（game-gateway），其餘走大廳（gateway）。你不用選，但送對局方法時若沒有對局連線，`sendRequest` 回 `{ok:false, reason:'no_game_gateway_connection'}`。
4. **`{ok:true}` 是「送出去了」不是「成功了」**：只代表 WebSocket 接受了 bytes。真正成功要看回應（`onInjectResponse`）或後續的權威 action。

---

## 5. Capability：三級

| 級別 | capability | 影響面 | 預設 |
|---|---|---|---|
| **L1 唯讀** | `observe` | 只看不改 | 啟用後即可用 |
| **L2 改本機顯示** | `rewriteReceive` | 改遊戲客戶端看到的東西。**不影響伺服器、不影響其他玩家** | 啟用後可用，受 §7 禁改名單限制 |
| **L3 改送出** | `rewriteSend` / `dropSend` / `injectSend` / `dropReceive` | **能替使用者送遊戲動作** | **完全不可用**，除非使用者另開總開關 `pluginsMayModifyOutbound`（預設 false）並通過一次性確認 |

L3 只能在使用者的**測試帳號**上用（Naki 的既有邊界）。

### msgId 號段（injectSend）

你注入的 request 用 **64000–65500** 號段（Naki 自送的是 60000–63999，遊戲自己的是低位遞增）。這是 Naki 自動分配的，你不用管。

### 收自己請求的回應（`onInjectResponse`）

你送出的請求，它的 RESPONSE `msgId` 也落在你的號段，Naki 會**只**把它回派給你這個發起的插件（其他插件收不到，維持信任隔離）：

```js
window.__nakiPlugins.register({
  id: 'com.example.myplugin',
  onReceive(ctx) {
    const r = ctx.sendRequest('.lq.Lobby.fetchAccountInfo', payloadBytes);
    if (!r.ok) { ctx.log(`送不出：${r.reason}`); return; }
    ctx.log(`已送出 msgId=${r.msgId}，等回應…`);
  },
  onInjectResponse(ctx) {
    // ctx.inResponseTo = 當初的 msgId；ctx.timedOut = true 表示逾時沒等到
    if (ctx.timedOut) { ctx.log(`msgId=${ctx.inResponseTo} 逾時`); return; }
    ctx.log(`收到 msgId=${ctx.inResponseTo} 的回應 ${ctx.bytes.length} bytes`);
  },
});
```

- RESPONSE 是**稍後**另一則訊息才到，所以走 callback（不是 `sendRequest` 當場回傳）。
- 逾時（預設約 10s）沒等到 ⇒ `onInjectResponse` 帶 `timedOut: true`，別無限等。
- **這是設計候選，對應實作尚未存在**（`plugin-system-design.md` §7.7b）。Phase 3 動工才落地；在那之前 `injectSend` 不保證可用。

---

## 6. 插件設定（`settings`）

manifest 宣告 schema，Naki 設定頁按 schema 自動渲染 UI，值存在 Naki 這側（不是頁面 `localStorage`）：

```json
"settings": {
  "displayName": { "type": "string",  "default": "Player", "description": "顯示名稱" },
  "opacity":     { "type": "number",  "default": 0.5,      "description": "遮罩不透明度" },
  "enabled":     { "type": "boolean", "default": true,     "description": "啟用效果" }
}
```

- 型別只有 `string` / `number` / `boolean`。不做巢狀、不做 enum。
- schema 無效（未知型別、`default` 與 `type` 不符）＝ manifest 無效 ⇒ **整個插件不載入**。
- 讀取：`ctx.settings.displayName`（唯讀快照，帶 default 與使用者覆寫值）。manifest 沒宣告 `settings` 時 `ctx.settings` 不存在。
- **改設定要重載頁面才生效**，與啟用開關同語意（不做熱更新）。
- **不要用頁面 `localStorage` 存設定**：那與遊戲同一個 storage 混居，Naki 看不見、UI 管不到。

---

## 7. 多插件、順序、失敗處理

- **順序**：`priority` 升冪，同值按 id 字典序。
- **鏈式**：每個插件看到**前一個改完**的 `bytes`。
- **drop 短路**：任一插件 `drop()` 成功 ⇒ 鏈**立即中止**，後續插件不再收到這則。
- **replace 換 buffer**：`replace()` 成功後，後續插件的 `ctx.bytes` 指向新 buffer。
- **isNaki 分流**：Naki／插件自送的封包（`isNaki===true`）走**另一條只含 observer 的鏈**——只有在 manifest 宣告 `observeNakiTraffic: true` 且**僅** `observe` 的插件收得到，永遠不給 rewrite。
- **錯誤隔離**：你的 hook throw ⇒ 這一則跳過你、記一行 log（同 id 同錯只記一次），**封包原樣通過**（fail-open）。其他插件不受影響。
- **自動停用**：同一插件連續失敗 N 次（建議 10）⇒ 本次頁面生命週期內自動停用，UI 顯示原因。

### 禁改名單（即使你有 `rewriteReceive`）

因為 Naki 的推薦與自動打牌讀的是**你改完的** bytes，以下 method 預設**不可改寫**（改了會污染 Naki 的牌局判斷，而且畫面上看不出來）：

- `.lq.ActionPrototype`（所有牌局動作）
- `.lq.FastTest.syncGame`（斷線重連狀態還原）
- `.lq.NotifyGameEndResult`（終局結算）
- `.lq.FastTest.authGame` 的 `players` / `robots` **以外**的欄位

要解除必須在 manifest 逐一列出，Naki UI 會以紅字警告使用者「這個插件會改動 Naki 用來判斷牌局的資料」。

### 你**不可以**自己呼叫 `sendToSwift`

那個 bridge type 契約是鎖死的（Naki 有機械測掃描），你送未知 type 會被 runtime 丟掉。要跟 Swift 說話一律經 `ctx.log()`（未來可能有 `ctx.notify()`），由 Naki 的 bundled 模組統一轉發。

---

## 8. 信任邊界：誠實聲明

**這是本 API 最重要的一段。**

你的插件與遊戲、與 Naki 的注入腳本在**同一個 JS realm**。這代表任何插件都能直接呼叫全域物件繞過所有 capability 檢查——即使不給你任何 L3 能力，一個決心繞過的插件只要呼叫 `window.__nakiWebSocket.sendRaw(...)` 就能送出任意封包。

**Naki 沒有辦法阻止這件事。** capability 宣告的價值是**可稽核性**（UI 寫明你宣稱要做什麼、log 記錄你實際改了什麼），不是防禦。

因此 Naki 的安裝 UI 會明講：

> 安裝插件 ＝ 信任插件作者。插件與遊戲跑在同一個環境裡，一個惡意插件可以用你的帳號送出任何遊戲動作、讀取頁面上的任何資料。Naki 沒有辦法阻止這件事。只裝你信任的插件。

作為插件作者，這對你的意義：**你的插件被安裝＝使用者把帳號託付給你。** 別辜負。也別在 log 或任何地方記錄封包內容——那可能含 session token。

### 插件實際能碰到什麼（完整頁面權限，實證）

**先分清兩件事：**

- **`capabilities` / `methods` 只管「Naki 主動遞給你的封包 hook」**——observe 讓你看 ctx、rewriteReceive 讓你改遊戲看到的封包。這是 Naki 這側能控制、能稽核的門。
- **頁面本身的一切，你無條件全有，不受 capability 限制。** 因為你的 JS 跟遊戲跑在同一個 realm——你人已經在房間裡了，房間裡的東西都拿得到，Naki 攔不住。

以下是**在 live 雀魂頁面實測**到的、任何插件（哪怕只給 `observe`）都能直接呼叫的東西：

| 你能碰到 | 全域入口 | 意味著 |
|---|---|---|
| **送任意 Liqi 封包** | `window.__nakiWebSocket.sendRaw(base64)` | 用使用者帳號送出任何遊戲動作——**繞過所有 capability**（這是 §8 的核心破口） |
| **發任意網路請求** | `fetch` / `XMLHttpRequest` / `new WebSocket` | 把頁面上任何資料（含下面的 token）外傳到任意伺服器 |
| **讀 session 憑證** | `localStorage`（實測 57 個鍵）、`document.cookie`、`indexedDB` | 讀到登入 token、帳號狀態——足以在別處冒用這個 session |
| **讀遊戲記憶體** | `window.__nakiHeap()`（Naki 已把 wasm heap 存這） | 讀 IL2CPP `System.String`（暱稱等）與其他 heap 內容 |
| **改／疊 DOM** | `document`、`document.body.appendChild` | 疊自己的 HTML/canvas 層（但見下「畫面」） |
| **碰 Naki 的 hook** | `window.__nakiHighlight`、`window.__nakiPlugins` | 存取 Naki 自己的 WebGL 高亮與插件 runtime |

換句話說：**安裝一個插件，等於把「這個帳號的整個 session ＋ 頁面上的一切」交給插件作者。** Naki 的 capability／禁改名單只是把「Naki 遞出去的那部分」寫清楚讓你稽核，擋不住決心亂來的插件。這就是為什麼上面反覆說「只裝你信任的作者」。

### 關於「自訂畫面顯示」——雀魂的現實

雀魂是 **Unity WebGL**：整個畫面（牌、名字、牌桌、按鈕）都畫在一塊 `unity-canvas`（WebGL，實測 2560×1440）上，**不在 DOM**（整頁 DOM 實測只有 ~30 個元素）。所以：

- **改 DOM 改不到遊戲畫的東西**——DOM 上沒有牌、沒有名字。CLAUDE.md 也寫死「不可用 DOM tile、Laya sprite 或座標點擊」。
- **疊 DOM overlay 有點擊衝突**：蓋在 canvas 上的 overlay 會攔截滑鼠事件，遊戲點不到；要 `pointer-events: none` 穿透，但那樣 overlay 自己的互動元件又點不了。這是為什麼 Naki **不**提供受控 overlay API——這個取捨留給插件作者自己權衡（你有完整 DOM 權限，要怎麼疊、怎麼處理 pointer-events 由你決定）。
- **真要改遊戲畫面內容**（角色／皮膚／名字）：走 `rewriteReceive` 改**封包**，讓遊戲自己重繪（Phase 2）——這才是「本機解鎖」的正路，不是改 DOM。
- **染色／遮罩遊戲畫的像素**：得 hook WebGL draw call（`window.__nakiHighlight` 是 Naki 的既有實作），但「認出哪個 draw 是什麼」極脆，自負風險。

### 封號風險

魔改有被雀魂偵測封號的風險。只在使用者自己的**測試帳號**上用，不要碰主帳號。

---

## 9. 怎麼把插件給使用者

| 方式 | 說明 |
|---|---|
| **手放檔案** | macOS：`~/Library/Application Support/Naki/Plugins/<id>/`；iOS：容器內 `Application Support/Plugins/`（經 document picker 匯入） |
| **貼 URL 一次性匯入** | 使用者在 Naki 設定頁貼你的 gist 或任意 HTTPS `plugin.json` URL。見下 |

### URL 匯入的格式要求（HTTPSource）

- URL **直接指向 `plugin.json`**。
- manifest 引用的檔案（`entry` 等）以 manifest URL 為基準的**相對路徑**，且必須**同源**——不能 manifest 在 A 站、程式碼在 B 站。
- 只允許 **HTTPS**。
- 尺寸上限：manifest 64KB、整包 5MB。

gist 來源（`gist.github.com/<user>/<id>`）Naki 會自動釘 revision，取到不可變的快照。

> Naki **不做**市集、推薦、自動更新。使用者按「檢查更新」＝重新走一次完整匯入流程（重抓、比對、重新確認）。Naki 不內建任何來源——你的插件能不能被找到，取決於你自己怎麼分發連結。

---

## 10. 版本與相容

- `apiVersion: 1` 是目前唯一版本。**exact match**——Naki 不承諾向前相容範圍。
- v2 出現時的相容矩陣屆時再定。現在把你的 manifest 釘 `apiVersion: 1`。
- 生命週期：插件狀態的生命週期＝**頁面生命週期**。頁面 reload 全清，沒有 deactivate 級的清理鉤子（也不需要）。唯一的連線層 hook 是 `onSocketClose({ socketId, url })`——多條 WebSocket 並存時，按 socketId 存狀態的插件用它知道哪條死了。

---

## 附錄：與設計文件的對應

| 本文件 | 設計文件 |
|---|---|
| §1 manifest | `plugin-system-design.md` §6.1 |
| §2 register | §7.1 |
| §3 ctx | §7.2、§7.3 |
| §4 改寫與長度 | §7.4 |
| §5 capability / msgId | §8.1、§7.6 |
| §6 settings | §7.10(a) |
| §7 多插件 / 禁改名單 | §7.7、§7.8、§8.2、§7.9 |
| §8 信任邊界 | §8.3、§8.4 |
| §9 安裝 / URL 匯入 | §6.2–§6.5 |
| §10 版本 / 生命週期 | §7.10(b)、§7.10(c) |
