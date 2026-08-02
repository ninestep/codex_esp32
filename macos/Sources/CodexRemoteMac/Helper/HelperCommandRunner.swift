import CodexRemoteCore
import Foundation

public struct HelperCommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct HelperCommandRunner: Sendable {
    private let socketClient: any LocalIPCClienting

    public init(socketClient: any LocalIPCClienting = LocalIPCClient()) {
        self.socketClient = socketClient
    }

    public func run(arguments: [String], stdin: Data, environment: [String: String]) async -> HelperCommandResult {
        guard let command = arguments.first else {
            return usage("command required")
        }

        let parser = OptionParser(arguments: Array(arguments.dropFirst()))
        switch command {
        case "register-launch":
            return await registerLaunch(parser)
        case "hook":
            return await hook(parser, stdin: stdin, environment: environment)
        case "list":
            return await list(parser)
        case "focus":
            return await commandWithSession(parser, makeRequest: LocalIPCRequest.focus(remoteSessionID:))
        case "scroll":
            return await scroll(parser)
        case "key":
            return await key(parser)
        case "serve":
            return usage("serve is only available through the process entrypoint")
        default:
            return usage("unknown command: \(command)")
        }
    }

    private func registerLaunch(_ parser: OptionParser) async -> HelperCommandResult {
        do {
            let socketURL = try parser.requiredURL("--socket")
            let launcherID = try parser.required("--launcher")
            return await sendExpectingOK(.registerLaunch(launcherID: launcherID), to: socketURL)
        } catch {
            return usage(String(describing: error))
        }
    }

    private func hook(_ parser: OptionParser, stdin: Data, environment: [String: String]) async -> HelperCommandResult {
        let socketURL: URL
        do {
            socketURL = try parser.requiredURL("--socket")
        } catch {
            return usage(String(describing: error))
        }

        let payload: HookPayload
        do {
            payload = try RawHookPayloadMapper(processEnvironment: environment).map(stdin)
        } catch {
            return HelperCommandResult(exitCode: 65, stderr: "codex-remote-helper: malformed hook: \(hookMappingDiagnostic(error))\n")
        }
        return await sendExpectingOK(.hook(payload), to: socketURL)
    }

    private func list(_ parser: OptionParser) async -> HelperCommandResult {
        do {
            let socketURL = try parser.requiredURL("--socket")
            guard parser.has("--json") else {
                return usage("missing --json")
            }
            let response = try await socketClient.send(.list, to: socketURL)
            guard case .sessions(let sessions) = response else {
                return daemonFailure(response)
            }
            let stdout = try String(decoding: LocalIPCCodec().encodeResponse(.sessions(sessions)), as: UTF8.self)
            return HelperCommandResult(exitCode: 0, stdout: stdout)
        } catch let error as HelperOptionError {
            return usage(String(describing: error))
        } catch {
            return daemonUnavailable(error)
        }
    }

    private func commandWithSession(
        _ parser: OptionParser,
        makeRequest: (String) -> LocalIPCRequest
    ) async -> HelperCommandResult {
        do {
            let socketURL = try parser.requiredURL("--socket")
            let sessionID = try parser.required("--session")
            return await sendExpectingOK(makeRequest(sessionID), to: socketURL)
        } catch {
            return usage(String(describing: error))
        }
    }

    private func scroll(_ parser: OptionParser) async -> HelperCommandResult {
        do {
            let socketURL = try parser.requiredURL("--socket")
            let sessionID = try parser.required("--session")
            guard let delta = Int(try parser.required("--delta")) else {
                return usage("invalid --delta")
            }
            return await sendExpectingOK(.scroll(remoteSessionID: sessionID, deltaY: delta), to: socketURL)
        } catch {
            return usage(String(describing: error))
        }
    }

    private func key(_ parser: OptionParser) async -> HelperCommandResult {
        do {
            let socketURL = try parser.requiredURL("--socket")
            let sessionID = try parser.required("--session")
            guard let key = TerminalKey(rawValue: try parser.required("--key")) else {
                return usage("invalid --key")
            }
            return await sendExpectingOK(.key(remoteSessionID: sessionID, key: key), to: socketURL)
        } catch {
            return usage(String(describing: error))
        }
    }

    private func sendExpectingOK(_ request: LocalIPCRequest, to socketURL: URL) async -> HelperCommandResult {
        do {
            let response = try await socketClient.send(request, to: socketURL)
            guard response == .ok else {
                return daemonFailure(response)
            }
            return HelperCommandResult(exitCode: 0)
        } catch {
            return daemonUnavailable(error)
        }
    }

    private func usage(_ message: String) -> HelperCommandResult {
        HelperCommandResult(exitCode: 64, stderr: "codex-remote-helper: \(message)\n")
    }

    private func daemonFailure(_ response: LocalIPCResponse) -> HelperCommandResult {
        switch response {
        case .error(let code):
            return HelperCommandResult(exitCode: 69, stderr: "codex-remote-helper: daemon error: \(code.rawValue)\n")
        default:
            return HelperCommandResult(exitCode: 69, stderr: "codex-remote-helper: unexpected daemon response\n")
        }
    }

    private func daemonUnavailable(_ error: Error) -> HelperCommandResult {
        HelperCommandResult(exitCode: 69, stderr: "codex-remote-helper: daemon unavailable\n")
    }

    private func hookMappingDiagnostic(_ error: Error) -> String {
        switch error {
        case RawHookPayloadMappingError.missingField(let field):
            field
        case RawHookPayloadMappingError.malformedJSON:
            "malformed_json"
        default:
            "invalid_hook"
        }
    }
}

private struct OptionParser: Sendable {
    private let options: [String: String]
    private let flags: Set<String>

    init(arguments: [String]) {
        var parsed: [String: String] = [:]
        var parsedFlags: Set<String> = []
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--") else {
                index += 1
                continue
            }
            let nextIndex = index + 1
            if nextIndex < arguments.count, !arguments[nextIndex].hasPrefix("--") {
                parsed[key] = arguments[nextIndex]
                index += 2
            } else {
                parsedFlags.insert(key)
                index += 1
            }
        }
        self.options = parsed
        self.flags = parsedFlags
    }

    func has(_ name: String) -> Bool {
        options.keys.contains(name) || flags.contains(name)
    }

    func required(_ name: String) throws -> String {
        guard let value = options[name], !value.isEmpty else {
            throw HelperOptionError.missing(name)
        }
        return value
    }

    func requiredURL(_ name: String) throws -> URL {
        URL(fileURLWithPath: try required(name))
    }
}

private enum HelperOptionError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case .missing(let option):
            "missing \(option)"
        }
    }
}
