import XCTest

/// 側欄兩處都要讀 `BotStatus.isCloudFallback`，不得自己拼 `cloudDegraded`／`cloudFallbackStreak` 判準。
/// 畫面層不做像素比對（重繪有抖動），以原始碼鎖呼叫點。
final class CloudFallbackViewTests: XCTestCase {

    private func sidebarCode() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("command/Views/DecisionSidebar.swift")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("找不到原始碼 \(file.path)")
        }
        return try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testAlertRowAndDetailsPanelReadSharedCondition() throws {
        let code = try sidebarCode()
        XCTAssertTrue(code.contains("if botStatus.isCloudFallback {\n                alert("), "異常列必須讀 isCloudFallback")
        XCTAssertTrue(code.contains("if botStatus.isCloudFallback { return \"改用本機\" }"), "展開層必須讀 isCloudFallback")
        XCTAssertTrue(code.contains("[botStatus.isCloudFallback, botStatus.cloudHost"), "shown 必須讀 isCloudFallback")
    }

    func testSidebarDoesNotRebuildFallbackCondition() throws {
        let code = try sidebarCode()
        XCTAssertFalse(code.contains("botStatus.cloudDegraded"), "側欄不得自行判斷 cloudDegraded")
        XCTAssertFalse(code.contains("showsCloudFallback"))
    }
}
