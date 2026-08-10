import Foundation

/// A forward-only RFC 4180 reader over a raw byte buffer.
///
/// Fields are returned as pointers into the source (or into a per-row scratch
/// buffer when unescaping was required) and are valid only until the next call
/// to `next()`. `stop_times.txt` in a metro feed has millions of rows; a reader
/// that allocated a `[String]` per row would spend the entire import budget in
/// the allocator.
///
/// The reader is a value type but its row storage is a shared reference, because
/// the row it vends has to point at memory that survives the return. Copying a
/// reader therefore shares that storage: a reader is meant to be created, drained
/// once, and dropped.
public struct CSVReader {
    private let source: UnsafePointer<UInt8>
    private let count: Int
    private var cursor: Int
    private let storage: CSVFieldStorage

    /// Column names as they appear in the file, trimmed and unquoted but with
    /// their original case, because they are shown in diagnostics.
    public private(set) var header: [String]
    /// Lowercased names to column positions. Feeds ship `Stop_ID`, `stop_id `
    /// and `"stop_id"` in roughly equal measure.
    private var headerLookup: [String: Int]

    public private(set) var rowsRead: Int

    public init(bytes: UnsafeRawBufferPointer) throws {
        guard let rawBase = bytes.baseAddress, bytes.count > 0 else { throw CSVError.emptyFile }

        var start = 0
        // A BOM on stop_times.txt would otherwise become part of the first
        // header name and silently break every column lookup.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            start = 3
        }

        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        self.source = base
        self.count = bytes.count
        self.cursor = start
        self.storage = CSVFieldStorage(source: base)
        self.header = []
        self.headerLookup = [:]
        self.rowsRead = 0

        guard let headerRow = next() else { throw CSVError.emptyFile }

        var names: [String] = []
        var lookup: [String: Int] = [:]
        names.reserveCapacity(headerRow.fieldCount)
        lookup.reserveCapacity(headerRow.fieldCount)
        for column in 0..<headerRow.fieldCount {
            let name = CSVReader.canonicalName(headerRow.string(column))
            names.append(name)
            let key = name.lowercased()
            if !key.isEmpty, lookup[key] == nil {
                lookup[key] = column
            }
        }
        guard !lookup.isEmpty else { throw CSVError.malformedHeader }

        self.header = names
        self.headerLookup = lookup
        // The header is not a data row, and callers use `rowsRead` for progress
        // reporting where an off-by-one is visible.
        self.rowsRead = 0
    }

    public func columnIndex(_ name: String) -> Int? {
        headerLookup[CSVReader.canonicalName(name).lowercased()]
    }

    /// Advances to the next record. The returned row is invalidated by the next
    /// call to `next()` — copy anything that has to outlive it.
    public mutating func next() -> CSVRow? {
        // Blank lines are skipped rather than reported as a one-empty-field row.
        // Feeds end with anything from no newline at all to three of them, and a
        // phantom row at the end of every table is a bug magnet.
        while cursor < count, source[cursor] == CSVReader.carriageReturn || source[cursor] == CSVReader.lineFeed {
            cursor += 1
        }
        guard cursor < count else { return nil }

        storage.reset()
        var index = cursor
        var rowFinished = false

        while !rowFinished {
            if source[index] == CSVReader.quote {
                index += 1
                let contentStart = index
                var containsEscapes = false
                while index < count {
                    if source[index] == CSVReader.quote {
                        if index + 1 < count, source[index + 1] == CSVReader.quote {
                            containsEscapes = true
                            index += 2
                            continue
                        }
                        break
                    }
                    index += 1
                }
                let contentEnd = index
                if index < count { index += 1 }  // the closing quote
                if containsEscapes {
                    storage.addUnescapedField(from: contentStart, to: contentEnd)
                } else {
                    storage.addSourceField(from: contentStart, to: contentEnd)
                }
                // Anything between the closing quote and the delimiter is not
                // legal CSV; dropping it beats derailing the rest of the file.
                while index < count, !CSVReader.isFieldTerminator(source[index]) {
                    index += 1
                }
            } else {
                let fieldStart = index
                while index < count, !CSVReader.isFieldTerminator(source[index]) {
                    index += 1
                }
                storage.addSourceField(from: fieldStart, to: index)
            }

            if index >= count {
                rowFinished = true
            } else if source[index] == CSVReader.comma {
                index += 1
                if index >= count {
                    // A record ending in a comma has one more, empty, field.
                    storage.addSourceField(from: index, to: index)
                    rowFinished = true
                }
            } else {
                if source[index] == CSVReader.carriageReturn {
                    index += 1
                    if index < count, source[index] == CSVReader.lineFeed { index += 1 }
                } else {
                    index += 1
                }
                rowFinished = true
            }
        }

        cursor = index
        rowsRead += 1
        return CSVRow(storage: storage)
    }

    /// Fraction of the buffer consumed. Progress is reported by bytes rather
    /// than by rows because the row count is unknown until the file is drained.
    public var approximateProgress: Double {
        guard count > 0 else { return 1 }
        return min(1, max(0, Double(cursor) / Double(count)))
    }

    // MARK: - Helpers

    private static let comma: UInt8 = 0x2C
    private static let quote: UInt8 = 0x22
    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A

    private static func isFieldTerminator(_ byte: UInt8) -> Bool {
        byte == comma || byte == lineFeed || byte == carriageReturn
    }

    /// Trims surrounding whitespace and one layer of quotes. Quotes normally
    /// come off during parsing, so this only catches names that were quoted
    /// twice or supplied by a caller copying a name out of the file.
    private static func canonicalName(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            trimmed = String(trimmed.dropFirst().dropLast())
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}

/// One record. Backed by the reader's storage, so it is only valid until the
/// reader advances.
public struct CSVRow {
    private let storage: CSVFieldStorage

    internal init(storage: CSVFieldStorage) {
        self.storage = storage
    }

    public var fieldCount: Int { storage.fieldCount }

    /// The raw bytes of a column, empty when the column is absent. Short rows
    /// are common in hand-edited feeds and are not worth an error.
    public func bytes(_ column: Int) -> UnsafeBufferPointer<UInt8> {
        storage.field(column)
    }

    public func string(_ column: Int) -> String {
        let field = storage.field(column)
        guard let base = field.baseAddress, field.count > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: base, count: field.count), as: UTF8.self)
    }

    public func isEmpty(_ column: Int) -> Bool {
        storage.field(column).count == 0
    }

    /// Parses an integer straight from the bytes. Building a `String` first
    /// would allocate several million times during an import of `stop_times`.
    public func int(_ column: Int) -> Int? {
        let field = storage.field(column)
        guard field.count > 0 else { return nil }

        var index = 0
        while index < field.count, CSVRow.isSpace(field[index]) { index += 1 }

        var negative = false
        if index < field.count, field[index] == CSVRow.minus {
            negative = true
            index += 1
        } else if index < field.count, field[index] == CSVRow.plus {
            index += 1
        }

        var value = 0
        var digits = 0
        while index < field.count {
            let byte = field[index]
            guard byte >= CSVRow.zero, byte <= CSVRow.nine else { break }
            let (scaled, scaleOverflowed) = value.multipliedReportingOverflow(by: 10)
            guard !scaleOverflowed else { return nil }
            let (sum, sumOverflowed) = scaled.addingReportingOverflow(Int(byte - CSVRow.zero))
            guard !sumOverflowed else { return nil }
            value = sum
            digits += 1
            index += 1
        }
        guard digits > 0 else { return nil }

        while index < field.count, CSVRow.isSpace(field[index]) { index += 1 }
        guard index == field.count else { return nil }

        return negative ? -value : value
    }

    /// Parses a decimal straight from the bytes, falling back to `strtod` for
    /// exponents and other rarities. The fast path covers every coordinate and
    /// distance a feed actually contains.
    public func double(_ column: Int) -> Double? {
        let field = storage.field(column)
        guard field.count > 0 else { return nil }

        var index = 0
        while index < field.count, CSVRow.isSpace(field[index]) { index += 1 }

        var negative = false
        if index < field.count, field[index] == CSVRow.minus {
            negative = true
            index += 1
        } else if index < field.count, field[index] == CSVRow.plus {
            index += 1
        }

        var value = 0.0
        var digits = 0
        while index < field.count, field[index] >= CSVRow.zero, field[index] <= CSVRow.nine {
            value = value * 10 + Double(field[index] - CSVRow.zero)
            digits += 1
            index += 1
        }

        if index < field.count, field[index] == CSVRow.period {
            index += 1
            var scale = 1.0
            while index < field.count, field[index] >= CSVRow.zero, field[index] <= CSVRow.nine {
                value = value * 10 + Double(field[index] - CSVRow.zero)
                scale *= 10
                digits += 1
                index += 1
            }
            value /= scale
        }

        while index < field.count, CSVRow.isSpace(field[index]) { index += 1 }

        if digits > 0, index == field.count {
            return negative ? -value : value
        }
        return CSVRow.parseWithStandardLibrary(field)
    }

    private static func parseWithStandardLibrary(_ field: UnsafeBufferPointer<UInt8>) -> Double? {
        var buffer = [CChar](repeating: 0, count: field.count + 1)
        for index in 0..<field.count {
            buffer[index] = CChar(bitPattern: field[index])
        }
        return buffer.withUnsafeBufferPointer { pointer -> Double? in
            guard let start = pointer.baseAddress else { return nil }
            var end: UnsafeMutablePointer<CChar>? = nil
            let value = strtod(start, &end)
            guard let end else { return nil }
            guard UnsafeRawPointer(end) != UnsafeRawPointer(start) else { return nil }
            return value
        }
    }

    private static let minus: UInt8 = 0x2D
    private static let plus: UInt8 = 0x2B
    private static let zero: UInt8 = 0x30
    private static let nine: UInt8 = 0x39
    private static let period: UInt8 = 0x2E

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D
    }
}

/// Where a row's fields live between calls to `next()`.
///
/// A reference type on purpose: `CSVRow` has to hand out pointers that outlive
/// the call that produced them, and a value type's storage moves. Fields are
/// recorded as *offsets* rather than pointers so that growing the scratch buffer
/// mid-row cannot invalidate the fields already recorded in it.
internal final class CSVFieldStorage {
    private struct Span {
        var offset: Int
        var count: Int
        var inScratch: Bool
    }

    private let source: UnsafePointer<UInt8>
    private var spans: [Span] = []
    private var scratch: UnsafeMutablePointer<UInt8>
    private var scratchCapacity: Int
    private var scratchCount: Int

    init(source: UnsafePointer<UInt8>) {
        self.source = source
        self.scratchCapacity = 256
        self.scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        self.scratchCount = 0
        spans.reserveCapacity(32)
    }

    deinit {
        scratch.deallocate()
    }

    var fieldCount: Int { spans.count }

    /// Keeps both buffers' capacity, which is what makes a row cost no
    /// allocations after the first few.
    func reset() {
        spans.removeAll(keepingCapacity: true)
        scratchCount = 0
    }

    func addSourceField(from start: Int, to end: Int) {
        spans.append(Span(offset: start, count: max(0, end - start), inScratch: false))
    }

    /// Copies a quoted field into scratch, collapsing `""` to `"`. Only reached
    /// for fields that actually contain a doubled quote — everything else points
    /// straight at the mapped file.
    func addUnescapedField(from start: Int, to end: Int) {
        let maximum = max(0, end - start)
        ensureScratchCapacity(scratchCount + maximum)

        let fieldOffset = scratchCount
        var written = scratchCount
        var index = start
        while index < end {
            let byte = source[index]
            scratch[written] = byte
            written += 1
            if byte == 0x22, index + 1 < end, source[index + 1] == 0x22 {
                index += 2
            } else {
                index += 1
            }
        }
        scratchCount = written
        spans.append(Span(offset: fieldOffset, count: written - fieldOffset, inScratch: true))
    }

    func field(_ column: Int) -> UnsafeBufferPointer<UInt8> {
        guard column >= 0, column < spans.count else {
            return UnsafeBufferPointer<UInt8>(start: nil, count: 0)
        }
        let span = spans[column]
        guard span.count > 0 else {
            return UnsafeBufferPointer<UInt8>(start: nil, count: 0)
        }
        if span.inScratch {
            return UnsafeBufferPointer<UInt8>(
                start: UnsafePointer(scratch.advanced(by: span.offset)),
                count: span.count
            )
        }
        return UnsafeBufferPointer<UInt8>(start: source.advanced(by: span.offset), count: span.count)
    }

    private func ensureScratchCapacity(_ needed: Int) {
        guard needed > scratchCapacity else { return }
        var capacity = scratchCapacity
        while capacity < needed {
            capacity *= 2
        }
        let grown = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        if scratchCount > 0 {
            grown.initialize(from: scratch, count: scratchCount)
        }
        scratch.deallocate()
        scratch = grown
        scratchCapacity = capacity
    }
}

public enum CSVError: Error, Equatable {
    case emptyFile
    case malformedHeader
}
