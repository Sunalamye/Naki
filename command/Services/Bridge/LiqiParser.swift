//
//  LiqiParser.swift
//  Naki
//
//  Created by Suoie on 2025/11/30.
//  雀魂 Protobuf 消息解析器 - 純 Swift 實現
//

import Foundation

// 使用 LogManager 的 liqiLog 函數
//
// wire 格式（varint / protobuf block / envelope）在 `LiqiEnvelope.swift`；
// 本檔只負責「這則訊息在說什麼」——欄位語意與 liqi.json 的對照。

// MARK: - XOR Decode Keys

/// 雀魂 XOR 解碼密鑰
private let xorKeys: [UInt8] = [0x84, 0x5e, 0x4e, 0x42, 0x39, 0xa2, 0x1f, 0x60, 0x1c]

/// bytes 的 hex 前綴（診斷用）。
///
/// **一律寫在 log 呼叫的括號裡面**：`liqiLog` 收 `@autoclosure`，trace 關掉時
/// 這個函式根本不會被呼叫。寫在呼叫之前先算好就沒有這個保護——
/// 每個 ActionPrototype 都會白做兩次 30 byte 的 `String(format:)` 迴圈。
func liqiHexPreview(_ data: Data, limit: Int = 30, separator: String = " ") -> String {
    let head = data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: separator)
    return data.count > limit ? head + "…" : head
}

/// XOR 解碼函數（用於解碼 action data）
func liqiDecode(_ data: Data) -> Data {
    var result = [UInt8](data)
    let len = result.count

    // 調試：顯示原始數據（trace 關掉時不會格式化）
    liqiLog("[XOR] Input (\(len) bytes): \(liqiHexPreview(data))")

    for i in 0..<len {
        let u = (23 ^ len) + 5 * i + Int(xorKeys[i % xorKeys.count])
        result[i] ^= UInt8(u & 0xFF)
    }

    // 調試：顯示解碼後數據
    liqiLog("[XOR] Output (\(len) bytes): \(liqiHexPreview(Data(result)))")

    return Data(result)
}

// MARK: - Liqi Parser

/// 雀魂協議解析器
///
/// ## 失敗不偽裝成資料
///
/// 解不開的欄位一律**不寫進結果**，同時往 `faults` 記一筆帶上下文的
/// `LiqiParseFault`（解析點、liqi.json 欄位編號、bytes 長度、原因）。
/// 呼叫端（`MajsoulBridge`）看得到「這個 key 不存在」，也拿得到「為什麼不存在」，
/// 才有辦法決定要 log 跳過還是讓整局停下來。預設值一律不再產生。
///
/// 欄位編號一律來自 `docs/protocol/liqi.json`（見各 case 的註解），不憑記憶。
class LiqiParser {

    /// msgId → 方法名。**全 Swift 只有這一份。**
    ///
    /// RESPONSE 的 envelope 不帶方法名，只能靠 msgId 對回當初的 REQUEST。
    /// 送出面的 frame 會經過 JS 的 `ws.send` hook 回到 `MajsoulBridge.parseRaw`，
    /// 所以遊戲自己送的與 Naki 自己送的（msgId 60000+）都會登記在這裡；
    /// `LiqiResponseStore` 拿得到方法名正是因為如此。
    private var pendingRequests: [Int: String] = [:]

    /// 當前消息 ID
    private var currentMsgId: Int = 1

    /// **這一次 `parse(_:)` 期間**累積的解析失敗。
    ///
    /// 刻意不直接寫進 `LiqiParseFaultState.shared`：解析器不知道少了某個欄位
    /// 會不會讓整局不工作，那是呼叫端的判斷。呼叫端 `parse` 完把這裡讀走
    /// （`MajsoulBridge.drainParserFaults`），決定升級成 blocking 或維持 degraded。
    private(set) var faults: [LiqiParseFault] = []

    /// `@MainActor` 隔離的 class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit { }

    /// 重置解析器狀態
    func reset() {
        pendingRequests.removeAll()
        currentMsgId = 1
        faults.removeAll()
        lastEnvelopeFailure = nil
    }

    /// 記一筆解析失敗（嚴重度先一律 degraded，由呼叫端升級）
    private func recordFault(site: String,
                             fieldId: Int? = nil,
                             byteCount: Int,
                             reason: String) {
        let fault = LiqiParseFault(site: site,
                                   fieldId: fieldId,
                                   byteCount: byteCount,
                                   reason: reason)
        faults.append(fault)
        liqiLog("[LiqiParser] ⚠️ 解析失敗 \(fault.text)")
    }

    /// bytes 的 hex 前綴（失敗訊息用；沒有這個就只知道「失敗」不知道「失敗在什麼上面」）
    private func hexPreview(_ data: Data, limit: Int = 16) -> String {
        liqiHexPreview(data, limit: limit, separator: "")
    }

    /// 最近一次 `parse` 解不開 envelope 的原因（帶得出 bytes 長度與訊息類型）。
    ///
    /// 存下來是為了讓呼叫端**不必再解一次**就寫得出診斷 log。
    private(set) var lastEnvelopeFailure: LiqiEnvelopeDecodeFailure?

    /// 解析雀魂消息
    /// - Parameter data: 原始二進制消息
    /// - Returns: 解析後的消息字典，包含 type, method, data 等字段
    func parse(_ data: Data) -> [String: Any]? {
        // 每則訊息各自結帳：呼叫端讀到的 faults 只屬於剛剛那一則
        faults.removeAll()
        lastEnvelopeFailure = nil

        // envelope 的形狀只有 `LiqiEnvelope` 知道（編碼端走同一份定義）
        let envelope: LiqiEnvelope
        switch LiqiEnvelope.decode(data) {
        case .success(let decoded):
            envelope = decoded
        case .failure(let failure):
            lastEnvelopeFailure = failure
            liqiLog("[LiqiParser] envelope 解不開：\(failure)｜preview: \(liqiHexPreview(data, limit: 20))")
            return nil
        }

        liqiLog("[LiqiParser] Message type: \(envelope.type), size: \(data.count)")

        switch envelope.type {
        case .notify:
            return parseNotify(method: envelope.method ?? "", payload: envelope.payload)

        case .request:
            return parseRequest(msgId: Int(envelope.msgId ?? 0),
                                method: envelope.method ?? "",
                                payload: envelope.payload)

        case .response:
            return parseResponse(msgId: Int(envelope.msgId ?? 0), payload: envelope.payload)
        }
    }

    // MARK: - Private Methods

    private func parseNotify(method: String, payload: Data) -> [String: Any]? {
        liqiLog("[LiqiParser] parseNotify method: \(method)，payload \(payload.count) bytes")

        // 解析內部數據
        var result: [String: Any] = [
            "id": -1,
            "type": "notify",
            "method": method
        ]

        // 嘗試解析內部 protobuf
        if let parsedData = parseInnerMessage(methodName: method, data: payload) {
            result["data"] = parsedData
        } else {
            // 返回原始數據
            result["rawData"] = payload.base64EncodedString()
        }

        return result
    }

    private func parseRequest(msgId: Int, method: String, payload: Data) -> [String: Any]? {
        liqiLog("[LiqiParser] parseRequest msgId=\(msgId), method: \(method)")

        // 記錄請求以便匹配響應
        pendingRequests[msgId] = method
        currentMsgId = msgId

        // 從遊戲自己的流量學 match_mode。寫死的對照表是錯的（見 ObservedMatchModes）。
        if method == ".lq.Lobby.fetchCurrentMatchInfo" {
            let modes = parseRepeatedVarint(payload, field: 1)
            if !modes.isEmpty {
                Task { @MainActor in ObservedMatchModes.shared.record(modes: modes) }
            }
        }

        var result: [String: Any] = [
            "id": msgId,
            "type": "request",
            "method": method
        ]

        if let parsedData = parseInnerMessage(methodName: method, data: payload) {
            result["data"] = parsedData
        }

        return result
    }

    private func parseResponse(msgId: Int, payload: Data) -> [String: Any]? {
        liqiLog("[LiqiParser] parseResponse msgId=\(msgId), pending=\(pendingRequests.keys.sorted())")

        // RESPONSE 的 envelope 不帶方法名，只能靠 msgId 對回 REQUEST；對不上就沒得解。
        guard let methodName = pendingRequests.removeValue(forKey: msgId) else {
            liqiLog("[LiqiParser] parseResponse: no pending request for msgId=\(msgId)"
                    + "，payload preview: \(liqiHexPreview(payload))")
            return nil
        }

        var result: [String: Any] = [
            "id": msgId,
            "type": "response",
            "method": methodName
        ]

        if let parsedData = parseInnerMessage(methodName: methodName, data: payload, isResponse: true) {
            result["data"] = parsedData
        }

        return result
    }

    /// 解析內部消息（根據方法名）
    /// 取出某個 field 的所有 varint 值（repeated uint32 用）
    ///
    /// protobuf 的 repeated 標量可能是 packed 也可能逐筆出現；
    /// `mode_list` 實測是逐筆（每個值一個 field 1 block）。
    private func parseRepeatedVarint(_ data: Data, field: Int) -> [Int] {
        parseProtobufBlocks(data)
            .filter { $0.fieldId == field && $0.wireType == 0 }
            .compactMap { block in
                parseVarint(block.data, offset: 0).map { Int($0.0) }
            }
    }

    private func parseInnerMessage(methodName: String, data: Data, isResponse: Bool = false) -> [String: Any]? {
        // 調試：顯示內部消息原始數據
        liqiLog("[LiqiParser] parseInnerMessage: method=\(methodName), dataSize=\(data.count)")
        liqiLog("[LiqiParser] parseInnerMessage raw: \(liqiHexPreview(data, limit: 80))")

        let innerBlocks = parseProtobufBlocks(data)
        liqiLog("[LiqiParser] parseInnerMessage: \(innerBlocks.count) inner blocks")

        // 顯示每個內部塊。
        //
        // 這整個迴圈**只為了寫 log 而存在**：每個 block 兩行、`stringValue` 還會多做一次
        // UTF-8 解碼。trace 關掉時連迴圈都不該進去——`@autoclosure` 只擋得住單一行訊息，
        // 擋不住「跑一圈迴圈」。一局 liqi.log 191KB 裡絕大多數就是這裡產生的。
        if isTraceLogging {
            for (i, block) in innerBlocks.enumerated() {
                liqiLog("[LiqiParser] innerBlock[\(i)]: fieldId=\(block.fieldId), wireType=\(block.wireType), size=\(block.data.count)")
                if block.wireType == 2 {
                    if let str = block.stringValue, str.count < 50 {
                        liqiLog("[LiqiParser] innerBlock[\(i)] string: \(str)")
                    } else {
                        liqiLog("[LiqiParser] innerBlock[\(i)] bytes: \(liqiHexPreview(block.data, limit: 40))")
                    }
                }
            }
        }

        // 根據消息類型進行特定解析
        if methodName == ".lq.ActionPrototype" {
            // Notify/request/response 路徑的 ActionPrototype 來自 WebSocket，需要 XOR 解碼
            return parseActionPrototype(innerBlocks, xorDecode: true)
        }

        if methodName == ".lq.FastTest.authGame" {
            if isResponse {
                return parseAuthGameResponse(innerBlocks)
            } else {
                // ⭐ 解析 authGame 請求以獲取 accountId
                return parseAuthGameRequest(innerBlocks)
            }
        }

        if methodName == ".lq.FastTest.syncGame" || methodName == ".lq.FastTest.enterGame" {
            return parseSyncGame(innerBlocks)
        }

        // 處理登入響應
        if (methodName == ".lq.Lobby.login" || methodName == ".lq.Lobby.oauth2Login" ||
            methodName == ".lq.Lobby.oauth2Auth" || methodName == ".lq.Lobby.emailLogin") && isResponse {
            return parseLoginResponse(innerBlocks)
        }

        // 通用解析：將塊轉換為字典
        return blocksToDict(innerBlocks)
    }

    /// 解析 ActionPrototype 消息
    /// - Parameter xorDecode: 是否需要 XOR 解碼。**契約：所有 caller 必須顯式傳入，不提供 default 值**，
    ///   以防未來新增 caller 忘記指定 flag 而導致靜默的雙重解碼 / 未解碼。
    ///   - Notify/request/response 訊息的 ActionPrototype 需要 XOR 解碼 (true)
    ///   - SyncGame/GameRestore 的 actions 已解碼，不可再次 XOR (false)
    private func parseActionPrototype(_ blocks: [ProtobufBlock], xorDecode: Bool) -> [String: Any]? {
        var result: [String: Any] = [:]
        var actionName: String = ""
        var actionData: Data? = nil

        liqiLog("[LiqiParser] parseActionPrototype: \(blocks.count) blocks, xorDecode=\(xorDecode)")

        // 欄位編號依 docs/protocol/liqi.json 的 `.lq.ActionPrototype`：
        // - field 1: step (uint32)
        // - field 2: name (string) - e.g., "ActionDealTile"
        // - field 3: data (bytes) - 可能需要 XOR 解碼（取決於來源）
        for block in blocks {
            liqiLog("[LiqiParser] ActionPrototype field \(block.fieldId), wireType \(block.wireType), size \(block.data.count)")

            switch block.fieldId {
            case 1: // step
                if let (value, _) = parseVarint(block.data, offset: 0) {
                    result["step"] = value
                    liqiLog("[LiqiParser] ActionPrototype step: \(value)")
                }

            case 2: // name
                if let str = block.stringValue {
                    actionName = str
                    result["name"] = str
                    liqiLog("[LiqiParser] ActionPrototype name: \(str)")
                } else {
                    recordFault(site: "ActionPrototype.name",
                                fieldId: 2,
                                byteCount: block.data.count,
                                reason: "name 不是合法 UTF-8：\(hexPreview(block.data))")
                }

            case 3: // data
                actionData = block.data
                liqiLog("[LiqiParser] ActionPrototype data (raw): \(liqiHexPreview(block.data, limit: 40))")

            default:
                // 其他欄位只記錄。**不再拿它頂替 field 3**——
                // 舊版「找不到 data 就抓任何一個 wireType 2 的 block 當 data」，
                // schema 一改（多一個字串欄位）就會安靜地把別的東西 XOR 解碼後
                // 當成動作內容餵給 Bot，而 log 裡看起來一切正常。
                if block.wireType == 2 {
                    liqiLog("[LiqiParser] ActionPrototype 未知欄位 \(block.fieldId): "
                            + "\(liqiHexPreview(block.data, limit: 40))")
                }
            }
        }

        // name 是 `parseActionData` 的分派依據，沒有它整則動作無法解讀 → 顯式失敗
        guard !actionName.isEmpty else {
            recordFault(site: "ActionPrototype.name",
                        fieldId: 2,
                        byteCount: 0,
                        reason: "缺少 name 欄位，無法判斷這是哪一種動作（blocks=\(blocks.count)）")
            return nil
        }

        // data 缺席與 data 為空是兩件事：前者是 schema 對不上（顯式失敗），
        // 後者是伺服器真的沒帶內容（合法，交給呼叫端處理空 dict）。
        guard let data = actionData else {
            recordFault(site: "ActionPrototype.data",
                        fieldId: 3,
                        byteCount: 0,
                        reason: "'\(actionName)' 沒有 field 3（blocks=\(blocks.count)）")
            return nil
        }

        liqiLog("[LiqiParser] ActionPrototype: name='\(actionName)', data size=\(data.count) bytes")

        if data.isEmpty {
            liqiLog("[LiqiParser] WARNING: ActionPrototype '\(actionName)' has empty data!")
            result["data"] = [String: Any]()
            return result
        }

        // 根據 xorDecode 參數決定是否進行 XOR 解碼
        let decodedData: Data
        if xorDecode {
            decodedData = liqiDecode(data)
            liqiLog("[LiqiParser] ActionPrototype '\(actionName)' XOR decoded: "
                    + "\(liqiHexPreview(decodedData, limit: 50))")
        } else {
            decodedData = data
            liqiLog("[LiqiParser] ActionPrototype '\(actionName)' raw (no XOR): "
                    + "\(liqiHexPreview(decodedData, limit: 50))")
        }

        let actionBlocks = parseProtobufBlocks(decodedData)
        liqiLog("[LiqiParser] ActionPrototype parsed \(actionBlocks.count) action blocks")

        result["data"] = parseActionData(name: actionName, blocks: actionBlocks)
        return result
    }

    /// 解析具體的 Action 數據
    private func parseActionData(name: String, blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]

        switch name {
        case "ActionNewRound":
            result = parseActionNewRound(blocks)
        case "ActionDealTile":
            result = parseActionDealTile(blocks)
        case "ActionDiscardTile":
            result = parseActionDiscardTile(blocks)
        case "ActionChiPengGang":
            result = parseActionChiPengGang(blocks)
        case "ActionAnGangAddGang":
            result = parseActionAnGangAddGang(blocks)
        case "ActionHule":
            result = parseActionHule(blocks)
        case "ActionNoTile":
            result["type"] = "no_tile"
        case "ActionLiuJu":
            result["type"] = "liu_ju"
        case "ActionBaBei":
            result = parseActionBaBei(blocks)
        default:
            result = blocksToDict(blocks)
        }

        return result
    }

    // MARK: - Action Parsers

    /// 欄位編號依 `docs/protocol/liqi.json` 的 `.lq.ActionNewRound`
    /// （1=chang, 2=ju, 3=ben, 4=tiles, 5=dora, 6=scores, 7=operation, 8=liqibang,
    ///  11=al, 12=md5, 13=left_tile_count, 14=doras）。
    private func parseActionNewRound(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]
        var tiles: [String] = []  // 累積所有手牌
        var scores: [Int] = []    // field 6 可能是 packed，也可能逐筆出現
        var scoresFailed = false

        liqiLog("[LiqiParser] parseActionNewRound: \(blocks.count) blocks")

        for block in blocks {
            switch block.fieldId {
            case 1: // chang (場)
                if let (v, _) = parseVarint(block.data, offset: 0) {
                    result["chang"] = v
                }
            case 2: // ju (局)
                if let (v, _) = parseVarint(block.data, offset: 0) {
                    result["ju"] = v
                }
            case 3: // ben (本場)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["ben"] = v }
            case 4: // tiles (手牌) - repeated string，每個 block 都是一張牌
                if let tile = block.stringValue {
                    tiles.append(tile)
                }
            case 5: // dora (寶牌指示牌)
                if let tile = block.stringValue {
                    if result["doras"] == nil { result["doras"] = [] }
                    if var doras = result["doras"] as? [String] {
                        doras.append(tile)
                        result["doras"] = doras
                    }
                }
            case 6: // scores（liqi.json：`repeated int32`）
                // 調試: 打印原始數據
                liqiLog("[LiqiParser] NewRound field 6 (scores) raw bytes: "
                        + "\(liqiHexPreview(block.data, limit: block.data.count))")
                liqiLog("[LiqiParser] NewRound field 6 wireType: \(block.wireType), size: \(block.data.count)")

                // packed（wireType 2）與逐筆（wireType 0）兩種編碼都收；
                // 解不開就標記失敗、**不寫 scores**。
                // 舊版在這裡回 [25000, 25000, 25000, 25000]，於是「起手就是 25000」
                // 與「這段 bytes 解不開」在呼叫端長得一模一樣。
                if let parsed = parseRepeatedVarintField(block,
                                                         site: "ActionNewRound.scores",
                                                         fieldId: 6) {
                    scores.append(contentsOf: parsed)
                } else {
                    scoresFailed = true
                }
            // 依 liqi.json 的 ActionNewRound：7=operation、8=liqibang。
            // 舊版把 7 當 liqibang 用 varint 硬解 operation 的訊息位元組 → kyotaku 是垃圾值，
            // 且開局第一巡的可用操作（親家打牌／天和）永遠拿不到。
            case 7: // operation (OptionalOperationList)
                // 帶上原始長度：莊家第一打拿不到 oplist 時，要能分辨
                // 「blob 本身是空的（伺服器沒給）」與「blob 有內容但解錯」。
                // 只看解析結果都是 seat=-1/list=0，兩者無法區分。
                var op = parseOperation(block.data)
                op["_rawBytes"] = block.data.count
                op["_rawHex"] = block.data.prefix(24).map { String(format: "%02x", $0) }.joined()
                result["operation"] = op
            case 8: // liqibang (立直棒)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["liqibang"] = v }
            case 11: // al (是否有操作)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["al"] = v != 0 }
            case 12: // md5
                if let md5 = block.stringValue { result["md5"] = md5 }
            case 13: // left_tile_count
                if let (v, _) = parseVarint(block.data, offset: 0) { result["leftTileCount"] = v }
            case 14: // doras (repeated)
                if result["doras"] == nil { result["doras"] = [] }
                if var doras = result["doras"] as? [String], let tile = block.stringValue {
                    doras.append(tile)
                    result["doras"] = doras
                }
            default:
                break
            }
        }

        // 設置累積的手牌
        result["tiles"] = tiles

        // 有一個 block 解不開就整個 scores 不給：半份分數比沒有分數更難查。
        if !scoresFailed && !scores.isEmpty {
            result["scores"] = scores
            liqiLog("[LiqiParser] NewRound scores parsed: \(scores)")
        }

        liqiLog("[LiqiParser] NewRound tiles=\(tiles.count): \(tiles)")
        liqiLog("[LiqiParser] NewRound result: \(result)")
        return result
    }

    private func parseActionDealTile(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]

        liqiLog("[LiqiParser] parseActionDealTile: \(blocks.count) blocks")

        for block in blocks {
            liqiLog("[LiqiParser] DealTile field \(block.fieldId), wireType \(block.wireType), size \(block.data.count)")

            switch block.fieldId {
            case 1: // seat
                if let (v, _) = parseVarint(block.data, offset: 0) {
                    result["seat"] = v
                    liqiLog("[LiqiParser] DealTile seat: \(v)")
                }
            case 2: // tile
                if let tile = block.stringValue {
                    result["tile"] = tile
                    liqiLog("[LiqiParser] DealTile tile: \(tile)")
                } else {
                    // 顯示原始數據用於調試
                    liqiLog("[LiqiParser] DealTile tile field not a valid string, raw: "
                            + "\(liqiHexPreview(block.data, limit: 20))")
                }
            case 3: // left_tile_count
                if let (v, _) = parseVarint(block.data, offset: 0) {
                    result["leftTileCount"] = v
                    liqiLog("[LiqiParser] DealTile leftTileCount: \(v)")
                }
            // 欄位編號依 docs/protocol/liqi.json 的 ActionDealTile（唯一事實來源）。
            // 舊版把 operation 當 field 11、doras 當 field 8，是 Laya 時代的猜測，
            // 結果 oplist 永遠是空的 → 自動打牌無從判斷是否輪到自己。
            case 4: // operation (OptionalOperationList)
                result["operation"] = parseOperation(block.data)
                liqiLog("[LiqiParser] DealTile has operation data")
            case 5: // liqi (LiQiSuccess)
                result["liqi"] = parseProtobufBlocks(block.data).count > 0
            case 6: // doras (repeated string)
                if let tile = block.stringValue {
                    if result["doras"] == nil { result["doras"] = [] }
                    if var doras = result["doras"] as? [String] {
                        doras.append(tile)
                        result["doras"] = doras
                    }
                }
            case 7: // zhenting (bool)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["zhenting"] = v != 0 }
            default:
                // 記錄未知字段
                liqiLog("[LiqiParser] DealTile unknown field \(block.fieldId): "
                        + "\(liqiHexPreview(block.data, limit: 20))")
            }
        }

        // 如果還沒有找到 tile，嘗試從 operation 中獲取
        if result["tile"] == nil {
            if let operation = result["operation"] as? [String: Any],
               let opList = operation["operationList"] as? [[String: Any]] {
                liqiLog("[LiqiParser] DealTile: tile not found, checking operation for hints")
                for op in opList {
                    if let combination = op["combination"] as? [String], !combination.isEmpty {
                        liqiLog("[LiqiParser] DealTile operation combination: \(combination)")
                    }
                }
            }
        }

        liqiLog("[LiqiParser] DealTile result: \(result)")
        return result
    }

    private func parseActionDiscardTile(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]

        for block in blocks {
            switch block.fieldId {
            case 1: // seat
                if let (v, _) = parseVarint(block.data, offset: 0) { result["seat"] = v }
            case 2: // tile
                if let tile = block.stringValue { result["tile"] = tile }
            // 欄位編號依 docs/protocol/liqi.json 的 ActionDiscardTile。
            // 舊版 operation 誤標 field 11（實為 muyu），doras 誤標 field 8 之外還漏了 is_wliqi 位置。
            case 3: // is_liqi (是否立直)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["isLiqi"] = v != 0 }
            case 4: // operation (OptionalOperationList)
                result["operation"] = parseOperation(block.data)
            case 5: // moqie (是否摸切)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["moqie"] = v != 0 }
            case 6: // zhenting
                if let (v, _) = parseVarint(block.data, offset: 0) { result["zhenting"] = v != 0 }
            case 8: // doras (repeated string)
                if let tile = block.stringValue {
                    if result["doras"] == nil { result["doras"] = [] }
                    if var doras = result["doras"] as? [String] {
                        doras.append(tile)
                        result["doras"] = doras
                    }
                }
            case 9: // is_wliqi (是否 W 立直)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["isWliqi"] = v != 0 }
            default:
                break
            }
        }

        return result
    }

    /// 欄位編號依 `docs/protocol/liqi.json` 的 `.lq.ActionChiPengGang`
    /// （1=seat, 2=type, 3=tiles[repeated string], 4=froms[repeated uint32],
    ///  5=liqi, 6=operation）。
    private func parseActionChiPengGang(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]
        var tiles: [String] = []  // ⭐ 累積所有 tiles
        var froms: [Int] = []

        for block in blocks {
            switch block.fieldId {
            case 1: // seat
                if let (v, _) = parseVarint(block.data, offset: 0) { result["seat"] = v }
            case 2: // type (0=chi, 1=pon, 2=daiminkan)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["type"] = v }
            case 3: // tiles（repeated string：一個 block 就是一張牌）
                // schema 已經說清楚一個 block 一張牌，解不出牌就是解錯了——
                // 舊版在這裡退回 `parseTileList` 的逐 byte 掃描，掃出來的東西
                // 與真的牌無法區分。現在直接記一筆失敗，讓呼叫端看得到。
                if let tile = block.stringValue, isTileString(tile) {
                    tiles.append(tile)
                    liqiLog("[LiqiParser] ChiPengGang tile: \(tile)")
                } else {
                    recordFault(site: "ActionChiPengGang.tiles",
                                fieldId: 3,
                                byteCount: block.data.count,
                                reason: "不是合法的牌字串：\(hexPreview(block.data))")
                }
            case 4: // froms（repeated uint32；packed 與逐筆都要接住並累積）
                if let parsed = parseRepeatedVarintField(block,
                                                         site: "ActionChiPengGang.froms",
                                                         fieldId: 4) {
                    froms.append(contentsOf: parsed)
                }
            case 6: // operation (OptionalOperationList)
                result["operation"] = parseOperation(block.data)
            default:
                break
            }
        }

        // ⭐ 設置累積的 tiles
        result["tiles"] = tiles
        if !froms.isEmpty { result["froms"] = froms }
        liqiLog("[LiqiParser] ChiPengGang tiles accumulated: \(tiles), froms=\(froms)")

        return result
    }

    private func parseActionAnGangAddGang(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]

        for block in blocks {
            switch block.fieldId {
            case 1: // seat
                if let (v, _) = parseVarint(block.data, offset: 0) { result["seat"] = v }
            case 2: // type (2=kakan, 3=ankan)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["type"] = v }
            case 3: // tiles
                if let tile = block.stringValue { result["tiles"] = tile }
            case 4: // operation（liqi.json ActionAnGangAddGang：operation 是 field 4）
                result["operation"] = parseOperation(block.data)
            default:
                break
            }
        }

        return result
    }

    /// 欄位編號依 `docs/protocol/liqi.json` 的 `.lq.ActionHule`
    /// （1=hules[repeated HuleInfo], 2=old_scores, 3=delta_scores, 4=wait_timeout,
    ///  5=scores, 6=gameend, 7=doras）。
    ///
    /// 舊版把 field 1 的**塊數**存成 `hules`（和牌詳情整個丟掉），
    /// 又把 field 3（delta_scores）當成 `scores`——兩個欄位編號都沒對過 schema。
    private func parseActionHule(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = ["type": "hule"]
        var hules: [[String: Any]] = []
        var oldScores: [Int] = []
        var deltaScores: [Int] = []
        var scores: [Int] = []
        var doras: [String] = []

        for block in blocks {
            switch block.fieldId {
            case 1: // hules（repeated HuleInfo：一個 block 一筆和牌）
                hules.append(parseHuleInfo(block.data))
            case 2: // old_scores（repeated int32）
                if let parsed = parseRepeatedVarintField(block,
                                                         site: "ActionHule.old_scores",
                                                         fieldId: 2) {
                    oldScores.append(contentsOf: parsed)
                }
            case 3: // delta_scores（repeated int32）
                if let parsed = parseRepeatedVarintField(block,
                                                         site: "ActionHule.delta_scores",
                                                         fieldId: 3) {
                    deltaScores.append(contentsOf: parsed)
                }
            case 5: // scores（repeated int32；和牌後的點數）
                if let parsed = parseRepeatedVarintField(block,
                                                         site: "ActionHule.scores",
                                                         fieldId: 5) {
                    scores.append(contentsOf: parsed)
                }
            case 7: // doras（repeated string）
                if let tile = block.stringValue { doras.append(tile) }
            default:
                break
            }
        }

        result["hules"] = hules
        if !oldScores.isEmpty { result["oldScores"] = oldScores }
        if !deltaScores.isEmpty { result["deltaScores"] = deltaScores }
        if !scores.isEmpty { result["scores"] = scores }
        // 刻意**不叫** `doras`：`MajsoulBridge.parseAction` 看到 `doras` 就會補一個
        // MJAI `dora` 事件，而 ActionHule 已經產生 `end_kyoku`——局結束後再補 dora
        // 會讓 Bot 收到一個屬於上一局的事件。這裡只是把資料保留下來給診斷看。
        if !doras.isEmpty { result["huleDoras"] = doras }

        return result
    }

    /// 解析單筆 `HuleInfo`（欄位編號依 `docs/protocol/liqi.json` 的 `.lq.HuleInfo`）
    ///
    /// 只取「事後看得懂這局怎麼結束」需要的欄位；`fans`（FanInfo）等巢狀結構暫不展開。
    private func parseHuleInfo(_ data: Data) -> [String: Any] {
        var info: [String: Any] = [:]
        var hand: [String] = []
        var ming: [String] = []
        var doras: [String] = []
        var liDoras: [String] = []

        for block in parseProtobufBlocks(data) {
            switch block.fieldId {
            case 1: // hand（repeated string）
                if let tile = block.stringValue { hand.append(tile) }
            case 2: // ming（repeated string，副露表記如 "shunzi(1m,2m,3m)"）
                if let str = block.stringValue { ming.append(str) }
            case 3: // hu_tile
                if let tile = block.stringValue { info["huTile"] = tile }
            case 4: // seat
                if let (v, _) = parseVarint(block.data, offset: 0) { info["seat"] = v }
            case 5: // zimo
                if let (v, _) = parseVarint(block.data, offset: 0) { info["zimo"] = v != 0 }
            case 6: // qinjia（是否親家）
                if let (v, _) = parseVarint(block.data, offset: 0) { info["qinjia"] = v != 0 }
            case 7: // liqi
                if let (v, _) = parseVarint(block.data, offset: 0) { info["liqi"] = v != 0 }
            case 8: // doras（repeated string）
                if let tile = block.stringValue { doras.append(tile) }
            case 9: // li_doras（裏寶牌，repeated string）
                if let tile = block.stringValue { liDoras.append(tile) }
            case 10: // yiman
                if let (v, _) = parseVarint(block.data, offset: 0) { info["yiman"] = v != 0 }
            case 11: // count（飜數／役滿倍數）
                if let (v, _) = parseVarint(block.data, offset: 0) { info["count"] = v }
            case 13: // fu
                if let (v, _) = parseVarint(block.data, offset: 0) { info["fu"] = v }
            case 14: // title（滿貫／跳滿…）
                if let str = block.stringValue { info["title"] = str }
            case 15: // point_rong
                if let (v, _) = parseVarint(block.data, offset: 0) { info["pointRong"] = v }
            case 16: // point_zimo_qin
                if let (v, _) = parseVarint(block.data, offset: 0) { info["pointZimoQin"] = v }
            case 17: // point_zimo_xian
                if let (v, _) = parseVarint(block.data, offset: 0) { info["pointZimoXian"] = v }
            case 19: // point_sum
                if let (v, _) = parseVarint(block.data, offset: 0) { info["pointSum"] = v }
            default:
                break
            }
        }

        if !hand.isEmpty { info["hand"] = hand }
        if !ming.isEmpty { info["ming"] = ming }
        if !doras.isEmpty { info["doras"] = doras }
        if !liDoras.isEmpty { info["liDoras"] = liDoras }

        // 座位是這筆和牌最基本的識別；沒有它整筆沒有意義（誰和的都不知道）
        if info["seat"] == nil {
            recordFault(site: "HuleInfo.seat",
                        fieldId: 4,
                        byteCount: data.count,
                        reason: "和牌詳情缺少 seat：\(hexPreview(data))")
        }

        return info
    }

    private func parseActionBaBei(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]

        for block in blocks {
            switch block.fieldId {
            case 1: // seat
                if let (v, _) = parseVarint(block.data, offset: 0) { result["seat"] = v }
            case 4: // operation（liqi.json ActionBaBei：operation 是 field 4）
                result["operation"] = parseOperation(block.data)
            case 9: // moqie
                if let (v, _) = parseVarint(block.data, offset: 0) { result["moqie"] = v != 0 }
            default:
                break
            }
        }

        return result
    }

    // MARK: - Auth Game Response

    /// 欄位編號依 `docs/protocol/liqi.json` 的 `.lq.ResAuthGame`
    /// （1=error, 2=players[repeated PlayerGameView], 3=seat_list[repeated uint32],
    ///  4=is_game_start, 5=game_config）。
    private func parseAuthGameResponse(_ blocks: [ProtobufBlock]) -> [String: Any]? {
        var result: [String: Any] = [:]
        var seatList: [Int] = []
        var seatListFailed = false
        var players: [[String: Any]] = []  // PlayerGameView（順序即座位順序）

        liqiLog("[LiqiParser] parseAuthGameResponse: \(blocks.count) blocks")

        for block in blocks {
            liqiLog("[LiqiParser] authGame field \(block.fieldId), wireType \(block.wireType), size \(block.data.count)")

            switch block.fieldId {
            case 2: // players (repeated PlayerGameView) - 每個玩家依座位順序排列
                players.append(parsePlayerGameView(block.data))
            case 3: // seat_list（repeated uint32）— ⭐ 座位的權威來源
                // seatList[座位] = accountId；自家座位 = seatList.firstIndex(of: accountId)
                if let parsed = parseRepeatedVarintField(block,
                                                         site: "ResAuthGame.seat_list",
                                                         fieldId: 3) {
                    seatList.append(contentsOf: parsed)
                } else {
                    seatListFailed = true
                }
            case 4: // is_game_start
                if let (v, _) = parseVarint(block.data, offset: 0) { result["isGameStart"] = v != 0 }
            case 5: // game_config
                result["gameConfig"] = blocksToDict(parseProtobufBlocks(block.data))
            default:
                break
            }
        }

        if !players.isEmpty { result["players"] = players }

        // seatList 的來源要**標在結果裡**：field 3 是 schema 說的權威來源（exact）；
        // 拿 players 的順序頂替只是「通常也對」（heuristic）。舊版兩者都寫進同一個
        // key、不留痕跡，於是「座位是查出來的還是猜出來的」在呼叫端無法分辨。
        if !seatListFailed && !seatList.isEmpty {
            result["seatList"] = seatList
            result["seatListConfidence"] = LiqiParseConfidence.exact.rawValue
            liqiLog("[LiqiParser] ⭐ seatList（field 3, exact）: \(seatList)")
        } else {
            let accountIds = players.compactMap { $0["accountId"] as? Int }
            if !accountIds.isEmpty {
                result["seatList"] = accountIds
                result["seatListConfidence"] = LiqiParseConfidence.heuristic.rawValue
                recordFault(site: "ResAuthGame.seat_list",
                            fieldId: 3,
                            byteCount: 0,
                            reason: "缺少 seat_list，改用 players 的順序推座位（heuristic，可能是錯的）")
            } else {
                recordFault(site: "ResAuthGame.seat_list",
                            fieldId: 3,
                            byteCount: 0,
                            reason: "沒有 seat_list，也沒有可用的 players（blocks=\(blocks.count)）")
            }
        }

        return result
    }

    /// 解析單筆 `PlayerGameView`（liqi.json：1=account_id, 4=nickname）
    private func parsePlayerGameView(_ data: Data) -> [String: Any] {
        var player: [String: Any] = [:]

        for block in parseProtobufBlocks(data) {
            switch block.fieldId {
            case 1: // account_id
                if let (accountId, _) = parseVarint(block.data, offset: 0) {
                    player["accountId"] = accountId
                    liqiLog("[LiqiParser] PlayerGameView accountId: \(accountId)")
                }
            case 4: // nickname
                if let name = block.stringValue { player["nickname"] = name }
            default:
                break
            }
        }

        return player
    }

    /// 解析 authGame 請求（獲取 accountId）
    private func parseAuthGameRequest(_ blocks: [ProtobufBlock]) -> [String: Any]? {
        var result: [String: Any] = [:]

        liqiLog("[LiqiParser] parseAuthGameRequest: \(blocks.count) blocks")

        for block in blocks {
            liqiLog("[LiqiParser] authGame request field \(block.fieldId), wireType \(block.wireType), size \(block.data.count)")

            switch block.fieldId {
            case 1: // account_id
                if let (accountId, _) = parseVarint(block.data, offset: 0) {
                    result["accountId"] = accountId
                    liqiLog("[LiqiParser] ⭐ authGame request accountId: \(accountId)")
                }
            // 解不出字串就**不寫 key**（舊版寫空字串，呼叫端無法分辨
            // 「伺服器沒給」與「給了但解不開」）。
            case 2: // token
                if let token = block.stringValue {
                    result["token"] = token
                } else {
                    recordFault(site: "ReqAuthGame.token",
                                fieldId: 2,
                                byteCount: block.data.count,
                                reason: "token 不是合法 UTF-8")
                }
            case 3: // game_uuid
                if let uuid = block.stringValue {
                    result["gameUuid"] = uuid
                } else {
                    recordFault(site: "ReqAuthGame.game_uuid",
                                fieldId: 3,
                                byteCount: block.data.count,
                                reason: "game_uuid 不是合法 UTF-8")
                }
            default:
                break
            }
        }

        return result
    }

    /// 解析一個 `repeated` 數值欄位的單一 block（packed 或逐筆都接）。
    ///
    /// protobuf 的 repeated 標量可以 packed（wireType 2，一個 block 裝全部）
    /// 也可以逐筆（wireType 0，每個值一個 block），解碼端兩種都必須接住。
    /// 呼叫端把多個 block 的結果**累積**起來，才不會像舊版那樣被最後一個 block 覆蓋掉。
    ///
    /// - Returns: 解出來的值；**解不完整就回 nil**（不回半份、不回預設值），
    ///            同時記一筆 `LiqiParseFault`。
    private func parseRepeatedVarintField(_ block: ProtobufBlock,
                                          site: String,
                                          fieldId: Int) -> [Int]? {
        if block.wireType == 0 {
            guard let (value, _) = parseVarint(block.data, offset: 0) else {
                recordFault(site: site,
                            fieldId: fieldId,
                            byteCount: block.data.count,
                            reason: "varint 解不出來：\(hexPreview(block.data))")
                return nil
            }
            return [value]
        }

        guard block.wireType == 2 else {
            recordFault(site: site,
                        fieldId: fieldId,
                        byteCount: block.data.count,
                        reason: "預期 varint(0) 或 packed(2)，實際 wireType \(block.wireType)")
            return nil
        }

        guard let values = parsePackedVarints(block.data) else {
            recordFault(site: site,
                        fieldId: fieldId,
                        byteCount: block.data.count,
                        reason: "packed varint 解不出來：\(hexPreview(block.data))")
            return nil
        }
        return values
    }

    /// packed repeated 數值：整段 bytes 必須剛好解成一串 varint。
    ///
    /// 有任何一個 byte 落單就代表這段不是我們以為的東西 → 回 nil。
    /// 負數（int32）在 wire 上是 10 bytes 的 64-bit 二補數，`parseVarint` 解得出來。
    private func parsePackedVarints(_ data: Data) -> [Int]? {
        guard !data.isEmpty else { return nil }

        var values: [Int] = []
        var offset = 0
        while offset < data.count {
            guard let (value, newOffset) = parseVarint(data, offset: offset) else {
                return nil
            }
            values.append(value)
            offset = newOffset
        }
        return values
    }

    // MARK: - Login Response

    private func parseLoginResponse(_ blocks: [ProtobufBlock]) -> [String: Any]? {
        var result: [String: Any] = [:]

        liqiLog("[LiqiParser] parseLoginResponse: \(blocks.count) blocks")

        for block in blocks {
            liqiLog("[LiqiParser] Login field \(block.fieldId), wireType \(block.wireType), size \(block.data.count)")

            switch block.fieldId {
            case 1: // error (如果有錯誤)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["error"] = v }
            case 2: // account_id (直接的帳號 ID)
                if let (v, _) = parseVarint(block.data, offset: 0) {
                    result["accountId"] = v
                    liqiLog("[LiqiParser] Found accountId: \(v)")
                }
            case 3: // account (嵌套的帳號結構)
                let accountResult = parseAccountInfo(block.data)
                result["account"] = accountResult
                if let accId = accountResult["accountId"] as? Int {
                    result["accountId"] = accId
                    liqiLog("[LiqiParser] Found accountId from account: \(accId)")
                }
            default:
                break
            }
        }

        return result
    }

    /// 解析帳號信息
    private func parseAccountInfo(_ data: Data) -> [String: Any] {
        var result: [String: Any] = [:]
        let blocks = parseProtobufBlocks(data)

        for block in blocks {
            switch block.fieldId {
            case 1: // account_id
                if let (v, _) = parseVarint(block.data, offset: 0) {
                    result["accountId"] = v
                    liqiLog("[LiqiParser] Account.accountId: \(v)")
                }
            case 2: // nickname
                if let str = block.stringValue {
                    result["nickname"] = str
                }
            case 3: // login_time
                if let (v, _) = parseVarint(block.data, offset: 0) { result["loginTime"] = v }
            case 4: // logout_time
                if let (v, _) = parseVarint(block.data, offset: 0) { result["logoutTime"] = v }
            case 5: // room_id
                if let (v, _) = parseVarint(block.data, offset: 0) { result["roomId"] = v }
            default:
                break
            }
        }

        return result
    }

    // MARK: - Sync Game

    private func parseSyncGame(_ blocks: [ProtobufBlock]) -> [String: Any]? {
        var result: [String: Any] = [:]

        liqiLog("[LiqiParser] parseSyncGame: \(blocks.count) blocks")

        for block in blocks {
            liqiLog("[LiqiParser] syncGame field \(block.fieldId), wireType \(block.wireType), size \(block.data.count)")

            switch block.fieldId {
            case 1: // error
                break
            case 2: // is_end
                if let (v, _) = parseVarint(block.data, offset: 0) { result["isEnd"] = v != 0 }
            case 3: // step
                if let (v, _) = parseVarint(block.data, offset: 0) { result["step"] = v }
            case 4: // game_restore (GameRestore message)
                let gameRestoreBlocks = parseProtobufBlocks(block.data)
                liqiLog("[LiqiParser] syncGame game_restore: \(gameRestoreBlocks.count) blocks")
                result["gameRestore"] = parseGameRestore(gameRestoreBlocks)
            default:
                break
            }
        }

        return result
    }

    /// 解析遊戲恢復數據 (GameRestore message)
    /// Proto定義:
    ///   message GameRestore {
    ///     GameSnapshot snapshot = 1;
    ///     repeated ActionPrototype actions = 2;
    ///     uint32 passed_waiting_time = 3;
    ///     uint32 game_state = 4;
    ///     uint32 start_time = 5;
    ///     uint32 last_pause_time_ms = 6;
    ///   }
    private func parseGameRestore(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]
        var actions: [[String: Any]] = []  // 在外部聲明以累積所有 actions

        liqiLog("[LiqiParser] parseGameRestore: \(blocks.count) blocks")

        for block in blocks {
            liqiLog("[LiqiParser] gameRestore field \(block.fieldId), wireType \(block.wireType), size \(block.data.count)")

            switch block.fieldId {
            case 1: // snapshot (GameSnapshot)
                let stateBlocks = parseProtobufBlocks(block.data)
                result["gameState"] = parseGameStateProto(stateBlocks)
            case 2: // actions (repeated ActionPrototype)
                // 每個 field 2 block 包含一個 ActionPrototype
                // repeated 字段會有多個 field 2 blocks
                // 重要：gameRestore 中的 actions 不需要 XOR 解碼！
                let innerBlocks = parseProtobufBlocks(block.data)
                if let actionData = parseActionPrototype(innerBlocks, xorDecode: false) {
                    liqiLog("[LiqiParser] gameRestore parsed action: \(actionData["name"] ?? "unknown")")
                    actions.append(actionData)
                }
            case 4: // game_state
                if let (v, _) = parseVarint(block.data, offset: 0) {
                    result["game_state"] = v
                }
            default:
                break
            }
        }

        if !actions.isEmpty {
            result["actions"] = actions
            liqiLog("[LiqiParser] gameRestore total actions: \(actions.count)")
        }

        return result
    }

    /// 解析 `GameSnapshot`（重連時的局面快照）。
    ///
    /// 欄位編號依 `docs/protocol/liqi.json` 的 `.lq.GameSnapshot`：
    /// 1=chang, 2=ju, 3=ben, 4=index_player, 5=left_tile_count,
    /// 6=hands[repeated string], 7=doras[repeated string], 8=liqibang,
    /// 9=players[repeated PlayerSnapshot], 10=zhenting。
    ///
    /// 舊版的對照是 4=tiles、5=doras、6=scores、7=liqibang——沒有一個對。
    /// 於是這條後備路徑（重連且沒有 actions 可重放）產出的手牌是空的、
    /// 分數是把牌字串當 varint 解出來的垃圾，而畫面上看起來只是「重連後怪怪的」。
    private func parseGameStateProto(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]
        var hands: [String] = []
        var doras: [String] = []
        var scores: [Int] = []

        for block in blocks {
            switch block.fieldId {
            case 1: // chang
                if let (v, _) = parseVarint(block.data, offset: 0) { result["chang"] = v }
            case 2: // ju
                if let (v, _) = parseVarint(block.data, offset: 0) { result["ju"] = v }
            case 3: // ben
                if let (v, _) = parseVarint(block.data, offset: 0) { result["ben"] = v }
            case 4: // index_player
                if let (v, _) = parseVarint(block.data, offset: 0) { result["indexPlayer"] = v }
            case 5: // left_tile_count
                if let (v, _) = parseVarint(block.data, offset: 0) { result["leftTileCount"] = v }
            case 6: // hands（repeated string：自家手牌，一個 block 一張）
                if let tile = block.stringValue, isTileString(tile) {
                    hands.append(tile)
                } else {
                    recordFault(site: "GameSnapshot.hands",
                                fieldId: 6,
                                byteCount: block.data.count,
                                reason: "不是合法的牌字串：\(hexPreview(block.data))")
                }
            case 7: // doras（repeated string）
                if let tile = block.stringValue, isTileString(tile) {
                    doras.append(tile)
                } else {
                    recordFault(site: "GameSnapshot.doras",
                                fieldId: 7,
                                byteCount: block.data.count,
                                reason: "不是合法的牌字串：\(hexPreview(block.data))")
                }
            case 8: // liqibang
                if let (v, _) = parseVarint(block.data, offset: 0) { result["liqibang"] = v }
            case 9: // players（repeated PlayerSnapshot；score 是 field 1）
                if let score = parsePlayerSnapshotScore(block.data) {
                    scores.append(score)
                }
            case 10: // zhenting
                if let (v, _) = parseVarint(block.data, offset: 0) { result["zhenting"] = v != 0 }
            default:
                break
            }
        }

        // 手牌／寶牌用 `MajsoulBridge` 既有的 key 名，避免呼叫端跟著改
        result["tiles"] = hands
        result["doras"] = doras
        if !scores.isEmpty { result["scores"] = scores }

        return result
    }

    /// 從 `PlayerSnapshot` 取點數（liqi.json `.lq.GameSnapshot.PlayerSnapshot`：1=score int32）
    private func parsePlayerSnapshotScore(_ data: Data) -> Int? {
        for block in parseProtobufBlocks(data) where block.fieldId == 1 {
            if let (score, _) = parseVarint(block.data, offset: 0) { return score }
        }

        recordFault(site: "GameSnapshot.players.score",
                    fieldId: 9,
                    byteCount: data.count,
                    reason: "PlayerSnapshot 缺少 score：\(hexPreview(data))")
        return nil
    }

    // MARK: - Helper Methods

    private func parseOperation(_ data: Data) -> [String: Any] {
        let blocks = parseProtobufBlocks(data)
        var result: [String: Any] = [:]

        // operation_list 是 repeated OptionalOperation：wire 上會出現多個 field 2 block，
        // 每個 block 本身就是一筆 OptionalOperation。舊版每遇到一個就覆寫 result，
        // 且把單筆訊息再拆一層當成清單，導致可用操作永遠解不出來。
        var operations: [[String: Any]] = []

        for block in blocks {
            switch block.fieldId {
            case 1: // seat
                if let (v, _) = parseVarint(block.data, offset: 0) { result["seat"] = v }
            case 2: // operation_list（repeated，逐筆累積）
                operations.append(parseOptionalOperation(block.data))
            case 4: // timeAdd
                if let (v, _) = parseVarint(block.data, offset: 0) { result["timeAdd"] = v }
            case 5: // timeFixed
                if let (v, _) = parseVarint(block.data, offset: 0) { result["timeFixed"] = v }
            default:
                break
            }
        }

        result["operationList"] = operations
        return result
    }

    /// 解析單筆 `OptionalOperation`（1=type, 2=combination, 3=change_tiles）
    private func parseOptionalOperation(_ data: Data) -> [String: Any] {
        var op: [String: Any] = [:]
        var combination: [String] = []

        for block in parseProtobufBlocks(data) {
            switch block.fieldId {
            case 1: // type
                if let (v, _) = parseVarint(block.data, offset: 0) { op["type"] = v }
            case 2: // combination（repeated string，如 "1m|2m"）
                if let str = block.stringValue { combination.append(str) }
            case 3: // change_tiles（repeated string）
                if let str = block.stringValue {
                    var changes = op["changeTiles"] as? [String] ?? []
                    changes.append(str)
                    op["changeTiles"] = changes
                }
            default:
                break
            }
        }

        op["combination"] = combination
        return op
    }

    // tiles／hands／doras 一律照 `docs/protocol/liqi.json` 逐 block 解
    // （這些欄位是 `repeated string`，一個 block 就是一張牌），解不出來就記 fault。
    // 不要退回猜格式的 heuristic，尤其是逐 byte 掃 ASCII 找 `[0-9][mpsz]`：
    // 任何一段二進位資料都可能「掃出」幾張牌，掃出來的東西與真手牌無法區分。

    /// 檢查字符串是否為有效的牌表示
    private func isTileString(_ str: String) -> Bool {
        // 有效格式: [0-9][mps], [0-9][mps]r, [1-7]z
        let pattern = "^[0-9][mpsz]r?$"
        return str.range(of: pattern, options: .regularExpression) != nil
    }

    private func blocksToDict(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]

        for block in blocks {
            let key = "field\(block.fieldId)"

            if block.wireType == 0 {
                // Varint
                if let (v, _) = parseVarint(block.data, offset: 0) {
                    result[key] = v
                }
            } else if block.wireType == 2 {
                // String or nested
                if let str = block.stringValue, str.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-") }) {
                    result[key] = str
                } else {
                    result[key] = block.data.base64EncodedString()
                }
            }
        }

        return result
    }
}
