# Naki 插件 API 契約（`apiVersion: 1`）

**資料日期**：2026-08-09；2026-10-13 核對實作現況
**狀態**：**對應實作已存在**（`PluginRegistry`、`naki-plugins.js`、熱插拔都已落地）。本文件描述 `apiVersion: 1` 的介面約定，供插件作者參照。**規格與實作有差**：下列項目只在文件裡，目前**未實作**（manifest 宣告了也沒有作用，呼叫也不存在）——`rewriteSend`、`dropSend`、`onSocketClose`。`dropReceive`、`ctx.drop()` 與長度不等的 receive `replace` 見文末「v2 Phase 4」，已通過 live 驗收（`docs/archive/plan/plugin-v2-phase4.md` §9.1）。其餘 capability 已實作：`observe`、`rewriteReceive`（`ctx.replace`，等長就地改寫）、`injectSend`（`ctx.sendRequest`，受 L3 總開關把關）；`injectReceive`、`respondLocally` 與 `onConnectionDegraded` 見文末「v2 Phase 4」，只有單測，未 live 驗證；hook 已實作：`onReceive`、`onSend`、`onRecommendations`、`onInjectResponse`、`onConnectionDegraded`、`onDisable`。標「未驗證」的行為不得當保證使用。
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
| `id` | ✅ | 反向網域命名。**必須與目錄名完全相同**，否則不載入。字元集僅限 `[A-Za-z0-9._-]`，不得以 `.` 開頭、不得含 `..`，不合整個不載入 |
| `name` / `version` | ✅ | 顯示用；`version` 建議 semver |
| `entry` | ✅ | 進入點 JS 的檔名：單一 `.js` 檔名，字元集同 `id`（不接受子目錄） |
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
  onSocketClose(info) { /* 規格保留，目前未實作（JS 端沒有呼叫端）：{ socketId, url } */ },
});
```

- **manifest 是權威**：你在 JS 裡宣稱什麼 capability／method 一律不算數，Naki 只認 manifest。
- id 對不上、未在啟用清單、或重複註冊 ⇒ 拒絕並記一行 log。
- hook 全部選用；沒有的就不會被呼叫。已實作的有 `onReceive`、`onSend`、`onRecommendations`、`onInjectResponse`（§5）、`onDisable`（熱停用或自動移除時呼叫，用來清理）。
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
  bytes     : Uint8Array,          // 完整 envelope。receive 可就地改（等長，見 §4）；send 是宿主給的副本，見下方「送出守衛」
  payload   : { from, to } | null, // envelope 內 field 2 的 byte range，不必自己再剝 wrapper
  isNaki    : boolean,             // 這筆是 Naki 或插件自己送的：當前 (socketId, msgId) 在 sendRaw 送出登記表內（REQUEST 只認尚未收到 RESPONSE 的），或是你注入請求的回應（見 §5）
  settings  : object,              // manifest 有宣告 settings 才存在，唯讀快照（見 §6）
  log(msg)  : void,                // 進 Naki 的 log，自動帶你的 id 前綴
  taint()   : boolean,             // 把自己標成已污染（僅宣告 sendGuard 者回 true，見下方「送出守衛」）；不可解除
  isTainted(): boolean,            // 自己是否已污染

  // 以下需要對應 capability，否則不存在或一律回 false：
  replace(newBytes) : boolean,     // 需要 rewriteReceive（rewriteSend 未實作）；isNaki 流量不提供
  drop()            : boolean,     // 【規格保留，目前未實作】需要 dropReceive / dropSend
  sendRequest(method, payloadBytes) : {ok, msgId} | {ok:false, reason}   // 需要 injectSend
}
```

### 你**看不到**什麼（如實）

- 非雀魂連線的訊息（`handleMessage` 開頭就 `if (!isMajsoul) return`）。
- Blob 分支與字串訊息不在範圍內。實務上雀魂送的是 ArrayBuffer／TypedArray，但這是限制不是保證。
- `method` 對 RESPONSE **可能是 null**（pending 對不回來時）。白名單比對時 null 視為**不命中**——宣告了某 method 不保證每一筆該 method 的 RESPONSE 都到得了你手上。

### 你**讀得到**的 Naki 狀態（唯讀，2026-08-10 起）

原本 §7.3 說「拿不到 Naki 的 Swift 狀態」——現在開了**唯讀**回程通道與現成的顯示 API，讓插件能接管「牌改色」「暱稱隱藏」這類顯示功能：

| 全域（唯讀讀取） | 內容 | 用途 |
|---|---|---|
| `window.__nakiRecommendations` | AI 推薦快照陣列，每項 `{tile, label, probability, actionType, detail}`（`tile` 是 MJAI 字串如 `"5m"`，非打牌動作為 null）。每次 Naki 同步高亮時更新 | 讀「該高亮哪張牌」「機率多少」——**能讀不能改** |

現成的顯示 API（插件可直接呼叫，Naki 內建的 WebGL 實作）：

| API | 作用 |
|---|---|
| `window.__nakiHighlight.set(...)` / `.clear()` | 牌面高亮／改色（Naki 內建 highlighter 用的同一支） |
| `window.__nakiHighlight.setNameMask(true/false)` | 暱稱遮罩（渲染層即時遮名字） |

**做「牌改色」插件**：讀 `window.__nakiRecommendations` 拿到推薦 → 自己呼叫 `window.__nakiHighlight.set(...)`。
**做「暱稱隱藏」插件**：直接 `window.__nakiHighlight.setNameMask(true)`（不需要推薦）。

⚠️ 這是唯讀通道，插件**改不了** Naki 的推薦或牌局狀態（只能讀）。想改遊戲畫面內容仍走 `rewriteReceive` 改封包。內建自動染色已於 2026-08-10 移除（`c0b7564`）、移交插件，所以不會與插件打架；AI 推薦模式切 `.off` 時 Naki 會推空推薦並 `clear()` 高亮，插件讀到的 `__nakiRecommendations` 也是空的。

---

## 4. 改寫封包：長度是硬約束

| 方向 | 等長改寫 | 改長度 | drop |
|---|---|---|---|
| **send** | 【規格保留，目前未實作】就地改 `bytes` | 【未實作】 | 【未實作】需 `dropSend`，且預設禁止（遊戲會卡在「以為送出去了」） |
| **receive** | 就地改 `bytes`（唯一已實作、已驗證機制） | ⚠️ 需 Phase 4 機制，**未驗證、未實作** | 【未實作】需 `dropReceive`，同上風險 |

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

整包替換走 `ctx.replace()`，只收 TypedArray，先複製再以實際長度判斷（自有 `length` 不算數）。等長替換後 envelope 結構不完整（欄位長度越界等）也回 `false` 並還原。receive 方向長度不等 ⇒ 回 `false` 且**不改任何 bytes**（fail-open，原樣通過）。替換後 Naki 會**重新解析** envelope：type／msgId／method 變了或落進禁改名單 ⇒ 還原原 bytes、計一次 `replace` 失敗並回 `false`。isNaki 流量不提供 `replace`：

```js
const ok = ctx.replace(newBytes);
if (!ok) ctx.log('長度不等，放棄');
```

### ⚠️ 若你整包重新序列化：canonical proto3 的三種合法變形

**契約硬性條件**：你改寫後的 bytes 必須能被 Naki 既有 parser 正確重讀。要容忍 canonical proto3 re-encode 的三種變形：**欄位順序重排**、**預設值欄位省略**、**repeated 轉 packed**。不必 byte-identical，但必須語意可讀。

具體的坑（Naki 已踩過，issue #2 根因）：Liqi wrapper 是 `{1: method, 2: payload}`，RESPONSE 的 field 1 是**空字串**，官方伺服器照寫（`0a 00`），但 canonical encoder 會省略預設值欄位，於是重編過的 RESPONSE 只剩 field 2。因此：

1. `injectSend` / `rewriteSend` 產生的 REQUEST **必須自己寫出 field 1**（method 非空）。
2. 重編 NOTIFY／REQUEST 時 **field 1（method）不能省**——Naki 三種 envelope 都按欄位號取（`LiqiEnvelope.decode`），缺 method 會**顯式失敗**（`notEnoughBlocks`）；field 2（payload）缺席則視為空。
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
| **L3 改送出** | `injectSend`、`injectReceive`、`respondLocally`（已實作，後兩者見文末）；`rewriteSend` / `dropSend` / `dropReceive`（規格保留，**未實作**） | **能替使用者送遊戲動作** | **完全不可用**，除非使用者另開總開關 `pluginsMayModifyOutbound`（預設 false）並通過一次性確認 |

L3 只能在使用者的**測試帳號**上用（Naki 的既有邊界）。

### msgId 號段（injectSend）

你注入的 request 用 **64000–65500** 號段（Naki 自送的是 60000–63999，遊戲自己的是低位遞增，跑久了也可能進入 60000+）。Swift 端（`ObservedMatchSids`、`LiqiResponseStore`）判斷「是不是 Naki 自己送的」靠配發器登記；Swift 沒有插件登記，`ObservedMatchSids` 仍把插件號段整段當成 Naki 側。

配發時 Naki 會跳過三種號碼（pair-source）：
- 你或其他插件注入、還沒收到 RESPONSE 的號碼。
- 任一連線上遊戲還沒收到 RESPONSE 的請求號碼。Naki 不論頁面上有沒有插件都會記錄遊戲送出。只記確定外送的請求，被守衛擋下的不算。「遊戲」指不經 `sendRaw` 送出的請求，與 `ctx.isNaki` 的判斷無關。
- 正在派發的遊戲請求號碼。你在 `onSend` 裡呼叫 `sendRequest` 時，觸發這次 `onSend` 的遊戲請求還沒外送，它的號碼與之後 256 個也會跳過。
- 每條連線上遊戲最後一個號碼之後的 256 個號碼。遊戲被守衛擋下或以 `respondLocally` 本地回應的請求不上 wire、不算未答，但它的號碼算遊戲已用過，最後一個號碼照樣前進。「最後」依遊戲進入送出的順序：hook 內重入的較新送出先結案，外層較早的請求之後才本地結案，最後號碼不會倒退。
- 本地回應還沒交給遊戲的號碼。遊戲在 `ws.send` 返回後的下一個 task 才收到本地回應，在那之前這個號碼不配發；交付後釋放，排不進交付（排程失敗）時立即釋放，連線關閉時清掉。這些號碼不算未答，但同一個 task 裡大量本地回應占住號段時，注入可能暫時回 `msgid_busy`，交付後恢復。每條連線待交付的 `respondLocally` 上限 256 筆（見 `local_busy`）；守衛擋下是強制結局，不受上限限制，也不淘汰任何遊戲在等的號碼。`diagnostics().localPending` 是目前保留的筆數。

所以你拿到的 msgId 不一定連續。下列情況 `sendRequest` 回 `{ok:false, reason:'msgid_busy'}`：
- 某條連線上遊戲確定外送、未答的請求超過 256 筆。Naki 無法再追蹤，這條連線關閉之前一律拒發，即使之後全部答覆也一樣。最後送出時才被擋下的那一筆不會造成這個狀態；但它被擋下前若同一條連線又有請求送出或回應抵達，Naki 保守維持這個狀態。
- 可用號碼被占滿（連線多、各自都有大量未答時可能發生）。
- 任一連線上遊戲曾以 Blob 送出請求。Blob 要非同步展開才知道號碼，Naki 不追蹤它的號碼，而是把那條連線標成不可信，直到連線關閉。現行客戶端以 TypedArray 送出，實測沒有遇過這個情況。已關閉連線上的送出不算。

**`ctx.isNaki` 的語意（D9 起登記制；D22 起加上連線）**：不是號段猜測。遊戲自己的 msgId 計數器跨連線遞增，跑久了會進 60000–65500。判斷規則如下：
- `sendRaw`（Naki 自送與你的 `sendRequest` 都走它）每送一筆，就把 **(socketId, msgId)** 記進登記表。表的**上限 256 筆，所有連線共用**，FIFO 淘汰。同一配對重送會刷新成最新，並重新變回「還沒收到 RESPONSE」，但不會移除配對；只有淘汰才會移除。
- REQUEST：配對在表內、且這個配對**還沒收到 RESPONSE** 才算 Naki。Naki 的 RESPONSE（ArrayBuffer、TypedArray 或 Blob 都算）到了以後，同一連線上同號的 REQUEST 是遊戲自己的。只有收到那條連線上的網路 RESPONSE 才算：別條連線的同號不算，本地錯誤回應不算，在這筆送出之前就已抵達、展開較慢的 Blob 也不算。
- RESPONSE：配對在表內就算 Naki。你注入請求的回應只要注入登記還在，即使送出登記已被淘汰，也算 Naki。
- 插件號段 64000–65500 本身**不再**算 Naki。別條連線上的同號也不算。
- 頁面 API `window.__nakiWebSocket.isNakiSent(msgId, socketId?, pendingOnly?)`：
  - 省略 `socketId`（或傳 `null`）時查任一連線。
  - 省略 `pendingOnly` 等同 `false`，此時已收到 RESPONSE 的配對也算。
  - 例：`isNakiSent(60003, null, true)` 是問「任一連線上有沒有還沒收到 RESPONSE 的 60003」。
  - 它只查 `sendRaw` 登記表，**不含**注入登記，所以不等於 `ctx.isNaki`。例如你注入請求的 `sendRaw` 登記被淘汰後，`isNakiSent(id, socketId)` 是 `false`，同一個回應的 `ctx.isNaki` 仍是 `true`。

**D22 對既有插件的可見差異**：遊戲在 64000–65500 的流量原本被當成 Naki，只有宣告 `observeNakiTraffic` 的 observer 看得到。現在它走一般鏈，可被 observe／rewrite。審查時以實際插件重現了兩例：
- 遊戲 `authGame#64003` 的回應現在會觸發 name-hider 關閉遮罩。
- 同一個回應現在會讓 gist-logger 新增一筆紀錄。

另一個差異：Naki 在某條連線用過的 60000–63999 號碼，原本在所有連線上都被當成 Naki 而對一般鏈隱藏；現在其他連線上遊戲的同號流量走一般鏈，插件看得到。

tile-highlighter 的 ActionPrototype 與推薦更新路徑不受影響。

**仍會誤認的情況**（都只發生在遊戲用到同一連線上的同一個 msgId 時）：
- **REQUEST 在途碰撞**：Naki 的請求還沒收到 RESPONSE 時，遊戲在同一連線送出同號請求，這筆仍被當成 Naki。
- **REQUEST 本地結案例外**：Naki 或你注入的守衛方法請求被擋下、改由本地錯誤回應時，伺服器沒有收到它，這個配對會一直停在「還沒收到 RESPONSE」，直到登記被淘汰；重送也只是重新進入待答。期間遊戲在同一連線送出同號請求，仍被當成 Naki。不把本地錯誤當成已答，是因為擋下的也可能是被誤認的遊戲請求，而真正的 Naki 請求仍在路上。
- **RESPONSE 持續誤認**：Naki 往返結束後，遊戲同號請求會恢復成遊戲的，但它的 RESPONSE 仍算 Naki，直到登記被淘汰；重送會延續這個登記，不會解除。一般 observer 收不到這則回應，也沒有 `replace`。
- **注入錯認領**：遊戲在你注入的請求還沒收到 RESPONSE 時，在同一連線送出同號請求，同號的第一則 RESPONSE 會被當成你的回應交給 `onInjectResponse`（方法是你注入時的方法），並消耗注入登記。配發已避開遊戲接下來的 256 個號碼，但這只是啟發式：遊戲計數器的步進、繞回與重連行為，以及注入往返期間遊戲送出的筆數，都沒有 live 證據。同號的下一則回應依遊戲那筆的配對對回遊戲方法，但兩則誰是誰只能靠到達順序，所以這一則一律當成 Naki 流量：只交給宣告 `observeNakiTraffic` 的 observer，沒有 `replace`，即使你注入請求的 `sendRaw` 登記已被淘汰。頁面上沒有插件時這則回應照樣消耗這個標記。同時存在的這類號碼超過 256 個時，Naki 不忘記任何一個：有這類號碼的連線整條改成只觀察，直到連線關閉。該連線上之後的 RESPONSE 都只交給 Naki observer、沒有 `replace`，只有一個例外：你注入的請求的回應仍先回派給你的 `onInjectResponse`，不受這個分流影響。整條只觀察的狀態本身不會被回應消耗，但回應照常消耗它對到的注入登記與遊戲配對。
- **遊戲同號請求被擋**：上述情況下，遊戲那筆若是守衛方法，會被當成 Naki 流量擋下（`naki_traffic`），本地錯誤回應交給遊戲，不會交給你的 `onInjectResponse`；你的注入回應之後照常送達。
- 繞過 `sendRaw` 直接 `ws.send` 的送出會被當成遊戲自己的。

這些 msgId 都是 Naki 自動分配的，你不用管。

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
    if (ctx.error === 'response_lost') { ctx.log(`msgId=${ctx.inResponseTo} 回應無法交付（${ctx.reason}），結果未知`); return; }
    ctx.log(`收到 msgId=${ctx.inResponseTo} 的回應 ${ctx.bytes.length} bytes`);
  },
});
```

- RESPONSE 是**稍後**另一則訊息才到，所以走 callback（不是 `sendRequest` 當場回傳）。
- `ctx.error === 'response_lost'`：Naki 無法再把回應交給你，以這個錯誤結案（`bytes` 為空），`ctx.reason` 說明原因。兩種情況下請求都可能已被伺服器處理，結果未知：
  - `ctx.reason === 'receive_untrusted'`：那條連線有接收 Blob 讀不到，或接收佇列超過 256 則。Naki 無法確定哪則回應是你的，立即結案；送出期間才發生的，在下一個 microtask 結案。
  - `ctx.reason === 'evicted'`：同時未答的注入超過 256 筆，最舊的一筆被淘汰，在下一個 microtask 結案。它之後才到的回應不會再交給你。
- 規格寫的是逾時（約 10s）沒等到 ⇒ `onInjectResponse` 帶 `timedOut: true`；**目前未實作**（`naki-plugins.js` 只有 `timedOut = false`），所以自己要設計等待上限，別無限等。
- 這條路徑已實作（`naki-plugins.js` 的 `sendRequest` 與回應路由，設計見 `plugin-system-design.md` §7.7b），但 L3 總開關預設關閉，關閉時 `sendRequest` 回 `{ok:false, reason:'outbound_disabled'}`。回應逾時通知**未實作**：`timedOut` 目前恆為 `false`，沒等到回應就沒有任何 callback。

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
- **drop 短路**（規格保留，`drop` 目前未實作）：任一插件 `drop()` 成功 ⇒ 鏈**立即中止**，後續插件不再收到這則。
- **replace 換 buffer**：`replace()` 成功後，後續插件的 `ctx.bytes` 指向新 buffer。
- **isNaki 分流**：Naki／插件自送的封包（`isNaki===true`）走**另一條只含 observer 的鏈**——只有在 manifest 宣告 `observeNakiTraffic: true` 且**僅** `observe` 的插件收得到，永遠不給 rewrite。
  - **溢出邊界**：`isNaki` 依賴上述 256 筆登記表，所有連線共用。若 Naki 送出一筆後，又經 `sendRaw` 送了 ≥256 筆，那筆的回應才到，登記已被淘汰，該回應的 `isNaki` 會是 `false`，等於違反「isNaki 流量永不給 rewrite」。這需要回應延遲到數百次送出之後，實務上不可達（判定為推測，未實測）。你注入請求的回應不受這個邊界影響，它以注入登記判斷（另有 256 筆上限，只計插件注入）。
- **錯誤隔離**：你的 hook throw ⇒ 這一則跳過你、記一行 log（同 id 同錯只記一次），**封包原樣通過**（fail-open）。其他插件不受影響。
- **自動停用**：失敗計數**按 hook 分開**（`onReceive`／`onSend`／`onRecommendations`／`onInjectResponse`／`onConnectionDegraded`／`replace` 各算各的），某個 hook 連續失敗 10 次 ⇒ 該插件在本次頁面生命週期內整個停用；該 hook 成功一次（`replace` 以一次成功改寫算）就把它自己的計數歸零。
- **注入範圍**：插件 script 只注入 main frame，不跑進第三方 iframe。

### 禁改名單（即使你有 `rewriteReceive`）

因為 Naki 的推薦與自動打牌讀的是**你改完的** bytes，以下 method 預設**不可改寫**（改了會污染 Naki 的牌局判斷，而且畫面上看不出來）：

- `.lq.ActionPrototype`（所有牌局動作）
- `.lq.FastTest.syncGame`（斷線重連狀態還原）
- `.lq.NotifyGameEndResult`（終局結算）
- `.lq.FastTest.authGame` 的 `players` / `robots` **以外**的欄位

要解除必須在 manifest 逐一列出，Naki UI 會以紅字警告使用者「這個插件會改動 Naki 用來判斷牌局的資料」。

### 載入來源與早期 log：`__nakiPlugins.loadSource` / `devLog`

- `window.__nakiPlugins.loadSource`：唯讀屬性。只有在**宿主注入階段**（Naki 以 document-start user script 串接所有啟用插件源碼，頁面載入時一起執行）載入的插件，於其頂層程式碼執行期間讀到 `'document-start'`；其餘任何時刻（熱啟用、停用後重新註冊、`register` 之後的 hook 內）一律 `'hot'`。要判斷自己的載入來源，請在頂層同步讀取並自行保存。
- 這是宿主標記，不是頁面側推論：Naki 在注入 script 前後各呼叫一次內部的開始／結束標記，每頁只成功一輪，熱啟用路徑不經過它。
- 權限邊界同 §8：標記與其他 `__nakiPlugins` 成員在同一 realm，惡意插件仍能繞過。這個值用於「防誤用」（例如測試專用插件拒絕在不可信的載入來源執行），不是安全邊界。
- `window.__nakiPlugins.devLog(pluginId, line)`：任何時候可呼叫，寫進宿主 log，管道與前綴格式同 `ctx.log`。只收已註冊，或持有宿主下發 grant 的 `pluginId`（含載入中、熱啟用 `register` 之前）；其他回 `false` 並丟棄。每插件每頁最多 500 行，超過回 `false`。回 `true` 代表 `sendToSwift` 確認已交給宿主；bridge 缺席、拋錯、`sendToSwift` 回 false，或 `line` 的 `toString` 拋例外，一律回 `false`，且不佔 500 行配額。
- `window.__nakiPlugins.devLogSeal(pluginId, meta)`：為插件本頁的 `devLog` 紀錄加上宿主見證的尾封。條件同 `devLog`；`meta` 必須是純物件（原型為 `null`，或原型的原型為 `null`；陣列、Map、Date、class 實例一律拒絕。Proxy 謊報原型、`toJSON` 改變序列化型別屬 §8 信任邊界，不防），JSON 序列化後不得超過 512 bytes（UTF-8），否則回 `false`。成功時以與 `devLog` 同一管道送出一行，內容由宿主組成 `{"kind":"seal","plugin":<id>,"count":<本頁已成功交付的 devLog 行數>,"meta":<meta>}`，`count` 無法由插件指定；落檔前綴同 `ctx.log`（`[Plugin] <id>：<json>`）。回 `true` 才算封存。封存後該插件本頁的 `devLog` 與 `devLogSeal` 一律回 `false` 且不送出；seal 不佔 500 行配額；`beginBootstrap` 成功時重設封存與計數（每頁一輪）。序列化期間（meta 的 getter／`toJSON`）重入呼叫 `devLogSeal` 時，先完成者生效，後者回 `false`，只送一條 seal 行。封存只防「頁尾被截斷或事後補寫」的誤用，同 §8 不防惡意同 realm 程式。
- 內部標記的繞過（同屬 §8 信任邊界內的刻意繞過）：頁面沒有啟用插件、或注入 script 語法錯時，開始標記從未被呼叫，之後任何同 realm 程式呼叫 `beginBootstrap()` 都能取得 `'document-start'`；插件跳出 try 使結束標記不執行同理。`loadSource` 因此不是安全證明。
- 兩者都不屬於 hook 契約的一部分，僅供載入期與早期診斷使用。

### 授權防誤用，不防惡意插件

`capabilities`、`methods` 與 L3 總開關在 JS 這側的實體，是頁面 realm 裡**可寫的全域變數**：授權表 `window.__nakiPluginGrants`（Swift 注入，熱插拔時 `setGrant` 寫入）與總開關 `window.__nakiPluginsMayModifyOutbound`。同一個 realm 的任何插件都能直接改寫它們，或乾脆呼叫 `window.__nakiWebSocket.sendRaw`。所以這套機制的定位是**防誤用**（manifest 與 UI 把「這個插件宣稱要做什麼」寫清楚、讓正常插件各守本分、讓 log 可稽核），**不是**防惡意插件的安全邊界。插件由使用者自行安裝，信任邊界本來就包含插件（2026-10-12 用戶裁決 U4：只改文件，不加防護）。

### 未記載的內部函式

`window.__nakiHideNames`（`naki-websocket.js`，authGame 暱稱等長覆寫）是**未記載於本 API 的內部函式**：Swift 與 bundled 插件都沒有呼叫端，只有 `scripts/plugin-regression.cjs` 測它。不屬於 `apiVersion: 1` 契約，可能不經通知就改動或移除；要隱藏暱稱請用本文記載的 `window.__nakiHighlight.setNameMask`。

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
| **手放檔案** | macOS：`~/Library/Application Support/Naki/Plugins/<id>/`；iOS：App 容器內 `Library/Application Support/Naki/Plugins/<id>/`（與 macOS 同一段程式碼，目錄名同為 `Naki/Plugins`）。iOS **沒有** document picker 匯入，使用者端只能走下面的 URL 匯入 |
| **貼 URL 一次性匯入** | 使用者在 Naki 設定頁貼你的 gist 或任意 HTTPS `plugin.json` URL。見下 |

### URL 匯入的格式要求（HTTPSource）

- URL **直接指向 `plugin.json`**。
- manifest 引用的檔案（`entry` 等）以 manifest URL 為基準的**相對路徑**，且必須**同源**——不能 manifest 在 A 站、程式碼在 B 站。
- 只允許 **HTTPS**。
- 尺寸上限：manifest 64KB、整包 5MB。

gist 來源（`gist.github.com/<user>/<id>`）Naki 會自動釘 revision，取到不可變的快照。

> Naki **不做**市集、推薦、自動更新。使用者按「檢查更新」＝重新走一次完整匯入流程（重抓、比對內容 sha、有差異時列為待確認更新）；**使用者確認之前不會落地**。Naki 不內建任何來源——你的插件能不能被找到，取決於你自己怎麼分發連結。

---

## 10. 版本與相容

- `apiVersion: 1` 是目前唯一版本。**exact match**——Naki 不承諾向前相容範圍。
- v2 出現時的相容矩陣屆時再定。現在把你的 manifest 釘 `apiVersion: 1`。
- 生命週期：插件狀態的生命週期＝**頁面生命週期**。頁面 reload 全清，清理鉤子是 `onDisable(ctx)`（熱停用或自動移除時呼叫）。規格另有連線層 hook `onSocketClose({ socketId, url })`（讓按 socketId 存狀態的插件知道哪條連線死了），但**目前未實作**，JS 端沒有呼叫端。

---

## v2 Phase 4（草案，未定案）

> **本段為 v2 Phase 4 契約**：設計見 `docs/archive/plan/plugin-v2-phase4.md`；live 驗收 L1–L7 於 2026-10-17 全綠（該文件 §9.1，含 L2 限制：只驗語意不變的變長重派，改顯示值的畫面效果未驗）。上面各節仍是現行契約。

- **長度不等的 `ctx.replace(bytes)` 要明確選用**：manifest `capabilities` 同時宣告 `rewriteReceive` 與 `reshapeReceive`，才會整包替換。只宣告 `reshapeReceive` 時 manifest 無效。條件：
  - 原事件的 data 是 ArrayBuffer。Blob 不提供。
  - method 不在下方禁改名單。不成立時回 `false`。
  - 新 bytes 每個欄位在界內；type、msgId 不變；NOTIFY 的 method 不變且非空；RESPONSE 不得帶非空 method，field 1 可省。不成立時回 `false`，計一次 `replace` 失敗。
  - 等長仍是就地改，與 v1 相同。
  - Swift 的 manifest 驗證是選用條件，不是隔離邊界。grant 與 L3 開關跟插件在同一個 realm，可被直接改寫，沿用 §8 的信任模型。
- **遷移**：沒有宣告 `reshapeReceive` 的既有插件，長度不等的 `replace` 仍回 `false`，行為與 v1 相同，不必改。要用新語意的插件加上 `reshapeReceive`，並把「回 `false` 時的替代處理」保留給禁改名單與不合規的情況。
- **`ctx.drop()`**（`dropReceive`，L3）：只有 NOTIFY 有。每次呼叫檢查總開關，關著回 `false`。成功後遊戲與 Naki 都收不到這則，後續插件也收不到。
- **禁改名單**（變長 `replace` 與 `drop` 共用，`rewriteAllow` 解不開，以全名比對）：來源是 Naki 的 Swift 端會據以改牌局、帳號或匹配狀態的訊息。
  - `.lq.ActionPrototype`、`.lq.NotifyGameEndResult`、`.lq.NotifyGameTerminate`、`.lq.NotifyGameBroadcast`
  - `.lq.Lobby.login`、`.lq.Lobby.oauth2Login`、`.lq.Lobby.emailLogin`、`.lq.Lobby.oauth2Auth`、`.lq.Lobby.startUnifiedMatch`
  - 全部 `.lq.FastTest.*`、全部 `.lq.Route.*`
  - method 對不回的 RESPONSE
  - `isNaki` 流量照舊沒有 `replace`、`drop`。
- **hook 拋錯**：鏈回到該 hook 進入前的狀態。它這次的整包替換、就地改寫與 `drop` 都撤回；先前插件成功的改寫保留並照常交付。只有它一個插件時，等於原事件照常交付。
- **交付故障與頁面鎖死**：改寫後的交付若在攔下原事件之後失敗（Swift 拒收、派發拋錯、派發期間有 listener 拋錯、原事件攔不住），本頁面之後不再提供變長 `replace` 與 `drop`，頁面重載才恢復，停用插件也不會解除。鎖定只停這兩個原語，不重同步、不停遊戲與自動操作。Swift 拒收時遊戲仍收到改寫後的版本，這是已記錄的降級交付。log 出現插件 id `naki` 的一行，列出故障種類、method、msgId 與候選改寫者。候選不等於元兇。
- **送出守衛**：宣告 `sendGuard` 的插件在大廳連線上變長改寫或 `drop` 一則，與等長改寫一樣會污染到頁面重載。
  - **`ctx.taint()`**：`onReceive`、`onSend`、`onInjectResponse` 的 ctx 有；`onRecommendations`、`onDisable` 沒有。把呼叫的插件自己標成已污染，不必等大廳改寫（對局連線上的長改寫不會自動污染，應先呼叫）。只能污染自己，沒有宣告 `sendGuard` 的插件回 `false` 且不做事，否則回 `true`。污染後的行為與大廳改寫造成的污染完全相同。重複呼叫沒有副作用，也不重發事件。
  - **`ctx.isTainted()`**：回傳自己是否已污染。曾污染的插件重新註冊後仍為 `true`，即使新的 grant 不再宣告 `sendGuard`。
  - **污染不可解除，頁面重載才清**：停用、熱重載、自動停用、`setGrant` 都不會解除。
  - **放行只對當下有效**：守衛者在 `onSend` 正常返回算放行，但只對「放行時的那次註冊」與「放行前的污染狀態」有效。同一筆送出還沒結束時，守衛者被污染（在任何大廳連線上、包括後面插件同步觸發的 receive），或同 id 停用後重新註冊，這次放行就作廢，這一筆擋下並改回本地錯誤（`not_on_chain`）。下一筆由新的狀態、新的 `onSend` 重新判定。已污染的插件重複呼叫 `ctx.taint()`、守衛方法沒變時，不影響放行。
  - **守衛者中途退出**：這一筆送出期間，未污染的守衛者全部停用（自己停用或被停用）而且沒有拋錯、沒有回傳 thenable、`respondLocally` 沒有被拒，這一筆就不再受守衛，送出遊戲的原請求，插件的改動一律不送，守衛紀錄是 `sent`／`guard_left`；已有 `respondLocally` 提案時改為本地成功（`local_ok`）。還有其他守衛者時，由其餘守衛者照常判定；例外是退出前已經拋錯或回傳 thenable 的守衛者，它對這一筆的否決仍有效（N2），即使其餘守衛者放行，這一筆仍擋下。這一筆的回應配對跟著實際送出的原請求，`replace` 換過的 method 不算。
  - **失敗歸責**：`onSend` 的成功要等這一筆的鏈尾判定通過才記，鏈尾違規照樣累計，連續 10 次自動停用。歸責與停用綁定 `register` 當下的那次註冊；之後再改自己 `spec.id` 不會轉嫁給別的插件。插件停用或同 id 重新註冊之後才記到的成功、失敗（含鏈尾判決、晚到的 thenable 結果，以及錯誤訊息 getter 執行期間換掉的情況）一律丟棄，不算在新的註冊上。`onDisable` 執行中若以同 id 重新註冊，停用結束時不清新註冊的失敗計數與 grant；新註冊照常累計，第 10 次停用。
  - **擋下請求的回應配對**：被擋下的請求不送出，它的回應配對在擋下當下就撤銷。遊戲收到本地錯誤回應後，即使在同一個回呼裡以同連線、同 msgId 送出新請求，新請求的配對也保留，伺服器的 RESPONSE 依新請求的 method 派發。送往 Swift 的路徑出錯、改送遊戲原請求時，配對也改回原請求的 method，`replace` 換過的 method 不算。
  - **跨來源的配對隔離**（pair-source）：配對以 (連線, msgId) 為鍵。插件注入的配對另存在注入登記，不進這張表。注入以宿主交易代號辨識：`ctx.sendRequest` 為每筆注入配一個代號，`sendRaw` 把它綁在送出的 buffer 上，派發、守衛判決、本地結案與 RESPONSE 消耗都依代號判來源，不比 msgId 或內容。所以注入期間同號的遊戲請求，不論內容是否相同、在哪條連線，都照常登記配對。唯一例外是守衛：與注入內容完全相同的重入請求，守衛照樣當成注入一併判定（可能兩筆都擋）。注入被擋下或注入回應抵達，都不會撤銷或消耗遊戲與 Naki 的配對；注入回應以注入時的方法交給 `onInjectResponse`。被擋下的若是遊戲請求，本地錯誤不會交給注入插件。注入配發避開未答注入、各連線遊戲未答的請求與遊戲接下來 256 個號碼（見「msgId 號段」），所以遊戲未答的請求不會與注入同號，注入被擋時的本地錯誤回應也不會帶遊戲正在等的號碼。遊戲仍可能在注入未答時走到同號，結果見「仍會誤認的情況」的注入錯認領。Naki 自送（60000–63999）與遊戲之間沒有隔離，仍共用配對。以 Blob 抵達、非同步展開的 RESPONSE，只對得上它抵達前就送出的請求；對不上時方法為 `null`，不派給任何 hook，也不交給 `onInjectResponse`。同一連線上的接收依抵達順序交給插件：前面有 Blob 還在展開時，後到的訊息（含 ArrayBuffer／TypedArray）排在它之後，展開完成才依序派發。hook 內同步送進來的接收也排在目前這則之後。展開失敗（或同一連線排隊超過 256 則）時，那條連線進入「接收不可信」直到關閉：你在那條連線上還沒收到回應的注入，`onInjectResponse` 會收到 `ctx.error === 'response_lost'`（`bytes` 為空）；`ctx.sendRequest` 回 `ok:true` 時若那條連線剛好在送出期間進入接收不可信，這筆不登記，稍後（下一個 microtask）同樣收到 `response_lost`。之後那條連線的每一則 RESPONSE 與 NOTIFY 都只交給 Naki observer，沒有 `replace`、`drop` 或變長改寫；期間任何注入都回 `msgid_busy`。讀不到的那則可能正是你的插件需要的，之後你的狀態可能不完整；恢復方式是連線關閉後重連。進入這個狀態時，宣告 `onConnectionDegraded` 的插件會收到一次退化事件（見下方）。排隊期間抵達的 ArrayBuffer／TypedArray 已交給遊戲，派發時只能觀察，沒有 `replace`、變長改寫或 `drop`；內容與遊戲收到的相同（含暱稱遮罩）。前面沒有待展開的 Blob 時，ArrayBuffer／TypedArray 照舊同步派發。
    - **代號不防惡意**（同 realm 信任模型）：`window.__nakiWebSocket.sendRaw` 頁面上任何程式都能呼叫。不帶有效代號送出的請求算 Naki 自送，登記進共用配對表，會覆寫遊戲同號未答的配對，讓那則回應派成送出的方法。包裝 `sendRaw` 的程式能在呼叫期間取得代號；代號在 `sendRaw` 返回後失效，事後重放只算 Naki 自送。`window.__nakiWebSocket.nextSeq` 也可被包裝，包裝者能在注入登記前取得控制權、改變序號或同步送入訊息；Naki 在取得序號之後才判斷連線是否可信，但不防序號被竄改。包裝 `sendRaw` 並偽造回傳值（例如把 `socketId` 做成 getter，或回報另一條可信連線的 `socketId`）同屬同 realm 不防，注入會登記到被偽造的連線；但宿主只讀一次 `socketId` 存成快照，所有可能執行頁面程式的步驟都在接收不可信檢查之前做完，所以不會因此留下對不到結果的孤兒注入登記。包裝公開的 `__nakiPlugins.dispatch` 能改寫送出交易，讓 Naki 撤回別筆遊戲請求的未答紀錄；這同樣屬於同 realm 信任模型，不列為防護範圍。
    - **外層包裝會讓代號遺失**：代號綁在 `sendRaw` 送進 `ws.send` 的那個 `ArrayBuffer` 上。頁面上若有程式包裝 `ws.send` 改傳 `new Uint8Array(buffer)`、`buffer.slice(0)`，或包裝 `sendRaw` 時漏傳第二參數，你的注入會被當成遊戲或 Naki 自送：配對進共用表，回應抵達後仍殘留。這是功能退化，不新增外送；`ctx.isNaki` 照常依 (連線, msgId) 判定，`onInjectResponse` 照常收到回應。
  - **配對表容量**：所有連線共用一張表，上限 256 筆，滿了淘汰最舊的（同鍵重寫算最新）。連線關閉時清掉該連線的配對。配對的**新增**看頁面上有沒有插件或污染：都沒有時不登記，同鍵已有的配對一併撤銷。配對的**消耗**不看：RESPONSE 到達、或同一連線以同一個 msgId 送出新請求，舊配對一律清掉。所以同一來源依序重用 msgId 時，RESPONSE 只會派成最後送出那筆請求的 method，或對不回 method（送出時沒人消耗）。已知例外：Naki 自送與遊戲同號時共用配對（見上一條）；表滿被淘汰的配對，它的 RESPONSE 對不回 method。目前筆數見 `__nakiPlugins.diagnostics().pendingPairs`。注入登記另計，上限 256 筆，連線關閉時清掉該連線的，筆數見 `diagnostics().pendingInjections`。注入登記與歧義標記同樣遵守「消耗不看消耗者」：頁面上沒有插件時，RESPONSE 仍會消耗同鍵的注入登記，沒有注入登記時消耗遊戲配對與歧義標記。
  - **`ctx.sendRequest` 退回對局連線**：沒有開著的大廳連線時，Lobby 方法可能落到對局連線。這個方法有守衛者時（已污染或已註冊宣告 `sendGuard`）照樣擋下，與大廳上相同：回 `ok:true`，之後 `onInjectResponse` 收到 `ctx.local === true` 的錯誤回應。
  - **送出方向不得就地改 `ctx.bytes`**：送出改寫只能經 `rewriteSend` 的 `ctx.replace`。大廳以外的連線上，不論就地改或經 `ctx.replace`，把請求改成可守衛方法（換裝、稱號、角色類），或改動既有可守衛方法的內容，都會撤回這個 hook 的改動並計一次該 hook 失敗；前面插件的合法改寫保留。hook 回傳 thenable 時，`then` 同步做的改寫一併檢查；違規那一次 thenable 的結果不再另計。送出方向的 `ctx.bytes` 是宿主給的副本，不是遊戲的 buffer：hook 結束當下的內容經檢查後由宿主複製送出，之後在錯誤處理、`onDisable` 或非同步時機改 `ctx.bytes`、呼叫 `ctx.replace`，都不會影響這一筆，也碰不到遊戲之後的送出。在副本上定義 `length`、`constructor` 等屬性不影響宿主讀到的內容。送出的 `ctx.replace(newBytes)` 只收 TypedArray：當下就複製成宿主自有的一份，驗證這份、採用這份，之後再改傳入物件或它的 buffer 都無效；`ArrayBuffer`、`SharedArrayBuffer`、`DataView`、普通陣列、Proxy、已分離或越界的 view 一律回 `false`，不計失敗；長度與內容只讀內部槽，自有 `length` 不讀。receive 方向長度不等的 `replace` 同樣先複製再驗證。每個 hook 結束時，宿主對要採用的快照再完整驗一次：經 `replace` 的照 `rewriteSend` 規則，就地改的不得改 type、msgId 或 method（要換 method 只能經 `rewriteSend` 的 `replace`），envelope 結構也要完整（每個欄位在界內），兩者都要過守衛規則；不合規就撤回這個 hook 的改動並計一次該 hook 失敗。整條鏈跑完後再對最終要送的內容判一次（type／msgId 不變、不在送出禁改名單、守衛規則，以當下的守衛者為準）；不過就整筆退回遊戲原內容，前面插件的改動一併不送，失敗記在最後改動的 hook。大廳上鏈跑到一半才出現的守衛者（新註冊或經同步 receive 重入污染）沒有在鏈上放行，這一筆照守衛規則擋下並改回本地錯誤。連續 10 次會自動停用。大廳上照舊：就地改成另一個有守衛者的方法會撤回，`replace` 成守衛方法當下回 `false`，改動有守衛者的方法本身會擋下並改回本地錯誤。
  - **角色未定的連線上的 Blob**：頁面上有守衛者時拒送，與大廳相同。只有已確定是對局的連線照送。若遊戲只在對局握手改用 Blob，對局連線會一直連不上。要停用宣告 `sendGuard` 的插件；已污染時還要重載頁面。
  - 沒有 `api.taint`：`register` 沒有回傳每個插件專屬的物件，全域 `__nakiPlugins` 不能辨識呼叫者。`guardState()` 是診斷用，不屬於契約，插件不得依賴。
- **`ctx.injectReceive(bytes)`**（capability `injectReceive`，L3；設計見 `docs/archive/plan/inject-receive-design-2026-10-18.md` §1）：合成一則 NOTIFY 交給 ctx 所在連線上的遊戲。
  - 只有非 Naki 流量的 ctx 有；`isNaki` 與合成通知的 ctx 都沒有，避免觀察合成再注入的迴圈。hook 返回後仍可呼叫，例如在計時器裡。
  - 宣告 `sendGuard` 的插件呼叫被接受（回 `ok:true`）的當下就污染，之後停用、熱重載都保留守衛，與改寫大廳回應相同（`plugin-v2-b2.md` §5.3 第 5 點）。
  - 回 `{ ok:true }` 只代表已排入，不代表已交付。被拒時回 `{ ok:false, reason }`：
    - `outbound_disabled`：L3 總開關關著。
    - `bad_bytes`：不是 TypedArray，或超過 1 MiB。
    - `bad_envelope`：不是每個欄位都在界內的 NOTIFY，或 method 為空。
    - `forbidden_method`：method 落在變長改寫禁改名單（見上方，含 `.lq.ActionPrototype`、全部 `.lq.FastTest.*`、`.lq.Route.*`）或 receive 禁改名單。`rewriteAllow` 解不開。
    - `no_connection`：ctx 的連線已關閉或正在關閉。
    - `receive_untrusted`：ctx 的連線處於接收不可信。
    - `inject_busy`：這條連線已有 32 則待交付。不淘汰舊的。
  - 32 則與 1 MiB 都是啟發式，未以 live 量測。32 則是整條連線共用的名額，沒有公平性保證：同一頁的其他程式持續搶先填滿時，你可能一直拿到 `inject_busy`（同 realm 不防，§8）。
  - 入口當場複製你的 bytes，之後改你自己的 buffer 不影響交付。
  - 交付在下一個 task（`setTimeout 0`）：先送 Swift（LiqiParser 只看這一次），送不到就不交付遊戲；再交付遊戲。遊戲看到的順序是「當時正在處理的那則 → 合成通知」，中間可能插進其他網路訊息（弱順序）。「排在當時那則之後」是依 HTML 規範的推論（capture listener 內排的 microtask 仍早於遊戲的 handler），**未 live 驗證**。
  - 交付當下連線已關閉、正在關閉（`readyState` 不是 OPEN）或進入接收不可信時，這則丟棄，遊戲、Swift 與觀察者都收不到，只寫一行 log，不另外通知你；這些情況各有關閉事件或退化事件。
  - 插件只透過觀察看到合成通知：只交給宣告 `observeNakiTraffic` 的 observer，`ctx.isNaki === true`、`ctx.synthetic === 'injectReceive'`、`ctx.syntheticBy` 是發起插件 id，沒有 `replace`、`drop`、`sendRequest`、`injectReceive`、`respondLocally`。觀察順序等於遊戲收到的順序：前面有 Blob 還在展開時，觀察跟著排隊。排隊的觀察項與網路接收共用同一個 256 則上限，超過時那條連線進入接收不可信（`receive_queue_overflow`），之後的 `injectReceive` 回 `receive_untrusted`。
  - 合成通知不碰配對、注入登記、歧義標記或遊戲未答。
  - 不新增外送路徑。遊戲收到合成通知後若自行送出請求，那是遊戲的送出，照常經守衛與送出禁改名單。
  - 同 realm 不防：`window.__nakiWebSocket.injectReceive` 頁面上任何程式都能直接呼叫，跳過 L3 與名單檢查；這與頁面程式本來就能 `dispatchEvent` 或直接呼叫 bridge 同級（§8）。
- **`ctx.respondLocally(bytes)`**（capability `respondLocally`，L3；設計見同文件 §2）：在 `onSend` 裡以本地回應取代送出，伺服器收不到這筆請求。
  - 只有送出方向、非 `isNaki`、同步派發（不是 Blob）的 ctx 有，而且 method 不在禁用名單：送出禁改名單（非 `.lq.Lobby.*` 一律禁，含登入類、`startUnifiedMatch`、`matchGame`），加 `.lq.Lobby.cancelUnifiedMatch`、`.lq.Lobby.cancelMatch`。`rewriteAllow` 解不開。名單由 `JSContractTests` 從 LiqiParser 反查。
  - 只在 hook 同步執行期間有效。被拒時回 `{ ok:false, reason }`：
    - `outbound_disabled`：L3 總開關關著。
    - `too_late`：hook 已返回（例如保存 ctx 後在計時器裡呼叫）。
    - `not_guardian`：大廳上這個方法有守衛者，而你不是。只有守衛者能在守衛方法上提案。
    - `local_busy`：這條連線已有 256 筆本地回應還沒交給遊戲。不淘汰舊的；下一個 task 交付後恢復。
    - `bad_bytes`：不是 TypedArray，或超過 1 MiB（啟發式，未以 live 量測）。
    - `bad_envelope`：不是 RESPONSE、msgId 不是這筆請求的，或欄位越界。field 1（method）可有可無。
    - `rewritten`：這筆請求已被前面的插件或你自己改過（`replace` 或就地改）。
    - `already_responded`：已有別的插件的提案。先到先得。
  - 接受時回 `{ ok:true }`，當場複製你的 bytes 存成提案。鏈不停止，其他插件照常執行；之後的 `ctx.replace` 回 `false`。
  - 結局：請求不送出。Swift 在同一則訊息收到原請求與提案回應；遊戲在 `ws.send` 返回後的下一個 task 收到提案回應。只有呼叫的插件知道回應內容，其他插件看不到這則回應。被拒時（非守衛方法）請求照常送出，與沒呼叫相同。
  - 判決出錯或 bridge 出錯時，有提案的非守衛方法仍交付提案，不會改送原請求：你已拿到 `ok:true`。
  - 守衛方法依 `plugin-v2-b2.md` §4.2：只收守衛者的提案。守衛者的 `respondLocally` 被拒算第 3 步失敗，整筆改為本地錯誤（`respond_rejected`；回應不合規是 `response_invalid`），之後它停用或退出也一樣。第 3 步不成立而有守衛者的提案時本地成功（守衛紀錄 `local_ok`），不需要其他守衛者放行。拋錯、回傳 thenable 與 bridge 出錯仍優先，改為本地錯誤。你呼叫時還沒有守衛者、提案被接受，鏈中才出現守衛者時，提案不交付，整筆改為本地錯誤（`not_guardian`），請求一樣不送出。
  - 宣告 `sendGuard` 的插件提案被接受的當下就污染（同 `injectReceive`）。
  - 本地回應的請求不算遊戲未答，但遊戲的最後號碼照樣前進；交給遊戲之前它的號碼另行保留，注入不會配到（見「msgId 號段」）。
- **`onConnectionDegraded(ctx)`**（不需要 capability，不需要在 manifest 宣告；設計見同文件 §3）：Naki 對某條連線或整頁進入降級模式時，通知所有有這個 hook 的插件，不看 `methods`、`observeNakiTraffic`，也不看你有沒有未答的注入。
  - ctx 唯讀（凍結），只有 `log` 一個函式：`socketId`、`url`、`reason`、`scope`（`'connection'` 或 `'page'`）、`effects`（字串陣列）、`recovery`（`'reconnect'` 或 `'reload'`）、`at`。沒有封包內容；`url` 是連線的原始網址、原樣傳入，網址本身帶的查詢參數會一併出現（與 `ctx.url` 同一份資訊，§8 同 realm 不防）。

    | reason | 何時 | scope | effects | recovery |
    |---|---|---|---|---|
    | `receive_blob_failed` | 接收 Blob 讀不到 | connection | `responses_observe_only`、`notify_observe_only`、`injections_refused` | reconnect |
    | `receive_queue_overflow` | 接收佇列超過 256 則 | connection | 同上 | reconnect |
    | `send_blob` | 遊戲以 Blob 送出 | page | `injections_refused` | reconnect（該連線） |
    | `send_inflight_overflow` | 遊戲未答超過 256 筆，且結算後仍失準 | page | `injections_refused` | reconnect（該連線） |
    | `ambiguity_overflow` | 歧義號碼超過 256 個，整條連線只觀察 | connection | `responses_observe_only` | reconnect |
    | `reshape_locked` | 變長交付故障鎖死 | page | `reshape_disabled` | reload |

  - 讀取或呼叫你的 `onConnectionDegraded` 拋錯（含 getter 拋錯）只記你自己的一次失敗，其他插件與同批其他事件照常收到。
  - 每條連線每個 reason 只發一次。恢復方式是連線關閉後重連（與 `response_lost` 一致）；`reshape_locked` 要重載頁面。重連是新的 socketId，之後再退化會再發。
  - 交付時機：觸發後的下一個 task（`setTimeout 0`），一次交付當時已排入的那一批；你在回呼裡造成的新退化排到再下一個 task，不會插進這一批。交付當下沒有任何插件 hook 在執行，也不在一筆送出的判決與上 wire 之間，所以你在回呼裡做的事（例如用保存的 ctx 呼叫 `taint()`）只影響之後的送出。代價是順序：同一個 task 裡排在它後面的訊息（例如接收佇列裡的觀察項）可能先派發；那些訊息的限制（只觀察）在觸發當下就已生效。同時寫一行插件 id `naki` 的 log。
  - `injections_refused` 的 scope 是 page：沿用現行規則，任一連線失準或以 Blob 送出，所有連線的 `sendRequest` 都回 `msgid_busy`。

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
