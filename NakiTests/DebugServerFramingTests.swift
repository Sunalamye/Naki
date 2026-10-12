//
//  DebugServerFramingTests.swift
//  NakiTests
//
//  DebugServer 的 request 邊界判斷（411）：用 loopback 上真的 server 與原始 socket 驗證。
//  port 固定在 8765 以外的高位區，不碰正在執行的 App。
//

import Darwin
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

/// listener 失敗或被取消後，`store.isDebugServerRunning` 必須歸零；
/// 否則 `NakiRuntime.startDebugServer` 的 guard 會一直回「已在運行」，使用者無法重啟。
@MainActor
final class DebugServerLifecycleTests: XCTestCase {

    /// 以沒有 SO_REUSEADDR 的 IPv6 loopback socket 佔住連續 `count` 個 port，
    /// 讓 `DebugServer` 對這些 port 的 bind 一律 EADDRINUSE。回傳 nil 代表這段區間有 port 已被別人用。
    private func occupyPorts(from base: UInt16, count: Int) -> [Int32]? {
        var fds: [Int32] = []
        for offset in 0..<count {
            let fd = socket(AF_INET6, SOCK_STREAM, 0)
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = (base + UInt16(offset)).bigEndian
            address.sin6_addr = in6addr_loopback
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 && listen(fd, 1) == 0
                }
            }
            fds.append(fd)
            if !bound { fds.forEach { close($0) }; return nil }
        }
        return fds
    }

    func testFailedBindOnEveryRetryResetsRunningFlag() async throws {
        var occupied: (base: UInt16, fds: [Int32])?
        for _ in 0..<20 where occupied == nil {
            let base = UInt16.random(in: 50000...60000)
            if let fds = occupyPorts(from: base, count: 10) { occupied = (base, fds) }
        }
        let held = try XCTUnwrap(occupied, "找不到連續 10 個可佔用的 port")
        defer { held.fds.forEach { close($0) } }

        // 模擬「曾經 ready 後失敗」留下的旗標：fix 前它永遠不會被改回 false
        let store = GameStore()
        store.isDebugServerRunning = true
        let server = DebugServer(port: held.base, dependencies: makeTestDependencies(store: store))
        server.start()
        defer { server.stop() }

        for _ in 0..<100 where store.isDebugServerRunning { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(store.isDebugServerRunning, "10 個 port 全部綁定失敗後旗標仍為 true")
    }

    /// 前幾個 port 被佔、後面成功：舊 listener 遲到的 `.cancelled` 不能把新 listener 的 ready 蓋成 false
    func testRetryAfterFailedBindEndsUpRunningOnNextFreePort() async throws {
        var occupied: (base: UInt16, fds: [Int32])?
        for _ in 0..<20 where occupied == nil {
            let base = UInt16.random(in: 50000...60000)
            if let fds = occupyPorts(from: base, count: 2) { occupied = (base, fds) }
        }
        let held = try XCTUnwrap(occupied, "找不到連續 2 個可佔用的 port")
        defer { held.fds.forEach { close($0) } }

        let store = GameStore()
        let server = DebugServer(port: held.base, dependencies: makeTestDependencies(store: store))
        server.start()
        defer { server.stop() }

        for _ in 0..<100 where !store.isDebugServerRunning { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(store.isDebugServerRunning)
        XCTAssertEqual(store.debugServerPort, held.base + 2)
    }

    func testStopResetsRunningFlagViaCancelledState() async throws {
        let store = GameStore()
        let server = DebugServer(port: UInt16.random(in: 40000...49000), dependencies: makeTestDependencies(store: store))
        server.start()
        for _ in 0..<100 where !store.isDebugServerRunning { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(store.isDebugServerRunning, "server 沒有起來")

        server.stop()

        // `stop()` 不碰 store；歸零來自 listener 的 `.cancelled` 回呼
        for _ in 0..<100 where store.isDebugServerRunning { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(store.isDebugServerRunning)
    }
}
