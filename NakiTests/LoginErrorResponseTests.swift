//
//  LoginErrorResponseTests.swift
//  NakiTests
//
//  登入回應 field 1 是巢狀 .lq.Error，code 要解 field 1，不能把首個 tag byte 當 code。
//

import XCTest

@testable import Naki

@MainActor
final class LoginErrorResponseTests: XCTestCase {

    private func parse(_ fields: [LiqiField]) -> [String: Any] {
        let parser = LiqiParser()
        _ = parser.parse(Data(LiqiEncoder.encodeRequest(method: ".lq.Lobby.oauth2Login", fields: [], msgId: 1)))
        let response = Data(LiqiEncoder.encodeEnvelope(type: .response, msgId: 1, method: "",
                                                       payload: LiqiEncoder.encodeFields(fields)))
        return (parser.parse(response)?["data"] as? [String: Any]) ?? [:]
    }

    func testSuccessfulLoginHasNoError() {
        let parsed = parse([.varint(field: 2, value: 123456)])
        XCTAssertNil(parsed["error"])
        XCTAssertEqual(parsed["accountId"] as? Int, 123456)
    }

    func testErrorCodeIsDecodedFromNestedMessage() {
        let parsed = parse([.message(field: 1, fields: [.varint(field: 1, value: 1002)])])
        XCTAssertEqual(parsed["error"] as? Int, 1002)
    }

    func testEmptyErrorMessageIsCodeZero() {
        let parsed = parse([.message(field: 1, fields: [])])
        XCTAssertEqual(parsed["error"] as? Int, 0)
    }

    func testOtherErrorFieldsDoNotAffectCode() {
        let parsed = parse([.message(field: 1, fields: [
            .varint(field: 2, value: 7),
            .string(field: 3, value: "x"),
            .varint(field: 1, value: 1003),
        ])])
        XCTAssertEqual(parsed["error"] as? Int, 1003)
    }

    func testErrorWithoutCodeFieldIsZero() {
        let parsed = parse([.message(field: 1, fields: [.varint(field: 2, value: 9)])])
        XCTAssertEqual(parsed["error"] as? Int, 0)
    }
}
