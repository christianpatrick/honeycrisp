import Foundation

/// One CBOR value (RFC 8949), as much of it as passkey ceremonies need:
/// the attestation object and the COSE public key inside it.
public indirect enum CBOR: Sendable, Hashable {
    case unsigned(UInt64)
    /// The real value, so COSE's alg -7 is .negative(-7).
    case negative(Int64)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([CBOR: CBOR])
    case bool(Bool)
    case null
    case float(Double)

    public subscript(text key: String) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs[.text(key)]
    }

    public subscript(int key: Int64) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs[key < 0 ? .negative(key) : .unsigned(UInt64(key))]
    }

    public var bytesValue: Data? {
        if case .bytes(let data) = self { return data }
        return nil
    }

    public var textValue: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .unsigned(let value): return value <= UInt64(Int64.max) ? Int64(value) : nil
        case .negative(let value): return value
        default: return nil
        }
    }
}

public enum CBORError: Error, Equatable {
    case truncated
    case unsupported
    case tooDeep
    case invalid
    case trailingBytes
}

extension CBOR {
    static let maxDepth = 16

    /// Decodes exactly one value that fills the whole input.
    public static func decode(_ data: Data) throws -> CBOR {
        let (value, length) = try decodePrefix(data)
        guard length == data.count else { throw CBORError.trailingBytes }
        return value
    }

    /// Decodes one value from the front of the input and says how many
    /// bytes it took, for the COSE key that sits mid-buffer in
    /// authenticator data.
    public static func decodePrefix(_ data: Data) throws -> (value: CBOR, length: Int) {
        var reader = Reader(bytes: [UInt8](data))
        let value = try reader.value(depth: 0)
        return (value, reader.index)
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        mutating func byte() throws -> UInt8 {
            guard index < bytes.count else { throw CBORError.truncated }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func take(_ count: UInt64) throws -> ArraySlice<UInt8> {
            guard count <= UInt64(bytes.count - index) else { throw CBORError.truncated }
            let end = index + Int(count)
            defer { index = end }
            return bytes[index..<end]
        }

        mutating func argument(_ info: UInt8) throws -> UInt64 {
            switch info {
            case 0..<24:
                return UInt64(info)
            case 24, 25, 26, 27:
                let width = 1 << Int(info - 24)
                return try take(UInt64(width)).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            default:
                // 28 through 30 are reserved, and 31 means an indefinite
                // length, which passkey data never uses.
                throw CBORError.unsupported
            }
        }

        mutating func value(depth: Int) throws -> CBOR {
            let initial = try byte()
            let major = initial >> 5
            let info = initial & 0x1F

            if major == 7 {
                switch info {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22: return .null
                case 26:
                    let bits = try take(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    return .float(Double(Float(bitPattern: bits)))
                case 27:
                    let bits = try take(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                    return .float(Double(bitPattern: bits))
                default:
                    throw CBORError.unsupported
                }
            }

            let count = try argument(info)
            switch major {
            case 0:
                return .unsigned(count)
            case 1:
                guard count <= UInt64(Int64.max) else { throw CBORError.unsupported }
                return .negative(-1 - Int64(count))
            case 2:
                return .bytes(Data(try take(count)))
            case 3:
                guard let text = String(bytes: try take(count), encoding: .utf8) else {
                    throw CBORError.invalid
                }
                return .text(text)
            case 4:
                guard depth < CBOR.maxDepth else { throw CBORError.tooDeep }
                // Every item takes at least a byte, which bounds the
                // allocation by the input size.
                guard count <= UInt64(bytes.count - index) else { throw CBORError.truncated }
                var items: [CBOR] = []
                items.reserveCapacity(Int(count))
                for _ in 0..<count {
                    items.append(try value(depth: depth + 1))
                }
                return .array(items)
            case 5:
                guard depth < CBOR.maxDepth else { throw CBORError.tooDeep }
                guard count <= UInt64(bytes.count - index) / 2 else { throw CBORError.truncated }
                var pairs: [CBOR: CBOR] = [:]
                for _ in 0..<count {
                    let key = try value(depth: depth + 1)
                    let item = try value(depth: depth + 1)
                    guard pairs.updateValue(item, forKey: key) == nil else {
                        throw CBORError.invalid
                    }
                }
                return .map(pairs)
            default:
                // Major type 6, tags, never appears in passkey data.
                throw CBORError.unsupported
            }
        }
    }
}
