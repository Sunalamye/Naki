//
//  LegacyAutoPlayPathTests.swift
//  NakiTests
//
//  p2-2 回歸鎖：Legacy（iOS 17–25 WKWebView）路徑不得自動送出，
//  而且模式要記得住、座位來源要與主路徑同一份。
//
//  背景：自動送出的保護鏈（1 秒輪詢的 AutoPlayGate、forceHora／sendPass 寬限、
//  executionId 去抖、送出重試）只長在 WebPage 路徑上；Legacy 沒有，而且
//  macOS deployment target 是 26，本機根本跑不到它——沒有 iOS 17–25 實機
//  就沒有任何對局證據。路線 A 的決策是：那條路只顯示推薦，不自己送牌。
//
//  這裡刻意只測**純函式與協定 extension**：`LegacyWebViewModel` 是 app target 的
//  MainActor 類別，在 NakiTests（沒開 `SWIFT_DEFAULT_ACTOR_ISOLATION`）裡建立／釋放
//  會 SIGABRT 把 test host 打掉（實測過，見 CLAUDE.md「專案結構的坑」），
//  所以 ViewModel 只呼叫這些函式、不在單測裡建實例。
//
//  ⚠️ picker 上實際長什麼樣、iOS 17–25 上跑起來如何，仍然只能實機驗證。
//

import SwiftUI
import XCTest

@testable import Naki

final class AutoPlayAvailabilityTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // 每個 test 一個乾淨的 suite：不碰使用者實際的 standard defaults
        suiteName = "naki.tests.autoplayavailability.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - 選項

    func testSupportedPathKeepsAllModes() {
        XCTAssertEqual(AutoPlayAvailability.modes(autoPlaySupported: true),
                       [.off, .recommend, .auto])
    }

    func testUnsupportedPathDropsAuto() {
        let modes = AutoPlayAvailability.modes(autoPlaySupported: false)
        XCTAssertEqual(modes, [.off, .recommend])
        XCTAssertFalse(modes.contains(.auto), "不支援的路徑上不該有「自動」這個選項")
    }

    func testUnavailableReasonIsUserFacing() {
        XCTAssertFalse(AutoPlayAvailability.autoUnavailableReason.isEmpty,
                       "選項消失一定要有理由可顯示，否則看起來像壞掉")
    }

    // MARK: - 收斂

    func testClampDowngradesAutoOnlyWhenUnsupported() {
        XCTAssertEqual(AutoPlayAvailability.clamp(.auto, autoPlaySupported: false), .recommend)
        XCTAssertEqual(AutoPlayAvailability.clamp(.auto, autoPlaySupported: true), .auto)
        // 降級只動 `.auto`：使用者選的關閉／推薦不該被改寫
        XCTAssertEqual(AutoPlayAvailability.clamp(.off, autoPlaySupported: false), .off)
        XCTAssertEqual(AutoPlayAvailability.clamp(.recommend, autoPlaySupported: false), .recommend)
    }

    // MARK: - 收斂 + 持久化（`commit`：兩條 path 的唯一入口）

    /// 不支援自動送出的路徑上，要求 `.auto` 會被降級，而且**存檔存的是降級後的值**。
    /// 存檔沒改的話，UI 的 @AppStorage 仍讀到「自動」——picker 顯示自動、實際跑推薦。
    func testCommitDowngradesAndPersistsOnUnsupportedPath() {
        let effective = AutoPlayAvailability.commit(.auto, autoPlaySupported: false,
                                                    defaults: defaults)

        XCTAssertEqual(effective, .recommend)
        XCTAssertEqual(defaults.string(forKey: AutoPlayModeStore.key),
                       AutoPlayMode.recommend.rawValue)
        XCTAssertEqual(AutoPlayModeStore.load(defaults), .recommend)
    }

    func testCommitKeepsAutoOnSupportedPath() {
        let effective = AutoPlayAvailability.commit(.auto, autoPlaySupported: true,
                                                    defaults: defaults)

        XCTAssertEqual(effective, .auto)
        XCTAssertEqual(AutoPlayModeStore.load(defaults), .auto)
    }

    /// 「重啟保留」：選了關閉，下次讀回來還是關閉。
    /// 舊的 Legacy `setAutoPlayMode` 只改記憶體不寫存檔，重啟就被沖回預設的自動。
    func testCommittedModeSurvivesReload() {
        AutoPlayAvailability.commit(.off, autoPlaySupported: false, defaults: defaults)

        XCTAssertEqual(AutoPlayModeStore.load(defaults), .off)

        // 再模擬一次「啟動時沿用存檔」：讀回來 → 收斂 → 仍是關閉
        let onLaunch = AutoPlayAvailability.commit(AutoPlayModeStore.load(defaults),
                                                   autoPlaySupported: false,
                                                   defaults: defaults)
        XCTAssertEqual(onLaunch, .off)
    }

    /// 存檔是在支援的裝置上寫下的 `.auto`：Legacy 啟動時要降級並把降級寫回去
    func testStoredAutoIsDowngradedOnLaunchOfUnsupportedPath() {
        AutoPlayModeStore.save(.auto, to: defaults)

        let onLaunch = AutoPlayAvailability.commit(AutoPlayModeStore.load(defaults),
                                                   autoPlaySupported: false,
                                                   defaults: defaults)

        XCTAssertEqual(onLaunch, .recommend)
        XCTAssertEqual(defaults.string(forKey: AutoPlayModeStore.key),
                       AutoPlayMode.recommend.rawValue)
    }
}

// MARK: - 座位來源

/// `WebViewModelProtocol.autoPlaySeat` 的回歸鎖。
///
/// 先前 Legacy 讀 `botStatus.playerId`、主路徑讀 `gameState.playerId`。兩者都源自
/// `NativeBotController.playerId`，但重置時機不同（`deleteNativeBot()` 把 botStatus
/// 打回預設值 0），所以同一個局面在兩條路上可以得到不同的 seat，
/// 而 resolver 的 `seat_mismatch` 是 fail-closed——判錯就整批 oplist 不動作。
///
/// 這裡用最小 double 驗「唯一定義」的行為：seat 只看 gameState。
final class AutoPlaySeatSourceTests: XCTestCase {

    @MainActor
    func testSeatComesFromGameStateNotBotStatus() {
        let model = SeatSourceDouble()
        model.gameState.playerId = 2
        model.botStatus.playerId = 0

        XCTAssertEqual(model.autoPlaySeat, 2, "座位要取 gameState.playerId")
    }

    @MainActor
    func testSeatIgnoresStaleBotStatus() {
        let model = SeatSourceDouble()
        model.gameState.playerId = 1
        model.botStatus.playerId = 3   // 例如 deleteNativeBot() 之後殘留／歸零的值

        XCTAssertNotEqual(model.autoPlaySeat, model.botStatus.playerId)
        XCTAssertEqual(model.autoPlaySeat, 1)
    }
}

/// 只為了驗 `autoPlaySeat` 的最小 `WebViewModelProtocol` 實作。
///
/// 全部成員都是空殼——這個 double 唯一的用途是提供 `gameState` / `botStatus` 兩個欄位，
/// 讓協定 extension 的預設實作（兩條 path 共用的那一份）能被單獨呼叫到。
@Observable
@MainActor
final class SeatSourceDouble: WebViewModelProtocol {
    var statusMessage: String = ""
    var isConnected: Bool = false
    var recommendationCount: Int = 0

    var gameState: GameState = GameState()
    var botStatus: BotStatus = BotStatus()
    var recommendations: [Recommendation] = []
    var tehaiTiles: [String] = []
    var tsumoTile: String?
    var highlightedTile: String?

    let gameStateManager = GameStateManager()
    var isDebugServerRunning: Bool = false
    var debugServerPort: UInt16 = 0

    var autoPlayMode: AutoPlayMode = .off

    /// MainActor 隔離的 class 在 NakiTests 裡釋放會 SIGABRT（見檔頭），double 也不例外
    nonisolated deinit { }

    func createNativeBot(playerId: Int, is3P: Bool) async throws {}
    func processNativeEvent(_ event: [String: Any]) async throws -> [String: Any]? { nil }
    func processNativeEvents(_ events: [[String: Any]]) async throws -> [String: Any]? { nil }
    func deleteNativeBot() {}
    func resyncBot() async {}
    func forceReconnect() async {}

    func setAutoPlayMode(_ mode: AutoPlayMode) { autoPlayMode = mode }
    func triggerAutoPlayNow(delay: TimeInterval) {}

    func setHidePlayerNames(_ hide: Bool) {}
    func applyHideNamesSettingsIfNeeded() {}
    func getPlayerNamesStatus() async -> [String: Any]? { nil }
    func resetHideNamesSettings() {}

    // 兩個平台都要（p2-3 統一啟動語意後，protocol 不再包 `#if os(macOS)`）
    func startDebugServer() {}
    func stopDebugServer() {}
    func toggleDebugServer() {}

    func makeWebView() -> AnyView { AnyView(EmptyView()) }

    func executeJavaScript(_ script: String) async throws -> Any? { nil }

    func loadMajsoul() async {}
    func loadURL(_ urlString: String) async {}
    func reload() {}
}
