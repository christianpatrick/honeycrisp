import Foundation

/// One approval waiting on the user.
public struct PendingApproval: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let prompt: ApprovalPrompt
    public let requestedAt: Date
}

/// Suspends approval-required tool calls until the user answers the
/// notification or the request times out as denied.
public actor ApprovalBroker: ApprovalRequesting {
    private let timeout: Duration
    private var handler: (@Sendable (PendingApproval) -> Void)?
    private var pendingByID: [UUID: PendingApproval] = [:]
    private var order: [UUID] = []
    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        timeout: Duration = .seconds(120),
        onRequest: (@Sendable (PendingApproval) -> Void)? = nil
    ) {
        self.timeout = timeout
        self.handler = onRequest
    }

    public func setRequestHandler(_ handler: @escaping @Sendable (PendingApproval) -> Void) {
        self.handler = handler
    }

    public func requestApproval(_ prompt: ApprovalPrompt) async -> Bool {
        let pending = PendingApproval(id: UUID(), prompt: prompt, requestedAt: Date())
        return await withCheckedContinuation { continuation in
            // Everything lands before the caller suspends, so a resolve
            // arriving the instant the handler fires still finds the
            // continuation.
            continuations[pending.id] = continuation
            pendingByID[pending.id] = pending
            order.append(pending.id)
            handler?(pending)

            let id = pending.id
            let timeout = timeout
            timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.resolve(id: id, approved: false)
            }
        }
    }

    /// Unknown ids and second resolutions are no-ops, so a late timeout
    /// racing a user tap is harmless in either order.
    public func resolve(id: UUID, approved: Bool) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        pendingByID.removeValue(forKey: id)
        order.removeAll { $0 == id }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        continuation.resume(returning: approved)
    }

    public func pending() -> [PendingApproval] {
        order.compactMap { pendingByID[$0] }
    }
}
