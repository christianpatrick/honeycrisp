import AppKit
import Foundation

/// Raw Apple event plumbing shared by the body fetcher (GH-12) and the
/// state writer (GH-18): object specifiers built from Mail.sdef codes, the
/// enabled account list, and addressing a message in its own account and
/// mailbox from its Envelope Index mailbox url. Codes: account mact with id
/// "ID  ", user name unme, server name host, and enabled isac; mailbox mbxp
/// by name; message mssg by id "ID  ". No osascript, no AppleScript
/// source. Only an Automation block is translated here; every other Apple
/// event error reaches the caller as is, because the fetcher and the writer
/// treat them differently.
enum MailEvents {
    static let mailBundleID = "com.apple.mail"
    static let automationBlocked =
        "macOS is blocking Honeycrisp from driving Mail. Grant Automation access in System Settings under Privacy & Security, Automation, then try again."

    static func mailTarget() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(bundleIdentifier: mailBundleID)
    }

    // MARK: - Accounts

    /// The id, user name, and server name of every enabled account: three
    /// gets over the same whose clause, so the lists line up. A disabled
    /// account cannot do anything, so it never matches. The ids are the
    /// point; a failed user name or server name get leaves those empty
    /// instead of losing every account, since most urls match on the id.
    static func enabledAccounts(target: NSAppleEventDescriptor) throws -> [MailAccountRecord] {
        guard
            let enabled = comparison(
                property: "isac", equals: NSAppleEventDescriptor(boolean: true)),
            let accounts = specifier(
                want: "mact", from: NSAppleEventDescriptor.null(), form: "test", seld: enabled)
        else { return [] }
        let ids = try strings(of: "ID  ", from: accounts, target: target)
        let users = try optionalStrings(of: "unme", from: accounts, target: target)
        let servers = try optionalStrings(of: "host", from: accounts, target: target)
        return ids.indices.map { index in
            MailAccountRecord(
                id: ids[index],
                userName: index < users.count ? users[index] : "",
                serverName: index < servers.count ? servers[index] : "")
        }
    }

    // MARK: - Targeting

    /// message id N of mailbox "<path>" of account id "<uuid>", or
    /// of the application for a mailbox On My Mac. nil when the url does not
    /// parse, the id is not one Mail can hold, or no enabled account matches.
    static func message(_ target: MailTarget, among accounts: [MailAccountRecord])
        -> NSAppleEventDescriptor?
    {
        guard let location = MailboxLocation(url: target.mailboxURL),
            let id = Int32(target.messageID)
        else { return nil }
        var account: NSAppleEventDescriptor?
        if !location.isLocal {
            guard let accountID = location.accountID(among: accounts),
                let specifier = self.account(id: accountID)
            else { return nil }
            account = specifier
        }
        guard let mailbox = mailbox(named: location.path, in: account) else { return nil }
        return message(id: id, in: mailbox)
    }

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

    /// message id N of <mailbox>. Mail looks the id up directly instead of
    /// testing every message the way "whose id = N" does, which took
    /// seconds on a big Archive (GH-18).
    private static func message(id: Int32, in mailbox: NSAppleEventDescriptor)
        -> NSAppleEventDescriptor?
    {
        specifier(
            want: "mssg", from: mailbox, form: "ID  ", seld: NSAppleEventDescriptor(int32: id))
    }

    static func specifier(
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

    /// every <class> of <container>: the absolute ordinal all.
    static func every(_ className: String, of container: NSAppleEventDescriptor)
        -> NSAppleEventDescriptor?
    {
        var all = code("all ")
        guard let ordinal = NSAppleEventDescriptor(
            descriptorType: code("abso"), bytes: &all, length: MemoryLayout<FourCharCode>.size)
        else { return nil }
        return specifier(want: className, from: container, form: "indx", seld: ordinal)
    }

    static func property(_ name: String, of container: NSAppleEventDescriptor)
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

    /// core/getd of <property> of <container>: the reply's direct object.
    static func get(
        _ name: String, from container: NSAppleEventDescriptor, target: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor? {
        guard let specifier = property(name, of: container) else { return nil }
        let event = event("core", "getd", target: target)
        event.setParam(specifier, forKeyword: code("----"))
        return try send(event)
    }

    static func event(_ eventClass: String, _ eventID: String, target: NSAppleEventDescriptor)
        -> NSAppleEventDescriptor
    {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: code(eventClass),
            eventID: code(eventID),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    /// Sends with a 20 second timeout and returns the reply's direct object.
    static func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: 20)
            return reply.paramDescriptor(forKeyword: code("----"))
        } catch let error as NSError where error.code == -1743 {
            throw ToolFailure(automationBlocked)
        }
    }

    private static func strings(
        of name: String, from container: NSAppleEventDescriptor, target: NSAppleEventDescriptor
    ) throws -> [String] {
        guard let value = try get(name, from: container, target: target) else { return [] }
        return items(of: value).compactMap(\.stringValue)
    }

    /// strings(of:), except that any error but an Automation block is an
    /// empty list.
    private static func optionalStrings(
        of name: String, from container: NSAppleEventDescriptor, target: NSAppleEventDescriptor
    ) throws -> [String] {
        do {
            return try strings(of: name, from: container, target: target)
        } catch let failure as ToolFailure {
            throw failure
        } catch {
            return []
        }
    }

    /// A whose clause answers with a list even for one match, so unwrap
    /// lists and treat a single value as a list of one.
    static func items(of value: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard value.descriptorType == code("list") else { return [value] }
        guard value.numberOfItems > 0 else { return [] }
        return (1...value.numberOfItems).compactMap { value.atIndex($0) }
    }

    static func code(_ four: String) -> FourCharCode {
        var result: FourCharCode = 0
        for byte in four.utf8 {
            result = (result << 8) | FourCharCode(byte)
        }
        return result
    }

    static func ensureMailIsRunning() async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: mailBundleID)
        guard running.isEmpty else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mailBundleID)
        else {
            throw ToolFailure("Mail is not installed on this Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
