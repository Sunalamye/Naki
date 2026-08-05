//
//  CloudBreaker.swift
//  Naki
//
//  雲端推論的指數退避斷路器（5s → 120s，直接沿用 Akagi 實戰參數）。
//
//  沒有它，伺服器掛掉時**每一個決策**都要等滿 react 逾時——
//  一局 100 手 × 2s 就是 200 秒純空等。有它，一個退避視窗只付一次慢回合。
//
//  `healthy` 旗標只在狀態轉變時觸發通知（呼叫端負責），持續掛著的伺服器
//  不會每一手都刷一次 log。
//

import Foundation

/// 指數退避斷路器。時間由呼叫端注入（`now:`），可單測。
struct CloudBreaker {

    /// 首次失敗的退避視窗
    static let base: TimeInterval = 5
    /// 退避上限
    static let max: TimeInterval = 120

    /// 連續失敗次數
    private(set) var failures = 0
    /// 此時刻之前不再嘗試（nil ＝ 允許）
    private(set) var openUntil: Date?
    /// 伺服器目前是否可達（供呼叫端做「只在轉變時通知」）
    var healthy = true

    /// 現在允不允許打 API。
    func allows(now: Date) -> Bool {
        guard let until = openUntil else { return true }
        return now >= until
    }

    /// 記錄一次成功：計數歸零、關閉斷路器。
    mutating func recordSuccess() {
        failures = 0
        openUntil = nil
    }

    /// 記錄一次失敗：開啟斷路器，回傳這次的視窗長度（供 log）。
    @discardableResult
    mutating func recordFailure(now: Date) -> TimeInterval {
        failures += 1
        let backoff = min(Self.base * pow(2, Double(failures - 1)), Self.max)
        openUntil = now.addingTimeInterval(backoff)
        return backoff
    }

    /// 使用者改設定＝明確的「現在再試一次」，整個歸零。
    mutating func reset() {
        failures = 0
        openUntil = nil
        healthy = true
    }
}
