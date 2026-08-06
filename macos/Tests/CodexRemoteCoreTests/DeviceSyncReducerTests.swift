import Foundation
import XCTest
@testable import CodexRemoteCore

final class DeviceSyncReducerTests: XCTestCase {
    func testCompatibleConnectionSendsSnapshotThenStrictlyOrderedDelta() {
        var reducer = DeviceSyncReducer()
        let idle = makeSession(id: "remote-1", state: .idle, updatedAt: 1)
        reducer.updateSessions([idle])

        XCTAssertEqual(reducer.connect(remoteVersion: .current), [
            .stateSnapshot(generation: 1, sessions: [makeDeviceSession(key: 1, state: .idle, updatedAt: 1)]),
        ])
        XCTAssertEqual(reducer.connectionState, .ready(generation: 1, lastDeltaSequence: 0))
        XCTAssertTrue(reducer.updateSessions([idle]).isEmpty)

        let working = makeSession(id: "remote-1", state: .working, updatedAt: 2)
        XCTAssertEqual(reducer.updateSessions([working]), [
            .stateDelta(generation: 1, sequence: 1, session: makeDeviceSession(key: 1, state: .working, updatedAt: 2)),
        ])
        XCTAssertEqual(reducer.connectionState, .ready(generation: 1, lastDeltaSequence: 1))
    }

    func testMembershipChangeUsesNewGenerationSnapshotAndStableKeys() {
        var reducer = DeviceSyncReducer()
        let first = makeSession(id: "remote-1", state: .idle, updatedAt: 1)
        let second = makeSession(id: "remote-2", state: .requiresInput, updatedAt: 2)
        reducer.updateSessions([first])
        _ = reducer.connect(remoteVersion: .current)

        XCTAssertEqual(reducer.updateSessions([second, first]), [
            .stateSnapshot(generation: 2, sessions: [
                makeDeviceSession(key: 2, state: .requiresInput, updatedAt: 2),
                makeDeviceSession(key: 1, state: .idle, updatedAt: 1),
            ]),
        ])
        XCTAssertEqual(reducer.connectionState, .ready(generation: 2, lastDeltaSequence: 0))
    }

    func testResyncAndReconnectSendLatestProjection() {
        var reducer = DeviceSyncReducer()
        let session = makeSession(id: "remote-1", state: .working, updatedAt: 3)
        reducer.updateSessions([session])
        _ = reducer.connect(remoteVersion: .current)

        XCTAssertEqual(reducer.resync(), [
            .stateSnapshot(generation: 2, sessions: [makeDeviceSession(key: 1, state: .working, updatedAt: 3)]),
        ])
        reducer.disconnect()
        XCTAssertEqual(reducer.connectionState, .disconnected)
        XCTAssertTrue(reducer.updateSessions([session]).isEmpty)
        XCTAssertEqual(reducer.connect(remoteVersion: .current), [
            .stateSnapshot(generation: 1, sessions: [makeDeviceSession(key: 1, state: .working, updatedAt: 3)]),
        ])
    }

    func testIncompatibleMajorRejectsSynchronization() {
        var reducer = DeviceSyncReducer()
        reducer.updateSessions([makeSession(id: "remote-1", state: .idle, updatedAt: 1)])

        XCTAssertTrue(reducer.connect(remoteVersion: BLEProtocolVersion(major: 2, minor: 0)).isEmpty)
        XCTAssertEqual(reducer.connectionState, .incompatible(remoteMajor: 2))
        XCTAssertTrue(reducer.resync().isEmpty)
    }

    func testResolvesPublicSessionKeysWithoutExposingTerminalIdentifiers() {
        var reducer = DeviceSyncReducer()
        reducer.updateSessions([makeSession(id: "remote-1", state: .idle, updatedAt: 1)])
        _ = reducer.connect(remoteVersion: .current)

        XCTAssertEqual(reducer.remoteSessionID(for: 1), "remote-1")
        XCTAssertEqual(reducer.sessionKey(for: "remote-1"), 1)
        XCTAssertNil(reducer.remoteSessionID(for: 99))
    }

    private func makeSession(id: String, state: RemoteSessionState, updatedAt: TimeInterval) -> RemoteSession {
        RemoteSession(
            remoteSessionID: id,
            launcherInstanceID: "launch-\(id)",
            providerSessionID: "provider-\(id)",
            terminalTargetID: "terminal-\(id)",
            displayTitle: id,
            workingDirectoryLabel: "esp32",
            state: state,
            statusDetail: state.rawValue,
            unread: state == .completeUnread,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private func makeDeviceSession(key: UInt16, state: DeviceSessionState, updatedAt: UInt64) -> DeviceSession {
        DeviceSession(
            sessionKey: key,
            displayTitle: "remote-\(key)",
            workingDirectoryLabel: "esp32",
            state: state,
            statusDetail: state == .requiresInput ? "requiresInput" : state == .working ? "working" : "idle",
            unread: false,
            capabilities: [.scroll, .terminalKeys, .ptt, .navigationKeys, .terminalShortcuts],
            updatedAtMilliseconds: updatedAt * 1_000
        )
    }
}
