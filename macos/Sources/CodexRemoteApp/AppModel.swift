import CodexRemoteCore
import CodexRemoteMac
import Combine
import ApplicationServices
import AppKit
import AVFoundation
import Darwin
import Foundation

enum HotkeyTestViewState: Equatable {
    case idle
    case countingDown(Int)
    case eventSent(String)
    case failed(String)

    var message: String {
        switch self {
        case .idle:
            "尚未测试"
        case .countingDown(let seconds):
            "请切换到目标应用，\(seconds) 秒后发送"
        case .eventSent:
            "按键事件已发送"
        case .failed(let message):
            message
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = ClientSnapshot(
        transportState: .disconnected,
        sessions: [],
        deviceInformation: nil,
        selectedSessionKey: nil
    )
    @Published private(set) var helperStatus = "未启动"
    @Published private(set) var audioStatus = AudioDependencyStatus.blackHoleMissing
    @Published private(set) var setupSnapshot = SetupSnapshot()
    @Published private(set) var setupLog: [SetupLogLine] = []
    @Published private(set) var hotkeyTestState: HotkeyTestViewState = .idle
    @Published private(set) var isSetupBusy = false
    @Published private(set) var settingsSaveMessage: String?
    @Published private var automaticSetupProgress = AutomaticSetupProgressState()
    @Published var settings: AppSettings

    private var runtime: AppRuntime?
    private var isStarting = false
    private var setupServices: SetupServices
    private let hotkeyTester: HotkeyTester
    private let bluetoothConnectionStatus: BluetoothConnectionStatus
    private let esp32ConnectedReader: @Sendable () async -> Bool
    private var setupActivity = SetupActivityState()
    private var pendingSetupSettings: AppSettings?
    var onOpenSetupAssistant: (() -> Void)?

    var hasStartedAutomaticSetup: Bool {
        automaticSetupProgress.hasStarted
    }

    init() {
        let loadedSettings = Self.loadSettings()
        let bluetoothConnectionStatus = BluetoothConnectionStatus()
        let esp32ConnectedReader: @Sendable () async -> Bool = {
            await bluetoothConnectionStatus.isConnected
        }
        settings = loadedSettings
        self.bluetoothConnectionStatus = bluetoothConnectionStatus
        self.esp32ConnectedReader = esp32ConnectedReader
        setupServices = Self.makeSetupServices(
            settings: loadedSettings,
            esp32ConnectedReader: esp32ConnectedReader
        )
        hotkeyTester = HotkeyTester()
    }

    var menuBarSymbol: String {
        switch snapshot.transportState {
        case .ready: "dot.radiowaves.left.and.right"
        case .unavailable: "exclamationmark.triangle"
        default: "antenna.radiowaves.left.and.right.slash"
        }
    }

    var bluetoothStatusText: String {
        switch snapshot.transportState {
        case .disconnected: "未连接"
        case .unavailable(.poweredOff): "蓝牙已关闭"
        case .unavailable(.unauthorized): "蓝牙未授权"
        case .unavailable(.unsupported): "蓝牙不可用"
        case .unavailable(.poweredOn): "蓝牙状态异常"
        case .scanning: "正在查找设备"
        case .connecting: "正在连接"
        case .discoveringService, .discoveringCharacteristics, .subscribingNotifications:
            "正在建立数据通道"
        case .ready: "已连接"
        }
    }

    var batteryText: String {
        guard let battery = snapshot.deviceInformation?.batteryPercent else { return "--" }
        return "\(battery)%"
    }

    var audioReadinessText: String {
        guard audioStatus == .ready else { return audioStatus.userMessage }
        guard !settings.doubaoHotkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请设置豆包语音快捷键"
        }
        guard AXIsProcessTrusted() else { return "需要辅助功能权限" }
        return "豆包语音链路已就绪"
    }

    var isDoubaoHotkeyInputValid: Bool {
        let value = settings.doubaoHotkey.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || HotkeyParser().parse(value) != nil
    }

    func start() async {
        guard runtime == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        let service = SessionService()
        let audioInput = ReloadableAudioInputBridge(current: BlackHoleAudioInputBridge(
            hotkeyText: settings.doubaoHotkey,
            hotkeyMode: settings.hotkeyMode
        ))
        audioStatus = audioInput.dependencyStatus
        let coordinator = MacClientCoordinator(sessionService: service, audioInput: audioInput)
        coordinator.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            let connectionChanged = self.bluetoothConnectionStatus.update(snapshot.transportState)
            self.snapshot = snapshot
            if connectionChanged {
                Task { [weak self] in
                    await self?.refreshSetup()
                }
            }
        }
        let dispatcher = SessionIPCDispatcher(
            service: service,
            onSessionsChanged: {
                try? await coordinator.refreshSessions()
            }
        )
        let socketURL = URL(fileURLWithPath: settings.socketPath)
        let startupGate = IPCStartupGate()
        let server = UnixSocketIPCServer(socketURL: socketURL) { request in
            await startupGate.waitUntilReady()
            return await dispatcher.handle(request)
        }

        do {
            try SocketParentPreparer().prepareParentDirectory(for: socketURL)
            try await server.start()
            _ = try await HookEventQueue().drain(forSocketAt: socketURL, dispatcher: dispatcher)
            await startupGate.open()
            runtime = AppRuntime(coordinator: coordinator, server: server, audioInput: audioInput)
            helperStatus = "运行中"
            coordinator.start()
        } catch {
            await server.stop()
            helperStatus = "启动失败：\(Self.userFacingStartupError(error))"
        }
    }

    func saveSettings() {
        var settingsToSave = settings
        guard (try? settingsToSave.normalizeDoubaoHotkey()) != nil,
              let data = try? JSONEncoder().encode(settingsToSave)
        else {
            settingsSaveMessage = "快捷键格式无效，设置未保存"
            return
        }

        settings = settingsToSave
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
        runtime?.audioInput.replace(with: BlackHoleAudioInputBridge(
            hotkeyText: settingsToSave.doubaoHotkey,
            hotkeyMode: settingsToSave.hotkeyMode
        ))
        audioStatus = runtime?.audioInput.dependencyStatus ?? audioStatus
        if setupActivity.requestServiceRebuild() {
            setupServices = Self.makeSetupServices(
                settings: settingsToSave,
                esp32ConnectedReader: esp32ConnectedReader
            )
            settingsSaveMessage = "设置已保存"
        } else {
            pendingSetupSettings = settingsToSave
            settingsSaveMessage = "设置已保存，将在当前配置结束后复查"
        }
    }

    func refreshSetup() async {
        guard let services = beginSetupOperation() else { return }
        let outcome = await services.coordinator.refresh()
        await finishSetupOperation(
            services: services,
            outcome: outcome,
            operation: "重新检查",
            targetItem: nil
        )
    }

    func runAutomaticSetup() async {
        guard let services = beginSetupOperation() else { return }
        automaticSetupProgress.begin()
        appendSetupLog(.info, "开始执行已确认的自动配置")
        let outcome = await services.coordinator.runAll()
        await finishSetupOperation(
            services: services,
            outcome: outcome,
            operation: "自动配置",
            targetItem: nil
        )
    }

    func performSetupAction(_ action: SetupAction, for item: SetupItem) async {
        if action == .testHotkey {
            await testDoubaoHotkey()
            return
        }
        guard let services = beginSetupOperation() else { return }
        let outcome: SetupOperationOutcome
        switch action {
        case .requestAccessibility:
            requestAccessibilityPermission()
            openPrivacySettings(anchor: "Privacy_Accessibility")
            appendSetupLog(.info, "已打开辅助功能设置；完成授权并返回 Codex Remote 后将自动复查")
            outcome = .completed
        case .requestMicrophone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            appendSetupLog(.info, "麦克风权限请求已完成，正在复查")
            outcome = await services.coordinator.runAll()
        case .requestBluetooth:
            openPrivacySettings(anchor: "Privacy_Bluetooth")
            appendSetupLog(.info, "已打开蓝牙权限设置；完成授权并返回 Codex Remote 后将自动复查")
            outcome = .completed
        case .confirmHooksTrust, .recheck:
            outcome = await services.coordinator.runAll()
        case .testHotkey:
            return
        case .installApplication, .installShimAndPath, .installHooks,
             .installBlackHole, .restoreManagedConfiguration:
            let performOutcome = await services.coordinator.perform(action, for: item)
            let performedSnapshot = await services.coordinator.snapshot
            if case .completed = performOutcome,
               performedSnapshot.result(for: item)?.state != .failed {
                outcome = await services.coordinator.runAll()
            } else {
                outcome = performOutcome
            }
        }
        await finishSetupOperation(
            services: services,
            outcome: outcome,
            operation: action == .recheck || action == .confirmHooksTrust
                ? "继续配置"
                : setupActionName(action),
            targetItem: item
        )
    }

    func testDoubaoHotkey() async {
        guard let services = beginSetupOperation() else { return }
        hotkeyTestState = .countingDown(3)
        do {
            let result = try await hotkeyTester.test(settings.doubaoHotkey) { [weak self] seconds in
                self?.hotkeyTestState = .countingDown(seconds)
            }
            switch result {
            case .eventSent(let displayValue):
                hotkeyTestState = .eventSent(displayValue)
                settings.recordSuccessfulHotkeyTest(displayValue: displayValue)
                saveSettings()
                appendSetupLog(.info, "豆包快捷键按键事件已发送")
            }
        } catch is CancellationError {
            hotkeyTestState = .idle
            appendSetupLog(.warning, "豆包快捷键测试已取消")
        } catch let error as HotkeyTestError {
            hotkeyTestState = .failed(error.message)
            appendSetupLog(.error, error.message)
        } catch {
            hotkeyTestState = .failed("快捷键测试失败")
            appendSetupLog(.error, "快捷键测试失败")
        }
        await finishSetupOperation(services: services)
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openSetupAssistant() {
        onOpenSetupAssistant?()
    }

    func stop() {
        guard let runtime else { return }
        runtime.coordinator.stop()
        self.runtime = nil
        Task { await runtime.server.stop() }
    }

    private static let settingsKey = "codexRemote.appSettings.v1"

    private func beginSetupOperation() -> SetupServices? {
        guard setupActivity.begin() else {
            appendSetupLog(.warning, SetupExecutionError.busy.userMessage)
            return nil
        }
        isSetupBusy = true
        return setupServices
    }

    private func finishSetupOperation(
        services: SetupServices,
        outcome: SetupOperationOutcome? = nil,
        operation: String? = nil,
        targetItem: SetupItem? = nil
    ) async {
        if let outcome, let operation {
            await synchronizeSetupState(
                services: services,
                outcome: outcome,
                operation: operation,
                targetItem: targetItem
            )
        }

        var shouldRebuild = setupActivity.finish()
        while shouldRebuild, let pendingSetupSettings {
            _ = setupActivity.begin()
            self.pendingSetupSettings = nil
            setupServices = Self.makeSetupServices(
                settings: pendingSetupSettings,
                esp32ConnectedReader: esp32ConnectedReader
            )
            let refreshedServices = setupServices
            let refreshOutcome = await refreshedServices.coordinator.refresh()
            await synchronizeSetupState(
                services: refreshedServices,
                outcome: refreshOutcome,
                operation: "设置变更后复查",
                targetItem: nil
            )
            shouldRebuild = setupActivity.finish()
        }
        isSetupBusy = false
    }

    private func synchronizeSetupState(
        services: SetupServices,
        outcome: SetupOperationOutcome,
        operation: String,
        targetItem: SetupItem?
    ) async {
        let inspectedSnapshot = await services.coordinator.snapshot
        setupSnapshot = inspectedSnapshot
        let installerLogs = await services.blackHoleInstaller.recentLogLines()
        let knownLogIDs = Set(setupLog.map(\.id))
        setupLog.append(contentsOf: installerLogs.filter { !knownLogIDs.contains($0.id) })
        let classification = SetupOperationLogClassifier.classify(
            operation: operation,
            outcome: outcome,
            snapshot: inspectedSnapshot,
            targetItem: targetItem
        )
        appendSetupLog(classification.level, classification.message)
    }

    private func appendSetupLog(_ level: SetupLogLevel, _ message: String) {
        setupLog.append(SetupLogLine(level: level, message: message))
        if setupLog.count > 500 {
            setupLog.removeFirst(setupLog.count - 500)
        }
    }

    private func setupActionName(_ action: SetupAction) -> String {
        switch action {
        case .installApplication: "安装应用"
        case .installShimAndPath: "配置命令桥接与 PATH"
        case .installHooks: "配置 Codex hooks"
        case .confirmHooksTrust: "复查 hooks 信任"
        case .installBlackHole: "安装 BlackHole 2ch"
        case .requestBluetooth: "请求蓝牙权限"
        case .requestMicrophone: "请求麦克风权限"
        case .requestAccessibility: "请求辅助功能权限"
        case .testHotkey: "测试豆包快捷键"
        case .recheck: "重新检查"
        case .restoreManagedConfiguration: "恢复托管配置"
        }
    }

    private static func makeSetupServices(
        settings: AppSettings,
        esp32ConnectedReader: @escaping @Sendable () async -> Bool
    ) -> SetupServices {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        let managedBinDirectory = home
            .appendingPathComponent(".codex-remote", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let stableApplicationURL = URL(fileURLWithPath: "/Applications/Codex Remote.app", isDirectory: true)
        let hookExecutableURL = stableApplicationURL
            .appendingPathComponent("Contents/Resources/codex-remote-hook")
        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let sourceApplicationURL = Bundle.main.bundleURL
        let testedHotkey = settings.lastTestedDoubaoHotkey
        let environment = MacSetupEnvironment(
            esp32ConnectedReader: esp32ConnectedReader,
            hotkeyTestReader: { hotkey in
                HotkeyParser().parse(hotkey)?.displayValue == testedHotkey
            }
        )
        let inspectionContext = SetupInspectionContext(
            socketPath: settings.socketPath,
            doubaoHotkey: settings.doubaoHotkey,
            applicationURL: sourceApplicationURL,
            stableApplicationURL: stableApplicationURL,
            managedShimURL: managedBinDirectory.appendingPathComponent("codex"),
            shellProfileURL: home.appendingPathComponent(".zshrc"),
            managedHooksConfigurationURL: hooksURL,
            managedHookExecutableURL: hookExecutableURL,
            managedHooksTrustTargetURL: codexDirectory
        )
        let shellConfiguration = ManagedShellConfiguration(
            profileURL: home.appendingPathComponent(".zshrc"),
            managedBinDirectoryURL: managedBinDirectory,
            shimURL: managedBinDirectory.appendingPathComponent("codex")
        )
        let hooksConfiguration = ManagedHooksConfiguration(
            paths: .init(hooksURL: hooksURL)
        )
        let brewURL = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .map(URL.init(fileURLWithPath:))
            .first { fileManager.isExecutableFile(atPath: $0.path) }
        let blackHoleInstaller = BlackHoleInstaller(brewURL: brewURL)
        let executor = MacSetupExecutor(
            applicationInstaller: ApplicationInstallerAdapter(),
            shellConfiguration: ManagedShellConfigurationAdapter(shellConfiguration),
            hooksConfiguration: ManagedHooksConfigurationAdapter(hooksConfiguration),
            blackHoleInstaller: blackHoleInstaller,
            context: MacSetupExecutionContext(
                sourceApplicationURL: sourceApplicationURL,
                destinationApplicationURL: stableApplicationURL,
                hookExecutableURL: hookExecutableURL
            )
        )
        let inspector = SetupInspector(environment: environment, context: inspectionContext)
        return SetupServices(
            coordinator: SetupCoordinator(inspector: inspector, executor: executor),
            blackHoleInstaller: blackHoleInstaller
        )
    }

    private static func loadSettings() -> AppSettings {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings
        }
        return .defaults(
            temporaryDirectory: ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp",
            userID: geteuid()
        )
    }

    private static func userFacingStartupError(_ error: Error) -> String {
        if case UnixSocketIPCServerError.socketPathAlreadyExists = error {
            return "Socket 已被占用，请退出旧版 helper 后重试"
        }
        return "本地服务不可用"
    }
}

private struct SetupServices {
    let coordinator: SetupCoordinator
    let blackHoleInstaller: BlackHoleInstaller
}


@MainActor
private final class AppRuntime {
    let coordinator: MacClientCoordinator
    let server: UnixSocketIPCServer
    let audioInput: ReloadableAudioInputBridge

    init(coordinator: MacClientCoordinator, server: UnixSocketIPCServer, audioInput: ReloadableAudioInputBridge) {
        self.coordinator = coordinator
        self.server = server
        self.audioInput = audioInput
    }
}
