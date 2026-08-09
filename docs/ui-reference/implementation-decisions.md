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

## iOS：單一 adaptive view + 右側常駐欄

**決策**：不做兩套 view。iOS 的控制列與決策收進右側 220pt 常駐欄，牌桌拿全螢幕
高度——**沒有 `NavigationStack`**。狀態訊息留在牌桌底部當浮層，但**預設關閉**。

**為什麼是「右側欄反而讓牌桌變大」**：這條看起來矛盾，但橫向 iPhone 的瓶頸是
**高度**不是寬度。雀魂是 16:9 等比縮放的 Unity canvas，貼齊高度之後左右本來就
空著約 25% 的黑邊。所以把 nav bar 與底部狀態列佔掉的高度還給 WebView、面板放進
原本是黑邊的那塊寬度，牌桌比「有 nav bar、沒有面板」時更大（iPhone 16 Pro 橫向
推算 571×321 → 622×350，面積 +19%）。

**演進**：140pt 硬切左欄 →（切走寬度，代價實在）→ 浮在 WebView 上的 HUD
→（遮住右家那一區）→ 右側常駐欄。中間那版的狀態列是
`.opacity(0.5).allowsHitTesting(false)` 疊在手牌上，半透明到既擋畫面又讀不清。

**分成 ZStack 兩層不是排版偏好**：WebView 的 `.ignoresSafeArea(.container)` 會把
**整個 HStack** 的高度撐成「含 safe area 的全螢幕高」，同一層的面板被一起拉到最下緣，
底部的內容就壓在 home indicator 上（實機確認）。所以牌桌鋪滿螢幕、右側用等寬
`Color.clear` 佔位讓開；面板獨立一層。

**safe area 只能問 UIKit**（實測，2026-08-09 iPhone 17 Pro 橫向）：整個 iOS 版面活在
`.ignoresSafeArea(.container)` 的座標系裡，而 SwiftUI 在那個座標系裡回報的 safe area
**一律是 0**——`GeometryProxy` 四邊全 0、size 是完整的 874×402，同一刻 UIKit 報
`left/right 62、bottom 20`。`safeAreaPadding` 同理失效。所以 home indicator 的高度是
`UIApplication.shared.connectedScenes` 逐一問 window 取最大值。

兩個踩過的坑：`keyWindow` 在 `onAppear` 時常常還是 nil（實測就是這樣讀回 0），要走
`windows`；重讀的訊號用**版面尺寸變化**而不是 `orientationDidChangeNotification`，
後者要先 `beginGeneratingDeviceOrientationNotifications()`、而且平放會回報 `.faceUp`。

**同一件事也決定了收合鈕的位置**：它必須待在 ZStack 內。掛在外層 `.overlay` 上會
重新套用 safe area，把按鈕往畫面內推 62pt，正好壓在牌桌右上角的「公告」那一區。

**adaptive 不是等比縮小**：欄寬 220pt、內容約 200pt。摘要條四欄塞進去每欄會縮到
10pt 而全部不可讀，所以窄版只留局況與自風，點數與模型**降級到展開層**；次選限 2 個
並顯示「還有 N 個」。

**狀態訊息預設不顯示**（`SettingsStore.showStatusBar`，只有 iOS 讀）：它疊在牌桌上，
而內容多半是「已連線到雀魂伺服器」這種一次性回饋或 `skip:noOplist` 這種診斷輸出。
真正不會自己好的錯誤走頂端橫幅那一組，不受這個開關影響。macOS 不讀它——那邊的狀態列
是 `safeAreaInset` 排版出來的一列，不疊在任何東西上。

**收合的回程**：面板收起時右上角出現一顆浮動小圓鈕，與面板內的收合鈕共用
`toolbar-game-panel-toggle`（兩者互斥出現）。沒有它，收合就是單向操作。

**已驗證**（2026-08-09）：實機 iPhone + iOS 26 看到牌桌放大、右側欄就位、對局中決策卡
正常更新（那一版狀態訊息還在面板底部）。Simulator（iPhone 17 Pro / iOS 26）確認全新安裝
下狀態訊息不顯示、`bottomSafeInset` 讀到 20.0、收合鈕貼齊螢幕右緣約 12pt。

**未驗證**：狀態訊息開啟後的實際樣子（要有非空 `statusMessage` 才畫得出來）、面板底部
那 20pt 的視覺確認（值有讀到並套用，但決策內容目前填不滿欄高，看不出來）、旋轉到另一個
方向、`DecisionHUDTouchTests` 未重跑。

## 啟動時選雀魂區服：預設每次問，可升級成「記住」

**決策**：三個區服（國服／日服／國際服）在啟動時選；勾「以後都用這個」就不再問；
設定頁可換服、也可取消固定。URL 的唯一定義點是 `MajsoulServer`
（`SettingsStore.swift`），先前寫死在 `WebSession.swift:171`。

**為什麼是「每次問」當預設**：選錯服的代價不是畫面不對，是**登不進去**——各服帳號
不互通。固定一個服的人勾一次就再也不會看到它，成本只有一次；而常換服的人如果預設
是「記住」，每次都要進設定改。兩邊的痛不對稱。

**三個服跑同一份 client**（2026-08-09 實測）：三個 `version.json` 完全相同
（`0.11.252.w`），所以 Liqi 協定一致，不需要為不同服準備 parser，UI 上也不必把非國服
標成「未驗證」。這個結論會隨雀魂改版失效——換服後解析大量失敗的話，先回頭比對這三個
`version.json`。

**換服不會打壞注入**：注入的 JS 不判 hostname，`WKUserScript` 是
`forMainFrameOnly: false` + `atDocumentStart` 套用在所有頁面。舊版那份有自己
majsoul URL 判定的 fallback 攔截器已經整段刪掉了（見 `WebSocketInterceptor`）。

**選擇畫面取代整個畫面，不是蓋在上面**：WebView 一旦進 view tree 就會開始載入
（`WebSession.makeView()` 的 `.task`），用 sheet／fullScreenCover 蓋上去等於
「先載入上次的服、選完再整頁重載一次」。不渲染它就不會載。

**判斷要不要顯示用 `@AppStorage` 而不是 `naki.settings`**：`@Environment` 要到 body
求值時才拿得到，那時主版面已經渲染過一幀——而那一幀就足以建立 WebView。
`@AppStorage` 只讀，寫入仍然只有 `SettingsStore` 一個入口。

**iOS 不掛 `.keyboardShortcut(.defaultAction)`**：Enter＝預設按鈕是 macOS 慣例。
在這個畫面上，任何送進來的 Return 都會直接確認選擇，而誤觸的代價是連錯服。

## iOS 右側欄的控制列順序：圖示在上，模式與延遲在下

**決策**：重載／日誌／雲端／設定／收面板那排圖示排在最上，模式切換與延遲 stepper
排在它下面。

**為什麼**：圖示那排是「離開這裡去別的地方」，一局裡按不到幾次；模式與延遲是對局中
真的會動的東西，排下面就離決策區更近。

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

## iOS 間歇性崩潰（**未解決**）

崩潰堆疊固定，30 格裡沒有一格是 Naki 的程式碼：

```
*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil
 3  UIKitCore  -[UIGestureRecognizer _delayTouchesForEvent:inPhase:]
 7  UIKitCore  -[UIWindow sendEvent:]
 9  UIKit      -[UIApplicationAccessibility sendEvent:]   ← 只在 accessibility 啟用時介入
```

**這一節的重點是「我試錯了什麼」，不是結論——因為還沒有結論。**

### 三次診斷，三次都不成立

1. `.help()` 註冊的 hover 互動 → 錯
2. 狀態列浮層參與 hit-testing → 錯
3. 容器上的 `.animation(_:value:)` 波及 WKWebView → **一度以為證實了，也不成立**

第 3 個是這樣「證實」的：其餘修正全保留、只把 `.animation` 加回去 → 重現崩潰；拿掉 → 通過。
看起來很乾淨，但那是**單次對照**，而這個崩潰是**間歇性**的。後續同條件重跑：

| 條件 | 結果 |
|---|---|
| 有 HUD、89 秒流程 | 通過 |
| 無 HUD、88 秒流程 | 通過 |
| 有 HUD、`DecisionHUDPresenceTests` | **崩潰** |

同一份程式碼、同一台模擬器，結果不一致。所以先前那次二分法只是運氣。

### 方法上的教訓

- **間歇性崩潰不能用單次對照做二分法。** 要先建立崩潰率（同條件重複 N 次），
  再比較兩組的率，否則得到的因果是假的。
- XCUITest 的合成觸控走 Source0，真實滑鼠點擊走 Source1（`__CFMachPortPerform`）。
  crash log 最後幾格是哪個 Source，能分辨事件從哪來——但**兩種都能觸發這個崩潰**。
- 一次崩潰發生在 XCUITest 只是在**查詢 accessibility 樹**的時候，完全沒有觸控。
  配合堆疊裡的 `UIApplicationAccessibility`，合理的懷疑是「accessibility 啟用時的事件
  派送」而非任何特定手勢。若成立，真機不開 VoiceOver 可能碰不到。**未驗證。**
- 判斷「HUD 在不在畫面上」不要用容器的 `accessibilityIdentifier` 查 `otherElements`
  （SwiftUI 不保證產生那個節點，會得到假的 false）；用它內部的 `staticTexts`。
  另外要留意：測試報「元素不存在」也可能是 **App 已經崩了**。

### 目前的處置

`.animation` 仍然移除、改用 `withAnimation`；`.help` 仍然只包 macOS；狀態列仍然
`allowsHitTesting(false)`。這三項各自站得住（見下），但**都不宣稱修好了崩潰**：

- 動畫只該作用在 HUD 的 transition，不該波及 WebView 子樹
- `.help` 在 iPhone 沒有 UI 效果（`LogPanel` 早有 `#if os(macOS)` 慣例）
- 狀態列是純顯示元件，不該吃掉牌桌的觸控

### 下一步

建立崩潰率再談因果：同一條測試連跑 10 次以上，記錄崩潰次數，然後才比較「有/無 HUD」
或「有/無 `.animation`」。在那之前不要再宣稱任何根因。

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
| iOS 間歇性崩潰 | **未解決**，見上節。三次診斷都不成立。右側欄版拿掉了牌桌上的所有浮層（HUD／狀態列），但那不是針對此崩潰的修復，也還沒證明它消失了 |
| iOS 右側欄 | 實機已驗版面與對局中決策；**未驗**收合／展開回程、另一旋轉方向、`DecisionHUDTouchTests` 未重跑 |
