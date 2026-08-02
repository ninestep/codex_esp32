import Foundation
import Darwin
import XCTest
@testable import CodexRemoteCore
@testable import CodexRemoteMac

final class HelperCommandTests: XCTestCase {
    func testIPCRequestCodecEncodesExplicitVersionedNewlineDelimitedJSON() throws {
        let request = LocalIPCRequest.hook(
            HookPayload(
                hookEventName: "Stop",
                sessionID: "codex-session-1",
                launcherInstanceID: "launcher-1",
                message: nil,
                lastAssistantMessage: "done"
            )
        )

        let encoded = try LocalIPCCodec().encodeRequest(request)

        XCTAssertEqual(encoded.last, UInt8(ascii: "\n"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded.dropLast()) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["type"] as? String, "hook")
        XCTAssertEqual(try LocalIPCCodec().decodeRequest(encoded), request)
    }

    func testIPCResponseCodecEncodesSessionsWithoutInternalErrorText() throws {
        let session = RemoteSession(
            remoteSessionID: "remote-1",
            launcherInstanceID: "launcher-1",
            providerSessionID: "codex-1",
            terminalTargetID: "term-1",
            displayTitle: "ESP32",
            workingDirectoryLabel: "esp32"
        )

        let encoded = try LocalIPCCodec().encodeResponse(.sessions([session]))

        XCTAssertEqual(encoded.last, UInt8(ascii: "\n"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded.dropLast()) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["type"] as? String, "sessions")
        XCTAssertEqual(try LocalIPCCodec().decodeResponse(encoded), .sessions([session]))
    }

    func testRawHookMapperReadsOfficialSnakeCaseAndPrefersJSONLauncherID() throws {
        let raw = Data(
            """
            {
              "hook_event_name": "SessionStart",
              "session_id": "codex-session-1",
              "message": "user prompt",
              "last_assistant_message": "assistant text",
              "env": {
                "CODEX_REMOTE_INSTANCE_ID": "json-launcher"
              }
            }
            """.utf8
        )

        let payload = try RawHookPayloadMapper(
            processEnvironment: ["CODEX_REMOTE_INSTANCE_ID": "process-launcher"]
        ).map(raw)

        XCTAssertEqual(
            payload,
            HookPayload(
                hookEventName: "SessionStart",
                sessionID: "codex-session-1",
                launcherInstanceID: "json-launcher",
                message: "user prompt",
                lastAssistantMessage: "assistant text"
            )
        )
    }

    func testRawHookMapperFallsBackToProcessEnvironmentLauncherID() throws {
        let raw = Data(
            """
            {
              "hook_event_name": "UserPromptSubmit",
              "session_id": "codex-session-2"
            }
            """.utf8
        )

        let payload = try RawHookPayloadMapper(
            processEnvironment: ["CODEX_REMOTE_INSTANCE_ID": "process-launcher"]
        ).map(raw)

        XCTAssertEqual(payload.launcherInstanceID, "process-launcher")
    }

    func testRawHookMapperRejectsMissingRequiredOfficialFields() {
        let raw = Data(#"{"hook_event_name":"Stop"}"#.utf8)

        XCTAssertThrowsError(try RawHookPayloadMapper(processEnvironment: [:]).map(raw)) { error in
            XCTAssertEqual(error as? RawHookPayloadMappingError, .missingField("session_id"))
        }
    }

    func testListCommandSendsListRequestAndPrintsMachineReadableJSON() async throws {
        let session = RemoteSession(
            remoteSessionID: "remote-1",
            launcherInstanceID: "launcher-1",
            providerSessionID: "codex-1",
            terminalTargetID: "term-1",
            displayTitle: "ESP32",
            workingDirectoryLabel: "esp32"
        )
        let client = RecordingIPCClient(response: .sessions([session]))
        let result = await HelperCommandRunner(socketClient: client).run(
            arguments: ["list", "--socket", "/tmp/codex.sock", "--json"],
            stdin: Data(),
            environment: [:]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        let calls = await client.recordedCalls()
        XCTAssertEqual(calls, [IPCClientCall(socketPath: "/tmp/codex.sock", request: .list)])

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.first?["remoteSessionID"] as? String, "remote-1")
    }

    func testHookCommandRejectsMalformedRawHookBeforeContactingDaemon() async {
        let client = RecordingIPCClient(response: .ok)
        let result = await HelperCommandRunner(socketClient: client).run(
            arguments: ["hook", "--socket", "/tmp/codex.sock"],
            stdin: Data(#"{"hook_event_name":"Stop"}"#.utf8),
            environment: [:]
        )

        XCTAssertEqual(result.exitCode, 65)
        XCTAssertTrue(result.stderr.contains("session_id"))
        XCTAssertEqual(result.stdout, "")
        let calls = await client.recordedCalls()
        XCTAssertEqual(calls, [])
    }

    func testFocusScrollAndKeyCommandsRequirePositiveDaemonResponse() async {
        let client = RecordingIPCClient(response: .error(code: .handlerFailed))
        let runner = HelperCommandRunner(socketClient: client)

        let focus = await runner.run(
            arguments: ["focus", "--socket", "/tmp/codex.sock", "--session", "remote-1"],
            stdin: Data(),
            environment: [:]
        )
        let scroll = await runner.run(
            arguments: ["scroll", "--socket", "/tmp/codex.sock", "--session", "remote-1", "--delta", "-12"],
            stdin: Data(),
            environment: [:]
        )
        let key = await runner.run(
            arguments: ["key", "--socket", "/tmp/codex.sock", "--session", "remote-1", "--key", "enter"],
            stdin: Data(),
            environment: [:]
        )

        XCTAssertEqual(focus.exitCode, 69)
        XCTAssertEqual(scroll.exitCode, 69)
        XCTAssertEqual(key.exitCode, 69)
        let calls = await client.recordedCalls()
        XCTAssertEqual(
            calls,
            [
                IPCClientCall(socketPath: "/tmp/codex.sock", request: .focus(remoteSessionID: "remote-1")),
                IPCClientCall(socketPath: "/tmp/codex.sock", request: .scroll(remoteSessionID: "remote-1", deltaY: -12)),
                IPCClientCall(socketPath: "/tmp/codex.sock", request: .key(remoteSessionID: "remote-1", key: .enter)),
            ]
        )
    }

    func testMissingRequiredCLIArgumentExitsUsage() async {
        let result = await HelperCommandRunner(socketClient: RecordingIPCClient(response: .ok)).run(
            arguments: ["register-launch", "--socket", "/tmp/codex.sock"],
            stdin: Data(),
            environment: [:]
        )

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("--launcher"))
    }

    func testSessionIPCDispatcherRoutesRequestsThroughSessionService() async throws {
        let controller = HelperRecordingTerminalController()
        let service = SessionService(controller: controller, idGenerator: { "remote-1" })
        let dispatcher = SessionIPCDispatcher(service: service)

        let registerResponse = await dispatcher.handle(.registerLaunch(launcherID: "launcher-1"))
        XCTAssertEqual(registerResponse, .ok)
        let hookResponse = await dispatcher.handle(
            .hook(
                HookPayload(
                    hookEventName: "SessionStart",
                    sessionID: "codex-1",
                    launcherInstanceID: "launcher-1",
                    message: nil,
                    lastAssistantMessage: nil
                )
            )
        )
        XCTAssertEqual(hookResponse, .ok)

        let listResponse = await dispatcher.handle(.list)
        guard case .sessions(let sessions) = listResponse else {
            return XCTFail("Expected sessions response")
        }
        XCTAssertEqual(sessions.map(\.remoteSessionID), ["remote-1"])

        let focusResponse = await dispatcher.handle(.focus(remoteSessionID: "remote-1"))
        let scrollResponse = await dispatcher.handle(.scroll(remoteSessionID: "remote-1", deltaY: -12))
        let keyResponse = await dispatcher.handle(.key(remoteSessionID: "remote-1", key: .escape))
        XCTAssertEqual(focusResponse, .ok)
        XCTAssertEqual(scrollResponse, .ok)
        XCTAssertEqual(keyResponse, .ok)

        let events = await controller.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .capture,
                .focus("term-7"),
                .scroll(-12, "term-7"),
                .focus("term-7"),
                .key(.escape, "term-7"),
            ]
        )
    }

    func testSessionIPCDispatcherReturnsFixedErrorCodeWithoutLeakingServiceError() async {
        let dispatcher = SessionIPCDispatcher(
            service: SessionService(controller: HelperRecordingTerminalController(), idGenerator: { "remote-1" })
        )

        let response = await dispatcher.handle(.focus(remoteSessionID: "missing-remote"))

        XCTAssertEqual(response, .error(code: .handlerFailed))
    }

    func testUnixSocketIPCServerRoundTripsClientRequestAndRemovesOwnedSocketOnStop() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let server = UnixSocketIPCServer(socketURL: socketURL) { request in
            XCTAssertEqual(request, .registerLaunch(launcherID: "launcher-1"))
            return .ok
        }
        try await server.start()

        let response = try await LocalIPCClient().send(.registerLaunch(launcherID: "launcher-1"), to: socketURL)

        XCTAssertEqual(response, .ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))

        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testUnixSocketIPCServerReturnsFixedInvalidRequestForMalformedJSON() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let server = UnixSocketIPCServer(socketURL: socketURL) { _ in
            XCTFail("Malformed requests must not reach handler")
            return .ok
        }
        try await server.start()

        let rawResponse = try await sendRawIPCFrame(Data(#"{"version":1,"type":"hook""#.utf8 + [UInt8(ascii: "\n")]), to: socketURL)

        XCTAssertEqual(try LocalIPCCodec().decodeResponse(rawResponse), .error(code: .invalidRequest))
        XCTAssertFalse(String(decoding: rawResponse, as: UTF8.self).contains("hook"))

        await server.stop()
    }

    private func makeSocketFixture() throws -> SocketFixture {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ipc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return SocketFixture(socketURL: directory.appendingPathComponent("helper.sock"))
    }
}

private actor RecordingIPCClient: LocalIPCClienting {
    private(set) var calls: [IPCClientCall] = []
    private let response: LocalIPCResponse

    init(response: LocalIPCResponse) {
        self.response = response
    }

    func send(_ request: LocalIPCRequest, to socketURL: URL) async throws -> LocalIPCResponse {
        calls.append(IPCClientCall(socketPath: socketURL.path, request: request))
        return response
    }

    func recordedCalls() -> [IPCClientCall] {
        calls
    }
}

private struct IPCClientCall: Equatable, Sendable {
    let socketPath: String
    let request: LocalIPCRequest
}

private actor HelperRecordingTerminalController: TerminalController {
    enum Event: Equatable, Sendable {
        case capture
        case focus(String)
        case scroll(Int, String)
        case key(TerminalKey, String)
    }

    private var events: [Event] = []

    func recordedEvents() -> [Event] {
        events
    }

    func captureFocusedTerminal() async throws -> TerminalContext {
        events.append(.capture)
        return TerminalContext(
            terminalTargetID: "term-7",
            workingDirectory: "/Users/wj/data/mcp/esp32",
            displayTitle: "ESP32"
        )
    }

    func focus(terminalTargetID: String) async throws {
        events.append(.focus(terminalTargetID))
    }

    func scroll(deltaY: Int, terminalTargetID: String) async throws {
        events.append(.scroll(deltaY, terminalTargetID))
    }

    func sendKey(_ key: TerminalKey, to terminalTargetID: String) async throws {
        events.append(.key(key, terminalTargetID))
    }
}

private struct SocketFixture {
    let socketURL: URL
}

private func sendRawIPCFrame(_ frame: Data, to socketURL: URL) async throws -> Data {
    try await Task.detached {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer {
            close(descriptor)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                for index in pathBytes.indices {
                    buffer[index] = pathBytes[index]
                }
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        try frame.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var written = 0
            while written < frame.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: written), frame.count - written)
                guard count > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                written += count
            }
        }
        shutdown(descriptor, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.last != UInt8(ascii: "\n") {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else {
                break
            }
            response.append(buffer, count: count)
        }
        return response
    }.value
}
