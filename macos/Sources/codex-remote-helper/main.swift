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
        try SocketParentPreparer().prepareParentDirectory(for: socketURL)
    } catch {
        write("codex-remote-helper: daemon unavailable\n", to: .standardError)
        exit(69)
    }

    let service = SessionService(controller: GhosttyAppleScriptController())
    let hookTrustEvidenceStore = HookTrustEvidenceStore(
        evidenceURL: HookTrustEvidenceStore.defaultEvidenceURL()
    )
    let dispatcher = SessionIPCDispatcher(
        service: service,
        onHookAccepted: { eventName in
            try? hookTrustEvidenceStore.recordAcceptedHook(eventName: eventName)
        }
    )
    let startupGate = IPCStartupGate()
    let server = UnixSocketIPCServer(socketURL: socketURL) { request in
        await startupGate.waitUntilReady()
        return await dispatcher.handle(request)
    }

    do {
        try await server.start()
    } catch {
        write("codex-remote-helper: daemon unavailable\n", to: .standardError)
        exit(69)
    }

    do {
        _ = try await HookEventQueue().drain(forSocketAt: socketURL, dispatcher: dispatcher)
    } catch {
        write("codex-remote-helper: pending hook drain unavailable\n", to: .standardError)
    }
    await startupGate.open()

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

private func write(_ string: String, to handle: FileHandle) {
    guard !string.isEmpty else {
        return
    }
    handle.write(Data(string.utf8))
}
