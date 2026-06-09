import HoneycrispCore
import SwiftUI

/// The menu bar app: hosts the MCP hub in process, shows the panel, runs
/// onboarding on first launch.
@main
struct HoneycrispApp: App {
    @State private var model: AppModel
    private let presenter: NotificationApprovalPresenter

    init() {
        let presenter = NotificationApprovalPresenter()
        let model = AppModel(presenter: presenter)
        presenter.model = model
        presenter.activate()
        self.presenter = presenter
        _model = State(initialValue: model)
        Task { @MainActor [model] in
            await model.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(model)
        } label: {
            if let glyph = BundledArt.menuBarGlyph() {
                Image(nsImage: glyph)
            } else {
                Image(systemName: "seal.fill")
            }
        }
        .menuBarExtraStyle(.window)

        Window("Set Up Honeycrisp", id: "onboarding") {
            OnboardingView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.config.onboardingCompleted ? .suppressed : .presented)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
