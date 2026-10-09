//
//  AkagiSanmaBot.swift
//  Naki
//
//  三麻本地引擎：MortalSwift 的 `AkagiSanma`（Akagi v3 三麻 BC 權重，純 Swift）。
//  模仿天鳳人類，強度不是 Mortal 等級；用途是雲端不可用時三麻仍有推薦與自動送出。
//
//  和牌只看形狀、不判役，動作類別由伺服器 oplist 授權（`authorizedKinds`）。
//  pending 不存在或不是本家時授權為空，只剩捨牌與 pass（fail-closed）。
//

import Foundation
import AkagiSanma

@MainActor
final class AkagiSanmaBot: MahjongBot {

    /// `BotReaction.source`；`BotStatus.isSanmaCapableDecision` 以它放行三麻自動打牌
    nonisolated static let source = "local-akagi3p"

    /// 模型隨 app 打包，本地三麻引擎永遠可建（建構失敗另有退路，見 `NativeBotController.createBot`）
    nonisolated static let isBundled = true

    private let engine: SanmaEngine
    private let seat: Int
    private let snapshot: () -> LiqiOperationSnapshot?

    init(playerId: UInt8, snapshot: @escaping () -> LiqiOperationSnapshot?,
         engine: SanmaEngine? = nil) throws {
        seat = Int(playerId)
        self.snapshot = snapshot
        self.engine = try engine ?? SanmaEngine(seat: Int(playerId))
    }

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    var identity: BotIdentity {
        BotIdentity(name: "akagi-sanma-bc",
                    displayName: "Akagi 三麻（default strength：模仿天鳳人類，非 Mortal 等級）",
                    supports3P: true,
                    isLocal: true)
    }

    func reset() { engine.reset() }

    /// oplist 型別 → 引擎動作類別。chi（三麻沒有）與 none 不授權任何類別。
    nonisolated static func authorizedKinds(_ snapshot: LiqiOperationSnapshot?,
                                            seat: Int) -> Set<SanmaAction.Kind> {
        guard let snapshot, snapshot.seat == seat else { return [] }
        return Set(snapshot.operations.compactMap { op -> SanmaAction.Kind? in
            guard let type = op.type else { return nil }
            return switch type {
            case .discard: .discard
            case .riichi: .riichi
            case .pon: .pon
            case .ankan: .ankan
            case .minkan: .daiminkan
            case .kakan: .kakan
            case .tsumo: .tsumo
            case .ron: .ron
            case .kyushu: .kyushu
            case .babei: .kita
            case .chi, .none: nil
            }
        })
    }

    func react(events: [[String: Any]]) async throws -> BotReaction? {
        for event in events { engine.feed(event) }
        guard let last = events.last else { return nil }
        // 自家槓之後要等嶺上牌：此刻的捨牌建議沒看過新牌，不能當決策（槓事件沒有 oplist seq，擋不住）
        let type = last["type"] as? String
        let isMine = last["actor"] as? Int == seat
        if isMine, ["ankan", "kakan", "daiminkan"].contains(type) { return nil }
        guard let decision = engine.decide(authorized: Self.authorizedKinds(snapshot(), seat: seat))
        else { return nil }

        // 自家碰完 mjai 不再送事件，但需要新的捨牌建議（同 BundledCoreMLBot）
        let isMyPon = type == "pon" && isMine
        return BotReaction(action: isMyPon ? nil : mjai(decision.action),
                           recommendations: recommendations(decision),
                           source: Self.source,
                           forced: decision.forced)
    }

    // MARK: - 轉換

    nonisolated static func mjai(tile tid: UInt8) -> String {
        switch tid {
        case 16: return "5mr"
        case 52: return "5pr"
        case 88: return "5sr"
        default:
            let t = Int(tid / 4)
            if t >= 27 { return ["E", "S", "W", "N", "P", "F", "C"][t - 27] }
            return "\(t % 9 + 1)\(["m", "p", "s"][t / 9])"
        }
    }

    private func mjai(_ a: SanmaAction) -> [String: Any] {
        var e: [String: Any] = ["actor": seat]
        if let t = a.tile { e["pai"] = Self.mjai(tile: t) }
        if !a.consumed.isEmpty { e["consumed"] = a.consumed.map(Self.mjai(tile:)) }
        let lastDiscarder = engine.state.lastDiscard?.seat
        switch a.kind {
        case .discard:
            e["type"] = "dahai"
            e["tsumogiri"] = a.tile == engine.state.drawnTile
        case .riichi: e["type"] = "reach"
        case .pon, .daiminkan:
            e["type"] = a.kind == .pon ? "pon" : "daiminkan"
            e["target"] = lastDiscarder
        case .ankan: e["type"] = "ankan"
        case .kakan: e["type"] = "kakan"
        case .ron:
            e["type"] = "hora"
            e["target"] = lastDiscarder
        case .tsumo:
            e["type"] = "hora"
            e["target"] = seat
        case .kyushu: e["type"] = "ryukyoku"
        case .kita:
            e["type"] = "nukidora"
            e["pai"] = "N"
        case .pass, .chi: e["type"] = "none"
        }
        return e
    }

    private func recommendations(_ decision: SanmaDecision) -> [Recommendation] {
        var rows: [Recommendation] = []
        var seen = Set<String>()
        func add(_ row: Recommendation) { if seen.insert(row.id).inserted { rows.append(row) } }

        for (index, (action, prob)) in decision.candidates.enumerated() {
            let p = Double(prob)
            let detail = action.consumed.isEmpty
                ? nil : action.consumed.map(Self.mjai(tile:)).joined(separator: "·")
            switch action.kind {
            case .discard:
                action.tile.map { add(Recommendation(tile: Self.mjai(tile: $0), probability: p, actionType: .discard)) }
            case .riichi:
                add(Recommendation(tile: "reach", probability: p, actionType: .riichi))
                // 立直宣言牌：executor 取清單順序第一個 discard 列（同 CloudDecisionMapper）
                if index == 0, let t = action.tile {
                    add(Recommendation(tile: Self.mjai(tile: t), probability: p, actionType: .discard))
                }
            case .pon: add(Recommendation(tile: "pon", probability: p, actionType: .pon, detail: detail))
            case .daiminkan, .ankan, .kakan:
                let kind: LiqiOperationType = switch action.kind {
                case .ankan: .ankan
                case .kakan: .kakan
                default: .minkan
                }
                add(Recommendation(tile: "kan", probability: p, actionType: .kan, detail: detail, kanKind: kind))
            case .ron, .tsumo: add(Recommendation(tile: "hora", probability: p, actionType: .hora))
            case .kyushu: add(Recommendation(tile: "ryukyoku", probability: p, actionType: .ryukyoku))
            case .kita: add(Recommendation(tile: "kita", probability: p, actionType: .kita))
            case .pass: add(Recommendation(tile: "none", probability: p, actionType: .none))
            case .chi: break
            }
        }
        return rows
    }
}
