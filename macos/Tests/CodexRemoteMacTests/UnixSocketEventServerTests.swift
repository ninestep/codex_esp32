import Darwin
import Foundation
import XCTest
@testable import CodexRemoteCore
@testable import CodexRemoteMac

final class UnixSocketEventServerTests: XCTestCase {
    func testStartCreatesSocketWithOwnerOnlyModeAndStopRemovesIt() async throws {
        let socketURL = try makeSocketURL()
        let server = UnixSocketEventServer(socketURL: socketURL, handler: { _ in })

        try await server.start()

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertEqual(try socketMode(at: socketURL), 0o600)

        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))

        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testLaunchRegisteredFrameCallsHandlerAndReturnsOKThenClosesConnection() async throws {
        let socketURL = try makeSocketURL()
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
        let socketURL = try makeSocketURL()
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
        let socketURL = try makeSocketURL()
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
        let socketURL = try makeSocketURL()
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

    func testStartThrowsExplicitLifecycleAndPathErrors() async throws {
        let socketURL = try makeSocketURL()
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

private enum TestTimeoutError: Error {
    case timedOut
}

private enum POSIXClientError: Error, Sendable {
    case systemCall(String, Int32)
    case socketPathTooLong(String)
    case emptyResponse
}

private func makeSocketURL() throws -> URL {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("ues-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory.appendingPathComponent("e.sock")
}

private func socketMode(at url: URL) throws -> Int {
    var status = stat()
    let result = url.path.withCString { stat($0, &status) }
    if result != 0 {
        throw POSIXClientError.systemCall("stat", errno)
    }
    return Int(status.st_mode & 0o777)
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

private func sendFrameSynchronously(_ frame: Data, to socketURL: URL) throws -> SocketExchangeResult {
    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
        throw POSIXClientError.systemCall("socket", errno)
    }
    defer {
        close(fileDescriptor)
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

    try connect(fileDescriptor: fileDescriptor, to: socketURL.path)
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
