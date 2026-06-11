import Foundation

/// One Messages conversation as the model sees it.
public struct Conversation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isGroup: Bool
    public let participants: [String]
    public let lastMessage: String
    public let lastFromMe: Bool
    public let lastAt: Date
    public let unreadCount: Int

    public init(
        id: String, name: String, isGroup: Bool, participants: [String],
        lastMessage: String, lastFromMe: Bool, lastAt: Date, unreadCount: Int
    ) {
        self.id = id
        self.name = name
        self.isGroup = isGroup
        self.participants = participants
        self.lastMessage = lastMessage
        self.lastFromMe = lastFromMe
        self.lastAt = lastAt
        self.unreadCount = unreadCount
    }
}

/// One search match.
public struct MessageHit: Codable, Equatable, Sendable {
    public let conversation: String
    public let conversationId: String
    public let sender: String
    public let text: String
    public let at: Date

    public init(conversation: String, conversationId: String, sender: String, text: String, at: Date) {
        self.conversation = conversation
        self.conversationId = conversationId
        self.sender = sender
        self.text = text
        self.at = at
    }
}

/// What a completed send reports back.
public struct SendReceipt: Codable, Equatable, Sendable {
    public let recipient: String
    public let body: String
    public let conversation: String

    public init(recipient: String, body: String, conversation: String) {
        self.recipient = recipient
        self.body = body
        self.conversation = conversation
    }
}

/// What mark_read reports back: whether Messages was driven, and whether the
/// unread count was confirmed to reach zero afterward.
public struct MarkReadResult: Codable, Equatable, Sendable {
    public let markedRead: Bool
    public let confirmed: Bool

    public init(markedRead: Bool, confirmed: Bool) {
        self.markedRead = markedRead
        self.confirmed = confirmed
    }
}

/// A resolved conversation for sending or marking read.
public struct ChatTarget: Sendable, Equatable {
    public let guid: String
    /// The handle for 1:1 chats, the chat identifier for groups.
    public let identifier: String
    public let displayName: String?
    public let isGroup: Bool

    public init(guid: String, identifier: String, displayName: String?, isGroup: Bool) {
        self.guid = guid
        self.identifier = identifier
        self.displayName = displayName
        self.isGroup = isGroup
    }
}

/// The Messages domain seam the translator talks to.
public protocol MessagesServicing: Sendable {
    func recent(limit: Int, since: Date?, unreadOnly: Bool) async throws -> [Conversation]
    func search(query: String?, contact: String?, since: Date?, until: Date?, limit: Int)
        async throws -> [MessageHit]
    func history(conversation: String, since: Date?, limit: Int) async throws -> [MessageHit]
    func send(recipient: String, body: String) async throws -> SendReceipt
    func markRead(conversation: String) async throws -> MarkReadResult
}

/// Sub-seams, one per access mechanism, so each is fakeable on its own.
public protocol ChatDatabaseReading: Sendable {
    func recentConversations(limit: Int, since: Date?, unreadOnly: Bool) async throws
        -> [Conversation]
    func searchMessages(query: String?, contact: String?, since: Date?, until: Date?, limit: Int)
        async throws -> [MessageHit]
    func history(conversation: String, since: Date?, limit: Int) async throws -> [MessageHit]
    func conversationTarget(matching query: String) async throws -> ChatTarget?
    func unreadCount(chatGUID: String) async throws -> Int
}

public protocol MessageSending: Sendable {
    func send(recipient: String, body: String) async throws -> SendReceipt
}

public protocol ConversationMarkReading: Sendable {
    func markRead(conversation: String) async throws -> MarkReadResult
}

/// The real composition: chat.db for reads, one Apple event for sends, and
/// the URL-scheme driver for mark read.
public struct MessagesService: MessagesServicing {
    private let reader: any ChatDatabaseReading
    private let sender: any MessageSending
    private let marker: any ConversationMarkReading

    public init(
        reader: any ChatDatabaseReading,
        sender: any MessageSending,
        marker: any ConversationMarkReading
    ) {
        self.reader = reader
        self.sender = sender
        self.marker = marker
    }

    /// The production wiring.
    public init() {
        let reader = ChatDatabase()
        self.init(
            reader: reader,
            sender: AppleEventMessageSender(targets: reader),
            marker: MessagesMarkReadDriver(reader: reader)
        )
    }

    public func recent(limit: Int, since: Date?, unreadOnly: Bool) async throws -> [Conversation]
    {
        try await reader.recentConversations(limit: limit, since: since, unreadOnly: unreadOnly)
    }

    public func search(query: String?, contact: String?, since: Date?, until: Date?, limit: Int)
        async throws -> [MessageHit]
    {
        try await reader.searchMessages(
            query: query, contact: contact, since: since, until: until, limit: limit)
    }

    public func history(conversation: String, since: Date?, limit: Int) async throws
        -> [MessageHit]
    {
        try await reader.history(conversation: conversation, since: since, limit: limit)
    }

    public func send(recipient: String, body: String) async throws -> SendReceipt {
        try await sender.send(recipient: recipient, body: body)
    }

    public func markRead(conversation: String) async throws -> MarkReadResult {
        try await marker.markRead(conversation: conversation)
    }
}
