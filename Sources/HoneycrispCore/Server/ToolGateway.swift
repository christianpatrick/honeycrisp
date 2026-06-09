import Foundation
import MCP

/// The seam where permissions, approvals, the audit log, and the services
/// meet MCP. Lists only what the user allowed, refuses the rest with a
/// sentence a person can read, asks when approval is required, and writes
/// the audit entry either way.
public struct ToolGateway: Sendable {
    private let configProvider: @Sendable () -> HoneycrispConfig
    private let executor: any ToolExecutor
    private let audit: AuditStore?
    private let approvals: (any ApprovalRequesting)?
    private let clientName: @Sendable () -> String

    public init(
        configProvider: @escaping @Sendable () -> HoneycrispConfig,
        executor: any ToolExecutor,
        audit: AuditStore?,
        approvals: (any ApprovalRequesting)? = nil,
        clientName: @escaping @Sendable () -> String = { "Unknown client" }
    ) {
        self.configProvider = configProvider
        self.executor = executor
        self.audit = audit
        self.approvals = approvals
        self.clientName = clientName
    }

    public func listTools() -> [Tool] {
        let config = configProvider()
        return ToolRegistry.all
            .filter { registered in
                if case .denied = config.decision(
                    app: registered.descriptor.app, action: registered.descriptor.id)
                {
                    return false
                }
                return true
            }
            .map(\.tool)
    }

    public func callTool(name: String, arguments: [String: Value]) async -> GatewayResult {
        guard let registered = ToolRegistry.registered(named: name) else {
            // Junk names are not worth an audit entry; denials are.
            return GatewayResult(content: "There is no tool named \(name).", isError: true)
        }
        let descriptor = registered.descriptor
        let config = configProvider()
        let client = clientName()
        let appName = Self.appName(for: descriptor.app)

        switch config.decision(app: descriptor.app, action: descriptor.id) {
        case .denied(let reason):
            let message = Self.denialSentence(
                reason: reason, label: descriptor.label, appName: appName, kind: descriptor.kind)
            await recordDenial(
                descriptor: descriptor, client: client, summary: message,
                permission: Self.permissionRow(reason: reason, label: descriptor.label, appName: appName))
            return GatewayResult(content: message, isError: true)

        case .needsApproval:
            guard let approvals else {
                let message =
                    "\(descriptor.label) needs your approval from the Honeycrisp menu bar app, which is not running. Open Honeycrisp and try again."
                await recordDenial(
                    descriptor: descriptor, client: client, summary: message,
                    permission: "\(appName) · Approval unavailable")
                return GatewayResult(content: message, isError: true)
            }
            let prompt = registered.approvalPrompt(client: client, arguments: arguments)
            guard await approvals.requestApproval(prompt) else {
                let message = "You did not allow this, so nothing left your Mac."
                await recordDenial(
                    descriptor: descriptor, client: client, summary: message,
                    permission: "\(appName) · You declined")
                return GatewayResult(content: message, isError: true)
            }
            return await run(registered, arguments: arguments, client: client, outcome: .asked)

        case .allowed:
            return await run(registered, arguments: arguments, client: client, outcome: .allowed)
        }
    }

    // MARK: - Execution

    private func run(
        _ registered: RegisteredTool,
        arguments: [String: Value],
        client: String,
        outcome: AuditOutcome
    ) async -> GatewayResult {
        let descriptor = registered.descriptor
        let start = ContinuousClock.now
        do {
            let result = try await executor.execute(
                app: descriptor.app, action: descriptor.id, arguments: arguments)
            var rows = result.auditRows
            if outcome == .asked {
                rows.append(AuditDetailRow(label: "You", value: "Allowed once"))
            }
            rows.append(AuditDetailRow(label: "Duration", value: Self.durationString(since: start)))
            await record(
                AuditEntry(
                    app: descriptor.app,
                    actionID: descriptor.id,
                    kind: descriptor.kind,
                    outcome: outcome,
                    action: result.auditAction,
                    client: client,
                    summary: result.auditSummary,
                    rows: rows
                ))
            return GatewayResult(content: result.content, isError: false)
        } catch {
            let message = (error as? ToolFailure)?.message ?? error.localizedDescription
            await record(
                AuditEntry(
                    app: descriptor.app,
                    actionID: descriptor.id,
                    kind: descriptor.kind,
                    outcome: outcome,
                    action: "Tried to \(descriptor.label.lowercased())",
                    client: client,
                    summary: "The request was allowed but failed: \(message)",
                    rows: [
                        AuditDetailRow(label: "Error", value: message),
                        AuditDetailRow(label: "Duration", value: Self.durationString(since: start)),
                    ]
                ))
            return GatewayResult(content: message, isError: true)
        }
    }

    // MARK: - Audit

    private func record(_ entry: AuditEntry) async {
        guard let audit else { return }
        // Audit failures must never fail a user's request.
        try? await audit.append(entry)
    }

    private func recordDenial(
        descriptor: ActionDescriptor, client: String, summary: String, permission: String
    ) async {
        await record(
            AuditEntry(
                app: descriptor.app,
                actionID: descriptor.id,
                kind: descriptor.kind,
                outcome: .denied,
                action: "Tried to \(descriptor.label.lowercased())",
                client: client,
                summary: summary,
                rows: [
                    AuditDetailRow(label: "Requested", value: descriptor.label),
                    AuditDetailRow(label: "Permission", value: permission),
                    AuditDetailRow(
                        label: "Result",
                        value: descriptor.kind == .write ? "Blocked, nothing sent" : "Blocked"),
                ]
            ))
    }

    // MARK: - Copy

    private static func appName(for app: AppID) -> String {
        ActionCatalog.apps.first { $0.id == app }?.name ?? app.rawValue
    }

    private static func denialSentence(
        reason: DenialReason, label: String, appName: String, kind: ActionKind
    ) -> String {
        switch reason {
        case .appOff:
            return "\(appName) is turned off in Honeycrisp, so the request was blocked."
        case .readOnlyApp:
            return "\(appName) is read only in Honeycrisp, so \(label.lowercased()) was blocked."
        case .actionOff:
            let tail = kind == .write ? " before anything left your Mac." : "."
            return "\(label) is turned off for \(appName), so the request was blocked\(tail)"
        case .unknownAction:
            return "There is no tool named \(label)."
        }
    }

    private static func permissionRow(reason: DenialReason, label: String, appName: String)
        -> String
    {
        switch reason {
        case .appOff: return "\(appName) · Off"
        case .readOnlyApp: return "\(appName) · Read only"
        case .actionOff: return "\(appName) · \(label) is off"
        case .unknownAction: return "\(appName) · Unknown action"
        }
    }

    private static func durationString(since start: ContinuousClock.Instant) -> String {
        let elapsed = start.duration(to: .now)
        let seconds =
            Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        return String(format: "%.1fs", seconds)
    }
}
