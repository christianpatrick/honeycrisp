import AppKit
import Foundation

/// Marks mail read with one raw in-process Apple event per message: set the
/// read status property (isrd) of the inbox message whose id matches. Mail
/// updates its own store and syncs the flag upstream; we never touch the
/// Envelope Index. Codes come from Mail.sdef: message mssg, application
/// inbox property inmb, id property "ID  ". No osascript, no AppleScript
/// source.
public struct AppleEventMailReadMarker: MailReadMarking {
    private static let mailBundleID = "com.apple.mail"

    public init() {}

    public func markRead(messageIDs: [String]) async throws -> Int {
        try await ensureMailIsRunning()
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.mailBundleID)
        var marked = 0
        for raw in messageIDs {
            guard let id = Int64(raw) else {
                throw ToolFailure("\u{201C}\(raw)\u{201D} is not a mail message id.")
            }
            try Self.setRead(messageID: id, target: target)
            marked += 1
        }
        return marked
    }

    /// core/setd: set (read status of (message of inbox whose id = N)) to true.
    private static func setRead(messageID: Int64, target: NSAppleEventDescriptor) throws {
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

        // read status of <message>
        let property = NSAppleEventDescriptor.record()
        property.setDescriptor(
            NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
        property.setDescriptor(messageSpecifier, forKeyword: code("from"))
        property.setDescriptor(
            NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
        property.setDescriptor(
            NSAppleEventDescriptor(typeCode: code("isrd")), forKeyword: code("seld"))
        guard let propertySpecifier = property.coerce(toDescriptorType: code("obj ")) else {
            throw ToolFailure("Could not address the read status.")
        }

        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code("core"),
            eventID: code("setd"),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(propertySpecifier, forKeyword: code("----"))
        event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: code("data"))

        do {
            _ = try event.sendEvent(options: [.waitForReply], timeout: 20)
        } catch let error as NSError where error.code == -1743 {
            throw ToolFailure(
                "macOS is blocking Honeycrisp from driving Mail. Grant Automation access in System Settings under Privacy & Security, Automation, then try again."
            )
        } catch let error as NSError where error.code == -1728 {
            throw ToolFailure(
                "That message is not in an inbox, and Honeycrisp can mark inbox messages read for now."
            )
        }
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
