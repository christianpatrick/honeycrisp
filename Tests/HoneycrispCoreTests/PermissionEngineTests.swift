import Foundation
import Testing
import HoneycrispCore

@Suite("Permission engine")
struct PermissionEngineTests {
    @Test("the default config matches the designed defaults")
    func defaults() {
        let config = HoneycrispConfig.default
        // Read-only by default: every read is allowed, and every write is
        // denied at the read level (readOnlyApp) before its switch matters.
        #expect(config.decision(app: .mail, action: "search") == .allowed)
        #expect(config.decision(app: .mail, action: "draft") == .denied(.readOnlyApp))
        #expect(config.decision(app: .mail, action: "send") == .denied(.readOnlyApp))
        #expect(config.decision(app: .messages, action: "recent") == .allowed)
        #expect(config.decision(app: .messages, action: "send") == .denied(.readOnlyApp))
        #expect(config.decision(app: .reminders, action: "list") == .allowed)
        #expect(config.decision(app: .reminders, action: "create") == .denied(.readOnlyApp))
        #expect(config.decision(app: .contacts, action: "create") == .denied(.readOnlyApp))
        #expect(config.decision(app: .calendar, action: "today") == .allowed)
        #expect(config.decision(app: .calendar, action: "create") == .denied(.readOnlyApp))
    }

    @Test("an enabled outbound write needs approval, never plain allowed")
    func approvalRequired() {
        var config = HoneycrispConfig.default
        config.setAction("send", on: true, for: .mail)
        #expect(config.decision(app: .mail, action: "send") == .needsApproval)
    }

    @Test("level off denies even read actions")
    func levelOff() {
        var config = HoneycrispConfig.default
        config.setLevel(.off, for: .mail)
        #expect(config.decision(app: .mail, action: "search") == .denied(.appOff))
    }

    @Test("dropping to read forces write switches off")
    func dropToRead() {
        var config = HoneycrispConfig.default
        config.setLevel(.write, for: .mail)
        #expect(config.isOn(app: .mail, action: "draft"))
        config.setLevel(.read, for: .mail)
        #expect(config.isOn(app: .mail, action: "search"))
        #expect(config.isOn(app: .mail, action: "draft") == false)
        #expect(config.level(for: .mail) == .read)
    }

    @Test("raising to write turns every action on, with sends still approval-gated")
    func raiseToWrite() {
        var config = HoneycrispConfig.default
        config.setLevel(.write, for: .messages)
        #expect(config.isOn(app: .messages, action: "recent"))
        #expect(config.isOn(app: .messages, action: "send"))
        #expect(config.isOn(app: .messages, action: "mark_read"))
        #expect(config.decision(app: .messages, action: "send") == .needsApproval)
    }

    @Test("read then read & write round-trips to everything on")
    func readThenWrite() {
        var config = HoneycrispConfig.default
        config.setLevel(.read, for: .mail)
        config.setLevel(.write, for: .mail)
        for action in ActionCatalog.actions(for: .mail) {
            #expect(config.isOn(app: .mail, action: action.id))
        }
    }

    @Test("enabling a write action auto-raises the level so the switch is effective")
    func autoRaise() {
        var config = HoneycrispConfig.default
        #expect(config.level(for: .messages) == .read)
        config.setAction("send", on: true, for: .messages)
        #expect(config.level(for: .messages) == .write)
        #expect(config.decision(app: .messages, action: "send") == .needsApproval)
    }

    @Test("a hand-edited config cannot smuggle writes past a read level")
    func readOnlyGate() throws {
        let json = #"{"levels": {"messages": "read"}, "switches": {"messages": {"send": true}}}"#
        let config = try JSONDecoder().decode(HoneycrispConfig.self, from: Data(json.utf8))
        #expect(config.decision(app: .messages, action: "send") == .denied(.readOnlyApp))
    }

    @Test("unknown actions are denied as unknown")
    func unknownAction() {
        let config = HoneycrispConfig.default
        #expect(config.decision(app: .mail, action: "teleport") == .denied(.unknownAction))
    }

    @Test("listing only surfaces actions that are not denied")
    func visibleActions() {
        let config = HoneycrispConfig.default
        #expect(config.visibleActions(for: .mail).map(\.id) == ["search", "read"])
        #expect(config.visibleActions(for: .messages).map(\.id) == ["recent", "search", "history"])
    }
}
