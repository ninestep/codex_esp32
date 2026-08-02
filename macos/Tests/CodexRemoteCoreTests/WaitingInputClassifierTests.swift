import XCTest
@testable import CodexRemoteCore

final class WaitingInputClassifierTests: XCTestCase {
    private let classifier = WaitingInputClassifier()

    func testBlockingConfirmationIsAmber() {
        let text = "如确认该远程仓库可信并授权推送，请回复“确认推送”，我会继续推送到 origin/master。"
        XCTAssertEqual(classifier.classify(text), .blocking(text))
    }

    func testChoiceRequiredIsAmber() {
        let text = "需要你选择 A 或 B 后才能继续。"
        XCTAssertEqual(classifier.classify(text), .blocking(text))
    }

    func testConfirmationBeforeContinueIsAmber() {
        let text = "确认后我会继续执行。"
        XCTAssertEqual(classifier.classify(text), .blocking(text))
    }

    func testOptionalOfferIsNormalCompletion() {
        let text = "任务已经完成。如果你愿意，我也可以继续优化。"
        XCTAssertEqual(classifier.classify(text), .normal(text))
    }

    func testQuestionInsideCompletedExplanationIsNormal() {
        let text = "这里解释了为什么会失败，但当前修改已经完成。"
        XCTAssertEqual(classifier.classify(text), .normal(text))
    }
}
