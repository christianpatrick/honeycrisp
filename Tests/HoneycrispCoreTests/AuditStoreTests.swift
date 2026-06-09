import Foundation
import Testing
import HoneycrispCore

@Suite("Audit store")
struct AuditStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("honeycrisp-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
    }

    /// A fixed local noon so same-day math never depends on when tests run.
    private var noon: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 9
        components.hour = 12
        return Calendar.current.date(from: components)!
    }

    private func entry(
        at timestamp: Date,
        app: AppID = .mail,
        actionID: String = "read",
        kind: ActionKind = .read,
        outcome: AuditOutcome = .allowed,
        action: String = "Read a thread",
        client: String = "Claude Desktop"
    ) -> AuditEntry {
        AuditEntry(
            timestamp: timestamp,
            app: app,
            actionID: actionID,
            kind: kind,
            outcome: outcome,
            action: action,
            client: client,
            summary: "Returned the subject and 6 message bodies. Nothing was modified.",
            rows: [
                AuditDetailRow(label: "Mailbox", value: "All Inboxes"),
                AuditDetailRow(label: "Duration", value: "0.4s"),
            ]
        )
    }

    @Test("appended entries come back newest first with every field intact")
    func appendAndRead() async throws {
        let store = AuditStore(fileURL: tempURL())
        let older = entry(at: noon.addingTimeInterval(-120))
        let newer = entry(at: noon.addingTimeInterval(-60), outcome: .denied, action: "Tried to send a mail")
        try await store.append(older)
        try await store.append(newer)
        let entries = await store.entries()
        #expect(entries == [newer, older])
        #expect(entries.first?.rows == newer.rows)
    }

    @Test("a second store on the same file sees the same entries")
    func persistence() async throws {
        let url = tempURL()
        let first = AuditStore(fileURL: url)
        let saved = entry(at: noon.addingTimeInterval(-60))
        try await first.append(saved)
        let second = AuditStore(fileURL: url)
        #expect(await second.entries() == [saved])
    }

    @Test("tile counts use the calendar day and a trailing 24 hour window")
    func counts() async throws {
        let store = AuditStore(fileURL: tempURL())
        try await store.append(entry(at: noon.addingTimeInterval(-3600)))
        try await store.append(entry(at: noon.addingTimeInterval(-7200), actionID: "send", outcome: .asked))
        try await store.append(entry(at: noon.addingTimeInterval(-26 * 3600), outcome: .asked))
        let counts = await store.counts(now: noon)
        #expect(counts.requestsToday == 2)
        #expect(counts.approvedLastDay == 1)
    }

    @Test("denied and allowed outcomes never count as approvals")
    func approvalCountsOnlyAsked() async throws {
        let store = AuditStore(fileURL: tempURL())
        try await store.append(entry(at: noon.addingTimeInterval(-60), outcome: .allowed))
        try await store.append(entry(at: noon.addingTimeInterval(-90), outcome: .denied))
        let counts = await store.counts(now: noon)
        #expect(counts.approvedLastDay == 0)
    }

    @Test("retention keeps the newest maxEntries and trims the file too")
    func retention() async throws {
        let url = tempURL()
        let store = AuditStore(fileURL: url, maxEntries: 3)
        for offset in 0..<5 {
            try await store.append(entry(at: noon.addingTimeInterval(Double(offset - 10))))
        }
        let entries = await store.entries()
        #expect(entries.count == 3)
        #expect(entries.last?.timestamp == noon.addingTimeInterval(-8))
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
    }

    @Test("clear empties the store and the file but leaves the file present")
    func clear() async throws {
        let url = tempURL()
        let store = AuditStore(fileURL: url)
        try await store.append(entry(at: noon))
        try await store.clear()
        #expect(await store.entries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test("a corrupt line is skipped and the valid lines still load")
    func corruptLine() async throws {
        let url = tempURL()
        let first = AuditStore(fileURL: url)
        let a = entry(at: noon.addingTimeInterval(-120))
        let b = entry(at: noon.addingTimeInterval(-60))
        try await first.append(a)
        try await first.append(b)
        var contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        contents = lines[0] + "\n{this is not json}\n" + lines[1] + "\n"
        try Data(contents.utf8).write(to: url)
        let second = AuditStore(fileURL: url)
        #expect(await second.entries() == [b, a])
    }

    @Test("a limit returns only the newest entries")
    func limit() async throws {
        let store = AuditStore(fileURL: tempURL())
        for offset in 0..<4 {
            try await store.append(entry(at: noon.addingTimeInterval(Double(offset * 60))))
        }
        let two = await store.entries(limit: 2)
        #expect(two.count == 2)
        #expect(two.first?.timestamp == noon.addingTimeInterval(180))
    }
}
