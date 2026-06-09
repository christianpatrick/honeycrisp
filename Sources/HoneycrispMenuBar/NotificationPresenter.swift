import Foundation
import HoneycrispCore
import UserNotifications

/// Presents approval requests as native notifications with Allow once and
/// Don't allow, exactly the design's approval moment. Requires a real app
/// bundle; under bare swift run the panel's pending list is the surface.
final class NotificationApprovalPresenter: NSObject, ApprovalPresenting,
    UNUserNotificationCenterDelegate, @unchecked Sendable
{
    static let categoryID = "app.honeycrisp.approval"
    static let allowAction = "app.honeycrisp.approval.allow"
    static let denyAction = "app.honeycrisp.approval.deny"

    /// Set right after the model is created; resolution hops to the main
    /// actor through it.
    weak var model: AppModel?

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func activate() {
        guard let center else { return }
        center.delegate = self
        let allow = UNNotificationAction(
            identifier: Self.allowAction, title: "Allow once", options: [.authenticationRequired])
        let deny = UNNotificationAction(
            identifier: Self.denyAction, title: "Don't allow", options: [])
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [deny, allow],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    // MARK: - ApprovalPresenting

    func present(_ approval: PendingApproval) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Honeycrisp"
        content.body = approval.prompt.message
        content.subtitle = approval.prompt.subtitle
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["approvalID": approval.id.uuidString]
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: approval.id.uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard
            let raw = response.notification.request.content.userInfo["approvalID"] as? String,
            let id = UUID(uuidString: raw)
        else { return }
        switch response.actionIdentifier {
        case Self.allowAction:
            await resolve(id: id, approved: true)
        case Self.denyAction:
            await resolve(id: id, approved: false)
        default:
            // Tapping the banner opens nothing special; the request stays
            // pending in the panel until answered or timed out.
            break
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func resolve(id: UUID, approved: Bool) async {
        await MainActor.run { [weak model] in
            guard let model else { return }
            Task { await model.resolveApproval(id: id, approved: approved) }
        }
    }
}
