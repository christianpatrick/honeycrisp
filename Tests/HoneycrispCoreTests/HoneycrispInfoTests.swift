import Testing
import HoneycrispCore

@Suite("Honeycrisp info")
struct HoneycrispInfoTests {
    @Test("a packaged bundle version wins over the compiled fallback")
    func bundleVersionWins() {
        #expect(HoneycrispInfo.resolveVersion(bundleShortVersion: "9.9.9") == "9.9.9")
    }

    @Test("a missing or empty bundle version falls back to the compiled default")
    func fallbackWhenAbsent() {
        #expect(
            HoneycrispInfo.resolveVersion(bundleShortVersion: nil) == HoneycrispInfo.fallbackVersion)
        #expect(
            HoneycrispInfo.resolveVersion(bundleShortVersion: "") == HoneycrispInfo.fallbackVersion)
    }
}
