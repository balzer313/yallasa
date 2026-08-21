import Foundation
import XCTest
@testable import YallaSaKit

final class CSVReaderTests: XCTestCase {

    // MARK: - Helpers

    private func withReader(
        bytes: [UInt8],
        _ body: (inout CSVReader) throws -> Void
    ) throws {
        try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            var reader = try CSVReader(bytes: raw)
            try body(&reader)
        }
    }

    private func withReader(
        _ text: String,
        _ body: (inout CSVReader) throws -> Void
    ) throws {
        try withReader(bytes: Array(text.utf8), body)
    }

    // MARK: - Structure

    func testParsesHeaderAndRows() throws {
        try withReader("stop_id,stop_name,stop_lat\nA,Alpha,1.5\nB,Beta,-2.25\n") { reader in
            XCTAssertEqual(reader.header, ["stop_id", "stop_name", "stop_lat"])
            XCTAssertEqual(reader.columnIndex("stop_id"), 0)
            XCTAssertEqual(reader.columnIndex("stop_lat"), 2)
            XCTAssertNil(reader.columnIndex("shape_id"))

            guard let first = reader.next() else { return XCTFail("expected a first row") }
            XCTAssertEqual(first.fieldCount, 3)
            XCTAssertEqual(first.string(0), "A")
            XCTAssertEqual(first.string(1), "Alpha")
            XCTAssertEqual(first.double(2), 1.5)

            guard let second = reader.next() else { return XCTFail("expected a second row") }
            XCTAssertEqual(second.string(0), "B")
            XCTAssertEqual(second.double(2), -2.25)

            XCTAssertNil(reader.next())
            XCTAssertEqual(reader.rowsRead, 2)
            XCTAssertEqual(reader.approximateProgress, 1.0, accuracy: 0.0001)
        }
    }

    func testQuotedFieldsCarryCommasNewlinesAndDoubledQuotes() throws {
        let text = """
        name,description
        "Main St, North","He said ""hello""
        then left"
        plain,value

        """
        try withReader(text) { reader in
            XCTAssertEqual(reader.header, ["name", "description"])

            guard let first = reader.next() else { return XCTFail("expected a first row") }
            XCTAssertEqual(first.fieldCount, 2)
            XCTAssertEqual(first.string(0), "Main St, North")
            XCTAssertEqual(first.string(1), "He said \"hello\"\nthen left")

            guard let second = reader.next() else { return XCTFail("expected a second row") }
            XCTAssertEqual(second.string(0), "plain")
            XCTAssertEqual(second.string(1), "value")

            XCTAssertNil(reader.next())
        }
    }

    func testEmptyQuotedFieldIsEmpty() throws {
        try withReader("a,b,c\n\"\",x,\"\"\n") { reader in
            guard let row = reader.next() else { return XCTFail("expected a row") }
            XCTAssertEqual(row.fieldCount, 3)
            XCTAssertTrue(row.isEmpty(0))
            XCTAssertEqual(row.string(1), "x")
            XCTAssertTrue(row.isEmpty(2))
        }
    }

    func testAcceptsCarriageReturnLineFeed() throws {
        try withReader("a,b\r\n1,2\r\n3,4\r\n") { reader in
            XCTAssertEqual(reader.header, ["a", "b"])
            guard let first = reader.next() else { return XCTFail("expected a first row") }
            XCTAssertEqual(first.string(0), "1")
            XCTAssertEqual(first.string(1), "2")
            guard let second = reader.next() else { return XCTFail("expected a second row") }
            XCTAssertEqual(second.string(1), "4")
            XCTAssertNil(reader.next())
        }
    }

    func testStripsByteOrderMark() throws {
        var bytes: [UInt8] = [0xEF, 0xBB, 0xBF]
        bytes.append(contentsOf: Array("stop_id,stop_name\nA,Alpha\n".utf8))
        try withReader(bytes: bytes) { reader in
            XCTAssertEqual(reader.header, ["stop_id", "stop_name"])
            XCTAssertEqual(reader.columnIndex("stop_id"), 0)
            guard let row = reader.next() else { return XCTFail("expected a row") }
            XCTAssertEqual(row.string(0), "A")
        }
    }

    func testShortRowsReportEmptyForMissingColumns() throws {
        try withReader("a,b,c\n1\n") { reader in
            guard let row = reader.next() else { return XCTFail("expected a row") }
            XCTAssertEqual(row.fieldCount, 1)
            XCTAssertEqual(row.string(0), "1")
            XCTAssertTrue(row.isEmpty(1))
            XCTAssertEqual(row.string(2), "")
            XCTAssertNil(row.int(2))
            XCTAssertEqual(row.bytes(9).count, 0)
        }
    }

    func testLongRowsKeepTheirExtraFields() throws {
        try withReader("a,b\n1,2,3,4\n") { reader in
            guard let row = reader.next() else { return XCTFail("expected a row") }
            XCTAssertEqual(row.fieldCount, 4)
            XCTAssertEqual(row.string(3), "4")
        }
    }

    func testTrailingCommaProducesAFinalEmptyField() throws {
        try withReader("a,b,c\n1,2,") { reader in
            guard let row = reader.next() else { return XCTFail("expected a row") }
            XCTAssertEqual(row.fieldCount, 3)
            XCTAssertTrue(row.isEmpty(2))
        }
    }

    func testToleratesMissingFinalNewline() throws {
        try withReader("a,b\n1,2") { reader in
            guard let row = reader.next() else { return XCTFail("expected a row") }
            XCTAssertEqual(row.string(0), "1")
            XCTAssertEqual(row.string(1), "2")
            XCTAssertNil(reader.next())
            XCTAssertEqual(reader.rowsRead, 1)
        }
    }

    func testBlankLinesAreSkipped() throws {
        try withReader("a,b\n\n1,2\n\n\n3,4\n\n") { reader in
            guard let first = reader.next() else { return XCTFail("expected a first row") }
            XCTAssertEqual(first.string(0), "1")
            guard let second = reader.next() else { return XCTFail("expected a second row") }
            XCTAssertEqual(second.string(0), "3")
            XCTAssertNil(reader.next())
            XCTAssertEqual(reader.rowsRead, 2)
        }
    }

    func testHeaderOnlyFileHasNoRows() throws {
        try withReader("a,b,c\n") { reader in
            XCTAssertEqual(reader.header.count, 3)
            XCTAssertNil(reader.next())
            XCTAssertEqual(reader.rowsRead, 0)
        }
    }

    // `withUnsafeBytes` is `rethrows`, and the throwing autoclosure inside makes
    // the trailing closure infer as throwing — so the call needs `try` and the
    // test needs to be `throws`.
    func testEmptyFileThrows() throws {
        let bytes: [UInt8] = []
        try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            XCTAssertThrowsError(try CSVReader(bytes: raw)) { error in
                XCTAssertEqual(error as? CSVError, .emptyFile)
            }
        }
    }

    func testHeaderOfOnlyBlankNamesThrows() throws {
        let bytes = Array(",,\n1,2,3\n".utf8)
        try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            XCTAssertThrowsError(try CSVReader(bytes: raw)) { error in
                XCTAssertEqual(error as? CSVError, .malformedHeader)
            }
        }
    }

    // MARK: - Header matching

    func testHeaderLookupIsCaseInsensitiveAndTrimmed() throws {
        try withReader(" Stop_ID , \"stop_name\" ,STOP_LAT\nA,Alpha,1\n") { reader in
            XCTAssertEqual(reader.header, ["Stop_ID", "stop_name", "STOP_LAT"])
            XCTAssertEqual(reader.columnIndex("stop_id"), 0)
            XCTAssertEqual(reader.columnIndex("  STOP_NAME  "), 1)
            XCTAssertEqual(reader.columnIndex("stop_lat"), 2)
        }
    }

    // MARK: - Value parsing

    func testIntegerParsing() throws {
        // The blank value is written as an empty quoted field because a wholly
        // blank *line* is skipped rather than reported as a row.
        try withReader("v\n42\n-17\n+8\n\"\"\n 91 \n12x\n-\n9223372036854775808\n") { reader in
            let expected: [Int?] = [42, -17, 8, nil, 91, nil, nil, nil]
            for value in expected {
                guard let row = reader.next() else { return XCTFail("expected a row") }
                XCTAssertEqual(row.int(0), value)
            }
        }
    }

    func testDoubleParsing() throws {
        try withReader("v\n1.5\n-33.865143\n0\n.25\n1e3\n\"\"\nabc\n") { reader in
            guard let a = reader.next() else { return XCTFail("expected a row") }
            XCTAssertEqual(a.double(0) ?? .nan, 1.5, accuracy: 1e-12)
            guard let b = reader.next() else { return XCTFail("expected a row") }
            XCTAssertEqual(b.double(0) ?? .nan, -33.865143, accuracy: 1e-9)
            guard let c = reader.next() else { return XCTFail("expected a row") }
            XCTAssertEqual(c.double(0) ?? .nan, 0, accuracy: 1e-12)
            guard let d = reader.next() else { return XCTFail("expected a row") }
            XCTAssertEqual(d.double(0) ?? .nan, 0.25, accuracy: 1e-12)
            guard let e = reader.next() else { return XCTFail("expected a row") }
            XCTAssertEqual(e.double(0) ?? .nan, 1000, accuracy: 1e-9)
            guard let f = reader.next() else { return XCTFail("expected a row") }
            XCTAssertNil(f.double(0))
            guard let g = reader.next() else { return XCTFail("expected a row") }
            XCTAssertNil(g.double(0))
        }
    }

    func testUnescapedFieldsPointIntoTheSourceAndSurviveWideRows() throws {
        // A row whose escaped field is longer than the initial scratch buffer,
        // proving the growth path keeps earlier fields addressable.
        let long = String(repeating: "a\"\"b", count: 200)
        let text = "one,two,three\n\"\(long)\",\"x\"\"y\",tail\n"
        try withReader(text) { reader in
            guard let row = reader.next() else { return XCTFail("expected a row") }
            XCTAssertEqual(row.string(0), String(repeating: "a\"b", count: 200))
            XCTAssertEqual(row.string(1), "x\"y")
            XCTAssertEqual(row.string(2), "tail")
        }
    }

    func testBytesMatchStrings() throws {
        try withReader("a\nhello\n") { reader in
            guard let row = reader.next() else { return XCTFail("expected a row") }
            let field = row.bytes(0)
            XCTAssertEqual(field.count, 5)
            XCTAssertEqual(Array(field), Array("hello".utf8))
        }
    }
}
