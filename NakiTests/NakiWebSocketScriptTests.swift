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

  // MARK: - sendRaw（p2-1：兩個 view model 共用同一份腳本與解析）

  /// 同樣是函式體語意，缺 `return` 送出結果會恆為 nil → 全部變成 unparsable。
  func testSendRawScriptStartsWithReturnAndEmbedsPayload() {
    let script = NakiWebSocketScript.sendRaw(base64: "AAEC")

    XCTAssertTrue(script.hasPrefix("return "), "缺 return 會讓送出結果恆為 nil")
    XCTAssertTrue(script.contains("window.__nakiWebSocket.sendRaw('AAEC')"),
                  "base64 只含 A-Za-z0-9+/=，直接放進單引號字串")
    XCTAssertTrue(script.contains("JSON.stringify"), "物件要 stringify 才過得了橋")
  }

  /// 成功：detail 要保留 socketId 與 bytes（事後對照送出去幾個位元組的唯一線索）
  @MainActor
  func testSendResultSuccessKeepsSocketAndBytes() {
    let result = NakiWebSocketScript.sendResult(
      from: #"{"success":true,"bytes":26,"socketId":1}"#)

    XCTAssertTrue(result.success)
    XCTAssertEqual(result.detail, "socket=1 bytes=26")
  }

  /// JS 端拒絕（沒有 OPEN 的雀魂連線等）：reason 必須原樣保留
  @MainActor
  func testSendResultFailureKeepsReason() {
    let result = NakiWebSocketScript.sendResult(
      from: #"{"success":false,"reason":"no_open_majsoul_connection"}"#)

    XCTAssertFalse(result.success)
    XCTAssertEqual(result.detail, "no_open_majsoul_connection")
  }

  /// 失敗但沒給 reason：不可以變成空字串，否則 log 上看不出發生過什麼
  @MainActor
  func testSendResultFailureWithoutReasonHasFallback() {
    let result = NakiWebSocketScript.sendResult(from: #"{"success":false}"#)

    XCTAssertFalse(result.success)
    XCTAssertEqual(result.detail, "unknown_reason")
  }

  /// nil（腳本沒 return）、非字串、非 JSON 一律是 unparsable——**不可以當成成功**
  @MainActor
  func testSendResultUnparsableIsNeverSuccess() {
    for input: Any? in [nil, 42, "not json", #"["array"]"#] {
      let result = NakiWebSocketScript.sendResult(from: input)
      XCTAssertFalse(result.success, "無法解析的回傳值不可以被當成送出成功")
      XCTAssertEqual(result.detail, "unparsable_js_result")
    }
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
