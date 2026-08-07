import Foundation

public enum SetupItem: String, CaseIterable, Equatable, Hashable, Sendable {
    case applicationLocation
    case ghostty
    case codexCLI
    case shim
    case shellPath
    case hooksConfiguration
    case hooksTrust
    case blackHole
    case bluetoothPermission
    case microphonePermission
    case accessibilityPermission
    case doubaoHotkey
    case localIPC
    case esp32Device

    public var blocksMacReadiness: Bool {
        switch self {
        case .blackHole, .doubaoHotkey, .esp32Device:
            false
        default:
            true
        }
    }
}

public enum SetupState: Equatable, Sendable {
    case checking
    case ready
    case needsConfiguration
    case waitingForUser
    case configuring
    case failed
    case notApplicable

    var isReadyState: Bool {
        self == .ready || self == .notApplicable
    }
}

public enum PermissionCheck: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    case restricted
    case unavailable
}

public enum SetupLogLevel: Equatable, Sendable {
    case info
    case warning
    case error
}

public struct SetupLogLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let level: SetupLogLevel
    public let message: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        level: SetupLogLevel,
        message: String
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

public struct SetupCheckResult: Identifiable, Equatable, Sendable {
    public var id: SetupItem { item }
    public let item: SetupItem
    public let state: SetupState
    public let summary: String
    public let detail: String?
    public let availableActions: [SetupAction]

    public init(
        item: SetupItem,
        state: SetupState,
        summary: String,
        detail: String? = nil,
        availableActions: [SetupAction] = []
    ) {
        self.item = item
        self.state = state
        self.summary = summary
        self.detail = detail
        self.availableActions = availableActions
    }
}

public enum SetupAction: Equatable, Hashable, Sendable {
    case installApplication
    case installShimAndPath
    case installHooks
    case confirmHooksTrust
    case installBlackHole
    case requestBluetooth
    case requestMicrophone
    case requestAccessibility
    case testHotkey
    case recheck
    case restoreManagedConfiguration

    public static func defaultAction(for item: SetupItem) -> SetupAction? {
        switch item {
        case .applicationLocation:
            .installApplication
        case .ghostty, .codexCLI:
            nil
        case .shim, .shellPath:
            .installShimAndPath
        case .hooksConfiguration:
            .installHooks
        case .hooksTrust:
            nil
        case .blackHole:
            .installBlackHole
        case .bluetoothPermission:
            .requestBluetooth
        case .microphonePermission:
            .requestMicrophone
        case .accessibilityPermission:
            .requestAccessibility
        case .doubaoHotkey:
            .testHotkey
        case .localIPC:
            .restoreManagedConfiguration
        case .esp32Device:
            nil
        }
    }
}

public enum SetupExecutionError: Error, Equatable, Sendable {
    case dependencyMissing
    case permissionDenied
    case configurationConflict
    case invalidConfiguration
    case commandFailed
    case timedOut
    case verificationFailed
    case busy
    case missingTarget
    case ambiguousAction
    case invalidTargetAction
    case requiresApplicationInteraction(SetupAction)

    public var userMessage: String {
        switch self {
        case .dependencyMissing:
            "缺少必要依赖，请先完成前置配置"
        case .permissionDenied:
            "权限被拒绝，请授权后重试"
        case .configurationConflict:
            "检测到配置冲突，请检查后重试"
        case .invalidConfiguration:
            "配置内容无效，请修正后重试"
        case .commandFailed:
            "配置命令执行失败，请重试"
        case .timedOut:
            "配置超时，请重试"
        case .verificationFailed:
            "配置后验证未通过，请检查后重试"
        case .busy:
            "配置任务正在运行，请稍后重试"
        case .missingTarget:
            "未找到可执行该动作的配置项"
        case .ambiguousAction:
            "该动作对应多个配置项，请指定目标项"
        case .invalidTargetAction:
            "该动作不能用于当前配置项状态"
        case .requiresApplicationInteraction:
            "该操作需要在应用中确认或完成"
        }
    }
}

public enum SetupOperationOutcome: Equatable, Sendable {
    case completed
    case rejected(SetupExecutionError)
}

public struct SetupSnapshot: Equatable, Sendable {
    public let results: [SetupCheckResult]

    public init(results: [SetupCheckResult] = []) {
        self.results = results
    }

    public var isMacReady: Bool {
        guard !results.isEmpty else {
            return false
        }

        let resultsByItem = Dictionary(uniqueKeysWithValues: results.map { ($0.item, $0) })
        return SetupItem.allCases
            .filter(\.blocksMacReadiness)
            .allSatisfy { item in
                resultsByItem[item]?.state.isReadyState == true
            }
    }

    public func result(for item: SetupItem) -> SetupCheckResult? {
        results.first { $0.item == item }
    }
}
