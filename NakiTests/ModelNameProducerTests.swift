import XCTest
@testable import Naki

/// `BotStatus.modelDisplayKey` 比對的名稱必須與產生端一致；產生端改名這裡就會紅。
@MainActor
final class ModelNameProducerTests: XCTestCase {

    func testBundledFourPlayerName() {
        XCTAssertEqual(NativeBotController().botState.modelName, BotStatus.bundledModelName)
    }

    func testAkagiSanmaIdentityName() throws {
        let controller = NativeBotController()
        try controller.createBot(playerId: 0, is3P: true)
        XCTAssertEqual(controller.botState.modelName, BotStatus.akagiSanmaModelName)
    }

    func testCloudOnlyName() throws {
        struct Boom: Error {}
        let controller = NativeBotController()
        controller.makeSanmaLocal = { _ in throw Boom() }
        controller.cloudConfigProvider = { nil }
        try controller.createBot(playerId: 0, is3P: true)
        XCTAssertEqual(controller.botState.modelName, BotStatus.cloudOnlyModelName)
    }
}
