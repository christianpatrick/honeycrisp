import Foundation
import MCP
import Testing
import HoneycrispCore

private actor FakeRemindersService: RemindersServicing {
    struct ListCall: Sendable, Equatable {
        let list: String?
        let includeCompleted: Bool
        let dueAfter: Date?
        let dueBefore: Date?
        let limit: Int
    }

    private(set) var listCalls: [ListCall] = []
    private(set) var dueCalls: [Int] = []
    private(set) var created: [NewReminder] = []
    private(set) var completedIDs: [String] = []

    var listResult: [Reminder] = []
    var dueResult: [Reminder] = []

    func setListResult(_ reminders: [Reminder]) { listResult = reminders }
    func setDueResult(_ reminders: [Reminder]) { dueResult = reminders }

    func reminders(
        list: String?, includeCompleted: Bool, dueAfter: Date?, dueBefore: Date?, limit: Int
    ) async throws -> [Reminder] {
        listCalls.append(
            ListCall(
                list: list, includeCompleted: includeCompleted,
                dueAfter: dueAfter, dueBefore: dueBefore, limit: limit))
        return listResult
    }

    private(set) var listNameCalls = 0

    func listNames() async throws -> [String] {
        listNameCalls += 1
        return ["Inbox", "Family"]
    }

    func dueToday(limit: Int) async throws -> [Reminder] {
        dueCalls.append(limit)
        return dueResult
    }

    func create(_ new: NewReminder) async throws -> Reminder {
        created.append(new)
        return Reminder(
            id: "r-new", title: new.title, notes: new.notes,
            list: new.list ?? "Reminders", dueDate: new.dueDate, completed: false)
    }

    func complete(id: String) async throws -> Reminder {
        completedIDs.append(id)
        return Reminder(
            id: id, title: "Call the dentist", notes: nil,
            list: "Personal", dueDate: nil, completed: true)
    }
}

private let dentist = Reminder(
    id: "r-1", title: "Call the dentist", notes: "Ask about Friday",
    list: "Personal", dueDate: nil, completed: false)

@Suite("Reminders tools")
struct RemindersToolsTests {
    private func config(list: String? = nil, limit: Int = 20) -> HoneycrispConfig {
        var config = HoneycrispConfig.default
        config.defaultRemindersList = list
        config.defaultLimit = limit
        return config
    }

    @Test("list applies the config defaults and round-trips JSON")
    func listDefaults() async throws {
        let service = FakeRemindersService()
        await service.setListResult([dentist])
        let tools = RemindersTools(service: service)
        let outcome = try await tools.execute(
            action: "list", arguments: [:], config: config(list: "Personal", limit: 7))
        #expect(
            await service.listCalls == [
                .init(
                    list: "Personal", includeCompleted: false,
                    dueAfter: nil, dueBefore: nil, limit: 7)
            ])
        let decoded = try ToolJSON.decode([Reminder].self, from: outcome.content)
        #expect(decoded == [dentist])
        #expect(outcome.auditSummary.contains("Read 1 reminder"))
    }

    @Test("explicit arguments override the config defaults")
    func listOverrides() async throws {
        let service = FakeRemindersService()
        let tools = RemindersTools(service: service)
        _ = try await tools.execute(
            action: "list",
            arguments: ["list": "Work", "include_completed": true, "limit": 3],
            config: config(list: "Personal", limit: 20))
        #expect(
            await service.listCalls == [
                .init(list: "Work", includeCompleted: true, dueAfter: nil, dueBefore: nil, limit: 3)
            ])
    }

    @Test("due uses the mock's sentence and notes that nothing was written")
    func dueToday() async throws {
        let service = FakeRemindersService()
        await service.setDueResult([dentist])
        let tools = RemindersTools(service: service)
        let outcome = try await tools.execute(action: "due", arguments: [:], config: config())
        #expect(await service.dueCalls == [20])
        #expect(outcome.auditAction == "Checked what is due today")
        #expect(outcome.auditRows.contains(AuditDetailRow(label: "Wrote", value: "Nothing")))
    }

    @Test("create maps the arguments and parses a local ISO due date")
    func create() async throws {
        let service = FakeRemindersService()
        let tools = RemindersTools(service: service)
        _ = try await tools.execute(
            action: "create",
            arguments: [
                "title": "Call the dentist",
                "due": "2026-06-12T09:00:00",
                "list": "Personal",
                "notes": "Ask about Friday",
            ],
            config: config())
        let created = await service.created
        #expect(created.count == 1)
        #expect(created.first?.title == "Call the dentist")
        #expect(created.first?.list == "Personal")
        #expect(created.first?.notes == "Ask about Friday")
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 12
        components.hour = 9
        #expect(created.first?.dueDate == Calendar.current.date(from: components))
    }

    @Test("a date-only due string parses to local midnight")
    func dateOnlyDue() async throws {
        let service = FakeRemindersService()
        let tools = RemindersTools(service: service)
        _ = try await tools.execute(
            action: "create",
            arguments: ["title": "Pack", "due": "2026-06-12"],
            config: config())
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 12
        #expect(await service.created.first?.dueDate == Calendar.current.date(from: components))
    }

    @Test("an unparseable due date names ISO 8601")
    func badDue() async {
        let tools = RemindersTools(service: FakeRemindersService())
        do {
            _ = try await tools.execute(
                action: "create",
                arguments: ["title": "Pack", "due": "next Friday"],
                config: config())
            Issue.record("expected a ToolFailure")
        } catch let failure as ToolFailure {
            #expect(failure.message.contains("ISO 8601"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("create without a title fails")
    func missingTitle() async {
        let tools = RemindersTools(service: FakeRemindersService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "create", arguments: [:], config: config())
        }
    }

    @Test("complete passes the id through and audits the title")
    func complete() async throws {
        let service = FakeRemindersService()
        let tools = RemindersTools(service: service)
        let outcome = try await tools.execute(
            action: "complete", arguments: ["id": "r-9"], config: config())
        #expect(await service.completedIDs == ["r-9"])
        #expect(outcome.auditAction.contains("Call the dentist"))
        #expect(outcome.auditAction.contains("done"))
    }

    @Test("a due window passes through and bad dates fail with the ISO sentence")
    func dueWindow() async throws {
        let service = FakeRemindersService()
        let tools = RemindersTools(service: service)
        _ = try await tools.execute(
            action: "list",
            arguments: ["due_after": "2026-06-08T00:00:00", "due_before": "2026-06-15T00:00:00"],
            config: config())
        let call = await service.listCalls.first
        #expect(call?.dueAfter != nil)
        #expect(call?.dueBefore != nil)

        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(
                action: "list", arguments: ["due_before": "someday"], config: config())
        }
    }

    @Test("lists returns the list names with read-only audit copy")
    func listNames() async throws {
        let service = FakeRemindersService()
        let tools = RemindersTools(service: service)
        let outcome = try await tools.execute(action: "lists", arguments: [:], config: config())
        #expect(await service.listNameCalls == 1)
        let names = try ToolJSON.decode([String].self, from: outcome.content)
        #expect(names == ["Inbox", "Family"])
        #expect(outcome.auditSummary.contains("Nothing was modified"))
    }

    @Test("complete without an id fails")
    func missingID() async {
        let tools = RemindersTools(service: FakeRemindersService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "complete", arguments: [:], config: config())
        }
    }

    @Test("an unknown reminders action fails")
    func unknownAction() async {
        let tools = RemindersTools(service: FakeRemindersService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "snooze", arguments: [:], config: config())
        }
    }

    @Test("the executor routes reminders when wired")
    func executorRouting() async throws {
        let service = FakeRemindersService()
        await service.setListResult([dentist])
        let executor = ServiceExecutor(configProvider: { .default }, reminders: service)
        let outcome = try await executor.execute(app: .reminders, action: "list", arguments: [:])
        #expect(outcome.content.contains("Call the dentist"))
    }
}
