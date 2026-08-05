import Darwin
import Foundation

public enum ApplicationInstallResult: Equatable, Sendable {
    case installedAndRequiresRelaunch(URL)
}

public enum ApplicationInstallError: Error, Equatable, Sendable {
    case invalidSource
    case invalidDestination
    case unsafePath
    case permissionDenied
    case copyFailed
    case verificationFailed
    case replacementFailed
    case rollbackFailed
}

public enum ApplicationInstallerFileKind: Equatable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

public protocol ApplicationInstallerFileOperations: Sendable {
    func itemKindNoFollow(at url: URL) throws -> ApplicationInstallerFileKind?
    func isExecutableFile(at url: URL) -> Bool
    func isReadableFile(at url: URL) -> Bool
    func createUniqueDirectory(in parentURL: URL, prefix: String) throws -> URL
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func replaceItem(at destinationURL: URL, with sourceURL: URL) throws
    func removeItem(at url: URL) throws
    func directoryContentsEqual(_ lhs: URL, _ rhs: URL) throws -> Bool
}

public struct ApplicationInstaller: Sendable {
    private let fileOperations: any ApplicationInstallerFileOperations

    public init(fileOperations: any ApplicationInstallerFileOperations = LocalApplicationInstallerFileOperations()) {
        self.fileOperations = fileOperations
    }

    @discardableResult
    public func install(
        sourceApplicationURL: URL,
        destinationApplicationURL: URL
    ) throws -> ApplicationInstallResult {
        try validateOriginalDestinationPath(destinationApplicationURL)
        let source = sourceApplicationURL.standardizedFileURL
        let destination = destinationApplicationURL.standardizedFileURL
        guard source.path != destination.path else {
            throw ApplicationInstallError.invalidDestination
        }
        try validateSource(at: source)
        try validateDestinationPath(destination)

        if (try? fileOperations.directoryContentsEqual(source, destination)) == true {
            return .installedAndRequiresRelaunch(destination)
        }

        let parent = destination.deletingLastPathComponent()
        let stagingContainer: URL
        do {
            stagingContainer = try fileOperations.createUniqueDirectory(in: parent, prefix: ".codex-remote-install-")
        } catch {
            throw mapPermission(error) ?? .invalidDestination
        }
        let staging = stagingContainer.appendingPathComponent(destination.lastPathComponent, isDirectory: true)

        do {
            try fileOperations.copyItem(at: source, to: staging)
        } catch {
            try? fileOperations.removeItem(at: stagingContainer)
            throw mapPermission(error) ?? .copyFailed
        }

        do {
            try validateSource(at: staging)
        } catch {
            try? fileOperations.removeItem(at: stagingContainer)
            throw ApplicationInstallError.verificationFailed
        }

        do {
            try replaceDestination(destination, with: staging)
            try? fileOperations.removeItem(at: stagingContainer)
        } catch let installError as ApplicationInstallError {
            try? fileOperations.removeItem(at: stagingContainer)
            throw installError
        } catch {
            try? fileOperations.removeItem(at: stagingContainer)
            throw mapPermission(error) ?? .replacementFailed
        }

        return .installedAndRequiresRelaunch(destination)
    }

    private func validateSource(at url: URL) throws {
        guard try fileOperations.itemKindNoFollow(at: url) == .directory else {
            throw ApplicationInstallError.invalidSource
        }
        for relativePath in [
            "Contents/MacOS/codex-remote-app",
            "Contents/MacOS/codex-remote-helper",
            "Contents/Resources/codex",
            "Contents/Resources/codex-remote-hook",
        ] {
            let executable = url.appendingPathComponent(relativePath)
            guard try fileOperations.itemKindNoFollow(at: executable) == .regularFile,
                  fileOperations.isExecutableFile(at: executable)
            else {
                throw ApplicationInstallError.invalidSource
            }
        }
        let hooks = url.appendingPathComponent("Contents/Resources/codex-remote-hooks.json")
        guard try fileOperations.itemKindNoFollow(at: hooks) == .regularFile,
              fileOperations.isReadableFile(at: hooks)
        else {
            throw ApplicationInstallError.invalidSource
        }
    }

    private func validateDestinationPath(_ destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        guard try fileOperations.itemKindNoFollow(at: parent) == .directory else {
            throw ApplicationInstallError.invalidDestination
        }
    }

    private func validateOriginalDestinationPath(_ destination: URL) throws {
        guard destination.isFileURL,
              destination.baseURL == nil,
              destination.path.hasPrefix("/")
        else {
            throw ApplicationInstallError.unsafePath
        }
        guard destination.path == destination.standardizedFileURL.path else {
            throw ApplicationInstallError.unsafePath
        }
    }

    private func replaceDestination(_ destination: URL, with staging: URL) throws {
        let destinationExists = try fileOperations.itemKindNoFollow(at: destination) != nil
        if !destinationExists {
            do {
                try fileOperations.moveItem(at: staging, to: destination)
            } catch {
                throw mapPermission(error) ?? .replacementFailed
            }
            return
        }

        let backup: URL
        do {
            backup = try prepareValidatedBackup(for: destination)
        } catch let installError as ApplicationInstallError {
            throw installError
        } catch {
            throw mapPermission(error) ?? .replacementFailed
        }

        do {
            try fileOperations.replaceItem(at: destination, with: staging)
        } catch {
            try restoreBackupIfNeeded(backup, to: destination)
            throw mapPermission(error) ?? .replacementFailed
        }

        do {
            try validateSource(at: destination)
        } catch {
            try restoreBackupIfNeeded(backup, to: destination)
            throw ApplicationInstallError.replacementFailed
        }
    }

    private func prepareValidatedBackup(for destination: URL) throws -> URL {
        let finalBackup = uniqueBackupURL(for: destination)
        let backupStaging = uniqueBackupStagingURL(for: destination)
        do {
            try fileOperations.copyItem(at: destination, to: backupStaging)
            try validateSource(at: backupStaging)
            guard try fileOperations.directoryContentsEqual(destination, backupStaging) else {
                throw ApplicationInstallError.verificationFailed
            }
            try fileOperations.moveItem(at: backupStaging, to: finalBackup)
            try validateSource(at: finalBackup)
            guard try fileOperations.directoryContentsEqual(destination, finalBackup) else {
                throw ApplicationInstallError.verificationFailed
            }
            return finalBackup
        } catch let installError as ApplicationInstallError {
            try? fileOperations.removeItem(at: backupStaging)
            try? fileOperations.removeItem(at: finalBackup)
            throw installError
        } catch {
            try? fileOperations.removeItem(at: backupStaging)
            try? fileOperations.removeItem(at: finalBackup)
            throw error
        }
    }

    private func restoreBackupIfNeeded(_ backup: URL, to destination: URL) throws {
        guard try fileOperations.itemKindNoFollow(at: backup) != nil else {
            return
        }
        do {
            if try fileOperations.itemKindNoFollow(at: destination) != nil {
                try fileOperations.removeItem(at: destination)
            }
            try fileOperations.moveItem(at: backup, to: destination)
        } catch {
            throw ApplicationInstallError.rollbackFailed
        }
    }

    private func uniqueBackupURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent("\(destination.lastPathComponent).backup-\(timestamp())-\(UUID().uuidString)")
    }

    private func uniqueBackupStagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent("\(destination.lastPathComponent).backup-staging-\(timestamp())-\(UUID().uuidString)")
    }

    private func mapPermission(_ error: any Error) -> ApplicationInstallError? {
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileReadNoPermission, .fileWriteNoPermission:
                return .permissionDenied
            default:
                break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return .permissionDenied
        }
        return nil
    }
}

open class LocalApplicationInstallerFileOperations: ApplicationInstallerFileOperations, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    open func itemKindNoFollow(at url: URL) throws -> ApplicationInstallerFileKind? {
        try fileKindNoFollow(at: url)
    }

    open func isExecutableFile(at url: URL) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }

    open func isReadableFile(at url: URL) -> Bool {
        fileManager.isReadableFile(atPath: url.path)
    }

    open func createUniqueDirectory(in parentURL: URL, prefix: String) throws -> URL {
        for _ in 0..<20 {
            let candidate = parentURL.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
            do {
                try fileManager.createDirectory(
                    at: candidate,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    open func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    open func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    open func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        _ = try fileManager.replaceItemAt(
            destinationURL,
            withItemAt: sourceURL,
            backupItemName: nil,
            options: []
        )
    }

    open func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    open func directoryContentsEqual(_ lhs: URL, _ rhs: URL) throws -> Bool {
        guard try itemKindNoFollow(at: lhs) == .directory,
              try itemKindNoFollow(at: rhs) == .directory
        else {
            return false
        }
        guard let lhsEntries = try entryMap(under: lhs),
              let rhsEntries = try entryMap(under: rhs),
              lhsEntries.keys == rhsEntries.keys
        else {
            return false
        }
        for key in lhsEntries.keys {
            guard lhsEntries[key] == rhsEntries[key] else {
                return false
            }
        }
        return true
    }

    private func entryMap(under root: URL) throws -> [String: ComparableEntry]? {
        let rootPath = try canonicalExistingPath(for: root)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return [:]
        }
        var entries: [String: ComparableEntry] = [:]
        for case let url as URL in enumerator {
            let kind = try itemKindNoFollow(at: url)
            let path = try canonicalComparablePath(for: url, kind: kind)
            guard path.hasPrefix(rootPath + "/") else {
                return nil
            }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            switch kind {
            case .regularFile:
                entries[relativePath] = .regularFile(try Data(contentsOf: url), executableMode(url))
            case .directory:
                entries[relativePath] = .directory
            case .symbolicLink:
                entries[relativePath] = .symbolicLink(try fileManager.destinationOfSymbolicLink(atPath: url.path))
            case .other, nil:
                return nil
            }
        }
        return entries
    }

    private func canonicalComparablePath(for url: URL, kind: ApplicationInstallerFileKind?) throws -> String {
        if kind == .symbolicLink {
            let parentPath = try canonicalExistingPath(for: url.deletingLastPathComponent())
            return parentPath + "/" + url.lastPathComponent
        }
        return try canonicalExistingPath(for: url)
    }

    private func canonicalExistingPath(for url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private enum ComparableEntry: Equatable {
        case regularFile(Data, Bool)
        case directory
        case symbolicLink(String)
    }

    private func executableMode(_ url: URL) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }
}

private func fileKindNoFollow(at url: URL) throws -> ApplicationInstallerFileKind? {
    var info = stat()
    let result = url.path.withCString { path in
        lstat(path, &info)
    }
    if result != 0 {
        if errno == ENOENT {
            return nil
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let mode = info.st_mode & S_IFMT
    if mode == S_IFREG {
        return .regularFile
    }
    if mode == S_IFDIR {
        return .directory
    }
    if mode == S_IFLNK {
        return .symbolicLink
    }
    return .other
}

private func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMddHHmmss"
    return formatter.string(from: Date())
}
