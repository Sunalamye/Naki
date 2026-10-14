//
//  Naki_MUITestsLaunchTests.swift
//  Naki-MUITests
//
//  Created by Suoie on 2025/12/4.
//

import XCTest

final class Naki_MUITestsLaunchTests: NakiMUITestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    @MainActor
    func testLaunch() throws {
        launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
