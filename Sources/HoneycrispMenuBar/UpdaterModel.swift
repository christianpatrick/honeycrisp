import Sparkle
import SwiftUI

/// Wraps Sparkle's updater for the menu bar app. The user's preference,
/// HoneycrispConfig.automaticUpdateChecks, is the source of truth and is
/// pushed into Sparkle here; a manual check is always available regardless.
@MainActor
final class UpdaterModel: ObservableObject {
    private let controller: SPUStandardUpdaterController

    init(automaticallyChecks: Bool) {
        // startingUpdater: true reads SUFeedURL and SUPublicEDKey from the
        // bundle's Info.plist, which the packaging script stamps in.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = automaticallyChecks
    }

    /// Begins a user-initiated check. Sparkle shows its own progress and
    /// install UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Pushes the user's Settings choice into Sparkle.
    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
