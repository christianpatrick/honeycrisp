import Foundation

/// Date parsing and formatting shared by the services. Parsing accepts the
/// three ISO 8601 shapes assistants actually send; formatting is pinned to
/// en_US_POSIX so audit rows and tests are locale-stable.
enum ToolDates {
    /// Accepts "2026-06-12T09:00:00Z" (with zone), "2026-06-12T09:00:00"
    /// (local), and "2026-06-12" (local midnight).
    static func parseISO(_ raw: String) -> Date? {
        let zoned = ISO8601DateFormatter()
        zoned.formatOptions = [.withInternetDateTime]
        if let date = zoned.date(from: raw) { return date }

        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = local.date(from: raw) { return date }

        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = .current
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: raw)
    }

    /// "Fri, Jun 12, 9:00 AM" for audit rows.
    static func rowString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMM d, h:mm a"
        return formatter.string(from: date)
    }
}
