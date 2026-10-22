import AppKit
import Foundation

/// Asks Mail for the raw source of messages whose body is not on disk yet
/// (GH-12). Mail downloads each message from its server to answer and keeps
/// the body in its own store through its own path; Honeycrisp writes
/// nothing. This is the one Apple event read in the toolset, recorded in
/// AGENTS.md tier 3. Codes come from Mail.sdef: account mact with id
/// "ID  ", user name unme, server name host, and enabled isac; mailbox
/// mbxp by name; message mssg whose id "ID  " = N; source raso. No
/// osascript, no AppleScript source.
public struct AppleEventMailBodyFetcher: MailBodyFetching {
    private static let mailBundleID = "com.apple.mail"
    private static let automationBlocked =
        "macOS is blocking Honeycrisp from driving Mail. Grant Automation access in System Settings under Privacy & Security, Automation, then try again."

    public init() {}

    public func sources(for missing: [MissingBody]) async throws -> [String: Data] {
        guard !missing.isEmpty else { return [:] }
        try await ensureMailIsRunning()
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.mailBundleID)
        let accounts = try Self.enabledAccounts(target: target)
        var found: [String: Data] = [:]
        for body in missing {
            guard let location = MailboxLocation(url: body.mailboxURL),
                let messageID = Int32(body.messageID)
            else { continue }
            var account: NSAppleEventDescriptor?
            if !location.isLocal {
                guard let accountID = location.accountID(among: accounts),
                    let specifier = Self.account(id: accountID)
                else { continue }
                account = specifier
            }
            guard
                let mailbox = Self.mailbox(named: location.path, in: account),
                let message = Self.message(id: messageID, in: mailbox),
                let source = try Self.text(of: "raso", from: message, target: target),
                !source.isEmpty
            else { continue }
            found[body.messageID] = Data(source.utf8)
        }
        return found
    }

    // MARK: - Accounts

    /// The id, user name, and server name of every enabled account: three
    /// gets over the same whose clause, so the lists line up. A disabled
    /// account cannot download anything, so it never matches.
    private static func enabledAccounts(target: NSAppleEventDescriptor) throws
        -> [MailAccountRecord]
    {
        guard
            let enabled = comparison(
                property: "isac", equals: NSAppleEventDescriptor(boolean: true)),
            let accounts = specifier(
                want: "mact", from: NSAppleEventDescriptor.null(), form: "test", seld: enabled)
        else { return [] }
        let ids = try strings(of: "ID  ", from: accounts, target: target)
        let users = try strings(of: "unme", from: accounts, target: target)
        let servers = try strings(of: "host", from: accounts, target: target)
        return ids.indices.map { index in
            MailAccountRecord(
                id: ids[index],
                userName: index < users.count ? users[index] : "",
                serverName: index < servers.count ? servers[index] : "")
        }
    }

    // MARK: - Targeting

    /// account id "<uuid>"
    private static func account(id: String) -> NSAppleEventDescriptor? {
        specifier(
            want: "mact", from: NSAppleEventDescriptor.null(), form: "ID  ",
            seld: NSAppleEventDescriptor(string: id))
    }

    /// mailbox "<path>" of <account>, or of the application for a mailbox
    /// On My Mac. Mail resolves nested mailboxes from a slash path.
    private static func mailbox(named path: String, in account: NSAppleEventDescriptor?)
        -> NSAppleEventDescriptor?
    {
        specifier(
            want: "mbxp", from: account ?? NSAppleEventDescriptor.null(), form: "name",
            seld: NSAppleEventDescriptor(string: path))
    }

    /// message of <mailbox> whose id = N, the HC-021 test.
    private static func message(id: Int32, in mailbox: NSAppleEventDescriptor)
        -> NSAppleEventDescriptor?
    {
        guard let test = comparison(property: "ID  ", equals: NSAppleEventDescriptor(int32: id))
        else { return nil }
        return specifier(want: "mssg", from: mailbox, form: "test", seld: test)
    }

    private static func specifier(
        want: String, from container: NSAppleEventDescriptor, form: String,
        seld: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor? {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        record.setDescriptor(container, forKeyword: code("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        record.setDescriptor(seld, forKeyword: code("seld"))
        return record.coerce(toDescriptorType: code("obj "))
    }

    private static func property(_ name: String, of container: NSAppleEventDescriptor)
        -> NSAppleEventDescriptor?
    {
        specifier(
            want: "prop", from: container, form: "prop",
            seld: NSAppleEventDescriptor(typeCode: code(name)))
    }

    /// its <property> = value, the whose-clause test.
    private static func comparison(property name: String, equals value: NSAppleEventDescriptor)
        -> NSAppleEventDescriptor?
    {
        guard let examined = NSAppleEventDescriptor(descriptorType: code("exmn"), data: Data()),
            let subject = property(name, of: examined)
        else { return nil }
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code("=   ")), forKeyword: code("relo"))
        record.setDescriptor(subject, forKeyword: code("obj1"))
        record.setDescriptor(value, forKeyword: code("obj2"))
        return record.coerce(toDescriptorType: code("cmpd"))
    }

    // MARK: - Events

    /// core/getd of <property> of <container>. Returns the reply's direct
    /// object, or nil when Mail had nothing to give (no such object, a
    /// timeout, an empty answer). Only an Automation block throws, because
    /// that is the failure the user can fix.
    private static func get(
        _ name: String, from container: NSAppleEventDescriptor, target: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor? {
        guard let specifier = property(name, of: container) else { return nil }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code("core"),
            eventID: code("getd"),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(specifier, forKeyword: code("----"))
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: 20)
            return reply.paramDescriptor(forKeyword: code("----"))
        } catch let error as NSError where error.code == -1743 {
            throw ToolFailure(automationBlocked)
        } catch {
            return nil
        }
    }

    private static func strings(
        of name: String, from container: NSAppleEventDescriptor, target: NSAppleEventDescriptor
    ) throws -> [String] {
        guard let value = try get(name, from: container, target: target) else { return [] }
        return items(of: value).compactMap(\.stringValue)
    }

    private static func text(
        of name: String, from container: NSAppleEventDescriptor, target: NSAppleEventDescriptor
    ) throws -> String? {
        guard let value = try get(name, from: container, target: target) else { return nil }
        return items(of: value).first?.stringValue
    }

    /// A whose clause answers with a list even for one match, so unwrap
    /// lists and treat a single value as a list of one.
    private static func items(of value: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard value.descriptorType == code("list") else { return [value] }
        guard value.numberOfItems > 0 else { return [] }
        return (1...value.numberOfItems).compactMap { value.atIndex($0) }
    }

    private static func code(_ four: String) -> FourCharCode {
        var result: FourCharCode = 0
        for byte in four.utf8 {
            result = (result << 8) | FourCharCode(byte)
        }
        return result
    }

    private func ensureMailIsRunning() async throws {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.mailBundleID)
        guard running.isEmpty else { return }
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: Self.mailBundleID)
        else {
            throw ToolFailure("Mail is not installed on this Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
