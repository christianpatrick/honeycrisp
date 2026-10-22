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
    /// The message:// link that opens it in Mail on the Mac and on iPhone
    /// and iPad (GH-12). Absent when the index has no Message-ID for it.
    public let link: String?

    public init(
        id: String, threadId: String, subject: String, from: String, fromName: String?,
        date: Date, mailbox: String, read: Bool, link: String? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.subject = subject
        self.from = from
        self.fromName = fromName
        self.date = date
        self.mailbox = mailbox
        self.read = read
        self.link = link
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
    /// The message:// link, as on MailMessageSummary.
    public let link: String?

    public init(
        id: String, from: String, fromName: String?, to: [String], date: Date, body: String,
        link: String? = nil
    ) {
        self.id = id
        self.from = from
        self.fromName = fromName
        self.to = to
        self.date = date
        self.body = body
        self.link = link
    }

    func withBody(_ body: String) -> MailMessage {
        MailMessage(
            id: id, from: from, fromName: fromName, to: to, date: date, body: body, link: link)
    }
}

/// A message whose body was not on disk, with the mailbox url Mail needs
/// to find it for a download (GH-12).
public struct MissingBody: Equatable, Sendable {
    public let messageID: String
    public let mailboxURL: String

    public init(messageID: String, mailboxURL: String) {
        self.messageID = messageID
        self.mailboxURL = mailboxURL
    }
}

/// A whole conversation, oldest message first.
public struct MailThread: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let subject: String
    public let participants: [String]
    public let messages: [MailMessage]
    /// Messages whose body is still not on this Mac. Kept out of the JSON.
    public private(set) var missingBodies: [MissingBody] = []
    /// How many bodies Mail downloaded for this read, for the audit copy.
    /// Kept out of the JSON.
    public private(set) var downloadedBodies = 0

    private enum CodingKeys: String, CodingKey {
        case id, subject, participants, messages
    }

    public init(
        id: String, subject: String, participants: [String], messages: [MailMessage],
        missingBodies: [MissingBody] = [], downloadedBodies: Int = 0
    ) {
        self.id = id
        self.subject = subject
        self.participants = participants
        self.messages = messages
        self.missingBodies = missingBodies
        self.downloadedBodies = downloadedBodies
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
    func search(
        query: String?, mailbox: String?, from: String?, to: String?,
        since: Date?, until: Date?, unreadOnly: Bool, limit: Int
    ) async throws -> [MailMessageSummary]
    func mailboxes() async throws -> [String]
    /// The thread for reading, with any body Mail has not downloaded yet
    /// fetched from Mail (GH-12).
    func thread(id: String, limit: Int) async throws -> MailThread
    /// The thread as the Envelope Index knows it, with no fetch, for
    /// resolving a thread_id to the message ids a write targets.
    func indexedThread(id: String, limit: Int) async throws -> MailThread
    /// For reply resolution: who sent this message, and what was it called.
    func messageSummary(id: String) async throws -> MailMessageSummary?
    func draft(_ draft: MailDraft) async throws -> MailComposeReceipt
    func send(_ draft: MailDraft) async throws -> MailComposeReceipt
    /// Returns how many messages were marked.
    func markRead(messageIDs: [String]) async throws -> Int
    /// Sets read or flagged state (HC-041); returns how many changed.
    func setState(messageIDs: [String], read: Bool?, flagged: Bool?) async throws -> Int
    /// Moves messages to Mail's Trash; returns how many moved.
    func delete(messageIDs: [String]) async throws -> Int
}

extension MailServicing {
    public func indexedThread(id: String, limit: Int) async throws -> MailThread {
        try await thread(id: id, limit: limit)
    }
}

/// Sub-seams: the read side over the Envelope Index, and the compose side
/// over Apple events.
public protocol EnvelopeIndexReading: Sendable {
    func search(
        query: String?, mailbox: String?, from: String?, to: String?,
        since: Date?, until: Date?, unreadOnly: Bool, limit: Int
    ) async throws -> [MailMessageSummary]
    func mailboxes() async throws -> [String]
    func thread(id: String, limit: Int) async throws -> MailThread
    func messageSummary(id: String) async throws -> MailMessageSummary?
}

public protocol MailComposing: Sendable {
    func compose(_ draft: MailDraft, send: Bool) async throws -> MailComposeReceipt
}

public protocol MailStateWriting: Sendable {
    func setState(messageIDs: [String], read: Bool?, flagged: Bool?) async throws -> Int
    func delete(messageIDs: [String]) async throws -> Int
}

/// Asks Mail for message sources it has not downloaded yet (GH-12), the
/// one Apple event read. Returns raw RFC822 keyed by message id for every
/// message Mail handed over, and throws only when macOS blocks Automation.
public protocol MailBodyFetching: Sendable {
    func sources(for missing: [MissingBody]) async throws -> [String: Data]
}

/// The real composition: Envelope Index plus .emlx for reads, a Mail fetch
/// for bodies that are not on disk, raw Apple events for drafts and sends.
public struct MailService: MailServicing {
    private let reader: any EnvelopeIndexReading
    private let composer: any MailComposing
    private let marker: any MailStateWriting
    private let fetcher: any MailBodyFetching

    public init(
        reader: any EnvelopeIndexReading,
        composer: any MailComposing,
        marker: any MailStateWriting,
        fetcher: any MailBodyFetching
    ) {
        self.reader = reader
        self.composer = composer
        self.marker = marker
        self.fetcher = fetcher
    }

    /// The production wiring.
    public init() {
        self.init(
            reader: MailDatabase(),
            composer: AppleEventMailComposer(),
            marker: AppleEventMailStateWriter(),
            fetcher: AppleEventMailBodyFetcher()
        )
    }

    public func search(
        query: String?, mailbox: String?, from: String?, to: String?,
        since: Date?, until: Date?, unreadOnly: Bool, limit: Int
    ) async throws -> [MailMessageSummary] {
        try await reader.search(
            query: query, mailbox: mailbox, from: from, to: to,
            since: since, until: until, unreadOnly: unreadOnly, limit: limit)
    }

    public func mailboxes() async throws -> [String] {
        try await reader.mailboxes()
    }

    /// Bodies on disk come straight from the index read. The rest go to
    /// Mail in one batch, and anything Mail does not hand over keeps its
    /// placeholder: a failed fetch never fails the thread. An Automation
    /// block is the one failure worth telling the reader about, because
    /// they can fix it.
    public func thread(id: String, limit: Int) async throws -> MailThread {
        let thread = try await reader.thread(id: id, limit: limit)
        guard !thread.missingBodies.isEmpty else { return thread }

        var fetched: [String: String] = [:]
        var blocked: String?
        do {
            let sources = try await fetcher.sources(for: thread.missingBodies)
            for (messageID, source) in sources {
                if let body = MimeText.bodyText(fromRFC822: source), !body.isEmpty {
                    fetched[messageID] = body
                }
            }
        } catch let failure as ToolFailure {
            blocked = failure.message
        } catch {
            // Mail could not be reached; the placeholders stand.
        }

        let missing = Set(thread.missingBodies.map(\.messageID))
        let messages = thread.messages.map { (message: MailMessage) -> MailMessage in
            if let body = fetched[message.id] { return message.withBody(body) }
            if let blocked, missing.contains(message.id) {
                return message.withBody("(body unavailable) \(blocked)")
            }
            return message
        }
        return MailThread(
            id: thread.id,
            subject: thread.subject,
            participants: thread.participants,
            messages: messages,
            missingBodies: thread.missingBodies.filter { fetched[$0.messageID] == nil },
            downloadedBodies: fetched.count
        )
    }

    public func indexedThread(id: String, limit: Int) async throws -> MailThread {
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

    public func markRead(messageIDs: [String]) async throws -> Int {
        try await marker.setState(messageIDs: messageIDs, read: true, flagged: nil)
    }

    public func setState(messageIDs: [String], read: Bool?, flagged: Bool?) async throws -> Int {
        try await marker.setState(messageIDs: messageIDs, read: read, flagged: flagged)
    }

    public func delete(messageIDs: [String]) async throws -> Int {
        try await marker.delete(messageIDs: messageIDs)
    }
}
