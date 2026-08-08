//
//  ActionDelayModel.swift
//  Naki
//
//  自動打牌的動作延遲：對照真人牌譜校準的混合分布。
//

import Foundation

/// 動作延遲模型
///
/// ## 為什麼不是均勻分布
///
/// 前一版是「每種動作一個均勻區間」（打牌 1.1–2.8 秒之類）。那比固定值好，
/// 但仍然可分：**真人的反應時間不是均勻的**。均勻分布在 1.1 秒與 2.8 秒的機率密度
/// 完全相同，而真人幾乎不可能這樣。
///
/// ## 校準來源
///
/// 參數移植自 Akagi v3 的 `assets/delay_default.lua`（Apache 2.0），該檔案自述
/// 校準自 **30 局王座間對局、約 21,500 個決策**，時間取自伺服器時鐘。它解出的形狀是
/// 一個**混合分布**：
///
/// - **routine 群**：牌早就決定好了，約 1 秒的反射性快切。
/// - **genuine think 群**：真的在想，長度依「打什麼牌」「手切還是摸切」而不同。
///
/// 混合權重不是實測的快切比例，而是解過的：`w*0.844 + (1-w)*P_think(<1.2s)` 等於
/// 實測比例（tedashi 字/么九/中張 = 21%/10%/4%；tsumogiri = 31%/26%/20%）。
/// tedashi 的么九與中張解出來趨近 0——它們的 think 群本身就已經覆蓋了那些快速質量。
///
/// ## 這一版移植了什麼、沒移植什麼
///
/// **已移植**：routine/think 混合、手切與摸切分開、牌種（字牌／么九／中張）、
/// 各非打牌動作的 log-normal、偶發長考。
///
/// **未移植**（需要 Naki 目前沒有追蹤的狀態，硬編一個猜測比不做更糟）：
/// - 巡目效應（手切隨巡目變長 1.2%/巡；摸切實測與巡目無關）
/// - 對手立直效應（手切 +16%、摸切 +25%，且尾巴變胖）
/// - time bank 塑形（伺服器的 `fixed_ms` + 每局補充的 bank）
///
/// **刻意不做**：不用模型信心值調整延遲。Akagi 做過（`top_prob < 0.60 → routine 機率
/// ×0.3`），而它自己的 issue #225 實測發現那條規則在推薦分布平坦時幾乎每次都觸發，
/// 把 20–31% 的快切群整個消掉、延遲變成人類中位數的兩倍——修法就是把那條關掉。
/// 信心低不等於人會想比較久（人也可能秒切）。
///
/// ## 已知的剩餘差距
///
/// 抽樣值在 Naki 是 **sleep 長度**，而 Akagi 的同一個數字是「伺服器觀察到的總時間」
/// ——它會扣掉網路與推論已經花掉的部分。Naki 是拿到推薦之後才開始睡，所以伺服器看到的
/// 是「推論時間 + 這個值」。本地推論在 50–100ms 量級影響不大，但雲端往返（逾時設 2 秒）
/// 會讓總時間系統性偏長。要修需要把決策起點的時間戳一路傳到這裡。
struct ActionDelayModel {

    // MARK: - 校準參數

    /// log-normal 的 (μ, σ)，單位是 ln(秒)
    struct LogNormal {
        let mu: Double
        let sigma: Double
    }

    /// 打牌是 routine 快切的機率（混合權重）
    private struct RoutineWeights {
        let honor: Double
        let terminal: Double
        let middle: Double
    }

    private static let routineTedashi = RoutineWeights(honor: 0.12, terminal: 0.0, middle: 0.0)
    private static let routineTsumogiri = RoutineWeights(honor: 0.15, terminal: 0.10, middle: 0.04)

    /// routine 快切：緊緊圍繞一秒
    private static let routineFlick = LogNormal(mu: 0.0, sigma: 0.18)

    /// 真思考群（手切）
    private static let thinkTedashi = (honor: LogNormal(mu: 0.77, sigma: 0.50),
                                       terminal: LogNormal(mu: 0.83, sigma: 0.50),
                                       middle: LogNormal(mu: 1.01, sigma: 0.55))
    /// 真思考群（摸切）——每一項都明顯比手切短：不必從手上挑牌
    private static let thinkTsumogiri = (honor: LogNormal(mu: 0.54, sigma: 0.45),
                                         terminal: LogNormal(mu: 0.57, sigma: 0.45),
                                         middle: LogNormal(mu: 0.63, sigma: 0.48))

    /// 非打牌動作（單一 log-normal 就描述得夠好）
    static let reach = LogNormal(mu: 1.10, sigma: 0.55)            // 中位數 ~3.0s
    static let claim = LogNormal(mu: 0.26, sigma: 0.57)            // 副露視窗含「過」，~1.3s
    static let hora = LogNormal(mu: 0.15, sigma: 0.50)             // 榮和／自摸，~1.2s
    static let kita = LogNormal(mu: 0.26, sigma: 0.57)             // 拔北：比照 claim（無實測）

    /// 偶發長考的機率與量（重數牌河、盤算要不要收手）
    private static let tankProbability = 0.02
    private static let tankExtra = LogNormal(mu: 0.8, sigma: 0.6)

    /// 驗證模式的倍率
    ///
    /// 開啟後所有延遲乘上這個數，讓 `/screenshot`（1–2 秒）來得及在送出前拍到高亮。
    /// 只在測試時開；正常對局用會讓每一手都明顯變慢。
    static var verificationScale: Double = 1.0

    /// 上限。伺服器實測給 300 秒思考時間，這個上限純粹是保護——
    /// 延遲再長也不該讓對局停住。**不隨 `scale` 放大**：它的職責是一條與使用者偏好
    /// 無關的保護線。
    static let maximum: TimeInterval = 12.0

    // MARK: - 牌種

    /// 牌種——真人對這三類的思考長度明顯不同
    enum TileClass {
        case honor      // 字牌
        case terminal   // 么九
        case middle     // 中張
    }

    /// 從 MJAI 牌名判斷牌種。認不出來時當中張（最保守：那是思考最久的一類）。
    static func tileClass(of tile: String) -> TileClass {
        // MJAI 字牌：E/S/W/N/P/F/C
        if ["E", "S", "W", "N", "P", "F", "C"].contains(tile) { return .honor }
        guard let first = tile.first, let number = first.wholeNumberValue else { return .middle }
        return (number == 1 || number == 9) ? .terminal : .middle
    }

    // MARK: - 抽樣

    /// 從 log-normal 取一個樣本（Box–Muller 產標準常態，再取指數）
    private static func sample(_ d: LogNormal,
                               using generator: inout some RandomNumberGenerator) -> Double {
        // u1 不能是 0（log(0) 是 -inf）
        let u1 = Double.random(in: Double.leastNormalMagnitude...1, using: &generator)
        let u2 = Double.random(in: 0...1, using: &generator)
        let standardNormal = (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
        return Foundation.exp(d.mu + d.sigma * standardNormal)
    }

    /// 算出這次動作要等多久。
    ///
    /// - Parameters:
    ///   - actionType: 決策出來的動作
    ///   - tile: 要打的那張牌（MJAI 表記）；只有打牌類會用到
    ///   - tsumogiri: 這一打是不是把剛摸的牌直接切掉
    ///   - scale: 使用者的基準秒數係數（`SettingsStore.actionDelayScale`）。
    ///     乘在**整個抽樣值**上，所以拉長的是分布本身而不是換成固定值——
    ///     防偵測的隨機性保留。`maximum` 不隨它縮放。
    ///   - generator: 注入亂數來源以便測試；正式路徑用系統預設
    static func delay(for actionType: Recommendation.ActionType?,
                      tile: String? = nil,
                      tsumogiri: Bool = false,
                      scale: Double = 1.0,
                      using generator: inout some RandomNumberGenerator) -> TimeInterval {
        var seconds: Double

        switch actionType {
        case .discard, .riichi:
            seconds = discardThink(tile: tile, tsumogiri: tsumogiri, using: &generator)
            // 立直是一個真正的決定，比一般打牌久（實測中位數約 3 秒）
            if actionType == .riichi {
                seconds = sample(reach, using: &generator)
            }
        case .hora:
            seconds = sample(hora, using: &generator)
        case .kita:
            seconds = sample(kita, using: &generator)
        case .chi, .pon, .kan, .some(.none), .ryukyoku:
            // 副露視窗的所有回應（含「過」與九種九牌）共用一個分布：
            // 從使用者的角度它們是同一個介面上的同一次選擇。
            seconds = sample(claim, using: &generator)
        case .unknown, nil:
            seconds = sample(claim, using: &generator)
        }

        // 偶發長考。**不要為了體感把這條拿掉**：真人確實會停下來重數牌河，
        // 沒有這個尾巴，時間分布會缺一塊而變得可分。
        if Double.random(in: 0...1, using: &generator) < tankProbability {
            seconds += 2.0 + sample(tankExtra, using: &generator)
        }

        return min(seconds * scale * verificationScale, maximum)
    }

    /// 打牌：routine 快切與真思考的混合
    private static func discardThink(tile: String?,
                                     tsumogiri: Bool,
                                     using generator: inout some RandomNumberGenerator) -> Double {
        let klass = tile.map { tileClass(of: $0) } ?? .middle
        let weights = tsumogiri ? routineTsumogiri : routineTedashi
        let routineProbability: Double = {
            switch klass {
            case .honor:    return weights.honor
            case .terminal: return weights.terminal
            case .middle:   return weights.middle
            }
        }()

        if Double.random(in: 0...1, using: &generator) < routineProbability {
            return sample(routineFlick, using: &generator)
        }

        let think = tsumogiri ? thinkTsumogiri : thinkTedashi
        switch klass {
        case .honor:    return sample(think.honor, using: &generator)
        case .terminal: return sample(think.terminal, using: &generator)
        case .middle:   return sample(think.middle, using: &generator)
        }
    }

    /// 便利版本：用系統亂數
    static func delay(for actionType: Recommendation.ActionType?,
                      tile: String? = nil,
                      tsumogiri: Bool = false,
                      scale: Double = 1.0) -> TimeInterval {
        var g = SystemRandomNumberGenerator()
        return delay(for: actionType, tile: tile, tsumogiri: tsumogiri,
                     scale: scale, using: &g)
    }
}
