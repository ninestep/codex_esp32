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

    func testRegisterLaunchRejectsDuplicateLauncher() async throws {
        let registry = SessionRegistry(idGenerator: IDGenerator(["remote-1", "remote-2"]).next)
        try await registry.registerLaunch(
            launcherInstanceID: "launch-1",
            terminalTargetID: "term-7",
            displayTitle: "ESP32",
            workingDirectoryLabel: "~/esp32"
        )

        do {
            try await registry.registerLaunch(
                launcherInstanceID: "launch-1",
                terminalTargetID: "term-8",
                displayTitle: "ESP32 duplicate",
                workingDirectoryLabel: "~/esp32-duplicate"
            )
            XCTFail("Expected duplicateLauncher")
        } catch {
            XCTAssertEqual(error as? SessionRegistryError, .duplicateLauncher("launch-1"))
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

    func testSessionByRemoteIDRejectsUnknownRemoteSession() async throws {
        let registry = SessionRegistry(idGenerator: { "remote-fixed" })

        do {
            _ = try await registry.session(remoteSessionID: "missing")
            XCTFail("Expected unknownRemoteSession")
        } catch {
            XCTAssertEqual(error as? SessionRegistryError, .unknownRemoteSession("missing"))
        }
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

    func testConditionalApplyUpdatesOnlyWhenCurrentStateMatchesExpected() async throws {
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
        _ = try await registry.apply(
            SessionStateResult(
                state: .completeUnread,
                statusDetail: "任务完成",
                unread: true,
                updatedAt: fixedDate
            ),
            providerSessionID: "codex-99"
        )
        let result = SessionStateResult(
            state: .idle,
            statusDetail: "",
            unread: false,
            updatedAt: fixedDate.addingTimeInterval(1)
        )

        let updated = try await registry.apply(
            result,
            providerSessionID: "codex-99",
            ifCurrentState: .completeUnread
        )

        XCTAssertEqual(updated.state, .idle)
        XCTAssertEqual(updated.statusDetail, "")
        XCTAssertFalse(updated.unread)
        XCTAssertEqual(updated.updatedAt, fixedDate.addingTimeInterval(1))
    }

    func testConditionalApplyReturnsCurrentSessionWithoutMetadataChangesWhenStateDiffers() async throws {
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
        let workingDate = fixedDate.addingTimeInterval(10)
        let current = try await registry.apply(
            SessionStateResult(
                state: .working,
                statusDetail: "Codex 正在处理",
                unread: false,
                updatedAt: workingDate
            ),
            providerSessionID: "codex-99"
        )
        let staleResult = SessionStateResult(
            state: .idle,
            statusDetail: "",
            unread: false,
            updatedAt: fixedDate.addingTimeInterval(20)
        )

        let unchanged = try await registry.apply(
            staleResult,
            providerSessionID: "codex-99",
            ifCurrentState: .completeUnread
        )

        XCTAssertEqual(unchanged, current)
        let stored = try await registry.session(providerSessionID: "codex-99")
        XCTAssertEqual(stored, current)
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

    func testActiveSessionsSortsByStatePriorityThenUpdatedAtThenRemoteID() async throws {
        let fixtures: [(String, RemoteSessionState, Date)] = [
            ("remote-idle", .idle, fixedDate.addingTimeInterval(100)),
            ("remote-requires", .requiresInput, fixedDate),
            ("remote-b", .working, fixedDate.addingTimeInterval(50)),
            ("remote-a", .working, fixedDate.addingTimeInterval(50)),
            ("remote-error", .error, fixedDate.addingTimeInterval(1)),
        ]
        let registry = SessionRegistry(idGenerator: IDGenerator(fixtures.map { $0.0 }).next)

        for (index, fixture) in fixtures.enumerated() {
            let launcherID = "launch-\(index)"
            let providerID = "codex-\(index)"
            try await registry.registerLaunch(
                launcherInstanceID: launcherID,
                terminalTargetID: "term-\(index)",
                displayTitle: fixture.0,
                workingDirectoryLabel: "~/\(fixture.0)"
            )
            _ = try await registry.bindProviderSession(
                launcherInstanceID: launcherID,
                providerSessionID: providerID
            )
            _ = try await registry.apply(
                SessionStateResult(
                    state: fixture.1,
                    statusDetail: fixture.0,
                    unread: false,
                    updatedAt: fixture.2
                ),
                providerSessionID: providerID
            )
        }

        let sessions = await registry.activeSessions(limit: fixtures.count)

        XCTAssertEqual(
            sessions.map(\.remoteSessionID),
            ["remote-error", "remote-requires", "remote-a", "remote-b", "remote-idle"]
        )
    }

    func testActiveSessionsReturnsEmptyForNonPositiveLimit() async throws {
        let registry = SessionRegistry(idGenerator: { "remote-fixed" })
        try await registry.registerLaunch(
            launcherInstanceID: "launch-1",
            terminalTargetID: "term-7",
            displayTitle: "ESP32",
            workingDirectoryLabel: "~/esp32"
        )

        let zeroLimitSessions = await registry.activeSessions(limit: 0)
        let negativeLimitSessions = await registry.activeSessions(limit: -1)

        XCTAssertEqual(zeroLimitSessions, [])
        XCTAssertEqual(negativeLimitSessions, [])
    }

    func testActiveSessionsDefaultLimitReturnsEightNewestSessions() async throws {
        let ids = (1...9).map { "remote-\($0)" }
        let registry = SessionRegistry(idGenerator: IDGenerator(ids).next)

        for index in 1...9 {
            try await registry.registerLaunch(
                launcherInstanceID: "launch-\(index)",
                terminalTargetID: "term-\(index)",
                displayTitle: "ESP32 \(index)",
                workingDirectoryLabel: "~/esp32-\(index)"
            )
            _ = try await registry.bindProviderSession(
                launcherInstanceID: "launch-\(index)",
                providerSessionID: "codex-\(index)"
            )
            _ = try await registry.apply(
                SessionStateResult(
                    state: .working,
                    statusDetail: "session \(index)",
                    unread: false,
                    updatedAt: fixedDate.addingTimeInterval(TimeInterval(index))
                ),
                providerSessionID: "codex-\(index)"
            )
        }

        let sessions = await registry.activeSessions()

        XCTAssertEqual(sessions.count, 8)
        XCTAssertEqual(sessions.map(\.remoteSessionID), (2...9).reversed().map { "remote-\($0)" })
        XCTAssertFalse(sessions.map(\.remoteSessionID).contains("remote-1"))
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
