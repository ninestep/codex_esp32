import Foundation
import XCTest
@testable import CodexRemoteMac

final class BlackHoleInstallerTests: XCTestCase {
    func testMissingHomebrewDoesNotRunInstall() async {
        let runner = RecordingCommandRunner(events: [])
        let installer = BlackHoleInstaller(commandRunner: runner, brewURL: nil)

        do {
            try await installer.install()
            XCTFail("expected homebrewMissing")
        } catch {
            XCTAssertEqual(error as? BlackHoleInstallerError, .homebrewMissing)
        }
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests, [])
    }

    func testRetryAfterFailureKeepsExistingLogSubscriberOpenAndReportsSecondSuccess() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let runner = SequencedCommandRunner(eventBatches: [
            [.standardError("token=first-secret"), .completed(12)],
            [.standardOutput("retry ok"), .completed(0)],
        ])
        let installer = BlackHoleInstaller(
            commandRunner: runner,
            brewURL: brewURL,
            catalog: SequencedBlackHoleCatalog(values: [false, false, true]),
            brewPathValidator: StaticBrewPathValidator(validPaths: [brewURL.standardizedFileURL.path])
        )
        let collector = Task {
            await collectLogMessages(from: installer.logLines) { messages in
                messages.contains("BlackHole install attempt 2 completed: BlackHole 2ch installed and verified")
            }
        }

        do {
            try await installer.install()
            XCTFail("expected commandFailed")
        } catch let error as BlackHoleInstallerError {
            guard case .commandFailed(let exitCode, let stderrSummary) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(exitCode, 12)
            XCTAssertTrue(stderrSummary.contains("token=[REDACTED]"))
            XCTAssertFalse(stderrSummary.contains("first-secret"))
        }

        try await installer.install()
        let messages = try await withTimeout(.seconds(2)) {
            await collector.value
        }

        XCTAssertTrue(messages.contains("BlackHole install attempt 1 started"))
        XCTAssertTrue(messages.contains("BlackHole install attempt 1 failed with exit code 12"))
        XCTAssertTrue(messages.contains("BlackHole install attempt 2 started"))
        XCTAssertTrue(messages.contains("retry ok"))
        XCTAssertTrue(messages.contains("BlackHole install attempt 2 completed: BlackHole 2ch installed and verified"))
    }

    func testInvalidHomebrewPathDoesNotRunInstall() async {
        let runner = RecordingCommandRunner(events: [])
        let installer = BlackHoleInstaller(
            commandRunner: runner,
            brewURL: URL(fileURLWithPath: "/tmp/brew"),
            catalog: SequencedBlackHoleCatalog(values: []),
            brewPathValidator: StaticBrewPathValidator(validPaths: [])
        )

        do {
            try await installer.install()
            XCTFail("expected invalidHomebrewPath")
        } catch {
            XCTAssertEqual(error as? BlackHoleInstallerError, .invalidHomebrewPath("/tmp/brew"))
        }
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests, [])
    }

    func testInstallUsesOfficialCaskCommandAndRequiresAudioDeviceAfterward() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let runner = RecordingCommandRunner(events: [.standardOutput("Installing"), .completed(0)])
        let catalog = SequencedBlackHoleCatalog(values: [false, true])

        try await BlackHoleInstaller(
            commandRunner: runner,
            brewURL: brewURL,
            catalog: catalog,
            brewPathValidator: StaticBrewPathValidator(validPaths: [brewURL.standardizedFileURL.path])
        ).install()

        let requests = await runner.recordedRequests()
        XCTAssertEqual(
            requests,
            [try CommandRequest(executableURL: brewURL, arguments: ["install", "--cask", "blackhole-2ch"])]
        )
        let callCount = await catalog.recordedCallCount()
        XCTAssertEqual(callCount, 2)
    }

    func testNonZeroExitReturnsStructuredFailureWithRedactedBoundedStderr() async {
        let brewURL = URL(fileURLWithPath: "/usr/local/bin/brew")
        let secret = String(repeating: "x", count: 4096)
        let runner = RecordingCommandRunner(events: [
            .standardError("token=\(secret)"),
            .completed(65),
        ])
        let installer = BlackHoleInstaller(
            commandRunner: runner,
            brewURL: brewURL,
            catalog: SequencedBlackHoleCatalog(values: [false]),
            brewPathValidator: StaticBrewPathValidator(validPaths: [brewURL.standardizedFileURL.path])
        )

        do {
            try await installer.install()
            XCTFail("expected commandFailed")
        } catch let error as BlackHoleInstallerError {
            guard case .commandFailed(let exitCode, let stderrSummary) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(exitCode, 65)
            XCTAssertLessThanOrEqual(Data(stderrSummary.utf8).count, 2048)
            XCTAssertTrue(stderrSummary.contains("token=[REDACTED]"))
            XCTAssertFalse(stderrSummary.contains(secret))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testExitZeroWithoutAudioDeviceFailsVerification() async {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let runner = RecordingCommandRunner(events: [.completed(0)])
        let installer = BlackHoleInstaller(
            commandRunner: runner,
            brewURL: brewURL,
            catalog: SequencedBlackHoleCatalog(values: [false, false]),
            brewPathValidator: StaticBrewPathValidator(validPaths: [brewURL.standardizedFileURL.path])
        )

        do {
            try await installer.install()
            XCTFail("expected deviceMissingAfterInstall")
        } catch {
            XCTAssertEqual(error as? BlackHoleInstallerError, .deviceMissingAfterInstall)
        }
    }

    func testLogStreamRedactsBoundsSingleLineAndKeepsNewestFiveHundredLines() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let longSecret = String(repeating: "a", count: 4096)
        var events: [CommandEvent] = []
        for index in 0..<510 {
            events.append(.standardOutput("line-\(index) token=\(longSecret)"))
        }
        events.append(.completed(0))
        let installer = BlackHoleInstaller(
            commandRunner: RecordingCommandRunner(events: events),
            brewURL: brewURL,
            catalog: SequencedBlackHoleCatalog(values: [false, true]),
            brewPathValidator: StaticBrewPathValidator(validPaths: [brewURL.standardizedFileURL.path])
        )

        try await installer.install()
        let snapshot = await installer.recentLogLines()
        let outputLines = snapshot.filter { $0.message.hasPrefix("line-") }

        XCTAssertEqual(snapshot.count, 500)
        XCTAssertTrue(snapshot.first?.message.hasPrefix("line-11 ") == true)
        XCTAssertTrue(snapshot.allSatisfy { Data($0.message.utf8).count <= 2048 })
        XCTAssertTrue(outputLines.allSatisfy { $0.message.contains("token=[REDACTED]") })
        XCTAssertFalse(snapshot.contains { $0.message.contains(longSecret) })
    }

    func testLogStreamPublishesStdoutStderrAndStructuredCompletion() async throws {
        let brewURL = URL(fileURLWithPath: "/usr/local/bin/brew")
        let installer = BlackHoleInstaller(
            commandRunner: RecordingCommandRunner(events: [
                .standardOutput("stdout"),
                .standardError("stderr password=secret"),
                .completed(0),
            ]),
            brewURL: brewURL,
            catalog: SequencedBlackHoleCatalog(values: [false, true]),
            brewPathValidator: StaticBrewPathValidator(validPaths: [brewURL.standardizedFileURL.path])
        )
        let collector = Task {
            await collectLogLines(from: installer.logLines) { lines in
                lines.contains { $0.message == "BlackHole install attempt 1 completed: BlackHole 2ch installed and verified" }
            }
        }

        try await installer.install()
        let lines = try await withTimeout(.seconds(2)) {
            await collector.value
        }

        XCTAssertEqual(lines.map(\.level), [.info, .info, .warning, .info])
        XCTAssertEqual(lines.map(\.message), [
            "BlackHole install attempt 1 started",
            "stdout",
            "stderr password=[REDACTED]",
            "BlackHole install attempt 1 completed: BlackHole 2ch installed and verified",
        ])
    }

    func testCancellationCancelsRunnerStreamAndFinishesLogs() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let runner = CancellableCommandRunner()
        let installer = BlackHoleInstaller(
            commandRunner: runner,
            brewURL: brewURL,
            catalog: SequencedBlackHoleCatalog(values: [false]),
            brewPathValidator: StaticBrewPathValidator(validPaths: [brewURL.standardizedFileURL.path])
        )
        let logCollector = Task {
            await collectLogLines(from: installer.logLines) { lines in
                lines.contains { $0.message == "BlackHole install attempt 1 cancelled" }
            }
        }

        let installTask = Task {
            try await installer.install()
        }
        await runner.waitUntilStreaming()
        installTask.cancel()

        do {
            try await withTimeout(.seconds(2)) {
                try await installTask.value
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }

        let wasCancelled = await runner.cancelled()
        XCTAssertTrue(wasCancelled)
        let lines = try await withTimeout(.seconds(2)) {
            await logCollector.value
        }
        XCTAssertEqual(lines.last?.level, .warning)
        XCTAssertEqual(lines.last?.message, "BlackHole install attempt 1 cancelled")
    }

    func testRetryAfterCancellationKeepsLogStreamOpen() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let runner = FirstStreamCancellableThenSuccessRunner()
        let installer = BlackHoleInstaller(
            commandRunner: runner,
            brewURL: brewURL,
            catalog: SequencedBlackHoleCatalog(values: [false, false, true]),
            brewPathValidator: StaticBrewPathValidator(validPaths: [brewURL.standardizedFileURL.path])
        )
        let collector = Task {
            await collectLogMessages(from: installer.logLines) { messages in
                messages.contains("BlackHole install attempt 2 completed: BlackHole 2ch installed and verified")
            }
        }

        let firstInstall = Task {
            try await installer.install()
        }
        await runner.waitUntilFirstStreamStarted()
        firstInstall.cancel()
        do {
            try await withTimeout(.seconds(2)) {
                try await firstInstall.value
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }

        try await installer.install()
        let messages = try await withTimeout(.seconds(2)) {
            await collector.value
        }

        XCTAssertTrue(messages.contains("BlackHole install attempt 1 cancelled"))
        XCTAssertTrue(messages.contains("BlackHole install attempt 2 started"))
        XCTAssertTrue(messages.contains("retry stdout"))
        XCTAssertTrue(messages.contains("BlackHole install attempt 2 completed: BlackHole 2ch installed and verified"))
    }

    func testConcurrentInstallRejectsSecondAttemptAsBusyWithoutSecondRunnerRequest() async throws {
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let runner = CancellableCommandRunner()
        let installer = BlackHoleInstaller(
            commandRunner: runner,
            brewURL: brewURL,
            catalog: SequencedBlackHoleCatalog(values: [false]),
            brewPathValidator: StaticBrewPathValidator(validPaths: [brewURL.standardizedFileURL.path])
        )
        let firstInstall = Task {
            try await installer.install()
        }
        await runner.waitUntilStreaming()

        do {
            try await installer.install()
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(error as? BlackHoleInstallerError, .busy)
        }

        let requestsWhileBusy = await runner.recordedRequests()
        XCTAssertEqual(requestsWhileBusy.count, 1)
        firstInstall.cancel()
        do {
            try await withTimeout(.seconds(2)) {
                try await firstInstall.value
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
    }
}

private func collectLogLines(
    from stream: AsyncStream<SetupLogLine>,
    until isComplete: ([SetupLogLine]) -> Bool
) async -> [SetupLogLine] {
    var lines: [SetupLogLine] = []
    for await line in stream {
        lines.append(line)
        if isComplete(lines) {
            return lines
        }
    }
    return lines
}

private func collectLogMessages(
    from stream: AsyncStream<SetupLogLine>,
    until isComplete: ([String]) -> Bool
) async -> [String] {
    let lines = await collectLogLines(from: stream) { lines in
        isComplete(lines.map(\.message))
    }
    return lines.map(\.message)
}

private actor RecordingCommandRunner: CommandRunning {
    private(set) var requests: [CommandRequest] = []
    private let events: [CommandEvent]

    init(events: [CommandEvent]) {
        self.events = events
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        requests.append(request)
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(request)
                for event in await self.eventsSnapshot() {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    private func record(_ request: CommandRequest) {
        requests.append(request)
    }

    func recordedRequests() -> [CommandRequest] {
        requests
    }

    private func eventsSnapshot() -> [CommandEvent] {
        events
    }
}

private actor SequencedCommandRunner: CommandRunning {
    private var requests: [CommandRequest] = []
    private var eventBatches: [[CommandEvent]]

    init(eventBatches: [[CommandEvent]]) {
        self.eventBatches = eventBatches
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        requests.append(request)
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let events = await self.recordAndNextBatch(request)
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    private func recordAndNextBatch(_ request: CommandRequest) -> [CommandEvent] {
        requests.append(request)
        guard !eventBatches.isEmpty else {
            return []
        }
        return eventBatches.removeFirst()
    }
}

private actor CancellableCommandRunner: CommandRunning {
    private var streamContinuation: AsyncThrowingStream<CommandEvent, any Error>.Continuation?
    private var streamingContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var wasCancelled = false
    private var requests: [CommandRequest] = []

    func run(_ request: CommandRequest) async throws -> CommandResult {
        CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.start(continuation, request: request)
            }
        }
    }

    func waitUntilStreaming() async {
        if streamContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            streamingContinuations.append(continuation)
        }
    }

    private func start(_ continuation: AsyncThrowingStream<CommandEvent, any Error>.Continuation, request: CommandRequest) {
        requests.append(request)
        streamContinuation = continuation
        continuation.onTermination = { @Sendable _ in
            Task {
                await self.recordCancellation()
            }
        }
        streamingContinuations.forEach { $0.resume() }
        streamingContinuations.removeAll()
    }

    private func recordCancellation() {
        wasCancelled = true
    }

    func cancelled() -> Bool {
        wasCancelled
    }

    func recordedRequests() -> [CommandRequest] {
        requests
    }
}

private actor FirstStreamCancellableThenSuccessRunner: CommandRunning {
    private var streamCount = 0
    private var firstStreamContinuations: [CheckedContinuation<Void, Never>] = []

    func run(_ request: CommandRequest) async throws -> CommandResult {
        CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let count = await self.nextStreamCount()
                if count == 1 {
                    await self.markFirstStreamStarted()
                    continuation.onTermination = { @Sendable _ in }
                } else {
                    continuation.yield(.standardOutput("retry stdout"))
                    continuation.yield(.completed(0))
                    continuation.finish()
                }
            }
        }
    }

    func waitUntilFirstStreamStarted() async {
        if streamCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            firstStreamContinuations.append(continuation)
        }
    }

    private func nextStreamCount() -> Int {
        streamCount += 1
        return streamCount
    }

    private func markFirstStreamStarted() {
        firstStreamContinuations.forEach { $0.resume() }
        firstStreamContinuations.removeAll()
    }
}

private actor SequencedBlackHoleCatalog: BlackHoleDeviceCatalog {
    private let values: [Bool]
    private var index = 0
    private(set) var callCount = 0

    init(values: [Bool]) {
        self.values = values
    }

    func hasBlackHole2ch() async -> Bool {
        defer {
            index += 1
            callCount += 1
        }
        guard index < values.count else {
            return values.last ?? false
        }
        return values[index]
    }

    func recordedCallCount() -> Int {
        callCount
    }
}

private struct StaticBrewPathValidator: BlackHoleBrewPathValidating {
    let validPaths: Set<String>

    init(validPaths: [String]) {
        self.validPaths = Set(validPaths)
    }

    func validate(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard validPaths.contains(standardized.path) else {
            throw BlackHoleInstallerError.invalidHomebrewPath(standardized.path)
        }
        return standardized
    }
}

private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestTimeoutError()
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private struct TestTimeoutError: Error {}
