//
//  MatchModeTable.swift
//  Naki
//
//  段位場的房間門檻表：哪個 mode id 對應哪個房間、需要什麼段位。
//
//  ## 為什麼敢在這裡放一張表（`ObservedMatchModes` 明明說對照表會錯）
//
//  差別在來源與用途：
//
//  - **來源是雀魂自己的 config**，不是觀察猜測。2026-08-09 從 live
//    `https://game.maj-soul.com/1/v0.11.252.w/res/config/lqc.lqbin`
//    （SHA-256 `a5959513fa31d3b5297d2dda400c86c0eacbdb4adad461b583439d7f673c9086`）
//    的 `desktop.matchmode` sheet 解出，只取 `type == 1`（段位場）那 25 筆。
//    舊的那張錯表是 Laya 時代**觀察**出來的，整組偏移一格。
//
//  - **用途只有「挑一個候選 id」**，不是「宣稱這個 id 一定對」。真正的授權在伺服器：
//    id 不存在回 error 1306、`match_sid` 不合法回 1303，兩個都是安全失敗（沒排進去）。
//    表過期最壞的情況是被拒絕，不是靜默排進錯的場次。
//
//  - **已觀察過的 sid 優先**。這張表只在「使用者沒點過那個房間」時提供候選，
//    而候選送出後仍由 `ObservedMatchSids.gameDidStart` 用**實際開出來的對局**回填確認。
//
//  失效條件：雀魂改版動到 `desktop.matchmode` 的 id 或段位門檻。徵兆是續局開始
//  連續回 1303/1306，或回填的人數與預期不符。重新解一次 `lqc.lqbin` 即可。
//

import Foundation

/// 段位場的一個入口（`desktop.matchmode` 的一列）
nonisolated struct MatchModeEntry: Equatable {
    /// `desktop.matchmode.id`，也就是 `match_sid` 冒號後面那個數字
    let id: Int
    /// 房間名（繁中，取自 `room_name_chs_t`）
    let roomName: String
    /// `mode` 欄：1=四人東 2=四人南 11=三人東 12=三人南（0=一局戰，不收進表）
    let mode: Int
    /// 可進入的段位區間（`level_limit` ～ `level_limit_ceil`，含兩端）
    let levelMin: Int
    let levelMax: Int

    /// 三麻的 mode 是 11／12
    var is3P: Bool { mode >= 11 }

    /// 東風戰（1／11）還是半莊（2／12）
    var isEast: Bool { mode == 1 || mode == 11 }

    var displayName: String {
        "\(roomName)・\(is3P ? "三人" : "四人")\(isEast ? "東" : "南")"
    }
}

/// 續局要挑「能進的最低房」還是「最高房」
nonisolated enum RoomPreference: String, CaseIterable, Sendable {
    /// 能進的最低房（穩，對手弱，掉段風險低）
    case lowest
    /// 能進的最高房（點數效率高，但打不好會掉段）
    case highest

    var label: String {
        switch self {
        case .lowest: return "最低"
        case .highest: return "最高"
        }
    }
}

/// 段位場房間表
nonisolated enum MatchModeTable {

    /// 解表日期，跟著 `lqc.lqbin` 版本走
    static let sourceVersion = "v0.11.252.w (2026-08-09)"

    /// `type == 1` 的段位場入口。一局戰（mode 0）不收：它不是續局要排的東西。
    static let entries: [MatchModeEntry] = [
        // ── 四麻 ────────────────────────────────────────────
        .init(id: 2,  roomName: "銅之間", mode: 1,  levelMin: 10101, levelMax: 10203),
        .init(id: 3,  roomName: "銅之間", mode: 2,  levelMin: 10101, levelMax: 10203),
        .init(id: 5,  roomName: "銀之間", mode: 1,  levelMin: 10201, levelMax: 10303),
        .init(id: 6,  roomName: "銀之間", mode: 2,  levelMin: 10201, levelMax: 10303),
        .init(id: 8,  roomName: "金之間", mode: 1,  levelMin: 10301, levelMax: 10403),
        .init(id: 9,  roomName: "金之間", mode: 2,  levelMin: 10301, levelMax: 10403),
        .init(id: 11, roomName: "玉之間", mode: 1,  levelMin: 10401, levelMax: 10503),
        .init(id: 12, roomName: "玉之間", mode: 2,  levelMin: 10401, levelMax: 10503),
        .init(id: 15, roomName: "王座間", mode: 1,  levelMin: 10501, levelMax: 10720),
        .init(id: 16, roomName: "王座間", mode: 2,  levelMin: 10501, levelMax: 10720),
        // ── 三麻 ────────────────────────────────────────────
        .init(id: 17, roomName: "銅之間", mode: 11, levelMin: 20101, levelMax: 20203),
        .init(id: 18, roomName: "銅之間", mode: 12, levelMin: 20101, levelMax: 20203),
        .init(id: 19, roomName: "銀之間", mode: 11, levelMin: 20201, levelMax: 20303),
        .init(id: 20, roomName: "銀之間", mode: 12, levelMin: 20201, levelMax: 20303),
        .init(id: 21, roomName: "金之間", mode: 11, levelMin: 20301, levelMax: 20403),
        .init(id: 22, roomName: "金之間", mode: 12, levelMin: 20301, levelMax: 20403),
        .init(id: 23, roomName: "玉之間", mode: 11, levelMin: 20401, levelMax: 20503),
        .init(id: 24, roomName: "玉之間", mode: 12, levelMin: 20401, levelMax: 20503),
        .init(id: 25, roomName: "王座間", mode: 11, levelMin: 20501, levelMax: 20720),
        .init(id: 26, roomName: "王座間", mode: 12, levelMin: 20501, levelMax: 20720)
    ]

    /// 這個段位能進哪些入口。
    ///
    /// - Parameters:
    ///   - level: 帳號段位 id（四麻讀 `ResAccountInfo` 的 level，三麻讀 level3）
    ///   - sanma: 要三麻的入口嗎
    ///   - east: 東風戰（true）還是半莊（false）
    static func eligible(level: Int, sanma: Bool, east: Bool) -> [MatchModeEntry] {
        entries.filter {
            $0.is3P == sanma
                && $0.isEast == east
                && level >= $0.levelMin
                && level <= $0.levelMax
        }
    }

    /// 依偏好挑一個入口；段位進不了任何房間時回 nil（不硬塞）。
    ///
    /// 排序鍵用 `levelMin`：門檻越高的房間越「高級」。用 id 排會在三麻段落錯位。
    static func pick(level: Int,
                     sanma: Bool,
                     east: Bool,
                     preference: RoomPreference) -> MatchModeEntry? {
        let candidates = eligible(level: level, sanma: sanma, east: east)
        switch preference {
        case .lowest:  return candidates.min(by: { $0.levelMin < $1.levelMin })
        case .highest: return candidates.max(by: { $0.levelMin < $1.levelMin })
        }
    }

    /// 已知的 id → 入口
    static func entry(id: Int) -> MatchModeEntry? {
        entries.first { $0.id == id }
    }
}

// MARK: - match_sid 組裝

/// `match_sid` 的形狀：`"{match_group}:{mode_id}"`
///
/// 2026-08-09 實測：使用者在畫面上點銅之間四人東，客戶端送出的是 `"1:2"`，
/// 而 `desktop.matchmode` 裡銅之間四人東的 id 正是 2、`match_group` 是 1。
///
/// **group 不寫死**：從實際觀察到的 sid 拆出來用。段位場目前全部是 group 1，
/// 但那是觀察結果不是保證，改版動到它時沿用觀察值才不會整組失效。
nonisolated enum MatchSid {

    /// 從觀察到的 sid 取出 group（`"1:2"` → `1`）
    static func group(of sid: String) -> String? {
        let parts = sid.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return String(parts[0])
    }

    /// 從觀察到的 sid 取出 mode id（`"1:2"` → `2`）
    static func modeId(of sid: String) -> Int? {
        let parts = sid.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }

    /// 用觀察到的 group 組一個新 sid
    static func make(group: String, modeId: Int) -> String {
        "\(group):\(modeId)"
    }
}

// MARK: - 續局目標決策

/// 「這次續局要送哪個 match_sid」的決策結果
nonisolated struct RematchTarget: Equatable {
    let sid: String
    let clientVersionString: String
    /// 對應的房間（用表推導出來時才有；純觀察沿用時可能是 nil）
    let entry: MatchModeEntry?
    /// sid 是否來自「實際觀察過且人數已確認」的紀錄。
    ///
    /// `false`＝用表推導的候選：形狀對、房間應該對，但這一組還沒被伺服器接受過。
    /// 呼叫端要把它寫進 log，別讓推論看起來像事實。
    let verified: Bool
}

/// 依段位與偏好決定續局目標。
///
/// 順序刻意是「先看觀察、再用表」：
/// 1. 目標房間**已經觀察過而且人數確認過** → 直接用那組 sid（最可靠）
/// 2. 目標房間沒觀察過 → 用任一觀察過的 sid 拆出 group，配上表裡的 id 組候選
/// 3. 一次都沒觀察過 → nil（沒有 group 可用，猜不出來）
nonisolated enum RematchTargetResolver {

    static func resolve(level: Int?,
                        sanma: Bool,
                        east: Bool,
                        preference: RoomPreference,
                        observations: [ObservedMatchSids.Observation]) -> RematchTarget? {
        // 這個人數的、已確認的觀察（最可靠的來源）
        let confirmed = observations.filter { $0.is3P == sanma }

        // 段位不明時退回「沿用上次打的那個房間」——不猜房間，但也不至於停擺
        guard let level, let target = MatchModeTable.pick(
            level: level, sanma: sanma, east: east, preference: preference) else {
            guard let fallback = confirmed.max(by: { $0.seenAt < $1.seenAt }) else { return nil }
            return RematchTarget(sid: fallback.sid,
                                 clientVersionString: fallback.clientVersionString,
                                 entry: MatchSid.modeId(of: fallback.sid)
                                     .flatMap(MatchModeTable.entry(id:)),
                                 verified: true)
        }

        // ① 目標房間本身觀察過
        if let exact = confirmed
            .filter({ MatchSid.modeId(of: $0.sid) == target.id })
            .max(by: { $0.seenAt < $1.seenAt }) {
            return RematchTarget(sid: exact.sid,
                                 clientVersionString: exact.clientVersionString,
                                 entry: target,
                                 verified: true)
        }

        // ② 借用任一觀察過的 sid 的 group（含人數不同的：group 是段位場共用的）
        guard let anyObserved = observations.max(by: { $0.seenAt < $1.seenAt }),
              let group = MatchSid.group(of: anyObserved.sid) else { return nil }

        return RematchTarget(sid: MatchSid.make(group: group, modeId: target.id),
                             clientVersionString: anyObserved.clientVersionString,
                             entry: target,
                             verified: false)
    }
}

// MARK: - 帳號段位

/// 從 `.lq.Lobby.fetchAccountInfo` 的 RESPONSE 取段位。
///
/// 2026-08-09 實測欄位（`ResAccountInfo.account` = field 2 的內層）：
///
/// ```text
/// field 21 → { 1: 10201, 2: 550 }   四麻段位（雀士1）與分數
/// field 22 → { 1: 20102, 2: 0 }     三麻段位（初心2）與分數
/// ```
///
/// 欄位編號取自實際封包而不是 `liqi.json`——那份 descriptor 已過期（見 CLAUDE.md）。
/// 解不出來就回 `nil`，呼叫端一律 fail-closed，不要用 0 當預設（0 會比對成
/// 「什麼房間都進不去」還是「初心」都說不準）。
nonisolated enum AccountLevelParser {

    /// `ResAccountInfo` 內層 account 訊息裡的段位欄位
    private static let yonmaField = 21
    private static let sanmaField = 22

    /// - Parameter accountPayload: RESPONSE 的 `field2`（account 訊息本體）
    /// - Returns: (四麻段位 id, 三麻段位 id)；解不到的那個是 nil
    static func levels(from accountPayload: Data) -> (yonma: Int?, sanma: Int?) {
        var yonma: Int?
        var sanma: Int?
        for block in parseProtobufBlocks(accountPayload) where block.wireType == 2 {
            guard block.fieldId == yonmaField || block.fieldId == sanmaField else { continue }
            // 內層 { id = 1, score = 2 }，只要 id
            guard let idBlock = parseProtobufBlocks(block.data)
                .first(where: { $0.fieldId == 1 && $0.wireType == 0 }),
                  let id = parseVarint(idBlock.data, offset: 0)?.value else { continue }
            if block.fieldId == yonmaField { yonma = id } else { sanma = id }
        }
        return (yonma, sanma)
    }

    /// base64 版本（`LiqiResponseRecord.fields` 裡的值就是 base64 字串）
    static func levels(fromBase64 base64: String) -> (yonma: Int?, sanma: Int?) {
        guard let data = Data(base64Encoded: base64) else { return (nil, nil) }
        return levels(from: data)
    }
}
