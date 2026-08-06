import Foundation

public struct CommandRequest: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]?

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) throws {
        guard executablePath.hasPrefix("/") else {
            throw CommandRunnerError.relativeExecutablePath
        }
        try self.init(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            environment: environment
        )
    }

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) throws {
        self.executableURL = try Self.validatedExecutableURL(executableURL)
        self.arguments = arguments
        self.environment = environment
    }

    fileprivate static func validatedExecutableURL(_ executableURL: URL) throws -> URL {
        let standardizedURL = executableURL.standardizedFileURL
        guard executableURL.isFileURL,
              executableURL.baseURL == nil,
              executableURL.path.hasPrefix("/"),
              executableURL.path == standardizedURL.path
        else {
            throw CommandRunnerError.relativeExecutablePath
        }
        return standardizedURL
    }
}

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandEvent: Equatable, Sendable {
    case standardOutput(String)
    case standardError(String)
    case completed(Int32)
}

public enum CommandRunnerError: Error, Equatable, Sendable {
    case relativeExecutablePath
    case launchFailed(String)
}

public protocol CommandRunning: Sendable {
    func run(_ request: CommandRequest) async throws -> CommandResult
    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, any Error>
}

public struct CommandOutputRedactor: Sendable {
    public init() {}

    public func redact(_ value: String) -> String {
        var redacted = value
        redacted = replace(
            pattern: #"(?i)("?(?:token|password|api[_-]?key|secret)"?)(\s*:\s*")([^"]+)(")"#,
            in: redacted
        ) { match in
            "\(match[1])\(match[2])[REDACTED]\(match[4])"
        }
        redacted = replace(
            pattern: #"(?i)\b(authorization)(\s*[:=]\s*)Bearer\s+[A-Za-z0-9._~+/=-]+"#,
            in: redacted
        ) { match in
            "\(match[1])\(match[2])Bearer [REDACTED]"
        }
        redacted = replace(
            pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            in: redacted
        ) { _ in
            "Bearer [REDACTED]"
        }
        redacted = replace(
            pattern: #"(?i)\b(authorization)(\s*[:=]\s*)(?!Bearer\b)([^\s'"]+)"#,
            in: redacted
        ) { match in
            "\(match[1])\(match[2])[REDACTED]"
        }
        redacted = replace(
            pattern: #"(?i)\b(token|password|api[_-]?key|secret)\b(\s*[:=]\s*)([^\s'"]+)"#,
            in: redacted
        ) { match in
            "\(match[1])\(match[2])[REDACTED]"
        }
        redacted = replace(
            pattern: #"(?i)\b([A-Z0-9_]*(?:SECRET_ACCESS_KEY|API_KEY|TOKEN|PASSWORD|SECRET))(\s*=\s*)([^\s'"]+)"#,
            in: redacted
        ) { match in
            "\(match[1])\(match[2])[REDACTED]"
        }
        redacted = replace(pattern: #"/Users/[^/\s]+"#, in: redacted) { _ in "~" }
        return redacted
    }

    private func replace(
        pattern: String,
        in value: String,
        replacement: (RegexMatch) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = expression.matches(in: value, range: range).reversed()
        var result = value
        for match in matches {
            guard let matchRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(matchRange, with: replacement(RegexMatch(match: match, value: result)))
        }
        return result
    }
}

public struct ProcessCommandRunner: CommandRunning {
    public static let defaultMaximumOutputBytes = 64 * 1024
    public static let defaultMaximumStreamLineBytes = 8 * 1024
    private let maxOutputBytes: Int
    private let maxStreamLineBytes: Int
    private let redactor: CommandOutputRedactor
    private let onProcessStarted: @Sendable (Int32) -> Void

    public init(
        maxOutputBytes: Int = ProcessCommandRunner.defaultMaximumOutputBytes,
        maxStreamLineBytes: Int = ProcessCommandRunner.defaultMaximumStreamLineBytes,
        redactor: CommandOutputRedactor = CommandOutputRedactor(),
        onProcessStarted: @escaping @Sendable (Int32) -> Void = { _ in }
    ) {
        self.maxOutputBytes = max(1, maxOutputBytes)
        self.maxStreamLineBytes = max(1, maxStreamLineBytes)
        self.redactor = redactor
        self.onProcessStarted = onProcessStarted
    }

    public func run(_ request: CommandRequest) async throws -> CommandResult {
        try validate(request)
        let holder = RunningProcessHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try runBlocking(request, holder: holder))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            holder.cancel()
        }
    }

    public func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(128)) { continuation in
            do {
                try validate(request)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let process = Process()
            process.executableURL = request.executableURL
            process.arguments = request.arguments
            process.environment = request.environment
            let processBox = RunningProcess(process)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let resources = StreamProcessResources(
                process: process,
                stdoutHandle: stdoutPipe.fileHandleForReading,
                stderrHandle: stderrPipe.fileHandleForReading
            )

            do {
                try process.run()
                onProcessStarted(process.processIdentifier)
            } catch {
                continuation.finish(throwing: CommandRunnerError.launchFailed(error.localizedDescription))
                return
            }

            let group = DispatchGroup()
            let limiter = StreamOutputLimiter(
                maxTotalBytes: maxOutputBytes,
                maxLineBytes: maxStreamLineBytes,
                diagnostic: {
                    continuation.yield(.standardError("[truncated]"))
                }
            )
            streamLines(
                from: stdoutPipe.fileHandleForReading,
                group: group,
                limiter: limiter,
                yield: { continuation.yield(.standardOutput(redactor.redact($0))) }
            )
            streamLines(
                from: stderrPipe.fileHandleForReading,
                group: group,
                limiter: limiter,
                yield: { continuation.yield(.standardError(redactor.redact($0))) }
            )

            DispatchQueue.global(qos: .utility).async {
                processBox.waitUntilExit()
                group.wait()
                resources.markFinished()
                continuation.yield(.completed(processBox.terminationStatus))
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                resources.cancel()
            }
        }
    }

    private func validate(_ request: CommandRequest) throws {
        _ = try CommandRequest.validatedExecutableURL(request.executableURL)
    }

    private func runBlocking(_ request: CommandRequest, holder: RunningProcessHolder) throws -> CommandResult {
        let stdout = BoundedCommandOutput(maxBytes: maxOutputBytes)
        let stderr = BoundedCommandOutput(maxBytes: maxOutputBytes)
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        guard holder.set(process) else {
            throw CancellationError()
        }

        do {
            try process.run()
            onProcessStarted(process.processIdentifier)
        } catch {
            throw CommandRunnerError.launchFailed(error.localizedDescription)
        }

        let group = DispatchGroup()
        readOutput(from: stdoutPipe.fileHandleForReading, into: stdout, group: group)
        readOutput(from: stderrPipe.fileHandleForReading, into: stderr, group: group)

        process.waitUntilExit()
        group.wait()

        if holder.isCancelled {
            throw CancellationError()
        }

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: redactor.redact(stdout.stringValue()),
            stderr: redactor.redact(stderr.stringValue())
        )
    }

    private func readOutput(
        from handle: FileHandle,
        into output: BoundedCommandOutput,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else {
                    return
                }
                output.append(data)
            }
        }
    }

    private func streamLines(
        from handle: FileHandle,
        group: DispatchGroup,
        limiter: StreamOutputLimiter,
        yield: @escaping @Sendable (String) -> Void
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            let buffer = CommandLineBuffer(limiter: limiter, yield: yield)
            while true {
                guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else {
                    buffer.finish()
                    return
                }
                buffer.append(data)
            }
        }
    }
}

private final class StreamProcessResources: @unchecked Sendable {
    private let process: Process
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let lock = NSLock()
    private var finished = false
    private var cancelled = false

    init(process: Process, stdoutHandle: FileHandle, stderrHandle: FileHandle) {
        self.process = process
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !finished, !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let pid = process.processIdentifier
        let shouldTerminate = process.isRunning
        lock.unlock()

        stdoutHandle.closeFile()
        stderrHandle.closeFile()

        if shouldTerminate {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(200)) { [process, pid] in
                if process.isRunning {
                    Darwin.kill(pid, SIGKILL)
                }
            }
        }
    }
}

private final class StreamOutputLimiter: @unchecked Sendable {
    private let maxTotalBytes: Int
    let maxLineBytes: Int
    private let diagnostic: @Sendable () -> Void
    private let lock = NSLock()
    private var usedBytes = 0
    private var emittedDiagnostic = false

    init(maxTotalBytes: Int, maxLineBytes: Int, diagnostic: @escaping @Sendable () -> Void) {
        self.maxTotalBytes = maxTotalBytes
        self.maxLineBytes = maxLineBytes
        self.diagnostic = diagnostic
    }

    func take(_ data: Data) -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard usedBytes < maxTotalBytes else {
            emitDiagnosticIfNeededLocked()
            return Data()
        }

        let remaining = maxTotalBytes - usedBytes
        if data.count <= remaining {
            usedBytes += data.count
            return data
        }

        usedBytes = maxTotalBytes
        emitDiagnosticIfNeededLocked()
        return Data(data.prefix(remaining))
    }

    func emitDiagnosticIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        emitDiagnosticIfNeededLocked()
    }

    private func emitDiagnosticIfNeededLocked() {
        guard !emittedDiagnostic else { return }
        emittedDiagnostic = true
        diagnostic()
    }
}

private final class RunningProcessHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func set(_ process: Process) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            process.terminate()
            return false
        }
        self.process = process
        lock.unlock()
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

private struct RegexMatch {
    private let match: NSTextCheckingResult
    private let value: String

    init(match: NSTextCheckingResult, value: String) {
        self.match = match
        self.value = value
    }

    subscript(index: Int) -> String {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: value)
        else { return "" }
        return String(value[range])
    }
}

private final class BoundedCommandOutput: @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }

        guard data.count < maxBytes else {
            truncated = true
            return
        }

        let remaining = maxBytes - data.count
        if chunk.count > remaining {
            data.append(chunk.prefix(remaining))
            truncated = true
        } else {
            data.append(chunk)
        }
    }

    func stringValue() -> String {
        lock.lock()
        defer { lock.unlock() }

        var value = data.validUTF8String()
        if truncated {
            value += "\n[truncated]"
        }
        return value
    }
}

private final class CommandLineBuffer: @unchecked Sendable {
    private var buffer = Data()
    private var droppingUntilNewline = false
    private let limiter: StreamOutputLimiter
    private let yield: @Sendable (String) -> Void

    init(limiter: StreamOutputLimiter, yield: @escaping @Sendable (String) -> Void) {
        self.limiter = limiter
        self.yield = yield
    }

    func append(_ data: Data) {
        for byte in data {
            if droppingUntilNewline {
                if byte == UInt8(ascii: "\n") {
                    droppingUntilNewline = false
                }
                continue
            }

            if byte == UInt8(ascii: "\n") {
                emitBuffer()
            } else if buffer.count >= limiter.maxLineBytes {
                emitBuffer()
                limiter.emitDiagnosticIfNeeded()
                droppingUntilNewline = true
            } else {
                buffer.append(byte)
            }
        }
    }

    func finish() {
        if !buffer.isEmpty {
            emitBuffer()
        }
    }

    private func emitBuffer() {
        if buffer.last == UInt8(ascii: "\r") {
            buffer.removeLast()
        }
        let data = limiter.take(buffer)
        if !data.isEmpty {
            yield(data.validUTF8String())
        }
        buffer.removeAll(keepingCapacity: true)
    }
}

private extension Data {
    func validUTF8String() -> String {
        var endIndex = count
        while endIndex > 0 {
            let slice = prefix(endIndex)
            if let value = String(data: slice, encoding: .utf8) {
                return value
            }
            endIndex -= 1
        }
        return ""
    }
}

private final class RunningProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()

    init(_ process: Process) {
        self.process = process
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }

    func terminateIfRunning() {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning {
            process.terminate()
        }
    }
}
