import AppKit
import Foundation

/// Composes drafts and sends mail with raw in-process Apple events to Mail
/// (tier 3 in the AGENTS.md hierarchy). Codes come straight from Mail.sdef:
/// outgoing message bcke with subj, ctnt, pvis; recipients trcp and ccrc
/// with radd; save with core/save (lands in Drafts); send with emsg/send.
/// No osascript, no AppleScript source, nothing written to Mail's stores.
public struct AppleEventMailComposer: MailComposing {
    private static let mailBundleID = "com.apple.mail"

    public init() {}

    public func compose(_ draft: MailDraft, send: Bool) async throws -> MailComposeReceipt {
        try await ensureMailIsRunning()
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.mailBundleID)

        let message = try Self.makeOutgoingMessage(draft: draft, target: target)
        for address in draft.to {
            try Self.addRecipient(
                address: address, recipientClass: "trcp", to: message, target: target)
        }
        for address in draft.cc {
            try Self.addRecipient(
                address: address, recipientClass: "ccrc", to: message, target: target)
        }
        if send {
            try Self.sendSimpleEvent(
                class: "emsg", id: "send", direct: message, target: target)
        } else {
            try Self.sendSimpleEvent(
                class: "core", id: "save", direct: message, target: target)
        }
        return MailComposeReceipt(to: draft.to, cc: draft.cc, subject: draft.subject, sent: send)
    }

    // MARK: - Events

    /// core/crel: make new outgoing message {subject, content, visible:false}.
    /// Returns the object specifier Mail hands back for the new message.
    private static func makeOutgoingMessage(
        draft: MailDraft, target: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        let event = appleEvent(class: "core", id: "crel", target: target)
        event.setParam(NSAppleEventDescriptor(typeCode: code("bcke")), forKeyword: code("kocl"))
        let properties = NSAppleEventDescriptor.record()
        if let subject = draft.subject {
            properties.setDescriptor(NSAppleEventDescriptor(string: subject), forKeyword: code("subj"))
        }
        properties.setDescriptor(NSAppleEventDescriptor(string: draft.body), forKeyword: code("ctnt"))
        properties.setDescriptor(
            NSAppleEventDescriptor(boolean: false), forKeyword: code("pvis"))
        event.setParam(properties, forKeyword: code("prdt"))
        let reply = try sendChecked(event)
        guard let specifier = reply.paramDescriptor(forKeyword: keyDirectObject) else {
            throw ToolFailure("Mail did not hand back the new message.")
        }
        return specifier
    }

    /// core/crel of a recipient at the end of the message's recipient
    /// elements, with the address in radd.
    private static func addRecipient(
        address: String,
        recipientClass: String,
        to message: NSAppleEventDescriptor,
        target: NSAppleEventDescriptor
    ) throws {
        let event = appleEvent(class: "core", id: "crel", target: target)
        event.setParam(
            NSAppleEventDescriptor(typeCode: code(recipientClass)), forKeyword: code("kocl"))

        // every <recipientClass> of <message>
        let all = NSAppleEventDescriptor.record()
        all.setDescriptor(
            NSAppleEventDescriptor(typeCode: code(recipientClass)), forKeyword: code("want"))
        all.setDescriptor(message, forKeyword: code("from"))
        all.setDescriptor(NSAppleEventDescriptor(enumCode: code("indx")), forKeyword: code("form"))
        all.setDescriptor(
            NSAppleEventDescriptor(
                descriptorType: code("abso"), data: fourCCData("all ")) ?? NSAppleEventDescriptor.null(),
            forKeyword: code("seld"))
        guard let elements = all.coerce(toDescriptorType: code("obj ")) else {
            throw ToolFailure("Could not address the recipient list.")
        }

        // insertion location: at end of those elements
        let insertion = NSAppleEventDescriptor.record()
        insertion.setDescriptor(elements, forKeyword: code("kobj"))
        insertion.setDescriptor(NSAppleEventDescriptor(enumCode: code("end ")), forKeyword: code("kpos"))
        guard let location = insertion.coerce(toDescriptorType: code("insl")) else {
            throw ToolFailure("Could not address the end of the recipient list.")
        }
        event.setParam(location, forKeyword: code("insh"))

        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(NSAppleEventDescriptor(string: address), forKeyword: code("radd"))
        event.setParam(properties, forKeyword: code("prdt"))
        _ = try sendChecked(event)
    }

    private static func sendSimpleEvent(
        class eventClass: String,
        id eventID: String,
        direct: NSAppleEventDescriptor,
        target: NSAppleEventDescriptor
    ) throws {
        let event = appleEvent(class: eventClass, id: eventID, target: target)
        event.setParam(direct, forKeyword: keyDirectObject)
        _ = try sendChecked(event)
    }

    // MARK: - Plumbing

    private static func appleEvent(
        class eventClass: String, id eventID: String, target: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: code(eventClass),
            eventID: code(eventID),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    private static func sendChecked(_ event: NSAppleEventDescriptor) throws
        -> NSAppleEventDescriptor
    {
        do {
            return try event.sendEvent(options: [.waitForReply], timeout: 30)
        } catch let error as NSError where error.code == -1743 {
            throw ToolFailure(
                "macOS is blocking Honeycrisp from driving Mail. Grant Automation access in System Settings under Privacy & Security, Automation, then try again."
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

    private static func fourCCData(_ four: String) -> Data {
        var value = code(four).bigEndian
        return Data(bytes: &value, count: MemoryLayout<FourCharCode>.size)
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

private let keyDirectObject: AEKeyword = {
    var result: AEKeyword = 0
    for byte in "----".utf8 {
        result = (result << 8) | AEKeyword(byte)
    }
    return result
}()
