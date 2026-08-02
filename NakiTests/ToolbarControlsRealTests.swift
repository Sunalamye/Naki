//
//  ToolbarControlsRealTests.swift
//  NakiTests
//
//  p2-6：工具列四個控制項要真的生效。
//
//  兩組鎖：
//  1. 三個模式 × 四個行為的 3×4 矩陣（每格一個斷言，共 12 格）——不能只測 `.off`。
//     行為讀的是**產品真正讀的那個值／那個純函式**：
//       - 側欄推薦   → `AutoPlayMode.showRecommendation`（`RecommendationView`/`ContentView` 讀它）
//       - 遊戲內高亮 → `GameHighlightScript.make(...)`（`.off` 回 clear）
//       - 自動送出   → `AutoPlayGate.evaluate(...)`（只有 `.auto` 放行）
//       - 局間確認   → `AutoPlayGate.allowsConfirm(...)`（p2-5：只有 `.auto` 自動確認）
//  2. 延遲基準的持久化與縮放係數換算（與 mode 同一套「單一 key、重啟還原」機制）。
//
//  「AI 推論在 `.off` 仍跑」是第五欄，但它是背景推論的 runtime 行為（Bot 仍跟著牌局
//  更新，否則切回 `.recommend` 會一片空白，見 `AutoPlayMode.showRecommendation` 註解），
//  純函式測不到，故不在這 12 格內、以 live 驗（未驗證）。
//

import XCTest

@testable import Naki

final class AutoPlayModeBehaviorMatrixTests: XCTestCase {

    // MARK: - Fixtures

    private let recs = [Recommendation(tile: "1m", probability: 0.9, actionType: .discard)]
    private let tehai = ["1m", "2m", "3m"]

    /// 一批「輪到自己打牌」的合法 oplist，讓閘門的唯一變因是 mode。
    private func discardSnapshot() -> LiqiOperationSnapshot {
        LiqiOperationSnapshot(
            sequence: 1,
            seat: 0,
            operations: [LiqiOperation(type: .discard)],
            timeAdd: 0,
            timeFixed: 300,
            contextTile: "1m",
            source: "test",
            capturedAt: Date())
    }

    /// 一格＝一個 mode 的四個行為期望值。
    private struct Row {
        let mode: AutoPlayMode
        let sidebar: Bool     // 側欄是否顯示推薦
        let highlight: Bool   // 遊戲內是否染色（非 clear）
        let autoSend: Bool    // 是否自動送出打牌
        let confirm: Bool     // 局間是否自動送 confirmNewRound
    }

    private let matrix: [Row] = [
        Row(mode: .off,       sidebar: false, highlight: false, autoSend: false, confirm: false),
        Row(mode: .recommend, sidebar: true,  highlight: true,  autoSend: false, confirm: false),
        Row(mode: .auto,      sidebar: true,  highlight: true,  autoSend: true,  confirm: true),
    ]

    // MARK: - 3×4 矩陣（12 格）

    func testModeBehaviorMatrixHasAllTwelveCells() {
        let snapshot = discardSnapshot()

        for row in matrix {
            // ── 格 1：側欄推薦（`RecommendationView.showsRecommendations` 綁這個值）
            XCTAssertEqual(row.mode.showRecommendation, row.sidebar,
                           "[\(row.mode.rawValue)] 側欄推薦格")

            // ── 格 2：遊戲內高亮（`.off` 一律回 clear；有推薦時 recommend/auto 會染）
            let script = GameHighlightScript.make(mode: row.mode,
                                                  recommendations: recs,
                                                  tehaiTiles: tehai,
                                                  snapshot: nil)
            let highlightShown = script != GameHighlightScript.clear
            XCTAssertEqual(highlightShown, row.highlight,
                           "[\(row.mode.rawValue)] 遊戲內高亮格：script=\(script)")

            // ── 格 3：自動送出（同一份合法 oplist + 推薦，唯一變因是 mode）
            let sendDecision = AutoPlayGate.evaluate(.init(
                isAutoMode: row.mode.isFullAuto,
                isSanma: false,
                hasActionInFlight: false,
                snapshot: snapshot,
                recommendations: recs,
                now: Date(),
                callPassGrace: 2.0))
            let expectedSend: AutoPlayGate.Decision = row.autoSend ? .proceed : .skip(.notAutoMode)
            XCTAssertEqual(sendDecision, expectedSend,
                           "[\(row.mode.rawValue)] 自動送出格")

            // ── 格 4：局間確認（p2-5：只有 .auto 自動送 confirmNewRound）
            let confirmDecision = AutoPlayGate.allowsConfirm(
                isAutoMode: row.mode.isFullAuto, isSanma: false)
            let expectedConfirm: AutoPlayGate.Decision = row.confirm ? .proceed : .skip(.notAutoMode)
            XCTAssertEqual(confirmDecision, expectedConfirm,
                           "[\(row.mode.rawValue)] 局間確認格")
        }
    }

    /// 明確鎖住「局間確認」欄與剛完成的 p2-5 對齊：只有 `.auto` 放行，其餘皆 `.notAutoMode`。
    ///
    /// 與矩陣重疊是刻意的——這一欄是本 task 補充特別點名要對齊的，單獨留一條讓回歸時
    /// 一眼看得出是哪一格破。
    func testBetweenRoundConfirmOnlyInAutoMode() {
        XCTAssertEqual(AutoPlayGate.allowsConfirm(isAutoMode: AutoPlayMode.off.isFullAuto,
                                                  isSanma: false), .skip(.notAutoMode))
        XCTAssertEqual(AutoPlayGate.allowsConfirm(isAutoMode: AutoPlayMode.recommend.isFullAuto,
                                                  isSanma: false), .skip(.notAutoMode))
        XCTAssertEqual(AutoPlayGate.allowsConfirm(isAutoMode: AutoPlayMode.auto.isFullAuto,
                                                  isSanma: false), .proceed)
    }
}

// MARK: - 延遲基準的持久化與係數（與 mode 同機制）

final class SettingsStoreDelayPersistenceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // 每個 test 一個乾淨 suite：不碰使用者的 standard defaults（與 AutoPlayModeStoreTests 同策略）
        suiteName = "naki.tests.actiondelay.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// 沒有存檔時回預設 1.0s（＝現行行為，scale 1.0）。
    func testDefaultWhenUnset() {
        XCTAssertEqual(SettingsStore.loadActionDelaySeconds(defaults),
                       SettingsStore.defaultActionDelaySeconds, accuracy: 1e-9)
        XCTAssertEqual(SettingsStore.defaultActionDelaySeconds, 1.0, accuracy: 1e-9)
    }

    /// 存進去的秒數讀得回來——「重啟後保留」靠的就是這一段（新實例 init 走 `loadActionDelaySeconds`）。
    func testSaveThenLoadRoundTrips() {
        for value in [0.5, 0.8, 1.0, 1.7, 2.4, 3.0] {
            SettingsStore.saveActionDelaySeconds(value, to: defaults)
            XCTAssertEqual(SettingsStore.loadActionDelaySeconds(defaults), value, accuracy: 1e-9)
        }
    }

    /// 越界值一律夾回區間，永不持久化 garbage（防外部/舊版寫入污染）。
    func testOutOfRangeIsClamped() {
        SettingsStore.saveActionDelaySeconds(99, to: defaults)
        XCTAssertEqual(SettingsStore.loadActionDelaySeconds(defaults),
                       SettingsStore.actionDelayRange.upperBound, accuracy: 1e-9)

        SettingsStore.saveActionDelaySeconds(0.01, to: defaults)
        XCTAssertEqual(SettingsStore.loadActionDelaySeconds(defaults),
                       SettingsStore.actionDelayRange.lowerBound, accuracy: 1e-9)
    }

    /// 縮放係數換算：1.0s ⇒ scale 1.0（現行行為），2.0s ⇒ 2.0，0.5s ⇒ 0.5。
    func testScaleDerivation() {
        XCTAssertEqual(SettingsStore.actionDelayScale(forSeconds: 1.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(SettingsStore.actionDelayScale(forSeconds: 2.0), 2.0, accuracy: 1e-9)
        XCTAssertEqual(SettingsStore.actionDelayScale(forSeconds: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SettingsStore.actionDelayScale(forSeconds: 3.0), 3.0, accuracy: 1e-9)
    }
}
