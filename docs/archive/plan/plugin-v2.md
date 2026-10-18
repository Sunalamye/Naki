# 插件系統 v2：插件自帶設定頁（A）＋ 本機解鎖類封包原語（B）

**資料日期**：2026-10-14
**狀態**：設計已提議，未拍板。2026-10-14 追加 §12 插件自由度盤點（方向：讓插件更自由）。A 與 B 的 `rewriteSend` 有 spike（分支 `plugin-v2-design`，基於 main `0ef66df`，未 commit）；變長 receive `replace`、`drop`、`injectReceive` 只有設計與 probe 腳本，**未實作**。
**決策紀錄**：`docs/archive/notes/plugin-v2-implementation-notes.md`（含 Deviations）。
**上位文件**：`docs/plugin-api-v1.md`（現行契約）、`docs/plugin-system-design.md`（設計與拍板）。三者衝突時以 `plugin-system-design.md` §11 的拍板為準，本文件不推翻任何拍板。

---

## 0. 引用的既有決策（mempal 查證，wing `naki`）

設計前查了三題，命中都指向 `plugin-system-design.md`：

| 查詢 | 命中 | 對本文件的約束 |
|---|---|---|
| 插件 設定 Phase 2 拍板 | §11 #11：「§7.10(a) 插件設定 schema 進 v1，排 Phase 2」；§7.10(a)：值存 `SettingsStore`，key `plugin.<id>.<key>`，型別只有 string／number／boolean | A 只換「誰畫 UI」，不換值的存放處與型別 |
| Phase 4 probe | §11 #6：「先做 probe（§7.5 三項），probe 綠了再決定實作與否。probe 不通過 ⇒ v1 永遠只支援等長」；§7.5：2026-08-10 只在 dummy `EventTarget` 綠 | 變長 receive `replace`、receive `drop`、`injectReceive` 共用同一套機制，**全部卡在這個 gate** |
| rewriteSend task #5 | §11 #1：Phase 3「做」，前置 task #5（injectSend 回應通道＋送出側協定怪癖入契約）；§7.7b 驗收末條：「只有 `rewriteSend` 這種不需回應的能先上」 | `rewriteSend` 不依賴回應通道，可以先做；L3 總開關（預設 false）照舊把關 |

另外沿用：§9 授權線（Naki 不得內置 MajsoulMax 任何規則表、id 對照、設定預設值；範例插件必須原創）、§8.2 禁改名單、§11 #4（Naki 的 Swift pipeline 看插件改過的封包）、`design-review-2026-10-12-decisions.md` U4（授權防誤用不防惡意，只改文件不加防護）。

---

## 1. 目標

- **A. 插件自帶設定頁**：插件在 manifest 宣告一個 HTML 檔，Naki 在插件頁該插件的詳情內用 WebView 載入。值仍存在 Naki 這側（`plugin.<id>.<key>`），型別仍只有 String／Double／Bool；頁面 JS 只能經一條 bridge 讀寫。沒宣告的插件維持現在的 schema 自動渲染。設定頁跑在 Naki 自己的 WebView，與遊戲頁完全隔離，碰不到封包與遊戲頁。
- **B. 讓「本機解鎖」類插件寫得出來**：補齊 MajsoulMax `plugin/mod.py` 用到的四種封包原語。
  1. receive 方向變長 `replace()`（整包重編 RESPONSE／NOTIFY）
  2. `drop()`（receive 與 send；例：drop `NotifyAccountUpdate`）
  3. `rewriteSend`（例：把 `changeCharacterSkin` 等 REQUEST 改成 `loginBeat`）
  4. `injectReceive`（向客戶端注入合成 NOTIFY；例：自造 `NotifyAccountUpdate`）

Naki 只提供原語。任何角色 id、皮膚 id、規則表都不進 Naki（§9.4）。

**整體方向（2026-10-14 用戶追加）**：讓插件更自由。逐條盤點現行契約對插件的限制，見 §12。授權線（`plugin-system-design.md` §9）與 Phase 4 live gate（`plugin-system-design.md` §11 #6）不變。

---

## 2. 模組邊界

| 模組 | A 的責任 | B 的責任 |
|---|---|---|
| `PluginRegistry.swift` | manifest 多 `settingsUI`；驗字元集、副檔名、必須同時宣告 `settings`；載入時驗檔案是插件目錄的直接子項（解掉 symlink 後）且是一般檔案 | 不變（capability 字串由 JS 端解讀） |
| `Services/Web/PluginSettingsHost.swift`（新；放 `Services/Web/` 是因為 `PlatformDivergenceTests.testWebViewImplementationsLiveOnlyInWebSessionLayer` 規定 `WKWebView(` 只准在這一層建立） | `PluginSettingsBridge.reply`（純函式：驗 key 與型別，讀寫經呼叫端注入的 closure）；`PluginSettingsWebView`（WKWebView 容器、導覽限制、message handler） | 無 |
| `PluginsPageView.swift` | 有 `settingsUI` 就載入設定頁，否則照舊 schema 渲染 | 無 |
| `NakiRuntime.setPluginSetting` | 不變；bridge 的寫入走它（存值，已啟用的插件熱重載） | 無 |
| `SettingsStore` | 不變（`pluginSettingValue`／`setPluginSettingValue`／`pluginSettingOverrides`） | `pluginsMayModifyOutbound` 不變，B 的 L3 原語都受它把關 |
| `naki-plugins.js` | 無 | 鏈式派發、capability 閘、禁改名單、每個原語的合規檢查；`dispatch` 回傳最終 bytes 或「丟棄」 |
| `naki-websocket.js` | 無 | 依 `dispatch` 結果決定送出什麼（send）、交給遊戲什麼（receive）、交給 Swift 什麼 |
| `LiqiParser`／`MajsoulBridge`／`AutoPlay*`／`LiqiActionSender` | 不碰 | **不碰**。B 只決定「Swift 收到哪一份 bytes」，不改 Swift 端解析 |

---

## 3. A：插件自帶設定頁

### 3.1 manifest

```json
{
  "settingsUI": "settings.html",
  "settings": {
    "note":    { "type": "string",  "default": "hello" },
    "repeat":  { "type": "number",  "default": 1 },
    "enabled": { "type": "boolean", "default": true }
  }
}
```

- `settingsUI`：選用。單一檔名，字元集同 `id`（`PluginRegistry.isSafeName`），必須以 `.html` 結尾，不接受子目錄。
- 宣告 `settingsUI` 就**必須**宣告非空的 `settings`。理由：bridge 只接受 schema 宣告過的 key 與型別，沒有 schema 就沒有型別可驗。
- 檔案必須在插件目錄內：解掉 symlink 後仍是插件目錄的直接子項，且是一般檔案（不是目錄）。
- 任何一條不合 ⇒ `manifestInvalid`，**整個插件不載入**（沿用 v1「沒有部分載入」）。
- **URL 匯入與更新**：三種來源都抓 `settingsUI` 檔；`PluginImportSource.finalize` 在宣告了 `settingsUI` 卻缺檔時直接拒絕，所以缺檔的更新包**不會**進到 `install`，可用的舊版不會被替換（審查第 2 條，spike 已修，`testImportFinalizeRequiresSettingsPageBeforeInstall`）。

### 3.2 資料流

```
設定頁 JS
  window.naki.get(key?) / window.naki.set(key, value)      ← WKUserScript（atDocumentStart、main frame only）注入的 shim
    → webkit.messageHandlers.nakiSettings.postMessage({op, key, value})   回傳 Promise
      → PluginSettingsWebView.Coordinator（WKScriptMessageHandlerWithReply，只收 main frame 且該文件就是 manifest 指定的設定頁）
        → PluginSettingsBridge.reply(body, schema, read, write)
            get：PluginSettingField.accept(read(key)) ?? default；省略 key 回全部
            set：key 必須在 schema、值型別必須相符（number 必須有限值）→ write(key, value) → 回 true
            其他：回錯誤碼（bad_message／unknown_op／unknown_key／type_mismatch），JS 端 Promise reject
        → write = naki.actions.setPluginSetting(id, key, value)
            → NakiRuntime.setPluginSetting → SettingsStore.setPluginSettingValue（`plugin.<id>.<key>`）
            → 插件已啟用才熱重載（setPluginEnabled(id, true) → 遊戲頁 disable＋setGrant＋重跑插件源碼）
```

- 遊戲頁的插件仍只經 `ctx.settings`（唯讀快照）讀值。設定頁與遊戲頁之間**沒有**直接通道，唯一交會點是 `SettingsStore`。
- JS 的 boolean 與 number 到 Swift 都是 `NSNumber`，bridge 用 `CFBoolean` 型別 ID 分辨，所以 `set('repeat', true)` 會被拒，不會變成 1。
- **讀值規則只有一份**：`PluginSettingField.accept` 同時用於設定頁 bridge 與遊戲頁 grant（`PluginRegistry.grantDict`）。儲存值型別不符（例如 manifest 更新後改了型別）或非有限值，兩端都退回 default，不會一端給 default、另一端把錯型別交給插件（審查第 10 條，spike 已修，`testGrantAndBridgeAgreeOnStaleOverrides`）。儲存值不刪除，使用者下次寫入才覆蓋。
- **插件更新後重建設定頁**：View 以 `PluginDescriptor.settingsPageIdentity`（id、版本、設定頁檔的修改時間與大小、schema 的 key 與型別）當身分；任一變了就拆掉舊 WebView（同時移除 message handler）再載入新頁，舊頁面不會繼續對新 schema 寫入（審查第 8 條，spike 已修，`testSettingsPageIdentityChangesWithVersionPageOrSchema`）。舊頁在拆除前已送出的 `set` 是同步處理完才回覆的，不會留下半套寫入；拆除後才送出的訊息沒有 handler 可收。WebKit 實際行為以 App 內手測為準（未驗證）。

### 3.3 WebView 選擇與隔離

- **用 `WKWebView`，不用 `WebPage`**。iOS target 是 17，`WebPage` 只在 26+；`WKScriptMessageHandlerWithReply` 在兩個平台都可用，所以一條路徑涵蓋 macOS 26 與 iOS 17–26，不需要 `#available` 分支。遊戲頁那套 `WebSessionBackend` 的分歧（`WebSession.init` 的唯一 `#available`）不受影響。
- 隔離手段：
  - 獨立 `WKWebViewConfiguration`，`websiteDataStore = .nonPersistent()`：與遊戲頁不共用 cookie、`localStorage`、`indexedDB`。
  - 不注入任何 Naki 模組：頁面上沒有 `__nakiPlugins`、`__nakiWebSocket`、`__nakiCore`（端到端單測鎖住）。
  - `loadFileURL(_:allowingReadAccessTo: 插件目錄)`：頁面只能讀自己插件目錄內的檔案。
  - 導覽限制：主框架只能停在 manifest 指定的設定頁；iframe 只能載入插件目錄內的 file URL；外站與其他文件的主框架導覽一律取消。沒有 `uiDelegate`，`window.open` 不會開新視窗。
  - message handler 只回應「主框架且文件 URL 就是 manifest 指定的設定頁」。同目錄的其他 HTML 可以當 iframe 載入，但拿不到 bridge（審查第 13 條，spike 已修，端到端單測驗了主框架導覽到同目錄其他文件與外站都被取消）。
- **不是安全邊界**（U4）：設定頁是插件作者寫的，與插件 JS 同一個信任等級。隔離的目的是「設定頁碰不到封包與遊戲頁」，不是「防惡意設定頁」。設定頁的 subresource（`<img src="https://…">`、`fetch`）**沒有擋**，這是刻意的：依 U4 插件在遊戲頁本來就能發網路請求，設定頁也可能需要遠端選項資料。全面封鎖（`WKContentRuleList`）是可選的產品政策，**不是** PV2-A 的必做項（審查第 13 條）。

### 3.4 A 的不變條件

1. 設定值只存在 `SettingsStore`，key `plugin.<id>.<key>`，型別只有 String／Double／Bool（PV2-A 加 `json`，見 §12.4）。設定頁不得有第二個存放處（data store 是非持久的，關掉就清）。
2. bridge 只接受 schema 宣告的 key；值型別必須與 schema 相符；number 必須是有限值（NaN／Inf 會讓組 grant 時 `JSONSerialization` 丟 ObjC 例外，見 `PluginRegistry.grantDict` 註解）。
3. 設定頁 WebView 與遊戲頁 WebView 不共用 configuration、data store、content world；設定頁上不存在任何 Naki 全域。
4. 沒宣告 `settingsUI` 的插件，UI 與行為與 main 完全相同。

---

## 4. B：封包原語

### 4.1 現行 `handleMessage` 的順序（main `0ef66df`）

**receive**（遊戲的 `ws` 上，Naki 在建構當下 `addEventListener('message')`，排在遊戲 handler 前）：

```
Naki listener(event)
  1. attribute（選線證據，只看 send）
  2. nakiNicknameMask.observe(bytes)          ← __nakiHideNames，就地等長
  3. dispatchToPlugins → naki-plugins.dispatch ← v1：rewriteReceive 就地等長改寫
  4. sendToSwift('websocket_message', 改後 bytes) → LiqiParser
  （Naki listener 結束）
遊戲 handler(event)  ← 讀到同一份 ArrayBuffer，所以看到改後的 bytes
```

**send**（`ws.send` 被 Naki 的實例屬性包住）：

```
ws.send(data)
  1. attributeSend(原始 data)
  2. nakiNicknameMask.observe(bytes)           ← 只記 msgId→method
  3. dispatchToPlugins                         ← v1：只 observe
  4. sendToSwift(bytes) → LiqiParser.parseRequest（記 pendingRequests、學 authGame accountId 與 startUnifiedMatch 的 sid）
  5. originalSend(data)
```

### 4.2 設計後的位置與順序（四個原語）

原則（沿用 §11 #4）：**Naki 的 parser 讀到的是「這條連線兩端實際交換的那一份」**。receive 側是「遊戲實際收到的」，send 側是「伺服器實際收到的」。這讓 Naki 的狀態與畫面一致，代價是插件能污染 Naki 的狀態，所以禁改名單同時套用在所有原語上。

**send 方向**：

```
ws.send(data)
  1. attributeSend(原始 data)                       不變
  2. nakiNicknameMask.observe                       不變
  3. dispatch → 鏈上每個插件的 onSend(ctx)
       ctx.replace(newBytes)   [rewriteSend，本 spike 已實作]
       ctx.drop()              [dropSend，未實作，卡 Phase 4，見 4.5]
     回傳：undefined（沒改）｜新 Uint8Array（換掉）｜DROP（丟棄）
  4. sendToSwift(最終 bytes)     ← Swift 看「改後」；DROP 時不送（伺服器也沒收到）
  5. originalSend(最終 bytes)    ← 沒改時是原物件；DROP 時不呼叫
```

**receive 方向**（Phase 4 機制，§7.5；**未實作**）：

```
Naki listener(event)   ← 改成 capture 階段註冊（at-target 時 capture listener 先跑，見 probe (d)）
  0. if (event 是 Naki 自己合成的) return             ← WeakSet 標記；防遞迴、防重複送 Swift
  1. nakiNicknameMask.observe                         不變
  2. dispatch → 鏈上每個插件的 onReceive(ctx)
       等長就地改                    [v1 已有]
       ctx.replace(任意長度)         [rewriteReceive，未實作]
       ctx.drop()                    [dropReceive，未實作]
     回傳：undefined｜新 Uint8Array｜DROP
  3a. undefined：sendToSwift(就地改後 bytes)；不攔 event，遊戲照舊讀同一份 ArrayBuffer     ← 與 v1 相同
  3b. 新 bytes：event.stopImmediatePropagation()；sendToSwift(新 bytes)；
      ws.dispatchEvent(合成 MessageEvent{data: 新 ArrayBuffer})（先登記進 WeakSet）
  3c. DROP：event.stopImmediatePropagation()；不送 Swift
```

**injectReceive**（`ctx.injectReceive(bytes)`，capability `injectReceive`，L3；2026-10-18 已實作，與 `respondLocally` 一起，決策見 `inject-receive-design-2026-10-18.md`，契約以 `docs/plugin-api-v1.md` 為準）：

```
  1. 驗：parseEnvelope 完整、type === 1（NOTIFY）、method 存在且不在禁改名單、不是 .lq.ActionPrototype
  2. sendToSwift('websocket_message', {direction:'receive', data: bytes})   ← 先讓 LiqiParser 看到
  3. 合成 MessageEvent 登記進 WeakSet，ws.dispatchEvent(...)                  ← 再交給遊戲；Naki listener 第 0 步略過它
  4. 不派發給任何插件的改寫鏈（它是插件自己造的）；宣告 observeNakiTraffic 的 observer 可以看到，isNaki = true
```

目標連線：預設是呼叫當下 ctx 的那條 socket；`.lq.Notify*` 大廳類走大廳連線，對局類走 game-gateway。沒有開著的對應連線 ⇒ 回 `{ok:false, reason:'no_connection'}`。

**injectReceive 必須先送 Swift 再 dispatch 的理由**：如果只 dispatch 而 Naki listener 又略過合成 event，LiqiParser 永遠看不到這則 NOTIFY，Naki 與遊戲狀態分叉，而且畫面上看不出來。如果不略過合成 event，同一機制下 3b 的合成 event 會被 Swift 收兩次。所以合成 event 一律略過，Swift 那份由產生者顯式送。

### 4.3 send drop 的形狀：drop 必須附帶本地回應

客戶端送出的都是 REQUEST，遊戲會等同 msgId 的 RESPONSE。單純不送 ⇒ 遊戲卡在「以為送出去了」（`plugin-api-v1.md` §4 已寫）。所以 send 側不提供裸 `drop()`，改為：

- `ctx.respondLocally(responseBytes)`：丟棄這筆 REQUEST，並以 `injectReceive` 的同一套機制把一筆合成 RESPONSE（type 3、同 msgId）交給遊戲與 Swift。
- 它依賴 receive 側的合成 event 機制，所以**同樣卡 Phase 4 gate**。

**Swift 的配對來源（審查第 7 條）**：`LiqiParser.parseResponse` 只靠 `pendingRequests[msgId]` 對回 method，對不上就走 unmatched（記 fault、不解析）。所以被丟棄的 REQUEST **仍要送 Swift**，順序如下：

```
ws.send(data)  → dispatch 回 RESPOND(responseBytes)
  1. sendToSwift({direction:'send', data: 原 REQUEST})   ← LiqiParser.parseRequest 登記 pendingRequests[msgId]
  2. 不呼叫 originalSend（伺服器沒收到）
  3. ws.send 回傳後才排程（setTimeout 0）：
       sendToSwift({direction:'receive', data: responseBytes})   ← parseResponse 用 1 的登記對回並清除
       合成 MessageEvent 登記進 WeakSet → ws.dispatchEvent       ← 遊戲收到；Naki listener 略過
```

- 第 3 步延到 `ws.send` 回傳之後：遊戲可能在 `send` 回傳後才登記自己的回應等待，同步回應有被遊戲丟掉的風險（推測，PV2-B2 live 驗收項）。
- **學習副作用**：Swift 看到一筆伺服器其實沒收到的 REQUEST。`LiqiParser.parseRequest` 對送出方向有三種副作用：登記 `pendingRequests`（本來就要）、`startUnifiedMatch` 學 sid（`ObservedMatchSids.record`）、`cancelUnifiedMatch`／`cancelMatch` 取消等待（`ObservedMatchSids.cancelAwaitingGameKind`，不論誰送）。後兩者若被本地回應觸發就是錯的狀態。因此 `respondLocally` 的禁用名單＝送出禁改名單（§4.4，已含 `startUnifiedMatch`、`matchGame`、全部 `.lq.FastTest.*`、登入類）**再加** `cancelUnifiedMatch`、`cancelMatch`。`parseInnerMessage` 對其餘 REQUEST／RESPONSE 只解析不寫狀態（登入類 RESPONSE 會解 account_id，但登入類已禁）；`LiqiResponseStore` 只收 Naki 登記過的 msgId，遊戲的 msgId 不進去。
- 結論：在上述禁用名單下「不改 Swift parser」成立。PV2-B2 要加一條契約測試：`LiqiParser` 中送出方向有副作用的 method 常數，必須全部出現在 JS 的 `respondLocally` 禁用名單裡（Swift 端日後新增學習點時會被擋下）。
- 在 gate 通過前，MajsoulMax 的「改成 `loginBeat`」寫法用 `rewriteSend` 就能做到：伺服器回的是 `loginBeat` 的 RESPONSE，遊戲以原 msgId 收到回應。遊戲是否把那筆回應當成原 method 的成功（以及是否需要再改寫 RESPONSE），**未驗證**。

### 4.4 `rewriteSend` 的規則（spike 已實作）

- capability `rewriteSend`（L3）。`ctx.replace` 只在 send 方向、非 isNaki、`rewriteSend` 已授權、改前 method 不在送出禁改名單時才存在。
- 每次呼叫時檢查總開關 `window.__nakiPluginsMayModifyOutbound`，關著 ⇒ 回 `false`、什麼都不改。
- 長度可以變，method 可以換（MajsoulMax 的用法需要換 method）。
- 換上的 bytes 必須：逐欄位走完 envelope 沒有越界（`isWellFormed`；`parseEnvelope` 對截斷的 fixed32／fixed64 會誤報 `complete`，不能只靠它，審查第 1 條）、field 1（method）非空、type 仍是 REQUEST、msgId 不變、改後 method 不在送出禁改名單。不合 ⇒ 回 `false`，計一次 `replace` 失敗。
- **送出禁改名單保障的範圍**（審查第 6 條，已收窄承諾並補齊名單）：只保障兩件事——(1) Swift 從遊戲自己的送出學東西的來源：全部 `.lq.FastTest.*`（method 不是 `.lq.Lobby.` 開頭的一律禁）、`startUnifiedMatch`、`matchGame`；(2) 帳號登入／session／憑證／付費操作，依 `docs/protocol/liqi.json` 的 Lobby 方法盤點：`login`、`oauth2Login`、`emailLogin`、`fastLogin`、`prepareLogin`、`dmmPreLogin`、`loginSuccess`、`logout`、`oauth2Auth`、`oauth2Check`、`oauth2Signup`、`signup`、`fetchOauth2Info`、`bindAccount`、`bindEmail`、`bindOauth2`、`bindPhoneNumber`、`unbindPhoneNumber`、`createPhoneLoginBind`、`fetchPhoneLoginBind`、`createEmailVerifyCode`、`createPhoneVerifyCode`、`modifyPassword`、`deleteAccount`、`cancelDeleteAccount`、`yostarDeleteAccount`、`fetchOBToken`、`generateAnnualReportToken`、`generateContestManagerLoginCode`、`gameMasterCommand`、`verifyMyCardOrder`、`verifySteamOrder`、`cancelGooglePlayOrder`。**其餘大廳寫入（含匹配、付費以外的帳號外觀變更）不在保障內**，只靠 L3 總開關與「只用測試帳號」。改前、改後兩側都查；`rewriteAllow` **解不開**送出側。`liqi.json` 已知過期，新登入方法出現時名單要跟著補。
- 鏈：換 buffer 後，後續插件拿到新 bytes 與重新解析的 payload 範圍；method 換了就停止派發（後續插件是照舊 method 的白名單選進鏈的）。
- fail-open（審查第 5 條）：每個 hook 執行前快照 bytes；hook 拋錯 ⇒ 撤回它這次的**全部**改動，包括整包替換、等長 `replace` 與直接改 `ctx.bytes` 的就地改寫，send 與 receive 兩個方向都適用。成本是每個 hook 一次 bytes 複製（Blob 路徑 `mutable:false` 不複製）。
- Swift 收到的是換後的 bytes（與伺服器一致），所以 `LiqiParser.pendingRequests` 記的是換後的 method，RESPONSE 會以換後的 method 解析。**插件看到的 RESPONSE `ctx.method` 也是實際送出的 method**（`naki-plugins.js` 在替換成功後更新自己的 msgId→method 表，審查第 4 條）。插件若需要原本的 method，要自己在 `onSend` 記下；契約不提供第二個欄位，避免插件拿錯型別解碼。
- `attributeSend`（選線證據）仍看原始 data：遊戲確實在那條線上送了請求，證據成立；換成 `loginBeat` 後本來也不算證據。

### 4.5 不變條件（B）

1. **isNaki 流量永不給 rewrite／drop／respondLocally**：Naki 自送（`sendRaw` 登記表）與插件號段 64000–65500 的封包，鏈上不掛任何改寫函式（單測：sendRaw 與 64002 兩條）。
2. **禁改名單同時適用於所有原語**：receive 側 `.lq.ActionPrototype`、`.lq.FastTest.syncGame`、`.lq.NotifyGameEndResult`（以及 `authGame` 非 players／robots 欄位）不得被變長改寫、drop、或由 `injectReceive` 產生；`rewriteAllow` 只能解開 receive 側等長與變長改寫，**不能**解開 drop 與 injectReceive。send 側見 4.4。
3. **合成封包不得是 `.lq.ActionPrototype`**，且 `injectReceive` 只能是 NOTIFY（type 1）；合成 RESPONSE 只能經 `respondLocally`、且 msgId 必須是被丟棄的那筆 REQUEST。
4. **`injectReceive` 的合成 NOTIFY 必須讓 LiqiParser 也看到**，且只看到一次（4.2 的順序）。
5. **改寫後的 bytes 必須能被 Naki 既有 parser 重讀**（`plugin-api-v1.md` §4：容忍欄位重排、預設值省略、repeated 轉 packed）；NOTIFY／REQUEST 的 field 1（method）不得省略。JS 端以 `isWellFormed` 嚴格檢查 **envelope 層**（每個欄位都在界內、method 非空）。**payload 內層**（field 2 裡的業務 message）JS 端不驗：那是插件的責任，PV2-C 的編碼器是建議的產生方式。
6. **零插件時行為與 main 完全相同**：send 把原物件交給 `originalSend`（單測鎖住物件同一性）；receive 不攔 event。
7. L3 原語（`rewriteSend`、`dropSend`／`respondLocally`、`injectReceive`）一律受 `pluginsMayModifyOutbound` 把關，關著回 `false` 或 `{ok:false, reason:'outbound_disabled'}`。

---

## 5. 取捨

| 選擇 | 採用 | 放棄的方案與理由 |
|---|---|---|
| 設定頁的 WebView | `WKWebView`，兩平台一條路徑 | `WebPage`：iOS 17–25 沒有，要兩條路徑；遊戲頁那套分歧是因為自動打牌需要 `WebPage`，設定頁沒有這個需求 |
| bridge 形狀 | `get`／`set` 兩個函式、Promise 回傳 | 事件訂閱（設定值變更推給頁面）：設定頁同時只有一個，自己 `get` 即可；推送要多一條通道 |
| bridge 驗證放哪 | Swift 純函式 `PluginSettingsBridge.reply` | 放 JS shim：頁面可改寫 shim，驗證等於沒驗 |
| settingsUI 檔不存在 | 整個插件不載入 | 只隱藏設定頁：與 v1「沒有部分載入」不一致 |
| send 側換 method | 允許，但前後兩個 method 都要過禁改名單 | 不允許：MajsoulMax 的核心用法（改成 `loginBeat`）做不出來 |
| send drop | 不提供裸 drop，提供 `respondLocally` | 裸 drop：遊戲一定卡住，沒有正當用途 |
| receive 變長的機制 | capture + `stopImmediatePropagation` + 合成 `MessageEvent` | 改寫 `ws.onmessage`／`addEventListener` 讓遊戲 handler 經 Naki 轉手：要攔所有註冊路徑，且 Naki 自己的 listener 排序更難保證 |
| 合成 event 是否給 Naki listener 處理 | 一律略過，Swift 那份由產生者顯式送 | 給 Naki listener 處理：3b 會讓 Swift 收兩次 |

---

## 6. 明確不做

- 不內置任何 MajsoulMax 規則、id 對照、設定預設值；範例插件只示範原語（§9）。
- 不在 Phase 4 probe 綠之前實作變長 receive `replace`、receive `drop`、`injectReceive`、`respondLocally`（§11 #6）。
- 設定頁不提供「讀遊戲狀態」「送封包」「讀其他插件設定」任何 API。
- 不做設定頁的 `WKContentRuleList` 網路封鎖（本輪；見 §8）。
- 不改 `LiqiParser`、`MajsoulBridge`、`AutoPlay*`、`LiqiActionSender`。
- `rewriteAllow` 不擴及 send 側、drop、injectReceive。
- 不做 `onInjectResponse` 逾時（`timedOut`）——那是 task #5 的尾巴，與本包無依賴。

---

## 7. 驗證分級

| 項目 | 分級 | 證據 |
|---|---|---|
| `settingsUI` manifest 驗證（字元集、`.html`、需 `settings`） | 已驗證（單測） | `PluginSettingsUITests.testSettingsUIAcceptsSingleHtmlFileName`、`testSettingsUIRejectsUnsafeOrNonHtmlNames`、`testSettingsUIRequiresSettingsSchema` |
| 檔案必須在插件目錄內（缺檔、symlink 外逃、是目錄） | 已驗證（單測＋變異） | `testMissingSettingsPageRejectsWholePlugin`、`testSettingsPageSymlinkLeavingPluginDirectoryIsRejected`、`testSettingsPageThatIsADirectoryIsRejected`；變異 S1 |
| bridge 寫入後 `pluginSettingOverrides` 讀得回 | 已驗證（單測） | `testBridgeWriteIsReadBackThroughSettingsStoreOverrides` |
| bridge 拒絕未宣告 key、錯型別、NaN／Inf | 已驗證（單測＋變異） | `testBridgeRejectsUndeclaredKeysWrongTypesAndNonFiniteNumbers`；變異 S2 |
| 設定頁 WebView 端到端（真 WKWebView、頁面上無 Naki 全域、set 經 handler 落地、錯型別 reject） | 已驗證（單測，macOS test host） | `testSettingsPageBridgeEndToEndInIsolatedWebView` |
| 插件頁實際顯示設定頁、版面、熱重載後遊戲頁插件拿到新值 | **未驗證**（沒有啟動 App 手測；沒有 UI 快照） | — |
| iOS 17–25 上設定頁 | **未驗證**（只編譯過 `Naki-M` iOS Simulator） | build log |
| 導覽限制：主框架導覽到同目錄其他文件與外站都被取消 | 已驗證（端到端單測＋變異 R13） | `testSettingsPageBridgeEndToEndInIsolatedWebView` |
| iframe 載入同目錄文件時拿不到 bridge（`not_settings_page`） | **未驗證**（沒有 iframe 測試；只有原始碼判讀） | — |
| 匯入／更新缺 `settingsUI` 檔時在 `finalize` 就被拒、不進 `install` | 已驗證（單測＋變異 R2） | `testImportFinalizeRequiresSettingsPageBeforeInstall` |
| grant 與 bridge 對錯型別儲存值的解讀一致 | 已驗證（單測＋變異 R10） | `testGrantAndBridgeAgreeOnStaleOverrides` |
| 插件更新後設定頁身分改變（觸發重建） | 已驗證身分值（單測＋變異 R8）；SwiftUI 實際重建 WebView **未驗證** | `testSettingsPageIdentityChangesWithVersionPageOrSchema` |
| `rewriteSend` 鏈、閘、禁改名單、零插件物件同一性、isNaki 不給 | 已驗證（node 單測＋變異） | `scripts/plugin-v2-regression.cjs` 第一輪 15 條；JS 變異 M1–M10 全被抓 |
| 審查第二輪：截斷 fixed32／fixed64 與空 method 被拒、換 method 後 RESPONSE 的 `ctx.method`、hook 拋錯完整還原（receive／send、等長 replace／就地改）、登入／session 名單兩側 | 已驗證（node 單測＋變異 R1／R4／R5／R6） | `plugin-v2-regression.cjs` 第 16–21 條；`round2-mutation-js.log` |
| Phase 4 probe 腳本的判讀邏輯 | 已驗證（三種假 dispatcher × 兩種註冊寫法）；**不是 live 證據** | `round2-probe-dry-run.log` |
| `rewriteSend` 在雀魂伺服器上的效果（改成 `loginBeat` 後遊戲是否當成功） | **需 live**（測試帳號） | — |
| 變長 receive `replace`、`drop`、`injectReceive`、`respondLocally` | **未實作**；機制**需 live probe**（§9） | — |
| §12 納入項：`json` 設定型別、`onSettingsChanged`、`onSocketClose`、`__nakiProto` | **未實作**（只有設計；本 spike 不含） | — |
| §12.5 的現況描述（改設定＝停用再重跑源碼，契約 §6 漂移） | 已讀原始碼確認（`NakiRuntime.setPluginSetting`→`setPluginEnabled`→`hotApplyPlugin`→`PluginRegistry.enableScript`）；未在 App 內實測 | — |

---

## 8. 已知風險

1. ~~URL 匯入不帶 `settingsUI` 檔~~ **已修（審查第 2 條）**：HTTPS 與 GitHub 來源都抓 `settingsUI`；`finalize` 在缺檔時拒絕，缺檔的更新包不會替換可用的舊版。GitHub 來源抓不到設定頁時同樣由 `finalize` 擋下，該插件不列入匯入結果。
2. **設定頁可以發網路請求**：subresource 與 `fetch` 沒擋，刻意的（§3.3）。全面封鎖是可選產品政策，不是 PV2-A 必做項。
3. **`rewriteSend` 換 method 後 RESPONSE 的形狀**：伺服器回的是新 method 的 Res 型別；遊戲以原 method 的 Res 型別解它。兩者都是 `ResCommon` 時沒事，其他組合遊戲端行為**未驗證**。這是插件作者的責任，但契約要寫明。
4. **`parseEnvelope`（naki-core）對截斷的 fixed32／fixed64 仍會回 `complete: true`**。`rewriteSend` 已改用 `naki-plugins.js` 自己的 `isWellFormed` 嚴格檢查，不再受影響（審查第 1 條）。`parseEnvelope` 其他呼叫端（暱稱遮罩、派發前的解析）只讀不寫，維持既有行為；`naki-core.js` 不在本包可改範圍，修 core 留給 PV2-B1 一併處理（要同步更新 `plugin-regression.cjs` 的 envelope corpus 測試）。
5. **send 包裝的接線改動**：`ws.send` 改成 `originalSend(handleMessage(...) || data)`。Naki 自送也經過這裡；isNaki 永遠拿不到 `replace`，所以 `handleMessage` 回 undefined、送原物件（單測鎖住）。這屬 CLAUDE.md「修改 WebSocket bridge **前**先確認」，spike 是先改後報，程序偏離由主線處理（審查第 12 條）。
6. Phase 4 機制若 probe (d) 顯示 WebKit at-target 不是 capture 優先，Naki listener 改 capture 也不保證排在遊戲之前；屆時要回頭看 4.2 的順序假設。

---

## 9. Phase 4 live probe

### 9.1 要回答的問題

§7.5 的三項，加一項實作需要的事實：

- **(a)** 在雀魂**真的 game-gateway 連線**上，`stopImmediatePropagation` 擋得住遊戲自己的 message handler。
- **(b)** 遊戲吃得下合成 `MessageEvent`（`isTrusted === false`、`data` 是新 ArrayBuffer）：handler 收到、不拋錯、之後連線與對局照常。
- **(c)** 遊戲用 `ws.onmessage = fn` 或 `addEventListener` 哪一種註冊，兩種寫法都被 probe 的攔截涵蓋。
- **(d)**（資訊）WebKit 在 at-target 階段，capture listener 是否先於「較早註冊的非 capture listener」執行。這決定 Phase 4 的 Naki listener 改 capture 後是否必然排第一。

### 9.2 設計

- 只能在 **game-gateway 連線建立之前**安裝（對局連線在進場時才 `new WebSocket`）。大廳連線在頁面載入時就建好，probe 不涵蓋。
- probe 包一層 `window.WebSocket` 建構子：建構期間註冊的 listener 標為 `naki`；建構之後才註冊的標為 `game:*`。
- **攔截器的註冊時點**：遊戲第一次對該連線註冊 message handler（`addEventListener` 或 `onmessage` setter）時，才以 capture 註冊攔截器。因此攔截器一定**晚於** Naki 的非 capture listener 註冊，(d) 量到的正是「後註冊的 capture 是否超前先註冊的非 capture」。攔截器之後緊接著註冊兩個 probe 自己的 handler：一個走 `addEventListener`、一個走 `onmessage`（遊戲之後若自己設 `onmessage`，會取代 probe 的那個，該路徑改由遊戲 handler 代表）。
- **逐 handler 紀錄**：每個 message 事件第一次被任何 handler 看到時給一個序號；合成事件在 dispatch 前就登記「它代替的是哪個序號」。每個 handler（Naki、攔截器、遊戲、probe）各自記錄它看到的目標事件序號與原／合成。所以排在攔截器**之前**執行的 handler 若收到原事件，也會被記到（第一版只在攔截器裡記 `original`，記不到這種情況）。
- **保留 listener 語意**：同一個 fn 只包一次（DOM 對重複註冊去重的語意不變）；`removeEventListener(fn)` 會換成移除包裝後的 fn；`onmessage` getter 回傳遊戲當初設的 fn。
- 攔截器只動**第一筆**命中目標 method 的封包：`stopImmediatePropagation()`，再 `dispatchEvent` 一個內容相同的合成 `MessageEvent`。內容相同，所以就算 (b) 失敗，遊戲最多少收一筆無害訊息。
- 目標 method：`.lq.NotifyGameBroadcast`（對局表情廣播）或 `.lq.FastTest.checkNetworkDelay` 的 RESPONSE。不得改成 `.lq.ActionPrototype`、`authGame`、`syncGame`、`enterGame`、`NotifyGameEndResult` 或任何禁改名單內的 method。
- 依 at-target 順序不同，Naki 可能收到同一則兩次（原始＋合成），或只收到合成：目標 method 對 Naki 的牌局狀態無影響（表情會在 `game_emoji_listen` 出現兩筆）。
- probe 腳本本身的自我驗證：在三種假 dispatcher（capture 先跑、照註冊順序、`stopImmediatePropagation` 無效）× 兩種遊戲註冊寫法上跑過，判讀分別為「(a)(b)(c) 綠、(d) 真」「(a)(b)(c) 綠、(d) 假、Naki 收到原事件被計入」「(a)(c) 紅」，並斷言 `removeEventListener` 與 `onmessage` getter 語意（`round2-probe-dry-run.log`）。**這只證明腳本判讀正確，不是 live 證據。**

### 9.3 腳本

**步驟 1：安裝**（大廳、尚未進場時執行）。`POST http://127.0.0.1:8765/js`，body 是 function body：

```js
if (window.__nakiP4) return JSON.stringify({ already: true });
var TARGETS = ['.lq.NotifyGameBroadcast', '.lq.FastTest.checkNetworkDelay'];
var P = window.__nakiP4 = { installedAt: Date.now(), sockets: [] };
var parse = window.__nakiCore.parseEnvelope;
var proto = WebSocket.prototype;
var origAdd = proto.addEventListener, origRemove = proto.removeEventListener;
var onmsg = Object.getOwnPropertyDescriptor(proto, 'onmessage');
var NakiWS = window.WebSocket;
var constructing = false;
var seqs = new WeakMap(), synthetic = new WeakMap(), originals = new WeakMap(), states = new WeakMap();
var nextSeq = 1, tick = 0;
window.WebSocket = function (url, protocols) {
  constructing = true;
  try { return protocols === undefined ? new NakiWS(url) : new NakiWS(url, protocols); }
  finally { constructing = false; }
};
window.WebSocket.prototype = NakiWS.prototype;
['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (k) { window.WebSocket[k] = NakiWS[k]; });

function state(ws) {
  var s = states.get(ws);
  if (s) return s;
  s = { url: ws.url, ws: ws, pending: new Map(), wrappers: new Map(), handlers: [], armed: false,
        targetSeq: null, syntheticSeq: null, dispatchedAt: null, gameVia: { addEventListener: 0, onmessage: 0 },
        errors: [], methods: {} };
  states.set(ws, s); P.sockets.push(s);
  var send = ws.send;
  ws.send = function (d) {
    try {
      var b = d instanceof ArrayBuffer ? new Uint8Array(d) : (ArrayBuffer.isView(d) ? new Uint8Array(d.buffer, d.byteOffset, d.byteLength) : null);
      var env = b && parse(b);
      if (env && env.type === 2 && env.method) s.pending.set(env.msgId, env.method);
    } catch (e) {}
    return send.apply(this, arguments);
  };
  return s;
}
// 事件第一次被任何 handler 看到時給序號與 method；合成事件在 dispatch 前就登記
function info(s, e) {
  var i = seqs.get(e);
  if (i) return i;
  var method = null;
  if (e.data instanceof ArrayBuffer) {
    var env = parse(new Uint8Array(e.data));
    method = env && (env.type === 3 ? s.pending.get(env.msgId) : env.method);
  }
  i = { seq: nextSeq++, method: method || null };
  if (method && !synthetic.has(e)) s.methods[method] = (s.methods[method] || 0) + 1;
  seqs.set(e, i);
  return i;
}
function record(s, name, path, e) {
  var i = info(s, e);
  if (TARGETS.indexOf(i.method) === -1) return;
  var h = s.handlers.find(function (x) { return x.name === name; });
  if (!h) { h = { name: name, path: path, log: [] }; s.handlers.push(h); }
  h.log.push({ seq: i.seq, synthetic: synthetic.has(e), forSeq: synthetic.get(e) || originals.get(e) || i.seq, tick: ++tick });
}
function wrap(ws, fn, name, path) {
  var s = state(ws);
  var w = s.wrappers.get(fn);
  if (w) return w;
  w = function (e) {
    record(s, name, path, e);
    try { return fn.apply(this, arguments); }
    catch (err) { if (name.indexOf('game') === 0) s.errors.push(String(err && err.message || err)); throw err; }
  };
  w.__probeOriginal = fn;
  s.wrappers.set(fn, w);
  return w;
}
// 遊戲第一次註冊 message handler 時才加攔截器（capture），所以它一定在 Naki listener 之後註冊
function arm(ws) {
  var s = state(ws);
  if (s.armed) return;
  s.armed = true;
  origAdd.call(ws, 'message', function (e) {
    var i = info(s, e);
    record(s, 'interceptor', 'capture', e);
    if (synthetic.has(e) || s.targetSeq !== null || TARGETS.indexOf(i.method) === -1) return;
    s.targetSeq = i.seq;
    originals.set(e, i.seq);
    e.stopImmediatePropagation();
    var ev = new MessageEvent('message', { data: e.data.slice(0) });
    synthetic.set(ev, i.seq);
    s.dispatchedAt = Date.now();
    ws.dispatchEvent(ev);
  }, true);
  origAdd.call(ws, 'message', wrap(ws, function () {}, 'probe:addEventListener', 'addEventListener'));
  if (!onmsg.get.call(ws)) onmsg.set.call(ws, wrap(ws, function () {}, 'probe:onmessage', 'onmessage'));
}
proto.addEventListener = function (type, fn, opts) {
  if (type === 'message' && typeof fn === 'function' && this instanceof NakiWS) {
    if (constructing) return origAdd.call(this, type, wrap(this, fn, 'naki', 'addEventListener'), opts);
    arm(this);
    state(this).gameVia.addEventListener++;
    return origAdd.call(this, type, wrap(this, fn, 'game:addEventListener#' + state(this).gameVia.addEventListener, 'addEventListener'), opts);
  }
  return origAdd.apply(this, arguments);
};
proto.removeEventListener = function (type, fn, opts) {
  var s = this instanceof NakiWS && states.get(this);
  var w = s && type === 'message' && s.wrappers.get(fn);
  return origRemove.call(this, type, w || fn, opts);
};
Object.defineProperty(proto, 'onmessage', {
  configurable: true, enumerable: onmsg.enumerable,
  get: function () { var w = onmsg.get.call(this); return (w && w.__probeOriginal) || w; },
  set: function (fn) {
    if (typeof fn === 'function' && this instanceof NakiWS && !constructing) {
      arm(this);
      state(this).gameVia.onmessage++;
      fn = wrap(this, fn, 'game:onmessage', 'onmessage');
    }
    onmsg.set.call(this, fn);
  }
});
return JSON.stringify({ installed: true, targets: TARGETS });
```

**步驟 2：觸發**：進入對局（人機或友人房，測試帳號）。在對局中用 Naki MCP `game_emoji`（`.lq.FastTest.broadcastInGame`）送一個表情，讓伺服器回 `.lq.NotifyGameBroadcast`（推測自己也會收到廣播，**未驗證**；收不到就等 `checkNetworkDelay`）。

**步驟 3：讀結果**（送出表情後立刻一次、60 秒後再一次）：

```js
var P = window.__nakiP4;
if (!P) return JSON.stringify({ installed: false });
return JSON.stringify(P.sockets.map(function (s) {
  var t = s.targetSeq;
  var hs = s.handlers.map(function (h) {
    var orig = h.log.filter(function (x) { return !x.synthetic && x.seq === t; });
    var syn = h.log.filter(function (x) { return x.synthetic && x.forSeq === t; });
    return { name: h.name, path: h.path, sawTargetOriginal: orig.length > 0, syntheticCount: syn.length,
             active: h.log.some(function (x) { return x.seq >= t; }),
             firstTick: (orig.concat(syn)[0] || {}).tick || null };
  });
  // 只看目標事件發生時仍掛著的 handler（之後才移除的遊戲 handler 不算）
  var after = hs.filter(function (h) { return h.active && h.name !== 'naki' && h.name !== 'interceptor'; });
  var game = after.filter(function (h) { return h.name.indexOf('game:') === 0; });
  var pathOk = function (p) {
    var list = after.filter(function (h) { return h.path === p; });
    return list.length > 0 && list.every(function (h) { return !h.sawTargetOriginal && h.syntheticCount === 1; });
  };
  var naki = hs.find(function (h) { return h.name === 'naki'; }) || {};
  return {
    url: s.url, readyState: s.ws.readyState, target: t, sinceDispatchMs: s.dispatchedAt ? Date.now() - s.dispatchedAt : null,
    gameVia: s.gameVia, errors: s.errors, handlers: hs,
    verdict: {
      a_blocked: t !== null && game.length > 0 && game.every(function (h) { return !h.sawTargetOriginal; }),
      b_auto: t !== null && game.length > 0 && game.every(function (h) { return h.syntheticCount === 1; }) && s.errors.length === 0 && s.ws.readyState === 1,
      c_addEventListener: t !== null && pathOk('addEventListener'),
      c_onmessage: t !== null && pathOk('onmessage'),
      d_laterCaptureOvertakes: t === null ? null : !naki.sawTargetOriginal
    },
    methods: Object.keys(s.methods).sort(function (a, b) { return s.methods[b] - s.methods[a]; })
      .slice(0, 15).map(function (m) { return [m, s.methods[m]]; })
  };
}));
```

同時記錄 `curl http://127.0.0.1:8765/game/state` 兩次（送表情前後與 60 秒後）。

**步驟 4：清除**：對局結束回大廳後重新載入頁面（不得在對局中 reload）。

### 9.4 判準（只看 game-gateway 那條，`url` 含 `game-gateway`）

步驟 3 的 `verdict` 由腳本直接算出；(b) 另有兩項人工條件。

| 項 | 綠的條件 |
|---|---|
| (a) | `verdict.a_blocked === true`：`target` 不是 null，且目標事件發生時仍掛著的每個 `game:*` handler 都沒有收到被攔下的原事件 |
| (b) | `verdict.b_auto === true`（每個 `game:*` handler 恰好收到一次合成事件、沒有拋錯、連線仍 OPEN），**且**人工確認：60 秒後再讀一次仍 `readyState === 1`、`methods` 計數持續增加、`/game/state` 照常前進（巡目或分數有變）、畫面上表情正常顯示 |
| (c) | `verdict.c_addEventListener === true` **且** `verdict.c_onmessage === true`：兩種註冊路徑各至少一個在攔截器之後註冊的 handler（遊戲的或 probe 的），沒收到原事件、恰好收到一次合成事件。**任一路徑沒有資料或為 false 都是紅，沒有「部分」** |
| (d) | 資訊項，記錄 `verdict.d_laterCaptureOvertakes`：true ＝ WebKit at-target 讓後註冊的 capture 先跑（Naki 只收到合成事件）；false ＝ 照註冊順序（Naki 收到原事件）。Phase 4 的 Naki listener 改 capture 後是否必然排第一，以這個值為準（§8-6） |

(a)(b)(c) 三項全綠才可依 `plugin-system-design.md` §11 #6 開工 Phase 4。任一項紅：receive 側維持等長，`drop`、`injectReceive`、`respondLocally` 不做。

### 9.5 誰來跑

主線或用戶，在**測試帳號**、有 live 對局的 session 上跑。本工作包沒有測試帳號與對局，**未執行**。log 建議放 `.swfd/logs/plugin-v2-probe/`（三次 `/js` 回應原文＋兩次 `/game/state`）。

### 9.6 live 結果（2026-10-17）

結論：第二輪（heartbeat 目標）**(a)(b)(c) 綠，(d) 為 true**。只有一次命中、一種 method 的樣本，見下方限制。第一輪（規格原目標）四項都未驗證。

**第一輪：規格原目標，未命中**

- probe 在大廳、進場前安裝，`room_quick_test` 四人南人機房＋`bot_sync` 進場，約 9 分鐘打到有人被飛終局。
- game-gateway 全場收到 `.lq.ActionPrototype` 693、`inputOperation` 87、`.lq.Route.heartbeat` 31，`.lq.FastTest.checkNetworkDelay` 0 筆。現行 Unity 客戶端不送 checkNetworkDelay，改以 `.lq.Route.heartbeat` 保活。`NotifyGameBroadcast` 要送表情，沒有授權送。
- 攔截器沒有觸發，四項無從判讀。對局照常。證據 `03-probe-1..10.json`、`03-probe-11-final.json`。

**第二輪：目標加上 game-gateway 的 heartbeat RESPONSE**

| 項 | 結果 | 依據（`r2-03-probe-1.json`，命中後 12 秒） |
|---|---|---|
| (a) | 綠 | `a_blocked: true`。唯一的遊戲 handler `game:onmessage` 沒收到原事件 |
| (b) | 綠 | `b_auto: true`，遊戲 handler 恰收到一次合成事件、無拋錯。人工條件見下 |
| (c) | 綠 | `c_onmessage` 與 `c_addEventListener` 皆 true。遊戲每條連線只用 `onmessage` 註冊 1 次，`addEventListener` 路徑只由 probe 自己的 handler 代表 |
| (d) | true | 攔截器（後註冊的 capture）tick 17 先看到原事件；Naki 的非 capture listener（較早註冊）只在 tick 19 看到合成事件 |

- **命中的 method**：`.lq.Route.heartbeat` RESPONSE，game-gateway 上第一筆（序號 18），進場後約 15 秒內。
- **(b) 的人工條件**：命中後 57、87、117 秒各讀一次（`r2-04-after-{1,2,3}.json`），連線都是 OPEN、無拋錯；game-gateway 訊息持續增加（ActionPrototype 77→125→165，heartbeat 4→6→8）；`/game/state` 從東1局前進到東2局、分數變動（`r2-04-game-state-*.json`）；截圖 `r2-04-after-hit.png` 顯示正常打牌。§9.4 的「畫面上表情正常顯示」不適用，因為目標不是表情。
- **對局是否照常**：照常。自動打牌持續有 `inputOperation` 與 RESPONSE，game-gateway 只有一條、沒有重連。Naki log 自 03:55 起只有 `bot_sync` 預期內的強制重連，沒有 error／fault（`r2-04-naki-log-grep.txt`）。約 2 分鐘後 `game_vote_game_end` 被伺服器受理（`r2-05-vote-end.json`），對局關閉，重載頁面回大廳，`__nakiP4` 已不存在。
- **限制**：每條連線只攔一筆，樣本數 1。heartbeat 回應不帶牌局資料；遊戲對 `ActionPrototype` 等牌局訊息是否同樣吃合成事件，本次沒有直接證據，只能由「同一個 `onmessage` handler 不看 `isTrusted`」推論。
- **原始資料**：`.swfd/logs/phase4-probe-live/`。第二輪是 `r2-*`，腳本差異在 `r2-script.diff`，遮罩後的 Naki log 在 `naki-all.log`。

**Deviations**

- 對 §9.2：現行客戶端不送 checkNetworkDelay，probe 目標加上 game-gateway 的 `.lq.Route.heartbeat` RESPONSE（主線裁決）。heartbeat 不在禁止清單，內容不變重新 dispatch。
- 對「只改 TARGETS」：heartbeat 在每條連線上都有，而 `bot_sync` 會讓大廳連線在 probe 安裝後重建並被掛上。為了只動 game-gateway，攔截器多加一個條件：連線 URL 不含 `game-gateway` 就不攔。大廳連線因此沒有被攔（`target` 為 null）。
- 節號：工作包要求 9.4，但 9.4 已是「判準」，改用 9.6。

---

## 10. 工作包切分與順序

| 包 | 內容 | 前置 | 風險 |
|---|---|---|---|
| **PV2-A** 設定頁 | spike 補完：App 內手測（macOS）與 iOS 模擬器手測；iframe 拿不到 bridge 的測試；`plugin-api-v1.md` §1／§6 補 `settingsUI` 與 `window.naki`。**加入 §12 一項**：設定 `json` 型別（§12.2 #5，規則見 §12.4）。spike 已含：匯入補抓 `settingsUI`（審查第 2 條）、共用讀值規則（第 10 條）、設定頁身分重建（第 8 條）、bridge 只授權 manifest 頁（第 13 條） | 無 | 低：不碰封包、不碰遊戲頁 |
| **PV2-B1** `rewriteSend`＋JS hook | spike 補完：`plugin-api-v1.md` §3／§4／§5 改契約（送出禁改名單的保障範圍、換 method 規則、RESPONSE `ctx.method` 語意、鏈停止條件、hook 拋錯全還原）；UI 對 `rewriteSend` 插件顯示 L3 警語；`naki-core.js` 的 `parseEnvelope` 修 fixed32／fixed64 越界並更新 corpus 測試；**live 測試帳號驗一次**（改寫一個無害的大廳請求，要有同 msgId RESPONSE）。**加入 §12 兩項**：`onSocketClose`（§12.2 #11）、設定熱更新 `onSettingsChanged`（§12.2 #7，JS 與 `NakiRuntime.setPluginSetting` 一起，規則見 §12.5） | **修改 bridge 前**取得主線確認（CLAUDE.md；spike 已先改，程序偏離由主線處理，審查第 12 條）；task #5 已滿足「不需回應的先上」 | 中：動送出路徑，但 isNaki 與零插件路徑有單測鎖住 |
| **PV2-C** protobuf 編解碼 API | §12.3：bundled `liqi.json` 驅動的 `window.__nakiProto`；資料保真契約與往返 fixture（§12.3 列的六類）；與 Swift 端解析結果對照的 fixture；manifest 加 `"protobuf": true` 才注入 | 無（不卡 Phase 4）；`liqi.json` 打包進 App 需主線確認 | 中：第二份協定解讀，`liqi.json` 本身過期（CLAUDE.md） |
| **PV2-B2** Phase 4 | 變長 receive `replace`、receive `drop`、`injectReceive`、`respondLocally`（含 §4.3 的 Swift 配對順序與契約測試）；Naki listener 改 capture 與合成 event 略過；canonical proto3 三種變形 fixture；`replay-check.sh` 零插件指紋相同；`soak-test.sh` ≥3 局 | **§9 probe (a)(b)(c) 全綠**（`plugin-system-design.md` §11 #6）；probe 結果見 §9.6 | 高：動 Naki 收封包的主路徑，做壞了 Naki 整個瞎掉 |

**檔案歸屬**（審查第 11 條：第一版寫「三包檔案不重疊」不正確，熱更新會動 `naki-plugins.js`）：

| 檔案 | PV2-A | PV2-B1 | PV2-C | PV2-B2 |
|---|---|---|---|---|
| `PluginRegistry.swift` | ✔（`json` 型別） | | ✔（`protobuf` 欄位） | |
| `PluginSettingsHost.swift`、`PluginsPageView.swift`、`SettingsStore.swift`、`PluginImportSource.swift` | ✔ | | | |
| `naki-plugins.js` | | ✔ | | ✔ |
| `naki-websocket.js` | | ✔ | | ✔ |
| `naki-core.js` | | ✔ | | |
| `NakiRuntime.swift` | | ✔（熱更新） | ✔（注入 proto 模組） | |
| 新的 proto 模組、`WebSocketInterceptor.jsModules`、`project.pbxproj` | | | ✔ | |

**建議順序**：PV2-A 與 PV2-B1 檔案不重疊，可並行。PV2-C 與 PV2-A 都改 `PluginRegistry.swift`、與 PV2-B1 都改 `NakiRuntime.swift`，排在兩者合併之後（或由同一人依序做）。合併順序 A → B1 → C。probe 由主線排進下一次有測試帳號的 live session；probe 綠且 PV2-C 合併後才開 PV2-B2（變長 `replace` 與 `injectReceive` 沒有編碼器幾乎不可用；B2 又與 B1 共用兩個 JS 檔，必須在 B1 之後）。

理由：

1. A 沒有 gate、沒有封包風險，而且完全獨立於 B；先交付使用者看得到的價值。
2. B1 不依賴 Phase 4 機制，§7.7b 已明文允許「不需回應的先上」；它單獨就能涵蓋 MajsoulMax「改成 `loginBeat`」那一類用法。
3. B2 的三個原語共用同一套未驗證機制，必須一起卡在 probe 後面；拆開做只會讓同一個主路徑改動被審兩次。
4. PV2-C 不改任何封包路徑，只是給插件一個工具；它讓 B1 的「整包重編 REQUEST」與日後 B2 的「整包重編 RESPONSE／NOTIFY」不必每個插件自帶 protobufjs。
5. 熱更新放進 PV2-B1 而不是 PV2-A：它的主體在 `naki-plugins.js`，放 A 會讓 A 與 B1 搶同一個檔案。

---

## 12. 插件自由度盤點

方向：讓插件更自由。下表逐條列出現行契約（`plugin-api-v1.md`，main `0ef66df`）限制插件的地方。「納入」指納入本次 v2 的工作包，**不是**本 spike 已實作；本 spike 只實作了 A 的設定頁與 B1 的 `rewriteSend`。授權線（§9）與 Phase 4 live gate 不因此放寬。

### 12.1 判斷標準

- **放寬的代價**分三種：(1) 動 Naki 自己的狀態來源（LiqiParser 看到的 bytes），(2) 動送出路徑（用使用者帳號對伺服器做事），(3) 只是多一個工具或通道。(3) 最便宜。
- 依 U4，Naki 的限制本來就只防誤用不防惡意；插件在遊戲頁有完整頁面權限，很多「限制」實際上插件自己繞得過。放寬這類限制的價值是**把插件本來就做得到、但要自己硬寫的事變成有契約、可稽核的 API**。

### 12.2 盤點

| # | 現行限制 | 放寬的代價 | 本次 | 不納入的理由／日後路徑 |
|---|---|---|---|---|
| 1 | receive 改寫只能等長 | (1)：動 Naki 收封包主路徑（§4.2 3b） | 納入設計（PV2-B2），**實作卡 Phase 4 gate** | gate 是 `plugin-system-design.md` §11 #6 拍板，不能推翻。probe 紅 ⇒ 永遠等長 |
| 2 | 沒有 `drop`（receive／send） | receive：(1)；send：(2)，而且裸 drop 會讓遊戲卡住 | 納入設計（PV2-B2，send 改為 `respondLocally`），**卡 gate** | 同上 |
| 3 | 沒有 `rewriteSend` | (2) | **納入**（PV2-B1，spike 已實作） | — |
| 4 | 沒有向客戶端注入（`injectReceive`） | (1)：合成封包必須也讓 LiqiParser 看到（§4.5-4） | 納入設計（PV2-B2），**卡 gate** | 同 #1 |
| 5 | 設定型別只有 string／number／boolean | (3)＋UserDefaults 體積：值會隨 grant 內嵌進每次頁面載入的注入腳本 | **納入**（PV2-A），見 §12.4 | — |
| 6 | 設定不能巢狀 | 同 #5 | **納入**，與 #5 是同一件事（`json` 型別） | — |
| 7 | 設定改動不熱更新 | (3)，但有失敗與並發語意要定（§12.5） | **納入**（PV2-B1），見 §12.5 | — |
| 8 | 沒有資源替換 hook（換貼圖、音效、asset bundle） | (1) 的變形：Naki 的 WebGL 高亮靠 `_MainTex_ST` UV 認牌，換掉牌面貼圖可能讓高亮與暱稱遮罩失效；另外 Unity 怎麼抓 asset bundle（`fetch`／XHR／有無 CRC 檢查）**未驗證** | 不納入 | 缺事實：要先 probe Unity WebGL 的資源載入路徑。插件依 U4 已能自己包 `fetch`／`XMLHttpRequest`（插件注入在 document start，見 `WebSession.setPluginInjection`），但**熱啟用**的插件注入時 Unity 早已載完。日後路徑：live probe 資源載入 → manifest 宣告 `resources: [URL 前綴]` → capability `replaceResource`（L2）→ `onResourceRequest(ctx)` 回傳替換 bytes；熱啟用時 UI 提示需重載頁面 |
| 9 | 沒有 `lqc.lqbin`（遊戲設定表）資料暴露 | (3)，但 Naki 目前**沒有**執行期解析 lqbin：`MatchModeTable` 是 2026-08-09 離線解出的 25 筆靜態表；而且 `lqc.lqbin` 在 Laya 時代的路徑（`v0.11.252.w`），Unity 客戶端是否仍讀它**未驗證**（CLAUDE.md：Unity 的 descriptor 已改放 asset bundle） | 不納入 | 缺事實，且暴露一份可能過期的表會誤導插件。PV2-C 完成後，插件可以自己 `fetch` lqbin 並用 `__nakiProto` 解 `ConfigTables`。日後路徑：先驗證 Unity 客戶端的設定來源 → 若仍是 lqbin，Naki 在執行期抓取、解析、快取並以唯讀 `window.__nakiConfig.table(name)` 提供，附來源版本 |
| 10 | Naki 側沒有可用的 protobuf 編解碼 | (3)；但多一份協定解讀，`liqi.json` 本身已知過期 | **納入**（新工作包 PV2-C），見 §12.3 | — |
| 11 | 生命週期 hook 只有 `onDisable`（`onSocketClose` 只在規格、沒有呼叫端） | (3) | **納入 `onSocketClose`**（PV2-B1，`naki-websocket.js` 的 close listener 已存在，只差派發）；`onSettingsChanged` 見 #7 | `onGameStart`／`onGameEnd` 不納入：牌局語意在 Swift 端（MJAI `start_game`／`end_game`），JS 端只有封包。日後路徑：Phase 5 的事件外送通道，或由 Swift 推一個唯讀 `window.__nakiGameState` 並呼叫 `onGameEvent` |
| 12 | `methods` 白名單必須逐一列出，沒有萬用字元 | (3)，但降低可稽核性：UI 只看到前綴，看不到實際碰了哪些 method | 不納入 | MajsoulMax 類插件要列幾十個 method，麻煩但可行。日後路徑：允許 `.lq.Lobby.*` 這類前綴，UI 顯示「本次頁面實際派發過的 method 清單」（`diagnostics` 已有 `lastMethod`，擴成計數表） |
| 13 | isNaki 流量只給宣告 `observeNakiTraffic` 的 observer，永不給改寫 | (2)：插件能改 Naki 自動打牌的動作 | 不納入 | 這是安全底線（§4.5-1），不是自由度問題 |
| 14 | 禁改名單（ActionPrototype 等） | (1) | 不擴大放寬 | 現行已可用 `rewriteAllow` 逐一解除等長改寫（`plugin-system-design.md` §11 #5 拍板）。v2 只決定它**不**擴及 drop、injectReceive、send 側（§4.5-2） |
| 15 | 插件不能自訂送往 Swift 的訊息（只有 `ctx.log`） | (3)，但 `BridgeMessageContractTests` 鎖死 bridge type | 不納入 | 沒有具體需求。日後路徑：`ctx.notify(kind, payload)` 經固定 type `plugin_event` 轉發，Swift 只顯示不解讀 |
| 16 | 沒有持久化 KV（只有 settings） | (3)；`json` 型別（#5）已涵蓋「插件自己存結構化資料」的大部分需求 | 不納入獨立 API | 插件可把狀態寫進自己的 `json` 設定（經設定頁 bridge）；遊戲頁插件寫設定需要新通道，屬 #15 的延伸 |
| 17 | Blob 訊息只能 observe | 拿到的是非同步副本，物理上改不到遊戲收到的 event | 不納入 | 實務上雀魂送 ArrayBuffer；Phase 4 機制若成立，Blob 可經同一套合成 event 改寫，屬 PV2-B2 的延伸 |
| 18 | `onInjectResponse` 沒有逾時通知（`timedOut` 恆 false） | (3) | 不納入本次 | 是 task #5 的尾巴，與自由度方向一致但與 v2 無依賴；可獨立小包補 |

（「所有插件串成一個 script，一個語法錯誤拖垮全部」是穩健度問題，不是自由度限制，不列入；修法是每插件一個 `WKUserScript` 或各自 `new Function` 包裝。）

### 12.3 #10：Naki 提供 protobuf 編解碼 JS API（納入，PV2-C）

**為什麼要**：B 的四個原語除了 drop，全都需要「整包重編」。沒有 Naki 側編解碼，每個插件要自帶 protobufjs（體積數十 KB 級，推測，未量）與一份 schema，而 schema 版本各插件不一。

**形狀**（提議）：

```js
const out = window.__nakiProto.modify('.lq.ResAccountInfo', bytes, msg => {   // 解碼 → 就地改 → 編碼，一次完成
  msg.account.nickname = 'x';
});
const msg = window.__nakiProto.decode('.lq.ResAccountInfo', bytes);           // 唯讀用途
const req = window.__nakiProto.encode('.lq.ReqLoginBeat', { contract: '' });   // 從零組新訊息
const env = window.__nakiProto.envelope.request(msgId, method, payload);       // field 1 一定寫出（§4 issue #2 的坑）
window.__nakiProto.schemaInfo  // { source: 'docs/protocol/liqi.json', sha256, knownStale: true }
```

**資料保真契約**（審查第 9 條；PV2-C 的硬性驗收，每一條都要有往返 fixture：`encode(decode(x))` 與 `modify(x, 不改)` 都必須 byte 相等，或只差 §4 的 canonical 三種變形）：

1. **未知欄位，每一層都保留**：任何巢狀深度的 message，schema 不認得的欄位號原樣保留其 tag 與 bytes，編碼時寫回。保留資料存在 Naki 內部、以解碼產生的物件身分為鍵的 `WeakMap`，**不**掛在物件屬性上。
2. **物件被替換或複製時的語意**：`modify` 是建議用法——回呼裡就地改的物件仍是解碼產生的同一個，未知欄位不會丟。插件若把某個子 message 整個換成新物件（或經 `JSON` 往返、展開運算子、`structuredClone` 複製），那一層的未知欄位會遺失；`encode` 在偵測到「這個子物件不是解碼產生的、而原位置原本有未知欄位」時**拋錯**，不靜默輸出。要刻意丟掉時呼叫 `__nakiProto.dropUnknown(obj)` 明示。
3. **已知欄位但 wire type 不符**（schema 過期、欄位改了型別）：該欄位**不解碼**，整筆當未知欄位保留，解碼結果在 `__nakiProto.anomalies(msg)` 可查；不得以錯的型別解讀後再寫回。
4. **64 位元整數**：`int64`／`uint64`／`sint64`／`fixed64`／`sfixed64` 一律解成 `BigInt`，編碼只收 `BigInt`（收到 Number 拋錯）。不使用一般 JS Number，避免超過 2^53 時靜默失真。
5. **bytes 與 string**：`bytes` 解成 `Uint8Array`；`string` 以 UTF-8 解碼，若不是合法 UTF-8 則該欄位當未知欄位保留（避免替換字元寫回）。
6. **repeated 與 packed**：保留原本的 packed／unpacked 形式；新增元素沿用同欄位原形式，從零組的訊息用 proto3 預設（packed）。enum 不認得的數值原樣保留為 Number。

**代價與對策**：

1. **`liqi.json` 已知過期**（CLAUDE.md：CDN 那份是 Laya 時代遺留，`ReqSelfOperation` 曾缺欄位）。保真契約 1–3 就是為了這件事；過期不會讓解碼靜默刪資料，只會讓更多欄位落入「未知」。
2. **第二份協定解讀**：Swift 端解析是手寫欄位號，不讀 `liqi.json`。對策：fixture 對照「JS decode 的欄位值」與「Swift `LiqiParser` 解出的值」，涵蓋 Naki 實際用到的 26 個訊息。這只驗兩份解讀一致，**不能**取代上面的保真 fixture。
3. **體積**：`liqi.json` 約 280KB。不得每次頁面載入都內嵌進注入腳本。對策：只在有啟用插件於 manifest 宣告 `"protobuf": true` 時注入，或打包成精簡格式。
4. **授權**：`liqi.json` 是雀魂的協定描述，已在 repo（`docs/protocol/`），與 MajsoulMax 無關，不越 §9。打包進 App 屬於散布範圍擴大，合併前請主線確認。
5. **canonical 變形**：encoder 必須產生 Naki parser 讀得回的形狀（`plugin-api-v1.md` §4 三種變形），fixture 逐項驗。

### 12.4 #5／#6：設定支援 `json` 型別（納入，PV2-A）

**形狀**：schema 新增第四種型別 `"json"`，`default` 可以是任何 JSON 值（object／array／純量）。

```json
"settings": { "rules": { "type": "json", "default": [], "description": "插件自己的規則表" } }
```

**解析與遷移規則**（審查第 10 條；只有一份實作：擴充 `PluginSettingField.accept`，設定頁 bridge 與遊戲頁 grant 都經它，spike 已把三種純量型別收斂到這裡）：

| 情況 | 處理 |
|---|---|
| 存法 | `json` 型別一律以 **JSON 字串**存進 `plugin.<id>.<key>`（plist 沒有 null，直接存 object 會失敗）；其餘三種型別存法不變 |
| 讀回時字串不是合法 JSON（損壞） | 視為未設定，回 default，記一行 log；儲存值不刪，使用者下次寫入才覆蓋 |
| 讀回時儲存值不是字串（manifest 更新後由純量型別改成 `json`，或反過來） | 視為未設定，回 default（同 §3.2 的純量規則）；不自動轉換，避免「`"1"` 是字串還是 JSON 數字」這類猜測 |
| 寫入：值不是合法 JSON、含非有限數字 | 拒絕，`type_mismatch` |
| 容量 | 每個插件所有 `json` 值序列化後合計上限 64KB，**三處都套用**：manifest 的 `default` 超量 ⇒ `manifestInvalid`、整個插件不載入；寫入使合計超量 ⇒ `too_large`、不寫；讀回超量（例如上限調低之後）⇒ 該值視為未設定、回 default |
| 內部結構 | Naki 不驗（不做 JSON Schema），由插件自己驗 |

**其他代價**：

1. **體積**：設定值隨 grant 內嵌進每次頁面載入的注入腳本，也進熱啟用腳本；上表的容量上限就是為此。
2. **schema 自動渲染畫不出 object**：沒宣告 `settingsUI` 的插件，`json` 欄位只顯示唯讀摘要與「還原預設」按鈕。結構化設定的編輯交給插件自己的設定頁（A）——這也是 A 與 #5 一起做的理由。
3. **§9 授權線**：MajsoulMax 類插件的規則表（角色 id、皮膚 id）正是會放進 `json` 設定的東西。這些值由使用者或插件提供，Naki 的 `default` 只來自插件 manifest，**Naki 自己不得內建任何預設內容**；範例插件的 `json` 預設必須是原創或空。

### 12.5 #7：設定改動熱更新（納入，PV2-B1）

**現況（已讀原始碼確認）**：契約 `plugin-api-v1.md` §6 寫「改設定要重載頁面才生效」，**與實作不符**。`NakiRuntime.setPluginSetting` 對已啟用插件呼叫 `setPluginEnabled(id, true)`，等於在當前頁面「`disable` → `setGrant` → 重跑插件源碼」：免重載頁面，但插件會被停用再重新註冊，執行期狀態全丟，`onDisable` 會被呼叫；而且每次都 `setPluginInjection` 重建 user script（`removeAllUserScripts` 緊接 `addUserScript` 不是原子操作：2026-09-30 審查以獨立探針在 macOS 26.0 實測，150 次載入有 4 次整頁沒有 user script；Naki 本體未實測）。設定頁每存一次就整個插件重來一次。

**提議**：

- 新增選用 hook `onSettingsChanged(ctx)`，`ctx.settings` 是新快照、`ctx.changed` 是變動的 key 陣列。
- Swift 端改設定時執行 `window.__nakiPlugins.updateSettings(id, settings, seq)`：替換 grant 的 `settings`（凍結的新物件），有 `onSettingsChanged` 就呼叫它；**沒有**就退回現行的停用再重跑（相容現有插件）。
- 下一次派發的 `ctx.settings` 自然是新值（`makeCtx` 每次從 grant 讀）。
- 頁面載入時的注入腳本照舊重建（下次載入要帶新值），但不再為了單一設定變更重跑插件源碼。
- 同時修正 `plugin-api-v1.md` §6 的漂移敘述。

**失敗與並發語意**（審查第 11 條）：

1. **權威來源只有 `SettingsStore`**。`window.naki.set` 的 Promise 在值**寫進 `SettingsStore` 後** resolve，代表「已存」，**不代表**遊戲頁已套用。遊戲頁套用是最終一致的；契約與設定頁 UI 文案都要寫明這一點。
2. **每次下發都帶完整快照**，不送差量。任何一次下發成功，遊戲頁的 grant 就與 `SettingsStore` 一致，中間掉的更新不會累積成分叉。
3. **順序**：`WebSession.fireJavaScript` 每次開一個新的 `Task`，Naki 不保證兩次 JS 依序抵達頁面。所以 Swift 端為每個插件維持遞增的 `seq`，`updateSettings` 只接受比頁面上已套用的更大的 `seq`，舊的直接丟棄（回傳 `stale`）。驗收：連續兩次更新以相反順序抵達時，頁面最後套用的是後一次。
4. **hook 拋錯**：`updateSettings` 先換 grant 再呼叫 hook。hook 拋錯 ⇒ grant 保持新值（與 `SettingsStore` 一致），插件內部狀態不可信，於是退回「停用再重跑源碼」，讓插件以新設定重新初始化；重跑也失敗就依現行規則停用並在 UI 顯示原因。不會出現「存的是新值、grant 是舊值」的狀態。hook 的失敗計數照 per-hook 規則累計。
5. **頁面不在**（reload 中、WebContent 重啟）：下發失敗只記 log；下次頁面載入的注入腳本由 `SettingsStore` 重建，自然帶最新值。
6. **驗收**：`node` 測試涵蓋 hook 成功、hook 拋錯後退回重跑、`seq` 逆序丟棄、無 hook 插件走舊路徑；Swift 單測涵蓋 `seq` 遞增與快照內容；App 內手測一次。

**代價**：比第一版估計大，但仍小。`naki-plugins.js` 一個函式、一個 hook、一個 `seq` 表；`NakiRuntime.setPluginSetting` 換一段 JS 並維護 `seq`。

## devLogSeal：devLog 尾封（2026-10-17）

插件測試紀錄的頁尾完整性無法由頁面側（localStorage）自證，需宿主見證。`__nakiPlugins.devLogSeal(pluginId, meta)` 由宿主組 `{"kind":"seal","plugin","count","meta"}` 一行，走 `devLog` 同一 `plugin_event` 管道與落檔格式；`count` 取宿主已成功交付的 `devLog` 行數，插件無法偽造。封存成功後該插件本頁 `devLog`／`devLogSeal` fail-closed。契約見 `docs/plugin-api-v1.md`，實作紀錄見 `docs/archive/notes/plugin-devlog-seal-implementation-notes.md`。
