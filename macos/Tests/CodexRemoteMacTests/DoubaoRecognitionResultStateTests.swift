@testable import CodexRemoteMac
import XCTest

final class DoubaoRecognitionResultStateTests: XCTestCase {
    func testFirstResultUpdatesCandidateWithoutCompletingRecognition() {
        var state = DoubaoRecognitionResultState()

        let completedText = state.receiveResult("这是前半段")

        XCTAssertNil(completedText)
        XCTAssertEqual(state.latestText, "这是前半段")
        XCTAssertFalse(state.didReceiveServerFinish)
    }

    func testLaterResultReplacesCandidateAndFinishReturnsCompleteText() {
        var state = DoubaoRecognitionResultState()
        _ = state.receiveResult("这是前半段")
        _ = state.receiveResult("这是前半段和后半段")

        let completedText = state.receiveFinish()

        XCTAssertEqual(completedText, "这是前半段和后半段")
        XCTAssertTrue(state.didReceiveServerFinish)
    }
}
