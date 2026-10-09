//
//  DebugUIStateTests.swift
//  NakiTests
//
//  畫面開關互斥邏輯與 `/debug/ui` 的欄位解析（純函式，不起 server）。
//

import XCTest

@testable import Naki

@MainActor
final class UIStateTests: XCTestCase {

    private func open(_ ui: UIState) -> [Bool] {
        [ui.showAdvancedSettings, ui.showPlugins, ui.showLog, ui.showFullAutoKindChoice]
    }

    func testDefaultsMatchOriginalViewState() {
        let ui = UIState()
        XCTAssertTrue(ui.showGamePanel)
        XCTAssertEqual(open(ui), [false, false, false, false])
    }

    func testEachScreenOpensExactlyOne() {
        let expected: [UIState.Screen: [Bool]] = [
            .settings: [true, false, false, false],
            .plugins: [false, true, false, false],
            .log: [false, false, true, false],
            .fullauto: [false, false, false, true],
            .none: [false, false, false, false],
        ]
        XCTAssertEqual(Set(expected.keys), Set(UIState.Screen.allCases))
        for (screen, flags) in expected {
            let ui = UIState()
            ui.showLog = true
            ui.showPlugins = true
            ui.apply(screen: screen)
            XCTAssertEqual(open(ui), flags, "\(screen)")
        }
    }

    func testApplyNeverTouchesGamePanel() {
        let ui = UIState()
        ui.showGamePanel = false
        for screen in UIState.Screen.allCases {
            ui.apply(screen: screen)
            XCTAssertFalse(ui.showGamePanel, "\(screen)")
        }
    }
}

#if DEBUG
@MainActor
final class DebugUIRequestTests: XCTestCase {

    func testEmptyBodyChangesNothing() throws {
        let parsed = try DebugServer.parseUIRequest([:]).get()
        XCTAssertNil(parsed.screen)
        XCTAssertNil(parsed.language)
    }

    func testEveryKnownValueParses() throws {
        for screen in UIState.Screen.allCases {
            XCTAssertEqual(try DebugServer.parseUIRequest(["screen": screen.rawValue]).get().screen, screen)
        }
        for language in AppLanguage.allCases {
            XCTAssertEqual(try DebugServer.parseUIRequest(["language": language.rawValue]).get().language, language)
        }
    }

    func testUnknownScreenListsAvailableValues() {
        guard case .failure(let error) = DebugServer.parseUIRequest(["screen": "bogus"]) else {
            return XCTFail("未知 screen 應失敗")
        }
        XCTAssertTrue(error.message.contains("screen"))
        for screen in UIState.Screen.allCases { XCTAssertTrue(error.message.contains(screen.rawValue)) }
    }

    func testUnknownLanguageListsAvailableValues() {
        guard case .failure(let error) = DebugServer.parseUIRequest(["language": "fr"]) else {
            return XCTFail("未知 language 應失敗")
        }
        XCTAssertTrue(error.message.contains("language"))
        for language in AppLanguage.allCases { XCTAssertTrue(error.message.contains(language.rawValue)) }
    }

    func testNonStringValueIsRejected() {
        if case .success = DebugServer.parseUIRequest(["screen": 1]) { XCTFail("非字串 screen 應失敗") }
        if case .success = DebugServer.parseUIRequest(["language": true]) { XCTFail("非字串 language 應失敗") }
    }

    func testStatusPayloadReportsFlagsAndLanguage() {
        let ui = UIState()
        ui.apply(screen: .log)
        ui.showGamePanel = false
        let payload = DebugServer.uiStatusPayload(ui: ui, language: .zhHant)
        XCTAssertEqual(payload["showLog"] as? Bool, true)
        XCTAssertEqual(payload["showAdvancedSettings"] as? Bool, false)
        XCTAssertEqual(payload["showPlugins"] as? Bool, false)
        XCTAssertEqual(payload["showFullAutoKindChoice"] as? Bool, false)
        XCTAssertEqual(payload["showGamePanel"] as? Bool, false)
        XCTAssertEqual(payload["language"] as? String, "zh-Hant")
    }
}
#endif
