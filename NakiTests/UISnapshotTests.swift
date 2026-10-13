import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import MortalSwift
@testable import Naki

/// 元件快照：固定 fixture 渲染成 PNG，與 `docs/ui-reference/app-baseline/` 逐像素比對，差異不超過 `PixelDiff.thresholdPermille` 才通過。
///
/// 重錄（錄製的那次一律失敗，不會被當成綠燈）：
/// `TEST_RUNNER_NAKI_SNAPSHOT_RECORD=1 xcodebuild test -project Naki.xcodeproj -scheme Naki -only-testing:NakiTests/UISnapshotTests`
@MainActor
final class UISnapshotTests: XCTestCase {

    private static let scale: CGFloat = 2
    private static let locale = "zh-Hant"
    private static let sidebarSize = CGSize(width: 380, height: 600)
    private static let cardWidth: CGFloat = 348
    private static let bannerSize = CGSize(width: 760, height: 70)
    private static let isRecording = ProcessInfo.processInfo.environment["NAKI_SNAPSHOT_RECORD"] == "1"
    private static let baselineDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/ui-reference/app-baseline", isDirectory: true)
    private static let osTag: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS\(v.majorVersion).\(v.minorVersion)"
    }()

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "naki.tests.snapshot.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - 快照

    func testDecisionSidebar() {
        let env = environment { store, _, _ in Self.inGame(store) }
        assertSnapshot(DecisionSidebar(), env: env, name: "DecisionSidebar_regular", size: Self.sidebarSize)
        assertSnapshot(DecisionSidebar(compact: true), env: env, name: "DecisionSidebar_compact", size: CGSize(width: 220, height: 560))
    }

    func testDecisionCard() {
        let env = environment()
        let size = CGSize(width: Self.cardWidth, height: 120)
        assertSnapshot(DecisionCard(recommendation: Recommendation(tile: "8p", probability: 0.712, actionType: .discard)),
                       env: env, name: "DecisionCard_discard", size: size)
        assertSnapshot(DecisionCard(recommendation: Recommendation(actionType: .chi, probability: 0.742, label: "chi_1",
                                                                   detail: "用 3m·5m 吃 4m")),
                       env: env, name: "DecisionCard_chi-detail", size: size)
        assertSnapshot(DecisionCard(recommendation: Recommendation(tile: "5mr", probability: 0.41, actionType: .discard), compact: true),
                       env: env, name: "DecisionCard_compact", size: CGSize(width: 200, height: 80))
    }

    func testOptionList() {
        let env = environment()
        let others = Array(Self.recommendations.dropFirst())
        assertSnapshot(OptionList(options: others, maxDisplay: 3, compact: false),
                       env: env, name: "OptionList_regular", size: CGSize(width: Self.cardWidth, height: 160))
        assertSnapshot(OptionList(options: others, maxDisplay: 2, compact: true),
                       env: env, name: "OptionList_compact", size: CGSize(width: 200, height: 90))
    }

    func testDecisionAlerts() {
        let env = environment()
        let size = CGSize(width: Self.cardWidth, height: 56)
        var degraded = BotStatus()
        degraded.cloudHost = "api.example.test"
        degraded.cloudDegraded = true
        degraded.cloudFallbackStreak = 3
        assertSnapshot(DecisionAlerts(botStatus: degraded, autoPlayStall: nil, compact: false),
                       env: env, name: "DecisionAlerts_cloud-degraded", size: size)
        assertSnapshot(DecisionAlerts(botStatus: BotStatus(),
                                      autoPlayStall: AutoPlayStall(reason: "no_open_majsoul_connection", consecutiveTicks: 6,
                                                                   sinceSequence: 42, elapsedSeconds: 12),
                                      compact: false),
                       env: env, name: "DecisionAlerts_stall", size: size)
        var sanma = BotStatus()
        sanma.is3P = true
        assertSnapshot(DecisionAlerts(botStatus: sanma, autoPlayStall: nil, compact: false),
                       env: env, name: "DecisionAlerts_sanma", size: size)
    }

    func testBanners() {
        let size = Self.bannerSize
        assertSnapshot(PageLoadFailureBanner(),
                       env: environment { store, _, _ in store.pageLoadFailure = "NSURLErrorDomain -1009：網路連線似乎已中斷。" },
                       name: "PageLoadFailureBanner", size: size)
        assertSnapshot(BotFailureBanner(),
                       env: environment { store, _, _ in store.botFailure = "Bot 推論失敗：Core ML 模型輸出形狀不符（expected 46, got 0）" },
                       name: "BotFailureBanner", size: size)
        assertSnapshot(JSInjectionFailureBanner(),
                       env: environment { _, js, _ in
                           js.record(.failed(loaded: ["naki-websocket"], failures: [JSModuleFailure(module: "naki-core", reason: .notFound)]))
                       },
                       name: "JSInjectionFailureBanner", size: size)
        assertSnapshot(LiqiParseFailureBanner(),
                       env: environment { _, _, fault in
                           fault.record(LiqiParseFault(site: "ResAuthGame.seat_list", byteCount: 0, reason: "missing", severity: .blocking))
                       },
                       name: "LiqiParseFailureBanner", size: size)
    }

    /// 延遲到達端點：設定頁寬版顯示「最快」、工具列窄版顯示「最慢」（新圖，WP-B）。
    func testActionDelayBounds() {
        let lower = environment()
        lower.settings.actionDelaySeconds = SettingsStore.actionDelayRange.lowerBound
        assertSnapshot(ActionDelayStepper(), env: lower, name: "ActionDelayStepper_settings-fastest", size: CGSize(width: 420, height: 32))
        let upper = environment()
        upper.settings.actionDelaySeconds = SettingsStore.actionDelayRange.upperBound
        assertSnapshot(ActionDelayStepper(compact: true), env: upper, name: "ActionDelayStepper_toolbar-slowest", size: CGSize(width: 200, height: 32))
    }

    // MARK: - 渲染性質

    /// 同一 fixture 連續渲染兩次必須逐像素相同，否則 baseline 比對沒有意義。
    func testRenderingIsDeterministic() throws {
        let env = environment { store, _, _ in Self.inGame(store) }
        let size = Self.sidebarSize
        let first = try XCTUnwrap(render(DecisionSidebar(), env: env, size: size, scheme: .light))
        let second = try XCTUnwrap(render(DecisionSidebar(), env: env, size: size, scheme: .light))
        XCTAssertEqual(try PixelDiff.compare(first, second).differing, 0)
    }

    /// 淺色與深色是兩張不同的圖：背景角落的像素必須不同（確認 appearance 真的被強制）。
    func testColorSchemeIsForced() throws {
        let env = environment()
        let size = CGSize(width: 40, height: 40)
        let light = try XCTUnwrap(render(EmptyRecommendationView(), env: env, size: size, scheme: .light))
        let dark = try XCTUnwrap(render(EmptyRecommendationView(), env: env, size: size, scheme: .dark))
        XCTAssertNotEqual(Array(PixelDiff.rgba(light).prefix(4)), Array(PixelDiff.rgba(dark).prefix(4)))
    }

    // MARK: - 比對契約

    func testDiffCountsSinglePixel() throws {
        let base = Self.solid(width: 200, height: 100)
        XCTAssertEqual(try PixelDiff.compare(base, Self.altered(base, pixels: 1)).differing, 1)
    }

    /// R、G、B、A 任一通道不同都算差異像素。
    func testDiffCountsEveryChannel() throws {
        let base = Self.solid(width: 200, height: 100)
        for channel in 0..<4 {
            XCTAssertEqual(try PixelDiff.compare(base, Self.altered(base, pixels: 1, channel: channel)).differing, 1, "channel \(channel)")
        }
    }

    /// 門檻本身釘在千分之 15：20000 像素的 300 通過、301 失敗。
    func testThresholdIsFifteenPermille() throws {
        XCTAssertEqual(PixelDiff.thresholdPermille, 15)
        let base = Self.solid(width: 200, height: 100)
        XCTAssertTrue(try PixelDiff.compare(base, Self.altered(base, pixels: 300)).withinThreshold)
        XCTAssertFalse(try PixelDiff.compare(base, Self.altered(base, pixels: 301)).withinThreshold)
    }

    func testSizeMismatchFails() {
        XCTAssertThrowsError(try PixelDiff.compare(Self.solid(width: 200, height: 100), Self.solid(width: 200, height: 101)))
    }

    func testMissingOrUnreadableBaselineFails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("naki-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try PixelDiff.load(dir.appendingPathComponent("missing.png")))
        let garbage = dir.appendingPathComponent("garbage.png")
        try Data("not a png".utf8).write(to: garbage)
        XCTAssertThrowsError(try PixelDiff.load(garbage))
    }

    /// baseline 檔不存在時，快照比對必須失敗，不能被當成通過。
    func testSnapshotFailsWhenBaselineMissing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("naki-snapshot-\(UUID().uuidString)")
        XCTExpectFailure {
            assertSnapshot(EmptyRecommendationView(), env: environment(), name: "missing", size: CGSize(width: 40, height: 40), baselineDir: dir)
        }
    }

    // MARK: - Fixture

    private static let recommendations: [Recommendation] = [
        Recommendation(tile: "8p", probability: 0.712, actionType: .discard),
        Recommendation(actionType: .riichi, probability: 0.164, label: "reach"),
        Recommendation(tile: "3s", probability: 0.071, actionType: .discard),
        Recommendation(tile: "E", probability: 0.032, actionType: .discard),
        Recommendation(tile: "9m", probability: 0.021, actionType: .discard),
    ]

    /// 東 2 局 1 本場、供託 1、自家座位 1（本局莊家）、可打可立直。
    private static func inGame(_ store: GameStore) {
        var state = GameState()
        state.kyoku = 2
        state.honba = 1
        state.kyotaku = 1
        state.scores = [32000, 24100, 18900, 25000]
        state.playerId = 1
        state.doraMarkers = ["5mr"].compactMap(Tile.init(mjaiString:))
        store.gameState = state
        var bot = BotStatus()
        bot.isActive = true
        bot.playerId = 1
        bot.canDiscard = true
        bot.canRiichi = true
        store.botStatus = bot
        store.autoPlayMode = .recommend
        store.recommendations = recommendations
    }

    private func environment(_ configure: (GameStore, JSInjectionState, LiqiParseFaultState) -> Void = { _, _, _ in }) -> NakiEnvironment {
        let store = GameStore()
        let js = JSInjectionState()
        let fault = LiqiParseFaultState()
        configure(store, js, fault)
        return NakiEnvironment(store: store, settings: SettingsStore(defaults: defaults), actions: NakiActions(),
                               pluginStore: PluginStore(), ui: UIState(), logManager: .shared,
                               jsInjection: js, parseFault: fault)
    }

    // MARK: - 渲染與比對

    private func render(_ view: some View, env: NakiEnvironment, size: CGSize, scheme: ColorScheme) -> CGImage? {
        let renderer = ImageRenderer(content: view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color.windowBackground)
            .environment(\.naki, env)
            .environment(\.locale, Locale(identifier: Self.locale))
            .environment(\.colorScheme, scheme))
        renderer.scale = Self.scale
        var image: CGImage?
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return image
    }

    private func assertSnapshot(_ view: some View, env: NakiEnvironment, name: String, size: CGSize,
                                baselineDir: URL = UISnapshotTests.baselineDir,
                                file: StaticString = #filePath, line: UInt = #line) {
        for scheme in [ColorScheme.light, .dark] {
            let fileName = "\(name)_\(Int(size.width))x\(Int(size.height))@\(Int(Self.scale))x_\(Self.osTag)_\(Self.locale)_\(scheme == .dark ? "dark" : "light").png"
            let url = baselineDir.appendingPathComponent(fileName)
            guard let image = render(view, env: env, size: size, scheme: scheme) else {
                XCTFail("\(fileName)：ImageRenderer 沒有產出影像", file: file, line: line)
                continue
            }
            if Self.isRecording {
                XCTAssertNoThrow(try PixelDiff.write(image, to: url), file: file, line: line)
                XCTFail("\(fileName)：record 模式已寫入 baseline，本次不算通過", file: file, line: line)
                continue
            }
            do {
                let result = try PixelDiff.compare(image, try PixelDiff.load(url))
                print("[snapshot] \(fileName) diff=\(result.differing)/\(result.total)")
                XCTAssertTrue(result.withinThreshold,
                              "\(fileName)：差異 \(result.differing)/\(result.total) 超過千分之 \(PixelDiff.thresholdPermille)", file: file, line: line)
            } catch {
                XCTFail("\(fileName)：\(error)", file: file, line: line)
            }
        }
    }

    private static func solid(width: Int, height: Int) -> CGImage {
        PixelDiff.image(from: Array([[UInt8]](repeating: [128, 128, 128, 255], count: width * height).joined()), width: width, height: height)
    }

    private static func altered(_ image: CGImage, pixels: Int, channel: Int = 0) -> CGImage {
        var bytes = PixelDiff.rgba(image)
        for i in 0..<pixels { bytes[i * 4 + channel] &-= 1 }
        return PixelDiff.image(from: bytes, width: image.width, height: image.height)
    }
}

/// 逐像素比對：兩邊都先畫進同一個 sRGB RGBA8 context，任一通道不同即算一個差異像素。
nonisolated enum PixelDiff {

    /// 千分之 15（1.5%）；用整數比較，避開浮點在邊界的誤差。
    static let thresholdPermille = 15

    struct Result {
        let differing: Int
        let total: Int
        var withinThreshold: Bool { differing * 1000 <= total * PixelDiff.thresholdPermille }
    }

    enum Failure: Error {
        case sizeMismatch(actual: String, baseline: String)
        case unreadable(String)
    }

    static func compare(_ actual: CGImage, _ baseline: CGImage) throws -> Result {
        guard actual.width == baseline.width, actual.height == baseline.height else {
            throw Failure.sizeMismatch(actual: "\(actual.width)x\(actual.height)", baseline: "\(baseline.width)x\(baseline.height)")
        }
        let a = rgba(actual), b = rgba(baseline)
        var differing = 0
        for i in stride(from: 0, to: a.count, by: 4) where a[i..<i + 4] != b[i..<i + 4] {
            differing += 1
        }
        return Result(differing: differing, total: actual.width * actual.height)
    }

    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.unreadable(url.path)
        }
        return image
    }

    static func write(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.unreadable(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure.unreadable(url.path) }
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func image(from bytes: [UInt8], width: Int, height: Int) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: Data(bytes) as CFData)!,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
