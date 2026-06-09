import Testing
import HoneycrispCore

@Suite("Action catalog")
struct ActionCatalogTests {
    @Test("sixteen actions with the designed per-app counts")
    func actionCounts() {
        #expect(ActionCatalog.all.count == 16)
        #expect(ActionCatalog.actions(for: .mail).count == 4)
        #expect(ActionCatalog.actions(for: .reminders).count == 4)
        #expect(ActionCatalog.actions(for: .messages).count == 5)
        #expect(ActionCatalog.actions(for: .contacts).count == 3)
    }

    @Test("exactly the three outbound writes require approval")
    func approvalActions() {
        let ids = Set(ActionCatalog.all.filter(\.requiresApproval).map { "\($0.app.rawValue).\($0.id)" })
        #expect(ids == ["mail.send", "messages.send", "messages.draft"])
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

        let complete = try #require(ActionCatalog.descriptor(app: .reminders, action: "complete"))
        #expect(complete.label == "Mark as done")
        #expect(complete.kind == .write)
        #expect(complete.defaultOn == true)
    }

    @Test("app display data carries the designed names and blurbs")
    func appDescriptors() throws {
        #expect(ActionCatalog.apps.map(\.id) == [.mail, .reminders, .messages, .contacts])
        let mail = try #require(ActionCatalog.apps.first { $0.id == .mail })
        #expect(mail.name == "Mail")
        #expect(mail.blurb == "Search, read, and draft mail.")
    }
}
