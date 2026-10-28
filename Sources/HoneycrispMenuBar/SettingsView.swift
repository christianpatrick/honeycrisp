import AppKit
import HoneycrispCore
import ServiceManagement
import SwiftUI

/// Grabs the hosting NSWindow once the view lands in one and applies
/// configuration. Reapplication must be idempotent.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            if let window = nsView?.window { configure(window) }
        }
    }
}

/// Small, native settings: launch at login, the port, an optional bearer
/// token, remote access, and the activity list's retention.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var updater: UpdaterModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var portText = ""
    @State private var tokenText = ""
    @State private var retention = 2000
    @State private var autoUpdates = true
    @State private var remoteEnabled = false
    @State private var publicURLText = ""
    @State private var publicURLRejected = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch Honeycrisp at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Server") {
                TextField("Port", text: $portText, prompt: Text("41117"))
                    .onSubmit {
                        if let port = Int(portText), (1024...65535).contains(port) {
                            Task { await model.updatePort(port) }
                        } else {
                            portText = String(model.config.port)
                        }
                    }
                TextField(
                    "Bearer token (optional)", text: $tokenText,
                    prompt: Text("Leave empty for none")
                )
                .onSubmit {
                    Task { await model.updateBearerToken(tokenText) }
                }
                LabeledContent(
                    "Endpoint", value: "http://127.0.0.1:\(model.config.port)/mcp")
            }

            Section("Remote access") {
                Toggle("Allow remote clients through your own tunnel", isOn: $remoteEnabled)
                    .onChange(of: remoteEnabled) { _, enabled in
                        Task { await model.updateRemoteAccess(enabled) }
                    }
                TextField(
                    "Public URL", text: $publicURLText,
                    prompt: Text("https://your-mac.your-tailnet.ts.net")
                )
                .onSubmit {
                    Task {
                        let saved = await model.updatePublicURL(publicURLText)
                        publicURLRejected = !saved
                        if saved { publicURLText = model.config.publicURL ?? "" }
                    }
                }
                if publicURLRejected {
                    Text("Use the https address your tunnel serves, with nothing after it but /mcp.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Point your tunnel at", value: "http://127.0.0.1:\(model.config.remotePort)")
                LabeledContent("Status", value: remoteStatus)
                if let connector = model.remoteConnectorURL {
                    LabeledContent("Connector URL") {
                        Text(connector).textSelection(.enabled)
                    }
                }
                if case .running = model.remoteState {
                    HStack {
                        Button("Add a passkey") {
                            Task {
                                if let link = await model.remoteSetupLink() {
                                    NSWorkspace.shared.open(link)
                                }
                            }
                        }
                        Button("Copy setup link") {
                            Task {
                                if let link = await model.remoteSetupLink() {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                                }
                            }
                        }
                    }
                }
                LabeledContent("Passkeys", value: "\(model.remotePasskeys.count)")
                if !model.remotePasskeys.isEmpty {
                    Button("Remove passkeys", role: .destructive) {
                        Task { await model.removePasskeys() }
                    }
                }
                ForEach(model.remoteGrants) { grant in
                    LabeledContent {
                        Button("Disconnect") {
                            Task { await model.disconnectRemote(grantID: grant.id) }
                        }
                    } label: {
                        Text(grant.clientName)
                        Text("Connected \(grant.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }

            Section("Activity") {
                Stepper(value: $retention, in: 100...20000, step: 100) {
                    LabeledContent("Keep", value: "\(retention) entries")
                }
                .onChange(of: retention) { _, value in
                    model.updateAuditRetention(value)
                }
                Button("Clear the activity list") {
                    Task { await model.clearActivity() }
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoUpdates)
                    .onChange(of: autoUpdates) { _, enabled in
                        model.updateAutomaticUpdateChecks(enabled)
                        updater.setAutomaticChecks(enabled)
                    }
                Button("Check for Updates Now") {
                    updater.checkForUpdates()
                }
            }

            Section {
                Button("Open the config folder") {
                    NSWorkspace.shared.open(HoneycrispConfig.supportDirectoryURL)
                }
                LabeledContent("Version", value: HoneycrispInfo.version)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .honeycrispChrome()
        .background(
            WindowConfigurator { window in
                // Come to the user's current Space instead of switching
                // macOS to the Space this window last lived on.
                window.collectionBehavior.insert(.moveToActiveSpace)
            }
        )
        .onAppear {
            portText = String(model.config.port)
            tokenText = model.config.bearerToken ?? ""
            retention = model.config.auditMaxEntries
            autoUpdates = model.config.automaticUpdateChecks
            remoteEnabled = model.config.remoteAccessEnabled
            publicURLText = model.config.publicURL ?? ""
            Task { await model.refresh() }
        }
    }

    private var remoteStatus: String {
        switch model.remoteState {
        case .off:
            return model.config.remoteAccessEnabled ? "Starts with the server" : "Off"
        case .needsPublicURL:
            return "Waiting for a public URL"
        case .running(let port):
            return "Listening on port \(port)"
        case .failed(let message):
            return message
        }
    }
}
