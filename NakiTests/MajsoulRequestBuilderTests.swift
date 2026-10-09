//
//  MajsoulRequestBuilderTests.swift
//  NakiTests
//
//  自訂雀魂請求 header／User-Agent：純函式規則、設定持久化，
//  以及兩個 backend 真的把 header 與 UA 送到 loopback 伺服器。
//

import Network
import WebKit
import XCTest

@testable import Naki

final class MajsoulRequestBuilderTests: XCTestCase {

    private let url = URL(string: "https://example.test/1/")!

    private func headers(_ extra: [String: String]) -> [String: String] {
        MajsoulRequestBuilder.request(url: url, extraHeaders: extra).allHTTPHeaderFields ?? [:]
    }

    func testValidHeadersAreSet() {
        let request = MajsoulRequestBuilder.request(
            url: url, extraHeaders: ["X-Naki-Test": "abc", "accept-language": "ja"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Naki-Test"), "abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "ja")
    }

    func testNoHeadersLeavesRequestUntouched() {
        let request = MajsoulRequestBuilder.request(url: url, extraHeaders: [:])
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.allHTTPHeaderFields ?? [:], [:])
    }

    func testInvalidNamesAreRejected() {
        for name in ["", "a b", "a:b", "a\nb", "a\r", " X", "X-測試", "(x)"] {
            XCTAssertEqual(MajsoulRequestBuilder.issue(name: name, value: "v"), .invalidName, name)
            XCTAssertEqual(headers([name: "v"]), [:], name)
        }
    }

    func testTokenPunctuationIsAccepted() {
        for name in ["X-A", "a.b", "a_b", "a!b", "a#b", "a$b", "a%b", "a&b", "a'b", "a*b", "a+b", "a^b", "a`b", "a|b", "a~b", "A1"] {
            XCTAssertNil(MajsoulRequestBuilder.issue(name: name, value: "v"), name)
        }
    }

    func testReservedNamesAreRejectedCaseInsensitively() {
        for name in MajsoulRequestBuilder.reservedNames {
            XCTAssertEqual(MajsoulRequestBuilder.issue(name: name, value: "v"), .reservedName, name)
            XCTAssertEqual(MajsoulRequestBuilder.issue(name: name.uppercased(), value: "v"), .reservedName)
        }
        XCTAssertEqual(headers(["Host": "evil", "Cookie": "a=b", "Content-Length": "1", "User-Agent": "u"]), [:])
        for name in ["host", "content-length", "cookie", "user-agent"] {
            XCTAssertTrue(MajsoulRequestBuilder.reservedNames.contains(name))
        }
    }

    func testValuesAreTrimmedAndBadValuesRejected() {
        XCTAssertEqual(headers(["X-A": "  v \t"])["X-A"], "v")
        for value in ["", "   ", "a\nb", "a\r\nInjected: 1"] {
            XCTAssertEqual(MajsoulRequestBuilder.issue(name: "X-A", value: value), .invalidValue, value)
            XCTAssertEqual(headers(["X-A": value]), [:], value)
        }
    }

    func testInvalidEntryDoesNotDropValidOnes() {
        XCTAssertEqual(headers(["X-Ok": "1", "Host": "x", "bad name": "y"]), ["X-Ok": "1"])
    }

    func testCaseVariantDuplicatesKeepOneValue() {
        let fields = headers(["x-a": "1", "X-A": "2"])
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.values.first, "1", "鍵排序在後者為準（小寫排在大寫之後）")
    }

    func testEmptyUserAgentIsNotSet() {
        XCTAssertNil(MajsoulRequestBuilder.userAgent(""))
        XCTAssertNil(MajsoulRequestBuilder.userAgent(" \n "))
        XCTAssertEqual(MajsoulRequestBuilder.userAgent("  Naki/1 "), "Naki/1")
    }
}

@MainActor
final class MajsoulConnectionSettingsTests: XCTestCase {

    func testExtraHeadersRoundTripThroughDefaults() throws {
        let suite = "naki.tests.h1.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(SettingsStore.loadExtraHeaders(from: defaults), [:])
        let headers = ["X-Naki-Test": "abc", "accept-language": "ja"]
        SettingsStore.saveExtraHeaders(headers, to: defaults)
        XCTAssertEqual(SettingsStore.loadExtraHeaders(from: defaults), headers)
    }

    func testSettingsStorePersistsUserAgentAndHeaders() {
        let standard = UserDefaults.standard
        let savedUA = standard.object(forKey: SettingsStore.majsoulUserAgentKey)
        let savedHeaders = standard.object(forKey: SettingsStore.majsoulExtraHeadersKey)
        defer {
            standard.set(savedUA, forKey: SettingsStore.majsoulUserAgentKey)
            standard.set(savedHeaders, forKey: SettingsStore.majsoulExtraHeadersKey)
        }

        let settings = SettingsStore()
        settings.majsoulUserAgent = "Naki-UA/1"
        settings.majsoulExtraHeaders = ["X-A": "1"]

        XCTAssertEqual(standard.string(forKey: SettingsStore.majsoulUserAgentKey), "Naki-UA/1")
        XCTAssertEqual(SettingsStore.loadExtraHeaders(), ["X-A": "1"])
        let reloaded = SettingsStore()
        XCTAssertEqual(reloaded.majsoulUserAgent, "Naki-UA/1")
        XCTAssertEqual(reloaded.majsoulExtraHeaders, ["X-A": "1"])
    }

    func testConnectionSettingsActionForwardsToStubs() async {
        var applied = 0
        let action = ConnectionSettingsAction(stub: { applied += 1 }, defaultUserAgent: { "UA" })
        action.apply()
        let agent = await action.defaultUserAgent()
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(agent, "UA")
        let none = await ConnectionSettingsAction().defaultUserAgent()
        XCTAssertNil(none)
    }
}

/// 只收一個請求、回 200 空頁的 loopback 伺服器；記下收到的原始 header。
private final class CaptureServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var captured: [String] = []

    var requests: [String] { lock.withLock { captured } }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data, let text = String(data: data, encoding: .utf8) {
                    self?.lock.withLock { self?.captured.append(text) }
                }
                let body = "<html><body>ok</body></html>"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func start() async throws -> URL {
        let ready = AsyncStream<Void> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield(); continuation.finish() }
            }
        }
        listener.start(queue: .global())
        for await _ in ready { break }
        let port = try XCTUnwrap(listener.port?.rawValue)
        return try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
    }

    func stop() { listener.cancel() }

    func firstRequest(timeout: Double = 15) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while requests.first == nil && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return requests.first
    }
}

@MainActor
final class MajsoulBackendRequestTests: XCTestCase {

    private let extra = ["X-Naki-Test": "abc"]

    private func assertCaptured(_ raw: String?, userAgent: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let raw else { return XCTFail("伺服器沒收到請求", file: file, line: line) }
        XCTAssertTrue(raw.contains("X-Naki-Test: abc"), raw, file: file, line: line)
        XCTAssertTrue(raw.contains("User-Agent: \(userAgent)"), raw, file: file, line: line)
    }

    func testLegacyBackendSendsHeaderAndUserAgent() async throws {
        let server = try CaptureServer()
        defer { server.stop() }
        let url = try await server.start()

        let backend = LegacyWebBackend(userContentController: WKUserContentController())
        backend.customUserAgent = "NakiLegacy/1"
        backend.load(MajsoulRequestBuilder.request(url: url, extraHeaders: extra))

        assertCaptured(await server.firstRequest(), userAgent: "NakiLegacy/1")
    }

    @available(macOS 26.0, iOS 26.0, *)
    func testWebPageBackendSendsHeaderAndUserAgent() async throws {
        let server = try CaptureServer()
        defer { server.stop() }
        let url = try await server.start()

        let backend = WebPageBackend(userContentController: WKUserContentController())
        backend.customUserAgent = "NakiPage/1"
        backend.load(MajsoulRequestBuilder.request(url: url, extraHeaders: extra))

        assertCaptured(await server.firstRequest(), userAgent: "NakiPage/1")
    }

    func testClearingCustomUserAgentEmptiesIt() {
        let backend = LegacyWebBackend(userContentController: WKUserContentController())
        backend.customUserAgent = "X"
        XCTAssertEqual(backend.customUserAgent, "X")
        backend.customUserAgent = nil
        XCTAssertTrue((backend.customUserAgent ?? "").isEmpty)
    }

    func testDefaultUserAgentProbeReturnsWebKitString() async {
        let store = GameStore()
        let session = WebSession(store: store, settings: SettingsStore(), messageHandler: NoopMessageHandler())
        let agent = await session.defaultUserAgent()
        XCTAssertTrue(agent?.contains("AppleWebKit") == true, agent ?? "nil")
    }
}

private final class NoopMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {}
}
