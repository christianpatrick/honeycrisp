import Testing
import HoneycrispCore

@Suite("Action catalog")
struct ActionCatalogTests {
    @Test("twenty-five actions with the designed per-app counts")
    func actionCounts() {
        #expect(ActionCatalog.all.count == 25)
        #expect(ActionCatalog.actions(for: .mail).count == 5)
        #expect(ActionCatalog.actions(for: .reminders).count == 4)
        #expect(ActionCatalog.actions(for: .calendar).count == 3)
        #expect(ActionCatalog.actions(for: .messages).count == 5)
        #expect(ActionCatalog.actions(for: .contacts).count == 3)
        #expect(ActionCatalog.actions(for: .notes).count == 5)
    }

    @Test("the conversation history action is a default-on read")
    func messagesHistory() throws {
        let history = try #require(ActionCatalog.descriptor(app: .messages, action: "history"))
        #expect(history.label == "Read a conversation")
        #expect(history.kind == .read)
        #expect(history.defaultOn)
        #expect(history.requiresApproval == false)
    }

    @Test("exactly the two outbound sends require approval")
    func approvalActions() {
        let ids = Set(ActionCatalog.all.filter(\.requiresApproval).map { "\($0.app.rawValue).\($0.id)" })
        #expect(ids == ["mail.send", "messages.send"])
    }

    @Test("messages has no draft action; iMessage cannot draft")
    func noMessagesDraft() {
        #expect(ActionCatalog.descriptor(app: .messages, action: "draft") == nil)
    }

    @Test("spot checks against the catalog spec")
    func spotChecks() throws {
        let send = try #require(ActionCatalog.descriptor(app: .mail, action: "send"))
        #expect(send.label == "Send mail")
        #expect(send.kind == .write)
        #expect(send.defaultOn == false)

        let markRead = try #require(ActionCatalog.descriptor(app: .messages, action: "mark_read"))
        #expect(markRead.label == "Mark a conversation read")
        #expect(markRead.kind == .write)
        #expect(markRead.defaultOn == false)
        #expect(markRead.requiresApproval == false)

        let mailMarkRead = try #require(ActionCatalog.descriptor(app: .mail, action: "mark_read"))
        #expect(mailMarkRead.label == "Mark as read")
        #expect(mailMarkRead.kind == .write)
        #expect(mailMarkRead.defaultOn == false)
        #expect(mailMarkRead.requiresApproval == false)

        let complete = try #require(ActionCatalog.descriptor(app: .reminders, action: "complete"))
        #expect(complete.label == "Mark as done")
        #expect(complete.kind == .write)
        #expect(complete.defaultOn == true)
    }

    @Test("app display data carries the designed names and blurbs")
    func appDescriptors() throws {
        #expect(
            ActionCatalog.apps.map(\.id) == [
                .mail, .reminders, .calendar, .messages, .contacts, .notes,
            ])
        let mail = try #require(ActionCatalog.apps.first { $0.id == .mail })
        #expect(mail.name == "Mail")
        #expect(mail.blurb == "Search, read, and draft mail.")
        let notes = try #require(ActionCatalog.apps.first { $0.id == .notes })
        #expect(notes.name == "Notes")
        #expect(notes.blurb == "Search, read, and capture notes.")
    }

    @Test("notes actions match the HC-040 spec")
    func notesActions() throws {
        let search = try #require(ActionCatalog.descriptor(app: .notes, action: "search"))
        #expect(search.label == "Search notes")
        #expect(search.kind == .read)
        #expect(search.defaultOn)
        #expect(search.requiresApproval == false)

        let link = try #require(ActionCatalog.descriptor(app: .notes, action: "link"))
        #expect(link.label == "Copy a note link")
        #expect(link.kind == .read)
        #expect(link.defaultOn)
        #expect(link.requiresApproval == false)

        let read = try #require(ActionCatalog.descriptor(app: .notes, action: "read"))
        #expect(read.label == "Read a note")
        #expect(read.kind == .read)

        let create = try #require(ActionCatalog.descriptor(app: .notes, action: "create"))
        #expect(create.label == "Create a note")
        #expect(create.kind == .write)
        #expect(create.defaultOn == false)
        #expect(create.requiresApproval == false)

        let append = try #require(ActionCatalog.descriptor(app: .notes, action: "append"))
        #expect(append.label == "Append to a note")
        #expect(append.kind == .write)
        #expect(append.defaultOn == false)
        #expect(append.requiresApproval == false)
    }

    @Test("calendar actions match the spec")
    func calendarActions() throws {
        let today = try #require(ActionCatalog.descriptor(app: .calendar, action: "today"))
        #expect(today.label == "Check what is on today")
        #expect(today.kind == .read)
        #expect(today.defaultOn)

        let create = try #require(ActionCatalog.descriptor(app: .calendar, action: "create"))
        #expect(create.label == "Create an event")
        #expect(create.kind == .write)
        #expect(create.defaultOn == false)
        #expect(create.requiresApproval == false)
    }
}
