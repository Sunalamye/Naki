# Majsoul WebUI API 架構（Laya 時代・已作廢）

> # ⚠️ 已作廢：本文描述的整套 JS API 已隨引擎更換消失
>
> **雀魂於 `chs_t-WebGL-release-4.0.45(45)` 改用 Unity WebGL 客戶端**（原為 Laya 3D + JS）。
> 2026-07-31 runtime 實測確認：`window.view`、`window.game`、`window.app`、`window.uiscript`、
> `window.mjcore`、`window.cfg`、`window.net`、`window.Laya`、`window.caps` …
> **本文列出的頂層命名空間全部不存在**。
>
> 現在頁面上只有：`createUnityInstance`、`unityFramework`、`getUnityElements`、`onUnityReady`，
> 加上 `<div id="unity-container">` + `<canvas id="unity-canvas" width=2560 height=1440>`。
>
> ### 👉 現在的正確做法
>
> 所有讀取與動作改走 **Liqi protobuf**（wire protocol 實測完全沒變）。
> 參見 **[majsoul-unity-protocol.md](majsoul-unity-protocol.md)**。
>
> ### 本文為何還留著
>
> 只保留「協議層仍可能有用的殘留」（列舉值、Liqi 方法名清單）與一份極簡歷史骨架。
> **Laya/UI/音效/渲染的 API 明細已全部刪除**，避免被當成可用參考照抄。
> 完整原文在 git history：`git show 49487a1 -- docs/majsoul-webui-api-architecture.md`

**原文日期**: 2025-12-07（Laya 時代）
**作廢日期**: 2026-07-31
**姊妹文件**: [majsoul-webui-objects-reference.md](majsoul-webui-objects-reference.md)（同樣已作廢）

---

## 目錄

1. [Naki Coordinator 現況](#naki-coordinator-現況)
2. [已消失的命名空間](#已消失的命名空間)
3. [仍可能有用的殘留：Liqi 方法名與列舉](#仍可能有用的殘留liqi-方法名與列舉)
4. [Laya 時代架構圖（純歷史）](#laya-時代架構圖純歷史)

---

## Naki Coordinator 現況

`window.naki`（= `NakiCoordinator`，`command/Resources/JavaScript/naki-coordinator.js`）
**仍會載入、物件仍在**，但大部分方法內部讀的是已消失的 Laya 物件，呼叫會拿到
`null` / `{success:false}` / 例外。

> 本輪**未修改任何 `.js` / `.swift`**，以下只是狀態陳述。

| 命名空間 | 依賴 | 狀態 |
|----------|------|------|
| `naki.state.*`（`isInGame` / `getFullState` / `getHandInfo` / `getAvailableOps`） | `view.DesktopMgr.Inst`、`GameMgr.Inst` | ❌ 失效 |
| `naki.auto.*`（`setHule` / `setNoFulu` / `setMoqie` …） | `DesktopMgr` 的 `auto_*` 屬性 | ❌ 失效 |
| `naki.action.*`（`discard` / `pass` / `chi` / `pon` / `kan` / `hora` / `riichi`） | `mainrole.*` 方法 | ❌ 失效 → **改走 Liqi protobuf** |
| `naki.lobby.*`（`getStatus` / `startMatch` / `cancelMatch`） | `uimgr._ui_lobby`、`_uis[105]` | ❌ 失效 → **改走 Liqi protobuf** |
| `naki.heartbeat.*`（`send` / `enableAntiIdle`） | `GameMgr.Inst.clientHeatBeat()` | ❌ 失效（wire 上有 `.lq.Route.heartbeat`，但 Naki 自送的可行性未驗證） |
| `naki.visual.*`（推薦高亮 / 隱藏玩家名） | `effect_*` Sprite3D、`uiscript` | ❌ 失效 |
| `naki.network.getConnections()` / `forceReconnect()` | `window.__nakiWebSocket` | ✅ **仍正常** |
| `naki.debug.*`（`getDiagnostics` / `listMethods`） | 混合 | ⚠️ 部分（診斷會如實回報上述模組不可用） |

---

## 已消失的命名空間

原文列出的 14 個頂層命名空間，**實測全部不存在**：

```
window.view (51)      window.game (95)      window.app (8)        window.uiscript (200+)
window.mjcore (10)    window.cfg (32)       window.net (22)       window.ui (12)
window.amulet (59)    window.caps (27)      window.capsui (26)    window.common (6)
window.Laya (40+)     window.protobuf (31)
```

連帶失效的整組 API（原文各有專章，已刪除）：

- `GameMgr` / `DesktopMgr` / `mainrole` 的全部屬性與方法
- `app.NetAgent.sendReq2Lobby` / `sendReq2MJ` / `addListener2MJ`
- `net.*`（Socket、NetRoute、ProtobufManager、NotifyHandler…）
- `UIMgr` / `uiscript.UI_*` 全系列
- `view.AudioMgr` / `view.BgmListMgr`（音效與 BGM 控制）
- `view.Action*` 動作類（`ActionNewRound`、`ActionDealTile`…）
  ⚠️ **注意區分**：這些是「Laya 客戶端的 view 層動作類」，
  與 Liqi 協議上的 `.lq.ActionPrototype` 內含的同名動作**不是同一回事**。
  **協議層的 Action 完全沒變**，Naki 的 Swift 端照舊解得動。
- `window.Laya` / `window.caps`（引擎與 shader）
- `common.*`、`app.CookieMgr`、`app.Taboo`、`game.LoginMgr`、`game.ChatMgr`
- `window.EventCode` / `window.ProtoCode` 常數表

---

## 仍可能有用的殘留：Liqi 方法名與列舉

> ⚠️ 以下來自 Laya 客戶端內部。與 Unity 時代 wire 上的實際內容**是否一致，本輪都沒實測**。
> 當成抓封包時的**猜測起點**，不是事實。

### Liqi 方法名線索（原 `ProtoCode` 常數 + `NetAgent` 呼叫過的）

```
# 匹配
matchGame  cancelMatch  startUnifiedMatch  cancelUnifiedMatch
fetchCurrentMatchInfo  fetchQueueInfo  fetchGamingInfo

# 房間
createRoom  joinRoom  leaveRoom  readyPlay  startRoom  fetchRoom

# 帳號 / 雜項
fetchAccountInfo  fetchMultiAccountBrief  fetchMailInfo  serverTime

# 比賽
createCustomizedContest  updateManagerCustomizedContest
fetchManagerCustomizedContestList  fetchCustomizedContestList
generateContestManagerLoginCode

# 活動
completePeriodActivityTask  completePeriodActivityTaskBatch
islandActivityMove / Buy / Sell / TidyBag / UnlockBagGrid
```

**未驗證**：完整方法名（`.lq.Lobby.xxx` / `.lq.FastTest.xxx` 前綴）與各自的
request message 欄位。唯一有完整實測範例的是 `.lq.Route.heartbeat`，
逐位元組解說見 [majsoul-unity-protocol.md](majsoul-unity-protocol.md#實測封包逐位元組解說)。

### mjcore 列舉（Laya 時代值）

```js
E_MJPai        { p:0, m:1, s:2, z:3, bd:4 }
E_Ming         { shunzi:0, kezi:1, gang_ming:2, gang_an:3, babei:4, gang_add:5 }
E_Hu_Type      { rong:0, zimo:1, qianggang:2 }
E_LiuJu        { none:0, jiuzhongjiupai:1, sifenglianda:2, sigangsanle:3,
                 sijializhi:4, sanjiahule:5 }
E_PlayOperation{ none:0, dapai:1, eat:2, peng:3, an_gang:4, ming_gang:5, add_gang:6,
                 liqi:7, zimo:8, rong:9, jiuzhongjiupai:10, babei:11, huansanzhang:12,
                 dingque:13, reveal:14, unveil:15, locktile:16, revealliqi:17,
                 selecttile:18, po_liqi_5000:19, po_liqi_10000:20 }
```

**未驗證**：Liqi 訊息內的對應欄位是否用同一組編碼。要用先抓真實封包比對。

### 配置模組清單（`cfg.*`，僅供知道曾經有哪些資料）

`achievement` `activity` `amulet` `animation` `audio` `character` `chest` `desktop`
`events` `exchange` `fan` `fandesc` `game_live` `global` `info` `item_definition`
`level_definition` `mall` `outfit_config` `quest_crew` `rank_introduce` `season`
`shoot` `shops` `simulation` `spot` `str` `tournament` `tutorial` `vip` `voice`

`cfg` 物件本身已不存在，**客戶端配置改寫這條路整條斷掉**
（含雪球小遊戲的本地設定表）。

---

## Laya 時代架構圖（純歷史）

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│   GameMgr    │  │  DesktopMgr  │  │   NetAgent   │
│  (全局管理)   │  │  (遊戲桌面)   │  │  (網路代理)   │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
   uimgr(UI)         mainrole(自家)    LobbyNetMgr / MJNetMgr
       │                 │                 │
   uiscript.UI_*     hand[] / oplist    WebSocket ── Liqi protobuf ──► 伺服器
                                            ▲
                        ─────────────────────┘
                        只有這一層在 Unity 遷移後存活
```

**遷移後**：圖中除了最底下那條 WebSocket + Liqi protobuf，其餘全部消失。
Naki 的攔截（`naki-websocket.js`）掛在 WebSocket 上，所以毫髮無傷；
Naki 的狀態讀取與動作執行掛在上面那些 JS 物件上，所以全壞。

---

**文檔版本**: 2.0（作廢改寫）
**更新日期**: 2026-07-31
**驗證狀態**: 「已消失的命名空間」= 已驗證（runtime 列舉）；「殘留線索」= 未驗證（Laya 時代觀察）
