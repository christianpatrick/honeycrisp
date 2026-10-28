import CryptoKit
import Foundation

/// A passkey the owner registered for remote sign-in. Nothing here is
/// secret: the private key never leaves the owner's devices.
public struct PasskeyCredential: Codable, Sendable, Equatable, Identifiable {
    /// The credential ID, base64url.
    public let id: String
    /// The P-256 public key in X9.63 form.
    public let publicKey: Data
    public var signCount: UInt32
    /// The host the passkey belongs to. A new public URL needs a new one.
    public let relyingPartyID: String
    public let createdAt: Date

    public init(
        id: String, publicKey: Data, signCount: UInt32, relyingPartyID: String, createdAt: Date
    ) {
        self.id = id
        self.publicKey = publicKey
        self.signCount = signCount
        self.relyingPartyID = relyingPartyID
        self.createdAt = createdAt
    }
}

public enum WebAuthnError: Error, Equatable {
    case malformed
    case wrongType
    case challengeMismatch
    case originMismatch
    case relyingPartyMismatch
    case userNotPresent
    case userNotVerified
    case missingCredentialData
    case unsupportedKey
    case unknownCredential
    case badSignature
    case signCountRegressed
}

/// Server-side passkey verification for the two ceremonies remote access
/// uses: registering the owner's passkey and signing in with it. ES256 on
/// P-256 only, user verification always required, and no attestation
/// trust, since the setup link already proves the owner is at the Mac.
public enum WebAuthn {
    private static let userPresent: UInt8 = 0x01
    private static let userVerified: UInt8 = 0x04
    private static let attestedCredentialData: UInt8 = 0x40

    public static func verifyRegistration(
        clientDataJSON: Data,
        attestationObject: Data,
        challenge: Data,
        origin: String,
        relyingPartyID: String,
        now: Date
    ) throws -> PasskeyCredential {
        try checkClientData(
            clientDataJSON, type: "webauthn.create", challenge: challenge, origin: origin)
        guard let attestation = try? CBOR.decode(attestationObject),
            let authData = attestation[text: "authData"]?.bytesValue
        else { throw WebAuthnError.malformed }
        let flags = try checkAuthenticatorData(authData, relyingPartyID: relyingPartyID)
        guard flags & attestedCredentialData != 0 else { throw WebAuthnError.missingCredentialData }

        // rpIdHash (32), flags (1), signCount (4), then the attested
        // credential data: aaguid (16), ID length (2), ID, COSE key.
        let bytes = [UInt8](authData)
        let signCount = bigEndian(bytes[33..<37])
        guard bytes.count >= 55 else { throw WebAuthnError.malformed }
        let idLength = Int(bytes[53]) << 8 | Int(bytes[54])
        guard idLength > 0, idLength <= 1023, bytes.count >= 55 + idLength else {
            throw WebAuthnError.malformed
        }
        let credentialID = Data(bytes[55..<(55 + idLength)])
        guard let cose = try? CBOR.decodePrefix(Data(bytes[(55 + idLength)...])) else {
            throw WebAuthnError.malformed
        }
        let publicKey = try p256Key(from: cose.value)

        return PasskeyCredential(
            id: Base64URL.encode(credentialID),
            publicKey: publicKey.x963Representation,
            signCount: signCount,
            relyingPartyID: relyingPartyID,
            createdAt: now
        )
    }

    /// Verifies a sign-in and returns the authenticator's new sign count.
    public static func verifyAssertion(
        credentialID: String,
        clientDataJSON: Data,
        authenticatorData: Data,
        signature: Data,
        challenge: Data,
        origin: String,
        relyingPartyID: String,
        passkeys: [PasskeyCredential]
    ) throws -> UInt32 {
        guard
            let passkey = passkeys.first(where: {
                $0.id == credentialID && $0.relyingPartyID == relyingPartyID
            })
        else { throw WebAuthnError.unknownCredential }
        try checkClientData(clientDataJSON, type: "webauthn.get", challenge: challenge, origin: origin)
        _ = try checkAuthenticatorData(authenticatorData, relyingPartyID: relyingPartyID)

        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: passkey.publicKey),
            let ecdsa = try? P256.Signing.ECDSASignature(derRepresentation: signature)
        else { throw WebAuthnError.badSignature }
        var signed = authenticatorData
        signed.append(Data(SHA256.hash(data: clientDataJSON)))
        guard publicKey.isValidSignature(ecdsa, for: signed) else {
            throw WebAuthnError.badSignature
        }

        // Synced passkeys report zero forever. A counter that is in use has
        // to move forward, or the authenticator may have been cloned.
        let count = bigEndian([UInt8](authenticatorData)[33..<37])
        if count != 0 || passkey.signCount != 0, count <= passkey.signCount {
            throw WebAuthnError.signCountRegressed
        }
        return count
    }

    // MARK: - Pieces

    private struct ClientData: Decodable {
        let type: String
        let challenge: String
        let origin: String
        let crossOrigin: Bool?
    }

    private static func checkClientData(
        _ json: Data, type: String, challenge: Data, origin: String
    ) throws {
        guard let clientData = try? JSONDecoder().decode(ClientData.self, from: json) else {
            throw WebAuthnError.malformed
        }
        guard clientData.type == type else { throw WebAuthnError.wrongType }
        guard Base64URL.decode(clientData.challenge) == challenge else {
            throw WebAuthnError.challengeMismatch
        }
        guard clientData.origin == origin, clientData.crossOrigin != true else {
            throw WebAuthnError.originMismatch
        }
    }

    /// Checks the relying party hash and the presence and verification
    /// flags, and returns the flags.
    private static func checkAuthenticatorData(_ data: Data, relyingPartyID: String) throws -> UInt8 {
        let bytes = [UInt8](data)
        guard bytes.count >= 37 else { throw WebAuthnError.malformed }
        guard Data(bytes[0..<32]) == Data(SHA256.hash(data: Data(relyingPartyID.utf8))) else {
            throw WebAuthnError.relyingPartyMismatch
        }
        let flags = bytes[32]
        guard flags & userPresent != 0 else { throw WebAuthnError.userNotPresent }
        guard flags & userVerified != 0 else { throw WebAuthnError.userNotVerified }
        return flags
    }

    /// An EC2 key (kty 2) for ES256 (alg -7) on P-256 (crv 1).
    private static func p256Key(from cose: CBOR) throws -> P256.Signing.PublicKey {
        guard cose[int: 1]?.intValue == 2, cose[int: 3]?.intValue == -7,
            cose[int: -1]?.intValue == 1,
            let x = cose[int: -2]?.bytesValue, x.count == 32,
            let y = cose[int: -3]?.bytesValue, y.count == 32,
            let key = try? P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)
        else { throw WebAuthnError.unsupportedKey }
        return key
    }

    private static func bigEndian(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}
