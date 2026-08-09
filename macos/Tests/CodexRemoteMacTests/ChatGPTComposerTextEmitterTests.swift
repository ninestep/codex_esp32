import XCTest
@testable import CodexRemoteMac

@MainActor
final class ChatGPTComposerTextEmitterTests: XCTestCase {
    func testInsertsTextIntoLocatedChatGPTProcess() throws {
        let query = RecordingComposerAccessor()
        let emitter = makeEmitter(query: query)

        try emitter.emit(text: "你好，Codex")

        XCTAssertEqual(query.insertions, [.init(text: "你好，Codex", processIdentifier: 88)])
    }

    func testDoesNotUseAccessibilityWhenChatGPTIsMissing() {
        let query = RecordingComposerAccessor()
        let emitter = ChatGPTComposerTextEmitter(
            applicationLocator: ChatGPTApplicationLocator(
                applicationProvider: StubEmitterApplicationProvider(applications: [])
            ),
            accessibilityQuery: query
        )

        XCTAssertThrowsError(try emitter.emit(text: "不会误写")) { error in
            XCTAssertEqual(
                error as? ChatGPTComposerTextEmitterError,
                .application(.notRunning)
            )
        }
        XCTAssertTrue(query.insertions.isEmpty)
    }

    func testDoesNotUseAccessibilityWhenTextIsEmpty() {
        let query = RecordingComposerAccessor()
        let emitter = makeEmitter(query: query)

        XCTAssertThrowsError(try emitter.emit(text: "")) { error in
            XCTAssertEqual(error as? ChatGPTComposerTextEmitterError, .emptyText)
        }
        XCTAssertTrue(query.insertions.isEmpty)
    }

    func testPreservesAccessibilityFailure() {
        let query = RecordingComposerAccessor(error: .unsupportedFocusedRole("AXSearchField"))
        let emitter = makeEmitter(query: query)

        XCTAssertThrowsError(try emitter.emit(text: "不能进入搜索框")) { error in
            XCTAssertEqual(
                error as? ChatGPTComposerTextEmitterError,
                .accessibility(.unsupportedFocusedRole("AXSearchField"))
            )
        }
    }

    private func makeEmitter(query: RecordingComposerAccessor) -> ChatGPTComposerTextEmitter {
        ChatGPTComposerTextEmitter(
            applicationLocator: ChatGPTApplicationLocator(
                applicationProvider: StubEmitterApplicationProvider(applications: [
                    ChatGPTApplication(processIdentifier: 88, bundleIdentifier: "com.openai.codex"),
                ])
            ),
            accessibilityQuery: query
        )
    }
}

private struct RecordedInsertion: Equatable {
    let text: String
    let processIdentifier: pid_t
}

@MainActor
private final class RecordingComposerAccessor: ChatGPTComposerAccessing {
    let error: AccessibilityTreeQueryError?
    var insertions: [RecordedInsertion] = []

    init(error: AccessibilityTreeQueryError? = nil) {
        self.error = error
    }

    func insertAtFocusedComposer(text: String, processIdentifier: pid_t) throws {
        if let error { throw error }
        insertions.append(.init(text: text, processIdentifier: processIdentifier))
    }
}

@MainActor
private final class StubEmitterApplicationProvider: RunningApplicationProviding {
    let applications: [ChatGPTApplication]

    init(applications: [ChatGPTApplication]) {
        self.applications = applications
    }

    func runningApplications() -> [ChatGPTApplication] { applications }
}
