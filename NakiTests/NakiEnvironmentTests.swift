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
            _ = try await NakiActions().executeJavaScript("return 1")
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
        environment.actions.triggerAutoPlay()
        environment.actions.setAutoPlayMode(.off)
        environment.actions.setHidePlayerNames(true)

        XCTAssertFalse(environment.store.isDebugServerRunning)
        // `setAutoPlayMode` 的收斂與持久化在 runtime，預設 Action 連 store 都不碰
        XCTAssertEqual(environment.store.autoPlayMode, AutoPlayModeStore.defaultMode)
    }
}

// MARK: - SettingsStore

@MainActor
final class SettingsStoreTests: XCTestCase {

    /// key 只有一份（先前三個檔案各寫一次，其中兩份是字面值）
    func testHidePlayerNamesKeyIsTheOnlyDefinition() {
        XCTAssertEqual(SettingsStore.hidePlayerNamesKey, "HidePlayerNames")
    }

    /// 初值來自持久化，不是硬寫 false
    func testHidePlayerNamesReadsPersistedValue() {
        let store = SettingsStore()

        XCTAssertEqual(
            store.hidePlayerNames,
            UserDefaults.standard.bool(forKey: SettingsStore.hidePlayerNamesKey))
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
