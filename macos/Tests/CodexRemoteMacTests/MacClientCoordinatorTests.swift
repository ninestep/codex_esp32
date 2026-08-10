import CodexRemoteCore
import Foundation
import XCTest
@testable import CodexRemoteMac

@MainActor
final class MacClientCoordinatorTests: XCTestCase {
    func testDeviceInfoStartsSessionSnapshot() async throws {
        let session = makeSession(id: "remote-1", state: .working)
        let service = SessionClientSpy(sessions: [session])
        let transport = BluetoothTransportSpy(maximumWriteValueLength: 64)
        let coordinator = MacClientCoordinator(sessionClient: service, transport: transport)

        try await coordinator.receive(message: .deviceInfo(deviceInfo()))

        let messages = try transport.decodedMessages()
        XCTAssertEqual(messages, [
            .stateSnapshot(generation: 1, sessions: [DeviceSession(
                remoteSession: session,
                sessionKey: 1,
                capabilities: [.scroll, .terminalKeys, .ptt, .navigationKeys, .terminalShortcuts]
            )]),
        ])
    }

    func testSelectFocusesSessionAndReturnsSuccess() async throws {
        let service = SessionClientSpy(sessions: [makeSession(id: "remote-1")])
        let transport = BluetoothTransportSpy(maximumWriteValueLength: 64)
        let coordinator = MacClientCoordinator(sessionClient: service, transport: transport)
        try await coordinator.receive(message: .deviceInfo(deviceInfo()))
        transport.removeAllPackets()

        try await coordinator.receive(message: .selectSession(requestID: 11, sessionKey: 1))

        let selectedSessionIDs = await service.selectedSessionIDs()
        XCTAssertEqual(selectedSessionIDs, ["remote-1"])
        XCTAssertEqual(try transport.decodedMessages(), [
            .actionResult(requestID: 11, result: .success, detail: ""),
        ])
    }

    func testTerminalKeyRequiresSelectedSessionAndMapsAllSupportedKeys() async throws {
        let service = SessionClientSpy(sessions: [makeSession(id: "remote-1")])
        let transport = BluetoothTransportSpy(maximumWriteValueLength: 64)
        let coordinator = MacClientCoordinator(sessionClient: service, transport: transport)
        try await coordinator.receive(message: .deviceInfo(deviceInfo()))
        transport.removeAllPackets()

        try await coordinator.receive(message: .terminalKey(requestID: 20, sessionKey: 1, key: .enter))
        try await coordinator.receive(message: .selectSession(requestID: 21, sessionKey: 1))
        try await coordinator.receive(message: .terminalKey(requestID: 22, sessionKey: 1, key: .enter))
        try await coordinator.receive(message: .terminalKey(requestID: 23, sessionKey: 1, key: .escape))
        try await coordinator.receive(message: .terminalKey(requestID: 24, sessionKey: 1, key: .up))
        try await coordinator.receive(message: .terminalKey(requestID: 25, sessionKey: 1, key: .down))
        try await coordinator.receive(message: .terminalKey(requestID: 26, sessionKey: 1, key: .left))
        try await coordinator.receive(message: .terminalKey(requestID: 27, sessionKey: 1, key: .right))
        try await coordinator.receive(message: .terminalKey(requestID: 28, sessionKey: 1, key: .backspace))
        try await coordinator.receive(message: .terminalKey(requestID: 29, sessionKey: 1, key: .clearLine))

        let sentKeys = await service.sentKeys()
        XCTAssertEqual(sentKeys, [
            SentKey(key: .enter, remoteSessionID: "remote-1"),
            SentKey(key: .escape, remoteSessionID: "remote-1"),
            SentKey(key: .up, remoteSessionID: "remote-1"),
            SentKey(key: .down, remoteSessionID: "remote-1"),
            SentKey(key: .left, remoteSessionID: "remote-1"),
            SentKey(key: .right, remoteSessionID: "remote-1"),
            SentKey(key: .backspace, remoteSessionID: "remote-1"),
            SentKey(key: .clearLine, remoteSessionID: "remote-1"),
        ])
        XCTAssertEqual(try transport.decodedMessages(), [
            .actionResult(requestID: 20, result: .invalidState, detail: "请先进入会话"),
            .actionResult(requestID: 21, result: .success, detail: ""),
            .actionResult(requestID: 22, result: .success, detail: ""),
            .actionResult(requestID: 23, result: .success, detail: ""),
            .actionResult(requestID: 24, result: .success, detail: ""),
            .actionResult(requestID: 25, result: .success, detail: ""),
            .actionResult(requestID: 26, result: .success, detail: ""),
            .actionResult(requestID: 27, result: .success, detail: ""),
            .actionResult(requestID: 28, result: .success, detail: ""),
            .actionResult(requestID: 29, result: .success, detail: ""),
        ])
    }

    func testTerminalShortcutRequiresSelectedSessionAndMapsFixedCommand() async throws {
        let service = SessionClientSpy(sessions: [makeSession(id: "remote-1")])
        let transport = BluetoothTransportSpy(maximumWriteValueLength: 64)
        let coordinator = MacClientCoordinator(sessionClient: service, transport: transport)
        try await coordinator.receive(message: .deviceInfo(deviceInfo()))
        transport.removeAllPackets()

        try await coordinator.receive(message: .terminalShortcut(requestID: 28, sessionKey: 1, shortcut: .plan))
        try await coordinator.receive(message: .selectSession(requestID: 29, sessionKey: 1))
        try await coordinator.receive(message: .terminalShortcut(requestID: 30, sessionKey: 1, shortcut: .plan))

        let sentShortcuts = await service.sentShortcuts()
        XCTAssertEqual(sentShortcuts, [
            SentShortcut(shortcut: .plan, remoteSessionID: "remote-1"),
        ])
        XCTAssertEqual(try transport.decodedMessages(), [
            .actionResult(requestID: 28, result: .invalidState, detail: "请先进入会话"),
            .actionResult(requestID: 29, result: .success, detail: ""),
            .actionResult(requestID: 30, result: .success, detail: ""),
        ])
    }

    func testDuplicateRequestReturnsCachedResultWithoutRepeatingAction() async throws {
        let service = SessionClientSpy(sessions: [makeSession(id: "remote-1")])
        let transport = BluetoothTransportSpy(maximumWriteValueLength: 64)
        let coordinator = MacClientCoordinator(sessionClient: service, transport: transport)
        try await coordinator.receive(message: .deviceInfo(deviceInfo()))
        transport.removeAllPackets()

        try await coordinator.receive(message: .selectSession(requestID: 30, sessionKey: 1))
        try await coordinator.receive(message: .selectSession(requestID: 30, sessionKey: 1))

        let selectedSessionIDs = await service.selectedSessionIDs()
        XCTAssertEqual(selectedSessionIDs, ["remote-1"])
        XCTAssertEqual(try transport.decodedMessages(), [
            .actionResult(requestID: 30, result: .success, detail: ""),
            .actionResult(requestID: 30, result: .success, detail: ""),
        ])
    }

    func testSelectedSessionScrollIgnoresDuplicateSequence() async throws {
        let service = SessionClientSpy(sessions: [makeSession(id: "remote-1")])
        let transport = BluetoothTransportSpy(maximumWriteValueLength: 64)
        let coordinator = MacClientCoordinator(sessionClient: service, transport: transport)
        try await coordinator.receive(message: .deviceInfo(deviceInfo()))
        try await coordinator.receive(message: .selectSession(requestID: 40, sessionKey: 1))

        try await coordinator.receive(message: .scroll(sessionKey: 1, delta: 120, sequence: 7))
        try await coordinator.receive(message: .scroll(sessionKey: 1, delta: 120, sequence: 7))

        let scrolls = await service.scrolls()
        XCTAssertEqual(scrolls, [ScrollAction(deltaY: 120, remoteSessionID: "remote-1")])
    }

    func testPTTRequiresSelectedSessionThenForwardsAudioAndEnds() async throws {
        let service = SessionClientSpy(sessions: [makeSession(id: "remote-1")])
        let transport = BluetoothTransportSpy(maximumWriteValueLength: 64)
        let audio = AudioInputSpy()
        let coordinator = MacClientCoordinator(
            sessionClient: service,
            transport: transport,
            audioInput: audio
        )
        try await coordinator.receive(message: .deviceInfo(deviceInfo()))
        transport.removeAllPackets()

        try await coordinator.receive(message: .pttBegin(requestID: 50, sessionKey: 1, firstAudioSequence: 10))
        try await coordinator.receive(message: .selectSession(requestID: 51, sessionKey: 1))
        try await coordinator.receive(message: .pttBegin(requestID: 52, sessionKey: 1, firstAudioSequence: 10))
        let frame = ADPCMFrame(
            sequence: 10,
            sampleTimestamp: 1,
            predictor: 0,
            stepIndex: 0,
            sampleCount: 1,
            encodedSamples: Data()
        )
        try await coordinator.receive(message: .audioFrame(frame))
        try await coordinator.receive(message: .pttEnd(requestID: 53, sessionKey: 1, lastAudioSequence: 10))

        XCTAssertEqual(audio.beginSequences, [10])
        XCTAssertEqual(audio.frames, [frame])
        XCTAssertEqual(audio.endSequences, [10])
        XCTAssertEqual(coordinator.pttDiagnostics.decodedFrameCount, 1)
        XCTAssertEqual(coordinator.pttDiagnostics.firstFrameSequence, 10)
        XCTAssertEqual(coordinator.pttDiagnostics.lastFrameSequence, 10)
        XCTAssertEqual(try transport.decodedMessages(), [
            .actionResult(requestID: 50, result: .invalidState, detail: "请先进入会话"),
            .actionResult(requestID: 51, result: .success, detail: ""),
            .actionResult(requestID: 52, result: .success, detail: "PTT 已就绪"),
            .actionResult(requestID: 53, result: .success, detail: "PTT 已结束"),
        ])
    }

    func testDisconnectAbortsActivePTT() async throws {
        let service = SessionClientSpy(sessions: [makeSession(id: "remote-1")])
        let transport = BluetoothTransportSpy(maximumWriteValueLength: 64)
        let audio = AudioInputSpy()
        let coordinator = MacClientCoordinator(
            sessionClient: service,
            transport: transport,
            audioInput: audio
        )
        try await coordinator.receive(message: .deviceInfo(deviceInfo()))
        try await coordinator.receive(message: .selectSession(requestID: 60, sessionKey: 1))
        try await coordinator.receive(message: .pttBegin(requestID: 61, sessionKey: 1, firstAudioSequence: 1))

        transport.onStateChange?(.disconnected)

        XCTAssertEqual(audio.abortCount, 1)
    }

    func testAudioPacketDiagnosticsCountFragmentsAndMalformedPackets() async throws {
        let transport = BluetoothTransportSpy(maximumWriteValueLength: 64)
        let coordinator = MacClientCoordinator(
            sessionClient: SessionClientSpy(sessions: []),
            transport: transport
        )

        do {
            try await coordinator.receive(packet: BLETransportPacket(
                channel: .audioToHost,
                bytes: Data([0x01, 0x02, 0x03])
            ))
            XCTFail("Expected malformed audio fragment")
        } catch {
            XCTAssertEqual(error as? BLEFragmentError, .malformedFragment)
        }

        XCTAssertEqual(coordinator.pttDiagnostics.fragmentCount, 1)
        XCTAssertEqual(coordinator.pttDiagnostics.byteCount, 3)
        XCTAssertEqual(coordinator.pttDiagnostics.packetErrorCount, 1)
    }

    private func makeSession(id: String, state: RemoteSessionState = .idle) -> RemoteSession {
        RemoteSession(
            remoteSessionID: id,
            launcherInstanceID: "launcher-\(id)",
            providerSessionID: "provider-\(id)",
            terminalTargetID: "target-\(id)",
            displayTitle: "Codex \(id)",
            workingDirectoryLabel: "project",
            state: state,
            statusDetail: "",
            unread: state == .completeUnread,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func deviceInfo() -> DeviceInformation {
        DeviceInformation(
            firmwareVersion: "0.1.0",
            capabilities: [.display, .microphone, .touch, .userButton],
            batteryPercent: 80,
            isCharging: true
        )
    }
}

@MainActor
private final class AudioInputSpy: AudioInputHandling {
    let dependencyStatus = AudioDependencyStatus.ready
    private(set) var beginSequences: [UInt32] = []
    private(set) var frames: [ADPCMFrame] = []
    private(set) var endSequences: [UInt32] = []
    private(set) var abortCount = 0

    func begin(firstAudioSequence: UInt32) {
        beginSequences.append(firstAudioSequence)
    }

    func receive(_ frame: ADPCMFrame) {
        frames.append(frame)
    }

    func end(lastAudioSequence: UInt32) async {
        endSequences.append(lastAudioSequence)
    }

    func abort() {
        abortCount += 1
    }
}

private struct SentKey: Equatable, Sendable {
    let key: TerminalKey
    let remoteSessionID: String
}

private struct ScrollAction: Equatable, Sendable {
    let deltaY: Int
    let remoteSessionID: String
}

private struct SentShortcut: Equatable, Sendable {
    let shortcut: TerminalShortcut
    let remoteSessionID: String
}

private actor SessionClientSpy: SessionClient {
    private var sessions: [RemoteSession]
    private var selected: [String] = []
    private var keys: [SentKey] = []
    private var scrollActions: [ScrollAction] = []
    private var shortcuts: [SentShortcut] = []

    init(sessions: [RemoteSession]) {
        self.sessions = sessions
    }

    func activeSessions(limit: Int) -> [RemoteSession] {
        Array(sessions.prefix(limit))
    }

    func selectSession(remoteSessionID: String) -> RemoteSession {
        selected.append(remoteSessionID)
        return sessions.first { $0.remoteSessionID == remoteSessionID }!
    }

    func sendKey(_ key: TerminalKey, remoteSessionID: String) {
        keys.append(SentKey(key: key, remoteSessionID: remoteSessionID))
    }

    func scroll(deltaY: Int, remoteSessionID: String) {
        scrollActions.append(ScrollAction(deltaY: deltaY, remoteSessionID: remoteSessionID))
    }


    func sendShortcut(_ shortcut: TerminalShortcut, remoteSessionID: String) {
        shortcuts.append(SentShortcut(shortcut: shortcut, remoteSessionID: remoteSessionID))
    }

    func selectedSessionIDs() -> [String] { selected }
    func sentKeys() -> [SentKey] { keys }
    func scrolls() -> [ScrollAction] { scrollActions }
    func sentShortcuts() -> [SentShortcut] { shortcuts }
}

@MainActor
private final class BluetoothTransportSpy: BluetoothTransport {
    var state: BluetoothTransportState = .ready(id: "device")
    let maximumWriteValueLength: Int
    var onStateChange: ((BluetoothTransportState) -> Void)?
    var onPacket: ((BLETransportPacket) -> Void)?
    private var packets: [BLETransportPacket] = []

    init(maximumWriteValueLength: Int) {
        self.maximumWriteValueLength = maximumWriteValueLength
    }

    func start() {}
    func stop() {}

    func send(_ packet: BLETransportPacket, mode: BluetoothWriteMode) {
        packets.append(packet)
    }

    func removeAllPackets() {
        packets.removeAll()
    }

    func decodedMessages() throws -> [BLEMessage] {
        var reassemblers: [BLELogicalChannel: BLEFragmentReassembler] = [:]
        let codec = BLEMessageCodec()
        return try packets.compactMap { packet in
            var reassembler = reassemblers[packet.channel, default: BLEFragmentReassembler()]
            let result = try reassembler.accept(packet.bytes)
            reassemblers[packet.channel] = reassembler
            guard case let .complete(data) = result else { return nil }
            return try codec.decode(data).message
        }
    }
}
