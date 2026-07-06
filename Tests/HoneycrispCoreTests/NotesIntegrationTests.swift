import AppKit
import Foundation
import Testing

@testable import HoneycrispCore

/// Real NoteStore reads and real Apple event writes, opt in because they
/// need Full Disk Access and the Notes Automation grant on the test host:
/// HONEYCRISP_INTEGRATION=1 swift test
@Suite(
    "Notes integration",
    .enabled(if: ProcessInfo.processInfo.environment["HONEYCRISP_INTEGRATION"] == "1"))
struct NotesIntegrationTests {
    @Test("the real store lists notes with UUID ids and mapped fields")
    func search() async throws {
        let database = NotesDatabase()
        let notes = try await database.search(
            query: nil, folder: nil, since: nil, until: nil, pinnedOnly: false, limit: 5)
        #expect(!notes.isEmpty)
        for note in notes {
            #expect(UUID(uuidString: note.id) != nil)
            #expect(!note.folder.isEmpty)
        }
    }

    @Test("folders list with accounts and counts")
    func folders() async throws {
        let database = NotesDatabase()
        let folders = try await database.folders()
        #expect(!folders.isEmpty)
        #expect(folders.allSatisfy { !$0.name.isEmpty })
    }

    @Test("a real note reads in full and links")
    func readAndLink() async throws {
        let database = NotesDatabase()
        let notes = try await database.search(
            query: nil, folder: nil, since: nil, until: nil, pinnedOnly: false, limit: 5)
        let summary = try #require(notes.first { !$0.locked })
        let note = try #require(try await database.note(id: summary.id))
        #expect(!note.body.isEmpty)

        let service = NotesService(
            reader: database, writer: AppleEventNoteWriter(targets: database),
            account: AppleAccount())
        let link = try await service.link(id: summary.id)
        #expect(link.url == "applenotes:note/\(summary.id)")

        let target = try #require(try await database.scriptTarget(id: summary.id))
        #expect(target.appleScriptID.hasPrefix("x-coredata://"))
        #expect(target.appleScriptID.contains("/ICNote/p"))
    }

    @Test("create, append, and read back a real note, then clean it up")
    func createAppendDelete() async throws {
        let database = NotesDatabase()
        let writer = AppleEventNoteWriter(targets: database)
        let marker = UUID().uuidString.prefix(8)
        let title = "Honeycrisp integration test \(marker)"

        let receipt = try await writer.create(
            title: title, body: "Created by the HC-040 integration test.", folder: nil)
        #expect(receipt.title.contains(marker) || receipt.title == title)
        let id = try #require(receipt.id)
        #expect(receipt.url == "applenotes:note/\(id)")

        _ = try await writer.append(id: id, body: "Appended by the same test.")

        // The store lags the app by a beat; poll with a deadline instead
        // of trusting a single read.
        var body = ""
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let note = try await database.note(id: id),
                note.body.contains("Appended by the same test.")
            {
                body = note.body
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(body.contains("Created by the HC-040 integration test."))
        #expect(body.contains("Appended by the same test."))

        // Clean up with a direct delete event. Delete deliberately ships
        // in no tool, so the test speaks the event itself.
        let target = try #require(try await database.scriptTarget(id: id))
        try Self.deleteNote(appleScriptID: target.appleScriptID)
    }

    /// core/delo of note id <x-coredata id>, the standard suite's delete,
    /// which moves the note to Recently Deleted.
    private static func deleteNote(appleScriptID: String) throws {
        func code(_ four: String) -> FourCharCode {
            var result: FourCharCode = 0
            for byte in four.utf8 {
                result = (result << 8) | FourCharCode(byte)
            }
            return result
        }
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code("note")), forKeyword: code("want"))
        record.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: code("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code("ID  ")), forKeyword: code("form"))
        record.setDescriptor(
            NSAppleEventDescriptor(string: appleScriptID), forKeyword: code("seld"))
        let specifier = try #require(record.coerce(toDescriptorType: code("obj ")))

        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code("core"),
            eventID: code("delo"),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes"),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        var direct: AEKeyword = 0
        for byte in "----".utf8 {
            direct = (direct << 8) | AEKeyword(byte)
        }
        event.setParam(specifier, forKeyword: direct)
        _ = try event.sendEvent(options: [.waitForReply], timeout: 30)
    }
}
