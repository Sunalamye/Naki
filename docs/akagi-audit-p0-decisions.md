# Akagi issue 稽核：三個 P0 的修法決策

**日期**：2026-08-07
**分支**：`fix/akagi-audit-p0`
**來源**：掃 [shinkuan/Akagi](https://github.com/shinkuan/Akagi) 全部 89 個 issue（開/關都看）對照 Naki 原始碼，查出 9 條會在 Naki 發生的問題，本輪修其中三個 P0。
**驗收**：512 tests 通過（原 494，新增 18），Debug／Release build 皆過，每條修法都有 mutation 驗證。**全部只有機械驗收，沒有 live 對局驗證。**

設計面的對照見 [`design-review-vs-akagi.md`](design-review-vs-akagi.md)（2026-08-01，那份比的是架構；這份比的是具體 bug）。

---

## D1. 連線狀態的語意從「頁面上有 WebSocket」收窄成「還連著幾條雀魂線」

**問題**（對應 Akagi #206，同構但故障邊相反）：`handleWebSocketConnected` 無條件呼叫
`onWebSocketStatusChanged?(true)`，而那個回調做的是 `MajsoulBridge.reset()`——清掉
`LiqiOperationStore`（自動打牌唯一的決策授權來源）、parser 的 msgId 對照表、
`doras`、`lastDiscard`——再重建 Bot 並重放整局歷史事件。

雀魂一個分頁會反覆開關 route 探測與大廳連線，而對局跑在另一條 `game-gateway` 上
從頭到尾沒動。**live log 佐證**（`~/Library/Logs/Naki/20260806-225732/`）：同一個
session 重置 9 次、其中 5 次在對局進行中，緊接著就是 `skip:noOplist`。

Akagi 的形狀是 close 側（探測 socket 關閉時清掉 page handle），Naki 是 open 側。
Naki 的影響更直接：Akagi 清的是點擊用的 handle，Naki 清的是決策授權本身。

**取捨**：Swift 側要判斷「這條是不是雀魂」有兩條路——自己用 URL 判一次，或讓 JS
把已經算好的 `isMajsoul` 帶過來。選後者：URL 判準（`isMajsoulWebSocket`）已經在
JS 有一份，Swift 再寫一份就是**同一條規則兩個實作**，那是最典型的靜默漂移來源
（`LiqiEnvelope` 檔頭記錄過同一個教訓）。代價是 bridge 訊息契約多兩個欄位，
而那張契約表本來就在 `WebSocketInterceptor` 的 doc comment 裡，一併更新即可。

**決定**：`connectedSockets` 只收雀魂線；`connected` 只在**由空轉非空**時報 true
（對稱於 close 側原本就有的「全空才報 disconnected」）。

**附帶**：`WebSocketMessageHandler` 補了 `nonisolated deinit`，並把訊息分派抽成
internal 的 `dispatch(type:data:)`。後者純粹是為了可測——`WKScriptMessage` 沒有
公開的 initializer，這正是 `onWebSocketStatusChanged` 在 NakiTests 曾經零命中的原因。
為測試而動可見性要有明確理由，這裡的理由是「否則這條路徑永遠測不到」。

---

## D2. 漏和的例外開在三處，而不是把和牌整個提前到閘門

**問題**（對應 Akagi #13）：`AutoPlayGate` 的 `.forceHora` 只在推薦**為空**時觸發；
推薦非空就落到 `.proceed`，而 `.proceed` 在進 resolver 之前有一道 stale guard。
榮和視窗帶新 oplist 抵達、該批沒刷新推薦、上一個決策點的推薦還在且序號較舊 →
每一拍都回 `notSent`，一路到伺服器逾時。**漏和不可逆。**

**第一版修法是錯的，記下來避免重蹈**：把 `snapshot.horaOperation != nil` 提到
`recommendations.isEmpty` 之外，讓所有和牌都走 `.forceHora`。結果 fixture C／E 轉紅。
那不是誤報——`.forceHora` 直接送和牌，**跳過了 resolver 的覆蓋機制**，於是
「AI 想打什麼、被伺服器覆蓋成什麼」這個診斷資訊整個消失，而 fixture C 正是在鎖
那條可追溯性（`run.overrode` 與 log 裡的「決策覆蓋」）。

功能上兩者都送出和牌（fixture C 驗 bytes 的那兩條斷言沒有失敗），差別只在路徑。
但那個路徑帶著診斷價值，不該為了少寫兩行而丟掉。

**決定**：保留 resolver 覆蓋路徑，改為在**擋住它的每一道關卡**上對和牌開例外。
實際有三道（比原本判斷的多一道）：

1. `AutoPlayGate` 的 `notMyDiscardTurn`——榮和視窗的 oplist 沒有 discard，而 stale
   推薦是 discard，所以會先在這裡被擋掉，根本走不到 stale guard。**這道是查證時
   才發現的**：測試第一次跑出來的失敗訊息是 `skipped(notMyDiscardTurn)`，不是
   預期的 `notSent(recommendations_stale)`。
2. `AutoPlayEngine` 輪詢路徑的 stale guard——自摸視窗（oplist 有 discard，不觸發
   第 1 道）。
3. `AutoPlayEngine` 手動路徑的 stale guard——MCP `bot_trigger`，使用者手動救援的那條。

三道各自有測試，三次獨立 mutation 各自讓對應的測試轉紅。**只驗一道會漏掉另外兩道**
——第一次 mutation 時只有 manual 那條轉紅，才發現輪詢路徑沒被鎖住。

**反向鎖**：另加一條測試斷言「沒有和牌機會時，stale 推薦仍然擋下來」。例外只開給
和牌，不能把整道防線一起拆掉——那道防線本來是防「拿舊推薦回應新機會」送出錯的動作。

---

## D3. varint 最多接受 9 bytes，超過一律視為畸形輸入

**問題**（對應 Akagi #52，但 Swift 的後果嚴重得多）：`decodeVarint` 的溢位檢查
寫在 `shift += 7` **之後**且用 `> 63`。第 9 個 byte 把 shift 推到 63，`63 > 63`
為 false 於是放行；第 10 個 byte 的 `<< 63` 正好打在 `Int` 的符號位上，若那個 byte
的最高位是 0 就直接把**負數**回傳出去。

Akagi 是 Python，`index out of range` 是可捕捉的例外。Swift 的陣列越界是 **trap**：
接不住，整個 App 當場結束，連 log 都留不下。

**決定**：檢查移到 `result |=` 之前並改成 `>= 63`，即最多接受 9 bytes（63 bits）。

**取捨**：這會拒絕合法但超過 63 bit 的 protobuf varint。接受這個限制——liqi 的
每個欄位都是小正數，超過就是畸形輸入或解錯位（例如 XOR 規則變了、解出近似隨機
bytes）。寧可拒絕也不要回傳一個下游沒有任何一處預期的負值。

**一個被推翻的判斷**：稽核報告原本說 `BAKAZE_NAMES[chang % 4]` 是 crash 點。
實測 `chang = 7` **不會** crash——`7 % 4 = 3` 是合法索引，只會產生錯誤的場風（北）。
真正的 crash 只能來自負值，而負值只能來自 varint 溢位。所以：

- **varint 那層才是根因**，也是唯一真正防住 crash 的地方。
- `chang`／`ju` 的範圍檢查與 `actorSeat` helper 是**縱深防禦**，防的是「大的正值
  導致靜默的錯誤」而非崩潰。

這個區分重要，因為它決定了哪一層不能被改掉。

**`actorSeat` helper 的理由**：五處裸的 `data["seat"] as? Int` 各自加檢查會漂，
收成一個 helper。範圍外的正值不會崩——會被下游 MortalSwift 的 `% 4` 折回去，把
別人的動作**靜默記到自己頭上**，污染 observation 而且畫面上完全看不出來。那比
丟掉一個事件糟，所以選擇丟棄並記 degraded fault（UI 看得到），而不是放行。

嚴重度分級沿用既有語意：開不出一局是 blocking（整局不做推薦，掛常駐橫幅），
丟一個事件是 degraded。

---

## 仍未驗證

- 三條都**沒有 live 對局驗證**。#12 的確認方式是跑一局、在對局中觀察 lobby socket
  開啟時 log 不再出現「重置」與「重新同步 Bot」。
- #13 照 CLAUDE.md 的完成判準，仍需要 live fixture（server `[1,7,8]` + AI discard →
  resolver hora → RESPONSE → `ActionHule`）才能宣稱漏和已修復。
- 本輪未動的 6 條會發生的問題見 task #15–#27（九種九牌三麻停擺、liqi schema 漂移
  偵測、雲端 key 啟用語意、autoplay 失敗零 UI 訊號、連線失敗可觀測性、release.sh
  版本號順序）。

---

# 第二輪：P1／P2（同日稍後）

三個 P0 之後繼續往下修，本節記其餘決策。**529 tests 通過**（起點 494），
Debug／Release build 皆過。

## D4. 九種九牌補齊四段，而不是在 mapper 加一個特例

`ryukyoku` 標籤原本落 `CloudDecisionMapper` 的 default 回 nil，而三麻是雲端-only、
沒有本地兜底 → 整手無推薦 → 停擺到雀魂逾時代打。

**取捨**：可以只在 mapper 補一個 case 讓它不回 nil，但那樣 resolver 與 executor
仍然不認得這個動作，結果是「有推薦但送不出去」——換一種形式的卡住。
照 2026-08-05 補拔北的同一條路補滿四段（ActionType 槽位、mapper 兩處、
resolver `isSupported`、executor switch），因為 Liqi 層（`kyushu` type 10）早就齊了。

**副作用**：兩個既有測試把 `ryukyoku` 當「未知型別」的測資，必須換掉。
那兩條的註解本來就記錄了這個模式（「kita 已於 2026-08-05 接上，改用真正未知的型別」）
——**測資會隨功能接上而過期**是這類測試的固有性質，已在註解寫明下一個人要怎麼換。

## D5. 發布腳本：bump 移到 build 之前，並用產物自證

舊順序是 build → package → bump，於是打包出去的 binary 帶**上一版**版本號。
腳本自己當時還印著「版本此時還是舊號，稍後 bump」。

**取捨**：只調順序的話，同一個坑下次還會被踩回去（它本來就是「先 build 比較直覺」）。
所以 build 之後加一道 `PlistBuddy` 讀 `CFBundleShortVersionString` 與目標版本比對，
對不上就非零退出——**讓機器記得，不靠人記得**。

bump 之後工作樹就髒了，任何一步失敗都會留下「版本已改、沒 commit 也沒產物」的中間
狀態（下次 preflight 會擋下自己），所以加了 `trap` 還原三個版本號檔案。

同時加了測試門禁（只跑 `NakiTests`——`-scheme Naki` 會連 `NakiUITests` 一起跑，
而那個要啟真 App、綁 8765、載 live Majsoul WebGL，拿它當發布門禁等於把發布綁在
網路與 live 頁面上）與 iOS 編譯步驟。`Naki-M.xcscheme` 補進版控：先前只靠 Xcode
autocreate，clean clone 不一定有。

`RELEASE.md` 裡那份「快速發布腳本」直接移除——它完全不 build（上傳 `dist/` 殘留檔案，
而 `.gitignore` 忽略 `dist/`）、不動 `MARKETING_VERSION`、push 到不存在的 `master`。
留著它就是留一個會發出壞 release 的陷阱。

## D6. 模型缺失的檢查放在第一次 `react`，不是 `init`

`MortalBot` 的建構子在模型檔缺失時**不 throw**：它建出 `hasModel == false` 的實例，
推論退化成「選 mask 裡第一個合法動作」，而 `/bot/status` 照舊回 `local`。
這是 AUDIT §14.5「副露後均勻分布假推薦」的同一個形狀。

**取捨**：最想放的位置是 `BundledCoreMLBot.init`，但 `hasModel` 是 actor-isolated
（`MortalBot` 是 actor），而 `init` 與其呼叫端 `NativeBotController.createBot` 都是同步的。
把 `createBot` 改成 `async` 會波及所有呼叫端。第一次 `react` 是最早能 `await` 到它的地方，
用一個 `modelVerified` 旗標讓它只付一次 actor hop 的成本。

## D7. 停滯回報是新的一條通道，不是多一行 log

引擎所有的失敗與略過都只走 `note(...)`，而它的兩個 sink 都是寫檔案的；`finish` 的
去重又讓同一個原因只印一行——**故障越持久，log 裡的痕跡越少**。同時側欄綠點讀的是
`botStatus.isActive`（推論層），推論照跑它就照亮。淨結果是「一手都沒送出、log 只有一行、
畫面顯示運行中」。

**取捨**：判準用「**有 pending oplist** 卻連續沒送出」，而不是「距離上次送出多久」。
後者在別人的回合會誤報（那時本來就不該送）。門檻 4 拍：`callPassGrace` 本來就會讓
副露機會等 2 秒推論，門檻要在那之上；伺服器給 300 秒，第 4 拍才出聲不算晚。

## D8. 延遲模型只移植拿得到上下文的維度

參數移植自 Akagi `assets/delay_default.lua`（Apache 2.0，校準自 30 局王座間、
約 21,500 個決策）。**已移植**：routine/think 混合、手切與摸切分開、牌種、
各動作的 log-normal、偶發長考。

**未移植**：巡目效應、對手立直效應、time bank 塑形——這三個都需要 Naki 目前沒有
追蹤的狀態，硬編一個猜測比不做更糟。

**刻意不做**：用模型信心值調整延遲。Akagi 做過（`top_prob < 0.60 → routine 機率 ×0.3`），
而它自己的 issue #225 實測發現那條規則在推薦分布平坦時幾乎每次都觸發，把快切群整個
消掉、延遲變成人類中位數的兩倍——修法就是把那條關掉。**Naki 原本「刻意不做」的立場
事後被證明是對的**，這次移植沒有把它改掉。

**已知剩餘差距**：抽樣值在 Naki 是 sleep 長度，而 Akagi 的同一個數字是「伺服器觀察到的
總時間」（會扣掉推論已花的時間）。本地推論影響不大，雲端往返會讓總時間系統性偏長。

## D9. 文件一致性列成紀律，而不是修完就算

`CLAUDE.md` 與 `AUDIT.md` 這輪查出四處與程式碼漂開（iOS 編譯狀態、executor case 數、
三麻模型路徑、liqi.json 的「已驗證」）。我自己就因為引用過時的 `AUDIT.md` 做出一個
錯誤判定。

所以除了改掉那四處，另外在 `CLAUDE.md` 加了「文件與程式碼的一致性」一節，把這四次
漂開列成表，並寫明：回答「目前是什麼狀態」一律以執行中的 loopback API、原始碼、
或當場跑一次 build/test 為準，文件只用來解釋「為什麼是這樣」。

## D10. #16／#22：把「做不了」拆成「真的做不了」與「我沒做」

第一次收尾時我把這兩條標成未做，理由寫「工程量大」「需要先決定策略」。
那個判斷有問題——它們各自有**一半是現在就能做的**，而我沒有分開看。

**#16 能做的一半**：`MajsoulBridge` 的未知 action 原本是 `default: break`，
那是整套 `LiqiParseFault` 機制唯一逃得掉的路徑——`liqi.json` 有 24 個 `Action*`
而 bridge 處理 9 個，沒處理的多屬活動場（雀魂最常改動的部分），靜默丟棄的表象
只是「某個情況下不給推薦」。改成記 degraded fault（同名只記一次），加上讓
`check-liqi-drift.sh` 明說「它比對的基準本身就過期」。

**真的做不了的一半**：從 Unity bundle chain 抽 descriptor。那需要解 Unity asset
bundle 格式 + Lua descriptor 解碼 + CI 接線，而且本機無法完整驗證（要實際抓 CDN
bundle）。這一條仍然是目前最大的未修風險。

**#22 能做的一半**：fixture 進版控。我當時說「要先決定 fixture 怎麼進版控」，
但那個決定其實很簡單——**匿名化**。原始錄影的 `start_game.names` 是四個真實玩家
暱稱（那正是它放在 gitignored 的 `note/` 的原因），換成 P1–P4 即可。

而且這個修法自帶驗證：名字不進 observation（Mortal 吃的是 1012×34 的牌局張量），
所以匿名化後**決策指紋必須與 baseline 相同**——測試通過就同時證明了這件事。
順帶把 `XCTSkip` 改成 `XCTFail`：fixture 現在在版控裡，缺席代表有人刪了它，
而不是「這台機器剛好沒有」。在此之前這條測試在別台機器上從未執行過，報告卻一直是綠的。

**教訓**：「這條要花很多力氣」與「這條現在做不了」是兩件事。前者不該讓後者的
配套修法一起停擺——尤其當那個配套修法就寫在自己列的 task 描述裡。

## 本輪未動的

- **task #16 的另一半**：從 Unity bundle chain 抽 descriptor（見 D10）。
  這是目前最大的一條未修風險。
- **task #22 的另一半**：`MajsoulBridge` 仍沒有專屬測試檔；`chi` 三種組合、
  三種槓的區別、紅五 consumed、`reach`→`reach_accepted` 時序都還沒有欄位級測試。
  另外 `ReplayFingerprintTests` 用 live Core ML 推論算指紋，而全專案沒設定
  `MLModelConfiguration.computeUnits`——換 compute unit 就換浮點捨入，
  要真正跨機器穩定得先釘住它。
- **task #19 的其餘部分**：`page.navigations` 迴圈 throw 後不重啟、白屏偵測、
  iOS 背景回收、`forceReconnect` 的對局中守衛。
