import Foundation

/// Streams a compiled graph out to disk in the layout `TransitGraph` expects.
///
/// Sections are appended in one forward pass so the importer never has to hold
/// the whole graph in memory at once; the section table is patched into the
/// reserved header region at the end. Nothing is fsynced here — the feed
/// installer writes to a temporary file and renames it into place, so a process
/// death mid-write leaves an orphan temp file rather than a corrupt graph.
public final class TransitGraphWriter {
    private let handle: FileHandle
    private let url: URL
    private var descriptors: [GraphSectionDescriptor] = []
    private var cursor: Int = GraphFormat.headerReservedBytes
    private var finished = false

    public init(url: URL) throws {
        self.url = url
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        guard manager.createFile(atPath: url.path, contents: nil) else {
            throw GraphError.ioFailure("Could not create \(url.lastPathComponent)")
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw GraphError.ioFailure("Could not open \(url.lastPathComponent) for writing")
        }
        self.handle = handle
        // Reserve the header. It is rewritten by `finish`.
        try handle.write(contentsOf: Data(count: GraphFormat.headerReservedBytes))
    }

    /// Appends a column. `T` must be a trivial, fixed-layout type — every column
    /// in the format is an integer.
    public func append<T>(_ section: GraphSection, _ values: [T]) throws {
        try values.withUnsafeBufferPointer { try append(section, buffer: $0) }
    }

    public func append<T>(_ section: GraphSection, buffer: UnsafeBufferPointer<T>) throws {
        precondition(!finished, "TransitGraphWriter used after finish()")
        try alignCursor()
        let byteCount = buffer.count * MemoryLayout<T>.stride
        if byteCount > 0, let base = buffer.baseAddress {
            let data = Data(bytes: base, count: byteCount)
            try handle.write(contentsOf: data)
        }
        descriptors.append(
            GraphSectionDescriptor(
                section: section,
                elementSize: UInt32(MemoryLayout<T>.stride),
                elementCount: UInt64(buffer.count),
                byteOffset: UInt64(cursor)
            )
        )
        cursor += byteCount
    }

    /// Appends a byte section (the string blob, the metadata JSON).
    public func appendBytes(_ section: GraphSection, _ data: Data) throws {
        precondition(!finished, "TransitGraphWriter used after finish()")
        try alignCursor()
        if !data.isEmpty {
            try handle.write(contentsOf: data)
        }
        descriptors.append(
            GraphSectionDescriptor(
                section: section,
                elementSize: 1,
                elementCount: UInt64(data.count),
                byteOffset: UInt64(cursor)
            )
        )
        cursor += data.count
    }

    /// Writes the metadata section and the header, then closes the file.
    public func finish(metadata: GraphMetadata) throws {
        precondition(!finished, "TransitGraphWriter.finish() called twice")

        var metadata = metadata
        metadata.formatVersion = GraphFormat.version
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let metadataData = try encoder.encode(metadata)
        try appendBytes(.metadata, metadataData)

        finished = true

        let maximumDescriptors = (GraphFormat.headerReservedBytes - 16) / GraphSectionDescriptor.encodedSize
        guard descriptors.count <= maximumDescriptors else {
            throw GraphError.malformedSection(.metadata, reason: "too many sections for the reserved header")
        }

        var header = Data(capacity: GraphFormat.headerReservedBytes)
        header.appendLittleEndian(GraphFormat.magic)
        header.appendLittleEndian(GraphFormat.version)
        header.appendLittleEndian(UInt32(descriptors.count))
        header.appendLittleEndian(UInt32(0))
        for descriptor in descriptors {
            header.appendLittleEndian(descriptor.section.rawValue)
            header.appendLittleEndian(descriptor.elementSize)
            header.appendLittleEndian(descriptor.elementCount)
            header.appendLittleEndian(descriptor.byteOffset)
        }
        header.append(Data(count: GraphFormat.headerReservedBytes - header.count))

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
        try handle.close()
    }

    /// Abandons the file. Safe to call after a failure; `finish` was never reached
    /// so the file has no valid header and could never be opened anyway.
    public func discard() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    private func alignCursor() throws {
        let remainder = cursor % GraphFormat.sectionAlignment
        guard remainder != 0 else { return }
        let padding = GraphFormat.sectionAlignment - remainder
        try handle.write(contentsOf: Data(count: padding))
        cursor += padding
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        // `Swift.` qualified because an unqualified `withUnsafeBytes` inside a
        // `Data` extension resolves to `Data.withUnsafeBytes(_:)` — the instance
        // method on the buffer being written to, not the global that views a
        // scalar's bytes.
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

/// Interns strings into the graph's single NUL-terminated UTF-8 blob and hands
/// back the offsets the columns store.
///
/// Deduplication is not an optimisation detail here — feeds repeat the same
/// handful of headsigns across hundreds of thousands of trips, and interning
/// turns tens of megabytes of duplicated text into a few hundred kilobytes.
public struct StringTableBuilder {
    /// Byte 0 is a lone terminator, so offset `0` always reads back as the empty
    /// string. Columns use `0` to mean "no value", which needs no special case.
    private var blob: [UInt8] = [0]
    private var offsets: [String: UInt32] = [:]

    public init() {
        offsets.reserveCapacity(4096)
    }

    public var byteCount: Int { blob.count }
    public var uniqueCount: Int { offsets.count }

    @discardableResult
    public mutating func intern(_ value: String?) -> UInt32 {
        guard let value, !value.isEmpty else { return 0 }
        if let existing = offsets[value] { return existing }
        let offset = UInt32(blob.count)
        blob.append(contentsOf: value.utf8)
        blob.append(0)
        offsets[value] = offset
        return offset
    }

    /// Interns raw UTF-8 straight from the CSV parser, skipping the round trip
    /// through `String` for values that are already in the table.
    @discardableResult
    public mutating func intern(utf8 bytes: some Collection<UInt8>) -> UInt32 {
        guard !bytes.isEmpty else { return 0 }
        return intern(String(decoding: bytes, as: UTF8.self))
    }

    public func finish() -> Data {
        Data(blob)
    }
}
