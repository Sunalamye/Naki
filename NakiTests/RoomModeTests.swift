//
//  RoomModeTests.swift
//  NakiTests
//
//  友人房 mode 與人數對齊：三人房送 mode=2 會被伺服器開成四人房（2026-10-09 live 證實）。
//

import XCTest
import MCPKit

@testable import Naki

final class RoomModeTests: XCTestCase {

    private func resolve(_ players: Int, _ mode: Int?) throws -> (mode: Int, adjusted: Bool) {
        try RoomMode.resolve(playerCount: players, requested: mode)
    }

    func testThreePlayerDefaultsToSouth() throws {
        let r = try resolve(3, nil)
        XCTAssertEqual(r.mode, 12)
        XCTAssertFalse(r.adjusted)
    }

    func testThreePlayerMapsFourPlayerModesAndFlagsAdjustment() throws {
        let east = try resolve(3, 1)
        XCTAssertEqual(east.mode, 11)
        XCTAssertTrue(east.adjusted)
        let south = try resolve(3, 2)
        XCTAssertEqual(south.mode, 12)
        XCTAssertTrue(south.adjusted)
    }

    func testThreePlayerKeepsNativeModes() throws {
        let east = try resolve(3, 11)
        XCTAssertEqual(east.mode, 11)
        XCTAssertFalse(east.adjusted)
        let south = try resolve(3, 12)
        XCTAssertEqual(south.mode, 12)
        XCTAssertFalse(south.adjusted)
    }

    func testThreePlayerRejectsOtherModes() {
        XCTAssertThrowsError(try resolve(3, 99))
        XCTAssertThrowsError(try resolve(3, 0))
    }

    func testFourPlayerAcceptsOnlyOneAndTwo() throws {
        let def = try resolve(4, nil)
        XCTAssertEqual(def.mode, 2)
        XCTAssertFalse(def.adjusted)
        let east = try resolve(4, 1)
        XCTAssertEqual(east.mode, 1)
        XCTAssertFalse(east.adjusted)
        let south = try resolve(4, 2)
        XCTAssertEqual(south.mode, 2)
        XCTAssertFalse(south.adjusted)
        XCTAssertThrowsError(try resolve(4, 11))
        XCTAssertThrowsError(try resolve(4, 12))
        XCTAssertThrowsError(try resolve(4, 3))
    }

    func testThreePlayerConfigUsesSanmaDefaults() {
        let c = LiqiFriendRoomConfig(playerCount: 3)
        XCTAssertEqual(c.playerCount, 3)
        XCTAssertEqual(c.doraCount, 2)
        XCTAssertEqual(c.initPoint, 35000)
        XCTAssertEqual(c.fandian, 40000)
    }

    func testThreePlayerExplicitArgumentsOverrideSanmaDefaults() throws {
        let c = LiqiFriendRoomConfig(playerCount: 3)
        let args: [String: Any] = ["dora_count": 3, "init_point": 25000, "fandian": 30000]
        XCTAssertEqual(try MCPArguments.uint32(args, "dora_count", default: Int(c.doraCount)), 3)
        XCTAssertEqual(try MCPArguments.uint32(args, "init_point", default: Int(c.initPoint)), 25000)
        XCTAssertEqual(try MCPArguments.uint32(args, "fandian", default: Int(c.fandian)), 30000)
        XCTAssertEqual(try MCPArguments.uint32([:], "init_point", default: Int(c.initPoint)), 35000)
    }

    func testFourPlayerConfigKeepsFourPlayerDefaults() {
        let c = LiqiFriendRoomConfig(playerCount: 4)
        XCTAssertEqual(c.doraCount, 3)
        XCTAssertEqual(c.initPoint, 25000)
        XCTAssertEqual(c.fandian, 30000)
        XCTAssertEqual(LiqiFriendRoomConfig().initPoint, 25000)
    }
}
