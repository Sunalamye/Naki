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
    ///
    /// 2026-08-03 從 0.12 調到 0.06：使用者回報偶發的 3–4 秒停頓讓人以為卡住、
    /// 提前手動點。降低機率讓長停頓更罕見，但保留尾巴（防偵測）。
    static let pauseProbability = 0.06

    /// 思考停頓額外加多久
    ///
    /// 2026-08-03 上限從 4.0 收到 2.5：配合上面降低機率，把「感覺卡住」的高尾壓掉，
    /// 同時仍保留 1.5–2.5s 的思考尾巴。
    static let pauseRange = Range(low: 1.5, high: 2.5)

    /// 驗證模式的倍率
    ///
    /// 開啟後所有延遲乘上這個數，讓 `/screenshot`（1–2 秒）來得及在送出前
    /// 拍到高亮。只在測試時開；正常對局用會讓每一手都明顯變慢。
    ///
    /// 與使用者的延遲 stepper（`scale` 參數）是兩件事：`verificationScale` 是
    /// 驗證時才開的全域旗標，`scale` 是使用者長期設定的基準秒數係數。兩者相乘。
    static var verificationScale: Double = 1.0

    /// 上限。伺服器實測給 300 秒思考時間，這個上限純粹是保護——
    /// 延遲再長也不該讓對局停住。
    ///
    /// **設計決策：`maximum` 是絕對硬上限，不隨 `scale` 一起放大。** 它的職責是
    /// 「延遲再長也不該讓對局停住」，那是一條與使用者偏好無關的保護線；使用者把
    /// stepper 拉到 3.0s 只放大分布本身，碰到上限就截在 12 秒（副露＋思考停頓的
    /// 高尾在 scale=3.0 時才會偶爾觸頂，日常打牌牌的區間遠在其下）。
    static let maximum: TimeInterval = 12.0

    /// 算出這次動作要等多久
    ///
    /// - Parameters:
    ///   - scale: 使用者的基準秒數係數（`SettingsStore.actionDelayScale`）。
    ///     `1.0` 等於現行行為，向下更快、向上更慢。乘在**整個抽樣值**上
    ///     （基準區間＋偶發思考停頓），所以拉長的是分布本身而不是換成固定值
    ///     ——防偵測的隨機性保留。`maximum` 不隨它縮放（見上）。
    ///   - generator: 注入亂數來源以便測試；正式路徑用系統預設
    static func delay(for actionType: Recommendation.ActionType?,
                      scale: Double = 1.0,
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

        // 抽樣順序刻意不動：`scale` 只乘在最後，所以 scale=1.0 與加入這個參數之前
        // 用同一顆種子逐位元等價（`ActionDelayModelTests` 鎖著這一點）。
        return min(value * scale * verificationScale, maximum)
    }

    /// 便利版本：用系統亂數
    static func delay(for actionType: Recommendation.ActionType?,
                      scale: Double = 1.0) -> TimeInterval {
        var g = SystemRandomNumberGenerator()
        return delay(for: actionType, scale: scale, using: &g)
    }
}
