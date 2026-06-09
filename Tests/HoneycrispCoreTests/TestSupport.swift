import Foundation
import MCP
import HoneycrispCore

/// Shared recording executor for suites that exercise the gateway through
/// transports.
actor CapturingExecutor: ToolExecutor {
    struct Call: Sendable {
        let app: AppID
        let action: String
        let arguments: [String: Value]
    }

    private(set) var calls: [Call] = []
    var outcome = ToolOutcome(
        content: #"{"ok":true}"#,
        auditAction: "Did the thing",
        auditSummary: "Returned a thing.",
        auditRows: []
    )

    func execute(app: AppID, action: String, arguments: [String: Value]) async throws -> ToolOutcome {
        calls.append(Call(app: app, action: action, arguments: arguments))
        return outcome
    }
}

func tempStoreURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("honeycrisp-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name)
}
