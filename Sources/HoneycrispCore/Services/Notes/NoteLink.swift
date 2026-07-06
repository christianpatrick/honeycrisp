import Foundation

/// The URL Notes itself uses for note-to-note links. Opening one shows
/// the note in Apple Notes on this Mac and on any device signed into the
/// same iCloud account; no sharing step is involved.
enum NoteLink {
    static func url(for identifier: String) -> String {
        "applenotes:note/\(identifier)"
    }
}

/// Who the signed-in iCloud account is, for share workflows around note
/// links. Nothing here talks to the network.
public protocol AppleAccountReading: Sendable {
    func primaryEmail() -> String?
}

/// Reads the Apple ID email from MobileMeAccounts.plist, the one local
/// record of the signed-in iCloud account. The file lives in
/// ~/Library/Preferences and needs no TCC grant. An account that syncs
/// Notes wins over one that does not; no account at all reads nil.
public struct AppleAccount: AppleAccountReading {
    private let path: String

    public init(path: String = NSHomeDirectory() + "/Library/Preferences/MobileMeAccounts.plist") {
        self.path = path
    }

    public func primaryEmail() -> String? {
        guard
            let data = FileManager.default.contents(atPath: path),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
            let accounts = plist["Accounts"] as? [[String: Any]]
        else { return nil }
        let signedIn = accounts.filter { $0["AccountID"] is String }
        let withNotes = signedIn.first { account in
            let services = account["Services"] as? [[String: Any]] ?? []
            return services.contains { $0["Name"] as? String == "NOTES" }
        }
        return (withNotes ?? signedIn.first)?["AccountID"] as? String
    }
}
