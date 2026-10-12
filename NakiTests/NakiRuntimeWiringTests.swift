//
//  NakiRuntimeWiringTests.swift
//  NakiTests
//
//  正式 `NakiRuntime.makeActions` 的接線。Action 自己的單測都用 stub 或手動組，
//  接線被換成 no-op 或別的實例時它們看不出來。
//  建 `NakiRuntime()` 不連網、不綁 port（test host 跳過 debug server，見 `BotToolsTests`）。
//

import XCTest

@testable import Naki

@MainActor
final class NakiRuntimeWiringTests: XCTestCase {

    override func setUp() {
        super.setUp()
        isolateAutoPlayDefaults()
    }

    /// 只有 `.live` 會走 `PluginImportSource.fetchAny`（空字串回 `badURL`，不發請求）；Preview 預設回 `.success([])`。
    func testFetchPluginImportIsWiredToLiveSource() async {
        let runtime = NakiRuntime()

        let result = await runtime.actions.fetchPluginImport(urlString: "")

        guard case .failure(.badURL) = result else {
            return XCTFail("應走 fetchAny 並回 badURL，實際 \(result)")
        }
    }

    /// 清的必須是 runtime 自己的 store。`skip: true` 會寫 `runtime.settings`（落在真實設定檔），所以只測 `skip: false`；
    /// settings 那半的接線需要 `NakiRuntime` 能注入 defaults，見 wp9b notes 未解。
    func testDismissUpdateClearsRuntimeStore() throws {
        let runtime = NakiRuntime()
        runtime.store.availableUpdate = ReleaseInfo(
            version: "9.9.9", url: try XCTUnwrap(URL(string: "https://example.invalid/r")))

        runtime.actions.dismissUpdate(skip: false)

        XCTAssertNil(runtime.store.availableUpdate)
    }

    /// 用自己的標記條目判斷，不比對 `entries.isEmpty`：其他 log 隨時會進來。
    func testClearLogsIsWiredToSharedLogManager() async throws {
        let runtime = NakiRuntime()
        let manager = LogManager.shared
        let marker = LogEntry(
            timestamp: Date(), category: .system, level: .info, message: "wiring-\(UUID().uuidString)")
        manager.entries.append(marker)

        runtime.actions.clearLogs()

        var tries = 0
        while manager.entries.contains(where: { $0.id == marker.id }) && tries < 50 {
            try await Task.sleep(for: .milliseconds(20))
            tries += 1
        }
        XCTAssertFalse(manager.entries.contains { $0.id == marker.id }, "clearLogs 應清掉 LogManager.shared")
    }
}
