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

        let upcoming = try await service.events(from: Date(), to: Date().addingTimeInterval(86400), calendar: nil, limit: 500)
        #expect(upcoming.contains { $0.id == created.id })
        #expect(upcoming.first { $0.id == created.id }?.title == marker)
    }

    @Test("a start move keeps the duration, and delete removes the event")
    func updateAndDelete() async throws {
        let service = EKCalendarService()
        let marker = "Honeycrisp update test \(UUID().uuidString.prefix(8))"
        let start = Date().addingTimeInterval(7 * 86400)
        let created = try await service.create(
            NewEvent(title: marker, start: start, end: start.addingTimeInterval(1800)))
        var needsCleanup = true
        defer {
            if needsCleanup { Self.remove(identifier: created.id) }
        }

        let newStart = start.addingTimeInterval(3600)
        let moved = try await service.update(EventUpdate(id: created.id, start: newStart))
        #expect(abs(moved.start.timeIntervalSince(newStart)) < 1)
        #expect(abs(moved.end.timeIntervalSince(newStart.addingTimeInterval(1800))) < 1)

        let detailed = try await service.update(
            EventUpdate(id: created.id, title: "\(marker) moved", location: "Kitchen"))
        #expect(detailed.title == "\(marker) moved")
        #expect(detailed.location == "Kitchen")

        let deleted = try await service.delete(id: created.id)
        needsCleanup = false
        #expect(deleted.id == created.id)
        let window = try await service.events(
            from: start.addingTimeInterval(-3600),
            to: newStart.addingTimeInterval(7200),
            calendar: nil, limit: 500)
        #expect(!window.contains { $0.id == created.id })
    }

    private static func remove(identifier: String) {
        let store = EKEventStore()
        guard let event = store.event(withIdentifier: identifier) else { return }
        try? store.remove(event, span: .thisEvent)
    }
}
