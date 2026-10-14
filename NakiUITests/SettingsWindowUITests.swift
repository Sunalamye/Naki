import XCTest

/// macOS 原生 `Settings` 視窗：開啟路徑、分頁、`/debug/ui` 的可見回報、唯一性、語言、草稿與雲端跨頁。
/// 不按「套用並重新載入」等會重新載入雀魂頁面的按鈕。
final class SettingsWindowUITests: NakiUITestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        try launch()
    }

    private func post(_ body: String) throws -> [String: Any] {
        try json("POST", "/debug/ui", body: body)
    }

    private func closeSettings() {
        closeSettingsWithCommandW()
        XCTAssertTrue(eventually { self.settingsWindows.count == 0 }, "⌘W 後設定視窗應關閉")
    }

    func testCommandCommaAndToolbarGearOpenSettings() throws {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5), "⌘, 應開出設定視窗")
        closeSettings()

        let gear = app.descendants(matching: .any)["toolbar-settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "找不到 toolbar-settings")
        gear.click()
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5), "工具列齒輪應開出設定視窗")
    }

    /// 分頁列與標題列是 HTTP 截圖截不到的部分，以 Accessibility 斷言驗。
    func testTabsAreSelectableAndTitleFollowsTab() throws {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        for id in ["general", "connection", "ai", "developer"] {
            let title = try XCTUnwrap(Self.tabTitles[id])
            XCTAssertTrue(tab(title).exists, "分頁按鈕 \(title)")
            select(id)
            XCTAssertEqual(settingsWindow.title, title)
        }
    }

    func testDebugUIOpensClosesAndReportsVisibility() throws {
        _ = try post(#"{"screen":"settings"}"#)
        XCTAssertTrue(try eventually { try self.settingsVisible() }, "POST settings 後 GET 應輪詢到 true")
        XCTAssertTrue(settingsWindow.exists)

        closeSettings()
        XCTAssertTrue(try eventually { try !self.settingsVisible() }, "⌘W 後 GET 應輪詢到 false")

        _ = try post(#"{"screen":"settings"}"#)
        XCTAssertTrue(try eventually { try self.settingsVisible() }, "關閉後再送一次應重新開出")

        let plugins = try post(#"{"screen":"plugins"}"#)
        XCTAssertEqual(plugins["showAdvancedSettings"] as? Bool, false, "回應前設定視窗已關")
        XCTAssertEqual(plugins["showPlugins"] as? Bool, true)
        XCTAssertEqual(settingsWindows.count, 0)
        _ = try post(#"{"screen":"none"}"#)

        _ = try post(#"{"screen":"settings"}"#)
        XCTAssertTrue(try eventually { try self.settingsVisible() })
        XCTAssertEqual(try post(#"{"screen":"none"}"#)["showAdvancedSettings"] as? Bool, false)
        XCTAssertEqual(settingsWindows.count, 0)

        _ = try post(#"{"screen":"settings"}"#)
        XCTAssertTrue(try eventually { try self.settingsVisible() })
        XCTAssertEqual(try post(#"{"language":"zh-Hant"}"#)["showAdvancedSettings"] as? Bool, true,
                       "沒有 screen 欄位時不動設定視窗")
        XCTAssertTrue(settingsWindow.exists)
    }

    func testSettingsWindowStaysUnique() throws {
        app.typeKey(",", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        XCTAssertEqual(settingsWindows.count, 1)

        _ = try post(#"{"screen":"settings"}"#)
        _ = try post(#"{"screen":"settings"}"#)
        XCTAssertTrue(try eventually { try self.settingsVisible() })
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(settingsWindows.count, 1)
    }

    /// App 語言與系統不同時，在一般頁切換語言，分頁名、標題列與 GroupBox 標題跟著換。
    func testSettingsFollowAppLanguage() throws {
        _ = try post(#"{"language":"ja"}"#)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        tab("接続").click()
        XCTAssertEqual(settingsWindow.title, "接続")

        tab("一般").click()
        settingsWindow.popUpButtons["app-language-picker"].click()
        app.menuItems["English"].click()

        XCTAssertTrue(tab("Connection").waitForExistence(timeout: 5))
        XCTAssertEqual(settingsWindow.title, "General")
        XCTAssertTrue(page("general").staticTexts["Language"].exists)
    }

    /// 未套用的 Header 草稿切頁不丟（不按「套用並重新載入」）。
    func testHeaderDraftSurvivesTabSwitch() throws {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        select("connection")
        page("connection").buttons["add-majsoul-header-button"].click()
        let field = page("connection").textFields["majsoul-header-name-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("X-Naki-Draft")

        select("ai")
        select("connection")
        XCTAssertEqual(page("connection").textFields["majsoul-header-name-field"].value as? String, "X-Naki-Draft")
    }

    /// 開關關閉、缺 key 兩種狀態下，AI 頁與開發者頁的生效狀態列文字相同（查詢限定在頁面容器內）。
    func testCloudEffectiveStateMatchesAcrossPages() throws {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))

        func effectiveState(_ id: String) -> String {
            select(id)
            let row = page(id).descendants(matching: .any)["cloud-effective-state"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(id) 頁缺 cloud-effective-state")
            return row.label
        }

        let offAI = effectiveState("ai")
        XCTAssertFalse(offAI.isEmpty)
        XCTAssertEqual(effectiveState("developer"), offAI, "開關關閉")

        select("ai")
        page("ai").descendants(matching: .any)["cloud-inference-toggle"].firstMatch.click()
        let missingKeyAI = effectiveState("ai")
        XCTAssertNotEqual(missingKeyAI, offAI, "開關打開後缺項應改變")
        XCTAssertEqual(effectiveState("developer"), missingKeyAI, "缺 key")
    }
}
