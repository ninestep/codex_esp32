import Darwin
import Foundation

public struct HookTrustEvidence: Codable, Equatable, Sendable {
    public let acceptedAt: Date
    public let eventName: String

    public init(acceptedAt: Date, eventName: String) {
        self.acceptedAt = acceptedAt
        self.eventName = eventName
    }
}

public protocol HookTrustEvidenceReading: Sendable {
    func latestEvidence() -> HookTrustEvidence?
}

public enum HookTrustEvidenceStoreError: Error, Equatable, Sendable {
    case invalidTarget
    case writeFailed
}

public struct HookTrustEvidenceStore: HookTrustEvidenceReading, Sendable {
    public static let fileName = "codex-remote-hook-trust.json"

    private let evidenceURL: URL
    private let clock: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        evidenceURL: URL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.evidenceURL = evidenceURL.standardizedFileURL
        self.clock = clock
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultEvidenceURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .standardizedFileURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func evidenceURL(fromTrustTarget targetURL: URL) -> URL {
        let standardized = targetURL.standardizedFileURL
        if standardized.pathExtension == "json" {
            return standardized
        }
        return standardized.appendingPathComponent(fileName)
    }

    public func latestEvidence() -> HookTrustEvidence? {
        let status: stat?
        do {
            try validateTrustedParentDirectory()
            status = try trustEvidenceStatusNoFollow(at: evidenceURL)
        } catch {
            return nil
        }
        guard let status,
              isTrustedEvidenceFileStatus(status),
              let data = try? Data(contentsOf: evidenceURL)
        else {
            return nil
        }
        return try? decoder.decode(HookTrustEvidence.self, from: data)
    }

    public func recordAcceptedHook(eventName: String) throws {
        try ensureParentDirectory()
        switch try trustEvidenceStatusNoFollow(at: evidenceURL) {
        case .some(let status):
            guard isTrustedEvidenceFileStatus(status) else {
                throw HookTrustEvidenceStoreError.invalidTarget
            }
        case nil:
            break
        }

        let evidence = HookTrustEvidence(acceptedAt: clock(), eventName: eventName)
        let data = try encoder.encode(evidence)
        try writeAtomically(data)
    }

    private func ensureParentDirectory() throws {
        let parent = evidenceURL.deletingLastPathComponent()
        switch try trustEvidenceStatusNoFollow(at: parent) {
        case .some(let status):
            guard isTrustedDirectoryStatus(status) else {
                throw HookTrustEvidenceStoreError.invalidTarget
            }
        case nil:
            do {
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
                try validateTrustedParentDirectory()
            } catch {
                throw HookTrustEvidenceStoreError.writeFailed
            }
        }
    }

    private func validateTrustedParentDirectory() throws {
        guard let status = try trustEvidenceStatusNoFollow(at: evidenceURL.deletingLastPathComponent()),
              isTrustedDirectoryStatus(status)
        else {
            throw HookTrustEvidenceStoreError.invalidTarget
        }
    }

    private func writeAtomically(_ data: Data) throws {
        let parent = evidenceURL.deletingLastPathComponent()
        let temporaryURL = try createTemporaryFile(in: parent, data: data)
        do {
            try validateTrustedParentDirectory()
            switch try trustEvidenceStatusNoFollow(at: evidenceURL) {
            case .some(let status):
                guard isTrustedEvidenceFileStatus(status) else {
                    throw HookTrustEvidenceStoreError.invalidTarget
                }
            case nil:
                break
            }
            guard Darwin.rename(temporaryURL.path, evidenceURL.path) == 0 else {
                throw HookTrustEvidenceStoreError.writeFailed
            }
            try fsyncDirectory(parent)
        } catch let error as HookTrustEvidenceStoreError {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw HookTrustEvidenceStoreError.writeFailed
        }
    }

    private func createTemporaryFile(in parent: URL, data: Data) throws -> URL {
        for _ in 0..<20 {
            let temporaryURL = parent.appendingPathComponent(".codex-remote-hook-trust-\(UUID().uuidString).tmp")
            let descriptor = Darwin.open(
                temporaryURL.path,
                O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            if descriptor < 0 {
                if errno == EEXIST {
                    continue
                }
                throw HookTrustEvidenceStoreError.writeFailed
            }
            do {
                try data.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress else {
                        return
                    }
                    var written = 0
                    while written < data.count {
                        let result = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
                        guard result >= 0 else {
                            throw HookTrustEvidenceStoreError.writeFailed
                        }
                        written += result
                    }
                }
                guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                      Darwin.fsync(descriptor) == 0
                else {
                    throw HookTrustEvidenceStoreError.writeFailed
                }
                Darwin.close(descriptor)
                return temporaryURL
            } catch {
                Darwin.close(descriptor)
                try? FileManager.default.removeItem(at: temporaryURL)
                throw HookTrustEvidenceStoreError.writeFailed
            }
        }
        throw HookTrustEvidenceStoreError.writeFailed
    }

    private func fsyncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw HookTrustEvidenceStoreError.writeFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw HookTrustEvidenceStoreError.writeFailed
        }
    }
}

private func isTrustedDirectoryStatus(_ status: stat) -> Bool {
    status.st_mode & S_IFMT == S_IFDIR
        && status.st_uid == Darwin.geteuid()
        && status.st_mode & mode_t(0o022) == 0
}

private func isTrustedEvidenceFileStatus(_ status: stat) -> Bool {
    status.st_mode & S_IFMT == S_IFREG
        && status.st_uid == Darwin.geteuid()
        && status.st_mode & mode_t(0o777) == mode_t(0o600)
}

private func trustEvidenceStatusNoFollow(at url: URL) throws -> stat? {
    var status = stat()
    let result = url.path.withCString { path in
        lstat(path, &status)
    }
    if result != 0 {
        if errno == ENOENT {
            return nil
        }
        throw HookTrustEvidenceStoreError.invalidTarget
    }
    return status
}
