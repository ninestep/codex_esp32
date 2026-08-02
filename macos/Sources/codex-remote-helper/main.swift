import CodexRemoteCore
import CodexRemoteMac
import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "serve" {
    await runServe(arguments: Array(arguments.dropFirst()))
} else {
    let stdin = HelperStdinPolicy.shouldReadStdin(arguments: arguments)
        ? FileHandle.standardInput.readDataToEndOfFile()
        : Data()
    let result = await HelperCommandRunner().run(
        arguments: arguments,
        stdin: stdin,
        environment: ProcessInfo.processInfo.environment
    )
    write(result.stdout, to: .standardOutput)
    write(result.stderr, to: .standardError)
    exit(result.exitCode)
}

private func runServe(arguments: [String]) async {
    let serveArguments: HelperServeArguments
    do {
        serveArguments = try HelperServeArguments.parse(arguments)
    } catch {
        write("codex-remote-helper: \(String(describing: error))\n", to: .standardError)
        exit(64)
    }

    let socketURL = URL(fileURLWithPath: serveArguments.socketPath)
    do {
        try ensureSocketParentDirectory(for: socketURL)
    } catch {
        write("codex-remote-helper: daemon unavailable\n", to: .standardError)
        exit(69)
    }

    let service = SessionService(controller: GhosttyAppleScriptController())
    let dispatcher = SessionIPCDispatcher(service: service)
    let server = UnixSocketIPCServer(socketURL: socketURL) { request in
        await dispatcher.handle(request)
    }

    do {
        try await server.start()
    } catch {
        write("codex-remote-helper: daemon unavailable\n", to: .standardError)
        exit(69)
    }

    await waitForTerminationSignal()
    await server.stop()
    exit(0)
}

private func waitForTerminationSignal() async {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let queue = DispatchQueue(label: "codex-remote-helper.signals")
        var didResume = false
        var sources: [DispatchSourceSignal] = []

        func install(_ signalNumber: Int32) {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler {
                guard !didResume else {
                    return
                }
                didResume = true
                for source in sources {
                    source.cancel()
                }
                continuation.resume()
            }
            sources.append(source)
            source.resume()
        }

        install(SIGINT)
        install(SIGTERM)
    }
}

private func ensureSocketParentDirectory(for socketURL: URL) throws {
    let parentURL = socketURL.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw CocoaError(.fileWriteFileExists)
        }
        return
    }
    try FileManager.default.createDirectory(
        at: parentURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
}

private func write(_ string: String, to handle: FileHandle) {
    guard !string.isEmpty else {
        return
    }
    handle.write(Data(string.utf8))
}
