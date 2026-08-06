//
//  SelfActionEchoTracker.swift
//  Naki
//
//  送出驗證的第 3 層：伺服器**執行**了我們的動作嗎？
//
//  前兩層都會騙人——2026-08-06 東家開局第一打，`sendRaw` 成功、RESPONSE 也無 error，
//  伺服器卻整整 16 秒沒動作（同局其他 59 次送出的回音都在 1 秒內）。唯一可信的事實是
//  伺服器把我方動作廣播回來。這裡只記「我方權威動作發生過幾次」，等多久、沒等到怎麼辦
//  在 `AutoPlayActionExecutor`。
//

import Foundation

/// 回音的觀測面。抽成協定是為了讓單測能精確擺出「回音來了／沒來」。
@MainActor
protocol SelfActionEchoObserving {
    var count: UInt64 { get }
    /// 等計數超過 `baseline`；逾時回 false。`timeoutMs == 0` 視為停用（直接回 true）。
    func waitForEcho(after baseline: UInt64, timeoutMs: Int) async -> Bool
}

@MainActor
final class SelfActionEchoTracker: SelfActionEchoObserving {

    static let shared = SelfActionEchoTracker()

    /// 我方權威動作累計次數。單調遞增，送出前取一次當 baseline 即可，不需要重置。
    private(set) var count: UInt64 = 0

    private let pollIntervalMs = 40

    init() {}

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    func record() { count &+= 1 }

    func waitForEcho(after baseline: UInt64, timeoutMs: Int) async -> Bool {
        guard timeoutMs > 0 else { return true }
        var waited = 0
        while waited < timeoutMs, count <= baseline {
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
            waited += pollIntervalMs
        }
        return count > baseline
    }

    /// 這則事件是否算「送出已定案」。
    ///
    /// 兩種都算：我方動作被廣播回來，或本局已結束——後者是 `ActionHule` 的唯一形式
    /// （bridge 把它轉成不帶 actor 的 `end_kyoku`），而局已結束時重送必然是錯的，
    /// 不論那手是誰和的。`tsumo` 不算：那是伺服器發牌，不是對我方送出的回應。
    static func isEcho(type: String, actor: Int?, seat: Int) -> Bool {
        type == "end_kyoku" || (selfActionTypes.contains(type) && actor == seat)
    }

    private static let selfActionTypes: Set<String> = [
        "dahai", "reach", "chi", "pon", "daiminkan", "ankan", "kakan",
        "hora", "nukidora", "kita",
    ]
}
