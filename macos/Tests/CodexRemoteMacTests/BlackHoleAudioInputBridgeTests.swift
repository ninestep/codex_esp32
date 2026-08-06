import AudioToolbox
import Foundation
import XCTest
@testable import CodexRemoteMac

@MainActor
final class BlackHoleAudioInputBridgeTests: XCTestCase {
    func testPlaybackPipelineUsesMixerCompatibleFloatSamples() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = macosRoot.appendingPathComponent(
            "Sources/CodexRemoteMac/Audio/BlackHoleAudioInputBridge.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("commonFormat: .pcmFormatFloat32"))
        XCTAssertTrue(source.contains("floatChannelData?[0]"))
        XCTAssertTrue(source.contains("Float(sample) / Float(Int16.max)"))
        XCTAssertFalse(source.contains("commonFormat: .pcmFormatInt16"))
    }

    func testHoldEndRecoversWhenKeyUpFailsAfterSuccessfulBeginKeyDown() async throws {
        let emitter = RecordingBlackHoleHotkeyEmitter(isAuthorized: true, failUpAttempts: 1)
        let bridge = makeBridge(mode: .hold, emitter: emitter)

        try bridge.begin(firstAudioSequence: 1)
        do {
            try await bridge.end(lastAudioSequence: 1)
            XCTFail("Expected end to fail")
        } catch {
            XCTAssertEqual(error as? AudioInputBridgeError, .audioSystemFailure)
        }

        XCTAssertEqual(emitter.events, [
            .down(49, .maskAlternate),
            .up(49, .maskAlternate),
            .recovery(49),
        ])
    }

    func testHoldAbortRecoversWhenKeyUpFailsAfterSuccessfulBeginKeyDown() throws {
        let emitter = RecordingBlackHoleHotkeyEmitter(isAuthorized: true, failUpAttempts: 1)
        let bridge = makeBridge(mode: .hold, emitter: emitter)

        try bridge.begin(firstAudioSequence: 1)
        bridge.abort()

        XCTAssertEqual(emitter.events, [
            .down(49, .maskAlternate),
            .up(49, .maskAlternate),
            .recovery(49),
        ])
    }

    func testToggleBeginRecoversWhenKeyUpFailsAfterSuccessfulKeyDown() {
        let emitter = RecordingBlackHoleHotkeyEmitter(isAuthorized: true, failUpAttempts: 1)
        let bridge = makeBridge(mode: .toggle, emitter: emitter)

        XCTAssertThrowsError(try bridge.begin(firstAudioSequence: 1)) { error in
            XCTAssertEqual(error as? AudioInputBridgeError, .audioSystemFailure)
        }

        XCTAssertEqual(emitter.events, [
            .down(49, .maskAlternate),
            .up(49, .maskAlternate),
            .recovery(49),
        ])
    }

    func testToggleEndRecoversWhenKeyUpFailsAfterSuccessfulKeyDown() async throws {
        let emitter = RecordingBlackHoleHotkeyEmitter(isAuthorized: true, failUpAttempts: 1, failUpAfterSuccesses: 1)
        let bridge = makeBridge(mode: .toggle, emitter: emitter)

        try bridge.begin(firstAudioSequence: 1)
        do {
            try await bridge.end(lastAudioSequence: 1)
            XCTFail("Expected end to fail")
        } catch {
            XCTAssertEqual(error as? AudioInputBridgeError, .audioSystemFailure)
        }

        XCTAssertEqual(emitter.events, [
            .down(49, .maskAlternate),
            .up(49, .maskAlternate),
            .down(49, .maskAlternate),
            .up(49, .maskAlternate),
            .recovery(49),
        ])
    }

    func testSuccessfulHoldEndDoesNotRecover() async throws {
        let emitter = RecordingBlackHoleHotkeyEmitter(isAuthorized: true)
        let bridge = makeBridge(mode: .hold, emitter: emitter)

        try bridge.begin(firstAudioSequence: 1)
        try await bridge.end(lastAudioSequence: 1)

        XCTAssertEqual(emitter.events, [
            .down(49, .maskAlternate),
            .up(49, .maskAlternate),
        ])
    }

    func testFunctionKeyHoldUsesSecondaryFnOnlyWhilePressed() async throws {
        let emitter = RecordingBlackHoleHotkeyEmitter(isAuthorized: true)
        let bridge = BlackHoleAudioInputBridge(
            hotkeyText: "Fn",
            hotkeyMode: .hold,
            blackHoleDeviceID: 11,
            originalInputDeviceID: 22,
            emitter: emitter
        )

        try bridge.begin(firstAudioSequence: 1)
        try await bridge.end(lastAudioSequence: 1)

        XCTAssertEqual(emitter.events, [
            .down(0x3F, .maskSecondaryFn),
            .up(0x3F, []),
        ])
    }

    private func makeBridge(
        mode: HotkeyTriggerMode,
        emitter: RecordingBlackHoleHotkeyEmitter
    ) -> BlackHoleAudioInputBridge {
        BlackHoleAudioInputBridge(
            hotkeyText: "⌥Space",
            hotkeyMode: mode,
            blackHoleDeviceID: 11,
            originalInputDeviceID: 22,
            emitter: emitter
        )
    }
}

@MainActor
private final class RecordingBlackHoleHotkeyEmitter: HotkeyEmitting {
    enum Event: Equatable {
        case down(CGKeyCode, CGEventFlags)
        case up(CGKeyCode, CGEventFlags)
        case recovery(CGKeyCode)
    }

    let isAuthorized: Bool
    private var remainingFailedUps: Int
    private var remainingSuccessfulUpsBeforeFailure: Int
    private(set) var events: [Event] = []

    init(isAuthorized: Bool, failUpAttempts: Int = 0, failUpAfterSuccesses: Int = 0) {
        self.isAuthorized = isAuthorized
        self.remainingFailedUps = failUpAttempts
        self.remainingSuccessfulUpsBeforeFailure = failUpAfterSuccesses
    }

    func keyDown(_ hotkey: ParsedHotkey) {
        events.append(.down(hotkey.keyCode, hotkey.keyDownFlags))
    }

    func keyUp(_ hotkey: ParsedHotkey) throws {
        events.append(.up(hotkey.keyCode, hotkey.keyUpFlags))
        if remainingSuccessfulUpsBeforeFailure > 0 {
            remainingSuccessfulUpsBeforeFailure -= 1
            return
        }
        if remainingFailedUps > 0 {
            remainingFailedUps -= 1
            throw AudioInputBridgeError.audioSystemFailure
        }
    }

    func recoverAfterKeyUpFailure(_ hotkey: ParsedHotkey) {
        events.append(.recovery(hotkey.keyCode))
    }
}
