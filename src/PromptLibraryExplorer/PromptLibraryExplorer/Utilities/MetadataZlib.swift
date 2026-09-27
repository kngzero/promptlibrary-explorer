import Compression
import Foundation

/// zlib helpers for embedded metadata (PNG zTXt / iTXt payloads).
///
/// Apple's `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951) with no zlib header or
/// Adler-32 trailer, while PNG text chunks carry full zlib streams (RFC 1950).
/// These helpers strip the 2-byte header before decoding and stream the output
/// into a growing buffer so large, highly compressible payloads (e.g. ComfyUI
/// workflow JSON) aren't truncated.
enum MetadataZlib {
    /// Maximum inflated size accepted, to guard against decompression bombs.
    static let maxInflatedSize = 256 * 1024 * 1024

    /// Inflates a zlib (RFC 1950) stream. Falls back to treating the input as raw DEFLATE
    /// when no valid zlib header is present.
    static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        var payload = data[...]
        if data.count >= 2 {
            let cmf = data[data.startIndex]
            let flg = data[data.startIndex + 1]
            let hasZlibHeader = (cmf & 0x0F) == 8 && ((UInt16(cmf) << 8) | UInt16(flg)) % 31 == 0
            if hasZlibHeader {
                // A preset dictionary (FDICT) can't be honored by raw DEFLATE decoding.
                guard flg & 0x20 == 0 else { return nil }
                payload = data.dropFirst(2)
            }
        }

        return inflateRawDeflate(Data(payload))
    }

    private static func inflateRawDeflate(_ data: Data) -> Data? {
        guard let output = process(data, operation: COMPRESSION_STREAM_DECODE), !output.isEmpty else {
            return nil
        }
        return output
    }

    private static func process(_ input: Data, operation: compression_stream_operation) -> Data? {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }

        guard compression_stream_init(streamPointer, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(streamPointer) }

        let bufferSize = 64 * 1024
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        var output = Data()

        let succeeded: Bool = input.withUnsafeBytes { (sourceBuffer: UnsafeRawBufferPointer) -> Bool in
            guard let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }

            streamPointer.pointee.src_ptr = sourceBase
            streamPointer.pointee.src_size = sourceBuffer.count

            while true {
                streamPointer.pointee.dst_ptr = destinationBuffer
                streamPointer.pointee.dst_size = bufferSize

                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - streamPointer.pointee.dst_size
                if produced > 0 {
                    output.append(destinationBuffer, count: produced)
                    if output.count > maxInflatedSize { return false }
                }

                switch status {
                case COMPRESSION_STATUS_OK:
                    // No progress with no input left means the stream is truncated.
                    if produced == 0 && streamPointer.pointee.src_size == 0 { return false }
                    continue
                case COMPRESSION_STATUS_END:
                    return true
                default:
                    return false
                }
            }
        }

        return succeeded ? output : nil
    }
}
