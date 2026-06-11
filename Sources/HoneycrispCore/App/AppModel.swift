import Foundation
import Observation

/// Posts an approval request to the user. The app implements this with
/// UNUserNotificationCenter; tests record.
public protocol ApprovalPresenting: Sendable {
    func present(_ approval: PendingApproval) async
}

/// Weakly holds the model for the broker's request handler without a
/// retain cycle (the model owns the broker, which holds the handler).
/// Loading a weak reference is thread safe.
private final class WeakModelRef: @unchecked Sendable {
    weak var model: AppModel?
    init(_ model: AppModel) { self.model = model }
}

/// Hands the live config to off-main-actor readers (the gateway's
/// configProvider) without racing the model.
final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HoneycrispConfig

    init(_ value: HoneycrispConfig) {
        self.value = value
    }

    var current: HoneycrispConfig {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// The one stateful object behind the menu bar UI: owns the config, the
/// audit store, the approval broker, the client registry, and the loopback
/// server lifecycle. Views render this; mutations persist immediately so
/// the CLI and the live server see them too.
@MainActor
@Observable
public final class AppModel {
    public enum ServerState: Equatable, Sendable {
        case starting
        case running(port: UInt16)
        case paused
        case failed(String)
    }

    public private(set) var serverState: ServerState = .paused
    public private(set) var config: HoneycrispConfig
    public private(set) var clients: [ConnectedClient] = []
    public private(set) var counts = AuditCounts(requestsToday: 0, approvedLastDay: 0)
    public private(set) var entries: [AuditEntry] = []
    public private(set) var pendingApprovals: [PendingApproval] = []

    public let configURL: URL
    public let audit: AuditStore

    private let box: ConfigBox
    private let registry = ClientRegistry()
    private let broker: ApprovalBroker
    private let presenter: any ApprovalPresenting
    private let executor: any ToolExecutor
    private let portOverride: UInt16?
    private var server: LoopbackHTTPServer?

    public init(
        configURL: URL = HoneycrispConfig.defaultFileURL,
        auditURL: URL = HoneycrispConfig.supportDirectoryURL.appendingPathComponent("audit.jsonl"),
        executor: (any ToolExecutor)? = nil,
        presenter: any ApprovalPresenting,
        portOverride: UInt16? = nil,
        approvalTimeout: Duration = .seconds(120)
    ) {
        let loaded = HoneycrispConfig.load(from: configURL)
        self.config = loaded
        self.configURL = configURL
        let box = ConfigBox(loaded)
        self.box = box
        self.audit = AuditStore(fileURL: auditURL, maxEntries: loaded.auditMaxEntries)
        self.presenter = presenter
        self.portOverride = portOverride
        self.broker = ApprovalBroker(timeout: approvalTimeout)
        self.executor = executor ?? ServiceExecutor.production(configProvider: { box.current })

        let broker = self.broker
        let ref = WeakModelRef(self)
        Task {
            await broker.setRequestHandler { approval in
                Task { @MainActor in
                    ref.model?.approvalRequested(approval)
                }
            }
        }
    }

    // MARK: - Server lifecycle

    public func start() async {
        guard server == nil else { return }
        serverState = .starting
        let gateway = ToolGateway(
            configProvider: { [box] in box.current },
            executor: executor,
            audit: audit,
            approvals: broker
        )
        let router = MCPHTTPRouter(gateway: gateway, clients: registry)
        do {
            let started = try await LoopbackHTTPServer.start(
                port: portOverride ?? UInt16(clamping: box.current.port),
                bearerToken: box.current.bearerToken,
                router: router
            )
            server = started
            serverState = .running(port: started.port)
        } catch {
            serverState = .failed(
                (error as? ToolFailure)?.message ?? error.localizedDescription)
        }
    }

    public func pause() {
        server?.stop()
        server = nil
        serverState = .paused
    }

    public func toggleServer() async {
        if case .running = serverState {
            pause()
        } else {
            await start()
        }
    }

    public var isRunning: Bool {
        if case .running = serverState { return true }
        return false
    }

    /// The header subtitle, in the design's words.
    public var statusLine: String {
        switch serverState {
        case .running:
            switch clients.count {
            case 0: return "Waiting for clients"
            case 1: return "1 client connected"
            default: return "\(clients.count) clients connected"
            }
        case .starting:
            return "Starting"
        case .paused:
            return "Server paused"
        case .failed(let message):
            return message
        }
    }

    // MARK: - Permissions

    public func setLevel(_ level: PermissionLevel, for app: AppID) {
        config.setLevel(level, for: app)
        persist()
    }

    public func setAction(_ id: String, on: Bool, for app: AppID) {
        config.setAction(id, on: on, for: app)
        persist()
    }

    public func toggleAction(_ id: String, for app: AppID) {
        setAction(id, on: !config.isOn(app: app, action: id), for: app)
    }

    // MARK: - Settings

    public func completeOnboarding() {
        config.onboardingCompleted = true
        persist()
    }

    public func updatePort(_ port: Int) async {
        guard port != config.port else { return }
        config.port = port
        persist()
        if isRunning {
            pause()
            await start()
        }
    }

    public func updateBearerToken(_ token: String?) async {
        config.bearerToken = (token?.isEmpty == true) ? nil : token
        persist()
        if isRunning {
            pause()
            await start()
        }
    }

    public func updateAuditRetention(_ maxEntries: Int) {
        config.auditMaxEntries = max(50, maxEntries)
        persist()
    }

    public func updateAutomaticUpdateChecks(_ enabled: Bool) {
        guard enabled != config.automaticUpdateChecks else { return }
        config.automaticUpdateChecks = enabled
        persist()
    }

    public func clearActivity() async {
        try? await audit.clear()
        await refresh()
    }

    private func persist() {
        box.current = config
        try? config.save(to: configURL)
    }

    // MARK: - Approvals

    private func approvalRequested(_ approval: PendingApproval) {
        pendingApprovals.append(approval)
        let presenter = presenter
        Task {
            await presenter.present(approval)
        }
    }

    public func resolveApproval(id: UUID, approved: Bool) async {
        await broker.resolve(id: id, approved: approved)
        pendingApprovals.removeAll { $0.id == id }
    }

    // MARK: - Panel data

    public func refresh() async {
        counts = await audit.counts()
        entries = await audit.entries(limit: 50)
        clients = await registry.list()
        let stillPending = await broker.pending()
        pendingApprovals = stillPending
    }
}
