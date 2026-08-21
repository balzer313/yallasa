import Foundation
#if canImport(Compression)
import Compression
#endif

/// One member of a ZIP archive, as described by its central directory record.
///
/// Sizes and offsets are widened to `Int` here, including the ZIP64 forms, so
/// that nothing downstream has to know whether the archive crossed the 4 GB or
/// 65 535-entry line that separates the two variants of the format.
public struct ZipEntry: Hashable, Sendable {
    /// Full path as stored in the archive.
    public var name: String
    /// Last path component, lowercased. Stored rather than computed because
    /// every lookup goes through it and archives can hold thousands of members.
    public var baseName: String
    public var compressedSize: Int
    public var uncompressedSize: Int
    public var crc32: UInt32
    /// 0 = stored, 8 = deflate. Anything else is refused at read time rather
    /// than at open time, so an archive with one exotic member is still usable.
    public var compressionMethod: UInt16
    public var localHeaderOffset: Int
}

/// Read-only access to a ZIP archive backed by the same memory map the graph
/// files use.
///
/// Three decisions are worth explaining:
///
/// 1. **It maps rather than reads.** A GTFS archive is routinely 100–400 MB and
///    the importer only ever streams each member once. Mapping keeps resident
///    memory proportional to what is being inflated right now, and `stops.txt`
///    stored uncompressed can be parsed straight out of the page cache with no
///    copy at all — that is what `withBytes(of:)` exists for.
/// 2. **Entry data is located by re-reading the local file header.** The central
///    directory's extra-field length describes the *central* record; the local
///    record almost always carries different extras (alignment padding, unix
///    timestamps), so the payload offset can only be computed from the local
///    header. Trusting the central directory's lengths is the single most common
///    way a hand-rolled ZIP reader silently returns garbage.
/// 3. **Lookup is by base name.** See `entry(named:)`.
///
/// The archive must outlive any buffer handed to `withBytes(of:)`; the mapping
/// dies with it.
public final class ZipArchive {
    /// Anything larger than this is refused rather than inflated. A 2 GB member
    /// in a transit feed is a corrupt header or a decompression bomb, never a
    /// real table, and the alternative to refusing is an allocation the device
    /// cannot satisfy.
    private static let maximumEntryBytes = 2 * 1024 * 1024 * 1024

    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64RecordSignature: UInt32 = 0x0606_4B50
    private static let zip64ExtraFieldIdentifier: UInt16 = 0x0001
    /// Sentinel written into a 32-bit field whose real value lives in the ZIP64
    /// extra field.
    private static let zip64Sentinel: UInt32 = 0xFFFF_FFFF

    /// Held only to keep the mapping alive for as long as `bytes` is used.
    private let memory: GraphMemory
    private let bytes: UnsafeRawBufferPointer
    private let baseNameIndex: [String: Int]

    public let entries: [ZipEntry]

    public init(url: URL) throws {
        // Reuses the graph's mapping code deliberately: one mmap implementation,
        // one place where the Darwin/non-Darwin split is handled.
        let memory = try GraphMemory.map(contentsOf: url)
        let bytes = try memory.rawBytes(byteOffset: 0, count: memory.count)
        let entries = try ZipArchive.readCentralDirectory(bytes)

        var index: [String: Int] = [:]
        index.reserveCapacity(entries.count)
        for position in 0..<entries.count {
            let entry = entries[position]
            // Directory records share a base name with nothing useful and would
            // shadow a real file only by accident; leave them out of the index.
            guard !entry.name.hasSuffix("/") else { continue }
            if index[entry.baseName] == nil {
                index[entry.baseName] = position
            }
        }

        self.memory = memory
        self.bytes = bytes
        self.entries = entries
        self.baseNameIndex = index
    }

    /// Case-insensitive match on the *base* name. GTFS archives are routinely
    /// published with every file inside a top-level folder, so matching the full
    /// path fails on perfectly valid feeds.
    public func entry(named name: String) -> ZipEntry? {
        guard let position = baseNameIndex[ZipArchive.baseName(of: name)] else { return nil }
        return entries[position]
    }

    /// Inflates an entry fully into memory.
    public func data(for entry: ZipEntry) throws -> Data {
        try withBytes(of: entry) { (raw: UnsafeRawBufferPointer) -> Data in
            guard let base = raw.baseAddress, raw.count > 0 else { return Data() }
            return Data(bytes: base, count: raw.count)
        }
    }

    /// Inflates and yields the bytes without an extra copy. Preferred for the
    /// large tables; `body` must not escape the pointer.
    ///
    /// A stored entry yields a view straight into the mapping, so importing an
    /// uncompressed `stop_times.txt` costs no heap at all.
    public func withBytes<R>(
        of entry: ZipEntry,
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) throws -> R {
        guard entry.uncompressedSize >= 0, entry.uncompressedSize <= ZipArchive.maximumEntryBytes else {
            throw ZipError.entryTooLarge(entry.uncompressedSize)
        }

        let payload = try payloadRegion(for: entry)

        switch entry.compressionMethod {
        case 0:
            try ZipArchive.verify(payload, against: entry)
            return try body(payload)
        case 8:
            // A national feed's stop_times.txt is half a gigabyte uncompressed.
            // Inflating that into one heap buffer is a jetsam kill on a phone,
            // so anything this large is spilled to a mapped temporary file and
            // the kernel is left to page it. Everything smaller keeps the
            // simpler in-memory route.
            if entry.uncompressedSize > ZipStreamingInflate.spillThreshold {
                return try ZipStreamingInflate.withMappedInflation(
                    of: payload,
                    expecting: entry.uncompressedSize,
                    entryName: entry.name
                ) { raw in
                    try ZipArchive.verify(raw, against: entry)
                    return try body(raw)
                }
            }

            let inflated = try ZipArchive.inflate(
                payload,
                expecting: entry.uncompressedSize,
                entryName: entry.name
            )
            return try inflated.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> R in
                try ZipArchive.verify(raw, against: entry)
                return try body(raw)
            }
        default:
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }
    }

    // MARK: - Locating payloads

    /// Computes the byte range of an entry's payload from its **local** header.
    private func payloadRegion(for entry: ZipEntry) throws -> UnsafeRawBufferPointer {
        let offset = entry.localHeaderOffset
        guard offset >= 0, offset <= bytes.count - 30,
              LittleEndian.uint32(bytes, at: offset) == ZipArchive.localHeaderSignature,
              let nameLength = LittleEndian.uint16(bytes, at: offset + 26),
              let extraLength = LittleEndian.uint16(bytes, at: offset + 28)
        else {
            throw ZipError.corruptCentralDirectory("no local header for \(entry.name)")
        }

        let start = offset + 30 + Int(nameLength) + Int(extraLength)
        // A stored entry's compressed size is occasionally left at zero by
        // writers that streamed it; the uncompressed size is the truth there.
        let length = entry.compressionMethod == 0 ? entry.uncompressedSize : entry.compressedSize
        guard length >= 0, start >= 0, start <= bytes.count, length <= bytes.count - start else {
            throw ZipError.corruptCentralDirectory("\(entry.name) runs past the end of the archive")
        }
        guard let base = bytes.baseAddress else {
            throw ZipError.corruptCentralDirectory("the archive is empty")
        }
        return UnsafeRawBufferPointer(start: base.advanced(by: start), count: length)
    }

    private static func verify(_ payload: UnsafeRawBufferPointer, against entry: ZipEntry) throws {
        // An empty member has nothing to check and some writers leave its CRC
        // field uninitialised.
        guard payload.count > 0 else { return }
        guard ZipCRC32.checksum(payload) == entry.crc32 else {
            throw ZipError.checksumMismatch(entry: entry.name)
        }
    }

    private static func baseName(of path: String) -> String {
        var component = path
        if let separator = component.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            component = String(component[component.index(after: separator)...])
        }
        return component.lowercased()
    }

    // MARK: - Central directory

    private struct EndOfCentralDirectory {
        var entryCount: Int
        var directoryOffset: Int
        var directorySize: Int
    }

    private static func readCentralDirectory(_ bytes: UnsafeRawBufferPointer) throws -> [ZipEntry] {
        let end = try findEndOfCentralDirectory(bytes)

        guard end.directoryOffset >= 0, end.directoryOffset <= bytes.count else {
            throw ZipError.corruptCentralDirectory("the central directory starts past the end of the file")
        }
        // The declared size is only a hint: self-extracting archives and
        // concatenated files habitually get it slightly wrong, and the record
        // signatures are what actually delimit the walk.
        let directoryEnd: Int
        if end.directorySize > 0, end.directoryOffset <= bytes.count - end.directorySize {
            directoryEnd = end.directoryOffset + end.directorySize
        } else {
            directoryEnd = bytes.count
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(min(max(end.entryCount, 0), 8192))

        var offset = end.directoryOffset
        while offset <= directoryEnd - 46 {
            guard LittleEndian.uint32(bytes, at: offset) == centralHeaderSignature else { break }
            let parsed = try parseCentralEntry(bytes, at: offset, limit: directoryEnd)
            entries.append(parsed.entry)
            offset = parsed.next
        }

        guard !entries.isEmpty || end.entryCount == 0 else {
            throw ZipError.corruptCentralDirectory(
                "expected \(end.entryCount) entries but found none at offset \(end.directoryOffset)"
            )
        }
        return entries
    }

    private static func parseCentralEntry(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int,
        limit: Int
    ) throws -> (entry: ZipEntry, next: Int) {
        guard let method = LittleEndian.uint16(bytes, at: offset + 10),
              let crc = LittleEndian.uint32(bytes, at: offset + 16),
              let compressedRaw = LittleEndian.uint32(bytes, at: offset + 20),
              let uncompressedRaw = LittleEndian.uint32(bytes, at: offset + 24),
              let nameLength = LittleEndian.uint16(bytes, at: offset + 28),
              let extraLength = LittleEndian.uint16(bytes, at: offset + 30),
              let commentLength = LittleEndian.uint16(bytes, at: offset + 32),
              let localOffsetRaw = LittleEndian.uint32(bytes, at: offset + 42)
        else {
            throw ZipError.corruptCentralDirectory("truncated directory record at \(offset)")
        }

        let nameStart = offset + 46
        let extraStart = nameStart + Int(nameLength)
        let extraEnd = extraStart + Int(extraLength)
        let next = extraEnd + Int(commentLength)
        guard next <= limit, next <= bytes.count else {
            throw ZipError.corruptCentralDirectory("directory record at \(offset) overruns the directory")
        }

        guard let name = RawBytes.string(bytes, at: nameStart, count: Int(nameLength)) else {
            throw ZipError.corruptCentralDirectory("unreadable file name at \(nameStart)")
        }

        var compressedSize = Int(compressedRaw)
        var uncompressedSize = Int(uncompressedRaw)
        var localHeaderOffset = Int(localOffsetRaw)

        if compressedRaw == zip64Sentinel || uncompressedRaw == zip64Sentinel || localOffsetRaw == zip64Sentinel {
            let overrides = zip64Overrides(
                bytes,
                from: extraStart,
                to: extraEnd,
                wantsUncompressed: uncompressedRaw == zip64Sentinel,
                wantsCompressed: compressedRaw == zip64Sentinel,
                wantsOffset: localOffsetRaw == zip64Sentinel
            )
            if let value = overrides.uncompressedSize { uncompressedSize = value }
            if let value = overrides.compressedSize { compressedSize = value }
            if let value = overrides.localHeaderOffset { localHeaderOffset = value }
        }

        let entry = ZipEntry(
            name: name,
            baseName: baseName(of: name),
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            crc32: crc,
            compressionMethod: method,
            localHeaderOffset: localHeaderOffset
        )
        return (entry, next)
    }

    /// Walks the extra-field chain looking for the ZIP64 record.
    ///
    /// The ZIP64 field packs only those values whose 32-bit slot held the
    /// sentinel, in a fixed order and with no per-value tag, so which flags were
    /// set in the fixed header is the only way to know what is present.
    private static func zip64Overrides(
        _ bytes: UnsafeRawBufferPointer,
        from start: Int,
        to end: Int,
        wantsUncompressed: Bool,
        wantsCompressed: Bool,
        wantsOffset: Bool
    ) -> (uncompressedSize: Int?, compressedSize: Int?, localHeaderOffset: Int?) {
        var uncompressedSize: Int? = nil
        var compressedSize: Int? = nil
        var localHeaderOffset: Int? = nil

        var cursor = start
        while cursor <= end - 4 {
            guard let identifier = LittleEndian.uint16(bytes, at: cursor),
                  let dataSize = LittleEndian.uint16(bytes, at: cursor + 2)
            else { break }
            let dataStart = cursor + 4
            let dataEnd = dataStart + Int(dataSize)
            guard dataEnd <= end else { break }

            if identifier == zip64ExtraFieldIdentifier {
                var field = dataStart
                if wantsUncompressed, field <= dataEnd - 8, let value = LittleEndian.uint64(bytes, at: field) {
                    uncompressedSize = Int(clamping: value)
                    field += 8
                }
                if wantsCompressed, field <= dataEnd - 8, let value = LittleEndian.uint64(bytes, at: field) {
                    compressedSize = Int(clamping: value)
                    field += 8
                }
                if wantsOffset, field <= dataEnd - 8, let value = LittleEndian.uint64(bytes, at: field) {
                    localHeaderOffset = Int(clamping: value)
                }
                break
            }
            cursor = dataEnd
        }
        return (uncompressedSize, compressedSize, localHeaderOffset)
    }

    private static func findEndOfCentralDirectory(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> EndOfCentralDirectory {
        let recordSize = 22
        guard bytes.count >= recordSize else { throw ZipError.notAZipArchive }

        // The record is last in the file but a trailing comment of up to 64 KB
        // may follow it, so the only way to find it is to scan backwards.
        let lowestOffset = max(0, bytes.count - (recordSize + 0xFFFF))
        var found: Int? = nil
        var offset = bytes.count - recordSize
        while offset >= lowestOffset {
            if LittleEndian.uint32(bytes, at: offset) == endOfCentralDirectorySignature {
                found = offset
                break
            }
            offset -= 1
        }
        guard let recordOffset = found else { throw ZipError.notAZipArchive }

        guard let entryCount16 = LittleEndian.uint16(bytes, at: recordOffset + 10),
              let directorySize32 = LittleEndian.uint32(bytes, at: recordOffset + 12),
              let directoryOffset32 = LittleEndian.uint32(bytes, at: recordOffset + 16)
        else {
            throw ZipError.corruptCentralDirectory("truncated end-of-central-directory record")
        }

        var result = EndOfCentralDirectory(
            entryCount: Int(entryCount16),
            directoryOffset: Int(directoryOffset32),
            directorySize: Int(directorySize32)
        )

        // A ZIP64 locator sits immediately before the classic record whenever any
        // of the 32-bit fields overflowed. Feeds for large countries do reach it.
        let locatorOffset = recordOffset - 20
        if locatorOffset >= 0,
           LittleEndian.uint32(bytes, at: locatorOffset) == zip64LocatorSignature,
           let recordPosition = LittleEndian.uint64(bytes, at: locatorOffset + 8) {
            let zip64Offset = Int(clamping: recordPosition)
            if zip64Offset >= 0, zip64Offset <= bytes.count - 56,
               LittleEndian.uint32(bytes, at: zip64Offset) == zip64RecordSignature {
                guard let entryCount64 = LittleEndian.uint64(bytes, at: zip64Offset + 32),
                      let directorySize64 = LittleEndian.uint64(bytes, at: zip64Offset + 40),
                      let directoryOffset64 = LittleEndian.uint64(bytes, at: zip64Offset + 48)
                else {
                    throw ZipError.corruptCentralDirectory("truncated ZIP64 end-of-central-directory record")
                }
                result.entryCount = Int(clamping: entryCount64)
                result.directorySize = Int(clamping: directorySize64)
                result.directoryOffset = Int(clamping: directoryOffset64)
            }
        }

        return result
    }

    // MARK: - Inflation

    /// Inflates `input` into a buffer sized from the central directory.
    ///
    /// The output size is taken from the directory rather than grown
    /// dynamically: it is authoritative even for entries written with a trailing
    /// data descriptor, it makes one allocation instead of a doubling sequence,
    /// and it turns a lying header into a thrown error instead of an unbounded
    /// allocation driven by the archive.
    ///
    /// One byte of slack is allocated beyond the declared size, and it is load
    /// bearing. With an exactly-sized destination the decoder writes the final
    /// byte, finds no room left, and returns `OK` *before* consuming the
    /// end-of-stream marker — indistinguishable from "there is more data than
    /// declared". The slack byte guarantees the decoder can always reach the end
    /// marker in the same call that emits the last byte, so `END` means the entry
    /// matched its declared size and a full buffer unambiguously means it lied.
    private static func inflate(
        _ input: UnsafeRawBufferPointer,
        expecting expectedSize: Int,
        entryName: String
    ) throws -> [UInt8] {
        guard expectedSize > 0 else { return [] }

        #if canImport(Compression)
        guard let inputBase = input.baseAddress, input.count > 0 else {
            throw ZipError.inflateFailed("\(entryName): the compressed payload is empty")
        }
        let source = inputBase.assumingMemoryBound(to: UInt8.self)
        let sourceCount = input.count
        let capacity = expectedSize + 1

        var produced = 0
        let output = try [UInt8](unsafeUninitializedCapacity: capacity) { buffer, initializedCount in
            guard let destination = buffer.baseAddress else {
                throw ZipError.inflateFailed("\(entryName): could not allocate \(capacity) bytes")
            }

            var stream = compression_stream(
                dst_ptr: destination,
                dst_size: capacity,
                src_ptr: source,
                src_size: sourceCount,
                state: nil
            )

            // COMPRESSION_ZLIB is Apple's name for *raw* deflate, which is
            // exactly what a ZIP member holds. There is no 2-byte header to
            // strip here, and adding one produces a decoder error.
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                    == COMPRESSION_STATUS_OK
            else {
                throw ZipError.inflateFailed("\(entryName): the decoder could not be created")
            }
            defer { compression_stream_destroy(&stream) }

            // compression_stream_init resets the buffer fields, so they are set
            // again afterwards rather than relying on the values above.
            stream.src_ptr = source
            stream.src_size = sourceCount
            stream.dst_ptr = destination
            stream.dst_size = capacity

            var previousSourceRemaining = stream.src_size
            var previousDestinationRemaining = stream.dst_size
            var finished = false

            while !finished {
                let status = compression_stream_process(
                    &stream,
                    Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                if status == COMPRESSION_STATUS_END {
                    finished = true
                } else if status == COMPRESSION_STATUS_OK {
                    if stream.dst_size == 0 {
                        throw ZipError.inflateFailed(
                            "\(entryName): inflates to more than the declared \(expectedSize) bytes"
                        )
                    }
                    if stream.src_size == previousSourceRemaining,
                       stream.dst_size == previousDestinationRemaining {
                        throw ZipError.inflateFailed("\(entryName): the deflate stream stalled")
                    }
                    previousSourceRemaining = stream.src_size
                    previousDestinationRemaining = stream.dst_size
                } else {
                    throw ZipError.inflateFailed("\(entryName): the deflate stream is corrupt")
                }
            }

            produced = capacity - stream.dst_size
            initializedCount = produced
        }

        guard produced == expectedSize else {
            throw ZipError.inflateFailed(
                "\(entryName): inflated \(produced) bytes but the directory declares \(expectedSize)"
            )
        }
        return output
        #else
        throw ZipError.unsupportedCompression(8)
        #endif
    }
}

/// CRC-32 as ZIP defines it: the IEEE 802.3 polynomial, reflected, with the
/// customary pre- and post-inversion.
///
/// Written out rather than taken from zlib because the whole engine ships with
/// no third-party code, and this runs once per imported table where the cost is
/// invisible next to inflation.
internal enum ZipCRC32 {
    /// Built on first use. Most graph opens never touch a ZIP at all, so the
    /// kilobyte stays unallocated for the common case.
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                if value & 1 == 1 {
                    value = 0xEDB8_8320 ^ (value >> 1)
                } else {
                    value >>= 1
                }
            }
            table[index] = value
        }
        return table
    }()

    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        let table = ZipCRC32.table
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

public enum ZipError: Error, LocalizedError, Equatable {
    case notAZipArchive
    case unsupportedCompression(UInt16)
    case corruptCentralDirectory(String)
    case entryTooLarge(Int)
    case inflateFailed(String)
    case checksumMismatch(entry: String)

    public var errorDescription: String? {
        switch self {
        case .notAZipArchive:
            return "This file is not a zip archive."
        case .unsupportedCompression(let method):
            return "The archive uses compression method \(method), which is not supported."
        case .corruptCentralDirectory(let reason):
            return "The archive's directory is damaged: \(reason)."
        case .entryTooLarge(let byteCount):
            return "An entry of \(byteCount) bytes is too large to read."
        case .inflateFailed(let reason):
            return "The archive could not be decompressed: \(reason)."
        case .checksumMismatch(let entry):
            return "\(entry) failed its checksum; the download is damaged."
        }
    }
}
