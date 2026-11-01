import Testing
import HoneycrispCore

@Suite("Audit retention")
struct AuditRetentionTests {
    @Test("presets ascend and include the default")
    func presets() {
        #expect(AuditRetention.presets == AuditRetention.presets.sorted())
        #expect(AuditRetention.presets.contains(HoneycrispConfig.default.auditMaxEntries))
    }

    @Test("a preset value leaves the choices unchanged")
    func presetValue() {
        #expect(AuditRetention.choices(including: 2000) == AuditRetention.presets)
    }

    @Test("a custom value joins the choices in order")
    func customValue() {
        #expect(AuditRetention.choices(including: 750) == [500, 750, 1000, 2000, 5000, 10000, 20000])
    }

    @Test("values outside the presets land at the ends")
    func outsideValues() {
        #expect(AuditRetention.choices(including: 100).first == 100)
        #expect(AuditRetention.choices(including: 30000).last == 30000)
    }
}
