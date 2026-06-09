import Foundation
import Testing
import HoneycrispCore

@Suite("Config persistence")
struct ConfigPersistenceTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("honeycrisp-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    @Test("round trips through disk")
    func roundTrip() throws {
        let url = tempURL()
        var config = HoneycrispConfig.default
        config.port = 50505
        config.setLevel(.off, for: .contacts)
        try config.save(to: url)
        #expect(HoneycrispConfig.load(from: url) == config)
    }

    @Test("a missing file loads the default")
    func missingFile() {
        #expect(HoneycrispConfig.load(from: tempURL()) == HoneycrispConfig.default)
    }

    @Test("corrupt JSON loads the default and leaves the file alone")
    func corruptFile() throws {
        let url = tempURL()
        try write("not json", to: url)
        #expect(HoneycrispConfig.load(from: url) == HoneycrispConfig.default)
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }

    @Test("a sparse config decodes with defaults everywhere else")
    func sparseConfig() throws {
        let url = tempURL()
        try write(#"{"port": 5}"#, to: url)
        let config = HoneycrispConfig.load(from: url)
        #expect(config.port == 5)
        #expect(config.defaultLimit == HoneycrispConfig.default.defaultLimit)
        #expect(config.level(for: .mail) == .write)
        #expect(config.isOn(app: .mail, action: "search"))
    }

    @Test("normalization heals old configs against the catalog")
    func normalization() throws {
        let url = tempURL()
        let old = #"""
        {"switches": {
            "messages": {"recent": false, "vanished_action": true},
            "garageband": {"strum": true}
        }}
        """#
        try write(old, to: url)
        let config = HoneycrispConfig.load(from: url)
        #expect(config.isOn(app: .messages, action: "recent") == false)
        #expect(config.isOn(app: .messages, action: "search"))
        #expect(config.decision(app: .messages, action: "vanished_action") == .denied(.unknownAction))
        let encoded = try String(data: JSONEncoder().encode(config), encoding: .utf8)
        #expect(encoded?.contains("vanished_action") == false)
        #expect(encoded?.contains("garageband") == false)
    }

    @Test("save creates the directory chain and writes valid JSON")
    func saveCreatesDirectories() throws {
        let url = tempURL()
        try HoneycrispConfig.default.save(to: url)
        let data = try Data(contentsOf: url)
        #expect(throws: Never.self) { try JSONSerialization.jsonObject(with: data) }
    }
}
