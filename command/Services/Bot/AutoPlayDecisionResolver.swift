//
//  AutoPlayDecisionResolver.swift
//  Naki
//
//  在「AI 推薦」與「送出動作」之間插入的決策層。
//
//  分層意圖：
//      雀魂 oplist（合法動作的權威）
//              ↓
//      Mortal / Core ML（只負責對候選動作評分）
//              ↓
//      本層 Resolver（終局保護、模式閘門、去重）
//              ↓
//      LiqiActionSender（組包送出）
//
//  為什麼需要這一層：模型只會「評分」，不會「保證不漏和」。
//  實測過一手 oplist = [discard, riichi, tsumo]，Mortal 回傳 dahai，
//  而送出端忠實照做——把和牌牌打掉了。合法性與終局價值不該由模型決定，
//  伺服器已經明確告訴我們可以自摸，那就必須自摸。
//
//  刻意做成 `nonisolated` 的純函式：不碰 UI、不碰網路，
//  才能對「同一批 oplist + 同一組推薦」寫回歸測試。
//

import Foundation

// MARK: - 決策結果

/// Resolver 對一批 oplist 的裁決
nonisolated enum AutoPlayDecision: Equatable {
    /// 送出這個動作
    case send(action: Recommendation.ActionType, tile: String)
    /// 有值得做的動作，但目前模式不允許自動送出（僅供 UI 呈現）
    case surfaceOnly(action: Recommendation.ActionType, tile: String)
    /// 什麼都不做
    case none(reason: String)
}

// MARK: - Resolver

nonisolated struct AutoPlayDecisionResolver {

    /// 依 oplist、AI 推薦與目前模式決定要送什麼。
    ///
    /// - Parameters:
    ///   - snapshot: 協定層當下的可用操作；**nil 代表沒有權威資料**
    ///   - recommendations: Mortal 的評分結果（可為空）
    ///   - mode: 使用者選的模式
    ///   - seat: 自家座位，用來確認這批 oplist 確實是給我們的
    ///   - isSanma: 這局是不是三麻。true 時**一律不自動送出**（見下方 fail-closed 說明）。
    ///     預設 false 只是為了不動舊測試，正式路徑必須明確傳 `gameState.is3P`。
    static func resolve(snapshot: LiqiOperationSnapshot?,
                        recommendations: [Recommendation],
                        mode: AutoPlayMode,
                        seat: Int,
                        isSanma: Bool = false,
                        cloudDecision: Bool = false) -> AutoPlayDecision {

        // 三麻 fail-closed：自動模式降級成「只顯示、不送出」。
        //
        // bundled 模型只有四麻一份，三麻的 observation 佈局與動作空間都不同
        // （MortalSwift 上游：無三麻權重、無 775×34 encoder、無拔北槽位）。
        // 推薦本身已經是無效輸出，讓它自動送出等於用亂數打牌。
        // 這裡刻意不整條 return `.none`：伺服器授權仍然要看得見，
        // 使用者可以自己決定要不要照做。
        //
        // 例外：`cloudDecision`（雲端 3p 算出的那一手）不降級，
        // 規則見 `AutoPlayGate.Input.cloudDecision`。
        let effectiveMode: AutoPlayMode =
            (isSanma && !cloudDecision && mode == .auto) ? .recommend : mode

        // 缺少權威資料一律 fail closed。
        // 舊行為是「沒有 snapshot 時預設當自摸送出」，那等於在沒有伺服器授權的
        // 情況下宣告和牌——寧可不做也不能猜。
        guard let snapshot else {
            return .none(reason: "no_oplist")
        }

        // oplist 不是給我們的就不動作（理論上伺服器只推給自己，但不假設）
        guard snapshot.seat == seat else {
            return .none(reason: "seat_mismatch(\(snapshot.seat)!=\(seat))")
        }

        // ── 終局保護：伺服器說可以和，就一定和 ──────────────────────
        //
        // 這條**凌駕 AI 推薦**。Mortal 可能因為狀態編碼或役種判定的差異
        // 而沒把和牌排在第一，但「能不能和」的權威在伺服器不在模型；
        // 模型只該決定「和的價值」，不該決定「能不能和」。
        if let hora = snapshot.horaOperation {
            let tile = snapshot.contextTile ?? ""
            switch effectiveMode {
            case .auto:
                return .send(action: .hora, tile: tile)
            case .recommend:
                return .surfaceOnly(action: .hora, tile: tile)
            case .off:
                return .none(reason: "mode_off_with_\(hora)")
            }
        }

        // ── 其餘動作：照 AI 的第一推薦 ────────────────────────────
        guard let top = recommendations.first else {
            // 有副露機會但模型沒有意見 → 送「過」，否則對局會停在那裡等我們回應
            if snapshot.isCallOpportunity {
                return effectiveMode == .auto
                    ? .send(action: .none, tile: "")
                    : .none(reason: "no_recommendation_mode_\(mode.rawValue)\(isSanma ? "_sanma" : "")")
            }
            return .none(reason: "no_recommendation")
        }

        // 推薦的動作必須真的在 oplist 裡，否則是拿舊推薦操作新 oplist
        guard isSupported(top.actionType, by: snapshot) else {
            return .none(reason: "action_\(top.actionType.rawValue)_not_in_oplist\(snapshot.rawTypes)")
        }

        switch effectiveMode {
        case .auto:
            return .send(action: top.actionType, tile: top.displayTile)
        case .recommend:
            return .surfaceOnly(action: top.actionType, tile: top.displayTile)
        case .off:
            return .none(reason: "mode_off")
        }
    }

    /// 這批 oplist 是否支援該動作
    static func isSupported(_ action: Recommendation.ActionType,
                            by snapshot: LiqiOperationSnapshot) -> Bool {
        switch action {
        case .discard:
            return snapshot.contains(.discard)
        case .riichi:
            return snapshot.contains(.riichi)
        case .chi:
            return snapshot.contains(.chi)
        case .pon:
            return snapshot.contains(.pon)
        case .kan:
            return snapshot.kanOperation != nil
        case .hora:
            return snapshot.horaOperation != nil
        case .kita:
            // 拔北（三麻）：oplist type 11（babei）。只有雲端 3p 模型會產出
            // 這種推薦（本地 action space 46 沒有拔北槽位）。
            return snapshot.contains(.babei)
        case .ryukyoku:
            // 九種九牌：oplist type 10（kyushu）。與 `.kita` 同一個形狀——
            // 本地 action space 沒有這個槽位，只有雲端模型會產出。
            return snapshot.contains(.kyushu)
        case .none:
            // 「過」永遠可以送（前提是這批確實是副露機會）
            return snapshot.isCallOpportunity
        case .unknown:
            return false
        }
    }

    /// 送出前的最終確認：這批 oplist 還是當初做決策時的那一批嗎？
    ///
    /// 從決策到真正送出中間有延遲（`calculateDelay` 目前 1.0–1.8 秒），
    /// 這段期間對局可能已經往前走。序號、座位、來源、觸發牌任一項變了，
    /// 就代表手上這個決策已經過期，不能拿它去操作新的 oplist。
    static func isStillValid(decidedOn decided: LiqiOperationSnapshot,
                             current: LiqiOperationSnapshot?) -> Bool {
        guard let current else { return false }
        return current.sequence == decided.sequence
            && current.seat == decided.seat
            && current.source == decided.source
            && current.contextTile == decided.contextTile
    }
}
