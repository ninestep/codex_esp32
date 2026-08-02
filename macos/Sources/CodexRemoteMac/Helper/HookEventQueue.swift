import CodexRemoteCore
import Darwin
import Foundation

public protocol HookEventQueueing: Sendable {
    func enqueue(_ event: PendingLocalEvent, forSocketAt socketURL: URL) async throws
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

public enum PendingLocalEvent: Equatable, Sendable {
    case launchSnapshot(LaunchRegistration)
    case hook(HookPayload)
}

extension PendingLocalEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case payload
    }

    private enum EventType: String, Codable {
        case launchSnapshot
        case hook
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "unsupported version")
        }

        switch try container.decode(EventType.self, forKey: .type) {
        case .launchSnapshot:
            self = .launchSnapshot(try container.decode(LaunchRegistration.self, forKey: .payload))
        case .hook:
            self = .hook(try container.decode(HookPayload.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)

        switch self {
        case .launchSnapshot(let snapshot):
            try container.encode(EventType.launchSnapshot, forKey: .type)
            try container.encode(snapshot, forKey: .payload)
        case .hook(let payload):
            try container.encode(EventType.hook, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }
}

public struct PendingLocalEventCodec: Sendable {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {}

    public func encode(_ event: PendingLocalEvent) throws -> Data {
        var data = try encoder.encode(event)
        data.append(UInt8(ascii: "\n"))
        try validateFrameSize(data.count)
        return data
    }

    public func decode(_ data: Data) throws -> PendingLocalEvent {
        try validateFrameSize(data.count)
        guard data.last == UInt8(ascii: "\n") else {
            throw LocalIPCCodecError.missingNewline
        }
        return try decoder.decode(PendingLocalEvent.self, from: data.dropLast())
    }

    private func validateFrameSize(_ size: Int) throws {
        guard size <= LocalIPCCodec.maximumFrameBytes else {
            throw LocalIPCCodecError.frameTooLarge(size)
        }
    }
}

public struct HookEventQueue: HookEventQueueing {
    private static let maximumEvents = 64
    private static let maximumFileBytes = 256 * 1024
    private static let maximumTextCharacters = 1_024

    private let codec = PendingLocalEventCodec()
    private let beforeRename: @Sendable (URL, URL) throws -> Void

    public init(beforeRename: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in }) {
        self.beforeRename = beforeRename
    }

    public static func queueURL(forSocketAt socketURL: URL) -> URL {
        socketURL.deletingLastPathComponent().appendingPathComponent("pending-hooks.jsonl")
    }

    public static func lockURL(forSocketAt socketURL: URL) -> URL {
        socketURL.deletingLastPathComponent().appendingPathComponent("pending-hooks.lock")
    }

    public func enqueue(_ event: PendingLocalEvent, forSocketAt socketURL: URL) async throws {
        try SocketParentPreparer().prepareParentDirectory(for: socketURL)
        try await withLockedQueue(forSocketAt: socketURL) { frames in
            var frames = frames
            frames.append(try codec.encode(normalized(event)))
            frames = bounded(frames)
            return ((), frames)
        }
    }

    public func drain(
        forSocketAt socketURL: URL,
        dispatcher: SessionIPCDispatcher
    ) async throws -> HookEventQueueDrainResult {
        try await drain(forSocketAt: socketURL) { payload in
            await dispatcher.handlePending(payload)
        }
    }

    public func drain(
        forSocketAt socketURL: URL,
        handler: @escaping @Sendable (PendingLocalEvent) async -> LocalIPCResponse
    ) async throws -> HookEventQueueDrainResult {
        try SocketParentPreparer().prepareParentDirectory(for: socketURL)
        return try await withLockedQueue(forSocketAt: socketURL) { frames in
            var consumedCount = 0

            for frame in frames {
                let event = try codec.decode(frame)
                let response = await handler(event)
                guard response == .ok else {
                    break
                }
                consumedCount += 1
            }

            let retainedFrames = Array(frames.dropFirst(consumedCount))
            let rewriteFrames = consumedCount > 0 ? retainedFrames : nil
            return (HookEventQueueDrainResult(consumedCount: consumedCount, retainedCount: retainedFrames.count), rewriteFrames)
        }
    }

    private func normalized(_ event: PendingLocalEvent) -> PendingLocalEvent {
        switch event {
        case .launchSnapshot:
            event
        case .hook(let payload):
            .hook(
                HookPayload(
                    hookEventName: payload.hookEventName,
                    sessionID: payload.sessionID,
                    launcherInstanceID: payload.launcherInstanceID,
                    message: truncated(payload.message),
                    lastAssistantMessage: truncated(payload.lastAssistantMessage)
                )
            )
        }
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
        _ operation: ([Data]) async throws -> (T, [Data]?)
    ) async throws -> T {
        let lockPath = Self.lockURL(forSocketAt: socketURL).path
        let queuePath = Self.queueURL(forSocketAt: socketURL).path
        let queueURL = Self.queueURL(forSocketAt: socketURL)
        let lockDescriptor = try openOrCreateSecureRegularFile(at: lockPath)
        defer {
            close(lockDescriptor)
        }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw HookEventQueueError.lockFailed(lockPath, errno)
        }
        defer {
            flock(lockDescriptor, LOCK_UN)
        }

        let frames = try readFrames(at: queuePath)
        let (result, updatedFrames) = try await operation(frames)
        if let updatedFrames {
            try atomicRewrite(updatedFrames, to: queueURL)
        }
        return result
    }

    private func openOrCreateSecureRegularFile(at path: String) throws -> Int32 {
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

    private func openExistingSecureRegularFile(at path: String) throws -> Int32? {
        var existingStatus = stat()
        let existingResult = path.withCString { lstat($0, &existingStatus) }
        if existingResult != 0 {
            guard errno == ENOENT else {
                throw HookEventQueueError.statFailed(path, errno)
            }
            return nil
        }
        try validateSecureStatus(existingStatus, path: path)

        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw HookEventQueueError.openFailed(path, errno)
        }
        do {
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

    private func validateSecureStatus(_ status: stat, path: String) throws {
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

    private func validateQueuePathIfPresent(_ path: String) throws {
        var status = stat()
        let result = path.withCString { lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT else {
                throw HookEventQueueError.statFailed(path, errno)
            }
            return
        }
        try validateSecureStatus(status, path: path)
    }

    private func readFrames(at path: String) throws -> [Data] {
        guard let descriptor = try openExistingSecureRegularFile(at: path) else {
            return []
        }
        defer {
            close(descriptor)
        }
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
            _ = try codec.decode(frame)
            return frame
        }
    }

    private func atomicRewrite(_ frames: [Data], to queueURL: URL) throws {
        let queuePath = queueURL.path
        let parentURL = queueURL.deletingLastPathComponent()
        try validateQueuePathIfPresent(queuePath)

        let tempURL = parentURL.appendingPathComponent(".pending-hooks.\(UUID().uuidString).tmp")
        let tempPath = tempURL.path
        let tempDescriptor = Darwin.open(tempPath, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard tempDescriptor >= 0 else {
            throw HookEventQueueError.openFailed(tempPath, errno)
        }
        var renamed = false
        defer {
            close(tempDescriptor)
            if !renamed {
                unlink(tempPath)
            }
        }

        guard fchmod(tempDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw HookEventQueueError.insecurePermissions(tempPath, 0)
        }
        try validateSecureRegularFile(descriptor: tempDescriptor, path: tempPath)
        for frame in frames {
            try writeAll(frame, to: tempDescriptor, path: tempPath)
        }
        guard fsync(tempDescriptor) == 0 else {
            throw HookEventQueueError.syncFailed(tempPath, errno)
        }

        try beforeRename(tempURL, queueURL)
        guard rename(tempPath, queuePath) == 0 else {
            throw HookEventQueueError.writeFailed(queuePath, errno)
        }
        renamed = true
        try fsyncDirectory(parentURL)
    }

    private func fsyncDirectory(_ directoryURL: URL) throws {
        let directoryPath = directoryURL.path
        let descriptor = Darwin.open(directoryPath, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw HookEventQueueError.openFailed(directoryPath, errno)
        }
        defer {
            close(descriptor)
        }
        guard fsync(descriptor) == 0 else {
            throw HookEventQueueError.syncFailed(directoryPath, errno)
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
