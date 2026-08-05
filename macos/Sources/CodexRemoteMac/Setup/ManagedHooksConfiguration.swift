import Darwin
import Foundation

public enum ManagedHooksConfigurationError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidCommand
    case invalidTarget
    case writeFailed
    case verificationFailed
}

public enum ManagedHookEvent: String, CaseIterable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case permissionRequest = "PermissionRequest"
    case stop = "Stop"
}

public struct ManagedHooksConfiguration: Sendable {
    public struct Paths: Equatable, Sendable {
        public let hooksURL: URL

        public init(hooksURL: URL) {
            self.hooksURL = hooksURL.standardizedFileURL
        }
    }

    private static let managedEvents = ManagedHookEvent.allCases.map(\.rawValue)

    private let paths: Paths
    private let beforeReplace: @Sendable (URL, URL) throws -> Void

    public init(
        paths: Paths,
        beforeReplace: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in }
    ) {
        self.paths = paths
        self.beforeReplace = beforeReplace
    }

    @discardableResult
    public func install(command: String) throws -> Bool {
        let commandPath = try validateOwnedCommandExecutable(command)
        let snapshot = try readSnapshot()
        var root = try parseRoot(snapshot.data)
        try validateManagedEvents(in: root)

        let originalData = try serialized(root)
        root = try installingManagedHooks(in: root, command: command)
        let desiredData = try serialized(root)
        guard desiredData != originalData || snapshot.exists == false else {
            return false
        }

        if snapshot.exists {
            try createBackup(snapshot: snapshot)
        }
        try writeAtomically(desiredData, expected: snapshot)
        guard ManagedHooksConfigurationValidator.validate(
            configurationURL: paths.hooksURL,
            hookExecutableURL: URL(fileURLWithPath: commandPath)
        ) == .valid else {
            throw ManagedHooksConfigurationError.verificationFailed
        }
        return true
    }

    @discardableResult
    public func restore(command: String) throws -> Bool {
        let snapshot = try readSnapshot()
        guard snapshot.exists else {
            return false
        }
        var root = try parseRoot(snapshot.data)
        try validateManagedEvents(in: root)
        _ = try normalizedOwnedCommandPath(command)
        let originalData = try serialized(root)
        root = try removingManagedHooks(in: root, command: command)
        let desiredData = try serialized(root)
        guard desiredData != originalData else {
            return false
        }

        try createBackup(snapshot: snapshot)
        try writeAtomically(desiredData, expected: snapshot)
        let verified = try parseRoot(try Data(contentsOf: paths.hooksURL))
        guard codexRemoteCommands(in: verified, command: command).isEmpty else {
            throw ManagedHooksConfigurationError.verificationFailed
        }
        return true
    }

    private func readSnapshot() throws -> HooksSnapshot {
        let url = paths.hooksURL
        let parent = url.deletingLastPathComponent()
        try ensureParentDirectory(parent)

        switch try fileStatusNoFollow(at: url) {
        case nil:
            return HooksSnapshot(exists: false, data: Data(#"{"hooks":{}}"#.utf8), mode: 0o600, status: nil)
        case .some(let status):
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw ManagedHooksConfigurationError.invalidTarget
            }
            let data = try Data(contentsOf: url)
            let current = try fileStatusNoFollow(at: url)
            guard let current, sameIdentity(status, current) else {
                throw ManagedHooksConfigurationError.invalidTarget
            }
            return HooksSnapshot(exists: true, data: data, mode: 0o600, status: status)
        }
    }

    private func parseRoot(_ data: Data) throws -> [String: Any] {
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let root = object as? [String: Any] else {
                throw ManagedHooksConfigurationError.invalidConfiguration
            }
            if root["hooks"] == nil {
                var root = root
                root["hooks"] = [String: Any]()
                return root
            }
            guard root["hooks"] is [String: Any] else {
                throw ManagedHooksConfigurationError.invalidConfiguration
            }
            return root
        } catch let error as ManagedHooksConfigurationError {
            throw error
        } catch {
            throw ManagedHooksConfigurationError.invalidConfiguration
        }
    }

    private func installingManagedHooks(in root: [String: Any], command: String) throws -> [String: Any] {
        _ = try normalizedOwnedCommandPath(command)
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in Self.managedEvents {
            var groups = try managedGroups(in: hooks, event: event)
            groups = removingOwnedHooks(from: groups, command: command)
            groups.append(Self.managedGroup(event: event, command: command))
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    private func removingManagedHooks(in root: [String: Any], command: String) throws -> [String: Any] {
        _ = try normalizedOwnedCommandPath(command)
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in Self.managedEvents {
            let groups = removingOwnedHooks(from: try managedGroups(in: hooks, event: event), command: command)
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }
        root["hooks"] = hooks
        return root
    }

    private func removingOwnedHooks(from groups: [[String: Any]], command: String) -> [[String: Any]] {
        groups.compactMap { group in
            guard let hookItems = group["hooks"] as? [[String: Any]] else {
                return group
            }
            let filteredHooks = hookItems.filter { hook in
                guard (hook["type"] as? String) == "command",
                      let existingCommand = hook["command"] as? String
                else {
                    return true
                }
                return normalizedHookCommand(existingCommand) != normalizedHookCommand(command)
            }
            if filteredHooks.isEmpty {
                return nil
            }
            var group = group
            group["hooks"] = filteredHooks
            return group
        }
    }

    private func codexRemoteCommands(in root: [String: Any], command: String) -> [String] {
        let ownedPath = normalizedHookCommand(command)
        guard let hooks = root["hooks"] as? [String: Any] else {
            return []
        }
        return Self.managedEvents.flatMap { event -> [String] in
            guard let groups = hooks[event] as? [[String: Any]] else {
                return []
            }
            return groups.flatMap { group -> [String] in
                guard let hookItems = group["hooks"] as? [[String: Any]] else {
                    return []
                }
                return hookItems.compactMap { hook in
                    guard (hook["type"] as? String) == "command",
                          let existingCommand = hook["command"] as? String,
                          normalizedHookCommand(existingCommand) == ownedPath
                    else {
                        return nil
                    }
                    return existingCommand
                }
            }
        }
    }

    private static func managedGroup(event: String, command: String) -> [String: Any] {
        var hook: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 5,
        ]
        if event == ManagedHookEvent.sessionStart.rawValue {
            hook["statusMessage"] = "同步 Codex Remote 会话"
            return [
                "matcher": "startup|resume",
                "hooks": [hook],
            ]
        }
        return [
            "hooks": [hook],
        ]
    }

    private func createBackup(snapshot: HooksSnapshot) throws {
        guard snapshot.exists else {
            return
        }
        let parent = paths.hooksURL.deletingLastPathComponent()
        for _ in 0..<20 {
            let candidate = parent.appendingPathComponent(
                "\(paths.hooksURL.lastPathComponent).codex-remote-backup-\(timestamp())-\(UUID().uuidString)"
            )
            let descriptor = Darwin.open(candidate.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, snapshot.mode)
            if descriptor < 0 {
                if errno == EEXIST {
                    continue
                }
                throw ManagedHooksConfigurationError.writeFailed
            }
            do {
                try write(snapshot.data, to: descriptor, mode: snapshot.mode)
                Darwin.close(descriptor)
                try fsyncDirectory(parent)
                return
            } catch {
                Darwin.close(descriptor)
                try? FileManager.default.removeItem(at: candidate)
                throw ManagedHooksConfigurationError.writeFailed
            }
        }
        throw ManagedHooksConfigurationError.writeFailed
    }

    private func writeAtomically(_ data: Data, expected snapshot: HooksSnapshot) throws {
        let parent = paths.hooksURL.deletingLastPathComponent()
        let temporaryURL = try createTemporaryFile(in: parent, data: data, mode: 0o600)
        do {
            try validateUnchangedTarget(expected: snapshot)
            try beforeReplace(temporaryURL, paths.hooksURL)
            try validateUnchangedTarget(expected: snapshot)
            guard Darwin.rename(temporaryURL.path, paths.hooksURL.path) == 0 else {
                throw ManagedHooksConfigurationError.writeFailed
            }
            try fsyncDirectory(parent)
            guard try Data(contentsOf: paths.hooksURL) == data else {
                throw ManagedHooksConfigurationError.verificationFailed
            }
        } catch let error as ManagedHooksConfigurationError {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw ManagedHooksConfigurationError.writeFailed
        }
    }

    private func createTemporaryFile(in parent: URL, data: Data, mode: mode_t) throws -> URL {
        for _ in 0..<20 {
            let url = parent.appendingPathComponent(".codex-remote-hooks-\(UUID().uuidString).tmp")
            let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode)
            if descriptor < 0 {
                if errno == EEXIST {
                    continue
                }
                throw ManagedHooksConfigurationError.writeFailed
            }
            do {
                try write(data, to: descriptor, mode: mode)
                Darwin.close(descriptor)
                return url
            } catch {
                Darwin.close(descriptor)
                try? FileManager.default.removeItem(at: url)
                throw ManagedHooksConfigurationError.writeFailed
            }
        }
        throw ManagedHooksConfigurationError.writeFailed
    }

    private func validateUnchangedTarget(expected snapshot: HooksSnapshot) throws {
        let current = try fileStatusNoFollow(at: paths.hooksURL)
        guard let expected = snapshot.status else {
            guard current == nil else {
                throw ManagedHooksConfigurationError.invalidTarget
            }
            return
        }
        guard let current,
              current.st_mode & S_IFMT == S_IFREG,
              sameIdentity(expected, current)
        else {
            throw ManagedHooksConfigurationError.invalidTarget
        }
    }

    private func ensureParentDirectory(_ parent: URL) throws {
        switch try fileStatusNoFollow(at: parent) {
        case .some(let status):
            guard isTrustedDirectoryStatus(status) else {
                throw ManagedHooksConfigurationError.invalidTarget
            }
        case nil:
            do {
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
                guard let status = try fileStatusNoFollow(at: parent),
                      isTrustedDirectoryStatus(status)
                else {
                    throw ManagedHooksConfigurationError.invalidTarget
                }
            } catch {
                throw ManagedHooksConfigurationError.writeFailed
            }
        }
    }

    @discardableResult
    private func validateOwnedCommandExecutable(_ command: String) throws -> String {
        let path = try normalizedOwnedCommandPath(command)
        guard let status = try fileStatusNoFollow(at: URL(fileURLWithPath: path)),
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & mode_t(0o111) != 0,
              Darwin.access(path, X_OK) == 0
        else {
            throw ManagedHooksConfigurationError.invalidCommand
        }
        return path
    }

    private func normalizedOwnedCommandPath(_ command: String) throws -> String {
        let path = unquotedCommand(command)
        guard path.hasPrefix("/") else {
            throw ManagedHooksConfigurationError.invalidCommand
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func normalizedHookCommand(_ command: String) -> String {
        let trimmed = unquotedCommand(command)
        guard trimmed.hasPrefix("/") else {
            return trimmed
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func unquotedCommand(_ command: String) -> String {
        var trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
            || (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private func validateManagedEvents(in root: [String: Any]) throws {
        guard let hooks = root["hooks"] as? [String: Any] else {
            return
        }
        for event in Self.managedEvents {
            _ = try managedGroups(in: hooks, event: event)
        }
    }

    private func managedGroups(in hooks: [String: Any], event: String) throws -> [[String: Any]] {
        guard let value = hooks[event] else {
            return []
        }
        guard let groups = value as? [Any] else {
            throw ManagedHooksConfigurationError.invalidConfiguration
        }
        return try groups.map { groupValue in
            guard let group = groupValue as? [String: Any],
                  let hookValues = group["hooks"] as? [Any]
            else {
                throw ManagedHooksConfigurationError.invalidConfiguration
            }
            _ = try hookValues.map { hookValue in
                guard let hook = hookValue as? [String: Any] else {
                    throw ManagedHooksConfigurationError.invalidConfiguration
                }
                return hook
            }
            return group
        }
    }

    private func serialized(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ManagedHooksConfigurationError.invalidConfiguration
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(UInt8(ascii: "\n"))
        return data
    }

    private func write(_ data: Data, to descriptor: Int32, mode: mode_t) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            var written = 0
            while written < data.count {
                let result = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
                guard result >= 0 else {
                    throw ManagedHooksConfigurationError.writeFailed
                }
                written += result
            }
        }
        guard Darwin.fchmod(descriptor, mode) == 0,
              Darwin.fsync(descriptor) == 0
        else {
            throw ManagedHooksConfigurationError.writeFailed
        }
    }

    private func fsyncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ManagedHooksConfigurationError.writeFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ManagedHooksConfigurationError.writeFailed
        }
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    private struct HooksSnapshot {
        let exists: Bool
        let data: Data
        let mode: mode_t
        let status: stat?
    }
}

private func isTrustedDirectoryStatus(_ status: stat) -> Bool {
    status.st_mode & S_IFMT == S_IFDIR
        && status.st_uid == Darwin.geteuid()
        && status.st_mode & mode_t(0o022) == 0
}

private func fileStatusNoFollow(at url: URL) throws -> stat? {
    var status = stat()
    let result = url.path.withCString { path in
        lstat(path, &status)
    }
    if result != 0 {
        if errno == ENOENT {
            return nil
        }
        throw ManagedHooksConfigurationError.invalidTarget
    }
    return status
}

private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev
        && lhs.st_ino == rhs.st_ino
        && lhs.st_size == rhs.st_size
        && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
        && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
}
