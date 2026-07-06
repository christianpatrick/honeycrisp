import EventKit
import Foundation
import Testing
import HoneycrispCore

/// Real-store tests, opt in because they need a Reminders TCC grant and a
/// prompt-capable host like Terminal: HONEYCRISP_INTEGRATION=1 swift test
@Suite(
    "Reminders integration",
    .enabled(if: ProcessInfo.processInfo.environment["HONEYCRISP_INTEGRATION"] == "1"))
struct RemindersIntegrationTests {
    @Test("create, find, complete, and remove round trip on the real store")
    func roundTrip() async throws {
        let service = EKRemindersService()
        let marker = "Honeycrisp test \(UUID().uuidString.prefix(8))"
        var due = DateComponents()
        due.year = 2026
        due.month = 12
        due.day = 24
        due.hour = 9
        let created = try await service.create(
            NewReminder(
                title: marker,
                notes: "Created by the Honeycrisp integration tests.",
                dueDate: Calendar.current.date(from: due)
            ))
        defer { Self.remove(identifier: created.id) }

        let listed = try await service.reminders(
            list: nil, includeCompleted: false, dueAfter: nil, dueBefore: nil, limit: 500)
        #expect(listed.contains { $0.id == created.id })

        let completed = try await service.complete(id: created.id)
        #expect(completed.completed)

        let after = try await service.reminders(
            list: nil, includeCompleted: true, dueAfter: nil, dueBefore: nil, limit: 500)
        #expect(after.first { $0.id == created.id }?.completed == true)
    }

    @Test("update and delete round trip on the real store")
    func updateAndDelete() async throws {
        let service = EKRemindersService()
        let marker = "Honeycrisp update test \(UUID().uuidString.prefix(8))"
        let created = try await service.create(NewReminder(title: marker))
        var needsCleanup = true
        defer {
            if needsCleanup { Self.remove(identifier: created.id) }
        }

        var components = DateComponents()
        components.year = 2026
        components.month = 12
        components.day = 24
        components.hour = 9
        let due = Calendar.current.date(from: components)
        let moved = try await service.update(
            ReminderUpdate(
                id: created.id, title: "\(marker) moved",
                notes: "Updated by the integration tests.", dueDate: due))
        #expect(moved.title == "\(marker) moved")
        #expect(moved.dueDate == due)
        #expect(moved.notes == "Updated by the integration tests.")

        let linked = try await service.update(
            ReminderUpdate(id: created.id, url: "https://honeycrisp.app/test"))
        #expect(linked.url == "https://honeycrisp.app/test")

        let unlinked = try await service.update(ReminderUpdate(id: created.id, url: ""))
        #expect(unlinked.url == nil)

        let cleared = try await service.update(
            ReminderUpdate(id: created.id, clearDue: true, completed: true))
        #expect(cleared.dueDate == nil)
        #expect(cleared.completed)

        let reopened = try await service.update(
            ReminderUpdate(id: created.id, completed: false))
        #expect(reopened.completed == false)

        let deleted = try await service.delete(id: created.id)
        needsCleanup = false
        #expect(deleted.id == created.id)
        let after = try await service.reminders(
            list: nil, includeCompleted: true, dueAfter: nil, dueBefore: nil, limit: 500)
        #expect(!after.contains { $0.id == created.id })
    }

    private static func remove(identifier: String) {
        let store = EKEventStore()
        guard let item = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            return
        }
        try? store.remove(item, commit: true)
    }
}
