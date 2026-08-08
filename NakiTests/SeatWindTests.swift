import XCTest
@testable import Naki

/// 座位 → 自風的對照。
///
/// 這條邏輯錯過一次：原本直接把點數陣列的 index 當風位，結果只有東 1 局是對的。
/// 東 1 局同時也是所有 `#Preview` 與 `GameState()` 的預設值，所以那個錯誤在
/// 開發期完全看不出來——要打到東 2 局才會顯形（2026-08-09 人機場實測抓到：
/// 摘要條說「南家」，點數列把同一個人標成「西」）。
final class SeatWindTests: XCTestCase {

    /// 東 1 局莊家是座位 0：這是唯一「座位＝風位」成立的一局，
    /// 也正是舊寫法能矇混過去的原因。
    func testEast1SeatEqualsWind() {
        XCTAssertEqual(SeatWind.name(seat: 0, kyoku: 1, is3P: false), "東")
        XCTAssertEqual(SeatWind.name(seat: 1, kyoku: 1, is3P: false), "南")
        XCTAssertEqual(SeatWind.name(seat: 2, kyoku: 1, is3P: false), "西")
        XCTAssertEqual(SeatWind.name(seat: 3, kyoku: 1, is3P: false), "北")
    }

    /// 東 2 局莊家移到座位 1，每個座位的風往前挪一位。
    /// 實測畫面就是在這一局自相矛盾的。
    func testEast2ShiftsByOneSeat() {
        XCTAssertEqual(SeatWind.name(seat: 1, kyoku: 2, is3P: false), "東", "莊家")
        XCTAssertEqual(SeatWind.name(seat: 2, kyoku: 2, is3P: false), "南", "實測中的我")
        XCTAssertEqual(SeatWind.name(seat: 3, kyoku: 2, is3P: false), "西")
        XCTAssertEqual(SeatWind.name(seat: 0, kyoku: 2, is3P: false), "北")
    }

    func testEast4WrapsAround() {
        XCTAssertEqual(SeatWind.name(seat: 3, kyoku: 4, is3P: false), "東")
        XCTAssertEqual(SeatWind.name(seat: 0, kyoku: 4, is3P: false), "南")
    }

    /// 南場：`kyoku` 繼續累加，莊家照樣 mod 家數。
    func testSouthRoundKeepsCounting() {
        XCTAssertEqual(SeatWind.name(seat: 0, kyoku: 5, is3P: false), "東", "南1局莊家回到座位 0")
        XCTAssertEqual(SeatWind.name(seat: 1, kyoku: 6, is3P: false), "東")
    }

    /// 三麻只有三家，沒有北——用 4 取模會產出一個不存在的座位。
    func testSanmaHasThreeSeatsAndNoNorth() {
        XCTAssertEqual(SeatWind.name(seat: 0, kyoku: 1, is3P: true), "東")
        XCTAssertEqual(SeatWind.name(seat: 1, kyoku: 1, is3P: true), "南")
        XCTAssertEqual(SeatWind.name(seat: 2, kyoku: 1, is3P: true), "西")
        XCTAssertEqual(SeatWind.name(seat: 3, kyoku: 1, is3P: true), "?", "三麻沒有第四家")
        // 三麻東 2 局：莊家是 (2-1) % 3 = 座位 1，所以座位 1 才是東、座位 2 是南。
        // 用 4 取模的話會算出座位 2 是南、座位 1 是東——四麻恰好同解，三麻才分得出來。
        XCTAssertEqual(SeatWind.name(seat: 1, kyoku: 2, is3P: true), "東", "三麻莊家 mod 3")
        XCTAssertEqual(SeatWind.name(seat: 2, kyoku: 2, is3P: true), "南")
        XCTAssertEqual(SeatWind.name(seat: 0, kyoku: 2, is3P: true), "西",
                       "四麻同座同局是「北」——三麻沒有北，這一格才分得出取模用 3 還是 4")
        XCTAssertEqual(SeatWind.name(seat: 2, kyoku: 3, is3P: true), "東", "三麻東 3 局莊家")
        XCTAssertEqual(SeatWind.name(seat: 0, kyoku: 4, is3P: true), "東", "繞完一輪回到座位 0")
    }

    func testInvalidInputsDoNotGuess() {
        XCTAssertEqual(SeatWind.name(seat: -1, kyoku: 1, is3P: false), "?")
        XCTAssertEqual(SeatWind.name(seat: 4, kyoku: 1, is3P: false), "?")
        XCTAssertEqual(SeatWind.name(seat: 0, kyoku: 0, is3P: false), "?", "尚未開局")
    }
}
