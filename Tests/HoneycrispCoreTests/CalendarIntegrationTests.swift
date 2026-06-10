import EventKit
import Foundation
import Testing
import HoneycrispCore

/// Real-store tests, opt in because they need a Calendar TCC grant and a
/// prompt-capable host like Terminal: HONEYCRISP_INTEGRATION=1 swift test
@Suite(
    "Calendar integration",
    .enabled(if: ProcessInfo.processInfo.environment["HONEYCRISP_INTEGRATION"] == "1"))
struct CalendarIntegrationTests {
    @Test("create, find, and remove an event round trip on the real store")
    func roundTrip() async throws {
        let service = EKCalendarService()
        let marker = "Honeycrisp test \(UUID().uuidString.prefix(8))"
        let start = Date().addingTimeInterval(3600)
        let created = try await service.create(
            NewEvent(title: marker, start: start, end: start.addingTimeInterval(1800)))
        defer { Self.remove(identifier: created.id) }

        let upcoming = try await service.upcoming(days: 1, calendar: nil, limit: 500)
        #expect(upcoming.contains { $0.id == created.id })
        #expect(upcoming.first { $0.id == created.id }?.title == marker)
    }

    private static func remove(identifier: String) {
        let store = EKEventStore()
        guard let event = store.event(withIdentifier: identifier) else { return }
        try? store.remove(event, span: .thisEvent)
    }
}
