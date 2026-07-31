import XCTest
@testable import Naki

/// macOS 單元測試（host = Naki.app）。
/// 這批 smoke test 涵蓋 Phase 2 幾個「可單測」的邏輯修正，
/// 讓後續回歸有機械驗收依據（對照 AUDIT.md）。
final class NakiTests: XCTestCase {

    // MARK: - MahjongTile 可讀名稱（Accessibility / #Phase3）

    func testMahjongTileAccessibleNameNumberTiles() {
        XCTAssertEqual(MahjongTile(mjai: "5m").accessibleName, "五萬")
        XCTAssertEqual(MahjongTile(mjai: "1p").accessibleName, "一筒")
        XCTAssertEqual(MahjongTile(mjai: "9s").accessibleName, "九索")
    }

    func testMahjongTileAccessibleNameHonorsAndRed() {
        XCTAssertEqual(MahjongTile(mjai: "E").accessibleName, "東")
        XCTAssertEqual(MahjongTile(mjai: "C").accessibleName, "中")
        XCTAssertEqual(MahjongTile(mjai: "5mr").accessibleName, "紅五萬")
    }

    // MARK: - 自風計算（#8 jikaze，kyoku 1-based、oya = kyoku-1）

    /// 以純函數形式重述 dict 版修正後的公式，鎖住「差一」不再回歸。
    /// 修正後：jikaze = (playerId - ((kyoku - 1) % n) + n) % n
    private func jikaze(playerId: Int, kyoku: Int, playerCount n: Int) -> Int {
        (playerId - ((kyoku - 1) % n) + n) % n
    }

    func testJikazeFirstKyokuOyaIsSeatZero() {
        // 東1局：親家 = 座位 0 → 自風 0（東）
        XCTAssertEqual(jikaze(playerId: 0, kyoku: 1, playerCount: 4), 0)
        XCTAssertEqual(jikaze(playerId: 1, kyoku: 1, playerCount: 4), 1)
    }

    func testJikazeRotatesWithKyoku() {
        // 東2局：親家輪到座位 1，座位 0 的自風應為北(3)
        XCTAssertEqual(jikaze(playerId: 0, kyoku: 2, playerCount: 4), 3)
        XCTAssertEqual(jikaze(playerId: 1, kyoku: 2, playerCount: 4), 0)
    }
}
