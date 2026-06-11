import Foundation
import Testing
import HoneycrispCore

@Suite("CLI parser")
struct CLIParserTests {
    @Test("serve parses with defaults and flags")
    func serve() throws {
        #expect(try CLIParser.parse(["serve"]) == .serve(ServeOptions()))
        #expect(
            try CLIParser.parse(["serve", "--port", "5151"])
                == .serve(ServeOptions(port: 5151)))
        #expect(
            try CLIParser.parse(["serve", "--apps", "mail,reminders", "--read-only"])
                == .serve(ServeOptions(apps: [.mail, .reminders], readOnly: true)))
    }

    @Test("version and help parse")
    func versionAndHelp() throws {
        #expect(try CLIParser.parse(["version"]) == .version)
        #expect(try CLIParser.parse(["--version"]) == .version)
        #expect(try CLIParser.parse([]) == .help)
        #expect(try CLIParser.parse(["help"]) == .help)
    }

    @Test("unknown flags and bad values are sentences")
    func badInput() {
        #expect(throws: CLIError.self) { try CLIParser.parse(["serve", "--frobnicate"]) }
        #expect(throws: CLIError.self) { try CLIParser.parse(["serve", "--port", "huge"]) }
        #expect(throws: CLIError.self) { try CLIParser.parse(["serve", "--apps", "garageband"]) }
    }

    @Test("read-only narrows write levels and switches")
    func readOnlyFlag() {
        var base = HoneycrispConfig.default
        base.setLevel(.write, for: .mail)
        let narrowed = applyServeFlags(ServeOptions(readOnly: true), to: base)
        #expect(narrowed.level(for: .mail) == .read)
        #expect(narrowed.isOn(app: .mail, action: "draft") == false)
        #expect(narrowed.isOn(app: .mail, action: "search"))
        #expect(narrowed.level(for: .contacts) == .read)
    }

    @Test("an apps list turns everything else off and keeps the kept app at its default")
    func appsFlag() {
        let narrowed = applyServeFlags(ServeOptions(apps: [.mail]), to: .default)
        #expect(narrowed.level(for: .mail) == .read)
        #expect(narrowed.level(for: .reminders) == .off)
        #expect(narrowed.level(for: .messages) == .off)
        #expect(narrowed.level(for: .contacts) == .off)
        #expect(narrowed.decision(app: .reminders, action: "list") == .denied(.appOff))
    }
}
