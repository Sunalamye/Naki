//
//  LiqiParser.swift
//  akagi
//
//  Created by Suoie on 2025/11/30.
//  雀魂 Protobuf 消息解析器 - 純 Swift 實現
//

import Foundation

// 使用 LogManager 的 liqiLog 函數

// MARK: - Message Types

/// 消息類型枚舉
enum LiqiMsgType: UInt8 {
    case notify = 1
    case request = 2
    case response = 3
}

// MARK: - XOR Decode Keys

/// 雀魂 XOR 解碼密鑰
private let xorKeys: [UInt8] = [0x84, 0x5e, 0x4e, 0x42, 0x39, 0xa2, 0x1f, 0x60, 0x1c]

/// XOR 解碼函數（用於解碼 action data）
func liqiDecode(_ data: Data) -> Data {
    var result = [UInt8](data)
    let len = result.count

    // 調試：顯示原始數據
    let rawPreview = data.prefix(min(30, data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
    liqiLog("[XOR] Input (\(len) bytes): \(rawPreview)")

    for i in 0..<len {
        let u = (23 ^ len) + 5 * i + Int(xorKeys[i % xorKeys.count])
        result[i] ^= UInt8(u & 0xFF)
    }

    // 調試：顯示解碼後數據
    let decodedPreview = result.prefix(min(30, result.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
    liqiLog("[XOR] Output (\(len) bytes): \(decodedPreview)")

    return Data(result)
}

// MARK: - Varint Parsing

/// 解析 Protobuf Varint
func parseVarint(_ data: Data, offset: Int) -> (value: Int, newOffset: Int)? {
    var result = 0
    var shift = 0
    var pos = offset

    while pos < data.count {
        let byte = data[pos]
        result |= Int(byte & 0x7F) << shift
        shift += 7
        pos += 1

        if byte & 0x80 == 0 {
            return (result, pos)
        }

        // 防止溢出
        if shift > 63 {
            return nil
        }
    }

    return nil
}

// MARK: - Protobuf Block

/// Protobuf 數據塊
struct ProtobufBlock {
    let fieldId: Int
    let wireType: Int
    let data: Data

    var stringValue: String? {
        return String(data: data, encoding: .utf8)
    }

    var varintValue: Int? {
        guard wireType == 0, let (value, _) = parseVarint(data, offset: 0) else {
            return nil
        }
        return value
    }
}

/// 從 Protobuf 二進制數據解析出塊列表
func parseProtobufBlocks(_ data: Data) -> [ProtobufBlock] {
    var blocks: [ProtobufBlock] = []
    var offset = 0

    while offset < data.count {
        let tag = data[offset]
        let wireType = Int(tag & 0x07)
        let fieldId = Int(tag >> 3)
        offset += 1

        switch wireType {
        case 0: // Varint
            guard let (_, newOffset) = parseVarint(data, offset: offset) else {
                return blocks
            }
            // 存儲原始 varint 字節（包含正確的編碼）
            let varintData = data.subdata(in: offset..<newOffset)
            blocks.append(ProtobufBlock(fieldId: fieldId, wireType: wireType, data: varintData))
            offset = newOffset

        case 2: // Length-delimited (string, bytes, embedded message)
            guard let (length, newOffset) = parseVarint(data, offset: offset) else {
                return blocks
            }
            offset = newOffset

            guard offset + length <= data.count else {
                return blocks
            }

            let blockData = data.subdata(in: offset..<(offset + length))
            blocks.append(ProtobufBlock(fieldId: fieldId, wireType: wireType, data: blockData))
            offset += length

        default:
            // 跳過未知類型
            return blocks
        }
    }

    return blocks
}

// MARK: - Liqi Parser

/// 雀魂協議解析器
class LiqiParser {

    /// 請求 ID 到方法名的映射
    private var pendingRequests: [Int: String] = [:]

    /// 當前消息 ID
    private var currentMsgId: Int = 1

    /// 重置解析器狀態
    func reset() {
        pendingRequests.removeAll()
        currentMsgId = 1
    }

    /// 解析雀魂消息
    /// - Parameter data: 原始二進制消息
    /// - Returns: 解析後的消息字典，包含 type, method, data 等字段
    func parse(_ data: Data) -> [String: Any]? {
        guard data.count >= 3 else {
            liqiLog("[LiqiParser] Message too short: \(data.count) bytes")
            return nil
        }

        let firstByte = data[0]
        liqiLog("[LiqiParser] First byte: \(firstByte), data size: \(data.count)")

        guard let msgType = LiqiMsgType(rawValue: firstByte) else {
            liqiLog("[LiqiParser] Unknown message type: \(firstByte)")
            // 嘗試顯示前幾個字節用於調試
            let preview = data.prefix(min(20, data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
            liqiLog("[LiqiParser] Data preview: \(preview)")
            return nil
        }

        liqiLog("[LiqiParser] Message type: \(msgType)")

        switch msgType {
        case .notify:
            return parseNotify(data.subdata(in: 1..<data.count))

        case .request:
            let msgId = Int(data[1]) | (Int(data[2]) << 8)
            return parseRequest(msgId: msgId, data: data.subdata(in: 3..<data.count))

        case .response:
            let msgId = Int(data[1]) | (Int(data[2]) << 8)
            return parseResponse(msgId: msgId, data: data.subdata(in: 3..<data.count))
        }
    }

    // MARK: - Private Methods

    private func parseNotify(_ data: Data) -> [String: Any]? {
        // 顯示原始通知數據
        let rawPreview = data.prefix(min(60, data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
        liqiLog("[LiqiParser] parseNotify raw data (\(data.count) bytes): \(rawPreview)")

        let blocks = parseProtobufBlocks(data)
        liqiLog("[LiqiParser] parseNotify: \(blocks.count) blocks")

        for (i, block) in blocks.enumerated() {
            let blockPreview = block.data.prefix(min(30, block.data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
            liqiLog("[LiqiParser] parseNotify block[\(i)]: fieldId=\(block.fieldId), wireType=\(block.wireType), size=\(block.data.count), data=\(blockPreview)")
        }

        guard blocks.count >= 2 else {
            liqiLog("[LiqiParser] parseNotify: Not enough blocks")
            return nil
        }

        guard let methodName = blocks[0].stringValue else {
            liqiLog("[LiqiParser] parseNotify: First block is not a string")
            let preview = blocks[0].data.prefix(min(20, blocks[0].data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
            liqiLog("[LiqiParser] First block data: \(preview)")
            return nil
        }

        liqiLog("[LiqiParser] parseNotify method: \(methodName)")

        let innerData = blocks[1].data

        // 解析內部數據
        var result: [String: Any] = [
            "id": -1,
            "type": "notify",
            "method": methodName
        ]

        // 嘗試解析內部 protobuf
        if let parsedData = parseInnerMessage(methodName: methodName, data: innerData) {
            result["data"] = parsedData
        } else {
            // 返回原始數據
            result["rawData"] = innerData.base64EncodedString()
        }

        return result
    }

    private func parseRequest(msgId: Int, data: Data) -> [String: Any]? {
        let blocks = parseProtobufBlocks(data)
        liqiLog("[LiqiParser] parseRequest msgId=\(msgId), \(blocks.count) blocks")

        guard blocks.count >= 2,
              let methodName = blocks[0].stringValue else {
            liqiLog("[LiqiParser] parseRequest: not enough blocks or no method name")
            return nil
        }

        liqiLog("[LiqiParser] parseRequest method: \(methodName)")

        // 記錄請求以便匹配響應
        pendingRequests[msgId] = methodName
        currentMsgId = msgId

        let innerData = blocks[1].data

        var result: [String: Any] = [
            "id": msgId,
            "type": "request",
            "method": methodName
        ]

        if let parsedData = parseInnerMessage(methodName: methodName, data: innerData) {
            result["data"] = parsedData
        }

        return result
    }

    private func parseResponse(msgId: Int, data: Data) -> [String: Any]? {
        let blocks = parseProtobufBlocks(data)
        liqiLog("[LiqiParser] parseResponse msgId=\(msgId), \(blocks.count) blocks, pending=\(pendingRequests.keys.sorted())")

        guard let methodName = pendingRequests.removeValue(forKey: msgId) else {
            liqiLog("[LiqiParser] parseResponse: no pending request for msgId=\(msgId)")
            // 嘗試解析響應數據以查看內容
            if !blocks.isEmpty && blocks[0].data.count > 0 {
                let previewData = blocks[0].data
                let previewCount = min(30, previewData.count)
                let preview = previewData.prefix(previewCount).map { String(format: "%02x", $0) }.joined(separator: " ")
                liqiLog("[LiqiParser] Response block[0] preview: \(preview)")
            }
            return nil
        }

        // 響應的第一個塊通常是空的
        let innerData = blocks.count >= 2 ? blocks[1].data : Data()

        var result: [String: Any] = [
            "id": msgId,
            "type": "response",
            "method": methodName
        ]

        if let parsedData = parseInnerMessage(methodName: methodName, data: innerData, isResponse: true) {
            result["data"] = parsedData
        }

        return result
    }

    /// 解析內部消息（根據方法名）
    private func parseInnerMessage(methodName: String, data: Data, isResponse: Bool = false) -> [String: Any]? {
        // 調試：顯示內部消息原始數據
        let rawPreview = data.prefix(min(80, data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
        liqiLog("[LiqiParser] parseInnerMessage: method=\(methodName), dataSize=\(data.count)")
        liqiLog("[LiqiParser] parseInnerMessage raw: \(rawPreview)")

        let innerBlocks = parseProtobufBlocks(data)
        liqiLog("[LiqiParser] parseInnerMessage: \(innerBlocks.count) inner blocks")

        // 顯示每個內部塊
        for (i, block) in innerBlocks.enumerated() {
            let blockPreview = block.data.prefix(min(40, block.data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
            liqiLog("[LiqiParser] innerBlock[\(i)]: fieldId=\(block.fieldId), wireType=\(block.wireType), size=\(block.data.count)")
            if block.wireType == 2 {
                if let str = block.stringValue, str.count < 50 {
                    liqiLog("[LiqiParser] innerBlock[\(i)] string: \(str)")
                } else {
                    liqiLog("[LiqiParser] innerBlock[\(i)] bytes: \(blockPreview)")
                }
            }
        }

        // 根據消息類型進行特定解析
        if methodName == ".lq.ActionPrototype" {
            return parseActionPrototype(innerBlocks)
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
    /// - Parameter xorDecode: 是否需要 XOR 解碼。
    ///   - Notify 訊息的 ActionPrototype 需要 XOR 解碼 (true)
    ///   - SyncGame/GameRestore 的 actions 不需要 XOR 解碼 (false)
    private func parseActionPrototype(_ blocks: [ProtobufBlock], xorDecode: Bool = true) -> [String: Any]? {
        var result: [String: Any] = [:]
        var actionName: String = ""
        var actionData: Data? = nil

        liqiLog("[LiqiParser] parseActionPrototype: \(blocks.count) blocks, xorDecode=\(xorDecode)")

        // 使用 field ID 來正確識別字段
        // ActionPrototype 結構:
        // - field 1: step (varint)
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
                }

            case 3: // data
                actionData = block.data
                let rawPreview = block.data.prefix(min(40, block.data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
                liqiLog("[LiqiParser] ActionPrototype data (raw): \(rawPreview)")

            default:
                // 其他字段，顯示用於調試
                if block.wireType == 2 {
                    let rawPreview = block.data.prefix(min(40, block.data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
                    liqiLog("[LiqiParser] ActionPrototype unknown field \(block.fieldId): \(rawPreview)")

                    // 備用邏輯：如果沒有找到 field 3，嘗試用這個作為 data
                    if actionData == nil {
                        actionData = block.data
                    }
                }
            }
        }

        // 處理 data 欄位
        if let data = actionData {
            liqiLog("[LiqiParser] ActionPrototype: name='\(actionName)', data size=\(data.count) bytes")

            // 如果 data 為空，記錄警告
            if data.count == 0 {
                liqiLog("[LiqiParser] WARNING: ActionPrototype '\(actionName)' has empty data!")
                result["data"] = [String: Any]()
                return result
            }

            // 根據 xorDecode 參數決定是否進行 XOR 解碼
            let decodedData: Data
            if xorDecode {
                decodedData = liqiDecode(data)
                let preview = decodedData.prefix(min(50, decodedData.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
                liqiLog("[LiqiParser] ActionPrototype '\(actionName)' XOR decoded: \(preview)")
            } else {
                decodedData = data
                let preview = decodedData.prefix(min(50, decodedData.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
                liqiLog("[LiqiParser] ActionPrototype '\(actionName)' raw (no XOR): \(preview)")
            }

            let actionBlocks = parseProtobufBlocks(decodedData)
            liqiLog("[LiqiParser] ActionPrototype parsed \(actionBlocks.count) action blocks")

            // 如果還沒有找到 name，嘗試從解碼後的數據中找
            if actionName.isEmpty {
                for ab in actionBlocks {
                    if ab.wireType == 2, let str = ab.stringValue, str.hasPrefix("Action") {
                        actionName = str
                        result["name"] = str
                        liqiLog("[LiqiParser] ActionPrototype name from data: \(str)")
                        break
                    }
                }
            }

            result["data"] = parseActionData(name: actionName, blocks: actionBlocks)
        }

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

    private func parseActionNewRound(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]
        var tiles: [String] = []  // 累積所有手牌

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
            case 6: // scores
                // 調試: 打印原始數據
                let rawHex = block.data.map { String(format: "%02x", $0) }.joined(separator: " ")
                liqiLog("[LiqiParser] NewRound field 6 (scores) raw bytes: \(rawHex)")
                liqiLog("[LiqiParser] NewRound field 6 wireType: \(block.wireType), size: \(block.data.count)")

                // 嘗試解析為 packed int32
                let scores = parsePackedInt32(block.data)
                liqiLog("[LiqiParser] NewRound scores parsed: \(scores)")
                result["scores"] = scores
            case 7: // liqibang (立直棒)
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
                    let rawPreview = block.data.prefix(min(20, block.data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
                    liqiLog("[LiqiParser] DealTile tile field not a valid string, raw: \(rawPreview)")
                }
            case 3: // left_tile_count
                if let (v, _) = parseVarint(block.data, offset: 0) {
                    result["leftTileCount"] = v
                    liqiLog("[LiqiParser] DealTile leftTileCount: \(v)")
                }
            case 4: // revealed tiles (明牌)
                if let tile = block.stringValue {
                    result["tile"] = tile
                    liqiLog("[LiqiParser] DealTile tile from field 4: \(tile)")
                }
            case 5: // liqi (立直後的自摸)
                result["liqi"] = parseProtobufBlocks(block.data).count > 0
            case 6: // 可能是另一種格式的 tile
                if let tile = block.stringValue {
                    if result["tile"] == nil {
                        result["tile"] = tile
                        liqiLog("[LiqiParser] DealTile tile from field 6: \(tile)")
                    }
                }
            case 7: // 未知字段，可能包含 tile 信息
                let rawPreview = block.data.prefix(min(20, block.data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
                liqiLog("[LiqiParser] DealTile field 7 raw: \(rawPreview)")
                if block.wireType == 2, let tile = block.stringValue {
                    liqiLog("[LiqiParser] DealTile field 7 as string: \(tile)")
                }
            case 8: // doras
                result["doras"] = parseTileList(block.data)
            case 11: // operation (可選操作)
                result["operation"] = parseOperation(block.data)
                liqiLog("[LiqiParser] DealTile has operation data")
            default:
                // 記錄未知字段
                let rawPreview = block.data.prefix(min(20, block.data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
                liqiLog("[LiqiParser] DealTile unknown field \(block.fieldId): \(rawPreview)")
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
            case 3: // is_liqi (是否立直)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["isLiqi"] = v != 0 }
            case 5: // moqie (是否摸切)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["moqie"] = v != 0 }
            case 7: // is_wliqi (是否 W 立直)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["isWliqi"] = v != 0 }
            case 8: // doras
                result["doras"] = parseTileList(block.data)
            case 11: // operation
                result["operation"] = parseOperation(block.data)
            default:
                break
            }
        }

        return result
    }

    private func parseActionChiPengGang(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]
        var tiles: [String] = []  // ⭐ 累積所有 tiles

        for block in blocks {
            switch block.fieldId {
            case 1: // seat
                if let (v, _) = parseVarint(block.data, offset: 0) { result["seat"] = v }
            case 2: // type (0=chi, 1=pon, 2=daiminkan)
                if let (v, _) = parseVarint(block.data, offset: 0) { result["type"] = v }
            case 3: // tiles - repeated string, 每個 block 是一張牌
                // ⭐ 對於 repeated 字段，每個 block 包含一張牌，需要累積
                if let tile = block.stringValue, isTileString(tile) {
                    tiles.append(tile)
                    liqiLog("[LiqiParser] ChiPengGang tile: \(tile)")
                } else {
                    // 備用：使用 parseTileList
                    let parsed = parseTileList(block.data)
                    tiles.append(contentsOf: parsed)
                }
            case 4: // froms (從哪個玩家拿的牌)
                result["froms"] = parseIntList(block.data)
            case 5: // operation
                result["operation"] = parseOperation(block.data)
            default:
                break
            }
        }

        // ⭐ 設置累積的 tiles
        result["tiles"] = tiles
        liqiLog("[LiqiParser] ChiPengGang tiles accumulated: \(tiles)")

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
            case 5: // operation
                result["operation"] = parseOperation(block.data)
            default:
                break
            }
        }

        return result
    }

    private func parseActionHule(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = ["type": "hule"]

        for block in blocks {
            switch block.fieldId {
            case 1: // hules (和牌信息列表)
                // 複雜結構，簡化處理
                result["hules"] = parseProtobufBlocks(block.data).count
            case 3: // scores
                result["scores"] = parseIntList(block.data)
            default:
                break
            }
        }

        return result
    }

    private func parseActionBaBei(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]

        for block in blocks {
            switch block.fieldId {
            case 1: // seat
                if let (v, _) = parseVarint(block.data, offset: 0) { result["seat"] = v }
            default:
                break
            }
        }

        return result
    }

    // MARK: - Auth Game Response

    private func parseAuthGameResponse(_ blocks: [ProtobufBlock]) -> [String: Any]? {
        var result: [String: Any] = [:]
        var seatList: [Int] = []
        var playerAccountIds: [Int] = []  // 從 PlayerGameView 提取的 accountIds（按 field 順序）

        liqiLog("[LiqiParser] parseAuthGameResponse: \(blocks.count) blocks")

        for block in blocks {
            liqiLog("[LiqiParser] authGame field \(block.fieldId), wireType \(block.wireType), size \(block.data.count)")

            switch block.fieldId {
            case 2: // players (repeated PlayerGameView) - 每個玩家依座位順序排列
                // 解析 PlayerGameView 提取 account_id（僅用於備用）
                let playerBlocks = parseProtobufBlocks(block.data)
                for playerBlock in playerBlocks {
                    if playerBlock.fieldId == 1 { // account_id
                        if let (accountId, _) = parseVarint(playerBlock.data, offset: 0) {
                            playerAccountIds.append(accountId)
                            liqiLog("[LiqiParser] PlayerGameView accountId: \(accountId)")
                        }
                    }
                }
            case 3: // seat_list (packed repeated uint32) - ⭐ 這是正確的 seatList！
                // Python 使用這個: seatList = liqi_message['data']['seatList']
                let packedList = parsePackedUInt32(block.data)
                if !packedList.isEmpty {
                    seatList = packedList
                    liqiLog("[LiqiParser] ⭐ Using field 3 seatList: \(packedList)")
                }
            case 4: // isGameStart
                if let (v, _) = parseVarint(block.data, offset: 0) { result["isGameStart"] = v != 0 }
            case 5: // gameConfig
                result["gameConfig"] = blocksToDict(parseProtobufBlocks(block.data))
            default:
                break
            }
        }

        // ⭐ 優先使用 field 3 的 seatList（這是 Python 的做法）
        // seatList[座位] = accountId，用戶座位 = seatList.firstIndex(of: userAccountId)
        if !seatList.isEmpty {
            result["seatList"] = seatList
            liqiLog("[LiqiParser] Final seatList (from field 3): \(seatList)")
        } else if !playerAccountIds.isEmpty {
            // 備用方案：使用 PlayerGameView 的順序（可能不正確）
            result["seatList"] = playerAccountIds
            liqiLog("[LiqiParser] Final seatList (fallback from players): \(playerAccountIds)")
        } else {
            liqiLog("[LiqiParser] ERROR: No seatList found in authGame response!")
        }

        return result
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
            case 2: // token
                result["token"] = String(data: block.data, encoding: .utf8) ?? ""
            case 3: // game_uuid
                result["gameUuid"] = String(data: block.data, encoding: .utf8) ?? ""
            default:
                break
            }
        }

        return result
    }

    /// 解析 packed repeated uint32
    private func parsePackedUInt32(_ data: Data) -> [Int] {
        var result: [Int] = []
        var offset = 0
        while offset < data.count {
            if let (value, newOffset) = parseVarint(data, offset: offset) {
                result.append(value)
                offset = newOffset
            } else {
                break
            }
        }
        return result
    }

    /// 解析 packed repeated int32 (帶符號)
    /// Protobuf 的 int32 使用 zigzag 編碼: (n << 1) ^ (n >> 31)
    private func parsePackedInt32(_ data: Data) -> [Int] {
        var result: [Int] = []
        var offset = 0

        // 首先嘗試作為 packed varints 解析
        while offset < data.count {
            if let (value, newOffset) = parseVarint(data, offset: offset) {
                // 嘗試 zigzag 解碼 (sint32 格式)
                // 注意: 普通 int32 不使用 zigzag，但分數可能使用 sint32
                result.append(value)
                offset = newOffset
            } else {
                break
            }
        }

        // 如果結果看起來不像分數 (應該是 4 個在 0-100000 範圍內的數字)
        // 可能是編碼問題
        if result.count != 4 || result.contains(where: { $0 < 0 || $0 > 200000 }) {
            liqiLog("[LiqiParser] parsePackedInt32: unusual scores \(result), checking if data is nested message")

            // 嘗試解析為嵌套消息
            let blocks = parseProtobufBlocks(data)
            if !blocks.isEmpty {
                var nestedScores: [Int] = []
                for block in blocks {
                    if let (v, _) = parseVarint(block.data, offset: 0) {
                        nestedScores.append(v)
                    }
                }
                if nestedScores.count == 4 {
                    liqiLog("[LiqiParser] parsePackedInt32: found nested scores \(nestedScores)")
                    return nestedScores
                }
            }

            // 如果還是不對，返回默認分數
            if result.count != 4 {
                liqiLog("[LiqiParser] parsePackedInt32: falling back to default scores")
                return [25000, 25000, 25000, 25000]
            }
        }

        return result
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

    /// 解析遊戲狀態 Protobuf
    private func parseGameStateProto(_ blocks: [ProtobufBlock]) -> [String: Any] {
        var result: [String: Any] = [:]

        for block in blocks {
            switch block.fieldId {
            case 1: // chang
                if let (v, _) = parseVarint(block.data, offset: 0) { result["chang"] = v }
            case 2: // ju
                if let (v, _) = parseVarint(block.data, offset: 0) { result["ju"] = v }
            case 3: // ben
                if let (v, _) = parseVarint(block.data, offset: 0) { result["ben"] = v }
            case 4: // tiles (手牌)
                result["tiles"] = parseTileList(block.data)
            case 5: // doras
                result["doras"] = parseTileList(block.data)
            case 6: // scores
                result["scores"] = parseIntList(block.data)
            case 7: // liqibang
                if let (v, _) = parseVarint(block.data, offset: 0) { result["liqibang"] = v }
            default:
                break
            }
        }

        return result
    }

    // MARK: - Helper Methods

    private func parseOperation(_ data: Data) -> [String: Any] {
        let blocks = parseProtobufBlocks(data)
        var result: [String: Any] = [:]

        for block in blocks {
            switch block.fieldId {
            case 1: // seat
                if let (v, _) = parseVarint(block.data, offset: 0) { result["seat"] = v }
            case 2: // operationList
                result["operationList"] = parseOperationList(block.data)
            case 4: // timeAdd
                if let (v, _) = parseVarint(block.data, offset: 0) { result["timeAdd"] = v }
            case 5: // timeFixed
                if let (v, _) = parseVarint(block.data, offset: 0) { result["timeFixed"] = v }
            default:
                break
            }
        }

        return result
    }

    private func parseOperationList(_ data: Data) -> [[String: Any]] {
        var results: [[String: Any]] = []
        let blocks = parseProtobufBlocks(data)

        for block in blocks {
            if block.wireType == 2 {
                let opBlocks = parseProtobufBlocks(block.data)
                var op: [String: Any] = [:]
                for opBlock in opBlocks {
                    switch opBlock.fieldId {
                    case 1: // type
                        if let (v, _) = parseVarint(opBlock.data, offset: 0) { op["type"] = v }
                    case 2: // combination
                        op["combination"] = parseTileList(opBlock.data)
                    default:
                        break
                    }
                }
                results.append(op)
            }
        }

        return results
    }

    private func parseTileList(_ data: Data) -> [String] {
        var tiles: [String] = []

        let rawPreview = data.prefix(min(60, data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
        liqiLog("[LiqiParser] parseTileList: \(data.count) bytes, raw: \(rawPreview)")

        // ⭐ 對於小數據（2-3 字節），優先嘗試直接解析為牌字符串
        // 這避免了 "8s" (38 73) 被錯誤解析為 protobuf tag 的問題
        if data.count >= 2 && data.count <= 3 {
            if let tile = String(data: data, encoding: .utf8), isTileString(tile) {
                liqiLog("[LiqiParser] parseTileList using direct string (small data): \(tile)")
                return [tile]
            }
        }

        let blocks = parseProtobufBlocks(data)
        liqiLog("[LiqiParser] parseTileList: \(blocks.count) blocks parsed")

        for block in blocks {
            liqiLog("[LiqiParser] parseTileList block: fieldId=\(block.fieldId), wireType=\(block.wireType), size=\(block.data.count)")
            if let tile = block.stringValue, isTileString(tile) {
                tiles.append(tile)
                liqiLog("[LiqiParser] parseTileList found tile: \(tile)")
            }
        }

        // 如果沒有嵌套塊，嘗試直接解析字符串
        if tiles.isEmpty, let tile = String(data: data, encoding: .utf8), isTileString(tile) {
            liqiLog("[LiqiParser] parseTileList using direct string: \(tile)")
            return [tile]
        }

        // 如果還是空的，嘗試另一種解析方式（tile 可能是連續的字符串）
        if tiles.isEmpty {
            // 嘗試將數據按照 2-3 字節的字符串解析
            var offset = 0
            while offset < data.count {
                // 檢查是否是有效的牌字符串開頭 (數字 1-9 或字母)
                let b = data[offset]
                if (b >= 0x31 && b <= 0x39) || b == 0x30 { // '0'-'9'
                    // 可能是牌字符串
                    if offset + 1 < data.count {
                        let suit = data[offset + 1]
                        if suit == 0x6d || suit == 0x70 || suit == 0x73 || suit == 0x7a { // 'm', 'p', 's', 'z'
                            if offset + 2 < data.count && data[offset + 2] == 0x72 { // 'r' (red five)
                                tiles.append(String(format: "%c%c%c", b, suit, data[offset + 2]))
                                offset += 3
                            } else {
                                tiles.append(String(format: "%c%c", b, suit))
                                offset += 2
                            }
                            continue
                        }
                    }
                }
                offset += 1
            }
            if !tiles.isEmpty {
                liqiLog("[LiqiParser] parseTileList using byte scan: \(tiles)")
            }
        }

        liqiLog("[LiqiParser] parseTileList result: \(tiles)")
        return tiles
    }

    /// 檢查字符串是否為有效的牌表示
    private func isTileString(_ str: String) -> Bool {
        // 有效格式: [0-9][mps], [0-9][mps]r, [1-7]z
        let pattern = "^[0-9][mpsz]r?$"
        return str.range(of: pattern, options: .regularExpression) != nil
    }

    private func parseIntList(_ data: Data) -> [Int] {
        var values: [Int] = []
        var offset = 0

        while offset < data.count {
            if let (value, newOffset) = parseVarint(data, offset: offset) {
                values.append(value)
                offset = newOffset
            } else {
                break
            }
        }

        // 處理 packed repeated
        if values.isEmpty {
            let blocks = parseProtobufBlocks(data)
            for block in blocks {
                if let (v, _) = parseVarint(block.data, offset: 0) {
                    values.append(v)
                }
            }
        }

        return values
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
