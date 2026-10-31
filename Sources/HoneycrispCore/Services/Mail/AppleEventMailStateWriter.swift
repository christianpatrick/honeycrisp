import AppKit
import Foundation

/// Changes message state with raw in-process Apple events: set read status
/// (isrd) or flagged status (isfl), or send Mail's delete command, which
/// moves the message to its Trash. Each message is addressed in its own
/// account and mailbox through MailEvents, never through the unified inbox,
/// which timed out on big inboxes and matched nothing outside an inbox
/// (GH-18). A change counts only once Mail reads it back, because the old
/// whose clause that matched nothing was not an error to Mail, and a read
/// back is the only proof the change landed. Mail updates its
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
            try Self.stopping(with: confirmed) {
                guard let message = MailEvents.message(mailTarget, among: accounts) else { return }
                if let read, try !Self.set("isrd", to: read, of: message, target: target) { return }
                if let flagged, try !Self.set("isfl", to: flagged, of: message, target: target) {
                    return
                }
                confirmed.append(mailTarget.messageID)
            }
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
                try Self.stopping(with: confirmed, { try Self.matches(message, target: target) })
                    == 1
            else { continue }
            let event = MailEvents.event("core", "delo", target: target)
            event.setParam(message, forKeyword: MailEvents.code("----"))
            guard try Self.stopping(with: confirmed, { try Self.sent(event) }) else { continue }
            if try await Self.isGone(message, target: target, confirmed: confirmed) {
                confirmed.append(mailTarget.messageID)
            }
        }
        return confirmed
    }

    /// name of every mailbox of trash mailbox: the application's Trash holds
    /// one mailbox per account, named the way Mail addresses it.
    public func trashMailboxNames() async throws -> [String] {
        try await MailEvents.ensureMailIsRunning()
        let target = MailEvents.mailTarget()
        guard let trash = MailEvents.property("trmb", of: NSAppleEventDescriptor.null()),
            let mailboxes = MailEvents.every("mbxp", of: trash)
        else { return [] }
        guard let value = try Self.attempt({ try MailEvents.get("pnam", from: mailboxes, target: target) })
        else { return [] }
        return MailEvents.items(of: value).compactMap(\.stringValue).filter { !$0.isEmpty }
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
        guard try sent(event) else { return false }
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
    /// their ids. Mail answers a message that is not there with no such
    /// object (-1728, or -1719 for a bad index), which is zero. nil when
    /// Mail gave no answer at all, which is never read as zero.
    private static func matches(_ message: NSAppleEventDescriptor, target: NSAppleEventDescriptor)
        throws -> Int?
    {
        do {
            guard let value = try MailEvents.get("ID  ", from: message, target: target) else {
                return nil
            }
            return MailEvents.items(of: value).count
        } catch let failure as ToolFailure {
            throw failure
        } catch let error as NSError where error.code == -1712 {
            throw ToolFailure(timedOut)
        } catch let error as NSError where error.code == -1728 || error.code == -1719 {
            return 0
        } catch {
            return nil
        }
    }

    /// Mail moves a deleted message out of its mailbox as part of the
    /// command, but give it a moment before calling the delete unconfirmed.
    /// Only an answer of zero matches counts as gone.
    private static func isGone(
        _ message: NSAppleEventDescriptor, target: NSAppleEventDescriptor, confirmed: [String]
    ) async throws -> Bool {
        for attempt in 0..<10 {
            if try stopping(with: confirmed, { try matches(message, target: target) }) == 0 {
                return true
            }
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

    /// Whether Mail took the event without an error.
    private static func sent(_ event: NSAppleEventDescriptor) throws -> Bool {
        do {
            _ = try MailEvents.send(event)
            return true
        } catch let error as NSError where error.code == -1712 {
            throw ToolFailure(timedOut)
        } catch let failure as ToolFailure {
            throw failure
        } catch {
            return false
        }
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

    /// Runs one step of a batch. A failure the user has to act on stops
    /// the batch, carrying what Mail had already confirmed.
    private static func stopping<T>(with confirmed: [String], _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let failure as ToolFailure {
            throw MailWriteStopped(confirmed: confirmed, reason: failure.message)
        }
    }
}
