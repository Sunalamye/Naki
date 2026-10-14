import XCTest

/// iOS 設定 sheet：「開發者」預設折疊，關閉再開回到折疊且在頂端；展開後兩個生效狀態列以頁面容器區分。
final class SettingsSheetUITests: NakiMUITestCase {

    private func page(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)["settings-page-\(id)"].firstMatch
    }

    private func openSettings() throws {
        try json("POST", "/debug/ui", body: #"{"screen":"settings"}"#)
        XCTAssertTrue(app.buttons["settings-done-button"].waitForExistence(timeout: 10), "設定 sheet 應出現")
    }

    @MainActor
    func testDeveloperCollapsesAndScrollResetsOnReopen() throws {
        launch()
        try openSettings()
        let disclosure = app.descendants(matching: .any)["settings-developer-disclosure"].firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(page("general").exists)
        XCTAssertFalse(page("developer").exists, "「開發者」預設折疊")

        disclosure.tap()
        XCTAssertTrue(page("developer").waitForExistence(timeout: 5), "展開後出現開發者頁")
        let aiState = page("ai").descendants(matching: .any)["cloud-effective-state"].firstMatch
        let developerState = page("developer").descendants(matching: .any)["cloud-effective-state"].firstMatch
        XCTAssertTrue(aiState.exists && developerState.exists, "兩個生效狀態列以容器區分")
        XCTAssertEqual(aiState.label, developerState.label)

        app.swipeUp()
        app.swipeUp()
        app.buttons["settings-done-button"].tap()
        XCTAssertTrue(eventually { (try? self.json("GET", "/debug/ui"))?["showAdvancedSettings"] as? Bool == false })

        try openSettings()
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertFalse(page("developer").exists, "再開回到折疊")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(page("general").frame.minY < window.midY, "再開回到頂端")
    }
}
