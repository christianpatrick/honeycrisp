import HoneycrispCore
import SwiftUI

// MARK: - Status

struct StatusTab: View {
    @Environment(AppModel.self) private var model
    let goPermissions: () -> Void
    let goActivity: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                GlanceTile(
                    value: "\(model.counts.requestsToday)",
                    label: "Requests today",
                    sub: nil,
                    tone: .primary,
                    action: goActivity)
                GlanceTile(
                    value: "\(model.counts.approvedLastDay)",
                    label: "You approved",
                    sub: "in the last day",
                    tone: .gold,
                    action: goActivity)
            }

            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Connected clients")
                GroupCard {
                    if model.clients.isEmpty {
                        Text(
                            model.isRunning
                                ? "No clients yet. Point an MCP client at honeycrisp serve."
                                : "The server is paused."
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11)
                    }
                    ForEach(model.clients) { client in
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Theme.red.opacity(0.12))
                                Text(String(client.name.prefix(1)))
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Theme.red)
                            }
                            .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(client.name)
                                    .font(.system(size: 13.5, weight: .semibold))
                                Text("Connected since \(client.since, format: .dateTime.hour().minute())")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(model.isRunning ? Theme.green : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        if client.id != model.clients.last?.id {
                            Divider()
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "Access")
                    Spacer()
                    Button("Manage", action: goPermissions)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.red)
                }
                GroupCard {
                    ForEach(ActionCatalog.apps, id: \.id) { app in
                        let level = model.config.level(for: app.id)
                        HStack(spacing: 10) {
                            AppIconView(app: app.id, size: 24)
                            Text(app.name)
                                .font(.system(size: 13.5, weight: .medium))
                            Spacer()
                            Circle().fill(level.dotColor).frame(width: 7, height: 7)
                            Text(level.label)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        if app.id != ActionCatalog.apps.last?.id {
                            Divider()
                        }
                    }
                }
            }

        }
    }
}

struct GlanceTile: View {
    enum Tone { case primary, gold }
    let value: String
    let label: String
    let sub: String?
    let tone: Tone
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(tone == .gold ? Theme.gold : .primary)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let sub {
                    Text(sub)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.background.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Permissions

struct PermissionsTab: View {
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .simple
    @State private var openApp: AppID?

    enum Mode: String, CaseIterable, Identifiable {
        case simple = "Simple"
        case advanced = "Advanced"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 11) {
            HStack {
                Text(mode == .simple ? "Choose what each app may do." : "Turn individual actions on or off.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                ThemedSegments(
                    options: Mode.allCases.map { ($0, $0.rawValue) },
                    selection: $mode
                )
                .fixedSize()
            }

            if mode == .simple {
                ForEach(ActionCatalog.apps, id: \.id) { app in
                    SimpleAppCard(app: app)
                }
            } else {
                ForEach(ActionCatalog.apps, id: \.id) { app in
                    AdvancedAppCard(app: app, isOpen: openApp == app.id) {
                        openApp = openApp == app.id ? nil : app.id
                    }
                }
            }
        }
    }
}

struct SimpleAppCard: View {
    @Environment(AppModel.self) private var model
    let app: AppDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                AppIconView(app: app.id, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 14, weight: .semibold))
                    Text(app.blurb).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            TriToggle(
                value: model.config.level(for: app.id),
                onChange: { model.setLevel($0, for: app.id) }
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }
}

/// Off / Read / Read & write, red when granting, like the design's control.
struct TriToggle: View {
    let value: PermissionLevel
    let onChange: (PermissionLevel) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(.off, "Off")
            segment(.read, "Read")
            segment(.write, "Read & write")
        }
        .padding(2)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func segment(_ level: PermissionLevel, _ label: String) -> some View {
        let selected = value == level
        return Button {
            onChange(level)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .padding(.vertical, 4)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            selected
                                ? (level == .off ? Color(nsColor: .controlBackgroundColor) : Theme.red)
                                : .clear)
                )
                .foregroundStyle(selected ? (level == .off ? .primary : Color.white) : .secondary)
        }
        .buttonStyle(.plain)
    }
}

struct AdvancedAppCard: View {
    @Environment(AppModel.self) private var model
    let app: AppDescriptor
    let isOpen: Bool
    let toggleOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggleOpen) {
                HStack(spacing: 10) {
                    AppIconView(app: app.id, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).font(.system(size: 14, weight: .semibold))
                        Text(onCountText).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Divider()
                ForEach(ActionCatalog.actions(for: app.id), id: \.id) { action in
                    HStack(spacing: 9) {
                        Text(action.label)
                            .font(.system(size: 13))
                        Spacer()
                        Text(action.kind == .write ? "WRITE" : "READ")
                            .font(.system(size: 9, weight: .bold))
                            .kerning(0.3)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 6)
                            .background(
                                (action.kind == .write ? Theme.red : Theme.gold).opacity(0.12))
                            .foregroundStyle(action.kind == .write ? Theme.red : Theme.gold)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { model.config.isOn(app: app.id, action: action.id) },
                                set: { model.setAction(action.id, on: $0, for: app.id) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    if action.id != ActionCatalog.actions(for: app.id).last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .background(.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }

    private var onCountText: String {
        let actions = ActionCatalog.actions(for: app.id)
        let on = actions.filter { model.config.isOn(app: app.id, action: $0.id) }.count
        return "\(on) of \(actions.count) actions on"
    }
}

// MARK: - Activity

struct ActivityTab: View {
    @Environment(AppModel.self) private var model
    @State private var openEntries: Set<UUID> = []
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Today")
            if model.entries.isEmpty {
                GroupCard {
                    Text("Nothing has been asked yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11)
                }
            } else {
                GroupCard {
                    let shown = showAll ? model.entries : Array(model.entries.prefix(8))
                    ForEach(shown) { entry in
                        AuditRow(entry: entry, isOpen: openEntries.contains(entry.id)) {
                            if openEntries.contains(entry.id) {
                                openEntries.remove(entry.id)
                            } else {
                                openEntries.insert(entry.id)
                            }
                        }
                        if entry.id != shown.last?.id {
                            Divider()
                        }
                    }
                }
                if model.entries.count > 8 && !showAll {
                    Button("Open full history") { showAll = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.red)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct AuditRow: View {
    let entry: AuditEntry
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    AppIconView(app: entry.app, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.action)
                            .font(.system(size: 13, weight: .medium))
                            .multilineTextAlignment(.leading)
                        Text("\(entry.client) · \(entry.timestamp, format: .relative(presentation: .named))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        OutcomeBadge(outcome: entry.outcome)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 7) {
                    Text(entry.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        ForEach(entry.rows.indices, id: \.self) { index in
                            GridRow {
                                Text(entry.rows[index].label.uppercased())
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(entry.rows[index].value)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                        }
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.leading, 45)
                .padding(.trailing, 11)
                .padding(.bottom, 11)
            }
        }
    }
}

struct OutcomeBadge: View {
    let outcome: AuditOutcome

    var body: some View {
        let style: (label: String, mark: String, color: Color) =
            switch outcome {
            case .allowed: ("Allowed", "checkmark", Theme.greenText)
            case .denied: ("Blocked", "xmark", Theme.red)
            case .asked: ("You approved", "questionmark", Theme.gold)
            }
        HStack(spacing: 4) {
            Image(systemName: style.mark).font(.system(size: 8, weight: .bold))
            Text(style.label).font(.system(size: 11, weight: .semibold))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 7)
        .background(style.color.opacity(0.13))
        .foregroundStyle(style.color)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
