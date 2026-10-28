import CryptoKit
import Foundation
import HoneycrispCore

/// A clock the remote access tests move by hand, so expiry is tested
/// without sleeping.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        value = start
    }

    var now: Date { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value += seconds }
    }
}

/// Encodes CBOR for test fixtures. Production only ever decodes.
func cborEncode(_ value: CBOR) -> Data {
    func head(_ major: UInt8, _ count: UInt64) -> Data {
        let top = major << 5
        switch count {
        case 0..<24:
            return Data([top | UInt8(count)])
        case 24..<0x100:
            return Data([top | 24, UInt8(count)])
        case 0x100..<0x1_0000:
            return Data([top | 25]) + withUnsafeBytes(of: UInt16(count).bigEndian) { Data($0) }
        case 0x1_0000..<0x1_0000_0000:
            return Data([top | 26]) + withUnsafeBytes(of: UInt32(count).bigEndian) { Data($0) }
        default:
            return Data([top | 27]) + withUnsafeBytes(of: count.bigEndian) { Data($0) }
        }
    }
    switch value {
    case .unsigned(let number):
        return head(0, number)
    case .negative(let number):
        return head(1, UInt64(-1 - number))
    case .bytes(let data):
        return head(2, UInt64(data.count)) + data
    case .text(let text):
        let data = Data(text.utf8)
        return head(3, UInt64(data.count)) + data
    case .array(let items):
        return items.reduce(head(4, UInt64(items.count))) { $0 + cborEncode($1) }
    case .map(let pairs):
        return pairs.reduce(head(5, UInt64(pairs.count))) {
            $0 + cborEncode($1.key) + cborEncode($1.value)
        }
    case .bool(let flag):
        return Data([flag ? 0xF5 : 0xF4])
    case .null:
        return Data([0xF6])
    case .float(let number):
        return Data([0xFB]) + withUnsafeBytes(of: number.bitPattern.bigEndian) { Data($0) }
    }
}

/// A passkey in software: a P-256 key that answers registration and
/// assertion ceremonies the way a browser and an authenticator would.
struct SoftwareAuthenticator {
    let key = P256.Signing.PrivateKey()
    let credentialID = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

    var credentialIDString: String { Base64URL.encode(credentialID) }

    struct Registration {
        var clientDataJSON: Data
        var attestationObject: Data
    }

    struct Assertion {
        var clientDataJSON: Data
        var authenticatorData: Data
        var signature: Data
    }

    static let userPresent: UInt8 = 0x01
    static let userVerified: UInt8 = 0x04
    static let attestedData: UInt8 = 0x40

    func clientData(type: String, challenge: Data, origin: String) -> Data {
        let object: [String: Any] = [
            "type": type,
            "challenge": Base64URL.encode(challenge),
            "origin": origin,
            "crossOrigin": false,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func coseKey(algorithm: Int64 = -7) -> CBOR {
        let point = key.publicKey.x963Representation
        return .map([
            .unsigned(1): .unsigned(2),
            .unsigned(3): .negative(algorithm),
            .negative(-1): .unsigned(1),
            .negative(-2): .bytes(point.subdata(in: 1..<33)),
            .negative(-3): .bytes(point.subdata(in: 33..<65)),
        ])
    }

    func register(
        challenge: Data,
        origin: String,
        relyingPartyID: String,
        type: String = "webauthn.create",
        flags: UInt8 = userPresent | userVerified | attestedData,
        cose: CBOR? = nil
    ) -> Registration {
        var authData = Data(SHA256.hash(data: Data(relyingPartyID.utf8)))
        authData.append(flags)
        authData.append(contentsOf: [0, 0, 0, 0])
        if flags & Self.attestedData != 0 {
            authData.append(Data(repeating: 0, count: 16))
            authData.append(contentsOf: [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xFF)])
            authData.append(credentialID)
            authData.append(cborEncode(cose ?? coseKey()))
        }
        let attestation = CBOR.map([
            .text("fmt"): .text("none"),
            .text("attStmt"): .map([:]),
            .text("authData"): .bytes(authData),
        ])
        return Registration(
            clientDataJSON: clientData(type: type, challenge: challenge, origin: origin),
            attestationObject: cborEncode(attestation)
        )
    }

    func assert(
        challenge: Data,
        origin: String,
        relyingPartyID: String,
        signCount: UInt32 = 0,
        type: String = "webauthn.get",
        flags: UInt8 = userPresent | userVerified
    ) -> Assertion {
        var authData = Data(SHA256.hash(data: Data(relyingPartyID.utf8)))
        authData.append(flags)
        authData.append(contentsOf: withUnsafeBytes(of: signCount.bigEndian) { Array($0) })
        let clientDataJSON = clientData(type: type, challenge: challenge, origin: origin)
        var signed = authData
        signed.append(Data(SHA256.hash(data: clientDataJSON)))
        let signature = try! key.signature(for: signed).derRepresentation
        return Assertion(
            clientDataJSON: clientDataJSON, authenticatorData: authData, signature: signature)
    }
}

// MARK: - Requests

func getRequest(_ target: String, headers: [String: String] = [:]) -> HTTPRequest {
    HTTPRequest(method: "GET", target: target, headers: headers, body: Data())
}

func jsonRequest(_ target: String, _ object: Any, headers: [String: String] = [:]) -> HTTPRequest {
    var all = headers
    all["content-type"] = "application/json"
    return HTTPRequest(
        method: "POST", target: target, headers: all,
        body: try! JSONSerialization.data(withJSONObject: object))
}

func formRequest(_ target: String, _ fields: [(String, String)]) -> HTTPRequest {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let body = fields.map { name, value in
        "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }.joined(separator: "&")
    return HTTPRequest(
        method: "POST", target: target,
        headers: ["content-type": "application/x-www-form-urlencoded"],
        body: Data(body.utf8))
}

func queryString(_ fields: [(String, String)]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return fields.map { name, value in
        "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }.joined(separator: "&")
}

func jsonObject(_ response: HTTPResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
}

func text(_ response: HTTPResponse) -> String {
    String(decoding: response.body, as: UTF8.self)
}

/// The JSON a Honeycrisp page hands its script, from the hc-data block.
func pageData(_ response: HTTPResponse) -> [String: Any] {
    let html = text(response)
    guard let open = html.range(of: #"<script type="application/json" id="hc-data">"#),
        let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex)
    else { return [:] }
    let json = Data(html[open.upperBound..<close.lowerBound].utf8)
    return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
}

/// Query parameters of a redirect URL.
func redirectParameters(_ url: String) -> [String: String] {
    guard let components = URLComponents(string: url) else { return [:] }
    var out: [String: String] = [:]
    for item in components.queryItems ?? [] {
        out[item.name] = item.value
    }
    return out
}

func pkceChallenge(_ verifier: String) -> String {
    Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
}
