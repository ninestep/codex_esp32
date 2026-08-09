import AudioToolbox
import Foundation
import XCTest
@testable import CodexRemoteMac

@MainActor
final class BlackHoleAudioInputBridgeTests: XCTestCase {
    func testBlackHoleOutputGainAmplifiesSpeechAndClipsSafely() {
        let gain = BlackHoleOutputGain()

        XCTAssertEqual(gain.apply(to: 232), 1_856)
        XCTAssertEqual(gain.apply(to: -232), -1_856)
        XCTAssertEqual(gain.apply(to: 5_000), Int16.max)
        XCTAssertEqual(gain.apply(to: -5_000), Int16.min)
    }

    func testAudioSignalDiagnosticsMeasurePeakAndRMSWithoutStoringSamples() {
        var diagnostics = AudioSignalDiagnostics()

        diagnostics.record([-32_768, 0, 32_767])

        XCTAssertEqual(diagnostics.frameCount, 1)
        XCTAssertEqual(diagnostics.sampleCount, 3)
        XCTAssertEqual(diagnostics.peakMagnitude, 32_768)
        XCTAssertEqual(diagnostics.rmsMagnitude, 26_755)
    }

    func testBeginChangesDefaultInputBeforeStartingBlackHoleEngine() throws {
        var operations: [String] = []
        let bridge = BlackHoleAudioInputBridge(
            hotkeyText: "⌥Space",
            hotkeyMode: .hold,
            blackHoleDeviceID: 11,
            originalInputDeviceID: 22,
            emitter: RecordingBlackHoleHotkeyEmitter(isAuthorized: true),
            setDefaultInputDeviceIDOperation: { _ in operations.append("default-input") },
            configureEngineOperation: { _ in operations.append("engine") }
        )

        try bridge.begin(firstAudioSequence: 1)

        XCTAssertEqual(operations, ["default-input", "engine"])
    }

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
        XCTAssertTrue(source.contains("let amplified = outputGain.apply(to: sample)"))
        XCTAssertTrue(source.contains("Float(amplified) / Float(Int16.max)"))
        XCTAssertFalse(source.contains("commonFormat: .pcmFormatInt16"))
    }

    func testPlaybackPipelineBindsBlackHoleBeforeUsingItsNativeOutputFormat() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = macosRoot.appendingPathComponent(
            "Sources/CodexRemoteMac/Audio/BlackHoleAudioInputBridge.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let outputNode = try XCTUnwrap(source.range(of: "let outputNode = engine.outputNode"))
        let bindDevice = try XCTUnwrap(source.range(of: "let status = AudioUnitSetProperty("))
        let nativeFormat = try XCTUnwrap(source.range(of: "outputNode.inputFormat(forBus: 0)"))
        let connectOutput = try XCTUnwrap(source.range(of: "engine.connect(engine.mainMixerNode, to: outputNode, format: outputFormat)"))

        XCTAssertLessThan(outputNode.lowerBound, bindDevice.lowerBound)
        XCTAssertLessThan(bindDevice.lowerBound, nativeFormat.lowerBound)
        XCTAssertLessThan(nativeFormat.lowerBound, connectOutput.lowerBound)
    }

    func testDefaultInputSwitchWaitsForCoreAudioToSettleBeforeEngineStarts() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = macosRoot.appendingPathComponent(
            "Sources/CodexRemoteMac/Audio/CoreAudioDeviceCatalog.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let confirmation = try XCTUnwrap(source.range(of: "defaultInputDeviceID() == id"))
        let settlingDelay = try XCTUnwrap(source.range(of: "Thread.sleep(forTimeInterval:"))
        XCTAssertLessThan(confirmation.lowerBound, settlingDelay.lowerBound)
    }

    func testReceiveRestartsEngineStoppedByCoreAudioBeforeSchedulingAudio() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = macosRoot.appendingPathComponent(
            "Sources/CodexRemoteMac/Audio/BlackHoleAudioInputBridge.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let receive = try XCTUnwrap(source.range(of: "try restartEngineIfNeeded()"))
        let schedule = try XCTUnwrap(source.range(of: "try schedule(samples: samples)"))
        XCTAssertLessThan(receive.lowerBound, schedule.lowerBound)
        XCTAssertTrue(source.contains("guard !engine.isRunning else { return }"))
        XCTAssertTrue(source.contains("try engine.start()"))
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

    func testHoldEndDrainsPlaybackBeforeReleasingHotkeyAndRestoringInput() async throws {
        var operations: [String] = []
        let emitter = RecordingBlackHoleHotkeyEmitter(isAuthorized: true)
        let bridge = BlackHoleAudioInputBridge(
            hotkeyText: "⌥Space",
            hotkeyMode: .hold,
            blackHoleDeviceID: 11,
            originalInputDeviceID: 22,
            emitter: emitter,
            setDefaultInputDeviceIDOperation: { id in operations.append("input-\(id)") },
            playbackCompletionOperation: {
                operations.append("drained")
                XCTAssertFalse(emitter.events.contains { event in
                    if case .up = event { return true }
                    return false
                })
            }
        )

        try bridge.begin(firstAudioSequence: 1)
        try await bridge.end(lastAudioSequence: 1)

        XCTAssertEqual(emitter.events, [
            .down(49, .maskAlternate),
            .up(49, .maskAlternate),
        ])
        XCTAssertEqual(operations, ["input-11", "drained", "input-22"])
    }

    func testModifierOnlyCombinationUsesHoldMode() async throws {
        let emitter = RecordingBlackHoleHotkeyEmitter(isAuthorized: true)
        let bridge = BlackHoleAudioInputBridge(
            hotkeyText: "⌘⌥",
            hotkeyMode: .hold,
            blackHoleDeviceID: 11,
            originalInputDeviceID: 22,
            emitter: emitter
        )

        try bridge.begin(firstAudioSequence: 1)
        try await bridge.end(lastAudioSequence: 1)

        let leftCommand = CGEventFlags(rawValue: 0x00000008)
        let leftOption = CGEventFlags(rawValue: 0x00000020)
        XCTAssertEqual(emitter.events, [
            .down(55, [.maskCommand, leftCommand]),
            .down(58, [.maskCommand, .maskAlternate, leftCommand, leftOption]),
            .up(58, [.maskCommand, leftCommand]),
            .up(55, []),
        ])
    }

    func testModifierOnlyCombinationCanCompleteTwoConsecutiveTransactions() async throws {
        let emitter = RecordingBlackHoleHotkeyEmitter(isAuthorized: true)
        var operations: [String] = []
        let bridge = BlackHoleAudioInputBridge(
            hotkeyText: "⌘⌥",
            hotkeyMode: .hold,
            blackHoleDeviceID: 11,
            originalInputDeviceID: 22,
            emitter: emitter,
            setDefaultInputDeviceIDOperation: { id in operations.append("input-\(id)") },
            configureEngineOperation: { id in operations.append("engine-\(id)") }
        )

        try bridge.begin(firstAudioSequence: 1)
        try await bridge.end(lastAudioSequence: 10)
        try bridge.begin(firstAudioSequence: 11)
        try await bridge.end(lastAudioSequence: 20)

        let leftCommand = CGEventFlags(rawValue: 0x00000008)
        let leftOption = CGEventFlags(rawValue: 0x00000020)
        XCTAssertEqual(emitter.events, [
            .down(55, [.maskCommand, leftCommand]),
            .down(58, [.maskCommand, .maskAlternate, leftCommand, leftOption]),
            .up(58, [.maskCommand, leftCommand]),
            .up(55, []),
            .down(55, [.maskCommand, leftCommand]),
            .down(58, [.maskCommand, .maskAlternate, leftCommand, leftOption]),
            .up(58, [.maskCommand, leftCommand]),
            .up(55, []),
        ])
        XCTAssertEqual(operations, [
            "input-11", "engine-11", "input-22",
            "input-11", "engine-11", "input-22",
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
        events.append(contentsOf: hotkey.keyDownEvents.map { .down($0.keyCode, $0.flags) })
    }

    func keyUp(_ hotkey: ParsedHotkey) throws {
        events.append(contentsOf: hotkey.keyUpEvents.map { .up($0.keyCode, $0.flags) })
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
        events.append(contentsOf: hotkey.keyUpEvents.map { .recovery($0.keyCode) })
    }
}
