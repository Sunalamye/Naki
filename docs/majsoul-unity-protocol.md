# Naki 現行 Unity／AI 技術基準

**資料日期**：2026-08-01（Asia/Taipei）

**程式基準**：Naki `main`，盤點起點 `7de0a04` 加目前工作樹

**用途**：這是目前唯一的 Unity、Liqi、Mortal、自動打牌與遊戲內高亮技術基準。

本文只保留能由下列來源支持的現況，不保存 Laya 時代做法或已被推翻的中間結論：

1. Naki 當前程式碼、測試與 Xcode package 設定。
2. 正在執行的 Naki loopback API（`127.0.0.1:8765`）唯讀查詢。
3. 由 Naki 頁面取得的雀魂當前資源索引，再下載並機械解析的資源。
4. 可重查的 runtime log。沒有這四類證據的項目一律標成「未驗證」。

## 目前結論

| 問題 | 現況 |
|------|------|
| 雀魂客戶端 | Unity WebGL `chs_t-WebGL-release-4.0.45(45)`，不是 Laya |
| Naki 狀態來源 | WebSocket → Liqi protobuf → Swift 狀態；不是 JS 遊戲物件 |
| Naki 動作來源 | Swift 組 Liqi request，再由 `window.__nakiWebSocket.sendRaw` 送出 |
| AI package | 本機目前 resolve 到 MortalSwift `0.5.0`，revision `802dc3d…` |
| AI 權重 | 仍是既有 bundled Mortal v4 四麻權重；0.5.0 並不是新訓練模型 |
| 「最新最強」 | **不能這樣宣稱**。0.5.0 是當日最新公開 package tag，但權重未更新，也沒有牌力 benchmark |
| 四麻 | 唯一有正確模型形狀與 parity 證據的模式 |
| 三麻 | 沒有三麻模型；目前仍把三麻狀態送進四麻模型，不應宣稱支援 |
| 自摸保護 | resolver 純邏輯已存在且單測通過，但整合仍有漏觸發與錯誤完成兩個漏洞 |
| 遊戲內高亮 | 現行 WebGL hook 會執行；尚未證明每次都染到正確牌／按鈕 |
| MCP | live `tools/list` 為 42 個；6 個 MCP 高亮工具仍只是明確失敗的相容樁 |

## 現場唯讀查詢

2026-08-01 以正在執行的 Naki 查到：

- `GET /status`：Debug／MCP server 正在 `127.0.0.1:8765` 運行。
- `GET /bot/status`、`GET /bot/ops`、`GET /game/state`、`GET /game/hand`、`GET /game/ops`：都可從 Naki 的 Swift 協定層取得資料。
- `POST /js` 唯讀 probe：頁面為 `https://game.maj-soul.com/1/`，`unity-canvas` 存在；`Laya`、`view.DesktopMgr`、`uiscript` 不存在。
- loader、framework、wasm、data 都來自 `chs_t-WebGL-release-4.0.45(45)`。
- `unityInstance` 是 script-scope 的裸識別字；`window.unityInstance` 不存在。
- `window.__nakiWebSocket` 與 `window.__nakiHighlight` 存在；highlighter 的 `tinted` counter 持續增加。
- live `POST /mcp` 的 `tools/list` 回傳 42 個工具。

這些 probe 是讀取狀態，不會送遊戲動作。最後重查時，running Naki 的 `/help` 已回 version 3.1 與 42 tools；這只證明部署中的 help／registry 版本，因為架構段落本身是程式內的靜態字串。Unity 客戶端由 `/js` probe 證明，Liqi 動作由 source 與實際 trace 證明；任何一項都不能替尚未走到的自摸、失敗重試或視覺流程背書。running build 未附可識別 commit，因此 source help／Debug 首頁的未提交後續調整仍視為 working-tree candidate。

### 查詢的資料語意

`/game/*` 與 `/bot/*` 不是每次向雀魂伺服器重新抓完整狀態。它們攤開的是 Naki 自 WebSocket 事件累積的 Swift 狀態：

```text
WebSocket frame
  → LiqiParser
  → MajsoulBridge
  → NativeBotController / LiqiOperationStore
  → Debug API / MCP / SwiftUI
```

若 Naki 中途加入、漏掉事件或尚未完成 sync，回傳可能不完整。這時應先診斷 `bot_status`、`game_ops` 與 log；`bot_sync` 會強制重連，屬會改變 runtime 的操作，不是唯讀查詢。

## 兩條平台路徑並不等價

`WebViewModelFactory` 目前按 OS 版本分流：

| 平台路徑 | View model | 自動打牌現況 |
|----------|------------|--------------|
| macOS 26+／iOS 26+ | `WebViewModel`（WebPage） | 有 `AutoPlayDecisionResolver`、oplist 合法性與 stale snapshot 檢查 |
| iOS 17–25 | `LegacyWebViewModel`（WKWebView） | 走同一個 resolver 與 stale 檢查；差別是 send 失敗不重試 |

macOS deployment target 是 26.0，所以 macOS 實際只走新路徑；iOS deployment target 是 17.0，仍會走 Legacy 路徑。決策層現在一致，但 Legacy 沒有 live 驗證（本機跑不到），不可宣稱兩條路徑等價。

## Unity WebGL 可控面

### 存在

- DOM 與單一 `<canvas id="unity-canvas">`
- WebSocket constructor／`send`
- WebGL2 context 與 draw calls
- 頁面載入的 Unity resource URLs
- script-scope `unityInstance`
- Naki 注入的 `__nakiWebSocket`、`__nakiHighlight` 等物件

### 不存在

- `window.Laya`
- `window.GameMgr`
- `window.uiscript`
- `window.view.DesktopMgr`
- `window.cfg`
- `window.app.NetAgent`

因此不可再用 DOM tile、Laya sprite、`DesktopMgr.Inst.oplist`、座標點擊或 `uiscript` 控制遊戲。JS 仍可做 WebSocket、WebGL、resource 與頁面層 probe；「JS 全部失效」同樣是不正確的說法。

## WebSocket 與 Liqi

### 注入順序

`WebSocketInterceptor.jsModules` 目前依序注入：

1. `naki-core.js`
2. `naki-websocket.js`

順序有意義：`naki-websocket.js` 取用 `naki-core.js` 的 base64／`sendToSwift`。

`naki-autoplay.js`、`naki-game-api.js`、`naki-coordinator.js` 已於 2026-08-02 整檔刪除（合計約 2,900 行）。它們的每一條路徑都經過 `Laya` / `GameMgr` / `app.NetAgent` / `view.DesktopMgr` / `uiscript`，在 Unity 客戶端一律不存在，所以只會靜默失敗；注入腳本是 `forMainFrameOnly: false`，每個 iframe 都要 parse 一次，留著只有成本。同批移除的還有 `naki-core.js` 的 `__nakiAntiIdle`（改由 Swift 定期送 `.lq.Lobby.heatbeat`）、`__nakiEmojiAutoReply`，以及 `naki-websocket.js` 的 `interceptConsole`（零呼叫者）。

現存的 JS 全域面只有四個：`__nakiCore`（base64／`sendToSwift`）、`__nakiWebSocket`（連線清單／`sendRaw`／`forceReconnect`）、`__nakiHideNames`（authGame 暱稱等長覆寫）、`__nakiHighlight`（WebGL draw hook）。任何 `window.naki`、`NakiCoordinator`、`__nakiGameAPI`、`__nakiAutoPlay`、`__nakiRecommendHighlight`、`__nakiPlayerNames`、`__nakiDoraHook`、`__nakiAntiIdle`、`__nakiEmojiAutoReply` 都已不存在，probe 到的一定是 `undefined`。

### Envelope

```text
[type: 1 byte][msgId: 2 bytes little-endian][protobuf envelope]
```

- type `1`：NOTIFY
- type `2`：REQUEST
- type `3`：RESPONSE
- envelope field 1：method name
- envelope field 2：payload
- Naki 自送 request 使用 `60000+` msgId，避免與遊戲低位遞增 id 衝突

一般 `.lq.ActionPrototype` 收包會做 Liqi XOR decode；`syncGame`／`enterGame` response 內的 restore actions 已是 payload，不應再 XOR。

協定欄位的唯一 schema 來源是 [`docs/protocol/liqi.json`](protocol/liqi.json)。2026-08-01 由 Naki live resource manifest 取得的 CDN 檔與 repo 版本 byte-for-byte 相同，SHA-256 都是：

```text
f2955c3d10cf2d42bee9309f672c062540941ea0cffe1bd62e3f436c7afc404c
```

### 連線選擇

- `.lq.FastTest.*` 對局 request 必須走 OPEN 的 `/game-gateway`。
- 大廳 request 走 OPEN 的 `/gateway`。
- 不能假設第一條 connection 就是正確連線，也不能寫死連線數。
- 選錯線常見結果是 code 6／method not found。

`sendRaw` 成功只表示資料交給瀏覽器 WebSocket；不等於雀魂接受。嚴格成功條件應包含同 msgId RESPONSE，對終局動作最好再看到 `ActionHule` 或後續權威狀態。

## Oplist 與動作

`OptionalOperationList` 是 server 提供的可用操作權威。Naki 將它存成帶 sequence、seat、source、context tile 的 snapshot。

目前 enum：

| type | 程式語意 | runtime 狀態 |
|------|----------|--------------|
| 1 | discard | 已有大量成功紀錄 |
| 2 | chi | 尚缺實際組合選擇驗收 |
| 3 | pon | 已見 `inputChiPengGang` → `ActionChiPengGang` |
| 4 | ankan | 未驗證 |
| 5 | minkan | 未驗證 |
| 6 | kakan | 未驗證 |
| 7 | riichi | 已有送出紀錄；完整 failure-path 仍未覆蓋 |
| 8 | tsumo | protocol 送出曾成功；「AI 想打牌時由 resolver 強制自摸」尚未端到端驗證 |
| 9 | ron | 已見 `inputOperation` payload `0809` → RESPONSE → `ActionHule` |
| 10 | kyushu | 未驗證 |
| 11 | babei | 三麻模型本身不支援，未驗證 |

赤五 chi／pon、多個 chi variant 的 combination index，以及三種槓都不可寫成已驗證。

## 自動打牌決策

### Resolver 已做的事

OS 26+ 主路徑的 `AutoPlayDecisionResolver`：

- 沒有 snapshot 時 fail closed。
- snapshot seat 不符時不動作。
- snapshot 有自摸或榮和時，和牌凌駕 AI 推薦。
- 其他 AI 推薦必須存在於同一份 oplist。
- 送出前再比 sequence、seat、source、context tile，拒絕 stale decision。
- recommend mode 只呈現，off mode 不送。

純 resolver 13 個專項測試與 NakiTests 75 個測試已通過。這證明純函式、encoding 與 builder，不等於 WebViewModel 整合或 live server 已驗證。

### 為什麼現在仍可能「能自摸卻不自摸」

現行整合還有兩個 P0 漏洞：

1. **resolver 的入口仍被 recommendations gate 擋住。** `WebViewModel` 只有在 Mortal 產生非空推薦時才進自動動作；timer 在推薦空時只處理副露 pass。若 server oplist 有 type 8，但 Mortal 回空，resolver 根本不會被呼叫。
2. **hora 送出失敗仍會被當成已完成。** 外層呼叫送出後，只看 resolved action 是 `.hora` 就 log 成功並 `markHandled`；它沒有取得 `LiqiSendResult`。沒有 game-gateway、JS send 失敗或 server 拒絕時，機會仍可能被吃掉而不重試。

Legacy iOS 17–25 的第三個漏洞（完全沒走 resolver）已修，見 AUDIT §15.2；剩下的差異是 send 失敗不重試。

同一種「先消化、後確認」問題也出現在其他 failure path：空推薦的副露 pass 在 send 前就 `markHandled`；打牌牌字串轉換失敗或立直找不到捨牌時，也會在沒有 request 的情況下標記 snapshot。這些不直接解釋漏自摸，但會讓重試與 rollback 語意不可靠。

另有一條手動工具風險：MCP／HTTP `game_action` 使用 `action=hora` 且沒有 oplist snapshot 時，
`NakiGameAction` 目前會 fallback 成 tsumo，而不是 fail closed。這不是自動 resolver 路徑，但同樣應改成缺權威資料就拒絕。

Mode 也有一個 current 語意差距：`.off` 能阻止自動 sender，但 AI 仍在背景推論，
RecommendationView 與 `syncGameHighlight()` 沒有讀 `showRecommendation`，所以側欄／遊戲內高亮仍可能更新。「關閉 = AI 不算也不顯示」不是目前程式事實。

### 正確調整方向

優先順序應是：

1. **由新 oplist 驅動決策。** snapshot 一到就先檢查 `horaOperation`；不應等待 AI recommendation。
2. **讓送出回傳結果。** `executeAutoPlayAction` 回傳 `LiqiSendResult`；只有確認 WebSocket send 成功，最好再確認同 msgId RESPONSE／權威 action 後，才 `markHandled`。
3. **失敗保留 pending 並重試。** 加上 bounded retry、sequence guard 與清楚 log；不能把「函式被呼叫」當成功。
4. ~~把 Legacy 收斂到同一個 resolver／sender。~~ 已完成（AUDIT §15.2），但未 live 驗證。
5. **加整合與 live 驗收。** 至少覆蓋：`[discard,riichi,tsumo] + AI discard`、空推薦 + tsumo、send failure、server reject、stale snapshot、recommend/off 絕不送。

## MortalSwift 與模型

### 真正的版本狀態

Xcode package requirement 是 `upToNextMinorVersion`、minimum `0.5.0`，即允許 `[0.5.0, 0.6.0)`，不是 exact pin。本機 `Package.resolved` 目前是：

```text
MortalSwift 0.5.0
revision 802dc3d030da6573094d413e18af34e776eb091d
```

2026-08-01 直接查[官方 MortalSwift remote](https://github.com/Sunalamye/MortalSwift) tags，最高 tag 是 `v0.5.0`，其 dereferenced
commit 正是 `802dc3d…`。所以 Naki 目前解析到最新公開 package tag；這仍不代表模型權重最新或最強。

但 `Package.resolved` 被 `.gitignore` 排除，新 clone 不保證固定在同一 revision。若要求可重現，應把 resolved lockfile 納入版本控制或改成 exact dependency。

### 0.5.0 驗證了什麼

MortalSwift test target 用 libriichi v4 當 oracle。兩套固定 MJAI 劇本會把每個需要決策的 snapshot 同時餵給兩邊，逐格比對：

- observation：固定 `1012 × 34`
- action mask：46 actions
- `knownUnportedChannels`：目前為空
- Debug 與 Release 各 47 tests：通過，測試輸出為 observation mismatch 0、mask parity pass

這只證明內建劇本所覆蓋的 snapshots 一致，不是所有牌局狀態的形式證明。

### 為什麼不能叫「最新最強模型」

- MortalSwift 0.5.0 更新的是 encoder、和牌／期望值相關邏輯與 parity，不是重新訓練權重。
- bundled `mortal.mlmodelc` 在 0.3.0、0.4.0、0.5.0 的 blobs 相同。
- Naki 沒有千局級牌力、順位、和率、放銃率或相對基準 benchmark。
- 現有 obvious-discard sanity test 不能代表實戰強度。

所以能說的是：「Naki 目前使用已完成這批 encoder parity 修正的 MortalSwift 0.5.0」；不能說「模型已升成最新最強」。

### 三麻

Naki 雖有 `is3P` 狀態與 UI 警示，`NativeBotController` 最後仍建立同一個 `MortalBot(version: 4, useBundledModel: true)`。目前沒有 sanma constructor、775×34 encoder 或專用權重。三麻推薦在結構上未驗證，不應用於品質判斷。

## Unity 遊戲內高亮

現行高亮不是 Laya material，也不是螢幕座標推算。`naki-core.js` 攔截 WebGL2 `drawElements`：

1. 只看 `count === 6` 的 quad draw。
2. 從 `_MainTex_ST` UV 解出牌種與牌號。
3. 若牌名在 Swift 傳入的 target set，暫時覆寫 `_Tint` 或 `_Color`。
4. draw 完立即還原 uniform。

Swift 由 `WebViewModel.syncGameHighlight()` 呼叫 `window.__nakiHighlight.set(...)`／`clear()`。
目前工作樹會把第一推薦牌設為綠色，並把其餘手牌 identity 以帶 alpha 的灰色調淡；
`naki-core.js` 也把字牌 UV 索引改為 `round(u × 10)`。這兩項是 current source candidate，尚未完成 screenshot／實戰視覺驗收。

live `state()` 的 tinted counter 持續增加，能證明 hook 與染色分支有執行；不能證明視覺命中正確。現有限制：

- target 以牌名為 key，同名牌會一起染。
- 只攔 WebGL2 `drawElements` 與特定 quad signature。
- 同 UV 的非手牌 draw 可能誤染。
- popup／動作按鈕用頻率 heuristic，不是穩定 identity。
- 帶 alpha 的「其餘手牌調淡」與字牌 UV 修正仍是未提交、未做視覺回歸的工作樹變更。
- 沒有 JS 自動測試或 screenshot-based 驗收。

MCP 的 6 個 `highlight_*` 工具是另一條舊 API，目前仍固定回 unavailable；這不代表 Naki 內建自動 WebGL 高亮不存在。

## 客戶端資源與配置表

live Naki 取得：

```text
version.json                    0.11.252.w
res/proto/liqi.json prefix      v0.11.243.w
res/proto/config.proto prefix   v0.10.1.w
res/config/lqc.lqbin prefix     v0.11.252.w
```

正確 URL 公式是：

```text
/1/<prefix>/<path>
```

`prefix` 已含前導 `v`，不可再補一個 `v`。

2026-08-01 依這份 live manifest fresh download 並用 repo 工具解析：

| 資源 | bytes | SHA-256 |
|------|------:|---------|
| `config.proto` | 855 | `7291c02850e0eebd913a585e123355fad04f06d44c2c5388a923328ba4d07873` |
| `lqc.lqbin` | 17,483,020 | `a5959513fa31d3b5297d2dda400c86c0eacbdb4adad461b583439d7f673c9086` |

解析結果仍是 41 tables、263 sheets、119,289 rows。詳細 current-only 表格見 [majsoul-config-tables.md](majsoul-config-tables.md)。

## Debug／MCP 現況

Debug server 只綁 loopback，HTTP 與 MCP 共用 port 8765。live registry 為 42 個工具：

| 類別 | 數量 |
|------|-----:|
| 系統 | 4 |
| Bot | 7 |
| 遊戲狀態／動作 | 6 |
| JavaScript | 1 |
| 大廳 | 8 |
| 防閒置 | 1 |
| 友人房 | 7 |
| 表情 | 2 |
| 高亮相容失敗樁 | 6 |

`detect`、`explore`、座標 click／calibrate、`ui_names_*`、`lobby_navigate` 等舊工具不存在。完整列表見 [mcp-server-guide.md](mcp-server-guide.md)。

## 目前已知風險

| 優先級 | 風險 | 驗證狀態 |
|--------|------|----------|
| P0 | tsumo snapshot 可能因推薦空而沒進 resolver | source code 已確認；尚缺 live failure fixture |
| P0 | hora send 失敗仍被 mark handled | source code 已確認；尚缺 live failure fixture |
| 已處理 | Legacy iOS 已接上 resolver（AUDIT §15.2） | source 已確認；未 live 驗證 |
| P1 | 手動 `game_action(hora)` 無 snapshot 時會猜 tsumo | source code 已確認；應改 fail closed |
| P1 | off mode 仍可能顯示推薦／高亮 | source code 已確認；sender mode gate 仍有效 |
| P1 | pass／無效 discard／riichi failure path 會過早 mark handled | source code 已確認；尚缺 failure-path integration tests |
| P1 | 三麻使用四麻模型 | source code 已確認 |
| P1 | Package.resolved 未納入版本控制 | git ignore 與 project 設定已確認 |
| 已處理 | 3 組無效設定已從 UI 移除；隱藏玩家名稱改以協定層重做（AUDIT §15.3） | source 已確認；協定層改寫只有合成 frame 測試，未 live 驗證 |
| P1 | WebGL highlighter 可能誤染／重複染 | hook 執行已確認；視覺正確性未驗證 |
| P2 | Liqi generic protobuf tag 只讀一 byte，field > 31 會錯 | source code 已確認 |
| P2 | AI 實戰強度未知 | 沒有 benchmark，未驗證 |

## 驗收邊界

已驗證：

- Unity 客戶端、canvas、Laya 缺席、WebSocket 與 WebGL hook 的 live 存在性。
- live Debug API 與 42-tool MCP registry。
- 當前 `liqi.json` 與 live CDN 相同。
- 當前 config 資源 fresh download／hash／解析統計。
- MortalSwift parity fixtures 與 Naki resolver／builder 單元測試。
- runtime 榮和、碰與一般 discard／pass 的協定鏈。

未驗證：

- 使用者回報的核心情境：server 有 tsumo、AI 想 discard 時，最新版整合能否每次成功 override 並收到 `ActionHule`。
- 空 recommendation + tsumo。
- send failure／server reject／中斷後 retry 與 cleanup。
- Legacy iOS 實機完整對局。
- chi variants、赤五 combination、三種槓。
- WebGL 高亮是否視覺上每次命中正確牌與正確動作按鈕。
- AI 相對其他模型或版本的實戰強度。
