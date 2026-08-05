//
//  MahjongBot.swift
//  Naki
//
//  推論引擎的 protocol 抽象（pluggable-bots-plan 第 1 層；2026-08-05 使用者
//  決策「先抽象、再實作」落地，取代前一日的 controller 內 overlay——見
//  docs/cloud-inference-decisions.md D11）。
//
//  邊界劃分：
//  - 引擎（conform 這個 protocol）負責「對事件做出反應＋產出推薦」。
//  - `NativeBotController` 保留遊戲狀態追蹤（手牌／分數／風）——那是**遊戲**
//    狀態不是引擎狀態，UI 與 MCP 的匯出都靠它，跟引擎是誰無關。
//  - 世代守衛（inflight 失效）也留在 controller：它守的是「bot 換了一代」，
//    必須站在引擎之外。
//
//  現有 conform：`BundledCoreMLBot`（MortalSwift + Core ML）、
//  `CloudBot`（裝飾器：本地閘門＋雲端代理）。未來的子行程／網路 mjai bot
//  也從這裡接入。
//

import Foundation

/// 一個能對 MJAI 事件做出反應的推論引擎。
@MainActor
protocol MahjongBot: AnyObject {

    /// 引擎自述（UI 顯示、log 標記用）
    var identity: BotIdentity { get }

    /// 雲端推論啟用中時的目的主機；nil ＝ 純本地。
    /// 非 nil 代表對局事件正在送往該主機——UI 依此常駐顯示。
    var cloudHost: String? { get }

    /// 雲端已設定但目前**退化中**（斷路器不健康或退避中）——決策正在用
    /// rollback 的本地模型（三麻＝沒有推薦）。UI 依此顯示紅色警示。
    var cloudDegraded: Bool { get }

    /// 雲端啟用期間**連續**以非雲端來源結束的決策數；0＝雲端正常服務。
    /// 「fallback 必須讓人看得出來」的量化版：紅色警示行會顯示這個數字。
    var cloudFallbackStreak: Int { get }

    /// 對一批事件做出反應。
    ///
    /// 批次是 mjai 慣例（自上次反應以來的事件，最後一個是觸發點）。目前的
    /// pipeline 逐事件餵（單元素批次）；介面收批次是為了未來的子行程／網路
    /// 引擎——那裡每個事件一次 round-trip 的代價是一局 700 次往返。
    ///
    /// 回傳 nil ＝ 這批事件不是決策點（無動作、也不刷新推薦——畫面保持現狀）。
    func react(events: [[String: Any]]) async throws -> BotReaction?

    /// 清內部狀態（對局結束／重連重建時由呼叫端觸發）。
    func reset()
}

extension MahjongBot {
    var cloudHost: String? { nil }
    var cloudDegraded: Bool { false }
    var cloudFallbackStreak: Int { 0 }
}

/// 引擎自述。
struct BotIdentity: Equatable {
    /// 機器名（log 用），例如 "mortal-bundled"、"cloud+mortal-bundled"
    let name: String
    /// 顯示名
    let displayName: String
    /// 是否真的支援三麻。內建 Mortal 是四麻模型 ⇒ false；
    /// 雲端只有在「啟用＋選了 3p 模型」時才如實為 true。
    let supports3P: Bool
    /// 推論是否完全在本機（隱私提示用）
    let isLocal: Bool
}

/// 引擎對一個決策點的完整輸出。
struct BotReaction {
    /// 要回應的 mjai 動作（字典形式）；nil ＝ 無動作但推薦有刷新
    /// （例：自家副露後的捨牌建議——mjai 對副露後不再送事件，
    /// 但畫面與自動打牌需要新的打牌推薦）。
    let action: [String: Any]?

    /// 這個決策點的推薦列（已排序；自動打牌的 executor 取清單順序
    /// 第一個對應 actionType 的列）。空陣列＝清空畫面上的推薦。
    let recommendations: [Recommendation]

    /// 這批推薦由誰算出："local" 或 "cloud:<model>"。
    /// fallback 原則——可以更弱，但必須讓人看得出來。
    let source: String
}
