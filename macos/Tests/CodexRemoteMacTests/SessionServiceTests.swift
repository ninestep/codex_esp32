import Foundation
import XCTest
@testable import CodexRemoteCore
@testable import CodexRemoteMac

final class SessionServiceTests: XCTestCase {
    func testSendKeyFocusesCapturedLaunchTerminalBeforeSendingKey() async throws {
        let controller = RecordingTerminalController()
        let service = SessionService(controller: controller, idGenerator: { "remote-1" })

        let registered = try await service.registerFocusedLaunch(launcherInstanceID: "launch-1")
        XCTAssertEqual(registered.remoteSessionID, "remote-1")
        XCTAssertEqual(registered.terminalTargetID, "term-7")
        XCTAssertEqual(registered.workingDirectoryLabel, "esp32")
        await controller.resetEvents()

        _ = try await service.receiveHook(sessionStart("codex-99", launcherInstanceID: "launch-1"))
        try await service.sendKey(.enter, remoteSessionID: "remote-1")

        let events = await controller.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .focus("term-7"),
                .key(.enter, "term-7"),
            ]
        )
    }

    func testScrollTargetsBoundTerminalWithoutRefocusing() async throws {
        let controller = RecordingTerminalController()
        let service = SessionService(controller: controller, idGenerator: { "remote-1" })
        _ = try await service.registerFocusedLaunch(launcherInstanceID: "launch-1")
        _ = try await service.receiveHook(sessionStart("codex-99", launcherInstanceID: "launch-1"))
        await controller.resetEvents()

        try await service.scroll(deltaY: -12, remoteSessionID: "remote-1")

        let events = await controller.recordedEvents()
        XCTAssertEqual(events, [.scroll(-12, "term-7")])
    }

    func testNormalizedHooksDriveSessionStateSequence() async throws {
        let service = SessionService(controller: RecordingTerminalController(), idGenerator: { "remote-1" })
        _ = try await service.registerFocusedLaunch(launcherInstanceID: "launch-1")

        _ = try await service.receiveHook(sessionStart("codex-99", launcherInstanceID: "launch-1"))
        try await assertSession(service, providerSessionID: "codex-99", state: .idle, detail: "会话已连接", unread: false)

        _ = try await service.receiveHook(prompt("codex-99"))
        try await assertSession(service, providerSessionID: "codex-99", state: .working, detail: "Codex 正在处理", unread: false)

        _ = try await service.receiveHook(permission("codex-99", message: "允许执行 git push？"))
        try await assertSession(
            service,
            providerSessionID: "codex-99",
            state: .requiresInput,
            detail: "允许执行 git push？",
            unread: false
        )

        _ = try await service.receiveHook(stop("codex-99", assistantMessage: "如确认该远程仓库可信并授权推送，请回复“确认推送”，我会继续推送到 origin/master。"))
        try await assertSession(
            service,
            providerSessionID: "codex-99",
            state: .requiresInput,
            detail: "如确认该远程仓库可信并授权推送，请回复“确认推送”，我会继续推送到 origin/master。",
            unread: false
        )

        _ = try await service.receiveHook(prompt("codex-99"))
        _ = try await service.receiveHook(stop("codex-99", assistantMessage: "任务完成"))
        try await assertSession(service, providerSessionID: "codex-99", state: .completeUnread, detail: "任务完成", unread: true)
    }

    func testExactConfirmationStopRequiresInput() async throws {
        let service = SessionService(controller: RecordingTerminalController(), idGenerator: { "remote-1" })
        _ = try await service.registerFocusedLaunch(launcherInstanceID: "launch-1")
        _ = try await service.receiveHook(sessionStart("codex-99", launcherInstanceID: "launch-1"))

        let updated = try await service.receiveHook(stop("codex-99", assistantMessage: "确认后我会继续执行。"))

        XCTAssertEqual(updated?.state, .requiresInput)
        XCTAssertEqual(updated?.statusDetail, "确认后我会继续执行。")
        XCTAssertFalse(updated?.unread ?? true)
    }

    func testPermissionRequestPrefersCurrentMessageWhenAssistantMessageAlsoExists() async throws {
        let service = SessionService(controller: RecordingTerminalController(), idGenerator: { "remote-1" })
        _ = try await service.registerFocusedLaunch(launcherInstanceID: "launch-1")
        _ = try await service.receiveHook(sessionStart("codex-99", launcherInstanceID: "launch-1"))

        let updated = try await service.receiveHook(
            HookPayload(
                hookEventName: "PermissionRequest",
                sessionID: "codex-99",
                launcherInstanceID: nil,
                message: "当前权限请求",
                lastAssistantMessage: "上一条回复"
            )
        )

        XCTAssertEqual(updated?.state, .requiresInput)
        XCTAssertEqual(updated?.statusDetail, "当前权限请求")
    }

    func testStopPrefersLastAssistantMessageWhenMessageAlsoExists() async throws {
        let service = SessionService(controller: RecordingTerminalController(), idGenerator: { "remote-1" })
        _ = try await service.registerFocusedLaunch(launcherInstanceID: "launch-1")
        _ = try await service.receiveHook(sessionStart("codex-99", launcherInstanceID: "launch-1"))

        let updated = try await service.receiveHook(
            HookPayload(
                hookEventName: "Stop",
                sessionID: "codex-99",
                launcherInstanceID: nil,
                message: "当前 hook message",
                lastAssistantMessage: "最终回复"
            )
        )

        XCTAssertEqual(updated?.state, .completeUnread)
        XCTAssertEqual(updated?.statusDetail, "最终回复")
    }

    func testUnknownProviderPromptAndUnknownLauncherStartThrowExactRegistryErrors() async throws {
        let service = SessionService(controller: RecordingTerminalController(), idGenerator: { "remote-1" })

        do {
            _ = try await service.receiveHook(prompt("unknown"))
            XCTFail("Expected unknownRemoteSession")
        } catch {
            XCTAssertEqual(error as? SessionRegistryError, .unknownRemoteSession("unknown"))
        }

        do {
            _ = try await service.receiveHook(sessionStart("codex-99", launcherInstanceID: "missing-launcher"))
            XCTFail("Expected unknownLauncher")
        } catch {
            XCTAssertEqual(error as? SessionRegistryError, .unknownLauncher("missing-launcher"))
        }
    }

    func testSessionStartWithoutLauncherThrowsServiceError() async throws {
        let service = SessionService(controller: RecordingTerminalController(), idGenerator: { "remote-1" })

        do {
            _ = try await service.receiveHook(sessionStart("codex-99", launcherInstanceID: nil))
            XCTFail("Expected launcherInstanceMissing")
        } catch {
            XCTAssertEqual(error as? SessionServiceError, .launcherInstanceMissing("codex-99"))
        }
    }

    func testSelectCompleteUnreadFocusesAndMarksDetailViewed() async throws {
        let controller = RecordingTerminalController()
        let service = SessionService(controller: controller, idGenerator: { "remote-1" })
        _ = try await service.registerFocusedLaunch(launcherInstanceID: "launch-1")
        _ = try await service.receiveHook(sessionStart("codex-99", launcherInstanceID: "launch-1"))
        _ = try await service.receiveHook(stop("codex-99", assistantMessage: "任务完成"))
        await controller.resetEvents()

        let selected = try await service.selectSession(remoteSessionID: "remote-1")

        let events = await controller.recordedEvents()
        XCTAssertEqual(events, [.focus("term-7")])
        XCTAssertEqual(selected.state, .idle)
        XCTAssertEqual(selected.statusDetail, "")
        XCTAssertFalse(selected.unread)
    }

    func testSelectRequiresInputOnlyFocusesAndPreservesDetail() async throws {
        let controller = RecordingTerminalController()
        let service = SessionService(controller: controller, idGenerator: { "remote-1" })
        _ = try await service.registerFocusedLaunch(launcherInstanceID: "launch-1")
        _ = try await service.receiveHook(sessionStart("codex-99", launcherInstanceID: "launch-1"))
        _ = try await service.receiveHook(permission("codex-99", message: "允许执行？"))
        await controller.resetEvents()

        let selected = try await service.selectSession(remoteSessionID: "remote-1")

        let events = await controller.recordedEvents()
        XCTAssertEqual(events, [.focus("term-7")])
        XCTAssertEqual(selected.state, .requiresInput)
        XCTAssertEqual(selected.statusDetail, "允许执行？")
        XCTAssertFalse(selected.unread)
    }

    func testSelectCompleteUnreadDoesNotOverwriteNewWorkingStateWhenFocusSuspends() async throws {
        let controller = BlockingFocusTerminalController()
        let service = SessionService(controller: controller, idGenerator: { "remote-1" })
        _ = try await service.registerFocusedLaunch(launcherInstanceID: "launch-1")
        _ = try await service.receiveHook(sessionStart("codex-99", launcherInstanceID: "launch-1"))
        _ = try await service.receiveHook(stop("codex-99", assistantMessage: "任务完成"))

        let selectTask = Task {
            try await service.selectSession(remoteSessionID: "remote-1")
        }
        await controller.waitForBlockedFocus()

        _ = try await service.receiveHook(prompt("codex-99"))
        await controller.releaseFocus()
        let selected = try await selectTask.value
        let stored = try await service.session(providerSessionID: "codex-99")

        XCTAssertEqual(selected.state, .working)
        XCTAssertEqual(selected.statusDetail, "Codex 正在处理")
        XCTAssertFalse(selected.unread)
        XCTAssertEqual(stored.state, .working)
        XCTAssertEqual(stored.statusDetail, "Codex 正在处理")
        XCTAssertFalse(stored.unread)
    }

    func testUnsupportedHookDoesNotChangeExistingSession() async throws {
        let service = SessionService(controller: RecordingTerminalController(), idGenerator: { "remote-1" })
        _ = try await service.registerFocusedLaunch(launcherInstanceID: "launch-1")
        _ = try await service.receiveHook(sessionStart("codex-99", launcherInstanceID: "launch-1"))
        _ = try await service.receiveHook(permission("codex-99", message: "允许执行？"))
        let before = try await service.session(providerSessionID: "codex-99")

        let result = try await service.receiveHook(
            HookPayload(
                hookEventName: "UnknownHook",
                sessionID: "codex-99",
                launcherInstanceID: nil,
                message: "ignored",
                lastAssistantMessage: "ignored"
            )
        )
        let after = try await service.session(providerSessionID: "codex-99")

        XCTAssertNil(result)
        XCTAssertEqual(after, before)
    }

    func testUnboundRegisteredLaunchCanBeSelectedBeforeSessionStart() async throws {
        let controller = RecordingTerminalController()
        let service = SessionService(controller: controller, idGenerator: { "remote-1" })
        _ = try await service.registerFocusedLaunch(launcherInstanceID: "launch-1")
        await controller.resetEvents()

        let selected = try await service.selectSession(remoteSessionID: "remote-1")
        let events = await controller.recordedEvents()

        XCTAssertEqual(selected.remoteSessionID, "remote-1")
        XCTAssertNil(selected.providerSessionID)
        XCTAssertEqual(events, [.focus("term-7")])
    }

    func testUnboundRegisteredLaunchAllowsTerminalControlsBeforeSessionStart() async throws {
        let controller = RecordingTerminalController()
        let service = SessionService(controller: controller, idGenerator: { "remote-1" })
        _ = try await service.registerFocusedLaunch(launcherInstanceID: "launch-1")
        await controller.resetEvents()

        try await service.sendKey(.enter, remoteSessionID: "remote-1")
        try await service.scroll(deltaY: 120, remoteSessionID: "remote-1")

        let events = await controller.recordedEvents()
        XCTAssertEqual(events, [
            .focus("term-7"),
            .key(.enter, "term-7"),
            .scroll(120, "term-7"),
        ])
    }

    private func assertSession(
        _ service: SessionService,
        providerSessionID: String,
        state: RemoteSessionState,
        detail: String,
        unread: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let session = try await service.session(providerSessionID: providerSessionID)
        XCTAssertEqual(session.state, state, file: file, line: line)
        XCTAssertEqual(session.statusDetail, detail, file: file, line: line)
        XCTAssertEqual(session.unread, unread, file: file, line: line)
    }
}

private func sessionStart(_ sessionID: String, launcherInstanceID: String?) -> HookPayload {
    HookPayload(
        hookEventName: "SessionStart",
        sessionID: sessionID,
        launcherInstanceID: launcherInstanceID,
        message: nil,
        lastAssistantMessage: nil
    )
}

private func prompt(_ sessionID: String) -> HookPayload {
    HookPayload(
        hookEventName: "UserPromptSubmit",
        sessionID: sessionID,
        launcherInstanceID: nil,
        message: nil,
        lastAssistantMessage: nil
    )
}

private func permission(_ sessionID: String, message: String) -> HookPayload {
    HookPayload(
        hookEventName: "PermissionRequest",
        sessionID: sessionID,
        launcherInstanceID: nil,
        message: message,
        lastAssistantMessage: nil
    )
}

private func stop(_ sessionID: String, assistantMessage: String) -> HookPayload {
    HookPayload(
        hookEventName: "Stop",
        sessionID: sessionID,
        launcherInstanceID: nil,
        message: nil,
        lastAssistantMessage: assistantMessage
    )
}

private actor RecordingTerminalController: TerminalController {
    enum Event: Equatable, Sendable {
        case capture
        case focus(String)
        case scroll(Int, String)
        case key(TerminalKey, String)
    }

    private(set) var events: [Event] = []
    private let context: TerminalContext

    init(
        context: TerminalContext = TerminalContext(
            terminalTargetID: "term-7",
            workingDirectory: "/Users/wj/data/mcp/esp32",
            displayTitle: "ESP32"
        )
    ) {
        self.context = context
    }

    func resetEvents() {
        events = []
    }

    func recordedEvents() -> [Event] {
        events
    }

    func captureFocusedTerminal() async throws -> TerminalContext {
        events.append(.capture)
        return context
    }

    func focus(terminalTargetID: String) async throws {
        events.append(.focus(terminalTargetID))
    }

    func scroll(deltaY: Int, terminalTargetID: String) async throws {
        events.append(.scroll(deltaY, terminalTargetID))
    }

    func sendKey(_ key: TerminalKey, to terminalTargetID: String) async throws {
        events.append(.key(key, terminalTargetID))
    }
}

private actor BlockingFocusTerminalController: TerminalController {
    private let context: TerminalContext
    private var focusContinuation: CheckedContinuation<Void, Never>?
    private var focusStartedContinuation: CheckedContinuation<Void, Never>?
    private var focusIsBlocked = false

    init(
        context: TerminalContext = TerminalContext(
            terminalTargetID: "term-7",
            workingDirectory: "/Users/wj/data/mcp/esp32",
            displayTitle: "ESP32"
        )
    ) {
        self.context = context
    }

    func waitForBlockedFocus() async {
        if focusIsBlocked {
            return
        }
        await withCheckedContinuation { continuation in
            focusStartedContinuation = continuation
        }
    }

    func releaseFocus() {
        focusContinuation?.resume()
        focusContinuation = nil
    }

    func captureFocusedTerminal() async throws -> TerminalContext {
        context
    }

    func focus(terminalTargetID: String) async throws {
        await withCheckedContinuation { continuation in
            focusContinuation = continuation
            focusIsBlocked = true
            focusStartedContinuation?.resume()
            focusStartedContinuation = nil
        }
    }

    func scroll(deltaY: Int, terminalTargetID: String) async throws {}

    func sendKey(_ key: TerminalKey, to terminalTargetID: String) async throws {}
}
