//
//  PlatformDivergenceTests.swift
//  NakiTests
//
//  p2-3 回歸鎖：平台／版本分歧只准有一個判斷點。
//
//  為什麼要用「掃原始碼」這種土方法：這兩件事都是**結構性**約束，型別系統看不見。
//  `WebViewModelFactory` 與 `AdaptiveNakiWebView` 曾經各寫一次
//  `if #available(macOS 26.0, iOS 26.0, *)`，靠註解「需要與 … 保持一致」維持——
//  改一處忘另一處會得到 WebPage VM + Legacy View 的組合，View 層的 `as?` 靜靜轉型失敗，
//  畫面只剩「正在初始化…」，沒有編譯錯誤也沒有執行期例外。同理，Debug Server 一旦
//  被包回 `#if os(macOS)`，iOS 就會再次變成「有沒有 MCP 取決於 OS 版本」。
//
//  這裡只能驗**原始碼形狀**，驗不到 iOS 上跑起來如何（本機沒有 iOS 26 platform，
//  `Naki-M` 連編譯都跑不了；見 tasks/naki/p2-3 執行結果）。
//

import XCTest

final class PlatformDivergenceTests: XCTestCase {

    /// repo 裡的 `command/` 目錄（`#filePath` = 編譯當下這個檔案的絕對路徑）
    private func commandSourceRoot() throws -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile
            .deletingLastPathComponent()   // NakiTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("command")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("找不到原始碼目錄 \(root.path)（repo 被搬走時這個鎖失效）")
        }
        return root
    }

    /// 掃 `command/**/*.swift`，回傳 (相對路徑, 行號, 行內容)，已濾掉純註解行。
    private func codeLines(in root: URL) -> [(file: String, line: Int, text: String)] {
        var out: [(String, Int, String)] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return out
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                // 註解行不算：說明文字裡會出現這些字串
                if trimmed.hasPrefix("//") { continue }
                out.append((relative, index + 1, String(raw)))
            }
        }
        return out
    }

    /// 版本分歧只有 `WebViewModelFactory.create()` 一處
    func testVersionCheckExistsExactlyOnce() throws {
        let root = try commandSourceRoot()
        let hits = codeLines(in: root).filter { $0.text.contains("#available") }

        XCTAssertEqual(
            hits.count, 1,
            "`#available` 應只出現在 WebViewModelFactory；實際: "
                + hits.map { "\($0.file):\($0.line)" }.joined(separator: ", "))
        XCTAssertEqual(hits.first?.file, "ViewModels/WebViewModelProtocol.swift")
    }

    /// Debug／MCP 整層不得再被平台條件編譯切掉（截圖那份 AppKit 分歧留在 WebViewModel）
    func testDebugAndMCPLayerIsNotPlatformGated() throws {
        let root = try commandSourceRoot()
        let gated = codeLines(in: root)
            .filter { $0.file.hasPrefix("Services/Debug/") || $0.file.hasPrefix("Services/MCP/") }
            .filter { $0.text.contains("#if os(") }

        XCTAssertTrue(
            gated.isEmpty,
            "Debug／MCP 層不得平台分歧（iOS 少了 loopback 8765 = 少了所有驗證腳本）；實際: "
                + gated.map { "\($0.file):\($0.line)" }.joined(separator: ", "))
    }

    /// View 的選擇必須來自 VM，`AdaptiveNakiWebView` 不得自己認型別
    func testAdaptiveWebViewDelegatesToViewModel() throws {
        let root = try commandSourceRoot()
        let adaptive = try String(
            contentsOf: root.appendingPathComponent("Views/LegacyWebViewController.swift"),
            encoding: .utf8)

        XCTAssertTrue(
            adaptive.contains("viewModel.makeWebView()"),
            "AdaptiveNakiWebView 應向 VM 要 View")
    }
}
