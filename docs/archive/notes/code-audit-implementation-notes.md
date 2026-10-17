# 全程式碼審查與修正 — implementation notes

日期：2026-09-30。基準：`48add0a`（工作樹乾淨）。範圍：Naki `command/`、內建 JS、naki-plugins 三個插件。MortalSwift 不含。

## 流程

1. 五條流程平行審查（入站協定／狀態→Bot／自動打牌／WebView＋插件／Debug＋測試），約 120 個候選。
2. 三份獨立復驗（崩潰類／對局後果類／安全＋插件類），逐條對照程式碼並試著反駁。
3. 依檔案範圍分五個工作包修正，範圍互不重疊；全部落地後統一 build＋測試，再獨立復驗。

審查與復驗原始報告在 session scratchpad（`audit-*.md`、`verify-*.md`），不進 repo。

## 舊 P0 再驗證

| 項目 | 現況 |
|---|---|
| 對局中 lobby socket 開啟觸發 reset | 已修（`WebSocketInterceptor.swift:503-509`，只在雀魂連線數 0→非 0 觸發） |
| varint 溢位／`chang` 負索引崩潰 | 已修（`LiqiEnvelope.swift:83`、`MajsoulBridge.swift:597`）；但修法讓負數 int32 全解不出來，見 P1 |
| 推薦過期時漏和 | 已修（stale guard 對和牌放行）；無 live 和牌樣本 |
| issue #2（MajsoulMax 併用） | 已修（response 按欄位號取 payload） |

## 工作包

| 包 | 範圍 | 主要項目 |
|---|---|---|
| P1 協定 | `Bridge/Liqi*`、`MajsoulBridge`、`ObservedMatchSids`、`WebSocketInterceptor` | 負數 int32 解碼、表情／oplist 轉型崩潰、NOTIFY 按欄位號取、W 立直、負分開局後停餵 bot、token 不進 log |
| P2 Bot | `Bot/Cloud*`、`BundledCoreMLBot`、`NativeBotController`、`NakiWebCoordinator`、`GameModels` | Retry-After 崩潰、三麻雲端問錯事件、推論失敗不合成推薦、拋錯時清推薦並提示、暱稱不上傳雲端 |
| P3 自動打牌 | `Bot/AutoPlay*`、`ActionDelayModel`、`AutoRematchEngine`、`DecisionSidebar` | 三麻和牌必送、副露不搶先送過、首選未授權退次選、立直宣言牌對照伺服器清單、延遲不超過伺服器時限 |
| P4 WebView／插件／UI | `Web/`、`Plugins/`、`NakiRuntime`、`ContentView`、`SettingsStore`、App 入口 | ⌘N 崩潰、插件設定非有限值崩潰、匯入路徑穿越、更新需確認、L3 開關重建注入、導覽迴圈重訂閱 |
| P5 Debug／MCP／log／測試 | `Debug/`、`MCP/`、`LogManager`、`LiqiActionSender`、`scripts/` | 測試不再清正式 App 偏好設定、錄影不被輪替刪除、工具參數轉型崩潰、`/js` 回傳非 JSON 型別崩潰、Host 檢查 |

## 決策（統帥代決）

- **負數解碼**：保留 `decodeVarint` 非負契約，另加有號版本只用在 int32 欄位。理由：下游多處依賴非負，全面放寬的影響面無法在沒有 live 樣本下驗完。
- **開局解析失敗（分數／場風解不出）**：本局停餵 bot（`end_kyoku` 除外），oplist 照常更新。理由：伺服器授權的和牌仍要能送；寧可整局不推薦，也不拿上一局牌況打牌。負分本身已能解，不再是觸發條件。
- **推論失敗**：不合成均勻分布推薦。理由：寧可讓伺服器逾時代打，也不送非模型判斷的牌。
- **三麻和牌**：和牌檢查提到三麻限制之前。理由：和牌由伺服器授權，不需要模型。
- **錄影保存**：輪替時跳過含錄影的 session，不搬位置。理由：不動 replay 工具的路徑約定。

## 不處理（附理由）

| 項目 | 理由 |
|---|---|
| 槓的選擇（C2） | 送的一定是伺服器授權的合法槓；推薦不帶槓種，需改推薦資料模型 |
| 回音逾時重送（C9／C11）、跨拍重試上限（C12） | 伺服器對重複請求的反應未知，需 live 樣本 |
| Debug server 認證（E8） | 需要設計 token 發放與各腳本配合，另案 |
| 插件 capability 不具強制力（D-09） | 文件明講的信任邊界；同一 JS realm 無法強制 |
| 手動工具與引擎協調（E10） | 復驗：引擎每次嘗試先驗 oplist 仍有效，實害限於手動送 pass |
| msgId 號段相撞（A6，若需跨包） | 連跑約 67 小時才會發生 |

## 副作用紀錄（本次作業造成）

- 今天三次啟動（一次測試、兩次開 App）各擠掉一個 8/11 以前的 log session；現存錄影已備份到 `note/recordings-backup-20260930/`。
- 跑 NakiTests 會清掉正式 App 的 `naki.observedMatchSids`；目前該 key 不存在，無法分辨是否今天清掉的。P5 修正測試隔離。

## 背景保活（P7，2026-09-30 追加）

需求：長時間 AFK 回來會跳斷線／閒置提示。`naki-core.js` 包住 rAF（隱藏時改由計時器驅動）並對頁面隱藏真實可見性；`SettingsStore.keepAliveInBackground` 預設開，設定頁可關。

- **Why 做成可關**：背景持續跑 Unity 主迴圈會耗 CPU／GPU，且會攔下頁面的 `visibilitychange`。
- **第一版無效**：長時間對照（關 22 分鐘 → 開 22 分鐘）兩組都在隱藏約 10 分鐘後降到 2 次／分，且那 2 次是主線每分鐘 `/js` 戳頁面才有的；停止戳頁後整夜（6.5 小時）零活動，叫回前景才自動重連。結論：WebContent process 被系統整個暫停，頁內計時器救不了，但 `callJavaScript` 能喚醒它。
- **第二版**：`WebSession` 隱藏時每秒 `callJavaScript` 一次 `__nakiKeepAlive.tick()`，並持有 `.userInitiatedAllowingIdleSystemSleep` activity；Legacy（WKWebView）另設 `inactiveSchedulingPolicy = .none`。**live 已驗證**（隱藏 35 分鐘心跳 7–9 次／分）；更長時間（數小時）與螢幕睡眠情境未驗。

## 驗證

| 閘 | 結果 |
|---|---|
| NakiTests | 第一輪 691 → 第二輪 714 tests，0 failures（基準 604） |
| `plugin-regression.cjs`／`name-hider.cjs`／`keepalive-regression.cjs` | 23/23、7/7、11/11 |
| macOS Debug／Release build、iOS Simulator build | 皆成功 |
| 新版 App live：兩個既有插件仍有效並註冊 | 已驗證 |
| 獨立復驗第一輪（協定＋Bot／自動打牌／WebView＋Debug）＋ code review（high） | 完成；必修項全部進第二輪修正 |
| 獨立復驗第二輪（Opus） | 可 commit、無必修項；10 個 mutation 殺死 9 個（存活的是憑證關鍵字 `Code` 沒有專屬測試） |
| 第二輪修正後整合閘 | NakiTests 714 tests 0 failures；JS 三套全過；Release／iOS build 成功 |
| Live（2026-10-01 07:49，`soak-test.sh 1`，60 秒友人房＋人機，自動模式） | 一局 76 個動作、13 次立直觸發、榮和 1 次完整鏈路（推薦 hora@98.5% → `inputOperation` payload `0809` → RESPONSE ✅ → `ActionHule`）；`ActionHule.delta_scores` 負數已能解（parse fault 只剩既有的 `ActionMJStart`）；oplist `timeFixed=60000`，**單位毫秒**；插件在出牌前完成染色；無停滯、無阻斷 |
| Live 背景保活 | 第一版（僅頁內計時器泵）：隱藏 10 分鐘後心跳降到 2 次／分，停止外部戳頁後整夜零活動——**無效**。第二版（Swift 每秒 tick＋activity assertion）：**隱藏 35 分鐘、期間不戳頁面，心跳全程 7–9 次／分**（與可見時相當），連線未中斷（兩次 socket 關閉皆立即重連，屬遊戲自身的重握手） |
| 收尾包後最終整合閘 | NakiTests 717 tests 0 failures；JS 三套全過；Release／iOS build 成功 |

未驗證：所有需要實際對局的行為（三麻、W 立直、立直宣言牌、和牌送出）、Debug server 的 403／411／逾時（未對 live server 測）、iOS 實機、各確認對話的互動。

## Deviations

- **P1**：`end_game` 不受「本局被擋」影響（屬整場）；authGame 座位失敗不設該旗標。msgId 登記制改由接線包完成。
- **P2**：重連重放不打雲端改用「送雲端前確認該決策點的授權仍 pending」（`serverAuthorization: (UInt64) -> Bool`），未沿用抑制計數——協調層看不到重放批次邊界。代價：live 時授權已被消化的那一手，四麻改用本地推薦。
- **P3**：副露寬限期 2 → 8 秒（引擎拿不到「推論進行中」訊號）；立直宣言牌在伺服器清單裡找不到任何推薦時退回舊行為；延遲上限只用總時限、未扣已經過時間；C13 未改（伺服器對「過」的回應語意未知）。
- **P4**：更新確認為整批確認／取消，無逐項勾選；`-999` 不當導覽失敗回報。
- **P5**：沒有 Host header 的請求放行；沒有 body 的 POST 不回 411；`bot_trigger` 只能回「已排入」（拿真正結果需改引擎，有雙送風險）。
- **流程**：整合閘由主線直接跑，未包成 verify.sh 交復驗者重跑。

## 待修（復驗前已知）

- test host 啟動會觸發 log 輪替，把**執行中 App** 的 session 目錄刪掉（今天實際發生）。→ XCTest 下不輪替。
