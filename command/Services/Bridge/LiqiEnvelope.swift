//
//  LiqiEnvelope.swift
//  Naki
//
//  Liqi wire 格式的單一事實來源：varint、protobuf block、envelope 的**解與編**。
//
//  ## 同一份協定知識只有一份
//
//  Swift 側只有本檔知道 envelope 的形狀，`LiqiParser` 與 `LiqiEncoder`
//  都經過這裡，`LiqiEnvelopeTests` 用 round-trip 把「解」與「編」鎖成同一份定義。
//  拆成「拆一份、組一份」沒有任何機制保證一致，會漂成**自己編出來的 notify 自己解不開**
//  （NOTIFY 沒有 msgId；組的那份多寫 2 bytes，拆的那份從 offset 1 開始）。
//  JS 那份刻意保留（跨語言邊界，同步成本高於重複成本），但 canonical 在這裡，
//  該檔檔頭已註明。
//
//  ## 格式（實測封包驗證，見 docs/majsoul-unity-protocol.md）
//
//      REQUEST / RESPONSE : [type:1][msgId:2 LE][protobuf{1=method, 2=payload}]
//      NOTIFY             : [type:1][protobuf{1=method, 2=payload}]   ← 沒有 msgId
//
//  RESPONSE 的 field 1 是空的：方法名要用 msgId 對回當初送出的 REQUEST。
//  那份 msgId→method 對照表全 Swift 只有一份，在 `LiqiParser.pendingRequests`
//  （送出面的 frame 會經過 JS 的 `ws.send` hook 回到 `MajsoulBridge.parseRaw`，
//  所以連 Naki 自己送的請求也在那份表裡）。
//
//  注意：envelope 本身**沒有** XOR。XOR 只作用在 notify 的 ActionPrototype.data
//  （見 `liqiDecode`），不要在這一層套用。
//

import Foundation

// MARK: - Message Types

/// 消息類型枚舉
enum LiqiMsgType: UInt8 {
    case notify = 1
    case request = 2
    case response = 3

    /// 這個 type 的 envelope 標頭佔幾個 byte。
    ///
    /// NOTIFY 是伺服器單向推播，沒有要配對的請求，所以**沒有 msgId**。
    /// 這一個值同時決定「解」從哪裡開始與「編」寫幾個 byte，兩邊不可能再各寫各的。
    var headerByteCount: Int { self == .notify ? 1 : 3 }
}

// MARK: - Protobuf Wire Type

/// Protobuf wire type（本專案的編碼端目前只需要 varint 與 length-delimited）
enum LiqiWireType: UInt8 {
    case varint = 0
    case lengthDelimited = 2
}

// MARK: - Varint（唯一實作）

/// protobuf varint 的解與編。
///
/// `nonisolated`：`LiqiResponseRecord`（nonisolated struct）要用它解 `Error.code`。
/// varint 全專案只有這一份實作——同一個格式兩份規則（例如溢位上限一邊 35 bits、
/// 一邊 63 bits）是最典型的靜默漂移來源。
nonisolated enum LiqiWire {

    /// 解一個 protobuf varint
    /// - Returns: 值與下一個位元組的 offset；bytes 不完整或超過 64 bit 回 nil
    static func decodeVarint(_ data: Data, offset: Int) -> (value: Int, newOffset: Int)? {
        var result = 0
        var shift = 0
        var pos = offset

        while pos < data.count {
            // 溢位檢查必須在 `result |=` **之前**、而且是 `>=`。
            //
            // 舊版寫在 `shift += 7` 之後且用 `> 63`：第 9 個 byte 把 shift 推到 63，
            // `63 > 63` 為 false 於是放行；第 10 個 byte 的 `<< 63` 正好打在 `Int` 的
            // 符號位上，若那個 byte 的最高位是 0 就直接把**負數**回傳出去。
            // 下游沒有一處預期負值：`BAKAZE_NAMES[chang % 4]` 在 Swift 對負數取模
            // 仍是負數，於是變成 `[-1]`——陣列越界在 Swift 是 trap，不可 catch，
            // 整個 App 當場結束。
            //
            // 這裡最多接受 9 bytes（63 bits）。liqi 的每個欄位都是小正數，
            // 超過就是畸形輸入或解錯位（例如 XOR 規則變了解出近似隨機 bytes）。
            if shift >= 63 {
                return nil
            }

            let byte = data[pos]
            result |= Int(byte & 0x7F) << shift
            shift += 7
            pos += 1

            if byte & 0x80 == 0 {
                return (result, pos)
            }
        }

        return nil
    }

    /// 編一個 protobuf varint（base-128，little-endian groups）
    ///
    /// - 0 → `[0x00]`、127 → `[0x7f]`、128 → `[0x80, 0x01]`、300 → `[0xac, 0x02]`
    /// - `UInt64.max` → 10 bytes
    static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            out.append(byte)
        } while remaining != 0
        return out
    }
}

/// 解析 Protobuf Varint（`LiqiWire.decodeVarint` 的舊名；呼叫端很多，保留為薄殼）
func parseVarint(_ data: Data, offset: Int) -> (value: Int, newOffset: Int)? {
    LiqiWire.decodeVarint(data, offset: offset)
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
}

/// 從 Protobuf 二進制數據解析出塊列表
func parseProtobufBlocks(_ data: Data) -> [ProtobufBlock] {
    var blocks: [ProtobufBlock] = []
    var offset = 0

    while offset < data.count {
        // tag 本身是 varint：field >= 16 要兩個 bytes（19 → 0x98 0x01）。
        // 舊版只讀一個 byte 就當成 tag，於是 field >= 16 之後整條訊息**錯位**：
        // 值的 bytes 會被當成下一個 tag，解出一堆 fieldId 與 wireType 都是假的 block
        // ——其中任何一個假 fieldId 撞到真欄位（例如 6 = scores）就會覆蓋掉正確的值。
        // liqi.json 裡 field >= 16 很常見（ActionNewRound 16/17/19/20/21/26、
        // HuleInfo 15…27），所以這不是理論問題。
        guard let (tag, tagEnd) = parseVarint(data, offset: offset) else {
            liqiLog("[LiqiParser] parseProtobufBlocks: tag 解不出來 at offset \(offset)，停止（保留 \(blocks.count) blocks）")
            return blocks
        }
        let wireType = tag & 0x07
        let fieldId = tag >> 3
        offset = tagEnd

        // field 0 不是合法欄位編號；出現它代表這段 bytes 不是我們以為的 protobuf
        guard fieldId >= 1 else {
            liqiLog("[LiqiParser] parseProtobufBlocks: 非法 field 0（tag=\(tag)），停止（保留 \(blocks.count) blocks）")
            return blocks
        }

        switch wireType {
        case 0: // Varint
            guard let (_, newOffset) = parseVarint(data, offset: offset) else {
                return blocks
            }
            // 存儲原始 varint 字節（包含正確的編碼）
            let varintData = data.subdata(in: offset..<newOffset)
            blocks.append(ProtobufBlock(fieldId: fieldId, wireType: wireType, data: varintData))
            offset = newOffset

        case 1: // 64-bit (fixed64 / sfixed64 / double) — 正確跳過 8 bytes
            guard offset + 8 <= data.count else {
                liqiLog("[LiqiParser] parseProtobufBlocks: fixed64 field \(fieldId) truncated at offset \(offset), stopping (kept \(blocks.count) blocks)")
                return blocks
            }
            offset += 8

        case 2: // Length-delimited (string, bytes, embedded message)
            guard let (length, newOffset) = parseVarint(data, offset: offset) else {
                return blocks
            }
            offset = newOffset

            // 防護：length 必須非負，且不超過剩餘資料長度。
            // 先比較 length 與 (data.count - offset)（此時 offset <= data.count），
            // 避免直接算 offset + length 時被超大 varint 造成整數溢位/越界。
            guard length >= 0, length <= data.count - offset else {
                liqiLog("[LiqiParser] parseProtobufBlocks: length-delimited field \(fieldId) invalid length \(length) (remaining \(data.count - offset)), stopping (kept \(blocks.count) blocks)")
                return blocks
            }

            let blockData = data.subdata(in: offset..<(offset + length))
            blocks.append(ProtobufBlock(fieldId: fieldId, wireType: wireType, data: blockData))
            offset += length

        case 5: // 32-bit (fixed32 / sfixed32 / float) — 正確跳過 4 bytes
            guard offset + 4 <= data.count else {
                liqiLog("[LiqiParser] parseProtobufBlocks: fixed32 field \(fieldId) truncated at offset \(offset), stopping (kept \(blocks.count) blocks)")
                return blocks
            }
            offset += 4

        default:
            // wireType 3/4 為已棄用的 group start/end；長度未知無法安全跳過，
            // 安全中止並記錄，但保留已解析出的 blocks（不因單一未知欄位丟掉整條訊息）。
            liqiLog("[LiqiParser] parseProtobufBlocks: unsupported wireType \(wireType) at field \(fieldId), stopping (kept \(blocks.count) blocks)")
            return blocks
        }
    }

    return blocks
}

// MARK: - Envelope

/// 解 envelope 失敗的原因（帶得出上下文，呼叫端不必再解一次來查為什麼）
enum LiqiEnvelopeDecodeFailure: Error, CustomStringConvertible {
    /// 連標頭都不夠長
    case tooShort(byteCount: Int)
    /// 第一個 byte 不是 1/2/3
    case unknownType(UInt8, byteCount: Int)
    /// wrapper 少了 method 或 payload block
    case notEnoughBlocks(type: LiqiMsgType, blocks: Int, byteCount: Int)
    /// field 1 存在但不是合法 UTF-8
    case methodNotUTF8(type: LiqiMsgType, byteCount: Int)

    var description: String {
        switch self {
        case let .tooShort(byteCount):
            return "訊息太短（\(byteCount) bytes）"
        case let .unknownType(raw, byteCount):
            return "未知的訊息類型 \(raw)（\(byteCount) bytes）"
        case let .notEnoughBlocks(type, blocks, byteCount):
            return "\(type) wrapper 只有 \(blocks) 個 block（\(byteCount) bytes），"
                + "取不到 method/payload"
        case let .methodNotUTF8(type, byteCount):
            return "\(type) 的 method 不是合法 UTF-8（\(byteCount) bytes）"
        }
    }
}

/// 一則 Liqi 訊息的外層信封。
///
/// `decode` 與 `encoded` 是同一份格式定義的兩個方向；新增／修改欄位一定要兩邊一起動，
/// round-trip 測試會擋住只改一邊的情況。
struct LiqiEnvelope {

    /// 1 = notify / 2 = request / 3 = response
    let type: LiqiMsgType

    /// NOTIFY 沒有 msgId（`nil`）；REQUEST／RESPONSE 一定有
    let msgId: UInt16?

    /// 明文方法名。RESPONSE 的 envelope 不帶方法名（`nil`），要靠 msgId 對照。
    let method: String?

    /// wrapper field 2 的內容（**未** XOR；ActionPrototype 的 XOR 在更內層）
    let payload: Data

    init(type: LiqiMsgType, msgId: UInt16?, method: String?, payload: Data) {
        self.type = type
        self.msgId = msgId
        self.method = method
        self.payload = payload
    }

    // MARK: 解

    /// 從原始 frame 解出信封
    static func decode(_ data: Data) -> Result<LiqiEnvelope, LiqiEnvelopeDecodeFailure> {
        guard data.count >= 3 else {
            return .failure(.tooShort(byteCount: data.count))
        }
        guard let type = LiqiMsgType(rawValue: data[0]) else {
            return .failure(.unknownType(data[0], byteCount: data.count))
        }

        let header = type.headerByteCount
        let msgId: UInt16? = type == .notify
            ? nil
            : UInt16(data[1]) | (UInt16(data[2]) << 8)
        let body = data.subdata(in: header..<data.count)
        let blocks = parseProtobufBlocks(body)

        // RESPONSE 的 field 1 是空字串，方法名只能靠 msgId 對照；
        // payload 缺席也合法（伺服器可以回一個空 Res）。
        //
        // payload 必須**按欄位號**取，不能按位置（`blocks[1]`）：官方伺服器會把空的
        // field 1 寫出來（`0a 00`，wrapper 恆為兩個 block），但 canonical proto3
        // encoder 重新序列化時會省略預設值欄位——mitmproxy 類改包工具（MajsoulMax）
        // 改寫過的 response 只剩 field 2 一個 block。按位置取會靜默拿到空 payload，
        // authGame 形同沒收到、整局偵測不到（issue #2）。遊戲自己的 decoder 按欄位
        // 號讀所以不受影響，症狀是「遊戲能玩、只有 Naki 失明」。
        guard type != .response else {
            let payload = blocks.first { $0.fieldId == 2 && $0.wireType == 2 }?.data ?? Data()
            return .success(LiqiEnvelope(type: type, msgId: msgId, method: nil, payload: payload))
        }

        // NOTIFY／REQUEST 這裡**刻意**維持位置取法：method（field 1）在這兩型恆非空，
        // canonical encoder 不會省略它，兩個 block 的位置序＝欄位序；且 REQUEST 是
        // Naki 在頁內先看到、任何 proxy 改寫都在其後。若日後出現「notify 被改包工具
        // 重寫且 payload 全為預設值」的案例，這裡會以 notEnoughBlocks 顯式失敗
        // （不是 response 那種靜默空 payload），到時再比照 response 改按欄位號取。
        guard blocks.count >= 2 else {
            return .failure(.notEnoughBlocks(type: type, blocks: blocks.count, byteCount: body.count))
        }
        guard let method = blocks[0].stringValue else {
            return .failure(.methodNotUTF8(type: type, byteCount: blocks[0].data.count))
        }

        return .success(LiqiEnvelope(type: type, msgId: msgId, method: method, payload: blocks[1].data))
    }

    // MARK: 編

    /// 組成可以送出的 bytes（`decode` 的反向）
    var encoded: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(type.headerByteCount + (method?.utf8.count ?? 0) + payload.count + 6)
        out.append(type.rawValue)
        if type != .notify {
            // msgId: little-endian（實測 141 → 8d 00）
            let id = msgId ?? 0
            out.append(UInt8(id & 0x00FF))
            out.append(UInt8((id >> 8) & 0x00FF))
        }
        out += LiqiEncoder.encodeStringField(field: 1, value: method ?? "")
        out += LiqiEncoder.encodeLengthDelimited(field: 2, bytes: [UInt8](payload))
        return out
    }
}
