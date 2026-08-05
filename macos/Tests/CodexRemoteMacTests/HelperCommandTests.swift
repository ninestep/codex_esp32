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

    func testRawHookMapperRejectsWhitespaceRequiredFieldsAndLauncherEnvironment() throws {
        let whitespaceEvent = Data(#"{"hook_event_name":"   ","session_id":"codex-session"}"#.utf8)
        XCTAssertThrowsError(try RawHookPayloadMapper(processEnvironment: [:]).map(whitespaceEvent)) { error in
            XCTAssertEqual(error as? RawHookPayloadMappingError, .missingField("hook_event_name"))
        }

        let whitespaceSession = Data(#"{"hook_event_name":"Stop","session_id":"   "}"#.utf8)
        XCTAssertThrowsError(try RawHookPayloadMapper(processEnvironment: [:]).map(whitespaceSession)) { error in
            XCTAssertEqual(error as? RawHookPayloadMappingError, .missingField("session_id"))
        }

        let payload = try RawHookPayloadMapper(
            processEnvironment: ["CODEX_REMOTE_INSTANCE_ID": "   "]
        ).map(Data(#"{"hook_event_name":"Stop","session_id":"codex-session"}"#.utf8))
        XCTAssertNil(payload.launcherInstanceID)
    }

    func testMainStdinPolicyReadsOnlyHookInput() {
        XCTAssertTrue(HelperStdinPolicy.shouldReadStdin(arguments: ["hook", "--socket", "/tmp/codex.sock"]))
        XCTAssertFalse(HelperStdinPolicy.shouldReadStdin(arguments: ["register-launch", "--socket", "/tmp/codex.sock", "--launcher", "launcher-1"]))
        XCTAssertFalse(HelperStdinPolicy.shouldReadStdin(arguments: ["list", "--socket", "/tmp/codex.sock", "--json"]))
        XCTAssertFalse(HelperStdinPolicy.shouldReadStdin(arguments: ["focus", "--socket", "/tmp/codex.sock", "--session", "remote-1"]))
        XCTAssertFalse(HelperStdinPolicy.shouldReadStdin(arguments: ["scroll", "--socket", "/tmp/codex.sock", "--session", "remote-1", "--delta", "-1"]))
        XCTAssertFalse(HelperStdinPolicy.shouldReadStdin(arguments: ["key", "--socket", "/tmp/codex.sock", "--session", "remote-1", "--key", "enter"]))
        XCTAssertFalse(HelperStdinPolicy.shouldReadStdin(arguments: ["serve", "--socket", "/tmp/codex.sock"]))
    }

    func testServeArgumentsRequireExactlyOneSocketOption() throws {
        XCTAssertEqual(try HelperServeArguments.parse(["--socket", "/tmp/codex.sock"]).socketPath, "/tmp/codex.sock")
        XCTAssertThrowsError(try HelperServeArguments.parse(["--socket", "/tmp/a", "--socket", "/tmp/b"]))
        XCTAssertThrowsError(try HelperServeArguments.parse(["--socket", "/tmp/a", "--unknown"]))
        XCTAssertThrowsError(try HelperServeArguments.parse(["--socket", "/tmp/a", "extra"]))
        XCTAssertThrowsError(try HelperServeArguments.parse(["--socket", "   "]))
    }

    func testSocketParentPreparerCreatesMissingParentWithOwnerOnlyPermissions() throws {
        let root = try makeTemporaryDirectory(prefix: "socket-parent-create")
        let socketURL = root.appendingPathComponent("missing").appendingPathComponent("events.sock")

        try SocketParentPreparer().prepareParentDirectory(for: socketURL)

        let status = try fileStatus(at: socketURL.deletingLastPathComponent())
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o700))
        XCTAssertEqual(status.st_uid, geteuid())
    }

    func testSocketParentPreparerAcceptsExistingPrivateDirectory() throws {
        let root = try makeTemporaryDirectory(prefix: "socket-parent-existing")
        let parent = root.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        try SocketParentPreparer().prepareParentDirectory(for: parent.appendingPathComponent("events.sock"))

        XCTAssertEqual(try socketMode(at: parent), 0o700)
    }

    func testSocketParentPreparerRejectsGroupOrOtherPermissionsWithoutChangingMode() throws {
        let root = try makeTemporaryDirectory(prefix: "socket-parent-public")
        let parent = root.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])

        XCTAssertThrowsError(try SocketParentPreparer().prepareParentDirectory(for: parent.appendingPathComponent("events.sock"))) { error in
            XCTAssertEqual(error as? SocketParentPreparationError, .insecurePermissions(parent.path, 0o755))
        }
        XCTAssertEqual(try socketMode(at: parent), 0o755)
    }

    func testSocketParentPreparerRejectsSymlinkToDirectory() throws {
        let root = try makeTemporaryDirectory(prefix: "socket-parent-symlink")
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try SocketParentPreparer().prepareParentDirectory(for: link.appendingPathComponent("events.sock"))) { error in
            XCTAssertEqual(error as? SocketParentPreparationError, .notDirectory(link.path))
        }
    }

    func testSocketParentPreparerRejectsOrdinaryFileParent() throws {
        let root = try makeTemporaryDirectory(prefix: "socket-parent-file")
        let file = root.appendingPathComponent("file")
        FileManager.default.createFile(atPath: file.path, contents: Data("not a directory".utf8))

        XCTAssertThrowsError(try SocketParentPreparer().prepareParentDirectory(for: file.appendingPathComponent("events.sock"))) { error in
            XCTAssertEqual(error as? SocketParentPreparationError, .notDirectory(file.path))
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

    func testStrictParserRejectsUnknownDuplicateExtraAndFlagValuesWithoutContactingDaemon() async {
        let client = RecordingIPCClient(response: .ok)
        let runner = HelperCommandRunner(socketClient: client)

        let unknown = await runner.run(
            arguments: ["focus", "--socket", "/tmp/codex.sock", "--session", "remote-1", "--sesion", "typo"],
            stdin: Data(),
            environment: [:]
        )
        let duplicate = await runner.run(
            arguments: ["focus", "--socket", "/tmp/codex.sock", "--session", "remote-1", "--session", "remote-2"],
            stdin: Data(),
            environment: [:]
        )
        let extra = await runner.run(
            arguments: ["focus", "--socket", "/tmp/codex.sock", "--session", "remote-1", "extra"],
            stdin: Data(),
            environment: [:]
        )
        let flagValue = await runner.run(
            arguments: ["list", "--socket", "/tmp/codex.sock", "--json", "false"],
            stdin: Data(),
            environment: [:]
        )

        XCTAssertEqual([unknown.exitCode, duplicate.exitCode, extra.exitCode, flagValue.exitCode], [64, 64, 64, 64])
        let calls = await client.recordedCalls()
        XCTAssertEqual(calls, [])
    }

    func testWhitespaceCLIRequiredValuesExitUsageWithoutContactingDaemon() async {
        let client = RecordingIPCClient(response: .ok)
        let runner = HelperCommandRunner(socketClient: client)

        let launcher = await runner.run(
            arguments: ["register-launch", "--socket", "/tmp/codex.sock", "--launcher", "   "],
            stdin: Data(),
            environment: [:]
        )
        let session = await runner.run(
            arguments: ["focus", "--socket", "/tmp/codex.sock", "--session", "   "],
            stdin: Data(),
            environment: [:]
        )
        let socket = await runner.run(
            arguments: ["list", "--socket", "   ", "--json"],
            stdin: Data(),
            environment: [:]
        )

        XCTAssertEqual([launcher.exitCode, session.exitCode, socket.exitCode], [64, 64, 64])
        let calls = await client.recordedCalls()
        XCTAssertEqual(calls, [])
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

    func testSessionIPCDispatcherRecordsAcceptedDirectHookOnlyAfterSuccess() async throws {
        let accepted = AcceptedHookRecorder()
        let service = SessionService(controller: HelperRecordingTerminalController(), idGenerator: { "remote-1" })
        let dispatcher = SessionIPCDispatcher(service: service, onHookAccepted: { eventName in
            Task {
                await accepted.record(eventName)
            }
        })

        let failed = await dispatcher.handle(.hook(HookPayload(
            hookEventName: "Stop",
            sessionID: "missing-session",
            launcherInstanceID: nil,
            message: nil,
            lastAssistantMessage: nil
        )))
        let register = await dispatcher.handle(.registerLaunch(launcherID: "launcher-1"))
        let succeeded = await dispatcher.handle(.hook(HookPayload(
            hookEventName: "SessionStart",
            sessionID: "codex-1",
            launcherInstanceID: "launcher-1",
            message: nil,
            lastAssistantMessage: nil
        )))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(failed, .error(code: .handlerFailed))
        XCTAssertEqual(register, .ok)
        XCTAssertEqual(succeeded, .ok)
        let acceptedEvents = await accepted.events()
        XCTAssertEqual(acceptedEvents, ["SessionStart"])
    }

    func testSessionIPCDispatcherDoesNotRecordUnknownDirectHookEvent() async throws {
        let accepted = AcceptedHookRecorder()
        let service = SessionService(controller: HelperRecordingTerminalController(), idGenerator: { "remote-1" })
        let dispatcher = SessionIPCDispatcher(service: service, onHookAccepted: { eventName in
            Task {
                await accepted.record(eventName)
            }
        })

        let response = await dispatcher.handle(.hook(HookPayload(
            hookEventName: "UnknownEvent",
            sessionID: "codex-unknown",
            launcherInstanceID: nil,
            message: nil,
            lastAssistantMessage: nil
        )))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(response, .ok)
        let acceptedEvents = await accepted.events()
        XCTAssertEqual(acceptedEvents, [])
    }

    func testSessionIPCDispatcherRecordsAcceptedPendingHookOnlyAfterSuccess() async throws {
        let accepted = AcceptedHookRecorder()
        let service = SessionService(controller: HelperRecordingTerminalController(), idGenerator: { "remote-1" })
        let dispatcher = SessionIPCDispatcher(service: service, onHookAccepted: { eventName in
            Task {
                await accepted.record(eventName)
            }
        })

        let failed = await dispatcher.handlePending(.hook(HookPayload(
            hookEventName: "Stop",
            sessionID: "missing-session",
            launcherInstanceID: nil,
            message: nil,
            lastAssistantMessage: nil
        )))
        let launch = await dispatcher.handlePending(.launchSnapshot(LaunchRegistration(
            launcherInstanceID: "launcher-1",
            terminalTargetID: "term-7",
            displayTitle: "ESP32",
            workingDirectoryLabel: "esp32"
        )))
        let succeeded = await dispatcher.handlePending(.hook(HookPayload(
            hookEventName: "SessionStart",
            sessionID: "codex-1",
            launcherInstanceID: "launcher-1",
            message: nil,
            lastAssistantMessage: nil
        )))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(failed, .error(code: .handlerFailed))
        XCTAssertEqual(launch, .ok)
        XCTAssertEqual(succeeded, .ok)
        let acceptedEvents = await accepted.events()
        XCTAssertEqual(acceptedEvents, ["SessionStart"])
    }

    func testSessionIPCDispatcherDoesNotRecordUnknownPendingHookEvent() async throws {
        let accepted = AcceptedHookRecorder()
        let service = SessionService(controller: HelperRecordingTerminalController(), idGenerator: { "remote-1" })
        let dispatcher = SessionIPCDispatcher(service: service, onHookAccepted: { eventName in
            Task {
                await accepted.record(eventName)
            }
        })

        let response = await dispatcher.handlePending(.hook(HookPayload(
            hookEventName: "UnknownEvent",
            sessionID: "codex-unknown",
            launcherInstanceID: nil,
            message: nil,
            lastAssistantMessage: nil
        )))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(response, .ok)
        let acceptedEvents = await accepted.events()
        XCTAssertEqual(acceptedEvents, [])
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
        XCTAssertEqual(try socketMode(at: socketURL), 0o600)

        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testUnixSocketIPCServerStopDoesNotRemoveReplacementFile() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let server = UnixSocketIPCServer(socketURL: socketURL) { _ in .ok }
        try await server.start()

        XCTAssertEqual(unlink(socketURL.path), 0)
        let replacement = Data("replacement".utf8)
        FileManager.default.createFile(atPath: socketURL.path, contents: replacement)

        await server.stop()

        XCTAssertEqual(try Data(contentsOf: socketURL), replacement)
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

    func testUnixSocketIPCServerRejectsTrailingBytesAfterOneLineWithoutCallingHandler() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let recorder = IPCRequestRecorder()
        let server = UnixSocketIPCServer(socketURL: socketURL) { request in
            await recorder.record(request)
            return .ok
        }
        try await server.start()

        let validFrame = try LocalIPCCodec().encodeRequest(.list)
        let junkResponse = try await sendRawIPCFrame(validFrame + Data("junk".utf8), to: socketURL)
        let doubleFrameResponse = try await sendRawIPCFrame(validFrame + validFrame, to: socketURL)

        XCTAssertEqual(try LocalIPCCodec().decodeResponse(junkResponse), .error(code: .invalidRequest))
        XCTAssertEqual(try LocalIPCCodec().decodeResponse(doubleFrameResponse), .error(code: .invalidRequest))
        let requests = await recorder.recordedRequests()
        XCTAssertEqual(requests, [])

        await server.stop()
    }

    func testUnixSocketIPCServerRejectsOversizedFrameWithoutCallingHandler() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let recorder = IPCRequestRecorder()
        let server = UnixSocketIPCServer(socketURL: socketURL) { request in
            await recorder.record(request)
            return .ok
        }
        try await server.start()

        let response = try await sendRawIPCFrame(
            Data(repeating: UInt8(ascii: "x"), count: LocalIPCCodec.maximumFrameBytes + 1),
            to: socketURL
        )

        XCTAssertEqual(try LocalIPCCodec().decodeResponse(response), .error(code: .frameTooLarge))
        let requests = await recorder.recordedRequests()
        XCTAssertEqual(requests, [])

        await server.stop()
    }

    func testLocalIPCClientTimesOutWhenDaemonAcceptsButDoesNotRespond() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let server = UnixSocketIPCServer(socketURL: socketURL) { _ in
            try await Task.sleep(for: .milliseconds(250))
            return .ok
        }
        try await server.start()

        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await LocalIPCClient(responseTimeout: .milliseconds(50)).send(.list, to: socketURL)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? LocalIPCClientError, .readTimedOut)
        }
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))

        await server.stop()
    }

    func testLocalIPCClientTimesOutOnPartialResponse() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let partialServer = try PartialResponseServer(socketURL: socketURL, responsePrefix: Data(#"{"version":1"#.utf8))
        try partialServer.start()

        do {
            _ = try await LocalIPCClient(responseTimeout: .milliseconds(50)).send(.list, to: socketURL)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? LocalIPCClientError, .readTimedOut)
        }

        partialServer.stop()
    }

    private func makeSocketFixture() throws -> SocketFixture {
        let directory = try makeTemporaryDirectory(prefix: "ipc")
        return SocketFixture(socketURL: directory.appendingPathComponent("helper.sock"))
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

private actor IPCRequestRecorder {
    private var requests: [LocalIPCRequest] = []

    func record(_ request: LocalIPCRequest) {
        requests.append(request)
    }

    func recordedRequests() -> [LocalIPCRequest] {
        requests
    }
}

private actor AcceptedHookRecorder {
    private var acceptedEvents: [String] = []

    func record(_ eventName: String) {
        acceptedEvents.append(eventName)
    }

    func events() -> [String] {
        acceptedEvents
    }
}

private actor RecordingIPCClient: LocalIPCClienting {
    private(set) var calls: [IPCClientCall] = []
    private let result: Result<LocalIPCResponse, Error>

    init(response: LocalIPCResponse) {
        self.result = .success(response)
    }

    init(error: Error) {
        self.result = .failure(error)
    }

    func send(_ request: LocalIPCRequest, to socketURL: URL) async throws -> LocalIPCResponse {
        calls.append(IPCClientCall(socketPath: socketURL.path, request: request))
        return try result.get()
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

private func socketMode(at socketURL: URL) throws -> mode_t {
    try fileStatus(at: socketURL).st_mode & mode_t(0o777)
}

private func fileStatus(at url: URL) throws -> stat {
    var status = stat()
    guard url.path.withCString({ lstat($0, &status) }) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return status
}

private final class PartialResponseServer {
    private let socketURL: URL
    private let responsePrefix: Data
    private var descriptor: Int32 = -1
    private var task: Task<Void, Never>?

    init(socketURL: URL, responsePrefix: Data) throws {
        self.socketURL = socketURL
        self.responsePrefix = responsePrefix
    }

    func start() throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
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

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard listen(descriptor, 1) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        task = Task.detached { [descriptor, responsePrefix] in
            let accepted = accept(descriptor, nil, nil)
            guard accepted >= 0 else {
                return
            }
            defer {
                close(accepted)
            }
            _ = responsePrefix.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return 0
                }
                return Darwin.write(accepted, baseAddress, responsePrefix.count)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        unlink(socketURL.path)
    }
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
