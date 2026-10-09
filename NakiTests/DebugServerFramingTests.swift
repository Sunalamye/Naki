//
//  DebugServerFramingTests.swift
//  NakiTests
//
//  DebugServer 的 request 邊界判斷（411）：用 loopback 上真的 server 與原始 socket 驗證。
//  port 固定在 8765 以外的高位區，不碰正在執行的 App。
//

import Network
import XCTest

@testable import Naki

@MainActor
final class DebugServerFramingTests: XCTestCase {

    private var server: DebugServer?
    private var store = GameStore()
    private var port: UInt16 = 0

    override func setUp() async throws {
        store = GameStore()
        let deps = makeTestDependencies(store: store)
        let server = DebugServer(port: UInt16.random(in: 40000...49000), dependencies: deps)
        server.start()
        self.server = server
        for _ in 0..<100 where !store.isDebugServerRunning { try await Task.sleep(for: .milliseconds(50)) }
        try XCTUnwrap(store.isDebugServerRunning ? true : nil, "server 沒有起來")
        port = store.debugServerPort
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
    }

    /// 送原始 bytes，回第一行狀態列。
    private func statusLine(_ raw: String) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            func finish(_ r: Result<String, Error>) { if !resumed { resumed = true; cont.resume(with: r) } }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data(raw.utf8), completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                        if let data, let text = String(data: data, encoding: .utf8) {
                            finish(.success(String(text.prefix(while: { $0 != "\r" }))))
                        } else { finish(.failure(error ?? URLError(.badServerResponse))) }
                    }
                case .failed(let e): finish(.failure(e))
                default: break
                }
            }
            connection.start(queue: .main)
        }
    }

    private func request(_ method: String, _ path: String, headers: [String] = [], body: String = "") -> String {
        (["\(method) \(path) HTTP/1.1", "Host: 127.0.0.1:\(port)"] + headers + ["", body]).joined(separator: "\r\n")
    }

    func testPlainGetIsServed() async throws {
        let line = try await statusLine(request("GET", "/"))
        XCTAssertTrue(line.contains(" 200 "), line)
    }

    func testChunkedRequestIsRejectedEvenWithContentLength() async throws {
        let line = try await statusLine(request("POST", "/", headers: ["Transfer-Encoding: chunked", "Content-Length: 0"]))
        XCTAssertTrue(line.contains(" 411 "), line)
    }

    func testBodyWithoutContentLengthIsRejected() async throws {
        let line = try await statusLine(request("POST", "/", body: "return 1"))
        XCTAssertTrue(line.contains(" 411 "), line)
    }

    func testBodylessPostPassesFraming() async throws {
        let line = try await statusLine(request("POST", "/bot/trigger"))
        XCTAssertFalse(line.contains(" 411 "), line)
    }

    func testBodyWithContentLengthPassesFraming() async throws {
        let line = try await statusLine(request("POST", "/", headers: ["Content-Length: 8"], body: "return 1"))
        XCTAssertFalse(line.contains(" 411 "), line)
    }
    #if DEBUG
    func testDebugUIRejectsUnknownScreenWith400() async throws {
        let body = #"{"screen":"bogus"}"#
        let line = try await statusLine(request("POST", "/debug/ui", headers: ["Content-Length: \(body.utf8.count)"], body: body))
        XCTAssertTrue(line.contains(" 400 "), line)
    }

    func testDebugUIRejectsUnknownLanguageWith400() async throws {
        let body = #"{"language":"fr"}"#
        let line = try await statusLine(request("POST", "/debug/ui", headers: ["Content-Length: \(body.utf8.count)"], body: body))
        XCTAssertTrue(line.contains(" 400 "), line)
    }

    func testDebugUIGetIsServed() async throws {
        let line = try await statusLine(request("GET", "/debug/ui"))
        XCTAssertTrue(line.contains(" 200 "), line)
    }
    #endif
}
