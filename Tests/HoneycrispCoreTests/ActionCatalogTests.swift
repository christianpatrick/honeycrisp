import Testing
import HoneycrispCore

@Suite("Action catalog")
struct ActionCatalogTests {
    @Test("nineteen actions with the designed per-app counts")
    func actionCounts() {
        #expect(ActionCatalog.all.count == 19)
        #expect(ActionCatalog.actions(for: .mail).count == 5)
        #expect(ActionCatalog.actions(for: .reminders).count == 4)
        #expect(ActionCatalog.actions(for: .calendar).count == 3)
        #expect(ActionCatalog.actions(for: .messages).count == 4)
        #expect(ActionCatalog.actions(for: .contacts).count == 3)
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
            ActionCatalog.apps.map(\.id) == [.mail, .reminders, .calendar, .messages, .contacts])
        let mail = try #require(ActionCatalog.apps.first { $0.id == .mail })
        #expect(mail.name == "Mail")
        #expect(mail.blurb == "Search, read, and draft mail.")
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
