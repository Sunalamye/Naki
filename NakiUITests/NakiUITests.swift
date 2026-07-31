import XCTest

/// macOS UI 測試（host = Naki.app）。
/// 依賴 Phase 3 為各元件補上的 accessibilityIdentifier —— 這正是「讓 mac app 測試更友好」的成果。
/// 若某 identifier 找不到，代表對應 View 的 a11y 標記被移除或改名，應同步更新。
final class NakiUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// App 能啟動並顯示主要可測面（原生側板與 WebView 容器）。
    func testAppLaunchesAndExposesAccessibleSurface() throws {
        let app = XCUIApplication()
        app.launch()

        // WebView 容器（Laya/WebGL 黑盒，但容器有 identifier 可斷言存在）
        XCTAssertTrue(
            app.descendants(matching: .any)["majsoul-webview"].waitForExistence(timeout: 10),
            "找不到 majsoul-webview —— WebView 容器的 accessibilityIdentifier 可能被移除"
        )
    }

    /// 工具列的核心互動元件都以 identifier 可定位（測試友好性的核心驗收）。
    func testToolbarControlsAreAddressable() throws {
        let app = XCUIApplication()
        app.launch()

        // 這些 id 由 Phase 3 ContentView 的 a11y 補強提供
        let reload = app.descendants(matching: .any)["toolbar-reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 10), "找不到 toolbar-reload")

        let modePicker = app.descendants(matching: .any)["autoplay-mode-picker"]
        XCTAssertTrue(modePicker.exists, "找不到 autoplay-mode-picker")
    }
}
