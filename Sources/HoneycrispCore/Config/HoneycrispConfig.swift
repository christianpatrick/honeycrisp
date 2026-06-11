import Foundation

/// What the user allowed an app to do overall. Write implies read.
public enum PermissionLevel: String, Codable, Sendable, Equatable {
    case off
    case read
    case write
}

/// Why a tool call was refused.
public enum DenialReason: String, Codable, Sendable, Equatable {
    case appOff
    case readOnlyApp
    case actionOff
    case unknownAction
}

/// The permission engine's verdict for one (app, action) pair.
public enum PermissionDecision: Equatable, Sendable {
    case allowed
    case needsApproval
    case denied(DenialReason)
}

/// The one config both the menu bar app and the CLI read and write.
public struct HoneycrispConfig: Codable, Equatable, Sendable {
    public var levels: [AppID: PermissionLevel]
    public var switches: [AppID: [String: Bool]]
    public var port: Int
    public var defaultLimit: Int
    public var defaultRemindersList: String?
    public var auditMaxEntries: Int
    public var bearerToken: String?
    public var loggingEnabled: Bool
    public var onboardingCompleted: Bool
    /// Whether the menu bar app checks for updates on its own. The user can
    /// turn this off in Settings and still check manually (HC-034).
    public var automaticUpdateChecks: Bool

    public static let `default`: HoneycrispConfig = {
        // Read-only out of the box: the assistant can read every app but
        // writes nothing until the user raises an app to write in the panel,
        // and outbound sends still need per-request approval on top. Building
        // through setLevel keeps levels and switches consistent: reads on,
        // writes off.
        var config = HoneycrispConfig(
            levels: [:],
            switches: [:],
            port: 41117,
            defaultLimit: 20,
            defaultRemindersList: nil,
            auditMaxEntries: 2000,
            bearerToken: nil,
            loggingEnabled: false,
            onboardingCompleted: false,
            automaticUpdateChecks: true
        )
        for app in AppID.allCases {
            config.setLevel(.read, for: app)
        }
        return config
    }()
}

// MARK: - Evaluation

extension HoneycrispConfig {
    public func level(for app: AppID) -> PermissionLevel {
        levels[app] ?? .off
    }

    public func isOn(app: AppID, action id: String) -> Bool {
        switches[app]?[id] ?? false
    }

    public func decision(app: AppID, action id: String) -> PermissionDecision {
        guard let descriptor = ActionCatalog.descriptor(app: app, action: id) else {
            return .denied(.unknownAction)
        }
        switch level(for: app) {
        case .off:
            return .denied(.appOff)
        case .read:
            // Levels gate before switches: a hand-edited config can carry an
            // enabled write switch under a read level, and it must not win.
            if descriptor.kind == .write { return .denied(.readOnlyApp) }
        case .write:
            break
        }
        guard isOn(app: app, action: id) else { return .denied(.actionOff) }
        return descriptor.requiresApproval ? .needsApproval : .allowed
    }

    /// The actions tools/list may surface: everything not denied.
    public func visibleActions(for app: AppID) -> [ActionDescriptor] {
        ActionCatalog.actions(for: app).filter {
            if case .denied = decision(app: app, action: $0.id) { return false }
            return true
        }
    }
}

// MARK: - Mutation

extension HoneycrispConfig {
    /// Simple mode is blunt and predictable (HC-016, superseding the
    /// mock-faithful HC-002 semantics that left write switches untouched):
    /// off clears everything, read turns reads on and writes off, and
    /// write turns every action on. Outbound sends keep their mandatory
    /// per-request approval regardless, so write never means silent sends.
    public mutating func setLevel(_ level: PermissionLevel, for app: AppID) {
        levels[app] = level
        for action in ActionCatalog.actions(for: app) {
            switch level {
            case .off:
                switches[app, default: [:]][action.id] = false
            case .read:
                switches[app, default: [:]][action.id] = action.kind == .read
            case .write:
                switches[app, default: [:]][action.id] = true
            }
        }
    }

    /// Advanced mode. Turning a switch on raises the level far enough that
    /// the switch is actually effective, so the UI never shows an enabled
    /// action the engine would silently deny. Turning one off never lowers
    /// the level.
    public mutating func setAction(_ id: String, on: Bool, for app: AppID) {
        guard let descriptor = ActionCatalog.descriptor(app: app, action: id) else { return }
        switches[app, default: [:]][id] = on
        guard on else { return }
        switch (descriptor.kind, level(for: app)) {
        case (.read, .off):
            levels[app] = .read
        case (.write, .off), (.write, .read):
            levels[app] = .write
        default:
            break
        }
    }
}

// MARK: - Tolerant decoding

extension HoneycrispConfig {
    private enum CodingKeys: String, CodingKey {
        case levels
        case switches
        case port
        case defaultLimit
        case defaultRemindersList
        case auditMaxEntries
        case bearerToken
        case loggingEnabled
        case onboardingCompleted
        case automaticUpdateChecks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = HoneycrispConfig.default

        // App-keyed maps decode through plain strings so unknown apps,
        // unknown actions, and unknown level values degrade to defaults
        // instead of failing the whole file.
        var levels = fallback.levels
        if let raw = try container.decodeIfPresent([String: String].self, forKey: .levels) {
            for (key, value) in raw {
                if let app = AppID(rawValue: key), let level = PermissionLevel(rawValue: value) {
                    levels[app] = level
                }
            }
        }
        var switches = fallback.switches
        if let raw = try container.decodeIfPresent([String: [String: Bool]].self, forKey: .switches) {
            for (key, value) in raw {
                guard let app = AppID(rawValue: key) else { continue }
                for action in ActionCatalog.actions(for: app) {
                    if let on = value[action.id] {
                        switches[app, default: [:]][action.id] = on
                    }
                }
            }
        }
        self.levels = levels
        self.switches = switches
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? fallback.port
        self.defaultLimit =
            try container.decodeIfPresent(Int.self, forKey: .defaultLimit) ?? fallback.defaultLimit
        self.defaultRemindersList = try container.decodeIfPresent(
            String.self, forKey: .defaultRemindersList)
        self.auditMaxEntries =
            try container.decodeIfPresent(Int.self, forKey: .auditMaxEntries)
            ?? fallback.auditMaxEntries
        self.bearerToken = try container.decodeIfPresent(String.self, forKey: .bearerToken)
        self.loggingEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .loggingEnabled)
            ?? fallback.loggingEnabled
        self.onboardingCompleted =
            try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted)
            ?? fallback.onboardingCompleted
        self.automaticUpdateChecks =
            try container.decodeIfPresent(Bool.self, forKey: .automaticUpdateChecks)
            ?? fallback.automaticUpdateChecks
    }
}

// MARK: - Persistence

extension HoneycrispConfig {
    /// ~/Library/Application Support/honeycrisp, shared by the app and CLI.
    public static var supportDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("honeycrisp", isDirectory: true)
    }

    public static var defaultFileURL: URL {
        supportDirectoryURL.appendingPathComponent("config.json")
    }

    /// Never throws and never touches the file: a missing or unreadable
    /// config means the defaults, and the broken file stays put for the
    /// user to inspect.
    public static func load(from url: URL = defaultFileURL) -> HoneycrispConfig {
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(HoneycrispConfig.self, from: data)
        else {
            return .default
        }
        return config
    }

    public func save(to url: URL = Self.defaultFileURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
