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

    /// The remote port (GH-16). Off whenever the hub is paused or remote
    /// access is switched off.
    public enum RemoteState: Equatable, Sendable {
        case off
        case needsPublicURL
        case running(port: UInt16)
        case failed(String)
    }

    public private(set) var serverState: ServerState = .paused
    public private(set) var remoteState: RemoteState = .off
    public private(set) var remoteGrants: [RemoteGrant] = []
    /// Passkeys for the current public URL's host.
    public private(set) var remotePasskeys: [PasskeyCredential] = []
    public private(set) var config: HoneycrispConfig
    public private(set) var clients: [ConnectedClient] = []
    public private(set) var counts = AuditCounts(requestsToday: 0, approvedLastDay: 0)
    public private(set) var entries: [AuditEntry] = []
    public private(set) var pendingApprovals: [PendingApproval] = []

    public let configURL: URL
    public let audit: AuditStore
    public let remoteStore: RemoteAccessStore

    private let box: ConfigBox
    private let registry = ClientRegistry()
    private let broker: ApprovalBroker
    private let presenter: any ApprovalPresenting
    private let executor: any ToolExecutor
    private let portOverride: UInt16?
    private let remotePortOverride: UInt16?
    private var server: LoopbackHTTPServer?
    private var router: MCPHTTPRouter?
    private var remoteServer: LoopbackHTTPServer?
    private var remoteAccess: RemoteAccessServer?
    /// Bumps on every stop, so a start that finishes after a stop knows to
    /// close what it opened.
    private var remoteGeneration = 0
    /// Restarts run one at a time, so quick toggles never race two
    /// listeners for the same port.
    private var remoteTransition: Task<Void, Never>?

    public init(
        configURL: URL = HoneycrispConfig.defaultFileURL,
        auditURL: URL = HoneycrispConfig.supportDirectoryURL.appendingPathComponent("audit.jsonl"),
        executor: (any ToolExecutor)? = nil,
        presenter: any ApprovalPresenting,
        portOverride: UInt16? = nil,
        remotePortOverride: UInt16? = nil,
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
        self.remotePortOverride = remotePortOverride
        // Beside the config, so a test's temporary config gets its own.
        self.remoteStore = RemoteAccessStore(
            fileURL: configURL.deletingLastPathComponent()
                .appendingPathComponent("remote-access.json"))
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
        self.router = router
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
            return
        }
        await startRemote()
    }

    public func pause() {
        stopRemote()
        server?.stop()
        server = nil
        serverState = .paused
    }

    // MARK: - Remote access

    /// Starts the remote port when the hub runs, remote access is on, and
    /// the public URL parses. A failure here never touches the local port.
    private func startRemote() async {
        guard remoteServer == nil, isRunning, let router else { return }
        guard config.remoteAccessEnabled else {
            remoteState = .off
            return
        }
        guard let origin = RemoteOrigin(publicURL: config.publicURL ?? "") else {
            remoteState = .needsPublicURL
            return
        }
        let generation = remoteGeneration
        let access = RemoteAccessServer(
            origin: origin,
            store: remoteStore,
            mcp: { body, client in
                let routed = await router.handle(body: body, clientHeader: client)
                return HTTPResponse(status: routed.status, body: routed.body)
            }
        )
        do {
            let started = try await LoopbackHTTPServer.start(
                port: remotePortOverride ?? UInt16(clamping: config.remotePort),
                handler: { request in await access.handle(request) }
            )
            guard generation == remoteGeneration, isRunning else {
                started.stop()
                return
            }
            remoteAccess = access
            remoteServer = started
            remoteState = .running(port: started.port)
        } catch {
            remoteState = .failed(
                (error as? ToolFailure)?.message ?? error.localizedDescription)
        }
    }

    private func stopRemote() {
        remoteGeneration += 1
        remoteServer?.stop()
        remoteServer = nil
        remoteAccess = nil
        remoteState = .off
    }

    private func restartRemote() async {
        let previous = remoteTransition
        let transition = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            self.stopRemote()
            await self.startRemote()
            await self.refreshRemote()
        }
        remoteTransition = transition
        await transition.value
    }

    public func updateRemoteAccess(_ enabled: Bool) async {
        guard enabled != config.remoteAccessEnabled else { return }
        config.remoteAccessEnabled = enabled
        persist()
        await restartRemote()
    }

    /// Saves the public URL in its normalized form. Returns false and
    /// changes nothing when the text isn't an https origin; empty text
    /// clears it.
    @discardableResult
    public func updatePublicURL(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String?
        if trimmed.isEmpty {
            normalized = nil
        } else if let origin = RemoteOrigin(publicURL: trimmed) {
            normalized = origin.origin
        } else {
            return false
        }
        guard normalized != config.publicURL else { return true }
        config.publicURL = normalized
        persist()
        await restartRemote()
        return true
    }

    /// The URL to paste into a client as the connector, when one is set.
    public var remoteConnectorURL: String? {
        RemoteOrigin(publicURL: config.publicURL ?? "")?.resource
    }

    /// A one-time passkey setup link, while the remote port runs.
    public func remoteSetupLink() async -> URL? {
        await remoteAccess?.makeSetupLink()
    }

    public func disconnectRemote(grantID: UUID) async {
        await remoteStore.revokeGrant(id: grantID)
        await refreshRemote()
    }

    public func removePasskeys() async {
        await remoteStore.removeAllPasskeys()
        await refreshRemote()
    }

    private func refreshRemote() async {
        remoteGrants = await remoteStore.grants()
        let host = RemoteOrigin(publicURL: config.publicURL ?? "")?.relyingPartyID
        remotePasskeys = await remoteStore.passkeys().filter { $0.relyingPartyID == host }
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
        await refreshRemote()
    }
}
