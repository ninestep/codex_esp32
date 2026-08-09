import CodexRemoteCore
import Foundation
import XCTest
@testable import CodexRemoteMac

@MainActor
final class CompanionAudioCoordinatorTests: XCTestCase {
    func testDeviceInfoSendsCurrentControlLayout() async throws {
        let transport = CompanionBluetoothTransportSpy()
        let coordinator = CompanionAudioCoordinator(
            transport: transport,
            audioInput: CompanionAudioInputSpy(),
            layoutReader: CompanionLayoutReaderStub(layout: .defaults)
        )

        try await coordinator.receive(message: .deviceInfo(deviceInfo()))

        XCTAssertEqual(try transport.decodedMessages(), [
            .microControlLayout(CodexMicroLayoutSettings.defaults.companionLayout),
        ])
    }

    func testPTTDoesNotRequireCodexSessionAndForwardsAudio() async throws {
        let transport = CompanionBluetoothTransportSpy()
        let audio = CompanionAudioInputSpy()
        let coordinator = CompanionAudioCoordinator(transport: transport, audioInput: audio)

        try await coordinator.receive(message: .pttBegin(
            requestID: 1,
            sessionKey: 0,
            firstAudioSequence: 10
        ))
        let frame = try makeFrame(sequence: 10)
        try await coordinator.receive(message: .audioFrame(frame))
        try await coordinator.receive(message: .pttEnd(
            requestID: 2,
            sessionKey: 0,
            lastAudioSequence: 10
        ))

        XCTAssertEqual(audio.beginSequences, [10])
        XCTAssertEqual(audio.frames, [frame])
        XCTAssertEqual(audio.endSequences, [10])
        XCTAssertEqual(coordinator.speechState, .idle)
        XCTAssertEqual(try transport.decodedMessages(), [
            .actionResult(requestID: 1, result: .success, detail: "PTT 已就绪"),
            .actionResult(requestID: 2, result: .success, detail: "PTT 已结束"),
        ])
    }

    func testDuplicateBeginReturnsCachedResultWithoutRestartingAudio() async throws {
        let transport = CompanionBluetoothTransportSpy()
        let audio = CompanionAudioInputSpy()
        let coordinator = CompanionAudioCoordinator(transport: transport, audioInput: audio)
        let begin = BLEMessage.pttBegin(requestID: 5, sessionKey: 0, firstAudioSequence: 3)

        try await coordinator.receive(message: begin)
        try await coordinator.receive(message: begin)

        XCTAssertEqual(audio.beginSequences, [3])
        XCTAssertEqual(try transport.decodedMessages(), [
            .actionResult(requestID: 5, result: .success, detail: "PTT 已就绪"),
            .actionResult(requestID: 5, result: .success, detail: "PTT 已就绪"),
        ])
    }

    func testDisconnectAbortsActivePTTAndClearsDeviceState() async throws {
        let transport = CompanionBluetoothTransportSpy()
        let audio = CompanionAudioInputSpy()
        let coordinator = CompanionAudioCoordinator(transport: transport, audioInput: audio)
        try await coordinator.receive(message: .deviceInfo(deviceInfo()))
        try await coordinator.receive(message: .pttBegin(
            requestID: 7,
            sessionKey: 9,
            firstAudioSequence: 1
        ))

        transport.state = .disconnected
        transport.onStateChange?(.disconnected)

        XCTAssertEqual(audio.abortCount, 1)
        XCTAssertNil(coordinator.deviceInformation)
        XCTAssertEqual(coordinator.speechState, .idle)
    }

    func testRecognitionFailureIsReportedAndTransactionIsReleased() async throws {
        let transport = CompanionBluetoothTransportSpy()
        let audio = CompanionAudioInputSpy()
        audio.endError = AudioInputBridgeError.audioSystemFailure
        let coordinator = CompanionAudioCoordinator(transport: transport, audioInput: audio)
        try await coordinator.receive(message: .pttBegin(
            requestID: 10,
            sessionKey: 1,
            firstAudioSequence: 1
        ))

        try await coordinator.receive(message: .pttEnd(
            requestID: 11,
            sessionKey: 1,
            lastAudioSequence: 0
        ))

        XCTAssertEqual(audio.abortCount, 1)
        XCTAssertEqual(coordinator.speechState, .failed("语音识别失败"))
        XCTAssertEqual(try transport.decodedMessages().last, .actionResult(
            requestID: 11,
            result: .unavailable,
            detail: "语音识别失败"
        ))
    }

    func testMalformedAudioPacketRequestsResyncAndCountsError() async throws {
        let transport = CompanionBluetoothTransportSpy()
        let coordinator = CompanionAudioCoordinator(
            transport: transport,
            audioInput: CompanionAudioInputSpy()
        )

        do {
            try await coordinator.receive(packet: BLETransportPacket(
                channel: .audioToHost,
                bytes: Data([1, 2, 3])
            ))
            XCTFail("Expected malformed fragment")
        } catch {
            XCTAssertEqual(error as? BLEFragmentError, .malformedFragment)
        }

        XCTAssertEqual(coordinator.diagnostics.fragmentCount, 1)
        XCTAssertEqual(coordinator.diagnostics.packetErrorCount, 1)
        XCTAssertEqual(try transport.decodedMessages(), [
            .resyncRequired(reason: .malformedFragment),
        ])
    }

    private func makeFrame(sequence: UInt32) throws -> ADPCMFrame {
        try IMAADPCMCodec().encode(
            samples: Array(repeating: Int16(1200), count: IMAADPCMCodec.samplesPerFrame),
            sequence: sequence,
            sampleTimestamp: 0
        )
    }

    private func deviceInfo() -> DeviceInformation {
        DeviceInformation(
            firmwareVersion: "0.1.2",
            capabilities: [.display, .microphone, .touch, .userButton],
            batteryPercent: 80
        )
    }
}

@MainActor
private final class CompanionAudioInputSpy: AudioInputHandling {
    let dependencyStatus = AudioDependencyStatus.ready
    var beginError: Error?
    var endError: Error?
    private(set) var beginSequences: [UInt32] = []
    private(set) var frames: [ADPCMFrame] = []
    private(set) var endSequences: [UInt32] = []
    private(set) var abortCount = 0

    func begin(firstAudioSequence: UInt32) throws {
        if let beginError { throw beginError }
        beginSequences.append(firstAudioSequence)
    }

    func receive(_ frame: ADPCMFrame) throws {
        frames.append(frame)
    }

    func end(lastAudioSequence: UInt32) async throws {
        if let endError { throw endError }
        endSequences.append(lastAudioSequence)
    }

    func abort() {
        abortCount += 1
    }
}

@MainActor
private final class CompanionBluetoothTransportSpy: BluetoothTransport {
    var state: BluetoothTransportState = .ready(id: "device")
    let maximumWriteValueLength = 64
    var onStateChange: ((BluetoothTransportState) -> Void)?
    var onPacket: ((BLETransportPacket) -> Void)?
    private var packets: [BLETransportPacket] = []

    func start() {}
    func stop() {}

    func send(_ packet: BLETransportPacket, mode: BluetoothWriteMode) {
        packets.append(packet)
    }

    func decodedMessages() throws -> [BLEMessage] {
        var reassemblers: [BLELogicalChannel: BLEFragmentReassembler] = [:]
        let codec = BLEMessageCodec()
        return try packets.compactMap { packet in
            var reassembler = reassemblers[packet.channel, default: BLEFragmentReassembler()]
            let result = try reassembler.accept(packet.bytes)
            reassemblers[packet.channel] = reassembler
            guard case .complete(let data) = result else { return nil }
            return try codec.decode(data).message
        }
    }
}

private struct CompanionLayoutReaderStub: CodexMicroLayoutReading {
    let layout: CodexMicroLayoutSettings

    func read() throws -> CodexMicroLayoutSettings {
        layout
    }
}
