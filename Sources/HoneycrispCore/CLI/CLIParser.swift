import Foundation

/// What `honeycrisp serve` was asked to do.
public struct ServeOptions: Equatable, Sendable {
    /// Standalone loopback HTTP instead of stdio.
    public var port: UInt16?
    /// Restrict the standalone server to these apps; nil means all.
    public var apps: [AppID]?
    /// Drop every app to read in the standalone server.
    public var readOnly: Bool

    public init(port: UInt16? = nil, apps: [AppID]? = nil, readOnly: Bool = false) {
        self.port = port
        self.apps = apps
        self.readOnly = readOnly
    }
}

public enum CLICommand: Equatable, Sendable {
    case serve(ServeOptions)
    case version
    case help
}

public struct CLIError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

public enum CLIParser {
    public static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let first = arguments.first else { return .help }
        switch first {
        case "version", "--version", "-v":
            return .version
        case "help", "--help", "-h":
            return .help
        case "serve":
            return .serve(try serveOptions(Array(arguments.dropFirst())))
        default:
            throw CLIError(
                "honeycrisp does not know \u{201C}\(first)\u{201D}. Try serve, version, or help.")
        }
    }

    private static func serveOptions(_ arguments: [String]) throws -> ServeOptions {
        var options = ServeOptions()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--port":
                guard index + 1 < arguments.count, let port = UInt16(arguments[index + 1]) else {
                    throw CLIError("--port needs a number between 1 and 65535.")
                }
                options.port = port
                index += 2
            case "--apps":
                guard index + 1 < arguments.count else {
                    throw CLIError("--apps needs a comma separated list, like mail,reminders.")
                }
                var apps: [AppID] = []
                for raw in arguments[index + 1].split(separator: ",") {
                    let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
                    guard let app = AppID(rawValue: name) else {
                        throw CLIError(
                            "\u{201C}\(name)\u{201D} is not one of mail, reminders, calendar, messages, contacts."
                        )
                    }
                    apps.append(app)
                }
                options.apps = apps
                index += 2
            case "--read-only":
                options.readOnly = true
                index += 1
            default:
                throw CLIError("serve does not know the flag \u{201C}\(flag)\u{201D}.")
            }
        }
        return options
    }
}

/// Narrows a config for standalone serving. Bridged mode ignores these by
/// design: the app owns central policy.
public func applyServeFlags(_ options: ServeOptions, to config: HoneycrispConfig)
    -> HoneycrispConfig
{
    var narrowed = config
    if let apps = options.apps {
        for app in AppID.allCases where !apps.contains(app) {
            narrowed.setLevel(.off, for: app)
        }
    }
    if options.readOnly {
        for app in AppID.allCases where narrowed.level(for: app) == .write {
            narrowed.setLevel(.read, for: app)
        }
    }
    return narrowed
}
