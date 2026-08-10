import Foundation

/// The six protobuf wire types, numbered as the encoding itself numbers them.
///
/// `startGroup` / `endGroup` are deprecated in proto3 and no GTFS-Realtime field
/// uses them, but a producer is free to emit them in a field we do not know
/// about, and "unknown field" must never mean "failed parse".
public enum ProtobufWireType: UInt8, Sendable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case startGroup = 3
    case endGroup = 4
    case fixed32 = 5
}

/// Everything that can go wrong reading a protobuf message.
///
/// All of these mean "the bytes are not a protobuf message", never "the message
/// contains something we did not expect" — the latter is normal and is handled by
/// skipping. Realtime feeds are network data from a third party, so every one of
/// these is reachable from a hostile input and none of them may be a trap.
public enum ProtobufError: Error, LocalizedError, Equatable {
    /// A field ran past the end of the buffer.
    case truncated
    /// A varint did not terminate within its ten-byte maximum.
    case malformedVarint
    /// Field numbers are 1...2^29-1; anything else is a corrupt tag.
    case invalidFieldNumber(UInt64)
    /// Wire types 6 and 7 do not exist.
    case unknownWireType(UInt8)
    /// A group ended that never started.
    case unexpectedEndGroup
    /// A pathologically nested group. Bounded so a crafted feed cannot blow the
    /// stack while being skipped.
    case nestingTooDeep

    public var errorDescription: String? {
        switch self {
        case .truncated:
            return "The realtime message is truncated."
        case .malformedVarint:
            return "The realtime message contains a malformed integer."
        case .invalidFieldNumber(let number):
            return "The realtime message contains an invalid field number (\(number))."
        case .unknownWireType(let value):
            return "The realtime message contains an unknown wire type (\(value))."
        case .unexpectedEndGroup:
            return "The realtime message contains an unbalanced group."
        case .nestingTooDeep:
            return "The realtime message is nested too deeply."
        }
    }
}

/// A forward-only reader over protobuf wire format.
///
/// Deliberately not a full protobuf runtime: it knows the wire encoding and
/// nothing about schemas, so the decoder above it can read the handful of
/// GTFS-Realtime fields the engine actually uses and skip the rest. That keeps
/// the realtime path free of a code-generated dependency, which the project's
/// no-third-party rule requires, and keeps the parse allocation-free until a
/// `String` is genuinely needed.
///
/// Every read is bounds-checked against the buffer. This parses bytes handed to
/// us by an agency's server over the public internet; a single unchecked
/// `advance` here would be a remote memory-disclosure bug.
public struct ProtobufReader {
    private let bytes: UnsafeRawBufferPointer
    private var offset: Int

    public init(bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
        self.offset = 0
    }

    /// True once every byte has been consumed.
    public var isAtEnd: Bool { offset >= bytes.count }

    /// Reads the next tag, or nil at the end of the buffer.
    public mutating func nextField() throws -> (number: Int, wireType: ProtobufWireType)? {
        if offset >= bytes.count { return nil }
        let key = try readVarint()
        let rawWireType = UInt8(key & 0x07)
        guard let wireType = ProtobufWireType(rawValue: rawWireType) else {
            throw ProtobufError.unknownWireType(rawWireType)
        }
        let rawNumber = key >> 3
        guard rawNumber >= 1, rawNumber <= 536_870_911 else {
            throw ProtobufError.invalidFieldNumber(rawNumber)
        }
        return (number: Int(rawNumber), wireType: wireType)
    }

    /// Base-128 varint. Ten bytes is the maximum: a negative `int32` is
    /// sign-extended to 64 bits before encoding, so `-1` arrives as ten bytes
    /// even though the declared field is 32 bits wide.
    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = 0
        while index < 10 {
            guard offset < bytes.count else { throw ProtobufError.truncated }
            let byte = bytes[offset]
            offset += 1
            index += 1
            if index == 10 {
                // Only bit 63 of the tenth byte can survive the shift; anything
                // above it is overflow that no conforming encoder produces.
                guard byte & 0x80 == 0 else { throw ProtobufError.malformedVarint }
                result |= UInt64(byte & 0x01) << 63
                return result
            }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtobufError.malformedVarint
    }

    /// Little-endian, assembled byte by byte rather than loaded as a word: the
    /// buffer offset is arbitrary and the file format makes no alignment promise.
    public mutating func readFixed32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw ProtobufError.truncated }
        var value: UInt32 = 0
        value |= UInt32(bytes[offset])
        value |= UInt32(bytes[offset + 1]) << 8
        value |= UInt32(bytes[offset + 2]) << 16
        value |= UInt32(bytes[offset + 3]) << 24
        offset += 4
        return value
    }

    public mutating func readFixed64() throws -> UInt64 {
        guard offset + 8 <= bytes.count else { throw ProtobufError.truncated }
        var value: UInt64 = 0
        value |= UInt64(bytes[offset])
        value |= UInt64(bytes[offset + 1]) << 8
        value |= UInt64(bytes[offset + 2]) << 16
        value |= UInt64(bytes[offset + 3]) << 24
        value |= UInt64(bytes[offset + 4]) << 32
        value |= UInt64(bytes[offset + 5]) << 40
        value |= UInt64(bytes[offset + 6]) << 48
        value |= UInt64(bytes[offset + 7]) << 56
        offset += 8
        return value
    }

    /// A length-prefixed payload — a string, a `bytes` field, or a submessage.
    ///
    /// The returned buffer points into the reader's own buffer and is valid only
    /// as long as that is. Nothing escapes the decode, which copies out `String`s.
    public mutating func readLengthDelimited() throws -> UnsafeRawBufferPointer {
        let length = try readVarint()
        let remaining = bytes.count - offset
        guard remaining >= 0, length <= UInt64(remaining) else { throw ProtobufError.truncated }
        let count = Int(length)
        let start = bytes.baseAddress.map { $0.advanced(by: offset) }
        offset += count
        return UnsafeRawBufferPointer(start: start, count: count)
    }

    /// Consumes a field whose number the decoder does not recognise.
    public mutating func skipField(wireType: ProtobufWireType) throws {
        switch wireType {
        case .varint:
            _ = try readVarint()
        case .fixed64:
            _ = try readFixed64()
        case .lengthDelimited:
            _ = try readLengthDelimited()
        case .fixed32:
            _ = try readFixed32()
        case .startGroup:
            try skipGroup(depth: 0)
        case .endGroup:
            throw ProtobufError.unexpectedEndGroup
        }
    }

    private mutating func skipGroup(depth: Int) throws {
        guard depth < 32 else { throw ProtobufError.nestingTooDeep }
        while true {
            guard let field = try nextField() else { throw ProtobufError.truncated }
            switch field.wireType {
            case .endGroup:
                return
            case .startGroup:
                try skipGroup(depth: depth + 1)
            default:
                try skipField(wireType: field.wireType)
            }
        }
    }

    // MARK: - Typed convenience reads
    //
    // Internal rather than public: `CONTRACTS.md` fixes the public surface of this
    // type, and only the decoder in this module needs these.

    mutating func readString() throws -> String {
        let payload = try readLengthDelimited()
        if payload.count == 0 { return "" }
        return String(decoding: payload, as: UTF8.self)
    }

    mutating func readBool() throws -> Bool {
        try readVarint() != 0
    }

    /// Signed 32-bit fields are *not* zigzag-encoded unless declared `sint32`;
    /// GTFS-Realtime declares plain `int32`, so a negative value arrives as a
    /// sign-extended 64-bit varint and the low 32 bits are the answer.
    mutating func readInt32() throws -> Int32 {
        Int32(truncatingIfNeeded: try readVarint())
    }

    mutating func readUInt32() throws -> UInt32 {
        UInt32(truncatingIfNeeded: try readVarint())
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readVarint())
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readFixed32())
    }

    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readFixed64())
    }
}
