import Foundation

/// One Mail message in search results.
public struct MailMessageSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let threadId: String
    public let subject: String
    public let from: String
    public let fromName: String?
    public let date: Date
    public let mailbox: String
    public let read: Bool

    public init(
        id: String, threadId: String, subject: String, from: String, fromName: String?,
        date: Date, mailbox: String, read: Bool
    ) {
        self.id = id
        self.threadId = threadId
        self.subject = subject
        self.from = from
        self.fromName = fromName
        self.date = date
        self.mailbox = mailbox
        self.read = read
    }
}

/// One message inside a thread, body included.
public struct MailMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let from: String
    public let fromName: String?
    public let to: [String]
    public let date: Date
    public let body: String

    public init(id: String, from: String, fromName: String?, to: [String], date: Date, body: String) {
        self.id = id
        self.from = from
        self.fromName = fromName
        self.to = to
        self.date = date
        self.body = body
    }
}

/// A whole conversation, oldest message first.
public struct MailThread: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let subject: String
    public let participants: [String]
    public let messages: [MailMessage]

    public init(id: String, subject: String, participants: [String], messages: [MailMessage]) {
        self.id = id
        self.subject = subject
        self.participants = participants
        self.messages = messages
    }
}

/// A fully resolved outgoing mail, after reply resolution.
public struct MailDraft: Equatable, Sendable {
    public let to: [String]
    public let cc: [String]
    public let subject: String?
    public let body: String

    public init(to: [String], cc: [String], subject: String?, body: String) {
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
    }
}

/// What compose reports back; sent distinguishes a send from a saved draft.
public struct MailComposeReceipt: Codable, Equatable, Sendable {
    public let to: [String]
    public let cc: [String]
    public let subject: String?
    public let sent: Bool

    public init(to: [String], cc: [String], subject: String?, sent: Bool) {
        self.to = to
        self.cc = cc
        self.subject = subject
        self.sent = sent
    }
}

/// The Mail domain seam the translator talks to.
public protocol MailServicing: Sendable {
    func search(query: String, mailbox: String?, limit: Int) async throws -> [MailMessageSummary]
    func thread(id: String, limit: Int) async throws -> MailThread
    /// For reply resolution: who sent this message, and what was it called.
    func messageSummary(id: String) async throws -> MailMessageSummary?
    func draft(_ draft: MailDraft) async throws -> MailComposeReceipt
    func send(_ draft: MailDraft) async throws -> MailComposeReceipt
}

/// Sub-seams: the read side over the Envelope Index, and the compose side
/// over Apple events.
public protocol EnvelopeIndexReading: Sendable {
    func search(query: String, mailbox: String?, limit: Int) async throws -> [MailMessageSummary]
    func thread(id: String, limit: Int) async throws -> MailThread
    func messageSummary(id: String) async throws -> MailMessageSummary?
}

public protocol MailComposing: Sendable {
    func compose(_ draft: MailDraft, send: Bool) async throws -> MailComposeReceipt
}

/// The real composition: Envelope Index plus .emlx for reads, raw Apple
/// events for drafts and sends.
public struct MailService: MailServicing {
    private let reader: any EnvelopeIndexReading
    private let composer: any MailComposing

    public init(reader: any EnvelopeIndexReading, composer: any MailComposing) {
        self.reader = reader
        self.composer = composer
    }

    /// The production wiring.
    public init() {
        self.init(reader: MailDatabase(), composer: AppleEventMailComposer())
    }

    public func search(query: String, mailbox: String?, limit: Int) async throws
        -> [MailMessageSummary]
    {
        try await reader.search(query: query, mailbox: mailbox, limit: limit)
    }

    public func thread(id: String, limit: Int) async throws -> MailThread {
        try await reader.thread(id: id, limit: limit)
    }

    public func messageSummary(id: String) async throws -> MailMessageSummary? {
        try await reader.messageSummary(id: id)
    }

    public func draft(_ draft: MailDraft) async throws -> MailComposeReceipt {
        try await composer.compose(draft, send: false)
    }

    public func send(_ draft: MailDraft) async throws -> MailComposeReceipt {
        try await composer.compose(draft, send: true)
    }
}
