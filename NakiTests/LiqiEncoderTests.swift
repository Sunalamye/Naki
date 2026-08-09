import XCTest
@testable import Naki

/// LiqiEncoder 單元測試。
///
/// 核心是「位元組對拍」：用實測抓到的真實封包當 ground truth，
/// 確保 encoder 產生的 bytes 與雀魂客戶端自己送出的完全一致。
final class LiqiEncoderTests: XCTestCase {

    // MARK: - Ground truth（實測封包）

    /// 真實送出的 heartbeat request（34 bytes）
    /// type=0x02(REQUEST), msgId=141(8d 00 LE),
    /// field1=".lq.Route.heartbeat", field2=08 00 10 00 18 0b 20 0f
    private let heartbeatRequestHex =
        "028d000a132e6c712e526f7574652e686561727462656174120808001000180b200f"

    /// 對應的 payload（4 個 varint 欄位：0, 0, 11, 15）
    private let heartbeatPayloadHex = "08001000180b200f"

    // MARK: - 位元組對拍

    func testHeartbeatPayloadMatchesCapturedBytes() {
        let payload = LiqiEncoder.encodeFields([
            .varint(field: 1, value: 0),
            .varint(field: 2, value: 0),
            .varint(field: 3, value: 11),
            .varint(field: 4, value: 15)
        ])

        XCTAssertEqual(payload.count, 8)
        XCTAssertEqual(LiqiEncoder.hexString(payload), heartbeatPayloadHex)
    }

    /// 最重要的一條：整包 envelope 必須與實測封包逐位元組相同
    func testHeartbeatRequestMatchesCapturedBytes() {
        let payload = LiqiEncoder.encodeFields([
            .varint(field: 1, value: 0),
            .varint(field: 2, value: 0),
            .varint(field: 3, value: 11),
            .varint(field: 4, value: 15)
        ])

        let bytes = LiqiEncoder.encodeRequest(method: ".lq.Route.heartbeat",
                                              payload: payload,
                                              msgId: 141)

        XCTAssertEqual(bytes.count, 34, "實測封包長度為 34 bytes")
        XCTAssertEqual(LiqiEncoder.hexString(bytes), heartbeatRequestHex)
    }

    /// 宣告式 API（fields 版）必須產生同一串 bytes
    func testHeartbeatRequestViaFieldsAPIMatchesCapturedBytes() {
        let bytes = LiqiEncoder.encodeRequest(
            method: ".lq.Route.heartbeat",
            fields: [
                .varint(field: 1, value: 0),
                .varint(field: 2, value: 0),
                .varint(field: 3, value: 11),
                .varint(field: 4, value: 15)
            ],
            msgId: 141
        )

        XCTAssertEqual(LiqiEncoder.hexString(bytes), heartbeatRequestHex)
    }

    /// envelope header：type + msgId little-endian
    func testEnvelopeHeaderLayout() {
        let bytes = LiqiEncoder.encodeRequest(method: "x", payload: [], msgId: 141)

        XCTAssertEqual(bytes[0], 0x02, "REQUEST = 2")
        XCTAssertEqual(bytes[1], 0x8d, "msgId 低位在前")
        XCTAssertEqual(bytes[2], 0x00, "msgId 高位在後")
    }

    func testEnvelopeMsgIdIsLittleEndianForHighRange() {
        // 60000 = 0xEA60 → LE 為 60 EA
        let bytes = LiqiEncoder.encodeRequest(method: "x", payload: [], msgId: 60000)

        XCTAssertEqual(bytes[1], 0x60)
        XCTAssertEqual(bytes[2], 0xEA)
    }

    /// method 是明文，request envelope 沒有 XOR
    func testMethodIsPlaintextInEnvelope() {
        let method = ".lq.Lobby.heatbeat"
        let bytes = LiqiEncoder.encodeRequest(method: method, payload: [], msgId: 60000)
        let body = Data(bytes.dropFirst(3))
        let blocks = parseProtobufBlocks(body)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].fieldId, 1)
        XCTAssertEqual(blocks[0].stringValue, method)
        XCTAssertEqual(blocks[1].fieldId, 2)
        XCTAssertEqual(blocks[1].data.count, 0)
    }

    /// 空 payload 仍要輸出 `12 00`（與實測 response `038d000a001200` 的結構一致）
    func testEmptyPayloadStillEmitsField2() {
        let bytes = LiqiEncoder.encodeEnvelope(type: .response, msgId: 141, method: "", payload: [])

        XCTAssertEqual(LiqiEncoder.hexString(bytes), "038d000a001200")
    }

    // MARK: - Varint 邊界

    func testEncodeVarintBoundaries() {
        XCTAssertEqual(LiqiEncoder.encodeVarint(0), [0x00])
        XCTAssertEqual(LiqiEncoder.encodeVarint(1), [0x01])
        XCTAssertEqual(LiqiEncoder.encodeVarint(127), [0x7f])
        XCTAssertEqual(LiqiEncoder.encodeVarint(128), [0x80, 0x01])
        XCTAssertEqual(LiqiEncoder.encodeVarint(300), [0xac, 0x02])
        XCTAssertEqual(LiqiEncoder.encodeVarint(16383), [0xff, 0x7f])
        XCTAssertEqual(LiqiEncoder.encodeVarint(16384), [0x80, 0x80, 0x01])
        XCTAssertEqual(LiqiEncoder.encodeVarint(2_097_151), [0xff, 0xff, 0x7f])
        XCTAssertEqual(LiqiEncoder.encodeVarint(2_097_152), [0x80, 0x80, 0x80, 0x01])
    }

    func testEncodeVarintMaxIsTenBytes() {
        let bytes = LiqiEncoder.encodeVarint(UInt64.max)

        XCTAssertEqual(bytes.count, 10)
        XCTAssertEqual(bytes, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01])
    }

    /// varint round-trip：用既有 parser 反解回原值
    func testEncodeVarintRoundTripsThroughParser() {
        for value in [0, 1, 127, 128, 300, 16383, 16384, 2_097_152, 1_000_000_007] {
            let bytes = LiqiEncoder.encodeVarint(UInt64(value))
            let parsed = parseVarint(Data(bytes), offset: 0)

            XCTAssertEqual(parsed?.value, value, "varint \(value) round-trip 失敗")
            XCTAssertEqual(parsed?.newOffset, bytes.count)
        }
    }

    // MARK: - Tag 編碼

    func testTagUsesVarintSoLargeFieldNumbersSpanMultipleBytes() {
        // field 1, wire 2 → 0x0A（實測 heartbeat 的 method 欄位）
        XCTAssertEqual(LiqiEncoder.encodeTag(field: 1, wireType: .lengthDelimited), [0x0a])
        // field 2, wire 2 → 0x12
        XCTAssertEqual(LiqiEncoder.encodeTag(field: 2, wireType: .lengthDelimited), [0x12])
        // field 15, wire 0 → 0x78（單 byte 上限）
        XCTAssertEqual(LiqiEncoder.encodeTag(field: 15, wireType: .varint), [0x78])
        // field 16, wire 0 → 128 → 兩 bytes
        XCTAssertEqual(LiqiEncoder.encodeTag(field: 16, wireType: .varint), [0x80, 0x01])
        // field 2047, wire 2 → (2047 << 3 | 2) = 16378 → 三 bytes
        XCTAssertEqual(LiqiEncoder.encodeTag(field: 2047, wireType: .lengthDelimited),
                       LiqiEncoder.encodeVarint(16378))
    }

    func testVarintFieldForHighFieldNumber() {
        let bytes = LiqiEncoder.encodeVarintField(field: 16, value: 300)

        XCTAssertEqual(bytes, [0x80, 0x01, 0xac, 0x02])
    }

    // MARK: - Length-delimited（長度也是 varint）

    func testLengthDelimitedShortLengthIsSingleByte() {
        let payload = [UInt8](repeating: 0xAB, count: 19)
        let bytes = LiqiEncoder.encodeLengthDelimited(field: 1, bytes: payload)

        XCTAssertEqual(bytes.count, 2 + 19)
        XCTAssertEqual(bytes[0], 0x0a)
        XCTAssertEqual(bytes[1], 0x13)
    }

    func testLengthDelimitedBoundaryAt127And128() {
        let short = LiqiEncoder.encodeLengthDelimited(field: 2,
                                                      bytes: [UInt8](repeating: 0x01, count: 127))
        XCTAssertEqual(Array(short.prefix(2)), [0x12, 0x7f])
        XCTAssertEqual(short.count, 2 + 127)

        let long = LiqiEncoder.encodeLengthDelimited(field: 2,
                                                     bytes: [UInt8](repeating: 0x01, count: 128))
        XCTAssertEqual(Array(long.prefix(3)), [0x12, 0x80, 0x01], "長度 >127 必須用多位元組 varint")
        XCTAssertEqual(long.count, 3 + 128)
    }

    func testLengthDelimitedLargePayloadLength() {
        let payload = [UInt8](repeating: 0x7F, count: 300)
        let bytes = LiqiEncoder.encodeLengthDelimited(field: 1, bytes: payload)

        XCTAssertEqual(Array(bytes.prefix(3)), [0x0a, 0xac, 0x02])
        XCTAssertEqual(bytes.count, 3 + 300)

        // 用既有 parser 反解，確認長度前綴正確
        let blocks = parseProtobufBlocks(Data(bytes))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].fieldId, 1)
        XCTAssertEqual(blocks[0].data.count, 300)
    }

    /// envelope 內的 method 若超過 127 bytes，長度前綴同樣要走 varint
    func testEnvelopeWithLongMethodUsesVarintLength() {
        let method = String(repeating: "a", count: 200)
        let bytes = LiqiEncoder.encodeRequest(method: method, payload: [], msgId: 60000)

        XCTAssertEqual(bytes[3], 0x0a)
        XCTAssertEqual(bytes[4], 0xc8)
        XCTAssertEqual(bytes[5], 0x01)

        let blocks = parseProtobufBlocks(Data(bytes.dropFirst(3)))
        XCTAssertEqual(blocks.first?.stringValue, method)
    }

    // MARK: - 字串 / bool / 有號整數 / 巢狀

    func testStringFieldLengthCountsUTF8BytesNotCharacters() {
        // "雀魂" = 6 UTF-8 bytes，2 個字元
        let bytes = LiqiEncoder.encodeStringField(field: 1, value: "雀魂")

        XCTAssertEqual(bytes[0], 0x0a)
        XCTAssertEqual(bytes[1], 6)
        XCTAssertEqual(bytes.count, 8)
        XCTAssertEqual(String(data: Data(bytes.dropFirst(2)), encoding: .utf8), "雀魂")
    }

    func testBoolField() {
        XCTAssertEqual(LiqiEncoder.encodeBoolField(field: 3, value: true), [0x18, 0x01])
        XCTAssertEqual(LiqiEncoder.encodeBoolField(field: 3, value: false), [0x18, 0x00])
    }

    func testSignedVarintFieldUsesTwosComplementForNegatives() {
        let positive = LiqiEncoder.encodeVarintField(field: 1, value: Int(300))
        XCTAssertEqual(positive, [0x08, 0xac, 0x02])

        // protobuf int32/int64 的負數固定 10 bytes（-1 → 64-bit 全 1）
        let negative = LiqiEncoder.encodeVarintField(field: 1, value: Int(-1))
        XCTAssertEqual(negative.count, 11)
        XCTAssertEqual(negative[0], 0x08)
        XCTAssertEqual(Array(negative.dropFirst()), LiqiEncoder.encodeVarint(UInt64.max))
    }

    func testNestedMessageField() {
        let bytes = LiqiEncoder.encodeFields([
            .message(field: 2, fields: [
                .varint(field: 1, value: 11),
                .bool(field: 2, value: true)
            ])
        ])

        // inner = 08 0b 10 01（4 bytes）→ outer = 12 04 08 0b 10 01
        XCTAssertEqual(LiqiEncoder.hexString(bytes), "1204080b1001")
    }

    // MARK: - 輸出格式

    func testBase64StringMatchesCapturedPacket() {
        let bytes = LiqiEncoder.encodeRequest(
            method: ".lq.Route.heartbeat",
            fields: [
                .varint(field: 1, value: 0),
                .varint(field: 2, value: 0),
                .varint(field: 3, value: 11),
                .varint(field: 4, value: 15)
            ],
            msgId: 141
        )

        let expected = Data(hexString: heartbeatRequestHex)!.base64EncodedString()
        XCTAssertEqual(LiqiEncoder.base64String(bytes), expected)
    }

    // MARK: - msgId 配發器

    func testAllocatorStartsAtHighRangeAndIncrements() {
        let allocator = LiqiMsgIdAllocator()

        XCTAssertEqual(allocator.next(), 60000)
        XCTAssertEqual(allocator.next(), 60001)
        XCTAssertEqual(allocator.next(), 60002)
        XCTAssertEqual(allocator.peek, 60003)
    }

    func testAllocatorStaysInsideReservedRange() {
        let allocator = LiqiMsgIdAllocator()

        for _ in 0..<10_000 {
            let id = allocator.next()
            XCTAssertGreaterThanOrEqual(id, LiqiMsgIdAllocator.rangeStart,
                                        "必須避開遊戲自己使用的低位 msgId")
            XCTAssertLessThanOrEqual(id, LiqiMsgIdAllocator.rangeEnd)
        }
    }

    func testAllocatorWrapsAtRangeEnd() {
        // 用常量而非寫死數字：§7.6 把 rangeEnd 由 65500 收窄為 63999（64000–65500 留給插件），
        // 這個測試不該因為區段調整就假紅。
        let allocator = LiqiMsgIdAllocator(start: LiqiMsgIdAllocator.rangeEnd - 1)

        XCTAssertEqual(allocator.next(), LiqiMsgIdAllocator.rangeEnd - 1)
        XCTAssertEqual(allocator.next(), LiqiMsgIdAllocator.rangeEnd)
        XCTAssertEqual(allocator.next(), LiqiMsgIdAllocator.rangeStart, "到 rangeEnd 之後回捲")
        XCTAssertEqual(allocator.next(), LiqiMsgIdAllocator.rangeStart + 1)
    }

    func testAllocatorClampsOutOfRangeStart() {
        XCTAssertEqual(LiqiMsgIdAllocator(start: 141).next(), 60000)
        XCTAssertEqual(LiqiMsgIdAllocator(start: 65535).next(), 60000)
    }

    func testAllocatorReset() {
        let allocator = LiqiMsgIdAllocator()
        _ = allocator.next()
        _ = allocator.next()
        allocator.reset()

        XCTAssertEqual(allocator.next(), 60000)
    }

    func testAllocatorIsThreadSafeAndProducesUniqueIds() {
        let allocator = LiqiMsgIdAllocator()
        let iterations = 1_000
        let lock = NSLock()
        var ids: [UInt16] = []

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let id = allocator.next()
            lock.lock()
            ids.append(id)
            lock.unlock()
        }

        XCTAssertEqual(ids.count, iterations)
        XCTAssertEqual(Set(ids).count, iterations, "並行配發不得重複")
    }

    func testSharedNextMsgIdIsInsideReservedRange() {
        let id = LiqiEncoder.nextMsgId()

        XCTAssertGreaterThanOrEqual(id, LiqiMsgIdAllocator.rangeStart)
        XCTAssertLessThanOrEqual(id, LiqiMsgIdAllocator.rangeEnd)
    }

    func testEncodeRequestAutoAllocatesMsgIdIntoEnvelope() {
        let (msgId, bytes) = LiqiEncoder.encodeRequest(
            method: ".lq.Route.heartbeat",
            fields: [.varint(field: 3, value: 11)]
        )

        XCTAssertGreaterThanOrEqual(msgId, LiqiMsgIdAllocator.rangeStart)
        XCTAssertLessThanOrEqual(msgId, LiqiMsgIdAllocator.rangeEnd)
        XCTAssertEqual(bytes[0], 0x02)
        XCTAssertEqual(bytes[1], UInt8(msgId & 0x00FF))
        XCTAssertEqual(bytes[2], UInt8((msgId >> 8) & 0x00FF))
    }
}

// MARK: - 測試輔助

private extension Data {
    /// hex 字串 → Data（僅測試用）
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        self = Data(bytes)
    }
}
