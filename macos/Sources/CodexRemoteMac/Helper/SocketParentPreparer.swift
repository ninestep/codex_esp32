import Darwin
import Foundation

public enum SocketParentPreparationError: Error, Equatable, Sendable {
    case notDirectory(String)
    case ownerMismatch(String, uid_t)
    case insecurePermissions(String, mode_t)
    case statFailed(String, Int32)
}

public struct SocketParentPreparer: Sendable {
    public init() {}

    public func prepareParentDirectory(for socketURL: URL) throws {
        let parentURL = socketURL.deletingLastPathComponent()
        let parentPath = parentURL.path

        if !FileManager.default.fileExists(atPath: parentPath) {
            try FileManager.default.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let status = try lstatStatus(at: parentPath)
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw SocketParentPreparationError.notDirectory(parentPath)
        }
        guard status.st_uid == geteuid() else {
            throw SocketParentPreparationError.ownerMismatch(parentPath, status.st_uid)
        }

        let permissions = status.st_mode & mode_t(0o777)
        guard permissions == 0o700 else {
            throw SocketParentPreparationError.insecurePermissions(parentPath, permissions)
        }
    }

    private func lstatStatus(at path: String) throws -> stat {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else {
            throw SocketParentPreparationError.statFailed(path, errno)
        }
        return status
    }
}
