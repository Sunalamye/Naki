# UI 重設計：實作決策與實測發現

`prototype.html` 記的是「畫面長什麼樣」，這份記的是**為什麼這樣選、放棄了什麼**，
以及把它接進 shipping SwiftUI 時真實對局揭露的問題。日期一律 2026-08-09。

驗證環境：友人房四人東 + 人機（`room_quick_test` + `bot_sync`），macOS 26。

---

## 牌面：Unicode → Asset Catalog

**決策**：側欄牌面改用 FluffyStuff/riichi-mahjong-tiles（CC0）的 SVG，不再用 `MahjongTile.unicode`。

**為什麼**：系統字型把 `🀇🀙🀐` 畫成黑白線稿，在推薦列的尺寸下必須先「認出」線稿代表哪張牌，
才能對到牌桌上的立體彩色牌——而那是這個介面唯一要做的事。更硬的問題是**赤五無法表示**：
`5mr` 與 `5m` 是同一個 code point，舊版只能 `.foregroundColor(.red)` 把整張牌染紅，
而紅線稿與黑線稿在小尺寸下分不出來。

**取捨**：多 40 個資產檔（兩份 catalog 各 ~860KB）。換來赤五是獨立圖、尺寸可縮放、
可支援 Dynamic Type（舊版為了不錯位把字級寫死成 28/22，等於完全不支援）。

**踩到的坑**：這套資產把**牌身與牌面圖案拆成兩個檔**（`Front.svg` 是米白牌身，
`Man5.svg` 只有圖案、背景透明）。只畫圖案的話深色側欄直接透出來，是一堆浮空花紋。
`TileImage` 疊 `Utility/front`；`TileImageTests` 對這個資產單獨寫了一條測試，
因為它不經過 `assetName(for:)`，映射測試的迴圈驗不到——少了它每張牌都會壞，
而每個映射測試仍然全綠。

## 資產命名以 Naki 為主（`0m` → `5mr`）

**決策**：把赤五的 imageset 從天鳳慣例的 `0m/0p/0s` 改名成 MJAI 的 `5mr/5pr/5sr`。

**為什麼**：`Tile.mjaiString` 產出的是 `5mr`。保留兩套命名就得有一層轉換，
而那層轉換是「某一邊漏掉赤五、把它畫成普通五」的唯一可能來源。改名之後
`TileImage.assetName(for:)` 只剩花色分派，沒有赤五特例。

**取捨**：與上游檔名（`Man5-Dora.svg`）不一致。對照表記在
`docs/third-party/riichi-mahjong-tiles.md`。`0m` 送進來會走 fallback 顯示原字串，
不猜成赤五——猜錯會在畫面上生出一張手牌裡不存在的牌。

## 側欄順序反轉

**決策**：`答案 → 次選 → 細節（收合）`。取代舊的「Bot 狀態卡在上、AI 推薦卡在下」。

**為什麼**：舊順序把每手都要看的推薦壓在約 260pt 的狀態資訊底下，而那些狀態
（模型名、本場、供託）多數時候是不變的常數。實測舊版側欄下半約 300pt 是純空白。

## 摘要條**就是** disclosure

**決策**：局況摘要條升格成 `<details>` 的 summary，取消獨立的「牌局與模型資訊」列。

**為什麼**：那兩列講的是同一份資料的兩個詳細度。合併後收合狀態少一列，
細節長在自己的概要正下方。量測：決策卡從 y=238 上移到 **178**（收合）、600 → **540**（展開）。

**演進**（三版，前兩版都留在 `action-states/README.md` 的 decision log）：
1. 絕對定位覆蓋 → 面板隨內容長高，蓋掉機率條與自己的 summary，失去收合的錨點
2. inline 但錨在側欄底部 → 逼出誠實的量測：內容**溢出 83px**，覆蓋式一直在掩蓋這件事
3. 合併兩列 → 空間回來了

## 「過」不是一張牌

**決策**：`過` 用中性虛線空位，不用牌背。

**為什麼**：紅色牌背同時說了兩件不成立的事——這個動作牽涉某張牌（不是），
而且它危險（紅是 danger 色）。暗槓的蓋牌保留真牌背，那裡「面朝下」是正確語意。

## iOS：單一 adaptive view + 浮動 HUD

**決策**：不做兩套 view。iOS 廢掉硬切 140pt 左欄，改成浮在 WebView 上的 HUD。

**為什麼**：舊版 `HStack { 固定 140pt 欄; WebView }` 直接從牌桌切走寬度，
而雀魂是 3D 橫向畫面。狀態列更糟——`.opacity(0.5).allowsHitTesting(false)`
疊在手牌上，半透明到既擋畫面又讀不清。

**adaptive 不是等比縮小**：iPhone 橫向只有 393pt 高、HUD 190pt 寬。摘要條四欄塞進去
每欄會縮到 10pt 而全部不可讀，所以窄版只留局況與自風，點數與模型**降級到展開層**；
次選限 2 個並顯示「還有 N 個」——截斷說得出來，裁切只是看起來壞掉。

**未驗證**：iOS 全部只有 build 與 wireframe，無實機。

## 診斷輸出不上狀態列

**決策**：`NakiMCPDependencies` / `MCPContext` 新增 `trace()`（只進 `LogManager`），
HTTP request、MCP `tools/call`、連線錯誤改走它。

**為什麼**：實測畫面底部長期停在 `callTool: game_state with args: []` 與
`Request: GET /screenshot`。狀態列是「給使用者看的最後一句話」，而這些是每秒好幾筆的
診斷輸出，會把它整個洗掉。伺服器生命週期訊息（啟動／停止／失敗）仍走 `log()`，
那是使用者按了按鈕該看到的回饋。

## 座位 ≠ 風位

**決策**：抽出 `SeatWind.name(seat:kyoku:is3P:)` 並加 `SeatWindTests`。

**為什麼**：點數陣列的 index 是**座位**，舊寫法直接拿它當風位。實測東 2 局時，
摘要條說我是「南家」，同一畫面的點數列把我的 33,000 標成「西」。風位要從莊家算起
（`(kyoku - 1) % 家數`）。

**為什麼值得一條測試**：這種差一位的錯誤**只有東 1 局是對的**，而東 1 局正是
`GameState()` 的預設值與所有 `#Preview` 的內容——開發期完全看不出來。
寫測試時斷言自己也算錯兩次，最後是用程式產對照表才寫對。

## 雲端開關顯示「生效狀態」而非開關值

**決策**：toolbar 的雲端快速開關，圖示分三態（生效 / 開了但缺條件 / 已關閉）。

**為什麼**：生效需要「開關 + URL + key」三者同時成立。只畫開關會讓
「貼了 key 沒開」與「開了沒 key」長得一模一樣，而那正是最常見的兩種設定錯誤
（Akagi #221 的形狀）。實測發現本機就處於前者——key、URL、模型都填好了，開關是關的。

## `/v3/key` 自動探測

**決策**：補上原本明確排除的額度查詢，並在開關／URL／key 變動時**自動**探測（700ms debounce）。

**為什麼**：貼完 key 就關掉設定頁的人永遠不會按「測試連線」，而 key 打錯的後果
（整局都在用本地模型）在對局中沒有徵兆。`/v3/key` 是認證端點，同時也是驗證 key
有效性最直接的方式——上游前端（`Akagi/frontend/src/lib/nativeApi.ts`）也是這樣用的。

**未驗證**：本機雲端開關是關的，狀態卡沒跑過真資料。

## 截圖 API 的能力邊界

**決策**：`windowScreenshot` 改成「有 attached sheet 就截 sheet」；**不**繞道 `screencapture`。

**為什麼**：`windows.first` 多半挑中主視窗，所以設定頁怎麼截都是它後面的遊戲畫面。

**做不到的**（下一個要驗 UI 的人先看這段，別重走）：
- **toolbar 截不到**。`contentView` 不含 titlebar/toolbar，而模式切換、延遲 stepper、
  MCP／連線指示、雲端開關全在那裡。改截 theme frame 的話位置有了，但 `cacheDisplay`
  畫不出 NSToolbar 裡的 SwiftUI hosting view——整排變白色空塊，比缺一塊更像 UI 壞了。
- `CGWindowListCreateImage` 在 **macOS 26 SDK 已 unavailable**，替代的 ScreenCaptureKit
  需要螢幕錄製授權；為了截自己的視窗要那個權限不成比例。
- sheet 雖然選對了視窗，SwiftUI 的 GroupBox 背景與多數標籤仍畫不出來，只能粗看。

**絕對不要**用 `screencapture` 配螢幕座標補：實測截到了同一座標上的**另一個 App**，
而且視窗一移動座標就失效。

---

## 已知遺留

| 項目 | 狀態 |
|---|---|
| `BotStatusView.swift` 全檔、`RecommendationView.swift` 大部分 | **死碼**——換成 `DecisionSidebar` 後外部零使用者，約 700 行待刪 |
| 自動打牌停滯 122 秒（`skip:awaitingInference`） | 實測畫面上出現過；未查，屬 `AutoPlayEngine` 範圍 |
| 「吃①②③」不可解讀 | 本地 mapper 不產 `consumed`，只有雲端有；要修得動資料層 |
| 動作色仍是 7 色 | 紅同時是「槓」與「危險」 |
| macOS toolbar 13 個控制 | 加了雲端開關後更擠；MCP Server 仍佔一級位置 |
| 側欄下半空白 | `tehaiTiles` / `tsumoTile` / `recommendationsOplistSequence` 都還沒上畫面 |
| iOS | 零實機驗證 |
