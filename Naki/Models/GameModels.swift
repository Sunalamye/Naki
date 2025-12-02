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

    // MARK: - Available Actions

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

    // MARK: - Computed Properties

    /// 模型顯示名稱
    var modelDisplayName: String {
        switch modelName {
        case "mortal": return "Mortal (4P)"
        case "mortal3p": return "Mortal (3P)"
        default: return modelName
        }
    }

    /// 是否有任何可用動作
    var hasAvailableAction: Bool {
        canDiscard || canRiichi || canChi || canPon || canKan || canAgari
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

    /// 動作類型
    enum ActionType: String, CaseIterable {
        case discard = "discard"
        case riichi = "riichi"
        case chi = "chi"
        case pon = "pon"
        case kan = "kan"
        case hora = "hora"
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
            case .none: return "過"
            case .unknown: return "?"
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
            case .none: return .gray
            case .unknown: return .secondary
            }
        }
    }

    // MARK: - Initializers

    /// 強類型初始化（打牌）
    init(tile: Tile, probability: Double) {
        self.tile = tile
        self.label = tile.mjaiString
        self.probability = probability
        self.actionType = .discard
    }

    /// 強類型初始化（非打牌動作）
    init(actionType: ActionType, probability: Double, label: String = "") {
        self.tile = nil
        self.label = label.isEmpty ? actionType.rawValue : label
        self.probability = probability
        self.actionType = actionType
    }

    /// 從 MJAI 字串初始化（保持兼容性）
    init(tile tileString: String, probability: Double, actionType: ActionType) {
        if actionType == .discard, let t = Tile(mjaiString: tileString) {
            self.tile = t
        } else {
            self.tile = nil
        }
        self.label = tileString
        self.probability = probability
        self.actionType = actionType
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

// MARK: - Tile Unicode Extension

extension Tile {
    /// 牌的 Unicode 表示
    var unicode: String {
        switch self {
        case .man(let n, let red):
            if red { return "🀋" } // 紅5萬特別處理
            let base = 0x1F007 + (n - 1)
            return String(UnicodeScalar(base)!)
        case .pin(let n, let red):
            if red { return "🀝" }
            let base = 0x1F019 + (n - 1)
            return String(UnicodeScalar(base)!)
        case .sou(let n, let red):
            if red { return "🀔" }
            let base = 0x1F010 + (n - 1)
            return String(UnicodeScalar(base)!)
        case .east: return "🀀"
        case .south: return "🀁"
        case .west: return "🀂"
        case .north: return "🀃"
        case .white: return "🀆"
        case .green: return "🀅"
        case .red: return "🀄"
        case .unknown: return "🀫"
        }
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
