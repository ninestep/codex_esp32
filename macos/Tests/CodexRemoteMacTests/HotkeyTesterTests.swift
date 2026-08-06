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

    func testParserNormalizesStandaloneFunctionKeyWithDistinctDownAndUpFlags() throws {
        let parser = HotkeyParser()

        for value in ["Fn", "fn", "FN"] {
            let hotkey = try parser.parseRequired(value)
            XCTAssertEqual(hotkey.displayValue, "Fn")
            XCTAssertEqual(hotkey.keyCode, 0x3F)
            XCTAssertEqual(hotkey.keyDownFlags, .maskSecondaryFn)
            XCTAssertEqual(hotkey.keyUpFlags, [])
            XCTAssertTrue(hotkey.requiresHoldMode)
        }
    }

    func testParserRejectsInvalidOrAmbiguousHotkeys() throws {
        let parser = HotkeyParser()

        XCTAssertThrowsError(try parser.parseRequired("Space")) { error in
            XCTAssertEqual(error as? HotkeyParseError, .missingModifier)
        }
        XCTAssertThrowsError(try parser.parseRequired("⌘⇧")) { error in
            XCTAssertEqual(error as? HotkeyParseError, .missingKey)
        }
        XCTAssertThrowsError(try parser.parseRequired("⌘ F13")) { error in
            XCTAssertEqual(error as? HotkeyParseError, .unknownToken("F13"))
        }
        XCTAssertThrowsError(try parser.parseRequired("⌘ A B")) { error in
            XCTAssertEqual(error as? HotkeyParseError, .multipleKeys)
        }
        XCTAssertThrowsError(try parser.parseRequired("⌘ ⌘ A")) { error in
            XCTAssertEqual(error as? HotkeyParseError, .duplicateModifier("⌘"))
        }
        for value in ["⌘Fn", "Fn+A"] {
            XCTAssertThrowsError(try parser.parseRequired(value)) { error in
                XCTAssertEqual(error as? HotkeyParseError, .functionKeyMustBeStandalone)
            }
        }
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
    func testTesterHoldsFunctionKeyForOneSecondBeforeRelease() async throws {
        let clock = ImmediateHotkeyTestClock()
        let emitter = RecordingHotkeyEmitter(isAuthorized: true)

        let result = try await HotkeyTester(emitter: emitter, clock: clock).test("Fn")

        XCTAssertEqual(clock.requestedSeconds, [1, 1, 1, 1])
        XCTAssertEqual(emitter.events, [.down(keyCode: 0x3F), .up(keyCode: 0x3F)])
        XCTAssertEqual(result, .eventSent(displayValue: "Fn"))
        XCTAssertEqual(result.message, "Fn 按住事件已发送")
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
        events.append(.down(keyCode: hotkey.keyCode))
        if failOnDown { throw AudioInputBridgeError.audioSystemFailure }
    }

    func keyUp(_ hotkey: ParsedHotkey) throws {
        events.append(.up(keyCode: hotkey.keyCode))
        if remainingFailedUps > 0 {
            remainingFailedUps -= 1
            throw AudioInputBridgeError.audioSystemFailure
        }
    }

    func recoverAfterKeyUpFailure(_ hotkey: ParsedHotkey) {
        events.append(.recovery(keyCode: hotkey.keyCode))
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
