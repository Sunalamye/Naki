import XCTest

/// 觸控不應該讓 App 崩潰。
///
/// 2026-08-09 的迴歸：iPhone 版把決策 HUD 疊到 WebView 上時，順手在容器加了
/// `.animation(_:value:)`，又把狀態列浮層的 `allowsHitTesting(false)` 拿掉。
/// 兩者都讓 SwiftUI 的手勢處理跟 WKWebView 自己那組 UIGestureRecognizer 打架，
/// 在 iOS 26 上**一碰畫面就崩**：
///
/// ```
/// *** -[__NSArrayM insertObject:atIndex:]: object cannot be nil
/// 3  UIKitCore  -[UIGestureRecognizer _delayTouchesForEvent:inPhase:]
/// 6  UIKitCore  -[UIGestureEnvironment _updateForEvent:window:]
/// 7  UIKitCore  -[UIWindow sendEvent:]
/// ```
///
/// 單元測試與 build 都抓不到——它只在真的有觸控事件時發生，而截圖驗證不會產生觸控。
/// 所以這條測試的價值不在斷言什麼結果，而在**真的去點**：只要 App 還在前景，就沒事。
final class DecisionHUDTouchTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// 點帳號欄位後**停住**，讓外部（`simctl io screenshot`）拍到當下畫面。
    ///
    /// 只在設了 `NAKI_HOLD_AFTER_TAP` 時才跑——一般回歸不需要卡 25 秒。
    @MainActor
    func testTapAccountFieldAndHold() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NAKI_HOLD_AFTER_TAP"] == "1",
                          "只在需要人工觀察畫面時執行")
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

        let field = app.webViews.textFields.firstMatch
        if field.waitForExistence(timeout: 45) {
            field.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.30)).tap()
        }
        XCTAssertEqual(app.state, .runningForeground, "點帳號欄位不應該崩潰")

        // 停住讓外部截圖；期間持續確認 App 還活著
        for _ in 0..<25 {
            Thread.sleep(forTimeInterval: 1)
            XCTAssertEqual(app.state, .runningForeground, "停留期間 App 不應該崩潰")
        }
    }

    /// 點雀魂登入頁的輸入框——使用者實際回報的崩潰觸發點。
    ///
    /// 點 WebView 裡的 `<input>` 會叫出鍵盤，那是 safe area 劇烈變動的時刻，而
    /// 決策 HUD 就浮在 WebView 上。舊版 iOS 版面有 `.ignoresSafeArea(edges: .bottom)`，
    /// 改寫成 overlay 之後那行沒了。
    @MainActor
    func testTappingWebViewTextFieldDoesNotCrash() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

        // 雀魂登入頁是 HTML 表單，等它出現。抓不到具名元素時退回座標。
        let field = app.webViews.textFields.firstMatch
        if field.waitForExistence(timeout: 45) {
            field.tap()
        } else {
            // 登入表單大致在畫面中間偏右（HUD 佔右上，避開它）
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.30)).tap()
        }
        XCTAssertEqual(app.state, .runningForeground, "點輸入框（鍵盤升起）不應該崩潰")

        // 鍵盤升起後再互動：safe area 已經變了，此時的 layout 與手勢狀態才是新的
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(app.state, .runningForeground, "鍵盤升起後不應該崩潰")

        // 只有真的拿到鍵盤焦點才打字。抓不到焦點是測試自身的限制（WebView 內的
        // HTML input 不一定被 XCUITest 視為 first responder），不該報成崩潰。
        if app.keyboards.element.waitForExistence(timeout: 3) {
            app.typeText("test")
            XCTAssertEqual(app.state, .runningForeground, "輸入文字後不應該崩潰")
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.28)).tap()
        XCTAssertEqual(app.state, .runningForeground, "鍵盤開著時點 HUD 不應該崩潰")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).tap()
        XCTAssertEqual(app.state, .runningForeground, "鍵盤收起時不應該崩潰")
    }

    @MainActor
    func testTappingAroundWebViewAndHUDDoesNotCrash() {
        let app = XCUIApplication()
        app.launch()

        // 等頁面起來。WebView 載入很慢，但這條測試不依賴內容，只要 App 在前景就能點。
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                      "App 應該進入前景")

        // 涵蓋三個會打架的區域：WebView 本體、右上的 HUD、底部的狀態列浮層。
        let spots: [(CGFloat, CGFloat)] = [
            (0.35, 0.50),   // WebView 中央
            (0.85, 0.25),   // HUD
            (0.85, 0.40),   // HUD 下緣與 WebView 交界
            (0.50, 0.93),   // 狀態列浮層
            (0.20, 0.70),   // WebView 左下
            (0.85, 0.25),   // 再點一次 HUD（重複觸控才會踩到 delayTouches 的狀態機）
        ]
        for (dx, dy) in spots {
            app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
            XCTAssertEqual(app.state, .runningForeground,
                           "在 (\(dx), \(dy)) 觸控後 App 不應該離開前景")
        }

        // 崩潰點是 `_delayTouchesForEvent`——手勢辨識器「先攔住觸控、稍後決定給誰」的
        // 那條路徑。單純 tap 走不到它：要有**持續中的觸控**（拖曳、長按）讓多個
        // recognizer 同時在競爭，才會進到延遲佇列。
        let webCenter = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let hudCenter = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.28))
        let bottomBar = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93))

        webCenter.press(forDuration: 0.9)
        XCTAssertEqual(app.state, .runningForeground, "WebView 長按後不應該崩潰")

        // 從 WebView 拖到 HUD：跨越兩個 hit-testing 區域，最容易讓延遲佇列出事
        webCenter.press(forDuration: 0.3, thenDragTo: hudCenter)
        XCTAssertEqual(app.state, .runningForeground, "從 WebView 拖到 HUD 後不應該崩潰")

        hudCenter.press(forDuration: 0.3, thenDragTo: webCenter)
        XCTAssertEqual(app.state, .runningForeground, "從 HUD 拖回 WebView 後不應該崩潰")

        // 拖過底部狀態列浮層（它先前參與了 hit-testing）
        webCenter.press(forDuration: 0.3, thenDragTo: bottomBar)
        XCTAssertEqual(app.state, .runningForeground, "拖過狀態列後不應該崩潰")

        app.swipeUp()
        app.swipeLeft()
        XCTAssertEqual(app.state, .runningForeground, "滑動後不應該崩潰")

        // 開關 HUD 會觸發 transition，那是 `.animation` 當初加上去的原因
        let hudToggle = app.buttons["toolbar-game-panel-toggle"]
        if hudToggle.waitForExistence(timeout: 5) {
            hudToggle.tap()
            XCTAssertEqual(app.state, .runningForeground, "收合 HUD 後不應該崩潰")
            hudToggle.tap()
            XCTAssertEqual(app.state, .runningForeground, "展開 HUD 後不應該崩潰")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
            XCTAssertEqual(app.state, .runningForeground, "transition 之後再觸控 WebView 不應該崩潰")
        }
    }
}

/// HUD 是否真的在畫面上。
///
/// 2026-08-09 觀察到：App 啟動約 20 秒時 HUD 還在，雀魂登入頁完全載入之後就從
/// 截圖裡消失了。截圖看不出「不存在」與「存在但透明」的差別，所以直接問
/// accessibility 樹。
final class DecisionHUDPresenceTests: XCTestCase {

    @MainActor
    func testHUDStaysVisibleAfterWebViewFinishesLoading() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

        // 用 HUD 內的實際文字判斷，不用容器的 identifier——SwiftUI 容器上的
        // `accessibilityIdentifier` 不保證會變成一個 `otherElements` 節點，
        // 拿它當「存在與否」的判準會得到假的 false（已踩過一次）。
        let title = app.staticTexts["即時決策"]
        let earlyExists = title.waitForExistence(timeout: 20)

        // 等雀魂登入頁載完（出現輸入框），再看 HUD 還在不在
        _ = app.webViews.textFields.firstMatch.waitForExistence(timeout: 60)
        Thread.sleep(forTimeInterval: 5)

        let lateExists = title.exists
        let toggle = app.buttons["toolbar-game-panel-toggle"]
        XCTContext.runActivity(named: "HUD 狀態") { _ in
            print(">>> HUD 早期=\(earlyExists) 晚期=\(lateExists) toggle存在=\(toggle.exists)")
            print(">>> staticTexts: \(app.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label))")
        }
        XCTAssertTrue(lateExists, "WebView 載入完成後 HUD 不應該消失（早期=\(earlyExists)）")
    }
}
