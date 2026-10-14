import XCTest
import SwiftUI
import MortalSwift
@testable import Naki

/// `DecisionAlerts` 底部間距：有警示列時 compact 比一般少 2pt，沒有警示列時整個視圖為空（沒有影像）。
/// 快照容差吞得掉 2pt，所以直接量渲染高度。
@MainActor
final class DecisionAlertsPaddingTests: XCTestCase {

    private func image(_ status: BotStatus, compact: Bool) -> NSImage? {
        let renderer = ImageRenderer(content: DecisionAlerts(botStatus: status, autoPlayStall: nil, compact: compact)
            .frame(width: 348))
        renderer.scale = 1
        return renderer.nsImage
    }

    private func height(_ status: BotStatus, compact: Bool) throws -> CGFloat {
        try XCTUnwrap(image(status, compact: compact)).size.height
    }

    func testCompactPaddingIsSmallerThanRegularWhenAlertShown() throws {
        var status = BotStatus()
        status.is3P = true
        let regular = try height(status, compact: false)
        let compact = try height(status, compact: true)
        XCTAssertEqual(regular - compact, PanelLayout.Spacing.s10 - PanelLayout.Spacing.s8, accuracy: 0.5)
    }

    func testNoPaddingWhenNoAlertShown() throws {
        XCTAssertNil(image(BotStatus(), compact: false))
        XCTAssertNil(image(BotStatus(), compact: true))
    }
}
