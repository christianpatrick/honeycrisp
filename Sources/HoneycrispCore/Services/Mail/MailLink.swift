import Foundation

/// The message:// URL Mail answers on the Mac and on iPhone and iPad: the
/// RFC Message-ID inside percent-encoded angle brackets (GH-12). Everything
/// outside the RFC 3986 unreserved set and @ is escaped, so ids carrying
/// +, =, /, or % survive the trip.
enum MailLink {
    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@")

    static func url(forMessageIDHeader header: String?) -> String? {
        guard var id = header?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if id.hasPrefix("<"), id.hasSuffix(">"), id.count >= 2 {
            id = String(id.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return "message://%3C\(encoded)%3E"
    }
}

/// One account as Mail's scripting dictionary reports it, for matching an
/// Envelope Index mailbox url to the account Mail can address.
struct MailAccountRecord: Equatable, Sendable {
    let id: String
    let userName: String
    let serverName: String
}

/// Where a message lives, parsed from its Envelope Index mailbox url:
/// imap://user@server/INBOX/Receipts, or imap://ACCOUNT-UUID/Archive on
/// some Mail versions. local:// urls name mailboxes On My Mac, outside any
/// account. The path is percent-decoded, which is how Mail names nested
/// mailboxes.
struct MailboxLocation: Equatable, Sendable {
    let user: String?
    let host: String
    let path: String
    let isLocal: Bool

    init?(url: String) {
        guard let components = URLComponents(string: url), let scheme = components.scheme
        else { return nil }
        var path = components.path
        if path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return nil }
        self.user = components.user
        self.host = components.host ?? ""
        self.path = path
        self.isLocal = scheme.lowercased() == "local"
    }

    /// Whether this is the mailbox a provider uses as its Trash, judged by
    /// the last path component without case: iCloud's Deleted Messages,
    /// Gmail's [Gmail]/Trash, Exchange's Deleted Items, and plain Trash or
    /// Bin elsewhere (GH-18).
    var isTrash: Bool {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return Self.trashNames.contains(last.lowercased())
    }

    private static let trashNames: Set<String> = ["trash", "deleted messages", "deleted items", "bin"]

    /// The id of the account this mailbox belongs to: an account whose id
    /// is the url host, else the one account on that server, else the one
    /// on that server with that user name, else the only account there is.
    /// A tie matches nothing rather than guessing.
    func accountID(among accounts: [MailAccountRecord]) -> String? {
        if let exact = accounts.first(where: { Self.same($0.id, host) }) {
            return exact.id
        }
        let onServer = accounts.filter { Self.same($0.serverName, host) }
        if onServer.count == 1 { return onServer[0].id }
        if let user {
            let named = onServer.filter { Self.same($0.userName, user) }
            if named.count == 1 { return named[0].id }
        }
        return accounts.count == 1 ? accounts[0].id : nil
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        !a.isEmpty && a.caseInsensitiveCompare(b) == .orderedSame
    }
}
