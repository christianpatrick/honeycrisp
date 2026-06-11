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

    private static func remove(identifier: String) {
        let store = EKEventStore()
        guard let item = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            return
        }
        try? store.remove(item, commit: true)
    }
}
