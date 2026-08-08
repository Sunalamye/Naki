//
//  GameModels.swift
//  Naki
//
//  Created by Suoie on 2025/12/01.
//  遊戲狀態模型 - 使用 MortalSwift 強類型
//

import Foundation
import SwiftUI
import MortalSwift

// MARK: - Game State

/// 遊戲狀態（強類型版本）
struct GameState: Equatable {
    /// 局數 (1-4 for 東1-東4, 5-8 for 南1-南4, etc.)
    var kyoku: Int = 1
    /// 本場
    var honba: Int = 0
    /// 供託（立直棒數）
    var kyotaku: Int = 0
    /// 場風
    var bakaze: Wind = .east
    /// 自風
    var jikaze: Wind = .east
    /// 四家點數
    var scores: [Int] = [25000, 25000, 25000, 25000]
    /// 自己的座位 (0-3)
    var playerId: Int = 0
    /// 寶牌指示牌
    var doraMarkers: [Tile] = []
    /// 是否為三麻
    var is3P: Bool = false

    // MARK: - Computed Properties

    /// 局的顯示名稱 (e.g., "東1局")
    var kyokuDisplayName: String {
        let winds = ["東", "南", "西", "北"]
        let playerCount = is3P ? 3 : 4
        let windIndex = (kyoku - 1) / playerCount
        let roundNum = ((kyoku - 1) % playerCount) + 1
        let windName = windIndex < winds.count ? winds[windIndex] : "?"
        return "\(windName)\(roundNum)局"
    }

    /// 自風顯示
    var jikazeDisplay: String {
        switch jikaze {
        case .east: return "東家"
        case .south: return "南家"
        case .west: return "西家"
        case .north: return "北家"
        }
    }

    /// 場風顯示
    var bakazeDisplay: String {
        switch bakaze {
        case .east: return "東"
        case .south: return "南"
        case .west: return "西"
        case .north: return "北"
        }
    }

    /// 寶牌指示牌（MJAI 字串格式，保持兼容性）
    var doraIndicators: [String] {
        doraMarkers.map { $0.mjaiString }
    }

    // MARK: - Legacy Compatibility

    /// 場風（MJAI 字串格式）
    var bakazeString: String { bakaze.rawValue }
    /// 自風（MJAI 字串格式）
    var jikazeString: String { jikaze.rawValue }

    /// 供託（別名，保持兼容性）
    var riichiBou: Int {
        get { kyotaku }
        set { kyotaku = newValue }
    }
}

// MARK: - Available Actions

/// 「現在能做什麼」——由伺服器推來的 `OptionalOperationList` 導出。
///
/// 權威刻意選 oplist 而不是模型 mask：mask 是 Mortal 對**自己認為的狀態**算出的合法動作，
/// oplist 是伺服器實際授權的動作。送出端（`AutoPlayGate` / `AutoPlayDecisionResolver` /
/// `LiqiActionSender`）本來就只認 oplist；UI 與 `/bot/status` 跟著同一個來源，
/// 才不會出現「徽章亮著但送不出去」或反過來的分歧。
///
/// 純值型別、不碰任何 singleton，因此可以對「這批 oplist → 這六個旗標」直接單測。
nonisolated struct BotAvailableActions: Equatable {
    var canDiscard: Bool = false
    var canRiichi: Bool = false
    var canChi: Bool = false
    var canPon: Bool = false
    var canKan: Bool = false
    var canAgari: Bool = false
    /// 拔北（三麻，oplist type 11 babei）
    var canKita: Bool = false

    /// 沒有任何授權（沒有 oplist ＝ 什麼都不能做，不是「未知」）
    static let none = BotAvailableActions()

    init() {}

    /// - Parameter snapshot: 協定層快照；nil 代表沒有伺服器授權 → 全部 false
    init(snapshot: LiqiOperationSnapshot?) {
        guard let snapshot else { return }
        canDiscard = snapshot.contains(.discard)
        canRiichi = snapshot.contains(.riichi)
        canChi = snapshot.contains(.chi)
        canPon = snapshot.contains(.pon)
        // 槓有三種（暗槓 / 加槓 / 大明槓），任一種都算「可以槓」
        canKan = snapshot.kanOperation != nil
        // 和了兩種（自摸 / 榮和）
        canAgari = snapshot.horaOperation != nil
        // 拔北（三麻）
        canKita = snapshot.contains(.babei)
    }

    /// 是否有任何可用動作
    var hasAny: Bool {
        canDiscard || canRiichi || canChi || canPon || canKan || canAgari || canKita
    }
}

// MARK: - Bot Status

/// Bot 狀態
struct BotStatus: Equatable {
    /// Bot 是否運行中
    var isActive: Bool = false
    /// 模型名稱
    var modelName: String = "mortal"
    /// 玩家座位
    var playerId: Int = 0
    /// 是否為三麻
    var is3P: Bool = false

    /// 這批推薦由誰算出："local" 或 "cloud:<model>"（雲端 overlay 寫入）。
    /// fallback 原則——可以更弱，但必須讓人看得出來：雲端失敗退回本地時
    /// 這裡會如實變回 "local"，UI 與 `/bot/status` 都讀同一份。
    var decisionSource: String = "local"

    /// 雲端推論啟用中時的目的主機；nil＝純本地。
    /// 非 nil 代表**對局事件（含自家手牌）正在送往這個主機**——
    /// UI 必須常駐顯示（pluggable-bots-plan 安全節第 3 條）。
    var cloudHost: String? = nil

    /// 雲端已設定但目前退化中（斷路器不健康/退避）——決策在 rollback 本地
    /// （三麻＝無推薦）。UI 依此把雲端行轉成紅色警示。
    var cloudDegraded: Bool = false

    /// 雲端啟用期間連續以非雲端來源結束的決策數；0＝雲端正常服務
    var cloudFallbackStreak: Int = 0

    // MARK: - Available Actions
    //
    // 這六個欄位的唯一真實來源是協定層 oplist（見 `BotAvailableActions`）。
    // 不要從別的地方寫進來：多一個沒被呼叫到的寫入點，UI 徽章與 `/bot/status`
    // 就會恆為 false，而且不會有任何錯誤訊息。

    /// 可打牌
    var canDiscard: Bool = false
    /// 可立直
    var canRiichi: Bool = false
    /// 可吃
    var canChi: Bool = false
    /// 可碰
    var canPon: Bool = false
    /// 可槓
    var canKan: Bool = false
    /// 可和
    var canAgari: Bool = false
    /// 可拔北（三麻）
    var canKita: Bool = false

    // MARK: - Computed Properties

    /// 這批推薦是否由雲端模型算出。三麻放行與 UI 警告的共同判準，
    /// 規則見 `AutoPlayGate.Input.cloudDecision`。
    var isCloudDecision: Bool { decisionSource.hasPrefix("cloud:") }

    /// 模型顯示名稱
    ///
    /// 三麻對局要明講「用的是四麻模型」。三麻的牌山、規則與 observation 佈局
    /// 都跟四麻不同（沒有 2m-8m、北是拔北寶牌、只有三家的分數與河），
    /// 拿四麻模型去推三麻，輸出不是「稍微偏差」而是**結構上無效**。
    /// 標成 "Mortal (3P)" 會讓人誤以為有專用模型。
    var modelDisplayName: String {
        let base: String
        switch modelName {
        case "mortal": base = "Mortal (4P)"
        case "mortal3p": base = "Mortal (3P)"
        case "cloud-3p": base = "雲端推論 (3P)"
        default: base = modelName
        }
        // 警告後綴只在雲端沒有在服務時出現（服務中掛著會與雲端指示行矛盾）；
        // 三麻本地模型不啟動，cloud-3p 未生效＝無推論
        guard is3P && !isCloudDecision else { return base }
        return modelName == "cloud-3p"
            ? "\(base) ⚠️ 未生效，無推論"
            : "\(base) ⚠️ 三麻無專用模型"
    }

    /// 是否有任何可用動作
    var hasAvailableAction: Bool {
        canDiscard || canRiichi || canChi || canPon || canKan || canAgari || canKita
    }

    // MARK: - Mutators

    /// 套用一組由 oplist 導出的可用動作
    mutating func applyAvailableActions(_ actions: BotAvailableActions) {
        canDiscard = actions.canDiscard
        canRiichi = actions.canRiichi
        canChi = actions.canChi
        canPon = actions.canPon
        canKan = actions.canKan
        canAgari = actions.canAgari
        canKita = actions.canKita
    }
}

// MARK: - Recommendation

/// AI 推薦動作
struct Recommendation: Identifiable, Equatable {
    /// 穩定 ID（基於內容）
    var id: String { "\(actionType.rawValue)_\(tile?.mjaiString ?? label)" }

    /// 推薦的牌（打牌時使用）
    let tile: Tile?
    /// 動作標籤（非打牌動作時使用）
    let label: String
    /// 機率 (0.0 ~ 1.0)
    let probability: Double
    /// 動作類型
    let actionType: ActionType
    /// 顯示用補充（例：吃列的實際牌組「用 4m·5m 吃 3m」）。
    /// 只有資訊源頭真的知道牌組時才有值（雲端 reaction 帶 consumed；
    /// 本地 mask 只有粗變體 ⇒ nil）。純顯示，executor 不讀它。
    let detail: String?

    /// 動作類型
    enum ActionType: String, CaseIterable {
        case discard = "discard"
        case riichi = "riichi"
        case chi = "chi"
        case pon = "pon"
        case kan = "kan"
        case hora = "hora"
        /// 拔北（三麻）。只有雲端 3p 模型會產出（本地 action space 46 無此槽位）。
        case kita = "kita"
        /// 九種九牌（配牌時么九牌 ≥ 9 種可宣告流局）。
        ///
        /// rawValue 取 `ryukyoku` 對齊雲端 API 與 MJAI 的動作名；送到雀魂時是
        /// `ReqSelfOperation type=10`（liqi 叫 kyushu）。與 `.kita` 同一個形狀：
        /// 本地 action space 46 沒有這個槽位，只有雲端模型會產出。
        case ryukyoku = "ryukyoku"
        case none = "none"
        case unknown = "unknown"

        var displayName: String {
            switch self {
            case .discard: return "打"
            case .riichi: return "立直"
            case .chi: return "吃"
            case .pon: return "碰"
            case .kan: return "槓"
            case .hora: return "和"
            case .kita: return "拔北"
            case .ryukyoku: return "九種九牌"
            case .none: return "過"
            case .unknown: return "?"
            }
        }

        /// 這個動作在遊戲畫面上會不會標到某一張牌。
        ///
        /// `GameHighlightScript` 只對這幾種產生 mark——和了／過／拔北／九種九牌
        /// 沒有對應的手牌可標，它們落在那個 switch 的 `default`。
        /// `GameStore.highlightedTile` 必須用同一個判斷，否則會宣稱畫面上有一個
        /// 其實不存在的標記（那個欄位的 doc 正是在防這件事）。
        /// `GameHighlightScriptTests` 有一條測試把兩邊鎖在一起。
        var marksTileOnBoard: Bool {
            switch self {
            case .discard, .riichi, .chi, .pon, .kan: return true
            case .hora, .kita, .ryukyoku, .none, .unknown: return false
            }
        }

        var color: Color {
            switch self {
            case .discard: return .blue
            case .riichi: return .orange
            case .chi: return .green
            case .pon: return .purple
            case .kan: return .red
            case .hora: return .yellow
            case .kita: return .teal
            case .ryukyoku: return .brown
            case .none: return .gray
            case .unknown: return .secondary
            }
        }
    }

    // MARK: - Initializers

    /// 強類型初始化（打牌）
    init(tile: Tile, probability: Double, detail: String? = nil) {
        self.tile = tile
        self.label = tile.mjaiString
        self.probability = probability
        self.actionType = .discard
        self.detail = detail
    }

    /// 強類型初始化（非打牌動作）
    init(actionType: ActionType, probability: Double, label: String = "",
         detail: String? = nil) {
        self.tile = nil
        self.label = label.isEmpty ? actionType.rawValue : label
        self.probability = probability
        self.actionType = actionType
        self.detail = detail
    }

    /// 從 MJAI 字串初始化（保持兼容性）
    init(tile tileString: String, probability: Double, actionType: ActionType,
         detail: String? = nil) {
        if actionType == .discard, let t = Tile(mjaiString: tileString) {
            self.tile = t
        } else {
            self.tile = nil
        }
        self.label = tileString
        self.probability = probability
        self.actionType = actionType
        self.detail = detail
    }

    /// 從字典初始化（Legacy）
    init(from dict: [String: Any]) {
        let tileStr = dict["tile"] as? String ?? "?"
        let prob = dict["prob"] as? Double ?? 0.0
        let typeStr = dict["action_type"] as? String ?? "unknown"
        let type = ActionType(rawValue: typeStr) ?? .unknown

        if type == .discard, let t = Tile(mjaiString: tileStr) {
            self.tile = t
        } else {
            self.tile = nil
        }
        self.label = tileStr
        self.probability = prob
        self.actionType = type
        self.detail = dict["detail"] as? String
    }

    // MARK: - Computed Properties

    /// 機率百分比字串
    var percentageString: String {
        String(format: "%.1f%%", probability * 100)
    }

    /// 牌的 Unicode 表示
    var tileUnicode: String {
        tile?.unicode ?? MahjongTile.mjaiToUnicode[label] ?? label
    }

    /// 顯示用的牌面字串
    var displayTile: String {
        tile?.mjaiString ?? label
    }

    /// 顯示用的標籤（友好格式）
    var displayLabel: String {
        switch actionType {
        case .chi:
            // chi_0, chi_1, chi_2 -> 吃①, 吃②, 吃③
            if label.hasPrefix("chi_"), let idx = Int(String(label.dropFirst(4))) {
                let symbols = ["①", "②", "③"]
                return "吃\(symbols[min(idx, 2)])"
            }
            return "吃"
        case .pon: return "碰"
        case .kan: return "槓"
        case .hora: return "和"
        case .riichi: return "立直"
        case .kita: return "拔北"
        case .ryukyoku: return "九種九牌"
        case .none: return "過"
        case .discard: return tile?.mjaiString ?? label
        case .unknown: return label
        }
    }

    /// 是否為紅寶牌
    var isRed: Bool {
        tile?.isRed ?? label.hasSuffix("r")
    }
}

// MARK: - MahjongTile

/// 麻將牌表示（整合 Tile 強類型和 MJAI 字串）
struct MahjongTile: Identifiable, Equatable, Hashable {
    /// 穩定 ID
    var id: String { mjai }
    /// MJAI 格式字串
    let mjai: String
    /// 強類型 Tile（可選）
    let tile: Tile?

    init(mjai: String) {
        self.mjai = mjai
        self.tile = Tile(mjaiString: mjai)
    }

    init(tile: Tile) {
        self.tile = tile
        self.mjai = tile.mjaiString
    }

    /// Unicode 表示
    var unicode: String {
        tile?.unicode ?? Self.mjaiToUnicode[mjai] ?? mjai
    }

    /// 是否為紅寶牌
    var isRed: Bool {
        tile?.isRed ?? mjai.hasSuffix("r")
    }

    /// 牌的中文名稱
    var displayName: String {
        let baseTile = isRed ? String(mjai.dropLast()) : mjai
        let names: [String: String] = [
            "1m": "一萬", "2m": "二萬", "3m": "三萬", "4m": "四萬", "5m": "五萬",
            "6m": "六萬", "7m": "七萬", "8m": "八萬", "9m": "九萬",
            "1p": "一筒", "2p": "二筒", "3p": "三筒", "4p": "四筒", "5p": "五筒",
            "6p": "六筒", "7p": "七筒", "8p": "八筒", "9p": "九筒",
            "1s": "一索", "2s": "二索", "3s": "三索", "4s": "四索", "5s": "五索",
            "6s": "六索", "7s": "七索", "8s": "八索", "9s": "九索",
            "E": "東", "S": "南", "W": "西", "N": "北",
            "P": "白", "F": "發", "C": "中",
        ]
        let name = names[baseTile] ?? mjai
        return isRed ? "紅\(name)" : name
    }

    /// 無障礙可讀名稱（VoiceOver 用）
    /// 數牌「一萬…九萬 / 一筒…九筒 / 一索…九索」、字牌「東南西北白發中」、紅寶牌加「紅」前綴（如「紅五萬」）。
    /// 供 BotStatusView 與 RecommendationView 共用，避免各寫一份牌名轉換。
    var accessibleName: String { displayName }

    /// MJAI 到 Unicode 的映射表
    static let mjaiToUnicode: [String: String] = [
        "1m": "🀇", "2m": "🀈", "3m": "🀉", "4m": "🀊", "5m": "🀋",
        "5mr": "🀋", "6m": "🀌", "7m": "🀍", "8m": "🀎", "9m": "🀏",
        "1p": "🀙", "2p": "🀚", "3p": "🀛", "4p": "🀜", "5p": "🀝",
        "5pr": "🀝", "6p": "🀞", "7p": "🀟", "8p": "🀠", "9p": "🀡",
        "1s": "🀐", "2s": "🀑", "3s": "🀒", "4s": "🀓", "5s": "🀔",
        "5sr": "🀔", "6s": "🀕", "7s": "🀖", "8s": "🀗", "9s": "🀘",
        "E": "🀀", "S": "🀁", "W": "🀂", "N": "🀃",
        "P": "🀆", "F": "🀅", "C": "🀄︎",
        "?": "🀫"
    ]
}
