import Foundation

/// One parsed HTTP/1.1 request. Header names are lowercased.
public struct HTTPRequest: Sendable, Equatable {
    public let method: String
    /// The raw request target, path and query together.
    public let target: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, target: String, headers: [String: String], body: Data) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }

    public var path: String {
        String(target.prefix { $0 != "?" })
    }

    /// The decoded query, or nil when a parameter repeats, which OAuth
    /// treats as an invalid request (RFC 6749 section 3.1).
    public var query: [String: String]? {
        guard let mark = target.firstIndex(of: "?") else { return [:] }
        return HTTPForm.decode(Data(target[target.index(after: mark)...].utf8))
    }
}

/// One HTTP response. The socket layer adds Content-Length and
/// Connection: close, and defaults Content-Type to JSON.
public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// A JSON body from a plain object, for the OAuth endpoints.
    public static func json(_ status: Int, _ object: [String: Any], headers: [String: String] = [:])
        -> HTTPResponse
    {
        var all = headers
        all["Content-Type"] = "application/json"
        let body =
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return HTTPResponse(status: status, headers: all, body: body)
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Content Too Large"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

/// application/x-www-form-urlencoded, used by OAuth for both query strings
/// and token request bodies.
public enum HTTPForm {
    /// The fields, or nil when a name repeats or an escape is malformed.
    public static func decode(_ data: Data) -> [String: String]? {
        var fields: [String: String] = [:]
        let text = String(decoding: data, as: UTF8.self)
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = unescape(parts[0]),
                let value = unescape(parts.count > 1 ? parts[1] : "")
            else { return nil }
            guard fields[name] == nil else { return nil }
            fields[name] = value
        }
        return fields
    }

    private static func unescape(_ text: Substring) -> String? {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}

/// Decodes a chunked transfer-encoded body (RFC 9112 section 7.1) as it
/// arrives. Each byte is looked at once, so a slow body costs work in
/// proportion to its size however it is split across receives.
public struct ChunkedDecoder {
    public struct Malformed: Error {}

    private enum State: Equatable {
        case size
        case data(remaining: Int)
        case dataEnd(seen: Int)
        case trailer
        case done
    }

    public private(set) var body = Data()
    private var state = State.size
    /// The size or trailer line read so far.
    private var line: [UInt8] = []

    public init() {}

    /// Feeds newly received bytes. True once the last chunk and the
    /// trailer section have arrived; bytes after that are ignored.
    public mutating func feed(_ data: Data) throws -> Bool {
        var index = data.startIndex
        while index < data.endIndex {
            switch state {
            case .done:
                return true
            case .data(let remaining):
                let take = min(remaining, data.endIndex - index)
                body.append(data[index..<(index + take)])
                index += take
                state = take == remaining ? .dataEnd(seen: 0) : .data(remaining: remaining - take)
            case .dataEnd(let seen):
                // Exactly CRLF closes every chunk's data.
                guard data[index] == (seen == 0 ? 0x0D : 0x0A) else { throw Malformed() }
                index += 1
                state = seen == 0 ? .dataEnd(seen: 1) : .size
            case .size, .trailer:
                line.append(data[index])
                index += 1
                // A size line has no business being this long.
                guard line.count <= 1024 else { throw Malformed() }
                guard line.count >= 2, line[line.count - 2] == 0x0D, line[line.count - 1] == 0x0A
                else { continue }
                let text = String(decoding: line.dropLast(2), as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if state == .trailer {
                    if text.isEmpty { state = .done }
                    continue
                }
                let digits = text.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
                // Hex digits only: Int(_:radix:) would also take a sign, and a
                // negative size would break the arithmetic above.
                guard !digits.isEmpty, digits.count <= 8, digits.allSatisfy(\.isHexDigit),
                    let size = Int(digits, radix: 16)
                else { throw Malformed() }
                state = size == 0 ? .trailer : .data(remaining: size)
            }
        }
        return state == .done
    }
}

/// A whole chunked body at once, for callers that already hold it.
public enum ChunkedBody {
    /// The body once the terminating chunk has arrived, nil while more is
    /// still to come, and a throw when the framing is broken.
    public static func decode(_ data: Data) throws -> Data? {
        var decoder = ChunkedDecoder()
        return try decoder.feed(data) ? decoder.body : nil
    }
}

/// The local port answers this Mac only. A tunnel forwards to loopback too,
/// so the source address can't tell them apart; the Host header and the
/// forwarding headers an HTTP proxy adds can. Refusing them means an HTTP
/// tunnel (Funnel's default, cloudflared, ngrok http) pointed at the local
/// port by mistake fails closed, and a web page can't reach it through DNS
/// rebinding (GH-16). A raw TCP forwarder passes the caller's own headers,
/// so nothing here can catch one.
public enum LocalRequestGuard {
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    public static func allows(headers: [String: String]) -> Bool {
        if headers["forwarded"] != nil || headers["x-forwarded-for"] != nil { return false }
        guard let host = headers["host"] else { return true }
        return loopbackHosts.contains(hostName(host).lowercased())
    }

    /// The host without its port, and without brackets for IPv6.
    private static func hostName(_ header: String) -> String {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return trimmed }
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        guard let colon = trimmed.lastIndex(of: ":") else { return trimmed }
        return String(trimmed[..<colon])
    }
}
