# Naki 當前驗證報告

**驗證日期**：2026-08-01

**程式基準**：`main`，盤點起點 `7de0a04` 加目前工作樹

**完整技術基準**：[docs/majsoul-unity-protocol.md](docs/majsoul-unity-protocol.md)

本檔只保留目前仍成立的驗證結果與差距，不保存歷次遷移、除錯或已被推翻的結論。

## 結論

Naki 的 Unity WebSocket → Liqi → MortalSwift → Liqi sender 主鏈已存在，四麻 observation／mask fixtures 與 resolver 純邏輯也有測試。但是「能自摸時必定自摸」尚未完成端到端驗收，而且現行 source 仍有兩個可直接造成漏和的整合漏洞。因此不能宣稱問題已完全修復，也不能把目前 bundled 權重稱為最新最強模型。

## 已驗證

| 項目 | 證據 | 結果 |
|------|------|------|
| 客戶端 | live Naki `/js` 唯讀 probe | Unity WebGL 4.0.45；Laya／DesktopMgr／uiscript 不存在 |
| Debug API | live `/status`、`/bot/status`、`/game/*` | loopback server 與 Swift protocol state 可用 |
| MCP registry | live `tools/list` | 42 tools |
| Liqi schema | live manifest fresh download + byte compare | repo `liqi.json` 與 CDN 完全相同 |
| config | live manifest fresh download + repo parser | 41 tables／263 sheets／119,289 rows |
| Mortal parity | fresh Debug／Release tests | 各 47 tests 通過；固定 fixtures obs／mask 零落差 |
| Naki unit tests | fresh NakiTests | 75 tests 通過；resolver 專項 13 tests 通過 |
| runtime ron | request／response／ActionHule trace | type 9 走 `inputOperation` 成功 |
| runtime pon | request／response／ActionChiPengGang trace | type 3 走 `inputChiPengGang` 成功 |
| WebGL hook | live `__nakiHighlight.state()` | hook 與染色分支有執行 |

## 已確認差距

### P0：自摸 resolver 仍可能不被呼叫

`AutoPlayDecisionResolver` 本身會讓 server oplist 的 tsumo／ron 凌駕 AI。但 `WebViewModel` 仍以 Mortal recommendation 是否非空作為進入自動動作的條件；空推薦時，timer 只補副露 pass。

結果：server 即使給 type 8，只要 Mortal 回空推薦，就可能完全不進 resolver。

### P0：hora send 失敗仍可能被標成完成

外層在呼叫 sender 後，只看 resolved action 是 `.hora` 就 `markHandled`；沒有拿到實際 `LiqiSendResult`。沒有 game-gateway、JS send 失敗或 server 拒絕時，pending opportunity 仍可能被吃掉且不重試。

### P0：Legacy iOS 沒有 server-authoritative 保護

iOS 17–25 的 `LegacyWebViewModel` 直接使用 AI 第一推薦，沒有 resolver、oplist action 檢查、seat check、stale check 或 fail-closed。新舊路徑功能不一致。

手動 MCP／HTTP `game_action(action=hora)` 另有相同類型的缺口：沒有 oplist snapshot 時目前會猜 tsumo，應改成 fail closed。

### P1：off mode 的顯示語意未落實

`.off` 會阻止自動 sender，但 AI 仍在背景計算；RecommendationView 與 WebGL highlighter 沒讀 `showRecommendation`，因此側欄／遊戲內標記仍可能更新。README 已改成描述 current behavior；若產品意圖是完全不顯示，仍需接上 mode gate 並清除現有 target。

### P1：其他 failure path 也會過早消化 snapshot

空推薦的副露 pass 在送出前先 `markHandled`；打牌字串轉換失敗或立直找不到捨牌時，也會在沒有 request 的情況下標記 snapshot。這些路徑不直接造成漏自摸，但同樣缺少可靠的失敗重試與 rollback 語意。

### P1：模型版本宣稱過度

- 本機 resolve 到 MortalSwift 0.5.0，但 package requirement 是 `[0.5.0,0.6.0)`，lockfile 又未提交。
- 0.5.0 修的是 encoder／計算與 parity；bundled model blobs 沒換。
- 沒有大規模實戰 benchmark。

正確說法是「目前使用 MortalSwift 0.5.0 的 encoder/parity 修正版」；不能說「已換最新最強權重」。

### P1：三麻沒有專用模型

`is3P` 只改 Naki 狀態與標籤；推論仍建立同一個 Mortal v4 四麻 model。三麻不應宣稱支援。

### 已處理：無效 UI 控制已移除

位置校準、推薦溫度、旋轉 Laya 高亮與隱藏玩家名稱四組控制都已從 UI 移除。
底層名稱 API 仍依賴 live 已確認不存在的 `uiscript`，所以不可重新掛回 UI；若要恢復功能，必須另做真正的 Unity 實作。

### P1：遊戲內高亮只有活性證據

現行 `__nakiHighlight` 會攔 WebGL draw 並執行 tint，但尚未用 screenshot／視覺測試證明每次命中正確牌或按鈕。同名牌全染與 popup heuristic 是已知風險。目前工作樹另有字牌 UV 索引修正與「其餘手牌帶 alpha 調淡」變更，兩者都仍屬未提交、未做視覺回歸的 candidate。

## 正確修正順序

1. 以 oplist arrival 驅動 resolver，先處理 hora，不依賴 recommendation。
2. 讓 action execution 回傳結果；hora 只有在 send 成功，最好收到同 msgId RESPONSE／權威 action 後才 handled。
3. 對失敗保留 pending、bounded retry、sequence guard 與明確錯誤 log。
4. Legacy 共用同一 resolver／sender，或在完成前禁用 Legacy 自動模式。
5. 建立端到端 fixture：AI discard + server tsumo、空推薦 + tsumo、send failure、server reject、stale snapshot、recommend/off。
6. 固定 MortalSwift dependency，再做千局級牌力評估；不要用 package 版本代替模型強度證據。

## 未驗證

- 最新 source 在「AI 想 discard、server 有 tsumo」情境能否穩定 override 並收到 `ActionHule`。
- 空 recommendation + tsumo。
- send failure／server reject／中斷 cleanup。
- Legacy iOS 17–25 實機完整對局。
- chi variants、赤五 combination、ankan／minkan／kakan。
- WebGL 高亮與 action popup 的視覺正確性。
- AI 相對其他模型的實戰強度。

## 驗證環境與副作用

- Fresh app-hosted tests 曾初始化共用 temp `LogManager`，使當時正在執行的 Naki 日誌發生一次 rotation；最舊的一份歷史 rotation 可能因此被擠掉。
- 最後以 live `/status` 加 process file descriptor 重查：目前 Naki PID 寫入的檔案已與 `/status` 回傳的 `akagi_websocket.log` 相同，active-log mismatch 已解除。
- 最後 build 使用獨立 `/tmp/naki-doc-build.*` DerivedData，結束後已清除；沒有啟動或停止 Naki。

## 完成判準

只有在下列條件同時成立後，才可對外寫「漏自摸已修復」：

- source 層兩個 P0 integration gap 已消失。
- resolver／integration tests 覆蓋上述正常與 failure paths。
- 測試帳號 live 對局重現原始 `[discard, riichi, tsumo] + AI discard` 情境。
- log 顯示 resolver 選 hora、送到 game-gateway、同 msgId 成功 RESPONSE，並收到 `ActionHule`。
- 測試後沒有 stale pending、重複 request、殘留 process 或非預期帳號操作。

---

## 14. 高亮、日誌與副露後推薦（2026-08-01 live 對局實測）

本節的每一條都由**執行中的 Naki** 驗出，不是讀 code 推論。

### 14.1 字牌高亮會染錯牌

`naki-core.js` 的 `tileFromST` 在字牌分支寫的是 `Math.round(u * 10) - 1`。

live 對局取樣（手牌 `E W W P C`，`count===6` 的 `_MainTex_ST`）：

| `u` | 次數 | 應為 | 原本算成 |
|-----|-----:|------|---------|
| 0 | 37 | E | null |
| 0.2 | **74** | W（兩張） | S |
| 0.4 | 37 | P | N |
| 0.6 | 37 | C | F |

數牌（`v` = 0.5/0.25/0.75）全部正確，3m 出現 74 次正好對應手上兩張。
**問題不是解不出來，是解成別張。** 推薦打 `E` 時會去染 `S`。已移除那個 `-1`。

> 探測時踩過的坑：`hlslcc_mtx4x4unity_ObjectToWorld[0]` 只回矩陣第一欄，
> 位移在 `[3]`。用 `[0]` 取位置會拿到一組看起來合理但無意義的數字。

### 14.2 牌的 shader 還有沒用到的參數

`count===606`（牌的 3D 本體，與高亮用的 `count===6` 是不同 program）：

```
_MainTex_ST  _TileTex_ST  _SplitThreshold
_ColorLight  _ColorUnlight  _Tint  _WorldSpaceLightPos0
hlslcc_mtx4x4unity_ObjectToWorld / WorldToObject / MatrixVP
```

`_ColorLight` / `_ColorUnlight` / `_SplitThreshold` 代表牌的受光面與背光面是分開的，
可做比整張染色更細緻的效果。**尚未使用。**

（先前推測 `_AlphaScale` / `_AlbedoIntensity` 也在牌上——**推測錯誤**，
那兩個屬於別的 shader program。）

### 14.3 副露彈出面板的判準換掉了

原本：「出現頻率 < 25% 的 draw 就當成按鈕」。
實測結果是**整個畫面被染色**——動畫、特效、過場 UI 全都是低頻的。

改為**基準線比對**：沒有副露機會時持續收集 draw 簽章當基準，
有機會時只染基準線裡沒出現過的。按鈕是「機會出現才有」的東西，
這個判準比頻率精確得多。實測基準線約 54 個簽章即穩定。

### 14.4 日誌分級與分檔

先前所有東西寫進同一個檔，而 LiqiParser 每解一個 protobuf 欄位就寫一行。
實測比例：

| 檔案 | 大小 |
|------|-----:|
| `naki-events.log`（對局時間軸） | 1.4 KB |
| `akagi_websocket.log`（合併，已排除 trace） | 43 KB |
| `naki-liqi.log`（解析細節） | **191 KB** |

要回答「剛剛有沒有出現過和牌機會」得靠 grep 才找得到。現在 `tail naki-events.log`
就看得完。分級為 `trace` / `info` / `event`，各類別另有完整檔案。

同時修掉一個重複：`DebugServer.log` 自己加時間戳後又透過 `onLog` 送進 `bridgeLog`
再加一次，檔案裡變成 `[ts] [Bridge] [ts] 訊息`，且同一件事出現兩行。

### 14.5 副露後的推薦是假的

**這是「有時候不會丟最推薦的牌」的真正原因。**

```
bot.react returned nil (no action needed)
自己碰/吃後，需要選擇打牌
updateRecommendationsFromCurrentMask: mask has 9 valid actions
Using uniform probabilities for 9 actions      ← 均勻分布
Generated 8 recommendations after meld
→ 自動檢查: discard-4m
```

MJAI 協定在自己吃／碰／槓之後不會再送事件要你打牌，`bot.react` 回 nil。
為了不讓對局卡住，程式改從 action mask 生推薦——但那是**均勻機率**，
等於「拿 mask 裡第一個合法的牌」，完全沒有經過模型。

| 情境 | 推薦來源 |
|------|---------|
| 摸牌後打牌 | Mortal 真的推論（機率有差異） |
| **吃／碰／槓之後** | **均勻分布，等於沒推論** |

**影響比 §12 的兩個 P0 更大**：P0 要撞到和牌機會才觸發，這個每次副露都會發生。
而且側欄顯示得與真推薦一模一樣，使用者看不出差別——正是 §13 要防的那類問題。

修法與驗收見 task #6。**在修好之前，副露後的推薦不應被當成 AI 判斷。**

## 15. 本輪修正（2026-08-01）

### 15.1 §14.5 副露後假推薦 — 已修

`MortalSwift 0.5.1` 加了 `inferCurrentState()`：直接用當前 state 編 observation
與 mask 跑一次推論，不需要有 MJAI 事件觸發。`NativeBotController` 的
`updateRecommendationsFromCurrentMask` 改呼叫它。

均勻分布的路徑沒有刪掉，但降級成**只有推論真的失敗才走**，而且會留下明確警告——
以前它是正常路徑且靜默，那才是問題所在。

**驗收**：event log 出現 `[Bot] 副露後推論:` 而不是 `退回均勻分布`。
需要一次真實的吃／碰。**未 live 驗證。**

### 15.2 Legacy path 接上 resolver — 已修

`LegacyWebViewModel.triggerAutoPlayNow` 以前直接送 `recommendations.first`：
沒有 oplist 合法性檢查、沒有座位檢查、沒有過期檢查、沒有 fail-closed。
也就是說「伺服器說可以自摸但 AI 想打牌」時，它會忠實把和牌牌打掉——
那正是主路徑用 resolver 擋住的情況。

現在兩條路共用 `AutoPlayDecisionResolver` + 送出前的 stale 檢查，
並補上「oplist 有和牌但模型無推薦 → 仍交給 resolver」的閘門。

剩下的差異是**重試**：主路徑 hora send 失敗會重試，Legacy 送一次就結束。
這是刻意保留的——Legacy 是舊 WKWebView，不想在沒有 live 驗證的路徑上加重試迴圈。

**未 live 驗證**：macOS deployment target 是 26，本機跑不到 Legacy。

### 15.3 隱藏玩家名稱 — 用協定層重做

舊實作靠 `uiscript.UI_DesktopInfo`，Unity 客戶端沒有這東西（§13）。
新實作在 `naki-websocket.js`：`message` listener 在 WebSocket 建構當下註冊，
一定排在遊戲自己的 handler 前面，而 `event.data` 的 ArrayBuffer 是同一份記憶體，
就地改 bytes 遊戲就會讀到改過的內容。

**等長覆寫是硬性條件。** protobuf string 前面有 varint 長度前綴，改長度就得
連動外層每一層 nested message 的長度，一路錯到底。等長則完全不碰結構，
最壞情況只是名字變成怪字串，不會讓遊戲解析爆掉。

範圍刻意收窄到 `.lq.FastTest.authGame` 的 RESPONSE（`ResAuthGame.players` /
`.robots` 的 `PlayerGameView.nickname`），因為名牌是在那裡設定的。解析中途
遇到看不懂的東西一律 return、維持原狀——fail-open 成「名字照常顯示」，
而不是 fail 成壞封包。

**已驗證（node 合成 frame）**：長度不變、關閉時 bytes 完全不動、非 authGame
的 RESPONSE 不動、垃圾 bytes 不丟例外、短名字降級成 `P1` 而非截斷成 `Pl`。

**已知限制（不是 bug，是範圍）**：
- 斷線重連走 `syncGame`／`ResEnterGame`，不在範圍內。
- 終局結算走 `NotifyGameEndResult`，不在範圍內。
- 對局中途才打開不會生效——名牌在 authGame 當下就畫好了。

**未 live 驗證**：沒有實際對局確認名牌真的變成 Player 1–4。
