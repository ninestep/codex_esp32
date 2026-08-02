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
    private let hookQueue: any HookEventQueueing

    public init(socketClient: any LocalIPCClienting = LocalIPCClient(), hookQueue: any HookEventQueueing = HookEventQueue()) {
        self.socketClient = socketClient
        self.hookQueue = hookQueue
    }

    public func run(arguments: [String], stdin: Data, environment: [String: String]) async -> HelperCommandResult {
        guard let command = arguments.first else {
            return usage("command required")
        }

        switch command {
        case "register-launch":
            return await registerLaunch(arguments: Array(arguments.dropFirst()))
        case "hook":
            return await hook(arguments: Array(arguments.dropFirst()), stdin: stdin, environment: environment)
        case "list":
            return await list(arguments: Array(arguments.dropFirst()))
        case "focus":
            return await commandWithSession(arguments: Array(arguments.dropFirst()), makeRequest: LocalIPCRequest.focus(remoteSessionID:))
        case "scroll":
            return await scroll(arguments: Array(arguments.dropFirst()))
        case "key":
            return await key(arguments: Array(arguments.dropFirst()))
        case "serve":
            return usage("serve is only available through the process entrypoint")
        default:
            return usage("unknown command: \(command)")
        }
    }

    private func registerLaunch(arguments: [String]) async -> HelperCommandResult {
        do {
            let parser = try HelperOptionParser(arguments: arguments, valuedOptions: ["--socket", "--launcher"], flags: [])
            let socketURL = try parser.requiredURL("--socket")
            let launcherID = try parser.required("--launcher")
            return await sendExpectingOK(.registerLaunch(launcherID: launcherID), to: socketURL)
        } catch {
            return usage(String(describing: error))
        }
    }

    private func hook(arguments: [String], stdin: Data, environment: [String: String]) async -> HelperCommandResult {
        let socketURL: URL
        do {
            let parser = try HelperOptionParser(arguments: arguments, valuedOptions: ["--socket"], flags: [])
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
        do {
            let response = try await socketClient.send(.hook(payload), to: socketURL)
            guard response == .ok else {
                return daemonFailure(response)
            }
            return HelperCommandResult(exitCode: 0)
        } catch {
            guard isQueueableHookTransportError(error) else {
                return daemonUnavailable(error)
            }
            do {
                try await hookQueue.enqueue(payload, forSocketAt: socketURL)
                return HelperCommandResult(exitCode: 0, stderr: "codex-remote-helper: hook queued\n")
            } catch {
                return daemonUnavailable(error)
            }
        }
    }

    private func list(arguments: [String]) async -> HelperCommandResult {
        do {
            let parser = try HelperOptionParser(arguments: arguments, valuedOptions: ["--socket"], flags: ["--json"])
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
        arguments: [String],
        makeRequest: (String) -> LocalIPCRequest
    ) async -> HelperCommandResult {
        do {
            let parser = try HelperOptionParser(arguments: arguments, valuedOptions: ["--socket", "--session"], flags: [])
            let socketURL = try parser.requiredURL("--socket")
            let sessionID = try parser.required("--session")
            return await sendExpectingOK(makeRequest(sessionID), to: socketURL)
        } catch {
            return usage(String(describing: error))
        }
    }

    private func scroll(arguments: [String]) async -> HelperCommandResult {
        do {
            let parser = try HelperOptionParser(arguments: arguments, valuedOptions: ["--socket", "--session", "--delta"], flags: [])
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

    private func key(arguments: [String]) async -> HelperCommandResult {
        do {
            let parser = try HelperOptionParser(arguments: arguments, valuedOptions: ["--socket", "--session", "--key"], flags: [])
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

    private func isQueueableHookTransportError(_ error: Error) -> Bool {
        guard let clientError = error as? LocalIPCClientError else {
            return false
        }
        switch clientError {
        case .connectFailed, .sendFailed, .receiveFailed, .emptyResponse, .timedOut:
            return true
        }
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
