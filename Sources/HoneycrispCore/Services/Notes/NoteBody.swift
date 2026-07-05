import Compression
import Foundation

/// Extracts the plain text of a note from ZICNOTEDATA.ZDATA. The blob is
/// a gzip or zlib compressed protobuf whose text is the string at field
/// path 2 (document), 3 (note), 2 (note text). Anything unrecognized
/// reads as nil and the caller degrades to a sentence, never a failure.
enum NoteBody {
    static func text(from blob: Data) -> String? {
        guard
            let inflated = inflate(blob),
            let document = firstLengthDelimited(field: 2, in: inflated),
            let note = firstLengthDelimited(field: 3, in: document),
            let textBytes = firstLengthDelimited(field: 2, in: note),
            let text = String(data: textBytes, encoding: .utf8)
        else { return nil }
        return text.replacingOccurrences(of: "\u{FFFC}", with: "[attachment]")
    }

    // MARK: - Containers

    /// Detects the container by its magic bytes: a gzip member (1F 8B)
    /// with its header fields skipped, a zlib stream with its 2 byte
    /// header skipped, or bare deflate. The Compression framework's
    /// COMPRESSION_ZLIB decoder speaks raw deflate and stops at the
    /// stream end, so both containers' trailers are ignored naturally.
    static func inflate(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        if bytes.count > 10, bytes[0] == 0x1F, bytes[1] == 0x8B {
            guard let start = gzipPayloadStart(bytes) else { return nil }
            return rawInflate(Data(bytes[start...]))
        }
        if bytes.count > 2, bytes[0] & 0x0F == 8,
            (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0
        {
            let start = bytes[1] & 0x20 == 0 ? 2 : 6
            guard bytes.count > start else { return nil }
            return rawInflate(Data(bytes[start...]))
        }
        return rawInflate(data)
    }

    /// The offset where the deflate stream starts, after the 10 byte
    /// header and any optional fields its flags declare.
    private static func gzipPayloadStart(_ bytes: [UInt8]) -> Int? {
        guard bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { return nil }
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        if flags & 0x08 != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x10 != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index < bytes.count else { return nil }
        return index
    }

    private static func rawInflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard
            compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
        else { return nil }
        defer { compression_stream_destroy(&stream) }

        let chunk = 64 * 1024
        var output = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = base
            stream.src_size = data.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = chunk
                let status = compression_stream_process(
                    &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return output.isEmpty ? nil : output
                case COMPRESSION_STATUS_OK:
                    // No progress with nothing left to read means a
                    // truncated stream, not a decodable one.
                    if produced == 0, stream.src_size == 0 { return nil }
                default:
                    return nil
                }
            }
        }
    }

    // MARK: - Protobuf

    /// Walks one protobuf message and returns the first length-delimited
    /// payload of the wanted field, skipping everything else.
    private static func firstLengthDelimited(field: Int, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            guard let key = varint(bytes, &index) else { return nil }
            let fieldNumber = Int(key >> 3)
            switch key & 0x7 {
            case 0:
                guard varint(bytes, &index) != nil else { return nil }
            case 1:
                index += 8
            case 2:
                guard let rawLength = varint(bytes, &index), rawLength <= UInt64(bytes.count),
                    Int(rawLength) <= bytes.count - index
                else { return nil }
                let length = Int(rawLength)
                if fieldNumber == field {
                    return Data(bytes[index..<index + length])
                }
                index += length
            case 5:
                index += 4
            default:
                return nil
            }
        }
        return nil
    }

    private static func varint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}
