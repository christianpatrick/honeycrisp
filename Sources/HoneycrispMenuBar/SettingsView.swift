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

/// Native settings in toolbar tabs (HC-043). Each tab is a grouped form
/// sized to its content, so the window resizes per tab and the tallest
/// one still fits a 13-inch laptop screen.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ServerSettings()
                .tabItem { Label("Server", systemImage: "server.rack") }
            RemoteAccessSettings()
                .tabItem { Label("Remote Access", systemImage: "network") }
            ActivitySettings()
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
        }
        .honeycrispChrome()
        .background(
            WindowConfigurator { window in
                // Come to the user's current Space instead of switching
                // macOS to the Space this window last lived on.
                window.collectionBehavior.insert(.moveToActiveSpace)
            }
        )
        .onAppear {
            Task { await model.refresh() }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var updater: UpdaterModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoUpdates = true

    var body: some View {
        Form {
            Section {
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

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoUpdates)
                    .onChange(of: autoUpdates) { _, enabled in
                        model.updateAutomaticUpdateChecks(enabled)
                        updater.setAutomaticChecks(enabled)
                    }
                LabeledContent("Version \(HoneycrispInfo.version)") {
                    Button("Check for Updates Now") {
                        updater.checkForUpdates()
                    }
                }
            }

            Section {
                LabeledContent {
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(HoneycrispConfig.supportDirectoryURL)
                    }
                } label: {
                    Text("Config folder")
                    Text("Settings and the activity list live here, on this Mac.")
                }
            }
        }
        .settingsPane()
        .onAppear {
            autoUpdates = model.config.automaticUpdateChecks
        }
    }
}

// MARK: - Server

private struct ServerSettings: View {
    @Environment(AppModel.self) private var model
    @State private var portText = ""
    @State private var tokenText = ""

    var body: some View {
        let endpoint = "http://127.0.0.1:\(model.config.port)/mcp"
        Form {
            Section {
                TextField("Port", text: $portText, prompt: Text("41117"))
                    .onSubmit {
                        if let port = Int(portText), (1024...65535).contains(port) {
                            Task { await model.updatePort(port) }
                        } else {
                            portText = String(model.config.port)
                        }
                    }
                TextField(
                    "Bearer token", text: $tokenText,
                    prompt: Text("Optional, leave empty for none")
                )
                .onSubmit {
                    Task { await model.updateBearerToken(tokenText) }
                }
                LabeledContent("Endpoint") {
                    HStack(spacing: 6) {
                        Text(endpoint).textSelection(.enabled)
                        CopyButton(value: endpoint, help: "Copy the endpoint")
                    }
                }
            } footer: {
                SettingsFooter("Clients on this Mac connect to this address. It only answers on loopback.")
            }
        }
        .settingsPane()
        .onAppear {
            portText = String(model.config.port)
            tokenText = model.config.bearerToken ?? ""
        }
    }
}

// MARK: - Remote access

private struct RemoteAccessSettings: View {
    @Environment(AppModel.self) private var model
    @State private var remoteEnabled = false
    @State private var publicURLText = ""
    @State private var publicURLRejected = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow remote clients through your own tunnel", isOn: $remoteEnabled)
                    .onChange(of: remoteEnabled) { _, enabled in
                        Task { await model.updateRemoteAccess(enabled) }
                    }
                if remoteEnabled {
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
                    LabeledContent(
                        "Point your tunnel at", value: "http://127.0.0.1:\(model.config.remotePort)")
                    LabeledContent("Status", value: remoteStatus)
                    if let connector = model.remoteConnectorURL {
                        LabeledContent("Connector URL") {
                            HStack(spacing: 6) {
                                Text(connector).textSelection(.enabled)
                                CopyButton(value: connector, help: "Copy the connector URL")
                            }
                        }
                    }
                }
            } footer: {
                if !remoteEnabled {
                    SettingsFooter(
                        "Reach Honeycrisp from another device through a tunnel you run, such as Tailscale Funnel. Honeycrisp never relays your data through a server of its own."
                    )
                }
            }

            if remoteEnabled {
                Section("Passkeys") {
                    LabeledContent {
                        if case .running = model.remoteState {
                            HStack {
                                Button("Add a Passkey") {
                                    Task {
                                        if let link = await model.remoteSetupLink() {
                                            NSWorkspace.shared.open(link)
                                        }
                                    }
                                }
                                Button("Copy Setup Link") {
                                    Task {
                                        if let link = await model.remoteSetupLink() {
                                            copyToPasteboard(link.absoluteString)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(passkeySummary)
                    }
                    if !model.remotePasskeys.isEmpty {
                        LabeledContent {
                            Button("Remove Passkeys", role: .destructive) {
                                Task { await model.removePasskeys() }
                            }
                        } label: {
                            Text("New clients cannot connect until you add a passkey again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !model.remoteGrants.isEmpty {
                    Section("Connected clients") {
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
                }
            }
        }
        .settingsPane()
        .onAppear {
            remoteEnabled = model.config.remoteAccessEnabled
            publicURLText = model.config.publicURL ?? ""
        }
    }

    private var passkeySummary: String {
        switch model.remotePasskeys.count {
        case 0: return "No passkeys yet"
        case 1: return "1 passkey can approve new clients"
        case let count: return "\(count) passkeys can approve new clients"
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

// MARK: - Activity

private struct ActivitySettings: View {
    @Environment(AppModel.self) private var model
    @State private var retention = 2000

    var body: some View {
        Form {
            Section {
                Picker("Keep", selection: $retention) {
                    ForEach(AuditRetention.choices(including: retention), id: \.self) { count in
                        Text("\(count.formatted()) entries").tag(count)
                    }
                }
                .onChange(of: retention) { _, value in
                    model.updateAuditRetention(value)
                }
                LabeledContent("Activity list") {
                    Button("Clear the Activity List") {
                        Task { await model.clearActivity() }
                    }
                }
            } footer: {
                SettingsFooter("The activity list is stored only on this Mac. Clearing it cannot be undone.")
            }
        }
        .settingsPane()
        .onAppear {
            retention = model.config.auditMaxEntries
        }
    }
}

// MARK: - Shared pieces

private struct SettingsFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CopyButton: View {
    let value: String
    let help: String

    var body: some View {
        Button {
            copyToPasteboard(value)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

private func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

extension View {
    /// One fixed width for every tab, height from the content, so the
    /// Settings window resizes as the user switches tabs.
    fileprivate func settingsPane() -> some View {
        formStyle(.grouped)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
    }
}
