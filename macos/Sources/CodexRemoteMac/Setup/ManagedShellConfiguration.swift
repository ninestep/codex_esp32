import Darwin
import Foundation

public enum ManagedShellConfigurationResult: Equatable, Sendable {
    case installed
}

public enum ManagedShellConfigurationRestoreResult: Equatable, Sendable {
    case restored
}

public enum ManagedShellConfigurationError: Error, Equatable, Sendable {
    case invalidProfile
    case invalidManagedBinDirectory
    case invalidManagedBlock
    case unsafePath
    case conflict
    case writeFailed
    case verificationFailed
    case rollbackFailed
}

public enum ManagedShellFileKind: Equatable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

public protocol ManagedShellFileOperations: Sendable {
    func itemKindNoFollow(at url: URL) throws -> ManagedShellFileKind?
    func readData(at url: URL) throws -> Data
    func createDirectory(at url: URL, mode: mode_t) throws
    func createBackup(of url: URL, data: Data, mode: mode_t) throws -> URL
    func createTemporaryFile(in parentURL: URL, prefix: String, data: Data, mode: mode_t) throws -> URL
    func replaceFile(at url: URL, withPreparedTemporaryFile temporaryURL: URL) throws
    func createSymbolicLink(at url: URL, withDestinationURL destination: URL) throws
    func destinationOfSymbolicLink(at url: URL) throws -> String
    func removeItem(at url: URL) throws
    func posixMode(at url: URL) throws -> mode_t
    func ownerUserID(at url: URL) throws -> uid_t
}

public struct ManagedShellConfiguration: Sendable {
    public static let startMarker = "# >>> Codex Remote >>>"
    public static let endMarker = "# <<< Codex Remote <<<"
    public static let pathLine = #"export PATH="$HOME/.codex-remote/bin:$PATH""#
    public static let managedBlock = "\(startMarker)\n\(pathLine)\n\(endMarker)"

    private let profileURL: URL
    private let managedBinDirectoryURL: URL
    private let shimURL: URL
    private let fileOperations: any ManagedShellFileOperations

    public init(
        profileURL: URL,
        managedBinDirectoryURL: URL,
        shimURL: URL,
        fileOperations: any ManagedShellFileOperations = LocalManagedShellFileOperations()
    ) {
        self.profileURL = profileURL.standardizedFileURL
        self.managedBinDirectoryURL = managedBinDirectoryURL.standardizedFileURL
        self.shimURL = shimURL.standardizedFileURL
        self.fileOperations = fileOperations
    }

    @discardableResult
    public func install(appURL: URL) throws -> ManagedShellConfigurationResult {
        let target = codexResourceURL(for: appURL)
        let original = try readProfileForMutation()
        let desiredText = try Self.installingManagedBlock(in: original.text)
        let profileNeedsWrite = desiredText != original.text
        try ensureManagedBinDirectory()
        try validateShimCanBeManaged(targetURL: target)

        if profileNeedsWrite {
            do {
                if original.exists {
                    _ = try fileOperations.createBackup(of: profileURL, data: original.data, mode: original.mode)
                }
                try writeProfile(Data(desiredText.utf8), mode: original.mode)
                try verifyProfileContainsManagedBlock()
            } catch {
                throw (error as? ManagedShellConfigurationError) ?? .writeFailed
            }
        }

        do {
            _ = try ensureShim(targetURL: target)
        } catch {
            if profileNeedsWrite {
                do {
                    try restoreProfile(original)
                } catch {
                    throw ManagedShellConfigurationError.rollbackFailed
                }
            }
            throw (error as? ManagedShellConfigurationError) ?? .writeFailed
        }
        return .installed
    }

    @discardableResult
    public func restore(appURL: URL) throws -> ManagedShellConfigurationRestoreResult {
        let target = codexResourceURL(for: appURL)
        try validateShimCanBeRestoredOrAbsent(targetURL: target)
        let original = try readProfileForMutation()
        let restoredText = try Self.removingManagedBlock(from: original.text)
        if restoredText != original.text {
            do {
                if original.exists {
                    _ = try fileOperations.createBackup(of: profileURL, data: original.data, mode: original.mode)
                }
                try writeProfile(Data(restoredText.utf8), mode: original.mode)
            } catch {
                throw (error as? ManagedShellConfigurationError) ?? .writeFailed
            }
        }

        switch try shimOwnership(targetURL: target) {
        case .missing:
            break
        case .ownedSymlink:
            do {
                try fileOperations.removeItem(at: shimURL)
            } catch {
                try rollbackProfileOrThrow(original)
                throw ManagedShellConfigurationError.writeFailed
            }
        case .foreignSymlink, .unexpected:
            if restoredText != original.text {
                try rollbackProfileOrThrow(original)
            }
            throw ManagedShellConfigurationError.conflict
        }

        return .restored
    }

    public static func isShellPathConfigured(_ content: String) -> Bool {
        (try? managedBlockRange(in: content)) != nil
    }

    public static func installingManagedBlock(in content: String) throws -> String {
        try validateManagedMarkers(in: content)
        let withoutExisting = try removingManagedBlock(from: content)
        if withoutExisting.isEmpty {
            return managedBlock + "\n"
        }
        return withoutExisting.trimmingCharacters(in: .newlines) + "\n" + managedBlock + "\n"
    }

    public static func removingManagedBlock(from content: String) throws -> String {
        try validateManagedMarkers(in: content)
        guard let range = try? managedBlockRange(in: content) else {
            return content
        }
        var result = content
        let suffixStartsWithNewline = range.upperBound < result.endIndex && result[range.upperBound] == "\n"
        let prefixEndsWithNewline = range.lowerBound > result.startIndex && result[result.index(before: range.lowerBound)] == "\n"
        result.removeSubrange(range)
        if prefixEndsWithNewline, suffixStartsWithNewline {
            let index = range.lowerBound
            if index < result.endIndex, result[index] == "\n" {
                result.remove(at: index)
            }
        } else if !prefixEndsWithNewline, suffixStartsWithNewline {
            let index = range.lowerBound
            if index < result.endIndex, result[index] == "\n" {
                result.remove(at: index)
            }
        }
        return result
    }

    private func readProfileForMutation() throws -> ProfileSnapshot {
        switch try fileOperations.itemKindNoFollow(at: profileURL) {
        case nil:
            return ProfileSnapshot(exists: false, data: Data(), text: "", mode: 0o600)
        case .regularFile:
            let mode = try fileOperations.posixMode(at: profileURL)
            let data = try fileOperations.readData(at: profileURL)
            guard try fileOperations.itemKindNoFollow(at: profileURL) == .regularFile,
                  let text = String(data: data, encoding: .utf8)
            else {
                throw ManagedShellConfigurationError.invalidProfile
            }
            try Self.validateManagedMarkers(in: text)
            return ProfileSnapshot(exists: true, data: data, text: text, mode: mode)
        default:
            throw ManagedShellConfigurationError.invalidProfile
        }
    }

    private func ensureManagedBinDirectory() throws {
        try ensurePrivateDirectoryPath(managedBinDirectoryURL)
    }

    private func ensurePrivateDirectoryPath(_ target: URL) throws {
        let ancestors = pathAncestors(to: target)
        guard !ancestors.isEmpty else {
            throw ManagedShellConfigurationError.invalidManagedBinDirectory
        }
        let managedRoot = managedBinDirectoryURL.deletingLastPathComponent().standardizedFileURL

        for index in ancestors.indices {
            let url = ancestors[index]
            switch try fileOperations.itemKindNoFollow(at: url) {
            case .directory:
                if isManagedPrivateDirectory(url, managedRoot: managedRoot) {
                    try validatePrivateManagedDirectory(url)
                }
            case nil:
                try createMissingManagedDirectories(Array(ancestors[index...]), managedRoot: managedRoot)
                return
            default:
                throw ManagedShellConfigurationError.invalidManagedBinDirectory
            }
        }
    }

    private func createMissingManagedDirectories(_ urls: [URL], managedRoot: URL) throws {
        for url in urls {
            do {
                try fileOperations.createDirectory(at: url, mode: 0o700)
            } catch {
                throw ManagedShellConfigurationError.writeFailed
            }
            guard try fileOperations.itemKindNoFollow(at: url) == .directory else {
                throw ManagedShellConfigurationError.invalidManagedBinDirectory
            }
            if isManagedPrivateDirectory(url, managedRoot: managedRoot) {
                try validatePrivateManagedDirectory(url)
            }
        }
    }

    private func isManagedPrivateDirectory(_ url: URL, managedRoot: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = managedRoot.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func validatePrivateManagedDirectory(_ url: URL) throws {
        guard try fileOperations.ownerUserID(at: url) == Darwin.geteuid(),
              try fileOperations.posixMode(at: url) & 0o777 == 0o700
        else {
            throw ManagedShellConfigurationError.invalidManagedBinDirectory
        }
    }

    @discardableResult
    private func ensureShim(targetURL: URL) throws -> Bool {
        let target = targetURL.standardizedFileURL
        switch try fileOperations.itemKindNoFollow(at: shimURL) {
        case nil:
            try fileOperations.createSymbolicLink(at: shimURL, withDestinationURL: target)
            return true
        case .symbolicLink:
            guard try resolvedSymlinkTarget(at: shimURL) == target.path else {
                throw ManagedShellConfigurationError.conflict
            }
            return false
        default:
            throw ManagedShellConfigurationError.conflict
        }
    }

    private func validateShimCanBeManaged(targetURL: URL) throws {
        switch try fileOperations.itemKindNoFollow(at: shimURL) {
        case nil:
            return
        case .symbolicLink:
            guard try resolvedSymlinkTarget(at: shimURL) == targetURL.standardizedFileURL.path else {
                throw ManagedShellConfigurationError.conflict
            }
        default:
            throw ManagedShellConfigurationError.conflict
        }
    }

    private func validateShimCanBeRestoredOrAbsent(targetURL: URL) throws {
        switch try fileOperations.itemKindNoFollow(at: shimURL) {
        case nil:
            return
        case .symbolicLink:
            guard try resolvedSymlinkTarget(at: shimURL) == targetURL.standardizedFileURL.path else {
                throw ManagedShellConfigurationError.conflict
            }
        default:
            throw ManagedShellConfigurationError.conflict
        }
    }

    private func shimOwnership(targetURL: URL) throws -> ShimOwnership {
        switch try fileOperations.itemKindNoFollow(at: shimURL) {
        case nil:
            return .missing
        case .symbolicLink:
            if try resolvedSymlinkTarget(at: shimURL) == targetURL.standardizedFileURL.path {
                return .ownedSymlink
            }
            return .foreignSymlink
        default:
            return .unexpected
        }
    }

    private enum ShimOwnership {
        case missing
        case ownedSymlink
        case foreignSymlink
        case unexpected
    }

    private func writeProfile(_ data: Data, mode: mode_t) throws {
        guard try fileOperations.itemKindNoFollow(at: profileURL) != .symbolicLink else {
            throw ManagedShellConfigurationError.invalidProfile
        }
        let parent = profileURL.deletingLastPathComponent()
        let temporary: URL
        do {
            temporary = try fileOperations.createTemporaryFile(
                in: parent,
                prefix: ".codex-remote-profile-",
                data: data,
                mode: mode
            )
        } catch {
            throw ManagedShellConfigurationError.writeFailed
        }
        do {
            try fileOperations.replaceFile(at: profileURL, withPreparedTemporaryFile: temporary)
        } catch {
            try? fileOperations.removeItem(at: temporary)
            throw ManagedShellConfigurationError.writeFailed
        }
        guard try fileOperations.itemKindNoFollow(at: profileURL) == .regularFile else {
            throw ManagedShellConfigurationError.invalidProfile
        }
    }

    private func verifyProfileContainsManagedBlock() throws {
        let data = try fileOperations.readData(at: profileURL)
        guard let text = String(data: data, encoding: .utf8),
              Self.isShellPathConfigured(text)
        else {
            throw ManagedShellConfigurationError.verificationFailed
        }
    }

    private func restoreProfile(_ snapshot: ProfileSnapshot) throws {
        if snapshot.exists {
            try writeProfile(snapshot.data, mode: snapshot.mode)
        } else {
            try fileOperations.removeItem(at: profileURL)
        }
    }

    private func rollbackProfileOrThrow(_ snapshot: ProfileSnapshot) throws {
        do {
            try restoreProfile(snapshot)
        } catch {
            throw ManagedShellConfigurationError.rollbackFailed
        }
    }

    private func pathAncestors(to url: URL) -> [URL] {
        let safeAncestor = profileURL.deletingLastPathComponent().standardizedFileURL
        let target = url.standardizedFileURL
        guard target.path == safeAncestor.path || target.path.hasPrefix(safeAncestor.path + "/") else {
            return [target]
        }
        let relativePath = String(target.path.dropFirst(safeAncestor.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = relativePath.isEmpty ? [] : relativePath.split(separator: "/").map(String.init)
        var current = safeAncestor
        var urls = [current]
        for component in components {
            current = current.appendingPathComponent(component, isDirectory: true)
            urls.append(current)
        }
        return urls
    }

    private func resolvedSymlinkTarget(at url: URL) throws -> String {
        let destination = try fileOperations.destinationOfSymbolicLink(at: url)
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination).standardizedFileURL.path
        }
        return url.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL.path
    }

    private func codexResourceURL(for appURL: URL) -> URL {
        appURL.standardizedFileURL.appendingPathComponent("Contents/Resources/codex")
    }

    private struct ProfileSnapshot {
        let exists: Bool
        let data: Data
        let text: String
        let mode: mode_t
    }

    private static func managedBlockRange(in content: String) throws -> Range<String.Index>? {
        try validateManagedMarkers(in: content)
        guard let start = content.range(of: startMarker),
              let endMarkerRange = content.range(of: endMarker, range: start.upperBound..<content.endIndex)
        else {
            return nil
        }
        let range = start.lowerBound..<endMarkerRange.upperBound
        return String(content[range]) == managedBlock ? range : nil
    }

    private static func validateManagedMarkers(in content: String) throws {
        let starts = ranges(of: startMarker, in: content)
        let ends = ranges(of: endMarker, in: content)
        guard starts.count == ends.count else {
            throw ManagedShellConfigurationError.invalidManagedBlock
        }
        guard starts.count <= 1 else {
            throw ManagedShellConfigurationError.invalidManagedBlock
        }
        if let start = starts.first, let end = ends.first {
            guard start.lowerBound < end.lowerBound else {
                throw ManagedShellConfigurationError.invalidManagedBlock
            }
            let between = content[start.upperBound..<end.lowerBound]
            guard !between.contains(startMarker), !between.contains(endMarker) else {
                throw ManagedShellConfigurationError.invalidManagedBlock
            }
            let range = start.lowerBound..<end.upperBound
            guard String(content[range]) == managedBlock else {
                throw ManagedShellConfigurationError.invalidManagedBlock
            }
        }
    }

    private static func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            ranges.append(range)
            searchRange = range.upperBound..<haystack.endIndex
        }
        return ranges
    }
}

open class LocalManagedShellFileOperations: ManagedShellFileOperations, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    open func itemKindNoFollow(at url: URL) throws -> ManagedShellFileKind? {
        guard let kind = try fileKindNoFollow(at: url) else {
            return nil
        }
        switch kind {
        case .regularFile:
            return .regularFile
        case .directory:
            return .directory
        case .symbolicLink:
            return .symbolicLink
        case .other:
            return .other
        }
    }

    open func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    open func createDirectory(at url: URL, mode: mode_t) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: mode)]
        )
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    open func createBackup(of url: URL, data: Data, mode: mode_t) throws -> URL {
        let parent = url.deletingLastPathComponent()
        for _ in 0..<20 {
            let candidate = parent.appendingPathComponent(
                "\(url.lastPathComponent).codex-remote-backup-\(timestamp())-\(UUID().uuidString)"
            )
            let descriptor = Darwin.open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, mode)
            if descriptor < 0 {
                if errno == EEXIST {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            do {
                try write(data, toDescriptor: descriptor, mode: mode)
                Darwin.close(descriptor)
                return candidate
            } catch {
                Darwin.close(descriptor)
                try? fileManager.removeItem(at: candidate)
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    open func createTemporaryFile(in parentURL: URL, prefix: String, data: Data, mode: mode_t) throws -> URL {
        for _ in 0..<20 {
            let candidate = parentURL.appendingPathComponent("\(prefix)\(UUID().uuidString).tmp")
            let descriptor = Darwin.open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, mode)
            if descriptor < 0 {
                if errno == EEXIST {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var didClose = false
            do {
                try write(data, toDescriptor: descriptor, mode: mode)
                Darwin.close(descriptor)
                didClose = true
                return candidate
            } catch {
                if !didClose {
                    Darwin.close(descriptor)
                }
                try? fileManager.removeItem(at: candidate)
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    open func replaceFile(at url: URL, withPreparedTemporaryFile temporaryURL: URL) throws {
        let parent = url.deletingLastPathComponent()
        do {
            guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            fsyncDirectory(parent)
        } catch {
            throw error
        }
    }

    open func createSymbolicLink(at url: URL, withDestinationURL destination: URL) throws {
        try fileManager.createSymbolicLink(at: url, withDestinationURL: destination)
    }

    open func destinationOfSymbolicLink(at url: URL) throws -> String {
        try fileManager.destinationOfSymbolicLink(atPath: url.path)
    }

    open func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    open func posixMode(at url: URL) throws -> mode_t {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return mode_t((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0) & 0o777
    }

    open func ownerUserID(at url: URL) throws -> uid_t {
        var info = stat()
        let result = url.path.withCString { path in
            lstat(path, &info)
        }
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return info.st_uid
    }

    private func write(_ data: Data, toDescriptor descriptor: Int32, mode: mode_t) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            var written = 0
            while written < data.count {
                let result = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
                if result < 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += result
            }
        }
        guard Darwin.fchmod(descriptor, mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func fsyncDirectory(_ url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            return
        }
        _ = Darwin.fsync(descriptor)
        Darwin.close(descriptor)
    }
}

private func fileKindNoFollow(at url: URL) throws -> ManagedShellFileKind? {
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
