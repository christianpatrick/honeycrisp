import AppKit
import Foundation

/// Changes message state with raw in-process Apple events: set read status
/// (isrd) or flagged status (isfl), or send Mail's delete command, which
/// moves the message to its Trash. Each message is addressed in its own
/// account and mailbox through MailEvents, never through the unified inbox,
/// which timed out on big inboxes and matched nothing outside an inbox
/// (GH-18). A change counts only once Mail reads it back, because a whose
/// clause that matches nothing is not an error to Mail. Mail updates its
/// own store and syncs upstream; we never touch the Envelope Index. Grown
/// from the HC-021 read marker for HC-041.
public struct AppleEventMailStateWriter: MailStateWriting {
    private static let timedOut =
        "Mail took too long to answer. It may be busy syncing; try again in a moment."

    public init() {}

    public func setState(_ targets: [MailTarget], read: Bool?, flagged: Bool?) async throws
        -> [String]
    {
        guard read != nil || flagged != nil, !targets.isEmpty else { return [] }
        try await MailEvents.ensureMailIsRunning()
        let target = MailEvents.mailTarget()
        let accounts = try Self.accounts(for: targets, target: target)
        var confirmed: [String] = []
        for mailTarget in targets {
            guard let message = MailEvents.message(mailTarget, among: accounts) else { continue }
            if let read, try !Self.set("isrd", to: read, of: message, target: target) { continue }
            if let flagged, try !Self.set("isfl", to: flagged, of: message, target: target) {
                continue
            }
            confirmed.append(mailTarget.messageID)
        }
        return confirmed
    }

    public func delete(_ targets: [MailTarget]) async throws -> [String] {
        guard !targets.isEmpty else { return [] }
        try await MailEvents.ensureMailIsRunning()
        let target = MailEvents.mailTarget()
        let accounts = try Self.accounts(for: targets, target: target)
        var confirmed: [String] = []
        for mailTarget in targets {
            guard let message = MailEvents.message(mailTarget, among: accounts),
                try Self.matches(message, target: target) == 1
            else { continue }
            let event = MailEvents.event("core", "delo", target: target)
            event.setParam(message, forKeyword: MailEvents.code("----"))
            _ = try Self.attempt { try MailEvents.send(event) }
            if try await Self.isGone(message, target: target) {
                confirmed.append(mailTarget.messageID)
            }
        }
        return confirmed
    }

    /// Reads flagged status back through the same targeting, so the
    /// integration tests can verify a toggle and restore the message's
    /// real prior state instead of guessing it. nil when Mail cannot find
    /// the message.
    func flaggedStatus(of mailTarget: MailTarget) async throws -> Bool? {
        try await MailEvents.ensureMailIsRunning()
        let target = MailEvents.mailTarget()
        let accounts = try Self.accounts(for: [mailTarget], target: target)
        guard let message = MailEvents.message(mailTarget, among: accounts) else { return nil }
        return try Self.bool("isfl", of: message, target: target)
    }

    // MARK: - Events

    /// core/setd on <property> of the message, then core/getd on the same
    /// property. True only when Mail answers with exactly one message
    /// holding the asked value.
    private static func set(
        _ name: String, to value: Bool, of message: NSAppleEventDescriptor,
        target: NSAppleEventDescriptor
    ) throws -> Bool {
        guard let property = MailEvents.property(name, of: message) else { return false }
        let event = MailEvents.event("core", "setd", target: target)
        event.setParam(property, forKeyword: MailEvents.code("----"))
        event.setParam(NSAppleEventDescriptor(boolean: value), forKeyword: MailEvents.code("data"))
        _ = try attempt { try MailEvents.send(event) }
        return try bool(name, of: message, target: target) == value
    }

    private static func bool(
        _ name: String, of message: NSAppleEventDescriptor, target: NSAppleEventDescriptor
    ) throws -> Bool? {
        guard let value = try attempt({ try MailEvents.get(name, from: message, target: target) })
        else { return nil }
        let items = MailEvents.items(of: value)
        guard items.count == 1 else { return nil }
        return items[0].booleanValue
    }

    /// How many messages the specifier matches right now, by asking for
    /// their ids. A whose clause with no match answers with an empty list.
    private static func matches(_ message: NSAppleEventDescriptor, target: NSAppleEventDescriptor)
        throws -> Int
    {
        guard let value = try attempt({ try MailEvents.get("ID  ", from: message, target: target) })
        else { return 0 }
        return MailEvents.items(of: value).count
    }

    /// Mail moves a deleted message out of its mailbox as part of the
    /// command, but give it a moment before calling the delete unconfirmed.
    private static func isGone(_ message: NSAppleEventDescriptor, target: NSAppleEventDescriptor)
        async throws -> Bool
    {
        for attempt in 0..<10 {
            if try matches(message, target: target) == 0 { return true }
            if attempt < 9 { try await Task.sleep(for: .milliseconds(200)) }
        }
        return false
    }

    /// The accounts Mail has enabled, asked for only when a target lives in
    /// an account rather than On My Mac.
    private static func accounts(for targets: [MailTarget], target: NSAppleEventDescriptor)
        throws -> [MailAccountRecord]
    {
        let needsAccount = targets.contains {
            MailboxLocation(url: $0.mailboxURL)?.isLocal == false
        }
        guard needsAccount else { return [] }
        return try attempt { try MailEvents.enabledAccounts(target: target) } ?? []
    }

    /// One exchange with Mail for a write. An Automation block and a
    /// timeout become sentences the user can act on. Any other Mail error,
    /// like no such message, is nil: the change is unconfirmed, and the
    /// service says so.
    private static func attempt<T>(_ body: () throws -> T?) throws -> T? {
        do {
            return try body()
        } catch let failure as ToolFailure {
            throw failure
        } catch let error as NSError where error.code == -1712 {
            throw ToolFailure(timedOut)
        } catch {
            return nil
        }
    }
}
