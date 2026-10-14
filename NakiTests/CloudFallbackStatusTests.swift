import XCTest

@testable import Naki

final class CloudFallbackStatusTests: XCTestCase {

    func testSingleFallbackWithHealthyBreakerCountsAsFallback() {
        var status = BotStatus()
        status.cloudHost = "cloud.example"
        status.cloudDegraded = false
        status.cloudFallbackStreak = 1
        XCTAssertTrue(status.isCloudFallback)
    }

    func testOpenBreakerCountsAsFallbackBeforeAnyDecision() {
        var status = BotStatus()
        status.cloudHost = "cloud.example"
        status.cloudDegraded = true
        XCTAssertTrue(status.isCloudFallback)
    }

    func testHealthyCloudAndLocalOnlyAreNotFallback() {
        var status = BotStatus()
        status.cloudHost = "cloud.example"
        XCTAssertFalse(status.isCloudFallback)
        status.cloudHost = nil
        status.cloudFallbackStreak = 3
        XCTAssertFalse(status.isCloudFallback, "沒有雲端主機時不顯示雲端失敗")
    }
}
