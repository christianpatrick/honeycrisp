import Foundation
import MCP
import Testing

@testable import HoneycrispCore

private actor FakeCalendarService: CalendarServicing {
    private(set) var todayLimits: [Int] = []
    private(set) var rangeCalls: [(from: Date, to: Date, calendar: String?, limit: Int)] = []
    private(set) var calendarNameCalls = 0
    private(set) var created: [NewEvent] = []

    var todayResult: [CalendarEvent] = []
    var upcomingResult: [CalendarEvent] = []

    func setTodayResult(_ events: [CalendarEvent]) { todayResult = events }

    func today(limit: Int) async throws -> [CalendarEvent] {
        todayLimits.append(limit)
        return todayResult
    }

    func events(from: Date, to: Date, calendar: String?, limit: Int) async throws
        -> [CalendarEvent]
    {
        rangeCalls.append((from, to, calendar, limit))
        return upcomingResult
    }

    func calendarNames() async throws -> [String] {
        calendarNameCalls += 1
        return ["Home", "Work"]
    }

    func create(_ new: NewEvent) async throws -> CalendarEvent {
        created.append(new)
        return CalendarEvent(
            id: "e-new", title: new.title, calendar: new.calendar ?? "Home",
            start: new.start, end: new.end, allDay: new.allDay,
            location: new.location, notes: new.notes)
    }

    private(set) var updates: [EventUpdate] = []
    private(set) var deletedIDs: [String] = []

    func update(_ update: EventUpdate) async throws -> CalendarEvent {
        updates.append(update)
        return CalendarEvent(
            id: update.id, title: update.title ?? "Standup",
            calendar: update.calendar ?? "Work",
            start: update.start ?? Date(timeIntervalSinceReferenceDate: 800_000_000),
            end: update.end ?? Date(timeIntervalSinceReferenceDate: 800_001_800),
            allDay: update.allDay ?? false,
            location: update.location, notes: update.notes)
    }

    func delete(id: String) async throws -> CalendarEvent {
        deletedIDs.append(id)
        return CalendarEvent(
            id: id, title: "Standup", calendar: "Work",
            start: Date(timeIntervalSinceReferenceDate: 800_000_000),
            end: Date(timeIntervalSinceReferenceDate: 800_001_800),
            allDay: false, location: nil, notes: nil)
    }
}

private let standup = CalendarEvent(
    id: "e-1", title: "Standup", calendar: "Work",
    start: Date(timeIntervalSinceReferenceDate: 800_000_000),
    end: Date(timeIntervalSinceReferenceDate: 800_001_800),
    allDay: false, location: nil, notes: nil)

@Suite("Calendar tools")
struct CalendarToolsTests {
    @Test("today applies the default limit and uses the designed sentence")
    func today() async throws {
        let service = FakeCalendarService()
        await service.setTodayResult([standup])
        let tools = CalendarTools(service: service)
        let outcome = try await tools.execute(action: "today", arguments: [:], defaultLimit: 15)
        #expect(await service.todayLimits == [15])
        let decoded = try ToolJSON.decode([CalendarEvent].self, from: outcome.content)
        #expect(decoded == [standup])
        #expect(outcome.auditAction == "Checked what is on today")
        #expect(outcome.auditSummary.contains("Nothing was modified"))
    }

    @Test("list defaults to a seven day window and honors days and explicit ranges")
    func list() async throws {
        let service = FakeCalendarService()
        let tools = CalendarTools(service: service)
        _ = try await tools.execute(action: "list", arguments: [:], defaultLimit: 20)
        _ = try await tools.execute(
            action: "list",
            arguments: ["days": 14, "calendar": "Work", "limit": 5],
            defaultLimit: 20)
        let calls = await service.rangeCalls
        #expect(calls.count == 2)
        let defaultSpan = calls[0].to.timeIntervalSince(calls[0].from)
        #expect(abs(defaultSpan - 7 * 86400) < 1)
        let daysSpan = calls[1].to.timeIntervalSince(calls[1].from)
        #expect(abs(daysSpan - 14 * 86400) < 1)
        #expect(calls[1].calendar == "Work")
        #expect(calls[1].limit == 5)

        _ = try await tools.execute(
            action: "list",
            arguments: ["from": "2026-06-16T00:00:00", "to": "2026-06-17T00:00:00"],
            defaultLimit: 20)
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 16
        let explicit = await service.rangeCalls.last
        #expect(explicit?.from == Calendar.current.date(from: components))
        #expect(abs((explicit?.to.timeIntervalSince(explicit?.from ?? .distantPast) ?? 0) - 86400) < 1)
    }

    @Test("calendars returns the calendar names")
    func calendarNames() async throws {
        let service = FakeCalendarService()
        let tools = CalendarTools(service: service)
        let outcome = try await tools.execute(action: "calendars", arguments: [:], defaultLimit: 20)
        #expect(await service.calendarNameCalls == 1)
        let names = try ToolJSON.decode([String].self, from: outcome.content)
        #expect(names == ["Home", "Work"])
    }

    @Test("create maps fields, parses ISO dates, and defaults the end an hour out")
    func create() async throws {
        let service = FakeCalendarService()
        let tools = CalendarTools(service: service)
        let outcome = try await tools.execute(
            action: "create",
            arguments: [
                "title": "Dentist",
                "start": "2026-06-12T09:00:00",
                "calendar": "Family",
                "location": "Bay Dental",
                "notes": "Bring the paperwork",
                "url": "https://baydental.example/booking",
            ],
            defaultLimit: 20)
        let created = await service.created
        #expect(created.count == 1)
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 12
        components.hour = 9
        let start = Calendar.current.date(from: components)!
        #expect(created.first?.title == "Dentist")
        #expect(created.first?.start == start)
        #expect(created.first?.end == start.addingTimeInterval(3600))
        #expect(created.first?.calendar == "Family")
        #expect(created.first?.location == "Bay Dental")
        #expect(created.first?.url == "https://baydental.example/booking")
        #expect(outcome.auditAction.contains("Dentist"))
        #expect(outcome.auditSummary.contains("Created one event"))
    }

    @Test("create requires a title and a parseable start")
    func createValidation() async {
        let tools = CalendarTools(service: FakeCalendarService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(
                action: "create", arguments: ["start": "2026-06-12T09:00:00"], defaultLimit: 20)
        }
        do {
            _ = try await tools.execute(
                action: "create",
                arguments: ["title": "Dentist", "start": "whenever"],
                defaultLimit: 20)
            Issue.record("expected a ToolFailure")
        } catch let failure as ToolFailure {
            #expect(failure.message.contains("ISO 8601"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("an unknown calendar action fails")
    func unknownAction() async {
        let tools = CalendarTools(service: FakeCalendarService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "rsvp", arguments: [:], defaultLimit: 20)
        }
    }

    @Test("the executor routes calendar when wired")
    func executorRouting() async throws {
        let service = FakeCalendarService()
        await service.setTodayResult([standup])
        let executor = ServiceExecutor(configProvider: { .default }, calendar: service)
        let outcome = try await executor.execute(app: .calendar, action: "today", arguments: [:])
        #expect(outcome.content.contains("Standup"))
    }

    @Test("update maps partial fields and reports what changed")
    func update() async throws {
        let service = FakeCalendarService()
        let tools = CalendarTools(service: service)
        let outcome = try await tools.execute(
            action: "update",
            arguments: [
                "id": "e-1",
                "title": "Standup, moved",
                "start": "2026-06-12T15:00:00",
                "location": "",
            ],
            defaultLimit: 20)
        let update = try #require(await service.updates.first)
        #expect(update.id == "e-1")
        #expect(update.title == "Standup, moved")
        #expect(update.start != nil)
        #expect(update.end == nil)
        #expect(update.location == "")
        #expect(update.notes == nil)
        #expect(update.allDay == nil)
        #expect(outcome.auditAction == "Updated the event \u{201C}Standup, moved\u{201D}")
        let decoded = try ToolJSON.decode(CalendarEvent.self, from: outcome.content)
        #expect(decoded.title == "Standup, moved")
    }

    @Test("update needs an id, at least one change, and parseable dates")
    func updateValidation() async {
        let tools = CalendarTools(service: FakeCalendarService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(
                action: "update", arguments: ["title": "x"], defaultLimit: 20)
        }
        do {
            _ = try await tools.execute(action: "update", arguments: ["id": "e-1"], defaultLimit: 20)
            Issue.record("expected a ToolFailure")
        } catch let failure as ToolFailure {
            #expect(failure.message.contains("something to change"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(
                action: "update", arguments: ["id": "e-1", "start": "sometime"], defaultLimit: 20)
        }
    }

    @Test("update carries a url, and an empty url clears it")
    func updateURL() async throws {
        let service = FakeCalendarService()
        let tools = CalendarTools(service: service)
        let outcome = try await tools.execute(
            action: "update",
            arguments: ["id": "e-1", "url": "https://meet.example/standup"],
            defaultLimit: 20)
        let update = try #require(await service.updates.first)
        #expect(update.url == "https://meet.example/standup")
        #expect(outcome.auditSummary.contains("url"))

        _ = try await tools.execute(
            action: "update", arguments: ["id": "e-1", "url": ""], defaultLimit: 20)
        #expect(await service.updates.last?.url == "")
    }

    @Test("delete passes the id and audits what went away")
    func delete() async throws {
        let service = FakeCalendarService()
        let tools = CalendarTools(service: service)
        let outcome = try await tools.execute(
            action: "delete", arguments: ["id": "e-7"], defaultLimit: 20)
        #expect(await service.deletedIDs == ["e-7"])
        #expect(outcome.auditAction == "Deleted the event \u{201C}Standup\u{201D}")
        #expect(outcome.auditSummary.contains("removed"))

        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "delete", arguments: [:], defaultLimit: 20)
        }
    }
}

@Suite("Event window resolution")
struct EventWindowTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let end = Date(timeIntervalSinceReferenceDate: 800_001_800)

    @Test("moving only the start keeps the event's duration")
    func startMovePreservesDuration() throws {
        let newStart = Date(timeIntervalSinceReferenceDate: 800_010_000)
        let window = try EKCalendarService.resolvedWindow(
            currentStart: start, currentEnd: end, newStart: newStart, newEnd: nil)
        #expect(window.start == newStart)
        #expect(window.end == newStart.addingTimeInterval(1800))
    }

    @Test("a new end alone keeps the start, and both together are used as given")
    func endAndBoth() throws {
        let newEnd = Date(timeIntervalSinceReferenceDate: 800_005_000)
        let endOnly = try EKCalendarService.resolvedWindow(
            currentStart: start, currentEnd: end, newStart: nil, newEnd: newEnd)
        #expect(endOnly.start == start)
        #expect(endOnly.end == newEnd)

        let newStart = Date(timeIntervalSinceReferenceDate: 800_002_000)
        let both = try EKCalendarService.resolvedWindow(
            currentStart: start, currentEnd: end, newStart: newStart, newEnd: newEnd)
        #expect(both.start == newStart)
        #expect(both.end == newEnd)
    }

    @Test("an end at or before the start refuses with a sentence")
    func endBeforeStart() {
        #expect(throws: ToolFailure.self) {
            _ = try EKCalendarService.resolvedWindow(
                currentStart: start, currentEnd: end, newStart: nil,
                newEnd: start.addingTimeInterval(-60))
        }
        #expect(throws: ToolFailure.self) {
            _ = try EKCalendarService.resolvedWindow(
                currentStart: start, currentEnd: end,
                newStart: end, newEnd: end)
        }
    }
}
