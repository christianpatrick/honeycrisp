import Foundation
import Testing

@testable import HoneycrispCore

@Suite("Mail links")
struct MailLinkTests {
    @Test("the live-verified DistroKid id gives exactly the link that opened on iPhone")
    func liveVerifiedLink() {
        #expect(
            MailLink.url(
                forMessageIDHeader:
                    "<07.28.03045.1AA97DA6@i-09d58df49531300c5.mta1vrest.sd.prd.sparkpost>")
                == "message://%3C07.28.03045.1AA97DA6@i-09d58df49531300c5.mta1vrest.sd.prd.sparkpost%3E"
        )
    }

    @Test("bare and bracketed headers give the same link")
    func bracketsAreOptional() {
        let bare = MailLink.url(forMessageIDHeader: "abc.123@example.com")
        let bracketed = MailLink.url(forMessageIDHeader: "  <abc.123@example.com>\r\n")
        #expect(bare == "message://%3Cabc.123@example.com%3E")
        #expect(bracketed == bare)
    }

    @Test("characters outside the unreserved set are escaped, @ stays")
    func escaping() {
        #expect(
            MailLink.url(forMessageIDHeader: "<CAB+x=y/z$w%q~_@mail.gmail.com>")
                == "message://%3CCAB%2Bx%3Dy%2Fz%24w%25q~_@mail.gmail.com%3E")
    }

    @Test("an empty or missing header gives no link")
    func empty() {
        #expect(MailLink.url(forMessageIDHeader: nil) == nil)
        #expect(MailLink.url(forMessageIDHeader: "") == nil)
        #expect(MailLink.url(forMessageIDHeader: " <> ") == nil)
    }
}

@Suite("Mailbox locations")
struct MailboxLocationTests {
    private let accounts = [
        MailAccountRecord(
            id: "8F2D61A4-1111-2222-3333-444444444444", userName: "christian@helvin.com",
            serverName: "p68-imap.mail.me.com"),
        MailAccountRecord(
            id: "0C1E5B77-5555-6666-7777-888888888888", userName: "work@example.com",
            serverName: "imap.gmail.com"),
        MailAccountRecord(
            id: "D4A0F1E2-9999-AAAA-BBBB-CCCCCCCCCCCC", userName: "side@example.com",
            serverName: "imap.gmail.com"),
    ]

    @Test("an imap url splits into user, server, and decoded path")
    func imapURL() throws {
        let location = try #require(
            MailboxLocation(url: "imap://work%40example.com@imap.gmail.com/%5BGmail%5D/All%20Mail"))
        #expect(location.user == "work@example.com")
        #expect(location.host == "imap.gmail.com")
        #expect(location.path == "[Gmail]/All Mail")
        #expect(location.isLocal == false)
    }

    @Test("a local url names a mailbox On My Mac")
    func localURL() throws {
        let location = try #require(MailboxLocation(url: "local://localhost/Old%20Receipts/2019"))
        #expect(location.isLocal)
        #expect(location.path == "Old Receipts/2019")
    }

    @Test("a url without a mailbox path is not a location")
    func noPath() {
        #expect(MailboxLocation(url: "imap://someone@imap.example.com/") == nil)
        #expect(MailboxLocation(url: "not a url") == nil)
    }

    @Test("a UUID host matches the account id first")
    func uuidHost() throws {
        let location = try #require(
            MailboxLocation(url: "imap://8F2D61A4-1111-2222-3333-444444444444/Archive"))
        #expect(location.accountID(among: accounts) == "8F2D61A4-1111-2222-3333-444444444444")
    }

    @Test("the one account on a server wins without a user check")
    func singleServer() throws {
        let location = try #require(
            MailboxLocation(url: "imap://christian@p68-imap.mail.me.com/Archive"))
        #expect(location.accountID(among: accounts) == "8F2D61A4-1111-2222-3333-444444444444")
    }

    @Test("two accounts on one server are told apart by user name")
    func sharedServer() throws {
        let location = try #require(
            MailboxLocation(url: "imap://side%40example.com@imap.gmail.com/INBOX"))
        #expect(location.accountID(among: accounts) == "D4A0F1E2-9999-AAAA-BBBB-CCCCCCCCCCCC")
    }

    @Test("a tie Honeycrisp cannot break matches nothing")
    func tie() throws {
        let location = try #require(
            MailboxLocation(url: "imap://nobody%40example.com@imap.gmail.com/INBOX"))
        #expect(location.accountID(among: accounts) == nil)
    }

    @Test("with a single account, any account mailbox belongs to it")
    func onlyAccount() throws {
        let location = try #require(
            MailboxLocation(url: "imap://christian@imap.mail.me.com/Archive"))
        #expect(location.accountID(among: [accounts[0]]) == accounts[0].id)
        #expect(location.accountID(among: []) == nil)
    }

    @Test("Trash mailboxes are recognized across providers")
    func trash() throws {
        let trash = [
            "imap://christian@p68-imap.mail.me.com/Deleted%20Messages",
            "imap://work%40example.com@imap.gmail.com/%5BGmail%5D/Trash",
            "imap://8F2D61A4-1111-2222-3333-444444444444/Deleted%20Items",
            "imap://someone@imap.example.com/TRASH",
            "local://localhost/Trash",
        ]
        for url in trash {
            #expect(try #require(MailboxLocation(url: url)).isTrash, "\(url)")
        }
        let kept = [
            "imap://christian@p68-imap.mail.me.com/INBOX",
            "imap://christian@p68-imap.mail.me.com/Archive",
            "imap://christian@p68-imap.mail.me.com/Junk",
            "imap://christian@p68-imap.mail.me.com/Trash%20Talk",
            "imap://christian@p68-imap.mail.me.com/Trash/Keep",
        ]
        for url in kept {
            #expect(try #require(MailboxLocation(url: url)).isTrash == false, "\(url)")
        }
    }
}
