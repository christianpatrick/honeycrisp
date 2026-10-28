import Foundation

/// The public https address a user's tunnel serves, and everything OAuth
/// and passkeys derive from it (GH-16).
public struct RemoteOrigin: Sendable, Equatable {
    /// Scheme, host, and a non-default port, like https://mac.tailnet.ts.net.
    public let origin: String
    public let host: String

    /// Accepts a bare https origin, or the connector URL ending in /mcp,
    /// and refuses anything else so the issuer and resource are exact.
    public init?(publicURL: String) {
        let trimmed = publicURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(), !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else { return nil }
        guard ["", "/", "/mcp", "/mcp/"].contains(components.path) else { return nil }
        self.host = host
        if let port = components.port, port != 443 {
            origin = "https://\(host):\(port)"
        } else {
            origin = "https://\(host)"
        }
    }

    public var issuer: String { origin }
    public var resource: String { origin + "/mcp" }
    public var relyingPartyID: String { host }
    public var resourceMetadataURL: String { origin + "/.well-known/oauth-protected-resource" }
}

/// Unpadded base64url (RFC 4648 section 5), the encoding WebAuthn and
/// PKCE use.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !base64.contains("=") else { return nil }
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

/// Random secrets for tokens, codes, and challenges.
enum RemoteSecret {
    static func bytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    static func token(prefix: String = "") -> String {
        prefix + Base64URL.encode(bytes(32))
    }
}
