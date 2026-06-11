import Foundation
import SQLite3
import Testing
import HoneycrispCore

/// Which recipients-table shape a fixture should mimic. Real Mail versions
/// disagree: older indexes use message_id and address_id, the current one
/// uses message and address, and degradation must survive the table being
/// unrecognizable entirely.
private enum RecipientsShape {
    case legacy
    case modern
    case absent
}

/// Builds a fixture Envelope Index and .emlx tree so MailDatabase's SQL and
/// body loading run for real without any TCC grant.
private func makeMailFixture(recipients: RecipientsShape = .legacy) throws -> (
    index: String, root: URL
) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("honeycrisp-tests-\(UUID().uuidString)", isDirectory: true)
    let mailData = root.appendingPathComponent("V10/MailData", isDirectory: true)
    try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)
    let index = mailData.appendingPathComponent("Envelope Index").path

    var db: OpaquePointer?
    guard sqlite3_open(index, &db) == SQLITE_OK else {
        throw ToolFailure("could not create the fixture index")
    }
    defer { sqlite3_close(db) }

    let recipientsSQL: String
    switch recipients {
    case .legacy:
        recipientsSQL = """
            CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message_id INTEGER, address_id INTEGER, type INTEGER, position INTEGER);
            INSERT INTO recipients VALUES (1, 101, 2, 0, 0);
            INSERT INTO recipients VALUES (2, 102, 1, 0, 0);
            INSERT INTO recipients VALUES (3, 102, 3, 1, 1);
            INSERT INTO recipients VALUES (4, 103, 2, 0, 0);
            """
    case .modern:
        recipientsSQL = """
            CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
            INSERT INTO recipients VALUES (1, 101, 2, 0, 0);
            INSERT INTO recipients VALUES (2, 102, 1, 0, 0);
            INSERT INTO recipients VALUES (3, 102, 3, 1, 1);
            INSERT INTO recipients VALUES (4, 103, 2, 0, 0);
            """
    case .absent:
        recipientsSQL = ""
    }

    let statements = """
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, date_received INTEGER, mailbox INTEGER, conversation_id INTEGER, read INTEGER);
        \(recipientsSQL)

        INSERT INTO subjects VALUES (1, 'Re: Q3 planning');
        INSERT INTO subjects VALUES (2, 'Lunch');
        INSERT INTO addresses VALUES (1, 'alex@studio.com', 'Alex Rivera');
        INSERT INTO addresses VALUES (2, 'me@me.com', 'Christian');
        INSERT INTO addresses VALUES (3, 'maya@studio.com', 'Maya Chen');
        INSERT INTO mailboxes VALUES (1, 'imap://chris@mail.example/INBOX');
        INSERT INTO mailboxes VALUES (2, 'imap://chris@mail.example/Sent%20Messages');

        INSERT INTO messages VALUES (101, 1, 1, 1750000000, 1, 9001, 1);
        INSERT INTO messages VALUES (102, 1, 2, 1750000600, 2, 9001, 1);
        INSERT INTO messages VALUES (103, 2, 3, 1750001200, 1, 9002, 0);
        """
    guard sqlite3_exec(db, statements, nil, nil, nil) == SQLITE_OK else {
        throw ToolFailure("fixture SQL failed: \(String(cString: sqlite3_errmsg(db)))")
    }

    // One .emlx for message 101, somewhere nested like the real store; 102
    // has none on purpose.
    let rfc822 = """
        From: alex@studio.com\r
        To: me@me.com\r
        Subject: Re: Q3 planning\r
        Content-Type: multipart/alternative; boundary="BOUND"\r
        \r
        --BOUND\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Planning looks =\r
        good. See you Thursday=21\r
        --BOUND\r
        Content-Type: text/html\r
        \r
        <p>ignored</p>\r
        --BOUND--\r
        """
    let payload = Data(rfc822.utf8)
    var emlx = Data("\(payload.count)\n".utf8)
    emlx.append(payload)
    emlx.append(Data("\n<?xml version=\"1.0\"?><plist/>".utf8))
    let messagesDir = root.appendingPathComponent(
        "V10/AccountUUID/INBOX.mbox/BoxUUID/Data/1/Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: messagesDir, withIntermediateDirectories: true)
    try emlx.write(to: messagesDir.appendingPathComponent("101.emlx"))

    // Message 103 is HTML-only, like a real newsletter: style soup wrapping
    // a little prose.
    let htmlOnly = """
        From: maya@studio.com\r
        To: me@me.com\r
        Subject: Lunch\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><head><meta charset="utf-8"></head><body>\r
        <style>.footer { font-size: 12px; } td { font-family: helvetica !important; }</style>\r
        <table><tr><td>   </td></tr><tr><td><p>Lunch Friday?</p></td></tr></table>\r
        <div>RSVP&nbsp;by <b>Thursday</b>.</div>\r
        <script>var tracking = "no thanks";</script>\r
        </body></html>\r
        """
    let htmlPayload = Data(htmlOnly.utf8)
    var htmlEmlx = Data("\(htmlPayload.count)\n".utf8)
    htmlEmlx.append(htmlPayload)
    htmlEmlx.append(Data("\n<?xml version=\"1.0\"?><plist/>".utf8))
    try htmlEmlx.write(to: messagesDir.appendingPathComponent("103.emlx"))

    return (index, root)
}

@Suite("Mail database")
struct MailDatabaseTests {
    @Test("search joins names, mailboxes, dates, and read flags")
    func search() async throws {
        let fixture = try makeMailFixture()
        let database = MailDatabase(indexPath: fixture.index, mailRoot: fixture.root)
        let hits = try await database.search(query: "Q3", mailbox: nil, from: nil, to: nil, since: nil, until: nil, unreadOnly: false, limit: 10)
        #expect(hits.count == 2)
        #expect(hits.first?.id == "102")
        #expect(hits.first?.date == Date(timeIntervalSince1970: 1_750_000_600))
        #expect(hits.first?.mailbox == "Sent Messages")
        #expect(hits.last?.from == "alex@studio.com")
        #expect(hits.last?.fromName == "Alex Rivera")

        let bySender = try await database.search(query: "alex", mailbox: nil, from: nil, to: nil, since: nil, until: nil, unreadOnly: false, limit: 10)
        #expect(bySender.map(\.id) == ["101"])

        let unread = try await database.search(query: "Lunch", mailbox: nil, from: nil, to: nil, since: nil, until: nil, unreadOnly: false, limit: 10)
        #expect(unread.first?.read == false)
    }

    @Test("the mailbox filter narrows by url fragment")
    func mailboxFilter() async throws {
        let fixture = try makeMailFixture()
        let database = MailDatabase(indexPath: fixture.index, mailRoot: fixture.root)
        let inbox = try await database.search(query: "Q3", mailbox: "INBOX", from: nil, to: nil, since: nil, until: nil, unreadOnly: false, limit: 10)
        #expect(inbox.map(\.id) == ["101"])
    }

    @Test("thread orders oldest first with recipients, participants, and bodies")
    func thread() async throws {
        let fixture = try makeMailFixture()
        let database = MailDatabase(indexPath: fixture.index, mailRoot: fixture.root)
        let thread = try await database.thread(id: "9001", limit: 10)
        #expect(thread.subject == "Re: Q3 planning")
        #expect(thread.messages.map(\.id) == ["101", "102"])
        #expect(thread.messages.first?.to == ["me@me.com"])
        #expect(thread.messages.first?.body == "Planning looks good. See you Thursday!")
        #expect(thread.messages.last?.body == "(body unavailable)")
        #expect(
            Set(thread.participants)
                == ["alex@studio.com", "me@me.com", "maya@studio.com"])
    }

    @Test("the modern recipients schema (message, address) resolves too")
    func modernRecipientsSchema() async throws {
        let fixture = try makeMailFixture(recipients: .modern)
        let database = MailDatabase(indexPath: fixture.index, mailRoot: fixture.root)
        let thread = try await database.thread(id: "9001", limit: 10)
        #expect(thread.messages.first?.to == ["me@me.com"])
        #expect(thread.messages.first?.body == "Planning looks good. See you Thursday!")
        #expect(
            Set(thread.participants)
                == ["alex@studio.com", "me@me.com", "maya@studio.com"])
    }

    @Test("a missing recipients table degrades to empty to lists, not a failure")
    func absentRecipientsTable() async throws {
        let fixture = try makeMailFixture(recipients: .absent)
        let database = MailDatabase(indexPath: fixture.index, mailRoot: fixture.root)
        let thread = try await database.thread(id: "9001", limit: 10)
        #expect(thread.messages.count == 2)
        #expect(thread.messages.first?.to == [])
        #expect(thread.messages.first?.body == "Planning looks good. See you Thursday!")
        #expect(Set(thread.participants) == ["alex@studio.com", "me@me.com"])
    }

    @Test("HTML-only mail reads as prose: no CSS, no scripts, no whitespace soup")
    func htmlOnlyBody() async throws {
        let fixture = try makeMailFixture()
        let database = MailDatabase(indexPath: fixture.index, mailRoot: fixture.root)
        let thread = try await database.thread(id: "9002", limit: 5)
        let body = try #require(thread.messages.first?.body)
        #expect(body == "Lunch Friday?\nRSVP by Thursday.")
    }

    @Test("messageSummary resolves one message for reply targeting")
    func messageSummary() async throws {
        let fixture = try makeMailFixture()
        let database = MailDatabase(indexPath: fixture.index, mailRoot: fixture.root)
        let summary = try await database.messageSummary(id: "101")
        #expect(summary?.from == "alex@studio.com")
        #expect(summary?.subject == "Re: Q3 planning")
        #expect(try await database.messageSummary(id: "999") == nil)
    }


    @Test("no filters at all is browse: the latest mail, newest first")
    func browse() async throws {
        let fixture = try makeMailFixture()
        let database = MailDatabase(indexPath: fixture.index, mailRoot: fixture.root)
        let latest = try await database.search(
            query: nil, mailbox: nil, from: nil, to: nil, since: nil, until: nil,
            unreadOnly: false, limit: 10)
        #expect(latest.map(\.id) == ["103", "102", "101"])
    }

    @Test("from, to, time bounds, and unread compose as filters")
    func filters() async throws {
        let fixture = try makeMailFixture()
        let database = MailDatabase(indexPath: fixture.index, mailRoot: fixture.root)

        let fromAlex = try await database.search(
            query: nil, mailbox: nil, from: "alex", to: nil, since: nil, until: nil,
            unreadOnly: false, limit: 10)
        #expect(fromAlex.map(\.id) == ["101"])

        let toMe = try await database.search(
            query: nil, mailbox: nil, from: nil, to: "me@me.com", since: nil, until: nil,
            unreadOnly: false, limit: 10)
        #expect(toMe.map(\.id) == ["103", "101"])

        let ccMaya = try await database.search(
            query: nil, mailbox: nil, from: nil, to: "maya", since: nil, until: nil,
            unreadOnly: false, limit: 10)
        #expect(ccMaya.map(\.id) == ["102"])

        let since = try await database.search(
            query: nil, mailbox: nil, from: nil, to: nil,
            since: Date(timeIntervalSince1970: 1_750_000_600), until: nil,
            unreadOnly: false, limit: 10)
        #expect(since.map(\.id) == ["103", "102"])

        let until = try await database.search(
            query: nil, mailbox: nil, from: nil, to: nil,
            since: nil, until: Date(timeIntervalSince1970: 1_750_000_600),
            unreadOnly: false, limit: 10)
        #expect(until.map(\.id) == ["101"])

        let unread = try await database.search(
            query: nil, mailbox: nil, from: nil, to: nil, since: nil, until: nil,
            unreadOnly: true, limit: 10)
        #expect(unread.map(\.id) == ["103"])
    }

    @Test("mailboxes lists the decoded display names")
    func mailboxNames() async throws {
        let fixture = try makeMailFixture()
        let database = MailDatabase(indexPath: fixture.index, mailRoot: fixture.root)
        #expect(try await database.mailboxes() == ["INBOX", "Sent Messages"])
    }

    @Test("the to filter fails honestly when the recipients schema is unusable")
    func toFilterWithoutRecipients() async throws {
        let fixture = try makeMailFixture(recipients: .absent)
        let database = MailDatabase(indexPath: fixture.index, mailRoot: fixture.root)
        do {
            _ = try await database.search(
                query: nil, mailbox: nil, from: nil, to: "me@me.com", since: nil, until: nil,
                unreadOnly: false, limit: 10)
            Issue.record("expected a ToolFailure")
        } catch let failure as ToolFailure {
            #expect(failure.message.contains("to filter"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("a missing index fails with the Full Disk Access sentence")
    func missingIndex() async {
        let database = MailDatabase(
            indexPath: "/nonexistent/Envelope Index",
            mailRoot: URL(fileURLWithPath: "/nonexistent"))
        do {
            _ = try await database.search(query: "x", mailbox: nil, from: nil, to: nil, since: nil, until: nil, unreadOnly: false, limit: 5)
            Issue.record("expected a ToolFailure")
        } catch let failure as ToolFailure {
            #expect(failure.message.contains("Full Disk Access"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
