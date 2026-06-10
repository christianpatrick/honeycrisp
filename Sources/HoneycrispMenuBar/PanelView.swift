import HoneycrispCore
import SwiftUI

/// The menu bar panel: header, Status / Permissions / Activity, footer.
/// Layout and copy mirror the panel spec in the System direction.
struct PanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var tab: Tab = .status

    enum Tab: String, CaseIterable, Identifiable {
        case status = "Status"
        case permissions = "Permissions"
        case activity = "Activity"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 11)

            ThemedSegments(
                options: Tab.allCases.map { ($0, $0.rawValue) },
                selection: $tab
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 12) {
                    if !model.pendingApprovals.isEmpty {
                        PendingApprovalsView()
                    }
                    switch tab {
                    case .status:
                        StatusTab(goPermissions: { tab = .permissions }, goActivity: { tab = .activity })
                    case .permissions:
                        PermissionsTab()
                    case .activity:
                        ActivityTab()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
            // Explicit, not maxHeight: a ScrollView inside a MenuBarExtra
            // window collapses to zero ideal height under the window's
            // unconstrained proposal, taking the whole panel body with it.
            .frame(height: 470)

            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: 360)
        .honeycrispChrome()
        .task {
            await model.refresh()
        }
        .onAppear {
            Task { await model.refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = BundledArt.panelIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.red.gradient)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "seal.fill").font(.system(size: 13)).foregroundStyle(.white))
            }
            VStack(alignment: .leading, spacing: 1) {
                Wordmark(size: 15)
                Text(model.statusLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.toggleServer() }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.isRunning ? Theme.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(model.isRunning ? "Running" : "Paused")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(
                    Capsule().fill(
                        model.isRunning
                            ? Theme.green.opacity(0.13) : Color.secondary.opacity(0.12)))
                .foregroundStyle(model.isRunning ? Theme.greenText : .secondary)
            }
            .buttonStyle(.plain)
            .help(model.isRunning ? "Pause the server" : "Start the server")
        }
    }

    private var footer: some View {
        HStack {
            Button {
                // Accessory apps are not activated just because a window
                // appeared, so without this Settings opens behind every
                // other app.
                NSApplication.shared.activate()
                openSettings()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    NSApplication.shared.activate()
                    NSApplication.shared.windows
                        .first { $0.identifier?.rawValue.contains("Settings") == true }?
                        .makeKeyAndOrderFront(nil)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                    Text("Settings")
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
            Text("v\(HoneycrispInfo.version)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
        }
    }
}

// MARK: - Shared bits

/// A grouped, inset card like the design's Group rows.
struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

extension PermissionLevel {
    var label: String {
        switch self {
        case .off: return "No access"
        case .read: return "Read only"
        case .write: return "Read & write"
        }
    }

    var dotColor: Color {
        switch self {
        case .off: return .secondary.opacity(0.4)
        case .read: return Theme.gold
        case .write: return Color(red: 0x7E / 255, green: 0x9F / 255, blue: 0x46 / 255)
        }
    }
}

// MARK: - Pending approvals (fallback surface when a banner is missed)

struct PendingApprovalsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Waiting for you")
            GroupCard {
                ForEach(model.pendingApprovals) { approval in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(approval.prompt.message)
                            .font(.system(size: 12.5))
                        Text(approval.prompt.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Don't allow") {
                                Task { await model.resolveApproval(id: approval.id, approved: false) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("Allow once") {
                                Task { await model.resolveApproval(id: approval.id, approved: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    if approval.id != model.pendingApprovals.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}
