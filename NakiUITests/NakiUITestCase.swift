import XCTest

/// 所有 macOS UI 測試的共同前置。
///
/// 啟動的 App 不是 test host：AutoPlayEngine 與 DebugServer 都會跑，WebView 用真實雀魂登入。
/// 所以：defaults 與 Keychain 走隔離鉤子；自動打牌模式啟動前固定為「關閉」，啟動後經
/// `/bot/status` 確認，不符就收掉 App；測試只動設定視窗與工具列，不碰遊戲頁面。
class NakiUITestCase: XCTestCase {

    static let suiteName = "naki.tests.ui"
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        let suite = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        suite.removePersistentDomain(forName: Self.suiteName)
        suite.set("關閉", forKey: "naki.autoPlayMode")
        suite.set(true, forKey: "PinMajsoulServer")
        suite.set("zh-Hant", forKey: "naki.appLanguage")
        app.launchEnvironment["NAKI_UI_TEST_DEFAULTS_SUITE"] = Self.suiteName
        app.launchEnvironment["NAKI_UI_TEST_KEYCHAIN_SERVICE"] = "org.naki.cloud-inference.uitest"
        // argument domain 疊在 suite 之上（`UserDefaults(suiteName:)` 也讀得到）：runner 寫不到 App 的 suite 時模式仍是「關閉」
        app.launchArguments += ["-naki.autoPlayMode", "關閉", "-PinMajsoulServer", "YES"]
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func launch() throws {
        app.launch()
        var mode: String?
        _ = eventually(20) {
            let status = try? json("GET", "/bot/status")
            mode = (status?["autoPlay"] as? [String: Any])?["mode"] as? String
            return mode != nil
        }
        if mode != "關閉" {
            app.terminate()
            XCTFail("自動打牌模式不是「關閉」（\(mode ?? "讀不到 /bot/status")），已收掉 App")
        }
    }

    // MARK: - Loopback HTTP

    @discardableResult
    func request(_ method: String, _ path: String, body: String? = nil) throws -> (status: Int, data: Data) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8765\(path)")))
        request.httpMethod = method
        request.timeoutInterval = 5
        request.httpBody = body.map { Data($0.utf8) }
        let done = DispatchSemaphore(value: 0)
        var result: Result<(Int, Data), Error> = .failure(URLError(.unknown))
        URLSession.shared.dataTask(with: request) { data, response, error in
            result = error.map { .failure($0) }
                ?? .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    func json(_ method: String, _ path: String, body: String? = nil) throws -> [String: Any] {
        let data = try request(method, path, body: body).data
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func settingsVisible() throws -> Bool {
        try XCTUnwrap(json("GET", "/debug/ui")["showAdvancedSettings"] as? Bool)
    }

    func eventually(_ timeout: TimeInterval = 5, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    // MARK: - 設定視窗

    /// 設定視窗以內容辨識（含 `settings-page-*`），不依賴系統給的視窗 identifier。
    var settingsWindows: XCUIElementQuery {
        app.windows.containing(NSPredicate(format: "identifier BEGINSWITH 'settings-page-'"))
    }

    var settingsWindow: XCUIElement { settingsWindows.firstMatch }

    /// 分頁按鈕以標籤查：`.tabItem` 內的 identifier 傳不到 toolbar 按鈕（WP-F2 以 AX 實測）。
    func tab(_ title: String) -> XCUIElement {
        settingsWindow.toolbars.buttons[title].firstMatch
    }

    func page(_ id: String) -> XCUIElement {
        settingsWindow.descendants(matching: .any)["settings-page-\(id)"].firstMatch
    }

    /// 點標題列讓設定視窗成為 key window 再按 ⌘W。不點視窗中央：那裡可能是「套用並重新載入」或「刪除 Bot」。
    func closeSettingsWithCommandW() {
        settingsWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 8)).click()
        app.typeKey("w", modifierFlags: .command)
    }

    static let tabTitles = ["general": "一般", "connection": "連線", "ai": "AI", "developer": "開發者"]

    /// 以繁中標籤選頁（`setUp` 固定 App 語言為 zh-Hant）。
    func select(_ id: String) {
        tab(Self.tabTitles[id] ?? id).click()
        XCTAssertTrue(page(id).waitForExistence(timeout: 5), "settings-page-\(id)")
    }
}
