//
//  LiqiParseFault.swift
//  Naki
//
//  解析失敗顯式化。
//
//  失敗一旦被偽裝成正常資料，症狀就不會出現在解析層。三種典型手法：
//
//  1. **預設值**：`parsePackedInt32` 解不出 4 個合理分數就回
//     `[25000, 25000, 25000, 25000]`——呼叫端無法分辨「真的是起手分」與
//     「這段 bytes 根本解不開」，Bot 於是拿假點數做決策。
//  2. **拿別的欄位頂替**：`parseActionPrototype` 找不到 field 3 時，
//     把任何一個 wireType 2 的 block 當成 action data。schema 一變就靜默解錯。
//  3. **只 log 不上報**：authGame 回應沒有 seatList 時只寫一行 log，
//     `start_game` 不發、整局靜默不工作，畫面上完全看不出來。
//
//  這份檔案提供失敗的**顯式型別**與**唯一的狀態去處**：
//  解析點（site）、liqi.json 的欄位編號、bytes 長度、原因、以及嚴重度。
//  嚴重度由呼叫端（`MajsoulBridge`）決定，不是由解析器決定——
//  同一個欄位解不開，在不同訊息裡的後果完全不同。
//

import Foundation

// MARK: - 解析信心

/// 這個值是「照 schema 解出來的」還是「猜出來的」。
///
/// 猜出來的東西不是不能用，但**必須看得見**：`LiqiParser` 會把它寫進解析結果，
/// 呼叫端可以據此降級處理，log 也查得到。沒有第三種狀態——
/// 「不知道是不是猜的」正是這個型別要消掉的東西。
nonisolated enum LiqiParseConfidence: String, Sendable {
    /// 照 `docs/protocol/liqi.json` 的欄位編號與型別解出來的
    case exact
    /// 靠備用推斷得到的（欄位缺失時的替代來源），可能是錯的
    case heuristic
}

// MARK: - 解析失敗

/// 一次解析失敗的完整上下文。
///
/// 有了 site／fieldId／byteCount，log 裡看到的不再是「解析失敗」四個字，
/// 而是「`ActionNewRound.scores` field 6 / 9 bytes：packed int32 解不出來」——
/// 可以直接拿 fieldId 去對 `docs/protocol/liqi.json`。
nonisolated struct LiqiParseFault: Sendable, Equatable {

    /// 後果嚴重度。**由呼叫端判定**：解析器只知道「這段 bytes 解不開」，
    /// 只有呼叫端知道少了這個欄位會不會讓整局不工作。
    nonisolated enum Severity: String, Sendable {
        /// 這一局不會正常運作（例如拿不到座位、開不出 start_kyoku）→ UI 常駐錯誤
        case blocking
        /// 單一欄位解不開，其餘照常（例如某個未知欄位）→ 記錄可查即可
        case degraded
    }

    /// 解析點：`<訊息>.<欄位>`，例如 `ResAuthGame.seat_list`
    let site: String
    /// `docs/protocol/liqi.json` 裡的欄位編號；不對應單一欄位時為 nil
    let fieldId: Int?
    /// 解析時看到的 bytes 長度（0 代表欄位整個不存在）
    let byteCount: Int
    /// 為什麼失敗（人看的）
    let reason: String
    /// 後果嚴重度
    let severity: Severity

    init(site: String,
         fieldId: Int? = nil,
         byteCount: Int,
         reason: String,
         severity: Severity = .degraded) {
        self.site = site
        self.fieldId = fieldId
        self.byteCount = byteCount
        self.reason = reason
        self.severity = severity
    }

    /// 單行敘述（log 與 UI 橫幅共用）
    var text: String {
        var head = site
        if let fieldId { head += " field \(fieldId)" }
        head += "（\(byteCount) bytes）"
        return "\(head)：\(reason)"
    }

    /// `/status`／`get_status` 用的機械可判讀欄位
    var payload: [String: Any] {
        var dict: [String: Any] = [
            "site": site,
            "bytes": byteCount,
            "reason": reason,
            "severity": severity.rawValue
        ]
        if let fieldId { dict["field"] = fieldId }
        return dict
    }
}

// MARK: - 解析失敗狀態

/// 解析失敗的唯一真相來源（UI 橫幅、`/status`、`get_status` 都讀它）。
///
/// `@Observable`：blocking 失敗要立刻掛出紅色橫幅，而不是等下一次狀態更新——
/// 這與 `JSInjectionState` 是同一個理由與同一個做法。
///
/// 為什麼 blocking 要常駐而不是寫進 `statusMessage`：`statusMessage` 會被載入、
/// 連線、Bot 建立等事件一路覆蓋，錯誤看一眼就沒了；而「這局的座位解不出來」
/// 是不會自己好的狀態，在它被清掉之前，側欄推薦與 `/game/*` 全部不可信。
@Observable
final class LiqiParseFaultState {

    /// 正式路徑共用的那一份
    static let shared = LiqiParseFaultState()

    /// 保留幾筆近期失敗（只給診斷看，不影響行為）
    static let historyLimit = 20

    /// MainActor class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit { }

    /// 各前提 domain 目前未解決的 blocking 失敗。
    ///
    /// 不同前提是各自獨立的：`ResAuthGame.seat_list`（座位／start_game／Bot 沒建）與
    /// `ActionNewRound.scores`（分數／start_kyoku）是兩回事。用單一 slot 時，A 失敗後
    /// B 也失敗會蓋掉 A，之後 B 恢復把 slot 清空，但 A 的前提從未恢復——橫幅消失卻
    /// Bot 仍不存在。改成按 domain keyed，每個前提各留一格，只有對應前提恢復才移除它。
    private(set) var blockingByDomain: [String: LiqiParseFault] = [:]

    /// domain 顯示優先序：authGame（Bot 沒建）最根本，排最前。
    private static let domainPriority = ["authGame", "round"]

    /// 由 site 推出前提 domain。
    private static func domain(for site: String) -> String {
        if site.hasPrefix("ResAuthGame") { return "authGame" }
        if site.hasPrefix("ActionNewRound") || site.hasPrefix("GameSnapshot") { return "round" }
        return site
    }

    /// 目前那個「這局不會運作」的失敗（多個前提時取優先序最高的）；nil = 沒有
    var blocking: LiqiParseFault? {
        for domain in Self.domainPriority {
            if let fault = blockingByDomain[domain] { return fault }
        }
        // 其餘 domain 取 site 字典序最小的，保證決定性（不用 dict.values.first）
        return blockingByDomain
            .filter { !Self.domainPriority.contains($0.key) }
            .min { $0.key < $1.key }?.value
    }

    /// 近期失敗（新的在後），最多 `historyLimit` 筆
    private(set) var recent: [LiqiParseFault] = []

    /// 累計看到幾筆（recent 會被截斷，這個不會）
    private(set) var totalCount = 0

    /// UI 橫幅要顯示的文字；沒有 blocking 失敗時為 nil
    var bannerSummary: String? { blocking?.text }

    /// 記一筆失敗
    func record(_ fault: LiqiParseFault) {
        totalCount += 1
        recent.append(fault)
        if recent.count > Self.historyLimit {
            recent.removeFirst(recent.count - Self.historyLimit)
        }
        if fault.severity == .blocking {
            blockingByDomain[Self.domain(for: fault.site)] = fault
        }
    }

    /// 只清「由指定前提失敗造成」的 blocking。
    ///
    /// 恢復某個里程碑時，只移除 site 屬於這個里程碑的 domain。若 authGame 失敗
    /// （座位缺、Bot 沒建）留下 blocking，一個 scores 合法的 `ActionNewRound` 只清
    /// round domain，不會清掉 authGame domain——橫幅正確保留（Bot 仍不存在）。
    func clearBlocking(matchingSitePrefixes prefixes: [String]) {
        blockingByDomain = blockingByDomain.filter { _, fault in
            !prefixes.contains(where: { fault.site.hasPrefix($0) })
        }
    }

    /// 全部歸零（頁面重新載入、測試）
    func reset() {
        blockingByDomain.removeAll()
        recent = []
        totalCount = 0
    }

    /// `get_status`／`GET /status` 用的欄位
    var statusPayload: [String: Any] {
        var payload: [String: Any] = [
            "liqiParseFaultTotal": totalCount,
            "liqiParseBlocked": blocking != nil
        ]
        if let blocking {
            payload["liqiParseBlockingFault"] = blocking.payload
            payload["liqiParseNote"] =
                "Liqi 封包有欄位解不開，且該欄位是這一局能不能運作的前提。"
                + "在這個狀態下 game_* / bot_* 的內容不完整，不要拿它當現況。"
        }
        if !recent.isEmpty {
            payload["liqiParseFaults"] = recent.map(\.payload)
        }
        return payload
    }
}
