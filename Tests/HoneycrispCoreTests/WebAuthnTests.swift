import Foundation
import Testing
import HoneycrispCore

@Suite("Passkey verification")
struct WebAuthnTests {
    private let origin = "https://mac.example.ts.net"
    private let rpID = "mac.example.ts.net"
    private let challenge = Data((0..<32).map { UInt8($0) })
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func register(
        _ authenticator: SoftwareAuthenticator, _ registration: SoftwareAuthenticator.Registration
    ) throws -> PasskeyCredential {
        try WebAuthn.verifyRegistration(
            clientDataJSON: registration.clientDataJSON,
            attestationObject: registration.attestationObject,
            challenge: challenge, origin: origin, relyingPartyID: rpID, now: now)
    }

    private func saved(_ authenticator: SoftwareAuthenticator, signCount: UInt32 = 0) throws
        -> PasskeyCredential
    {
        var credential = try register(
            authenticator,
            authenticator.register(challenge: challenge, origin: origin, relyingPartyID: rpID))
        credential.signCount = signCount
        return credential
    }

    private func verify(
        _ assertion: SoftwareAuthenticator.Assertion, id: String, passkeys: [PasskeyCredential]
    ) throws -> UInt32 {
        try WebAuthn.verifyAssertion(
            credentialID: id,
            clientDataJSON: assertion.clientDataJSON,
            authenticatorData: assertion.authenticatorData,
            signature: assertion.signature,
            challenge: challenge, origin: origin, relyingPartyID: rpID, passkeys: passkeys)
    }

    // MARK: - Registration

    @Test("a good registration yields the credential")
    func registration() throws {
        let authenticator = SoftwareAuthenticator()
        let credential = try saved(authenticator)
        #expect(credential.id == authenticator.credentialIDString)
        #expect(credential.publicKey == authenticator.key.publicKey.x963Representation)
        #expect(credential.signCount == 0)
        #expect(credential.relyingPartyID == rpID)
        #expect(credential.createdAt == now)
    }

    @Test("registration refuses the wrong type, challenge, origin, or relying party")
    func registrationMismatches() {
        let authenticator = SoftwareAuthenticator()
        #expect(throws: WebAuthnError.wrongType) {
            try register(
                authenticator,
                authenticator.register(
                    challenge: challenge, origin: origin, relyingPartyID: rpID, type: "webauthn.get"))
        }
        #expect(throws: WebAuthnError.challengeMismatch) {
            try register(
                authenticator,
                authenticator.register(challenge: Data([9]), origin: origin, relyingPartyID: rpID))
        }
        #expect(throws: WebAuthnError.originMismatch) {
            try register(
                authenticator,
                authenticator.register(
                    challenge: challenge, origin: "https://evil.example", relyingPartyID: rpID))
        }
        #expect(throws: WebAuthnError.relyingPartyMismatch) {
            try register(
                authenticator,
                authenticator.register(
                    challenge: challenge, origin: origin, relyingPartyID: "evil.example"))
        }
    }

    @Test("registration requires user verification and attested credential data")
    func registrationFlags() {
        let authenticator = SoftwareAuthenticator()
        #expect(throws: WebAuthnError.userNotVerified) {
            try register(
                authenticator,
                authenticator.register(
                    challenge: challenge, origin: origin, relyingPartyID: rpID,
                    flags: SoftwareAuthenticator.userPresent | SoftwareAuthenticator.attestedData))
        }
        #expect(throws: WebAuthnError.userNotPresent) {
            try register(
                authenticator,
                authenticator.register(
                    challenge: challenge, origin: origin, relyingPartyID: rpID,
                    flags: SoftwareAuthenticator.userVerified | SoftwareAuthenticator.attestedData))
        }
        #expect(throws: WebAuthnError.missingCredentialData) {
            try register(
                authenticator,
                authenticator.register(
                    challenge: challenge, origin: origin, relyingPartyID: rpID,
                    flags: SoftwareAuthenticator.userPresent | SoftwareAuthenticator.userVerified))
        }
    }

    @Test("registration accepts only ES256 keys on P-256")
    func registrationKeyType() {
        let authenticator = SoftwareAuthenticator()
        #expect(throws: WebAuthnError.unsupportedKey) {
            try register(
                authenticator,
                authenticator.register(
                    challenge: challenge, origin: origin, relyingPartyID: rpID,
                    cose: authenticator.coseKey(algorithm: -257)))
        }
    }

    @Test("registration refuses garbage")
    func registrationGarbage() {
        #expect(throws: WebAuthnError.self) {
            try WebAuthn.verifyRegistration(
                clientDataJSON: Data("{}".utf8), attestationObject: Data([0xFF]),
                challenge: challenge, origin: origin, relyingPartyID: rpID, now: now)
        }
    }

    // MARK: - Assertion

    @Test("a good assertion verifies and returns the new count")
    func assertion() throws {
        let authenticator = SoftwareAuthenticator()
        let credential = try saved(authenticator)
        let count = try verify(
            authenticator.assert(
                challenge: challenge, origin: origin, relyingPartyID: rpID, signCount: 3),
            id: credential.id, passkeys: [credential])
        #expect(count == 3)
    }

    @Test("synced passkeys that always report zero keep working")
    func zeroCounts() throws {
        let authenticator = SoftwareAuthenticator()
        let credential = try saved(authenticator)
        for _ in 0..<2 {
            let count = try verify(
                authenticator.assert(challenge: challenge, origin: origin, relyingPartyID: rpID),
                id: credential.id, passkeys: [credential])
            #expect(count == 0)
        }
    }

    @Test("a signature from another key fails")
    func badSignature() throws {
        let owner = SoftwareAuthenticator()
        let credential = try saved(owner)
        let stranger = SoftwareAuthenticator()
        #expect(throws: WebAuthnError.badSignature) {
            try verify(
                stranger.assert(challenge: challenge, origin: origin, relyingPartyID: rpID),
                id: credential.id, passkeys: [credential])
        }
    }

    @Test("an unknown credential fails")
    func unknownCredential() throws {
        let authenticator = SoftwareAuthenticator()
        let credential = try saved(authenticator)
        #expect(throws: WebAuthnError.unknownCredential) {
            try verify(
                authenticator.assert(challenge: challenge, origin: origin, relyingPartyID: rpID),
                id: "nope", passkeys: [credential])
        }
    }

    @Test("a passkey saved for another host does not sign in here")
    func otherHost() throws {
        let authenticator = SoftwareAuthenticator()
        let old = authenticator.register(
            challenge: challenge, origin: "https://old.example.ts.net",
            relyingPartyID: "old.example.ts.net")
        let credential = try WebAuthn.verifyRegistration(
            clientDataJSON: old.clientDataJSON, attestationObject: old.attestationObject,
            challenge: challenge, origin: "https://old.example.ts.net",
            relyingPartyID: "old.example.ts.net", now: now)
        #expect(throws: WebAuthnError.unknownCredential) {
            try verify(
                authenticator.assert(challenge: challenge, origin: origin, relyingPartyID: rpID),
                id: credential.id, passkeys: [credential])
        }
    }

    @Test("a count that goes backwards fails")
    func countRegressed() throws {
        let authenticator = SoftwareAuthenticator()
        let credential = try saved(authenticator, signCount: 5)
        #expect(throws: WebAuthnError.signCountRegressed) {
            try verify(
                authenticator.assert(
                    challenge: challenge, origin: origin, relyingPartyID: rpID, signCount: 5),
                id: credential.id, passkeys: [credential])
        }
    }

    @Test("assertions check type, challenge, origin, relying party, and verification")
    func assertionMismatches() throws {
        let authenticator = SoftwareAuthenticator()
        let credential = try saved(authenticator)
        #expect(throws: WebAuthnError.wrongType) {
            try verify(
                authenticator.assert(
                    challenge: challenge, origin: origin, relyingPartyID: rpID,
                    type: "webauthn.create"),
                id: credential.id, passkeys: [credential])
        }
        #expect(throws: WebAuthnError.challengeMismatch) {
            try verify(
                authenticator.assert(challenge: Data([1]), origin: origin, relyingPartyID: rpID),
                id: credential.id, passkeys: [credential])
        }
        #expect(throws: WebAuthnError.originMismatch) {
            try verify(
                authenticator.assert(
                    challenge: challenge, origin: "https://evil.example", relyingPartyID: rpID),
                id: credential.id, passkeys: [credential])
        }
        #expect(throws: WebAuthnError.relyingPartyMismatch) {
            try verify(
                authenticator.assert(
                    challenge: challenge, origin: origin, relyingPartyID: "evil.example"),
                id: credential.id, passkeys: [credential])
        }
        #expect(throws: WebAuthnError.userNotVerified) {
            try verify(
                authenticator.assert(
                    challenge: challenge, origin: origin, relyingPartyID: rpID,
                    flags: SoftwareAuthenticator.userPresent),
                id: credential.id, passkeys: [credential])
        }
    }
}
