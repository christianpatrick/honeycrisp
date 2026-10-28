import Foundation
import Testing
import HoneycrispCore

@Suite("CBOR decoding")
struct CBORTests {
    private func decode(_ hex: String) throws -> CBOR {
        try CBOR.decode(bytes(hex))
    }

    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    @Test("unsigned integers decode at every length width")
    func unsigned() throws {
        #expect(try decode("00") == .unsigned(0))
        #expect(try decode("17") == .unsigned(23))
        #expect(try decode("1818") == .unsigned(24))
        #expect(try decode("1903e8") == .unsigned(1000))
        #expect(try decode("1a000f4240") == .unsigned(1_000_000))
        #expect(try decode("1b000000e8d4a51000") == .unsigned(1_000_000_000_000))
    }

    @Test("negative integers carry their real value")
    func negative() throws {
        #expect(try decode("20") == .negative(-1))
        #expect(try decode("26") == .negative(-7))
        #expect(try decode("3863") == .negative(-100))
        #expect(try decode("3903e7") == .negative(-1000))
    }

    @Test("a negative integer below Int64 throws")
    func negativeOverflow() {
        #expect(throws: CBORError.self) { try decode("3bffffffffffffffff") }
    }

    @Test("byte and text strings decode")
    func strings() throws {
        #expect(try decode("40") == .bytes(Data()))
        #expect(try decode("4401020304") == .bytes(Data([1, 2, 3, 4])))
        #expect(try decode("60") == .text(""))
        #expect(try decode("6449455446") == .text("IETF"))
    }

    @Test("arrays, maps, and simple values decode")
    func containers() throws {
        #expect(try decode("83010203") == .array([.unsigned(1), .unsigned(2), .unsigned(3)]))
        #expect(
            try decode("a201020304") == .map([.unsigned(1): .unsigned(2), .unsigned(3): .unsigned(4)]))
        let nested = try decode("a26161016162820203")
        #expect(nested[text: "a"] == .unsigned(1))
        #expect(nested[text: "b"] == .array([.unsigned(2), .unsigned(3)]))
        #expect(try decode("f4") == .bool(false))
        #expect(try decode("f5") == .bool(true))
        #expect(try decode("f6") == .null)
    }

    @Test("integer map keys look up by value")
    func integerKeys() throws {
        let map = try decode("a2012620f5")
        #expect(map[int: 1] == .negative(-7))
        #expect(map[int: -1] == .bool(true))
        #expect(map[int: 3] == nil)
    }

    @Test("a prefix decode reports how many bytes it used")
    func prefix() throws {
        let (value, length) = try CBOR.decodePrefix(bytes("8201026161"))
        #expect(value == .array([.unsigned(1), .unsigned(2)]))
        #expect(length == 3)
    }

    @Test("a whole decode refuses trailing bytes")
    func trailing() {
        #expect(throws: CBORError.self) { try decode("0102") }
    }

    @Test("truncated input throws instead of reading past the end")
    func truncated() {
        #expect(throws: CBORError.self) { try decode("1903") }
        #expect(throws: CBORError.self) { try decode("5affffffff00") }
        #expect(throws: CBORError.self) { try decode("83 01 02".replacingOccurrences(of: " ", with: "")) }
        #expect(throws: CBORError.self) { try CBOR.decode(Data()) }
    }

    @Test("indefinite lengths are refused")
    func indefinite() {
        #expect(throws: CBORError.self) { try decode("5f42010243030405ff") }
        #expect(throws: CBORError.self) { try decode("9f0102ff") }
    }

    @Test("nesting stops at sixteen levels")
    func depth() throws {
        #expect(throws: Never.self) { try decode(String(repeating: "81", count: 15) + "00") }
        #expect(throws: CBORError.self) { try decode(String(repeating: "81", count: 17) + "00") }
    }

    @Test("duplicate map keys are refused")
    func duplicateKeys() {
        #expect(throws: CBORError.self) { try decode("a201020103") }
    }
}
