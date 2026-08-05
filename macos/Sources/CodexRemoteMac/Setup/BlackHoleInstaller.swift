import Darwin
import Foundation

public enum BlackHoleInstallerError: Error, Equatable, Sendable {
    case homebrewMissing
    case invalidHomebrewPath(String)
    case commandFailed(exitCode: Int32, stderrSummary: String)
    case commandRunnerFailed(String)
    case deviceMissingAfterInstall
    case busy

    public var userMessage: String {
        switch self {
        case .homebrewMissing:
            "未检测到 Homebrew。请先安装 Homebrew，再执行 brew install --cask blackhole-2ch。"
        case .invalidHomebrewPath:
            "Homebrew 可执行文件不在受支持的位置。请确认 brew 位于 /opt/homebrew/bin/brew 或 /usr/local/bin/brew。"
        case .commandFailed(let exitCode, let stderrSummary):
            "Homebrew 安装命令失败（退出码 \(exitCode)）：\(stderrSummary)\n修复建议：在终端执行 brew install --cask blackhole-2ch，按提示完成管理员授权；安装后重启 Mac，再回到应用重新检查。"
        case .commandRunnerFailed(let detail):
            "无法执行 Homebrew 安装命令：\(detail)\n请在终端执行 brew install --cask blackhole-2ch；安装后重启 Mac，再回到应用重新检查。"
        case .deviceMissingAfterInstall:
            "Homebrew 已完成安装，但 CoreAudio 尚未发现 BlackHole 2ch。请重启 Mac 后重新检查。"
        case .busy:
            "BlackHole 安装任务正在运行，请等待当前任务结束后重试。"
        }
    }
}

public protocol BlackHoleDeviceCatalog: Sendable {
    func hasBlackHole2ch() async -> Bool
}

extension CoreAudioDeviceCatalog: BlackHoleDeviceCatalog {
    public func hasBlackHole2ch() async -> Bool {
        blackHole2ch() != nil
    }
}

public protocol BlackHoleBrewPathValidating: Sendable {
    func validate(_ url: URL) throws -> URL
}

public struct FileSystemBrewPathValidator: BlackHoleBrewPathValidating {
    private static let allowedPaths: Set<String> = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    public init() {}

    public func validate(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard url.isFileURL,
              url.baseURL == nil,
              url.path.hasPrefix("/"),
              url.path == standardized.path,
              Self.allowedPaths.contains(standardized.path)
        else {
            throw BlackHoleInstallerError.invalidHomebrewPath(standardized.path)
        }

        var status = stat()
        guard lstat(standardized.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              access(standardized.path, X_OK) == 0
        else {
            throw BlackHoleInstallerError.invalidHomebrewPath(standardized.path)
        }

        return standardized
    }
}

public final class BlackHoleInstaller: @unchecked Sendable {
    public var logLines: AsyncStream<SetupLogLine> {
        logBuffer.stream()
    }

    private let commandRunner: any CommandRunning
    private let brewURL: URL?
    private let catalog: any BlackHoleDeviceCatalog
    private let brewPathValidator: any BlackHoleBrewPathValidating
    private let redactor: CommandOutputRedactor
    private let logBuffer = BlackHoleInstallerLogBuffer(maxLineBytes: 2 * 1024, maxLines: 500)
    private let attemptState = BlackHoleInstallerAttemptState()

    public init(
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        brewURL: URL?,
        catalog: any BlackHoleDeviceCatalog = CoreAudioDeviceCatalog(),
        brewPathValidator: any BlackHoleBrewPathValidating = FileSystemBrewPathValidator(),
        redactor: CommandOutputRedactor = CommandOutputRedactor()
    ) {
        self.commandRunner = commandRunner
        self.brewURL = brewURL
        self.catalog = catalog
        self.brewPathValidator = brewPathValidator
        self.redactor = redactor
    }

    deinit {
        logBuffer.finish()
    }

    public func install() async throws {
        let attempt = try attemptState.begin()
        defer {
            attemptState.end()
        }
        appendLog(level: .info, message: "BlackHole install attempt \(attempt) started")

        guard let brewURL else {
            appendLog(level: .error, message: "BlackHole install attempt \(attempt) failed: Homebrew missing")
            throw BlackHoleInstallerError.homebrewMissing
        }
        let validBrewURL: URL
        do {
            validBrewURL = try brewPathValidator.validate(brewURL)
        } catch {
            appendLog(level: .error, message: "BlackHole install attempt \(attempt) failed: invalid Homebrew path")
            throw error
        }

        if await catalog.hasBlackHole2ch() {
            appendLog(level: .info, message: "BlackHole install attempt \(attempt) completed: BlackHole 2ch already installed")
            return
        }

        let request = try CommandRequest(
            executableURL: validBrewURL,
            arguments: ["install", "--cask", "blackhole-2ch"]
        )
        var stderrLines: [String] = []
        var exitCode: Int32?

        do {
            for try await event in commandRunner.stream(request) {
                try Task.checkCancellation()
                switch event {
                case .standardOutput(let line):
                    appendLog(level: .info, message: line)
                case .standardError(let line):
                    let bounded = appendLog(level: .warning, message: line)
                    stderrLines.append(bounded)
                    stderrLines = boundedRecent(lines: stderrLines, maxBytes: 2 * 1024)
                case .completed(let status):
                    exitCode = status
                }
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            appendLog(level: .warning, message: "BlackHole install attempt \(attempt) cancelled")
            throw CancellationError()
        } catch {
            let message = boundedLine(redactor.redact(error.localizedDescription))
            appendLog(level: .error, message: "BlackHole install attempt \(attempt) failed: \(message)")
            throw BlackHoleInstallerError.commandRunnerFailed(message)
        }

        guard let exitCode else {
            appendLog(level: .error, message: "BlackHole install attempt \(attempt) failed: brew install did not report completion")
            throw BlackHoleInstallerError.commandFailed(
                exitCode: -1,
                stderrSummary: "brew install did not report completion"
            )
        }
        guard exitCode == 0 else {
            let summary = stderrSummary(from: stderrLines)
            appendLog(level: .error, message: "BlackHole install attempt \(attempt) failed with exit code \(exitCode)")
            throw BlackHoleInstallerError.commandFailed(exitCode: exitCode, stderrSummary: summary)
        }

        guard await catalog.hasBlackHole2ch() else {
            appendLog(level: .error, message: "BlackHole install attempt \(attempt) failed: BlackHole 2ch device missing after install")
            throw BlackHoleInstallerError.deviceMissingAfterInstall
        }

        appendLog(level: .info, message: "BlackHole install attempt \(attempt) completed: BlackHole 2ch installed and verified")
    }

    public func recentLogLines() async -> [SetupLogLine] {
        logBuffer.snapshot()
    }

    @discardableResult
    private func appendLog(level: SetupLogLevel, message: String) -> String {
        let bounded = boundedLine(redactor.redact(message))
        logBuffer.append(SetupLogLine(level: level, message: bounded))
        return bounded
    }

    private func stderrSummary(from lines: [String]) -> String {
        let summary = lines.joined(separator: "\n")
        guard !summary.isEmpty else {
            return "No stderr output"
        }
        return boundedLine(summary)
    }

    private func boundedRecent(lines: [String], maxBytes: Int) -> [String] {
        var kept = Array(lines.suffix(500))
        while Data(kept.joined(separator: "\n").utf8).count > maxBytes, kept.count > 1 {
            kept.removeFirst()
        }
        if let only = kept.first, Data(only.utf8).count > maxBytes {
            return [boundedLine(only)]
        }
        return kept
    }

    private func boundedLine(_ value: String) -> String {
        value.truncatedToUTF8ByteCount(2 * 1024)
    }
}

private final class BlackHoleInstallerAttemptState: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var nextAttempt = 1

    func begin() throws -> Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !running else {
            throw BlackHoleInstallerError.busy
        }
        running = true
        let attempt = nextAttempt
        nextAttempt += 1
        return attempt
    }

    func end() {
        lock.lock()
        running = false
        lock.unlock()
    }
}

private final class BlackHoleInstallerLogBuffer: @unchecked Sendable {
    private let maxLineBytes: Int
    private let maxLines: Int
    private let lock = NSLock()
    private var lines: [SetupLogLine] = []
    private var continuations: [UUID: AsyncStream<SetupLogLine>.Continuation] = [:]
    private var isFinished = false

    init(maxLineBytes: Int, maxLines: Int) {
        self.maxLineBytes = max(1, maxLineBytes)
        self.maxLines = max(1, maxLines)
    }

    func stream() -> AsyncStream<SetupLogLine> {
        AsyncStream(bufferingPolicy: .bufferingNewest(maxLines)) { continuation in
            let id = UUID()
            let snapshot: [SetupLogLine]
            let finished: Bool
            lock.lock()
            snapshot = lines
            finished = isFinished
            if !isFinished {
                continuations[id] = continuation
            }
            lock.unlock()

            for line in snapshot {
                continuation.yield(line)
            }
            if finished {
                continuation.finish()
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    func append(_ line: SetupLogLine) {
        let boundedLine = SetupLogLine(
            id: line.id,
            date: line.date,
            level: line.level,
            message: line.message.truncatedToUTF8ByteCount(maxLineBytes)
        )
        let targets: [AsyncStream<SetupLogLine>.Continuation]
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        lines.append(boundedLine)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        targets = Array(continuations.values)
        lock.unlock()

        for continuation in targets {
            continuation.yield(boundedLine)
        }
    }

    func snapshot() -> [SetupLogLine] {
        lock.lock()
        let snapshot = lines
        lock.unlock()
        return snapshot
    }

    func finish() {
        let targets: [AsyncStream<SetupLogLine>.Continuation]
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()

        for continuation in targets {
            continuation.finish()
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

private extension String {
    func truncatedToUTF8ByteCount(_ maxBytes: Int) -> String {
        let bytes = Data(utf8)
        guard bytes.count > maxBytes else {
            return self
        }
        var end = index(startIndex, offsetBy: min(count, maxBytes))
        while end > startIndex {
            let candidate = String(self[..<end])
            if Data(candidate.utf8).count <= maxBytes {
                return candidate
            }
            end = index(before: end)
        }
        return ""
    }
}
