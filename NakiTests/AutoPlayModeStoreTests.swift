//
//  AutoPlayModeStoreTests.swift
//  NakiTests
//
//  p1-3 回歸鎖：自動打牌模式只能有一個持久化 key。
//
//  刪掉 AutoPlay「控制器」空殼之前，同一個設定散在兩個地方：
//  ViewModel 讀寫 `naki.autoPlayMode`，ContentView 的 `@AppStorage` 讀寫 `AutoPlayMode`。
//  兩邊各存各的，所以「UI picker 顯示自動、實際跑的是關閉」是可能的，
//  而 Legacy 路徑更乾脆——改了模式根本沒寫進任何 key，重啟就沖掉。
//
//  這批 test 鎖住兩件事：
//  1. 舊 key 的一次性遷移（含衝突時以新 key 為準、非法值不污染設定）。
//  2. 遷移是冪等的——它會在 App init 與 `load()` 各被呼叫一次。
//

import XCTest

@testable import Naki

final class AutoPlayModeStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // 每個 test 一個乾淨的 suite：不碰使用者實際的 standard defaults
        suiteName = "naki.tests.autoplaymode.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - 遷移

    /// 只有舊 key 有值：值搬到新 key，舊 key 消失。
    func testMigratesLegacyKeyWhenNewKeyMissing() {
        defaults.set(AutoPlayMode.off.rawValue, forKey: AutoPlayModeStore.legacyKey)

        XCTAssertTrue(AutoPlayModeStore.migrateLegacyKeyIfNeeded(defaults))

        XCTAssertEqual(defaults.string(forKey: AutoPlayModeStore.key), AutoPlayMode.off.rawValue)
        XCTAssertNil(defaults.object(forKey: AutoPlayModeStore.legacyKey),
                     "舊 key 必須刪掉，否則下次啟動又會被當成待遷移")
        XCTAssertEqual(AutoPlayModeStore.load(defaults), .off)
    }

    /// 兩個 key 都有值：以新 key 為準（它才是實際驅動送出的那一個），舊 key 一樣清掉。
    func testNewKeyWinsOverLegacyKey() {
        defaults.set(AutoPlayMode.recommend.rawValue, forKey: AutoPlayModeStore.key)
        defaults.set(AutoPlayMode.off.rawValue, forKey: AutoPlayModeStore.legacyKey)

        XCTAssertFalse(AutoPlayModeStore.migrateLegacyKeyIfNeeded(defaults))

        XCTAssertEqual(AutoPlayModeStore.load(defaults), .recommend)
        XCTAssertNil(defaults.object(forKey: AutoPlayModeStore.legacyKey))
    }

    /// 舊 key 存了不是 `AutoPlayMode` 的字串：不搬、也不留，讀回預設值。
    func testInvalidLegacyValueIsDiscarded() {
        defaults.set("這不是模式", forKey: AutoPlayModeStore.legacyKey)

        XCTAssertFalse(AutoPlayModeStore.migrateLegacyKeyIfNeeded(defaults))

        XCTAssertNil(defaults.object(forKey: AutoPlayModeStore.legacyKey))
        XCTAssertNil(defaults.string(forKey: AutoPlayModeStore.key))
        XCTAssertEqual(AutoPlayModeStore.load(defaults), AutoPlayModeStore.defaultMode)
    }

    /// 遷移會被呼叫多次（App init 一次、`load()` 每次一次），第二次起必須是 no-op。
    func testMigrationIsIdempotent() {
        defaults.set(AutoPlayMode.recommend.rawValue, forKey: AutoPlayModeStore.legacyKey)

        XCTAssertTrue(AutoPlayModeStore.migrateLegacyKeyIfNeeded(defaults))
        XCTAssertFalse(AutoPlayModeStore.migrateLegacyKeyIfNeeded(defaults))
        XCTAssertFalse(AutoPlayModeStore.migrateLegacyKeyIfNeeded(defaults))

        XCTAssertEqual(AutoPlayModeStore.load(defaults), .recommend)
    }

    // MARK: - 讀寫

    /// 沒有任何存檔時的預設值（保持舊行為：全自動）。
    func testLoadFallsBackToDefaultMode() {
        XCTAssertEqual(AutoPlayModeStore.load(defaults), .auto)
        XCTAssertEqual(AutoPlayModeStore.defaultMode, .auto)
    }

    /// 存進去的模式讀得回來——「重啟後保留」靠的就是這一段。
    func testSaveThenLoadRoundTripsEveryMode() {
        for mode in AutoPlayMode.allCases {
            AutoPlayModeStore.save(mode, to: defaults)
            XCTAssertEqual(AutoPlayModeStore.load(defaults), mode)
            XCTAssertEqual(defaults.string(forKey: AutoPlayModeStore.key), mode.rawValue,
                           "@AppStorage 直接讀這個 key 的字串，格式必須是 rawValue")
        }
    }
}
