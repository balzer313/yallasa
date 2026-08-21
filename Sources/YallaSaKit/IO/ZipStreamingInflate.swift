import Foundation
#if canImport(Compression)
import Compression
#endif

/// Inflates a large ZIP entry to a temporary file and memory-maps it.
///
/// ## The problem this solves
///
/// `ZipArchive.withBytes` allocates the entry's full uncompressed size in one
/// buffer. That is fine for a city feed and fatal for a national one: Israel's
/// `stop_times.txt` is **520 MB** uncompressed and `shapes.txt` is 219 MB,
/// against a stated budget of 250 MB peak. Asking iOS for half a gigabyte in a
/// single allocation, on top of the 139 MB mapped archive, is a jetsam kill on
/// most devices — and the app cannot even report it, because the process is
/// gone.
///
/// ## Why a file rather than a chunked reader
///
/// The obvious fix is to stream the inflate straight into `CSVReader`. That
/// means teaching it to handle records that straddle a chunk boundary, quoted
/// fields containing newlines split across two buffers, and a header row that
/// might not arrive in the first read — a genuinely fiddly rewrite of the one
/// component whose correctness the whole import depends on.
///
/// Inflating to a file and mapping it gets the same result with none of that
/// risk. The decompressor never holds more than `chunkSize`, and the mapped
/// file gives `CSVReader` exactly the contiguous buffer it already expects, so
/// not one line of parsing changes. The kernel pages the mapping in and out on
/// demand, so resident memory stays flat no matter how large the entry is: a
/// sequential scan of a 520 MB mapping touches a few megabytes at a time and
/// the pages behind it are evicted as it goes.
///
/// The cost is disk. The entry is written once and deleted immediately after,
/// and the app is already downloading 139 MB and writing a compiled graph, so
/// the transient headroom is in the same order as everything else the install
/// does.
enum ZipStreamingInflate {
    /// Above this, spill to a file rather than the heap.
    ///
    /// 32 MB is comfortably more than any table in a metro feed, so ordinary
    /// installs never touch this path and keep the simpler in-memory route.
    static let spillThreshold = 32 * 1024 * 1024

    /// The decompressor's working window. The peak cost of this whole operation
    /// is one of these plus the page cache the kernel decides to keep.
    static let chunkSize = 4 * 1024 * 1024

    /// Inflates `payload` into a temporary file and calls `body` with a mapping
    /// of it. The file is removed before returning, whether or not `body` throws.
    static func withMappedInflation<R>(
        of payload: UnsafeRawBufferPointer,
        expecting expectedSize: Int,
        entryName: String,
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) throws -> R {
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent(
            "yallasa-inflate-\(UUID().uuidString).bin",
            isDirectory: false
        )

        // Deleted on every path. A failed import must not leave half a gigabyte
        // behind in the container for the next install to trip over.
        defer { try? FileManager.default.removeItem(at: url) }

        try write(payload, expecting: expectedSize, entryName: entryName, to: url)

        let memory = try GraphMemory.map(contentsOf: url)
        // withExtendedLifetime rather than relying on ARC: the only reference to
        // the mapping after `rawBytes` returns is a raw pointer, which ARC does
        // not see, so an optimiser is free to release the mapping while `body`
        // is still reading through it.
        return try withExtendedLifetime(memory) {
            let bytes = try memory.rawBytes(byteOffset: 0, count: memory.count)
            return try body(bytes)
        }
    }

    // MARK: - Writing

    private static func write(
        _ payload: UnsafeRawBufferPointer,
        expecting expectedSize: Int,
        entryName: String,
        to url: URL
    ) throws {
        #if canImport(Compression)
        guard let inputBase = payload.baseAddress, payload.count > 0 else {
            throw ZipError.inflateFailed("\(entryName): the compressed payload is empty")
        }

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ZipError.inflateFailed("\(entryName): could not create a temporary file")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: inputBase.assumingMemoryBound(to: UInt8.self),
            src_size: payload.count,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
        else {
            throw ZipError.inflateFailed("\(entryName): the decoder could not be created")
        }
        defer { compression_stream_destroy(&stream) }

        // compression_stream_init resets the buffer fields, so the real source is
        // installed afterwards rather than relying on the values above.
        stream.src_ptr = inputBase.assumingMemoryBound(to: UInt8.self)
        stream.src_size = payload.count

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        var produced = 0
        var finished = false

        while !finished {
            stream.dst_ptr = buffer
            stream.dst_size = chunkSize

            let status = compression_stream_process(&stream, 0)
            let written = chunkSize - stream.dst_size

            if written > 0 {
                // `Data(bytesNoCopy:)` with `.none` borrows the buffer for the
                // duration of the write instead of copying a chunk each time.
                let chunk = Data(
                    bytesNoCopy: UnsafeMutableRawPointer(buffer),
                    count: written,
                    deallocator: .none
                )
                try handle.write(contentsOf: chunk)
                produced += written
            }

            switch status {
            case COMPRESSION_STATUS_END:
                finished = true
            case COMPRESSION_STATUS_OK:
                // No output and no input consumed means the decoder cannot make
                // progress; without this the loop spins forever on a truncated
                // stream.
                if written == 0 && stream.src_size == 0 {
                    throw ZipError.inflateFailed("\(entryName): the compressed stream ended early")
                }
            default:
                throw ZipError.inflateFailed("\(entryName): the compressed data is damaged")
            }

            if produced > expectedSize {
                throw ZipError.inflateFailed(
                    "\(entryName): inflates to more than the declared \(expectedSize) bytes"
                )
            }
        }

        guard produced == expectedSize else {
            throw ZipError.inflateFailed(
                "\(entryName): inflated to \(produced) bytes but the header declared \(expectedSize)"
            )
        }
        #else
        throw ZipError.unsupportedCompression(8)
        #endif
    }
}
