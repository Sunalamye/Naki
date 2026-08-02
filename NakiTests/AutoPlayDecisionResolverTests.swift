//
//  AutoPlayDecisionResolverTests.swift
//  NakiTests
//
//  P0「server-authoritative 自摸保護」的回歸測試。
//
//  這些案例全部來自一次真實漏和：實測某手 oplist = [discard, riichi, tsumo]，
//  Mortal 回傳 dahai，送出端忠實把和牌牌打掉了。
//  合法性的權威在伺服器不在模型——只要伺服器說可以自摸，就必須自摸。
//

import XCTest

@testable import Naki

final class AutoPlayDecisionResolverTests: XCTestCase {

  // MARK: - 測試輔助

  private func snapshot(
    types: [LiqiOperationType],
    seat: Int = 0,
    sequence: UInt64 = 1,
    source: String = "ActionDealTile",
    contextTile: String? = "9s"
  ) -> LiqiOperationSnapshot {
    LiqiOperationSnapshot(
      sequence: sequence,
      seat: seat,
      operations: types.map { LiqiOperation(rawType: $0.rawValue) },
      timeAdd: 0,
      timeFixed: 300_000,
      contextTile: contextTile,
      source: source,
      capturedAt: Date())
  }

  private func rec(_ action: Recommendation.ActionType, _ tile: String, _ p: Double = 0.9)
    -> Recommendation
  {
    // 用既有的 MJAI 字串 initializer；displayTile = tile?.mjaiString ?? label
    Recommendation(tile: tile.isEmpty ? action.rawValue : tile,
                   probability: p,
                   actionType: action)
  }

  // MARK: - 終局保護

  /// 本次漏和的直接重播：ops=[1,7,8]、AI top=discard，auto 模式必須送自摸
  func testTsumoOverridesDiscardRecommendationInAutoMode() {
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: snapshot(types: [.discard, .riichi, .tsumo]),
      recommendations: [rec(.discard, "9s"), rec(.riichi, "9s")],
      mode: .auto,
      seat: 0)

    XCTAssertEqual(decision, .send(action: .hora, tile: "9s"),
                   "伺服器提供自摸時必須覆蓋 AI 的打牌推薦")
  }

  /// 推薦模式：顯示自摸，但絕不自動送出
  func testTsumoIsSurfacedButNotSentInRecommendMode() {
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: snapshot(types: [.discard, .riichi, .tsumo]),
      recommendations: [rec(.discard, "9s")],
      mode: .recommend,
      seat: 0)

    guard case .surfaceOnly(let action, _) = decision else {
      return XCTFail("推薦模式應為 surfaceOnly，實際: \(decision)")
    }
    XCTAssertEqual(action, .hora)
  }

  /// 關閉模式：不得產生任何送出
  func testNothingIsSentInOffMode() {
    for types in [[LiqiOperationType.discard, .riichi, .tsumo], [.discard], [.chi, .pon]] {
      let decision = AutoPlayDecisionResolver.resolve(
        snapshot: snapshot(types: types),
        recommendations: [rec(.discard, "9s")],
        mode: .off,
        seat: 0)

      if case .send = decision {
        XCTFail("關閉模式不得送出任何動作，ops=\(types)")
      }
    }
  }

  /// 榮和同樣受保護（自摸優先，但只有榮和時也要和）
  func testRonIsAlsoProtected() {
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: snapshot(types: [.chi, .pon, .ron]),
      recommendations: [rec(.none, "")],
      mode: .auto,
      seat: 0)

    XCTAssertEqual(decision, .send(action: .hora, tile: "9s"))
  }

  // MARK: - Fail closed

  /// 沒有 oplist 就什麼都不做——不得「預設當自摸送出」
  /// 模型完全沒有推薦時，伺服器提供的和牌仍然必須被送出。
  ///
  /// 這是實際踩到的整合缺口：Mortal 判斷不出和牌時 `react` 回 nil，
  /// 呼叫端看到推薦是空的就直接 return，resolver 根本沒被呼叫——
  /// 而 resolver 本身其實是對的（和牌檢查在推薦檢查之前）。
  /// 這個測試鎖住 resolver 那一半；呼叫端那一半由 WebViewModel 的
  /// `snapshot.horaOperation != nil` 分支負責。
  func testHoraIsSentEvenWithNoRecommendations() {
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: snapshot(types: [.discard, .riichi, .tsumo]),
      recommendations: [],
      mode: .auto,
      seat: 0)
    XCTAssertEqual(decision, .send(action: .hora, tile: "9s"),
                   "模型沒意見不代表可以放掉伺服器給的自摸")
  }

  /// 榮和被歸類為 isCallOpportunity，所以「無推薦 → 送過」那條路徑
  /// 會把和牌當成副露機會直接棄掉。resolver 這一層必須擋住。
  func testRonIsNotTurnedIntoPassWhenNoRecommendations() {
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: snapshot(types: [.chi, .pon, .ron]),
      recommendations: [],
      mode: .auto,
      seat: 0)
    XCTAssertEqual(decision, .send(action: .hora, tile: "9s"),
                   "有榮和機會時絕不能送出「過」")
  }

  func testNoOplistFailsClosed() {
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: nil,
      recommendations: [rec(.hora, "9s")],
      mode: .auto,
      seat: 0)

    XCTAssertEqual(decision, .none(reason: "no_oplist"))
  }

  /// oplist 不是給我們的座位就不動作
  func testSeatMismatchIsRejected() {
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: snapshot(types: [.discard, .tsumo], seat: 2),
      recommendations: [rec(.discard, "9s")],
      mode: .auto,
      seat: 0)

    if case .none = decision {} else {
      XCTFail("座位不符時不得送出，實際: \(decision)")
    }
  }

  /// AI 推薦的動作不在 oplist 裡 → 那是拿舊推薦操作新 oplist，必須擋掉
  func testRecommendationNotInOplistIsRejected() {
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: snapshot(types: [.chi, .pon]),   // 沒有 discard
      recommendations: [rec(.discard, "9s")],
      mode: .auto,
      seat: 0)

    if case .none = decision {} else {
      XCTFail("動作不在 oplist 內不得送出，實際: \(decision)")
    }
  }

  // MARK: - 快照過期

  /// 序號被換掉後，先前的決策不得再送出
  func testStaleSnapshotIsRejectedBySequence() {
    let decided = snapshot(types: [.discard, .tsumo], sequence: 10)
    let current = snapshot(types: [.discard], sequence: 11)

    XCTAssertFalse(
      AutoPlayDecisionResolver.isStillValid(decidedOn: decided, current: current),
      "sequence 變了代表對局已往前走，舊決策必須作廢")
  }

  /// 觸發牌換了也算過期（同序號但不同來源牌的防禦）
  func testStaleSnapshotIsRejectedByContextTile() {
    let decided = snapshot(types: [.pon], sequence: 10, contextTile: "1m")
    let current = snapshot(types: [.pon], sequence: 10, contextTile: "5p")

    XCTAssertFalse(AutoPlayDecisionResolver.isStillValid(decidedOn: decided, current: current))
  }

  /// oplist 整批消失（已被處理）也不得送出
  func testNilCurrentSnapshotIsRejected() {
    let decided = snapshot(types: [.discard], sequence: 10)
    XCTAssertFalse(AutoPlayDecisionResolver.isStillValid(decidedOn: decided, current: nil))
  }

  /// 同一批 oplist 才算有效
  func testIdenticalSnapshotIsValid() {
    let s = snapshot(types: [.discard, .tsumo], sequence: 10)
    XCTAssertTrue(AutoPlayDecisionResolver.isStillValid(decidedOn: s, current: s))
  }

  // MARK: - 副露機會無推薦

  /// Mortal 不表態時要送「過」，否則對局會停在那裡等我們回應
  func testCallOpportunityWithoutRecommendationPassesInAutoMode() {
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: snapshot(types: [.chi]),
      recommendations: [],
      mode: .auto,
      seat: 0)

    XCTAssertEqual(decision, .send(action: .none, tile: ""))
  }

  /// 非自動模式下，無推薦的副露機會不得自行送出
  func testCallOpportunityWithoutRecommendationDoesNotSendWhenNotAuto() {
    for mode in [AutoPlayMode.recommend, .off] {
      let decision = AutoPlayDecisionResolver.resolve(
        snapshot: snapshot(types: [.chi]),
        recommendations: [],
        mode: mode,
        seat: 0)

      if case .send = decision {
        XCTFail("\(mode.rawValue) 模式不得自動送出過")
      }
    }
  }

  // MARK: - 三麻 fail-closed（MortalSwift p3-1「不做」路線的驗收）

  /// 三麻對局：自動模式降級成「只顯示、不送出」。
  ///
  /// 內建 Core ML 只有四麻一份（obs 1012×34、action 46）。三麻的牌山、規則與
  /// observation 佈局都不同，拿四麻模型推三麻**結構上無效**——讓它自動送出
  /// 等於用亂數打牌。
  func testSanmaDowngradesAutoToSurfaceOnly() {
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: snapshot(types: [.discard]),
      recommendations: [rec(.discard, "9s")],
      mode: .auto,
      seat: 0,
      isSanma: true)

    XCTAssertEqual(decision, .surfaceOnly(action: .discard, tile: "9s"),
                   "三麻不得自動送出，但仍應讓 UI 看得到推薦")
  }

  /// 三麻連伺服器提供的和牌也不自動送——不自動送出**任何**動作
  func testSanmaDoesNotAutoSendHora() {
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: snapshot(types: [.discard, .riichi, .tsumo]),
      recommendations: [rec(.discard, "9s")],
      mode: .auto,
      seat: 0,
      isSanma: true)

    if case .send = decision {
      XCTFail("三麻不得自動送出和牌，實際: \(decision)")
    }
    XCTAssertEqual(decision, .surfaceOnly(action: .hora, tile: "9s"))
  }

  /// 三麻的副露機會也不會自動送「過」
  func testSanmaDoesNotAutoPass() {
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: snapshot(types: [.chi]),
      recommendations: [],
      mode: .auto,
      seat: 0,
      isSanma: true)

    if case .send = decision {
      XCTFail("三麻不得自動送出過，實際: \(decision)")
    }
  }

  /// 四麻不受影響——確認上面三條不是「把所有人都關掉」的假綠燈
  func testFourPlayerStillAutoSends() {
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: snapshot(types: [.discard]),
      recommendations: [rec(.discard, "9s")],
      mode: .auto,
      seat: 0,
      isSanma: false)

    XCTAssertEqual(decision, .send(action: .discard, tile: "9s"))
  }
}
