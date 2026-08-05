//
//  LiqiOperationStore.swift
//  Naki
//
//  雀魂「可用操作」（OptionalOperationList）的協定層快照。
//
//  背景：Unity WebGL 客戶端沒有 `window.view.DesktopMgr.Inst.oplist`，
//  舊的 JS 讀取路徑已死。但同樣的資訊本來就在 notify 裡：
//
//      OptionalOperationList { seat=1, operation_list=2, time_add=4, time_fixed=5 }
//      OptionalOperation     { type=1, combination=2, change_tiles=3,
//                              change_tile_states=4, gap_type=5 }
//
//  `LiqiParser.parseOperation` 已經把它解成字典（key: seat / operationList /
//  timeAdd / timeFixed），`MajsoulBridge` 解析每個 ActionPrototype 時把最近一次
//  存進本檔的 `LiqiOperationStore.shared`，供
//  `AutoPlayEngine` → `AutoPlayGate` / `AutoPlayDecisionResolver` → `LiqiActionSender`
//  這條決策鏈判斷「現在到底能做什麼」。
//
//  驗收語彙（2026-08-01）：
//  - 欄位編號取自 docs/protocol/liqi.json；repo snapshot 與當日 live CDN byte-identical。
//  - runtime 已對到 discard(1)、pon(3)、riichi(7)、tsumo request(8)、ron(9)。
//  - chi variant／赤五 combination、三種槓、九種九牌與拔北仍需真實對局驗證。
//

import Foundation

// MARK: - 操作類型

/// 雀魂 `OptionalOperation.type` 的數值語意。
///
/// `liqi.json` 只把 `type` 定義為 `uint32`，沒有 enum；因此每個值仍需 runtime 證據。
/// 已有證據與未驗項目見檔頭，不能把已驗 subset 外推到整張表。
nonisolated enum LiqiOperationType: UInt32, CaseIterable {
    /// 無操作
    case none = 0
    /// 打牌（dapai）
    case discard = 1
    /// 吃
    case chi = 2
    /// 碰
    case pon = 3
    /// 暗槓
    case ankan = 4
    /// 大明槓（他家打牌後槓）
    case minkan = 5
    /// 加槓（碰後補槓）
    case kakan = 6
    /// 立直
    case riichi = 7
    /// 自摸和
    case tsumo = 8
    /// 榮和
    case ron = 9
    /// 九種九牌
    case kyushu = 10
    /// 拔北（三麻）
    case babei = 11

    /// 該操作要送去哪一個 FastTest 方法。
    ///
    /// 現行 channel：
    /// - 吃 / 碰 / 大明槓：回應**他家**打出的牌 → `inputChiPengGang`
    /// - 其餘（打牌、立直、暗槓、加槓、自摸、榮和、九種九牌、拔北）→ `inputOperation`
    ///
    /// runtime 已驗證 ron(9) 走 `inputOperation` 並收到 RESPONSE／ActionHule；pon(3)
    /// 走 `inputChiPengGang`。chi／minkan 與三種槓仍需各別驗證。
    ///
    /// ⚠️ 榮和刻意**不**歸在 `.chiPengGang`，儘管 `isCallOpportunity` 把它算成副露機會：
    /// 它是回應他家打牌沒錯，但送出走 `inputOperation`。所以要決定 pass 的通道時，
    /// 必須從快照裡實際那個機會操作的 `channel` 取值（`AutoPlayEngine.sendPass` 即如此），
    /// 不能因為「這是副露機會」就假設 `.chiPengGang`。
    var channel: LiqiActionChannel {
        switch self {
        case .chi, .pon, .minkan:
            return .chiPengGang
        default:
            return .selfOperation
        }
    }

    /// 是否屬於「回應他家打牌」的機會（用來決定 pass 要送哪個方法）。
    ///
    /// ⚠️ 榮和刻意算在內：它確實是他家打牌後的回應窗口，沒人回應對局會停到伺服器代打。
    /// 代價是「沒有推薦 → 送過」那條路徑會把和牌送成棄和——這曾經是漏和的成因，
    /// 所以 `AutoPlayGate` 必須先檢查 `horaOperation` 才准走 pass。
    /// 與 `channel` 對榮和的分類刻意不對稱（那裡是 `.selfOperation`），改任一邊都要同時看另一邊。
    var isCallOpportunity: Bool {
        switch self {
        case .chi, .pon, .minkan, .ron:
            return true
        default:
            return false
        }
    }
}

/// 動作送出的服務方法
nonisolated enum LiqiActionChannel {
    /// `.lq.FastTest.inputOperation`（ReqSelfOperation）
    case selfOperation
    /// `.lq.FastTest.inputChiPengGang`（ReqChiPengGang）
    case chiPengGang

    /// Liqi 方法全名（格式實測自 `.lq.Route.heartbeat`）
    var method: String {
        switch self {
        case .selfOperation: return ".lq.FastTest.inputOperation"
        case .chiPengGang: return ".lq.FastTest.inputChiPengGang"
        }
    }
}

// MARK: - 單一操作

/// 一筆 `OptionalOperation`
nonisolated struct LiqiOperation: Equatable {
    /// 原始 type 值（保留未知值，不硬塞進 enum）
    let rawType: UInt32
    /// 可用組合（雀魂牌字串，例如 `["4m|5m", "3m|4m"]`；吃/碰/槓才有）
    let combination: [String]

    /// 已知語意（未知 type 回 nil）
    var type: LiqiOperationType? { LiqiOperationType(rawValue: rawType) }

    init(rawType: UInt32, combination: [String] = []) {
        self.rawType = rawType
        self.combination = combination
    }

    init(type: LiqiOperationType, combination: [String] = []) {
        self.rawType = type.rawValue
        self.combination = combination
    }
}

// MARK: - 操作快照

/// 最近一次收到的「可用操作」快照
nonisolated struct LiqiOperationSnapshot: Equatable {
    /// 單調遞增序號（用來標記「這批操作已處理過」，避免重送）
    let sequence: UInt64
    /// 可操作的座位（伺服器只會推播給我們自己，理論上等於自家座位）
    let seat: Int
    /// 可用操作清單
    let operations: [LiqiOperation]
    /// 加時秒數
    let timeAdd: UInt32
    /// 固定思考秒數
    let timeFixed: UInt32
    /// 觸發這批操作的牌（他家打出的牌 / 自己摸到的牌，雀魂格式）
    let contextTile: String?
    /// 來源動作名稱（ActionDealTile / ActionDiscardTile …），純診斷用
    let source: String
    /// 擷取時間
    let capturedAt: Date

    /// 所有原始 type 值（log 用）
    var rawTypes: [UInt32] { operations.map(\.rawType) }

    /// 是否含指定操作
    func contains(_ type: LiqiOperationType) -> Bool {
        operations.contains { $0.rawType == type.rawValue }
    }

    /// 取出指定操作
    func operation(of type: LiqiOperationType) -> LiqiOperation? {
        operations.first { $0.rawType == type.rawValue }
    }

    /// 這批操作是否為「回應他家打牌」（決定 pass 要送 inputChiPengGang 還是 inputOperation）
    var isCallOpportunity: Bool {
        operations.contains { $0.type?.isCallOpportunity == true }
    }

    /// 第一個可用的和牌操作（自摸優先於榮和；都沒有回 nil）
    var horaOperation: LiqiOperationType? {
        if contains(.tsumo) { return .tsumo }
        if contains(.ron) { return .ron }
        return nil
    }

    /// 第一個可用的槓操作（暗槓 → 加槓 → 大明槓）
    var kanOperation: LiqiOperationType? {
        for candidate in [LiqiOperationType.ankan, .kakan, .minkan] where contains(candidate) {
            return candidate
        }
        return nil
    }

    /// 依 Mortal 的吃法變體挑出雀魂 `combination` 的索引。
    ///
    /// Mortal 的 `chi_low` / `chi_mid` / `chi_high` 指的是**被吃的那張牌**在順子中的位置：
    /// - `chi_low`(0)：被吃的牌最小 → 手上兩張都比它大（例：吃 3m，consumed = 4m,5m）
    /// - `chi_mid`(1)：被吃的牌在中間（例：吃 3m，consumed = 2m,4m）
    /// - `chi_high`(2)：被吃的牌最大 → 手上兩張都比它小（例：吃 3m，consumed = 1m,2m）
    ///
    /// ⚠️ **未驗證**：Mortal 變體命名與此對應關係為推導，未以真實對局比對。
    /// 找不到對應組合時回 nil，呼叫端可自行退回保守索引。
    func chiCombinationIndex(variant: Int) -> Int? {
        guard let chi = operation(of: .chi), !chi.combination.isEmpty else { return nil }
        guard let called = LiqiOperationSnapshot.tileNumber(contextTile) else { return nil }

        for (index, combo) in chi.combination.enumerated() {
            let numbers = combo.split(separator: "|").compactMap {
                LiqiOperationSnapshot.tileNumber(String($0))
            }
            guard numbers.count == 2 else { continue }

            let below = numbers.filter { $0 < called }.count
            let above = numbers.filter { $0 > called }.count

            let comboVariant: Int
            if above == 2 { comboVariant = 0 }
            else if below == 2 { comboVariant = 2 }
            else if below == 1 && above == 1 { comboVariant = 1 }
            else { continue }

            if comboVariant == variant { return index }
        }
        return nil
    }

    /// 給 MCP 工具輸出用的字典（取代已死的 `DesktopMgr.Inst.oplist` 探測）
    var dictionary: [String: Any] {
        [
            "sequence": Int(sequence),
            "seat": seat,
            "timeAdd": Int(timeAdd),
            "timeFixed": Int(timeFixed),
            "contextTile": contextTile ?? NSNull(),
            "source": source,
            "capturedAt": ISO8601DateFormatter().string(from: capturedAt),
            "isCallOpportunity": isCallOpportunity,
            "operations": operations.map { op -> [String: Any] in
                [
                    "type": Int(op.rawType),
                    "name": op.type.map { String(describing: $0) } ?? "unknown",
                    "combination": op.combination
                ]
            }
        ]
    }

    /// 雀魂牌字串 → 數字（紅五 `0m` 視為 5；字牌回 nil，吃不到字牌）
    private static func tileNumber(_ tile: String?) -> Int? {
        guard let tile, tile.count >= 2 else { return nil }
        let chars = Array(tile)
        guard let digit = chars.first.flatMap({ Int(String($0)) }) else { return nil }
        let suit = chars[1]
        guard suit == "m" || suit == "p" || suit == "s" else { return nil }
        return digit == 0 ? 5 : digit
    }
}

// MARK: - 快照儲存

/// 最近一次可用操作的儲存體（thread-safe）
///
/// - 寫入端：`MajsoulBridge.parseAction`（每個 ActionPrototype）
/// - 讀取端：`AutoPlayEngine` 一路到 `AutoPlayGate` / `AutoPlayDecisionResolver` /
///   `AutoPlayActionExecutor` / `LiqiActionSender`，以及 MCP 的 `game_*` / `bot_*` 工具
///
/// `pending` 只在「有快照且尚未被 `markHandled`」時回值，
/// 送出動作後標記已處理即可避免重試迴圈重複送同一個動作。
nonisolated final class LiqiOperationStore: @unchecked Sendable {

    /// 全域共用實例
    static let shared = LiqiOperationStore()

    private let lock = NSLock()
    private var sequenceCounter: UInt64 = 0
    private var snapshot: LiqiOperationSnapshot?
    private var handledSequence: UInt64 = 0

    init() {}

    /// 最近一次快照（不論是否已處理）
    var latest: LiqiOperationSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// 尚未處理的快照（送出動作後會被 `markHandled` 清掉）
    var pending: LiqiOperationSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot, snapshot.sequence > handledSequence else { return nil }
        return snapshot
    }

    /// 記錄一批可用操作
    @discardableResult
    func record(seat: Int,
                operations: [LiqiOperation],
                timeAdd: UInt32 = 0,
                timeFixed: UInt32 = 0,
                contextTile: String? = nil,
                source: String = "") -> LiqiOperationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        sequenceCounter &+= 1
        let new = LiqiOperationSnapshot(sequence: sequenceCounter,
                                        seat: seat,
                                        operations: operations,
                                        timeAdd: timeAdd,
                                        timeFixed: timeFixed,
                                        contextTile: contextTile,
                                        source: source,
                                        capturedAt: Date())
        snapshot = new
        return new
    }

    /// 從 `LiqiParser.parseOperation` 的字典建立快照
    ///
    /// - Parameters:
    ///   - parsed: key 為 `seat` / `operationList` / `timeAdd` / `timeFixed`
    ///   - contextTile: 觸發這批操作的牌（雀魂格式）
    ///   - source: 來源動作名稱（診斷用）
    /// - Returns: 建立的快照；`operationList` 缺失或為空時回 nil（不覆蓋既有快照）
    @discardableResult
    func record(fromParsed parsed: [String: Any],
                contextTile: String? = nil,
                source: String = "") -> LiqiOperationSnapshot? {
        guard let rawList = parsed["operationList"] as? [[String: Any]], !rawList.isEmpty else {
            return nil
        }

        let operations: [LiqiOperation] = rawList.compactMap { entry in
            guard let type = entry["type"] as? Int, type >= 0 else { return nil }
            let combination = entry["combination"] as? [String] ?? []
            return LiqiOperation(rawType: UInt32(type), combination: combination)
        }
        guard !operations.isEmpty else { return nil }

        return record(seat: parsed["seat"] as? Int ?? -1,
                      operations: operations,
                      timeAdd: UInt32(max(0, parsed["timeAdd"] as? Int ?? 0)),
                      timeFixed: UInt32(max(0, parsed["timeFixed"] as? Int ?? 0)),
                      contextTile: contextTile,
                      source: source)
    }

    /// 標記某序號之前（含）的快照已處理
    func markHandled(_ sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        handledSequence = max(handledSequence, sequence)
    }

    /// 標記目前快照已處理（沒有快照時不做事）
    func markCurrentHandled() {
        lock.lock()
        defer { lock.unlock() }
        if let snapshot {
            handledSequence = max(handledSequence, snapshot.sequence)
        }
    }

    /// 清空（局結束 / 重置 / 收到不含操作的動作時）
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        snapshot = nil
    }

    /// 完全重置（含序號，測試用）
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        snapshot = nil
        sequenceCounter = 0
        handledSequence = 0
    }

    // MARK: - 測試注入（只在 DEBUG build 存在）

    #if DEBUG
    /// 直接放進一份現成快照。**只有 DEBUG build 有這個入口。**
    ///
    /// 正式路徑只有 `record(...)`：序號由 store 自己配、`capturedAt` 一律是當下。
    /// 那表達不出 fail-safe 分支的前提——「這批 oplist 是 3 秒前到的」（寬限期已過）
    /// 與「序號已經被換掉」（stale）。這兩條分支在正常對局撞不到（模型幾乎總是
    /// 給出 hora 推薦、送出幾乎不失敗），要驗只能注入。
    ///
    /// 之所以不讓它進 Release：注入等於繞過「合法性的權威在 oplist」這條界線，
    /// 使用者跑的 binary 裡不該存在能偽造伺服器授權的入口。
    ///
    /// `handledSequence` 刻意不動——注入的快照要不要算 pending，由它自己的序號決定。
    func injectForTesting(_ snapshot: LiqiOperationSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        self.snapshot = snapshot
        // 注入後 record 的新快照仍必須贏過它，否則新到的 oplist 會被誤判成舊的
        sequenceCounter = max(sequenceCounter, snapshot.sequence)
    }
    #endif
}
