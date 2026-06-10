import AppKit
import Contacts
import EventKit
import Foundation
import HoneycrispCore
import SQLite3

/// The real macOS grants behind the onboarding's four rows. Contacts and
/// Reminders can prompt in place; Mail and Messages ride on Full Disk
/// Access, which only System Settings can grant; the two Apple-event
/// targets prompt for Automation on first use.
enum PermissionProbes {
    static func contactsGranted() -> Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    static func requestContacts() async -> Bool {
        let store = CNContactStore()
        return (try? await store.requestAccess(for: .contacts)) ?? false
    }

    static func remindersGranted() -> Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    static func requestReminders() async -> Bool {
        let store = EKEventStore()
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    static func calendarGranted() -> Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static func requestCalendar() async -> Bool {
        let store = EKEventStore()
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Whether this process can read the Messages database (Full Disk
    /// Access in practice).
    static func fullDiskGranted() -> Bool {
        let path = NSHomeDirectory() + "/Library/Messages/chat.db"
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        if let db { sqlite3_close_v2(db) }
        return result == SQLITE_OK
    }

    static func openFullDiskSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Triggers (or checks) the Automation grant for one target app by
    /// asking Apple events directly. 0 means granted.
    static func requestAutomation(bundleID: String) -> Bool {
        guard
            let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc?.pointee
        else { return false }
        var target = descriptor
        let status = AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, true)
        return status == noErr
    }

    static let messagesBundleID = "com.apple.MobileSMS"
    static let mailBundleID = "com.apple.mail"
}
