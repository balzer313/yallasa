import XCTest
@testable import YallaSaKit

/// Covers the path a national feed takes.
///
/// The threshold is 32 MB, so these tests build entries that actually cross it
/// rather than testing the mechanism at a size that would never trigger it. That
/// makes them slower than the rest of the suite and worth it: this code only
/// ever runs on the largest, least recoverable import the app performs, and a
/// bug here is a crash the user cannot report.
final class ZipStreamingInflateTests: XCTestCase {

    /// Builds CSV text large enough to force the spill path.
    private func makeLargeCSV(rows: Int) -> [UInt8] {
        var text = "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
        text.reserveCapacity(rows * 46 + 64)
        for i in 0..<rows {
            let h = (i % 24), m = (i % 60), s = (i % 60)
            text += "trip\(i % 5000),"
            text += String(format: "%02d:%02d:%02d,", h, m, s)
            text += String(format: "%02d:%02d:%02d,", h, m, s)
            text += "stop\(i % 900),\(i % 60)\n"
        }
        return Array(text.utf8)
    }

    func testInflatesAnEntryLargerThanTheSpillThreshold() throws {
        // ~40 MB of CSV: over the 32 MB threshold, so this takes the mapped path.
        let payload = makeLargeCSV(rows: 900_000)
        XCTAssertGreaterThan(
            payload.count, ZipStreamingInflate.spillThreshold,
            "fixture must exceed the threshold or this tests the wrong branch"
        )

        var builder = ZipBuilder()
        builder.addDeflated(name: "stop_times.txt", bytes: payload)
        let url = try builder.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZipArchive(url: url)
        let entry = try XCTUnwrap(archive.entry(named: "stop_times.txt"))
        XCTAssertEqual(entry.uncompressedSize, payload.count)

        // Read it back through the public API, which routes to the spill path.
        let (count, firstByte, lastByte) = try archive.withBytes(of: entry) { raw in
            (raw.count, raw.first, raw.last)
        }
        XCTAssertEqual(count, payload.count)
        XCTAssertEqual(firstByte, payload.first)
        XCTAssertEqual(lastByte, payload.last)
    }

    /// The whole point of the exercise: the bytes have to survive intact, or the
    /// importer parses garbage and blames the agency's data.
    func testMappedContentMatchesTheOriginalExactly() throws {
        let payload = makeLargeCSV(rows: 900_000)
        var builder = ZipBuilder()
        builder.addDeflated(name: "big.txt", bytes: payload)
        let url = try builder.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZipArchive(url: url)
        let entry = try XCTUnwrap(archive.entry(named: "big.txt"))

        let identical = try archive.withBytes(of: entry) { raw -> Bool in
            guard raw.count == payload.count else { return false }
            return payload.withUnsafeBytes { original in
                memcmp(raw.baseAddress!, original.baseAddress!, raw.count) == 0
            }
        }
        XCTAssertTrue(identical, "the mapped inflation differs from the source bytes")
    }

    /// A mapped entry must be parseable by the unchanged CSVReader — that
    /// equivalence is the reason this design avoids rewriting the parser.
    func testCSVReaderParsesAMappedEntry() throws {
        let rows = 900_000
        let payload = makeLargeCSV(rows: rows)
        var builder = ZipBuilder()
        builder.addDeflated(name: "stop_times.txt", bytes: payload)
        let url = try builder.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZipArchive(url: url)
        let entry = try XCTUnwrap(archive.entry(named: "stop_times.txt"))

        let counted = try archive.withBytes(of: entry) { raw -> Int in
            var reader = try CSVReader(bytes: raw)
            XCTAssertNotNil(reader.columnIndex("trip_id"))
            XCTAssertNotNil(reader.columnIndex("stop_sequence"))
            var seen = 0
            while reader.next() != nil { seen += 1 }
            return seen
        }
        XCTAssertEqual(counted, rows, "every data row must survive the round trip")
    }

    /// Entries below the threshold must keep using the in-memory path — the
    /// spill costs a file write and a mapping, and a metro feed needs neither.
    func testSmallEntriesStillUseTheInMemoryPath() throws {
        let payload = Array("a,b\n1,2\n3,4\n".utf8)
        var builder = ZipBuilder()
        builder.addDeflated(name: "small.txt", bytes: payload)
        let url = try builder.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZipArchive(url: url)
        let entry = try XCTUnwrap(archive.entry(named: "small.txt"))
        XCTAssertLessThan(entry.uncompressedSize, ZipStreamingInflate.spillThreshold)

        let text = try archive.withBytes(of: entry) { raw in
            String(decoding: raw, as: UTF8.self)
        }
        XCTAssertEqual(text, "a,b\n1,2\n3,4\n")
    }

    /// The temporary file must not outlive the call, or a national import leaves
    /// half a gigabyte in the container.
    func testTemporaryFileIsRemovedAfterwards() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        func spillFiles() throws -> [String] {
            try FileManager.default
                .contentsOfDirectory(atPath: temporaryDirectory.path)
                .filter { $0.hasPrefix("yallasa-inflate-") }
        }

        let before = try spillFiles()

        let payload = makeLargeCSV(rows: 900_000)
        var builder = ZipBuilder()
        builder.addDeflated(name: "big.txt", bytes: payload)
        let url = try builder.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZipArchive(url: url)
        let entry = try XCTUnwrap(archive.entry(named: "big.txt"))
        _ = try archive.withBytes(of: entry) { $0.count }

        XCTAssertEqual(try spillFiles().count, before.count, "a spill file was left behind")
    }
}
