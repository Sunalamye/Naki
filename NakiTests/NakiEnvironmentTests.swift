//
//  NakiEnvironmentTests.swift
//  NakiTests
//
//  p3-4 回歸鎖：`WebViewModel` / `WebViewModelProtocol` 已刪除，View 層改吃
//  `@Environment(\.naki)`，而預設值**只給 Preview**。
//
//  為什麼要用「掃原始碼」這種土方法：這一批都是**結構性**約束，型別系統看不見。
//  例如「App 層有沒有顯式注入」——忘了注入不會有編譯錯誤，只會讓每個 View 各自
//  拿到 `@Entry` 的預設值，也就是**一個全新的空 `GameStore`**：畫面永遠不更新、
//  按鈕永遠沒反應，而 MCP 那邊照樣有資料。那正是 p3-1 花整個 task 修掉的
//  「雙重真實來源」，只是換了個入口回來。
//

import SwiftUI
import XCTest

@testable import Naki

// MARK: - 結構鎖

final class NakiEnvironmentSourceTests: XCTestCase {

    private func repoRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // NakiTests/
            .deletingLastPathComponent()   // repo root
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("command").path)
        else {
            throw XCTSkip("找不到原始碼目錄 \(root.path)（repo 被搬走時這個鎖失效）")
        }
        return root
    }

    /// 掃 `<dir>/**/*.swift`，回傳 (相對路徑, 行號, 行內容)，已濾掉純註解行
    private func codeLines(under directory: URL) -> [(file: String, line: Int, text: String)] {
        var out: [(String, Int, String)] = []
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil)
        else { return out }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }   // 說明文字裡會提到這些名字
                out.append((relative, index + 1, String(raw)))
            }
        }
        return out
    }

    /// 三個型別整批刪除，不得有任何殘留引用（驗收條件 1、2）
    func testWebViewModelTypesAreGone() throws {
        let root = try repoRoot()
        let banned = ["WebViewModelProtocol", "WebViewModelFactory",
                      "LegacyWebViewModel", "WebViewModel"]

        let hits = codeLines(under: root.appendingPathComponent("command"))
            .filter { line in banned.contains { line.text.contains($0) } }

        XCTAssertTrue(
            hits.isEmpty,
            "`WebViewModel` 系列已被 `WebSession` + `NakiRuntime` 取代，不該再出現；實際: "
                + hits.map { "\($0.file):\($0.line)" }.joined(separator: ", "))
    }

    /// View 層不得再向下轉型撈具體 view model（驗收條件 1）。
    ///
    /// 那個 `as?` 一失敗就只剩一個永遠轉圈的 `ProgressView`
    /// ——沒有編譯錯誤，也沒有執行期例外。
    func testNoDowncastToConcreteViewModel() throws {
        let root = try repoRoot()
        let hits = codeLines(under: root.appendingPathComponent("command"))
            .filter { $0.text.contains("as? WebViewModel") || $0.text.contains("as? LegacyWebViewModel") }

        XCTAssertTrue(
            hits.isEmpty,
            "View 不得認得具體 WebView 實作；實際: "
                + hits.map { "\($0.file):\($0.line)" }.joined(separator: ", "))
    }

    /// 舊的 environment key 一併消失（否則會有兩條注入路徑並存）
    func testOldEnvironmentKeyIsGone() throws {
        let root = try repoRoot()
        let hits = codeLines(under: root.appendingPathComponent("command"))
            .filter { $0.text.contains("webViewModel") }

        XCTAssertTrue(
            hits.isEmpty,
            "`\\.webViewModel` 已被 `\\.naki` 取代；實際: "
                + hits.map { "\($0.file):\($0.line)" }.joined(separator: ", "))
    }

    /// View 不得直讀單例：狀態一律經 `@Environment(\.naki)` 取得（2026-08-02 決策），
    /// 否則 Preview 與單測換不掉它。白名單只放系統 API；先去掉白名單字樣再比對，
    /// 同一行另有單例照樣抓。
    ///
    /// 比對 `\bshared\b`（不要求前面有點，`extension X { static var y { shared } }` 這種轉出也抓）；
    /// 四個名稱並列是為了 regex 日後被放寬時，已知的單例與直呼的 `fetchAny` 仍有保護。
    func testViewsDoNotReadSingletons() throws {
        let root = try repoRoot()
        let allowed = ["UIApplication.shared"]
        let banned = ["LogManager.shared", "JSInjectionState.shared", "LiqiParseFaultState.shared",
                      "PluginImportSource.fetchAny"]
        let lines = codeLines(under: root.appendingPathComponent("command/Views"))
        XCTAssertFalse(lines.isEmpty, "command/Views 掃不到任何行，路徑變了或目錄不存在，lint 會空轉通過")
        let hits = lines.filter { line in
            let rest = allowed.reduce(line.text) { $0.replacingOccurrences(of: $1, with: "") }
            return rest.range(of: #"\bshared\b"#, options: .regularExpression) != nil
                || banned.contains { rest.contains($0) }
        }

        XCTAssertTrue(
            hits.isEmpty,
            "command/Views 不得出現 `shared` 或 \(banned.joined(separator: "／"))（改經 `NakiEnvironment`）；實際: "
                + hits.map { "\($0.file):\($0.line)" }.joined(separator: ", "))
    }

    /// **App 層必須顯式注入**（p3-4 的核心約束）。
    ///
    /// `@Entry` 的預設值只給 Preview：忘了注入不會有編譯錯誤，只會讓 View 拿到
    /// 一個全新的空 `GameStore`，畫面永遠不更新——而那正是 p3-1 修掉的雙重真實來源。
    func testAppScenesInjectEnvironmentExplicitly() throws {
        let root = try repoRoot()
        let entries = ["Naki/App/NakiApp.swift", "Naki-M/Naki_MApp.swift"]

        for entry in entries {
            let url = root.appendingPathComponent(entry)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("找不到 App 進入點 \(entry)")
                continue
            }
            XCTAssertTrue(
                source.contains("NakiRuntime()"),
                "\(entry) 應持有一份 NakiRuntime")
            XCTAssertTrue(
                source.contains(#".environment(\.naki, runtime.environment)"#),
                "\(entry) 必須顯式注入 `\\.naki`（預設值只給 Preview）")
        }
    }
}

// MARK: - Preview 預設值的行為

/// 「預設值只給 Preview」要成立，前提是它**真的沒有副作用**：
/// 不建立 WebView、不綁 loopback 8765、按鈕按下去什麼都不會送出。
@MainActor
final class NakiEnvironmentDefaultsTests: XCTestCase {

    func testDefaultEnvironmentHasEmptyStore() {
        let environment = NakiEnvironment()

        XCTAssertTrue(environment.store.recommendations.isEmpty)
        XCTAssertTrue(environment.store.statusMessage.isEmpty)
        XCTAssertFalse(environment.store.isConnected)
        XCTAssertFalse(environment.store.isDebugServerRunning)
    }

    /// 兩次預設值是**兩個不同的 store**——這正是「不可以拿它當正式路徑」的理由
    func testDefaultEnvironmentIsNotShared() {
        let a = NakiEnvironment()
        let b = NakiEnvironment()

        XCTAssertFalse(a.store === b.store)
    }

    /// 預設 Action 不做事，而且**說出自己沒接線**（不是靜靜地成功）
    func testDefaultForceReconnectReportsNotWired() async {
        let outcome = await NakiActions().forceReconnect()

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.dictionary["error"] as? String, "not_wired")
    }

    func testDefaultExecuteJavaScriptThrows() async {
        do {
            _ = try await ExecuteJavaScriptAction()("return 1")
            XCTFail("Preview 預設值不該假裝執行成功")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("JavaScript execution"))
        }
    }

    /// 無副作用的那幾個：呼叫不 crash、也不改變任何狀態
    func testDefaultNoOpActionsDoNothing() {
        let environment = NakiEnvironment()

        environment.actions.deleteBot()
        environment.actions.toggleDebugServer()
        environment.actions.reloadPage()
        environment.actions.setAutoPlayMode(.off)

        XCTAssertFalse(environment.store.isDebugServerRunning)
        // `setAutoPlayMode` 的收斂與持久化在 runtime，預設 Action 連 store 都不碰
        XCTAssertEqual(environment.store.autoPlayMode, AutoPlayModeStore.defaultMode)
    }
}

// MARK: - SettingsStore

@MainActor
final class SettingsStoreTests: XCTestCase {

    /// 背景保活預設開；未設定過的 key 不能落到 `UserDefaults.bool` 的 false。用獨立 suite，不碰 `.standard`。
    func testKeepAliveInBackgroundDefaultsToOnAndHonorsPersistedValue() throws {
        let name = "naki.tests.keepAlive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertTrue(SettingsStore.loadKeepAliveInBackground(from: defaults))

        defaults.set(false, forKey: SettingsStore.keepAliveInBackgroundKey)
        XCTAssertFalse(SettingsStore.loadKeepAliveInBackground(from: defaults))

        defaults.set(true, forKey: SettingsStore.keepAliveInBackgroundKey)
        XCTAssertTrue(SettingsStore.loadKeepAliveInBackground(from: defaults))
    }

    /// 能力旗標由 runtime 在選定 backend 之後寫入一次；預設樂觀為 true，
    /// 因為 macOS deployment target 是 26（永遠是 WebPage path）。
    func testAutoPlaySupportIsAdoptedFromTheBackend() {
        let store = SettingsStore()
        XCTAssertTrue(store.supportsAutoPlay)

        store.adoptAutoPlaySupport(false)

        XCTAssertFalse(store.supportsAutoPlay)
        XCTAssertEqual(AutoPlayAvailability.modes(autoPlaySupported: store.supportsAutoPlay),
                       [.off, .recommend],
                       "不支援自動送出時 picker 上不該有「自動」")
    }
}

// MARK: - Recommendation.actionName

/// 期望值抄自改動前 `DecisionSidebar` 兩處的三元式（打牌 → `actionType.displayName`，其餘 → `displayLabel`）。
@MainActor
final class RecommendationActionNameTests: XCTestCase {

    func testActionNameMatchesFormerSidebarLogic() {
        let cases: [(Recommendation, String)] = [
            (Recommendation(tile: "8p", probability: 0.4, actionType: .discard), "打"),
            (Recommendation(tile: "?", probability: 0.4, actionType: .discard), "打"),
            (Recommendation(actionType: .riichi, probability: 0.1), "立直"),
            (Recommendation(tile: "chi_0", probability: 0.1, actionType: .chi), "吃①"),
            (Recommendation(tile: "chi_1", probability: 0.1, actionType: .chi), "吃②"),
            (Recommendation(tile: "chi_2", probability: 0.1, actionType: .chi), "吃③"),
            (Recommendation(actionType: .chi, probability: 0.1), "吃"),
            (Recommendation(actionType: .pon, probability: 0.1), "碰"),
            (Recommendation(actionType: .kan, probability: 0.1), "槓"),
            (Recommendation(actionType: .hora, probability: 0.1), "和"),
            (Recommendation(actionType: .kita, probability: 0.1), "拔北"),
            (Recommendation(actionType: .ryukyoku, probability: 0.1), "九種九牌"),
            (Recommendation(actionType: .none, probability: 0.1), "過"),
            (Recommendation(tile: "foo", probability: 0.1, actionType: .unknown), "foo"),
        ]
        for (recommendation, expected) in cases {
            XCTAssertEqual(recommendation.actionName, expected, "\(recommendation.actionType) \(recommendation.label)")
        }
        XCTAssertEqual(cases[0].0.actionNameKey, LocalizedStringKey("打"))
    }
}

// MARK: - ConnectionSettingsAction

/// 字典規則抄自改動前 `MajsoulConnectionSettingsBox.apply()`：空名稱略過、空值保留、重複名稱後者勝出。
@MainActor
final class ConnectionSettingsHeadersTests: XCTestCase {

    private let rows: [(name: String, value: String)] = [
        ("X-A", "1"), ("", "dropped"), ("X-Empty", ""), ("X-B", "b"), ("X-A", "2"),
    ]
    private let expected = ["X-A": "2", "X-Empty": "", "X-B": "b"]

    func testHeadersDictionaryMatchesFormerViewAssembly() {
        XCTAssertEqual(ConnectionSettingsAction.headers(from: rows), expected)
        XCTAssertEqual(ConnectionSettingsAction.headers(from: []), [:])
    }

    func testApplyWritesHeadersBeforeReloading() {
        var events: [String] = []
        var saved: [String: String]?
        let action = ConnectionSettingsAction(
            stub: { events.append("reload") },
            saveHeaders: { saved = $0; events.append("save") })

        action.apply(headers: rows)

        XCTAssertEqual(events, ["save", "reload"])
        XCTAssertEqual(saved, expected)
    }
}

// MARK: - View 改走 Action 的三個副作用

@MainActor
final class ViewSideEffectActionTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "naki.tests.wp8.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeUpdate() throws -> ReleaseInfo {
        ReleaseInfo(version: "9.9.9", url: try XCTUnwrap(URL(string: "https://example.invalid/r")))
    }

    /// 改動前「略過此版本」：先寫 skippedUpdateVersion，再清 availableUpdate。
    func testDismissUpdateWithSkipRemembersVersionAndClears() throws {
        let store = GameStore()
        let settings = SettingsStore(defaults: defaults)
        store.availableUpdate = try makeUpdate()

        DismissUpdateAction(store: store, settings: settings)(skip: true)

        XCTAssertEqual(settings.skippedUpdateVersion, "9.9.9")
        XCTAssertEqual(defaults.string(forKey: SettingsStore.skippedUpdateVersionKey), "9.9.9")
        XCTAssertNil(store.availableUpdate)
    }

    /// 改動前「關閉提示」：只清 availableUpdate，不記略過。
    func testDismissUpdateWithoutSkipOnlyClears() throws {
        let store = GameStore()
        let settings = SettingsStore(defaults: defaults)
        store.availableUpdate = try makeUpdate()

        DismissUpdateAction(store: store, settings: settings)(skip: false)

        XCTAssertNil(settings.skippedUpdateVersion)
        XCTAssertNil(defaults.string(forKey: SettingsStore.skippedUpdateVersionKey))
        XCTAssertNil(store.availableUpdate)
    }

    func testFetchPluginImportForwardsURLAndResult() async {
        var asked: [String] = []
        let action = FetchPluginImportAction(stub: { asked.append($0); return .failure(.notHTTPS) })

        let result = await action(urlString: "http://example.invalid/p")

        XCTAssertEqual(asked, ["http://example.invalid/p"])
        guard case .failure(.notHTTPS) = result else { return XCTFail("應原樣回傳 stub 結果：\(result)") }
    }

    /// Preview 預設值不連網：直接回空清單。
    func testDefaultFetchPluginImportReturnsEmptyWithoutNetwork() async {
        let result = await FetchPluginImportAction()(urlString: "https://example.invalid/p")
        guard case .success(let list) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(list.isEmpty)
    }

    /// 真實實作清的是 test host 共用的 `LogManager.shared`，這裡只驗轉發。
    func testClearLogsForwards() {
        var cleared = 0
        ClearLogsAction(stub: { cleared += 1 })()
        ClearLogsAction()()
        XCTAssertEqual(cleared, 1)
    }
}

// MARK: - environment 上的三個 service ref

@MainActor
final class NakiEnvironmentTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "naki.tests.wp8.env.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeEnvironment(store: GameStore, jsInjection: JSInjectionState,
                                 parseFault: LiqiParseFaultState) -> NakiEnvironment {
        NakiEnvironment(store: store, settings: SettingsStore(defaults: defaults), actions: NakiActions(),
                        pluginStore: PluginStore(), ui: UIState(), logManager: .shared,
                        jsInjection: jsInjection, parseFault: parseFault)
    }

    /// 四個來源各自單獨成立都要算故障；全不成立才不算。全用注入的新實例，不碰 `.shared`。
    func testHasFaultReadsFourSourcesFromEnvironment() {
        let faults: [(String, (GameStore, JSInjectionState, LiqiParseFaultState) -> Void)] = [
            ("botFailure", { store, _, _ in store.botFailure = "bot" }),
            ("pageLoadFailure", { store, _, _ in store.pageLoadFailure = "page" }),
            ("jsInjection", { _, js, _ in
                js.record(.failed(loaded: [], failures: [JSModuleFailure(module: "naki-core", reason: .notFound)]))
            }),
            ("parseFault", { _, _, fault in
                fault.record(LiqiParseFault(site: "ResAuthGame.seat_list", byteCount: 0,
                                            reason: "missing", severity: .blocking))
            }),
        ]

        let clean = makeEnvironment(store: GameStore(), jsInjection: JSInjectionState(),
                                    parseFault: LiqiParseFaultState())
        XCTAssertFalse(clean.hasFault)

        for (name, inject) in faults {
            let store = GameStore()
            let js = JSInjectionState()
            let fault = LiqiParseFaultState()
            inject(store, js, fault)
            let environment = makeEnvironment(store: store, jsInjection: js, parseFault: fault)
            XCTAssertTrue(environment.hasFault, "\(name) 單獨成立時應算故障")
            XCTAssertTrue(environment.jsInjection === js && environment.parseFault === fault,
                          "environment 必須回傳注入的那一份")
        }
    }

    /// Preview 預設值讀取時解析成 `.shared`（判斷理由見 `NakiEnvironment`），兩次讀取是同一份。
    func testPreviewRefsResolveToShared() {
        let preview = NakiEnvironment()
        XCTAssertTrue(preview.logManager === LogManager.shared)
        XCTAssertTrue(preview.jsInjection === JSInjectionState.shared)
        XCTAssertTrue(preview.parseFault === LiqiParseFaultState.shared)
    }
}
