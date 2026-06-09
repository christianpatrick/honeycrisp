import Foundation
import HoneycrispCore

/// The honeycrisp command. `serve` speaks MCP over stdio: it bridges to the
/// menu bar app when the app's loopback server answers, and serves
/// standalone otherwise (where approval-required actions fail closed, since
/// only the app can ask you anything).
@main
struct HoneycrispCommand {
    static func main() async {
        let command: CLICommand
        do {
            command = try CLIParser.parse(Array(CommandLine.arguments.dropFirst()))
        } catch let error as CLIError {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            exit(64)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(64)
        }

        switch command {
        case .version:
            print("honeycrisp \(HoneycrispInfo.version)")
        case .help:
            print(Self.helpText)
        case .serve(let options):
            await serve(options)
        }
    }

    private static func serve(_ options: ServeOptions) async {
        let configProvider: @Sendable () -> HoneycrispConfig = {
            applyServeFlags(options, to: HoneycrispConfig.load())
        }
        let config = configProvider()
        let audit = AuditStore(
            fileURL: HoneycrispConfig.supportDirectoryURL.appendingPathComponent("audit.jsonl"),
            maxEntries: config.auditMaxEntries
        )
        let executor = ServiceExecutor.production(configProvider: configProvider)

        if let port = options.port {
            // Standalone loopback HTTP, mostly useful for development.
            await serveHTTP(
                port: port, configProvider: configProvider, executor: executor, audit: audit)
            return
        }

        if await MCPProxy.hubIsReachable(port: config.port) {
            await bridge(port: config.port, token: config.bearerToken)
            return
        }

        do {
            try await HoneycrispServer.runStdio(
                configProvider: configProvider,
                executor: executor,
                audit: audit,
                approvals: nil
            )
        } catch {
            FileHandle.standardError.write(Data("honeycrisp: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func serveHTTP(
        port: UInt16,
        configProvider: @escaping @Sendable () -> HoneycrispConfig,
        executor: ServiceExecutor,
        audit: AuditStore
    ) async {
        let clients = ClientRegistry()
        let gateway = ToolGateway(
            configProvider: configProvider,
            executor: executor,
            audit: audit,
            approvals: nil
        )
        let router = MCPHTTPRouter(gateway: gateway, clients: clients)
        do {
            let server = try await LoopbackHTTPServer.start(
                port: port, bearerToken: configProvider().bearerToken, router: router)
            FileHandle.standardError.write(
                Data("honeycrisp serving on http://127.0.0.1:\(server.port)/mcp\n".utf8))
            while true {
                try await Task.sleep(for: .seconds(3600))
            }
        } catch {
            FileHandle.standardError.write(Data("honeycrisp: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func bridge(port: Int, token: String?) async {
        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else { return }
        let lines = AsyncStream<String> { continuation in
            Task.detached {
                do {
                    for try await line in FileHandle.standardInput.bytes.lines {
                        continuation.yield(line)
                    }
                } catch {}
                continuation.finish()
            }
        }
        await MCPProxy.run(
            lines: lines,
            post: { body, client in
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = body
                request.timeoutInterval = 300
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let token {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                if let client {
                    request.setValue(client, forHTTPHeaderField: "X-Honeycrisp-Client")
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 202 { return nil }
                return data
            },
            write: { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
        )
    }

    private static let helpText = """
        honeycrisp \(HoneycrispInfo.version)

        A local MCP server for macOS that gives your assistant fast, private,
        native access to Mail, Reminders, Messages, and Contacts.

        Usage:
          honeycrisp serve [--port N] [--apps mail,reminders] [--read-only]
          honeycrisp version

        serve speaks MCP over stdio. When the Honeycrisp menu bar app is
        running, serve bridges to it so approvals, the audit log, and your
        permission settings all live in one place. When the app is not
        running, serve runs standalone with the same config file, and
        actions that need your approval fail closed.

        --port N      Serve loopback HTTP on 127.0.0.1:N instead of stdio.
        --apps LIST   Standalone only: expose just these apps.
        --read-only   Standalone only: never write, send, or change anything.
        """
}
