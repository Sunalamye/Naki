//
//  LiqiTile.swift
//  Naki
//
//  牌的表示法：雀魂 ⇄ MJAI 的轉換，以及 MJAI 的排序。
//
//  ## p4-2：轉換與排序各只剩一份
//
//  以前牌碼轉換有兩份（`MajsoulBridge.MS_TILE_TO_MJAI` 這張 37 項字典 +
//  `LiqiTileCode` 的規則式轉換），排序表另外硬編在 `MajsoulBridge.comparePai`。
//  兩份轉換規則沒有任何測試證明它們一致——`MS_TILE_TO_MJAI` 是查表（漏一個 key
//  就回 nil），`LiqiTileCode` 是規則（多接受了幾種寫法），差異只會在真的遇到
//  邊界牌碼時才暴露，而那時看到的症狀是「某張牌的推薦沒出現」。
//
//  現在只有本檔知道牌長什麼樣。
//
//  ## 兩套表示法
//
//  - 雀魂：`1m`–`9m` / `1p`–`9p` / `1s`–`9s`、`0m`/`0p`/`0s` = 紅五、`1z`–`7z` = 字牌
//  - MJAI：`1m`–`9m` / …、`5mr`/`5pr`/`5sr` = 紅五、`E/S/W/N/P/F/C` = 字牌
//
//  ⚠️ 不在這裡的是 **Mortal 動作索引**（`NativeBotController.tileToDiscardActionIndex`）。
//  那是模型輸出空間的佈局（0–33 普通牌 + 34–36 紅五打牌），不是牌的排序：
//  紅五在動作空間裡是**另外三個獨立動作**，在 `mjaiOrder` 裡則排在同數字普通牌之前。
//  兩者形狀不同、來源不同（一個來自 MortalSwift 的 mask，一個是顯示順序），
//  硬併成一張表只會製造一個「看起來共用、其實兩邊都要各自維護」的假共用點。
//

import Foundation

// MARK: - Tile

/// 牌碼轉換與排序（純函式，無狀態）
///
/// `nonisolated`：呼叫端橫跨 MainActor（`MajsoulBridge`）與非隔離的腳本組裝
/// （`GameHighlightScript.make`），純查表不需要任何隔離。
nonisolated enum LiqiTile {

    // MARK: 字牌對照

    /// 字牌（雀魂 → MJAI）
    private static let honorToMJAI: [String: String] = [
        "1z": "E", "2z": "S", "3z": "W", "4z": "N",
        "5z": "P", "6z": "F", "7z": "C"
    ]

    /// 字牌（MJAI → 雀魂）
    private static let honorToMajsoul: [String: String] = [
        "E": "1z", "S": "2z", "W": "3z", "N": "4z",
        "P": "5z", "F": "6z", "C": "7z"
    ]

    // MARK: 轉換

    /// MJAI → 雀魂（`5mr` → `0m`、`E` → `1z`）；無法辨識回 nil
    static func majsoul(fromMJAI mjai: String) -> String? {
        if let honor = honorToMajsoul[mjai] { return honor }

        let chars = Array(mjai)
        guard chars.count == 2 || chars.count == 3 else { return nil }
        guard let number = Int(String(chars[0])), (1...9).contains(number) else { return nil }
        let suit = chars[1]
        guard suit == "m" || suit == "p" || suit == "s" else { return nil }

        if chars.count == 3 {
            // 紅五：MJAI `5mr` → 雀魂 `0m`
            guard chars[2] == "r", number == 5 else { return nil }
            return "0\(suit)"
        }
        return "\(number)\(suit)"
    }

    /// 雀魂 → MJAI（`0m` → `5mr`、`1z` → `E`）；無法辨識回 nil
    static func mjai(fromMajsoul tile: String) -> String? {
        if let honor = honorToMJAI[tile] { return honor }

        let chars = Array(tile)
        guard chars.count == 2, let number = Int(String(chars[0])) else { return nil }
        let suit = chars[1]
        guard suit == "m" || suit == "p" || suit == "s" else { return nil }
        return number == 0 ? "5\(suit)r" : "\(number)\(suit)"
    }

    // MARK: 排序

    /// MJAI 牌序（手牌顯示與送進 Bot 前的排序用）。
    ///
    /// 紅五排在同數字普通牌**之前**（`5mr` 在 `5m` 前），字牌在最後，
    /// `?`（未知牌，`MajsoulBridge` 解不出牌時的佔位）排在所有已知牌之後。
    static let mjaiOrder: [String] = [
        "1m", "2m", "3m", "4m", "5mr", "5m", "6m", "7m", "8m", "9m",
        "1p", "2p", "3p", "4p", "5pr", "5p", "6p", "7p", "8p", "9p",
        "1s", "2s", "3s", "4s", "5sr", "5s", "6s", "7s", "8s", "9s",
        "E", "S", "W", "N", "P", "F", "C", "?"
    ]

    /// `mjaiOrder` 的反查表（原本每次比較都跑 `firstIndex(of:)`，排 13 張手牌是 O(n·38·log n)）
    private static let mjaiOrderIndex: [String: Int] = {
        var index: [String: Int] = [:]
        for (i, tile) in mjaiOrder.enumerated() { index[tile] = i }
        return index
    }()

    /// 兩張 MJAI 牌的先後（不在表內的一律排到最後）
    static func compare(_ a: String, _ b: String) -> Bool {
        (mjaiOrderIndex[a] ?? mjaiOrder.count) < (mjaiOrderIndex[b] ?? mjaiOrder.count)
    }

    /// 依 `mjaiOrder` 排序
    static func sorted(_ tiles: [String]) -> [String] {
        tiles.sorted(by: compare)
    }
}
