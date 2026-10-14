import XCTest

@testable import Naki

@MainActor
final class GameToolKanValidationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        isolateAutoPlayDefaults()
    }

    nonisolated deinit {}

    private func context(sent: @escaping () -> Void) -> DefaultNakiMCPContext {
        let send = SendActionAction(stub: { _, _ in sent(); return .unavailable("test_spy") })
        return DefaultNakiMCPContext(dependencies: NakiMCPDependencies(
            store: GameStore(), ui: UIState(), settings: SettingsStore(),
            executeJavaScript: .unavailable, captureScreenshot: .unavailable,
            sendAction: send,
            startUnifiedMatch: StartUnifiedMatchAction(send: send),
            cancelUnifiedMatch: CancelUnifiedMatchAction(send: send),
            triggerAutoPlay: .unavailable,
            setAntiIdle: .unavailable,
            gameSnapshot: GameSnapshotAction(store: GameStore(), accountSource: nil),
            forceReconnect: .unavailable))
    }

    func testInvalidExplicitKanArgumentsAreRejectedWithoutSending() async {
        let cases: [[String: Any]] = [
            ["action": "kan", "kanType": "kakan2"],
            ["action": "kan", "tile": "zz"],
            ["action": "kan", "tile": ""],
        ]
        for arguments in cases {
            var sent = 0
            let tool = GameActionTool(context: context { sent += 1 })
            do {
                _ = try await tool.execute(arguments: arguments)
                XCTFail("應該回錯誤: \(arguments)")
            } catch {
                XCTAssertTrue("\(error)".contains("kanType") || "\(error)".contains("tile"), "\(error)")
            }
            XCTAssertEqual(sent, 0, "無效輸入不得送出任何動作: \(arguments)")
        }
    }

    func testOmittedKanArgumentsStillFallBackToDerivedValues() throws {
        let spec = try NakiGameAction.spec(action: "kan", arguments: [:], snapshot: nil)
        XCTAssertFalse(spec.payload.isEmpty)
        let kakan = try NakiGameAction.spec(action: "kan", arguments: ["kanType": "KAKAN", "tile": "5mr"], snapshot: nil)
        XCTAssertEqual(kakan.payload, try NakiGameAction.spec(action: "kan", arguments: ["kanType": "kakan", "tile": "5mr"], snapshot: nil).payload)
        XCTAssertNotEqual(kakan.payload, spec.payload, "KAKAN 應與預設暗槓不同")
    }

    func testJSONNullKanArgumentsAreTreatedAsOmitted() throws {
        let omitted = try NakiGameAction.spec(action: "kan", arguments: [:], snapshot: nil)
        let nulls = try NakiGameAction.spec(action: "kan", arguments: ["kanType": NSNull(), "tile": NSNull()], snapshot: nil)
        XCTAssertEqual(nulls.payload, omitted.payload)
    }
}
