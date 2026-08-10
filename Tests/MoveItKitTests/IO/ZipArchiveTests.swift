import Foundation
import XCTest
#if canImport(Compression)
import Compression
#endif
@testable import MoveItKit

final class ZipArchiveTests: XCTestCase {

    // MARK: - Byte helpers

    private func putUInt16(_ value: UInt16, into data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func putUInt32(_ value: UInt32, into data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func putUInt64(_ value: UInt64, into data: inout Data) {
        var shift: UInt64 = 0
        while shift < 64 {
            data.append(UInt8((value >> shift) & 0xFF))
            shift += 8
        }
    }

    private func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            ZipCRC32.checksum(raw)
        }
    }

    /// One member, described the way the writer wants it rather than the way the
    /// archive stores it, so a test can lie about a size or a checksum.
    private struct Member {
        var name: String
        var payload: Data
        var uncompressedSize: Int
        var crc32: UInt32
        var method: UInt16
        /// Present in the *local* header only. Real archives put alignment and
        /// timestamp extras here that the central directory does not repeat, and
        /// a reader that trusts the central lengths reads from the wrong offset.
        var localExtra: Data
    }

    private func storedMember(name: String, text: String, localExtra: Data = Data()) -> Member {
        let payload = Data(text.utf8)
        return Member(
            name: name,
            payload: payload,
            uncompressedSize: payload.count,
            crc32: checksum(payload),
            method: 0,
            localExtra: localExtra
        )
    }

    private func buildArchive(_ members: [Member]) -> Data {
        var body = Data()
        var directory = Data()

        for member in members {
            let nameBytes = Array(member.name.utf8)
            let localOffset = body.count

            putUInt32(0x0403_4B50, into: &body)
            putUInt16(20, into: &body)                                  // version needed
            putUInt16(0, into: &body)                                   // flags
            putUInt16(member.method, into: &body)
            putUInt16(0, into: &body)                                   // modification time
            putUInt16(0, into: &body)                                   // modification date
            putUInt32(member.crc32, into: &body)
            putUInt32(UInt32(member.payload.count), into: &body)
            putUInt32(UInt32(member.uncompressedSize), into: &body)
            putUInt16(UInt16(nameBytes.count), into: &body)
            putUInt16(UInt16(member.localExtra.count), into: &body)
            body.append(contentsOf: nameBytes)
            body.append(member.localExtra)
            body.append(member.payload)

            putUInt32(0x0201_4B50, into: &directory)
            putUInt16(20, into: &directory)                             // version made by
            putUInt16(20, into: &directory)                             // version needed
            putUInt16(0, into: &directory)                              // flags
            putUInt16(member.method, into: &directory)
            putUInt16(0, into: &directory)                              // modification time
            putUInt16(0, into: &directory)                              // modification date
            putUInt32(member.crc32, into: &directory)
            putUInt32(UInt32(member.payload.count), into: &directory)
            putUInt32(UInt32(member.uncompressedSize), into: &directory)
            putUInt16(UInt16(nameBytes.count), into: &directory)
            putUInt16(0, into: &directory)                              // extra length
            putUInt16(0, into: &directory)                              // comment length
            putUInt16(0, into: &directory)                              // disk number
            putUInt16(0, into: &directory)                              // internal attributes
            putUInt32(0, into: &directory)                              // external attributes
            putUInt32(UInt32(localOffset), into: &directory)
            directory.append(contentsOf: nameBytes)
        }

        var archive = body
        let directoryOffset = archive.count
        archive.append(directory)

        putUInt32(0x0605_4B50, into: &archive)
        putUInt16(0, into: &archive)                                    // this disk
        putUInt16(0, into: &archive)                                    // disk with the directory
        putUInt16(UInt16(members.count), into: &archive)
        putUInt16(UInt16(members.count), into: &archive)
        putUInt32(UInt32(directory.count), into: &archive)
        putUInt32(UInt32(directoryOffset), into: &archive)
        putUInt16(0, into: &archive)                                    // comment length
        return archive
    }

    private func write(_ archive: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moveit-zip-\(UUID().uuidString).zip")
        try archive.write(to: url)
        return url
    }

    // MARK: - Stored entries

    func testReadsStoredEntries() throws {
        let stops = "stop_id,stop_name\nA,Alpha\n"
        let routes = "route_id,route_short_name\n1,Red\n"
        let archive = buildArchive([
            storedMember(name: "feed/stops.txt", text: stops, localExtra: Data([0x55, 0x54, 0x02, 0x00, 0x01, 0x02])),
            storedMember(name: "feed/routes.txt", text: routes),
        ])
        let url = try write(archive)
        defer { try? FileManager.default.removeItem(at: url) }

        let zip = try ZipArchive(url: url)
        XCTAssertEqual(zip.entries.count, 2)
        XCTAssertEqual(zip.entries.map(\.name), ["feed/stops.txt", "feed/routes.txt"])
        XCTAssertEqual(zip.entries.map(\.baseName), ["stops.txt", "routes.txt"])
        XCTAssertEqual(zip.entries[0].compressionMethod, 0)
        XCTAssertEqual(zip.entries[0].uncompressedSize, Data(stops.utf8).count)
        XCTAssertEqual(zip.entries[0].crc32, checksum(Data(stops.utf8)))

        // The first member carries a local-only extra field, so this also proves
        // the payload offset comes from the local header.
        XCTAssertEqual(try zip.data(for: zip.entries[0]), Data(stops.utf8))
        XCTAssertEqual(try zip.data(for: zip.entries[1]), Data(routes.utf8))
    }

    func testEntryLookupIgnoresFoldersAndCase() throws {
        let archive = buildArchive([
            storedMember(name: "gtfs-2026/stops.txt", text: "stop_id\nA\n"),
            storedMember(name: "gtfs-2026/trips.txt", text: "trip_id\nT\n"),
        ])
        let url = try write(archive)
        defer { try? FileManager.default.removeItem(at: url) }

        let zip = try ZipArchive(url: url)
        XCTAssertEqual(zip.entry(named: "stops.txt")?.name, "gtfs-2026/stops.txt")
        XCTAssertEqual(zip.entry(named: "STOPS.TXT")?.name, "gtfs-2026/stops.txt")
        XCTAssertEqual(zip.entry(named: "some/other/path/trips.txt")?.name, "gtfs-2026/trips.txt")
        XCTAssertNil(zip.entry(named: "shapes.txt"))
    }

    func testWithBytesYieldsTheSameContentAsData() throws {
        let text = String(repeating: "0123456789,abcdefghij\n", count: 64)
        let archive = buildArchive([storedMember(name: "stop_times.txt", text: text)])
        let url = try write(archive)
        defer { try? FileManager.default.removeItem(at: url) }

        let zip = try ZipArchive(url: url)
        guard let entry = zip.entry(named: "stop_times.txt") else {
            return XCTFail("expected stop_times.txt")
        }
        let copied = try zip.data(for: entry)
        let viewed = try zip.withBytes(of: entry) { (raw: UnsafeRawBufferPointer) -> Data in
            guard let base = raw.baseAddress else { return Data() }
            return Data(bytes: base, count: raw.count)
        }
        XCTAssertEqual(copied, Data(text.utf8))
        XCTAssertEqual(viewed, copied)
    }

    // MARK: - Failure modes

    func testChecksumMismatchIsReported() throws {
        var member = storedMember(name: "stops.txt", text: "stop_id\nA\n")
        member.crc32 = member.crc32 &+ 1
        let url = try write(buildArchive([member]))
        defer { try? FileManager.default.removeItem(at: url) }

        let zip = try ZipArchive(url: url)
        guard let entry = zip.entry(named: "stops.txt") else { return XCTFail("expected stops.txt") }
        XCTAssertThrowsError(try zip.data(for: entry)) { error in
            XCTAssertEqual(error as? ZipError, .checksumMismatch(entry: "stops.txt"))
        }
    }

    func testUnsupportedCompressionIsReported() throws {
        var member = storedMember(name: "stops.txt", text: "stop_id\nA\n")
        member.method = 99
        let url = try write(buildArchive([member]))
        defer { try? FileManager.default.removeItem(at: url) }

        let zip = try ZipArchive(url: url)
        guard let entry = zip.entry(named: "stops.txt") else { return XCTFail("expected stops.txt") }
        XCTAssertThrowsError(try zip.data(for: entry)) { error in
            XCTAssertEqual(error as? ZipError, .unsupportedCompression(99))
        }
    }

    func testNonArchiveIsRejected() throws {
        let url = try write(Data(repeating: 0x41, count: 512))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ZipArchive(url: url)) { error in
            XCTAssertEqual(error as? ZipError, .notAZipArchive)
        }
    }

    // MARK: - CRC-32

    func testChecksumMatchesTheStandardVector() {
        // The check value every CRC-32 implementation is measured against.
        XCTAssertEqual(checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(checksum(Data()), 0)
    }

    // MARK: - ZIP64

    func testReadsZip64DirectoryAndExtraField() throws {
        let text = "stop_id,stop_name\nA,Alpha\nB,Beta\n"
        let payload = Data(text.utf8)
        let nameBytes = Array("stops.txt".utf8)
        let sentinel: UInt32 = 0xFFFF_FFFF

        var archive = Data()
        let localOffset = archive.count
        putUInt32(0x0403_4B50, into: &archive)
        putUInt16(45, into: &archive)
        putUInt16(0, into: &archive)
        putUInt16(0, into: &archive)                                    // stored
        putUInt16(0, into: &archive)
        putUInt16(0, into: &archive)
        putUInt32(checksum(payload), into: &archive)
        putUInt32(UInt32(payload.count), into: &archive)
        putUInt32(UInt32(payload.count), into: &archive)
        putUInt16(UInt16(nameBytes.count), into: &archive)
        putUInt16(0, into: &archive)
        archive.append(contentsOf: nameBytes)
        archive.append(payload)

        // Central record with every 32-bit field replaced by the sentinel and the
        // real values carried in a ZIP64 extra field.
        var extra = Data()
        putUInt16(0x0001, into: &extra)
        putUInt16(24, into: &extra)
        putUInt64(UInt64(payload.count), into: &extra)                  // uncompressed
        putUInt64(UInt64(payload.count), into: &extra)                  // compressed
        putUInt64(UInt64(localOffset), into: &extra)                    // local header offset

        var directory = Data()
        putUInt32(0x0201_4B50, into: &directory)
        putUInt16(45, into: &directory)
        putUInt16(45, into: &directory)
        putUInt16(0, into: &directory)
        putUInt16(0, into: &directory)
        putUInt16(0, into: &directory)
        putUInt16(0, into: &directory)
        putUInt32(checksum(payload), into: &directory)
        putUInt32(sentinel, into: &directory)
        putUInt32(sentinel, into: &directory)
        putUInt16(UInt16(nameBytes.count), into: &directory)
        putUInt16(UInt16(extra.count), into: &directory)
        putUInt16(0, into: &directory)
        putUInt16(0, into: &directory)
        putUInt16(0, into: &directory)
        putUInt32(0, into: &directory)
        putUInt32(sentinel, into: &directory)
        directory.append(contentsOf: nameBytes)
        directory.append(extra)

        let directoryOffset = archive.count
        archive.append(directory)

        let zip64RecordOffset = archive.count
        putUInt32(0x0606_4B50, into: &archive)
        putUInt64(44, into: &archive)                                   // size of the rest of this record
        putUInt16(45, into: &archive)
        putUInt16(45, into: &archive)
        putUInt32(0, into: &archive)
        putUInt32(0, into: &archive)
        putUInt64(1, into: &archive)                                    // entries on this disk
        putUInt64(1, into: &archive)                                    // entries in total
        putUInt64(UInt64(directory.count), into: &archive)
        putUInt64(UInt64(directoryOffset), into: &archive)

        putUInt32(0x0706_4B50, into: &archive)                          // ZIP64 locator
        putUInt32(0, into: &archive)
        putUInt64(UInt64(zip64RecordOffset), into: &archive)
        putUInt32(1, into: &archive)

        putUInt32(0x0605_4B50, into: &archive)                          // classic record
        putUInt16(0xFFFF, into: &archive)
        putUInt16(0xFFFF, into: &archive)
        putUInt16(0xFFFF, into: &archive)
        putUInt16(0xFFFF, into: &archive)
        putUInt32(sentinel, into: &archive)
        putUInt32(sentinel, into: &archive)
        putUInt16(0, into: &archive)

        let url = try write(archive)
        defer { try? FileManager.default.removeItem(at: url) }

        let zip = try ZipArchive(url: url)
        XCTAssertEqual(zip.entries.count, 1)
        guard let entry = zip.entry(named: "stops.txt") else { return XCTFail("expected stops.txt") }
        XCTAssertEqual(entry.uncompressedSize, payload.count)
        XCTAssertEqual(entry.localHeaderOffset, localOffset)
        XCTAssertEqual(try zip.data(for: entry), payload)
    }

    // MARK: - Deflate

    #if canImport(Compression)
    func testDeflatedEntryRoundTrips() throws {
        let text = String(repeating: "stop_id,stop_name,stop_lat,stop_lon\n", count: 200)
        let payload = Data(text.utf8)
        guard let deflated = rawDeflate(payload) else {
            return XCTFail("could not produce a deflate stream")
        }
        XCTAssertFalse(deflated.isEmpty)

        let member = Member(
            name: "feed/stops.txt",
            payload: deflated,
            uncompressedSize: payload.count,
            crc32: checksum(payload),
            method: 8,
            localExtra: Data([0x01, 0x02, 0x03, 0x04])
        )
        let url = try write(buildArchive([member]))
        defer { try? FileManager.default.removeItem(at: url) }

        let zip = try ZipArchive(url: url)
        guard let entry = zip.entry(named: "stops.txt") else { return XCTFail("expected stops.txt") }
        XCTAssertEqual(entry.compressionMethod, 8)
        XCTAssertEqual(entry.compressedSize, deflated.count)
        XCTAssertEqual(try zip.data(for: entry), payload)

        let viewedCount = try zip.withBytes(of: entry) { (raw: UnsafeRawBufferPointer) -> Int in
            raw.count
        }
        XCTAssertEqual(viewedCount, payload.count)
    }

    func testDeflatedEntryWithABadChecksumIsRejected() throws {
        let payload = Data(String(repeating: "abcabcabc\n", count: 64).utf8)
        guard let deflated = rawDeflate(payload) else {
            return XCTFail("could not produce a deflate stream")
        }
        let member = Member(
            name: "stops.txt",
            payload: deflated,
            uncompressedSize: payload.count,
            crc32: checksum(payload) &+ 1,
            method: 8,
            localExtra: Data()
        )
        let url = try write(buildArchive([member]))
        defer { try? FileManager.default.removeItem(at: url) }

        let zip = try ZipArchive(url: url)
        guard let entry = zip.entry(named: "stops.txt") else { return XCTFail("expected stops.txt") }
        XCTAssertThrowsError(try zip.data(for: entry)) { error in
            XCTAssertEqual(error as? ZipError, .checksumMismatch(entry: "stops.txt"))
        }
    }

    /// Produces the raw deflate stream a ZIP member holds. `COMPRESSION_ZLIB` is
    /// Apple's name for headerless deflate, which is why nothing here writes a
    /// zlib wrapper.
    private func rawDeflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        var stream = streamPointer.pointee
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
        else { return nil }
        defer { compression_stream_destroy(&stream) }

        let capacity = 32 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        var output = Data()
        let succeeded = input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            stream.src_ptr = base.assumingMemoryBound(to: UInt8.self)
            stream.src_size = raw.count
            stream.dst_ptr = destination
            stream.dst_size = capacity

            while true {
                let status = compression_stream_process(
                    &stream,
                    Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                let produced = capacity - stream.dst_size
                if produced > 0 {
                    output.append(destination, count: produced)
                    stream.dst_ptr = destination
                    stream.dst_size = capacity
                }
                if status == COMPRESSION_STATUS_END { return true }
                guard status == COMPRESSION_STATUS_OK, produced > 0 else { return false }
            }
        }
        return succeeded ? output : nil
    }
    #endif
}
