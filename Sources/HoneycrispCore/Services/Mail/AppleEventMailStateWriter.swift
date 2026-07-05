import AppKit
import Foundation

/// Changes message state with raw in-process Apple events: set read status
/// (isrd) or flagged status (isfl), or send Mail's delete command, which
/// moves the message to its Trash, on the inbox message whose id matches.
/// Mail updates its own store and syncs upstream; we never touch the
/// Envelope Index. Codes come from Mail.sdef: message mssg, application
/// inbox property inmb, id property "ID  ". No osascript, no AppleScript
/// source. Grown from the HC-021 read marker for HC-041.
public struct AppleEventMailStateWriter: MailStateWriting {
    private static let mailBundleID = "com.apple.mail"

    public init() {}

    public func setState(messageIDs: [String], read: Bool?, flagged: Bool?) async throws -> Int {
        guard read != nil || flagged != nil else { return 0 }
        try await ensureMailIsRunning()
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.mailBundleID)
        var changed = 0
        for raw in messageIDs {
            let id = try Self.numericID(raw)
            if let read {
                try Self.setBool(property: "isrd", to: read, messageID: id, target: target)
            }
            if let flagged {
                try Self.setBool(property: "isfl", to: flagged, messageID: id, target: target)
            }
            changed += 1
        }
        return changed
    }

    public func delete(messageIDs: [String]) async throws -> Int {
        try await ensureMailIsRunning()
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.mailBundleID)
        var deleted = 0
        for raw in messageIDs {
            let id = try Self.numericID(raw)
            try Self.deleteMessage(messageID: id, target: target)
            deleted += 1
        }
        return deleted
    }

    // MARK: - Events

    /// core/setd: set (<property> of (message of inbox whose id = N)).
    private static func setBool(
        property: String, to value: Bool, messageID: Int64, target: NSAppleEventDescriptor
    ) throws {
        let message = try messageSpecifier(messageID: messageID)
        let propertyRecord = NSAppleEventDescriptor.record()
        propertyRecord.setDescriptor(
            NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
        propertyRecord.setDescriptor(message, forKeyword: code("from"))
        propertyRecord.setDescriptor(
            NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
        propertyRecord.setDescriptor(
            NSAppleEventDescriptor(typeCode: code(property)), forKeyword: code("seld"))
        guard let propertySpecifier = propertyRecord.coerce(toDescriptorType: code("obj ")) else {
            throw ToolFailure("Could not address the message state.")
        }

        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code("core"),
            eventID: code("setd"),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(propertySpecifier, forKeyword: code("----"))
        event.setParam(NSAppleEventDescriptor(boolean: value), forKeyword: code("data"))
        try send(event, verb: "change")
    }

    /// core/delo: Mail's delete, which routes the message to its Trash.
    private static func deleteMessage(messageID: Int64, target: NSAppleEventDescriptor) throws {
        let message = try messageSpecifier(messageID: messageID)
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code("core"),
            eventID: code("delo"),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(message, forKeyword: code("----"))
        try send(event, verb: "delete")
    }

    private static func send(_ event: NSAppleEventDescriptor, verb: String) throws {
        do {
            _ = try event.sendEvent(options: [.waitForReply], timeout: 20)
        } catch let error as NSError where error.code == -1743 {
            throw ToolFailure(
                "macOS is blocking Honeycrisp from driving Mail. Grant Automation access in System Settings under Privacy & Security, Automation, then try again."
            )
        } catch let error as NSError where error.code == -1728 {
            throw ToolFailure(
                "That message is not in an inbox, and Honeycrisp can only \(verb) inbox messages for now."
            )
        }
    }

    // MARK: - Targeting

    private static func numericID(_ raw: String) throws -> Int64 {
        guard let id = Int64(raw) else {
            throw ToolFailure("\u{201C}\(raw)\u{201D} is not a mail message id.")
        }
        return id
    }

    /// message of inbox whose id = N.
    private static func messageSpecifier(messageID: Int64) throws -> NSAppleEventDescriptor {
        // inbox: the application's unified inbox property.
        let inbox = NSAppleEventDescriptor.record()
        inbox.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
        inbox.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: code("from"))
        inbox.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
        inbox.setDescriptor(NSAppleEventDescriptor(typeCode: code("inmb")), forKeyword: code("seld"))
        guard let inboxSpecifier = inbox.coerce(toDescriptorType: code("obj ")) else {
            throw ToolFailure("Could not address Mail's inbox.")
        }

        // its id = N, the whose-clause test.
        guard let examined = NSAppleEventDescriptor(descriptorType: code("exmn"), data: Data())
        else {
            throw ToolFailure("Could not build the message test.")
        }
        let idProperty = NSAppleEventDescriptor.record()
        idProperty.setDescriptor(
            NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
        idProperty.setDescriptor(examined, forKeyword: code("from"))
        idProperty.setDescriptor(
            NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
        idProperty.setDescriptor(
            NSAppleEventDescriptor(typeCode: code("ID  ")), forKeyword: code("seld"))
        guard let idSpecifier = idProperty.coerce(toDescriptorType: code("obj ")) else {
            throw ToolFailure("Could not address the message id.")
        }
        let comparison = NSAppleEventDescriptor.record()
        comparison.setDescriptor(
            NSAppleEventDescriptor(enumCode: code("=   ")), forKeyword: code("relo"))
        comparison.setDescriptor(idSpecifier, forKeyword: code("obj1"))
        guard let id32 = Int32(exactly: messageID) else {
            throw ToolFailure("The message id \(messageID) is out of range for Mail.")
        }
        comparison.setDescriptor(
            NSAppleEventDescriptor(int32: id32), forKeyword: code("obj2"))
        guard let test = comparison.coerce(toDescriptorType: code("cmpd")) else {
            throw ToolFailure("Could not build the message test.")
        }

        // message of inbox whose <test>
        let message = NSAppleEventDescriptor.record()
        message.setDescriptor(
            NSAppleEventDescriptor(typeCode: code("mssg")), forKeyword: code("want"))
        message.setDescriptor(inboxSpecifier, forKeyword: code("from"))
        message.setDescriptor(NSAppleEventDescriptor(enumCode: code("test")), forKeyword: code("form"))
        message.setDescriptor(test, forKeyword: code("seld"))
        guard let messageSpecifier = message.coerce(toDescriptorType: code("obj ")) else {
            throw ToolFailure("Could not address the message.")
        }
        return messageSpecifier
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
