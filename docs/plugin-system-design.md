# Naki 原生插件系統：設計方案與落地計畫

**資料日期**：2026-08-09
**狀態**：**設計草案。本文件產出過程中未修改任何程式碼、未送出任何 Liqi request、未 build 任何可送 request 的東西。**
**邊界**：本文件描述的每一項改動都尚未實作。`naki-websocket.js`、`WebSocketInterceptor.swift`、`WebSession.swift`、任何 bridge 程式碼都**原封未動**。
**適用**：CLAUDE.md「修改 WebSocket bridge、自動打牌或任何會送 Liqi request 的行為前先確認」——本文件 §10 的 Phase 3 以後全部落在這條規則內，動工前需要逐項確認。

---

## 0. 驗證分級

本文件所有承重宣稱的證據來源。**「已驗證」＝我在這次工作中親自開檔／抓取確認過**；標「未驗證」的一律不得當成事實使用。

| # | 宣稱 | 分級 | 證據 |
|---|------|------|------|
| 1 | Naki 授權是 AGPL-3.0 + Commons Clause，Licensor 為 Suoie | 已驗證 | `LICENSE:1-13`。註：該檔第 78 行自述 "This is a simplified version"，內含的不是 FSF AGPL 全文 |
| 2 | MajsoulMax 授權是 GPL-3.0 | 已驗證 | 抓取 `raw.githubusercontent.com/Avenshy/MajsoulMax/main/LICENSE`（2026-08-09）＝ GNU GPL Version 3, 29 June 2007 完整 FSF 文本。**commit pin `b3933bbaf7d847fdc0c7b4509b07f9bcb3610ab0`（committer date 2026-07-16）、674 行、sha256 前綴 `3972dc9744f6499f` 由 teammate `gpl-30-license` 以本機 clone 取證**——我抓的是同日的 `main` raw content，未自行核對 SHA |
| 2b | MajsoulMax 沒有其他授權檔；`addons.py` / `plugin/mod.py` 檔頭無授權 header | 引用 teammate，未獨立驗證 | teammate `gpl-30-license` 本機 clone 檢查。其餘檔案 headers 與 `requirements.txt` 相依（mitmproxy / protobuf 3.20.1 / requests / ruamel.yaml / loguru）各自的授權**兩邊都未驗證** |
| 2c | **MajsoulMax 的 README 自己加了一條與其 GPL-3.0 矛盾的限制** | 已驗證 | 我抓的 README 原文：「本项目仅供学习参考交流，请使用者于下载 24 小时内自行删除，**不得用于商业用途**，否则后果自负。」——這本身就是 GPL §7 意義下的 further restriction。**對方自己的授權姿態就是內部矛盾的**（LICENSE 說 GPL-3.0、README 加非商業限制），這是 arm's-length 之外沒有安全選項的加分論據 |
| 3 | GPL-3.0 §7 把「不在 (a)–(f) 之列的非許可性附加條款」定義為 further restriction | 已驗證 | 同一份 LICENSE 全文：「All other non-permissive additional terms are considered "further restrictions" within the meaning of section 10.」 |
| 4 | GPL-3.0 §10 禁止 further restriction | 已驗證 | 同上：「You may not impose any further restrictions on the exercise of the rights granted or affirmed under this License.」 |
| 4b | GPL-3.0 §13 明文允許與 AGPL-3.0 結合 | 已驗證 | 同一份 LICENSE §13「Use with the GNU Affero General Public License」：「Notwithstanding any other provision of this License, you have permission to link or combine any covered work with a work licensed under version 3 of the GNU Affero General Public License into a single combined work, and to convey the resulting work.」 |
| 4c | GPL-3.0 §7 另給下游「移除該限制條款」的權利 | 已驗證 | 同一段緊接著：「If the Program as you received it, or any part of it, contains a notice stating that it is governed by this License along with a term that is a further restriction, **you may remove that term**.」⇒ Commons Clause 在合併作品裡不只違法，還站不住——下游可以直接把它拿掉 |
| 4d | **Naki 的 LICENSE 裡沒有 AGPL↔GPL 相容條款** | 已驗證 | `LICENSE` 只有 §0–§8（`:26,38,42,46,50,54,64,68,72`）。官方 AGPL-3.0 §13「Remote Network Interaction; Use with the GNU General Public License」在這裡被壓成只講 network interaction 的 §6（`:64-66`），相容授權整段不存在。全檔 `grep -i "General Public License"` 只命中 `:11`／`:17`／`:28` 三處，全是 "GNU **Affero** General Public License" |
| 5 | MajsoulMax 由 mod / helper / replace 三部分組成，預設只啟用 mod | 已驗證 | 抓取其 README（2026-08-09）：「程序包含三部分：包括 `mod` 、 `helper` 和 `replace`」「程序默认配置为启用 `mod`、禁用 `helper` 和 `replace`」 |
| 6 | MajsoulMax 是 mitmproxy MITM + CA 憑證 + 系統代理 | 已驗證 | 同上 README：「基于 mitmproxy 的中间人攻击方式」；「默认在本地 `127.0.0.1:23410` 启动一个 HTTPS 代理」；「请先在系统中导入并信任 `~/.mitmproxy/` 下的 `mitmproxy-ca-cert.cer` 证书」 |
| 7 | MajsoulMax 自己警告封號風險 | 已驗證 | 同上 README CAUTION 區塊：「魔改千万条，安全第一条。使用不规范，账号两行泪。」「雀魂官方可能会检测并封号，如产生任何后果与作者无关。」 |
| 8 | macOS target 未啟用 App Sandbox | 已驗證 | `Naki.xcodeproj/project.pbxproj:833`（Debug）、`:865`（Release）`ENABLE_APP_SANDBOX = NO` |
| 9 | `Naki/akagi.entitlements` 目前不生效 | 已驗證 | `grep -c CODE_SIGN_ENTITLEMENTS project.pbxproj` → **0**。該檔只出現在 `Naki-MUITests` 的 Compile Sources membershipExceptions（`project.pbxproj:232`），沒有任何 target 以 `CODE_SIGN_ENTITLEMENTS` 指向它 |
| 10 | iOS target 沒有開檔案分享 | 已驗證 | `grep UIFileSharing\|LSSupportsOpeningDocumentsInPlace project.pbxproj` → 0 命中；全部 target 都是 `GENERATE_INFOPLIST_FILE = YES`，repo 內找不到任何 `Info.plist` |
| 11 | JS 模組只從 `Bundle` 讀，不讀外部檔案 | 已驗證 | `WebSocketInterceptor.swift:178-201`（`bundle.url(forResource:...)`），`:167-170` 模組清單只有 `naki-core`、`naki-websocket` |
| 12 | 注入是 `atDocumentStart` + `forMainFrameOnly: false`，且全有或全無 | 已驗證 | `WebSocketInterceptor.swift:249-276`（`createUserScript`）、`:204-236`（`buildInjection`：任一模組失敗就整批不注入） |
| 13 | Naki 自送 request 的 msgId 落在 60000–65500 | 已驗證 | `LiqiEncoder.swift:203-249`（`LiqiMsgIdAllocator`，`rangeStart = 60000`、`rangeEnd = 65500`） |
| 14 | 有兩處以 60000 為界判斷「這是遊戲自己送的」 | 已驗證 | `naki-websocket.js:400`（`if (msgId >= 60000) return;`）、`LiqiParser.swift:198-199`（`msgId < Int(LiqiMsgIdAllocator.rangeStart)`） |
| 15 | 受端就地改 bytes 必須等長 | 已驗證 | `naki-websocket.js:172-174` 的既有註解與 `writeLabel`（`:304-312`）的實作：長度不足就降級成更短標籤再補空白，從不改變 byte 數 |
| 16 | Naki 的 Swift 側看到的是**改寫後**的 bytes | 已驗證 | `naki-websocket.js:439-449`：先 `nakiNicknameMask.observe(...)`（就地改）再 `arrayBufferToBase64(data)`。TypedArray 分支（`:450-462`）同理 |
| 17 | Naki 自己送出的封包會回流經過 `ws.send` hook | 已驗證 | `naki-websocket.js:144-148`（`ws.send` 被包裝，先 `handleMessage` 再 `originalSend`）；`sendRaw` 呼叫的正是這個被包裝的 `ws.send`（`:593`、`:613`）。`LiqiActionSender.swift:19-25` 檔頭也依賴這個事實 |
| 18 | JS→Swift 訊息型別有機械契約鎖 | 已驗證 | `WebSocketInterceptor.swift:310-317`（`BridgeMessageType` 六個 case，switch 無 `default`）＋ `NakiTests/BridgeMessageContractTests.swift:36-51`（從 **bundle 內** `WebSocketInterceptor.jsModules` 的原始碼 regex 抓 `sendToSwift('…')`，與 `allCases` 雙向比對） |
| 19 | 新增 JS 檔要手動加進三份 membershipExceptions | 已驗證 | `project.pbxproj:69-70`（`Naki` target）、`:152-153`（`Naki-M`）、`:241-242`（`Naki-MUITests`）各自列出兩個 `.js` 檔 |
| 20 | iOS 無法載入任意原生程式碼 | **平台事實，未於本機實測** | 這是 Apple 平台的既有限制（無未簽章碼的 `dlopen`、App 內可執行碼必須與 App 同簽章、無 JIT 例外給 App 本體）。不是 Naki 的配置問題 |
| 21 | receive 側「換掉遊戲拿到的 event」在技術上可行 | **未驗證** | §7.5 的機制候選（capture 階段 `stopImmediatePropagation()` + `ws.dispatchEvent(new MessageEvent(...))`）在 Naki 上**沒有做過任何 probe**。Phase 4 動工前必須先驗 |
| 22 | JS 插件可攔 `fetch`／`XHR` 做資源替換 | **未驗證** | 對應 MajsoulMax `replace`。Naki 目前只 hook 了 `WebAssembly.instantiate*`（`naki-core.js`），沒有任何 `fetch`／`XHR` hook 的證據 |
| 23 | gist 有 revision-pinned raw URL；GitHub API 可列出 gist 的檔案與 revision | **未驗證** | §6.5 GistSource 依賴此行為。訓練知識，Phase 1b 動工前要以真實 gist 驗一次（驗收已含） |
| 24 | WebExtensions（MV3）有 `options_ui`＋`chrome.storage`＋`optional_permissions`；VS Code 有 `activate`/`deactivate`＋`contributes.configuration`＋`engines.vscode` | 已驗證（檢索） | 2026-08-09 經 context7 取自 developer.chrome.com 與 code.visualstudio.com 官方文件；§7.10 的對照以此為據。**未親測**任一平台的執行期行為 |

> ⚠️ 授權段落是工程判讀，不是法律意見。真正要對外散布前應取得法律意見。

---

## 1. 為什麼「Naki 自己就是那個 proxy」

MajsoulMax 走的是**外部程序 + TLS 外側**：mitmproxy 監聽 `127.0.0.1:23410`，使用者要匯入並信任 `mitmproxy-ca-cert.cer`，還要用 Clash／Surge 把雀魂流量分流過去（客戶端／Steam 端還要開 TUN）。這是為了「從 App 外面看見加密流量」而付的全部代價。

Naki 不需要付這個代價，因為它已經在 TLS **內側**：

```
Majsoul Unity WebGL（同一個 JS realm）
      │  new WebSocket(url)
      ▼
naki-websocket.js:80   ← window.WebSocket 被整個換掉
      │
      ├─ :106-108  message listener 在建構當下就註冊 ⇒ 一定排在遊戲自己的 handler 之前
      │              event.data 的 ArrayBuffer 是同一份記憶體 ⇒ 就地改 bytes，遊戲讀到的就是改過的
      │
      └─ :144-148  ws.send 被包裝 ⇒ 送出面在 originalSend 之前先過一手
```

`__nakiHideNames`（`naki-websocket.js:207-389`）就是這條路的既有實證：它在遊戲解析 `ResAuthGame` **之前**把 nickname bytes 就地覆寫成等長 ASCII。這證明「在 TLS 內、在遊戲解析前改封包」在 Naki 裡已經是**運作中的機制**，不是設想。

**結論**：對雀魂 Web 客戶端而言，Naki 的攔截點嚴格優於外部 proxy——不必裝憑證、不必設代理、不必改系統路由，而且看得到的東西完全一樣（同一條 WebSocket 的雙向 bytes）。唯一 Naki 位置**較差**的地方見 §2 的 `replace`。

---

## 2. MajsoulMax 三塊功能與 Naki 的對應性

以下 mod／helper／replace 的功能描述全部出自其 README（已驗證，見 §0 #5–#7）。

| MajsoulMax | 它做什麼 | Naki 對應的 hook | 可行性 |
|---|---|---|---|
| **`mod`**（預設開） | 解鎖角色／皮膚／裝扮／語音／稱號／加載 CG／表情、強制便捷提示、星標角色、自訂名稱、顯示所在服務器、顯示主播 Pro 標識。**README 明說「解锁人物仅在本地有效，别人还是只能看到你原来的角色」** | **JS 層 receive hook**（改遊戲看到的 RESPONSE／NOTIFY bytes） | ✅ 機制已存在（`__nakiHideNames` 就是同一件事的窄化版）。Phase 2 |
| **`helper`**（預設關） | 把牌局送到 mahjong-helper | **Swift 層唯讀外送**（現成的 MJAI 事件流 + loopback DebugServer） | ✅ 最容易。Naki 已經有比它更完整的東西（`MJAIEventStream`、`/game/*`、MCP）。Phase 5 |
| **`replace`**（預設關） | 「替换游戏资源文件，**仅支持网页版**」 | **不是 WebSocket 的事**——那是 HTTP 資源替換 | ⚠️ **WebSocket hook 做不到**。見下 |

### `replace` 為什麼不同

`replace` 改的是 HTTP 資源（圖檔、asset bundle），不是 WebSocket 訊息。Naki 的攔截點在 `window.WebSocket`，看不到 HTTP。

WKWebView／WebPage 也**不提供** https 請求的攔截：`WKURLSchemeHandler` 只對自訂 scheme 生效，`NSURLProtocol` 不作用於 WebKit 的 network process。

唯一在 Naki 架構內成立的候選是**再開一個 JS 層 hook**：在頁面內包住 `fetch` / `XMLHttpRequest`（Naki 已經對 `WebAssembly.instantiate*` 做過同類事情，見 `naki-core.js`）。這條路**未驗證**（§0 #22）——不知道 Unity WebGL 客戶端實際用哪個 API 拉資源、也不知道有沒有完整性檢查。

**建議**：`replace` 等價功能**不列入本次範圍**，標為「未評估的第二條 hook」。硬把它塞進 WebSocket hook 的設計只會讓契約變髒。

---

## 3. 現行資料流：可插點盤點

```
Majsoul Unity WebGL
  │
  │ ① new WebSocket / ws.send / message event
  ▼
naki-websocket.js
  │   handleMessage(ws, wsId, data, direction, isMajsoul)      :420-488
  │     ├─ :421   if (!isMajsoul) return                       ← 只有雀魂線進得來
  │     ├─ :432-436 attributeSend（選線證據，msgId ≥ 60000 排除）
  │     ├─ :440   nakiNicknameMask.observe(bytes, direction)   ← 【就地改 bytes 的既有位置】
  │     │                                                        ★ 插件 hook 的最佳插入點在這一行之後
  │     └─ :443   sendToSwift('websocket_message', { base64 }) ← 改寫後的 bytes 才被編碼送去 Swift
  ▼
② websocketBridge（WKScriptMessageHandler）
  │   WebSocketMessageHandler.dispatch(type:data:)             WebSocketInterceptor.swift:409-438
  │     契約表 = BridgeMessageType（六個 case，switch 無 default）:310-317
  ▼
③ MajsoulBridge.parseRaw / parse                              MajsoulBridge.swift:139-144 / :223-237
  │   → LiqiParser.parse（envelope → {id, type, method, data}） LiqiParser.swift:119-149
  │   → LiqiResponseStore.capture / LiqiOperationStore
  ▼
④ MJAIEventStream.emit(event)                                 MJAIEventStream.swift:98-109
  │     ★ Swift 層唯讀 hook 的最佳插入點
  ▼
⑤ NakiWebCoordinator → NativeBotController → GameStore

（送出面）
AutoPlayEngine → AutoPlayDecisionResolver → AutoPlayActionExecutor
  → LiqiActionSender.send                                     LiqiActionSender.swift:96-118
  → LiqiEncoder.encodeRequest（配 msgId 60000+）               LiqiEncoder.swift:166-177
  → NakiRuntime.sendHandler                                   NakiRuntime.swift:126-135
  → window.__nakiWebSocket.sendRaw(base64)                    naki-websocket.js:543-622
  → proven.ws.send(bytes.buffer)  ← 這是【被包裝過的】send，會再回流到 ① 的 handleMessage
```

### 每個插點的性質

| 插點 | 看得到 | 改得動 | 時序 |
|---|---|---|---|
| ① `handleMessage` 中段 | 原始 bytes（雙向），未解析 | **是**——遊戲還沒解析 | 同步，在遊戲的 handler 之前 |
| ② `dispatch` | 已過 ① 的 bytes | 只能影響 Naki 自己，改不到遊戲 | 非同步（postMessage 過橋） |
| ③ `parse` 之後 | 已解析的 `{id, type, method, data}` | 同上 | 非同步 |
| ④ `emit` | MJAI 事件（Naki 的語意層） | 同上 | 非同步 |
| ⑤ 送出鏈 | Naki 自己的動作 | — | — |

**②③④ 一律改不到遊戲**：那時候遊戲早就解析完了，bytes 已經是 base64 字串的一份拷貝。這是 JS 層與 Swift 層能力差異的根源，不是實作偷懶。

---

## 4. 兩種 hook 的能力邊界

### (a) JS 層 hook — 插件是 JS，注入頁面

**能做**
- 在遊戲解析前檢視／改寫雙向 liqi bytes（＝ MajsoulMax `mod` 的等效位置）
- 送出面可以整個換掉傳給 `originalSend` 的參數 ⇒ **送出方向改長度是自由的**
- 存取 `window` / `document` / `fetch` / `localStorage`（與遊戲同一個 realm）
- 兩個平台都能跑（macOS 與 iOS 皆為 WKWebView 家族）

**不能做（或代價很大）**
- **受端改長度**：就地改 `event.data` 的 buffer 只能等長（§0 #15）。要改長度必須換掉「遊戲拿到的那個 event」，機制未驗證（§7.5）
- **看不到 HTTP 資源**（＝ `replace` 做不到，§2）
- **沒有真正的隔離**：與遊戲、與 Naki 的注入腳本同一個 realm，見 §8.3
- 拿不到 Naki 的 Swift 狀態（推薦、手牌、oplist）——除非另開回程通道

### (b) Swift 層 hook — 插件收 Naki 已解析的事件

**能做**
- 拿到 Naki 的語意層產物：MJAI 事件、oplist snapshot、推薦、`GameStore` 快照
- 唯讀分析與轉發（＝ MajsoulMax `helper` 的等效效果）
- 型別安全、可單測、不影響頁面

**不能做**
- **改不到遊戲看到的東西**（§3）
- **不能是動態載入的原生程式碼**——這是本設計最重要的取捨，見 §5.2

### 對應總表

| 需求 | hook | 說明 |
|---|---|---|
| 改角色／皮膚／稱號／自訂名稱（`mod`） | JS receive | 等長改寫夠用的部分先做；需要改長度的排 Phase 4 |
| 把牌局轉發給外部工具（`helper`） | Swift 唯讀 | 走既有 loopback，不需要載入任何外部程式碼 |
| 替換遊戲資源（`replace`） | 都不行 | 需要第二條 HTTP hook，未評估 |
| 自動打牌／代送動作 | JS send | **危險面**，見 §8 |

---

## 5. 建議架構

### 5.1 一句話

> **JS 層開 hook 給第三方插件（可改封包）；Swift 層只開唯讀外送通道（不載入任何外部原生程式碼）。**

### 5.2 為什麼 Swift 側不做動態載入

| 平台 | 動態載入原生插件 | 事實 |
|---|---|---|
| iOS | **不可能** | 平台限制（§0 #20）。這不是配置問題 |
| macOS | 技術上可以，但要付代價 | `ENABLE_HARDENED_RUNTIME = YES`（`project.pbxproj:834`/`:866`）。載入非同 Team 簽章的 `.dylib`／`.bundle` 需要 `com.apple.security.cs.disable-library-validation`。repo 內 `Naki/akagi.entitlements` **有**這個 key，但**沒有任何 target 用 `CODE_SIGN_ENTITLEMENTS` 指向它**（§0 #9）——目前完全不生效。要用就得先接上，而接上等於對整個 App 放寬程式碼載入限制，還會讓公證變複雜 |

`docs/pluggable-bots-plan.md`（2026-08-01）在「不做 bot 市集／自動安裝」一節已經對同一類問題做過同樣的判斷（「Naki **沒有開 App Sandbox**，自動下載並執行任意程式碼的風險太高」）。本設計沿用該結論。

**替代方案**：Swift 側的「插件」＝**跑在 Naki 外面的獨立程序**，透過既有 loopback DebugServer 訂閱事件。
- 不需要任何 entitlement、不需要動態載入、不需要改簽章
- iOS 上同樣可用（DebugServer 兩個平台都啟動，見 `NakiRuntime.swift:97-101`）
- 授權上是最乾淨的 arm's-length：兩個程序、跨程序通訊、各自的授權

### 5.3 分層圖（設計後）

```
                  ┌─────────────────────────────────────┐
   使用者可寫目錄  │  Plugins/<id>/plugin.json + *.js    │  ← 不進 repo、不進 App bundle
                  └───────────────┬─────────────────────┘
                                  │ PluginRegistry 掃描 + 讀 manifest（Swift，新增）
                                  ▼
   WebSession.init ── WKUserContentController
                        ├─ WKUserScript #1：bundled 模組（現況，全有或全無）
                        │    naki-core.js → naki-websocket.js → naki-plugins.js（新增）
                        └─ WKUserScript #2：已啟用的插件（新增，失敗只停用該插件）
                                  │
                                  ▼
   頁面內：window.__nakiPlugins.register({...})
                                  │
                                  ▼
   naki-websocket.js handleMessage 中段 → __nakiPlugins.dispatch(ctx)
                                  │
                                  ▼
   （原本的路徑不變）sendToSwift → LiqiParser → MJAI → Bot

   ── 另一條，完全獨立 ──
   MJAIEventStream.emit ──▶ DebugServer 事件外送（loopback）──▶ 外部程序（helper 等價）
```

---

## 6. 插件的形態與安裝

### 6.1 打包格式

一個插件 ＝ 一個目錄：

```
Plugins/
  com.example.appearance/
    plugin.json          # manifest（必要）
    plugin.js            # 進入點（必要，路徑由 manifest 的 entry 指定）
    LICENSE              # 插件自己的授權（強烈建議；Naki 只顯示不解讀）
    README.md            # 選用
```

`plugin.json`：

```json
{
  "schemaVersion": 1,
  "apiVersion": 1,
  "id": "com.example.appearance",
  "name": "外觀本地解鎖",
  "version": "1.0.0",
  "entry": "plugin.js",
  "capabilities": ["observe", "rewriteReceive"],
  "methods": [".lq.Lobby.fetchAccountInfo", ".lq.Lobby.login"],
  "priority": 100,
  "license": "GPL-3.0-only",
  "homepage": "https://example.com/…",
  "description": "只改本機顯示的角色與裝扮，不影響其他玩家看到的內容。"
}
```

規則：
- `capabilities` 與 `methods` 都是**必填**。`methods` 是白名單，空陣列＝這個插件不處理任何訊息（等於停用）
- `id` 必須與目錄名相同，否則不載入（避免同一份插件用不同 id 重複註冊）
- 任何欄位缺漏／格式錯 ⇒ **整個插件不載入**，UI 掛出可查的原因（沿用 `JSModuleFailure` 的分級寫法：`notFound` / `unreadable` / `empty` / `manifestInvalid`）
- **無簽章、無雜湊驗證**。這是刻意的：假的完整性檢查比沒有更糟（使用者會以為它擋住了什麼）

### 6.2 放哪裡

| 平台 | 路徑 | 事實 |
|---|---|---|
| macOS | `~/Library/Application Support/Naki/Plugins/` | App Sandbox = NO（§0 #8），該路徑不在 TCC 保護範圍 ⇒ **讀得到，不需要任何授權對話**。（對照：`~/Documents`、`~/Desktop`、`~/Downloads` 會觸發 TCC，不該用） |
| iOS | App 容器內 `Application Support/Plugins/` | 讀得到。**問題在檔案怎麼進去**，見下 |

Naki 目前完全不從檔案系統讀 JS（§0 #11），這是全新的能力。

### 6.3 iOS 的真實結論

**能做的**：JS 插件在 iOS 上**可行**。`WKUserScript` 的內容只是一個 `String`；從容器讀檔再注入不需要任何 entitlement、不涉及 JIT（WebKit 的 JIT 例外屬於 WebContent process，與 App 本體無關）。

**做不到的**：載入任意**原生**程式碼——這是平台限制（§0 #20），沒有繞法。

**目前的實際障礙**：使用者**沒有辦法把檔案放進 App 容器**。`UIFileSharingEnabled` 與 `LSSupportsOpeningDocumentsInPlace` 兩個 key 都不存在（§0 #10），也沒有任何 `Info.plist`（全部 `GENERATE_INFOPLIST_FILE = YES`）。三個選項：

| 選項 | 做法 | 代價 |
|---|---|---|
| (a) 開檔案分享 | 加 `INFOPLIST_KEY_UIFileSharingEnabled = YES` + `INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace = YES` | 「檔案」App 從此看得到整個 Documents 目錄。要把插件放 Documents 而不是 Application Support |
| (b) App 內匯入 | `UIDocumentPickerViewController` 讓使用者挑檔案，複製進容器 | 要寫 UI；體驗較差但容器不對外開放 |
| (c) 自動從 URL 下載 | — | **仍然否決**。「Naki 決定來源＋執行期抓取＋無人工確認」三件事的疊加，`pluggable-bots-plan.md` 已經為同一理由否決過 |
| (d) 使用者貼 URL 一次性匯入 | 見 §6.5 | 與 (c) 的三個要素全部相反（使用者選來源、只在匯入當下抓、逐項確認才落地）。App Store 2.5.2 的衝突仍在（§6.5 代價段） |

**建議 (d)**（§6.5，2026-08-09 拍板），(b) 作為無網路環境的備援；兩者都不改變容器的對外可見性。

### 6.4 發現、載入、開關

1. **發現**：`PluginRegistry`（新增，Swift）在 `NakiRuntime.init` 早期掃描目錄，讀 manifest，產出 `[PluginDescriptor]`。掃描本身不執行任何插件程式碼。
2. **載入**：`WebSession.init`（`WebSession.swift:120-150`）在現有 `controller.addUserScript(websocketScript)` 之後，**再加一個** `WKUserScript`，內容是所有已啟用插件的原始碼串接。
   - **必須是第二個 script**：現有 `buildInjection` 是全有或全無（§0 #12）。把插件混進那一批，一個壞插件就會讓整個 Naki 停擺。第二個 script 失敗只影響插件。
   - 順序：bundled 模組必須先跑（插件要用 `window.__nakiPlugins`）。同一個 `WKUserContentController` 內，先 `addUserScript` 的先執行。
3. **開關**：`SettingsStore` 新增 `enabledPluginIds: Set<String>`（UserDefaults，沿用 `SettingsStore.swift:82-121` 的既有 pattern）。**預設空集合——所有插件預設關閉**。
4. **生效時機**：~~`WKUserScript` 只在 document start 注入 ⇒ 開關插件必須重新載入頁面才生效~~
   **已改為熱插拔（2026-08-10 實作，live 驗證通過）**：`WKUserScript` 仍是「首次載入」的路徑（頁面 reload 後照 `enabledPluginIds` 還原），但**開關當下**走另一條——`naki-plugins.js` 提供 runtime `setGrant`/`disable`，Swift 端 `NakiRuntime.setPluginEnabled` 在 toggle 時用 `evaluateJavaScript` 對**當前活著的頁面**注入 enable（`setGrant` + 插件源碼 → `register`）或 disable。`evaluateJavaScript` 是 App 注入、跑在頁面 main world，不受頁面 CSP 阻擋，所以**免 reload 即時生效**。live 實證：`register`/`disable` 後 `list()` 立刻反映，且 `[Plugin] registered/disabled` 進 log。持久化仍寫 `enabledPluginIds`（下次啟動照舊）。
5. **不做**：市集、推薦、自動更新。§6.5 的「使用者指定來源的一次性匯入」不是發現機制——Naki 不內建任何來源，抓取只發生在使用者確認的當下。

### 6.5 從 URL 匯入（gist 或任意 HTTPS 位置）★ 2026-08-09 拍板新增

**定性：使用者指定來源的一次性匯入器，不是執行期載入器。** §6.3 (c) 被否決的是三件事的疊加——Naki 決定來源、執行期抓取、無人工確認；本節三件全部反過來：來源由使用者貼入（輸入框預設空白，**Naki 不內建任何 URL、清單、推薦**）、只在匯入當下抓一次、逐項確認後才落地。落地之後與手放檔案走**完全相同**的路徑（§6.4 的掃描、開關、重載生效，一字不改）。

#### 來源解析器

```
使用者貼 URL
  ├─ GistSource：gist.github.com/<user>/<id>
  │     GitHub API 取檔案清單 → 釘 revision → 以 revision-pinned raw URL 抓全部檔案
  │     （revision 不可變性：未驗證，§0 #23；Phase 1b 驗收一併驗掉）
  └─ HTTPSource：任意 https://…/plugin.json
        抓 manifest → 依 entry 等欄位解析相對路徑 → 同源逐檔抓取
        ▼
兩者輸出同一個正規化結果：
  { files: [名稱 → bytes], provenance: { url, revision?, 每檔 sha256 } }
        ▼
共用管線：本地驗證（§6.1 同一套規則）→ 匯入確認畫面 → 落地 Plugins/<id>/ + install-receipt.json
```

#### HTTPSource 的格式契約（「格式正確」的機械定義）

1. URL 必須**直接指向 `plugin.json`**。不猜 index、不嘗試多個路徑。
2. manifest 引用的檔案（`entry` 等）以 manifest URL 為基準解析**相對路徑**，且必須**同源**——不允許 manifest 在 A 站、程式碼在 B 站；出處紀錄才是「一個插件一個來源」。
3. **只允許 HTTPS**（順帶排除 `http://127.0.0.1:8765` 這類指向自家 DebugServer 的輸入）。允許 redirect，receipt 記**最終** URL（短網址遮不住出處）。
4. 尺寸上限：manifest 64KB、整包 5MB，超過即中止。
5. 驗證與本地插件**完全同一套**（§6.1：欄位齊全、id 合法、capabilities/methods 必填）。任一不過就不落地，原因可查（沿用 `JSModuleFailure` 分級）。

#### fetch-once 語意（任意 URL 沒有 revision pinning 的補償）

整個匯入流程只抓**一次**網路；bytes 進記憶體後，預覽、確認、落地全部用**同一份 bytes**，中間絕不重抓。不可變性從「來源保證」（gist revision）變成「流程保證」：**使用者確認的就是之後執行的**。

#### 匯入確認畫面（人工把關，取代簽章）

顯示 id／版本／capabilities／methods 白名單／license／**原始碼全文**，加 §8.3 警語（「執行此插件＝信任其作者。它可以用你的帳號送出任何遊戲動作」）。沒有捷徑可跳過。

#### install-receipt.json

落地時寫進 `Plugins/<id>/`（`PluginRegistry` 掃描時忽略它）：來源 URL（redirect 後最終值）、gist revision（若適用）、每檔 sha256、匯入時間。**這是出處紀錄，不是完整性驗證**——與 §6.1「無簽章、無雜湊驗證」不矛盾：receipt 記「當時裝了什麼」，不宣稱「作者可信」。

#### 更新

不做自動更新。「檢查更新」按鈕＝**重新走一次完整匯入流程**：重抓、與 receipt 的 hash 對比、內容有變就明講並重新給預覽、再次確認才覆蓋。

#### 代價（如實）

- **社交工程面比手放檔案寬**：手放檔案的摩擦力本身是過濾器，貼連結把它移除了——這正是 §9.3 #5 說的放大器。緩解只有確認畫面＋警語，**無法根除**。
- **gist 在中國大陸不可達**：HTTPSource 同時存在就是為了這個——使用者可自架或改用可達的託管。
- **App Store 2.5.2 正面衝突**：「下載會改變 App 功能的程式碼」是條文所指。本功能等於預設回答 §11 #3 為「不上架」。

---

## 7. Hook API 契約（`apiVersion: 1`）

### 7.1 註冊

由新增的 bundled 模組 `naki-plugins.js` 提供：

```js
window.__nakiPlugins.register({
  id: 'com.example.appearance',      // 必須與 manifest 的 id 相同，否則拒絕註冊
  onReceive(ctx) { /* … */ },        // 選用
  onSend(ctx) { /* … */ },           // 選用
  onSocketClose(info) { /* … */ },   // 選用（§7.10(c)：{socketId, url}）
});
```

`register` 由 **Naki** 決定這個 id 被允許哪些 capability 與 methods——**manifest 是權威，插件自己在 JS 裡宣稱什麼一律不算數**。id 對不上、未在 `enabledPluginIds` 內、或重複註冊 ⇒ 拒絕並記一行 log。

### 7.2 `ctx` 看得到什麼

```
ctx = {
  direction : 'receive' | 'send',
  socketId  : number,              // naki-websocket.js 的 wsId
  url       : string,              // 這條連線的 URL（判斷 gateway / game-gateway）
  type      : 1 | 2 | 3,           // notify / request / response（envelope 第 0 byte）
  msgId     : number | null,       // notify 沒有 msgId
  method    : string | null,       // REQUEST 直接解出；RESPONSE 由 pendingMethods 對回（可能是 null）
  bytes     : Uint8Array,          // 完整 envelope。可就地改（等長），見 7.4
  payload   : { from, to } | null, // envelope 內 field 2 的 byte range，插件不必自己再解一次
  isNaki    : boolean,             // msgId 落在 Naki／插件號段
  log(msg)  : void,                // 進 Naki 的 log，自動帶插件 id 前綴
  settings  : object,              // §7.10(a) 的唯讀快照；manifest 有宣告 settings 才存在
  replace(newBytes) : boolean,     // 需要 rewrite* capability
  drop()            : boolean,     // 需要 drop* capability
  sendRequest(method, payloadBytes) : {ok, msgId} | {ok:false, reason}   // 需要 injectSend；回應走 onInjectResponse（§7.7b）
}
```

回傳值一律忽略——所有作用都經 `ctx` 的方法，這樣「插件做了什麼」在 Naki 這側是可觀測的。

### 7.3 插件**看不到**什麼（如實）

- `handleMessage` 開頭就有 `if (!isMajsoul) return`（`naki-websocket.js:421`）⇒ 非雀魂連線的訊息插件看不到
- **Blob 分支不在範圍內**：`handleMessage` 的 Blob 路徑（`:463-473`）是非同步的，既有的 `nakiNicknameMask.observe` 也沒有接進去。插件同樣不接。實務上雀魂送的是 ArrayBuffer / TypedArray，但這是限制不是保證
- 字串訊息（`:474-483`）不在範圍內
- 拿不到 Naki 的 Swift 狀態（推薦、手牌、oplist）。要拿必須另開回程通道——**v1 不做**

### 7.4 改寫與長度

| 方向 | 等長改寫 | 改長度 | drop |
|---|---|---|---|
| **send** | 就地改 `bytes` | ✅ **可以**——wrapper 換掉傳給 `originalSend` 的參數即可 | 技術上可以（不呼叫 `originalSend`），但**預設禁止**：遊戲會以為送出去了，狀態機會卡住而且完全沒有徵兆 |
| **receive** | 就地改 `bytes`（唯一已驗證的機制，`__nakiHideNames` 在用） | ⚠️ 需要換掉遊戲拿到的 event，機制未驗證（§7.5） | 同上，需要同一套機制 |

**等長是 v1 的硬性約束**，理由與 `naki-websocket.js:172-174` 寫的完全相同：protobuf 的 string／bytes 前面是 varint 長度，改長度就要連動所有外層 nested message 的長度前綴，一路錯到底。等長覆寫完全不碰結構，最壞情況是顯示出怪字串，不會讓遊戲解析爆掉。

`ctx.replace(newBytes)` 在 v1 對 receive 方向若長度不等 ⇒ 回 `false` 並記一行 log，**不做任何改動**（fail-open 成「原樣通過」）。

#### 重新編碼的陷阱：空 field 1 不能省

「等長就地改」不會踩到這個，但**任何整包重新序列化的插件（Phase 3/4）都會**。

Liqi 的 wrapper 是 `{1: method, 2: payload}`。RESPONSE 的 field 1 是**空字串**——官方伺服器照寫（`0a 00`，所以 wrapper 恆為兩個 block），但 canonical proto3 encoder 重新序列化時會**省略預設值欄位**，於是改寫過的 RESPONSE 只剩 field 2 一個 block。

`LiqiEnvelope.decode` 對 RESPONSE 原本是**按位置**取 payload（`blocks[1]`），碰到這種只有一個 block 的封包會靜默拿到空 payload——`authGame` 形同沒收到、整局偵測不到，而**遊戲自己照常能玩**（它的 decoder 按欄位號讀），症狀是「只有 Naki 失明」。

> **這一條不是推論，而是 Naki 已經踩過的坑（issue #2 的根因）。** 症狀鏈：改寫過的 `authGame` RESPONSE 只剩一個 block → `blocks[1]` 不存在 → payload 靜默變空 `Data()` → authGame 解出 0 blocks → 不發 `start_game` → **「偵測不到對局」**。
>
> **狀態：已修，未 commit**（非我所為，見交付說明）。本文件撰寫當下的工作區：
> - `command/Services/Bridge/LiqiEnvelope.swift` 的 RESPONSE 分支已改為 `blocks.first { $0.fieldId == 2 && $0.wireType == 2 }?.data ?? Data()`，附 why 註解
> - `NakiTests/LiqiParserFailureTests.swift` 已有回歸測試 `testAuthGameResponseWithoutEmptyMethodFieldStillStartsGame`（canonical proto3 形狀、wrapper 無空 field 1）
> - 全套 NakiTests 601 tests / 0 failures（由 teammate `gpl-30-license` 回報，**我未自行重跑**）
>
> NOTIFY／REQUEST **刻意維持位置取法**，並在該檔註解裡寫明理由與日後改法。引用時請直接讀現在的 `LiqiEnvelope.swift` 原始碼為準，不要引本文件。

對插件契約的三個要求：

1. `injectSend` / `rewriteSend` 產生的 REQUEST **必須自己寫出 field 1**（method 非空，一般 encoder 不會省，但不能靠運氣）
2. 插件若重編 NOTIFY，要知道 `LiqiEnvelope.decode` 對 NOTIFY 仍是位置取法——省掉任何欄位會讓 Naki 以 `notEnoughBlocks` **顯式失敗**（不是靜默空 payload，這是刻意的）
3. Phase 3/4 的驗收要有一條專門的 fixture：「用 canonical encoder 重編過的封包，Naki 仍解得開」

#### 送出側協定怪癖（Phase 3 契約，已讀原始碼佐證）

插件作者送 REQUEST 時必知的四件事，全部從既有實作抽出，不是新規則：

| 事實 | 對插件的意義 | 位置 |
|---|---|---|
| **REQUEST envelope 完全無 XOR**：`[type=2][msgId 2B LE][protobuf: field1=method, field2=payload]` | 插件 `injectSend` 送 request **不需要** XOR。別自作聰明去 XOR payload | `LiqiEncoder.swift:13`、`naki-websocket.js:568` |
| **XOR 只作用在 receive 側 notify 的 `.lq.ActionPrototype` payload 內層**；`syncGame`／`enterGame` restore **不** XOR | 與插件送 request **無關**。若插件將來要 `rewriteReceive` 改 ActionPrototype，才需要知道它的 payload 是 XOR 過的（但 ActionPrototype 在 §8.2 禁改名單裡，預設就改不了） | `MajsoulBridge.swift:365`（XOR）、`:376-384`（sync 不 XOR） |
| **gateway 分流由 Naki 自動處理**：`.lq.FastTest.*` 走 game-gateway，其餘走 gateway | 插件不用選連線。但送對局方法時若無 game-gateway 連線，`sendRaw` 回 `no_game_gateway_connection`——`sendRequest` 要把這個 reason 原樣透出 | `naki-websocket.js:579-587` |
| **`sendRaw` 成功只代表 WebSocket 接受了 bytes**，不代表伺服器接受 | `sendRequest` 的 `{ok:true}` 是「送出去了」不是「成功了」。真正成功要看同 msgId 的 RESPONSE（§7.7b 的回應通道）或權威 action | `CLAUDE.md`；`LiqiActionSender.swift:133-147` |

**因此 hook API 契約新增一條硬性條件（`apiVersion: 1`）：**

> **插件改寫後的 bytes 必須能被 Naki 既有 parser 正確重讀。** 具體要容忍 canonical proto3 re-encode 的三種合法變形：**欄位順序重排**、**預設值欄位省略**、**repeated 轉 packed**。插件不必保證 byte-identical，但必須保證語意可讀。

這條寫進契約而不只是「建議」，是因為它的失敗模式**完全不可見**：遊戲照常運作（它按欄位號解），只有 Naki 失明，而且失明的表徵是「偵測不到對局」這種看起來像別的問題的症狀。Phase 3/4 的驗收清單必須逐項對這三種變形做 fixture。

### 7.5 receive 改長度的機制候選（Phase 4，**未驗證**）

Naki 的 listener 在 `new WebSocket()` 當下就註冊（`naki-websocket.js:106-108`），一定排在遊戲自己的 handler 之前。因此候選是：

1. Naki 的 listener 以 capture 階段註冊
2. 需要替換時呼叫 `event.stopImmediatePropagation()`，攔下原本的 event
3. `ws.dispatchEvent(new MessageEvent('message', { data: newBuffer }))` 送一個新的
4. Naki 自己的 listener 用旗標略過這個合成 event，避免無限遞迴

**風險**：這會動到 Naki 收封包的**主要路徑**——現在所有東西（LiqiParser、MJAI、bot、oplist）都掛在那條 listener 上。做壞了不是「插件不動」而是「Naki 整個瞎掉」。

**要求**：動工前先寫一個獨立 probe（可用 `POST /js` 在 live 頁面上跑），確認 (a) `stopImmediatePropagation` 真的擋得住遊戲的 handler、(b) 合成 `MessageEvent` 遊戲吃得下、(c) `ws.onmessage = fn` 這種寫法也涵蓋得到。probe 綠了才寫實作。

### 7.6 msgId：與既有 60000 號段的相處

有**兩處**現行邏輯以 60000 為界判斷「這一筆是遊戲自己送的」（§0 #14）：

- `naki-websocket.js:400`：`if (msgId >= 60000) return;`——不把 Naki 自送的請求當作選線證據
- `LiqiParser.swift:198-199`：`msgId < LiqiMsgIdAllocator.rangeStart`——`ObservedMatchSids` 只學遊戲自己送的 sid。CLAUDE.md 記載 2026-08-09 踩過這個坑：不濾掉會讓猜錯的嘗試值被記成「觀察到的真值」，錯誤自我餵養

**設計**：插件的 msgId 不另開新號段，而是**切分現有的 Naki 號段**：

| 用途 | 區段 | 改動 |
|---|---|---|
| 遊戲自己 | 低位遞增（實測 141、142…） | 不變 |
| Naki 自送 | **60000–63999** | `LiqiMsgIdAllocator.rangeEnd` 由 `65500` 改為 `63999` |
| 插件注入 | **64000–65500** | 新增第二個 allocator 實例 |

這樣**上面兩處判準一個字都不用改**（插件送的仍然 `>= 60000`，仍然不會被誤認成遊戲自己送的），同時 Naki 又能分辨「這筆是我送的還是插件送的」。

如果反過來給插件低於 60000 的號段，兩處判準都會把插件送出的請求當成「遊戲自己送的」——`ObservedMatchSids` 會把插件送的 `startUnifiedMatch` 記成觀察到的真值，`attributeSend` 會拿它當選線證據。**這是一個具體的、會靜默污染狀態的錯誤設計，不要做。**

### 7.7 插件與 Naki 自送封包的相互可見性

Naki 自己的 `sendRaw` 呼叫的是**被包裝過的** `ws.send`（§0 #17），所以 Naki 自送的封包會回流到 `handleMessage`。這代表：

- **預設**：`ctx.isNaki === true` 的訊息**不派發給插件**。插件不該看見、更不該改寫 Naki 的自動打牌動作
- 想看的插件必須在 manifest 明確宣告 `"observeNakiTraffic": true`，且只給 `observe`，**永遠不給 rewrite**

### 7.7b `injectSend` 的回應通道（補契約洞，2026-08-09；**設計候選，未驗證**）

**問題**：插件用 `sendRequest` 送出的 REQUEST 拿 64000–65500 號段（§7.6），伺服器回來的 RESPONSE `msgId` 落在同一號段 ⇒ `isNaki === true` ⇒ 依 §7.7 預設不派發給任何插件。結果是**插件送得出請求，卻永遠收不到自己的回應**——`sendRequest` 只回 `{ok, msgId}` 就到頂了。這使 `injectSend` 半殘（送一個 `fetchAccountInfo` 卻拿不到帳號資料）。

**機制根據（已讀原始碼佐證，非發明）**：

| 事實 | 位置 |
|---|---|
| RESPONSE 不帶方法名，配對**完全靠 msgId** | `LiqiParser.swift:66`、`:223-225` |
| msgId→method 對照**只有一份權威**，靠 `ws.send` hook 記下 | `LiqiActionSender.swift:19-21`（自述「不再自己記一份 `pendingMethods`」） |
| JS 側 `pendingMethods` Map（msgId→method），送出時記、RESPONSE 回來時對回 | `naki-websocket.js:210`、`:349-362` |
| Swift 側 `pendingRequests: [Int: String]`，同機制 | `LiqiParser.swift:70`、`:174-178`、`:223-225` |
| 既有「送出後輪詢 `LiqiResponseStore` 等 RESPONSE」的成熟模式 | `LiqiActionSender.swift:131-147`（`send(spec, awaitResponseMs:)`） |

**設計**：不廣播、不破壞 §7.7，只把「自己那筆的回應」交還「自己」。

1. `sendRequest` 成功時，`naki-plugins.js` 在一張**注入登記表**記 `msgId → 發起插件 id`（msgId 一定落在 64000–65500，天然不與遊戲、與 Naki 自送相撞）。
2. `handleMessage` 收到 RESPONSE，若 `isNaki` 且 `msgId` 命中登記表 ⇒ **只**回派給登記的那一個插件（其餘插件仍看不到，§7.7 不變）。
3. 回派介面二選一（Phase 3 拍板時定，二者都要求非同步——RESPONSE 是稍後另一則訊息才到，dispatch 是同步的，當下拿不到）：

   | 選項 | 形狀 | 取捨 |
   |---|---|---|
   | (a) callback | `register({ onInjectResponse(ctx) })`，ctx 帶 `inResponseTo: msgId` | 與現有 hook 一致；但插件要自己把 msgId 對回當初的請求語意 |
   | (b) promise | `sendRequest` 回 `{ ok, msgId, response: Promise<ctx> }` | 呼叫端最直覺（`await`）；但要在同步 dispatch 裡建 promise、跨訊息 resolve，實作較重 |

   **建議 (a)**：與 §7.1 的 hook 模型同構，不在同步熱路徑上掛 pending promise；逾時（建議 10s）沒等到就丟一則 `onInjectResponse` 帶 `timedOut: true`，避免插件無限等。
4. 登記表要有上限與 TTL（沿用 `pendingMethods` 的 256 上限 + FIFO 淘汰，`naki-websocket.js:353-355`），逾時或滿了就丟最舊的，`onInjectResponse` 收 `timedOut`。

**驗收（併入 Phase 3）**：
- 單測：插件送出 msgId 落 64000–65500 → 該 msgId 的 RESPONSE **只**回派發起插件，其他插件收不到
- 單測：非插件號段（遊戲自己、Naki 自送 60000–63999）的 RESPONSE **不**進 `onInjectResponse`
- 單測：逾時 → `onInjectResponse` 帶 `timedOut: true` 且登記表清掉該筆
- 這條沒補完，Phase 3 的 `injectSend` 不得宣稱可用（只有 `rewriteSend` 這種不需回應的能先上）

### 7.8 多插件

- 順序：manifest `priority` 升冪，同值按 id 字典序
- 每個插件看到**前一個改完**的 bytes（鏈式）
- 任一插件 throw ⇒ 該插件本次跳過、記一行 log（同 id 同錯只記一次，沿用 `UnknownBridgeTypeReporter` 的去重寫法，`WebSocketInterceptor.swift:327-349`）
- 同一個插件連續失敗 N 次（建議 10）⇒ 本次頁面生命週期內自動停用該插件，UI 顯示原因
- **hook 出錯絕不影響封包本身**（fail-open：原樣通過）
- **drop 短路**（2026-08-09 補）：任一插件 `drop()` 成功 ⇒ 鏈**立即中止**，後續插件不再派發——封包已不存在，繼續派發只會讓後面的插件「改了個寂寞」
- **replace 換 buffer**（2026-08-09 補）：`replace(newBytes)` 成功後，dispatch 必須把後續插件的 `ctx.bytes` 指向**新** buffer。「看到前一個改完的」在等長就地改寫時是同一份記憶體的自然結果；在 replace 時是 dispatch 要主動維護的契約
- **可觀測**（2026-08-09 補）：log／UI 要能查「這個 method 被哪些插件、按什麼順序動過」——兩個 rewrite 插件改到重疊 byte range 時，結果由 priority 決定且畫面上看不出來，唯一防線是事後可查
- **isNaki 分流**（2026-08-09 補）：`isNaki === true` 的訊息走**另一條只含 observer 的鏈**（§7.7：宣告 `observeNakiTraffic` 且僅 `observe` 的插件），與一般鏈分開建構——同一則訊息永遠只屬於其中一條鏈，dispatch 不得混用

### 7.9 插件 → Swift 的訊息通道

`BridgeMessageContractTests`（§0 #18）只掃 `WebSocketInterceptor.jsModules` 裡的 bundled 原始碼。因此：

- **第三方插件絕對不可以自己呼叫 `sendToSwift('新type', …)`**——那個 type 不會在 `BridgeMessageType.allCases` 裡，runtime 會被 `warnUnknown` 丟掉（`WebSocketInterceptor.swift:412`、`:443-452`）
- 插件要跟 Swift 說話，一律經 `ctx.log()`／未來的 `ctx.notify()`，由 **bundled 的** `naki-plugins.js` 用**一個**固定 type（例如 `plugin_event`）送出
- 這個新 type 要同時加進 `BridgeMessageType` 的 case、並在 `naki-plugins.js` 裡出現，契約測試才會綠。加了 case 沒處理會**編譯失敗**（switch 無 `default`）——這是設計上要的

### 7.10 外部接口對照後的補強（2026-08-09，證據見 §0 #24）

本節是拿 WebExtensions（Chrome MV3）與 VS Code Extension API 的接口面當 checklist 掃出來的。原設計的接口是從 Naki 既有 hook 點**逆推**的，沒有系統性對照過成熟插件系統；掃完的結論：核心決策與業界收斂（manifest 權威＝MV3 permissions 模型、priority 鏈＝middleware pipeline、fail-open＝extension host 錯誤隔離），但缺三塊標配，補如下。

#### (a) 插件設定（2026-08-09 拍板：進 v1，排 Phase 2）

對照：VS Code `contributes.configuration`（JSON schema，宿主渲染設定 UI，`workspace.getConfiguration` 讀取）；Chrome `options_ui`＋`chrome.storage.sync`。mod 類插件（換哪個角色、顯示什麼名字）沒有設定就只能 hardcode。

- manifest 新增**選用**欄位 `settings`：`{ "<key>": { "type": "string"|"number"|"boolean", "default": …, "description": "…" } }`。型別就這三種，不做巢狀、不做 enum
- Naki 設定頁按 schema 自動渲染（掛在插件清單 UI 下），值存 `SettingsStore`，以插件 id 命名空間隔離（UserDefaults key `plugin.<id>.<key>`）
- 注入時隨 grants 一起下發，插件經 `ctx.settings`（唯讀快照）讀取；改設定與開關同語意——**重載頁面才生效**（不做熱更新，與 §6.4 一致）
- 插件**不得**用頁面 `localStorage` 存設定：與遊戲同一個 storage 混居，Naki 看不見、UI 管不到
- schema 無效（未知型別、`default` 與 `type` 不符）＝ manifest 無效 ⇒ **整個插件不載入**（§6.1 同語意，不做部分載入）

#### (b) `apiVersion` 相容政策（v1 定死）

對照：VS Code `engines.vscode: "^1.8.0"`（semver range）。Naki 不做 range——**exact match**：`manifest.apiVersion !== 1` ⇒ 不載入，原因 `apiVersionUnsupported`（進 `JSModuleFailure` 分級）。v2 真的出現時再決定相容矩陣；現在就承諾相容範圍是負債。

#### (c) 生命週期（v1 只補一個 hook）

對照：VS Code `activate`/`deactivate`＋`context.subscriptions` 自動 dispose；MV3 service worker 靠 `chrome.storage` 跨生命週期。Naki 的對應現實：**WKUserScript realm 的生命週期＝頁面生命週期**，reload 全清——deactivate 級的清理沒有對應物，不必發明。真正缺的只有連線層：

- `register` 新增選用 hook `onSocketClose({ socketId, url })`——gateway／game-gateway 多條 WebSocket 並存，按 socketId 存狀態的插件需要知道哪條死了
- 插件被自動停用（§7.8 連續失敗）**不另發通知**——它的 hook 已經不可信了，原因走 UI／log

---

## 8. 安全與信任邊界

### 8.1 能力分三級

| 級別 | capability | 影響面 | 預設 |
|---|---|---|---|
| **L1 唯讀** | `observe` | 只看，不改 | 插件啟用後即可用 |
| **L2 改本機顯示** | `rewriteReceive` | 改遊戲客戶端看到的東西。**不影響伺服器，不影響其他玩家**（MajsoulMax README 自己也說「解锁人物仅在本地有效」） | 插件啟用後可用，但受禁改名單限制（§8.2） |
| **L3 改送出** | `rewriteSend` / `dropSend` / `injectSend` / `dropReceive` | **能替使用者送遊戲動作**。這正是 CLAUDE.md 第 10 條列的「動作、匹配、建房、強制重連與帳號外觀變更都不是唯讀查詢」 | **完全不可用**，除非另外開總開關 |

**L3 的總開關**：`SettingsStore.pluginsMayModifyOutbound`，**預設 false**。開啟時必須有一次性確認對話，文字要直說「插件將可以用你的帳號送出遊戲動作」。這對應 CLAUDE.md「修改 WebSocket bridge、自動打牌或任何會送 Liqi request 的行為前先確認」。

### 8.2 預設禁改名單（即使有 `rewriteReceive`）

Naki 的 Swift 側看到的是**插件改完的** bytes（§0 #16），因為現行 `handleMessage` 就是先改再編 base64。這個順序**應該保留**——Naki 的推薦與自動打牌必須與玩家實際看到的牌桌一致，否則會出現「側欄建議的那張牌畫面上根本不在」。

代價是：**插件能污染 Naki 的牌局狀態**。所以以下方法預設不可改寫：

- `.lq.ActionPrototype`（所有牌局動作的載體）
- `.lq.FastTest.syncGame`（斷線重連的狀態還原）
- `.lq.NotifyGameEndResult`（終局結算）
- `.lq.FastTest.authGame` 的 `players` / `robots` **以外**的欄位（那兩個是 `__nakiHideNames` 的既有範圍）

要解除必須在 manifest 逐一列出，UI 以紅字顯示「這個插件會改動 Naki 用來判斷牌局的資料，推薦可能與實際牌局不一致」。

### 8.3 ⚠️ 能力宣告是「協作式」不是「強制式」

**這是本設計最重要的誠實聲明。**

JS 插件與遊戲、與 Naki 的注入腳本在**同一個 JS realm**。`window.__nakiWebSocket` 是全域物件（`naki-websocket.js:494`），任何插件都可以直接呼叫：

```js
window.__nakiWebSocket.sendRaw(anyBase64);   // 繞過所有 capability 檢查
```

也就是說：**即使不給插件任何 L3 能力，插件只要呼叫 `sendRaw` 就能送出任意封包。**

能不能堵？
- 把 `__nakiWebSocket` 藏起來：**不行**。Naki 自己的送出鏈就是靠 `window.__nakiWebSocket.sendRaw` 這個全域名字（`NakiWebSocketScript.swift:26,32`），拿掉會直接打斷 `LiqiActionSender`
- 換成一次性 token：頁面上任何腳本（包含雀魂自己與其他插件）都讀得到那個 token
- 把插件放進獨立 realm（iframe / Worker）＋ postMessage：**能真正隔離，但就拿不到「在遊戲解析前就地改 bytes」的位置**——而那正是整個設計的價值所在

**結論**：capability 宣告的價值是**可稽核性**（UI 上寫明這個插件宣稱要做什麼、log 記錄它實際改了什麼），不是防禦。

因此 UI 必須明講：

> 安裝插件 ＝ 信任插件作者。插件與遊戲跑在同一個環境裡，一個惡意插件可以用你的帳號送出任何遊戲動作、讀取頁面上的任何資料。Naki 沒有辦法阻止這件事。只裝你信任的插件。

#### 插件的實際權限範圍（2026-08-10 決定：明講「完整頁面權限」）

決策：**不做受控的 overlay／DOM API，直接讓插件擁有完整頁面權限，並把「有多大」寫清楚**（呼應 §8.3 的誠實聲明——同 realm 本來就擋不住，假裝有沙箱只會誤導）。完整實證清單見 `docs/plugin-api-v1.md` §8「插件實際能碰到什麼」。要點：

- `capabilities`／`methods` 只管「Naki 遞出去的封包 hook」；**頁面本身**（`window`／`document`／`fetch`／`localStorage`（實測 57 鍵）／`cookie`／`indexedDB`／`__nakiWebSocket.sendRaw`／`__nakiHeap` wasm heap）插件**無條件全有**，不受 capability 限制。
- **「自訂畫面顯示」的現實**：雀魂是 Unity WebGL，畫面全在 `unity-canvas`（WebGL，實測 DOM 僅 ~30 元素），**改 DOM 改不到遊戲畫的東西**；overlay 疊 canvas 有 pointer-events 點擊衝突（故不做受控 overlay API，取捨留給插件）。改遊戲畫面內容 → `rewriteReceive` 改封包（Phase 2）；碰遊戲像素 → hook WebGL draw（`__nakiHighlight`，極脆）。

### 8.4 封號風險

MajsoulMax 自己的 README 反覆警告（原文，已驗證）：

> 魔改千万条，安全第一条。使用不规范，账号两行泪。
> 雀魂官方可能会检测并封号，如产生任何后果与作者无关。

Naki 的插件 UI 必須顯示等價警語，並沿用 CLAUDE.md 第 7 條：**只操作使用者自己的測試帳號；不可使用主帳號。**

### 8.5 其他邊界

- 插件目錄**不掃描子目錄以外的任何位置**。網路取得只有一個例外：§6.5 的匯入當下（使用者貼的 URL、一次性、確認後落地）；頁面載入與執行期零網路請求
- Naki 不對插件內容做任何解讀／執行以外的處理；manifest 的 `description`、`homepage` 一律當**資料**渲染，不當指令（沿用 `pluggable-bots-plan.md` 的「bot 的 `meta` 原樣轉發但不執行」）
- log 要記錄「哪個插件、改了哪個 method、改了幾個 byte」，但**不得記錄封包內容**（可能含 session token；CLAUDE.md 第 8 條）

---

## 9. 授權隔離：哪條線不能越

### 9.1 事實

| 項目 | 授權 | 驗證 |
|---|---|---|
| Naki | AGPL-3.0 **＋ Commons Clause** v1.0（Licensor: Suoie） | 已驗證，`LICENSE:1-13` |
| MajsoulMax | GPL-3.0（FSF 全文） | 已驗證，2026-08-09 抓取 |

> ⚠️ **順帶發現，與插件無關但值得知道**：`LICENSE:78` 自述「This is a simplified version」——repo 內那份不是 FSF 的 AGPL-3.0 全文，而是一個八節的摘要版，並在文末指向官方 URL。實際授予的條款因此與官方 AGPL-3.0 不完全相同（例如官方 §13 的 AGPL↔GPL 相容條款在這份摘要裡根本沒有）。這不影響本文件的結論（插件本來就不進 repo），但它是一個獨立的授權衛生問題。

### 9.2 為什麼不能內置

GPL-3.0 §7 列舉了六類可以附加的條款（(a) 免責、(b) 法律聲明、(c) 標示修改、(d) 限制名稱使用、(e) 商標、(f) 賠償），然後明文寫：

> All other non-permissive additional terms are considered "further restrictions" within the meaning of section 10.

§10 則寫：

> You may not impose any further restrictions on the exercise of the rights granted or affirmed under this License.

Commons Clause 的「不得 Sell」（`LICENSE:5`）不屬於 (a)–(f) 任何一類 ⇒ 是 further restriction ⇒ §10 禁止 ⇒ §8「Any attempt otherwise to propagate or modify it is void, and will automatically terminate your rights under this License」。

**精確一點**：問題出在 **Commons Clause**，不在 AGPL。GPL-3.0 §13 明文寫著（已驗證，§0 #4b）：

> Notwithstanding any other provision of this License, you have permission to link or combine any covered work with a work licensed under version 3 of the GNU Affero General Public License into a single combined work, and to convey the resulting work.

也就是說，**如果 Naki 是純 AGPL-3.0，結合 GPL-3.0 程式碼是被明文允許的**。是 `LICENSE:5` 那一句「不得 Sell」讓組合變成不合法。

GPL-3.0 §7 同一段還接著寫（已驗證，§0 #4c）：

> If the Program as you received it, or any part of it, contains a notice stating that it is governed by this License along with a term that is a further restriction, **you may remove that term.**

所以問題不只是「違反 GPL」，而是 **Commons Clause 在合併作品裡根本站不住**——下游拿到那份合併作品後，有權直接把「不得 Sell」拿掉。內置 GPL 程式碼等於用一個會被合法移除的條款去保護商業限制。

### 9.2b 「那就拿掉 Commons Clause」為什麼比表面貴一階

看起來只要刪掉 `LICENSE:1-13` 的 Commons Clause 區塊，就能直接內置 MajsoulMax，插件系統整個不必做。**但那條路要走兩步，不是一步**：

`LICENSE` 用的是自述 "This is a simplified version"（`:78`）的 AGPL 摘要版，只有 §0–§8。官方 AGPL-3.0 的 §13「Remote Network Interaction; **Use with the GNU General Public License**」在這裡被壓縮成只講 network interaction 的 §6（`:64-66`），**AGPL↔GPL 的相容授權整段不存在**（已驗證，§0 #4d）。

| 路線 | 要做的事 | 代價 |
|---|---|---|
| **A. 內置**（改授權） | ① 刪掉 Commons Clause ② **把精簡版換成 FSF AGPL-3.0 全文**（否則沒有 §13 可援引，第一步等於白做）③ 整個 Naki 從此不能對「不得 Sell」有任何主張 ④ 內置的 GPL 程式碼要持續同步上游、承擔其 bug 與封號設計 | 授權立場永久改變；且 MajsoulMax 的 README 自己還加了「不得用于商业用途」（§0 #2c），對方的條款本身就內部矛盾——內置等於把別人的授權混亂搬進自己 repo |
| **B. 插件**（本文件） | 開一組 hook，插件在執行期由使用者自己放 | Naki 授權**一個字都不用改**；第三方各自負責自己的授權；使用者免裝憑證、免設代理；iOS 也吃得到 |

**路線 B 的優勢不只是「比較保守」**——它讓 Naki 完全不必碰對方那份自相矛盾的授權，而且順帶得到 macOS/iOS 雙平台可用、無需系統代理的能力，那是路線 A 給不了的（MajsoulMax 需要 mitmproxy + CA 憑證 + 系統代理，§1）。

### 9.3 五條線

1. **插件目錄不進 repo**：`.gitignore` 加入插件路徑；插件是使用者在**執行期**自己放的檔案，不隨 Naki 散布，不進 App bundle
2. **Naki 不 link、不 vendored、不 bundle 任何 GPL 程式碼**：build 產物內零第三方插件。範例插件由 Naki 自己寫（MIT 或 CC0），內容不得參考 MajsoulMax 的實作
3. **hook API 是穩定介面**：`apiVersion` 明確版號，Naki 這側的實作完全原創。純介面相容（別人寫插件來實作 Naki 定義的 API）不使 Naki 成為衍生作品——Naki 沒有使用任何 GPL 程式碼
4. **插件各自負責自己的授權**：插件目錄放自己的 LICENSE，Naki 的 UI 顯示 manifest 的 `license` 欄位但不代為授權、不驗證、不背書
5. **不做市集／推薦／自動更新**：一旦 Naki 主動幫使用者**挑選**插件，「單純的執行期組合」這個定性就開始鬆動，而且是 §8.3 那個安全問題的最大放大器。§6.5 的一次性匯入不越這條線的前提：Naki 零內建來源、零推薦，只抓使用者自己貼的 URL——arm's-length 的關鍵是「Naki 不提供內容」，不是「Naki 不碰網路」

### 9.4 越線就會出事的具體行為

以下任一項都會讓 Commons Clause 變成 GPL §7 意義下的 further restriction：

- 把 MajsoulMax 的 `mod` 規則表（角色 id、皮膚 id 對照）抄進 Naki 的原始碼
- 把它的 `config/settings.yaml` 內容內建成 Naki 的預設值
- 把它的資源替換清單打包進 App
- 在 Naki 的 repo 裡放一份 MajsoulMax 的副本（哪怕是 submodule 或 vendored 目錄）
- 發佈一個「內含插件」的 Naki 安裝包

---

## 10. 落地計畫

每一階段的驗收都要照 CLAUDE.md「驗收回報」分開寫：已修改 / 已驗證 / 未驗證 / 已知風險。

### Phase 0 — 只寫文件，零程式碼

- 本文件 + `docs/plugin-api-v1.md`（給插件作者的契約，從 §7 抽出來）
- §11 的決策拍板
- **驗收**：無程式碼改動；`git status` 只有 docs

### Phase 1 — 唯讀（`observe`）

| 改什麼 | 檔案 |
|---|---|
| 新增 bundled 模組 | `command/Resources/JavaScript/naki-plugins.js`（新） |
| 加進模組清單 | `WebSocketInterceptor.swift:167-170` 的 `jsModules` |
| 加進三份 membershipExceptions | `project.pbxproj` 的 `Naki` / `Naki-M` / `Naki-MUITests` 三個 exception set（§0 #19） |
| 在中段派發一次 | `naki-websocket.js` 的 `handleMessage`：在 `nakiNicknameMask.observe(...)` **之後**、`arrayBufferToBase64(...)` **之前** |
| 掃描與 manifest | `command/Services/Plugins/PluginRegistry.swift`（新） |
| 第二個 user script | `WebSession.swift` 的 `init` |
| 開關 | `SettingsStore` 的 `enabledPluginIds`（預設空） |
| UI | 設定頁的插件清單（顯示 id / 版本 / capability / license / 啟用開關） |

**驗收**
- `BridgeMessageContractTests` 仍綠（新 type 要同步加 `BridgeMessageType` case）
- **新增機械測**：零插件時 `buildInjection` 的輸出與現況**逐字元相同**
- **新增機械測**：插件 script 建立失敗時，bundled 的那一份仍然注入（對照現行「全有或全無」只適用於 bundled 模組）
- **新增機械測**：manifest 缺欄位／id 與目錄名不符 ⇒ 不載入且原因可查
- **新增機械測**：`apiVersion !== 1` ⇒ 不載入，原因 `apiVersionUnsupported`（§7.10(b)）
- live：裝一個只 `ctx.log()` 的範例插件，`GET /logs` 看得到它的輸出；`/game/state` 與裝插件前一致

### Phase 1b — URL 匯入器（§6.5）※ 依賴 Phase 1 的 PluginRegistry 與驗證規則

| 改什麼 | 檔案 |
|---|---|
| 來源解析器（GistSource / HTTPSource） | `command/Services/Plugins/PluginImportSource.swift`（新） |
| 匯入流程與確認 UI | 設定頁「從 URL 匯入」 |
| 出處紀錄 | `Plugins/<id>/install-receipt.json`（Registry 掃描時忽略） |

**驗收**
- 單測：格式契約逐條——非 HTTPS 拒絕、跨源引用拒絕、尺寸超限中止、manifest 缺欄位不落地且原因可查
- 單測：fetch-once——預覽用的 bytes 與落地的 bytes 逐 byte 相同（hash 一致）
- 單測：receipt 欄位齊全（最終 URL、每檔 sha256、時間；gist 含 revision）
- live：從真實 gist 匯入 `ctx.log()` 範例插件成功（§0 #23 藉此驗掉）；修改 gist 後「檢查更新」顯示內容已變更且要求重新確認

### Phase 2 — 等長 receive 改寫（`rewriteReceive`）

- `ctx.replace()`（等長）、method 白名單、§8.2 禁改名單
- 插件設定（§7.10(a)：manifest `settings` schema → 設定頁渲染 → `ctx.settings`）※ §11 #11 已拍板（2026-08-09）
- **驗收**
  - node 合成 frame 測試（沿用 `__nakiHideNames` 已經在用的做法）
  - 白名單外的 method 呼叫 `replace()` 一律回 `false` 且不改 bytes（單測）
  - 長度不等時回 `false` 且不改 bytes（單測）
  - 單測：`drop()` 成功後鏈中止；`replace()` 成功後後續插件拿到新 buffer（§7.8 的短路與換 buffer 語意）
  - 單測：`settings` schema 無效 ⇒ 整個插件不載入且原因可查；有效時 `ctx.settings` 帶 default 與使用者覆寫值；manifest 未宣告 `settings` 時 `ctx.settings` 不存在
  - 單測：設定值變更 → 重載頁面 → `ctx.settings` 反映新值（不做熱更新的驗證面）
  - 延遲基準：0／1／5 個插件時 `handleMessage` 的耗時分佈可查——同步熱路徑，鏈長直接累加，不能只驗零插件
  - live probe：範例插件只改 `.lq.Lobby.fetchAccountInfo` 的某個顯示欄位 ⇒ 遊戲畫面變了、`/game/state` 沒變

### Phase 3 — send 側（`rewriteSend` / `injectSend`）★ §11 #1 已拍板「做」；前置為 task #5（injectSend 回應通道＋協定怪癖入契約）

- `SettingsStore.pluginsMayModifyOutbound`（預設 false）+ 一次性確認對話
- `LiqiMsgIdAllocator.rangeEnd` 收窄為 63999；新增插件 allocator 64000–65500（§7.6）
- **驗收**
  - 單測：插件送出的 `.lq.Lobby.startUnifiedMatch` **不得**進 `ObservedMatchSids`（`LiqiParser.swift:198-207` 的既有守衛必須仍然有效）
  - 單測：插件送出**不得**成為 `attributeSend` 的選線證據（`naki-websocket.js:392-415`）
  - 單測：總開關 false 時 `ctx.sendRequest` / `ctx.replace`（send 方向）一律回 `{ok:false}` 且什麼都不做
  - live：**只在測試帳號**驗一次，且要有同 msgId 的 RESPONSE 才算成功（CLAUDE.md：`sendRaw` 成功只代表 WebSocket 接受 bytes）

### Phase 4 — receive 改長度／drop ★ 最高風險；§11 #6 已拍板「先 probe，probe 綠才實作」

- **先 probe 再實作**（§7.5）。probe 不通過就此打住，v1 永遠只支援等長
- **驗收**
  - probe 三項全綠（擋得住遊戲 handler / 合成 event 遊戲吃得下 / `onmessage` 寫法也涵蓋）
  - 回歸：`replay-check.sh` 決策指紋與 baseline **完全相同**（零插件時）
  - live soak：`scripts/soak-test.sh` 至少 3 局無異常

### Phase 5 — Swift 唯讀外送（`helper` 等價）

- `DebugServer` 新增事件外送通道（SSE 或 WebSocket），來源是 `MJAIEventStream.emit`
- loopback-only（`DebugServer` 已只綁 loopback）
- **不載入任何外部原生程式碼**——訂閱端是獨立程序
- **驗收**：外部程序訂閱到的事件序列與 `docs/replay-baseline.txt` 對得起來

### 明確不做

- 插件市集、自動更新、簽章驗證（假的完整性檢查比沒有更糟）；「自動下載」仍不做——§6.5 是使用者指定來源的一次性匯入，Naki 不選來源、不在執行期抓
- 動態載入原生插件（macOS 需要接上一份目前不生效的 entitlement；iOS 不可能）
- `replace` 等價的 HTTP 資源替換（§2，需要第二條未評估的 hook）
- 插件讀取 Naki 的 Swift 狀態（推薦、手牌、oplist）——v1 不開回程通道
- 執行期權限升級（對照 Chrome `optional_permissions`）——§8.3 已說明 capability 是可稽核性不是防禦，執行期授權對話會給使用者「這是安全機制」的錯覺，同「假的完整性檢查比沒有更糟」
- 懶啟動／activationEvents（對照 VS Code）——插件數量級是個位數，methods 白名單已在 dispatch 層過濾，lazy activation 的複雜度買不到東西
- 通用 KV 儲存與 secrets API（對照 `chrome.storage`／VS Code `SecretStorage`）——同 realm 之下（§8.3）任何「秘密」都是假的，提供 secrets API 本身就是誤導；設定走 §7.10(a)，其他持久化 v1 不提供
- i18n（manifest 的 `%key%` 機制）——單語言 description 夠用，翻譯基礎設施等有第二個語言的真需求再說

---

## 11. 決策拍板紀錄

**2026-08-09 全部拍板完成。** 下表「拍板」欄是定案，非建議。除 #10（另案處理）外，Phase 0 的決策 gate 已清空——工程可依 §10 動工。

| # | 決策 | 為什麼要你決定 | 拍板（2026-08-09） |
|---|---|---|---|
| 1 | **插件到底要不要能改「送出去的」東西？**（Phase 3 做不做） | 這直接踩 CLAUDE.md「修改…任何會送 Liqi request 的行為前先確認」。而且 §8.3 說明了 capability 檢查擋不住決心繞過的插件 | **做**。排進計畫，Phase 1–2 之後接著做。L3 仍受總開關（預設 false）＋一次性確認＋只用測試帳號限制。**前置**：先補 injectSend 回應通道與送出側協定怪癖入契約（task #5），否則 Phase 3 不動工 |
| 2 | **iOS 用哪個方式讓使用者放插件？** | (a) 開 `UIFileSharingEnabled` 會讓「檔案」App 看到容器；(b) document picker 要寫 UI；(c) 自動下載已被否決 | **(d) URL 匯入（§6.5）為主，(b) 備援** |
| 3 | **有沒有上架 App Store 的打算？** | 影響 2.5.2「不得下載執行改變 App 功能的程式碼」的風險評估。目前簽章是 Automatic + Team `YRJZ6WG9VC`，看不出上架意圖 | **確認不上架**。2.5.2 從此不作為設計約束；§6.5 的 URL 匯入不必為上架讓步 |
| 4 | **「Naki 的 Swift pipeline 看插件改過的封包」這個預設對不對？** | 現行 `__nakiHideNames` 就是這個順序（§0 #16）。保留＝畫面與推薦一致但插件能污染牌局狀態；反過來＝Naki 看原始封包但可能與畫面不符 | **保留現行順序 + §8.2 禁改名單** |
| 5 | **§8.2 的禁改名單允不允許插件解除？** | 解除就等於允許插件改 Naki 的牌局真相來源，而且**畫面上看不出來** | **允許，但要 manifest 逐一宣告 + UI 紅字** |
| 6 | **Phase 4 要不要做？** | 它會動到 Naki 收封包的主要路徑。做壞了不是插件不動，是 Naki 整個瞎掉 | **先做 probe（§7.5 三項），probe 綠了再決定實作與否**。probe 不通過 ⇒ v1 永遠只支援等長 |
| 7 | **插件只能手動放檔案嗎？** | 「不做自動下載」是安全與授權隔離的共同前提 | **否**——開放 §6.5 的 URL 一次性匯入（gist 或任意 HTTPS）。「不做自動下載」的實質（Naki 不選來源、不在執行期抓、不自動更新）全部保留 |
| 8 | **§8.3 那段警語能不能接受？** | 「Naki 沒有辦法阻止惡意插件用你的帳號打牌」是這個設計的固有性質。若不能接受，唯一的替代是把插件放進獨立 realm，代價是失去「遊戲解析前改 bytes」的能力——整個設計的價值就沒了 | **接受並如實顯示**。UI 必明講 §8.3 警語，不遮掩 |
| 9 | **（延伸）Commons Clause 要不要留？** | 見 §9.2b 的兩條路線對照。「拿掉 Commons Clause 就能內置」是**兩步**不是一步——現行 `LICENSE` 是 §0–§8 的精簡版，官方 AGPL-3.0 §13 的 AGPL↔GPL 相容條款整段不存在，光刪 Commons Clause 沒有條款可援引 | **留著，走插件路線**。Naki 授權一個字都不用改，順帶拿到免憑證、免代理、iOS 也能用 |
| 10 | **`LICENSE` 的精簡版 AGPL 要不要換成 FSF 全文？** | 與插件系統無關，但它是決策 #9 的前置條件，而且獨立來看也是授權衛生問題：實際授予的條款與官方 AGPL-3.0 不同 | **另案處理**，不綁進插件系統的工期（唯一未清的項，與插件工程無依賴） |
| 11 | **§7.10(a) 插件設定 schema 要不要進 v1？** | 它把 `SettingsStore` 與設定頁 UI 的範圍擴大到「按 schema 動態渲染」；不做則 mod 類插件只能 hardcode | **做**，排在 Phase 2——`rewriteReceive` 沒有設定就只有玩具價值 |

---

## 附錄 A：引用的程式碼位置

| 事實 | 位置 |
|---|---|
| `window.WebSocket` 被整個換掉 | `command/Resources/JavaScript/naki-websocket.js:80-151` |
| message listener 在建構當下註冊 | 同上 `:106-108` |
| `ws.send` 包裝（先 hook 再 originalSend） | 同上 `:144-148` |
| 等長改寫的既有約束 | 同上 `:161-182`（註解）、`:304-312`（`writeLabel`） |
| `msgId >= 60000` 排除自送 | 同上 `:400` |
| `handleMessage`（插件 hook 的插入點） | 同上 `:420-488`，特別是 `:440`／`:443` |
| Blob 分支（不在 hook 範圍） | 同上 `:463-473` |
| `sendRaw`（全域可呼叫，§8.3 的破口） | 同上 `:543-622` |
| JS 模組清單與 Bundle-only 載入 | `command/Services/Bridge/WebSocketInterceptor.swift:167-201` |
| 全有或全無的注入 | 同上 `:204-236` |
| `createUserScript`（atDocumentStart / 非僅主 frame） | 同上 `:249-276` |
| `BridgeMessageType` 契約（switch 無 default） | 同上 `:310-317`、`:409-438` |
| 未知 type 去重器 | 同上 `:327-349` |
| `WKUserContentController` 組裝與 user script 加入 | `command/Services/Web/WebSession.swift:120-150` |
| `callJavaScript` 函式體語意 | 同上 `:161-163` |
| 送出鏈接線（`sendRaw` 的呼叫端） | `command/App/NakiRuntime.swift:114-136` |
| `LiqiMsgIdAllocator` 60000–65500 | `command/Services/Bridge/LiqiEncoder.swift:203-249` |
| `ObservedMatchSids` 的 `< 60000` 守衛 | `command/Services/Bridge/LiqiParser.swift:189-207` |
| `MajsoulBridge.parse` / `parseRaw` | `command/Services/Bridge/MajsoulBridge.swift:139-144`、`:223-237` |
| `MJAIEventStream.emit`（Swift 唯讀 hook 點） | `command/Services/Bridge/MJAIEventStream.swift:98-109` |
| 契約測試掃 bundle 內 JS 原始碼 | `NakiTests/BridgeMessageContractTests.swift:36-51` |
| `ENABLE_APP_SANDBOX = NO` / `ENABLE_HARDENED_RUNTIME = YES` | `Naki.xcodeproj/project.pbxproj:833-834`、`:865-866` |
| 三份 JS membershipExceptions | 同上 `:69-70`、`:152-153`、`:241-242` |
| 未生效的 entitlements | `Naki/akagi.entitlements`（無任何 `CODE_SIGN_ENTITLEMENTS` 指向） |

## 附錄 B：外部引用

- MajsoulMax：`https://github.com/Avenshy/MajsoulMax`
  - README 與 LICENSE 由我於 2026-08-09 抓取 `main` 的 raw content
  - commit pin `b3933bbaf7d847fdc0c7b4509b07f9bcb3610ab0`（committer date 2026-07-16）、LICENSE 674 行、sha256 前綴 `3972dc9744f6499f`——由 teammate `gpl-30-license` 以本機 clone 取證，我未自行核對 SHA
- GPL-3.0 全文：即上述 repo 的 `LICENSE`（§7 在 L388-390、§10 在 L463-464、§13 在 L552-560）
- 相關既有文件：`docs/pluggable-bots-plan.md`（「不做 bot 市集／自動安裝」的既有決定與理由）、`docs/architecture-deep-dive.md`（現行架構）、`docs/majsoul-unity-protocol.md`（Unity／Liqi 事實）
