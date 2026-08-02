import Foundation
import XCTest
@testable import CodexRemoteCore

final class SessionRegistryTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testRegisterLaunchBindsProviderToRemoteSession() async throws {
        let registry = SessionRegistry(idGenerator: { "remote-fixed" })

        try await registry.registerLaunch(
            launcherInstanceID: "launch-1",
            terminalTargetID: "term-7",
            displayTitle: "ESP32",
            workingDirectoryLabel: "~/esp32"
        )
        let session = try await registry.bindProviderSession(
            launcherInstanceID: "launch-1",
            providerSessionID: "codex-99"
        )

        XCTAssertEqual(session.remoteSessionID, "remote-fixed")
        XCTAssertEqual(session.terminalTargetID, "term-7")
        XCTAssertEqual(session.providerSessionID, "codex-99")
    }

    func testRegisterLaunchRejectsLiveTerminalAlreadyBound() async throws {
        let registry = SessionRegistry(idGenerator: IDGenerator(["remote-1", "remote-2"]).next)
        try await registry.registerLaunch(
            launcherInstanceID: "launch-1",
            terminalTargetID: "term-7",
            displayTitle: "ESP32",
            workingDirectoryLabel: "~/esp32"
        )

        do {
            try await registry.registerLaunch(
                launcherInstanceID: "launch-2",
                terminalTargetID: "term-7",
                displayTitle: "ESP32 second",
                workingDirectoryLabel: "~/esp32-second"
            )
            XCTFail("Expected terminalAlreadyBound")
        } catch let error as SessionRegistryError {
            XCTAssertEqual(error, .terminalAlreadyBound("term-7"))
        } catch {
            XCTFail("Expected SessionRegistryError, got \(error)")
        }
    }

    func testSessionByProviderIDReturnsSameRemoteSession() async throws {
        let registry = SessionRegistry(idGenerator: { "remote-fixed" })
        try await registry.registerLaunch(
            launcherInstanceID: "launch-1",
            terminalTargetID: "term-7",
            displayTitle: "ESP32",
            workingDirectoryLabel: "~/esp32"
        )
        let bound = try await registry.bindProviderSession(
            launcherInstanceID: "launch-1",
            providerSessionID: "codex-99"
        )

        let found = try await registry.session(providerSessionID: "codex-99")

        XCTAssertEqual(found, bound)
    }

    func testApplyProviderStateResultUpdatesSessionFields() async throws {
        let registry = SessionRegistry(idGenerator: { "remote-fixed" })
        try await registry.registerLaunch(
            launcherInstanceID: "launch-1",
            terminalTargetID: "term-7",
            displayTitle: "ESP32",
            workingDirectoryLabel: "~/esp32"
        )
        _ = try await registry.bindProviderSession(
            launcherInstanceID: "launch-1",
            providerSessionID: "codex-99"
        )
        let result = SessionStateResult(
            state: .working,
            statusDetail: "Codex 正在处理",
            unread: false,
            updatedAt: fixedDate
        )

        let updated = try await registry.apply(result, providerSessionID: "codex-99")

        XCTAssertEqual(updated.state, .working)
        XCTAssertEqual(updated.statusDetail, "Codex 正在处理")
        XCTAssertFalse(updated.unread)
        XCTAssertEqual(updated.updatedAt, fixedDate)
    }

    func testBindProviderRejectsUnknownLauncherAndDuplicateProvider() async throws {
        let registry = SessionRegistry(idGenerator: IDGenerator(["remote-1", "remote-2"]).next)

        do {
            _ = try await registry.bindProviderSession(
                launcherInstanceID: "missing-launcher",
                providerSessionID: "codex-99"
            )
            XCTFail("Expected unknownLauncher")
        } catch let error as SessionRegistryError {
            XCTAssertEqual(error, .unknownLauncher("missing-launcher"))
        } catch {
            XCTFail("Expected SessionRegistryError, got \(error)")
        }

        try await registry.registerLaunch(
            launcherInstanceID: "launch-1",
            terminalTargetID: "term-7",
            displayTitle: "ESP32",
            workingDirectoryLabel: "~/esp32"
        )
        try await registry.registerLaunch(
            launcherInstanceID: "launch-2",
            terminalTargetID: "term-8",
            displayTitle: "ESP32 second",
            workingDirectoryLabel: "~/esp32-second"
        )
        _ = try await registry.bindProviderSession(
            launcherInstanceID: "launch-1",
            providerSessionID: "codex-99"
        )

        do {
            _ = try await registry.bindProviderSession(
                launcherInstanceID: "launch-2",
                providerSessionID: "codex-99"
            )
            XCTFail("Expected providerAlreadyBound")
        } catch let error as SessionRegistryError {
            XCTAssertEqual(error, .providerAlreadyBound("codex-99"))
        } catch {
            XCTFail("Expected SessionRegistryError, got \(error)")
        }
    }

    func testActiveSessionsReturnsNewestSessionsWithinLimit() async throws {
        let registry = SessionRegistry(idGenerator: IDGenerator(["remote-first", "remote-second"]).next)
        try await registry.registerLaunch(
            launcherInstanceID: "launch-1",
            terminalTargetID: "term-7",
            displayTitle: "ESP32",
            workingDirectoryLabel: "~/esp32"
        )
        try await registry.registerLaunch(
            launcherInstanceID: "launch-2",
            terminalTargetID: "term-8",
            displayTitle: "ESP32 second",
            workingDirectoryLabel: "~/esp32-second"
        )
        _ = try await registry.bindProviderSession(
            launcherInstanceID: "launch-1",
            providerSessionID: "codex-1"
        )
        _ = try await registry.bindProviderSession(
            launcherInstanceID: "launch-2",
            providerSessionID: "codex-2"
        )
        _ = try await registry.apply(
            SessionStateResult(
                state: .idle,
                statusDetail: "first",
                unread: false,
                updatedAt: fixedDate
            ),
            providerSessionID: "codex-1"
        )
        _ = try await registry.apply(
            SessionStateResult(
                state: .working,
                statusDetail: "second",
                unread: false,
                updatedAt: fixedDate.addingTimeInterval(10)
            ),
            providerSessionID: "codex-2"
        )

        let sessions = await registry.activeSessions(limit: 1)

        XCTAssertEqual(sessions.map(\.remoteSessionID), ["remote-second"])
    }
}

private final class IDGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String]

    init(_ ids: [String]) {
        self.ids = ids.reversed()
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return ids.popLast() ?? "remote-extra"
    }
}
