import Foundation
import XCTest
@testable import CodexRemoteMac

final class MacSetupExecutorTests: XCTestCase {
    func testRoutesEveryAutomaticActionToItsOwnedExecutor() async throws {
        let recorder = MacSetupOperationRecorder()
        let executor = MacSetupExecutor(
            applicationInstaller: RecordingApplicationInstaller(recorder: recorder),
            shellConfiguration: RecordingShellConfiguration(recorder: recorder),
            hooksConfiguration: RecordingHooksConfiguration(recorder: recorder),
            blackHoleInstaller: RecordingBlackHoleInstaller(recorder: recorder),
            context: .test
        )

        try await executor.perform(.installApplication, for: .applicationLocation)
        try await executor.perform(.installShimAndPath, for: .shim)
        try await executor.perform(.installShimAndPath, for: .shellPath)
        try await executor.perform(.installHooks, for: .hooksConfiguration)
        try await executor.perform(.installBlackHole, for: .blackHole)
        try await executor.perform(.restoreManagedConfiguration, for: .localIPC)

        XCTAssertEqual(recorder.operations, [
            "app:/Source.app->/Applications/Codex Remote.app",
            "shell-install:/Applications/Codex Remote.app",
            "shell-install:/Applications/Codex Remote.app",
            "hooks-install:/Applications/Codex Remote.app/Contents/Resources/codex-remote-hook",
            "blackhole-install",
            "hooks-restore:/Applications/Codex Remote.app/Contents/Resources/codex-remote-hook",
            "shell-restore:/Applications/Codex Remote.app",
        ])
    }

    func testInteractiveActionsRequireApplicationInteraction() async {
        let executor = MacSetupExecutor(
            applicationInstaller: RecordingApplicationInstaller(recorder: MacSetupOperationRecorder()),
            shellConfiguration: RecordingShellConfiguration(recorder: MacSetupOperationRecorder()),
            hooksConfiguration: RecordingHooksConfiguration(recorder: MacSetupOperationRecorder()),
            blackHoleInstaller: RecordingBlackHoleInstaller(recorder: MacSetupOperationRecorder()),
            context: .test
        )
        let cases: [(SetupAction, SetupItem)] = [
            (.confirmHooksTrust, .hooksTrust),
            (.requestBluetooth, .bluetoothPermission),
            (.requestMicrophone, .microphonePermission),
            (.requestAccessibility, .accessibilityPermission),
            (.testHotkey, .doubaoHotkey),
            (.recheck, .localIPC),
        ]

        for (action, item) in cases {
            do {
                try await executor.perform(action, for: item)
                XCTFail("expected application interaction for \(action)")
            } catch {
                XCTAssertEqual(error as? SetupExecutionError, .requiresApplicationInteraction(action))
            }
        }
    }

    func testRejectsAutomaticActionForWrongItemWithoutRunningIt() async {
        let recorder = MacSetupOperationRecorder()
        let executor = MacSetupExecutor(
            applicationInstaller: RecordingApplicationInstaller(recorder: recorder),
            shellConfiguration: RecordingShellConfiguration(recorder: recorder),
            hooksConfiguration: RecordingHooksConfiguration(recorder: recorder),
            blackHoleInstaller: RecordingBlackHoleInstaller(recorder: recorder),
            context: .test
        )

        do {
            try await executor.perform(.installHooks, for: .blackHole)
            XCTFail("expected invalid target")
        } catch {
            XCTAssertEqual(error as? SetupExecutionError, .invalidTargetAction)
        }
        XCTAssertEqual(recorder.operations, [])
    }
}

private extension MacSetupExecutionContext {
    static let test = MacSetupExecutionContext(
        sourceApplicationURL: URL(fileURLWithPath: "/Source.app"),
        destinationApplicationURL: URL(fileURLWithPath: "/Applications/Codex Remote.app"),
        hookExecutableURL: URL(fileURLWithPath: "/Applications/Codex Remote.app/Contents/Resources/codex-remote-hook")
    )
}

private final class MacSetupOperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var operations: [String] {
        lock.withLock { recorded }
    }

    func append(_ operation: String) {
        lock.withLock { recorded.append(operation) }
    }
}

private struct RecordingApplicationInstaller: MacApplicationInstalling {
    let recorder: MacSetupOperationRecorder

    func install(sourceApplicationURL: URL, destinationApplicationURL: URL) throws {
        recorder.append("app:\(sourceApplicationURL.path)->\(destinationApplicationURL.path)")
    }
}

private struct RecordingShellConfiguration: MacShellConfiguring {
    let recorder: MacSetupOperationRecorder

    func install(appURL: URL) throws {
        recorder.append("shell-install:\(appURL.path)")
    }

    func restore(appURL: URL) throws {
        recorder.append("shell-restore:\(appURL.path)")
    }
}

private struct RecordingHooksConfiguration: MacHooksConfiguring {
    let recorder: MacSetupOperationRecorder

    func install(command: String) throws {
        recorder.append("hooks-install:\(command)")
    }

    func restore(command: String) throws {
        recorder.append("hooks-restore:\(command)")
    }
}

private struct RecordingBlackHoleInstaller: MacBlackHoleInstalling {
    let recorder: MacSetupOperationRecorder

    func install() async throws {
        recorder.append("blackhole-install")
    }
}
