import Foundation
import SQLite3

/// Shared row helpers for the read-only SQLite readers (chat.db and Mail's
/// Envelope Index).

func column(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let text = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: text)
}

func blobColumn(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    return Data(bytes: bytes, count: count)
}

func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, index, value, -1, transient)
}
