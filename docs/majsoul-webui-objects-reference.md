# Majsoul WebUI Objects Reference（Laya 時代・已作廢）

> # ⚠️ 已作廢：本文描述的物件全部不存在了
>
> **雀魂於 `chs_t-WebGL-release-4.0.45(45)` 改用 Unity WebGL 客戶端**（原為 Laya 3D + JS）。
> 2026-07-31 runtime 實測確認：`window.Laya`、`window.GameMgr`、`window.uiscript`、
> `window.view.DesktopMgr`、`window.cfg`、`window.app.NetAgent` **全部不存在**。
>
> 本文原本記載的 `mainrole.hand`、`setChoosePai()`、`DoDiscardTile()`、
> `effect_doraPlane.clone()` 高亮、`uimgr._ui_lobby`、`_uis[105].addMatch()`、
> `cfg.xxx.rows_` 改配置、`clientHeatBeat()` 防閒置 —— **全數失效，照抄必定拋錯。**
>
> ### 👉 現在的正確做法
>
> 所有讀取與動作改走 **Liqi protobuf**（wire protocol 實測完全沒變）。
> 參見 **[majsoul-unity-protocol.md](majsoul-unity-protocol.md)**。
>
> ### 本文為何還留著
>
> 只留「協議層仍可能有用的殘留知識」（列舉值、方法名、伺服器端機制），
> 作為查真實封包時的**線索**——不是事實。**Laya JS 操作食譜已全部刪除**，
> 避免有人（或 AI agent）grep 到就照抄。
> 完整 Laya 時代原文在 git history：`git show 1201c74 -- docs/majsoul-webui-objects-reference.md`

**原文日期**: 2025-12-04 ~ 2025-12-06（Laya 時代）
**作廢日期**: 2026-07-31
**保留理由**: 協議層線索存檔

---

## 目錄

1. [失效清單（速查）](#失效清單速查)
2. [仍可能有用的殘留知識](#仍可能有用的殘留知識)
3. [Laya 時代物件圖（純歷史）](#laya-時代物件圖純歷史)
4. [遷移影響：Naki 哪些部分壞了](#遷移影響naki-哪些部分壞了)

---

## 失效清單（速查）

以下每一項都是 **runtime 實測不存在**（不是「可能失效」）：

| 舊做法 | 用途 | 狀態 |
|--------|------|------|
| `window.view.DesktopMgr.Inst` | 遊戲桌面總入口 | ❌ 不存在 |
| `...Inst.mainrole.hand` | 讀手牌 | ❌ 不存在 |
| `...mainrole.setChoosePai(tile, true)` | 選牌 | ❌ 不存在 |
| `...mainrole.DoDiscardTile()` | 打牌 | ❌ 不存在 |
| `...mainrole.DoOperation(i)` / `QiPaiNoPass()` | 吃碰槓/確認 | ❌ 不存在 |
| `...Inst.oplist` | 可用操作列表 | ❌ 不存在 |
| `...Inst.dora` | 寶牌指示牌 | ❌ 不存在 |
| `...Inst.effect_doraPlane` / `effect_recommend` | 高亮/寶牌特效 | ❌ 不存在 |
| `window.uiscript.UI_ChiPengHu.Inst` | 動作按鈕 UI | ❌ 不存在 |
| `window.GameMgr.Inst.uimgr._ui_lobby` | 大廳切頁 | ❌ 不存在 |
| `window.GameMgr.Inst.uimgr._uis[105].addMatch(n)` | 開始匹配 | ❌ 不存在 |
| `window.GameMgr.Inst.clientHeatBeat()` | 大廳防閒置心跳 | ❌ 不存在 |
| `window.app.NetAgent.sendReq2Lobby(...)` | 發 Liqi 請求 | ❌ 不存在 |
| `window.cfg.*` | 客戶端配置表 | ❌ 不存在 |
| `window.Laya.*`（Vector3 / timer / Sprite3D…） | 引擎 API | ❌ 不存在 |

**替代路徑**：全部改走 WebSocket + Liqi protobuf，見
[majsoul-unity-protocol.md](majsoul-unity-protocol.md)。

---

## 仍可能有用的殘留知識

> ⚠️ 下列內容來自 **Laya 客戶端內部**的觀察。
> 它們與 Liqi wire protocol **是否一致，本輪都沒有實測**。
> 當成「查真實封包時的猜測起點」，不是事實。

### 操作類型列舉（`mjcore.E_PlayOperation`，Laya 時代值）

```
0  none              7  liqi (立直)         14 reveal
1  dapai (打牌)       8  zimo (自摸)         15 unveil
2  eat (吃)           9  rong (榮和)         16 locktile
3  peng (碰)         10  jiuzhongjiupai      17 revealliqi
4  an_gang (暗槓)    11  babei (拔北)        18 selecttile
5  ming_gang (明槓)  12  huansanzhang        19 po_liqi_5000
6  add_gang (加槓)   13  dingque             20 po_liqi_10000
```

**未驗證**：Liqi `ActionOperation` 內的 `type` 是否使用同一組編碼。

### 牌型編碼（Laya 客戶端內部 `val.type` / `val.index`）

```
type: 0=筒(p)  1=萬(m)  2=索(s)  3=字(z)  4=百搭(bd)
```

**未驗證**：Liqi wire 上的牌表示（Naki `LiqiParser` 走的是牌字串形式）與此**不是**同一套，
不要把 `val.type/index` 的轉換規則搬去解 protobuf。牌字串轉換的實作以
`command/Services/Bridge/LiqiParser.swift` / `MajsoulBridge.swift` 為準。

### 匹配模式 ID（`match_mode`，Laya 時代由 `cfg.desktop.matchmode` 讀出）

| ID | 房間 | 說明 |
|----|------|------|
| 1–3 | 銅之間 | 四麻 東/半/— |
| 4–5 | 銀之間 | 四麻 東/半 |
| 6–8 | 金之間 | 四麻 |
| 9–11 | 玉之間 | 四麻 |
| 14–15 | 王座間 | 四麻 |
| 17–18 | 銅之間 | 三麻 |
| 19–20 | 銀之間 | 三麻 |
| 26–29 | 休閒場 | — |
| 30 | 寶牌狂熱 | 特殊模式 |

**未驗證**：這是伺服器端概念（會出現在 `ReqJoinMatchQueue.match_mode`），
遷移後編號**應該**沒變，但沒實測。要用必須先抓真實匹配封包確認。

### 段位 ID 編碼

```
10xxx = 四麻   20xxx = 三麻
第2位：1=雀士 2=雀傑 3=雀豪 4=雀聖 5=魂天
第3–4位：等級與星數
```

> 原文對 `10202` 的中文段位名前後不一致（一處寫「雀士二 2星」、一處依表應為「雀傑」），
> 本輪未重新驗證，故只保留編碼規則、移除具體範例。

### Liqi 方法名線索（Laya 時代 `app.NetAgent` 呼叫過的）

大廳：`matchGame`、`cancelMatch`、`startUnifiedMatch`、`cancelUnifiedMatch`、
`fetchCurrentMatchInfo`、`fetchGamingInfo`、`fetchAccountInfo`、`fetchQueueInfo`、
`fetchRoom`、`createRoom`、`joinRoom`、`leaveRoom`、`readyPlay`、`startRoom`、`serverTime`

**未驗證**：完整 Liqi 方法名（含 `.lq.Lobby.` 前綴）與 request 欄位定義都沒實測。
唯一有完整實測範例的是 `.lq.Route.heartbeat`，見
[majsoul-unity-protocol.md](majsoul-unity-protocol.md#實測封包逐位元組解說)。

### 錯誤碼（Laya 時代觀察）

| 碼 | 含義 |
|----|------|
| 2 | 通用錯誤 |
| 157 | 隊列資訊不可用 |
| 1302 | 未在匹配中 |
| 1306 | 匹配失敗（段位不符或其他限制） |

### 閒置 / AFK 機制（**伺服器端部分仍然成立**）

雀魂有三種獨立機制，只有第 1 種是客戶端可干預的：

| 機制 | 觸發 | 閾值 | 客戶端能否阻止 |
|------|------|------|----------------|
| 大廳閒置登出 | 大廳長時間無動作 | 約 50 分鐘（Laya 時代為 3000 秒警告） | Laya 時代靠 `clientHeatBeat()`；**Unity 下做法未驗證** |
| 對局單次操作超時 | 輪到你不操作 | 依房間 | ❌ 伺服器控制 |
| 連續超時（AFK/托管） | 連續多次超時 | 連續 N 次 | ❌ 伺服器控制，可能觸發臨時封禁 |

相關 protobuf（協議層，**不受引擎遷移影響**）：

```protobuf
message NotifyPlayerConnectionState { uint32 seat = 1; GamePlayerState state = 2; }
enum GamePlayerState { NULL = 0; AUTH = 1; SYNCING = 2; READY = 3; }
message NotifyAFKResult { uint32 type = 1; uint32 ban_end_time = 2; string game_uuid = 3; }
```

> 實測補充：wire 上確實有 `.lq.Route.heartbeat` REQUEST（遊戲自己在送）。
> **Naki 是否應該／可以自行補送以防閒置：未驗證。**

---

## Laya 時代物件圖（純歷史）

保留一份極簡骨架，僅供閱讀舊 commit 或舊 issue 時對照。**不要照著寫任何新 code。**

```
window.GameMgr.Inst                 全域管理器（登入態、帳號、uimgr）
 └─ uimgr                           UI 管理器
     ├─ _ui_lobby                   大廳（page0 / page_rank / page_match …）
     ├─ _ui_waitingroom             等待房
     └─ _uis[105]                   匹配 UI（addMatch / cancelPiPei）

window.view.DesktopMgr.Inst         對局桌面
 ├─ mainrole                        自家（hand[] / setChoosePai / DoDiscardTile / DoOperation）
 ├─ players[]                       其他家
 ├─ oplist[]                        可用操作
 ├─ dora[]                          寶牌指示牌
 └─ effect_dora3D / effect_doraPlane / effect_recommend / effect_shadow

window.uiscript.UI_ChiPengHu.Inst   吃碰槓和按鈕（container_btns，15 個子按鈕）
window.app.NetAgent                 Liqi 請求出口（sendReq2Lobby / sendReq2MJ）
window.cfg.*                        配置表（table_ 索引 + rows_ 陣列）
window.mjcore.*                     牌型/操作/和牌列舉
window.Laya.*                       引擎（Vector3、timer、Sprite3D…）
```

已刪除的內容（可在 git history 取回）：
Laya `Sprite3D` 屬性表、寶牌／推薦高亮的 clone 食譜（`effect_doraPlane` + `anim.RunUV`
／雙層旋轉 `anim.Bling`）、`UI_ChiPengHu` 按鈕索引與 3D 座標映射表、
`Laya.timer._handlers` 逆向流程、shader / 貼圖 URL 清單、逐段 JS 查詢範例。

刪除理由：這些是「某個已被移除的渲染引擎的實作細節」，對 Unity 時代零遷移價值，
留著只會讓後續的人/agent 誤以為可用。

---

## 遷移影響：Naki 哪些部分壞了

> 這節只描述**事實與影響**。本輪未修改任何 `.swift` / `.js`。

| Naki 元件 | 狀態 |
|-----------|------|
| `naki-websocket.js`（攔截 + `getMajsoulConnections`） | ✅ **仍正常**（實測 2 條 live 連線） |
| Swift `LiqiParser` / `MajsoulBridge`（協議解碼） | ✅ **仍正常**（wire protocol 沒變） |
| `NativeBotController` / MortalSwift 推論 | ✅ 不受影響（吃的是 MJAI 事件） |
| `naki-game-api.js`（`DesktopMgr` 讀狀態） | ❌ **全壞** |
| `naki-autoplay.js`（找牌 DOM/Laya、點擊） | ❌ **全壞** |
| `naki-coordinator.js` 的 `state` / `action` / `lobby` / `visual` | ❌ **全壞**（依賴 `DesktopMgr` / `GameMgr` / `uiscript`） |
| `naki-coordinator.js` 的 `network`（`getConnections` / `forceReconnect`） | ✅ 仍正常（只碰 `__nakiWebSocket`） |
| `naki-core.js` 的 `__nakiAntiIdle`（`clientHeatBeat`） | ❌ 壞（改走 `.lq.Route.heartbeat`，做法未驗證） |
| Debug Server `/game/*`、`/ui/names`、MCP 對應工具 | ❌ 壞（底層走上述 JS） |
| Debug Server `/js`、`/logs`、`/bot/*` | ✅ 大致仍可用（`/js` 仍能在頁面 context 執行） |

修復方向：**動作與狀態一律改走 Liqi protobuf**，見
[majsoul-unity-protocol.md](majsoul-unity-protocol.md)。

---

**文檔版本**: 2.0（作廢改寫）
**更新日期**: 2026-07-31
**驗證狀態**: 「失效清單」= 已驗證（runtime 列舉）；「殘留知識」= 未驗證（Laya 時代觀察）
