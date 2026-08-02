import CodexRemoteCore
import Darwin
import Foundation

public protocol HookEventQueueing: Sendable {
    func enqueue(_ payload: HookPayload, forSocketAt socketURL: URL) async throws
}

public struct HookEventQueueDrainResult: Equatable, Sendable {
    public let consumedCount: Int
    public let retainedCount: Int

    public init(consumedCount: Int, retainedCount: Int) {
        self.consumedCount = consumedCount
        self.retainedCount = retainedCount
    }
}

public enum HookEventQueueError: Error, Equatable, Sendable {
    case openFailed(String, Int32)
    case statFailed(String, Int32)
    case insecureFile(String)
    case ownerMismatch(String, uid_t)
    case insecurePermissions(String, mode_t)
    case lockFailed(String, Int32)
    case readFailed(String, Int32)
    case writeFailed(String, Int32)
    case seekFailed(String, Int32)
    case truncateFailed(String, Int32)
    case syncFailed(String, Int32)
    case invalidQueuedRequest
}

public struct HookEventQueue: HookEventQueueing {
    private static let maximumEvents = 64
    private static let maximumFileBytes = 256 * 1024
    private static let maximumTextCharacters = 1_024

    private let codec = LocalIPCCodec()

    public init() {}

    public static func queueURL(forSocketAt socketURL: URL) -> URL {
        socketURL.deletingLastPathComponent().appendingPathComponent("pending-hooks.jsonl")
    }

    public static func lockURL(forSocketAt socketURL: URL) -> URL {
        socketURL.deletingLastPathComponent().appendingPathComponent("pending-hooks.lock")
    }

    public func enqueue(_ payload: HookPayload, forSocketAt socketURL: URL) async throws {
        try SocketParentPreparer().prepareParentDirectory(for: socketURL)
        try await withLockedQueue(forSocketAt: socketURL) { queueDescriptor in
            var frames = try readFrames(from: queueDescriptor, path: Self.queueURL(forSocketAt: socketURL).path)
            frames.append(try codec.encodeRequest(.hook(normalized(payload))))
            frames = bounded(frames)
            try writeFrames(frames, to: queueDescriptor, path: Self.queueURL(forSocketAt: socketURL).path)
        }
    }

    public func drain(
        forSocketAt socketURL: URL,
        dispatcher: SessionIPCDispatcher
    ) async throws -> HookEventQueueDrainResult {
        try await drain(forSocketAt: socketURL) { payload in
            await dispatcher.handle(.hook(payload))
        }
    }

    public func drain(
        forSocketAt socketURL: URL,
        handler: @escaping @Sendable (HookPayload) async -> LocalIPCResponse
    ) async throws -> HookEventQueueDrainResult {
        try SocketParentPreparer().prepareParentDirectory(for: socketURL)
        return try await withLockedQueue(forSocketAt: socketURL) { queueDescriptor in
            let frames = try readFrames(from: queueDescriptor, path: Self.queueURL(forSocketAt: socketURL).path)
            var consumedCount = 0

            for frame in frames {
                guard case .hook(let payload) = try codec.decodeRequest(frame) else {
                    throw HookEventQueueError.invalidQueuedRequest
                }
                let response = await handler(payload)
                guard response == .ok else {
                    break
                }
                consumedCount += 1
            }

            let retainedFrames = Array(frames.dropFirst(consumedCount))
            try writeFrames(retainedFrames, to: queueDescriptor, path: Self.queueURL(forSocketAt: socketURL).path)
            return HookEventQueueDrainResult(consumedCount: consumedCount, retainedCount: retainedFrames.count)
        }
    }

    private func normalized(_ payload: HookPayload) -> HookPayload {
        HookPayload(
            hookEventName: payload.hookEventName,
            sessionID: payload.sessionID,
            launcherInstanceID: payload.launcherInstanceID,
            message: truncated(payload.message),
            lastAssistantMessage: truncated(payload.lastAssistantMessage)
        )
    }

    private func truncated(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        return String(value.prefix(Self.maximumTextCharacters))
    }

    private func bounded(_ frames: [Data]) -> [Data] {
        var boundedFrames = frames
        while boundedFrames.count > Self.maximumEvents || boundedFrames.reduce(0, { $0 + $1.count }) > Self.maximumFileBytes {
            boundedFrames.removeFirst()
        }
        return boundedFrames
    }

    private func withLockedQueue<T>(
        forSocketAt socketURL: URL,
        _ operation: (Int32) async throws -> T
    ) async throws -> T {
        let lockPath = Self.lockURL(forSocketAt: socketURL).path
        let queuePath = Self.queueURL(forSocketAt: socketURL).path
        let lockDescriptor = try openSecureRegularFile(at: lockPath)
        defer {
            close(lockDescriptor)
        }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw HookEventQueueError.lockFailed(lockPath, errno)
        }
        defer {
            flock(lockDescriptor, LOCK_UN)
        }

        let queueDescriptor = try openSecureRegularFile(at: queuePath)
        defer {
            close(queueDescriptor)
        }
        return try await operation(queueDescriptor)
    }

    private func openSecureRegularFile(at path: String) throws -> Int32 {
        var existed = false
        var existingStatus = stat()
        let existingResult = path.withCString { lstat($0, &existingStatus) }
        if existingResult == 0 {
            existed = true
            guard existingStatus.st_mode & S_IFMT == S_IFREG else {
                throw HookEventQueueError.insecureFile(path)
            }
        } else if errno != ENOENT {
            throw HookEventQueueError.statFailed(path, errno)
        }

        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw HookEventQueueError.openFailed(path, errno)
        }

        do {
            try validateSecureRegularFile(descriptor: descriptor, path: path)
            if !existed {
                guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                    throw HookEventQueueError.insecurePermissions(path, 0)
                }
            }
            try validateSecureRegularFile(descriptor: descriptor, path: path)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func validateSecureRegularFile(descriptor: Int32, path: String) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw HookEventQueueError.statFailed(path, errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw HookEventQueueError.insecureFile(path)
        }
        guard status.st_uid == geteuid() else {
            throw HookEventQueueError.ownerMismatch(path, status.st_uid)
        }
        let permissions = status.st_mode & mode_t(0o777)
        guard permissions == 0o600 else {
            throw HookEventQueueError.insecurePermissions(path, permissions)
        }
    }

    private func readFrames(from descriptor: Int32, path: String) throws -> [Data] {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw HookEventQueueError.seekFailed(path, errno)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                guard data.count <= Self.maximumFileBytes else {
                    throw LocalIPCCodecError.frameTooLarge(data.count)
                }
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw HookEventQueueError.readFailed(path, errno)
        }

        guard !data.isEmpty else {
            return []
        }
        guard data.last == UInt8(ascii: "\n") else {
            throw LocalIPCCodecError.missingNewline
        }
        return try data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { line in
            let frame = Data(line) + Data([UInt8(ascii: "\n")])
            guard frame.count <= LocalIPCCodec.maximumFrameBytes else {
                throw LocalIPCCodecError.frameTooLarge(frame.count)
            }
            return frame
        }
    }

    private func writeFrames(_ frames: [Data], to descriptor: Int32, path: String) throws {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw HookEventQueueError.seekFailed(path, errno)
        }
        guard ftruncate(descriptor, 0) == 0 else {
            throw HookEventQueueError.truncateFailed(path, errno)
        }

        for frame in frames {
            try writeAll(frame, to: descriptor, path: path)
        }
        guard fsync(descriptor) == 0 else {
            throw HookEventQueueError.syncFailed(path, errno)
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var written = 0
            while written < data.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: written), data.count - written)
                if count > 0 {
                    written += count
                    continue
                }
                if errno == EINTR {
                    continue
                }
                throw HookEventQueueError.writeFailed(path, errno)
            }
        }
    }
}
