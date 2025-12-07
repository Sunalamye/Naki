//
//  WebViewBridgeTests.swift
//  WebViewBridge
//
//  WebViewBridge 單元測試
//

import XCTest
@testable import WebViewBridge

@available(macOS 26.0, *)
@MainActor
final class WebViewBridgeTests: XCTestCase {

    func testBridgeInitialization() async {
        let bridge = WebViewBridge(handlerName: "testBridge")
        XCTAssertEqual(bridge.handlerName, "testBridge")
        XCTAssertFalse(bridge.isWebSocketConnected)
    }

    func testModuleRegistration() async {
        let bridge = WebViewBridge()

        let module = JavaScriptModule(
            name: "test-module",
            source: "console.log('test');"
        )

        bridge.registerModule(module)

        // 生成注入腳本應該包含模組內容
        let script = bridge.generateInjectionScript()
        XCTAssertTrue(script.contains("test-module"))
        XCTAssertTrue(script.contains("console.log('test');"))
    }

    func testJavaScriptModuleFromBundle() async {
        // 測試從 Bundle 載入（這個測試可能會失敗，因為測試環境沒有實際的 JS 文件）
        let module = JavaScriptModule.fromBundle(named: "nonexistent")
        XCTAssertNil(module)
    }

    func testBridgeReset() async {
        let bridge = WebViewBridge()
        bridge.reset()
        XCTAssertFalse(bridge.isWebSocketConnected)
    }

    func testGenerateInjectionScript() async {
        let bridge = WebViewBridge()

        let module1 = JavaScriptModule(name: "module1", source: "var a = 1;")
        let module2 = JavaScriptModule(name: "module2", source: "var b = 2;")

        bridge.registerModules([module1, module2])

        let script = bridge.generateInjectionScript()

        XCTAssertTrue(script.contains("module1"))
        XCTAssertTrue(script.contains("module2"))
        XCTAssertTrue(script.contains("var a = 1;"))
        XCTAssertTrue(script.contains("var b = 2;"))
    }
}
