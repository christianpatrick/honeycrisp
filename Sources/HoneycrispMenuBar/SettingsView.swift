import HoneycrispCore
import ServiceManagement
import SwiftUI

/// Small, native settings: launch at login, the port, an optional bearer
/// token, and the activity list's retention.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var portText = ""
    @State private var tokenText = ""
    @State private var retention = 2000

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

            Section {
                Button("Open the config folder") {
                    NSWorkspace.shared.open(HoneycrispConfig.supportDirectoryURL)
                }
                LabeledContent("Version", value: HoneycrispInfo.version)
            } footer: {
                Text(
                    "Everything Honeycrisp knows lives in this folder, on this Mac. Nothing is uploaded, ever."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            portText = String(model.config.port)
            tokenText = model.config.bearerToken ?? ""
            retention = model.config.auditMaxEntries
        }
    }
}
