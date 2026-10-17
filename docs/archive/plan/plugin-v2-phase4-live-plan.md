# plugin-v2 Phase 4 live 前置計畫（L1–L7）

**資料日期**：2026-10-17。**狀態**：live 已執行，L1–L7 全綠，結果與偏差見設計 §9.1。**分支**：`plugin-v2-phase4`，HEAD `1f8c2cb`（rebase 到 main `91841ba`）。
**來源**：設計 `plugin-v2-phase4.md` §8。本文件只把每一項落到「哪個插件、哪個 `/js`、看哪個值」。判準以設計 §8 為準。

## 0. 前置

| 項 | 內容 |
|---|---|
| 帳號 | 只用測試帳號（CLAUDE.md 邊界） |
| build | 從本 worktree build 的 Naki。執行中的 main Naki 佔 8765，要嘛先結束它，要嘛讓新 instance 退到 8766 並設 `NAKI_API=http://127.0.0.1:8766`。兩支腳本都讀 `NAKI_API` |
| 確認跑的是 HEAD | `curl -X POST $API/js -d 'return typeof window.__nakiPlugins.isReshapeForbidden'` 回 `"function"`；main 回 `"undefined"` |
| 插件目錄 | `~/Library/Application Support/Naki/Plugins/<id>/`，熱插拔驗啟用，不用 `defaults write` |
| L3 總開關 | L3（drop）與 L1 需要開；其餘項目保持關 |
| 收尾 | 移除測試插件、關 L3、重載頁面（解除 reshape 鎖死與 `/js` 臨時 patch） |

### 腳本相容性（已讀碼）

- `scripts/replay-check.sh`：經 MCP `replay_list`／`replay_game` 重跑 Swift 錄影，**不經 JS**。Phase 4 只改 JS 與 `PluginRegistry.validate`，所以對既有錄影跑它只能證明 Swift 決策沒變，證明不了 capture 主路徑。L4 因此改成「L5 新錄的局」再重跑，見下。
- `scripts/soak-test.sh`：用 bridge log 的 `[協調器] start_game`／`end_game` 判局界，**不讀** `__nakiWebSocket.diagnostics()`。與新增的 `reshape`、`reshapeLocked`、`reshapeFaults` 欄位沒有衝突，也沒有覆蓋。要另外在 soak 前後用 `/js` 取快照。
- `diagnostics()` 的形狀：`{ reshape:{attempted,delivered,dropped,fallback,faults}, reshapeLocked, reshapeFaults:[…≤32], receive:{ArrayBuffer,TypedArray,Blob,String,Other}, send:{…} }`。Swift 端只經 `__nakiPlugins.diagnostics().runtime.websocket` 當字串轉出，加欄位不破壞解析。

### 共用 `/js`

```bash
# 快照（每項前後各取一次）
curl -s -X POST $API/js -d 'return JSON.stringify(window.__nakiWebSocket.diagnostics())'
# 插件端：錯誤、log、污染
curl -s -X POST $API/js -d 'return JSON.stringify({p:window.__nakiPlugins.diagnostics(),g:window.__nakiPlugins.guardState()})'
```

## 1. 測試插件

一個插件 `naki-p4-live`，依項目換 manifest。`capabilities` 與 `methods` 依各項填；`sendGuard` 不宣告（避免污染干擾 L2）。

改寫一律用**語意不變**的變長版本，讓「遊戲照常」可當判準：

- RESPONSE：canonical 重編碼，拿掉空的 field 1（長度 −2）。`[3, id_lo, id_hi, 0x12, len, …payload]`。
- NOTIFY：payload 之後補一個未知欄位（例如 field 15 varint 0，`0x78 0x00`），並更新 field 2 的長度前綴。protobuf 忽略未知欄位。

插件在 `ctx.log` 寫 `method`、`ctx.replace(...)` 的回傳值、原長與新長。

## 2. 各項

| # | 插件設定 | 操作 | `/js` | 通過判準 |
|---|---|---|---|---|
| L0 普查 | `observe`，`methods` 列候選：`.lq.NotifyAccountUpdate`、`.lq.NotifyRoomPlayerUpdate`、`.lq.NotifyRoomPlayerReady`、`.lq.Lobby.heatbeat`、`.lq.Lobby.fetchRoom`、`.lq.Lobby.fetchAccountInfo` | 大廳待 2 分鐘；建友人房、加人機（`room_create`＋`room_add_robot`，屬寫入動作）；開自己的資料頁 | `__nakiPlugins.diagnostics()` 的 log | 選出一則實際會出現的大廳 NOTIFY 與一則遊戲自送請求的大廳 RESPONSE，供 L2／L3 用。Naki 自送的不算（isNaki，沒有 replace） |
| L1 kill-switch 同步性 | `rewriteReceive`＋`reshapeReceive`，`methods` 為 L0 選的 NOTIFY | 先注入下方 patch，再觸發一次該 NOTIFY | `window.__p4L1` | `lockedRightAfterDispatch === true`；`reshapeFaults` 有一筆 `kind:"synthetic_dispatch_error"`、帶 method 與 `candidates:["naki-p4-live"]`；`sawWindowError === true`。若 `lockedRightAfterDispatch` 為 false 而稍後變 true，代表 `error` 非同步，設計 §5 的觀測要改 |
| L2 大廳變長 | 同 L1，`methods` 加 L0 選的 RESPONSE | 各觸發 3 次（重載頁面先清 L1 的鎖） | 快照 | 每次 replace 回 `true`；`attempted === delivered === 6`、`faults === 0`、`reshapeLocked === false`；連線 OPEN（`getConnections()` 該連線 `readyState === 1`）；畫面照常、無錯誤提示 |
| L3 大廳 drop | `dropReceive`，L3 開，`methods` 為 L0 選的 NOTIFY | 觸發 3 次 | 快照；bridge log 該 method 次數 | `dropped === 3`；bridge log 在這段時間沒有該 NOTIFY；之後建房、開局照常 |
| L4 零插件 replay | 無插件 | L5 跑完後 `scripts/replay-check.sh --session <L5 的 session>` | — | 每局 `錯誤` 為 0、沒有 TOOL_ERROR／PARSE_ERROR。另以同一批錄影在 main build 上跑 `--save`，HEAD build 上跑 `--baseline`，指紋相同 |
| L5 三局 soak | 無插件 | `NAKI_API=$API scripts/soak-test.sh 3` | soak 前後快照 | 腳本報告無異常；`reshape` 全為 0、`reshapeLocked === false`、`reshapeFaults` 為空；`receive.ArrayBuffer` 有增長 |
| L6 等長回歸 | 既有等長改寫插件（`naki-plugins` 的 tile-highlighter／name-hider 若有改寫，否則用 `naki-p4-live` 只宣告 `rewriteReceive` 做等長改寫） | 一局 | 快照；插件 log | 等長 replace 回 `true`；`reshape.attempted === 0`（等長不走合成事件）；行為與 main build 相同 |
| L7 binaryType | 無插件 | 大廳與對局各待一段 | 快照的 `receive` | 記錄 `ArrayBuffer` 與 `Blob` 計數。`Blob > 0` 代表該連線的變長改寫不會生效，`respondLocal` 缺口要開案 |

### L1 patch（頁面重載即移除）

```js
// curl -X POST $API/js -d '<下面整段>'
var proto = EventTarget.prototype, orig = proto.dispatchEvent, Orig = window.__nakiWebSocket.OriginalWebSocket;
window.__p4L1 = { armed: true };
window.addEventListener('error', function () { if (window.__p4L1.inDispatch) window.__p4L1.sawWindowError = true; });
proto.dispatchEvent = function (ev) {
  var s = window.__p4L1;
  if (!(s.armed && this instanceof Orig && ev.type === 'message' && window.__nakiWebSocket.diagnostics().reshape.attempted > 0)) return orig.call(this, ev);
  s.armed = false;
  var thrower = function () { this.removeEventListener('message', thrower); throw new Error('p4 L1 probe'); };
  this.addEventListener('message', thrower);
  s.inDispatch = true;
  try { return orig.call(this, ev); }
  finally { s.inDispatch = false; s.lockedRightAfterDispatch = window.__nakiWebSocket.diagnostics().reshapeLocked; }
};
return 'armed';
```

`ws.dispatchEvent` 在呼叫當下才查原型，所以 patch 對既有連線有效。`respondLocal` 也走 `dispatchEvent`，L1 期間不要觸發守衛本地回應。

## 3. 不在本計畫內

- 牌局類 method 的放寬（設計 §4 放寬條件）。
- `injectReceive`、`respondLocally`。
- 哨兵盲區一的 live 重現（需要遊戲自己註冊 capture handler，現況 (c) 顯示遊戲只用 `onmessage`）。
