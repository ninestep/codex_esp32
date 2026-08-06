import ApplicationServices
import XCTest
@testable import CodexRemoteMac

final class HotkeyRecordingSessionTests: XCTestCase {
    func testCompletesTwoModifierCombinationOnlyAfterEveryModifierIsReleased() {
        var session = HotkeyRecordingSession()

        XCTAssertEqual(session.update(flags: .maskCommand), .recording("⌘"))
        XCTAssertEqual(
            session.update(flags: [.maskCommand, .maskAlternate]),
            .recording("⌘⌥")
        )
        XCTAssertEqual(session.update(flags: .maskCommand), .recording("⌘⌥"))
        XCTAssertEqual(session.update(flags: []), .completed("⌘⌥"))
    }

    func testNormalizesThreeModifiersRegardlessOfPressOrder() {
        var session = HotkeyRecordingSession()

        XCTAssertEqual(session.update(flags: .maskControl), .recording("⌃"))
        XCTAssertEqual(
            session.update(flags: [.maskControl, .maskAlternate]),
            .recording("⌥⌃")
        )
        XCTAssertEqual(
            session.update(flags: [.maskCommand, .maskControl, .maskAlternate]),
            .recording("⌘⌥⌃")
        )
        XCTAssertEqual(session.update(flags: []), .completed("⌘⌥⌃"))
    }

    func testRejectsSingleModifierAndUnsupportedFlagsWithoutCompleting() {
        var singleModifier = HotkeyRecordingSession()
        XCTAssertEqual(singleModifier.update(flags: .maskCommand), .recording("⌘"))
        XCTAssertEqual(singleModifier.update(flags: []), .invalid)

        var shiftCombination = HotkeyRecordingSession()
        XCTAssertEqual(
            shiftCombination.update(flags: [.maskCommand, .maskShift]),
            .invalid
        )
        XCTAssertEqual(shiftCombination.update(flags: []), .invalid)

        var functionCombination = HotkeyRecordingSession()
        XCTAssertEqual(
            functionCombination.update(flags: [.maskCommand, .maskSecondaryFn]),
            .invalid
        )
    }

    func testResetDiscardsPendingCombination() {
        var session = HotkeyRecordingSession()
        _ = session.update(flags: [.maskCommand, .maskAlternate])

        session.reset()

        XCTAssertEqual(session.update(flags: []), .invalid)
    }
}
