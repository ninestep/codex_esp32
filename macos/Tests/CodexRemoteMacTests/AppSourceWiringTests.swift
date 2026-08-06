import Foundation
import XCTest

final class AppSourceWiringTests: XCTestCase {
    func testAppDeclaresGhosttyAutomationUsage() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = macosRoot.appendingPathComponent("App/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(
            info["NSAppleEventsUsageDescription"] as? String,
            "允许 Codex Remote 控制 Ghostty，以聚焦用户选择的 Codex 会话并发送终端操作。"
        )
    }

    func testMenuBarLabelObservesAppModel() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = macosRoot.appendingPathComponent("Sources/CodexRemoteApp/CodexRemoteApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("MenuBarStatusLabel(model: appDelegate.model)"))
        XCTAssertTrue(source.contains("@ObservedObject var model: AppModel"))
    }

    func testCoreBluetoothResetsPersistedDeviceInfoSubscription() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = macosRoot.appendingPathComponent(
            "Sources/CodexRemoteMac/Bluetooth/CoreBluetoothTransport.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("pendingSubscriptionResets.insert(role)"))
        XCTAssertTrue(source.contains("setNotifyValue(false, for: characteristic)"))
        XCTAssertTrue(source.contains("pendingSubscriptionResets.remove(role) != nil"))
        XCTAssertTrue(source.contains("setNotifyValue(true, for: characteristic)"))
    }
}
