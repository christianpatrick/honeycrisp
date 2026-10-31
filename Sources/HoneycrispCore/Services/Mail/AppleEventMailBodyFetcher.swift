import AppKit
import Foundation

/// Asks Mail for the raw source of messages whose body is not on disk yet
/// (GH-12). Mail downloads each message from its server to answer and keeps
/// the body in its own store through its own path; Honeycrisp writes
/// nothing. This is the one Apple event read in the toolset, recorded in
/// AGENTS.md tier 3. Each message is addressed in its own account and
/// mailbox through MailEvents; the source property is raso in Mail.sdef.
public struct AppleEventMailBodyFetcher: MailBodyFetching {
    public init() {}

    public func sources(for missing: [MissingBody]) async throws -> [String: Data] {
        guard !missing.isEmpty else { return [:] }
        try await MailEvents.ensureMailIsRunning()
        let target = MailEvents.mailTarget()
        let accounts = try Self.lenient { try MailEvents.enabledAccounts(target: target) } ?? []
        var found: [String: Data] = [:]
        for body in missing {
            let location = MailTarget(messageID: body.messageID, mailboxURL: body.mailboxURL)
            guard let message = MailEvents.message(location, among: accounts),
                let value = try Self.lenient({ try MailEvents.get("raso", from: message, target: target) }),
                let source = MailEvents.items(of: value).first?.stringValue,
                !source.isEmpty
            else { continue }
            found[body.messageID] = Data(source.utf8)
        }
        return found
    }

    /// A failed fetch is nil (no such object, a timeout, an empty answer).
    /// Only an Automation block throws, because that is the failure the
    /// user can fix.
    private static func lenient<T>(_ body: () throws -> T?) throws -> T? {
        do {
            return try body()
        } catch let failure as ToolFailure {
            throw failure
        } catch {
            return nil
        }
    }
}
