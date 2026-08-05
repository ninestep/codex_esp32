# macOS 安装检查与一键配置实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Codex Remote Mac 客户端增加首次启动配置向导和长期诊断页，检查并在用户授权后配置 Ghostty、Codex CLI、shim、PATH、hooks、BlackHole、macOS 权限及豆包快捷键。

**Architecture:** `CodexRemoteMac` 新增平台适配层：只读 `SetupInspector` 产生统一检查结果，`SetupCoordinator` 按依赖编排经授权的 `SetupAction`，各执行器只负责一类系统变更。`CodexRemoteApp` 只渲染状态、收集确认和触发操作；共享 BLE v1、本地 IPC 契约和固件保持不变。

**Tech Stack:** Swift 6.2、SwiftUI、AppKit、ApplicationServices、CoreAudio、Foundation `Process`/`FileManager`、XCTest、现有 Swift Package 与应用打包脚本。

---

## 范围与执行门禁

- 本计划不修改 BLE v1、设备固件、本地 IPC schema、依赖或 CI。
- 自动测试只能使用临时目录和 fake，不写真实 `~/.zshrc`、`~/.codex/hooks.json`，不安装 BlackHole，不申请系统权限。
- 真实 PATH、hooks、`/Applications` 和 BlackHole 变更必须由配置界面逐项确认；实施验证如需修改当前机器，再单独取得现场授权。
- 每个任务完成后先验证。Git commit 仍属于独立门禁；只有用户明确授权提交后，才执行计划中的提交命令。

## 文件结构

### 新增文件

- `macos/Sources/CodexRemoteMac/Setup/SetupModels.swift`：平台无关的检查状态、操作和结果类型。
- `macos/Sources/CodexRemoteMac/Setup/SetupInspector.swift`：聚合只读检查，不执行修复。
- `macos/Sources/CodexRemoteMac/Setup/SetupCoordinator.swift`：按依赖执行、暂停、重试和复查。
- `macos/Sources/CodexRemoteMac/Setup/CommandRunner.swift`：受限外部命令端口和 macOS 实现。
- `macos/Sources/CodexRemoteMac/Setup/ApplicationInstaller.swift`：把应用安全复制到 `/Applications` 并验证产物。
- `macos/Sources/CodexRemoteMac/Setup/ManagedShellConfiguration.swift`：shim 与 zsh PATH 托管区块。
- `macos/Sources/CodexRemoteMac/Setup/ManagedHooksConfiguration.swift`：hooks JSON 合并、备份、原子写入和恢复。
- `macos/Sources/CodexRemoteMac/Setup/HookTrustEvidenceStore.swift`：记录真实 hook 到达证据。
- `macos/Sources/CodexRemoteMac/Setup/BlackHoleInstaller.swift`：Homebrew 存在性检查与 BlackHole 安装。
- `macos/Sources/CodexRemoteMac/Setup/MacSetupExecutor.swift`：把已确认动作路由到各单项执行器。
- `macos/Sources/CodexRemoteMac/Input/HotkeyTester.swift`：快捷键标准化和倒计时发送测试。
- `macos/Sources/CodexRemoteMac/Audio/ReloadableAudioInputBridge.swift`：在不重启客户端的情况下替换下一次 PTT 使用的音频桥接配置。
- `macos/Sources/CodexRemoteApp/SetupAssistantView.swift`：首次启动四阶段向导。
- `macos/Sources/CodexRemoteApp/InstallationDiagnosticsView.swift`：设置页长期状态中心。
- `macos/Sources/CodexRemoteApp/SetupWindowController.swift`：按检查结果打开和复用向导窗口。
- `macos/Tests/CodexRemoteMacTests/SetupModelsTests.swift`
- `macos/Tests/CodexRemoteMacTests/SetupInspectorTests.swift`
- `macos/Tests/CodexRemoteMacTests/SetupCoordinatorTests.swift`
- `macos/Tests/CodexRemoteMacTests/ApplicationInstallerTests.swift`
- `macos/Tests/CodexRemoteMacTests/ManagedShellConfigurationTests.swift`
- `macos/Tests/CodexRemoteMacTests/ManagedHooksConfigurationTests.swift`
- `macos/Tests/CodexRemoteMacTests/BlackHoleInstallerTests.swift`
- `macos/Tests/CodexRemoteMacTests/HotkeyTesterTests.swift`
- `macos/Tests/CodexRemoteMacTests/ReloadableAudioInputBridgeTests.swift`

### 修改文件

- `macos/Sources/CodexRemoteMac/Input/HotkeyEmitter.swift`：扩展解析键表并提供标准化显示值。
- `macos/Sources/CodexRemoteMac/App/AppSettings.swift`：记录向导状态和快捷键最近测试结果。
- `macos/Sources/CodexRemoteApp/AppModel.swift`：持有配置协调器并桥接 UI。
- `macos/Sources/CodexRemoteApp/CodexRemoteApp.swift`：首次启动时按真实检查结果展示向导。
- `macos/Sources/CodexRemoteApp/SettingsView.swift`：增加“安装与诊断”标签页。
- `macos/Sources/CodexRemoteApp/MenuBarContentView.swift`：显示未就绪入口。
- `macos/App/Info.plist`：补充麦克风用途说明。
- `macos/Scripts/package-app.zsh`：校验配置资源随应用打包。
- `macos/Docs/phase-3-mac-client-verification.md`：补充配置向导的验证证据与现场门禁。
- `docs/设备到位启用手册.md`：把主要手工命令改为向导流程，并保留故障排查命令。

### 明确不修改

- `macos/Sources/CodexRemoteCore/BLE/**`
- `macos/Sources/CodexRemoteCore/Transport/**`
- `firmware/**`
- `protocol/**`

## Task 1：建立配置状态模型与编排器

**Files:**
- Create: `macos/Sources/CodexRemoteMac/Setup/SetupModels.swift`
- Create: `macos/Sources/CodexRemoteMac/Setup/SetupCoordinator.swift`
- Test: `macos/Tests/CodexRemoteMacTests/SetupModelsTests.swift`
- Test: `macos/Tests/CodexRemoteMacTests/SetupCoordinatorTests.swift`

- [ ] **Step 1：写状态模型失败测试**

```swift
func testReadinessRequiresEveryRequiredItem() {
    let ready = SetupCheckResult(item: .ghostty, state: .ready, summary: "已安装")
    let waiting = SetupCheckResult(item: .hooksTrust, state: .waitingForUser, summary: "等待确认")

    XCTAssertTrue(SetupSnapshot(results: [ready]).isMacReady)
    XCTAssertFalse(SetupSnapshot(results: [ready, waiting]).isMacReady)
}

func testDeviceWaitingDoesNotBlockMacReadiness() {
    let result = SetupCheckResult(item: .esp32Device, state: .waitingForUser, summary: "等待设备")
    XCTAssertTrue(SetupSnapshot(results: [result]).isMacReady)
}

func testEmptySnapshotIsNotReadyBeforeFirstInspection() {
    XCTAssertFalse(SetupSnapshot(results: []).isMacReady)
}
```

- [ ] **Step 2：运行测试并确认 RED**

Run: `cd macos && swift test --disable-sandbox --filter SetupModelsTests`

Expected: 编译失败，提示 `SetupCheckResult`、`SetupSnapshot` 不存在。

- [ ] **Step 3：实现最小状态模型**

```swift
public enum SetupItem: String, CaseIterable, Sendable {
    case applicationLocation, ghostty, codexCLI, shim, shellPath
    case hooksConfiguration, hooksTrust, blackHole
    case bluetoothPermission, microphonePermission, accessibilityPermission
    case doubaoHotkey, localIPC, esp32Device

    public var blocksMacReadiness: Bool { self != .esp32Device }
}

public enum SetupState: String, Sendable {
    case checking, ready, needsConfiguration, waitingForUser
    case configuring, failed, notApplicable
}

public enum PermissionCheck: Equatable, Sendable {
    case granted, denied, notDetermined, restricted, unavailable
}

public enum SetupLogLevel: String, Sendable {
    case info, warning, error
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

public struct SetupLogLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let level: SetupLogLevel
    public let message: String
}

public enum SetupAction: String, Equatable, Sendable {
    case installApplication, installShimAndPath, installHooks
    case confirmHooksTrust, installBlackHole
    case requestBluetooth, requestMicrophone, requestAccessibility
    case testHotkey, recheck, restoreManagedConfiguration
}

public struct SetupSnapshot: Equatable, Sendable {
    public let results: [SetupCheckResult]
    public var isMacReady: Bool {
        guard !results.isEmpty else { return false }
        results.filter(\.item.blocksMacReadiness).allSatisfy {
            $0.state == .ready || $0.state == .notApplicable
        }
    }
    public func result(for item: SetupItem) -> SetupCheckResult? {
        results.first { $0.item == item }
    }
}
```

- [ ] **Step 4：写编排暂停与继续失败测试**

```swift
func testRunAllStopsAtUserConfirmationAndRechecksAfterResume() async {
    let executor = RecordingSetupExecutor()
    let coordinator = SetupCoordinator(inspector: SequencedInspector(), executor: executor)

    await coordinator.runAll()
    XCTAssertEqual(await executor.actions, [.installShimAndPath, .installHooks])
    XCTAssertEqual(await coordinator.snapshot.result(for: .hooksTrust)?.state, .waitingForUser)

    await coordinator.resumeAfterUserAction(.confirmHooksTrust)
    XCTAssertEqual(await coordinator.snapshot.result(for: .hooksTrust)?.state, .ready)
}
```

- [ ] **Step 5：实现最小编排器并验证 GREEN**

`SetupCoordinator` 依次处理 `SetupInspector.inspect()` 返回的首个未就绪必需项；遇到 `waitingForUser` 停止；执行动作后必须重新检查，不能直接把状态改为 `ready`。

Run: `cd macos && swift test --disable-sandbox --filter 'SetupModelsTests|SetupCoordinatorTests'`

Expected: 两组测试全部通过。

- [ ] **Step 6：提交门禁**

授权后执行：

```bash
git add macos/Sources/CodexRemoteMac/Setup/SetupModels.swift macos/Sources/CodexRemoteMac/Setup/SetupCoordinator.swift macos/Tests/CodexRemoteMacTests/SetupModelsTests.swift macos/Tests/CodexRemoteMacTests/SetupCoordinatorTests.swift
git commit -m "feat(macos): 增加安装检查状态与编排器"
```

## Task 2：实现只读环境检查

**Files:**
- Create: `macos/Sources/CodexRemoteMac/Setup/CommandRunner.swift`
- Create: `macos/Sources/CodexRemoteMac/Setup/SetupInspector.swift`
- Test: `macos/Tests/CodexRemoteMacTests/SetupInspectorTests.swift`

- [ ] **Step 1：写只读检查失败测试**

```swift
func testInspectorReportsExactMissingDependencies() async {
    let environment = FakeSetupEnvironment(
        applicationURL: URL(fileURLWithPath: "/tmp/Codex Remote.app"),
        executablePaths: ["ghostty": nil, "codex": "/opt/bin/codex"],
        accessibilityGranted: false,
        microphoneGranted: true,
        bluetoothGranted: true,
        blackHoleAvailable: false
    )

    let snapshot = await SetupInspector(environment: environment).inspect()

    XCTAssertEqual(snapshot.result(for: .applicationLocation)?.state, .needsConfiguration)
    XCTAssertEqual(snapshot.result(for: .ghostty)?.state, .needsConfiguration)
    XCTAssertEqual(snapshot.result(for: .codexCLI)?.state, .ready)
    XCTAssertEqual(snapshot.result(for: .blackHole)?.state, .needsConfiguration)
    XCTAssertEqual(snapshot.result(for: .accessibilityPermission)?.state, .waitingForUser)
}
```

- [ ] **Step 2：运行测试并确认 RED**

Run: `cd macos && swift test --disable-sandbox --filter SetupInspectorTests`

Expected: 编译失败，提示 `SetupInspector` 不存在。

- [ ] **Step 3：实现可替换环境端口和受限命令执行器**

```swift
public struct CommandRequest: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
}

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
}

public enum CommandEvent: Equatable, Sendable {
    case standardOutput(String)
    case standardError(String)
    case completed(Int32)
}

public protocol CommandRunning: Sendable {
    func run(_ request: CommandRequest) async throws -> CommandResult
    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error>
}

public protocol SetupEnvironmentReading: Sendable {
    var applicationURL: URL { get }
    func executablePath(named name: String) async -> String?
    func commandVersion(executable: String, arguments: [String]) async -> String?
    func isAccessibilityGranted() -> Bool
    func microphoneAuthorization() async -> PermissionCheck
    func bluetoothAuthorization() -> PermissionCheck
    func isBlackHole2chAvailable() -> Bool
    func isLocalIPCReachable(socketPath: String) async -> Bool
    func isESP32Connected() -> Bool
}
```

`ProcessCommandRunner` 只接收绝对可执行路径，不通过 shell 拼接命令；`run` 供短命令检查版本，`stream` 分行返回长命令输出。两种路径都设置输出大小上限并在 UI 展示前脱敏。

- [ ] **Step 4：实现检查器**

检查器固定输出所有 `SetupItem`，并为每项给出中文摘要和允许的动作。应用位置只接受 `/Applications/Codex Remote.app`；Ghostty 与 Codex 版本读取失败时显示“版本不可识别”，不伪报未安装。

- [ ] **Step 5：运行定向测试**

Run: `cd macos && swift test --disable-sandbox --filter SetupInspectorTests`

Expected: 覆盖全部安装、部分缺失、权限拒绝、版本读取失败和等待 ESP32 的测试全部通过。

- [ ] **Step 6：提交门禁**

授权后执行：

```bash
git add macos/Sources/CodexRemoteMac/Setup/CommandRunner.swift macos/Sources/CodexRemoteMac/Setup/SetupInspector.swift macos/Tests/CodexRemoteMacTests/SetupInspectorTests.swift
git commit -m "feat(macos): 增加安装环境只读检查"
```

## Task 3：实现应用安装、shim 与 PATH 托管配置

**Files:**
- Create: `macos/Sources/CodexRemoteMac/Setup/ApplicationInstaller.swift`
- Create: `macos/Sources/CodexRemoteMac/Setup/ManagedShellConfiguration.swift`
- Test: `macos/Tests/CodexRemoteMacTests/ApplicationInstallerTests.swift`
- Test: `macos/Tests/CodexRemoteMacTests/ManagedShellConfigurationTests.swift`

- [ ] **Step 1：写应用安装原子替换失败测试**

```swift
func testInstallStagesValidBundleBeforeReplacingDestination() throws {
    let fixture = try ApplicationInstallFixture()
    let installer = ApplicationInstaller(fileManager: fixture.fileManager)

    let result = try installer.install(source: fixture.validSource, destination: fixture.destination)

    XCTAssertEqual(result, .installedAndRequiresRelaunch(fixture.destination))
    XCTAssertTrue(fixture.hasRequiredExecutableAndResources(at: fixture.destination))
    XCTAssertFalse(fixture.stagingURLExists)
}

func testInvalidSourceDoesNotReplaceExistingApplication() throws {
    let fixture = try ApplicationInstallFixture(existingDestination: true)
    let original = try fixture.destinationDigest()

    XCTAssertThrowsError(try ApplicationInstaller().install(source: fixture.invalidSource, destination: fixture.destination))
    XCTAssertEqual(try fixture.destinationDigest(), original)
}
```

- [ ] **Step 2：运行应用安装测试并确认 RED**

Run: `cd macos && swift test --disable-sandbox --filter ApplicationInstallerTests`

Expected: 编译失败，提示 `ApplicationInstaller` 不存在。

- [ ] **Step 3：实现应用安装器**

安装器先验证源应用包含 `Contents/MacOS/codex-remote-app`、`codex-remote-helper` 以及 `Contents/Resources/codex`、`codex-remote-hook`、`codex-remote-hooks.json`。随后复制到目标同级临时目录，复查产物，再使用 `FileManager.replaceItemAt` 替换既有目标；失败时删除临时目录并保留旧应用。权限不足时返回 `permissionDenied`，界面提示用户手工拖入“应用程序”，不申请或收集管理员密码。

- [ ] **Step 4：写 shim 幂等和恢复失败测试**

```swift
func testInstallCreatesOneManagedBlockAndShim() throws {
    let fixture = try ShellFixture(zshrc: "export PATH=\"/opt/bin:$PATH\"\n")
    let manager = ManagedShellConfiguration(paths: fixture.paths)

    try manager.install(appURL: URL(fileURLWithPath: "/Applications/Codex Remote.app"))
    try manager.install(appURL: URL(fileURLWithPath: "/Applications/Codex Remote.app"))

    let content = try String(contentsOf: fixture.paths.zshrcURL)
    XCTAssertEqual(content.components(separatedBy: ManagedShellConfiguration.beginMarker).count - 1, 1)
    XCTAssertTrue(content.hasSuffix(ManagedShellConfiguration.managedBlock))
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.paths.shimURL.path), "/Applications/Codex Remote.app/Contents/Resources/codex")
}

func testRestoreRemovesOnlyManagedContent() throws {
    let fixture = try ShellFixture(zshrc: "export EDITOR=vim\n" + ManagedShellConfiguration.managedBlock)
    try ManagedShellConfiguration(paths: fixture.paths).restore()
    XCTAssertEqual(try String(contentsOf: fixture.paths.zshrcURL), "export EDITOR=vim\n")
}
```

- [ ] **Step 5：运行 shim 测试并确认 RED**

Run: `cd macos && swift test --disable-sandbox --filter ManagedShellConfigurationTests`

Expected: 编译失败，提示 `ManagedShellConfiguration` 不存在。

- [ ] **Step 6：实现固定托管区块**

```swift
public static let beginMarker = "# >>> Codex Remote >>>"
public static let endMarker = "# <<< Codex Remote <<<"
public static let managedBlock = """
# >>> Codex Remote >>>
export PATH="$HOME/.codex-remote/bin:$PATH"
# <<< Codex Remote <<<
"""
```

实现必须：

- 拒绝 `.zshrc` 符号链接；
- 写入前在同目录创建带时间戳的备份；
- 用同目录临时文件和原子替换写入；
- 创建 `~/.codex-remote/bin/codex` 指向应用资源的符号链接；
- 重新解析 PATH 区块并确认只有一个托管区块；
- 恢复时只删除托管区块和该符号链接。

- [ ] **Step 7：验证应用安装、shim、冲突和恢复**

Run: `cd macos && swift test --disable-sandbox --filter 'ApplicationInstallerTests|ManagedShellConfigurationTests'`

Expected: 全部通过，且测试只写 XCTest 临时目录。

- [ ] **Step 8：提交门禁**

授权后执行：

```bash
git add macos/Sources/CodexRemoteMac/Setup/ApplicationInstaller.swift macos/Sources/CodexRemoteMac/Setup/ManagedShellConfiguration.swift macos/Tests/CodexRemoteMacTests/ApplicationInstallerTests.swift macos/Tests/CodexRemoteMacTests/ManagedShellConfigurationTests.swift
git commit -m "feat(macos): 自动安装应用与 Codex shim"
```

## Task 4：实现 Codex hooks 安全合并与恢复

**Files:**
- Create: `macos/Sources/CodexRemoteMac/Setup/ManagedHooksConfiguration.swift`
- Create: `macos/Sources/CodexRemoteMac/Setup/HookTrustEvidenceStore.swift`
- Modify: `macos/Sources/CodexRemoteMac/Helper/SessionIPCDispatcher.swift`
- Test: `macos/Tests/CodexRemoteMacTests/ManagedHooksConfigurationTests.swift`

- [ ] **Step 1：写保留第三方 hook 和幂等失败测试**

```swift
func testInstallPreservesUnrelatedHooksAndIsIdempotent() throws {
    let fixture = try HooksFixture(existingJSON: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party"}]}]}}"#)
    let manager = ManagedHooksConfiguration(paths: fixture.paths)

    try manager.install(command: "'/Applications/Codex Remote.app/Contents/Resources/codex-remote-hook'")
    try manager.install(command: "'/Applications/Codex Remote.app/Contents/Resources/codex-remote-hook'")

    let object = try fixture.readJSONObject()
    XCTAssertEqual(fixture.commands(in: object, event: "Stop").filter { $0 == "third-party" }.count, 1)
    XCTAssertEqual(fixture.codexRemoteCommands(in: object).count, 4)
    XCTAssertEqual(try fixture.mode(), 0o600)
}

func testInvalidJSONLeavesOriginalBytesUnchanged() throws {
    let fixture = try HooksFixture(existingJSON: "{invalid")
    XCTAssertThrowsError(try ManagedHooksConfiguration(paths: fixture.paths).install(command: "hook"))
    XCTAssertEqual(try Data(contentsOf: fixture.paths.hooksURL), Data("{invalid".utf8))
}
```

- [ ] **Step 2：运行测试并确认 RED**

Run: `cd macos && swift test --disable-sandbox --filter ManagedHooksConfigurationTests`

Expected: 编译失败，提示 `ManagedHooksConfiguration` 不存在。

- [ ] **Step 3：实现 JSON 合并**

使用 `JSONSerialization` 保留未建模字段。Codex Remote 条目以命令绝对路径作为所有权标识，只维护四个事件：`SessionStart`、`UserPromptSubmit`、`PermissionRequest`、`Stop`。`SessionStart` 保留 `startup|resume` matcher，其余字段与 `macos/App/codex-remote-hooks.json` 一致。

写入顺序固定为：读取原始字节、解析、备份、构造合并对象、写同目录临时文件、设置 `0600`、原子替换、重新读取验证。恢复时只删除命令路径匹配的 Codex Remote 条目；事件数组仍有其他条目时保留事件。

- [ ] **Step 4：验证空文件、第三方配置、非法 JSON、重复执行和恢复**

Run: `cd macos && swift test --disable-sandbox --filter ManagedHooksConfigurationTests`

Expected: 全部通过；非法 JSON 和替换失败用例保持原文件字节不变。

- [ ] **Step 5：记录真实 hook 信任证据**

`HookTrustEvidenceStore` 保存最近一次成功处理 hook 的时间和事件名。`SessionIPCDispatcher` 仅在 `.hook` 请求完成并返回 `.ok` 后调用注入的 `onHookAccepted` 闭包：

```swift
public init(service: SessionService, onSessionChange: @escaping @Sendable () async -> Void, onHookAccepted: @escaping @Sendable (String) -> Void = { _ in })
```

`SetupInspector` 只有在 hooks 配置正确且证据存储中存在当前配置写入时间之后的真实 hook 时，才把 `.hooksTrust` 标为 `ready`；否则保持 `waitingForUser`，提示用户运行 Codex `/hooks` 并启动一次测试会话。

- [ ] **Step 6：补充证据测试并验证**

Run: `cd macos && swift test --disable-sandbox --filter 'ManagedHooksConfigurationTests|SetupInspectorTests|HelperCommandTests'`

Expected: hook 成功才记录证据，解析失败和 daemon 失败均不记录；旧证据不能让新 hooks 配置直接就绪。

- [ ] **Step 7：提交门禁**

授权后执行：

```bash
git add macos/Sources/CodexRemoteMac/Setup/ManagedHooksConfiguration.swift macos/Sources/CodexRemoteMac/Setup/HookTrustEvidenceStore.swift macos/Sources/CodexRemoteMac/Helper/SessionIPCDispatcher.swift macos/Tests/CodexRemoteMacTests/ManagedHooksConfigurationTests.swift macos/Tests/CodexRemoteMacTests/SetupInspectorTests.swift macos/Tests/CodexRemoteMacTests/HelperCommandTests.swift
git commit -m "feat(macos): 安全合并 Codex hooks 配置"
```

## Task 5：实现 BlackHole 安装器

**Files:**
- Create: `macos/Sources/CodexRemoteMac/Setup/BlackHoleInstaller.swift`
- Test: `macos/Tests/CodexRemoteMacTests/BlackHoleInstallerTests.swift`

- [ ] **Step 1：写 Homebrew 缺失和安装结果失败测试**

```swift
func testMissingHomebrewDoesNotRunInstall() async {
    let runner = RecordingCommandRunner(results: [:])
    let installer = BlackHoleInstaller(commandRunner: runner, brewURL: nil)

    do {
        try await installer.install()
        XCTFail("expected homebrewMissing")
    } catch {
        XCTAssertEqual(error as? BlackHoleInstallerError, .homebrewMissing)
    }
    XCTAssertEqual(await runner.requests, [])
}

func testInstallUsesOfficialCaskCommandAndRequiresAudioDeviceAfterward() async throws {
    let runner = RecordingCommandRunner(events: [.standardOutput("Installing"), .completed(0)])
    let catalog = SequencedBlackHoleCatalog(values: [false, true])
    try await BlackHoleInstaller(commandRunner: runner, brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), catalog: catalog).install()
    XCTAssertEqual(
        await runner.requests,
        [CommandRequest(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), arguments: ["install", "--cask", "blackhole-2ch"])]
    )
}
```

- [ ] **Step 2：运行测试并确认 RED**

Run: `cd macos && swift test --disable-sandbox --filter BlackHoleInstallerTests`

Expected: 编译失败，提示 `BlackHoleInstaller` 不存在。

- [ ] **Step 3：实现安装器**

安装器只接受已解析的 `/opt/homebrew/bin/brew` 或 `/usr/local/bin/brew` 绝对路径，执行参数固定为 `install --cask blackhole-2ch`。退出码非零时返回包含脱敏 stderr 摘要的失败；退出码为零后重新查询 CoreAudio，只有发现 BlackHole 2ch 才返回成功。

日志使用 `AsyncStream<SetupLogLine>` 逐行返回界面，最多保留最近 500 行，每行最多 2 KiB。安装器不调用 shell，不自动安装 Homebrew，不实现卸载快捷入口。

- [ ] **Step 4：运行定向测试**

Run: `cd macos && swift test --disable-sandbox --filter BlackHoleInstallerTests`

Expected: Homebrew 缺失、命令失败、退出零但设备缺失、安装完成四类测试全部通过。

- [ ] **Step 5：提交门禁**

授权后执行：

```bash
git add macos/Sources/CodexRemoteMac/Setup/BlackHoleInstaller.swift macos/Tests/CodexRemoteMacTests/BlackHoleInstallerTests.swift
git commit -m "feat(macos): 增加 BlackHole 引导安装"
```

## Task 6：实现豆包快捷键输入校验与测试

**Files:**
- Modify: `macos/Sources/CodexRemoteMac/Input/HotkeyEmitter.swift`
- Create: `macos/Sources/CodexRemoteMac/Input/HotkeyTester.swift`
- Create: `macos/Sources/CodexRemoteMac/Audio/ReloadableAudioInputBridge.swift`
- Modify: `macos/Sources/CodexRemoteMac/App/AppSettings.swift`
- Test: `macos/Tests/CodexRemoteMacTests/HotkeyTesterTests.swift`
- Test: `macos/Tests/CodexRemoteMacTests/ReloadableAudioInputBridgeTests.swift`
- Test: `macos/Tests/CodexRemoteMacTests/AppSettingsTests.swift`

- [ ] **Step 1：写解析和测试语义失败测试**

```swift
func testParserNormalizesSupportedLettersAndSpecialKeys() throws {
    XCTAssertEqual(try HotkeyParser().parseRequired("⌘ ⇧ v").displayValue, "⌘⇧V")
    XCTAssertEqual(try HotkeyParser().parseRequired("⌥ Space").displayValue, "⌥Space")
    XCTAssertThrowsError(try HotkeyParser().parseRequired("Space"))
    XCTAssertThrowsError(try HotkeyParser().parseRequired("⌘⇧"))
}

@MainActor
func testTesterCountsDownThenSendsOneCompletePress() async throws {
    let clock = ImmediateHotkeyTestClock()
    let emitter = RecordingHotkeyEmitter(isAuthorized: true)
    let result = try await HotkeyTester(emitter: emitter, clock: clock).test("⌥Space")

    XCTAssertEqual(clock.requestedSeconds, [1, 1, 1])
    XCTAssertEqual(emitter.events, [.down(keyCode: 49), .up(keyCode: 49)])
    XCTAssertEqual(result, .eventSent(displayValue: "⌥Space"))
}
```

- [ ] **Step 2：运行测试并确认 RED**

Run: `cd macos && swift test --disable-sandbox --filter 'HotkeyTesterTests|AppSettingsTests'`

Expected: 编译失败，提示 `HotkeyTester` 或 `parseRequired` 不存在。

- [ ] **Step 3：扩展解析器并实现测试器**

解析器支持 `A...Z`、`0...9`、Space、Enter、Tab 和方向键；至少包含一个 Command、Option、Control 或 Shift 修饰键。解析结果新增 `displayValue`，设置保存标准化值。

`HotkeyTester.test` 先校验 `emitter.isAuthorized`，再倒计时三秒，最后调用一次 `keyDown` 和一次 `keyUp`。UI 文案固定为“按键事件已发送”，错误分别映射为“快捷键格式无效”“需要辅助功能权限”“按键事件发送失败”。

- [ ] **Step 4：更新设置兼容性**

`AppSettings` 保持 `Codable` 向后兼容；新增字段必须使用自定义 `init(from:)` 提供默认值，确保现有 `codexRemote.appSettings.v1` 数据仍可读取。不得持久化录音、识别文本或系统权限结果。

- [ ] **Step 5：让下一次 PTT 使用新快捷键**

```swift
@MainActor
public final class ReloadableAudioInputBridge: AudioInputHandling {
    private var current: any AudioInputHandling

    public init(current: any AudioInputHandling) { self.current = current }

    public func replace(with replacement: any AudioInputHandling) {
        current.abort()
        current = replacement
    }

    public var dependencyStatus: AudioDependencyStatus { current.dependencyStatus }
    public func begin(firstAudioSequence: UInt32) throws { try current.begin(firstAudioSequence: firstAudioSequence) }
    public func receive(_ frame: ADPCMFrame) throws { try current.receive(frame) }
    public func end(lastAudioSequence: UInt32) async throws { try await current.end(lastAudioSequence: lastAudioSequence) }
    public func abort() { current.abort() }
}
```

`AppModel` 启动时把该包装器注入 `MacClientCoordinator`；保存标准化快捷键后，以新 `BlackHoleAudioInputBridge` 替换内部 handler。测试覆盖替换前后分别路由到旧、新 fake，以及替换时中止旧事务。

- [ ] **Step 6：运行定向测试**

Run: `cd macos && swift test --disable-sandbox --filter 'HotkeyTesterTests|ReloadableAudioInputBridgeTests|AppSettingsTests'`

Expected: 快捷键解析、倒计时、取消、无权限、发送失败和旧设置解码测试全部通过。

- [ ] **Step 7：提交门禁**

授权后执行：

```bash
git add macos/Sources/CodexRemoteMac/Input/HotkeyEmitter.swift macos/Sources/CodexRemoteMac/Input/HotkeyTester.swift macos/Sources/CodexRemoteMac/Audio/ReloadableAudioInputBridge.swift macos/Sources/CodexRemoteMac/App/AppSettings.swift macos/Tests/CodexRemoteMacTests/HotkeyTesterTests.swift macos/Tests/CodexRemoteMacTests/ReloadableAudioInputBridgeTests.swift macos/Tests/CodexRemoteMacTests/AppSettingsTests.swift
git commit -m "feat(macos): 支持豆包快捷键输入测试"
```

## Task 7：接入首次启动向导和长期诊断页

**Files:**
- Create: `macos/Sources/CodexRemoteMac/Setup/MacSetupExecutor.swift`
- Create: `macos/Sources/CodexRemoteApp/SetupAssistantView.swift`
- Create: `macos/Sources/CodexRemoteApp/InstallationDiagnosticsView.swift`
- Create: `macos/Sources/CodexRemoteApp/SetupWindowController.swift`
- Modify: `macos/Sources/CodexRemoteApp/AppModel.swift`
- Modify: `macos/Sources/CodexRemoteApp/CodexRemoteApp.swift`
- Modify: `macos/Sources/CodexRemoteApp/SettingsView.swift`
- Modify: `macos/Sources/CodexRemoteApp/MenuBarContentView.swift`
- Modify: `macos/App/Info.plist`
- Modify: `macos/Scripts/package-app.zsh`

- [ ] **Step 1：给 AppModel 接入可观察状态**

`MacSetupExecutor` 使用穷举 `switch` 路由所有动作，未知动作不能静默成功：

```swift
public func execute(_ action: SetupAction) async throws {
    switch action {
    case .installApplication: try applicationInstaller.installCurrentApplication()
    case .installShimAndPath: try shellConfiguration.installCurrentApplicationShim()
    case .installHooks: try hooksConfiguration.installCurrentApplicationHook()
    case .installBlackHole: try await blackHoleInstaller.install()
    case .restoreManagedConfiguration:
        try hooksConfiguration.restore()
        try shellConfiguration.restore()
    case .requestBluetooth, .requestMicrophone, .requestAccessibility,
         .confirmHooksTrust, .testHotkey, .recheck:
        throw SetupExecutionError.requiresApplicationInteraction(action)
    }
}
```

```swift
@Published private(set) var setupSnapshot = SetupSnapshot(results: [])
@Published private(set) var setupLog: [SetupLogLine] = []
@Published private(set) var hotkeyTestState: HotkeyTestViewState = .idle

func refreshSetup() async
func runAutomaticSetup() async
func performSetupAction(_ action: SetupAction) async
func testDoubaoHotkey() async
```

`AppModel` 通过注入的 `SetupCoordinator` 更新界面。保存快捷键后重建音频输入桥接所需配置，避免继续使用启动时捕获的旧值；不得要求用户重启应用才能生效。

- [ ] **Step 2：实现复用检查清单**

`InstallationDiagnosticsView` 渲染统一的 `SetupCheckResult`：状态图标、标题、摘要、详细原因和一个主操作。`ready` 使用绿色，`waitingForUser`/`needsConfiguration` 使用琥珀色，`failed` 使用红色，`checking`/等待设备使用灰色；颜色之外必须显示图标与文字。

- [ ] **Step 3：实现四阶段向导**

`SetupAssistantView` 使用已确认草图的双栏布局：基础环境、自动配置、功能测试、完成。主按钮为“开始自动配置”或“继续配置”；用户确认弹窗必须展示将要修改的目标：

- PATH：`~/.zshrc` 和 `~/.codex-remote/bin/codex`；
- hooks：`~/.codex/hooks.json`；
- BlackHole：`brew install --cask blackhole-2ch`；
- 应用安装：`/Applications/Codex Remote.app`。

向导允许“稍后设置”。退出不缓存伪状态，下次打开重新检查。

- [ ] **Step 4：实现窗口与设置入口**

`SetupWindowController` 使用 `NSHostingController(rootView:)` 创建唯一窗口；`AppDelegate.applicationDidFinishLaunching` 启动 runtime 后执行 `refreshSetup()`，当 `isMacReady == false` 时展示该窗口。设置页改为 `TabView`，包含“常规”和“安装与诊断”；菜单栏在未就绪时显示“完成安装配置…”入口。

- [ ] **Step 5：补充权限说明与打包校验**

`Info.plist` 增加：

```xml
<key>NSMicrophoneUsageDescription</key>
<string>接收 Codex Remote 设备语音并送入用户选择的语音输入流程。</string>
```

`package-app.zsh` 在签名前检查 `Contents/Resources/codex`、`codex-remote-hook` 和 `codex-remote-hooks.json` 均存在且可读；缺失时明确失败。

- [ ] **Step 6：构建应用并检查产物**

Run:

```bash
cd macos
swift build --disable-sandbox --product codex-remote-app
zsh Scripts/package-app.zsh release /tmp/codex-remote-setup-build
codesign --verify --deep --strict "/tmp/codex-remote-setup-build/Codex Remote.app"
plutil -lint "/tmp/codex-remote-setup-build/Codex Remote.app/Contents/Info.plist"
```

Expected: 四条命令退出 0；应用包包含两个可执行文件和三项配置资源；Info.plist 同时包含蓝牙和麦克风用途说明。

- [ ] **Step 7：人工 UI smoke（不执行系统变更）**

从临时应用包启动客户端，只执行只读检查。确认首次向导、四阶段导航、七类状态、豆包输入框、测试倒计时、确认弹窗和长期诊断页可见；在确认弹窗选择“取消”，核对真实 PATH、hooks 和 BlackHole 未变化。

- [ ] **Step 8：提交门禁**

授权后执行：

```bash
git add macos/Sources/CodexRemoteApp macos/App/Info.plist macos/Scripts/package-app.zsh
git commit -m "feat(macos): 增加首次安装配置向导"
```

## Task 8：回归、文档与现场启用门禁

**Files:**
- Modify: `macos/Docs/phase-3-mac-client-verification.md`
- Modify: `docs/设备到位启用手册.md`

- [ ] **Step 1：运行全部 Mac 测试**

Run:

```bash
cd macos
swift test --parallel --disable-sandbox
swift build --disable-sandbox
zsh Tests/Scripts/codex-shim.zsh
zsh Tests/Scripts/ble-golden-fixtures.zsh
```

Expected: Swift 测试、全目标构建、shim 脚本和 BLE golden fixtures 全部退出 0。

- [ ] **Step 2：执行边界与安全扫描**

Run:

```bash
rg -n '^import (SwiftUI|AppKit|CoreBluetooth|CoreAudio|ApplicationServices)' macos/Sources/CodexRemoteCore
rg -n 'Setup|Ghostty|BlackHole|zshrc|hooks.json' macos/Sources/CodexRemoteCore/BLE macos/Sources/CodexRemoteCore/Transport macos/Fixtures/ble-v1
rg -n 'Process\(|executableURL|arguments' macos/Sources/CodexRemoteMac/Setup
git diff --check
```

Expected: 前两项无匹配；第三项能人工确认外部命令只通过 `CommandRunner` 且使用绝对路径和参数数组；`git diff --check` 退出 0。

- [ ] **Step 3：更新中文验证报告**

报告必须分开记录：

- 自动测试与构建证据；
- 临时目录中的配置写入测试；
- 只读 UI smoke；
- 尚未授权的真实 PATH、hooks 和 BlackHole 变更；
- 尚未完成的 ESP32、BLE、音频与实体键真机验收。

- [ ] **Step 4：更新设备到位启用手册**

将默认流程改为“打开 Codex Remote → 开始自动配置 → 按提示确认权限和 `/hooks` → 连接设备 → 运行综合测试”。手工命令保留在“故障排查”章节，不再作为普通安装主路径。

- [ ] **Step 5：复核工作区与 staged 范围**

Run:

```bash
git status --short
git diff --stat
git diff -- macos/Sources/CodexRemoteMac/Setup macos/Sources/CodexRemoteMac/Input macos/Sources/CodexRemoteApp macos/Tests/CodexRemoteMacTests macos/App/Info.plist macos/Scripts/package-app.zsh macos/Docs/phase-3-mac-client-verification.md docs/设备到位启用手册.md
```

Expected: 只审查本功能目标文件；不暂存或提交工作区中既有的无关改动。

- [ ] **Step 6：最终提交门禁**

只有用户明确要求提交时，逐项核对 staged diff 后执行：

```bash
git add macos/Docs/phase-3-mac-client-verification.md docs/设备到位启用手册.md
git commit -m "docs(macos): 更新一键配置验证与启用说明"
```

## 完成标准

- 首次启动向导和长期诊断页读取同一套真实检查结果。
- 一键配置按依赖执行，并在系统权限、hooks 信任和 BlackHole 安装前暂停确认。
- shim、PATH 和 hooks 操作具备备份、原子写入、幂等与受控恢复测试。
- BlackHole 安装仅调用已解析的 Homebrew 绝对路径和固定参数；Homebrew 缺失时不安装。
- 豆包快捷键支持直接输入、标准化、保存、三秒倒计时和按键发送测试。
- 快捷键修改无需重启客户端即可用于下一次 PTT。
- Mac 全量测试、构建、打包、签名校验、shim 和 BLE fixtures 通过。
- 真机未到位或未经现场授权的项目明确保留为门禁，不伪报完成。
