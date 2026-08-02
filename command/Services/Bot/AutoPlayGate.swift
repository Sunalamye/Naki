//
//  AutoPlayGate.swift
//  Naki
//
//  「現在該不該觸發自動打牌」的純決策。
//

import Foundation

/// 自動打牌的觸發閘門
///
/// 這些判斷原本散在 `WebViewModel.checkAndRetriggerAutoPlay` 裡，跟非同步的
/// 重試框架、送出通道、UI 同步交織在一起。**本輪的多個 bug 就是因此產生的**：
///
/// - 加上「沒有 oplist 就別觸發」之後，跟「有對局就等待」互相打架造成死結
/// - 「此刻推薦是空的」被當成「模型決定不做」，把 85.9% 的碰蓋成過
///
/// 兩個都不是單一條件寫錯，而是**看不出新加的條件會擋掉哪條既有路徑**。
/// 抽成純函式之後，所有閘門在同一個 switch 裡，而且可以逐條單測。
///
/// 這裡**只決定要不要動、動什麼**；怎麼送、重試幾次、去抖多久仍在 WebViewModel。
/// 那些跟 `webPage` / `liqiSender` / `debugServer` 綁死，搬過來只會把耦合換個位置。
enum AutoPlayGate {

    /// 閘門的結論
    enum Decision: Equatable {
        /// 不動作，附上原因（原因會進 log，排查時要看得出是哪一關擋的）
        case skip(Reason)
        /// 伺服器提供和牌但模型沒推薦 → 強制交給 resolver
        case forceHora
        /// 副露機會而模型確實判斷不做 → 主動送「過」
        case sendPass
        /// 照常走推薦
        case proceed
    }

    enum Reason: String, Equatable {
        case notAutoMode = "非自動模式"
        case sanmaUnsupported = "三麻不支援自動打牌（只有四麻模型）"
        case actionInFlight = "已有動作執行中"
        case noOplist = "尚無 oplist"
        case awaitingInference = "推論尚未完成（寬限期內）"
        case noRecommendation = "無推薦且非副露機會"
        case notMyDiscardTurn = "已非本家打牌回合"
    }

    /// 判斷用的輸入
    ///
    /// 全部是值，不含任何 UI 或網路物件——這是能單測的前提。
    struct Input {
        let isAutoMode: Bool
        /// 這局是不是三麻（`GameState.is3P`）
        ///
        /// 預設 false：舊的呼叫點與測試不必逐一改，但**正式路徑必須明確傳入**。
        var isSanma: Bool = false
        /// 是否已有動作在執行（`currentExecutionId != nil`）
        let hasActionInFlight: Bool
        let snapshot: LiqiOperationSnapshot?
        let recommendations: [Recommendation]
        /// 現在時間（測試時注入）
        let now: Date
        /// 副露機會在多久之後才允許因「沒推薦」而送過
        let callPassGrace: TimeInterval
    }

    static func evaluate(_ input: Input) -> Decision {
        guard input.isAutoMode else { return .skip(.notAutoMode) }

        // 三麻 fail-closed。
        //
        // bundled Core ML 只有四麻一份（obs 1012×34、action 46），三麻的牌山、
        // 規則與 observation 佈局都不同（沒有 2m–8m、北是拔北寶牌、只有三家的分數與河）。
        // 拿四麻模型推三麻不是「稍微偏差」而是**結構上無效**（MortalSwift p3-1），
        // 而這條閘門下游的 `.sendPass` 會**繞過 resolver 直接送出**，
        // 所以擋必須擋在這裡，不能只擋在 resolver。
        guard !input.isSanma else { return .skip(.sanmaUnsupported) }

        guard !input.hasActionInFlight else { return .skip(.actionInFlight) }

        // 合法性的權威在 oplist。沒有它就沒有伺服器授權，一律不動。
        guard let snapshot = input.snapshot else { return .skip(.noOplist) }

        if input.recommendations.isEmpty {
            // 伺服器提供和牌時，絕不因為「模型沒意見」而放過。
            // 這裡曾經是漏和的成因，而且更糟的是榮和被歸類為 isCallOpportunity，
            // 會走到下面主動送「過」——等於自己棄和。
            if snapshot.horaOperation != nil { return .forceHora }

            // 「此刻推薦是空的」≠「模型決定不做」。
            // 輪詢與推論是非同步的：oplist 到達後約 50–100ms 才有結果，
            // 再經過一次同步才到得了這裡。搶在那之前送「過」不可逆，
            // 而伺服器給 300 秒思考時間——等一下的代價是零。
            if input.now.timeIntervalSince(snapshot.capturedAt) < input.callPassGrace {
                return .skip(.awaitingInference)
            }

            // 過了寬限期仍然沒有推薦，才視為「模型判斷不做」。
            // 只在確實是我方副露機會時補送；沒人送 cancel 的話對局會停到伺服器逾時代打。
            let isCall = snapshot.operations.compactMap(\.type).contains { $0.isCallOpportunity }
            return isCall ? .sendPass : .skip(.noRecommendation)
        }

        guard let first = input.recommendations.first else { return .skip(.noRecommendation) }

        // discard 必須仍有打牌／立直操作，代表確實輪到自己打牌。
        // 已換成別家回合或只剩吃碰機會時重新觸發，會送出遲到或重複的打牌。
        if first.actionType == .discard,
           !snapshot.contains(.discard), !snapshot.contains(.riichi) {
            return .skip(.notMyDiscardTurn)
        }

        return .proceed
    }

    /// 局間確認（`confirmNewRound`）的閘門：只看 mode 與三麻 fail-closed。
    ///
    /// confirmNewRound 沒有 oplist（它不是牌桌上的一個可用操作，而是「進下一局」的
    /// 流程訊號），所以不走 `evaluate` 的 snapshot 分支。但「只有自動模式才自動送、
    /// 三麻一律不自動」與打牌完全同一條規則，故共用同一組 `Reason`，收斂在同一個檔案：
    ///
    /// - `.off` / `.recommend`：不自動送（使用者要自己在遊戲內確認）→ `.skip(.notAutoMode)`
    /// - 三麻：fail-closed（內建模型只有四麻一份，自動流程一律不介入三麻）
    ///   → `.skip(.sanmaUnsupported)`
    ///
    /// - Returns: `.proceed` 表示可以送；否則 `.skip(reason)`（永遠不會回 `.forceHora`/`.sendPass`）
    static func allowsConfirm(isAutoMode: Bool, isSanma: Bool) -> Decision {
        guard isAutoMode else { return .skip(.notAutoMode) }
        guard !isSanma else { return .skip(.sanmaUnsupported) }
        return .proceed
    }
}
