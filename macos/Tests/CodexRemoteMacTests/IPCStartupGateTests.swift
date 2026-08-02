import CodexRemoteCore
import CodexRemoteMac
import Foundation
import XCTest

final class IPCStartupGateTests: XCTestCase {
    func testGateBlocksRequestsUntilOpenThenReleasesAllWaitersAndIsIdempotent() async {
        let probe = StartupGateProbe()
        let gate = IPCStartupGate(onWaiterBlocked: {
            await probe.signal()
        })
        let dispatcher = StartupGateCallRecorder()

        let first = Task {
            await gate.waitUntilReady()
            await dispatcher.record("first")
        }
        let second = Task {
            await gate.waitUntilReady()
            await dispatcher.record("second")
        }

        await probe.waitForSignals(2)
        let callsBeforeOpen = await dispatcher.recordedCalls()
        XCTAssertEqual(callsBeforeOpen, [])

        await gate.open()
        await first.value
        await second.value
        let callsAfterOpen = await dispatcher.recordedCalls()
        XCTAssertEqual(Set(callsAfterOpen), ["first", "second"])

        await gate.open()
        await gate.waitUntilReady()
        await dispatcher.record("after-open")
        let callsAfterIdempotentOpen = await dispatcher.recordedCalls()
        XCTAssertEqual(callsAfterIdempotentOpen.count, 3)
    }

    func testGatedSessionStartWaitsForPendingLaunchSnapshotDrain() async throws {
        let socketURL = try makeSocketFixture()
        try await HookEventQueue().enqueue(
            .launchSnapshot(
                LaunchRegistration(
                    launcherInstanceID: "launcher-1",
                    terminalTargetID: "term-7",
                    displayTitle: "ESP32",
                    workingDirectoryLabel: "esp32"
                )
            ),
            forSocketAt: socketURL
        )

        let probe = StartupGateProbe()
        let gate = IPCStartupGate(onWaiterBlocked: {
            await probe.signal()
        })
        let directCalls = StartupGateCallRecorder()
        let service = SessionService(controller: StartupGateTerminalController(), idGenerator: { "remote-1" })
        let dispatcher = SessionIPCDispatcher(service: service)
        let sessionStart = HookPayload(
            hookEventName: "SessionStart",
            sessionID: "codex-1",
            launcherInstanceID: "launcher-1",
            message: nil,
            lastAssistantMessage: nil
        )

        let directSessionStart = Task {
            await gate.waitUntilReady()
            await directCalls.record("direct")
            return await dispatcher.handle(.hook(sessionStart))
        }

        await probe.waitForSignals(1)
        let directCallsBeforeOpen = await directCalls.recordedCalls()
        let sessionsBeforeDrain = await service.activeSessions(limit: 8)
        XCTAssertEqual(directCallsBeforeOpen, [])
        XCTAssertEqual(sessionsBeforeDrain, [])

        let drainResult = try await HookEventQueue().drain(forSocketAt: socketURL, dispatcher: dispatcher)
        XCTAssertEqual(drainResult, HookEventQueueDrainResult(consumedCount: 1, retainedCount: 0))
        let afterDrain = await service.activeSessions(limit: 8)
        XCTAssertEqual(afterDrain.first?.launcherInstanceID, "launcher-1")
        XCTAssertNil(afterDrain.first?.providerSessionID)

        await gate.open()
        let directResponse = await directSessionStart.value
        XCTAssertEqual(directResponse, .ok)

        let sessions = await service.activeSessions(limit: 8)
        let directCallsAfterOpen = await directCalls.recordedCalls()
        XCTAssertEqual(directCallsAfterOpen, ["direct"])
        XCTAssertEqual(sessions.map(\.remoteSessionID), ["remote-1"])
        XCTAssertEqual(sessions.first?.launcherInstanceID, "launcher-1")
        XCTAssertEqual(sessions.first?.providerSessionID, "codex-1")
        XCTAssertEqual(sessions.first?.terminalTargetID, "term-7")
    }

    func testOpenAfterDrainErrorStillReleasesWaitingRequests() async {
        let probe = StartupGateProbe()
        let gate = IPCStartupGate(onWaiterBlocked: {
            await probe.signal()
        })
        let dispatcher = StartupGateCallRecorder()

        let request = Task {
            await gate.waitUntilReady()
            await dispatcher.record("released")
        }

        await probe.waitForSignals(1)
        let callsBeforeOpen = await dispatcher.recordedCalls()
        XCTAssertEqual(callsBeforeOpen, [])

        await gate.open()
        await request.value

        let callsAfterOpen = await dispatcher.recordedCalls()
        XCTAssertEqual(callsAfterOpen, ["released"])
    }

    private func makeSocketFixture() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("startup-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("events.sock")
    }
}

private actor StartupGateProbe {
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signal() {
        count += 1
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    func waitForSignals(_ target: Int) async {
        if count >= target {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }
}

private actor StartupGateCallRecorder {
    private var calls: [String] = []

    func record(_ value: String) {
        calls.append(value)
    }

    func recordedCalls() -> [String] {
        calls
    }
}

private actor StartupGateTerminalController: TerminalController {
    func captureFocusedTerminal() async throws -> TerminalContext {
        throw GhosttyControllerError.noFocusedTerminal
    }

    func focus(terminalTargetID: String) async throws {}

    func scroll(deltaY: Int, terminalTargetID: String) async throws {}

    func sendKey(_ key: TerminalKey, to terminalTargetID: String) async throws {}
}
