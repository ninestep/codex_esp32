import Foundation
import XCTest
@testable import CodexRemoteCore

final class SessionStateReducerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testPromptStartsWorkAndPermissionRequiresInput() {
        let reducer = SessionStateReducer()
        let working = reducer.reduce(.userPromptSubmitted, from: .idle, at: now)
        let waiting = reducer.reduce(.permissionRequested("允许执行？"), from: working.state, at: now)

        XCTAssertEqual(working.state, .working)
        XCTAssertEqual(waiting.state, .requiresInput)
        XCTAssertEqual(waiting.statusDetail, "允许执行？")
    }

    func testNormalStopBecomesUnreadAndViewingClearsIt() {
        let reducer = SessionStateReducer()
        let complete = reducer.reduce(.stopped(.normal("任务完成")), from: .working, at: now)
        let viewed = reducer.reduce(.detailViewed, from: complete.state, at: now)

        XCTAssertEqual(complete.state, .completeUnread)
        XCTAssertTrue(complete.unread)
        XCTAssertEqual(viewed.state, .idle)
        XCTAssertFalse(viewed.unread)
    }

    func testFatalFailureWinsOverWorking() {
        let result = SessionStateReducer().reduce(.failed("进程退出 1"), from: .working, at: now)
        XCTAssertEqual(result.state, .error)
        XCTAssertEqual(result.statusDetail, "进程退出 1")
    }
}
