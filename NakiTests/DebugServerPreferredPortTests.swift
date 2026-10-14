import XCTest

@testable import Naki

@MainActor
final class DebugServerPreferredPortTests: XCTestCase {

    override func setUp() {
        super.setUp()
        isolateAutoPlayDefaults()
    }

    nonisolated deinit {}

    func testRestartStartsFromPreferredPortNotLastBoundPort() async throws {
        let runtime = NakiRuntime()
        let preferred = try freePort()
        runtime.store.debugServerPreferredPort = preferred
        runtime.store.debugServerPort = preferred + 1000

        runtime.startDebugServer()
        defer { runtime.stopDebugServer() }

        for _ in 0..<50 where !runtime.store.isDebugServerRunning {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(runtime.store.isDebugServerRunning)
        XCTAssertEqual(runtime.store.debugServerPort, preferred, "重啟應從偏好 port 開始，不是上次綁到的 port")
    }

    /// 取暫時區之外的隨機 port 並實際 bind 驗證空閒，避免與系統暫時 port 撞上而假紅。
    private func freePort() throws -> UInt16 {
        for _ in 0..<50 {
            let port = UInt16.random(in: 20000...29999)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if bound == 0 { return port }
        }
        throw XCTSkip("找不到空閒 port")
    }

    func testDefaultsToStandardPort() {
        let store = GameStore()
        XCTAssertEqual(store.debugServerPreferredPort, 8765)
        XCTAssertEqual(store.debugServerPort, 8765)
    }
}
