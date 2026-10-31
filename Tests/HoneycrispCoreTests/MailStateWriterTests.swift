import Foundation
import Testing

@testable import HoneycrispCore

/// How the writer reads Mail's answer to "how many messages does this
/// specifier match", without Mail: a delete counts as gone only on zero.
@Suite("Mail state writer")
struct MailStateWriterTests {
    private func osStatus(_ code: Int) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: code)
    }

    @Test("no such object means the message is not there")
    func noSuchObject() throws {
        #expect(try AppleEventMailStateWriter.matchCount { throw osStatus(-1728) } == 0)
        #expect(try AppleEventMailStateWriter.matchCount { throw osStatus(-1719) } == 0)
    }

    @Test("an answer counts its items, and an empty list is zero")
    func answers() throws {
        #expect(try AppleEventMailStateWriter.matchCount { NSAppleEventDescriptor(int32: 35450) } == 1)
        #expect(try AppleEventMailStateWriter.matchCount { NSAppleEventDescriptor.list() } == 0)
    }

    @Test("no answer or any other error is unknown, never zero")
    func unknown() throws {
        #expect(try AppleEventMailStateWriter.matchCount { nil } == nil)
        #expect(try AppleEventMailStateWriter.matchCount { throw osStatus(-600) } == nil)
        #expect(try AppleEventMailStateWriter.matchCount { throw osStatus(-10000) } == nil)
    }

    @Test("a timeout and an Automation block reach the user")
    func failures() {
        #expect(throws: ToolFailure.self) {
            _ = try AppleEventMailStateWriter.matchCount { throw osStatus(-1712) }
        }
        #expect(throws: ToolFailure.self) {
            _ = try AppleEventMailStateWriter.matchCount { throw ToolFailure("blocked") }
        }
    }
}
