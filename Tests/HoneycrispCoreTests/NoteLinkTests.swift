import Foundation
import Testing

@testable import HoneycrispCore

@Suite("Note links")
struct NoteLinkTests {
    @Test("the link is the applenotes scheme over the note identifier")
    func url() {
        #expect(
            NoteLink.url(for: "AAAAAAAA-1111-2222-3333-444444444444")
                == "applenotes:note/AAAAAAAA-1111-2222-3333-444444444444")
    }
}

@Suite("Apple account")
struct AppleAccountTests {
    private func writePlist(_ accounts: [[String: Any]]) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("honeycrisp-account-tests-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Accounts": accounts], format: .binary, options: 0)
        try data.write(to: url)
        return url.path
    }

    @Test("the account whose services include Notes wins")
    func notesServicePreferred() throws {
        let path = try writePlist([
            ["AccountID": "work@example.com", "Services": [["Name": "MAIL"]]],
            [
                "AccountID": "christian@example.com",
                "Services": [["Name": "MAIL"], ["Name": "NOTES"]],
            ],
        ])
        #expect(AppleAccount(path: path).primaryEmail() == "christian@example.com")
    }

    @Test("without a Notes service the first signed-in account answers")
    func firstAccountFallback() throws {
        let path = try writePlist([
            ["AccountID": "first@example.com"],
            ["AccountID": "second@example.com"],
        ])
        #expect(AppleAccount(path: path).primaryEmail() == "first@example.com")
    }

    @Test("no plist means no signed-in account, nil")
    func missingPlist() {
        let account = AppleAccount(path: "/nonexistent/honeycrisp/MobileMeAccounts.plist")
        #expect(account.primaryEmail() == nil)
    }
}
