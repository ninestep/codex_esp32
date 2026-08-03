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
        assertUsesGhosttyBundleID(scripts[0])
        XCTAssertTrue(scripts[0].contains(#"terminal id "term-42""#))
        XCTAssertTrue(scripts[0].contains(#"send key "enter" to targetTerm"#))
    }

    func testSendEscapeTargetsTerminal() async throws {
        let runner = RecordingAppleScriptRunner()
        let controller = GhosttyAppleScriptController(runner: runner)

        try await controller.sendKey(.escape, to: "term-42")

        let scripts = await runner.scripts
        XCTAssertEqual(scripts.count, 1)
        assertUsesGhosttyBundleID(scripts[0])
        XCTAssertTrue(scripts[0].contains(#"terminal id "term-42""#))
        XCTAssertTrue(scripts[0].contains(#"send key "escape" to targetTerm"#))
    }

    func testScrollUsesPreciseDelta() async throws {
        let runner = RecordingAppleScriptRunner()
        let controller = GhosttyAppleScriptController(runner: runner)

        try await controller.scroll(deltaY: -12, terminalTargetID: "term-42")

        let scripts = await runner.scripts
        XCTAssertEqual(scripts.count, 1)
        assertUsesGhosttyBundleID(scripts[0])
        XCTAssertTrue(scripts[0].contains(#"terminal id "term-42""#))
        XCTAssertTrue(scripts[0].contains("send mouse scroll x 0 y -12 precision true to targetTerm"))
    }

    func testFocusTargetsTerminal() async throws {
        let runner = RecordingAppleScriptRunner()
        let controller = GhosttyAppleScriptController(runner: runner)

        try await controller.focus(terminalTargetID: "term-42")

        let scripts = await runner.scripts
        XCTAssertEqual(scripts.count, 1)
        assertUsesGhosttyBundleID(scripts[0])
        XCTAssertTrue(scripts[0].contains(#"terminal id "term-42""#))
        XCTAssertTrue(scripts[0].contains("focus targetTerm"))
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
        let scripts = await runner.scripts
        XCTAssertEqual(scripts.count, 1)
        assertUsesGhosttyBundleID(scripts[0])
        XCTAssertTrue(scripts[0].contains("return (id of targetTerm) & (ASCII character 9) & (working directory of targetTerm) & (ASCII character 9) & (name of targetTerm)"))
        XCTAssertFalse(scripts[0].contains(" & tab & "))
    }

    func testCaptureRejectsMalformedFocusedTerminalResponse() async throws {
        for output in [
            "term-42\t/work/esp32",
            "\t/path\ttitle",
            "term-42\t/work/esp32\tesp32\textra",
        ] {
            let runner = RecordingAppleScriptRunner(result: output)
            let controller = GhosttyAppleScriptController(runner: runner)

            do {
                _ = try await controller.captureFocusedTerminal()
                XCTFail("Expected noFocusedTerminal for \(output)")
            } catch {
                XCTAssertEqual(error as? GhosttyControllerError, .noFocusedTerminal)
            }
        }
    }

    func testInvalidTerminalIDDoesNotRunScript() async throws {
        let runner = RecordingAppleScriptRunner()
        let controller = GhosttyAppleScriptController(runner: runner)

        for terminalID in [
            "",
            #"term-"42"#,
            #"term\42"#,
            "term\n42",
            "term\r42",
            "term\t42",
        ] {
            do {
                try await controller.sendKey(.enter, to: terminalID)
                XCTFail("Expected invalidTerminalID for \(terminalID.debugDescription)")
            } catch {
                XCTAssertEqual(error as? GhosttyControllerError, .invalidTerminalID)
            }
        }

        let scripts = await runner.scripts
        XCTAssertTrue(scripts.isEmpty)
    }

    func testProcessRunnerReturnsTrimmedOutputFromOsascript() async throws {
        let runner = ProcessAppleScriptRunner()

        let output = try await runner.run(source: #"return "ok""#)

        XCTAssertEqual(output, "ok")
    }

    func testProcessRunnerThrowsAppleScriptFailureWithStderr() async throws {
        let runner = ProcessAppleScriptRunner()

        do {
            _ = try await runner.run(source: #"error "boom""#)
            XCTFail("Expected appleScriptFailed")
        } catch let error as GhosttyControllerError {
            guard case let .appleScriptFailed(message) = error else {
                return XCTFail("Expected appleScriptFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("boom"))
        } catch {
            XCTFail("Expected GhosttyControllerError, got \(error)")
        }
    }
}

private func assertUsesGhosttyBundleID(_ script: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(script.contains(#"tell application id "com.mitchellh.ghostty""#), file: file, line: line)
    XCTAssertFalse(script.contains(#"tell application "Ghostty""#), file: file, line: line)
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
