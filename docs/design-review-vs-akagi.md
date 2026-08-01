# 設計檢討：對照 Akagi v3

**資料日期**：2026-08-01
**對照對象**：[shinkuan/Akagi](https://github.com/shinkuan/Akagi) v3.4.1（Rust + Tauri 單一 binary，569 commits）

這份不是功能清單抄寫。每一項都對應**本輪 session 實際踩到的痛點**，Akagi 的做法只是佐證那個痛點有更好的解法。沒有對應痛點的差異（i18n、主題、應用內更新、對局統計圖表）不列入。

---

## P1 對局錄製與 replay

**Akagi**：每一局完整的 mjai event stream 存成 `history/games/<ulid>.mjai.jsonl`，加上 `index.jsonl`。只有產生 `end_game` 的完整對局才落盤。

**Naki 現況**：沒有。`MJAIEventStream` 有 `eventHistory` 但只在 process 內、只為重連重播。

**今天的代價**：

- 莊家第一打 oplist 沒被記錄的 bug——查到 `ActionNewRound` 有 `operation` 但 `record` 回 nil，然後**沒有那個封包可以再看一次**，只能加診斷等它下次發生。
- soak test 只跑完 5 局。每一次驗證都要真的打一局，一局 12–14 分鐘。
- 「副露後推論是不是真的」靠的是比對機率分布，因為沒有可重跑的固定輸入。

**建議**：把 `MJAIEventStream` 的事件流落盤，加上原始 WS frame。有了它：

1. bug 可以重現——把錄下的 frame 餵回 `MajsoulBridge` 就好，不用等真人對局
2. 回歸測試從「跑 10 局看看」變成「replay 20 局錄影，diff 決策」
3. encoder / resolver 的改動可以離線驗，不必碰伺服器

這是**投報率最高的一項**：它把本文其他每一項的驗證成本都降下來。

---

## P2 Inspector：frame ↔ event ↔ bot reaction 對照

**Akagi**：Inspector 分頁有三種條目——WS Frame（原始 binary + 第一層解析）、MjaiEvent（送進 bot 的）、BotReaction（含 meta / q-values）。並顯示「每個 WS frame 產生了幾個 mjai event」。

**Naki 現況**：六個分類 log，但**沒有跨層對照**。

**今天的代價**：我手動解了四次 base64 varint 才拿到錯誤碼：

| 碼 | 意義 | 花掉的時間 |
|----|------|-----------|
| 1004 | socket 未完成登入 | 選線判準改了五版 |
| 1023 | 對局進行中不能建房 | 一輪 |
| 1105 | 已在友人房中 | 一輪 |
| 1306 | match_mode 不存在 | 兩輪（先誤判成段位不符）|

每一個都是「`sendRaw` 回 `success: true`、實際失敗」，錯誤碼藏在 RESPONSE 的 `field1` base64 裡。

**建議（分兩階段）**：

**最小可行**——`LiqiActionSender` 收到 RESPONSE 時，若 `field1` 存在就自動解 varint 並印出錯誤碼。**這一項今天就能省下數小時**，改動不到 20 行。

**完整版**——`/inspector` 端點回傳最近 N 筆的 frame → parse → mjai events → bot reaction 對照，MCP 也能讀。

---

## P3 每次執行獨立的 log 目錄

**Akagi**：`<log_dir>/<YYYYMMDD-HHMMSS>/`，內含 `all.log`、per-module log、`proxy.binlog`（原始 binary frame）、`majsoul/<flow_id>.mjai.jsonl`。要回報 bug 就整包送出。

**Naki 現況**：固定檔名寫在 temp（`akagi_websocket.log`、`naki-events.log` …），靠 `.1`–`.5` 輪替。

**今天的代價**：

- `xcodebuild test` 是 app-hosted，會用**同一組檔名**——所以「跑測試」和「App 正在跑」互斥。今天因此必須先停 soak 才能跑測試。
- soak 腳本要從一個被多方寫入的共用檔案裡切出「這一局」的範圍，`anom-N.txt` 因此變成累計而非單局。
- 輪替可能在對局中途發生，log 就斷了。

**建議**：啟動時建 `~/Library/Logs/Naki/<timestamp>/`，所有分類寫在裡面。test host 自然不會撞到，soak 也不用切範圍。

---

## P4 liqi 協定的漂移防護

**Akagi**：`scripts/` 有「self-host liqi proto extraction from the Unity client」——直接從 Unity 客戶端抽 proto。

**Naki 現況**：`docs/protocol/liqi.json` 是靜態快照。CLAUDE.md 寫著「2026-08-01 repo snapshot 與 live CDN byte-identical」，但**沒有任何機制維持這件事為真**。

**今天的代價**：`lobby_match_modes` 的對照表整組偏移一格（銅之間四人東實際是 2，表上寫 1），而且 `liqi.json` 幫不上忙——`match_mode` 沒有對應 enum。最後是攔遊戲自己送的 `fetchCurrentMatchInfo` 才解出 `[2, 3, 17, 18]`。

**建議**：

1. 一支 `scripts/check-liqi-drift.sh`：抓 live CDN 的 liqi.json 與 repo 版本 diff，不一致就非零退出
2. 對 liqi.json 沒有 enum 的值（`match_mode` 之類），改成**從遊戲流量學習**而不是寫死表——攔 `fetchCurrentMatchInfo` 就能得到當前房間的真值

---

## P5 `WebViewModel` 是 god object

**Akagi**：「Subsystems own only their bus handles, never each other. `src/event_bus.rs` is the single source of truth.」

**Naki 現況**：`WebViewModel.swift` **1476 行**，一個型別同時負責：

導覽事件、JS 注入、Liqi 送出通道、自動打牌觸發與重試、決策閘門、高亮同步、隱藏名稱、Debug server 接線、截圖、對局生命週期。

**今天的代價**：本輪的 bug **全部集中在這個檔案**，而且是互相干擾的：

- 副露自動送「過」的競態（推薦尚未同步 vs 1 秒輪詢）
- 「沒有 oplist 就別觸發」的閘門加上去後，和「有對局就等待」的閘門互相打架造成死結
- 重試框架、決策、觸發去抖三者交織，改一個要同時想另外兩個

這不是「檔案太長」的美學問題。**是因為這些關注點交織在同一個狀態機裡，所以加防護時看不出它會擋掉別的路徑。**

**建議**：先切出邊界最清楚的一塊——`AutoPlayCoordinator`（觸發 / 去抖 / 閘門 / 重試 / 送出結果處理）。它有明確的輸入（推薦 + oplist snapshot + mode）與輸出（LiqiSendResult），可以單獨測，不需要 WebPage。

---

## P6 動作延遲模型

**Akagi**：可設定的延遲模型，且他們特地「harden the Lua delay sandbox and correct delay-model」——代表這塊被認真對待過。

**Naki 現況**：固定 1.0–1.9 秒。

**兩個代價**：

1. **固定時序是指紋。** 每次都在同一個區間送出，統計上與人類可分。
2. **今天的驗證困難**：`/screenshot` 回 4 MB PNG 要 1–2 秒，而送出只等 1.9 秒——**截圖常常拍到牌已經打掉之後**，導致「非推薦牌透明度有沒有生效」至今無法定論。

**建議**：延遲改成可設定的分布（依動作類型不同——打牌快、副露慢、和牌立即），並提供「驗證模式」把延遲拉長，讓截圖來得及。

---

## P7 點擊能力：一個要想清楚的取捨

**Akagi**：AutoPlay「clicks the table through the Chromium capture backend (CDP)」——**它是點的**。

**Naki**：一律走 Liqi 協定。CLAUDE.md 明文禁止座標點擊。

**Naki 的做法在遊戲動作上更穩**：座標依賴解析度、動畫、皮膚；點錯會送出錯誤動作；而且沒有回饋。這個判斷不變。

**但今天暴露了它的邊界**：`startRoom` 之後**客戶端不會自己進場**。伺服器開了局（`fetchGamingInfo` 有 `connect_token`），客戶端停在大廳。協定層叫得動伺服器，叫不動客戶端的 UI 換頁。

結果是每局固定浪費約 2 分鐘在 `bot_sync` 重連自救上，而且要靠兩層 fallback 才進得去。**Akagi 直接點「開始」就好。**

**建議**：不要為了遊戲動作引入點擊——那個取捨 Naki 判斷正確。但可以考慮一個**極窄的例外**：只用於大廳／房間導覽（進場、確認結算）。這類元素位置穩定、點錯的後果是「沒反應」而不是「送出錯誤動作」。

這一項我標成「要想清楚」而不是「該做」——引入點擊就引入了整類新的脆弱性，值不值得取決於你多在意那 2 分鐘。

---

## P8 三麻

**Akagi**：真的有三麻 bot（`akagi-native3p`），`bot.active_4p` / `bot.active_3p` 依桌上人數自動切換。

**Naki 現況**：`is3P` 只改自己的狀態與標籤，**三麻仍送進四麻 model**。已在 CLAUDE.md 標明不得宣稱支援。

**Akagi 的存在證明這個缺口是可補的**——他們自己訓了一份。Naki 先前查過沒有公開三麻權重，Akagi 是自訓 + 內嵌。

---

## P9 fallback 的哲學

**Akagi**：雲端推論失敗時「the bot plays the local model's move so a live game never stalls」——fallback 是**另一個真實模型**。

**Naki 先前**：副露後退回**均勻分布**，等於「拿 mask 裡第一個合法的牌」，而側欄顯示得跟真推薦一模一樣。（本輪已修。）

**該內化的原則**：fallback 可以更弱，但必須是**同一種東西**。「更差的決策」可以接受，「看起來一樣但其實不是決策」不行。這條原則也適用於本輪修掉的另外兩處——`inGame` 的語意、`❌` 的措辭。

---

## Naki 目前優於 Akagi 的地方

避免單向抄襲，這些不要為了對齊而丟掉：

| 項目 | Naki | Akagi |
|------|------|-------|
| 安裝門檻 | 開 App 就好 | 要信任 CA（MITM）或裝 Chromium profile |
| 推論硬體 | Apple Neural Engine | CPU（candle）|
| AI 助理整合 | MCP server，42 個工具 | 無 |
| 遊戲動作可靠性 | 協定層，有 RESPONSE 可查證 | CDP 點擊 |
| 隱藏玩家名稱 | 協定層等長改寫 | 無 |
| 平台原生度 | SwiftUI，macOS/iOS | Tauri webview |

---

## 建議順序

| 順位 | 項目 | 理由 |
|------|------|------|
| 1 | **P2 最小版**（自動解錯誤碼）| 20 行，今天就能省下數小時 |
| 2 | **P1 對局錄製 + replay** | 把其他每一項的驗證成本都降下來 |
| 3 | **P3 per-session log 目錄** | 解掉 test 與 live app 互斥 |
| 4 | **P5 切出 AutoPlayCoordinator** | 本輪 bug 的集中地 |
| 5 | **P6 延遲模型** | 指紋 + 驗證窗口 |
| 6 | **P4 協定漂移防護** | 目前靠人記得 |
| 7 | **P7 窄範圍點擊** | 要先決定值不值得 |
| 8 | **P8 三麻** | 工作量最大 |
