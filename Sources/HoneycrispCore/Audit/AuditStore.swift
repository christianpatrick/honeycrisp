import Foundation

/// How a request ended, mirroring the design's three badges:
/// allowed ran silently, denied was blocked (by permissions, the user,
/// or a timeout; the detail rows say which), asked means the user was
/// asked and approved.
public enum AuditOutcome: String, Codable, Sendable, Equatable {
    case allowed
    case denied
    case asked
}

/// One label and value pair in an entry's expandable detail.
public struct AuditDetailRow: Codable, Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// One row in the Activity tab.
public struct AuditEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let app: AppID
    public let actionID: String
    public let kind: ActionKind
    public let outcome: AuditOutcome
    /// The human sentence shown in the row, like "Read the thread".
    public let action: String
    public let client: String
    public let summary: String
    public let rows: [AuditDetailRow]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        app: AppID,
        actionID: String,
        kind: ActionKind,
        outcome: AuditOutcome,
        action: String,
        client: String,
        summary: String,
        rows: [AuditDetailRow]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.app = app
        self.actionID = actionID
        self.kind = kind
        self.outcome = outcome
        self.action = action
        self.client = client
        self.summary = summary
        self.rows = rows
    }
}

/// The numbers behind the Status tab's glance tiles.
public struct AuditCounts: Equatable, Sendable {
    public let requestsToday: Int
    public let approvedLastDay: Int

    public init(requestsToday: Int, approvedLastDay: Int) {
        self.requestsToday = requestsToday
        self.approvedLastDay = approvedLastDay
    }
}

/// Local, capped, clearable record of every request. JSONL on disk, one
/// object per line, and nothing here ever leaves the Mac.
public actor AuditStore {
    private let fileURL: URL
    private let maxEntries: Int
    /// Oldest first; the cap keeps this small enough to hold in memory.
    private var cache: [AuditEntry]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, maxEntries: Int = 2000) {
        self.fileURL = fileURL
        self.maxEntries = max(1, maxEntries)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        var loaded = Self.loadEntries(from: fileURL)
        if loaded.count > self.maxEntries {
            loaded.removeFirst(loaded.count - self.maxEntries)
        }
        self.cache = loaded
    }

    public func append(_ entry: AuditEntry) throws {
        cache.append(entry)
        if cache.count > maxEntries {
            cache.removeFirst(cache.count - maxEntries)
            try rewrite()
            return
        }
        var line = try encoder.encode(entry)
        line.append(0x0A)
        try ensureFileExists()
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func entries(limit: Int? = nil) -> [AuditEntry] {
        let newestFirst = Array(cache.reversed())
        guard let limit else { return newestFirst }
        return Array(newestFirst.prefix(limit))
    }

    public func counts(now: Date = Date()) -> AuditCounts {
        let calendar = Calendar.current
        let windowStart = now.addingTimeInterval(-24 * 3600)
        var today = 0
        var approved = 0
        for entry in cache {
            if calendar.isDate(entry.timestamp, inSameDayAs: now) {
                today += 1
            }
            if entry.outcome == .asked, entry.timestamp > windowStart, entry.timestamp <= now {
                approved += 1
            }
        }
        return AuditCounts(requestsToday: today, approvedLastDay: approved)
    }

    public func clear() throws {
        cache = []
        try ensureFileExists()
        try Data().write(to: fileURL)
    }

    private func rewrite() throws {
        var data = Data()
        for entry in cache {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func ensureFileExists() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    /// Corrupt lines are skipped rather than poisoning the whole file.
    private static func loadEntries(from url: URL) -> [AuditEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(AuditEntry.self, from: $0)
        }
    }
}
