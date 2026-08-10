import Foundation
import XCTest
@testable import CodexRemoteCore

final class BLEMessageCodecTests: XCTestCase {
    private let codec = BLEMessageCodec()

    func testProtocolV14DefinesChargingControlLayoutAndEditingContract() {
        XCTAssertEqual(BLEProtocolVersion.current, BLEProtocolVersion(major: 1, minor: 4))
        XCTAssertEqual(RemoteTerminalKey.up.rawValue, 3)
        XCTAssertEqual(RemoteTerminalKey.down.rawValue, 4)
        XCTAssertEqual(RemoteTerminalKey.left.rawValue, 5)
        XCTAssertEqual(RemoteTerminalKey.right.rawValue, 6)
        XCTAssertEqual(RemoteTerminalKey.backspace.rawValue, 7)
        XCTAssertEqual(RemoteTerminalKey.clearLine.rawValue, 8)
        XCTAssertEqual(RemoteTerminalShortcut.newSession.rawValue, 1)
        XCTAssertEqual(RemoteTerminalShortcut.quit.rawValue, 2)
        XCTAssertEqual(RemoteTerminalShortcut.write.rawValue, 3)
        XCTAssertEqual(RemoteTerminalShortcut.plan.rawValue, 4)
        XCTAssertEqual(RemoteTerminalShortcut.compact.rawValue, 5)
        XCTAssertEqual(DeviceSessionCapabilities.navigationKeys.rawValue, 1 << 3)
        XCTAssertEqual(DeviceSessionCapabilities.terminalShortcuts.rawValue, 1 << 4)
    }

    func testRoundTripsEveryV1MessageCase() throws {
        let session = makeSession(key: 7)
        let manifest = AssetManifest(
            setID: 12,
            totalBytes: 3,
            items: [AssetItemDescriptor(assetID: 1, width: 480, height: 480, byteCount: 3, crc32: 0x3524_41c2)]
        )
        let audio = ADPCMFrame(
            sequence: 5,
            sampleTimestamp: 32_000,
            predictor: -120,
            stepIndex: 17,
            sampleCount: 320,
            encodedSamples: Data(repeating: 0x11, count: 160)
        )
        let messages: [BLEMessage] = [
            .selectSession(requestID: 1, sessionKey: 7),
            .scroll(sessionKey: 7, delta: -42, sequence: 2),
            .terminalKey(requestID: 3, sessionKey: 7, key: .enter),
            .terminalKey(requestID: 4, sessionKey: 7, key: .up),
            .terminalShortcut(requestID: 5, sessionKey: 7, shortcut: .compact),
            .pttBegin(requestID: 6, sessionKey: 7, firstAudioSequence: 10),
            .pttEnd(requestID: 7, sessionKey: 7, lastAudioSequence: 19),
            .actionResult(requestID: 8, result: .success, detail: "已聚焦"),
            .stateSnapshot(generation: 8, sessions: [session]),
            .stateDelta(generation: 8, sequence: 9, session: session),
            .audioFrame(audio),
            .assetManifest(manifest),
            .assetChunk(AssetChunk(setID: 12, assetID: 1, offset: 0, bytes: Data([1, 2, 3]))),
            .assetAcknowledgement(setID: 12, assetID: 1, nextOffset: 3, result: .accepted),
            .deviceInfo(DeviceInformation(
                firmwareVersion: "sim-1",
                capabilities: [.display, .microphone],
                batteryPercent: 82,
                isCharging: true
            )),
            .resyncRequired(reason: .sequenceGap),
            .microControlLayout(MicroControlLayout(
                controls: ["快速模式", "批准", "拒绝", "继续", "按住说话", "发送"],
                encoder: "会话滚动",
                directions: ["计划模式", "前进", "显示或隐藏侧栏", "后退"]
            )),
        ]

        for (index, message) in messages.enumerated() {
            let encoded = try codec.encode(message, sequence: UInt32(index + 1))
            XCTAssertEqual(try codec.decode(encoded), BLEDecodedMessage(sequence: UInt32(index + 1), message: message))
        }
    }

    func testControlLayoutRequiresSixControlsAndFourDirections() {
        XCTAssertThrowsError(try codec.encode(.microControlLayout(MicroControlLayout(
            controls: ["批准"],
            encoder: "会话滚动",
            directions: ["上", "右", "下", "左"]
        )), sequence: 1)) { error in
            XCTAssertEqual(error as? BLEMessageCodecError, .invalidMicroControlCount(1))
        }
        XCTAssertThrowsError(try codec.encode(.microControlLayout(MicroControlLayout(
            controls: ["1", "2", "3", "4", "5", "6"],
            encoder: "会话滚动",
            directions: ["上"]
        )), sequence: 1)) { error in
            XCTAssertEqual(error as? BLEMessageCodecError, .invalidMicroDirectionCount(1))
        }
    }

    func testSnapshotAllowsEightSessionsAndRejectsNine() throws {
        let eight = (1...8).map { makeSession(key: UInt16($0)) }
        XCTAssertNoThrow(try codec.encode(.stateSnapshot(generation: 1, sessions: eight), sequence: 1))

        let nine = (1...9).map { makeSession(key: UInt16($0)) }
        XCTAssertThrowsError(try codec.encode(.stateSnapshot(generation: 1, sessions: nine), sequence: 1)) { error in
            XCTAssertEqual(error as? BLEMessageCodecError, .tooManySessions(9))
        }
    }

    func testEnforcesBoundedDisplayStringsAndAudioFrameShape() throws {
        let longTitle = String(repeating: "a", count: 65)
        let invalidSession = DeviceSession(
            sessionKey: 1,
            displayTitle: longTitle,
            workingDirectoryLabel: "work",
            state: .idle,
            statusDetail: "",
            unread: false,
            capabilities: [.scroll],
            updatedAtMilliseconds: 1
        )
        XCTAssertThrowsError(try codec.encode(.stateSnapshot(generation: 1, sessions: [invalidSession]), sequence: 1)) { error in
            XCTAssertEqual(error as? BLECodecError, .stringTooLong(maximum: 64, actual: 65))
        }

        let badAudio = ADPCMFrame(
            sequence: 1,
            sampleTimestamp: 0,
            predictor: 0,
            stepIndex: 0,
            sampleCount: 319,
            encodedSamples: Data(repeating: 0, count: 160)
        )
        XCTAssertThrowsError(try codec.encode(.audioFrame(badAudio), sequence: 1)) { error in
            XCTAssertEqual(error as? BLEMessageCodecError, .invalidAudioSampleCount(319))
        }
    }

    func testRejectsUnknownEnumAndTrailingPayloadBytes() throws {
        var invalidKey = try codec.encode(.terminalKey(requestID: 1, sessionKey: 2, key: .enter), sequence: 1)
        invalidKey[20] = 0xff
        rewriteCRC(&invalidKey)
        XCTAssertThrowsError(try codec.decode(invalidKey)) { error in
            XCTAssertEqual(error as? BLEMessageCodecError, .unknownEnum(field: "terminalKey", rawValue: 0xff))
        }

        var invalidShortcut = try codec.encode(
            .terminalShortcut(requestID: 1, sessionKey: 2, shortcut: .compact),
            sequence: 1
        )
        invalidShortcut[20] = 0xff
        rewriteCRC(&invalidShortcut)
        XCTAssertThrowsError(try codec.decode(invalidShortcut)) { error in
            XCTAssertEqual(error as? BLEMessageCodecError, .unknownEnum(field: "terminalShortcut", rawValue: 0xff))
        }

        let envelope = BLEEnvelope(type: .selectSession, sequence: 1, payload: Data([1, 0, 0, 0, 2, 0, 9]))
        XCTAssertThrowsError(try codec.decode(BLEEnvelopeCodec().encode(envelope))) { error in
            XCTAssertEqual(error as? BLECodecError, .trailingBytes(1))
        }

        var invalidCharging = try codec.encode(.deviceInfo(DeviceInformation(
            firmwareVersion: "sim-1",
            capabilities: [.display],
            batteryPercent: 82,
            isCharging: true
        )), sequence: 2)
        invalidCharging[invalidCharging.index(invalidCharging.endIndex, offsetBy: -5)] = 2
        rewriteCRC(&invalidCharging)
        XCTAssertThrowsError(try codec.decode(invalidCharging)) { error in
            XCTAssertEqual(error as? BLEMessageCodecError, .invalidBoolean(2))
        }
    }

    func testRemoteSessionProjectionDoesNotExposePrivateMappingIdentifiers() throws {
        let remote = RemoteSession(
            remoteSessionID: "remote-secret",
            launcherInstanceID: "launcher-secret",
            providerSessionID: "provider-secret",
            terminalTargetID: "terminal-secret",
            displayTitle: "esp32",
            workingDirectoryLabel: "work",
            state: .requiresInput,
            statusDetail: "确认后继续",
            unread: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let projection = DeviceSession(remoteSession: remote, sessionKey: 3, capabilities: [.scroll, .terminalKeys, .ptt])
        let encoded = try codec.encode(.stateSnapshot(generation: 1, sessions: [projection]), sequence: 1)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(projection.state, .requiresInput)
        XCTAssertFalse(text.contains("remote-secret"))
        XCTAssertFalse(text.contains("launcher-secret"))
        XCTAssertFalse(text.contains("provider-secret"))
        XCTAssertFalse(text.contains("terminal-secret"))
    }

    private func makeSession(key: UInt16) -> DeviceSession {
        DeviceSession(
            sessionKey: key,
            displayTitle: "esp32-\(key)",
            workingDirectoryLabel: "macos",
            state: .working,
            statusDetail: "实现 BLE v1",
            unread: false,
            capabilities: [.scroll, .terminalKeys, .ptt],
            updatedAtMilliseconds: 1_700_000_000_000
        )
    }

    private func rewriteCRC(_ data: inout Data) {
        let body = data.dropLast(4)
        let checksum = BLECRC32.checksum(body)
        data.replaceSubrange(data.index(data.endIndex, offsetBy: -4)..<data.endIndex, with: checksum.littleEndianBytes)
    }
}
