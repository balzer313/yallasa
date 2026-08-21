import XCTest
@testable import YallaSaKit

/// Wire-format tests, with every input written out as literal bytes.
///
/// The point of hand-assembling them is that these tests are the only check the
/// reader gets: there is no reference implementation in the package to compare
/// against, so the bytes below are transcribed from the protobuf encoding spec
/// rather than produced by the code under test.
final class ProtobufReaderTests: XCTestCase {

    private func withReader<R>(_ bytes: [UInt8], _ body: (inout ProtobufReader) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes { raw in
            var reader = ProtobufReader(bytes: raw)
            return try body(&reader)
        }
    }

    // MARK: - Varints

    func testSingleByteVarints() throws {
        XCTAssertEqual(try withReader([0x00]) { try $0.readVarint() }, 0)
        XCTAssertEqual(try withReader([0x01]) { try $0.readVarint() }, 1)
        XCTAssertEqual(try withReader([0x7F]) { try $0.readVarint() }, 127)
    }

    func testMultiByteVarints() throws {
        // 300 = 0b10_0101100 -> 0xAC 0x02
        XCTAssertEqual(try withReader([0xAC, 0x02]) { try $0.readVarint() }, 300)
        // 16384 = 2^14 -> 0x80 0x80 0x01
        XCTAssertEqual(try withReader([0x80, 0x80, 0x01]) { try $0.readVarint() }, 16_384)
    }

    func testTenByteVarintDecodesUInt64Max() throws {
        let bytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        XCTAssertEqual(try withReader(bytes) { try $0.readVarint() }, UInt64.max)
    }

    /// The case that breaks naive readers: GTFS-Realtime declares `delay` as a
    /// plain `int32`, so a negative value is sign-extended to 64 bits before
    /// encoding and arrives as ten bytes.
    func testNegativeInt32IsATenByteVarint() throws {
        let minusSixty: [UInt8] = [0xC4, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        XCTAssertEqual(try withReader(minusSixty) { try $0.readVarint() }, 0xFFFF_FFFF_FFFF_FFC4)
        XCTAssertEqual(try withReader(minusSixty) { try $0.readInt32() }, -60)

        let minusOne: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        XCTAssertEqual(try withReader(minusOne) { try $0.readInt32() }, -1)
        XCTAssertEqual(try withReader(minusOne) { try $0.readInt64() }, -1)
    }

    func testPositiveInt32RoundTrips() throws {
        // 90 seconds late, one byte on the wire.
        XCTAssertEqual(try withReader([0x5A]) { try $0.readInt32() }, 90)
    }

    func testVarintWithoutTerminatorThrows() {
        let neverEnds: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertThrowsError(try withReader(neverEnds) { try $0.readVarint() }) { error in
            XCTAssertEqual(error as? ProtobufError, .malformedVarint)
        }
    }

    func testTruncatedVarintThrows() {
        XCTAssertThrowsError(try withReader([0x80]) { try $0.readVarint() }) { error in
            XCTAssertEqual(error as? ProtobufError, .truncated)
        }
    }

    // MARK: - Fixed width

    func testFixed32IsLittleEndian() throws {
        XCTAssertEqual(try withReader([0x78, 0x56, 0x34, 0x12]) { try $0.readFixed32() }, 0x1234_5678)
    }

    func testFixed64IsLittleEndian() throws {
        let bytes: [UInt8] = [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
        XCTAssertEqual(try withReader(bytes) { try $0.readFixed64() }, 0x0102_0304_0506_0708)
    }

    func testFloatDecodes() throws {
        // 1.0f is 0x3F800000.
        XCTAssertEqual(try withReader([0x00, 0x00, 0x80, 0x3F]) { try $0.readFloat() }, 1.0)
    }

    func testTruncatedFixedFieldsThrow() {
        XCTAssertThrowsError(try withReader([0x01, 0x02, 0x03]) { try $0.readFixed32() }) { error in
            XCTAssertEqual(error as? ProtobufError, .truncated)
        }
        XCTAssertThrowsError(try withReader([0x01, 0x02, 0x03]) { try $0.readFixed64() }) { error in
            XCTAssertEqual(error as? ProtobufError, .truncated)
        }
    }

    // MARK: - Tags

    func testFieldTagsSplitIntoNumberAndWireType() throws {
        // field 1, varint  -> (1 << 3) | 0 = 0x08
        // field 2, bytes   -> (2 << 3) | 2 = 0x12
        // field 3, fixed32 -> (3 << 3) | 5 = 0x1D
        let bytes: [UInt8] = [0x08, 0x00, 0x12, 0x00, 0x1D, 0x00, 0x00, 0x00, 0x00]
        try withReader(bytes) { reader in
            let first = try XCTUnwrap(try reader.nextField())
            XCTAssertEqual(first.number, 1)
            XCTAssertEqual(first.wireType, .varint)
            try reader.skipField(wireType: first.wireType)

            let second = try XCTUnwrap(try reader.nextField())
            XCTAssertEqual(second.number, 2)
            XCTAssertEqual(second.wireType, .lengthDelimited)
            try reader.skipField(wireType: second.wireType)

            let third = try XCTUnwrap(try reader.nextField())
            XCTAssertEqual(third.number, 3)
            XCTAssertEqual(third.wireType, .fixed32)
            try reader.skipField(wireType: third.wireType)

            XCTAssertNil(try reader.nextField())
        }
    }

    func testFieldNumberZeroThrows() {
        // Tag 0x00 is field 0, which no encoder may emit.
        XCTAssertThrowsError(try withReader([0x00]) { try $0.nextField() }) { error in
            XCTAssertEqual(error as? ProtobufError, .invalidFieldNumber(0))
        }
    }

    func testUnknownWireTypeThrows() {
        // (1 << 3) | 6 = 0x0E; wire types 6 and 7 do not exist.
        XCTAssertThrowsError(try withReader([0x0E]) { try $0.nextField() }) { error in
            XCTAssertEqual(error as? ProtobufError, .unknownWireType(6))
        }
    }

    // MARK: - Length-delimited and nesting

    func testLengthDelimitedStringIsBounded() throws {
        // field 1, bytes, length 5, "hello"
        let bytes: [UInt8] = [0x0A, 0x05, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
        try withReader(bytes) { reader in
            let field = try XCTUnwrap(try reader.nextField())
            XCTAssertEqual(field.number, 1)
            XCTAssertEqual(try reader.readString(), "hello")
            XCTAssertNil(try reader.nextField())
        }
    }

    func testLengthDelimitedRunningPastTheBufferThrows() {
        // Claims 16 bytes of payload but supplies two.
        let bytes: [UInt8] = [0x0A, 0x10, 0x01, 0x02]
        XCTAssertThrowsError(try withReader(bytes) { reader -> Void in
            _ = try reader.nextField()
            _ = try reader.readLengthDelimited()
        }) { error in
            XCTAssertEqual(error as? ProtobufError, .truncated)
        }
    }

    func testNestedMessageDecodesThroughASubReader() throws {
        // Outer: field 1 = submessage { field 2 = varint 300, field 3 = "hi" }
        let inner: [UInt8] = [0x10, 0xAC, 0x02, 0x1A, 0x02, 0x68, 0x69]
        let outer: [UInt8] = [0x0A, UInt8(inner.count)] + inner

        try withReader(outer) { reader in
            let field = try XCTUnwrap(try reader.nextField())
            XCTAssertEqual(field.number, 1)
            XCTAssertEqual(field.wireType, .lengthDelimited)

            let payload = try reader.readLengthDelimited()
            XCTAssertEqual(payload.count, inner.count)

            var sub = ProtobufReader(bytes: payload)
            let a = try XCTUnwrap(try sub.nextField())
            XCTAssertEqual(a.number, 2)
            XCTAssertEqual(try sub.readVarint(), 300)

            let b = try XCTUnwrap(try sub.nextField())
            XCTAssertEqual(b.number, 3)
            XCTAssertEqual(try sub.readString(), "hi")
            XCTAssertNil(try sub.nextField())

            // The outer reader must have been advanced past the whole submessage.
            XCTAssertNil(try reader.nextField())
        }
    }

    // MARK: - Skipping

    func testUnknownFieldsOfEveryWireTypeAreSkipped() throws {
        // Unknown varint (field 9), unknown fixed64 (field 10), unknown bytes
        // (field 11), unknown fixed32 (field 12), then the field we want (13).
        var bytes: [UInt8] = []
        bytes += [0x48, 0xAC, 0x02]                                     // 9: varint 300
        bytes += [0x51, 1, 2, 3, 4, 5, 6, 7, 8]                         // 10: fixed64
        bytes += [0x5A, 0x03, 0x61, 0x62, 0x63]                         // 11: "abc"
        bytes += [0x65, 1, 2, 3, 4]                                     // 12: fixed32
        bytes += [0x68, 0x2A]                                           // 13: varint 42

        try withReader(bytes) { reader in
            var found: UInt64?
            while let field = try reader.nextField() {
                if field.number == 13, field.wireType == .varint {
                    found = try reader.readVarint()
                } else {
                    try reader.skipField(wireType: field.wireType)
                }
            }
            XCTAssertEqual(found, 42)
        }
    }

    func testUnknownGroupIsSkippedWholesale() throws {
        // field 4 startGroup -> (4 << 3) | 3 = 0x23, endGroup -> 0x24.
        // Inside the group: a varint and a nested group, none of which the
        // decoder knows about.
        var bytes: [UInt8] = []
        bytes += [0x23]                     // start group 4
        bytes += [0x08, 0x05]               // 1: varint 5
        bytes += [0x2B]                     // start group 5 -> (5 << 3) | 3
        bytes += [0x10, 0x06]               // 2: varint 6
        bytes += [0x2C]                     // end group 5 -> (5 << 3) | 4
        bytes += [0x24]                     // end group 4
        bytes += [0x30, 0x07]               // 6: varint 7

        try withReader(bytes) { reader in
            let group = try XCTUnwrap(try reader.nextField())
            XCTAssertEqual(group.wireType, .startGroup)
            try reader.skipField(wireType: group.wireType)

            let after = try XCTUnwrap(try reader.nextField())
            XCTAssertEqual(after.number, 6)
            XCTAssertEqual(try reader.readVarint(), 7)
            XCTAssertNil(try reader.nextField())
        }
    }

    func testUnbalancedEndGroupThrows() {
        XCTAssertThrowsError(try withReader([0x24]) { reader -> Void in
            let field = try XCTUnwrap(try reader.nextField())
            try reader.skipField(wireType: field.wireType)
        }) { error in
            XCTAssertEqual(error as? ProtobufError, .unexpectedEndGroup)
        }
    }

    func testEmptyBufferYieldsNoFields() throws {
        try withReader([]) { reader in
            XCTAssertNil(try reader.nextField())
            XCTAssertTrue(reader.isAtEnd)
        }
    }
}
