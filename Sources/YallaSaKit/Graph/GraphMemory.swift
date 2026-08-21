import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Owns the bytes of a compiled graph and hands out typed, bounds-checked views
/// into them.
///
/// Backed by `mmap` when opened from a file. That is the whole reason the graph
/// is a flat binary file: a 250 MB metro feed costs ~0 resident bytes until the
/// router touches a column, the kernel evicts cold pages under memory pressure
/// instead of the app being killed, and startup is a syscall rather than a parse.
///
/// The typed buffers this vends are valid only while the `GraphMemory` is alive.
/// `TransitGraph` is the only thing that holds them, and it holds the memory too,
/// so that invariant is enforced by construction rather than by convention.
public final class GraphMemory: @unchecked Sendable {
    public let count: Int
    private let base: UnsafeRawPointer
    private let release: (@Sendable () -> Void)?

    private init(base: UnsafeRawPointer, count: Int, release: (@Sendable () -> Void)?) {
        self.base = base
        self.count = count
        self.release = release
    }

    deinit { release?() }

    /// Memory-maps a graph file read-only.
    public static func map(contentsOf url: URL) throws -> GraphMemory {
        #if canImport(Darwin)
        let path = url.withUnsafeFileSystemRepresentation { pointer -> String in
            guard let pointer else { return url.path }
            return String(cString: pointer)
        }
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw GraphError.ioFailure("Could not open \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw GraphError.ioFailure("Could not size \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        let byteCount = Int(status.st_size)
        guard byteCount > 0 else { throw GraphError.fileTooSmall }

        guard let pointer = mmap(nil, byteCount, PROT_READ, MAP_FILE | MAP_PRIVATE, descriptor, 0),
              pointer != MAP_FAILED
        else {
            throw GraphError.ioFailure("Could not map \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }

        // The router jumps between columns rather than streaming, so tell the VM
        // not to bother with aggressive readahead.
        madvise(pointer, byteCount, MADV_RANDOM)

        let raw = UnsafeRawPointer(pointer)
        return GraphMemory(base: raw, count: byteCount, release: {
            munmap(UnsafeMutableRawPointer(mutating: raw), byteCount)
        })
        #else
        // Non-Darwin fallback: read the whole file. Used only by tooling.
        let data = try Data(contentsOf: url)
        return makeCopy(of: data)
        #endif
    }

    /// Wraps an in-memory blob. Used by tests and by the importer's verification
    /// pass, which reads back what it just wrote before the file is published.
    public static func copying(_ data: Data) -> GraphMemory {
        makeCopy(of: data)
    }

    private static func makeCopy(of data: Data) -> GraphMemory {
        let count = data.count
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: max(count, 1),
            alignment: GraphFormat.sectionAlignment
        )
        data.withUnsafeBytes { source in
            if let address = source.baseAddress, count > 0 {
                buffer.copyMemory(from: address, byteCount: count)
            }
        }
        return GraphMemory(base: UnsafeRawPointer(buffer), count: count, release: { buffer.deallocate() })
    }

    /// Hints that the pages backing `range` are about to be read, so the kernel
    /// can fault them in ahead of the router rather than one at a time. Called
    /// before a query on the stop-time columns.
    public func prefetch(byteOffset: Int, byteCount: Int) {
        #if canImport(Darwin)
        guard byteOffset >= 0, byteCount > 0, byteOffset + byteCount <= count else { return }
        let pageSize = Int(getpagesize())
        let start = (byteOffset / pageSize) * pageSize
        let length = min(count - start, byteCount + (byteOffset - start))
        madvise(UnsafeMutableRawPointer(mutating: base.advanced(by: start)), length, MADV_WILLNEED)
        #endif
    }

    /// A typed view over `count` elements starting at `byteOffset`.
    ///
    /// Validates bounds and alignment; a corrupt or truncated file therefore
    /// produces a thrown error at open time rather than a wild read during a
    /// query. `section` is carried only to make the error message useful.
    public func buffer<T>(
        byteOffset: Int,
        count elementCount: Int,
        as type: T.Type,
        section: GraphSection
    ) throws -> UnsafeBufferPointer<T> {
        guard elementCount >= 0, byteOffset >= 0 else {
            throw GraphError.malformedSection(section, reason: "negative offset or count")
        }
        let byteCount = elementCount * MemoryLayout<T>.stride
        guard byteOffset &+ byteCount <= count else {
            throw GraphError.sectionOutOfBounds(section)
        }
        guard byteOffset % MemoryLayout<T>.alignment == 0 else {
            throw GraphError.unalignedSection(section)
        }
        guard elementCount > 0 else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        let start = base.advanced(by: byteOffset).assumingMemoryBound(to: T.self)
        return UnsafeBufferPointer(start: start, count: elementCount)
    }

    /// Raw bytes of a region, for the metadata JSON and the string blob.
    public func rawBytes(byteOffset: Int, count byteCount: Int) throws -> UnsafeRawBufferPointer {
        guard byteOffset >= 0, byteCount >= 0, byteOffset &+ byteCount <= count else {
            throw GraphError.fileTooSmall
        }
        return UnsafeRawBufferPointer(start: base.advanced(by: byteOffset), count: byteCount)
    }

    /// Reads a scalar from an arbitrary offset without alignment assumptions.
    /// Only used for the header, which is read once.
    public func loadUnaligned<T>(byteOffset: Int, as type: T.Type) throws -> T {
        guard byteOffset >= 0, byteOffset &+ MemoryLayout<T>.size <= count else {
            throw GraphError.fileTooSmall
        }
        return base.loadUnaligned(fromByteOffset: byteOffset, as: T.self)
    }
}
