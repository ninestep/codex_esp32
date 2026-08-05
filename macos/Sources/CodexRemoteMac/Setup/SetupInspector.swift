import ApplicationServices
import AVFoundation
import CoreBluetooth
import Darwin
import Foundation

public enum SetupExecutableVersion: Equatable, Sendable {
    case installed(String)
    case notInstalled
    case unrecognized(String)
}

public enum SetupConfigurationState: Equatable, Sendable {
    case valid
    case missing
    case invalid(String)
}

public enum SetupPermissionKind: Equatable, Sendable {
    case bluetooth
    case microphone
    case accessibility
}

public struct SetupInspectionContext: Equatable, Sendable {
    public let socketPath: String
    public let doubaoHotkey: String
    public let applicationURL: URL
    public let stableApplicationURL: URL
    public let managedShimURL: URL
    public let managedShimTargetURL: URL
    public let shellProfileURL: URL
    public let managedHooksConfigurationURL: URL
    public let managedHookExecutableURL: URL
    public let managedHooksTrustTargetURL: URL

    public init(
        socketPath: String,
        doubaoHotkey: String,
        applicationURL: URL,
        stableApplicationURL: URL = URL(fileURLWithPath: "/Applications/Codex Remote.app"),
        managedShimURL: URL,
        managedShimTargetURL: URL? = nil,
        shellProfileURL: URL,
        managedHooksConfigurationURL: URL,
        managedHookExecutableURL: URL? = nil,
        managedHooksTrustTargetURL: URL
    ) {
        self.socketPath = socketPath
        self.doubaoHotkey = doubaoHotkey
        self.applicationURL = applicationURL
        self.stableApplicationURL = stableApplicationURL
        self.managedShimURL = managedShimURL
        self.managedShimTargetURL = managedShimTargetURL
            ?? stableApplicationURL.appendingPathComponent("Contents/Resources/codex")
        self.shellProfileURL = shellProfileURL
        self.managedHooksConfigurationURL = managedHooksConfigurationURL
        self.managedHookExecutableURL = managedHookExecutableURL
            ?? stableApplicationURL.appendingPathComponent("Contents/Resources/codex-remote-hook")
        self.managedHooksTrustTargetURL = managedHooksTrustTargetURL
    }
}

public protocol SetupEnvironmentReading: Sendable {
    func currentApplicationURL() async -> URL
    func isApplicationBundleInstalled(at url: URL) async -> Bool
    func ghosttyExecutable() async -> URL?
    func ghosttyVersion(executableURL: URL) async -> SetupExecutableVersion
    func codexExecutable() async -> URL?
    func codexVersion(executableURL: URL) async -> SetupExecutableVersion
    func isShimInstalled(at url: URL, targetURL: URL) async -> Bool
    func isShellPathConfigured(profileURL: URL) async -> Bool
    func hooksConfigurationState(at url: URL, hookExecutableURL: URL) async -> SetupConfigurationState
    func hooksTrustState(targetURL: URL) async -> Bool?
    func isBlackHoleInstalled() async -> Bool
    func permissionStatus(_ permission: SetupPermissionKind) async -> PermissionCheck
    func wasHotkeyTested(_ hotkey: String) async -> Bool
    func isLocalIPCReachable(socketPath: String) async -> Bool
    func isESP32Connected() async -> Bool
}

public struct SetupInspector: SetupInspecting {
    private let environment: any SetupEnvironmentReading
    private let context: SetupInspectionContext
    private let hotkeyParser: HotkeyParser
    private let hookTrustEvidenceStore: any HookTrustEvidenceReading

    public init(
        environment: any SetupEnvironmentReading = MacSetupEnvironment(),
        context: SetupInspectionContext,
        hotkeyParser: HotkeyParser = HotkeyParser(),
        hookTrustEvidenceStore: (any HookTrustEvidenceReading)? = nil
    ) {
        self.environment = environment
        self.context = context
        self.hotkeyParser = hotkeyParser
        self.hookTrustEvidenceStore = hookTrustEvidenceStore ?? HookTrustEvidenceStore(
            evidenceURL: HookTrustEvidenceStore.evidenceURL(fromTrustTarget: context.managedHooksTrustTargetURL)
        )
    }

    public func inspect() async -> [SetupCheckResult] {
        var results: [SetupCheckResult] = []
        for item in SetupItem.allCases {
            switch item {
            case .applicationLocation:
                results.append(await inspectApplicationLocation())
            case .ghostty:
                results.append(await inspectExecutable(
                    item: .ghostty,
                    executableURL: environment.ghosttyExecutable(),
                    version: environment.ghosttyVersion
                ))
            case .codexCLI:
                results.append(await inspectExecutable(
                    item: .codexCLI,
                    executableURL: environment.codexExecutable(),
                    version: environment.codexVersion
                ))
            case .shim:
                results.append(await boolResult(
                    item: .shim,
                    isReady: environment.isShimInstalled(
                        at: context.managedShimURL,
                        targetURL: context.managedShimTargetURL
                    ),
                    readySummary: "Shim 已安装",
                    missingSummary: "Shim 缺失",
                    action: .installShimAndPath
                ))
            case .shellPath:
                results.append(await boolResult(
                    item: .shellPath,
                    isReady: environment.isShellPathConfigured(profileURL: context.shellProfileURL),
                    readySummary: "PATH 已配置",
                    missingSummary: "PATH 配置缺失",
                    action: .installShimAndPath
                ))
            case .hooksConfiguration:
                results.append(await inspectHooksConfiguration())
            case .hooksTrust:
                results.append(await inspectHooksTrust())
            case .blackHole:
                results.append(await boolResult(
                    item: .blackHole,
                    isReady: environment.isBlackHoleInstalled(),
                    readySummary: "BlackHole 2ch 已安装",
                    missingSummary: "BlackHole 2ch 缺失",
                    action: .installBlackHole
                ))
            case .bluetoothPermission:
                results.append(await inspectPermission(.bluetooth, item: .bluetoothPermission, action: .requestBluetooth))
            case .microphonePermission:
                results.append(await inspectPermission(.microphone, item: .microphonePermission, action: .requestMicrophone))
            case .accessibilityPermission:
                results.append(await inspectPermission(
                    .accessibility,
                    item: .accessibilityPermission,
                    action: .requestAccessibility
                ))
            case .doubaoHotkey:
                results.append(await inspectDoubaoHotkey())
            case .localIPC:
                results.append(await inspectLocalIPC())
            case .esp32Device:
                results.append(await inspectESP32())
            }
        }
        return results
    }

    private func inspectApplicationLocation() async -> SetupCheckResult {
        let currentURL = await environment.currentApplicationURL()
        if samePath(currentURL, context.stableApplicationURL) {
            return SetupCheckResult(item: .applicationLocation, state: .ready, summary: "应用位于稳定位置")
        }
        if await environment.isApplicationBundleInstalled(at: context.stableApplicationURL) {
            return SetupCheckResult(
                item: .applicationLocation,
                state: .waitingForUser,
                summary: "应用已安装，请退出当前实例并从 /Applications/Codex Remote.app 重新打开",
                availableActions: [.recheck]
            )
        }
        return SetupCheckResult(
            item: .applicationLocation,
            state: .needsConfiguration,
            summary: "应用不在稳定位置",
            detail: "\(currentURL.path) -> \(context.stableApplicationURL.path)",
            availableActions: [.installApplication]
        )
    }

    private func inspectExecutable(
        item: SetupItem,
        executableURL: URL?,
        version: (URL) async -> SetupExecutableVersion
    ) async -> SetupCheckResult {
        guard let executableURL else {
            return SetupCheckResult(item: item, state: .needsConfiguration, summary: "\(name(for: item)) 未安装")
        }

        switch await version(executableURL) {
        case .installed(let value):
            return SetupCheckResult(
                item: item,
                state: .ready,
                summary: "\(name(for: item)) 已安装",
                detail: value
            )
        case .notInstalled:
            return SetupCheckResult(item: item, state: .needsConfiguration, summary: "\(name(for: item)) 未安装")
        case .unrecognized(let value):
            return SetupCheckResult(
                item: item,
                state: .needsConfiguration,
                summary: "\(name(for: item)) 版本不可识别",
                detail: value.isEmpty ? nil : value
            )
        }
    }

    private func inspectHooksConfiguration() async -> SetupCheckResult {
        switch await environment.hooksConfigurationState(
            at: context.managedHooksConfigurationURL,
            hookExecutableURL: context.managedHookExecutableURL
        ) {
        case .valid:
            return SetupCheckResult(item: .hooksConfiguration, state: .ready, summary: "Hooks 配置有效")
        case .missing:
            return SetupCheckResult(
                item: .hooksConfiguration,
                state: .needsConfiguration,
                summary: "Hooks 配置缺失",
                availableActions: [.installHooks]
            )
        case .invalid(let detail):
            return SetupCheckResult(
                item: .hooksConfiguration,
                state: .needsConfiguration,
                summary: "Hooks 配置非法",
                detail: detail,
                availableActions: [.installHooks]
            )
        }
    }

    private func inspectHooksTrust() async -> SetupCheckResult {
        guard case .valid = await environment.hooksConfigurationState(
            at: context.managedHooksConfigurationURL,
            hookExecutableURL: context.managedHookExecutableURL
        ),
            let hooksWrittenAt = hooksConfigurationModificationDate(),
            let evidence = hookTrustEvidenceStore.latestEvidence(),
            ManagedHookEvent(rawValue: evidence.eventName) != nil,
            evidence.acceptedAt >= hooksWrittenAt
        else {
            return SetupCheckResult(
                item: .hooksTrust,
                state: .waitingForUser,
                summary: "Hooks 信任需要确认，请在 Codex 中运行 /hooks 并启动一次测试会话",
                availableActions: [.confirmHooksTrust]
            )
        }
        return SetupCheckResult(item: .hooksTrust, state: .ready, summary: "Hooks 信任已确认")
    }

    private func hooksConfigurationModificationDate() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: context.managedHooksConfigurationURL.path)
        return attributes?[.modificationDate] as? Date
    }

    private func inspectPermission(
        _ permission: SetupPermissionKind,
        item: SetupItem,
        action: SetupAction
    ) async -> SetupCheckResult {
        switch await environment.permissionStatus(permission) {
        case .granted:
            return SetupCheckResult(item: item, state: .ready, summary: "\(permissionName(permission)) 权限已授权")
        case .denied:
            return SetupCheckResult(
                item: item,
                state: .waitingForUser,
                summary: "\(permissionName(permission)) 权限被拒绝",
                availableActions: [action]
            )
        case .notDetermined:
            return SetupCheckResult(
                item: item,
                state: .waitingForUser,
                summary: "\(permissionName(permission)) 权限未决定",
                availableActions: [action]
            )
        case .restricted:
            return SetupCheckResult(
                item: item,
                state: .waitingForUser,
                summary: "\(permissionName(permission)) 权限受限",
                availableActions: [action]
            )
        case .unavailable:
            return SetupCheckResult(item: item, state: .notApplicable, summary: "\(permissionName(permission)) 权限不可用")
        }
    }

    private func inspectDoubaoHotkey() async -> SetupCheckResult {
        guard !context.doubaoHotkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hotkeyParser.parse(context.doubaoHotkey) != nil
        else {
            return SetupCheckResult(item: .doubaoHotkey, state: .waitingForUser, summary: "豆包快捷键无效")
        }

        guard await environment.wasHotkeyTested(context.doubaoHotkey) else {
            return SetupCheckResult(
                item: .doubaoHotkey,
                state: .waitingForUser,
                summary: "豆包快捷键待测试",
                availableActions: [.testHotkey]
            )
        }

        return SetupCheckResult(item: .doubaoHotkey, state: .ready, summary: "豆包快捷键已测试")
    }

    private func inspectLocalIPC() async -> SetupCheckResult {
        if await environment.isLocalIPCReachable(socketPath: context.socketPath) {
            return SetupCheckResult(item: .localIPC, state: .ready, summary: "本地 IPC 可连接")
        }
        return SetupCheckResult(
            item: .localIPC,
            state: .failed,
            summary: "本地 IPC 不可连接",
            availableActions: [.restoreManagedConfiguration]
        )
    }

    private func inspectESP32() async -> SetupCheckResult {
        if await environment.isESP32Connected() {
            return SetupCheckResult(item: .esp32Device, state: .ready, summary: "ESP32 已连接")
        }
        return SetupCheckResult(item: .esp32Device, state: .waitingForUser, summary: "等待 ESP32 连接")
    }

    private func boolResult(
        item: SetupItem,
        isReady: Bool,
        readySummary: String,
        missingSummary: String,
        action: SetupAction
    ) async -> SetupCheckResult {
        if isReady {
            return SetupCheckResult(item: item, state: .ready, summary: readySummary)
        }
        return SetupCheckResult(
            item: item,
            state: .needsConfiguration,
            summary: missingSummary,
            availableActions: [action]
        )
    }

    private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private func name(for item: SetupItem) -> String {
        switch item {
        case .ghostty: "Ghostty"
        case .codexCLI: "Codex CLI"
        default: item.rawValue
        }
    }

    private func permissionName(_ permission: SetupPermissionKind) -> String {
        switch permission {
        case .bluetooth: "蓝牙"
        case .microphone: "麦克风"
        case .accessibility: "辅助功能"
        }
    }

}

public struct MacSetupEnvironment: SetupEnvironmentReading {
    private let fileManager: SendableFileManager
    private let commandRunner: any CommandRunning
    private let audioCatalog: CoreAudioDeviceCatalog
    private let esp32ConnectedReader: @Sendable () async -> Bool
    private let hotkeyTestReader: @Sendable (String) async -> Bool

    public init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        audioCatalog: CoreAudioDeviceCatalog = CoreAudioDeviceCatalog(),
        esp32ConnectedReader: @escaping @Sendable () async -> Bool = { false },
        hotkeyTestReader: @escaping @Sendable (String) async -> Bool = { _ in false }
    ) {
        self.fileManager = SendableFileManager(fileManager)
        self.commandRunner = commandRunner
        self.audioCatalog = audioCatalog
        self.esp32ConnectedReader = esp32ConnectedReader
        self.hotkeyTestReader = hotkeyTestReader
    }

    public func currentApplicationURL() async -> URL {
        Bundle.main.bundleURL
    }

    public func isApplicationBundleInstalled(at url: URL) async -> Bool {
        guard (try? setupFileKindNoFollow(at: url)) == .directory else {
            return false
        }
        for relativePath in [
            "Contents/MacOS/codex-remote-app",
            "Contents/MacOS/codex-remote-helper",
            "Contents/Resources/codex",
            "Contents/Resources/codex-remote-hook",
        ] {
            let executable = url.appendingPathComponent(relativePath)
            guard (try? setupFileKindNoFollow(at: executable)) == .regularFile,
                  FileManager.default.isExecutableFile(atPath: executable.path)
            else {
                return false
            }
        }
        let hooks = url.appendingPathComponent("Contents/Resources/codex-remote-hooks.json")
        return (try? setupFileKindNoFollow(at: hooks)) == .regularFile
            && FileManager.default.isReadableFile(atPath: hooks.path)
    }

    public func ghosttyExecutable() async -> URL? {
        await firstExecutable(named: "ghostty", extraCandidates: [
            URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
        ])
    }

    public func ghosttyVersion(executableURL: URL) async -> SetupExecutableVersion {
        await readVersion(executableURL: executableURL, arguments: ["--version"])
    }

    public func codexExecutable() async -> URL? {
        await firstExecutable(named: "codex", extraCandidates: [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ])
    }

    public func codexVersion(executableURL: URL) async -> SetupExecutableVersion {
        await readVersion(executableURL: executableURL, arguments: ["--version"])
    }

    public func isShimInstalled(at url: URL, targetURL: URL) async -> Bool {
        guard let destination = fileManager.symbolicLinkDestination(atPath: url.path) else {
            return false
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return destinationURL.standardizedFileURL.path == targetURL.standardizedFileURL.path
    }

    public func isShellPathConfigured(profileURL: URL) async -> Bool {
        guard let content = fileManager.stringContents(at: profileURL) else {
            return false
        }
        return ManagedShellConfiguration.isShellPathConfigured(content)
    }

    public func hooksConfigurationState(at url: URL, hookExecutableURL: URL) async -> SetupConfigurationState {
        ManagedHooksConfigurationValidator.validate(configurationURL: url, hookExecutableURL: hookExecutableURL)
    }

    public func hooksTrustState(targetURL: URL) async -> Bool? {
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return nil
        }
        // Task 2 has no HookTrustEvidenceStore; absence of evidence must keep the gate waiting.
        return nil
    }

    public func isBlackHoleInstalled() async -> Bool {
        audioCatalog.blackHole2ch() != nil
    }

    public func permissionStatus(_ permission: SetupPermissionKind) async -> PermissionCheck {
        switch permission {
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unavailable
            }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unavailable
            }
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        }
    }

    public func wasHotkeyTested(_ hotkey: String) async -> Bool {
        await hotkeyTestReader(hotkey)
    }

    public func isLocalIPCReachable(socketPath: String) async -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            return false
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                for index in pathBytes.indices {
                    buffer[index] = pathBytes[index]
                }
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    public func isESP32Connected() async -> Bool {
        await esp32ConnectedReader()
    }

    private func firstExecutable(named name: String, extraCandidates: [URL]) async -> URL? {
        for candidate in extraCandidates where isExecutableFile(candidate) {
            return candidate
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if isExecutableFile(url) {
                return url
            }
        }
        return nil
    }

    private func readVersion(executableURL: URL, arguments: [String]) async -> SetupExecutableVersion {
        guard isExecutableFile(executableURL) else {
            return .notInstalled
        }
        do {
            let request = try CommandRequest(executableURL: executableURL, arguments: arguments)
            let result = try await commandRunner.run(request)
            let output = [result.stdout, result.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            guard result.exitCode == 0, !output.isEmpty else {
                return .unrecognized(output)
            }
            return .installed(output)
        } catch {
            return .unrecognized(error.localizedDescription)
        }
    }

    private func isExecutableFile(_ url: URL) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }

}

public struct ManagedHooksConfigurationValidator: Sendable {
    public static func validate(configurationURL url: URL, hookExecutableURL: URL) -> SetupConfigurationState {
        do {
            guard try setupFileKindNoFollow(at: url) != nil else {
                return .missing
            }
            guard try setupTrustedDirectoryNoFollow(at: url.deletingLastPathComponent()) else {
                return .invalid("hooks parent directory is insecure")
            }
            guard try setupFileKindNoFollow(at: url) == .regularFile,
                  FileManager.default.isReadableFile(atPath: url.path)
            else {
                return .invalid("hooks file is not a readable regular file")
            }
            guard try setupFileKindNoFollow(at: hookExecutableURL) == .regularFile,
                  FileManager.default.isExecutableFile(atPath: hookExecutableURL.path)
            else {
                return .invalid("managed hook executable is invalid")
            }
            let data = try Data(contentsOf: url)
            let object = try JSONSerialization.jsonObject(with: data)
            return validateHooksConfiguration(object, hookExecutableURL: hookExecutableURL)
        } catch {
            return .invalid("hooks validation failed")
        }
    }

    private static func validateHooksConfiguration(_ object: Any, hookExecutableURL: URL) -> SetupConfigurationState {
        guard let root = object as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else {
            return .invalid("hooks root is missing")
        }

        for event in ManagedHookEvent.allCases {
            guard eventContainsManagedTemplate(hooks[event.rawValue], event: event, hookExecutableURL: hookExecutableURL) else {
                return .invalid("missing or malformed managed \(event.rawValue) command hook")
            }
        }
        return .valid
    }

    private static func eventContainsManagedTemplate(
        _ value: Any?,
        event: ManagedHookEvent,
        hookExecutableURL: URL
    ) -> Bool {
        guard let groups = value as? [[String: Any]] else {
            return false
        }

        var containsValidManagedHook = false
        for group in groups {
            guard let hookItems = group["hooks"] as? [[String: Any]] else {
                continue
            }
            let ownedHooks = hookItems.filter { hook in
                guard let command = hook["command"] as? String else {
                    return false
                }
                return normalizedHookCommand(command) == hookExecutableURL.standardizedFileURL.path
            }
            guard !ownedHooks.isEmpty else {
                continue
            }
            guard groupMatchesManagedTemplate(group, event: event) else {
                return false
            }
            for hook in ownedHooks {
                guard hookMatchesManagedTemplate(hook, event: event) else {
                    return false
                }
            }
            containsValidManagedHook = true
        }
        return containsValidManagedHook
    }

    private static func groupMatchesManagedTemplate(_ group: [String: Any], event: ManagedHookEvent) -> Bool {
        switch event {
        case .sessionStart:
            return group["matcher"] as? String == "startup|resume"
        case .userPromptSubmit, .permissionRequest, .stop:
            return group["matcher"] == nil
        }
    }

    private static func hookMatchesManagedTemplate(_ hook: [String: Any], event: ManagedHookEvent) -> Bool {
        guard (hook["type"] as? String) == "command",
              intValue(hook["timeout"]) == 5
        else {
            return false
        }
        switch event {
        case .sessionStart:
            return hook["statusMessage"] as? String == "同步 Codex Remote 会话"
        case .userPromptSubmit, .permissionRequest, .stop:
            return hook["statusMessage"] == nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        return (value as? NSNumber)?.intValue
    }

    private static func normalizedHookCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
            || (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}

private func setupTrustedDirectoryNoFollow(at url: URL) throws -> Bool {
    var info = stat()
    let result = url.path.withCString { path in
        lstat(path, &info)
    }
    if result != 0 {
        if errno == ENOENT {
            return false
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return info.st_mode & S_IFMT == S_IFDIR
        && info.st_uid == Darwin.geteuid()
        && info.st_mode & mode_t(0o022) == 0
}

private enum SetupFileKind {
    case regularFile
    case directory
    case symbolicLink
    case other
}

private func setupFileKindNoFollow(at url: URL) throws -> SetupFileKind? {
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

private final class SendableFileManager: @unchecked Sendable {
    private let fileManager: FileManager

    init(_ fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    func isExecutableFile(atPath path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }

    func symbolicLinkDestination(atPath path: String) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: path)
    }

    func stringContents(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}
