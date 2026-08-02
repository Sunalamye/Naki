//
//  NakiWebSocketScriptTests.swift
//  NakiTests
//
//  AUDIT P0-2 的回歸鎖：forceReconnect 腳本必須自帶 `return`。
//
//  `WebPage.callJavaScript` 是函式體語意，沒有 `return` 就恆回 nil，
//  於是 `closedCount` 恆為 0——連線其實關掉了，UI 卻顯示「沒有活躍的連接」。
//  這個 bug 沒有任何編譯期或型別上的訊號，只能靠字串層的斷言鎖住。
//

import XCTest

@testable import Naki

final class NakiWebSocketScriptTests: XCTestCase {

  // MARK: - 腳本本身

  /// 漏 `return` 正是 P0-2 的成因，這條是主鎖。
  func testForceReconnectScriptStartsWithReturn() {
    XCTAssertTrue(
      NakiWebSocketScript.forceReconnect.hasPrefix("return "),
      "callJavaScript 是函式體語意，缺 return 會讓回傳值恆為 nil")
  }

  /// 模組未注入時要收斂成 0，而不是 undefined 或丟例外。
  func testForceReconnectScriptIsNilSafe() {
    let script = NakiWebSocketScript.forceReconnect
    XCTAssertTrue(script.contains("window.__nakiWebSocket?."), "必須用 optional chaining 保護未注入的情況")
    XCTAssertTrue(script.contains("|| 0"), "undefined 要收斂成 0")
  }

  // MARK: - 回傳值解析

  func testClosedCountFromInt() {
    XCTAssertEqual(NakiWebSocketScript.closedCount(from: 2), 2)
    XCTAssertEqual(NakiWebSocketScript.closedCount(from: 0), 0)
  }

  /// JS number 過橋常常是 NSNumber(double)，直接 `as? Int` 在部分路徑上會失敗。
  func testClosedCountFromNSNumber() {
    XCTAssertEqual(NakiWebSocketScript.closedCount(from: NSNumber(value: 3)), 3)
    XCTAssertEqual(NakiWebSocketScript.closedCount(from: NSNumber(value: 3.0)), 3)
  }

  func testClosedCountFromDouble() {
    XCTAssertEqual(NakiWebSocketScript.closedCount(from: 1.0 as Double), 1)
    XCTAssertEqual(NakiWebSocketScript.closedCount(from: Double.nan), 0)
    XCTAssertEqual(NakiWebSocketScript.closedCount(from: Double.infinity), 0)
  }

  func testClosedCountFromString() {
    XCTAssertEqual(NakiWebSocketScript.closedCount(from: "4"), 4)
    XCTAssertEqual(NakiWebSocketScript.closedCount(from: "not a number"), 0)
  }

  /// nil（腳本沒 return、或 JS 丟出 undefined）與非數值一律當作 0。
  func testClosedCountFallsBackToZero() {
    XCTAssertEqual(NakiWebSocketScript.closedCount(from: nil), 0)
    XCTAssertEqual(NakiWebSocketScript.closedCount(from: ["unexpected": true]), 0)
  }
}
