//
//  LiqiErrorCodeTests.swift
//  NakiTests
//
//  `LiqiResponseRecord.errorCode` 的解碼測試。
//
//  下面的 base64 取自 2026-08-01 的實際伺服器回應。當時每一個都是人工
//  base64 → hex → varint 解出來的，而且在解出來之前，`sendRaw` 回的是
//  `success: true`——完全看不出伺服器拒絕了請求。
//

import XCTest

@testable import Naki

final class LiqiErrorCodeTests: XCTestCase {

    private func record(field1: String?,
                        method: String = ".lq.Lobby.matchGame") -> LiqiResponseRecord {
        var fields: [String: Any] = [:]
        if let field1 { fields["field1"] = field1 }
        return LiqiResponseRecord(msgId: 60001, method: method, fields: fields, receivedAt: Date())
    }

    private func b64(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    /// live 回應：08 ec 07 → 1004、08 9a 0a → 1306
    func testDecodesRealErrorCodes() {
        XCTAssertEqual(record(field1: "COwH").errorCode, 1004)
        XCTAssertEqual(record(field1: "CJoK").errorCode, 1306)
    }

    func testDecodesSingleByteVarint() {
        XCTAssertEqual(record(field1: b64([0x08, 0x01])).errorCode, 1)
    }

    /// 跨越 7-bit 邊界的多位元組 varint
    func testDecodesMultiByteVarint() {
        XCTAssertEqual(record(field1: b64([0x08, 0xff, 0x07])).errorCode, 1023)
        XCTAssertEqual(record(field1: b64([0x08, 0xd1, 0x08])).errorCode, 1105)
    }

    func testNoErrorFieldMeansNoCode() {
        let r = record(field1: nil)
        XCTAssertFalse(r.hasError)
        XCTAssertNil(r.errorCode)
        XCTAssertNil(r.errorDescription)
    }

    /// 壞資料不能當掉，也不能亂猜出一個碼
    func testMalformedDataYieldsNil() {
        XCTAssertNil(record(field1: "").errorCode)
        XCTAssertNil(record(field1: "!!!not-base64!!!").errorCode)
        // 只有 tag 沒有 payload
        XCTAssertNil(record(field1: b64([0x08])).errorCode)
        // field1 不是 varint（length-delimited）
        XCTAssertNil(record(field1: b64([0x0a, 0x02, 0x41, 0x42])).errorCode)
        // varint 永遠不結束
        XCTAssertNil(record(field1: b64(Array(repeating: 0x80, count: 12))).errorCode)
    }

    func testDescribesKnownCode() {
        let desc = record(field1: "COwH").errorDescription
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc!.contains("1004"))
        XCTAssertTrue(desc!.contains("登入"))
    }

    /// 不在表內的碼必須明說未知——編一個語意出來比不解碼更糟
    func testUnknownCodeSaysUnknown() {
        let desc = record(field1: b64([0x08, 0x8f, 0x4e])).errorDescription   // 9999
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc!.contains("9999"))
        XCTAssertTrue(desc!.contains("未收錄"))
    }
}
