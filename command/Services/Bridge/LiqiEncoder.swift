//
//  LiqiEncoder.swift
//  Naki
//
//  雀魂 Liqi Request 編碼器 - 純 Swift 實現（LiqiParser 的對稱寫入端）
//
//  Envelope 格式的**定義**在 `LiqiEnvelope.swift`（parse 與 encode 共用同一份）；
//  本檔只負責 protobuf 欄位層的編碼與 request 的組裝便利函式。
//
//  Ground truth（.lq.Route.heartbeat，msgId = 141）：
//      028d000a132e6c712e526f7574652e686561727462656174120808001000180b200f
//
//  注意：request envelope **沒有** XOR。XOR 只作用在 notify 的
//  ActionPrototype.data（見 LiqiParser.liqiDecode），不要在這裡套用。
//

import Foundation

// MARK: - Payload 欄位描述

/// 宣告式 payload 欄位：把「field 編號 + 值」組成 protobuf bytes。
///
/// 用法（heartbeat payload = 0, 0, 11, 15）：
/// ```swift
/// let payload = LiqiEncoder.encodeFields([
///     .varint(field: 1, value: 0),
///     .varint(field: 2, value: 0),
///     .varint(field: 3, value: 11),
///     .varint(field: 4, value: 15)
/// ])
/// ```
enum LiqiField {
    /// 無號整數（protobuf uint32/uint64/enum）
    case varint(field: Int, value: UInt64)
    /// 有號整數（protobuf int32/int64；負數以 64-bit 二補數編成 10 bytes，與 protobuf 規範一致）
    case int(field: Int, value: Int)
    /// bool（true = 1, false = 0）
    case bool(field: Int, value: Bool)
    /// UTF-8 字串
    case string(field: Int, value: String)
    /// 原始 bytes
    case bytes(field: Int, value: [UInt8])
    /// 巢狀 message
    case message(field: Int, fields: [LiqiField])

    /// 編成 protobuf bytes（含 tag）
    var encoded: [UInt8] {
        switch self {
        case let .varint(field, value):
            return LiqiEncoder.encodeVarintField(field: field, value: value)
        case let .int(field, value):
            return LiqiEncoder.encodeVarintField(field: field, value: value)
        case let .bool(field, value):
            return LiqiEncoder.encodeBoolField(field: field, value: value)
        case let .string(field, value):
            return LiqiEncoder.encodeStringField(field: field, value: value)
        case let .bytes(field, value):
            return LiqiEncoder.encodeLengthDelimited(field: field, bytes: value)
        case let .message(field, fields):
            return LiqiEncoder.encodeLengthDelimited(field: field,
                                                     bytes: LiqiEncoder.encodeFields(fields))
        }
    }
}

// MARK: - Liqi Encoder

/// Liqi request 編碼器（無狀態；msgId 配發見 `LiqiMsgIdAllocator`）
enum LiqiEncoder {

    // MARK: - Varint

    /// 編碼 protobuf varint（實作在 `LiqiWire.encodeVarint`，與解碼端同一個檔案）
    ///
    /// - 0 → `[0x00]`、127 → `[0x7f]`、128 → `[0x80, 0x01]`、300 → `[0xac, 0x02]`
    /// - `UInt64.max` → 10 bytes
    static func encodeVarint(_ value: UInt64) -> [UInt8] {
        LiqiWire.encodeVarint(value)
    }

    /// 編碼 tag（`field << 3 | wireType`）
    ///
    /// tag 本身也是 varint：field > 15 會自動變成多 bytes。
    /// field 必須 >= 1（protobuf 規範），否則回傳空陣列。
    static func encodeTag(field: Int, wireType: LiqiWireType) -> [UInt8] {
        guard field >= 1 else {
            assertionFailure("[LiqiEncoder] 非法 field 編號: \(field)")
            return []
        }
        return encodeVarint((UInt64(field) << 3) | UInt64(wireType.rawValue))
    }

    // MARK: - 單一欄位

    /// varint 欄位（wire type 0），tag = `field << 3 | 0`
    static func encodeVarintField(field: Int, value: UInt64) -> [UInt8] {
        let tag = encodeTag(field: field, wireType: .varint)
        guard !tag.isEmpty else { return [] }
        return tag + encodeVarint(value)
    }

    /// varint 欄位（有號）。負數依 protobuf int32/int64 規範以 64-bit 二補數編碼（固定 10 bytes）。
    static func encodeVarintField(field: Int, value: Int) -> [UInt8] {
        encodeVarintField(field: field, value: UInt64(bitPattern: Int64(value)))
    }

    /// bool 欄位（wire type 0）
    static func encodeBoolField(field: Int, value: Bool) -> [UInt8] {
        encodeVarintField(field: field, value: value ? 1 : 0)
    }

    /// length-delimited 欄位（wire type 2），tag = `field << 3 | 2`
    ///
    /// 長度本身是 varint：>127 bytes 會自動用多 bytes 編長度（不是單 byte）。
    static func encodeLengthDelimited(field: Int, bytes: [UInt8]) -> [UInt8] {
        let tag = encodeTag(field: field, wireType: .lengthDelimited)
        guard !tag.isEmpty else { return [] }
        return tag + encodeVarint(UInt64(bytes.count)) + bytes
    }

    /// UTF-8 字串欄位（wire type 2），長度以「位元組數」計算而非字元數
    static func encodeStringField(field: Int, value: String) -> [UInt8] {
        encodeLengthDelimited(field: field, bytes: Array(value.utf8))
    }

    /// 巢狀 message 欄位（wire type 2）
    static func encodeMessageField(field: Int, message: [UInt8]) -> [UInt8] {
        encodeLengthDelimited(field: field, bytes: message)
    }

    // MARK: - Payload 組裝

    /// 依序把欄位串成 payload bytes（不含 envelope）
    static func encodeFields(_ fields: [LiqiField]) -> [UInt8] {
        fields.reduce(into: [UInt8]()) { $0 += $1.encoded }
    }

    // MARK: - Envelope

    /// 組裝 Liqi envelope（格式定義在 `LiqiEnvelope`，與 `LiqiParser` 共用同一份）
    ///
    /// - Parameters:
    ///   - type: 1 = notify / 2 = request / 3 = response
    ///   - msgId: 2 bytes little-endian。**NOTIFY 沒有 msgId**，這個參數會被忽略
    ///     ——舊版無條件寫進去，導致自己編出來的 notify 自己解不開（見 LiqiEnvelope 檔頭）。
    ///   - method: 明文方法名，例如 `.lq.Route.heartbeat`
    ///   - payload: 已編好的 protobuf payload bytes（可為空，仍會輸出 `12 00`）
    static func encodeEnvelope(type: LiqiMsgType,
                              msgId: UInt16,
                              method: String,
                              payload: [UInt8]) -> [UInt8] {
        LiqiEnvelope(type: type,
                     msgId: type == .notify ? nil : msgId,
                     method: method,
                     payload: Data(payload)).encoded
    }

    /// 組裝 REQUEST envelope（type = 2）
    static func encodeRequest(method: String, payload: [UInt8], msgId: UInt16) -> [UInt8] {
        encodeEnvelope(type: .request, msgId: msgId, method: method, payload: payload)
    }

    /// 組裝 REQUEST envelope，payload 用宣告式欄位描述
    static func encodeRequest(method: String, fields: [LiqiField], msgId: UInt16) -> [UInt8] {
        encodeRequest(method: method, payload: encodeFields(fields), msgId: msgId)
    }

    /// 組裝 REQUEST envelope 並自動配發 msgId（避開遊戲自身的低位號段）
    ///
    /// - Returns: 送出用的 bytes 與實際使用的 msgId（呼叫端需要它來配對 response）
    static func encodeRequest(method: String,
                              fields: [LiqiField]) -> (msgId: UInt16, bytes: [UInt8]) {
        let msgId = nextMsgId()
        return (msgId, encodeRequest(method: method, fields: fields, msgId: msgId))
    }

    // MARK: - msgId

    /// 從共用配發器取下一個 msgId（60000...65500 區段，避免撞到遊戲自己的遞增號）
    static func nextMsgId() -> UInt16 {
        LiqiMsgIdAllocator.shared.next()
    }

    // MARK: - 輸出格式

    /// bytes → base64（送進 JS `window.__nakiWebSocket.sendRaw` 用）
    static func base64String(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    /// bytes → 小寫 hex（log / 測試對拍用）
    static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - msgId 配發器

/// Naki 注入用的 msgId 配發器（thread-safe）
///
/// 遊戲自己用的是低位遞增號（實測 141、142…），為了不撞號，
/// Naki 一律從 60000 開始配發，超過 65500 回捲。
///
/// `nonisolated`：專案設了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
/// 不標注的 class 會被推導成 MainActor-isolated 並帶 **isolated deinit**；
/// 本類別是 NSLock 保護的共用配發器，isolated deinit 只會在釋放時
/// 觸發 `swift_task_deinitOnExecutorImpl`（實測會讓 host app 在單元測試中 abort）。
nonisolated final class LiqiMsgIdAllocator: @unchecked Sendable {

    /// 全域共用配發器
    static let shared = LiqiMsgIdAllocator()

    /// 配發區段下界（含）
    static let rangeStart: UInt16 = 60000
    /// 配發區段上界（含）；配發到這個值之後回捲到 `rangeStart`
    static let rangeEnd: UInt16 = 65500

    private let lock = NSLock()
    private var current: UInt16

    /// - Parameter start: 起始值；超出 `rangeStart...rangeEnd` 會被夾回區段內
    init(start: UInt16 = LiqiMsgIdAllocator.rangeStart) {
        current = LiqiMsgIdAllocator.clamp(start)
    }

    /// 取下一個 msgId：回傳當前值並前進；到達 `rangeEnd` 後回捲到 `rangeStart`
    func next() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        let value = current
        current = (value >= LiqiMsgIdAllocator.rangeEnd) ? LiqiMsgIdAllocator.rangeStart : value &+ 1
        return value
    }

    /// 目前尚未配發出去的值（測試 / 診斷用，不會前進）
    var peek: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// 重設到指定起點（預設回到區段下界）
    func reset(to value: UInt16 = LiqiMsgIdAllocator.rangeStart) {
        lock.lock()
        defer { lock.unlock() }
        current = LiqiMsgIdAllocator.clamp(value)
    }

    private static func clamp(_ value: UInt16) -> UInt16 {
        guard value >= rangeStart else { return rangeStart }
        guard value <= rangeEnd else { return rangeStart }
        return value
    }
}
