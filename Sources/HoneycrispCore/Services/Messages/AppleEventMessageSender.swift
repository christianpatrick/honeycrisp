import AppKit
import Foundation

/// Sends a message with one raw in-process Apple event to Messages: class
/// icht, id send, direct parameter the text, TO parameter the chat by its
/// scripting unique id, which is exactly chat.db's chat.guid. No osascript,
/// no AppleScript source, nothing written to a store Messages owns.
public struct AppleEventMessageSender: MessageSending {
    private static let messagesBundleID = "com.apple.MobileSMS"
    private let targets: any ChatDatabaseReading

    public init(targets: any ChatDatabaseReading) {
        self.targets = targets
    }

    public func send(recipient: String, body: String) async throws -> SendReceipt {
        guard let target = try await targets.conversationTarget(matching: recipient) else {
            throw ToolFailure(
                "There is no existing Messages conversation with \u{201C}\(recipient)\u{201D}. Start the conversation in Messages once, then Honeycrisp can reply."
            )
        }
        try await ensureMessagesIsRunning()
        do {
            try Self.sendEvent(body: body, chatGUID: target.guid)
        } catch let error as NSError where error.code == -600 {
            // procNotFound: Messages launched but was not ready yet.
            try await Task.sleep(for: .seconds(1))
            try Self.sendEvent(body: body, chatGUID: target.guid)
        }
        return SendReceipt(
            recipient: recipient,
            body: body,
            conversation: target.displayName ?? target.identifier
        )
    }

    // MARK: - The Apple event

    private static func sendEvent(body: String, chatGUID: String) throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: messagesBundleID)
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code("icht"),
            eventID: code("send"),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: body), forKeyword: code("----"))
        event.setParam(try chatSpecifier(guid: chatGUID), forKeyword: code("TO  "))
        do {
            _ = try event.sendEvent(options: [.waitForReply], timeout: 20)
        } catch let error as NSError where error.code == -1743 {
            throw ToolFailure(
                "macOS is blocking Honeycrisp from driving Messages. Grant Automation access in System Settings under Privacy & Security, Automation, then try again."
            )
        }
    }

    /// An object specifier for: chat id "<guid>".
    private static func chatSpecifier(guid: String) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code("imct")), forKeyword: code("want"))
        record.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: code("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code("ID  ")), forKeyword: code("form"))
        record.setDescriptor(NSAppleEventDescriptor(string: guid), forKeyword: code("seld"))
        guard let specifier = record.coerce(toDescriptorType: code("obj ")) else {
            throw ToolFailure("Could not address the Messages conversation.")
        }
        return specifier
    }

    private static func code(_ four: String) -> FourCharCode {
        var result: FourCharCode = 0
        for byte in four.utf8 {
            result = (result << 8) | FourCharCode(byte)
        }
        return result
    }

    // MARK: - Launching

    private func ensureMessagesIsRunning() async throws {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.messagesBundleID)
        guard running.isEmpty else { return }
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: Self.messagesBundleID)
        else {
            throw ToolFailure("Messages is not installed on this Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
