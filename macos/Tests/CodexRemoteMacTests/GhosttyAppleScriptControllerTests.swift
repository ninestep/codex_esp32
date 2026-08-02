import XCTest
@testable import CodexRemoteCore
@testable import CodexRemoteMac

final class GhosttyAppleScriptControllerTests: XCTestCase {
    func testSendEnterTargetsTerminal() async throws {
        let runner = RecordingAppleScriptRunner()
        let controller = GhosttyAppleScriptController(runner: runner)

        try await controller.sendKey(.enter, to: "term-42")

        let scripts = await runner.scripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains(#"terminal id "term-42""#))
        XCTAssertTrue(scripts[0].contains(#"send key "enter""#))
    }

    func testSendEscapeTargetsTerminal() async throws {
        let runner = RecordingAppleScriptRunner()
        let controller = GhosttyAppleScriptController(runner: runner)

        try await controller.sendKey(.escape, to: "term-42")

        let scripts = await runner.scripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains(#"terminal id "term-42""#))
        XCTAssertTrue(scripts[0].contains(#"send key "escape""#))
    }

    func testScrollUsesPreciseDelta() async throws {
        let runner = RecordingAppleScriptRunner()
        let controller = GhosttyAppleScriptController(runner: runner)

        try await controller.scroll(deltaY: -12, terminalTargetID: "term-42")

        let scripts = await runner.scripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains(#"terminal id "term-42""#))
        XCTAssertTrue(scripts[0].contains("send mouse scroll x 0 y -12 precision true"))
    }

    func testCaptureParsesFocusedTerminalContext() async throws {
        let runner = RecordingAppleScriptRunner(result: "term-42\t/work/esp32\tesp32")
        let controller = GhosttyAppleScriptController(runner: runner)

        let context = try await controller.captureFocusedTerminal()

        XCTAssertEqual(
            context,
            TerminalContext(
                terminalTargetID: "term-42",
                workingDirectory: "/work/esp32",
                displayTitle: "esp32"
            )
        )
    }

    func testCaptureRejectsIncompleteFocusedTerminalResponse() async throws {
        let runner = RecordingAppleScriptRunner(result: "term-42\t/work/esp32")
        let controller = GhosttyAppleScriptController(runner: runner)

        do {
            _ = try await controller.captureFocusedTerminal()
            XCTFail("Expected noFocusedTerminal")
        } catch {
            XCTAssertEqual(error as? GhosttyControllerError, .noFocusedTerminal)
        }
    }

    func testInvalidTerminalIDDoesNotRunScript() async throws {
        let runner = RecordingAppleScriptRunner()
        let controller = GhosttyAppleScriptController(runner: runner)

        do {
            try await controller.sendKey(.enter, to: #"term-"42"#)
            XCTFail("Expected invalidTerminalID")
        } catch {
            XCTAssertEqual(error as? GhosttyControllerError, .invalidTerminalID)
        }

        do {
            try await controller.scroll(deltaY: -12, terminalTargetID: #"term\42"#)
            XCTFail("Expected invalidTerminalID")
        } catch {
            XCTAssertEqual(error as? GhosttyControllerError, .invalidTerminalID)
        }

        let scripts = await runner.scripts
        XCTAssertTrue(scripts.isEmpty)
    }
}

private actor RecordingAppleScriptRunner: AppleScriptRunning {
    private(set) var scripts: [String] = []
    private let result: String

    init(result: String = "") {
        self.result = result
    }

    func run(source: String) async throws -> String {
        scripts.append(source)
        return result
    }
}
