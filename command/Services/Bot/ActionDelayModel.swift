//
//  ActionDelayModel.swift
//  Naki
//
//  自動打牌的動作延遲：依動作類型的分布，而不是固定值。
//

import Foundation

/// 動作延遲模型
///
/// 舊做法是每種動作一個**固定**秒數（打牌 1.8、副露 1.5、和牌 1.0）。
/// 兩個問題：
///
/// 1. **固定時序是指紋。** 每次都在同一個時間點送出，統計上與人類可分。
///    真人的反應時間是右偏分布：多數很快，偶爾停下來想。
///
/// 2. **驗證窗口太短。** `/screenshot` 回 4 MB PNG 要 1–2 秒，而送出只等
///    1.9 秒——2026-08-01 那輪的截圖常常拍到牌已經打掉之後，導致
///    「非推薦牌透明度有沒有生效」至今無法定論。
///
/// 這裡用「基準區間 + 偶發思考停頓」來模擬，並提供 `verificationScale`
/// 讓驗證時把整體拉長。
///
/// **刻意不做的事**：不模擬「牌越難決定越久」。那需要把模型的信心值接進來，
/// 而信心低不等於人會想比較久（人也可能秒切）。與其做一個沒有根據的關聯，
/// 不如維持簡單且可解釋。
struct ActionDelayModel {

    /// 每種動作的基準區間（秒）
    ///
    /// 區間的形狀對應真人的操作成本：和牌是明確的單鍵、打牌要選牌、
    /// 副露要在彈出面板上再選一次。
    struct Range {
        let low: TimeInterval
        let high: TimeInterval
    }

    static let hora = Range(low: 0.8, high: 1.6)
    static let call = Range(low: 1.2, high: 2.6)     // 吃／碰／槓
    static let pass = Range(low: 0.7, high: 1.8)
    static let discard = Range(low: 1.1, high: 2.8)

    /// 出現「思考停頓」的機率
    ///
    /// 真人偶爾會明顯停久一點。沒有這個尾巴，時間分布會是一個乾淨的
    /// 均勻區間——那本身就是可辨識的特徵。
    static let pauseProbability = 0.12

    /// 思考停頓額外加多久
    static let pauseRange = Range(low: 1.5, high: 4.0)

    /// 驗證模式的倍率
    ///
    /// 開啟後所有延遲乘上這個數，讓 `/screenshot`（1–2 秒）來得及在送出前
    /// 拍到高亮。只在測試時開；正常對局用會讓每一手都明顯變慢。
    static var verificationScale: Double = 1.0

    /// 上限。伺服器實測給 300 秒思考時間，這個上限純粹是保護——
    /// 延遲再長也不該讓對局停住。
    static let maximum: TimeInterval = 12.0

    /// 算出這次動作要等多久
    ///
    /// - Parameter generator: 注入亂數來源以便測試；正式路徑用系統預設
    static func delay(for actionType: Recommendation.ActionType?,
                      using generator: inout some RandomNumberGenerator) -> TimeInterval {
        let range: Range
        switch actionType {
        case .hora:            range = hora
        case .chi, .pon, .kan: range = call
        case .some(.none):     range = pass
        default:               range = discard
        }

        var value = Double.random(in: range.low...range.high, using: &generator)

        if Double.random(in: 0...1, using: &generator) < pauseProbability {
            value += Double.random(in: pauseRange.low...pauseRange.high, using: &generator)
        }

        return min(value * verificationScale, maximum)
    }

    /// 便利版本：用系統亂數
    static func delay(for actionType: Recommendation.ActionType?) -> TimeInterval {
        var g = SystemRandomNumberGenerator()
        return delay(for: actionType, using: &g)
    }
}
