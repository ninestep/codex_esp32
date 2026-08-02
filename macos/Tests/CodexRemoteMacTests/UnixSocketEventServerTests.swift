import Darwin
import Foundation
import XCTest
@testable import CodexRemoteCore
@testable import CodexRemoteMac

final class UnixSocketEventServerTests: XCTestCase {
    func testStartCreatesSocketWithOwnerOnlyModeAndStopRemovesIt() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let server = UnixSocketEventServer(socketURL: socketURL, handler: { _ in })

        try await server.start()

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertEqual(try socketMode(at: socketURL), 0o600)
        XCTAssertEqual(try fileType(at: socketURL), S_IFSOCK)

        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))

        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testStopBeforeStartDoesNotRemoveExistingRegularFileAtSocketPath() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let originalData = Data("keep me".utf8)
        FileManager.default.createFile(atPath: socketURL.path, contents: originalData)
        let server = UnixSocketEventServer(socketURL: socketURL, handler: { _ in })

        await server.stop()

        XCTAssertEqual(try Data(contentsOf: socketURL), originalData)
    }

    func testStopDoesNotRemoveReplacementFileWhenSocketPathWasExternallyReplaced() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let replacementData = Data("replacement".utf8)
        let server = UnixSocketEventServer(socketURL: socketURL, handler: { _ in })
        try await server.start()

        XCTAssertEqual(unlink(socketURL.path), 0)
        FileManager.default.createFile(atPath: socketURL.path, contents: replacementData)

        await server.stop()

        XCTAssertEqual(try Data(contentsOf: socketURL), replacementData)
    }

    func testLaunchRegisteredFrameCallsHandlerAndReturnsOKThenClosesConnection() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let recorder = EventRecorder()
        let server = UnixSocketEventServer(socketURL: socketURL) { event in
            await recorder.record(event)
        }
        try await server.start()

        let event = LocalEvent.launchRegistered(
            LaunchRegistration(
                launcherInstanceID: "launch-1",
                terminalTargetID: "terminal-7",
                displayTitle: "ESP32",
                workingDirectoryLabel: "~/esp32"
            )
        )
        let result = try await sendFrame(try LocalEventCodec().encode(event), to: socketURL)

        XCTAssertEqual(result.response, SocketResponse(ok: true, error: nil))
        XCTAssertTrue(result.connectionClosed)
        let recordedEvents = await recorder.events()
        XCTAssertEqual(recordedEvents, [event])

        await server.stop()
    }

    func testHandlerErrorReturnsFixedFailureCodeWithoutLeakingInternalError() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let server = UnixSocketEventServer(socketURL: socketURL) { _ in
            throw HandlerFailure.sensitiveToken
        }
        try await server.start()

        let event = LocalEvent.launchRegistered(
            LaunchRegistration(
                launcherInstanceID: "launch-1",
                terminalTargetID: "terminal-7",
                displayTitle: "ESP32",
                workingDirectoryLabel: "~/esp32"
            )
        )
        let result = try await sendFrame(try LocalEventCodec().encode(event), to: socketURL)

        XCTAssertEqual(result.response, SocketResponse(ok: false, error: "handler_failed"))
        XCTAssertFalse(result.rawResponseString.contains("sensitiveToken"))

        await server.stop()
    }

    func testMalformedJSONReturnsInvalidEventAndDoesNotCallHandler() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let recorder = EventRecorder()
        let server = UnixSocketEventServer(socketURL: socketURL) { event in
            await recorder.record(event)
        }
        try await server.start()

        let result = try await sendFrame(Data(#"{"type":"launchRegistered""#.utf8), to: socketURL)

        XCTAssertEqual(result.response, SocketResponse(ok: false, error: "invalid_event"))
        let recordedEvents = await recorder.events()
        XCTAssertEqual(recordedEvents, [])

        await server.stop()
    }

    func testOversizedFrameReturnsFrameTooLargeAndServerAcceptsNextValidConnection() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let recorder = EventRecorder()
        let server = UnixSocketEventServer(socketURL: socketURL) { event in
            await recorder.record(event)
        }
        try await server.start()

        let oversized = Data(repeating: 0x20, count: LocalEventCodec.maximumFrameBytes + 1)
        let oversizedResult = try await sendFrame(oversized, to: socketURL)
        XCTAssertEqual(oversizedResult.response, SocketResponse(ok: false, error: "frame_too_large"))
        var recordedEvents = await recorder.events()
        XCTAssertEqual(recordedEvents, [])

        let event = LocalEvent.launchRegistered(
            LaunchRegistration(
                launcherInstanceID: "launch-2",
                terminalTargetID: "terminal-8",
                displayTitle: "ESP32 Monitor",
                workingDirectoryLabel: "~/esp32-monitor"
            )
        )
        let validResult = try await sendFrame(try LocalEventCodec().encode(event), to: socketURL)
        XCTAssertEqual(validResult.response, SocketResponse(ok: true, error: nil))
        recordedEvents = await recorder.events()
        XCTAssertEqual(recordedEvents, [event])

        await server.stop()
    }

    func testIdleClientTimesOutWithoutCallingHandlerAndServerAcceptsNextValidConnection() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let recorder = EventRecorder()
        let server = UnixSocketEventServer(
            socketURL: socketURL,
            frameReadTimeout: .milliseconds(50)
        ) { event in
            await recorder.record(event)
        }
        try await server.start()

        let idleClient = try openConnectedClient(to: socketURL)
        defer {
            close(idleClient)
        }

        let timeoutResult = try await readResponse(from: idleClient)
        XCTAssertEqual(timeoutResult.response, SocketResponse(ok: false, error: "read_timeout"))
        var recordedEvents = await recorder.events()
        XCTAssertEqual(recordedEvents, [])

        let event = LocalEvent.launchRegistered(
            LaunchRegistration(
                launcherInstanceID: "launch-timeout",
                terminalTargetID: "terminal-timeout",
                displayTitle: "ESP32 Timeout",
                workingDirectoryLabel: "~/esp32-timeout"
            )
        )
        let validResult = try await sendFrame(try LocalEventCodec().encode(event), to: socketURL)
        XCTAssertEqual(validResult.response, SocketResponse(ok: true, error: nil))
        recordedEvents = await recorder.events()
        XCTAssertEqual(recordedEvents, [event])

        await server.stop()
    }

    func testConnectionLifecycleIgnoresCompleteFrameAfterTimeoutResponseIsClaimed() {
        var lifecycle = ConnectionLifecycle()

        XCTAssertTrue(lifecycle.claimTimeoutResponse())
        XCTAssertFalse(lifecycle.claimFrameProcessing())
        XCTAssertFalse(lifecycle.claimProcessingResponse())
        XCTAssertFalse(lifecycle.claimTimeoutResponse())
    }

    func testConnectionLifecycleRejectsTimeoutAfterFrameProcessingHasStarted() {
        var lifecycle = ConnectionLifecycle()

        XCTAssertTrue(lifecycle.claimFrameProcessing())
        XCTAssertFalse(lifecycle.claimTimeoutResponse())
        XCTAssertTrue(lifecycle.claimProcessingResponse())
        XCTAssertFalse(lifecycle.claimProcessingResponse())
    }

    func testTimedOutConnectionDoesNotProcessLateCompleteFrameOrSendSecondResponse() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let recorder = EventRecorder()
        let server = UnixSocketEventServer(
            socketURL: socketURL,
            frameReadTimeout: .milliseconds(5)
        ) { event in
            await recorder.record(event)
        }
        try await server.start()

        let client = try openConnectedClient(to: socketURL)
        defer {
            close(client)
        }
        try await Task.sleep(for: .milliseconds(30))

        let event = LocalEvent.launchRegistered(
            LaunchRegistration(
                launcherInstanceID: "late-launch",
                terminalTargetID: "late-terminal",
                displayTitle: "Late ESP32",
                workingDirectoryLabel: "~/late"
            )
        )
        try? writeAll(try LocalEventCodec().encode(event), to: client)
        _ = shutdown(client, SHUT_WR)

        let responseData = try await readRawResponse(from: client)
        XCTAssertEqual(responseData, Data(#"{"ok":false,"error":"read_timeout"}"#.utf8))
        XCTAssertEqual(try JSONDecoder().decode(SocketResponse.self, from: responseData), SocketResponse(ok: false, error: "read_timeout"))
        let recordedEvents = await recorder.events()
        XCTAssertEqual(recordedEvents, [])

        await server.stop()
    }

    func testConnectionLimitReturnsServerBusyAndKeepsExistingServerUsable() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let recorder = EventRecorder()
        let server = UnixSocketEventServer(
            socketURL: socketURL,
            maximumActiveConnections: 2,
            frameReadTimeout: .seconds(5),
            handler: { event in
                await recorder.record(event)
            }
        )
        try await server.start()

        let firstIdleClient = try openConnectedClient(to: socketURL)
        let secondIdleClient = try openConnectedClient(to: socketURL)
        defer {
            close(secondIdleClient)
        }

        let busyClient = try openConnectedClient(to: socketURL)
        let busyResult = try await waitForServerBusy(from: busyClient, to: socketURL)

        XCTAssertEqual(busyResult.response, SocketResponse(ok: false, error: "server_busy"))

        close(firstIdleClient)
        let event = LocalEvent.launchRegistered(
            LaunchRegistration(
                launcherInstanceID: "after-busy",
                terminalTargetID: "terminal-after-busy",
                displayTitle: "ESP32 After Busy",
                workingDirectoryLabel: "~/after-busy"
            )
        )
        let successAfterSlotRelease = try await sendFrameEventually(
            try LocalEventCodec().encode(event),
            to: socketURL,
            expected: SocketResponse(ok: true, error: nil)
        )
        XCTAssertEqual(successAfterSlotRelease.response, SocketResponse(ok: true, error: nil))
        let recordedEvents = await recorder.events()
        XCTAssertEqual(recordedEvents, [event])

        await server.stop()
    }

    func testStartThrowsExplicitLifecycleAndPathErrors() async throws {
        let socketURL = try makeSocketFixture().socketURL
        let server = UnixSocketEventServer(socketURL: socketURL, handler: { _ in })
        try await server.start()

        do {
            try await server.start()
            XCTFail("Expected alreadyStarted")
        } catch {
            XCTAssertEqual(error as? UnixSocketEventServerError, .alreadyStarted)
        }
        await server.stop()

        let missingParentURL = socketURL.deletingLastPathComponent()
            .appendingPathComponent("missing")
            .appendingPathComponent("events.sock")
        let missingParentServer = UnixSocketEventServer(socketURL: missingParentURL, handler: { _ in })
        do {
            try await missingParentServer.start()
            XCTFail("Expected parentDirectoryMissing")
        } catch {
            XCTAssertEqual(
                error as? UnixSocketEventServerError,
                .parentDirectoryMissing(missingParentURL.deletingLastPathComponent().path)
            )
        }

        let longPathURL = socketURL.deletingLastPathComponent()
            .appendingPathComponent(String(repeating: "x", count: 200))
        let longPathServer = UnixSocketEventServer(socketURL: longPathURL, handler: { _ in })
        do {
            try await longPathServer.start()
            XCTFail("Expected socketPathTooLong")
        } catch {
            XCTAssertEqual(error as? UnixSocketEventServerError, .socketPathTooLong(longPathURL.path))
        }

        FileManager.default.createFile(atPath: socketURL.path, contents: Data("existing".utf8))
        let existingPathServer = UnixSocketEventServer(socketURL: socketURL, handler: { _ in })
        do {
            try await existingPathServer.start()
            XCTFail("Expected socketPathAlreadyExists")
        } catch {
            XCTAssertEqual(error as? UnixSocketEventServerError, .socketPathAlreadyExists(socketURL.path))
        }
    }

    private func makeSocketFixture() throws -> SocketFixture {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ues-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return SocketFixture(socketURL: directory.appendingPathComponent("e.sock"))
    }
}

private actor EventRecorder {
    private var recordedEvents: [LocalEvent] = []

    func record(_ event: LocalEvent) {
        recordedEvents.append(event)
    }

    func events() -> [LocalEvent] {
        recordedEvents
    }
}

private enum HandlerFailure: Error {
    case sensitiveToken
}

private struct SocketResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let error: String?
}

private struct SocketExchangeResult: Sendable {
    let response: SocketResponse
    let rawResponseString: String
    let connectionClosed: Bool
}

private struct SocketFixture {
    let socketURL: URL
}

private enum TestTimeoutError: Error {
    case timedOut
}

private enum POSIXClientError: Error, Sendable {
    case systemCall(String, Int32)
    case socketPathTooLong(String)
    case emptyResponse
}

private func socketMode(at url: URL) throws -> Int {
    try Int(fileStatus(at: url).st_mode & 0o777)
}

private func fileType(at url: URL) throws -> mode_t {
    try fileStatus(at: url).st_mode & S_IFMT
}

private func fileStatus(at url: URL) throws -> stat {
    var status = stat()
    let result = url.path.withCString { lstat($0, &status) }
    if result != 0 {
        throw POSIXClientError.systemCall("lstat", errno)
    }
    return status
}

private func sendFrame(_ frame: Data, to socketURL: URL) async throws -> SocketExchangeResult {
    try await withTimeout(seconds: 3) {
        try await Task.detached {
            try sendFrameSynchronously(frame, to: socketURL)
        }.value
    }
}

private func withTimeout<T: Sendable>(
    seconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            throw TestTimeoutError.timedOut
        }

        guard let result = try await group.next() else {
            throw TestTimeoutError.timedOut
        }
        group.cancelAll()
        return result
    }
}

private func readResponse(from fileDescriptor: Int32) async throws -> SocketExchangeResult {
    let responseData = try await readRawResponse(from: fileDescriptor)
    let response = try JSONDecoder().decode(SocketResponse.self, from: responseData)
    return SocketExchangeResult(
        response: response,
        rawResponseString: String(decoding: responseData, as: UTF8.self),
        connectionClosed: true
    )
}

private func readRawResponse(from fileDescriptor: Int32) async throws -> Data {
    try await withTimeout(seconds: 3) {
        try await Task.detached {
            let responseData = try readUntilEOF(from: fileDescriptor)
            guard !responseData.isEmpty else {
                throw POSIXClientError.emptyResponse
            }
            return responseData
        }.value
    }
}

private func sendFrameEventually(
    _ frame: Data,
    to socketURL: URL,
    expected: SocketResponse
) async throws -> SocketExchangeResult {
    let deadline = Date().addingTimeInterval(3)
    var lastResult: SocketExchangeResult?

    while Date() < deadline {
        let result = try await sendFrame(frame, to: socketURL)
        if result.response == expected {
            return result
        }
        lastResult = result
        try await Task.sleep(for: .milliseconds(10))
    }

    return try XCTUnwrap(lastResult)
}

private func waitForServerBusy(from firstClient: Int32, to socketURL: URL) async throws -> SocketExchangeResult {
    var client: Int32? = firstClient
    defer {
        if let client {
            close(client)
        }
    }

    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let currentClient = try XCTUnwrap(client)
        do {
            return try await readResponse(from: currentClient)
        } catch POSIXClientError.systemCall("read", EAGAIN) {
            close(currentClient)
            client = nil
            try await Task.sleep(for: .milliseconds(10))
            client = try openConnectedClient(to: socketURL)
        }
    }

    return try await readResponse(from: try XCTUnwrap(client))
}

private func sendFrameSynchronously(_ frame: Data, to socketURL: URL) throws -> SocketExchangeResult {
    let fileDescriptor = try openConnectedClient(to: socketURL)
    defer {
        close(fileDescriptor)
    }

    try writeAll(frame, to: fileDescriptor)
    guard shutdown(fileDescriptor, SHUT_WR) == 0 else {
        throw POSIXClientError.systemCall("shutdown", errno)
    }

    let responseData = try readUntilEOF(from: fileDescriptor)
    guard !responseData.isEmpty else {
        throw POSIXClientError.emptyResponse
    }
    let response = try JSONDecoder().decode(SocketResponse.self, from: responseData)
    return SocketExchangeResult(
        response: response,
        rawResponseString: String(decoding: responseData, as: UTF8.self),
        connectionClosed: true
    )
}

private func openConnectedClient(to socketURL: URL) throws -> Int32 {
    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
        throw POSIXClientError.systemCall("socket", errno)
    }

    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    guard setsockopt(
        fileDescriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    ) == 0 else {
        throw POSIXClientError.systemCall("setsockopt", errno)
    }

    var noSignal: Int32 = 1
    guard setsockopt(
        fileDescriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        throw POSIXClientError.systemCall("setsockopt", errno)
    }

    try connect(fileDescriptor: fileDescriptor, to: socketURL.path)
    return fileDescriptor
}

private func connect(fileDescriptor: Int32, to path: String) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let maximumPathBytes = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count < maximumPathBytes else {
        throw POSIXClientError.socketPathTooLong(path)
    }

    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: pathBytes + [0])
    }

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.connect(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        throw POSIXClientError.systemCall("connect", errno)
    }
}

private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return
        }
        var offset = 0
        while offset < buffer.count {
            let written = write(fileDescriptor, baseAddress.advanced(by: offset), buffer.count - offset)
            if written < 0 {
                throw POSIXClientError.systemCall("write", errno)
            }
            offset += written
        }
    }
}

private func readUntilEOF(from fileDescriptor: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)

    while true {
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        if bytesRead < 0 {
            throw POSIXClientError.systemCall("read", errno)
        }
        if bytesRead == 0 {
            return data
        }
        data.append(buffer, count: bytesRead)
    }
}
