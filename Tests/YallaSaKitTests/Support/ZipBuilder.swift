import Foundation
import Compression

/// Writes a minimal ZIP archive, stored by default and deflated on request.
///
/// Stored rather than deflated on purpose: the point of these fixtures is to
/// exercise the *importer*, and an archive whose contents are plainly visible in
/// a hex dump is far easier to debug when a test fails. `ZipArchiveTests` covers
/// the deflate path separately.
///
/// The CRC-32 here is written out independently of the engine's own
/// implementation, so a fault in `ZipCRC32` shows up as a checksum mismatch
/// rather than being cancelled out by using the same code on both sides.
struct ZipBuilder {
    private struct Entry {
        var name: String
        var data: Data
        var crc: UInt32
        var localHeaderOffset: Int
        /// 0 stored, 8 deflated. The central record has to agree with the local
        /// one or the reader looks for the wrong payload shape.
        var method: UInt16 = 0
        /// Equal to data.count for a stored entry.
        var compressedSize: Int?
    }

    private var body = Data()
    private var entries: [Entry] = []

    mutating func add(_ name: String, contents: String) {
        add(name, data: Data(contents.utf8))
    }

    mutating func add(_ name: String, data: Data) {
        let nameBytes = Data(name.utf8)
        let crc = ZipBuilder.crc32(data)
        let offset = body.count

        var header = Data()
        header.appendLE(UInt32(0x0403_4B50))     // local file header signature
        header.appendLE(UInt16(20))              // version needed
        header.appendLE(UInt16(0))               // flags
        header.appendLE(UInt16(0))               // method: stored
        header.appendLE(UInt16(0))               // modification time
        header.appendLE(UInt16(0))               // modification date
        header.appendLE(crc)
        header.appendLE(UInt32(data.count))      // compressed size
        header.appendLE(UInt32(data.count))      // uncompressed size
        header.appendLE(UInt16(nameBytes.count))
        // Deliberately non-zero: the local and central records legitimately carry
        // different extra fields, and a reader that computes the payload offset
        // from the central record's length lands in the middle of the data.
        let extra = Data([0xEF, 0xBE, 0x04, 0x00, 0x01, 0x02, 0x03, 0x04])
        header.appendLE(UInt16(extra.count))

        body.append(header)
        body.append(nameBytes)
        body.append(extra)
        body.append(data)

        entries.append(Entry(name: name, data: data, crc: crc, localHeaderOffset: offset))
    }

    /// Adds a **deflated** entry.
    ///
    /// Needed because the streaming-inflate path only runs for method 8, so a
    /// fixture built from stored entries would silently test the branch it was
    /// meant to avoid. The compressed bytes are produced by Compression rather
    /// than by the engine's reader, keeping generation and verification
    /// independent for the same reason the CRC is hand-rolled above.
    mutating func addDeflated(name: String, bytes: [UInt8]) {
        let data = Data(bytes)
        let compressed = ZipBuilder.deflate(data)
        let nameBytes = Data(name.utf8)
        let crc = ZipBuilder.crc32(data)
        let offset = body.count

        var header = Data()
        header.appendLE(UInt32(0x0403_4B50))
        header.appendLE(UInt16(20))
        header.appendLE(UInt16(0))
        header.appendLE(UInt16(8))               // method: deflate
        header.appendLE(UInt16(0))
        header.appendLE(UInt16(0))
        header.appendLE(crc)
        header.appendLE(UInt32(compressed.count))
        header.appendLE(UInt32(data.count))
        header.appendLE(UInt16(nameBytes.count))
        let extra = Data([0xEF, 0xBE, 0x04, 0x00, 0x01, 0x02, 0x03, 0x04])
        header.appendLE(UInt16(extra.count))

        body.append(header)
        body.append(nameBytes)
        body.append(extra)
        body.append(compressed)

        entries.append(
            Entry(
                name: name,
                data: data,
                crc: crc,
                localHeaderOffset: offset,
                method: 8,
                compressedSize: compressed.count
            )
        )
    }

    /// Raw deflate — what a ZIP member holds. `COMPRESSION_ZLIB` is Apple's
    /// name for it and emits no zlib header, which is what the reader expects.
    private static func deflate(_ data: Data) -> Data {
        let capacity = data.count + 64 * 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                compression_encode_buffer(
                    destination.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    capacity,
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        precondition(written > 0, "the fixture failed to compress")
        return output.prefix(written)
    }

    func build() -> Data {
        var archive = body
        let directoryOffset = archive.count

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            var record = Data()
            record.appendLE(UInt32(0x0201_4B50))    // central directory signature
            record.appendLE(UInt16(20))             // version made by
            record.appendLE(UInt16(20))             // version needed
            record.appendLE(UInt16(0))              // flags
            record.appendLE(entry.method)           // 0 stored, 8 deflated
            record.appendLE(UInt16(0))              // modification time
            record.appendLE(UInt16(0))              // modification date
            record.appendLE(entry.crc)
            record.appendLE(UInt32(entry.compressedSize ?? entry.data.count))
            record.appendLE(UInt32(entry.data.count))
            record.appendLE(UInt16(nameBytes.count))
            record.appendLE(UInt16(0))              // extra length (central: none)
            record.appendLE(UInt16(0))              // comment length
            record.appendLE(UInt16(0))              // disk number start
            record.appendLE(UInt16(0))              // internal attributes
            record.appendLE(UInt32(0))              // external attributes
            record.appendLE(UInt32(entry.localHeaderOffset))
            archive.append(record)
            archive.append(nameBytes)
        }

        let directorySize = archive.count - directoryOffset

        var end = Data()
        end.appendLE(UInt32(0x0605_4B50))           // end of central directory
        end.appendLE(UInt16(0))                     // this disk
        end.appendLE(UInt16(0))                     // disk with the directory
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt32(directorySize))
        end.appendLE(UInt32(directoryOffset))
        end.appendLE(UInt16(0))                     // comment length
        archive.append(end)

        return archive
    }

    /// Writes the archive to a temporary file and returns its URL.
    func write(named name: String = "feed.zip") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yallasa-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try build().write(to: url)
        return url
    }

    /// IEEE 802.3 CRC-32, reflected, with the customary inversions.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        // Qualified: unqualified, this resolves to `Data.withUnsafeBytes`.
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
