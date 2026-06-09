import AppKit
import Foundation

/// Marks a 1:1 conversation read the SIP-safe way: open the chat through
/// the Messages URL scheme so the Messages daemon updates its own state
/// (which is what syncs to iCloud and sends the read receipt), confirm by
/// watching the unread count, then put the user back where they were.
/// Never writes chat.db.
public struct MessagesMarkReadDriver: ConversationMarkReading {
    private let reader: any ChatDatabaseReading

    public init(reader: any ChatDatabaseReading) {
        self.reader = reader
    }

    public func markRead(conversation: String) async throws -> MarkReadResult {
        guard let target = try await reader.conversationTarget(matching: conversation) else {
            throw ToolFailure(
                "No Messages conversation matched \u{201C}\(conversation)\u{201D}.")
        }
        guard !target.isGroup else {
            throw ToolFailure(
                "Marking group chats read is not supported, only one on one conversations.")
        }
        if try await reader.unreadCount(chatGUID: target.guid) == 0 {
            return MarkReadResult(markedRead: false, confirmed: true)
        }

        let allowed = CharacterSet(charactersIn: "+@.0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_")
        guard
            let encoded = target.identifier.addingPercentEncoding(withAllowedCharacters: allowed),
            let url = URL(string: "imessage://\(encoded)")
        else {
            throw ToolFailure("Could not address the conversation with \(target.identifier).")
        }

        let previous = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }

        // The daemon needs a beat to flip the flag; poll the snapshot,
        // bounded, exactly like the previous build did.
        var confirmed = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(250))
            if (try? await reader.unreadCount(chatGUID: target.guid)) == 0 {
                confirmed = true
                break
            }
        }
        await MainActor.run {
            if let previous, previous.bundleIdentifier != "com.apple.MobileSMS" {
                previous.activate()
            }
        }
        return MarkReadResult(markedRead: true, confirmed: confirmed)
    }
}
