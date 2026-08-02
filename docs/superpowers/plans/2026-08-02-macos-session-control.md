# macOS Session Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify the macOS phase-one core that maps a transparent `codex` launch to the exact Ghostty terminal, reduces Codex events into remote states, and safely focuses, scrolls, or sends Enter/Esc to that terminal.

**Architecture:** A Swift 6 package provides a platform-neutral session domain, deterministic state reducer, conservative waiting-input classifier, actor-backed registry, Unix-socket event receiver, and a Ghostty AppleScript adapter. A repository-local zsh shim and hook helper feed launch and lifecycle events into the daemon without changing the user's shell or Codex configuration during development.

**Tech Stack:** Swift 6.2, Swift Package Manager, Foundation, Network, XCTest, zsh, Ghostty 1.3.1 AppleScript, Codex CLI 0.146.0 hooks.

---

## Scope and gates

This is the first of four implementation plans derived from the approved design:

1. macOS session mapping, state recognition, and Ghostty control — this plan.
2. Versioned BLE contract, golden fixtures, and simulated device.
3. macOS CoreBluetooth, BlackHole, Doubao hotkey, image preparation, and menu-bar UI.
4. ESP-IDF firmware, LVGL UI, audio codec, keys, screensaver, and simulated integration.

The repository is not currently a Git repository. Do not initialize Git or create commits without explicit user confirmation. Full Xcode is not installed; this phase therefore uses a Swift package and Command Line Tools. Installing Xcode, installing BlackHole, changing `PATH`, installing a persistent shim, and editing `~/.codex/config.toml` remain separate approval gates.

## File map

```text
macos/
├── Package.swift
├── Sources/
│   ├── CodexRemoteCore/
│   │   ├── Domain/RemoteSession.swift
│   │   ├── Domain/SessionEvent.swift
│   │   ├── State/SessionStateReducer.swift
│   │   ├── State/WaitingInputClassifier.swift
│   │   ├── Mapping/SessionRegistry.swift
│   │   ├── Transport/LocalEvent.swift
│   │   ├── Transport/LocalEventCodec.swift
│   │   └── Terminal/TerminalController.swift
│   ├── CodexRemoteMac/
│   │   ├── Ghostty/GhosttyAppleScriptController.swift
│   │   ├── Ghostty/ProcessAppleScriptRunner.swift
│   │   ├── Socket/UnixSocketEventServer.swift
│   │   └── Service/SessionService.swift
│   └── codex-remote-helper/
│       └── main.swift
├── Tests/
│   ├── CodexRemoteCoreTests/
│   │   ├── SessionStateReducerTests.swift
│   │   ├── WaitingInputClassifierTests.swift
│   │   ├── SessionRegistryTests.swift
│   │   └── LocalEventCodecTests.swift
│   └── CodexRemoteMacTests/
│       ├── GhosttyAppleScriptControllerTests.swift
│       ├── SessionServiceTests.swift
│       └── UnixSocketEventServerTests.swift
├── Scripts/
│   ├── codex
│   └── codex-remote-hook
└── Fixtures/
    ├── hooks/session-start.json
    ├── hooks/user-prompt-submit.json
    ├── hooks/permission-request.json
    ├── hooks/stop-confirm-push.json
    └── hooks/stop-complete.json
```

Each source file has one responsibility. `CodexRemoteCore` imports no AppKit, AppleScript, CoreBluetooth, Core Audio, SwiftUI, or Ghostty-specific type. `CodexRemoteMac` owns operating-system adapters. The helper executable exposes repository-local development commands and communicates with one `SessionService` instance.

### Task 1: Scaffold the Swift package and enforce platform boundaries

**Files:**
- Create: `macos/Package.swift`
- Create: `macos/Sources/CodexRemoteCore/Domain/RemoteSession.swift`
- Create: `macos/Sources/CodexRemoteMac/Service/SessionService.swift`
- Create: `macos/Sources/codex-remote-helper/main.swift`
- Create: `macos/Tests/CodexRemoteCoreTests/ModuleBoundaryTests.swift`

- [ ] **Step 1: Write a package-boundary test**

```swift
import XCTest
@testable import CodexRemoteCore

final class ModuleBoundaryTests: XCTestCase {
    func testCoreCanConstructRemoteSessionWithoutPlatformTypes() {
        let session = RemoteSession(
            remoteSessionID: "remote-1",
            launcherInstanceID: "launch-1",
            providerSessionID: nil,
            terminalTargetID: "terminal-1",
            displayTitle: "esp32",
            workingDirectoryLabel: "esp32"
        )

        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.terminalTargetID, "terminal-1")
    }
}
```

- [ ] **Step 2: Create `Package.swift` with no third-party dependency**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexRemote",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CodexRemoteCore", targets: ["CodexRemoteCore"]),
        .library(name: "CodexRemoteMac", targets: ["CodexRemoteMac"]),
        .executable(name: "codex-remote-helper", targets: ["codex-remote-helper"]),
    ],
    targets: [
        .target(name: "CodexRemoteCore"),
        .target(name: "CodexRemoteMac", dependencies: ["CodexRemoteCore"]),
        .executableTarget(
            name: "codex-remote-helper",
            dependencies: ["CodexRemoteCore", "CodexRemoteMac"]
        ),
        .testTarget(name: "CodexRemoteCoreTests", dependencies: ["CodexRemoteCore"]),
        .testTarget(name: "CodexRemoteMacTests", dependencies: ["CodexRemoteMac", "CodexRemoteCore"]),
    ]
)
```

- [ ] **Step 3: Add the minimum domain type**

```swift
import Foundation

public enum RemoteSessionState: String, Codable, Sendable {
    case idle, working, completeUnread, requiresInput, error, offline
}

public struct RemoteSession: Codable, Equatable, Sendable {
    public let remoteSessionID: String
    public let launcherInstanceID: String
    public var providerSessionID: String?
    public let terminalTargetID: String
    public var displayTitle: String
    public var workingDirectoryLabel: String
    public var state: RemoteSessionState
    public var statusDetail: String
    public var unread: Bool
    public var updatedAt: Date

    public init(
        remoteSessionID: String,
        launcherInstanceID: String,
        providerSessionID: String?,
        terminalTargetID: String,
        displayTitle: String,
        workingDirectoryLabel: String,
        state: RemoteSessionState = .idle,
        statusDetail: String = "",
        unread: Bool = false,
        updatedAt: Date = .now
    ) {
        self.remoteSessionID = remoteSessionID
        self.launcherInstanceID = launcherInstanceID
        self.providerSessionID = providerSessionID
        self.terminalTargetID = terminalTargetID
        self.displayTitle = displayTitle
        self.workingDirectoryLabel = workingDirectoryLabel
        self.state = state
        self.statusDetail = statusDetail
        self.unread = unread
        self.updatedAt = updatedAt
    }
}
```

- [ ] **Step 4: Add the minimum compilable service and executable entry point**

`SessionService.swift`:

```swift
import CodexRemoteCore

public actor SessionService {
    public init() {}
}
```

`main.swift`:

```swift
import Foundation

FileHandle.standardError.write(Data("codex-remote-helper: command required\n".utf8))
exit(64)
```

- [ ] **Step 5: Run the first build and test**

Run: `cd macos && swift test --parallel`

Expected: build succeeds and `ModuleBoundaryTests.testCoreCanConstructRemoteSessionWithoutPlatformTypes` passes.

- [ ] **Step 6: Record the review checkpoint**

Run: `find macos -type f -not -path '*/.build/*' -print | sort`

Expected: only the five planned files exist. If the user separately authorizes Git initialization and commits, use `git add macos/Package.swift macos/Sources macos/Tests/CodexRemoteCoreTests/ModuleBoundaryTests.swift` and commit message `feat(mac): 建立会话控制核心包`.

### Task 2: Implement deterministic state reduction

**Files:**
- Create: `macos/Sources/CodexRemoteCore/Domain/SessionEvent.swift`
- Create: `macos/Sources/CodexRemoteCore/State/SessionStateReducer.swift`
- Create: `macos/Tests/CodexRemoteCoreTests/SessionStateReducerTests.swift`
- Modify: `macos/Sources/CodexRemoteCore/Domain/RemoteSession.swift`

- [ ] **Step 1: Write failing reducer tests**

```swift
import XCTest
@testable import CodexRemoteCore

final class SessionStateReducerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testPromptStartsWorkAndPermissionRequiresInput() {
        let reducer = SessionStateReducer()
        let working = reducer.reduce(.userPromptSubmitted, from: .idle, at: now)
        let waiting = reducer.reduce(.permissionRequested("允许执行？"), from: working.state, at: now)

        XCTAssertEqual(working.state, .working)
        XCTAssertEqual(waiting.state, .requiresInput)
        XCTAssertEqual(waiting.statusDetail, "允许执行？")
    }

    func testNormalStopBecomesUnreadAndViewingClearsIt() {
        let reducer = SessionStateReducer()
        let complete = reducer.reduce(.stopped(.normal("任务完成")), from: .working, at: now)
        let viewed = reducer.reduce(.detailViewed, from: complete.state, at: now)

        XCTAssertEqual(complete.state, .completeUnread)
        XCTAssertTrue(complete.unread)
        XCTAssertEqual(viewed.state, .idle)
        XCTAssertFalse(viewed.unread)
    }

    func testFatalFailureWinsOverWorking() {
        let result = SessionStateReducer().reduce(.failed("进程退出 1"), from: .working, at: now)
        XCTAssertEqual(result.state, .error)
        XCTAssertEqual(result.statusDetail, "进程退出 1")
    }
}
```

- [ ] **Step 2: Run the focused test and confirm failure**

Run: `cd macos && swift test --filter SessionStateReducerTests`

Expected: compile fails because `SessionEvent` and `SessionStateReducer` do not exist.

- [ ] **Step 3: Define source-aware events**

```swift
import Foundation

public enum StopReason: Equatable, Sendable {
    case normal(String)
    case blockingInput(String)
}

public enum SessionEvent: Equatable, Sendable {
    case sessionStarted
    case userPromptSubmitted
    case permissionRequested(String)
    case structuredWaiting(String)
    case stopped(StopReason)
    case detailViewed
    case failed(String)
    case disconnected(String)
}

public struct SessionStateResult: Equatable, Sendable {
    public let state: RemoteSessionState
    public let statusDetail: String
    public let unread: Bool
    public let updatedAt: Date
}
```

- [ ] **Step 4: Implement the pure reducer**

```swift
public struct SessionStateReducer: Sendable {
    public init() {}

    public func reduce(
        _ event: SessionEvent,
        from current: RemoteSessionState,
        at date: Date = .now
    ) -> SessionStateResult {
        switch event {
        case .sessionStarted:
            return result(.idle, "会话已连接", false, date)
        case .userPromptSubmitted:
            return result(.working, "Codex 正在处理", false, date)
        case let .permissionRequested(detail), let .structuredWaiting(detail):
            return result(.requiresInput, detail, false, date)
        case let .stopped(.blockingInput(detail)):
            return result(.requiresInput, detail, false, date)
        case let .stopped(.normal(detail)):
            return result(.completeUnread, detail, true, date)
        case .detailViewed:
            return result(current == .completeUnread ? .idle : current, "", false, date)
        case let .failed(detail):
            return result(.error, detail, false, date)
        case let .disconnected(detail):
            return result(.offline, detail, false, date)
        }
    }

    private func result(
        _ state: RemoteSessionState,
        _ detail: String,
        _ unread: Bool,
        _ date: Date
    ) -> SessionStateResult {
        SessionStateResult(
            state: state,
            statusDetail: String(detail.prefix(120)),
            unread: unread,
            updatedAt: date
        )
    }
}
```

- [ ] **Step 5: Run reducer tests**

Run: `cd macos && swift test --filter SessionStateReducerTests`

Expected: all three reducer tests pass.

- [ ] **Step 6: Run the package suite**

Run: `cd macos && swift test --parallel`

Expected: all tests pass with zero warnings from project sources.

### Task 3: Classify blocking assistant messages conservatively

**Files:**
- Create: `macos/Sources/CodexRemoteCore/State/WaitingInputClassifier.swift`
- Create: `macos/Tests/CodexRemoteCoreTests/WaitingInputClassifierTests.swift`

- [ ] **Step 1: Write positive and negative examples**

```swift
import XCTest
@testable import CodexRemoteCore

final class WaitingInputClassifierTests: XCTestCase {
    private let classifier = WaitingInputClassifier()

    func testBlockingConfirmationIsAmber() {
        let text = "如确认该远程仓库可信并授权推送，请回复“确认推送”，我会继续推送到 origin/master。"
        XCTAssertEqual(classifier.classify(text), .blocking(text))
    }

    func testChoiceRequiredIsAmber() {
        let text = "需要你选择 A 或 B 后才能继续。"
        XCTAssertEqual(classifier.classify(text), .blocking(text))
    }

    func testOptionalOfferIsNormalCompletion() {
        let text = "任务已经完成。如果你愿意，我也可以继续优化。"
        XCTAssertEqual(classifier.classify(text), .normal(text))
    }

    func testQuestionInsideCompletedExplanationIsNormal() {
        let text = "这里解释了为什么会失败，但当前修改已经完成。"
        XCTAssertEqual(classifier.classify(text), .normal(text))
    }
}
```

- [ ] **Step 2: Confirm the classifier tests fail**

Run: `cd macos && swift test --filter WaitingInputClassifierTests`

Expected: compile fails because `WaitingInputClassifier` does not exist.

- [ ] **Step 3: Implement the two-condition classifier**

```swift
public enum WaitingInputClassification: Equatable, Sendable {
    case blocking(String)
    case normal(String)
}

public struct WaitingInputClassifier: Sendable {
    private let replySignals = ["请回复", "请确认", "需要你选择", "请选择", "请提供", "请授权"]
    private let pauseSignals = ["我会继续", "才能继续", "后继续", "再继续", "之后继续"]
    private let optionalSignals = ["如果你愿意", "如有需要", "也可以继续优化"]

    public init() {}

    public func classify(_ text: String) -> WaitingInputClassification {
        let summary = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let optional = optionalSignals.contains { text.contains($0) }
        let asksForReply = replySignals.contains { text.contains($0) }
        let pausesWork = pauseSignals.contains { text.contains($0) }

        return asksForReply && pausesWork && !optional ? .blocking(summary) : .normal(summary)
    }
}
```

- [ ] **Step 4: Run classifier tests**

Run: `cd macos && swift test --filter WaitingInputClassifierTests`

Expected: all four examples pass, including the exact “确认推送” sentence.

- [ ] **Step 5: Run the complete core suite**

Run: `cd macos && swift test --filter CodexRemoteCoreTests`

Expected: reducer, classifier, and module-boundary tests pass.

### Task 4: Build the three-part session registry

**Files:**
- Create: `macos/Sources/CodexRemoteCore/Mapping/SessionRegistry.swift`
- Create: `macos/Tests/CodexRemoteCoreTests/SessionRegistryTests.swift`

- [ ] **Step 1: Write mapping and conflict tests**

```swift
import XCTest
@testable import CodexRemoteCore

final class SessionRegistryTests: XCTestCase {
    func testBindsTerminalLauncherAndProviderSession() async throws {
        let registry = SessionRegistry(idGenerator: { "remote-fixed" })
        try await registry.registerLaunch(
            launcherInstanceID: "launch-1",
            terminalTargetID: "term-7",
            displayTitle: "esp32",
            workingDirectoryLabel: "esp32"
        )
        let session = try await registry.bindProviderSession(
            launcherInstanceID: "launch-1",
            providerSessionID: "codex-99"
        )

        XCTAssertEqual(session.remoteSessionID, "remote-fixed")
        XCTAssertEqual(session.terminalTargetID, "term-7")
        XCTAssertEqual(session.providerSessionID, "codex-99")
    }

    func testRejectsTerminalAlreadyOwnedByAnotherLiveLaunch() async throws {
        let registry = SessionRegistry(idGenerator: { UUID().uuidString })
        try await registry.registerLaunch(
            launcherInstanceID: "launch-1",
            terminalTargetID: "term-7",
            displayTitle: "one",
            workingDirectoryLabel: "one"
        )

        await XCTAssertThrowsErrorAsync {
            try await registry.registerLaunch(
                launcherInstanceID: "launch-2",
                terminalTargetID: "term-7",
                displayTitle: "two",
                workingDirectoryLabel: "two"
            )
        }
    }
}
```

Add this async XCTest helper at the bottom of the test file:

```swift
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
```

- [ ] **Step 2: Confirm the registry tests fail**

Run: `cd macos && swift test --filter SessionRegistryTests`

Expected: compile fails because `SessionRegistry` does not exist.

- [ ] **Step 3: Implement explicit indexing and conflict rejection**

```swift
import Foundation

public enum SessionRegistryError: Error, Equatable {
    case duplicateLauncher(String)
    case terminalAlreadyBound(String)
    case unknownLauncher(String)
    case providerAlreadyBound(String)
    case unknownRemoteSession(String)
}

public actor SessionRegistry {
    private var sessionsByRemoteID: [String: RemoteSession] = [:]
    private var remoteIDByLauncher: [String: String] = [:]
    private var remoteIDByTerminal: [String: String] = [:]
    private var remoteIDByProvider: [String: String] = [:]
    private let idGenerator: @Sendable () -> String

    public init(idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.idGenerator = idGenerator
    }

    public func registerLaunch(
        launcherInstanceID: String,
        terminalTargetID: String,
        displayTitle: String,
        workingDirectoryLabel: String
    ) throws {
        guard remoteIDByLauncher[launcherInstanceID] == nil else {
            throw SessionRegistryError.duplicateLauncher(launcherInstanceID)
        }
        guard remoteIDByTerminal[terminalTargetID] == nil else {
            throw SessionRegistryError.terminalAlreadyBound(terminalTargetID)
        }

        let remoteID = idGenerator()
        let session = RemoteSession(
            remoteSessionID: remoteID,
            launcherInstanceID: launcherInstanceID,
            providerSessionID: nil,
            terminalTargetID: terminalTargetID,
            displayTitle: displayTitle,
            workingDirectoryLabel: workingDirectoryLabel
        )
        sessionsByRemoteID[remoteID] = session
        remoteIDByLauncher[launcherInstanceID] = remoteID
        remoteIDByTerminal[terminalTargetID] = remoteID
    }

    public func bindProviderSession(
        launcherInstanceID: String,
        providerSessionID: String
    ) throws -> RemoteSession {
        guard let remoteID = remoteIDByLauncher[launcherInstanceID],
              var session = sessionsByRemoteID[remoteID] else {
            throw SessionRegistryError.unknownLauncher(launcherInstanceID)
        }
        guard remoteIDByProvider[providerSessionID] == nil else {
            throw SessionRegistryError.providerAlreadyBound(providerSessionID)
        }
        session.providerSessionID = providerSessionID
        sessionsByRemoteID[remoteID] = session
        remoteIDByProvider[providerSessionID] = remoteID
        return session
    }

    public func session(remoteSessionID: String) throws -> RemoteSession {
        guard let session = sessionsByRemoteID[remoteSessionID] else {
            throw SessionRegistryError.unknownRemoteSession(remoteSessionID)
        }
        return session
    }

    public func session(providerSessionID: String) throws -> RemoteSession {
        guard let remoteID = remoteIDByProvider[providerSessionID],
              let session = sessionsByRemoteID[remoteID] else {
            throw SessionRegistryError.unknownRemoteSession(providerSessionID)
        }
        return session
    }

    public func apply(_ result: SessionStateResult, providerSessionID: String) throws -> RemoteSession {
        guard let remoteID = remoteIDByProvider[providerSessionID],
              var session = sessionsByRemoteID[remoteID] else {
            throw SessionRegistryError.unknownRemoteSession(providerSessionID)
        }
        session.state = result.state
        session.statusDetail = result.statusDetail
        session.unread = result.unread
        session.updatedAt = result.updatedAt
        sessionsByRemoteID[remoteID] = session
        return session
    }

    public func activeSessions(limit: Int = 8) -> [RemoteSession] {
        Array(sessionsByRemoteID.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }
}
```

- [ ] **Step 4: Run registry tests**

Run: `cd macos && swift test --filter SessionRegistryTests`

Expected: both tests pass and Swift concurrency emits no actor-isolation error.

- [ ] **Step 5: Run all core tests**

Run: `cd macos && swift test --filter CodexRemoteCoreTests`

Expected: all core tests pass.

### Task 5: Define terminal operations and the Ghostty AppleScript adapter

**Files:**
- Create: `macos/Sources/CodexRemoteCore/Terminal/TerminalController.swift`
- Create: `macos/Sources/CodexRemoteMac/Ghostty/ProcessAppleScriptRunner.swift`
- Create: `macos/Sources/CodexRemoteMac/Ghostty/GhosttyAppleScriptController.swift`
- Create: `macos/Tests/CodexRemoteMacTests/GhosttyAppleScriptControllerTests.swift`

- [ ] **Step 1: Write exact-script generation tests with a fake runner**

```swift
import XCTest
import CodexRemoteCore
@testable import CodexRemoteMac

final class GhosttyAppleScriptControllerTests: XCTestCase {
    func testEnterTargetsExactTerminalID() async throws {
        let runner = RecordingAppleScriptRunner(result: "ok")
        let controller = GhosttyAppleScriptController(runner: runner)

        try await controller.sendKey(.enter, to: "term-42")

        let script = await runner.lastScript
        XCTAssertTrue(script.contains("terminal id \"term-42\""))
        XCTAssertTrue(script.contains("send key \"enter\""))
    }

    func testScrollUsesPreciseSignedDelta() async throws {
        let runner = RecordingAppleScriptRunner(result: "ok")
        let controller = GhosttyAppleScriptController(runner: runner)

        try await controller.scroll(deltaY: -12, terminalTargetID: "term-42")

        let script = await runner.lastScript
        XCTAssertTrue(script.contains("send mouse scroll x 0 y -12 precision true"))
    }
}

actor RecordingAppleScriptRunner: AppleScriptRunning {
    private(set) var lastScript = ""
    private let result: String

    init(result: String) { self.result = result }

    func run(_ source: String) async throws -> String {
        lastScript = source
        return result
    }
}
```

- [ ] **Step 2: Confirm the adapter tests fail**

Run: `cd macos && swift test --filter GhosttyAppleScriptControllerTests`

Expected: compile fails because terminal and AppleScript adapter types do not exist.

- [ ] **Step 3: Define the platform-neutral port**

```swift
public enum TerminalKey: String, Codable, Sendable {
    case enter
    case escape
}

public struct TerminalContext: Equatable, Sendable {
    public let terminalTargetID: String
    public let workingDirectory: String
    public let displayTitle: String

    public init(terminalTargetID: String, workingDirectory: String, displayTitle: String) {
        self.terminalTargetID = terminalTargetID
        self.workingDirectory = workingDirectory
        self.displayTitle = displayTitle
    }
}

public protocol TerminalController: Sendable {
    func captureFocusedTerminal() async throws -> TerminalContext
    func focus(terminalTargetID: String) async throws
    func scroll(deltaY: Int, terminalTargetID: String) async throws
    func sendKey(_ key: TerminalKey, to terminalTargetID: String) async throws
}
```

- [ ] **Step 4: Implement the process runner without shell interpolation**

```swift
import Foundation

public protocol AppleScriptRunning: Sendable {
    func run(_ source: String) async throws -> String
}

public struct ProcessAppleScriptRunner: AppleScriptRunning {
    public init() {}

    public func run(_ source: String) async throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw GhosttyControllerError.appleScriptFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 5: Implement targeted Ghostty commands**

```swift
import CodexRemoteCore
import Foundation

public enum GhosttyControllerError: Error, Equatable {
    case noFocusedTerminal
    case invalidTerminalID
    case appleScriptFailed(String)
}

public struct GhosttyAppleScriptController: TerminalController {
    private let runner: any AppleScriptRunning

    public init(runner: any AppleScriptRunning = ProcessAppleScriptRunner()) {
        self.runner = runner
    }

    public func captureFocusedTerminal() async throws -> TerminalContext {
        let value = try await runner.run(Self.captureScript)
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, !fields[0].isEmpty else { throw GhosttyControllerError.noFocusedTerminal }
        return TerminalContext(terminalTargetID: fields[0], workingDirectory: fields[1], displayTitle: fields[2])
    }

    public func focus(terminalTargetID: String) async throws {
        _ = try await runner.run(Self.targetScript(terminalTargetID, command: "focus targetTerm"))
    }

    public func scroll(deltaY: Int, terminalTargetID: String) async throws {
        _ = try await runner.run(Self.targetScript(
            terminalTargetID,
            command: "send mouse scroll x 0 y \(deltaY) precision true to targetTerm"
        ))
    }

    public func sendKey(_ key: TerminalKey, to terminalTargetID: String) async throws {
        _ = try await runner.run(Self.targetScript(
            terminalTargetID,
            command: "send key \"\(key.rawValue)\" to targetTerm"
        ))
    }

    private static let captureScript = """
    tell application "Ghostty"
        if frontmost is false then error "Ghostty is not frontmost"
        set targetTab to selected tab of front window
        set targetTerm to focused terminal of targetTab
        return (id of targetTerm) & tab & (working directory of targetTerm) & tab & (name of targetTerm)
    end tell
    """

    private static func targetScript(_ id: String, command: String) -> String {
        precondition(!id.contains("\"") && !id.contains("\\"), "invalid terminal ID")
        return """
        tell application "Ghostty"
            set targetTerm to first terminal whose id is "\(id)"
            \(command)
        end tell
        """
    }
}
```

- [ ] **Step 6: Run adapter tests and all package tests**

Run: `cd macos && swift test --filter GhosttyAppleScriptControllerTests && swift test --parallel`

Expected: script-generation tests and the whole suite pass. The tests must not open or manipulate Ghostty because they use the recording runner.

### Task 6: Define and decode local launch/hook events

**Files:**
- Create: `macos/Sources/CodexRemoteCore/Transport/LocalEvent.swift`
- Create: `macos/Sources/CodexRemoteCore/Transport/LocalEventCodec.swift`
- Create: `macos/Tests/CodexRemoteCoreTests/LocalEventCodecTests.swift`
- Create: `macos/Fixtures/hooks/session-start.json`
- Create: `macos/Fixtures/hooks/user-prompt-submit.json`
- Create: `macos/Fixtures/hooks/permission-request.json`
- Create: `macos/Fixtures/hooks/stop-confirm-push.json`
- Create: `macos/Fixtures/hooks/stop-complete.json`

- [ ] **Step 1: Add sanitized fixtures from the approved state contract**

`session-start.json`:

```json
{"hook_event_name":"SessionStart","session_id":"codex-99","cwd":"/workspace/esp32","env":{"CODEX_REMOTE_INSTANCE_ID":"launch-1"}}
```

`user-prompt-submit.json`:

```json
{"hook_event_name":"UserPromptSubmit","session_id":"codex-99","cwd":"/workspace/esp32"}
```

`permission-request.json`:

```json
{"hook_event_name":"PermissionRequest","session_id":"codex-99","cwd":"/workspace/esp32","message":"允许执行受保护操作？"}
```

`stop-confirm-push.json`:

```json
{"hook_event_name":"Stop","session_id":"codex-99","cwd":"/workspace/esp32","last_assistant_message":"如确认该远程仓库可信并授权推送，请回复“确认推送”，我会继续推送到 origin/master。"}
```

`stop-complete.json`:

```json
{"hook_event_name":"Stop","session_id":"codex-99","cwd":"/workspace/esp32","last_assistant_message":"修改已完成，相关测试通过。"}
```

- [ ] **Step 2: Write codec tests**

```swift
import XCTest
@testable import CodexRemoteCore

final class LocalEventCodecTests: XCTestCase {
    func testLaunchRoundTrip() throws {
        let event = LocalEvent.launchRegistered(.init(
            launcherInstanceID: "launch-1",
            terminalTargetID: "term-7",
            workingDirectory: "/workspace/esp32",
            displayTitle: "esp32"
        ))
        XCTAssertEqual(try LocalEventCodec().decode(LocalEventCodec().encode(event)), event)
    }

    func testRejectsOversizedFrame() {
        let data = Data(repeating: 0, count: LocalEventCodec.maximumFrameBytes + 1)
        XCTAssertThrowsError(try LocalEventCodec().decode(data))
    }
}
```

- [ ] **Step 3: Confirm codec tests fail**

Run: `cd macos && swift test --filter LocalEventCodecTests`

Expected: compile fails because local event types do not exist.

- [ ] **Step 4: Define the bounded local event contract**

```swift
public struct LaunchRegistration: Codable, Equatable, Sendable {
    public let launcherInstanceID: String
    public let terminalTargetID: String
    public let workingDirectory: String
    public let displayTitle: String

    public init(launcherInstanceID: String, terminalTargetID: String, workingDirectory: String, displayTitle: String) {
        self.launcherInstanceID = launcherInstanceID
        self.terminalTargetID = terminalTargetID
        self.workingDirectory = workingDirectory
        self.displayTitle = displayTitle
    }
}

public struct HookPayload: Codable, Equatable, Sendable {
    public let hookEventName: String
    public let sessionID: String
    public let launcherInstanceID: String?
    public let message: String?
    public let lastAssistantMessage: String?

    public init(
        hookEventName: String,
        sessionID: String,
        launcherInstanceID: String?,
        message: String?,
        lastAssistantMessage: String?
    ) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.launcherInstanceID = launcherInstanceID
        self.message = message
        self.lastAssistantMessage = lastAssistantMessage
    }
}

public enum LocalEvent: Codable, Equatable, Sendable {
    case launchRegistered(LaunchRegistration)
    case hookReceived(HookPayload)
}
```

- [ ] **Step 5: Implement newline-free JSON framing with a hard size cap**

```swift
import Foundation

public enum LocalEventCodecError: Error, Equatable {
    case frameTooLarge(Int)
}

public struct LocalEventCodec: Sendable {
    public static let maximumFrameBytes = 64 * 1024
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {}

    public func encode(_ event: LocalEvent) throws -> Data {
        let data = try encoder.encode(event)
        guard data.count <= Self.maximumFrameBytes else { throw LocalEventCodecError.frameTooLarge(data.count) }
        return data
    }

    public func decode(_ data: Data) throws -> LocalEvent {
        guard data.count <= Self.maximumFrameBytes else { throw LocalEventCodecError.frameTooLarge(data.count) }
        return try decoder.decode(LocalEvent.self, from: data)
    }
}
```

- [ ] **Step 6: Run codec and full core tests**

Run: `cd macos && swift test --filter LocalEventCodecTests && swift test --filter CodexRemoteCoreTests`

Expected: codec round-trip and oversize rejection pass; all core tests remain green.

### Task 7: Route local events through the session service

**Files:**
- Modify: `macos/Sources/CodexRemoteMac/Service/SessionService.swift`
- Create: `macos/Tests/CodexRemoteMacTests/SessionServiceTests.swift`

- [ ] **Step 1: Write an integration-style service test with a fake terminal**

```swift
import XCTest
import CodexRemoteCore
@testable import CodexRemoteMac

final class SessionServiceTests: XCTestCase {
    func testLaunchHookThenEnterTargetsSameTerminal() async throws {
        let terminal = RecordingTerminalController(
            context: .init(terminalTargetID: "term-7", workingDirectory: "/workspace/esp32", displayTitle: "esp32")
        )
        let service = SessionService(terminalController: terminal, idGenerator: { "remote-1" })

        try await service.registerFocusedLaunch(launcherInstanceID: "launch-1")
        try await service.receiveHook(.init(
            hookEventName: "SessionStart",
            sessionID: "codex-99",
            launcherInstanceID: "launch-1",
            message: nil,
            lastAssistantMessage: nil
        ))
        try await service.sendKey(.enter, remoteSessionID: "remote-1")

        let keys = await terminal.keys
        let targetIDs = await terminal.targetIDs
        XCTAssertEqual(keys, [.enter])
        XCTAssertEqual(targetIDs, ["term-7"])
    }
}

actor RecordingTerminalController: TerminalController {
    let context: TerminalContext
    private(set) var keys: [TerminalKey] = []
    private(set) var targetIDs: [String] = []

    init(context: TerminalContext) { self.context = context }
    func captureFocusedTerminal() async throws -> TerminalContext { context }
    func focus(terminalTargetID: String) async throws { targetIDs.append(terminalTargetID) }
    func scroll(deltaY: Int, terminalTargetID: String) async throws { targetIDs.append(terminalTargetID) }
    func sendKey(_ key: TerminalKey, to terminalTargetID: String) async throws {
        keys.append(key)
        targetIDs.append(terminalTargetID)
    }
}
```

- [ ] **Step 2: Confirm the service test fails**

Run: `cd macos && swift test --filter SessionServiceTests`

Expected: compile fails because `SessionService` lacks the tested initializer and methods.

- [ ] **Step 3: Implement service orchestration**

```swift
import CodexRemoteCore
import Foundation

public actor SessionService {
    private let registry: SessionRegistry
    private let terminalController: any TerminalController
    private let reducer = SessionStateReducer()
    private let classifier = WaitingInputClassifier()

    public init(
        terminalController: any TerminalController,
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.terminalController = terminalController
        self.registry = SessionRegistry(idGenerator: idGenerator)
    }

    public func registerFocusedLaunch(launcherInstanceID: String) async throws {
        let context = try await terminalController.captureFocusedTerminal()
        try await registry.registerLaunch(
            launcherInstanceID: launcherInstanceID,
            terminalTargetID: context.terminalTargetID,
            displayTitle: context.displayTitle,
            workingDirectoryLabel: URL(fileURLWithPath: context.workingDirectory).lastPathComponent
        )
    }

    public func receiveHook(_ payload: HookPayload) async throws {
        if payload.hookEventName == "SessionStart", let launcher = payload.launcherInstanceID {
            let session = try await registry.bindProviderSession(
                launcherInstanceID: launcher,
                providerSessionID: payload.sessionID
            )
            let result = reducer.reduce(.sessionStarted, from: session.state)
            _ = try await registry.apply(result, providerSessionID: payload.sessionID)
            return
        }

        let session = try await registry.session(providerSessionID: payload.sessionID)
        let event: SessionEvent
        switch payload.hookEventName {
        case "UserPromptSubmit":
            event = .userPromptSubmitted
        case "PermissionRequest":
            event = .permissionRequested(payload.message ?? "Codex 需要确认")
        case "Stop":
            let message = payload.lastAssistantMessage ?? "Codex 已完成"
            switch classifier.classify(message) {
            case let .blocking(summary): event = .stopped(.blockingInput(summary))
            case let .normal(summary): event = .stopped(.normal(summary))
            }
        default:
            return
        }
        let result = reducer.reduce(event, from: session.state)
        _ = try await registry.apply(result, providerSessionID: payload.sessionID)
    }

    public func sendKey(_ key: TerminalKey, remoteSessionID: String) async throws {
        let session = try await registry.session(remoteSessionID: remoteSessionID)
        try await terminalController.focus(terminalTargetID: session.terminalTargetID)
        try await terminalController.sendKey(key, to: session.terminalTargetID)
    }

    public func scroll(deltaY: Int, remoteSessionID: String) async throws {
        let session = try await registry.session(remoteSessionID: remoteSessionID)
        try await terminalController.scroll(deltaY: deltaY, terminalTargetID: session.terminalTargetID)
    }
}
```

- [ ] **Step 4: Run service tests**

Run: `cd macos && swift test --filter SessionServiceTests`

Expected: the launch, hook binding, focus, and Enter path passes through the same `term-7` target.

- [ ] **Step 5: Add fixture-driven routing assertions**

Decode the five JSON files under `macos/Fixtures/hooks` into `HookPayload`, feed them to one `SessionService`, and assert this exact sequence:

```swift
XCTAssertEqual(states, [
    .idle,
    .working,
    .requiresInput,
    .requiresInput,
    .completeUnread,
])
```

Add a separate payload with `sessionID: "unknown"` and assert `SessionRegistryError.unknownRemoteSession("unknown")`. The test must obtain states through a `SessionService.session(providerSessionID:)` read method that delegates to the registry; do not expose the registry itself.

```swift
public func session(providerSessionID: String) async throws -> RemoteSession {
    try await registry.session(providerSessionID: providerSessionID)
}
```

Run: `cd macos && swift test --filter SessionServiceTests`

Expected: every approved lifecycle transition passes, and an unknown launcher fails explicitly instead of binding by working directory.

### Task 8: Add the Unix-domain socket boundary

**Files:**
- Create: `macos/Sources/CodexRemoteMac/Socket/UnixSocketEventServer.swift`
- Create: `macos/Tests/CodexRemoteMacTests/UnixSocketEventServerTests.swift`

- [ ] **Step 1: Write socket lifecycle tests using a temporary directory**

```swift
import XCTest
@testable import CodexRemoteMac

final class UnixSocketEventServerTests: XCTestCase {
    func testCreatesSocketWithOwnerOnlyPermissionsAndRemovesItOnStop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketURL = directory.appendingPathComponent("events.sock")
        let server = UnixSocketEventServer(socketURL: socketURL) { _ in }

        try await server.start()
        let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }
}
```

- [ ] **Step 2: Confirm the socket test fails**

Run: `cd macos && swift test --filter UnixSocketEventServerTests`

Expected: compile fails because `UnixSocketEventServer` does not exist.

- [ ] **Step 3: Implement one-frame-per-connection Unix socket handling**

Use `Network.NWListener` with `NWEndpoint.unix(path:)`. Accept at most 64 KiB, decode exactly one `LocalEvent`, call the async handler, send a compact success/error JSON response, and close the connection. After listener start, call `chmod(socketURL.path, S_IRUSR | S_IWUSR)`. On stop, cancel the listener and unlink only the exact socket path supplied to the initializer.

The public surface must be:

```swift
public actor UnixSocketEventServer {
    public typealias Handler = @Sendable (LocalEvent) async throws -> Void

    public init(socketURL: URL, handler: @escaping Handler)
    public func start() async throws
    public func stop() async
}
```

Do not add retry loops, disk queues, daemonization, or launch agents in this task. A failed helper call must exit nonzero and preserve the error text.

- [ ] **Step 4: Run socket and package tests**

Run: `cd macos && swift test --filter UnixSocketEventServerTests && swift test --parallel`

Expected: socket permissions and cleanup pass; the complete package suite passes.

### Task 9: Implement repository-local helper commands, shim, and hook bridge

**Files:**
- Modify: `macos/Sources/codex-remote-helper/main.swift`
- Create: `macos/Scripts/codex`
- Create: `macos/Scripts/codex-remote-hook`
- Create: `macos/Tests/CodexRemoteMacTests/HelperCommandTests.swift`
- Create: `macos/Tests/Scripts/codex-shim.zsh`

- [ ] **Step 1: Specify helper commands in tests**

Test these invocations against a temporary socket and fake terminal controller:

```text
codex-remote-helper serve --socket /tmp/.../events.sock
codex-remote-helper register-launch --socket /tmp/.../events.sock --launcher launch-1
codex-remote-helper hook --socket /tmp/.../events.sock
codex-remote-helper list --socket /tmp/.../events.sock --json
codex-remote-helper focus --socket /tmp/.../events.sock --session remote-1
codex-remote-helper scroll --socket /tmp/.../events.sock --session remote-1 --delta -12
codex-remote-helper key --socket /tmp/.../events.sock --session remote-1 --key enter
codex-remote-helper key --socket /tmp/.../events.sock --session remote-1 --key escape
```

Assert exit code `64` for missing arguments, `65` for malformed JSON, `69` when the daemon is unavailable, and `0` only after a positive daemon response.

- [ ] **Step 2: Implement manual argument parsing with no new dependency**

Create a `HelperCommand` enum and parse only the flags listed above. Read hook JSON from standard input, map the official hook field names into `HookPayload`, and reject an event without `hook_event_name` or `session_id`. Print machine-readable JSON to stdout for `list`; print diagnostics to stderr for every nonzero exit.

Run: `cd macos && swift test --filter HelperCommandTests`

Expected: all command parsing and exit-code tests pass.

- [ ] **Step 3: Write the transparent repository-local `codex` shim**

```zsh
#!/bin/zsh
set -u

script_dir=${0:A:h}
helper=${CODEX_REMOTE_HELPER:-"${script_dir:h}/.build/debug/codex-remote-helper"}
real_codex=${CODEX_REMOTE_REAL_CODEX:-$(whence -p codex)}
socket_path=${CODEX_REMOTE_SOCKET:-"${TMPDIR%/}/codex-remote-$UID/events.sock"}
launcher_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

if [[ -x "$helper" ]]; then
  "$helper" register-launch --socket "$socket_path" --launcher "$launcher_id" || \
    print -u2 "codex-remote: 当前会话未加入远程控制，Codex 仍将正常启动"
else
  print -u2 "codex-remote: helper 不可用，Codex 仍将正常启动"
fi

if [[ -z "$real_codex" || "$real_codex" == "$0" ]]; then
  print -u2 "codex-remote: 找不到真实 codex 可执行文件"
  exit 127
fi

export CODEX_REMOTE_INSTANCE_ID=$launcher_id
exec "$real_codex" "$@"
```

During tests, always set `CODEX_REMOTE_REAL_CODEX` to a fake executable. Do not prepend `macos/Scripts` to the user's persistent `PATH`.

- [ ] **Step 4: Write the hook bridge**

```zsh
#!/bin/zsh
set -u

script_dir=${0:A:h}
helper=${CODEX_REMOTE_HELPER:-"${script_dir:h}/.build/debug/codex-remote-helper"}
socket_path=${CODEX_REMOTE_SOCKET:-"${TMPDIR%/}/codex-remote-$UID/events.sock"}

if [[ ! -x "$helper" ]]; then
  print -u2 "codex-remote-hook: helper 不可用"
  exit 69
fi

exec "$helper" hook --socket "$socket_path"
```

The helper must obtain `CODEX_REMOTE_INSTANCE_ID` from its environment when the hook JSON omits it. Do not log the complete assistant message; log only event name, session ID, classification, and bounded summary length.

- [ ] **Step 5: Test argument forwarding and fallback behavior**

The zsh test must create a fake `codex` that records its arguments, run the shim with `exec --model test-model "prompt with spaces"`, and assert that the fake process receives the three original arguments unchanged. It must also point the helper to a missing file and assert that the real fake Codex still runs with a warning.

Run: `zsh macos/Tests/Scripts/codex-shim.zsh`

Expected: exit `0`, exact argument equality, environment contains a UUID-like `CODEX_REMOTE_INSTANCE_ID`, and missing helper does not fake registration success.

- [ ] **Step 6: Run the complete automated phase-one suite**

Run: `cd macos && swift test --parallel && cd .. && zsh macos/Tests/Scripts/codex-shim.zsh`

Expected: all Swift and zsh tests pass.

### Task 10: Run controlled live Ghostty and Codex smoke tests

**Files:**
- Create: `macos/Docs/phase-1-verification.md`
- Modify: `docs/superpowers/specs/2026-08-02-codex-remote-control-design.md` only if live behavior disproves a stated assumption

- [ ] **Step 1: Capture the environment without changing it**

Run:

```bash
swift --version
xcode-select -p
codex --version
/Applications/Ghostty.app/Contents/MacOS/ghostty +version
```

Expected on the current machine: Swift 6.2.1, Command Line Tools active, Codex CLI 0.146.0, and Ghostty 1.3.1. Record actual output in `macos/Docs/phase-1-verification.md`; never copy expected values when the command differs.

- [ ] **Step 2: Build the helper and start the repository-local service**

Run: `cd macos && swift build`

Then run the helper in a dedicated terminal using an explicit socket under a `mktemp -d` directory. Keep that directory path in a task-specific variable such as `codex_remote_tmp`; do not use or overwrite `HOME`.

Expected: the socket appears with mode `0600`, and `list --json` returns an empty session array.

- [ ] **Step 3: Verify targeted Ghostty operations on disposable terminals**

Open two disposable Ghostty tabs manually, each running `read -r` or another harmless waiting command. Capture both terminal IDs. Send scroll, Enter, and Esc to one ID and verify the other terminal receives no input. Then focus each target by ID.

Expected: every operation affects exactly the selected terminal. If Ghostty rejects `send key "escape"`, inspect the installed scripting dictionary and update the adapter and tests to the actual supported key name before continuing.

- [ ] **Step 4: Verify same-directory sessions do not collide**

In two Ghostty tabs with the same working directory, launch Codex through the repository-local shim by setting `PATH` only for each test command invocation. Submit distinct harmless prompts and inspect `list --json`.

Expected: two remote sessions have different launcher, provider, and terminal IDs even though their working-directory labels match.

- [ ] **Step 5: Verify status transitions with real hooks only after explicit config approval**

Before this step, present the exact temporary Codex hook configuration and its rollback to the user. After approval, back up only the affected config file, install the repository-local hook command, run idle → working → complete, permission request, and “确认推送” scenarios, then restore the original config.

Expected: white → blue → green for normal completion; amber for structured permission and blocking confirmation; optional completion offers stay green. If approval is not granted, record this step as blocked by configuration authorization and retain the fixture-based test evidence.

- [ ] **Step 6: Record evidence and residual risk**

Write `macos/Docs/phase-1-verification.md` with:

```markdown
# Phase 1 Verification

## Environment
## Automated tests
## Ghostty live targeting
## Codex hook lifecycle
## Authorization-gated checks
## Failures and fixes
## Residual risks
## Phase 2 go/no-go
```

Record commands, exit codes, test counts, exact unverified items, and whether persistent configuration was restored. Do not mark phase one complete if exact terminal targeting, same-directory separation, or the approved status classifier fails.

### Task 11: Phase-one completion review

**Files:**
- Modify: `macos/Docs/phase-1-verification.md`
- Modify: `docs/superpowers/specs/2026-08-02-codex-remote-control-design.md` only for evidence-backed corrections

- [ ] **Step 1: Run fresh verification**

Run: `cd macos && swift test --parallel && swift build && cd .. && zsh macos/Tests/Scripts/codex-shim.zsh`

Expected: every command exits `0`. Quote the final test count and build result from this fresh run.

- [ ] **Step 2: Scan for prohibited coupling and sensitive output**

Run:

```bash
rg -n "import (AppKit|SwiftUI|CoreBluetooth|CoreAudio)|Ghostty|AppleScript" macos/Sources/CodexRemoteCore
rg -n "last_assistant_message|prompt|transcript" macos/Sources macos/Tests
```

Expected: the first search returns no matches. The second returns only bounded decoding/classification code and sanitized fixtures; no runtime logging prints complete prompt, transcript, or assistant text.

- [ ] **Step 3: Check the approved spec against phase-one evidence**

Confirm that the implementation proves:

- `terminal_target_id ↔ launcher_instance_id ↔ provider_session_id` without cwd guessing.
- same-directory concurrent sessions remain distinct.
- Enter/Esc use targeted Ghostty `send key` and never auto-retry.
- blocking “确认推送” becomes `requiresInput`; optional offers do not.
- the shim forwards arguments, streams, and the real Codex exit code.
- no persistent shell or Codex config remains changed after verification.

- [ ] **Step 4: Stop at the phase gate**

Present the evidence report to the user. Request separate approval before any of these actions: initialize Git, commit files, install Xcode, modify persistent shell/Codex configuration, add a third-party dependency, install BlackHole, or begin the shared BLE contract plan.

Do not start phase two merely because phase-one unit tests pass. Phase two starts after the user accepts the phase-one live evidence or explicitly accepts a documented unverified constraint.
