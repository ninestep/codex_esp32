import CodexRemoteCore
import Foundation
import XCTest
@testable import CodexRemoteMac

final class CodexMicroLayoutSettingsTests: XCTestCase {
    func testReadsCurrentDefaultKeycapAssignments() throws {
        let source = """
        [desktop.codex-micro-layout]
        version = 1
        separateMicrophoneKeys = false
        encoderMode = "conversation-scroll"

        [desktop.codex-micro-layout.slots.ACT06]
        keycapId = "FAST"

        [desktop.codex-micro-layout.slots.ACT07]
        keycapId = "APPR"

        [desktop.codex-micro-layout.slots.ACT08]
        keycapId = "REJ"

        [desktop.codex-micro-layout.slots.ACT09]
        keycapId = "SPLIT"

        [desktop.codex-micro-layout.slots.ACT10_ACT11]
        keycapId = "MIC"

        [desktop.codex-micro-layout.slots.ACT12]
        keycapId = "CODEX"

        [desktop.codex-micro-layout.analogStick.up]
        type = "command"
        commandId = "composer.togglePlanMode"

        [desktop.codex-micro-layout.analogStick.right]
        type = "command"
        commandId = "navigateForward"

        [desktop.codex-micro-layout.analogStick.down]
        type = "command"
        commandId = "toggleSidebar"

        [desktop.codex-micro-layout.analogStick.left]
        type = "command"
        commandId = "navigateBack"
        """

        let layout = try CodexMicroLayoutParser().parse(source)

        XCTAssertEqual(layout.activeCommandSlots.map(\.slot), [
            .act06, .act07, .act08, .act09, .act10Act11, .act12,
        ])
        XCTAssertEqual(layout.activeCommandSlots.map(\.action), [
            .command(id: "composer.toggleFastMode"),
            .command(id: "approval.approve"),
            .command(id: "approval.decline"),
            .command(id: "forkThread"),
            .pushToTalk,
            .command(id: "composer.submit"),
        ])
        XCTAssertEqual(layout.companionLayout, MicroControlLayout(
            controls: ["快速模式", "批准", "拒绝", "在新会话中继续", "按住说话", "发送"],
            encoder: "会话滚动",
            directions: ["计划模式", "前进", "显示或隐藏侧栏", "后退"]
        ))
    }

    func testExplicitCommandAndSkillOverrideKeycapDefaults() throws {
        let source = """
        [desktop.codex-micro-layout]
        version = 1
        separateMicrophoneKeys = true

        [desktop.codex-micro-layout.slots.ACT07]
        keycapId = "APPR"

        [desktop.codex-micro-layout.slots.ACT07.action]
        type = "command"
        commandId = "toggleSidebar"

        [desktop.codex-micro-layout.slots.ACT08.action]
        type = "skill"
        skillId = "review-current-change"
        """

        let layout = try CodexMicroLayoutParser().parse(source)

        XCTAssertTrue(layout.separateMicrophoneKeys)
        XCTAssertEqual(layout.slots[.act07]?.action, .command(id: "toggleSidebar"))
        XCTAssertEqual(layout.slots[.act08]?.action, .skill(id: "review-current-change"))
        XCTAssertEqual(layout.activeCommandSlots.map(\.slot), [
            .act06, .act07, .act08, .act09, .act10, .act11, .act12,
        ])
        XCTAssertEqual(layout.companionLayout.controls.count, 6)
        XCTAssertEqual(layout.companionLayout.controls[4], "按住说话")
    }

    func testMissingLayoutUsesEffectiveDefaults() throws {
        let layout = try CodexMicroLayoutParser().parse("model = \"gpt-5.6\"")

        XCTAssertEqual(layout, .defaults)
    }

    func testUnsupportedLayoutVersionFailsExplicitly() {
        XCTAssertThrowsError(try CodexMicroLayoutParser().parse("""
        [desktop.codex-micro-layout]
        version = 2
        """)) { error in
            XCTAssertEqual(error as? CodexMicroLayoutReadError, .unsupportedVersion(2))
        }
    }

    func testReaderUsesInjectedConfigurationURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurationURL = directory.appendingPathComponent("config.toml")
        try """
        [desktop.codex-micro-layout]
        version = 1
        [desktop.codex-micro-layout.slots.ACT12.action]
        type = "command"
        commandId = "newTask"
        """.write(to: configurationURL, atomically: true, encoding: .utf8)

        let layout = try CodexMicroLayoutReader(configurationURL: configurationURL).read()

        XCTAssertEqual(layout.slots[.act12]?.action, .command(id: "newTask"))
    }
}
