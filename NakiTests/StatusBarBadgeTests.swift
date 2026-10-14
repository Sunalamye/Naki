import XCTest
import SwiftUI
import MortalSwift
@testable import Naki

/// `.off` 關掉推薦顯示，但 AI 仍在背景算，`recommendations` 不為空；狀態列徽章不得因此顯示。
@MainActor
final class StatusBarBadgeTests: XCTestCase {

    private func store(mode: AutoPlayMode, recommendations: [Recommendation]) -> GameStore {
        let store = GameStore()
        store.autoPlayMode = mode
        store.recommendations = recommendations
        store.statusMessage = "已連線到雀魂服務器"
        return store
    }

    private let sample = [Recommendation(tile: "8p", probability: 0.7, actionType: .discard)]

    func testBadgeHiddenWhenModeIsOffEvenWithRecommendations() {
        XCTAssertFalse(store(mode: .off, recommendations: sample).showsRecommendationBadge)
    }

    func testBadgeShownWhenModeShowsRecommendations() {
        for mode in AutoPlayMode.allCases where mode.showRecommendation {
            XCTAssertTrue(store(mode: mode, recommendations: sample).showsRecommendationBadge, "\(mode)")
        }
    }

    func testBadgeHiddenWithoutRecommendations() {
        for mode in AutoPlayMode.allCases {
            XCTAssertFalse(store(mode: mode, recommendations: []).showsRecommendationBadge, "\(mode)")
        }
    }

    /// 畫面證據：同一份推薦資料在 `.off` 與 `.recommend` 各渲染一張。
    /// 預設寫暫存目錄並附加到測試結果；設 `NAKI_SNAPSHOT_DIR` 時另外寫一份到該目錄。
    func testRenderStatusBarForOffAndRecommend() throws {
        let suite = "naki.tests.statusbar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("naki-statusbar-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpDir) }
        let outDirs = [tmpDir] + (ProcessInfo.processInfo.environment["NAKI_SNAPSHOT_DIR"].map { [URL(fileURLWithPath: $0, isDirectory: true)] } ?? [])
        for (name, mode) in [("off", AutoPlayMode.off), ("recommend", .recommend)] {
            let env = NakiEnvironment(store: store(mode: mode, recommendations: sample), settings: SettingsStore(defaults: defaults),
                                      actions: NakiActions(), pluginStore: PluginStore(), ui: UIState(),
                                      logManager: .shared, jsInjection: JSInjectionState(), parseFault: LiqiParseFaultState())
            let renderer = ImageRenderer(content: StatusBar()
                .frame(width: 480, height: 40)
                .background(Color.windowBackground)
                .environment(\.naki, env)
                .environment(\.locale, Locale(identifier: "zh-Hant"))
                .environment(\.colorScheme, .light))
            renderer.scale = 2
            var image: CGImage?
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
            let cgImage = try XCTUnwrap(image)
            let file = "statusbar-\(name).png"
            for dir in outDirs {
                try PixelDiff.write(cgImage, to: dir.appendingPathComponent(file))
            }
            let attachment = XCTAttachment(contentsOfFile: tmpDir.appendingPathComponent(file))
            attachment.name = file
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
