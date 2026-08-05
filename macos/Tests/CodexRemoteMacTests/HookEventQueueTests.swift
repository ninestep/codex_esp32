import CodexRemoteCore
import CodexRemoteMac
import Darwin
import Foundation
import XCTest

final class HookEventQueueTests: XCTestCase {
    func testUnavailableHookQueuesAndExitsZeroAfterOneClientAttempt() async throws {
        let socketURL = try makeSocketFixture()
        let client = QueueTestIPCClient(error: LocalIPCClientError.connectFailed(ECONNREFUSED))
        let queue = RecordingPendingEventQueue()
        let recorder = QueueHookTrustEvidenceRecorder()

        let result = await HelperCommandRunner(
            socketClient: client,
            hookQueue: queue,
            hookTrustEvidenceRecorderFactory: { receivedSocketURL in
                XCTAssertEqual(receivedSocketURL, socketURL)
                return recorder
            }
        ).run(
            arguments: ["hook", "--socket", socketURL.path],
            stdin: hookJSON(sessionID: "codex-1"),
            environment: [:]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "codex-remote-helper: hook queued\n")
        let callCount = await client.recordedCalls().count
        let enqueues = await queue.recordedEnqueues()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(enqueues, [QueuedPendingEvent(socketPath: socketURL.path, event: .hook(minimalHookPayload(sessionID: "codex-1")))])
        XCTAssertEqual(recorder.recordedEventNames(), ["Stop"])
    }

    func testHookConnectTimeoutQueuesButPostSendFailuresDoNotQueue() async throws {
        let socketURL = try makeSocketFixture()
        let queued = RecordingPendingEventQueue()
        let connectTimeout = await HelperCommandRunner(
            socketClient: QueueTestIPCClient(error: LocalIPCClientError.connectTimedOut),
            hookQueue: queued
        ).run(arguments: ["hook", "--socket", socketURL.path], stdin: hookJSON(sessionID: "codex-timeout"), environment: [:])

        XCTAssertEqual(connectTimeout.exitCode, 0)
        XCTAssertEqual(connectTimeout.stderr, "codex-remote-helper: hook queued\n")
        let queuedEnqueues = await queued.recordedEnqueues()
        XCTAssertEqual(queuedEnqueues, [QueuedPendingEvent(socketPath: socketURL.path, event: .hook(minimalHookPayload(sessionID: "codex-timeout")))])

        for error in [
            LocalIPCClientError.sendFailed(EPIPE),
            LocalIPCClientError.receiveFailed(ECONNRESET),
            LocalIPCClientError.emptyResponse,
            LocalIPCClientError.readTimedOut,
        ] {
            let queue = RecordingPendingEventQueue()
            let result = await HelperCommandRunner(
                socketClient: QueueTestIPCClient(error: error),
                hookQueue: queue
            ).run(arguments: ["hook", "--socket", socketURL.path], stdin: hookJSON(sessionID: "codex-post-send"), environment: [:])

            XCTAssertEqual(result.exitCode, 69)
            XCTAssertEqual(result.stderr, "codex-remote-helper: daemon unavailable\n")
            let enqueues = await queue.recordedEnqueues()
            XCTAssertEqual(enqueues, [])
        }
    }

    func testRegisterLaunchConnectFailureCapturesSnapshotQueuesAndExitsZero() async throws {
        let socketURL = try makeSocketFixture()
        let queue = RecordingPendingEventQueue()
        let capturer = RecordingLaunchSnapshotCapturer(
            result: launchSnapshot(launcherID: "launcher-1", terminalID: "term-7", workingDirectoryLabel: "esp32")
        )

        let result = await HelperCommandRunner(
            socketClient: QueueTestIPCClient(error: LocalIPCClientError.connectFailed(ECONNREFUSED)),
            hookQueue: queue,
            launchSnapshotCapturer: capturer
        ).run(arguments: ["register-launch", "--socket", socketURL.path, "--launcher", "launcher-1"], stdin: Data(), environment: [:])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "codex-remote-helper: launch queued\n")
        let launcherIDs = await capturer.recordedLauncherIDs()
        XCTAssertEqual(launcherIDs, ["launcher-1"])
        let enqueues = await queue.recordedEnqueues()
        XCTAssertEqual(
            enqueues,
            [QueuedPendingEvent(socketPath: socketURL.path, event: .launchSnapshot(launchSnapshot(launcherID: "launcher-1", terminalID: "term-7", workingDirectoryLabel: "esp32")))]
        )
    }

    func testRegisterLaunchPostSendFailuresDoNotCaptureOrQueue() async throws {
        let socketURL = try makeSocketFixture()
        for error in [
            LocalIPCClientError.sendFailed(EPIPE),
            LocalIPCClientError.receiveFailed(ECONNRESET),
            LocalIPCClientError.emptyResponse,
            LocalIPCClientError.readTimedOut,
        ] {
            let queue = RecordingPendingEventQueue()
            let capturer = RecordingLaunchSnapshotCapturer(
                result: launchSnapshot(launcherID: "launcher-1", terminalID: "term-7", workingDirectoryLabel: "esp32")
            )

            let result = await HelperCommandRunner(
                socketClient: QueueTestIPCClient(error: error),
                hookQueue: queue,
                launchSnapshotCapturer: capturer
            ).run(arguments: ["register-launch", "--socket", socketURL.path, "--launcher", "launcher-1"], stdin: Data(), environment: [:])

            XCTAssertEqual(result.exitCode, 69)
            XCTAssertEqual(result.stderr, "codex-remote-helper: daemon unavailable\n")
            let enqueues = await queue.recordedEnqueues()
            let launcherIDs = await capturer.recordedLauncherIDs()
            XCTAssertEqual(enqueues, [])
            XCTAssertEqual(launcherIDs, [])
        }
    }

    func testNegativeDaemonResponseIsNotQueuedAndExitsUnavailable() async throws {
        let socketURL = try makeSocketFixture()
        let client = QueueTestIPCClient(response: .error(code: .handlerFailed))
        let queue = RecordingPendingEventQueue()

        let result = await HelperCommandRunner(socketClient: client, hookQueue: queue).run(
            arguments: ["hook", "--socket", socketURL.path],
            stdin: hookJSON(sessionID: "codex-1"),
            environment: [:]
        )

        XCTAssertEqual(result.exitCode, 69)
        XCTAssertTrue(result.stderr.contains("daemon error: handler_failed"))
        let enqueues = await queue.recordedEnqueues()
        XCTAssertEqual(enqueues, [])
    }

    func testQueueStorageFailureExitsUnavailable() async throws {
        let socketURL = try makeSocketFixture()
        let client = QueueTestIPCClient(error: LocalIPCClientError.connectFailed(ECONNREFUSED))
        let queue = RecordingPendingEventQueue(error: POSIXError(.EACCES))

        let result = await HelperCommandRunner(socketClient: client, hookQueue: queue).run(
            arguments: ["hook", "--socket", socketURL.path],
            stdin: hookJSON(sessionID: "codex-1"),
            environment: [:]
        )

        XCTAssertEqual(result.exitCode, 69)
        XCTAssertEqual(result.stderr, "codex-remote-helper: daemon unavailable\n")
    }

    func testNonTransportClientErrorIsNotQueued() async throws {
        let socketURL = try makeSocketFixture()
        let client = QueueTestIPCClient(error: LocalIPCCodecError.frameTooLarge(70_000))
        let queue = RecordingPendingEventQueue()

        let result = await HelperCommandRunner(socketClient: client, hookQueue: queue).run(
            arguments: ["hook", "--socket", socketURL.path],
            stdin: hookJSON(sessionID: "codex-1"),
            environment: [:]
        )

        XCTAssertEqual(result.exitCode, 69)
        XCTAssertEqual(result.stderr, "codex-remote-helper: daemon unavailable\n")
        let enqueues = await queue.recordedEnqueues()
        XCTAssertEqual(enqueues, [])
    }

    func testQueueTruncatesHookTextFieldsAndPersistsNoRawTranscriptFields() async throws {
        let socketURL = try makeSocketFixture()
        let longMessage = String(repeating: "用", count: 1_100)
        let longAssistant = String(repeating: "答", count: 1_100)
        let raw = Data(
            """
            {
              "hook_event_name": "Stop",
              "session_id": "codex-1",
              "message": "\(longMessage)",
              "last_assistant_message": "\(longAssistant)",
              "transcript": "must-not-persist",
              "env": {
                "CODEX_REMOTE_INSTANCE_ID": "launcher-1",
                "SECRET": "must-not-persist"
              }
            }
            """.utf8
        )
        let payload = try RawHookPayloadMapper(processEnvironment: [:]).map(raw)

        try await HookEventQueue().enqueue(.hook(payload), forSocketAt: socketURL)

        let frame = try XCTUnwrap(try queueLines(for: socketURL).first)
        XCTAssertLessThanOrEqual(frame.count, LocalIPCCodec.maximumFrameBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frame.dropLast()) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["type"] as? String, "hook")
        XCTAssertNil(object["transcript"])
        let payloadObject = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(Set(payloadObject.keys), ["hookEventName", "sessionID", "launcherInstanceID", "message", "lastAssistantMessage"])
        XCTAssertEqual((payloadObject["message"] as? String)?.count, 1_024)
        XCTAssertEqual((payloadObject["lastAssistantMessage"] as? String)?.count, 1_024)
        XCTAssertFalse(String(decoding: frame, as: UTF8.self).contains("must-not-persist"))
    }

    func testSixtyFifthQueuedEventDropsOldestAndPreservesOrder() async throws {
        let socketURL = try makeSocketFixture()
        let queue = HookEventQueue()

        for index in 0..<65 {
            try await queue.enqueue(.hook(payload(sessionID: "codex-\(index)")), forSocketAt: socketURL)
        }

        let queuedPayloads = try readQueuedPayloads(for: socketURL)
        XCTAssertEqual(queuedPayloads.count, 64)
        XCTAssertEqual(queuedPayloads.first?.sessionID, "codex-1")
        XCTAssertEqual(queuedPayloads.last?.sessionID, "codex-64")
    }

    func testQueueCreatesPrivateParentQueueAndLockFiles() async throws {
        let root = try makeTemporaryDirectory(prefix: "hook-queue-private")
        let socketURL = root.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("events.sock")

        try await HookEventQueue().enqueue(.hook(payload(sessionID: "codex-1")), forSocketAt: socketURL)

        XCTAssertEqual(try fileMode(at: socketURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try fileMode(at: HookEventQueue.queueURL(forSocketAt: socketURL)), 0o600)
        XCTAssertEqual(try fileMode(at: HookEventQueue.lockURL(forSocketAt: socketURL)), 0o600)
        XCTAssertEqual(try fileStatus(at: HookEventQueue.queueURL(forSocketAt: socketURL)).st_uid, geteuid())
        XCTAssertEqual(try fileStatus(at: HookEventQueue.lockURL(forSocketAt: socketURL)).st_uid, geteuid())
    }

    func testQueueRejectsSymlinkAndWidePermissions() async throws {
        let socketURL = try makeSocketFixture()
        let queueURL = HookEventQueue.queueURL(forSocketAt: socketURL)
        let targetURL = socketURL.deletingLastPathComponent().appendingPathComponent("target.jsonl")
        FileManager.default.createFile(atPath: targetURL.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: queueURL, withDestinationURL: targetURL)

        await XCTAssertThrowsErrorAsync(try await HookEventQueue().enqueue(.hook(payload(sessionID: "codex-1")), forSocketAt: socketURL))

        try? FileManager.default.removeItem(at: queueURL)
        FileManager.default.createFile(atPath: queueURL.path, contents: Data(), attributes: [.posixPermissions: 0o644])
        await XCTAssertThrowsErrorAsync(try await HookEventQueue().enqueue(.hook(payload(sessionID: "codex-2")), forSocketAt: socketURL))
    }

    func testDrainSuccessRemovesConfirmedEvents() async throws {
        let socketURL = try makeSocketFixture()
        let queue = HookEventQueue()
        try await queue.enqueue(.hook(payload(sessionID: "codex-1")), forSocketAt: socketURL)
        try await queue.enqueue(.hook(payload(sessionID: "codex-2")), forSocketAt: socketURL)

        let recorder = HookDrainRecorder(responses: [.ok, .ok])
        let result = try await queue.drain(forSocketAt: socketURL) { event in
            guard case .hook(let payload) = event else {
                return .error(code: .handlerFailed)
            }
            return await recorder.handle(payload)
        }

        XCTAssertEqual(result.consumedCount, 2)
        XCTAssertEqual(try readQueuedPayloads(for: socketURL), [])
        let recordedSessionIDs = await recorder.recordedSessionIDs()
        XCTAssertEqual(recordedSessionIDs, ["codex-1", "codex-2"])
    }

    func testDrainFailureRetainsFailedAndLaterEvents() async throws {
        let socketURL = try makeSocketFixture()
        let queue = HookEventQueue()
        try await queue.enqueue(.hook(payload(sessionID: "codex-1")), forSocketAt: socketURL)
        try await queue.enqueue(.hook(payload(sessionID: "codex-2")), forSocketAt: socketURL)
        try await queue.enqueue(.hook(payload(sessionID: "codex-3")), forSocketAt: socketURL)

        let recorder = HookDrainRecorder(responses: [.ok, .error(code: .handlerFailed), .ok])
        let result = try await queue.drain(forSocketAt: socketURL) { event in
            guard case .hook(let payload) = event else {
                return .error(code: .handlerFailed)
            }
            return await recorder.handle(payload)
        }

        XCTAssertEqual(result.consumedCount, 1)
        XCTAssertEqual(try readQueuedPayloads(for: socketURL).map(\.sessionID), ["codex-2", "codex-3"])
        let recordedSessionIDs = await recorder.recordedSessionIDs()
        XCTAssertEqual(recordedSessionIDs, ["codex-1", "codex-2"])
    }

    func testConcurrentEnqueuePreservesAllEventsWithoutCorruptingFrames() async throws {
        let socketURL = try makeSocketFixture()
        let queue = HookEventQueue()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await queue.enqueue(.hook(payload(sessionID: "codex-\(index)")), forSocketAt: socketURL)
                }
            }
            try await group.waitForAll()
        }

        let payloads = try readQueuedPayloads(for: socketURL)
        XCTAssertEqual(payloads.count, 20)
        XCTAssertEqual(Set(payloads.map(\.sessionID)).count, 20)
    }

    func testDrainLaunchSnapshotThenSessionStartRestoresProviderMappingInOrder() async throws {
        let socketURL = try makeSocketFixture()
        let queue = HookEventQueue()
        try await queue.enqueue(
            .launchSnapshot(launchSnapshot(launcherID: "launcher-1", terminalID: "term-7", workingDirectoryLabel: "esp32")),
            forSocketAt: socketURL
        )
        try await queue.enqueue(.hook(sessionStart(sessionID: "codex-1", launcherID: "launcher-1")), forSocketAt: socketURL)
        let controller = QueueRecordingTerminalController()
        let service = SessionService(controller: controller, idGenerator: { "remote-1" })
        let dispatcher = SessionIPCDispatcher(service: service)

        let result = try await queue.drain(forSocketAt: socketURL, dispatcher: dispatcher)

        XCTAssertEqual(result, HookEventQueueDrainResult(consumedCount: 2, retainedCount: 0))
        XCTAssertEqual(try readQueuedEvents(for: socketURL), [])
        let sessions = await service.activeSessions(limit: 8)
        XCTAssertEqual(sessions.map(\.remoteSessionID), ["remote-1"])
        XCTAssertEqual(sessions.first?.launcherInstanceID, "launcher-1")
        XCTAssertEqual(sessions.first?.providerSessionID, "codex-1")
        XCTAssertEqual(sessions.first?.terminalTargetID, "term-7")
        let terminalEvents = await controller.recordedEvents()
        XCTAssertEqual(terminalEvents, [])
    }

    func testDrainSessionStartWithoutLaunchSnapshotRetainsHook() async throws {
        let socketURL = try makeSocketFixture()
        let queue = HookEventQueue()
        try await queue.enqueue(.hook(sessionStart(sessionID: "codex-1", launcherID: "launcher-1")), forSocketAt: socketURL)
        let service = SessionService(controller: QueueRecordingTerminalController(), idGenerator: { "remote-1" })
        let dispatcher = SessionIPCDispatcher(service: service)

        let result = try await queue.drain(forSocketAt: socketURL, dispatcher: dispatcher)

        XCTAssertEqual(result, HookEventQueueDrainResult(consumedCount: 0, retainedCount: 1))
        XCTAssertEqual(try readQueuedEvents(for: socketURL), [.hook(sessionStart(sessionID: "codex-1", launcherID: "launcher-1"))])
    }

    func testAtomicRewriteFailureBeforeRenamePreservesOldQueueAndRemovesTemp() async throws {
        let socketURL = try makeSocketFixture()
        try await HookEventQueue().enqueue(.hook(payload(sessionID: "codex-1")), forSocketAt: socketURL)
        let queueURL = HookEventQueue.queueURL(forSocketAt: socketURL)
        let originalBytes = try Data(contentsOf: queueURL)
        let failingQueue = HookEventQueue(beforeRename: { _, _ in throw POSIXError(.EIO) })

        await XCTAssertThrowsErrorAsync(try await failingQueue.enqueue(.hook(payload(sessionID: "codex-2")), forSocketAt: socketURL))

        XCTAssertEqual(try Data(contentsOf: queueURL), originalBytes)
        XCTAssertEqual(try temporaryQueueFiles(for: socketURL), [])
        XCTAssertEqual(try readQueuedPayloads(for: socketURL).map(\.sessionID), ["codex-1"])
    }

    func testDrainRewriteFailureLeavesOldQueueForAtLeastOnceRetry() async throws {
        let socketURL = try makeSocketFixture()
        try await HookEventQueue().enqueue(.hook(payload(sessionID: "codex-1")), forSocketAt: socketURL)
        try await HookEventQueue().enqueue(.hook(payload(sessionID: "codex-2")), forSocketAt: socketURL)
        let queueURL = HookEventQueue.queueURL(forSocketAt: socketURL)
        let originalBytes = try Data(contentsOf: queueURL)
        let failingQueue = HookEventQueue(beforeRename: { _, _ in throw POSIXError(.EIO) })
        let recorder = HookDrainRecorder(responses: [.ok, .ok])

        await XCTAssertThrowsErrorAsync(
            _ = try await failingQueue.drain(forSocketAt: socketURL) { event in
                guard case .hook(let payload) = event else {
                    return .error(code: .handlerFailed)
                }
                return await recorder.handle(payload)
            }
        )

        let recordedSessionIDs = await recorder.recordedSessionIDs()
        XCTAssertEqual(recordedSessionIDs, ["codex-1", "codex-2"])
        XCTAssertEqual(try Data(contentsOf: queueURL), originalBytes)
        XCTAssertEqual(try readQueuedPayloads(for: socketURL).map(\.sessionID), ["codex-1", "codex-2"])
        XCTAssertEqual(try temporaryQueueFiles(for: socketURL), [])
    }

    private func makeSocketFixture() throws -> URL {
        let directory = try makeTemporaryDirectory(prefix: "hook-queue")
        return directory.appendingPathComponent("events.sock")
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

private actor RecordingPendingEventQueue: HookEventQueueing {
    private var enqueues: [QueuedPendingEvent] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func enqueue(_ event: PendingLocalEvent, forSocketAt socketURL: URL) async throws {
        if let error {
            throw error
        }
        enqueues.append(QueuedPendingEvent(socketPath: socketURL.path, event: event))
    }

    func recordedEnqueues() -> [QueuedPendingEvent] {
        enqueues
    }
}

private final class QueueHookTrustEvidenceRecorder: HookTrustEvidenceRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var eventNames: [String] = []

    func recordAcceptedHook(eventName: String) throws {
        lock.withLock {
            eventNames.append(eventName)
        }
    }

    func recordedEventNames() -> [String] {
        lock.withLock { eventNames }
    }
}

private actor QueueTestIPCClient: LocalIPCClienting {
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

private struct QueuedPendingEvent: Equatable, Sendable {
    let socketPath: String
    let event: PendingLocalEvent
}

private actor RecordingLaunchSnapshotCapturer: LaunchSnapshotCapturing {
    private let result: LaunchRegistration
    private var launcherIDs: [String] = []

    init(result: LaunchRegistration) {
        self.result = result
    }

    func captureLaunchSnapshot(launcherID: String) async throws -> LaunchRegistration {
        launcherIDs.append(launcherID)
        return result
    }

    func recordedLauncherIDs() -> [String] {
        launcherIDs
    }
}

private actor QueueRecordingTerminalController: TerminalController {
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
        throw GhosttyControllerError.noFocusedTerminal
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

private actor HookDrainRecorder {
    private var responses: [LocalIPCResponse]
    private var sessionIDs: [String] = []

    init(responses: [LocalIPCResponse]) {
        self.responses = responses
    }

    func handle(_ payload: HookPayload) -> LocalIPCResponse {
        sessionIDs.append(payload.sessionID)
        return responses.isEmpty ? .ok : responses.removeFirst()
    }

    func recordedSessionIDs() -> [String] {
        sessionIDs
    }
}

private func hookJSON(sessionID: String) -> Data {
    Data(#"{"hook_event_name":"Stop","session_id":"\#(sessionID)"}"#.utf8)
}

private func payload(sessionID: String) -> HookPayload {
    HookPayload(
        hookEventName: "Stop",
        sessionID: sessionID,
        launcherInstanceID: nil,
        message: "message-\(sessionID)",
        lastAssistantMessage: nil
    )
}

private func minimalHookPayload(sessionID: String) -> HookPayload {
    HookPayload(
        hookEventName: "Stop",
        sessionID: sessionID,
        launcherInstanceID: nil,
        message: nil,
        lastAssistantMessage: nil
    )
}

private func sessionStart(sessionID: String, launcherID: String) -> HookPayload {
    HookPayload(
        hookEventName: "SessionStart",
        sessionID: sessionID,
        launcherInstanceID: launcherID,
        message: nil,
        lastAssistantMessage: nil
    )
}

private func launchSnapshot(launcherID: String, terminalID: String, workingDirectoryLabel: String) -> LaunchRegistration {
    LaunchRegistration(
        launcherInstanceID: launcherID,
        terminalTargetID: terminalID,
        displayTitle: "ESP32",
        workingDirectoryLabel: workingDirectoryLabel
    )
}

private func queueLines(for socketURL: URL) throws -> [Data] {
    let queueURL = HookEventQueue.queueURL(forSocketAt: socketURL)
    guard FileManager.default.fileExists(atPath: queueURL.path) else {
        return []
    }
    return try Data(contentsOf: queueURL).split(separator: UInt8(ascii: "\n")).map { line in
        Data(line) + Data([UInt8(ascii: "\n")])
    }
}

private func readQueuedPayloads(for socketURL: URL) throws -> [HookPayload] {
    try readQueuedEvents(for: socketURL).map { event in
        guard case .hook(let payload) = event else {
            throw LocalIPCCodecError.missingNewline
        }
        return payload
    }
}

private func readQueuedEvents(for socketURL: URL) throws -> [PendingLocalEvent] {
    try queueLines(for: socketURL).map { line in
        try PendingLocalEventCodec().decode(line)
    }
}

private func temporaryQueueFiles(for socketURL: URL) throws -> [String] {
    let parentURL = socketURL.deletingLastPathComponent()
    return try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
        .filter { $0.hasPrefix(".pending-hooks.") && $0.hasSuffix(".tmp") }
        .sorted()
}

private func fileMode(at url: URL) throws -> mode_t {
    try fileStatus(at: url).st_mode & mode_t(0o777)
}

private func fileStatus(at url: URL) throws -> stat {
    var status = stat()
    guard url.path.withCString({ lstat($0, &status) }) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return status
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
