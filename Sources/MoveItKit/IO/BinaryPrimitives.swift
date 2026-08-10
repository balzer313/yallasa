import Foundation

/// Bounds-checked little-endian scalar reads over a raw byte buffer.
///
/// ZIP headers are a dense pile of unaligned little-endian fields sitting at
/// offsets that come *from the file itself*. A truncated or hostile archive will
/// therefore point at offsets past the end of the mapping, and a wild read on
/// mapped memory is a crash rather than a caught error. Every accessor here
/// returns an optional so the parser is forced to write `guard let` at each field
/// and a malformed archive degrades into a thrown `ZipError`.
///
/// The reads are spelled out byte by byte rather than as a typed load because
/// these offsets are never guaranteed to be aligned and header parsing happens a
/// few hundred times per archive, where clarity is worth more than speed.
internal enum LittleEndian {
    static func uint16(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= bytes.count - 2 else { return nil }
        let byte0 = UInt16(bytes[offset])
        let byte1 = UInt16(bytes[offset + 1])
        return byte0 | (byte1 << 8)
    }

    static func uint32(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= bytes.count - 4 else { return nil }
        let byte0 = UInt32(bytes[offset])
        let byte1 = UInt32(bytes[offset + 1])
        let byte2 = UInt32(bytes[offset + 2])
        let byte3 = UInt32(bytes[offset + 3])
        return byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
    }

    static func uint64(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= bytes.count - 8 else { return nil }
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var index = offset
        while index < offset + 8 {
            value |= UInt64(bytes[index]) << shift
            shift += 8
            index += 1
        }
        return value
    }
}

/// Reads over raw bytes that are not scalars.
internal enum RawBytes {
    /// Decodes a UTF-8 run, substituting replacement characters rather than
    /// failing. File names in the wild are occasionally CP437 or plain broken,
    /// and refusing to open a feed because one member name has a stray byte in it
    /// would be a much worse outcome than a mangled name we never match on.
    static func string(_ bytes: UnsafeRawBufferPointer, at offset: Int, count length: Int) -> String? {
        guard offset >= 0, offset <= bytes.count, length >= 0, length <= bytes.count - offset else {
            return nil
        }
        guard length > 0 else { return "" }
        guard let base = bytes.baseAddress else { return nil }
        let start = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        return String(decoding: UnsafeBufferPointer(start: start, count: length), as: UTF8.self)
    }
}
