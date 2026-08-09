import ApplicationServices
import Foundation
import XCTest
@testable import CodexRemoteMac

final class HotkeyTesterTests: XCTestCase {
    func testParserNormalizesSupportedLettersDigitsAndSpecialKeys() throws {
        let parser = HotkeyParser()

        XCTAssertEqual(try parser.parseRequired("⌘ ⇧ v").displayValue, "⌘⇧V")
        XCTAssertEqual(try parser.parseRequired("⌥ Space").displayValue, "⌥Space")
        XCTAssertEqual(try parser.parseRequired("⌃ 7").displayValue, "⌃7")
        XCTAssertEqual(try parser.parseRequired("⇧ tab").displayValue, "⇧Tab")
        XCTAssertEqual(try parser.parseRequired("⌘ enter").displayValue, "⌘Enter")
        XCTAssertEqual(try parser.parseRequired("⌥ ↑").displayValue, "⌥↑")
        XCTAssertEqual(try parser.parseRequired("control arrowleft").displayValue, "⌃←")
    }

    func testParserNormalizesModifierOnlyCombinationAsHoldShortcut() throws {
        let parser = HotkeyParser()
        let leftCommand = CGEventFlags(rawValue: 0x00000008)
        let leftOption = CGEventFlags(rawValue: 0x00000020)

        for value in ["⌘⌥", "option command", "cmd opt"] {
            let hotkey = try parser.parseRequired(value)
            XCTAssertEqual(hotkey.displayValue, "⌘⌥")
            XCTAssertEqual(
                hotkey.keyDownFlags,
                [.maskCommand, .maskAlternate, leftCommand, leftOption]
            )
            XCTAssertEqual(hotkey.keyUpFlags, [])
            XCTAssertEqual(hotkey.keyDownEventType, .flagsChanged)
            XCTAssertEqual(hotkey.keyUpEventType, .flagsChanged)
            XCTAssertTrue(hotkey.requiresHoldMode)
        }

        let threeModifiers = try parser.parseRequired("control option command")
        XCTAssertEqual(threeModifiers.displayValue, "⌘⌥⌃")
        XCTAssertEqual(threeModifiers.keyDownEvents.map(\.keyCode), [55, 58, 59])
        XCTAssertEqual(threeModifiers.keyUpEvents.map(\.keyCode), [59, 58, 55])
    }

    func testParserUsesKeyboardEventsForNonModifierHotkeys() throws {
        let hotkey = try HotkeyParser().parseRequired("⌥Space")

        XCTAssertEqual(hotkey.keyDownEventType, .keyDown)
        XCTAssertEqual(hotkey.keyUpEventType, .keyUp)
    }

    @MainActor
    func testEmitterPostsModifierCombinationInPressAndReverseReleaseOrder() throws {
        var events: [SyntheticHotkeyEvent] = []
        let emitter = CGEventHotkeyEmitter(
            authorizationReader: { true },
            eventPoster: { events.append($0) }
        )
        let hotkey = try HotkeyParser().parseRequired("⌘⌥")

        try emitter.keyDown(hotkey)
        try emitter.keyUp(hotkey)

        let leftCommand = CGEventFlags(rawValue: 0x00000008)
        let leftOption = CGEventFlags(rawValue: 0x00000020)
        XCTAssertEqual(events, [
            SyntheticHotkeyEvent(
                keyCode: 55,
                keyDown: true,
                type: .flagsChanged,
                flags: [.maskCommand, leftCommand]
            ),
            SyntheticHotkeyEvent(
                keyCode: 58,
                keyDown: true,
                type: .flagsChanged,
                flags: [.maskCommand, .maskAlternate, leftCommand, leftOption]
            ),
            SyntheticHotkeyEvent(
                keyCode: 58,
                keyDown: false,
                type: .flagsChanged,
                flags: [.maskCommand, leftCommand]
            ),
            SyntheticHotkeyEvent(keyCode: 55, keyDown: false, type: .flagsChanged, flags: []),
        ])
    }

    @MainActor
    func testEmitterReleasesPressedModifiersWhenLaterPressFails() throws {
        var events: [SyntheticHotkeyEvent] = []
        let emitter = CGEventHotkeyEmitter(
            authorizationReader: { true },
            eventPoster: { event in
                events.append(event)
                if event.keyCode == 58, event.keyDown {
                    throw AudioInputBridgeError.audioSystemFailure
                }
            }
        )
        let hotkey = try HotkeyParser().parseRequired("⌘⌥")

        XCTAssertThrowsError(try emitter.keyDown(hotkey)) { error in
            XCTAssertEqual(error as? AudioInputBridgeError, .audioSystemFailure)
        }
        let leftCommand = CGEventFlags(rawValue: 0x00000008)
        let leftOption = CGEventFlags(rawValue: 0x00000020)
        XCTAssertEqual(events, [
            SyntheticHotkeyEvent(
                keyCode: 55,
                keyDown: true,
                type: .flagsChanged,
                flags: [.maskCommand, leftCommand]
            ),
            SyntheticHotkeyEvent(
                keyCode: 58,
                keyDown: true,
                type: .flagsChanged,
                flags: [.maskCommand, .maskAlternate, leftCommand, leftOption]
            ),
            SyntheticHotkeyEvent(keyCode: 55, keyDown: false, type: .flagsChanged, flags: []),
        ])
    }

    func testParserRejectsInvalidOrAmbiguousHotkeys() throws {
        let parser = HotkeyParser()

        XCTAssertThrowsError(try parser.parseRequired("Space")) { error in
            XCTAssertEqual(error as? HotkeyParseError, .missingModifier)
        }
        XCTAssertThrowsError(try parser.parseRequired("⌘")) { error in
            XCTAssertEqual(error as? HotkeyParseError, .missingKey)
        }
        XCTAssertThrowsError(try parser.parseRequired("⌘⇧")) { error in
            XCTAssertEqual(error as? HotkeyParseError, .missingKey)
        }
        let functionHotkey = try parser.parseRequired("Fn")
        XCTAssertEqual(functionHotkey.displayValue, "Fn")
        XCTAssertTrue(functionHotkey.requiresHoldMode)
        XCTAssertEqual(functionHotkey.keyDownEvents, [
            SyntheticHotkeyEvent(
                keyCode: 63,
                keyDown: true,
                type: .flagsChanged,
                flags: .maskSecondaryFn
            ),
        ])
        XCTAssertEqual(functionHotkey.keyUpEvents, [
            SyntheticHotkeyEvent(keyCode: 63, keyDown: false, type: .flagsChanged, flags: []),
        ])
        XCTAssertThrowsError(try parser.parseRequired("⌘ F13")) { error in
            XCTAssertEqual(error as? HotkeyParseError, .unknownToken("F13"))
        }
        XCTAssertThrowsError(try parser.parseRequired("⌘ A B")) { error in
            XCTAssertEqual(error as? HotkeyParseError, .multipleKeys)
        }
        XCTAssertThrowsError(try parser.parseRequired("⌘ ⌘ A")) { error in
            XCTAssertEqual(error as? HotkeyParseError, .duplicateModifier("⌘"))
        }
        XCTAssertNotNil(parser.parse("Fn"))
        XCTAssertNotNil(parser.parse("⌘Fn"))
        XCTAssertNil(parser.parse("Fn+A"))
        XCTAssertNil(parser.parse("⌘ A B"))
    }

    @MainActor
    func testTesterCountsDownThenSendsOneCompletePress() async throws {
        let clock = ImmediateHotkeyTestClock()
        let emitter = RecordingHotkeyEmitter(isAuthorized: true)
        var countdown: [Int] = []

        let result = try await HotkeyTester(emitter: emitter, clock: clock).test("⌥Space") { seconds in
            countdown.append(seconds)
        }

        XCTAssertEqual(clock.requestedSeconds, [1, 1, 1])
        XCTAssertEqual(countdown, [3, 2, 1])
        XCTAssertEqual(emitter.events, [.down(keyCode: 49), .up(keyCode: 49)])
        XCTAssertEqual(result, .eventSent(displayValue: "⌥Space"))
        XCTAssertEqual(result.message, "按键事件已发送")
    }

    @MainActor
    func testTesterHoldsModifierOnlyCombinationForOneSecondBeforeRelease() async throws {
        let clock = ImmediateHotkeyTestClock()
        let emitter = RecordingHotkeyEmitter(isAuthorized: true)

        let result = try await HotkeyTester(emitter: emitter, clock: clock).test("⌘⌥")

        XCTAssertEqual(clock.requestedSeconds, [1, 1, 1, 1])
        XCTAssertEqual(emitter.events, [
            .down(keyCode: 55),
            .down(keyCode: 58),
            .up(keyCode: 58),
            .up(keyCode: 55),
        ])
        XCTAssertEqual(result, .eventSent(displayValue: "⌘⌥"))
        XCTAssertEqual(result.message, "按键事件已发送")
    }

    @MainActor
    func testTesterCancellationStopsBeforeSendingEvents() async {
        let clock = CancellingHotkeyTestClock()
        let emitter = RecordingHotkeyEmitter(isAuthorized: true)

        do {
            _ = try await HotkeyTester(emitter: emitter, clock: clock).test("⌥Space")
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            XCTAssertEqual(clock.requestedSeconds, [1])
            XCTAssertEqual(emitter.events, [])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testTesterMapsFormatPermissionAndSendFailures() async throws {
        let clock = ImmediateHotkeyTestClock()

        do {
            _ = try await HotkeyTester(
                emitter: RecordingHotkeyEmitter(isAuthorized: true),
                clock: clock
            ).test("Space")
            XCTFail("Expected invalid format")
        } catch {
            XCTAssertEqual(error as? HotkeyTestError, .invalidFormat)
        }

        do {
            _ = try await HotkeyTester(
                emitter: RecordingHotkeyEmitter(isAuthorized: false),
                clock: clock
            ).test("⌥Space")
            XCTFail("Expected permission error")
        } catch {
            XCTAssertEqual(error as? HotkeyTestError, .accessibilityPermissionRequired)
        }

        let failingEmitter = RecordingHotkeyEmitter(isAuthorized: true, failOnDown: true)
        do {
            _ = try await HotkeyTester(emitter: failingEmitter, clock: clock).test("⌥Space")
            XCTFail("Expected send failure")
        } catch {
            XCTAssertEqual(error as? HotkeyTestError, .sendFailed)
            XCTAssertEqual(failingEmitter.events, [.down(keyCode: 49)])
        }
    }

    @MainActor
    func testTesterReportsSendFailureWhenKeyUpFailsAfterSuccessfulDown() async {
        let clock = ImmediateHotkeyTestClock()
        let emitter = RecordingHotkeyEmitter(isAuthorized: true, failUpAttempts: 1)

        do {
            _ = try await HotkeyTester(emitter: emitter, clock: clock).test("⌥Space")
            XCTFail("Expected send failure")
        } catch {
            XCTAssertEqual(error as? HotkeyTestError, .sendFailed)
            XCTAssertEqual(emitter.events, [
                .down(keyCode: 49),
                .up(keyCode: 49),
                .recovery(keyCode: 49),
            ])
        }
    }
}

@MainActor
private final class RecordingHotkeyEmitter: HotkeyEmitting {
    enum Event: Equatable {
        case down(keyCode: CGKeyCode)
        case up(keyCode: CGKeyCode)
        case recovery(keyCode: CGKeyCode)
    }

    let isAuthorized: Bool
    private let failOnDown: Bool
    private var remainingFailedUps: Int
    private(set) var events: [Event] = []

    init(isAuthorized: Bool, failOnDown: Bool = false, failUpAttempts: Int = 0) {
        self.isAuthorized = isAuthorized
        self.failOnDown = failOnDown
        self.remainingFailedUps = failUpAttempts
    }

    func keyDown(_ hotkey: ParsedHotkey) throws {
        events.append(contentsOf: hotkey.keyDownEvents.map { .down(keyCode: $0.keyCode) })
        if failOnDown { throw AudioInputBridgeError.audioSystemFailure }
    }

    func keyUp(_ hotkey: ParsedHotkey) throws {
        events.append(contentsOf: hotkey.keyUpEvents.map { .up(keyCode: $0.keyCode) })
        if remainingFailedUps > 0 {
            remainingFailedUps -= 1
            throw AudioInputBridgeError.audioSystemFailure
        }
    }

    func recoverAfterKeyUpFailure(_ hotkey: ParsedHotkey) {
        events.append(contentsOf: hotkey.keyUpEvents.map { .recovery(keyCode: $0.keyCode) })
    }
}

private final class ImmediateHotkeyTestClock: HotkeyTestClock {
    private(set) var requestedSeconds: [UInt64] = []

    func sleep(seconds: UInt64) async throws {
        requestedSeconds.append(seconds)
    }
}

private final class CancellingHotkeyTestClock: HotkeyTestClock {
    private(set) var requestedSeconds: [UInt64] = []

    func sleep(seconds: UInt64) async throws {
        requestedSeconds.append(seconds)
        throw CancellationError()
    }
}
