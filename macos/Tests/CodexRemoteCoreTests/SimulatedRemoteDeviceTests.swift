import Foundation
import XCTest
@testable import CodexRemoteCore

final class SimulatedRemoteDeviceTests: XCTestCase {
    func testConnectEmitsDeviceInfoThroughEncodedFragments() throws {
        var device = makeDevice()

        let messages = try decode(device.connect())

        XCTAssertEqual(messages, [
            .deviceInfo(DeviceInformation(
                firmwareVersion: "sim-1",
                capabilities: [.display, .microphone, .touch, .userButton, .assetStorage],
                batteryPercent: 80,
                isCharging: true
            )),
        ])
    }

    func testRequiresSnapshotBeforeOrderedDeltasAndDisconnectClearsConnectionState() throws {
        var device = makeDevice()
        let session = makeSession(key: 1, state: .idle)

        XCTAssertEqual(try transmit(.stateDelta(generation: 7, sequence: 1, session: session), channel: .stateToDevice, to: &device), [.resyncRequired(reason: .connectionReset)])
        XCTAssertTrue(try transmit(.stateSnapshot(generation: 7, sessions: [session]), channel: .stateToDevice, to: &device).isEmpty)

        let working = makeSession(key: 1, state: .working)
        XCTAssertTrue(try transmit(.stateDelta(generation: 7, sequence: 1, session: working), channel: .stateToDevice, to: &device).isEmpty)
        XCTAssertEqual(device.sessions[1]?.state, .working)

        XCTAssertEqual(try transmit(.stateDelta(generation: 7, sequence: 3, session: working), channel: .stateToDevice, to: &device), [.resyncRequired(reason: .sequenceGap)])
        XCTAssertEqual(try transmit(.stateDelta(generation: 6, sequence: 2, session: working), channel: .stateToDevice, to: &device), [.resyncRequired(reason: .staleGeneration)])

        device.disconnect()
        XCTAssertTrue(device.sessions.isEmpty)
        XCTAssertNil(device.selectedSessionKey)
    }

    func testSelectionScrollAndTerminalKeyRequestsAreValidatedAndDeduplicated() throws {
        var device = makeDevice()
        _ = try transmit(.stateSnapshot(generation: 1, sessions: [makeSession(key: 1, state: .idle)]), channel: .stateToDevice, to: &device)

        XCTAssertEqual(try transmit(.selectSession(requestID: 10, sessionKey: 9), channel: .controlToHost, to: &device), [.actionResult(requestID: 10, result: .unavailable, detail: "会话不可用")])
        XCTAssertEqual(try transmit(.selectSession(requestID: 11, sessionKey: 1), channel: .controlToHost, to: &device), [.actionResult(requestID: 11, result: .success, detail: "会话已选择")])
        XCTAssertEqual(device.selectedSessionKey, 1)

        XCTAssertTrue(try transmit(.scroll(sessionKey: 1, delta: -20, sequence: 1), channel: .controlToHost, to: &device).isEmpty)
        XCTAssertTrue(try transmit(.scroll(sessionKey: 1, delta: -20, sequence: 1), channel: .controlToHost, to: &device).isEmpty)
        XCTAssertEqual(device.scrollExecutions, [SimulatedScrollExecution(sessionKey: 1, delta: -20, sequence: 1)])

        let key = BLEMessage.terminalKey(requestID: 12, sessionKey: 1, key: .enter)
        let first = try transmit(key, channel: .controlToHost, to: &device)
        let duplicate = try transmit(key, channel: .controlToHost, to: &device)
        XCTAssertEqual(first, [.actionResult(requestID: 12, result: .success, detail: "按键已发送")])
        XCTAssertEqual(duplicate, first)
        XCTAssertEqual(device.keyExecutions, [SimulatedKeyExecution(requestID: 12, sessionKey: 1, key: .enter)])
    }

    func testPTTRequiresSelectionAndCountsDroppedIndependentAudioFrames() throws {
        var device = makeDevice()
        _ = try transmit(.stateSnapshot(generation: 1, sessions: [makeSession(key: 1, state: .idle)]), channel: .stateToDevice, to: &device)

        XCTAssertEqual(try transmit(.pttBegin(requestID: 20, sessionKey: 1, firstAudioSequence: 10), channel: .controlToHost, to: &device), [.actionResult(requestID: 20, result: .invalidState, detail: "请先进入会话")])
        _ = try transmit(.selectSession(requestID: 21, sessionKey: 1), channel: .controlToHost, to: &device)
        XCTAssertEqual(try transmit(.pttBegin(requestID: 22, sessionKey: 1, firstAudioSequence: 10), channel: .controlToHost, to: &device), [.actionResult(requestID: 22, result: .success, detail: "PTT 已就绪")])

        let codec = IMAADPCMCodec()
        let frame10 = try codec.encode(samples: Array(repeating: 0, count: 320), sequence: 10, sampleTimestamp: 0)
        let frame12 = try codec.encode(samples: Array(repeating: 1_000, count: 320), sequence: 12, sampleTimestamp: 640)
        XCTAssertTrue(try transmit(.audioFrame(frame10), channel: .audioToHost, to: &device).isEmpty)
        XCTAssertTrue(try transmit(.audioFrame(frame12), channel: .audioToHost, to: &device).isEmpty)

        XCTAssertEqual(device.audioReceivedSequences, [10, 12])
        XCTAssertEqual(device.audioDroppedFrameCount, 1)
        XCTAssertEqual(try transmit(.pttEnd(requestID: 23, sessionKey: 1, lastAudioSequence: 12), channel: .controlToHost, to: &device), [.actionResult(requestID: 23, result: .success, detail: "PTT 已结束")])
        XCTAssertFalse(device.isRecording)
    }

    func testAssetInterruptionPreservesOldSetAndCompleteReplacementActivates() throws {
        var device = makeDevice()
        let old = Data([0xff, 0xd8, 1, 0xff, 0xd9])
        let new = Data([0xff, 0xd8, 2, 0xff, 0xd9])

        try transfer(setID: 1, bytes: old, to: &device)
        XCTAssertEqual(device.activeAssetSet?.setID, 1)

        let manifest = assetManifest(setID: 2, bytes: new)
        _ = try transmit(.assetManifest(manifest), channel: .assetToDevice, to: &device)
        _ = try transmit(.assetChunk(AssetChunk(setID: 2, assetID: 1, offset: 0, bytes: Data(new.prefix(2)))), channel: .assetToDevice, to: &device)
        device.disconnect()
        XCTAssertEqual(device.activeAssetSet?.setID, 1)

        try transfer(setID: 2, bytes: new, to: &device)
        XCTAssertEqual(device.activeAssetSet, ActiveAssetSet(setID: 2, assets: [1: new]))
    }

    func testMalformedFragmentReturnsResyncInsteadOfApplyingPartialMessage() throws {
        var device = makeDevice()
        let encoded = try BLEMessageCodec().encode(.stateSnapshot(generation: 1, sessions: [makeSession(key: 1, state: .idle)]), sequence: 1)
        let fragments = try BLEFragmentCodec().fragment(encoded, messageID: 99, maximumPacketBytes: 40)

        XCTAssertTrue(try device.receive(BLETransportPacket(channel: .stateToDevice, bytes: fragments[0])).isEmpty)
        let response = try device.receive(BLETransportPacket(channel: .stateToDevice, bytes: fragments[0]))

        XCTAssertEqual(try decode(response), [.resyncRequired(reason: .malformedFragment)])
        XCTAssertTrue(device.sessions.isEmpty)
    }

    private func makeDevice() -> SimulatedRemoteDevice {
        SimulatedRemoteDevice(
            maximumPacketBytes: 64,
            deviceInformation: DeviceInformation(
                firmwareVersion: "sim-1",
                capabilities: [.display, .microphone, .touch, .userButton, .assetStorage],
                batteryPercent: 80,
                isCharging: true
            )
        )
    }

    private func makeSession(key: UInt16, state: DeviceSessionState) -> DeviceSession {
        DeviceSession(
            sessionKey: key,
            displayTitle: "esp32",
            workingDirectoryLabel: "macos",
            state: state,
            statusDetail: "",
            unread: false,
            capabilities: [.scroll, .terminalKeys, .ptt],
            updatedAtMilliseconds: 1
        )
    }

    private func transmit(
        _ message: BLEMessage,
        channel: BLELogicalChannel,
        to device: inout SimulatedRemoteDevice
    ) throws -> [BLEMessage] {
        let encoded = try BLEMessageCodec().encode(message, sequence: 1)
        let packets = try BLEFragmentCodec().fragment(encoded, messageID: 1, maximumPacketBytes: 64)
        var responses: [BLETransportPacket] = []
        for bytes in packets {
            responses += try device.receive(BLETransportPacket(channel: channel, bytes: bytes))
        }
        return try decode(responses)
    }

    private func decode(_ packets: [BLETransportPacket]) throws -> [BLEMessage] {
        var reassemblers: [BLELogicalChannel: BLEFragmentReassembler] = [:]
        var messages: [BLEMessage] = []
        for packet in packets {
            var reassembler = reassemblers[packet.channel] ?? BLEFragmentReassembler()
            let result = try reassembler.accept(packet.bytes)
            reassemblers[packet.channel] = reassembler
            if case let .complete(data) = result {
                messages.append(try BLEMessageCodec().decode(data).message)
            }
        }
        return messages
    }

    private func transfer(setID: UInt32, bytes: Data, to device: inout SimulatedRemoteDevice) throws {
        _ = try transmit(.assetManifest(assetManifest(setID: setID, bytes: bytes)), channel: .assetToDevice, to: &device)
        let responses = try transmit(.assetChunk(AssetChunk(setID: setID, assetID: 1, offset: 0, bytes: bytes)), channel: .assetToDevice, to: &device)
        XCTAssertEqual(responses, [.assetAcknowledgement(setID: setID, assetID: 1, nextOffset: UInt32(bytes.count), result: .complete)])
    }

    private func assetManifest(setID: UInt32, bytes: Data) -> AssetManifest {
        AssetManifest(
            setID: setID,
            totalBytes: UInt32(bytes.count),
            items: [AssetItemDescriptor(
                assetID: 1,
                width: 480,
                height: 480,
                byteCount: UInt32(bytes.count),
                crc32: BLECRC32.checksum(bytes)
            )]
        )
    }
}
