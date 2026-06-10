import Foundation
import MCP
import Testing
import HoneycrispCore

private actor FakeCalendarService: CalendarServicing {
    private(set) var todayLimits: [Int] = []
    private(set) var upcomingCalls: [(days: Int, calendar: String?, limit: Int)] = []
    private(set) var created: [NewEvent] = []

    var todayResult: [CalendarEvent] = []
    var upcomingResult: [CalendarEvent] = []

    func setTodayResult(_ events: [CalendarEvent]) { todayResult = events }

    func today(limit: Int) async throws -> [CalendarEvent] {
        todayLimits.append(limit)
        return todayResult
    }

    func upcoming(days: Int, calendar: String?, limit: Int) async throws -> [CalendarEvent] {
        upcomingCalls.append((days, calendar, limit))
        return upcomingResult
    }

    func create(_ new: NewEvent) async throws -> CalendarEvent {
        created.append(new)
        return CalendarEvent(
            id: "e-new", title: new.title, calendar: new.calendar ?? "Home",
            start: new.start, end: new.end, allDay: new.allDay,
            location: new.location, notes: new.notes)
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

    @Test("list defaults to seven days and passes filters through")
    func list() async throws {
        let service = FakeCalendarService()
        let tools = CalendarTools(service: service)
        _ = try await tools.execute(action: "list", arguments: [:], defaultLimit: 20)
        _ = try await tools.execute(
            action: "list",
            arguments: ["days": 14, "calendar": "Work", "limit": 5],
            defaultLimit: 20)
        let calls = await service.upcomingCalls
        #expect(calls.count == 2)
        #expect(calls.first?.days == 7)
        #expect(calls.first?.calendar == nil)
        #expect(calls.last?.days == 14)
        #expect(calls.last?.calendar == "Work")
        #expect(calls.last?.limit == 5)
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
}
