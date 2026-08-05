import Foundation

public struct MacSetupExecutionContext: Equatable, Sendable {
    public let sourceApplicationURL: URL
    public let destinationApplicationURL: URL
    public let hookExecutableURL: URL

    public init(
        sourceApplicationURL: URL,
        destinationApplicationURL: URL,
        hookExecutableURL: URL
    ) {
        self.sourceApplicationURL = sourceApplicationURL.standardizedFileURL
        self.destinationApplicationURL = destinationApplicationURL.standardizedFileURL
        self.hookExecutableURL = hookExecutableURL.standardizedFileURL
    }
}

public protocol MacApplicationInstalling: Sendable {
    func install(sourceApplicationURL: URL, destinationApplicationURL: URL) throws
}

public protocol MacShellConfiguring: Sendable {
    func install(appURL: URL) throws
    func restore(appURL: URL) throws
}

public protocol MacHooksConfiguring: Sendable {
    func install(command: String) throws
    func restore(command: String) throws
}

public protocol MacBlackHoleInstalling: Sendable {
    func install() async throws
}

public struct ApplicationInstallerAdapter: MacApplicationInstalling {
    private let installer: ApplicationInstaller

    public init(_ installer: ApplicationInstaller = ApplicationInstaller()) {
        self.installer = installer
    }

    public func install(sourceApplicationURL: URL, destinationApplicationURL: URL) throws {
        _ = try installer.install(
            sourceApplicationURL: sourceApplicationURL,
            destinationApplicationURL: destinationApplicationURL
        )
    }
}

public struct ManagedShellConfigurationAdapter: MacShellConfiguring {
    private let configuration: ManagedShellConfiguration

    public init(_ configuration: ManagedShellConfiguration) {
        self.configuration = configuration
    }

    public func install(appURL: URL) throws {
        _ = try configuration.install(appURL: appURL)
    }

    public func restore(appURL: URL) throws {
        _ = try configuration.restore(appURL: appURL)
    }
}

public struct ManagedHooksConfigurationAdapter: MacHooksConfiguring {
    private let configuration: ManagedHooksConfiguration

    public init(_ configuration: ManagedHooksConfiguration) {
        self.configuration = configuration
    }

    public func install(command: String) throws {
        _ = try configuration.install(command: command)
    }

    public func restore(command: String) throws {
        _ = try configuration.restore(command: command)
    }
}

extension BlackHoleInstaller: MacBlackHoleInstalling {}

public struct MacSetupExecutor: SetupExecuting {
    private let applicationInstaller: any MacApplicationInstalling
    private let shellConfiguration: any MacShellConfiguring
    private let hooksConfiguration: any MacHooksConfiguring
    private let blackHoleInstaller: any MacBlackHoleInstalling
    private let context: MacSetupExecutionContext

    public init(
        applicationInstaller: any MacApplicationInstalling,
        shellConfiguration: any MacShellConfiguring,
        hooksConfiguration: any MacHooksConfiguring,
        blackHoleInstaller: any MacBlackHoleInstalling,
        context: MacSetupExecutionContext
    ) {
        self.applicationInstaller = applicationInstaller
        self.shellConfiguration = shellConfiguration
        self.hooksConfiguration = hooksConfiguration
        self.blackHoleInstaller = blackHoleInstaller
        self.context = context
    }

    public func perform(_ action: SetupAction, for item: SetupItem) async throws {
        guard Self.validItems(for: action).contains(item) else {
            throw SetupExecutionError.invalidTargetAction
        }

        switch action {
        case .installApplication:
            try applicationInstaller.install(
                sourceApplicationURL: context.sourceApplicationURL,
                destinationApplicationURL: context.destinationApplicationURL
            )
        case .installShimAndPath:
            try shellConfiguration.install(appURL: context.destinationApplicationURL)
        case .installHooks:
            try hooksConfiguration.install(command: context.hookExecutableURL.path)
        case .installBlackHole:
            try await blackHoleInstaller.install()
        case .restoreManagedConfiguration:
            try hooksConfiguration.restore(command: context.hookExecutableURL.path)
            try shellConfiguration.restore(appURL: context.destinationApplicationURL)
        case .requestBluetooth, .requestMicrophone, .requestAccessibility,
             .confirmHooksTrust, .testHotkey, .recheck:
            throw SetupExecutionError.requiresApplicationInteraction(action)
        }
    }

    private static func validItems(for action: SetupAction) -> Set<SetupItem> {
        switch action {
        case .installApplication:
            [.applicationLocation]
        case .installShimAndPath:
            [.shim, .shellPath]
        case .installHooks:
            [.hooksConfiguration]
        case .confirmHooksTrust:
            [.hooksTrust]
        case .installBlackHole:
            [.blackHole]
        case .requestBluetooth:
            [.bluetoothPermission]
        case .requestMicrophone:
            [.microphonePermission]
        case .requestAccessibility:
            [.accessibilityPermission]
        case .testHotkey:
            [.doubaoHotkey]
        case .recheck, .restoreManagedConfiguration:
            [.localIPC]
        }
    }
}
