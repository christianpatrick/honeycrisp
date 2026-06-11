import HoneycrispCore
import SwiftUI

/// First run, five steps:
/// Welcome, Allow access, What it can do, Connect, Done.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: WelcomeStep()
                case 1: AccessStep()
                case 2: ActionsStep()
                case 3: ConnectStep()
                default: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 30)
            .padding(.top, 26)

            footer
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
                .padding(.top, 13)
        }
        .frame(width: 480, height: 470)
        .honeycrispChrome()
    }

    private var footer: some View {
        HStack {
            Group {
                if step > 0 && step < 4 {
                    Button("Back") { step -= 1 }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 64, alignment: .leading)
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<5) { index in
                    Circle()
                        .fill(index == step ? Theme.red : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            Group {
                switch step {
                case 0:
                    primaryButton("Get started") { step = 1 }
                case 1:
                    primaryButton("Continue") { step = 2 }
                case 2:
                    primaryButton("Continue") { step = 3 }
                case 3:
                    primaryButton(model.clients.isEmpty ? "Skip for now" : "Continue") { step = 4 }
                default:
                    primaryButton("Open Honeycrisp") {
                        model.completeOnboarding()
                        dismiss()
                    }
                }
            }
            .frame(minWidth: 64, alignment: .trailing)
        }
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 10)
            if let icon = BundledArt.panelIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 74, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 11, y: 5)
            } else {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Theme.red.gradient)
                    .frame(width: 74, height: 74)
                    .overlay(
                        Image(systemName: "seal.fill").font(.system(size: 30)).foregroundStyle(
                            .white))
            }
            Text("Welcome to Honeycrisp")
                .font(.system(size: 24, weight: .semibold))
                .padding(.top, 18)
            Text(
                "Your assistant, finally fluent in your Mac. Honeycrisp lets the AI you already use read a mail thread, check what is due today, or pull up a contact, all in an instant."
            )
            .font(.system(size: 14.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .padding(.top, 9)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AccessStep: View {
    @State private var contacts = PermissionProbes.contactsGranted()
    @State private var reminders = PermissionProbes.remindersGranted()
    @State private var calendar = PermissionProbes.calendarGranted()
    @State private var fullDisk = PermissionProbes.fullDiskGranted()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Allow access to your apps")
                .font(.system(size: 19, weight: .semibold))
            Text(
                "macOS asks permission the first time Honeycrisp opens each app. You stay in control and can change this whenever you like."
            )
            .font(.system(size: 13.5))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .padding(.bottom, 16)

            VStack(spacing: 8) {
                AccessRow(
                    app: .mail,
                    blurb: "Needs Full Disk Access to read your mail index.",
                    granted: fullDisk
                ) {
                    PermissionProbes.openFullDiskSettings()
                }
                AccessRow(
                    app: .reminders,
                    blurb: "See what is due and add new ones.",
                    granted: reminders
                ) {
                    Task {
                        reminders = await PermissionProbes.requestReminders()
                    }
                }
                AccessRow(
                    app: .calendar,
                    blurb: "See your schedule and add events.",
                    granted: calendar
                ) {
                    Task {
                        calendar = await PermissionProbes.requestCalendar()
                    }
                }
                AccessRow(
                    app: .messages,
                    blurb: "Needs Full Disk Access to read recent texts.",
                    granted: fullDisk
                ) {
                    PermissionProbes.openFullDiskSettings()
                }
                AccessRow(
                    app: .contacts,
                    blurb: "Look up people you know.",
                    granted: contacts
                ) {
                    Task {
                        contacts = await PermissionProbes.requestContacts()
                    }
                }
            }
        }
        .task {
            // Re-probe while the user flips System Settings switches.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                contacts = PermissionProbes.contactsGranted()
                reminders = PermissionProbes.remindersGranted()
                calendar = PermissionProbes.calendarGranted()
                fullDisk = PermissionProbes.fullDiskGranted()
            }
        }
    }
}

private struct AccessRow: View {
    let app: AppID
    let blurb: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(app: app, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(ActionCatalog.apps.first { $0.id == app }?.name ?? "")
                    .font(.system(size: 14, weight: .semibold))
                Text(blurb)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    Text("Allowed").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Theme.greenText)
            } else {
                Button("Allow", action: request)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }
}

private struct ActionsStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose what it can do")
                .font(.system(size: 19, weight: .semibold))
            Text(
                "Start simple. Read lets the assistant look, write lets it draft and act. You can switch on individual actions later."
            )
            .font(.system(size: 13.5))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .padding(.bottom, 16)

            VStack(spacing: 9) {
                ForEach(ActionCatalog.apps, id: \.id) { app in
                    HStack(spacing: 12) {
                        AppIconView(app: app.id, size: 28)
                        Text(app.name).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        TriToggle(
                            value: model.config.level(for: app.id),
                            onChange: { model.setLevel($0, for: app.id) }
                        )
                        .fixedSize()
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(.background.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                    )
                }
            }
        }
    }
}

private struct ConnectStep: View {
    @Environment(AppModel.self) private var model
    @State private var client: Client = .claude

    enum Client: String, CaseIterable, Identifiable {
        case claude = "Claude Desktop"
        case cursor = "Cursor"
        case other = "Other"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connect your assistant")
                .font(.system(size: 19, weight: .semibold))
            Text(
                "Point your MCP client at Honeycrisp. It works with any client that speaks MCP, the same way it uses any other server."
            )
            .font(.system(size: 13.5))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .padding(.bottom, 14)

            ThemedSegments(
                options: Client.allCases.map { ($0, $0.rawValue) },
                selection: $client
            )
            .padding(.bottom, 12)

            Text(fileLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)
            ScrollView(.horizontal) {
                Text(snippet)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: 0.94, green: 0.91, blue: 0.85))
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(Color(red: 0.12, green: 0.11, blue: 0.11))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                if model.clients.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Waiting for a connection")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.greenText)
                    Text("\(model.clients.first?.name ?? "A client") is connected")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.greenText)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                }
                .controlSize(.small)
            }
            .padding(.top, 13)
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var cliPath: String {
        let bundled = Bundle.main.bundlePath + "/Contents/MacOS/honeycrisp-cli"
        return FileManager.default.fileExists(atPath: bundled) ? bundled : "honeycrisp"
    }

    private var fileLabel: String {
        switch client {
        case .claude: return "~/Library/Application Support/Claude/claude_desktop_config.json"
        case .cursor: return "~/.cursor/mcp.json"
        case .other: return "Terminal"
        }
    }

    private var snippet: String {
        switch client {
        case .claude, .cursor:
            return """
                {
                  "mcpServers": {
                    "honeycrisp": {
                      "command": "\(cliPath)",
                      "args": ["serve"]
                    }
                  }
                }
                """
        case .other:
            return "claude mcp add --transport http honeycrisp http://127.0.0.1:\(model.config.port)/mcp"
        }
    }
}

private struct DoneStep: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 12)
            ZStack {
                Circle().fill(Theme.green.opacity(0.13)).frame(width: 70, height: 70)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.green)
            }
            Text("You are all set")
                .font(.system(size: 23, weight: .semibold))
                .padding(.top, 18)
            Text(
                "Honeycrisp is running quietly in your menu bar. Click the seed up there any time to check what has been asked or change what your assistant can touch."
            )
            .font(.system(size: 14.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 350)
            .padding(.top, 9)
        }
        .frame(maxWidth: .infinity)
    }
}
