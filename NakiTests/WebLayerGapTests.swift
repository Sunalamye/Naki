//
//  WebLayerGapTests.swift
//  NakiTests
//
//  WebSession／兩個 backend 的行為邊界：插件注入重建、背景保活迴圈、導覽失敗後的重訂閱、
//  Legacy 對 -999 的處理。用真的 WebPage／WKWebView，導覽目標是 loopback 上沒人聽的 port。
//

import WebKit
import XCTest

@testable import Naki

@MainActor
private final class RecordingSink: WebNavigationSink {
    var starts = 0, failures: [String] = []
    func webDidStartNavigation() { starts += 1 }
    func webDidCommitNavigation() {}
    func webDidFinishNavigation() {}
    func webDidFailNavigation(_ message: String) { failures.append(message) }
}

private final class NoopHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {}
}

@MainActor
final class WebLayerGapTests: XCTestCase {

    private let handler = NoopHandler()

    private func child(_ object: Any, _ label: String) -> Any? {
        Mirror(reflecting: object).children.first { $0.label == label }?.value
    }

    private func isNil(_ value: Any?) -> Bool {
        guard let value else { return true }
        let m = Mirror(reflecting: value)
        return m.displayStyle == .optional && m.children.isEmpty
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    // MARK: - Legacy

    func testLegacyBackendIgnoresCancelledNavigationButReportsOtherFailures() {
        let backend = LegacyWebBackend(userContentController: WKUserContentController())
        let sink = RecordingSink()
        backend.sink = sink

        backend.webView(backend.webView, didFail: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertEqual(sink.failures, [], "-999 是被新導覽取代，不算失敗")

        backend.webView(backend.webView, didFail: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertEqual(sink.failures.count, 1)
    }

    // MARK: - WebPage 導覽事件

    func testWebPageNavigationsKeepReportingAfterAFailure() async throws {
        let backend = WebPageBackend(userContentController: WKUserContentController())
        let sink = RecordingSink()
        backend.sink = sink
        let dead = try XCTUnwrap(URL(string: "http://127.0.0.1:9/"))

        backend.load(URLRequest(url: dead))
        await waitUntil(15) { !sink.failures.isEmpty }
        XCTAssertEqual(sink.failures.count, 1, "第一次導覽失敗要回報")
        XCTAssertGreaterThanOrEqual(sink.starts, 1)

        backend.load(URLRequest(url: dead))
        await waitUntil(15) { sink.failures.count >= 2 }
        XCTAssertGreaterThanOrEqual(sink.failures.count, 2, "失敗之後必須重新訂閱，否則之後的導覽都收不到")
    }

    // MARK: - WebSession

    func testSetPluginInjectionRebuildsOnlyWhenContentChanges() throws {
        let session = WebSession(store: GameStore(), settings: SettingsStore(), messageHandler: handler)
        let controller = try XCTUnwrap(child(session, "controller") as? WKUserContentController)
        let base = controller.userScripts.count

        session.setPluginInjection("window.__a = 1;")
        XCTAssertEqual(controller.userScripts.count, base + 1)
        let plugin = try XCTUnwrap(controller.userScripts.last)
        XCTAssertEqual(plugin.source, "window.__a = 1;")
        XCTAssertTrue(plugin.isForMainFrameOnly, "插件不該跑進第三方 iframe")

        session.setPluginInjection("window.__a = 1;")
        XCTAssertEqual(controller.userScripts.count, base + 1)

        session.setPluginInjection("window.__a = 2;")
        XCTAssertEqual(controller.userScripts.last?.source, "window.__a = 2;")
        XCTAssertEqual(controller.userScripts.count, base + 1, "換內容是取代不是疊加")

        session.setPluginInjection(nil)
        XCTAssertEqual(controller.userScripts.count, base, "沒有插件時只剩 bundled")
        session.setPluginInjection("")
        XCTAssertEqual(controller.userScripts.count, base)
    }

    func testKeepAliveLoopTicksWhileHiddenAndHoldsActivityOnlyWhileEnabled() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: SettingsStore.keepAliveInBackgroundKey)
        defer { defaults.set(saved, forKey: SettingsStore.keepAliveInBackgroundKey) }

        let settings = SettingsStore()
        let session = WebSession(store: GameStore(), settings: settings, messageHandler: handler)
        _ = try await session.callJavaScript(
            "window.__n = 0; window.__nakiKeepAlive = { tick() { window.__n++; return true; }, set(v) {} }; return null;")

        session.setKeepAliveInBackground(true)
        session.setKeepAliveInBackground(true)
        try await Task.sleep(for: .milliseconds(3200))
        let ticks = try await session.callJavaScript("return window.__n") as? Int ?? -1
        XCTAssertTrue((3...5).contains(ticks), "隱藏時每秒 tick（且重複開啟不會多開一條迴圈），實際 \(ticks)")
        XCTAssertFalse(isNil(child(session, "keepAliveActivity")), "隱藏期間要持有 activity")
        XCTAssertFalse(isNil(child(session, "keepAliveTask")))

        session.setKeepAliveInBackground(false)
        XCTAssertTrue(isNil(child(session, "keepAliveActivity")), "關閉後要釋放 activity")
        XCTAssertTrue(isNil(child(session, "keepAliveTask")))
        let frozen = try await session.callJavaScript("return window.__n") as? Int ?? -1
        try await Task.sleep(for: .milliseconds(1500))
        let after = try await session.callJavaScript("return window.__n") as? Int ?? -2
        XCTAssertEqual(frozen, after, "關閉後迴圈要停")
    }
}
