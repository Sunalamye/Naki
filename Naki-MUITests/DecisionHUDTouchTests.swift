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
