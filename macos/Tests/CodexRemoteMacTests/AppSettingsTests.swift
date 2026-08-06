import Foundation
import XCTest
@testable import CodexRemoteMac

final class AppSettingsTests: XCTestCase {
    func testDefaultsUsePerUserSocketAndAutomaticReconnect() {
        let settings = AppSettings.defaults(temporaryDirectory: "/private/tmp/", userID: 501)

        XCTAssertEqual(settings.socketPath, "/private/tmp/codex-remote-501/events.sock")
        XCTAssertTrue(settings.automaticBLEReconnect)
        XCTAssertEqual(settings.doubaoHotkey, "")
        XCTAssertEqual(settings.hotkeyMode, .hold)
        XCTAssertNil(settings.lastTestedDoubaoHotkey)
    }

    func testPTTRequiresSelectionBlackHoleAndConfiguredHotkey() {
        var settings = AppSettings.defaults(temporaryDirectory: "/tmp", userID: 501)
        settings.doubaoHotkey = "⌥Space"

        XCTAssertFalse(settings.canUsePTT(hasSelectedSession: false, blackHoleAvailable: true))
        XCTAssertFalse(settings.canUsePTT(hasSelectedSession: true, blackHoleAvailable: false))
        XCTAssertTrue(settings.canUsePTT(hasSelectedSession: true, blackHoleAvailable: true))
    }

    func testEncodedSettingsContainNoPromptTranscriptOrRecording() throws {
        let data = try JSONEncoder().encode(AppSettings.defaults(temporaryDirectory: "/tmp", userID: 501))
        let json = String(decoding: data, as: UTF8.self).lowercased()

        XCTAssertFalse(json.contains("prompt"))
        XCTAssertFalse(json.contains("transcript"))
        XCTAssertFalse(json.contains("recording"))
        XCTAssertFalse(json.contains("permission"))
        XCTAssertFalse(json.contains("recognized"))
    }

    func testMissingBlackHoleMessageIsExplicit() {
        XCTAssertEqual(AudioDependencyStatus.blackHoleMissing.userMessage, "未检测到 BlackHole 2ch，语音功能不可用")
    }

    func testDecodingLegacySettingsUsesStableDefaultsForMissingFields() throws {
        let data = Data("{}".utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.socketPath, "/tmp/codex-remote/events.sock")
        XCTAssertTrue(settings.automaticBLEReconnect)
        XCTAssertEqual(settings.doubaoHotkey, "")
        XCTAssertEqual(settings.hotkeyMode, .hold)
        XCTAssertNil(settings.lastTestedDoubaoHotkey)
    }

    func testEncodingNormalizesDoubaoHotkey() throws {
        let settings = AppSettings(
            socketPath: "/tmp/custom.sock",
            automaticBLEReconnect: false,
            doubaoHotkey: "⌘ ⇧ v",
            hotkeyMode: .toggle
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.doubaoHotkey, "⌘⇧V")
        XCTAssertEqual(decoded.hotkeyMode, .toggle)
    }

    func testModifierOnlyCombinationNormalizesAndForcesHoldMode() throws {
        var settings = AppSettings(
            socketPath: "/tmp/custom.sock",
            automaticBLEReconnect: true,
            doubaoHotkey: "option command",
            hotkeyMode: .toggle
        )

        try settings.normalizeDoubaoHotkey()

        XCTAssertEqual(settings.doubaoHotkey, "⌘⌥")
        XCTAssertEqual(settings.hotkeyMode, .hold)
    }

    func testDecodingInvalidHotkeyModeFallsBackWithoutDroppingOtherFields() throws {
        let invalidString = Data("""
        {
          "socketPath": "/tmp/custom.sock",
          "automaticBLEReconnect": false,
          "doubaoHotkey": "⌘ ⇧ v",
          "hotkeyMode": "press"
        }
        """.utf8)
        let invalidType = Data("""
        {
          "socketPath": "/tmp/number.sock",
          "automaticBLEReconnect": false,
          "doubaoHotkey": "⌥ Space",
          "hotkeyMode": 42
        }
        """.utf8)

        let stringSettings = try JSONDecoder().decode(AppSettings.self, from: invalidString)
        let typeSettings = try JSONDecoder().decode(AppSettings.self, from: invalidType)

        XCTAssertEqual(stringSettings.socketPath, "/tmp/custom.sock")
        XCTAssertFalse(stringSettings.automaticBLEReconnect)
        XCTAssertEqual(stringSettings.doubaoHotkey, "⌘⇧V")
        XCTAssertEqual(stringSettings.hotkeyMode, .hold)
        XCTAssertEqual(typeSettings.socketPath, "/tmp/number.sock")
        XCTAssertFalse(typeSettings.automaticBLEReconnect)
        XCTAssertEqual(typeSettings.doubaoHotkey, "⌥Space")
        XCTAssertEqual(typeSettings.hotkeyMode, .hold)
    }

    func testHotkeyEvidenceOnlyMatchesTheExactNormalizedCurrentValue() throws {
        var settings = AppSettings(
            socketPath: "/tmp/custom.sock",
            automaticBLEReconnect: true,
            doubaoHotkey: "⌘ ⇧ v",
            hotkeyMode: .hold
        )

        settings.recordSuccessfulHotkeyTest(displayValue: "⌘⇧V")
        XCTAssertTrue(settings.wasCurrentHotkeyTested)

        settings.doubaoHotkey = "⌥Space"
        XCTAssertFalse(settings.wasCurrentHotkeyTested)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.lastTestedDoubaoHotkey, "⌘⇧V")
        XCTAssertFalse(decoded.wasCurrentHotkeyTested)
    }
}
